// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {Currency, PoolKey} from "../../src/libraries/Types.sol";
import {PoolIdLib} from "../../src/libraries/PoolIdLib.sol";
import {MockToken, MockStateView, MockAggregator, PriceGuardHarness} from "../mocks/PriceGuardMocks.sol";

/**
 * @dev Shared fixture for PriceGuard unit, fuzz and attack suites: WETH(18)/USDC(6) pool at 2000 USDC per ETH
 *      with a Chainlink-style feed at 2000 (8 decimals) and a 1% deviation limit.
 */
abstract contract PriceGuardBase is Test {
    using PoolIdLib for PoolKey;

    MockToken internal weth;
    MockToken internal usdc;
    MockStateView internal stateView;
    MockAggregator internal ethUsdFeed;
    PriceGuardHarness internal guard;
    PoolKey internal key;

    function setUp() public virtual {
        vm.warp(10 days);
        weth = new MockToken("Wrapped Ether", "WETH", 18);
        usdc = new MockToken("USD Coin", "USDC", 6);
        stateView = new MockStateView();
        ethUsdFeed = new MockAggregator(8);
        guard = new PriceGuardHarness(stateView, address(0), address(weth), address(this));
        key = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        _setPoolUsd(key, 2000);
        ethUsdFeed.setAnswer(2000e8, block.timestamp);
    }

    /**
     * @dev Sets the pool's spot price to `usdPerEth` USDC per ETH (ETH has 18 decimals, USDC 6).
     */
    function _setPoolUsd(PoolKey memory k, uint256 usdPerEth) internal {
        stateView.setSqrtPrice(k.toId(), guard.sqrtFromRatio(usdPerEth * 10 ** 6, 10 ** 18));
    }

    function _chainlinkConfig() internal view returns (IPriceGuard.PairConfig memory config) {
        config.chainlinkFeed = address(ethUsdFeed);
        config.maxStaleness = 1 hours;
        config.minAnswer = 1000e8;
        config.maxAnswer = 5000e8;
        config.maxDeviationBps = 100;
    }

    /**
     * @dev Reads trust without caring whether the guard reverts: a revert counts as "not trusted". This is the
     *      property every consumer relies on (fail closed), independent of how the failure is reported.
     */
    function _trustedOrFalse(PoolKey memory k) internal view returns (bool trusted) {
        try guard.isPriceTrusted(k) returns (bool trusted_, uint256) {
            return trusted_;
        } catch {
            return false;
        }
    }

    function _assertTrusted() internal view {
        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
        assertTrue(trusted, "expected trusted");
        assertLe(devBps, 1000);
    }

    /**
     * @dev Asserts the pool is rejected because it deviates from a *valid* reference (a real deviation is reported,
     *      not the "no reference" sentinel).
     */
    function _assertRejectedForDeviation() internal view {
        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
        assertFalse(trusted, "expected not trusted");
        assertGt(devBps, 100, "expected a real deviation above the limit");
        assertLt(devBps, type(uint256).max, "expected a real deviation, not the sentinel");
    }

    function _assertNotTrusted() internal view {
        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
        assertFalse(trusted, "expected not trusted");
        assertEq(devBps, type(uint256).max, "expected sentinel deviation");
    }
}
