// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vault} from "../../src/Vault.sol";
import {VaultM5Module} from "../../src/VaultM5Module.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {Band, PoolKey} from "../../src/libraries/Types.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {VaultRealV4Base} from "./utils/VaultRealV4Base.sol";

/**
 * @title M5 lifecycle and controls on real Uniswap v4
 * @notice ERC-20 pool lifecycle (deposit, fees, collect, compound, withdraw) with exact protocol-fee accounting,
 *         plus the M5 edge cases from guide 7.2 and the module's access rules.
 */
contract VaultM5LifecycleRealV4Test is VaultRealV4Base {
    PoolKey internal key;
    Vault internal vault;
    address internal keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();
        key = _usdcWethKey();
        int24 tick = _initPool(key, 1e18, 2000e6, true);
        _seedExternalLiquidity(key, tick, 1e15);
        vault = _newVault(key, 0, tick, 4000, 4000);
        factoryKeepers[keeper] = true;
        factoryFeeBps = 1_500;
    }

    /**
     * @notice Full ERC-20 lifecycle: every fee the vault collects (deposit, collect, compound, withdraw) pays the
     *         collector exactly `floor(F * 15%)`, the PositionManager keeps nothing, no Permit2 allowance stands,
     *         and the holders leave with their pro-rata value.
     */
    function test_erc20_lifecycle_pays_exact_protocol_fees_and_leaves_nothing_behind() public {
        (uint256 aliceShares,,) = _deposit(vault, alice, 200_000e6, 100 ether);
        uint256 expected0;
        uint256 expected1;

        _churn(6);
        (uint256 f0, uint256 f1) = _pending();
        (uint256 bobShares,,) = _deposit(vault, bob, 20_000e6, 10 ether);
        expected0 += f0 * 1_500 / 10_000;
        expected1 += f1 * 1_500 / 10_000;
        _assertCollector(expected0, expected1, "deposit");

        _churn(6);
        (f0, f1) = _pending();
        vm.prank(attacker);
        vault.collectFees();
        expected0 += f0 * 1_500 / 10_000;
        expected1 += f1 * 1_500 / 10_000;
        _assertCollector(expected0, expected1, "collect");

        _churn(6);
        _syncOracleToUsdcWethPool(key);
        (f0, f1) = _pending();
        vm.prank(keeper);
        vault.compound();
        expected0 += f0 * 1_500 / 10_000;
        expected1 += f1 * 1_500 / 10_000;
        _assertCollector(expected0, expected1, "compound");

        _churn(6);
        _syncOracleToUsdcWethPool(key);
        (f0, f1) = _pending();
        (uint160 sp,,,) = stateView.getSlot0(_poolId(key));
        uint256 aliceExpected = Math.mulDiv(aliceShares, vault.totalAssets(), vault.totalSupply());
        vm.prank(alice);
        (uint256 a0, uint256 a1) = vault.withdrawPair(aliceShares, 0, 0, alice);
        expected0 += f0 * 1_500 / 10_000;
        expected1 += f1 * 1_500 / 10_000;
        _assertCollector(expected0, expected1, "withdraw");
        assertApproxEqRel(_valueAt(a0, a1, sp), aliceExpected, 1e9, "alice leaves with her share");

        uint256 bobExpected = Math.mulDiv(bobShares, vault.totalAssets(), vault.totalSupply());
        vm.prank(bob);
        (uint256 b0, uint256 b1) = vault.withdrawPair(bobShares, 0, 0, bob);
        assertApproxEqRel(_valueAt(b0, b1, sp), bobExpected, 1e9, "bob leaves with his share");

        assertEq(usdc.balanceOf(address(posm)), 0, "PositionManager kept USDC");
        assertEq(weth.balanceOf(address(posm)), 0, "PositionManager kept WETH");
        (uint160 allowance0,,) = permit2.allowance(address(vault), USDC_ADDR, address(posm));
        (uint160 allowance1,,) = permit2.allowance(address(vault), WETH_ADDR, address(posm));
        assertEq(uint256(allowance0) + allowance1, 0, "standing Permit2 allowance");
        Band[] memory b = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            assertEq(posm.ownerOf(b[i].tokenId), address(vault));
        }
    }

    /**
     * @notice Guide 7.4: `totalAssets` is bands at the current price plus pending fees (net of the protocol cut)
     *         plus idle, to the wei.
     */
    function test_totalAssets_equals_the_sum_of_its_parts_net_of_the_protocol_fee() public {
        _deposit(vault, alice, 200_000e6, 100 ether);
        _churn(6);
        usdc.mint(address(vault), 123e6);
        (uint160 sp,,,) = stateView.getSlot0(_poolId(key));
        (uint256 f0, uint256 f1) = _pending();
        uint256 amount0 = usdc.balanceOf(address(vault)) + f0 - f0 * 1_500 / 10_000;
        uint256 amount1 = weth.balanceOf(address(vault)) + f1 - f1 * 1_500 / 10_000;
        Band[] memory b = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            (uint256 x, uint256 y) = LiquidityMath.amountsForLiquidity(
                sp,
                SqrtPriceMath.getSqrtPriceAtTick(b[i].tickLower),
                SqrtPriceMath.getSqrtPriceAtTick(b[i].tickUpper),
                b[i].liquidity
            );
            amount0 += x;
            amount1 += y;
        }
        assertEq(vault.totalAssets(), _valueAt(amount0, amount1, sp));
    }

    /**
     * @notice Guide 7.2 edge case: a withdrawal so small that it removes zero liquidity from every band pays the
     *         idle share without reverting and, when no fee is pending, without calling the PositionManager.
     */
    function test_a_withdrawal_that_removes_zero_liquidity_pays_the_idle_share() public {
        (uint256 shares,,) = _deposit(vault, alice, 200_000e6, 100 ether);
        weth.mint(address(vault), 1 ether);
        Band[] memory b = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            assertLt(b[i].liquidity, vault.totalSupply(), "precondition: less than one liquidity unit per share");
        }

        uint256 supply = vault.totalSupply();
        uint256 idle1 = weth.balanceOf(address(vault));
        vm.expectCall(address(posm), "", 0);
        uint256 before = weth.balanceOf(alice);
        vm.prank(alice);
        (, uint256 out1) = vault.withdrawPair(1, 0, 0, alice);
        assertEq(out1, Math.mulDiv(1, idle1, supply), "idle share only");
        assertEq(weth.balanceOf(alice) - before, out1);
        assertEq(vault.balanceOf(alice), shares - 1);
        Band[] memory afterBands = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            assertEq(afterBands[i].liquidity, b[i].liquidity);
        }
    }

    /**
     * @notice Same zero-liquidity withdrawal while fees are pending: it collects them (DECREASE of zero) and pays the
     *         idle-plus-fees share, still removing no liquidity.
     */
    function test_a_zero_liquidity_withdrawal_with_pending_fees_collects_them() public {
        _deposit(vault, alice, 200_000e6, 100 ether);
        _churn(2);
        Band[] memory b = vault.bands();
        (uint256 f0, uint256 f1) = _pending();
        assertGt(f0 + f1, 0);
        vm.prank(alice);
        vault.withdrawPair(1, 0, 0, alice);
        (uint256 g0, uint256 g1) = _pending();
        assertEq(g0 + g1, 0, "pending fees were collected");
        assertEq(usdc.balanceOf(factoryFeeCollector), f0 * 1_500 / 10_000);
        assertEq(weth.balanceOf(factoryFeeCollector), f1 * 1_500 / 10_000);
        Band[] memory afterBands = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            assertEq(afterBands[i].liquidity, b[i].liquidity);
        }
    }

    /**
     * @notice A vault without bands has nothing to collect: `collectFees` returns zero without touching Uniswap or
     *         the factory.
     */
    function test_collectFees_without_bands_is_a_no_op() public {
        vm.expectCall(address(posm), "", 0);
        vm.expectCall(address(this), abi.encodeWithSelector(this.protocolFeeBps.selector), 0);
        (uint256 fee0, uint256 fee1) = vault.collectFees();
        assertEq(fee0 + fee1, 0);
    }

    /**
     * @notice `withdrawPair` burns only the caller's shares; an allowance does not let a spender withdraw.
     */
    function test_withdrawPair_burns_only_the_callers_shares() public {
        (uint256 shares,,) = _deposit(vault, alice, 200_000e6, 100 ether);
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert();
        vault.withdrawPair(shares, 0, 0, bob);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.allowance(alice, bob), type(uint256).max);
    }

    /**
     * @notice A failed minimum leaves every balance unchanged.
     */
    function test_withdrawPair_minimums_revert_atomically() public {
        (uint256 shares,,) = _deposit(vault, alice, 200_000e6, 100 ether);
        _churn(2);
        uint256 supply = vault.totalSupply();
        vm.prank(alice);
        vm.expectRevert(Vault.SlippageExceeded.selector);
        vault.withdrawPair(shares, 0, type(uint256).max, alice);
        assertEq(vault.totalSupply(), supply);
        assertEq(usdc.balanceOf(factoryFeeCollector), 0);
    }

    /**
     * @notice Compound is keeper-only, pause-gated and refuses a manipulated price.
     */
    function test_compound_gates() public {
        _deposit(vault, alice, 200_000e6, 100 ether);
        usdc.mint(address(vault), 10_000e6);
        weth.mint(address(vault), 5 ether);

        vm.prank(alice);
        vm.expectRevert(Vault.NotAuthorized.selector);
        vault.compound();

        vm.prank(guardianAccount);
        vault.pause();
        vm.prank(keeper);
        vm.expectRevert(Vault.IsPaused.selector);
        vault.compound();
        vm.prank(timelockAccount);
        vault.unpause();

        _swap(attacker, key, true, 5_000_000e6); // push the price far from the oracle
        vm.prank(keeper);
        vm.expectRevert(Vault.PriceUntrusted.selector);
        vault.compound();
    }

    /**
     * @notice Compound measures what it really took: idle is never "used" twice and ETH forced into the
     *         PositionManager (swept back on native pools) cannot underflow the measurement.
     */
    function test_compound_on_a_native_pool_with_forced_eth_in_the_position_manager() public {
        PoolKey memory nativeKey = _nativeUsdcKey();
        int24 tick = _initPool(nativeKey, 2000e6, 1e18, false);
        _seedExternalLiquidity(nativeKey, tick, 1e15);
        Vault nativeVault = _newVault(nativeKey, 1, tick, 2000, 2000);
        _deposit(nativeVault, alice, 100 ether, 300_000e6);
        vm.deal(address(nativeVault), address(nativeVault).balance + 3 ether);
        usdc.mint(address(nativeVault), 10_000e6);
        vm.deal(address(posm), 7 ether);
        uint256 idle0 = address(nativeVault).balance;
        uint256 idle1 = usdc.balanceOf(address(nativeVault));
        vm.prank(keeper);
        (uint256 used0, uint256 used1) = nativeVault.compound();
        assertLe(used0, idle0);
        assertLe(used1, idle1);
        assertEq(address(posm).balance, 0, "forced ETH swept to the vault, nothing left in the PositionManager");
    }

    /**
     * @notice The module refuses direct calls: its own storage is never used.
     */
    function test_the_m5_module_refuses_direct_calls() public {
        VaultM5Module module = VaultM5Module(vault.m5Module());
        assertEq(address(module), vm.computeCreateAddress(address(implementation), 1), "module address");
        assertEq(Vault(payable(address(implementation))).m5Module(), address(module), "shared by every clone");
        vm.expectRevert(VaultM5Module.NotAuthorized.selector);
        module.withdrawPair(1, 0, 0, alice);
        vm.expectRevert(VaultM5Module.NotAuthorized.selector);
        module.collectFees();
        vm.expectRevert(VaultM5Module.NotAuthorized.selector);
        module.compound();
        vm.expectRevert(VaultM5Module.NotAuthorized.selector);
        module.payDepositProtocolFee(1, 1);
    }

    /**
     * @notice A withdrawal that cannot deliver the protocol fee reports exactly what it forfeited.
     */
    function test_forfeited_protocol_fee_is_reported() public {
        (uint256 shares,,) = _deposit(vault, alice, 200_000e6, 100 ether);
        _churn(4);
        (uint256 f0, uint256 f1) = _pending();
        factoryFeeCollector = address(0);
        vm.expectEmit(address(vault));
        emit IVault.ProtocolFeeForfeited(f0 * 1_500 / 10_000, f1 * 1_500 / 10_000);
        vm.prank(alice);
        vault.withdrawPair(shares / 2, 0, 0, alice);
    }

    /**
     * @notice Strict fee paths (collect, compound, deposit) refuse to run while the collector is unset, so fees are
     *         never silently dropped there; withdrawals keep working.
     */
    function test_strict_fee_paths_revert_while_the_collector_is_unset() public {
        (uint256 shares,,) = _deposit(vault, alice, 200_000e6, 100 ether);
        _churn(4);
        factoryFeeCollector = address(0);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vault.collectFees();
        vm.prank(bob);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vault.depositPair(20_000e6, 10 ether, 0, bob);
        vm.prank(alice);
        vault.withdrawPair(shares, 0, 0, alice);
    }

    /**
     * @notice Guide 7.4: the in-kind preview equals the real withdrawal to the wei, for large, tiny and full exits,
     *         with pending fees, idle balances and a protocol fee in play.
     */
    function test_previewWithdrawPair_matches_the_real_withdrawal_to_the_wei() public {
        (uint256 aliceShares,,) = _deposit(vault, alice, 200_000e6, 100 ether);
        (uint256 bobShares,,) = _deposit(vault, bob, 20_000e6, 10 ether);
        _churn(4);
        usdc.mint(address(vault), 1_234e6);
        weth.mint(address(vault), 0.5 ether);
        _assertPreviewExact(alice, aliceShares / 3);
        _assertPreviewExact(alice, 1);
        _churn(2);
        _assertPreviewExact(bob, bobShares);
        _assertPreviewExact(alice, vault.balanceOf(alice));
    }

    /**
     * @notice Same on the native pool, including while the fee collector is broken (the payout uses the owed fee,
     *         so the preview does not depend on delivery).
     */
    function test_previewWithdrawPair_is_exact_on_the_native_pool_and_with_a_broken_collector() public {
        key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, 1e15);
        vault = _newVault(key, 1, tick, 2000, 2000);
        (uint256 shares,,) = _deposit(vault, alice, 100 ether, 300_000e6);
        for (uint256 i; i < 4; ++i) {
            _swap(attacker, key, true, 50 ether);
            _swap(attacker, key, false, 100_000e6);
        }
        _assertPreviewExact(alice, shares / 4);
        factoryFeeCollector = address(0);
        for (uint256 i; i < 2; ++i) {
            _swap(attacker, key, true, 50 ether);
            _swap(attacker, key, false, 100_000e6);
        }
        _assertPreviewExact(alice, shares / 4);
    }

    /**
     * @notice Fuzz: any share amount, any fee setting (including above the cap), after any amount of trading.
     */
    function testFuzz_previewWithdrawPair_matches_the_real_withdrawal(uint256 fraction, uint256 rounds, uint256 bps)
        public
    {
        (uint256 shares,,) = _deposit(vault, alice, 200_000e6, 100 ether);
        _deposit(vault, bob, 20_000e6, 10 ether);
        _churn(bound(rounds, 0, 5));
        factoryFeeBps = bound(bps, 0, 5_000);
        _assertPreviewExact(alice, bound(fraction, 1, shares));
    }

    function test_previewWithdrawPair_rejects_zero_and_excess_shares() public {
        _deposit(vault, alice, 200_000e6, 100 ether);
        VaultM5Module module = VaultM5Module(vault.m5Module());
        vm.expectRevert(VaultM5Module.ZeroValue.selector);
        module.previewWithdrawPair(vault, 0);
        uint256 supply = vault.totalSupply();
        vm.expectRevert(VaultM5Module.ZeroValue.selector);
        module.previewWithdrawPair(vault, supply + 1);
    }

    function _assertPreviewExact(address who, uint256 shares) internal {
        (uint256 p0, uint256 p1) = VaultM5Module(vault.m5Module()).previewWithdrawPair(vault, shares);
        vm.prank(who);
        (uint256 out0, uint256 out1) = vault.withdrawPair(shares, 0, 0, who);
        assertEq(out0, p0, "currency0 preview");
        assertEq(out1, p1, "currency1 preview");
    }

    /**
     * @notice ERC-4626 exits by a spender consume exactly the owner's allowance and fail without one.
     */
    function test_erc4626_exits_by_a_spender_require_and_spend_allowance() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100_000e6, alice);
        vm.prank(bob);
        vm.expectRevert();
        vault.redeem(shares / 4, bob, alice);
        vm.prank(bob);
        vm.expectRevert();
        vault.withdraw(1_000e6, bob, alice);

        vm.prank(alice);
        vault.approve(bob, shares / 2);
        vm.prank(bob);
        vault.redeem(shares / 4, bob, alice);
        assertEq(vault.allowance(alice, bob), shares / 2 - shares / 4, "redeem spends the allowance");
        uint256 needed = vault.previewWithdraw(1_000e6);
        vm.prank(bob);
        vault.withdraw(1_000e6, bob, alice);
        assertEq(vault.allowance(alice, bob), shares / 2 - shares / 4 - needed, "withdraw spends the allowance");
        assertEq(vault.balanceOf(alice), shares - shares / 4 - needed);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _assertCollector(uint256 expected0, uint256 expected1, string memory step) internal view {
        assertEq(usdc.balanceOf(factoryFeeCollector), expected0, string.concat(step, ": USDC protocol fee"));
        assertEq(weth.balanceOf(factoryFeeCollector), expected1, string.concat(step, ": WETH protocol fee"));
    }

    function _churn(uint256 rounds) internal {
        for (uint256 i; i < rounds; ++i) {
            _swap(attacker, key, true, 100_000e6);
            _swap(attacker, key, false, 50 ether);
        }
        _syncOracleToUsdcWethPool(key);
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

    function _valueAt(uint256 a0, uint256 a1, uint160 sp) internal pure returns (uint256) {
        return Math.mulDiv(a0, Math.mulDiv(sp, sp, 1 << 96), 1 << 96) + a1;
    }
}
