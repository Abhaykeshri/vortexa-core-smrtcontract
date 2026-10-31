// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IV4Router} from "uni-test/v4-periphery/src/interfaces/IV4Router.sol";
import {ISwapExecutor} from "../../src/interfaces/ISwapExecutor.sol";
import {Vault} from "../../src/Vault.sol";
import {Band, PoolKey, RebalanceParams, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {M9ZapRealV4Base} from "../integration/M9ZapRealV4.t.sol";

/**
 * @title Zap lifecycle handler on real Uniswap v4
 * @notice Zaps of random size from random actors in both tokens, mixed with direct deposits, withdrawals, trends
 *         (oracle kept in sync) and keeper rebalances on a production Normal LP vault. Every zap is checked against the
 *         oracle reference price: the zapper is never credited more than it supplied, the holders before it keep their
 *         value, and a failure outside the expected set is counted.
 */
contract M9ZapLifecycleHandler is M9ZapRealV4Base {
    PoolKey internal _key;
    Vault public vault;
    address public keeper = makeAddr("keeper");
    address[] internal _actors;

    uint256 public zapCalls;
    uint256 public zaps;
    uint256 public overCredited;
    uint256 public holderLosses;
    uint256 public unexpectedFailures;
    bytes4 public lastUnexpected;
    uint256 public rebalances;

    constructor() {
        setUp();
        _key = _nativeUsdcKey();
        int24 tick = _initPool(_key, 2000e6, 1e18, false);
        _seedExternalLiquidity(_key, tick, DEEP_LIQUIDITY);
        VaultConfig memory cfg;
        cfg.poolKey = _key;
        cfg.strategy = Strategy.NormalLP;
        cfg.shapeId = 2;
        cfg.centerTick = tick / 10 * 10;
        cfg.ticksLeft = 800;
        cfg.ticksRight = 800;
        cfg.driftTicks = 300;
        cfg.autoRebalance = true;
        cfg.baseIsCurrency0 = true;
        vault = _newVaultWith(cfg, address(normal));
        factoryKeepers[keeper] = true;
        factoryFeeBps = 1_000;
        _actors.push(alice);
        _actors.push(bob);
    }

    function seed() external {
        _deposit(vault, alice, 5 ether, 10_000e6);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------------------------------------------------

    function zapIn(uint256 who, bool inputIsEth, uint256 size, uint256 slippage) external {
        zapCalls++;
        address actor = _actors[who % _actors.length];
        uint256 amount = inputIsEth ? bound(size, 0.001 ether, 8 ether) : bound(size, 2e6, 16_000e6);
        address token = inputIsEth ? address(0) : USDC_ADDR;
        uint160 ref = guard.referenceSqrtPriceX96(_key);
        uint256 supplyBefore = vault.totalSupply();
        uint256 valueBefore = valueAt(ref);
        uint256 supplied = inputIsEth ? _valueAt(amount, 0, ref) : amount;

        vm.prank(actor);
        try zap.zapDeposit{value: inputIsEth ? amount : 0}(
            address(vault), token, amount, 0, uint16(bound(slippage, 1, 100)), actor
        ) returns (
            uint256 shares
        ) {
            zaps++;
            uint256 valueAfter = valueAt(ref);
            uint256 supplyAfter = vault.totalSupply();
            if (Math.mulDiv(valueAfter, shares, supplyAfter) > supplied + 10) overCredited++;
            if (Math.mulDiv(valueAfter, supplyBefore, supplyAfter) + 10 < valueBefore) holderLosses++;
        } catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            // tiny inputs that mint nothing, and a swap that misses the caller's oracle floor (an earlier zap or
            // trade can leave the pool off the oracle by more than a 1 bps tolerance)
            if (
                sel != Vault.ZeroLiquidity.selector && sel != Vault.ZeroValue.selector
                    && sel != ISwapExecutor.InsufficientOutput.selector && sel != IV4Router.V4TooLittleReceived.selector
            ) {
                unexpectedFailures++;
                lastUnexpected = sel;
            }
        }
    }

    function depositPair(uint256 who, uint256 eth, uint256 usdcAmount) external {
        address actor = _actors[who % _actors.length];
        eth = bound(eth, 0.01 ether, 5 ether);
        usdcAmount = bound(usdcAmount, 20e6, 10_000e6);
        vm.prank(actor);
        try vault.depositPair{value: eth}(eth, usdcAmount, 0, actor) returns (uint256, uint256, uint256) {} catch {}
    }

    function withdraw(uint256 who, uint256 fraction) external {
        address actor = _actors[who % _actors.length];
        uint256 shares = Math.mulDiv(vault.balanceOf(actor), bound(fraction, 1, 10_000), 10_000);
        if (shares == 0) return;
        vm.prank(actor);
        vault.withdrawPair(shares, 0, 0, actor); // exits must never revert
    }

    function trend(bool down, uint256 size) external {
        if (down) _swap(attacker, _key, true, bound(size, 0.1 ether, 6 ether));
        else _swap(attacker, _key, false, bound(size, 200e6, 12_000e6));
        _syncOracleToNativePool(_key);
    }

    function rebalance() external {
        vm.warp(block.timestamp + 31 minutes);
        _syncOracleToNativePool(_key);
        (, int24 tick,,) = stateView.getSlot0(_poolId(_key));
        vm.prank(keeper);
        try vault.rebalance(RebalanceParams({newCenterTick: tick / 10 * 10, maxSlippageBps: 100})) {
            rebalances++;
        } catch {}
    }

    // ------------------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------------------

    /**
     * Vault value at `ref`: band principal at that price, idle balances, pending fees net of the protocol fee.
     */
    function valueAt(uint160 ref) public view returns (uint256) {
        uint256 amount0 = address(vault).balance;
        uint256 amount1 = usdc.balanceOf(address(vault));
        Band[] memory b = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            (uint128 liq, uint256 last0, uint256 last1) = stateView.getPositionInfo(
                _poolId(_key), address(posm), b[i].tickLower, b[i].tickUpper, bytes32(b[i].tokenId)
            );
            (uint256 now0, uint256 now1) = stateView.getFeeGrowthInside(_poolId(_key), b[i].tickLower, b[i].tickUpper);
            uint256 f0;
            uint256 f1;
            unchecked {
                f0 = Math.mulDiv(liq, now0 - last0, 1 << 128);
                f1 = Math.mulDiv(liq, now1 - last1, 1 << 128);
            }
            (uint256 x, uint256 y) = LiquidityMath.amountsForLiquidity(
                ref,
                SqrtPriceMath.getSqrtPriceAtTick(b[i].tickLower),
                SqrtPriceMath.getSqrtPriceAtTick(b[i].tickUpper),
                b[i].liquidity
            );
            amount0 += x + f0 - f0 * factoryFeeBps / 10_000;
            amount1 += y + f1 - f1 * factoryFeeBps / 10_000;
        }
        return _valueAt(amount0, amount1, ref);
    }

    function zapAddress() external view returns (address) {
        return address(zap);
    }

    function executorAddress() external view returns (address) {
        return address(executor);
    }

    function usdcBalance(address who) external view returns (uint256) {
        return usdc.balanceOf(who);
    }

    function usdcAllowance(address owner, address spender) external view returns (uint256) {
        return usdc.allowance(owner, spender);
    }

    function _valueAt(uint256 a0, uint256 a1, uint160 sp) internal pure returns (uint256) {
        return Math.mulDiv(a0, Math.mulDiv(sp, sp, 1 << 96), 1 << 96) + a1;
    }
}

/**
 * forge-config: default.invariant.runs = 128
 * forge-config: default.invariant.depth = 48
 * forge-config: ci.invariant.runs = 128
 * forge-config: ci.invariant.depth = 48
 */
contract M9ZapLifecycleInvariantTest is Test {
    M9ZapLifecycleHandler internal handler;

    function setUp() public {
        handler = new M9ZapLifecycleHandler();
        handler.seed();
        bytes4[] memory s = new bytes4[](6);
        s[0] = M9ZapLifecycleHandler.zapIn.selector;
        s[1] = M9ZapLifecycleHandler.zapIn.selector;
        s[2] = M9ZapLifecycleHandler.depositPair.selector;
        s[3] = M9ZapLifecycleHandler.withdraw.selector;
        s[4] = M9ZapLifecycleHandler.trend.selector;
        s[5] = M9ZapLifecycleHandler.rebalance.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: s}));
        targetContract(address(handler));
    }

    /**
     * Sanity: the handler really zaps, and every zap can succeed in this pool.
     */
    function test_handler_zaps_both_tokens() public {
        handler.zapIn(0, true, 2 ether, 50);
        handler.zapIn(1, false, 5_000e6, 50);
        require(handler.zaps() == 2, "both zaps succeeded");
        invariant_zap_is_fair_and_keeps_nothing();
    }

    /**
     * The campaign must exercise the success path: most zaps clear their floor, so a broken Zap that reverts every
     * call into the allowlisted errors cannot pass silently.
     */
    function afterInvariant() public view {
        require(handler.zaps() * 2 >= handler.zapCalls(), "most zaps must succeed");
    }

    function invariant_zap_is_fair_and_keeps_nothing() public view {
        require(handler.overCredited() == 0, "a zapper was credited more than it supplied");
        require(handler.holderLosses() == 0, "a zap cost the existing holders value");
        require(handler.unexpectedFailures() == 0, "a zap failed for an unexpected reason");
        address zapAddr = handler.zapAddress();
        require(zapAddr.balance == 0, "the Zap kept ETH");
        require(handler.usdcBalance(zapAddr) == 0, "the Zap kept USDC");
        require(handler.usdcAllowance(zapAddr, address(handler.vault())) == 0, "standing vault allowance");
        require(handler.usdcAllowance(zapAddr, handler.executorAddress()) == 0, "standing executor allowance");
    }
}
