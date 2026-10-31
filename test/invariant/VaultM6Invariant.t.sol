// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/Vault.sol";
import {Band, RebalanceParams} from "../../src/libraries/Types.sol";
import {MockFactory, MockPositionManager, MockStrategy} from "../mocks/VaultMocks.sol";
import {VaultM6Test} from "../unit/VaultM6.t.sol";

contract VaultM6Handler is Test {
    Vault internal immutable vault;
    MockStrategy internal immutable strategy;

    constructor(Vault vault_, MockStrategy strategy_) {
        vault = vault_;
        strategy = strategy_;
    }

    function rebalance(int24 proposed, uint16 slippage) external {
        proposed = int24(bound(int256(proposed), -200, 200));
        slippage = uint16(bound(slippage, 0, 100));
        Band[] memory target = new Band[](1);
        target[0] = Band({tickLower: -60, tickUpper: 0, tokenId: 0, liquidity: 0});
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        strategy.setPlan(target, weights, false, false, 0, false);
        vm.warp(block.timestamp + 30 minutes);
        vault.rebalance(RebalanceParams({newCenterTick: proposed, maxSlippageBps: slippage}));
    }
}

contract VaultM6InvariantTest is VaultM6Test {
    VaultM6Handler internal handler;
    uint256 internal supplyBefore;

    function setUp() public override {
        super.setUp();
        handler = new VaultM6Handler(vault, strategy);
        factory.setKeeper(address(handler), true);
        supplyBefore = vault.totalSupply();
        targetContract(address(handler));
    }

    function invariant_every_recorded_position_is_owned_by_the_vault() public view {
        Band[] memory active = vault.bands();
        for (uint256 i; i < active.length; ++i) {
            assertEq(positionManager.ownerOf(active[i].tokenId), address(vault));
        }
    }

    function invariant_rebalance_never_changes_share_supply() public view {
        assertEq(vault.totalSupply(), supplyBefore);
    }
}
