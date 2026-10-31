// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {SwapExecutor} from "../src/SwapExecutor.sol";
import {Vault} from "../src/Vault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {Zap} from "../src/Zap.sol";
import {Strategy} from "../src/libraries/Types.sol";
import {NetworkConfig} from "./NetworkConfigs.s.sol";
import {PostDeployM8Check} from "./PostDeployM8Check.s.sol";

/**
 * @title M9 Post-Deployment Checks
 * @notice Read-only verification of M8 governance plus the complete immutable M9 dependency graph.
 */
contract PostDeployM9Check is PostDeployM8Check {
    /**
     * @notice Checks the chain-selected configuration.
     */
    function run() external override returns (bool) {
        return check(new NetworkConfig().getConfigs());
    }

    /**
     * @notice Verifies one explicit finalized deployment configuration without changing target state.
     */
    function check(NetworkConfig.Configs memory configs) public view override returns (bool) {
        super.check(configs);
        _checkM9(configs.chainId == block.chainid, "CHAIN_ID");
        _checkM9(configs.zap.code.length != 0, "ZAP_CODE");
        _checkM9(configs.swapExecutor.code.length != 0, "EXECUTOR_CODE");
        _checkM9(configs.vaultImplementation.code.length != 0, "VAULT_CODE");

        Zap zap = Zap(payable(configs.zap));
        SwapExecutor executor = SwapExecutor(payable(configs.swapExecutor));
        VaultFactory factory = VaultFactory(configs.vaultFactory);
        Vault implementation = Vault(payable(configs.vaultImplementation));

        _checkM9(executor.zap() == configs.zap, "EXECUTOR_ZAP");
        _checkM9(address(zap.factory()) == configs.vaultFactory, "ZAP_FACTORY");
        _checkM9(address(zap.executor()) == configs.swapExecutor, "ZAP_EXECUTOR");
        _checkM9(address(executor.factory()) == configs.vaultFactory, "EXECUTOR_FACTORY");
        _checkM9(factory.swapExecutor() == configs.swapExecutor, "FACTORY_EXECUTOR");
        _checkM9(implementation.factory() == configs.vaultFactory, "VAULT_FACTORY");
        _checkM9(implementation.swapExecutor() == configs.swapExecutor, "VAULT_EXECUTOR");
        _checkM9(address(executor.priceGuard()) == configs.priceGuard, "EXECUTOR_GUARD");
        _checkM9(address(implementation.priceGuard()) == configs.priceGuard, "VAULT_GUARD");
        _checkM9(address(zap.normalStrategy()) == configs.normalStrategy, "ZAP_NORMAL");
        _checkM9(address(zap.buyTheDipStrategy()) == configs.dipStrategy, "ZAP_DIP");
        _checkM9(address(zap.sellThePumpStrategy()) == configs.pumpStrategy, "ZAP_PUMP");
        _checkM9(address(factory.strategyOf(Strategy.NormalLP)) == configs.normalStrategy, "FACTORY_NORMAL");
        _checkM9(address(factory.strategyOf(Strategy.BuyTheDip)) == configs.dipStrategy, "FACTORY_DIP");
        _checkM9(address(factory.strategyOf(Strategy.SellThePump)) == configs.pumpStrategy, "FACTORY_PUMP");
        return true;
    }

    function _checkM9(bool success, bytes32 name) private pure {
        if (!success) revert CheckFailed(name);
    }
}
