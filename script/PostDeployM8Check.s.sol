// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script} from "forge-std/Script.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {SwapExecutor} from "../src/SwapExecutor.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {VaultLens} from "../src/VaultLens.sol";
import {PoolIdLib} from "../src/libraries/PoolIdLib.sol";
import {Strategy} from "../src/libraries/Types.sol";
import {NetworkConfig} from "./NetworkConfigs.s.sol";

/**
 * @title M8 Post-Deployment Checks
 * @notice Read-only verification of the finalized M8 governance and immutable dependency graph.
 */
contract PostDeployM8Check is Script {
    error CheckFailed(bytes32 check);

    function run() external virtual returns (bool) {
        NetworkConfig.Configs memory configs = new NetworkConfig().getConfigs();
        return check(configs);
    }

    /**
     * @notice Verifies one explicit configuration without changing target state.
     */
    function check(NetworkConfig.Configs memory configs) public view virtual returns (bool) {
        TimelockController timelock = TimelockController(payable(configs.timelock));
        VaultFactory factory = VaultFactory(configs.vaultFactory);

        _check(configs.timelock.code.length != 0, "TIMELOCK_CODE");
        _check(configs.vaultFactory.code.length != 0, "FACTORY_CODE");
        _check(configs.feeCollector.code.length != 0, "COLLECTOR_CODE");
        _check(configs.vaultLens.code.length != 0, "LENS_CODE");
        _check(factory.owner() == configs.timelock, "FACTORY_OWNER");
        _check(FeeCollector(payable(configs.feeCollector)).owner() == configs.timelock, "COLLECTOR_OWNER");
        _check(PriceGuard(configs.priceGuard).owner() == configs.timelock, "GUARD_OWNER");
        _check(FeeCollector(payable(configs.feeCollector)).recipient() == configs.treasury, "TREASURY");
        _check(factory.implementation() == configs.vaultImplementation, "IMPLEMENTATION");
        _check(factory.swapExecutor() == configs.swapExecutor, "FACTORY_EXECUTOR");
        _check(address(factory.stateView()) == address(configs.stateView), "FACTORY_STATE_VIEW");
        _check(address(factory.priceGuard()) == configs.priceGuard, "FACTORY_GUARD");
        _check(address(factory.shapes()) == configs.shapeLibrary, "FACTORY_SHAPES");
        _check(
            address(SwapExecutor(payable(configs.swapExecutor)).factory()) == configs.vaultFactory, "EXECUTOR_FACTORY"
        );
        _check(
            address(SwapExecutor(payable(configs.swapExecutor)).priceGuard()) == configs.priceGuard, "EXECUTOR_GUARD"
        );
        _check(address(VaultLens(configs.vaultLens).factory()) == configs.vaultFactory, "LENS_FACTORY");
        _check(address(VaultLens(configs.vaultLens).stateView()) == address(configs.stateView), "LENS_STATE_VIEW");
        _check(factory.guardian() == configs.guardianSafe, "GUARDIAN");
        _check(factory.feeCollector() == configs.feeCollector, "FACTORY_COLLECTOR");
        _check(factory.protocolFeeBps() == configs.initialProtocolFeeBps, "PROTOCOL_FEE");
        _check(factory.maxProtocolFeeBps() == configs.initialMaxProtocolFeeBps, "PROTOCOL_FEE_CAP");
        if (configs.normalStrategy != address(0)) {
            _check(address(factory.strategyOf(Strategy.NormalLP)) == configs.normalStrategy, "NORMAL_STRATEGY");
            _check(address(factory.strategyOf(Strategy.BuyTheDip)) == configs.dipStrategy, "DIP_STRATEGY");
            _check(address(factory.strategyOf(Strategy.SellThePump)) == configs.pumpStrategy, "PUMP_STRATEGY");
        }
        _check(timelock.getMinDelay() == configs.timelockDelay, "TIMELOCK_DELAY");
        _check(timelock.hasRole(timelock.PROPOSER_ROLE(), configs.governanceSafe), "PROPOSER");
        _check(timelock.hasRole(timelock.EXECUTOR_ROLE(), configs.authorizedExecutor), "EXECUTOR");
        _check(!timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), "OPEN_EXECUTION");
        _checkDeployerHasNoRole(configs, timelock, factory);
        _checkPendingOwnersCleared(configs, factory);
        if (configs.ethUsdcMaxDepositCap != 0) {
            (bool allowed, bool baseIsCurrency0, uint256 maxDepositCap) =
                factory.poolRule(PoolIdLib.toId(configs.ethUsdcPoolKey));
            _check(allowed && baseIsCurrency0 && maxDepositCap == configs.ethUsdcMaxDepositCap, "ETH_USDC_RULE");
        }
        return true;
    }

    /**
     * @notice Guide 10.4: after deployment the deployer holds no role anywhere.
     * @dev The deployer address must be recorded in the configuration (an unset value fails instead of skipping the
     *      check). Until the timelock accepted ownership the deployer owned the factory, collector and PriceGuard, so
     *      a role it granted itself in that window must not survive.
     */
    function _checkDeployerHasNoRole(
        NetworkConfig.Configs memory configs,
        TimelockController timelock,
        VaultFactory factory
    ) private view {
        address deployer = configs.deploymentOwner;
        _check(deployer != address(0), "DEPLOYER_UNSET");
        _check(!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer), "DEPLOYER_ADMIN");
        _check(!timelock.hasRole(timelock.PROPOSER_ROLE(), deployer), "DEPLOYER_PROPOSER");
        _check(!timelock.hasRole(timelock.CANCELLER_ROLE(), deployer), "DEPLOYER_CANCELLER");
        _check(!timelock.hasRole(timelock.EXECUTOR_ROLE(), deployer), "DEPLOYER_EXECUTOR");
        _check(!factory.isKeeper(deployer), "DEPLOYER_KEEPER");
        _check(factory.guardian() != deployer, "DEPLOYER_GUARDIAN");
        _check(FeeCollector(payable(configs.feeCollector)).recipient() != deployer, "DEPLOYER_TREASURY");
    }

    /**
     * @notice No further ownership transfer is pending on any timelocked contract.
     * @dev A pending owner left behind (for example re-nominated by the deployer before acceptance) could take
     *      ownership later without the timelock.
     */
    function _checkPendingOwnersCleared(NetworkConfig.Configs memory configs, VaultFactory factory) private view {
        _check(factory.pendingOwner() == address(0), "FACTORY_PENDING_OWNER");
        _check(FeeCollector(payable(configs.feeCollector)).pendingOwner() == address(0), "COLLECTOR_PENDING_OWNER");
        _check(PriceGuard(configs.priceGuard).pendingOwner() == address(0), "GUARD_PENDING_OWNER");
    }

    function _check(bool success, bytes32 name) private pure {
        if (!success) revert CheckFailed(name);
    }
}
