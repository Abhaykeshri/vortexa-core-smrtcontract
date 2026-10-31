// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script, console2} from "forge-std/Script.sol";
import {NetworkConfig} from "./NetworkConfigs.s.sol";
import {ScheduleM8Handover} from "./ScheduleM8Handover.s.sol";

/**
 * @title Execute M8 Ownership Handover
 * @notice Executes the scheduled ownership acceptances after the configured timelock delay.
 */
contract ExecuteM8Handover is Script {
    error WrongBroadcaster(address actual, address expected);

    /**
     * @notice Executes the handover, or prints the transaction the executor Safe must propose.
     * @dev A Safe executor cannot sign a forge broadcast; the script then prints the exact `executeBatch` call.
     */
    function run() external {
        NetworkConfig.Configs memory configs = new NetworkConfig().getConfigs();
        ScheduleM8Handover helper = new ScheduleM8Handover();
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = helper.actions(configs);
        if (configs.authorizedExecutor.code.length != 0) {
            console2.log("Propose from the executor Safe:", configs.authorizedExecutor);
            console2.log("to (TimelockController):", configs.timelock);
            console2.log("data:");
            console2.logBytes(
                abi.encodeCall(
                    TimelockController.executeBatch, (targets, values, payloads, bytes32(0), helper.HANDOVER_SALT())
                )
            );
            return;
        }

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        if (sender != configs.authorizedExecutor) {
            revert WrongBroadcaster(sender, configs.authorizedExecutor);
        }
        TimelockController(payable(configs.timelock))
            .executeBatch(targets, values, payloads, bytes32(0), helper.HANDOVER_SALT());
        vm.stopBroadcast();
    }
}
