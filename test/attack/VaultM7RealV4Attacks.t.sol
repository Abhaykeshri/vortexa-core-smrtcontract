// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";
import {Vault} from "../../src/Vault.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {NormalLPStrategy} from "../../src/strategies/NormalLPStrategy.sol";
import {BuyTheDipStrategy} from "../../src/strategies/BuyTheDipStrategy.sol";
import {SellThePumpStrategy} from "../../src/strategies/SellThePumpStrategy.sol";
import {Band, Currency, PoolKey, RebalanceParams, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {VaultRealV4Base} from "../integration/utils/VaultRealV4Base.sol";

interface TestTokenLike {
    function balanceOf(address account) external view returns (uint256);
}

interface TestTokenTransfer {
    function transfer(address to, uint256 amount) external returns (bool);
}

/**
 * @title M7 strategy attacks on real Uniswap v4
 * @notice The production Normal LP, Buy the Dip and Sell the Pump strategies driving real vaults on the real
 *         PoolManager, PositionManager, StateView, PriceGuard, ShapeLibrary, SwapExecutor and V4Router pipeline.
 */
contract VaultM7RealV4AttacksTest is VaultRealV4Base {
    uint128 internal constant DEEP = 2e17;

    NormalLPStrategy internal normal;
    BuyTheDipStrategy internal dip;
    SellThePumpStrategy internal pump;
    address internal keeper = makeAddr("keeper");
    PoolKey internal key;
    Vault internal vault;

    function setUp() public override {
        super.setUp();
        normal = new NormalLPStrategy(shapes);
        dip = new BuyTheDipStrategy(shapes);
        pump = new SellThePumpStrategy(shapes);
        factoryKeepers[keeper] = true;
    }

    // ------------------------------------------------------------------------------------------------------------
    // First-deposit swap accounting
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice Bug: a Normal LP vault's first pair deposit may swap part of the depositor's tokens. Shares were minted
     *         for `value(supplied) - value(refunds)` at the pre-swap price, i.e. including the value the swap itself
     *         lost (pool fee, price impact, slippage). When the vault already had holders (ERC-4626 deposits held
     *         idle before any band existed) that loss was charged to them. The depositor must bear their own swap.
     */
    function test_first_band_deposit_swap_cost_is_not_charged_to_existing_holders() public {
        _normalVault(_nativeUsdcKey(), 1);
        vm.prank(bob);
        uint256 bobShares = vault.deposit(50_000e6, bob); // idle, no bands yet
        assertEq(vault.bands().length, 0);
        uint160 ref = guard.referenceSqrtPriceX96(key); // fixed: the oracle does not follow alice's own swap
        uint256 bobValueBefore = _shareValueAt(bobShares, ref);

        // alice supplies USDC only: the plan swaps about half of it to ETH
        (uint256 aliceShares, uint256 used0, uint256 used1) = _deposit(vault, alice, 0, 100_000e6);
        assertGt(vault.bands().length, 0);

        assertGe(_shareValueAt(bobShares, ref) + 2, bobValueBefore, "an existing holder paid for the depositor's swap");
        assertLe(
            _shareValueAt(aliceShares, ref),
            _valueAt(used0, used1, ref) + 2,
            "the depositor received shares worth more than they paid"
        );
    }

    // ------------------------------------------------------------------------------------------------------------
    // One-sided strategies: both strategies x both orientations x native and ERC-20 pools (guide 9.1, 9.4, 9.5)
    // ------------------------------------------------------------------------------------------------------------

    function test_buy_the_dip_native_base_currency0_lifecycle() public {
        _oneSidedLifecycle(true, true);
    }

    function test_sell_the_pump_native_base_currency0_lifecycle() public {
        _oneSidedLifecycle(false, true);
    }

    function test_buy_the_dip_erc20_base_currency1_lifecycle() public {
        _oneSidedLifecycle(true, false);
    }

    function test_sell_the_pump_erc20_base_currency1_lifecycle() public {
        _oneSidedLifecycle(false, false);
    }

    /**
     * Single-sided deposit with the right token only, deposit window closing as the price enters the range, full
     * conversion triggering FILLED, the lock-idle rebalance, and withdrawals still paying out the converted tokens.
     */
    function _oneSidedLifecycle(bool buyTheDip, bool native) internal {
        bool below = _oneSidedVault(buyTheDip, native, true);
        uint256 shares = _depositOneSided(alice, below, 1);
        Band[] memory b = vault.bands();
        _assertSingleSided(b, below);

        // the wrong token is refused: a range below the price takes only currency1, above only currency0
        {
            uint256 wrong0 = below ? (_isNative() ? 1 ether : 1_000e6) : 0;
            uint256 wrong1 = below ? 0 : (_isNative() ? 1_000e6 : 1 ether);
            vm.prank(bob);
            vm.expectRevert(Vault.InvalidDepositMode.selector);
            vault.depositPair{value: _isNative() ? wrong0 : 0}(wrong0, wrong1, 0, bob);
            // an empty deposit gets the same error as in a two-sided vault
            vm.prank(bob);
            vm.expectRevert(Vault.InvalidDepositMode.selector);
            vault.depositPair(0, 0, 0, bob);
        }

        // move the price into the range: the deposit window closes
        int24 lo = b[0].tickLower;
        int24 hi = b[b.length - 1].tickUpper;
        _moveTickTo(below ? hi - 1 : lo, below);
        assertEq(vault.maxDeposit(bob), 0, "deposit window must close inside the range");
        _expectDepositRefused(below);

        // move through the whole range: fully converted, FILLED, lock idle
        _moveTickTo(below ? lo - 1 : hi, below);
        (bool needed, bytes32 reason) = vault.checkRebalance();
        assertTrue(needed);
        assertEq(reason, bytes32("FILLED"));
        uint160 ref = guard.referenceSqrtPriceX96(key);
        uint256 before = _vaultValueAt(ref);
        _rebalanceKeeper(100);
        assertTrue(vault.filled());
        assertEq(vault.bands().length, 0);
        assertGe(_vaultValueAt(ref) + 2, before, "lock idle lost value");
        (needed,) = vault.checkRebalance();
        assertFalse(needed, "a filled vault never triggers again");

        // a filled vault takes no new money through any entry point, not even an empty ERC-4626 deposit
        assertEq(vault.maxDeposit(bob), 0);
        vm.prank(bob);
        vm.expectRevert(Vault.DepositNotAllowed.selector);
        vault.deposit(0, bob);

        // withdrawals keep working and pay out the converted base/quote token
        vm.prank(alice);
        (uint256 out0, uint256 out1) = vault.withdrawPair(shares, 0, 0, alice);
        assertGt(below ? out0 : out1, 0, "converted token paid out");
    }

    /**
     * TRAIL: the price runs away from the range by more than `trailTicks`; the rebalance re-anchors the range on the
     * live tick (ignoring the keeper's center), on the correct side, with no swap and no value loss.
     */
    function test_one_sided_trail_reanchors_on_the_live_tick_without_a_swap() public {
        bool[2] memory kinds = [true, false];
        bool[2] memory pools = [true, false];
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 2; ++j) {
                uint256 snap = vm.snapshotState();
                bool below = _oneSidedVault(kinds[i], pools[j], false);
                _depositOneSided(alice, below, 1);
                Band[] memory b = vault.bands();
                int24 away = below ? b[b.length - 1].tickUpper + 350 : b[0].tickLower - 351;
                _moveTickTo(away, !below);
                (bool needed, bytes32 reason) = vault.checkRebalance();
                assertTrue(needed);
                assertEq(reason, bytes32("TRAIL"));
                uint160 ref = guard.referenceSqrtPriceX96(key);
                uint256 before = _vaultValueAt(ref);
                vm.recordLogs();
                _rebalanceKeeper(1); // 1 bp: Uniswap rounds every mint up by a wei or two per band
                assertFalse(_swapped(), "a one-sided rebalance must never swap");
                Band[] memory nb = vault.bands();
                _assertSingleSided(nb, below);
                (, int24 tick,,) = stateView.getSlot0(_poolId(key));
                if (below) {
                    assertGe(int256(tick) - int256(nb[nb.length - 1].tickUpper), 0);
                } else {
                    assertGt(int256(nb[0].tickLower), int256(tick));
                }
                assertGe(_vaultValueAt(ref), Math.mulDiv(before, 9_999, 10_000), "trail rebalance lost value");
                vm.revertToState(snap);
            }
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Normal LP with the production strategy
    // ------------------------------------------------------------------------------------------------------------

    /**
     * OUT_OF_RANGE after a large move, both directions, both pools: the production plan re-centres with a bounded
     * swap, bands are re-entered, and the loss at the oracle price stays inside the tolerance.
     */
    function test_production_normal_lp_rebalances_after_out_of_range_moves() public {
        bool[2] memory pools = [true, false];
        bool[2] memory dirs = [true, false];
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 2; ++j) {
                uint256 snap = vm.snapshotState();
                _normalVault(pools[i] ? _nativeUsdcKey() : _usdcWethKey(), 4);
                // sized against the pool: an out-of-range re-centre swaps about half the vault in one trade
                _deposit(vault, alice, pools[i] ? 5 ether : 10_000e6, pools[i] ? 15_000e6 : 5 ether);
                Band[] memory b = vault.bands();
                _moveTickTo(dirs[j] ? b[0].tickLower - 50 : b[b.length - 1].tickUpper + 50, dirs[j]);
                (bool needed, bytes32 reason) = vault.checkRebalance();
                assertTrue(needed);
                assertEq(reason, bytes32("OUT_OF_RANGE"));
                uint160 ref = guard.referenceSqrtPriceX96(key);
                uint256 before = _vaultValueAt(ref);
                _rebalanceKeeper(100);
                Band[] memory nb = vault.bands();
                (, int24 tick,,) = stateView.getSlot0(_poolId(key));
                assertTrue(tick >= nb[0].tickLower && tick < nb[nb.length - 1].tickUpper, "re-centred in range");
                assertGe(_vaultValueAt(ref), Math.mulDiv(before, 9_900, 10_000), "loss above tolerance");
                vm.revertToState(snap);
            }
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Recheck (2026-10-23): adversarial variants not covered before
    // ------------------------------------------------------------------------------------------------------------

    /**
     * A sandwich around the first-deposit swap: the attacker buys ETH ahead of alice's USDC-only first deposit (whose
     * plan buys ETH), staying inside the oracle tolerance, then sells it back. Deposits are priced at the trusted spot
     * price (guide 6.4), so alice's new LP is valued at the pushed price while bob holds idle USDC; when the price
     * returns, bob absorbs his share of that revaluation. This is the documented in-tolerance deposit-sandwich bound
     * (`docs/known-issues.md`: at most `deposit * m / (1 - m)`, m = 1%): measured about 0.06% of the deposit. Alice
     * is never credited more than she added at the price her deposit was valued at.
     */
    function test_sandwiched_first_deposit_swap_stays_inside_the_documented_bound() public {
        _normalVault(_nativeUsdcKey(), 1);
        vm.prank(bob);
        uint256 bobShares = vault.deposit(50_000e6, bob);
        uint160 ref = guard.referenceSqrtPriceX96(key);
        uint256 bobBefore = _shareValueAt(bobShares, ref);

        // front-run: push the price up about 40 bps, inside the 1% tolerance
        (, int24 start,,) = stateView.getSlot0(_poolId(key));
        uint256 ethBefore = attacker.balance;
        for (uint256 i; i < 200; ++i) {
            (, int24 t,,) = stateView.getSlot0(_poolId(key));
            if (t >= start + 40) break;
            _swap(attacker, key, false, 2_000e6);
        }
        (bool trusted,) = guard.isPriceTrusted(key);
        assertTrue(trusted, "the push stays inside the oracle tolerance");
        uint256 ethBought = attacker.balance - ethBefore;

        vm.prank(alice);
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeCall(Vault.depositPair, (0, 100_000e6, 0, alice)));

        // back-run: sell the ETH back
        _swap(attacker, key, true, ethBought);

        uint256 bobAfter = _shareValueAt(bobShares, ref);
        if (!ok) {
            assertGe(bobAfter + 2, bobBefore, "a refused deposit moved value");
            return;
        }
        (,, uint256 used1) = abi.decode(ret, (uint256, uint256, uint256));
        uint256 bobLoss = bobBefore > bobAfter ? bobBefore - bobAfter : 0;
        // m / (1 - m) of the deposit for m = 1%, rounded up to 102 bps
        assertLe(bobLoss, Math.mulDiv(used1, 102, 10_000), "above the documented in-tolerance sandwich bound");
        assertLe(bobLoss, Math.mulDiv(used1, 10, 10_000), "measured loss changed: re-check the bound");
    }

    /**
     * ERC-4626 inflation on an empty one-sided vault: the attacker makes the smallest first deposit, donates token1
     * to the vault, lets the victim deposit, then redeems. Dead shares make the attack lose money for every donation
     * size; the victim loses at most the value of one share to rounding (the documented M4 behaviour), and a deposit
     * worth less than one share is refused.
     */
    function testFuzz_erc4626_first_deposit_inflation_on_a_one_sided_vault_never_profits(
        uint256 donation,
        uint256 victimAssets
    ) public {
        donation = bound(donation, 1e6, 1_000_000e6);
        victimAssets = bound(victimAssets, 1e6, 1_000_000e6);
        bool below = _oneSidedVault(true, true, false);
        assertTrue(below, "Buy the Dip on ETH/USDC takes USDC through ERC-4626");
        address usdcToken = Currency.unwrap(key.currency1);

        uint256 spent = 10_000 + donation;
        vm.startPrank(attacker);
        uint256 attackerShares = vault.deposit(10_000, attacker);
        TestTokenTransfer(usdcToken).transfer(address(vault), donation);
        vm.stopPrank();

        uint256 sharePrice = Math.mulDiv(vault.totalAssets(), 1, vault.totalSupply()) + 1;
        uint256 victimShares;
        vm.prank(alice);
        try vault.deposit(victimAssets, alice) returns (uint256 minted) {
            victimShares = minted;
        } catch (bytes memory reason) {
            // a deposit worth less than one share is refused rather than minting nothing
            assertEq(bytes4(reason), Vault.ZeroValue.selector);
            assertLt(victimAssets, sharePrice);
        }

        vm.prank(attacker);
        uint256 out = vault.redeem(attackerShares, attacker, attacker);
        assertLe(out, spent, "the inflation attack made a profit");
        if (victimShares != 0) {
            vm.prank(alice);
            uint256 victimOut = vault.redeem(victimShares, alice, alice);
            assertGe(victimOut + sharePrice, victimAssets, "the victim lost more than one share to rounding");
        }
    }

    /**
     * Liveness: after a TRAIL re-anchor every holder leaves; the dead shares keep each band's liquidity above zero,
     * so the next depositor can still enter, and exits pay back their deposit.
     */
    function test_one_sided_vault_reopens_after_everyone_leaves_following_a_trail() public {
        bool below = _oneSidedVault(true, true, false);
        uint256 aliceShares = _depositOneSided(alice, below, 1);
        uint256 bobShares = _depositOneSided(bob, below, 1);
        Band[] memory b = vault.bands();
        _moveTickTo(b[b.length - 1].tickUpper + 350, false);
        _rebalanceKeeper(1);

        vm.prank(alice);
        vault.withdrawPair(aliceShares, 0, 0, alice);
        vm.prank(bob);
        vault.withdrawPair(bobShares, 0, 0, bob);
        b = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            assertGt(b[i].liquidity, 0, "dead shares keep every band alive");
        }

        uint256 usdcBefore = _bal(key.currency1, alice);
        uint256 shares = _depositOneSided(alice, below, 1);
        vm.prank(alice);
        vault.withdrawPair(shares, 0, 0, alice);
        assertGe(_bal(key.currency1, alice) + 10, usdcBefore, "the re-entry lost more than settlement dust");
    }

    /**
     * Bug (recheck): later deposits are sized from the token amounts of the bands' stored liquidity. When that
     * liquidity is small (a dust first deposit, or only the dead shares left after everyone exits) those amounts are
     * a few hundred raw USDC units per band and round down by up to one unit each. The overstated scale made a normal
     * deposit pull more than its budget (`InsufficientAllowance`). A 0.02 USDC first deposit blocked every later pair
     * deposit and compound of the vault until a rebalance.
     */
    function test_a_dust_first_deposit_cannot_block_later_deposits() public {
        bool[2] memory pools = [true, false];
        for (uint256 j; j < 2; ++j) {
            uint256 snap = vm.snapshotState();
            bool below = _oneSidedVault(true, pools[j], false);
            uint256 dust0 = below ? 0 : (pools[j] ? 1e13 : 20_000);
            uint256 dust1 = below ? (pools[j] ? 20_000 : 1e13) : 0;
            _deposit(vault, attacker, dust0, dust1); // the griefing first deposit

            (uint256 shares,,) = _deposit(
                vault,
                alice,
                below ? 0 : (pools[j] ? 20 ether : 40_000e6),
                dust1 == 0 ? 0 : (pools[j] ? 40_000e6 : 20 ether)
            );
            assertGt(shares, 0);
            vm.revertToState(snap);
        }
    }

    function test_a_dust_first_deposit_cannot_block_a_normal_lp_vault() public {
        _normalVault(_nativeUsdcKey(), 4);
        _deposit(vault, attacker, 1e13, 20_000); // about 0.04 USDC of value
        (uint256 shares,,) = _deposit(vault, alice, 5 ether, 10_000e6);
        assertGt(shares, 0);
    }

    function test_compound_of_large_idle_funds_into_dust_bands() public {
        bool below = _oneSidedVault(true, true, false);
        assertTrue(below);
        _deposit(vault, attacker, 0, 20_000);
        vm.prank(alice);
        vault.deposit(40_000e6, alice); // ERC-4626: held idle
        vm.prank(keeper);
        (, uint256 used1) = vault.compound();
        assertGt(used1, 39_000e6, "compound deployed the idle USDC");
    }

    /**
     * Known behaviour: Uniswap rounds every mint up by a wei or two per band, so even a swap-free re-anchor ends a few
     * wei below its starting value. The loss brake has no dust allowance, so a keeper must pass at least 1 bp.
     */
    function test_known_behaviour_a_swap_free_reanchor_needs_at_least_one_bp() public {
        bool below = _oneSidedVault(true, true, false);
        _depositOneSided(alice, below, 1);
        Band[] memory b = vault.bands();
        _moveTickTo(b[b.length - 1].tickUpper + 350, false);
        (, int24 tick,,) = stateView.getSlot0(_poolId(key));
        vm.prank(keeper);
        vm.expectRevert(IVault.LossTooLarge.selector);
        vault.rebalance(RebalanceParams({newCenterTick: _floor(tick, key.tickSpacing), maxSlippageBps: 0}));
        _rebalanceKeeper(1);
        assertGt(vault.bands()[0].tokenId, b[b.length - 1].tokenId, "re-anchored at 1 bp");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _oneSidedVault(bool buyTheDip, bool native, bool lockOnFill) internal returns (bool below) {
        key = native ? _nativeUsdcKey() : _usdcWethKey();
        int24 tick = native ? _initPool(key, 2000e6, 1e18, false) : _initPool(key, 1e18, 2000e6, true);
        _seedExternalLiquidity(key, tick, DEEP);
        VaultConfig memory cfg;
        cfg.poolKey = key;
        cfg.strategy = buyTheDip ? Strategy.BuyTheDip : Strategy.SellThePump;
        cfg.baseIsCurrency0 = native; // ETH is currency0 on ETH/USDC, WETH is currency1 on USDC/WETH
        below = buyTheDip == cfg.baseIsCurrency0;
        cfg.shapeId = 4;
        cfg.centerTick = _floor(tick, key.tickSpacing);
        cfg.ticksLeft = below ? int24(1_000) : int24(0);
        cfg.ticksRight = below ? int24(0) : int24(1_000);
        cfg.trailTicks = 300;
        cfg.lockOnFill = lockOnFill;
        cfg.autoRebalance = true;
        vault = _newVaultWith(cfg, buyTheDip ? address(dip) : address(pump));
    }

    /**
     * Deposits the single token the range takes: currency1 for a range below the price, currency0 above.
     */
    function _depositOneSided(address who, bool below, uint256 scale) internal returns (uint256 shares) {
        bool native = _isNative();
        uint256 a0 = below ? 0 : (native ? 20 ether : 40_000e6) * scale;
        uint256 a1 = below ? (native ? 40_000e6 : 20 ether) * scale : 0;
        (shares,,) = _deposit(vault, who, a0, a1);
    }

    function _expectDepositRefused(bool below) internal {
        bool native = _isNative();
        uint256 a0 = below ? 0 : (native ? 1 ether : 2_000e6);
        uint256 a1 = below ? (native ? 2_000e6 : 1 ether) : 0;
        vm.prank(bob);
        vm.expectRevert(Vault.DepositNotAllowed.selector);
        vault.depositPair{value: native ? a0 : 0}(a0, a1, 0, bob);
    }

    function _assertSingleSided(Band[] memory b, bool below) internal view {
        (, int24 tick,,) = stateView.getSlot0(_poolId(key));
        assertGt(b.length, 0);
        for (uint256 i; i < b.length; ++i) {
            if (below) {
                assertLe(int256(b[i].tickUpper), int256(tick), "range must sit at or below the price");
            } else {
                assertGt(int256(b[i].tickLower), int256(tick), "range must sit above the price");
            }
        }
    }

    /**
     * Swaps until the pool tick reaches `target` (down: tick <= target, up: tick >= target); the oracle follows.
     */
    function _moveTickTo(int24 target, bool down) internal {
        bool native = _isNative();
        for (uint256 i; i < 400; ++i) {
            (, int24 t,,) = stateView.getSlot0(_poolId(key));
            if (down ? t <= target : t >= target) break;
            if (down) _swap(attacker, key, true, native ? 10 ether : 20_000e6);
            else _swap(attacker, key, false, native ? 20_000e6 : 10 ether);
        }
        _syncOracle();
        vm.warp(block.timestamp + 31 minutes);
        _syncOracle();
    }

    function _syncOracle() internal {
        if (_isNative()) _syncOracleToNativePool(key);
        else _syncOracleToUsdcWethPool(key);
    }

    function _rebalanceKeeper(uint16 slippage) internal {
        (, int24 tick,,) = stateView.getSlot0(_poolId(key));
        vm.prank(keeper);
        vault.rebalance(RebalanceParams({newCenterTick: _floor(tick, key.tickSpacing), maxSlippageBps: slippage}));
    }

    function _swapped() internal view returns (bool found) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("SwapExecuted(address,(address,address,uint24,int24,address),bool,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(executor) && logs[i].topics[0] == topic) found = true;
        }
    }

    function _isNative() internal view returns (bool) {
        return Currency.unwrap(key.currency0) == address(0);
    }

    function _normalVault(PoolKey memory k, uint8 shape) internal returns (int24 tick) {
        key = k;
        tick = Currency.unwrap(k.currency0) == address(0)
            ? _initPool(k, 2000e6, 1e18, false)
            : _initPool(k, 1e18, 2000e6, true);
        _seedExternalLiquidity(k, tick, DEEP);
        VaultConfig memory cfg;
        cfg.poolKey = k;
        cfg.strategy = Strategy.NormalLP;
        cfg.shapeId = shape;
        cfg.centerTick = _floor(tick, k.tickSpacing);
        cfg.ticksLeft = 600;
        cfg.ticksRight = 600;
        cfg.autoRebalance = true;
        cfg.baseIsCurrency0 = Currency.unwrap(k.currency0) == address(0);
        vault = _newVaultWith(cfg, address(normal));
    }

    function _shareValueAt(uint256 shares, uint160 ref) internal view returns (uint256) {
        return Math.mulDiv(shares, _vaultValueAt(ref), vault.totalSupply());
    }

    /**
     * Vault value at a fixed sqrt price: band principal at that price, idle balances, and pending fees net of the
     * protocol fee (the rebalance's own valuation).
     */
    function _vaultValueAt(uint160 ref) internal view returns (uint256) {
        uint256 amount0 = _bal(key.currency0, address(vault));
        uint256 amount1 = _bal(key.currency1, address(vault));
        Band[] memory b = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            (uint128 liq, uint256 last0, uint256 last1) = stateView.getPositionInfo(
                _poolId(key), address(posm), b[i].tickLower, b[i].tickUpper, bytes32(b[i].tokenId)
            );
            (uint256 now0, uint256 now1) = stateView.getFeeGrowthInside(_poolId(key), b[i].tickLower, b[i].tickUpper);
            uint256 f0;
            uint256 f1;
            unchecked {
                f0 = Math.mulDiv(liq, now0 - last0, 1 << 128);
                f1 = Math.mulDiv(liq, now1 - last1, 1 << 128);
            }
            amount0 += f0 - (f0 * _bps()) / 10_000;
            amount1 += f1 - (f1 * _bps()) / 10_000;
            (uint256 x, uint256 y) = LiquidityMath.amountsForLiquidity(
                ref,
                SqrtPriceMath.getSqrtPriceAtTick(b[i].tickLower),
                SqrtPriceMath.getSqrtPriceAtTick(b[i].tickUpper),
                b[i].liquidity
            );
            amount0 += x;
            amount1 += y;
        }
        return _valueAt(amount0, amount1, ref);
    }

    function _bps() internal view returns (uint256) {
        return factoryFeeBps < 10_000 ? factoryFeeBps : 10_000;
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return Currency.unwrap(c) == address(0) ? who.balance : TestTokenLike(Currency.unwrap(c)).balanceOf(who);
    }

    function _valueAt(uint256 a0, uint256 a1, uint160 sp) internal pure returns (uint256) {
        return Math.mulDiv(a0, Math.mulDiv(sp, sp, 1 << 96), 1 << 96) + a1;
    }

    function _floor(int24 tick, int24 spacing) internal pure returns (int24 c) {
        c = (tick / spacing) * spacing;
        if (tick < 0 && c != tick) c -= spacing;
    }
}
