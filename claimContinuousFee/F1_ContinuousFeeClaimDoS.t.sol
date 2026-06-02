// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Market, Offer, CollateralParams} from "../src/interfaces/IMidnight.sol";
import {TickLib, MAX_TICK} from "../src/libraries/TickLib.sol";
import {WAD, MAX_CONTINUOUS_FEE, LIQUIDATION_CURSOR_LOW} from "../src/libraries/ConstantsLib.sol";
import {BaseTest} from "./BaseTest.sol";

/// @title F1 — claimContinuousFee DoS when withdrawable < continuousFeeCredit
///
/// Root cause:
///   claimContinuousFee decrements withdrawable, totalUnits, and continuousFeeCredit
///   by the same `amount`.  But continuousFeeCredit is funded lazily from lenders'
///   pendingFees (via _updatePosition), while the actual tokens backing those fees are
///   still locked inside borrowers' debt positions.  Until a borrower repays, withdrawable
///   stays 0, so ANY claim attempt with amount > 0 reverts with arithmetic underflow.
///
/// Impact:
///   The fee claimer earns fees "on paper" the moment lender positions are updated,
///   but cannot redeem them until borrowers repay.  There is no documentation or warning
///   about this, no way for the fee claimer to distinguish "no fees earned" from "fees
///   earned but inaccessible", and no on-chain indication of when they will become claimable.
///
/// PoC structure:
///   1. Create market with max continuous fee.
///   2. Lender lends to borrower → lender gets pendingFee, withdrawable stays 0.
///   3. Warp time and call updatePosition → continuousFeeCredit > 0, withdrawable still 0.
///   4. Fee claimer tries to claim → REVERT (withdrawable underflow).
///   5. Borrower repays PARTIAL amount (just enough) → claim now succeeds.
contract F1_ContinuousFeeClaimDoSTest is BaseTest {
    Market internal market;
    bytes32 internal id;
    address internal feeClaimer;

    uint256 internal constant LEND_UNITS = 100e18;
    uint256 internal constant WARP_DAYS  = 30;

    function setUp() public override {
        super.setUp();

        feeClaimer = makeAddr("feeClaimer");
        midnight.setFeeClaimer(feeClaimer);

        // Set max continuous fee BEFORE market creation so the market inherits it.
        midnight.setDefaultContinuousFee(address(loanToken), MAX_CONTINUOUS_FEE);

        market.loanToken        = address(loanToken);
        market.maturity         = vm.getBlockTimestamp() + 365 days;
        market.rcfThreshold     = 0;
        market.collateralParams.push(CollateralParams({
            token:   address(collateralToken1),
            lltv:    0.77e18,
            maxLif:  maxLif(0.77e18, LIQUIDATION_CURSOR_LOW),
            oracle:  address(oracle1)
        }));
        market.collateralParams = sortCollateralParams(market.collateralParams);

        // touchMarket captures the current defaultContinuousFee for this loanToken.
        id = midnight.touchMarket(market);
    }

    /// @notice Core finding: claimContinuousFee reverts when no repayments have occurred.
    function testF1_ClaimRevertsWhenWithdrawableIsZero() public {
        // ── Step 1: borrower borrows (creates debt, lender gains credit+pendingFee) ──
        Offer memory sellOffer;
        sellOffer.market                  = market;
        sellOffer.buy                     = false;
        sellOffer.maker                   = borrower;
        sellOffer.receiverIfMakerIsSeller = borrower;
        sellOffer.maxUnits                = LEND_UNITS;
        sellOffer.ratifier                = address(dummyRatifier);
        sellOffer.start                   = vm.getBlockTimestamp();
        sellOffer.expiry                  = vm.getBlockTimestamp() + 365 days;
        sellOffer.tick                    = MAX_TICK;

        collateralize(market, borrower, LEND_UNITS);
        deal(address(loanToken), lender, LEND_UNITS);
        vm.prank(lender);
        midnight.take(sellOffer, hex"", LEND_UNITS, lender, borrower, address(0), hex"");

        // ── Step 2: sanity checks immediately after take ──────────────────────────
        assertEq(midnight.withdrawable(id),         0, "withdrawable = 0 (tokens are in borrower debt)");
        assertEq(midnight.continuousFeeCredit(id),  0, "continuousFeeCredit = 0 (not yet accrued lazily)");
        assertGt(midnight.pendingFee(id, lender),   0, "lender has pending fee");

        // ── Step 3: advance time → accrue fee lazily ──────────────────────────────
        vm.warp(vm.getBlockTimestamp() + WARP_DAYS * 1 days);

        // updatePosition moves lender.pendingFee → continuousFeeCredit (Midnight.sol:846)
        midnight.updatePosition(market, lender);

        uint128 accruedFee = midnight.continuousFeeCredit(id);
        assertGt(accruedFee, 0,  "continuousFeeCredit > 0 after accrual");
        assertEq(midnight.withdrawable(id), 0, "withdrawable STILL 0 (borrower has not repaid)");

        // ── Step 4: fee claimer cannot claim — tokens are locked in debt ──────────
        // claimContinuousFee: withdrawable -= amount → underflow because withdrawable = 0
        vm.prank(feeClaimer);
        vm.expectRevert();  // arithmetic underflow
        midnight.claimContinuousFee(market, accruedFee, feeClaimer);

        // Even claiming 1 wei fails
        vm.prank(feeClaimer);
        vm.expectRevert();
        midnight.claimContinuousFee(market, 1, feeClaimer);

        // ── Step 5: borrower repays just enough → claim now unblocked ─────────────
        // Repaying `accruedFee` units is sufficient because withdrawable becomes accruedFee.
        deal(address(loanToken), borrower, accruedFee);
        vm.prank(borrower);
        midnight.repay(market, accruedFee, borrower, address(0), hex"");

        assertGe(midnight.withdrawable(id), accruedFee, "withdrawable now covers fee");

        vm.prank(feeClaimer);
        midnight.claimContinuousFee(market, accruedFee, feeClaimer);  // succeeds

        assertEq(loanToken.balanceOf(feeClaimer), accruedFee,
            "feeClaimer received fees only AFTER partial repayment");
    }

    /// @notice Quantifies the gap: continuousFeeCredit >> withdrawable across a
    ///         large outstanding loan, showing the claimer is fully blocked until maturity.
    function testF1_FeeClaimerBlockedForEntireMarketLifetime() public {
        Offer memory sellOffer;
        sellOffer.market                  = market;
        sellOffer.buy                     = false;
        sellOffer.maker                   = borrower;
        sellOffer.receiverIfMakerIsSeller = borrower;
        sellOffer.maxUnits                = LEND_UNITS;
        sellOffer.ratifier                = address(dummyRatifier);
        sellOffer.start                   = vm.getBlockTimestamp();
        sellOffer.expiry                  = vm.getBlockTimestamp() + 365 days;
        sellOffer.tick                    = MAX_TICK;

        collateralize(market, borrower, LEND_UNITS);
        deal(address(loanToken), lender, LEND_UNITS);
        vm.prank(lender);
        midnight.take(sellOffer, hex"", LEND_UNITS, lender, borrower, address(0), hex"");

        // Warp to maturity (worst case: borrower never repaid pre-maturity)
        vm.warp(market.maturity);
        midnight.updatePosition(market, lender);

        uint128 totalAccrued = midnight.continuousFeeCredit(id);

        // The full continuous fee for the lifetime is earned on paper...
        assertGt(totalAccrued, 0, "fees accrued over entire loan lifetime");
        // ...but withdrawable is still 0 (borrower hasn't repaid yet)
        assertEq(midnight.withdrawable(id), 0, "withdrawable = 0 without repayment");

        // Every claim attempt fails — fee claimer is completely blocked
        vm.prank(feeClaimer);
        vm.expectRevert();
        midnight.claimContinuousFee(market, totalAccrued, feeClaimer);

        // Only after the borrower repays at/post-maturity does the fee become claimable
        deal(address(loanToken), borrower, LEND_UNITS);
        vm.prank(borrower);
        midnight.repay(market, LEND_UNITS, borrower, address(0), hex"");

        vm.prank(feeClaimer);
        midnight.claimContinuousFee(market, totalAccrued, feeClaimer);
        assertEq(loanToken.balanceOf(feeClaimer), totalAccrued, "fees redeemed after repayment");
    }
}
