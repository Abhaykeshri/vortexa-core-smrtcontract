// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";
import {VaultM5Module as VaultM5Module_} from "../../src/VaultM5Module.sol";
import {VaultM6Module as VaultM6Module_} from "../../src/VaultM6Module.sol";
import {Vault} from "../../src/Vault.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {Band, Currency, PoolKey, RebalanceParams, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {VaultRealV4Base} from "../integration/utils/VaultRealV4Base.sol";
import {TestNormalLPStrategy} from "../utils/TestNormalLPStrategy.sol";

/**
 * @title M6 rebalance attacks on real Uniswap v4
 * @notice Rebalances run through the real PoolManager, PositionManager, StateView, PriceGuard, ShapeLibrary and the
 *         real V4Router action pipeline (behind a Universal Router double), with a guide 8.3 Normal LP planner.
 */
contract VaultM6RealV4AttacksTest is VaultRealV4Base {
    TestNormalLPStrategy internal planner;
    address internal keeper = makeAddr("keeper");
    uint128 internal constant DEEP_LIQUIDITY = 2e17;
    PoolKey internal key;
    Vault internal vault;

    function setUp() public override {
        super.setUp();
        planner = new TestNormalLPStrategy(shapes);
        factoryKeepers[keeper] = true;
    }

    // ------------------------------------------------------------------------------------------------------------
    // Swap leg
    // ------------------------------------------------------------------------------------------------------------

    function test_native_pool_rebalance_with_a_swap() public {
        _nativeVault();
        _churnAndDrift(true);
        _rebalance(_alignedTick(), 50);
        _assertCleanCustody();
    }

    function test_erc20_pool_rebalance_with_a_swap() public {
        _erc20Vault();
        _churnAndDrift(true);
        _rebalance(_alignedTick(), 50);
        _assertCleanCustody();
    }

    /**
     * @notice Bug: one exact-balance check let anyone block every swap of a token by sending 1 wei of it to the
     *         executor (there is no way to remove it), freezing all rebalances that need that swap direction.
     */
    function test_a_donation_to_the_executor_cannot_block_rebalances() public {
        _erc20Vault();
        _churnAndDrift(true);
        vm.startPrank(attacker);
        usdc.transfer(address(executor), 1);
        weth.transfer(address(executor), 1);
        vm.stopPrank();
        _rebalance(_alignedTick(), 50);
        assertEq(usdc.balanceOf(address(executor)), 1, "the donation stays untouched");
        assertEq(weth.balanceOf(address(executor)), 1, "the donation stays untouched");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Loss bound (guide 8.2, 8.4 tests)
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice Sandwich (guide 8.4): the attacker moves the pool price inside the oracle tolerance, the keeper
     *         rebalances, the attacker reverses. The vault's loss at the oracle price stays within the keeper's
     *         `maxSlippageBps`, and a tighter bound makes the rebalance revert instead.
     */
    function test_sandwiched_rebalance_loss_is_bounded_price_pushed_down() public {
        _sandwich(true);
    }

    function test_sandwiched_rebalance_loss_is_bounded_price_pushed_up() public {
        _sandwich(false);
    }

    function _sandwich(bool down) internal {
        _nativeVault();
        _churnAndDrift(true);
        uint160 ref = guard.referenceSqrtPriceX96(key);
        uint256 before = _valueAtRef(ref);
        uint256 snap = vm.snapshotState();

        // A large push (80 bps of the 100 bps tolerance): against the vault's swap the trade would clear below the
        // floor and is refused; in its favour it succeeds. Either way the loss stays inside the tolerance.
        uint256 bigPush = _pushWithinTolerance(down, 80);
        int24 center = _alignedTick();
        vm.prank(keeper);
        (bool ok,) = address(vault)
            .call(abi.encodeCall(Vault.rebalance, (RebalanceParams({newCenterTick: center, maxSlippageBps: 100}))));
        if (ok) {
            _swap(attacker, key, !down, down ? _usdcFor(bigPush) : bigPush);
            assertGe(_valueAtRef(ref), Math.mulDiv(before, 10_000 - 100, 10_000), "large push: loss above bound");
        }
        vm.revertToState(snap);

        // A smaller push: zero tolerance either refuses or loses nothing; the maximum tolerance must succeed (no
        // denial of service) and the loss stays inside it.
        uint256 pushed = _pushWithinTolerance(down, 30);
        center = _alignedTick();
        uint256 snap2 = vm.snapshotState();
        vm.prank(keeper);
        (bool zeroOk,) = address(vault)
            .call(abi.encodeCall(Vault.rebalance, (RebalanceParams({newCenterTick: center, maxSlippageBps: 0}))));
        if (zeroOk) assertGe(_valueAtRef(ref), before, "zero tolerance accepted a loss");
        vm.revertToState(snap2);

        _rebalance(center, 100);
        _swap(attacker, key, !down, down ? _usdcFor(pushed) : pushed); // reverse
        uint256 afterValue = _valueAtRef(ref);
        assertGe(afterValue, Math.mulDiv(before, 10_000 - 100, 10_000), "loss above the keeper bound");
        emit log_named_uint(
            "sandwiched rebalance loss, bps of vault value", (before - _min(before, afterValue)) * 10_000 / before
        );
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // ------------------------------------------------------------------------------------------------------------
    // Gates (guide 8.4: each reverts with the right error)
    // ------------------------------------------------------------------------------------------------------------

    function test_rebalance_gates_revert_with_the_right_errors() public {
        _nativeVault();
        _churnAndDrift(true);
        int24 center = _alignedTick();

        vm.prank(alice);
        vm.expectRevert(IVault.NotKeeper.selector);
        vault.rebalance(RebalanceParams(center, 50));

        vm.prank(keeper);
        vm.expectRevert(IVault.SlippageTooHigh.selector);
        vault.rebalance(RebalanceParams(center, 101));

        vm.prank(keeper);
        vm.expectRevert(IVault.CenterTooFar.selector);
        vault.rebalance(RebalanceParams(center + 210, 50));

        planner.setTriggered(false);
        vm.prank(keeper);
        vm.expectRevert(IVault.NothingToDo.selector);
        vault.rebalance(RebalanceParams(center, 50));
        planner.setTriggered(true);

        vm.prank(guardianAccount);
        vault.pause();
        vm.prank(keeper);
        vm.expectRevert(Vault.IsPaused.selector);
        vault.rebalance(RebalanceParams(center, 50));
        vm.prank(timelockAccount);
        vault.unpause();

        vm.warp(block.timestamp + 2 hours); // oracle answer goes stale
        vm.prank(keeper);
        vm.expectRevert(Vault.PriceUntrusted.selector);
        vault.rebalance(RebalanceParams(center, 50));
        _syncOracle();

        _pushWithinTolerance(true, 150); // pool beyond the oracle tolerance
        vm.prank(keeper);
        vm.expectRevert(Vault.PriceUntrusted.selector);
        vault.rebalance(RebalanceParams(center, 50));
        _syncOracle();

        center = _alignedTick();
        _rebalance(center, 100);
        vm.prank(keeper);
        vm.expectRevert(IVault.CooldownActive.selector);
        vault.rebalance(RebalanceParams(center, 100));
    }

    function test_rebalance_reverts_when_auto_rebalance_is_off() public {
        key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);
        VaultConfig memory cfg = _config(key, _align(tick), 1, 600, 600);
        cfg.autoRebalance = false;
        vault = _newVaultWith(cfg, address(planner));
        _deposit(vault, alice, 10 ether, 30_000e6);
        int24 center = _alignedTick();
        vm.prank(keeper);
        vm.expectRevert(IVault.AutoRebalanceOff.selector);
        vault.rebalance(RebalanceParams(center, 50));
    }

    function test_center_drift_boundary_is_exactly_200_ticks() public {
        _nativeVault();
        _churnAndDrift(true);
        (, int24 tick,,) = stateView.getSlot0(_poolId(key));
        vm.prank(keeper);
        vm.expectRevert(IVault.CenterTooFar.selector);
        vault.rebalance(RebalanceParams(tick + 201, 100));
        int24 center = _align(tick + 200);
        _rebalance(center, 100);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Protocol fee and accounting
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice The rebalance's burn collects all pending fees; the collector receives exactly `feeBps` of them.
     */
    function test_rebalance_pays_exactly_the_protocol_fee_on_collected_fees() public {
        _nativeVault();
        _churnAndDrift(true);
        factoryFeeBps = 1_500;
        (uint256 f0, uint256 f1) = _pending();
        assertGt(f0 + f1, 0);
        _rebalance(_alignedTick(), 50);
        assertEq(factoryFeeCollector.balance, f0 * 1_500 / 10_000);
        assertEq(usdc.balanceOf(factoryFeeCollector), f1 * 1_500 / 10_000);
    }

    /**
     * @notice Bug: the rebalance reverted on a factory fee above 100% (while every other path clamps it), so a
     *         misconfigured factory froze rebalancing. It now clamps like the rest of the vault.
     */
    function test_a_factory_fee_above_100_percent_is_clamped_in_rebalance() public {
        _nativeVault();
        _churnAndDrift(true);
        factoryFeeBps = 20_000;
        (uint256 f0, uint256 f1) = _pending();
        _rebalance(_alignedTick(), 100);
        assertEq(factoryFeeCollector.balance, f0, "fee capped at the collected fees");
        assertEq(usdc.balanceOf(factoryFeeCollector), f1, "fee capped at the collected fees");
    }

    /**
     * @notice A factory whose fee getter returns no data reads as a zero fee in the rebalance too (same rule as the
     *         M5 paths and the vault's valuation).
     */
    function test_a_factory_returning_no_fee_data_charges_no_rebalance_fee() public {
        _nativeVault();
        _churnAndDrift(true);
        factoryFeeBps = 1_000;
        vm.mockCall(address(this), abi.encodeWithSelector(this.protocolFeeBps.selector), "");
        _rebalance(_alignedTick(), 50);
        assertEq(factoryFeeCollector.balance + usdc.balanceOf(factoryFeeCollector), 0);
    }

    /**
     * @notice The rebalance fee path is strict (like collect and compound): an unset collector reverts the whole
     *         rebalance atomically, leaving the old positions in place.
     */
    function test_rebalance_with_an_unset_collector_reverts_atomically() public {
        _nativeVault();
        _churnAndDrift(true);
        factoryFeeBps = 1_000;
        factoryFeeCollector = address(0);
        Band[] memory before = vault.bands();
        int24 center = _alignedTick();
        vm.prank(keeper);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vault.rebalance(RebalanceParams(center, 50));
        Band[] memory afterBands = vault.bands();
        assertEq(afterBands.length, before.length);
        assertEq(afterBands[0].tokenId, before[0].tokenId);
        assertEq(posm.ownerOf(before[0].tokenId), address(vault));
    }

    /**
     * @notice Bug: `Rebalanced` reported the immutable configured center as the old center, so after the first
     *         rebalance the event (and any indexer) showed the wrong range history.
     */
    function test_rebalanced_event_reports_the_previous_center() public {
        _nativeVault();
        _churnAndDrift(true);
        int24 first = _alignedTick();
        _rebalance(first, 50);
        Band[] memory b = vault.bands();
        int24 heldCenter = _midpoint(b);

        _churnAndDrift(false);
        int24 second = _alignedTick();
        vm.expectEmit(true, false, false, false, address(vault));
        emit IVault.Rebalanced(keeper, heldCenter, second, 0, 0);
        vm.recordLogs();
        _rebalance(second, 50);
        assertEq(_lastOldCenter(), heldCenter, "old center must be the center of the bands just replaced");
    }

    /**
     * @notice After a rebalance the vault's accounting stays exact: the in-kind preview matches the real
     *         withdrawal to the wei, every holder can exit, and deposits keep working.
     */
    function test_after_a_rebalance_previews_exits_and_deposits_stay_exact() public {
        uint256 aliceShares = _nativeVault();
        _churnAndDrift(true);
        _rebalance(_alignedTick(), 50);
        (uint256 bobShares,,) = _deposit(vault, bob, 5 ether, 15_000e6);
        (uint256 p0, uint256 p1) = VaultM5Module_(vault.m5Module()).previewWithdrawPair(vault, aliceShares / 2);
        vm.prank(alice);
        (uint256 o0, uint256 o1) = vault.withdrawPair(aliceShares / 2, 0, 0, alice);
        assertEq(o0, p0);
        assertEq(o1, p1);
        vm.prank(bob);
        vault.withdrawPair(bobShares, 0, 0, bob);
        uint256 rest = vault.balanceOf(alice);
        vm.prank(alice);
        vault.withdrawPair(rest, 0, 0, alice);
        assertEq(vault.totalSupply(), 1_000);
    }

    /**
     * @notice ETH forced into the PositionManager and into the executor neither blocks a native rebalance nor is
     *         counted as swap output.
     */
    function test_forced_eth_cannot_block_or_inflate_a_native_rebalance() public {
        _nativeVault();
        _churnAndDrift(true);
        vm.deal(address(posm), 3 ether);
        vm.deal(address(executor), 2 ether);
        _rebalance(_alignedTick(), 50);
        assertEq(address(posm).balance, 0, "forced PositionManager ETH swept to the vault");
        assertEq(address(executor).balance, 2 ether, "executor ETH is not swap output");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Lock-idle path (guide 8.4) and hostile plans
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice Lock-idle (one-sided strategy that filled): all positions removed, no bands, `filled` set, the loss
     *         brake still applied, withdrawals still work and deposits are refused; a later rebalance re-enters.
     */
    function test_lock_idle_leaves_idle_tokens_no_bands_filled_and_withdrawals_open() public {
        key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);
        VaultConfig memory cfg = _config(key, _align(tick), 1, 600, 600);
        cfg.strategy = Strategy.BuyTheDip;
        cfg.ticksRight = 0;
        cfg.lockOnFill = true;
        vault = _newVaultWith(cfg, address(strategy));
        (uint256 shares,,) = _deposit(vault, alice, 10 ether, 30_000e6);
        strategy.setRebalance(true, bytes32("FILLED"));
        strategy.setPlan(new Band[](0), new uint16[](0), false, false, 0, true);
        vm.warp(block.timestamp + 31 minutes);
        _syncOracle();
        uint160 ref = guard.referenceSqrtPriceX96(key);
        uint256 before = _valueAtRef(ref);

        _rebalance(_alignedTick(), 0);

        assertTrue(vault.filled());
        assertEq(vault.bands().length, 0);
        assertEq(posm.balanceOf(address(vault)), 0, "old NFTs burned");
        assertGe(_valueAtRef(ref), before, "no value lost on the lock-idle path");
        assertEq(vault.maxDeposit(alice), 0);
        vm.prank(bob);
        vm.expectRevert(Vault.DepositNotAllowed.selector);
        vault.depositPair{value: 1 ether}(1 ether, 3_000e6, 0, bob);
        (uint256 fee0, uint256 fee1) = vault.collectFees();
        assertEq(fee0 + fee1, 0);
        vm.prank(alice);
        (uint256 out0, uint256 out1) = vault.withdrawPair(shares / 2, 0, 0, alice);
        assertGt(out0 + out1, 0, "withdrawals stay open on a filled vault");

        // a later rebalance re-enters the pool and reopens deposits
        int24 c = _alignedTick();
        Band[] memory one = new Band[](1);
        uint16[] memory w = new uint16[](1);
        w[0] = 10_000;
        one[0] = Band({tickLower: c - 600, tickUpper: c - 10, tokenId: 0, liquidity: 0});
        strategy.setPlan(one, w, false, false, 0, false);
        vm.warp(block.timestamp + 31 minutes);
        _syncOracle();
        _rebalance(_alignedTick(), 100);
        assertFalse(vault.filled(), "re-entering clears filled");
        assertEq(vault.bands().length, 1);
        _deposit(vault, bob, 1 ether, 3_000e6);
    }

    /**
     * @notice Every structurally unsafe plan is refused before any token moves, and the old positions survive.
     */
    function test_hostile_plans_are_rejected_atomically() public {
        key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);
        int24 c = _align(tick);
        vault = _newVaultWith(_config(key, c, 1, 600, 600), address(strategy));
        _deposit(vault, alice, 10 ether, 30_000e6);
        strategy.setRebalance(true, bytes32("DRIFT"));
        vm.warp(block.timestamp + 31 minutes);
        _syncOracle();
        Band[] memory held = vault.bands();

        _expectPlanRejected(_bands2(c - 100, c, c, c + 100), _w2(5_000, 5_000), false, false, 0, false, 0); // ok shape
        _expectPlanRejected(_bands2(c - 100, c + 10, c, c + 100), _w2(5_000, 5_000), false, false, 0, false, 1); // overlap
        _expectPlanRejected(_bands2(c - 105, c, c, c + 100), _w2(5_000, 5_000), false, false, 0, false, 1); // misaligned
        _expectPlanRejected(_bands2(c - 100, c, c, c + 100), _w2(5_000, 4_999), false, false, 0, false, 1); // weights
        _expectPlanRejected(_bands2(c - 100, c, c, c + 100), _w2(10_000, 0), false, false, 0, false, 1); // empty band
        _expectPlanRejected(_bands2(-887280, c, c, c + 100), _w2(5_000, 5_000), false, false, 0, false, 1); // range
        _expectPlanRejected(new Band[](0), new uint16[](0), false, false, 0, true, 1); // lock-idle on Normal LP
        _expectPlanRejected(_bands2(c - 100, c, c, c + 100), _w2(5_000, 5_000), true, true, 0, false, 1); // swap 0
        // a lopsided vault (mostly ETH): a swap above 60% of its value, and a swap above what it holds
        vm.deal(address(vault), address(vault).balance + 50 ether);
        uint256 held0 = address(vault).balance;
        _expectPlanRejected(_bands2(c - 100, c, c, c + 100), _w2(5_000, 5_000), true, true, held0 * 9 / 10, false, 2);
        _expectPlanRejected(_bands2(c - 100, c, c, c + 100), _w2(5_000, 5_000), true, true, held0 + 1, false, 2);

        Band[] memory still = vault.bands();
        assertEq(still.length, held.length);
        for (uint256 i; i < still.length; ++i) {
            assertEq(still[i].tokenId, held[i].tokenId, "old position must survive a refused plan");
            assertEq(posm.ownerOf(still[i].tokenId), address(vault));
        }
    }

    /**
     * @notice A swap larger than the holding of its input token is refused even when it is below 60% of the vault's
     *         value (vault mostly in the other token).
     */
    function test_a_swap_above_the_input_holding_is_refused_even_under_the_value_cap() public {
        key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);
        int24 c = _align(tick);
        vault = _newVaultWith(_config(key, c, 1, 600, 600), address(strategy));
        _deposit(vault, alice, 10 ether, 30_000e6);
        usdc.mint(address(vault), 500_000e6); // mostly USDC now
        strategy.setRebalance(true, bytes32("DRIFT"));
        vm.warp(block.timestamp + 31 minutes);
        _syncOracle();
        // the vault holds about 10 ETH after the burn and is worth about 550,000 USDC: 50 ETH is under the 60% cap
        // but above the holding
        _expectPlanRejected(_bands2(c - 100, c, c, c + 100), _w2(5_000, 5_000), true, true, 50 ether, false, 2);
    }

    /**
     * @notice Lock-idle is only for one-sided strategies: a Normal LP vault with `lockOnFill` set still refuses it.
     */
    function test_lock_idle_is_refused_for_normal_lp_even_with_lock_on_fill() public {
        key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);
        VaultConfig memory cfg = _config(key, _align(tick), 1, 600, 600);
        cfg.lockOnFill = true;
        vault = _newVaultWith(cfg, address(strategy));
        _deposit(vault, alice, 10 ether, 30_000e6);
        strategy.setRebalance(true, bytes32("DRIFT"));
        vm.warp(block.timestamp + 31 minutes);
        _syncOracle();
        _expectPlanRejected(new Band[](0), new uint16[](0), false, false, 0, true, 1);
    }

    /**
     * @notice A minted band NFT that the vault does not own aborts the whole rebalance.
     */
    function test_a_band_nft_not_owned_by_the_vault_aborts_the_rebalance() public {
        _nativeVault();
        _churnAndDrift(true);
        uint256 next = posm.nextTokenId();
        vm.mockCall(address(posm), abi.encodeWithSignature("ownerOf(uint256)", next), abi.encode(attacker));
        int24 center = _alignedTick();
        vm.prank(keeper);
        vm.expectRevert(Vault.InvalidPositionOwner.selector);
        vault.rebalance(RebalanceParams(center, 100));
    }

    /**
     * @notice The swap itself never clears more than the keeper's tolerance below the oracle (fee aside): with the
     *         price pushed against the vault's swap by more than that tolerance, the rebalance is refused even when
     *         the swap is too small a part of the vault for the overall loss check to notice.
     */
    function test_the_swap_floor_uses_the_keepers_tolerance() public {
        _nativeVault();
        _churnAndDrift(true);
        bool vaultSellsToken0 = _plannedSwapSellsToken0();
        _pushWithinTolerance(vaultSellsToken0, 30);
        int24 center = _alignedTick();
        vm.prank(keeper);
        vm.expectRevert();
        vault.rebalance(RebalanceParams(center, 50));
    }

    function _plannedSwapSellsToken0() internal returns (bool sellsToken0) {
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        _rebalance(_alignedTick(), 100);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("SwapExecuted(address,(address,address,uint24,int24,address),bool,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(executor) && logs[i].topics[0] == topic) {
                (, sellsToken0,,) = abi.decode(logs[i].data, (PoolKey, bool, uint256, uint256));
                found = true;
            }
        }
        require(found, "the planned rebalance must swap");
        vm.revertToState(snap);
    }

    /**
     * @notice More structural refusals: no bands without lock-idle, more than five bands, mismatched weights, a swap
     *         requested by a one-sided strategy, and a Sell the Pump band that reaches the price.
     */
    function test_more_hostile_plans_are_rejected() public {
        key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);
        int24 c = _align(tick);
        vault = _newVaultWith(_config(key, c, 1, 600, 600), address(strategy));
        _deposit(vault, alice, 10 ether, 30_000e6);
        strategy.setRebalance(true, bytes32("DRIFT"));
        vm.warp(block.timestamp + 31 minutes);
        _syncOracle();

        _expectPlanRejected(new Band[](0), new uint16[](0), false, false, 0, false, 1);
        Band[] memory six = new Band[](6);
        uint16[] memory w6 = new uint16[](6);
        for (uint256 i; i < 6; ++i) {
            six[i] = Band({
                tickLower: c + int24(int256(i)) * 10, tickUpper: c + int24(int256(i + 1)) * 10, tokenId: 0, liquidity: 0
            });
            w6[i] = i == 0 ? 5_000 : 1_000;
        }
        _expectPlanRejected(six, w6, false, false, 0, false, 1);
        uint16[] memory w1 = new uint16[](1);
        w1[0] = 10_000;
        _expectPlanRejected(_bands2(c - 100, c, c, c + 100), w1, false, false, 0, false, 1);

        key = _nativeUsdcKey();
        VaultConfig memory cfg = _config(key, c, 1, 600, 600);
        cfg.strategy = Strategy.SellThePump;
        cfg.centerTick = c + 10;
        cfg.ticksLeft = 0;
        strategy.clearPlan();
        vault = _newVaultWith(cfg, address(strategy));
        _deposit(vault, alice, 10 ether, 30_000e6);
        vm.warp(block.timestamp + 31 minutes);
        _syncOracle();
        (, int24 now_,,) = stateView.getSlot0(_poolId(key));
        int24 above = _align(now_) + 10;
        Band[] memory one = new Band[](1);
        one[0] = Band({tickLower: above, tickUpper: above + 600, tokenId: 0, liquidity: 0});
        _expectPlanRejected(one, w1, true, true, 1 ether, false, 1); // one-sided strategies never swap
        one[0] = Band({tickLower: above - 20, tickUpper: above + 600, tokenId: 0, liquidity: 0});
        _expectPlanRejected(one, w1, false, false, 0, false, 1); // band reaches the price
        one[0] = Band({tickLower: above, tickUpper: above + 600, tokenId: 0, liquidity: 0});
        _expectPlanRejected(one, w1, false, false, 0, false, 0);
    }

    /**
     * @notice A malformed collector word reads as unset in the rebalance's fee path too (whole rebalance reverts).
     */
    function test_a_malformed_fee_collector_reverts_the_rebalance() public {
        _nativeVault();
        _churnAndDrift(true);
        factoryFeeBps = 1_000;
        vm.mockCall(address(this), abi.encodeWithSelector(this.feeCollector.selector), abi.encode(type(uint256).max));
        int24 center = _alignedTick();
        vm.prank(keeper);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vault.rebalance(RebalanceParams(center, 50));
    }

    /**
     * @notice The rebalance module refuses direct calls.
     */
    function test_the_m6_module_refuses_direct_calls() public {
        VaultM6Module_ module = VaultM6Module_(executor.vaultModule());
        vm.expectRevert(IVault.InvalidPlan.selector);
        module.rebalance(RebalanceParams(0, 0));
    }

    /**
     * @notice Multi-band rebalances (the shape library's five-band bell and uniform shapes, and a three-band shape):
     *         every old NFT is burned, five new ones are minted and owned, custody stays clean, and the worst case
     *         (five bands burned and re-minted plus a swap) fits comfortably in a block.
     */
    function test_five_band_rebalance_with_a_swap_and_its_gas() public {
        uint256[3] memory shapesToTry = [uint256(0), 4, 2];
        uint256[3] memory expectedBands = [uint256(5), 5, 3];
        for (uint256 k; k < shapesToTry.length; ++k) {
            uint256 snap = vm.snapshotState();
            key = _nativeUsdcKey();
            int24 tick = _initPool(key, 2000e6, 1e18, false);
            _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);
            vault = _newVaultWith(_config(key, _align(tick), uint8(shapesToTry[k]), 1_500, 1_500), address(planner));
            _deposit(vault, alice, 100 ether, 300_000e6);
            Band[] memory old = vault.bands();
            assertEq(old.length, expectedBands[k]);
            _churnAndDrift(true);
            int24 center = _alignedTick();

            uint256 gasBefore = gasleft();
            _rebalance(center, 100);
            uint256 used = gasBefore - gasleft();
            emit log_named_uint("rebalance gas, bands", expectedBands[k]);
            emit log_named_uint("rebalance gas", used);
            assertLt(used, 3_000_000, "worst-case rebalance must stay well inside a block");

            assertEq(vault.bands().length, expectedBands[k]);
            for (uint256 i; i < old.length; ++i) {
                vm.expectRevert();
                posm.ownerOf(old[i].tokenId); // burned
            }
            _assertCleanCustody();
            vm.revertToState(snap);
        }
    }

    function _expectPlanRejected(
        Band[] memory bands_,
        uint16[] memory weights,
        bool needsSwap,
        bool zeroForOne,
        uint256 swapAmountIn,
        bool lockIdle,
        uint8 expect // 0: accepted, 1: InvalidPlan, 2: SwapTooLarge
    ) internal {
        strategy.setPlan(bands_, weights, needsSwap, zeroForOne, swapAmountIn, lockIdle);
        int24 center = _alignedTick();
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        if (expect == 1) vm.expectRevert(IVault.InvalidPlan.selector);
        if (expect == 2) vm.expectRevert(IVault.SwapTooLarge.selector);
        vault.rebalance(RebalanceParams(center, 100));
        vm.revertToState(snap);
    }

    function _bands2(int24 a, int24 b, int24 c, int24 d) internal pure returns (Band[] memory out) {
        out = new Band[](2);
        out[0] = Band({tickLower: a, tickUpper: b, tokenId: 0, liquidity: 0});
        out[1] = Band({tickLower: c, tickUpper: d, tokenId: 0, liquidity: 0});
    }

    function _w2(uint16 a, uint16 b) internal pure returns (uint16[] memory out) {
        out = new uint16[](2);
        out[0] = a;
        out[1] = b;
    }

    /**
     * @notice A one-sided (Buy the Dip, base currency0) plan must sit entirely below the current price: a band that
     *         reaches the price is refused.
     */
    function test_one_sided_plan_must_stay_on_its_side_of_the_price() public {
        key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);
        int24 c = _align(tick);
        VaultConfig memory cfg = _config(key, c, 1, 600, 600);
        cfg.strategy = Strategy.BuyTheDip;
        cfg.ticksRight = 0;
        vault = _newVaultWith(cfg, address(strategy));
        _deposit(vault, alice, 10 ether, 30_000e6);
        strategy.setRebalance(true, bytes32("TRAIL"));
        vm.warp(block.timestamp + 31 minutes);
        _syncOracle();
        Band[] memory one = new Band[](1);
        uint16[] memory w = new uint16[](1);
        w[0] = 10_000;
        one[0] = Band({tickLower: c - 600, tickUpper: c + 10, tokenId: 0, liquidity: 0});
        _expectPlanRejected(one, w, false, false, 0, false, 1);
        one[0] = Band({tickLower: c - 600, tickUpper: c - 10, tokenId: 0, liquidity: 0});
        _expectPlanRejected(one, w, false, false, 0, false, 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _pushWithinTolerance(bool down, uint256 targetBps) internal returns (uint256 pushedIn) {
        bool native = Currency_isNative(key);
        uint256 step = down ? (native ? 0.5 ether : 1_000e6) : (native ? 1_000e6 : 0.5 ether);
        for (uint256 i; i < 400; ++i) {
            (, uint256 dev) = guard.isPriceTrusted(key);
            if (dev >= targetBps) break;
            _swap(attacker, key, down, step);
            pushedIn += step;
        }
    }

    function _usdcFor(uint256 ethIn) internal view returns (uint256) {
        (uint160 sp,,,) = stateView.getSlot0(_poolId(key));
        return Math.mulDiv(Math.mulDiv(ethIn, Math.mulDiv(sp, sp, 1 << 96), 1 << 96), 101, 100);
    }

    /**
     * Vault value at a fixed sqrt price, computed like the rebalance's own check: band principal at that price,
     * idle, and pending fees net of the protocol fee.
     */
    function _valueAtRef(uint160 ref) internal view returns (uint256) {
        uint256 amount0 = Currency_isNative(key) ? address(vault).balance : usdc.balanceOf(address(vault));
        uint256 amount1 = Currency_isNative(key) ? usdc.balanceOf(address(vault)) : weth.balanceOf(address(vault));
        (uint256 f0, uint256 f1) = _pending();
        amount0 += f0 - f0 * factoryFeeBps / 10_000;
        amount1 += f1 - f1 * factoryFeeBps / 10_000;
        Band[] memory b = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            (uint256 x, uint256 y) = LiquidityMath.amountsForLiquidity(
                ref,
                SqrtPriceMath.getSqrtPriceAtTick(b[i].tickLower),
                SqrtPriceMath.getSqrtPriceAtTick(b[i].tickUpper),
                b[i].liquidity
            );
            amount0 += x;
            amount1 += y;
        }
        return Math.mulDiv(amount0, Math.mulDiv(ref, ref, 1 << 96), 1 << 96) + amount1;
    }

    function _pending() internal view returns (uint256 f0, uint256 f1) {
        Band[] memory b = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            (uint128 liq, uint256 last0, uint256 last1) = stateView.getPositionInfo(
                _poolId(key), address(posm), b[i].tickLower, b[i].tickUpper, bytes32(b[i].tokenId)
            );
            (uint256 now0, uint256 now1) = stateView.getFeeGrowthInside(_poolId(key), b[i].tickLower, b[i].tickUpper);
            unchecked {
                f0 += Math.mulDiv(liq, now0 - last0, 1 << 128);
                f1 += Math.mulDiv(liq, now1 - last1, 1 << 128);
            }
        }
    }

    function _midpoint(Band[] memory b) internal pure returns (int24) {
        int256 sum = int256(b[0].tickLower) + int256(b[b.length - 1].tickUpper);
        int256 half = sum / 2;
        if (sum < 0 && half * 2 != sum) half -= 1;
        return int24(half);
    }

    function _lastOldCenter() internal view returns (int24 oldCenter) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = IVault.Rebalanced.selector;
        for (uint256 i = logs.length; i > 0; --i) {
            if (logs[i - 1].topics[0] == topic && logs[i - 1].emitter == address(vault)) {
                (oldCenter,,,) = abi.decode(logs[i - 1].data, (int24, int24, uint256, uint256));
                return oldCenter;
            }
        }
        revert("no Rebalanced event");
    }

    function _nativeVault() internal returns (uint256 shares) {
        key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);
        vault = _newVaultWith(_config(key, _align(tick), 1, 600, 600), address(planner));
        (shares,,) = _deposit(vault, alice, 100 ether, 300_000e6);
    }

    function _erc20Vault() internal returns (uint256 shares) {
        key = _usdcWethKey();
        int24 tick = _initPool(key, 1e18, 2000e6, true);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);
        vault = _newVaultWith(_config(key, _align(tick), 1, 600, 600), address(planner));
        (shares,,) = _deposit(vault, alice, 200_000e6, 100 ether);
    }

    function _config(PoolKey memory k, int24 center, uint8 shape, int24 left, int24 right)
        internal
        pure
        returns (VaultConfig memory cfg)
    {
        cfg.poolKey = k;
        cfg.strategy = Strategy.NormalLP;
        cfg.shapeId = shape;
        cfg.centerTick = center;
        cfg.ticksLeft = left;
        cfg.ticksRight = right;
        cfg.autoRebalance = true;
        cfg.baseIsCurrency0 = true;
    }

    /**
     * Organic two-way volume (fees), then a net move of the pool price, oracle following the market.
     */
    function _churnAndDrift(bool down) internal {
        bool native = Currency_isNative(key);
        for (uint256 i; i < 3; ++i) {
            _swap(attacker, key, true, native ? 20 ether : 40_000e6);
            _swap(attacker, key, false, native ? 40_000e6 : 20 ether);
        }
        _swap(attacker, key, down, down ? (native ? 30 ether : 60_000e6) : (native ? 60_000e6 : 30 ether));
        _syncOracle();
        vm.warp(block.timestamp + 31 minutes);
        _syncOracle();
    }

    function _syncOracle() internal {
        if (Currency_isNative(key)) _syncOracleToNativePool(key);
        else _syncOracleToUsdcWethPool(key);
    }

    function _rebalance(int24 center, uint16 slippage) internal {
        vm.prank(keeper);
        vault.rebalance(RebalanceParams({newCenterTick: center, maxSlippageBps: slippage}));
    }

    function _alignedTick() internal view returns (int24) {
        (, int24 tick,,) = stateView.getSlot0(_poolId(key));
        return _align(tick);
    }

    function _align(int24 tick) internal view returns (int24) {
        int24 spacing = key.tickSpacing == 0 ? int24(10) : key.tickSpacing;
        int24 c = tick / spacing * spacing;
        if (tick < 0 && c != tick) c -= spacing;
        return c;
    }

    function _assertCleanCustody() internal view {
        Band[] memory b = vault.bands();
        assertGt(b.length, 0, "bands re-entered");
        for (uint256 i; i < b.length; ++i) {
            assertEq(posm.ownerOf(b[i].tokenId), address(vault), "band NFT owned");
            (uint128 real,,) = stateView.getPositionInfo(
                _poolId(key), address(posm), b[i].tickLower, b[i].tickUpper, bytes32(b[i].tokenId)
            );
            assertEq(real, b[i].liquidity, "stored liquidity is real");
        }
        assertEq(posm.balanceOf(address(vault)), b.length, "no stray NFTs");
        _assertNothingLeftIn(address(posm));
        _assertNothingLeftIn(address(executor));
        _assertNothingLeftIn(address(router));
        assertEq(_permit2Allowance(address(vault), address(posm)), 0, "standing vault allowance");
        assertEq(_permit2Allowance(address(executor), address(router)), 0, "standing executor allowance");
        assertEq(usdc.allowance(address(executor), address(permit2)), 0, "executor USDC approval");
        assertEq(usdc.allowance(address(vault), address(executor)), 0, "vault USDC approval to the executor");
        assertEq(weth.allowance(address(vault), address(executor)), 0, "vault WETH approval to the executor");
        assertEq(weth.allowance(address(executor), address(permit2)), 0, "executor WETH approval");
    }

    function _assertNothingLeftIn(address who) internal view {
        assertEq(usdc.balanceOf(who), 0, "USDC left behind");
        assertEq(weth.balanceOf(who), 0, "WETH left behind");
        assertEq(who.balance, 0, "ETH left behind");
    }

    function _permit2Allowance(address owner_, address spender) internal view returns (uint256 total) {
        (uint160 a,,) = permit2.allowance(owner_, USDC_ADDR, spender);
        (uint160 b,,) = permit2.allowance(owner_, WETH_ADDR, spender);
        total = uint256(a) + b;
    }

    function Currency_isNative(PoolKey memory k) internal pure returns (bool) {
        return Currency.unwrap(k.currency0) == address(0);
    }
}
