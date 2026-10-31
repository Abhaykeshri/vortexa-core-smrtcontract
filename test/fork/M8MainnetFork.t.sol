// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {NetworkConfig} from "../../script/NetworkConfigs.s.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {PriceGuard} from "../../src/PriceGuard.sol";
import {SwapExecutor} from "../../src/SwapExecutor.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {VaultLens} from "../../src/VaultLens.sol";

contract M8MainnetForkTest is Test {
    NetworkConfig.Configs private configs;

    function setUp() public {
        if (block.chainid != 1) vm.skip(true);
        configs = new NetworkConfig().getConfigs();
        if (
            configs.timelock.code.length == 0 || configs.vaultFactory.code.length == 0
                || configs.feeCollector.code.length == 0 || configs.vaultLens.code.length == 0
                || configs.swapExecutor.code.length == 0 || configs.vaultImplementation.code.length == 0
        ) vm.skip(true);
    }

    function test_mainnetM8GovernanceAndImmutableGraphMatchConfiguration() public view {
        VaultFactory factory = VaultFactory(configs.vaultFactory);
        TimelockController timelock = TimelockController(payable(configs.timelock));

        assertEq(factory.owner(), configs.timelock);
        assertEq(FeeCollector(payable(configs.feeCollector)).owner(), configs.timelock);
        assertEq(PriceGuard(configs.priceGuard).owner(), configs.timelock);
        assertEq(factory.implementation(), configs.vaultImplementation);
        assertEq(factory.swapExecutor(), configs.swapExecutor);
        assertEq(address(SwapExecutor(payable(configs.swapExecutor)).factory()), configs.vaultFactory);
        assertEq(address(VaultLens(configs.vaultLens).factory()), configs.vaultFactory);
        assertGe(timelock.getMinDelay(), 48 hours);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), configs.governanceSafe));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), configs.authorizedExecutor));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertEq(factory.guardian(), configs.guardianSafe);
        assertEq(FeeCollector(payable(configs.feeCollector)).recipient(), configs.treasury);
    }
}
