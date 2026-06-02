// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Market, Offer, CollateralParams} from "../src/interfaces/IMidnight.sol";
import {TickLib, MAX_TICK} from "../src/libraries/TickLib.sol";
import {WAD, LIQUIDATION_CURSOR_LOW, maxSettlementFee as _maxSettlementFee} from "../src/libraries/ConstantsLib.sol";
import {MidnightBundles} from "../src/periphery/MidnightBundles.sol";
import {
    Take,
    CollateralWithdrawal,
    TokenPermit
} from "../src/periphery/interfaces/IMidnightBundles.sol";
import {BaseTest} from "./BaseTest.sol";

/// @title F2 -- buyWithUnitsTargetAndWithdrawCollateral referral formula underflow
///
/// Root cause:
///   buyWithUnitsTargetAndWithdrawCollateral uses the formula:
///     referralFeeAssets = filledBuyerAssets * pct / (WAD - pct)
///
///   meaning the total cost to msg.sender is:
///     filledBuyerAssets * WAD / (WAD - pct)
///
///   This is DIFFERENT from buyWithAssetsTargetAndWithdrawCollateral which uses:
///     referralFeeAssets = targetBuyerAssets * pct / WAD
///
///   The asymmetry creates two failure modes:
///
///   [A] Formula confusion: users computing maxBuyerAssets as "fill * (1 + pct)" get
///       an underflow because the correct formula is "fill * WAD / (WAD - pct)".
///       For pct = 50%, the user needs 2x the fill, not 1.5x.
///
///   [B] Settlement fee front-run: a user correctly calculates maxBuyerAssets for the
///       current settlement fee.  If the fee setter increases the fee between off-chain
///       preparation and on-chain execution, filledBuyerAssets grows, causing:
///         maxBuyerAssets - filledBuyerAssets - referralFeeAssets < 0 -> revert.
///
///   Both revert with an arithmetic underflow.  No funds are lost (tx is atomic),
///   but the user's tx fails unexpectedly, and they must retry with a higher cap.
///
/// Note on scope:
///   buyWithAssetsTargetAndWithdrawCollateral does NOT have this problem: its referral
///   formula guarantees referralFeeAssets < targetBuyerAssets, so the refund is always
///   >= 0 regardless of fee changes.
contract F2_ReferralFormulaUnderflowTest is BaseTest {
    MidnightBundles internal midnightBundles;
    Market internal market;
    bytes32 internal id;

    // tick 2908 = 4 x 727 (multiple of DEFAULT_TICK_SPACING=4).
    // Price ~ 0.4975 WAD -- well below WAD even after maximum settlement fee.
    uint256 internal constant SAFE_TICK    = 2908;
    uint256 internal constant TARGET_UNITS = 100e18;

    // 50 % referral -- worst case for the asymmetric formula
    uint256 internal constant REFERRAL_PCT = WAD / 2;

    function setUp() public override {
        super.setUp();

        midnightBundles = new MidnightBundles(address(midnight));

        // No settlement fees initially (default = 0).
        midnight.setFeeClaimer(makeAddr("feeClaimer"));

        market.loanToken    = address(loanToken);
        market.maturity     = vm.getBlockTimestamp() + 365 days; // long TTM -> fee matters
        market.rcfThreshold = 0;
        market.collateralParams.push(CollateralParams({
            token:  address(collateralToken1),
            lltv:   0.77e18,
            maxLif: maxLif(0.77e18, LIQUIDATION_CURSOR_LOW),
            oracle: address(oracle1)
        }));
        market.collateralParams = sortCollateralParams(market.collateralParams);
        id = midnight.touchMarket(market);

        // Lender authorises bundler on Midnight.
        vm.prank(lender);
        midnight.setIsAuthorized(address(midnightBundles), true, lender);
        vm.prank(lender);
        loanToken.approve(address(midnightBundles), type(uint256).max);
    }

    function _noPermit() internal pure returns (TokenPermit memory) {}

    function _makeSellOffer(uint256 maxUnits) internal view returns (Offer memory o) {
        o.market                  = market;
        o.buy                     = false;
        o.maker                   = borrower;
        o.receiverIfMakerIsSeller = borrower;
        o.maxUnits                = maxUnits;
        o.ratifier                = address(dummyRatifier);
        o.start                   = vm.getBlockTimestamp();
        o.expiry                  = vm.getBlockTimestamp() + 365 days;
        o.tick                    = SAFE_TICK;
    }

    /// ?? Case A: formula confusion ??????????????????????????????????????????????
    ///
    /// User thinks: 50% referral means "add 50% on top of my fill cost"
    ///              -> maxBuyerAssets = expectedFill x 1.5
    /// Reality:     referralFee = fill x pct / (WAD-pct) = fill x 1 (for pct=50%)
    ///              -> total deducted = fill x 2  > fill x 1.5 -> UNDERFLOW
    function testF2_FormulaConfusion_50pctReferral() public {
        collateralize(market, borrower, TARGET_UNITS);
        deal(address(loanToken), lender, type(uint256).max);

        Offer memory sellOffer = _makeSellOffer(TARGET_UNITS);
        Take[] memory takes    = new Take[](1);
        takes[0] = Take({ offer: sellOffer, units: TARGET_UNITS, ratifierData: hex"" });

        // Step 1: compute what the fill will actually cost (settlement fee = 0 now).
        uint256 offerPrice     = TickLib.tickToPrice(SAFE_TICK);
        uint256 settleFee      = midnight.settlementFee(id, market.maturity - block.timestamp);
        uint256 buyerPrice     = offerPrice + settleFee; // = offerPrice since fee=0
        // ceil(TARGET_UNITS * buyerPrice / WAD)
        uint256 expectedFill   = (TARGET_UNITS * buyerPrice + WAD - 1) / WAD;

        // Step 2: user mistakenly computes maxBuyerAssets = expectedFill x 1.5
        //         (correct for additive pct/WAD formula, WRONG for pct/(WAD-pct))
        uint256 wrongMax = expectedFill * 3 / 2; // 1.5x

        // Step 3: correct maxBuyerAssets = expectedFill x WAD / (WAD - pct) = 2x
        uint256 correctMax = expectedFill * WAD / (WAD - REFERRAL_PCT);

        // ?? wrong maxBuyerAssets -> REVERT ??????????????????????????????????????
        deal(address(loanToken), lender, wrongMax);
        address referralRecipient = makeAddr("referral");
        vm.prank(lender);
        vm.expectRevert(); // arithmetic underflow at: maxBuyerAssets - fill - referralFee
        midnightBundles.buyWithUnitsTargetAndWithdrawCollateral(
            TARGET_UNITS, wrongMax, lender, _noPermit(),
            takes, new CollateralWithdrawal[](0), address(0),
            REFERRAL_PCT, referralRecipient
        );

        // ?? correct maxBuyerAssets -> SUCCESS ???????????????????????????????????
        deal(address(loanToken), lender, correctMax);
        vm.prank(lender);
        midnightBundles.buyWithUnitsTargetAndWithdrawCollateral(
            TARGET_UNITS, correctMax, lender, _noPermit(),
            takes, new CollateralWithdrawal[](0), address(0),
            REFERRAL_PCT, referralRecipient
        );
        assertEq(midnight.creditOf(id, lender), TARGET_UNITS, "lender should have credit");
    }

    /// ?? Case B: settlement-fee front-run ??????????????????????????????????????
    ///
    /// User correctly calculates maxBuyerAssets for current settlement fee (= 0).
    /// Fee setter increases the fee before the user's tx executes.
    /// filledBuyerAssets increases -> referralFee increases -> underflow.
    function testF2_SettlementFeeFrontRun() public {
        collateralize(market, borrower, TARGET_UNITS);
        deal(address(loanToken), lender, type(uint256).max);

        Offer memory sellOffer = _makeSellOffer(TARGET_UNITS);
        Take[] memory takes    = new Take[](1);
        takes[0] = Take({ offer: sellOffer, units: TARGET_UNITS, ratifierData: hex"" });

        // ?? Step 1: user prepares tx based on current fee (= 0) ???????????????
        uint256 offerPrice    = TickLib.tickToPrice(SAFE_TICK);
        uint256 feeBefore     = midnight.settlementFee(id, market.maturity - block.timestamp);
        assertEq(feeBefore, 0, "initial settlement fee must be 0");

        uint256 fillBefore    = (TARGET_UNITS * (offerPrice + feeBefore) + WAD - 1) / WAD;
        // Correct maxBuyerAssets for pct=50%: fill x WAD / (WAD - pct) = fill x 2
        uint256 maxBuyerAssets = fillBefore * WAD / (WAD - REFERRAL_PCT);

        // ?? Step 2: front-run -- fee setter increases settlement fee ????????????
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, _maxSettlementFee(i));
        }

        uint256 feeAfter  = midnight.settlementFee(id, market.maturity - block.timestamp);
        assertGt(feeAfter, 0, "settlement fee must be non-zero after increase");

        // New fill cost (higher due to higher settlement fee)
        uint256 fillAfter = (TARGET_UNITS * (offerPrice + feeAfter) + WAD - 1) / WAD;
        assertGt(fillAfter, fillBefore, "fill cost increased due to fee hike");

        // Verify the underflow would occur:
        // referralFee (new) = fillAfter x pct / (WAD-pct) = fillAfter (for pct=50%)
        // total deducted    = fillAfter + fillAfter = 2 x fillAfter
        // underflow amount  = 2 x fillAfter - maxBuyerAssets = 2x(fillAfter-fillBefore) > 0
        uint256 referralFeeNew = fillAfter * REFERRAL_PCT / (WAD - REFERRAL_PCT);
        assertGt(fillAfter + referralFeeNew, maxBuyerAssets,
            "total deducted exceeds maxBuyerAssets -> underflow confirmed");

        // ?? Step 3: user's tx reverts ??????????????????????????????????????????
        deal(address(loanToken), lender, maxBuyerAssets);
        address referralRecipient = makeAddr("referral");
        vm.prank(lender);
        vm.expectRevert(); // arithmetic underflow at MidnightBundles.sol:104
        midnightBundles.buyWithUnitsTargetAndWithdrawCollateral(
            TARGET_UNITS, maxBuyerAssets, lender, _noPermit(),
            takes, new CollateralWithdrawal[](0), address(0),
            REFERRAL_PCT, referralRecipient
        );

        // ?? Step 4: with a higher maxBuyerAssets (covering new fee), tx succeeds ?
        uint256 correctMax = fillAfter * WAD / (WAD - REFERRAL_PCT) + 1; // safe ceiling
        deal(address(loanToken), lender, correctMax);
        vm.prank(lender);
        midnightBundles.buyWithUnitsTargetAndWithdrawCollateral(
            TARGET_UNITS, correctMax, lender, _noPermit(),
            takes, new CollateralWithdrawal[](0), address(0),
            REFERRAL_PCT, referralRecipient
        );
        assertEq(midnight.creditOf(id, lender), TARGET_UNITS, "lender has credit after retry");
    }

    /// ?? Contrast: buyWithAssetsTargetAndWithdrawCollateral is NOT affected ?????
    ///
    /// Its formula: referralFee = targetBuyerAssets x pct / WAD (never exceeds target)
    /// So refund = targetBuyerAssets x (1 - pct/WAD) > 0 always.
    function testF2_AssetsBundlerNotVulnerable() public {
        collateralize(market, borrower, TARGET_UNITS);
        deal(address(loanToken), lender, type(uint256).max);

        Offer memory sellOffer = _makeSellOffer(TARGET_UNITS);
        Take[] memory takes    = new Take[](1);
        takes[0] = Take({ offer: sellOffer, units: TARGET_UNITS, ratifierData: hex"" });

        // Increase fee (simulate front-run)
        for (uint256 i; i <= 6; i++) {
            midnight.setMarketSettlementFee(id, i, _maxSettlementFee(i));
        }

        // For buyWithAssetsTargetAndWithdrawCollateral: caller pays targetBuyerAssets exactly.
        // referralFee = targetBuyerAssets x pct/WAD < targetBuyerAssets -> always safe.
        uint256 offerPrice  = TickLib.tickToPrice(SAFE_TICK);
        uint256 feeNow      = midnight.settlementFee(id, market.maturity - block.timestamp);
        uint256 buyerPrice  = offerPrice + feeNow;
        // targetBuyerAssets must cover the fill: set generously
        uint256 targetBuyerAssets = TARGET_UNITS * buyerPrice / WAD + 1e18;

        deal(address(loanToken), lender, targetBuyerAssets);
        address referralRecipient = makeAddr("referral2");
        vm.prank(lender);
        // Does NOT revert -- formula pct/WAD is always safe
        midnightBundles.buyWithAssetsTargetAndWithdrawCollateral(
            targetBuyerAssets, 0, lender, _noPermit(),
            takes, new CollateralWithdrawal[](0), address(0),
            REFERRAL_PCT, referralRecipient
        );
        assertGt(midnight.creditOf(id, lender), 0, "lender received credit via assets-target bundler");
    }
}
