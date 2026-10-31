// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script, console2} from "forge-std/Script.sol";
import {NetworkConfig} from "./NetworkConfigs.s.sol";

/**
 * @title Schedule M8 Ownership Handover
 * @notice Schedules acceptance of VaultFactory, FeeCollector and PriceGuard ownership by the M8 timelock.
 */
contract ScheduleM8Handover is Script {
    bytes32 public constant HANDOVER_SALT = keccak256("VORTEXA_M8_OWNERSHIP_HANDOVER_V1");

    error MissingDeploymentAddress();
    error WrongBroadcaster(address actual, address expected);

    /**
     * @notice Schedules the handover, or prints the transaction the governance Safe must propose.
     * @dev On mainnet the proposer is a Safe (enforced by `DeployM8`), which cannot sign a forge broadcast; the
     *      script then prints the exact `scheduleBatch` call for the Safe owners instead of failing. An EOA proposer
     *      (testnets) broadcasts directly.
     */
    function run() external returns (bytes32 operationId) {
        NetworkConfig.Configs memory configs = new NetworkConfig().getConfigs();
        _validate(configs);
        (address target, bytes memory data, bytes32 id) = scheduleTransaction(configs);
        operationId = id;
        if (configs.governanceSafe.code.length != 0) {
            console2.log("Propose from the governance Safe:", configs.governanceSafe);
            console2.log("to (TimelockController):", target);
            console2.log("data:");
            console2.logBytes(data);
            console2.log("operation id:");
            console2.logBytes32(operationId);
            return operationId;
        }

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        if (sender != configs.governanceSafe) revert WrongBroadcaster(sender, configs.governanceSafe);
        operationId = schedule(configs);
        vm.stopBroadcast();
    }

    /**
     * @notice The single timelock call that schedules the handover batch, and its operation id.
     * @dev Uses the timelock's current minimum delay, exactly like `schedule`.
     */
    function scheduleTransaction(NetworkConfig.Configs memory configs)
        public
        view
        returns (address target, bytes memory data, bytes32 operationId)
    {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = actions(configs);
        TimelockController timelock = TimelockController(payable(configs.timelock));
        target = configs.timelock;
        data = abi.encodeCall(
            TimelockController.scheduleBatch,
            (targets, values, payloads, bytes32(0), HANDOVER_SALT, timelock.getMinDelay())
        );
        operationId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), HANDOVER_SALT);
    }

    function schedule(NetworkConfig.Configs memory configs) public returns (bytes32 operationId) {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = actions(configs);
        TimelockController timelock = TimelockController(payable(configs.timelock));
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), HANDOVER_SALT, timelock.getMinDelay());
        return timelock.hashOperationBatch(targets, values, payloads, bytes32(0), HANDOVER_SALT);
    }

    function actions(NetworkConfig.Configs memory configs)
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](3);
        targets[0] = configs.vaultFactory;
        targets[1] = configs.feeCollector;
        targets[2] = configs.priceGuard;
        values = new uint256[](3);
        payloads = new bytes[](3);
        bytes memory acceptOwnership = abi.encodeWithSignature("acceptOwnership()");
        payloads[0] = acceptOwnership;
        payloads[1] = acceptOwnership;
        payloads[2] = acceptOwnership;
    }

    function _validate(NetworkConfig.Configs memory configs) private view {
        if (
            configs.timelock.code.length == 0 || configs.vaultFactory.code.length == 0
                || configs.feeCollector.code.length == 0 || configs.priceGuard.code.length == 0
        ) revert MissingDeploymentAddress();
    }
}
