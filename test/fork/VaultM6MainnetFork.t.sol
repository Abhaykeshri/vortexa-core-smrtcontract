// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SwapExecutor} from "../../src/SwapExecutor.sol";
import {Vault} from "../../src/Vault.sol";
import {IPermit2Like} from "../../src/interfaces/external/IPermit2Like.sol";
import {IPositionManagerLike} from "../../src/interfaces/external/IPositionManagerLike.sol";
import {IUniversalRouterLike} from "../../src/interfaces/external/IUniversalRouterLike.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {Band, Currency, PoolKey, RebalanceParams, VaultConfig} from "../../src/libraries/Types.sol";
import {PoolIdLib} from "../../src/libraries/PoolIdLib.sol";
import {MockFactory, MockFeeCollector} from "../mocks/VaultMocks.sol";
import {VaultMainnetForkTest} from "./VaultMainnetFork.t.sol";

interface IAllowanceLike {
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

contract VaultM6MainnetForkTest is VaultMainnetForkTest {
    using PoolIdLib for PoolKey;

    function test_mainnet_native_rebalance_burns_and_remints_real_v4_position() public {
        MockFactory factory = new MockFactory(0, 1_000, address(new MockFeeCollector(address(this))));
        SwapExecutor executor = new SwapExecutor(
            IUniversalRouterLike(configs.universalRouter), IPermit2Like(configs.permit2), factory, guard, address(0)
        );
        Vault implementation = new Vault(
            IPositionManagerLike(configs.positionManager),
            configs.stateView,
            IPermit2Like(configs.permit2),
            guard,
            shapes,
            address(executor),
            address(factory),
            configs.poolManager
        );
        VaultConfig memory cfg = _vaultConfigAroundCurrentPrice(key, poolId);
        cfg.autoRebalance = true;
        Vault rebalanceVault = Vault(payable(Clones.clone(address(implementation))));
        vm.prank(address(factory));
        rebalanceVault.initialize("Vortex M6 Mainnet", "vM6", address(strategy), cfg);
        factory.setVault(address(rebalanceVault), true);
        factory.setKeeper(address(this), true);
        _fundAndApprove(USER, rebalanceVault);

        vm.prank(USER);
        rebalanceVault.depositPair{value: IN_RANGE_ETH_AMOUNT}(IN_RANGE_ETH_AMOUNT, IN_RANGE_USDC_AMOUNT, 1, USER);
        Band[] memory oldBands = rebalanceVault.bands();
        uint256 oldTokenId = oldBands[0].tokenId;
        (, int24 tick,,) = configs.stateView.getSlot0(poolId);
        int24 center = _floorToSpacing(tick, key.tickSpacing);
        Band[] memory target = new Band[](1);
        target[0] = Band({
            tickLower: center - key.tickSpacing * 100,
            tickUpper: center + key.tickSpacing * 100,
            tokenId: 0,
            liquidity: 0
        });
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        strategy.setRebalance(true, bytes32("DRIFT"));
        strategy.setPlan(target, weights, false, false, 0, false);
        uint256 supplyBefore = rebalanceVault.totalSupply();
        vm.warp(block.timestamp + 30 minutes);

        rebalanceVault.rebalance(RebalanceParams({newCenterTick: center, maxSlippageBps: 100}));

        Band[] memory newBands = rebalanceVault.bands();
        assertEq(newBands.length, 1);
        assertGt(newBands[0].tokenId, oldTokenId);
        assertEq(IPositionManagerLike(configs.positionManager).ownerOf(newBands[0].tokenId), address(rebalanceVault));
        assertGt(newBands[0].liquidity, 0);
        assertEq(rebalanceVault.totalSupply(), supplyBefore);
        assertEq(rebalanceVault.lastRebalance(), block.timestamp);
    }

    /**
     * @notice ERC-20/ERC-20 pool (USDC/WETH 0.05%) rebalance with a real swap through the deployed Universal Router,
     *         PositionManager and Permit2: the path the in-process router double can only approximate.
     */
    function test_mainnet_erc20_pool_rebalance_with_a_real_swap() public {
        PoolKey memory wethUsdc = _wethUsdcPoolKey();
        bytes32 id = wethUsdc.toId();
        _requireInitializedPool(id, "WETH/USDC V4 pool");
        guard.setPairConfig(wethUsdc, _wethUsdcPriceConfig());
        (Vault rv, SwapExecutor executor) = _m6Vault(wethUsdc, id);
        vm.prank(USER);
        rv.depositPair(3_000e6, 1 ether, 1, USER);
        _rebalanceWithSwap(rv, executor, wethUsdc, id, true, 200e6);
    }

    /**
     * @notice Native ETH/USDC rebalance with a real ETH-to-USDC swap (ETH leaves as value, USDC returns).
     */
    function test_mainnet_native_pool_rebalance_with_a_real_swap() public {
        (Vault rv, SwapExecutor executor) = _m6Vault(key, poolId);
        vm.prank(USER);
        rv.depositPair{value: IN_RANGE_ETH_AMOUNT}(IN_RANGE_ETH_AMOUNT, IN_RANGE_USDC_AMOUNT, 1, USER);
        _rebalanceWithSwap(rv, executor, key, poolId, true, 0.05 ether);
    }

    function _rebalanceWithSwap(
        Vault rv,
        SwapExecutor executor,
        PoolKey memory poolKey,
        bytes32 id,
        bool zeroForOne,
        uint256 amountIn
    ) internal {
        int24 center = _planOneBandWithSwap(poolKey, id, zeroForOne, amountIn);
        uint256 supplyBefore = rv.totalSupply();
        uint256 oldTokenId = rv.bands()[0].tokenId;
        uint256 router0 = _balanceOf(poolKey.currency0, configs.universalRouter);
        uint256 router1 = _balanceOf(poolKey.currency1, configs.universalRouter);
        vm.warp(block.timestamp + 30 minutes);

        vm.recordLogs();
        rv.rebalance(RebalanceParams({newCenterTick: center, maxSlippageBps: 100}));
        assertTrue(_swapped(address(executor)), "the rebalance swapped through the executor");

        Band[] memory newBands = rv.bands();
        assertEq(newBands.length, 1);
        assertGt(newBands[0].tokenId, oldTokenId);
        assertEq(IPositionManagerLike(configs.positionManager).ownerOf(newBands[0].tokenId), address(rv));
        assertEq(rv.totalSupply(), supplyBefore);
        assertEq(_balanceOf(poolKey.currency0, configs.universalRouter), router0, "router kept token0");
        assertEq(_balanceOf(poolKey.currency1, configs.universalRouter), router1, "router kept token1");
        _assertClean(poolKey, address(rv), address(executor));
    }

    function _planOneBandWithSwap(PoolKey memory poolKey, bytes32 id, bool zeroForOne, uint256 amountIn)
        internal
        returns (int24 center)
    {
        (, int24 tick,,) = configs.stateView.getSlot0(id);
        center = _floorToSpacing(tick, poolKey.tickSpacing);
        Band[] memory target = new Band[](1);
        target[0] = Band({
            tickLower: center - poolKey.tickSpacing * 100,
            tickUpper: center + poolKey.tickSpacing * 100,
            tokenId: 0,
            liquidity: 0
        });
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        strategy.setRebalance(true, bytes32("DRIFT"));
        strategy.setPlan(target, weights, true, zeroForOne, amountIn, false);
    }

    function _assertClean(PoolKey memory poolKey, address rv, address executor) internal view {
        assertEq(_balanceOf(poolKey.currency0, executor), 0, "executor kept token0");
        assertEq(_balanceOf(poolKey.currency1, executor), 0, "executor kept token1");
        _assertNoStandingAllowance(Currency.unwrap(poolKey.currency0), rv, executor);
        _assertNoStandingAllowance(Currency.unwrap(poolKey.currency1), rv, executor);
    }

    function _assertNoStandingAllowance(address token, address rv, address executor) internal view {
        if (token == address(0)) return;
        (uint160 a,,) = IAllowanceLike(configs.permit2).allowance(rv, token, configs.positionManager);
        (uint160 b,,) = IAllowanceLike(configs.permit2).allowance(executor, token, configs.universalRouter);
        assertEq(uint256(a) + b, 0, "standing Permit2 allowance");
        assertEq(IERC20(token).allowance(rv, executor), 0, "standing vault approval to the executor");
        assertEq(IERC20(token).allowance(executor, configs.permit2), 0, "standing executor approval to Permit2");
    }

    function _swapped(address executor) internal view returns (bool found) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("SwapExecuted(address,(address,address,uint24,int24,address),bool,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == executor && logs[i].topics[0] == topic) found = true;
        }
    }

    function _balanceOf(Currency currency, address who) internal view returns (uint256) {
        address token = Currency.unwrap(currency);
        return token == address(0) ? who.balance : IERC20(token).balanceOf(who);
    }

    function _m6Vault(PoolKey memory poolKey, bytes32 id) internal returns (Vault rv, SwapExecutor executor) {
        MockFactory factory = new MockFactory(0, 1_000, address(new MockFeeCollector(address(this))));
        executor = new SwapExecutor(
            IUniversalRouterLike(configs.universalRouter), IPermit2Like(configs.permit2), factory, guard, address(0)
        );
        Vault implementation = new Vault(
            IPositionManagerLike(configs.positionManager),
            configs.stateView,
            IPermit2Like(configs.permit2),
            guard,
            shapes,
            address(executor),
            address(factory),
            configs.poolManager
        );
        VaultConfig memory cfg = _vaultConfigAroundCurrentPrice(poolKey, id);
        cfg.autoRebalance = true;
        rv = Vault(payable(Clones.clone(address(implementation))));
        vm.prank(address(factory));
        rv.initialize("Vortex M6 Mainnet", "vM6", address(strategy), cfg);
        factory.setVault(address(rv), true);
        factory.setKeeper(address(this), true);
        _fundAndApprove(USER, rv);
    }

    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24 result) {
        result = (tick / spacing) * spacing;
        if (tick < 0 && tick % spacing != 0) result -= spacing;
    }
}
