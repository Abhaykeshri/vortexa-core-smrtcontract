// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {NormalLPStrategy} from "../../src/strategies/NormalLPStrategy.sol";
import {BuyTheDipStrategy} from "../../src/strategies/BuyTheDipStrategy.sol";
import {SellThePumpStrategy} from "../../src/strategies/SellThePumpStrategy.sol";
import {Vault} from "../../src/Vault.sol";
import {DepositMode, PoolKey, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {VaultRealV4Base} from "./utils/VaultRealV4Base.sol";

contract M7StrategiesRealV4Test is VaultRealV4Base {
    uint128 internal constant DEEP_LIQUIDITY = 2e17;

    function test_normalStrategyFirstDepositUsesItsPlanOnAnErc20Pool() public {
        PoolKey memory key = _usdcWethKey();
        int24 tick = _initPool(key, 1e18, 2000e6, true);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);
        NormalLPStrategy normal = new NormalLPStrategy(shapes);
        VaultConfig memory config = _normalConfig(key, _align(tick, key.tickSpacing));
        Vault vault = _newVaultWith(config, address(normal));

        (uint256 shares,,) = _deposit(vault, alice, 200_000e6, 100 ether);

        assertGt(shares, 0);
        assertEq(vault.bands().length, 3);
        assertEq(uint256(normal.depositMode(config)), uint256(DepositMode.BothTokens));
    }

    function test_normalStrategyFirstDepositExecutesItsSwapAndRevokesAllowance() public {
        PoolKey memory key = _usdcWethKey();
        int24 tick = _initPool(key, 1e18, 2000e6, true);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY * 10);
        NormalLPStrategy normal = new NormalLPStrategy(shapes);
        VaultConfig memory config = _normalConfig(key, _align(tick, key.tickSpacing));
        Vault vault = _newVaultWith(config, address(normal));
        (uint160 beforePrice,,,) = stateView.getSlot0(_poolId(key));

        (uint256 shares,,) = _deposit(vault, alice, 300_000e6, 50 ether);

        (uint160 afterPrice,,,) = stateView.getSlot0(_poolId(key));
        assertGt(shares, 0);
        assertTrue(afterPrice != beforePrice, "first-deposit swap was not executed");
        assertEq(usdc.allowance(address(vault), address(executor)), 0, "executor allowance remains");
        assertEq(weth.allowance(address(vault), address(executor)), 0, "executor allowance remains");
    }

    function test_normalStrategyFirstDepositExecutesNativeInputSwap() public {
        PoolKey memory key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY * 10);
        NormalLPStrategy normal = new NormalLPStrategy(shapes);
        VaultConfig memory config = _normalConfig(key, _align(tick, key.tickSpacing));
        Vault vault = _newVaultWith(config, address(normal));
        (uint160 beforePrice,,,) = stateView.getSlot0(_poolId(key));

        (uint256 shares,,) = _deposit(vault, alice, 100 ether, 50_000e6);

        (uint160 afterPrice,,,) = stateView.getSlot0(_poolId(key));
        assertGt(shares, 0);
        assertTrue(afterPrice != beforePrice, "native first-deposit swap was not executed");
        assertEq(usdc.allowance(address(vault), address(executor)), 0, "executor allowance remains");
    }

    function test_buyAndSellOneSidedStrategiesDepositOnANativePool() public {
        PoolKey memory key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);

        BuyTheDipStrategy buy = new BuyTheDipStrategy(shapes);
        VaultConfig memory buyConfig = _oneSidedConfig(key, Strategy.BuyTheDip, true);
        Vault buyVault = _newVaultWith(buyConfig, address(buy));
        (uint256 buyShares,, uint256 buyUsed1) = _deposit(buyVault, alice, 0, 3_000e6);
        assertGt(buyShares, 0);
        assertGt(buyUsed1, 0);
        assertEq(uint256(buy.depositMode(buyConfig)), uint256(DepositMode.Token1Only));
        assertLe(buyVault.bands()[buyVault.bands().length - 1].tickUpper, tick);

        SellThePumpStrategy sell = new SellThePumpStrategy(shapes);
        VaultConfig memory sellConfig = _oneSidedConfig(key, Strategy.SellThePump, false);
        Vault sellVault = _newVaultWith(sellConfig, address(sell));
        (uint256 sellShares, uint256 sellUsed0,) = _deposit(sellVault, bob, 1 ether, 0);
        assertGt(sellShares, 0);
        assertGt(sellUsed0, 0);
        assertEq(uint256(sell.depositMode(sellConfig)), uint256(DepositMode.Token0Only));
        assertGt(sellVault.bands()[0].tickLower, tick);
    }

    function _normalConfig(PoolKey memory key, int24 center) private pure returns (VaultConfig memory config) {
        config.poolKey = key;
        config.strategy = Strategy.NormalLP;
        config.shapeId = 2;
        config.centerTick = center;
        config.ticksLeft = 600;
        config.ticksRight = 600;
        config.driftTicks = 100;
        config.autoRebalance = true;
        config.baseIsCurrency0 = true;
    }

    function _oneSidedConfig(PoolKey memory key, Strategy strategy_, bool below)
        private
        pure
        returns (VaultConfig memory config)
    {
        config.poolKey = key;
        config.strategy = strategy_;
        config.shapeId = 3;
        config.ticksLeft = below ? int24(600) : int24(0);
        config.ticksRight = below ? int24(0) : int24(600);
        config.trailTicks = 100;
        config.autoRebalance = true;
        config.lockOnFill = true;
        config.baseIsCurrency0 = true;
    }

    function _align(int24 tick, int24 spacing) private pure returns (int24 aligned) {
        int256 quotient = int256(tick) / int256(spacing);
        if (tick < 0 && tick % spacing != 0) --quotient;
        aligned = int24(quotient * int256(spacing));
    }
}
