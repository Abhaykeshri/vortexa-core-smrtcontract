// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {NetworkConfig} from "./NetworkConfigs.s.sol";

/**
 * @title PriceGuard Deployment Script
 * @notice Deploys PriceGuard from the chain-selected `NetworkConfig` values.
 * @dev This script does not broadcast by itself. Run with Foundry broadcasting flags only when intentionally deploying.
 */
contract DeployPriceGuard is Script {
    /**
     * @notice Deployment owner is not configured.
     */
    error MissingDeploymentOwner();

    /**
     * @notice Reads the current network config and deploys PriceGuard.
     * @dev The caller (the deployer) becomes the temporary initial owner, because the network config carries no
     *      owner address. The deployer is expected to call `transferOwnership(timelock)` afterwards and the
     *      timelock must call `acceptOwnership()` before the deployment is considered complete.
     * @return guard Newly deployed PriceGuard instance.
     * @return configs Network configuration used for deployment.
     */
    function run() external returns (PriceGuard guard, NetworkConfig.Configs memory configs) {
        NetworkConfig networkConfig = new NetworkConfig();
        configs = networkConfig.getConfigs();
        configs.deploymentOwner = msg.sender;

        guard = deploy(configs);
    }

    /**
     * @notice Deploys PriceGuard using a provided config struct.
     * @param configs Network configuration containing constructor dependencies.
     * @return guard Newly deployed PriceGuard instance.
     */
    function deploy(NetworkConfig.Configs memory configs) public returns (PriceGuard guard) {
        if (configs.deploymentOwner == address(0)) revert MissingDeploymentOwner();

        guard = new PriceGuard(
            configs.stateView, configs.sequencerUptimeFeed, configs.nativeWrapper, configs.deploymentOwner
        );
    }
}
