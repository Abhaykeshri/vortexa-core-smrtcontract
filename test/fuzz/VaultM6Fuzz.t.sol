// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IVault} from "../../src/interfaces/IVault.sol";
import {RebalanceParams} from "../../src/libraries/Types.sol";
import {VaultM6Test} from "../unit/VaultM6.t.sol";

contract VaultM6FuzzTest is VaultM6Test {
    function testFuzz_center_drift_above_cap_reverts_atomically(int24 proposed) public {
        vm.assume(proposed > 200 || proposed < -200);
        vm.prank(keeper);
        vm.expectRevert(IVault.CenterTooFar.selector);
        vault.rebalance(RebalanceParams({newCenterTick: proposed, maxSlippageBps: 100}));
        assertEq(positionManager.ownerOf(1), address(vault));
    }

    function testFuzz_slippage_above_hard_cap_reverts(uint16 slippage) public {
        vm.assume(slippage > 100);
        vm.prank(keeper);
        vm.expectRevert(IVault.SlippageTooHigh.selector);
        vault.rebalance(RebalanceParams({newCenterTick: 0, maxSlippageBps: slippage}));
        assertEq(vault.lastRebalance(), 0);
    }
}
