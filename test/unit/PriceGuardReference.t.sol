// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {PriceGuard} from "../../src/PriceGuard.sol";
import {Currency, PoolKey} from "../../src/libraries/Types.sol";
import {MockAggregator, PriceGuardHarness} from "../mocks/PriceGuardMocks.sol";
import {PriceGuardBase} from "../utils/PriceGuardBase.sol";

/**
 * @title PriceGuard.referenceSqrtPriceX96
 * @notice The M6 reference price used for rebalance valuation and the swap floor: it must fail closed exactly when
 *         `isPriceTrusted` has no usable reference.
 */
contract PriceGuardReferenceTest is PriceGuardBase {
    function test_reference_equals_the_oracle_price() public {
        guard.setPairConfig(key, _chainlinkConfig());
        uint160 ref = guard.referenceSqrtPriceX96(key);
        assertApproxEqRel(ref, guard.sqrtFromRatio(2000e6, 1e18), 1e12, "reference is the Chainlink price");
    }

    function test_reference_for_an_unconfigured_pool_reverts() public {
        PoolKey memory other = key;
        other.fee = 500;
        vm.expectRevert(PriceGuard.NoConfig.selector);
        guard.referenceSqrtPriceX96(other);
    }

    function test_reference_from_a_stale_oracle_reverts() public {
        guard.setPairConfig(key, _chainlinkConfig());
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(PriceGuard.InvalidReference.selector);
        guard.referenceSqrtPriceX96(key);
    }

    function test_reference_while_the_sequencer_is_down_reverts() public {
        MockAggregator sequencer = new MockAggregator(0);
        sequencer.setAnswer(0, block.timestamp - 2 hours);
        PriceGuardHarness l2Guard = new PriceGuardHarness(stateView, address(sequencer), address(weth), address(this));
        l2Guard.setPairConfig(key, _chainlinkConfig());
        assertGt(l2Guard.referenceSqrtPriceX96(key), 0);
        sequencer.setAnswer(1, block.timestamp - 2 hours);
        vm.expectRevert(PriceGuard.InvalidReference.selector);
        l2Guard.referenceSqrtPriceX96(key);
    }
}
