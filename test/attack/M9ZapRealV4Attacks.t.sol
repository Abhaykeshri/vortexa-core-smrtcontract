// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath as V4TickMath} from "uni-test/v4-core/src/libraries/TickMath.sol";
import {IV4Router} from "uni-test/v4-periphery/src/interfaces/IV4Router.sol";
import {Vault} from "../../src/Vault.sol";
import {Zap} from "../../src/Zap.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {ISwapExecutor} from "../../src/interfaces/ISwapExecutor.sol";
import {Band, Currency, PoolKey, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {M9ZapRealV4Base} from "../integration/M9ZapRealV4.t.sol";

interface M9BalanceOf {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

/**
 * @title M9 Zap attacks and end-to-end checks on real Uniswap v4
 * @notice ERC-20/ERC-20 pools, value fairness for the zapper and for existing holders, dust-sized vaults,
 *         sandwiches inside the oracle tolerance, and closed or filled vaults.
 */
contract M9ZapRealV4AttacksTest is M9ZapRealV4Base {
    PoolKey internal key;

    // ------------------------------------------------------------------------------------------------------------
    // ERC-20/ERC-20 pool
    // ------------------------------------------------------------------------------------------------------------

    /**
     * USDC/WETH (no native leg): Normal LP first and later zaps from both tokens, and both one-sided strategies with
     * the right and the wrong token. The Zap keeps nothing and leaves no allowance in either token.
     */
    function test_erc20_pool_zaps_from_both_tokens_into_every_strategy() public {
        int24 tick = _usdcWethPool();
        Vault normalVault = _newVaultWith(_normalConfig(_floor(tick)), address(normal));
        vm.prank(alice);
        assertGt(zap.zapDeposit(address(normalVault), WETH_ADDR, 5 ether, 1, 100, alice), 0);
        vm.prank(bob);
        assertGt(zap.zapDeposit(address(normalVault), USDC_ADDR, 10_000e6, 1, 100, bob), 0);
        vm.prank(bob);
        assertGt(zap.zapDeposit(address(normalVault), WETH_ADDR, 1 ether, 1, 100, bob), 0);
        _assertClean(normalVault);

        // base WETH is currency1: Buy the Dip sits above the price (takes USDC), Sell the Pump below (takes WETH)
        Vault dipVault = _newVaultWith(_oneSidedConfig(Strategy.BuyTheDip, false, tick), address(dip));
        vm.prank(alice);
        assertGt(zap.zapDeposit(address(dipVault), USDC_ADDR, 4_000e6, 1, 100, alice), 0);
        vm.prank(bob);
        assertGt(zap.zapDeposit(address(dipVault), WETH_ADDR, 1 ether, 1, 100, bob), 0); // swapped to USDC
        _assertClean(dipVault);

        Vault pumpVault = _newVaultWith(_oneSidedConfig(Strategy.SellThePump, false, tick), address(pump));
        vm.prank(alice);
        assertGt(zap.zapDeposit(address(pumpVault), WETH_ADDR, 2 ether, 1, 100, alice), 0);
        vm.prank(bob);
        assertGt(zap.zapDeposit(address(pumpVault), USDC_ADDR, 4_000e6, 1, 100, bob), 0); // swapped to WETH
        _assertClean(pumpVault);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Value fairness
    // ------------------------------------------------------------------------------------------------------------

    /**
     * A zapper is never credited more than the value supplied, an existing holder never pays for the zap, and the
     * zapper's loss is bounded by the pool fee and the swap's price impact (well inside the 1% slippage cap), all
     * measured at the oracle reference price. Native and ERC-20 pools, both input tokens, first and later deposits.
     */
    function testFuzz_zap_value_is_fair_for_the_zapper_and_existing_holders(
        uint96 rawAmount,
        bool nativePool,
        bool inputIs0,
        bool existingHolder
    ) public {
        int24 tick = nativePool ? _nativePool() : _usdcWethPool();
        Vault vault = _newVaultWith(_normalConfig(_floor(tick)), address(normal));
        uint256 bobShares;
        if (existingHolder) {
            (bobShares,,) = _deposit(vault, bob, nativePool ? 5 ether : 10_000e6, nativePool ? 10_000e6 : 5 ether);
        }
        address token = _token(inputIs0);
        uint256 amount = _inputAmount(rawAmount, nativePool, inputIs0);
        uint160 ref = guard.referenceSqrtPriceX96(key);
        uint256 bobBefore = bobShares == 0 ? 0 : _shareValue(vault, bobShares, ref);
        uint256 supplied = inputIs0 ? _valueAt(amount, 0, ref) : amount;

        (uint256 refund0, uint256 refund1, uint256 shares) = _zapAndMeasure(vault, token, amount);
        uint256 received = _shareValue(vault, shares, ref) + _valueAt(refund0, refund1, ref);
        assertLe(_shareValue(vault, shares, ref), supplied + 4, "zapper over-credited");
        // one swap at most: fee (5 bps) plus impact in a deep pool; generous 60 bps bound, plus rounding
        assertGe(received + 4, Math.mulDiv(supplied, 9_940, 10_000), "zapper lost more than fee and impact");
        if (bobShares != 0) assertGe(_shareValue(vault, bobShares, ref) + 4, bobBefore, "existing holder paid");
        _assertClean(vault);
    }

    /**
     * `quoteZap` is the interface's basis for `minShares` (guide 11.3), so it must never promise more than a zap
     * executed right after it mints: native and ERC-20 pools, both tokens, first and later deposits, every strategy.
     */
    function testFuzz_quote_never_exceeds_the_executed_zap(
        uint96 rawAmount,
        bool nativePool,
        bool inputIs0,
        uint8 rawKind,
        bool existingHolder
    ) public {
        _checkQuote(rawAmount, nativePool, inputIs0, rawKind, existingHolder, false);
    }

    /**
     * Same at dust sizes (a raw unit of USDC up to 2 USDC, 1 gwei up to 0.001 ETH), where the quote's fixed per-band
     * reserves, not its 1 ppm margin, keep it conservative. Zaps too small to mint, or to swap within the floor,
     * revert, which is fine.
     */
    function testFuzz_dust_quote_never_exceeds_the_executed_zap(
        uint96 rawAmount,
        bool nativePool,
        bool inputIs0,
        uint8 rawKind,
        bool existingHolder
    ) public {
        _checkQuote(rawAmount, nativePool, inputIs0, rawKind, existingHolder, true);
    }

    function _checkQuote(
        uint96 rawAmount,
        bool nativePool,
        bool inputIs0,
        uint8 rawKind,
        bool existingHolder,
        bool dust
    ) internal {
        int24 tick = nativePool ? _nativePool() : _usdcWethPool();
        uint8 kind = rawKind % 3;
        Vault vault;
        if (kind == 0) {
            vault = _newVaultWith(_normalConfig(_floor(tick)), address(normal));
        } else {
            Strategy s = kind == 1 ? Strategy.BuyTheDip : Strategy.SellThePump;
            vault = _newVaultWith(_oneSidedConfig(s, nativePool, tick), kind == 1 ? address(dip) : address(pump));
        }
        if (existingHolder) {
            address seedToken = _token(inputIs0);
            uint256 seedAmount = _inputAmount(rawAmount / 2, nativePool, inputIs0);
            vm.prank(bob);
            zap.zapDeposit{value: seedToken == address(0) ? seedAmount : 0}(
                address(vault), seedToken, seedAmount, 1, 100, bob
            );
        }
        address token = _token(inputIs0);
        uint256 amount =
            dust ? _dustAmount(rawAmount, nativePool, inputIs0) : _inputAmount(rawAmount, nativePool, inputIs0);
        (, uint256 quote) = zap.quoteZap(address(vault), token, amount);
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(zap).call{value: token == address(0) ? amount : 0}(
            abi.encodeCall(zap.zapDeposit, (address(vault), token, amount, quote, uint16(100), alice))
        );
        if (!ok) {
            bytes4 sel = bytes4(ret);
            // too small to mint anything (or below the first-deposit minimum), or a swap of a few raw units whose
            // rounded output misses the 1% floor
            if (
                dust
                    && (sel == Vault.ZeroLiquidity.selector
                        || sel == Vault.ZeroValue.selector
                        || sel == Vault.FirstDepositTooSmall.selector
                        || sel == IV4Router.V4TooLittleReceived.selector)
            ) return;
            // A wrong-token zap into a one-sided ladder that sits at the price can push the price into the ladder
            // with its own swap, closing the deposit window (documented). Anything else is a quote failure.
            assertEq(sel, Vault.DepositNotAllowed.selector, "the quote promised more than the zap minted");
            assertTrue(kind != 0 && existingHolder, "only a live one-sided ladder can close under the zap");
            return;
        }
        assertGe(abi.decode(ret, (uint256)), quote, "the quote promised more than the zap minted");
    }

    /**
     * The Zap's first-deposit quote mirrors the one-sided strategy's anchor exactly: with the price inside a
     * spacing-aligned tick, Sell the Pump's first band starts one spacing above it (all token0), so a token0 zap
     * is quoted in full rather than as zero.
     */
    function test_one_sided_first_quote_mirrors_the_strategy_anchor_on_a_tick_boundary() public {
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDC_ADDR), 3000, 60, address(0));
        int24 aligned = V4TickMath.getTickAtSqrtPrice(guard.sqrtFromRatio(2000e6, 1e18)) / 60 * 60;
        // halfway into the aligned tick: a band starting at `aligned` would straddle the price and need token1
        uint160 lo = V4TickMath.getSqrtPriceAtTick(aligned);
        manager.initialize(_v4(key), lo + (V4TickMath.getSqrtPriceAtTick(aligned + 1) - lo) / 2);
        (, int24 tick,,) = stateView.getSlot0(_poolId(key));
        assertEq(tick, aligned, "the price sits just above an aligned tick");
        _syncOracleToNativePool(key);
        IPriceGuard.PairConfig memory c;
        c.chainlinkFeed = address(ethUsd);
        c.maxStaleness = 1 hours;
        c.minAnswer = 100e8;
        c.maxAnswer = 20_000e8;
        c.maxDeviationBps = 100;
        guard.setPairConfig(key, c);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);

        Vault vault = _newVaultWith(_oneSidedConfig(Strategy.SellThePump, true, tick), address(pump));
        (uint256 swapAmount, uint256 quote) = zap.quoteZap(address(vault), address(0), 1 ether);
        assertEq(swapAmount, 0);
        assertGt(quote, 0, "a token0-only first deposit was quoted as nothing");
        vm.prank(alice);
        uint256 shares = zap.zapDeposit{value: 1 ether}(address(vault), address(0), 1 ether, quote, 100, alice);
        assertGe(shares, quote);
        assertGe(quote, Math.mulDiv(shares, 9_999, 10_000), "quote far below the minted shares");
        assertGt(vault.bands()[0].tickLower, tick, "the ladder starts above the price");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Dust-sized vault
    // ------------------------------------------------------------------------------------------------------------

    /**
     * Bug (M9 audit): the Zap derived its swap split from the token amounts of the bands' stored liquidity. Once only
     * the dead shares remain (or after a dust first deposit) that liquidity is tiny and its amounts round down by up
     * to a unit per band, skewing the split: a 1,000 USDC zap left 0.146% undeployed instead of the 0.050% a normal
     * vault leaves (the pool fee). The split now uses the vault's probe-scaled proportions, so a dust-sized vault
     * zaps exactly like a full one. Larger zaps leave more behind in every vault (the Zap prices its swap before its
     * own price impact, and the guide accepts refunding the difference); that part is identical across vault sizes.
     */
    function test_zap_split_on_a_dust_sized_vault_matches_a_normal_vault() public {
        uint256[2] memory sizes = [uint256(1_000e6), 10_000e6];
        for (uint256 z; z < sizes.length; ++z) {
            uint256 snap = vm.snapshotState();
            uint256 normalRefund = _refundPpm(0, sizes[z]);
            vm.revertToState(snap);
            uint256 deadSharesRefund = _refundPpm(1, sizes[z]);
            vm.revertToState(snap);
            uint256 dustRefund = _refundPpm(2, sizes[z]);
            vm.revertToState(snap);
            assertLe(deadSharesRefund, normalRefund + 20, "a dead-shares vault skews the split");
            assertLe(dustRefund, normalRefund + 20, "a dust vault skews the split");
        }
    }

    /**
     * Refund left by a USDC zap, in parts per million of the input. Mode 0: a vault with a real holder; 1: every
     * holder left (dead shares only); 2: a dust first deposit.
     */
    function _refundPpm(uint256 mode, uint256 amount) internal returns (uint256) {
        int24 tick = _nativePool();
        Vault vault = _newVaultWith(_normalConfig(_floor(tick)), address(normal));
        if (mode == 0 || mode == 1) {
            (uint256 s,,) = _deposit(vault, bob, 5 ether, 10_000e6);
            if (mode == 1) {
                vm.prank(bob);
                vault.withdrawPair(s, 0, 0, bob);
            }
        } else {
            _deposit(vault, attacker, 1e13, 20_000);
        }
        uint160 ref = guard.referenceSqrtPriceX96(key);
        (uint256 refund0, uint256 refund1,) = _zapAndMeasure(vault, USDC_ADDR, amount);
        return _valueAt(refund0, refund1, ref) * 1e6 / amount;
    }

    // ------------------------------------------------------------------------------------------------------------
    // Sandwich
    // ------------------------------------------------------------------------------------------------------------

    /**
     * Guide 11 security note: a sandwich around a zap's swap, inside the oracle tolerance, either makes the call
     * revert or costs the zapper at most about `maxDeviationBps + maxSlippageBps` of the input, while an existing
     * holder stays within the documented in-tolerance deposit bound.
     */
    function test_sandwiched_zap_stays_inside_the_documented_bound() public {
        int24 tick = _nativePool();
        Vault vault = _newVaultWith(_normalConfig(_floor(tick)), address(normal));
        (uint256 bobShares,,) = _deposit(vault, bob, 5 ether, 10_000e6);
        uint160 ref = guard.referenceSqrtPriceX96(key);
        uint256 bobBefore = _shareValue(vault, bobShares, ref);

        // front-run: buy ETH ahead of a USDC zap (which buys ETH), about 40 bps, inside the 1% tolerance
        (, int24 start,,) = stateView.getSlot0(_poolId(key));
        uint256 ethBefore = attacker.balance;
        for (uint256 i; i < 400; ++i) {
            (, int24 t,,) = stateView.getSlot0(_poolId(key));
            if (t >= start + 40) break;
            _swap(attacker, key, false, 2_000e6);
        }
        (bool trusted,) = guard.isPriceTrusted(key);
        assertTrue(trusted, "the push stays inside the tolerance");

        uint256 amount = 40_000e6;
        uint256 aliceUsdc = usdc.balanceOf(alice);
        uint256 aliceEth = alice.balance;
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(zap)
            .call(abi.encodeCall(zap.zapDeposit, (address(vault), USDC_ADDR, amount, uint256(1), uint16(100), alice)));
        _swap(attacker, key, true, attacker.balance - ethBefore); // back-run

        if (!ok) {
            assertEq(usdc.balanceOf(alice), aliceUsdc, "a refused zap moved funds");
            return;
        }
        uint256 shares = abi.decode(ret, (uint256));
        uint256 received = _shareValue(vault, shares, ref)
            + _valueAt(alice.balance - aliceEth, usdc.balanceOf(alice) + amount - aliceUsdc, ref);
        assertGe(received, Math.mulDiv(amount, 9_795, 10_000), "zapper lost more than deviation + slippage + fee");
        uint256 bobLoss =
            bobBefore > _shareValue(vault, bobShares, ref) ? bobBefore - _shareValue(vault, bobShares, ref) : 0;
        assertLe(bobLoss, Math.mulDiv(amount, 102, 10_000), "existing holder above the documented bound");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Closed or filled vaults
    // ------------------------------------------------------------------------------------------------------------

    /**
     * A zap into a one-sided vault whose deposit window is closed (price inside the ladder) reverts atomically: the
     * swap is undone and the caller keeps every token.
     */
    function test_zap_into_a_closed_vault_reverts_without_moving_funds() public {
        int24 tick = _nativePool();
        Vault vault = _newVaultWith(_oneSidedConfig(Strategy.BuyTheDip, true, tick), address(dip));
        vm.prank(alice);
        zap.zapDeposit(address(vault), USDC_ADDR, 20_000e6, 1, 100, alice);
        // move the price down into the ladder: deposits close
        Band[] memory b = vault.bands();
        for (uint256 i; i < 400; ++i) {
            (, int24 t,,) = stateView.getSlot0(_poolId(key));
            if (t < b[b.length - 1].tickUpper - 20) break;
            _swap(attacker, key, true, 0.5 ether);
        }
        _syncOracleToNativePool(key);
        uint256 ethBefore = bob.balance;
        vm.prank(bob);
        vm.expectRevert(Vault.DepositNotAllowed.selector);
        zap.zapDeposit{value: 1 ether}(address(vault), address(0), 1 ether, 1, 100, bob);
        assertEq(bob.balance, ethBefore);
        _assertClean(vault);
    }

    // ------------------------------------------------------------------------------------------------------------
    // First deposit split
    // ------------------------------------------------------------------------------------------------------------

    /**
     * On a first deposit the vault plans its own corrective swap for whatever the Zap's split missed. The Zap sizes
     * its swap from the weighted planned bands, so that correction stays a few basis points of the input even when the
     * planned center sits away from the price (where the band weights shift the target ratio the most).
     */
    function test_first_deposit_zap_leaves_the_vault_only_a_small_corrective_swap() public {
        int24[2] memory offsets = [int24(400), -400];
        for (uint256 o; o < offsets.length; ++o) {
            uint256 snap = vm.snapshotState();
            int24 tick = _nativePool();
            Vault vault = _newVaultWith(_normalConfig(_floor(tick) + offsets[o]), address(normal));
            uint160 ref = guard.referenceSqrtPriceX96(key);
            vm.recordLogs();
            _zapAndMeasure(vault, USDC_ADDR, 10_000e6);
            assertLe(_swappedBy(address(vault), ref), 50e6, "the Zap's first-deposit split left a large correction");
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Defence in depth: a misbehaving vault or executor
    // ------------------------------------------------------------------------------------------------------------

    /**
     * The Zap checks what the vault reports (shares against `minShares`, used amounts against what it supplied) and
     * revokes the vault allowance itself, so a vault that pulls less than approved leaves no standing allowance.
     */
    function test_zap_checks_the_vault_result_and_revokes_unused_allowances() public {
        int24 tick = _usdcWethPool();
        Vault vault = _newVaultWith(_normalConfig(_floor(tick)), address(normal));
        _deposit(vault, bob, 10_000e6, 5 ether);
        bytes memory deposit = abi.encodeWithSelector(Vault.depositPair.selector);

        vm.mockCall(address(vault), deposit, abi.encode(uint256(0), uint256(0), uint256(0)));
        vm.prank(alice);
        vm.expectRevert(Zap.InvalidDepositResult.selector);
        zap.zapDeposit(address(vault), USDC_ADDR, 1_000e6, 1, 100, alice);

        vm.mockCall(address(vault), deposit, abi.encode(uint256(1), type(uint256).max, uint256(0)));
        vm.prank(alice);
        vm.expectRevert(Zap.InvalidDepositResult.selector);
        zap.zapDeposit(address(vault), USDC_ADDR, 1_000e6, 0, 100, alice);

        vm.mockCall(address(vault), deposit, abi.encode(uint256(1), uint256(0), uint256(0)));
        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        zap.zapDeposit(address(vault), USDC_ADDR, 1_000e6, 0, 100, alice);
        assertGt(usdc.balanceOf(alice) + 1_000e6, usdcBefore, "the unpulled input came back");
        assertGt(weth.balanceOf(address(alice)), 0);
        _assertClean(vault);
        vm.clearMockedCalls();
    }

    /**
     * The Zap measures the executor's output instead of trusting the reported amount, and revokes the executor's
     * allowance itself.
     */
    function test_zap_checks_the_executor_output_and_revokes_its_allowance() public {
        int24 tick = _usdcWethPool();
        Vault vault = _newVaultWith(_normalConfig(_floor(tick)), address(normal));
        _deposit(vault, bob, 10_000e6, 5 ether);
        bytes memory swap = abi.encodeWithSelector(ISwapExecutor.swapExactInput.selector);

        vm.mockCall(address(executor), swap, abi.encode(uint256(1)));
        vm.prank(alice);
        vm.expectRevert(Zap.TokenTransferShortfall.selector);
        zap.zapDeposit(address(vault), USDC_ADDR, 1_000e6, 0, 100, alice);

        vm.mockCall(address(executor), swap, abi.encode(uint256(0)));
        vm.mockCall(
            address(vault),
            abi.encodeWithSelector(Vault.depositPair.selector),
            abi.encode(uint256(1), uint256(0), uint256(0))
        );
        vm.prank(alice);
        zap.zapDeposit(address(vault), USDC_ADDR, 1_000e6, 0, 100, alice);
        _assertClean(vault);
        vm.clearMockedCalls();
    }

    /**
     * Active bands whose first band holds no liquidity cannot define a ratio; the Zap refuses instead of dividing by
     * zero.
     */
    function test_zap_refuses_bands_without_liquidity() public {
        int24 tick = _nativePool();
        Vault vault = _newVaultWith(_normalConfig(_floor(tick)), address(normal));
        _deposit(vault, bob, 5 ether, 10_000e6);
        Band[] memory b = vault.bands();
        b[0].liquidity = 0;
        vm.mockCall(address(vault), abi.encodeWithSelector(Vault.bands.selector), abi.encode(b));
        vm.expectRevert(Zap.InvalidVaultConfiguration.selector);
        zap.quoteZap(address(vault), USDC_ADDR, 1_000e6);
    }

    /**
     * After refunding, the Zap must hold exactly its pre-call balances. A caller whose ETH refund hook changes the
     * Zap's balance (here by a forced send) aborts its own zap.
     */
    function test_balance_change_during_the_refund_aborts_the_zap() public {
        int24 tick = _nativePool();
        Vault vault = _newVaultWith(_normalConfig(_floor(tick)), address(normal));
        _deposit(vault, bob, 5 ether, 10_000e6);
        M9BalanceBumper bumper = new M9BalanceBumper(zap, vault);
        deal(USDC_ADDR, address(bumper), 1_000e6);
        vm.expectRevert(Zap.BalanceContaminated.selector);
        bumper.zapUsdc(1_000e6);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _zapAndMeasure(Vault vault, address token, uint256 amount)
        internal
        returns (uint256 refund0, uint256 refund1, uint256 shares)
    {
        bool native = Currency.unwrap(key.currency0) == address(0);
        uint256 b0 = native ? alice.balance : M9BalanceOf(Currency.unwrap(key.currency0)).balanceOf(alice);
        uint256 b1 = M9BalanceOf(Currency.unwrap(key.currency1)).balanceOf(alice);
        vm.prank(alice);
        shares = zap.zapDeposit{value: token == address(0) ? amount : 0}(address(vault), token, amount, 1, 100, alice);
        uint256 a0 = native ? alice.balance : M9BalanceOf(Currency.unwrap(key.currency0)).balanceOf(alice);
        uint256 a1 = M9BalanceOf(Currency.unwrap(key.currency1)).balanceOf(alice);
        bool inputIs0 = token == Currency.unwrap(key.currency0);
        refund0 = inputIs0 ? a0 + amount - b0 : a0 - b0;
        refund1 = inputIs0 ? a1 - b1 : a1 + amount - b1;
    }

    /**
     * Token1 value at `ref` of the executor swaps `caller` made, from the recorded logs.
     */
    function _swappedBy(address caller, uint160 ref) internal returns (uint256 value) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = ISwapExecutor.SwapExecuted.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(executor) || logs[i].topics[0] != sig) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != caller) continue;
            (,,,,, bool zeroForOne, uint256 amountIn,) =
                abi.decode(logs[i].data, (address, address, uint24, int24, address, bool, uint256, uint256));
            value += zeroForOne ? _valueAt(amountIn, 0, ref) : amountIn;
        }
    }

    function _token(bool inputIs0) internal view returns (address) {
        return inputIs0 ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
    }

    function _inputAmount(uint96 raw, bool nativePool, bool inputIs0) internal pure returns (uint256) {
        // ETH or WETH legs in 18 decimals, USDC in 6; native pool: currency0 ETH, currency1 USDC
        bool eth = nativePool ? inputIs0 : !inputIs0;
        return eth ? bound(uint256(raw), 0.05 ether, 10 ether) : bound(uint256(raw), 100e6, 20_000e6);
    }

    function _dustAmount(uint96 raw, bool nativePool, bool inputIs0) internal pure returns (uint256) {
        bool eth = nativePool ? inputIs0 : !inputIs0;
        return eth ? bound(uint256(raw), 1e9, 1e15) : bound(uint256(raw), 1, 2e6);
    }

    function _nativePool() internal returns (int24 tick) {
        key = _nativeUsdcKey();
        tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);
    }

    function _usdcWethPool() internal returns (int24 tick) {
        key = _usdcWethKey();
        tick = _initPool(key, 1e18, 2000e6, true);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);
    }

    function _normalConfig(int24 center) internal view returns (VaultConfig memory config) {
        config.poolKey = key;
        config.strategy = Strategy.NormalLP;
        config.shapeId = 2;
        config.centerTick = center;
        config.ticksLeft = 600;
        config.ticksRight = 600;
        config.autoRebalance = true;
        config.baseIsCurrency0 = Currency.unwrap(key.currency0) == address(0);
    }

    function _oneSidedConfig(Strategy kind, bool baseIsCurrency0, int24 tick)
        internal
        view
        returns (VaultConfig memory config)
    {
        bool below = (kind == Strategy.BuyTheDip) == baseIsCurrency0;
        config.poolKey = key;
        config.strategy = kind;
        config.shapeId = 3;
        config.centerTick = _floor(tick);
        config.ticksLeft = below ? int24(600) : int24(0);
        config.ticksRight = below ? int24(0) : int24(600);
        config.trailTicks = 100;
        config.autoRebalance = true;
        config.lockOnFill = true;
        config.baseIsCurrency0 = baseIsCurrency0;
    }

    function _assertClean(Vault vault) internal view {
        assertEq(address(zap).balance, 0, "Zap kept ETH");
        assertEq(usdc.balanceOf(address(zap)), 0, "Zap kept USDC");
        assertEq(weth.balanceOf(address(zap)), 0, "Zap kept WETH");
        assertEq(usdc.allowance(address(zap), address(vault)), 0);
        assertEq(weth.allowance(address(zap), address(vault)), 0);
        assertEq(usdc.allowance(address(zap), address(executor)), 0);
        assertEq(weth.allowance(address(zap), address(executor)), 0);
    }

    function _shareValue(Vault vault, uint256 shares, uint160 ref) internal view returns (uint256) {
        return Math.mulDiv(shares, _vaultValueAt(vault, ref), vault.totalSupply());
    }

    /**
     * Band principal at `ref`, idle balances and pending fees net of the protocol fee.
     */
    function _vaultValueAt(Vault vault, uint160 ref) internal view returns (uint256) {
        bool native = Currency.unwrap(key.currency0) == address(0);
        uint256 amount0 =
            native ? address(vault).balance : M9BalanceOf(Currency.unwrap(key.currency0)).balanceOf(address(vault));
        uint256 amount1 = M9BalanceOf(Currency.unwrap(key.currency1)).balanceOf(address(vault));
        Band[] memory b = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            (uint256 f0, uint256 f1) = _pendingNet(b[i]);
            (uint256 x, uint256 y) = LiquidityMath.amountsForLiquidity(
                ref,
                SqrtPriceMath.getSqrtPriceAtTick(b[i].tickLower),
                SqrtPriceMath.getSqrtPriceAtTick(b[i].tickUpper),
                b[i].liquidity
            );
            amount0 += x + f0;
            amount1 += y + f1;
        }
        return _valueAt(amount0, amount1, ref);
    }

    function _pendingNet(Band memory band) internal view returns (uint256 f0, uint256 f1) {
        (uint128 liq, uint256 last0, uint256 last1) = stateView.getPositionInfo(
            _poolId(key), address(posm), band.tickLower, band.tickUpper, bytes32(band.tokenId)
        );
        (uint256 now0, uint256 now1) = stateView.getFeeGrowthInside(_poolId(key), band.tickLower, band.tickUpper);
        unchecked {
            f0 = Math.mulDiv(liq, now0 - last0, 1 << 128);
            f1 = Math.mulDiv(liq, now1 - last1, 1 << 128);
        }
        uint256 bps = factoryFeeBps < 10_000 ? factoryFeeBps : 10_000;
        f0 -= f0 * bps / 10_000;
        f1 -= f1 * bps / 10_000;
    }

    function _valueAt(uint256 a0, uint256 a1, uint160 sp) internal pure returns (uint256) {
        return Math.mulDiv(a0, Math.mulDiv(sp, sp, 1 << 96), 1 << 96) + a1;
    }

    function _floor(int24 tick) internal view returns (int24 c) {
        int24 spacing = key.tickSpacing;
        c = (tick / spacing) * spacing;
        if (tick < 0 && c != tick) c -= spacing;
    }
}

/**
 * A zapper whose ETH refund hook changes the Zap's ETH balance (a forced send, simulated with `deal`).
 */
contract M9BalanceBumper {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    Zap private immutable zap;
    Vault private immutable vault;

    constructor(Zap zap_, Vault vault_) {
        zap = zap_;
        vault = vault_;
    }

    function zapUsdc(uint256 amount) external returns (uint256) {
        M9Approve(USDC).approve(address(zap), amount);
        return zap.zapDeposit(address(vault), USDC, amount, 0, 100, address(this));
    }

    receive() external payable {
        VM.deal(address(zap), address(zap).balance + 1);
    }
}

interface M9Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}
