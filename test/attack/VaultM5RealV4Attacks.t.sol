// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Vault} from "../../src/Vault.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {Band, PoolKey} from "../../src/libraries/Types.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {VaultRealV4Base} from "../integration/utils/VaultRealV4Base.sol";

/**
 * @title M5 attacks on real Uniswap v4
 * @notice Withdraw liveness, protocol-fee exactness, compound settlement and read-only reentrancy, all against the
 *         real PoolManager and PositionManager. Each test states the secure behaviour; the ones marked "bug" failed
 *         before the M5 audit fixes.
 */
contract VaultM5RealV4AttacksTest is VaultRealV4Base {
    PoolKey internal key;
    Vault internal vault;
    address internal keeper = makeAddr("keeper");
    uint256 internal _f0Before;

    // ------------------------------------------------------------------------------------------------------------
    // Withdraw must not depend on the factory or the fee collector (guide 7.2 rule 1, 7.4 security notes)
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice Bug: the protocol fee was sent with a reverting transfer inside `withdrawPair`, so a fee collector that
     *         cannot take ETH froze every withdrawal from native pools.
     */
    function test_withdraw_survives_a_fee_collector_that_rejects_eth() public {
        uint256 shares = _nativeVaultWithFees(1_000);
        factoryFeeCollector = address(new RejectingCollector());
        (uint256 f0, uint256 f1) = _pending();
        assertGt(f0, 0, "churn must produce ETH fees");
        assertGt(f1, 0, "churn must produce USDC fees");

        vm.prank(alice);
        (uint256 out0, uint256 out1) = vault.withdrawPair(shares / 2, 0, 0, alice);
        assertGt(out0, 0);
        assertGt(out1, 0);
        assertEq(factoryFeeCollector.balance, 0, "the collector refused ETH");
        assertEq(usdc.balanceOf(factoryFeeCollector), f1 * 1_000 / 10_000, "the USDC fee is still paid");
    }

    /**
     * @notice Bug: a fee collector blacklisted by the token (USDC can freeze any address) made the USDC protocol fee
     *         transfer revert, freezing all withdrawals from every USDC vault.
     */
    function test_withdraw_survives_a_fee_collector_blacklisted_by_the_token() public {
        uint256 shares = _nativeVaultWithFees(1_000);
        vm.etch(USDC_ADDR, address(new BlacklistToken(6)).code);
        BlacklistToken(USDC_ADDR).setBlocked(factoryFeeCollector, true);

        vm.prank(alice);
        (uint256 out0, uint256 out1) = vault.withdrawPair(shares / 2, 0, 0, alice);
        assertGt(out0, 0);
        assertGt(out1, 0);
        assertEq(usdc.balanceOf(factoryFeeCollector), 0);
    }

    /**
     * @notice Bug: a zero fee collector reverted with `ZeroAddress` whenever fees were pending.
     */
    function test_withdraw_survives_an_unset_fee_collector() public {
        uint256 shares = _nativeVaultWithFees(1_000);
        factoryFeeCollector = address(0);
        vm.prank(alice);
        (uint256 out0, uint256 out1) = vault.withdrawPair(shares, 0, 0, alice);
        assertGt(out0, 0);
        assertGt(out1, 0);
    }

    /**
     * @notice Bug: the ETH fee transfer forwarded all gas, so a collector that burns gas made withdrawals run out of
     *         gas.
     */
    function test_withdraw_survives_a_gas_burning_fee_collector() public {
        uint256 shares = _nativeVaultWithFees(1_000);
        factoryFeeCollector = address(new GasBurner());
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        (uint256 out0,) = vault.withdrawPair{gas: 6_000_000}(shares / 2, 0, 0, alice);
        assertGt(out0, 0);
        assertLt(gasBefore - gasleft(), 1_500_000, "the collector may burn only a bounded amount of gas");
    }

    /**
     * @notice A token that reports failure by returning `false` (instead of reverting) is treated as a failed fee
     *         delivery: the fee is reported as forfeited and the withdrawal still completes.
     */
    function test_a_false_returning_fee_transfer_is_reported_as_forfeited() public {
        uint256 shares = _nativeVaultWithFees(1_000);
        vm.etch(USDC_ADDR, address(new BlacklistToken(6)).code);
        BlacklistToken(USDC_ADDR).setBlocked(factoryFeeCollector, true);
        BlacklistToken(USDC_ADDR).setQuiet(true);
        (uint256 f0, uint256 f1) = _pending();
        vm.expectEmit(address(vault));
        emit IVault.ProtocolFeeForfeited(0, f1 * 1_000 / 10_000);
        vm.prank(alice);
        vault.withdrawPair(shares / 2, 0, 0, alice);
        assertEq(factoryFeeCollector.balance, f0 * 1_000 / 10_000, "the ETH fee is still delivered");
        assertEq(usdc.balanceOf(factoryFeeCollector), 0);
    }

    /**
     * @notice Bug: a reverting factory read (`protocolFeeBps`) blocked withdrawals.
     */
    function test_withdraw_survives_a_reverting_factory() public {
        uint256 shares = _nativeVaultWithFees(1_000);
        factoryReadsRevert = true;
        vm.prank(alice);
        (uint256 out0, uint256 out1) = vault.withdrawPair(shares, 0, 0, alice);
        assertGt(out0, 0);
        assertGt(out1, 0);
    }

    /**
     * @notice Bug: guide 7.2 requires the no-band path to make no external call except token transfers, but the
     *         module always read the factory's fee, even with nothing to charge.
     */
    function test_no_band_withdraw_makes_no_call_except_token_transfers() public {
        key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        vault = _newVault(key, 1, tick, 2000, 2000);
        vm.prank(alice);
        uint256 shares = vault.deposit(10_000e6, alice);
        assertEq(vault.bands().length, 0);

        factoryReadsRevert = true;
        vm.expectCall(address(this), abi.encodeWithSelector(this.protocolFeeBps.selector), 0);
        vm.expectCall(address(this), abi.encodeWithSelector(this.feeCollector.selector), 0);
        vm.expectCall(address(guard), abi.encodeWithSelector(IPriceGuard.isPriceTrusted.selector), 0);
        vm.expectCall(address(stateView), "", 0);
        vm.expectCall(address(posm), "", 0);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        (uint256 out0, uint256 out1) = vault.withdrawPair(shares, 0, 0, alice);
        assertEq(out0, 0);
        assertEq(usdc.balanceOf(alice) - before, out1);
        assertEq(out1, 10_000e6 - 1_000, "the holder leaves with all but the locked shares' value");
    }

    /**
     * @notice Control (guide 7.4 tests): withdraw works when paused, when the oracle reverts and with no keeper ever.
     */
    function test_withdraw_works_when_paused_and_the_oracle_reverts() public {
        uint256 shares = _nativeVaultWithFees(1_000);
        vm.prank(guardianAccount);
        vault.pause();
        vm.mockCallRevert(address(guard), abi.encodeWithSelector(IPriceGuard.isPriceTrusted.selector), "oracle down");
        vm.prank(alice);
        (uint256 out0, uint256 out1) = vault.withdrawPair(shares, 0, 0, alice);
        assertGt(out0, 0);
        assertGt(out1, 0);
        assertEq(vault.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Protocol fee: exactly feeBps of every fee the vault collects, never principal (guide invariant 7)
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice Control: the withdraw fee equals `floor(F * feeBps / 10_000)` and the payout equals the guide formula.
     */
    function test_withdraw_protocol_fee_is_exact_and_the_payout_matches_the_guide_formula() public {
        uint256 shares = _nativeVaultWithFees(1_000);
        Expect memory e;
        e.s = shares / 3;
        (e.f0, e.f1) = _pending();
        e.supply = vault.totalSupply();
        e.idle0 = address(vault).balance;
        e.idle1 = usdc.balanceOf(address(vault));
        (e.pr0, e.pr1) = _principalFor(e.s, e.supply);
        e.c0 = factoryFeeCollector.balance;
        e.c1 = usdc.balanceOf(factoryFeeCollector);

        vm.prank(alice);
        (uint256 out0, uint256 out1) = vault.withdrawPair(e.s, 0, 0, alice);

        uint256 p0 = e.f0 * 1_000 / 10_000;
        uint256 p1 = e.f1 * 1_000 / 10_000;
        assertEq(factoryFeeCollector.balance - e.c0, p0, "ETH protocol fee");
        assertEq(usdc.balanceOf(factoryFeeCollector) - e.c1, p1, "USDC protocol fee");
        uint256 n = vault.bands().length;
        assertApproxEqAbs(out0, e.pr0 + Math.mulDiv(e.s, e.idle0 + e.f0 - p0, e.supply), n, "ETH payout");
        assertApproxEqAbs(out1, e.pr1 + Math.mulDiv(e.s, e.idle1 + e.f1 - p1, e.supply), n, "USDC payout");
    }

    struct Expect {
        uint256 s;
        uint256 f0;
        uint256 f1;
        uint256 supply;
        uint256 idle0;
        uint256 idle1;
        uint256 pr0;
        uint256 pr1;
        uint256 c0;
        uint256 c1;
    }

    /**
     * @notice Bug: adding liquidity credits a band's accrued fees into the deposit's settlement; the vault kept them
     *         without the protocol cut, so every deposit silently cancelled the protocol fee on all pending fees.
     */
    function test_deposit_pays_the_protocol_fee_on_the_fees_it_sweeps() public {
        _nativeVaultWithFees(1_000);
        (uint256 f0, uint256 f1) = _pending();
        uint256 c0 = factoryFeeCollector.balance;
        uint256 c1 = usdc.balanceOf(factoryFeeCollector);
        _deposit(vault, bob, 0.01 ether, 30e6);
        assertEq(factoryFeeCollector.balance - c0, f0 * 1_000 / 10_000, "ETH fee swept without the protocol cut");
        assertEq(usdc.balanceOf(factoryFeeCollector) - c1, f1 * 1_000 / 10_000, "USDC fee swept without the cut");
        (f0, f1) = _pending();
        assertEq(f0 + f1, 0);
    }

    /**
     * @notice Bug: same for `compound`, which the keeper runs routinely.
     */
    function test_compound_pays_the_protocol_fee_on_the_fees_it_sweeps() public {
        _nativeVaultWithFees(1_000);
        _giveIdle(5 ether, 10_000e6);
        (uint256 f0, uint256 f1) = _pending();
        uint256 c0 = factoryFeeCollector.balance;
        uint256 c1 = usdc.balanceOf(factoryFeeCollector);
        factoryKeepers[keeper] = true;
        uint256 idle0 = address(vault).balance;
        uint256 idle1 = usdc.balanceOf(address(vault));
        vm.expectEmit(true, false, false, false, address(vault));
        emit IVault.Compounded(keeper, 0, 0);
        vm.prank(keeper);
        (uint256 used0, uint256 used1) = vault.compound();
        assertEq(factoryFeeCollector.balance - c0, f0 * 1_000 / 10_000, "ETH fee swept without the protocol cut");
        assertEq(usdc.balanceOf(factoryFeeCollector) - c1, f1 * 1_000 / 10_000, "USDC fee swept without the cut");
        // balance identity: idle + credited fees - spent - protocol cut
        assertEq(address(vault).balance, idle0 + f0 - used0 - f0 * 1_000 / 10_000, "ETH accounting");
        assertEq(usdc.balanceOf(address(vault)), idle1 + f1 - used1 - f1 * 1_000 / 10_000, "USDC accounting");
    }

    /**
     * @notice Control: `collectFees` is permissionless, takes exactly the protocol cut, leaves the rest idle and
     *         never touches principal.
     */
    function test_collectFees_is_exact_and_never_touches_principal() public {
        _nativeVaultWithFees(1_000);
        Band[] memory before = vault.bands();
        (uint256 f0, uint256 f1) = _pending();
        uint256 idle0 = address(vault).balance;
        uint256 idle1 = usdc.balanceOf(address(vault));

        vm.prank(attacker);
        (uint256 fee0, uint256 fee1) = vault.collectFees();

        assertEq(fee0, f0);
        assertEq(fee1, f1);
        assertEq(factoryFeeCollector.balance, f0 / 10);
        assertEq(usdc.balanceOf(factoryFeeCollector), f1 / 10);
        assertEq(address(vault).balance - idle0, f0 - f0 / 10);
        assertEq(usdc.balanceOf(address(vault)) - idle1, f1 - f1 / 10);
        Band[] memory afterBands = vault.bands();
        for (uint256 i; i < before.length; ++i) {
            assertEq(afterBands[i].liquidity, before[i].liquidity, "principal liquidity changed");
            assertEq(_realLiquidity(afterBands[i]), before[i].liquidity, "real position changed");
        }
        (f0, f1) = _pending();
        assertEq(f0 + f1, 0, "fees are not counted twice");
        (fee0, fee1) = vault.collectFees();
        assertEq(fee0 + fee1, 0);
    }

    /**
     * @notice Bug: the vault trusted any factory fee. A misconfigured fee above 100% made `collectFees` send the
     *         collector more than the fees (taking principal) or revert, and made withdrawals underflow. The
     *         business cap is mutable factory state, so the vault clamps only at 100% of the collected fees.
     */
    function test_a_protocol_fee_above_100_percent_is_clamped() public {
        uint256 shares = _nativeVaultWithFees(20_000);
        (uint256 f0, uint256 f1) = _pending();
        uint256 idle0 = address(vault).balance;
        uint256 idle1 = usdc.balanceOf(address(vault));
        vault.collectFees();
        assertEq(factoryFeeCollector.balance, f0, "ETH fee above 100%");
        assertEq(usdc.balanceOf(factoryFeeCollector), f1, "USDC fee above 100%");
        assertEq(address(vault).balance, idle0, "principal untouched");
        assertEq(usdc.balanceOf(address(vault)), idle1, "principal untouched");

        _churn(4);
        vm.prank(alice);
        (uint256 out0, uint256 out1) = vault.withdrawPair(shares, 0, 0, alice);
        assertGt(out0, 0);
        assertGt(out1, 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // compound settlement
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice Bug: `compound` measured `used = budget - balanceAfter`, which underflows when the fees credited by
     *         INCREASE_LIQUIDITY exceed what the compound spends in a currency (CLOSE_CURRENCY then pays the surplus
     *         to the vault), so the keeper could not compound.
     */
    function test_compound_does_not_revert_when_swept_fees_exceed_what_it_spends() public {
        _nativeVaultWithFees(0);
        _giveIdle(5 ether, 1_000);
        uint256 f1;
        (_f0Before, f1) = _pending();
        assertGt(f1, 1_000_000, "fees must exceed the idle USDC");
        uint256 idle1 = usdc.balanceOf(address(vault));
        factoryKeepers[keeper] = true;
        uint256 supply = vault.totalSupply();
        uint256 idle0 = address(vault).balance;
        vm.prank(keeper);
        (uint256 used0, uint256 used1) = vault.compound();
        assertGt(used0, 0);
        assertLe(used1, idle1);
        assertEq(address(vault).balance, idle0 + _f0Before - used0, "ETH accounting");
        assertEq(usdc.balanceOf(address(vault)), idle1 + f1 - used1, "USDC accounting");
        assertEq(vault.totalSupply(), supply, "compound mints no shares");
        assertEq(usdc.balanceOf(address(posm)), 0);
        assertEq(address(posm).balance, 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Valuation consistency between exits
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice Bug: `totalAssets` valued pending fees gross while `withdrawPair` pays them net of the protocol fee, so
     *         the share value the vault reports (and prices deposits, previews and ERC-4626 exits with) overstated
     *         what a holder can withdraw.
     */
    function test_pair_payout_equals_the_reported_share_value() public {
        uint256 shares = _nativeVaultWithFees(2_500);
        (uint160 sp,,,) = stateView.getSlot0(_poolId(key));
        uint256 expected = Math.mulDiv(shares / 3, vault.totalAssets(), vault.totalSupply());
        vm.prank(alice);
        (uint256 out0, uint256 out1) = vault.withdrawPair(shares / 3, 0, 0, alice);
        assertApproxEqAbs(_valueAt(out0, out1, sp), expected, 1_000, "payout differs from the reported value");
    }

    /**
     * @notice Bug: an ERC-4626 `redeem` paid the gross value, so a holder could dodge the protocol fee on their share
     *         of pending fees and leave it to the remaining holders.
     */
    function test_erc4626_redeem_cannot_dodge_the_protocol_fee() public {
        _nativeVaultWithFees(2_500);
        vm.prank(bob);
        uint256 bobShares = vault.deposit(50_000e6, bob);
        (uint160 sp,,,) = stateView.getSlot0(_poolId(key));
        uint256 s = bobShares / 2;

        uint256 snap = vm.snapshotState();
        vm.prank(bob);
        (uint256 out0, uint256 out1) = vault.withdrawPair(s, 0, 0, bob);
        uint256 pairValue = _valueAt(out0, out1, sp);
        vm.revertToState(snap);

        vm.prank(bob);
        uint256 assets = vault.redeem(s, bob, bob);
        assertLe(assets, pairValue + 1_000, "redeem pays more than the pair exit for the same shares");
    }

    /**
     * @notice Control (guide 7.4): two users entering at different times each exit with their pro-rata share.
     */
    function test_two_users_entering_at_different_times_exit_pro_rata() public {
        uint256 aliceShares = _nativeVaultWithFees(1_000);
        (uint256 bobShares,,) = _deposit(vault, bob, 10 ether, 30_000e6);
        _churn(5);
        _syncOracleToNativePool(key);
        (uint160 sp,,,) = stateView.getSlot0(_poolId(key));

        uint256 aliceExpected = Math.mulDiv(aliceShares, vault.totalAssets(), vault.totalSupply());
        vm.prank(alice);
        (uint256 a0, uint256 a1) = vault.withdrawPair(aliceShares, 0, 0, alice);
        assertApproxEqAbs(_valueAt(a0, a1, sp), aliceExpected, 1_000, "alice");

        uint256 bobExpected = Math.mulDiv(bobShares, vault.totalAssets(), vault.totalSupply());
        vm.prank(bob);
        (uint256 b0, uint256 b1) = vault.withdrawPair(bobShares, 0, 0, bob);
        assertApproxEqAbs(_valueAt(b0, b1, sp), bobExpected, 1_000, "bob");
        assertEq(vault.totalSupply(), 1_000, "only the locked shares remain");
    }

    /**
     * @notice Control: after every real holder leaves, the vault keeps working for new depositors (dead shares keep a
     *         residual liquidity in each band, so no position is ever empty).
     */
    function test_vault_is_reusable_after_every_real_holder_exits() public {
        uint256 shares = _nativeVaultWithFees(1_000);
        vm.prank(alice);
        vault.withdrawPair(shares, 0, 0, alice);
        Band[] memory b = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            assertGt(b[i].liquidity, 0, "a band was emptied");
        }
        (uint256 bobShares,,) = _deposit(vault, bob, 1 ether, 3_000e6);
        vm.prank(bob);
        vault.withdrawPair(bobShares, 0, 0, bob);
        vault.collectFees();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Reentrancy
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice Bug: `withdrawPair` sent the ETH leg first; a contract receiver observed `totalAssets` while the USDC
     *         leg was still in the vault, i.e. an inflated share price (read-only reentrancy against integrators).
     */
    function test_native_withdraw_receiver_sees_the_final_share_price() public {
        uint256 shares = _nativeVaultWithFees(0);
        SharePriceProbe probe = new SharePriceProbe(vault);
        vm.prank(alice);
        vault.withdrawPair(shares / 2, 0, 0, address(probe));
        assertTrue(probe.seen());
        assertEq(probe.seenAssets(), vault.totalAssets(), "receiver saw an intermediate totalAssets");
        assertEq(probe.seenSupply(), vault.totalSupply());
    }

    /**
     * @notice Bug: the deposit refund sent ETH before the USDC refund, with the same read-only reentrancy window.
     */
    function test_native_deposit_refund_receiver_sees_the_final_share_price() public {
        _nativeVaultWithFees(0);
        RefundProbe probe = new RefundProbe(vault);
        vm.deal(address(probe), 10 ether);
        usdc.mint(address(probe), 1_000_000e6);
        probe.deposit(1 ether, 500_000e6);
        assertTrue(probe.seen(), "the ETH refund must reach the probe");
        assertEq(probe.seenAssets(), vault.totalAssets(), "payer saw an intermediate totalAssets");
        assertEq(probe.seenSupply(), vault.totalSupply());
    }

    /**
     * @notice Control (guide 7.4): a contract receiver that re-enters on the ETH leg fails.
     */
    /**
     * @notice A factory returning a malformed collector word (high bits set) is treated as an unset collector: the
     *         strict paths refuse to pay and withdrawals forfeit, rather than sending fees to a truncated address.
     */
    function test_a_malformed_fee_collector_reads_as_unset() public {
        uint256 shares = _nativeVaultWithFees(1_000);
        vm.mockCall(address(this), abi.encodeWithSelector(this.feeCollector.selector), abi.encode(type(uint256).max));
        vm.expectRevert(Vault.ZeroAddress.selector);
        vault.collectFees();
        (uint256 f0, uint256 f1) = _pending();
        vm.expectEmit(address(vault));
        emit IVault.ProtocolFeeForfeited(f0 / 10, f1 / 10);
        vm.prank(alice);
        vault.withdrawPair(shares / 2, 0, 0, alice);
        assertEq(address(type(uint160).max).balance, 0);
    }

    /**
     * @notice A factory whose fee getter returns no data (or too little) reads as a zero fee everywhere: valuation
     *         is gross and nothing is sent. Guards the raw-call reads against using stale scratch memory.
     */
    function test_a_factory_returning_no_fee_data_reads_as_zero_fee() public {
        _nativeVaultWithFees(1_000);
        uint256 net = vault.totalAssets();
        vm.mockCall(address(this), abi.encodeWithSelector(this.protocolFeeBps.selector), "");
        (uint160 sp,,,) = stateView.getSlot0(_poolId(key));
        (uint256 f0, uint256 f1) = _pending();
        assertApproxEqAbs(
            vault.totalAssets() - net, _valueAt(f0 / 10, f1 / 10, sp), 1, "valuation must treat the fee as zero"
        );
        vault.collectFees();
        assertEq(factoryFeeCollector.balance + usdc.balanceOf(factoryFeeCollector), 0, "no fee sent");
    }

    function test_a_reentrant_native_receiver_cannot_reenter() public {
        uint256 shares = _nativeVaultWithFees(1_000);
        ReentrantReceiver r = new ReentrantReceiver(vault);
        vm.prank(alice);
        vault.transfer(address(r), shares / 2);
        r.exit(shares / 4);
        assertTrue(r.attempted());
        assertFalse(r.reentered(), "re-entry succeeded");
        assertEq(r.reason(), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _nativeVaultWithFees(uint256 feeBps) internal returns (uint256 aliceShares) {
        key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, 1e15);
        vault = _newVault(key, 1, tick, 2000, 2000);
        (aliceShares,,) = _deposit(vault, alice, 100 ether, 300_000e6);
        _churn(10);
        _syncOracleToNativePool(key);
        factoryFeeBps = feeBps;
    }

    function _giveIdle(uint256 eth, uint256 usdcAmount) internal {
        vm.deal(address(vault), address(vault).balance + eth);
        usdc.mint(address(vault), usdcAmount);
    }

    function _churn(uint256 rounds) internal {
        for (uint256 i; i < rounds; ++i) {
            _swap(attacker, key, true, 50 ether);
            _swap(attacker, key, false, 100_000e6);
        }
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

    function _realLiquidity(Band memory b) internal view returns (uint128 liquidity) {
        (liquidity,,) =
            stateView.getPositionInfo(_poolId(key), address(posm), b.tickLower, b.tickUpper, bytes32(b.tokenId));
    }

    function _principalFor(uint256 shares, uint256 supply) internal view returns (uint256 a0, uint256 a1) {
        (uint160 sp,,,) = stateView.getSlot0(_poolId(key));
        Band[] memory b = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            (uint256 x, uint256 y) = LiquidityMath.amountsForLiquidity(
                sp,
                SqrtPriceMath.getSqrtPriceAtTick(b[i].tickLower),
                SqrtPriceMath.getSqrtPriceAtTick(b[i].tickUpper),
                uint128(Math.mulDiv(b[i].liquidity, shares, supply))
            );
            a0 += x;
            a1 += y;
        }
    }

    function _valueAt(uint256 a0, uint256 a1, uint160 sp) internal pure returns (uint256) {
        return Math.mulDiv(a0, Math.mulDiv(sp, sp, 1 << 96), 1 << 96) + a1;
    }
}

contract RejectingCollector {
    receive() external payable {
        revert("no ETH");
    }
}

contract GasBurner {
    uint256 internal _sink;

    receive() external payable {
        while (true) {
            _sink++;
        }
    }
}

contract BlacklistToken is ERC20 {
    uint8 private immutable _d;
    mapping(address => bool) public blocked;

    constructor(uint8 d) ERC20("B", "B") {
        _d = d;
    }

    function decimals() public view override returns (uint8) {
        return _d;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    bool public quiet;

    function setQuiet(bool quiet_) external {
        quiet = quiet_;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (quiet && blocked[to]) return false;
        return super.transfer(to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[from] && !blocked[to], "blacklisted");
        super._update(from, to, value);
    }
}

contract SharePriceProbe {
    Vault internal immutable _vault;
    bool public seen;
    uint256 public seenAssets;
    uint256 public seenSupply;

    constructor(Vault vault_) {
        _vault = vault_;
    }

    receive() external payable {
        seen = true;
        seenAssets = _vault.totalAssets();
        seenSupply = _vault.totalSupply();
    }
}

contract RefundProbe {
    Vault internal immutable _vault;
    bool public seen;
    uint256 public seenAssets;
    uint256 public seenSupply;

    constructor(Vault vault_) {
        _vault = vault_;
    }

    function deposit(uint256 amount0, uint256 amount1) external {
        ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48).approve(address(_vault), amount1);
        _vault.depositPair{value: amount0}(amount0, amount1, 0, address(this));
    }

    receive() external payable {
        if (msg.sender != address(_vault)) return;
        seen = true;
        seenAssets = _vault.totalAssets();
        seenSupply = _vault.totalSupply();
    }
}

contract ReentrantReceiver {
    Vault internal immutable _vault;
    bool public attempted;
    bool public reentered;
    bytes4 public reason;

    constructor(Vault vault_) {
        _vault = vault_;
    }

    function exit(uint256 shares) external {
        _vault.withdrawPair(shares, 0, 0, address(this));
    }

    receive() external payable {
        if (attempted) return;
        attempted = true;
        try _vault.withdrawPair(1, 0, 0, address(this)) returns (uint256, uint256) {
            reentered = true;
        } catch (bytes memory r) {
            reason = bytes4(r);
        }
    }
}
