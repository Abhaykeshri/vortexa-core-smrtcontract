// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {IStateViewLike} from "../../src/interfaces/external/IStateViewLike.sol";
import {PriceGuard} from "../../src/PriceGuard.sol";
import {Currency, PoolKey} from "../../src/libraries/Types.sol";
import {PoolIdLib} from "../../src/libraries/PoolIdLib.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {PriceGuardBase} from "../utils/PriceGuardBase.sol";
import {MockAggregator, MockTwapPool, MockStateView, PriceGuardHarness} from "../mocks/PriceGuardMocks.sol";

/**
 * @dev A reference contract that is also the guard's owner and tries to reconfigure ANOTHER pool from inside the
 *      guard's own validation call. Access control would let it through, so only the STATICCALL context protects
 *      the guard. It performs no storage writes itself, because those would fail for the same static reason.
 */
contract ReentrantOwnerFeed {
    PriceGuard public guard;
    PoolKey internal _mainKey;
    PoolKey internal _victimKey;
    IPriceGuard.PairConfig internal _mainConfig;
    IPriceGuard.PairConfig internal _victimConfig;

    function arm(
        PriceGuard guard_,
        PoolKey calldata mainKey,
        IPriceGuard.PairConfig calldata mainConfig,
        PoolKey calldata victimKey,
        IPriceGuard.PairConfig calldata victimConfig
    ) external {
        guard = guard_;
        _mainKey = mainKey;
        _mainConfig = mainConfig;
        _victimKey = victimKey;
        _victimConfig = victimConfig;
    }

    function configure() external {
        guard.setPairConfig(_mainKey, _mainConfig);
    }

    function decimals() external returns (uint8) {
        _reenter();
        return 8;
    }

    function latestRoundData() external returns (uint80, int256, uint256, uint256, uint80) {
        _reenter();
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }

    function _reenter() internal {
        // Swallow failures so the outer call proceeds, then the test checks whether the reentrant call took effect.
        // A call that violates the static context burns all gas forwarded to it, so cap what we forward.
        try guard.setPairConfig{gas: 400_000}(_victimKey, _victimConfig) {} catch {}
        try guard.transferOwnership{gas: 100_000}(address(0xBAD)) {} catch {}
    }
}

/**
 * @dev Scenario tests drawn from the developer guide's attack catalogue (section 12.4), restricted to the oracle
 *      layer. Each test states the attack, what the attacker controls, and the expected outcome.
 */
contract PriceGuardAttacksTest is PriceGuardBase {
    using PoolIdLib for PoolKey;

    int24 internal constant BASE_TICK = -200_311; // about 2000 USDC per ETH in raw units

    // ------------------------------------------------------------------------------------------------------------
    // Price manipulation
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Attack: flash-swap the pool price beyond tolerance, then deposit. Expected: PriceUntrusted upstream,
     *      i.e. isPriceTrusted is false, for every magnitude and both directions.
     */
    function test_flash_manipulation_beyond_tolerance_is_never_trusted() public {
        guard.setPairConfig(key, _chainlinkConfig());
        uint32[6] memory upMoves = [uint32(150), 200, 500, 1000, 10_000, 100_000];
        for (uint256 i; i < upMoves.length; ++i) {
            stateView.setSqrtPrice(
                key.toId(), guard.sqrtFromRatio(2000e6 * (10_000 + uint256(upMoves[i])) / 10_000, 1e18)
            );
            (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
            assertFalse(trusted, "upward manipulation must be rejected");
            assertGt(devBps, 100);
        }
        uint16[4] memory downMoves = [uint16(150), 500, 5000, 9900];
        for (uint256 i; i < downMoves.length; ++i) {
            stateView.setSqrtPrice(
                key.toId(), guard.sqrtFromRatio(2000e6 * (10_000 - uint256(downMoves[i])) / 10_000, 1e18)
            );
            (bool trusted,) = guard.isPriceTrusted(key);
            assertFalse(trusted, "downward manipulation must be rejected");
        }
    }

    /**
     * @dev Attack: move the price by exactly the allowed tolerance. Expected: accepted, with the reported
     *      deviation never above the configured maximum. This is the documented residual risk.
     */
    function test_manipulation_within_tolerance_is_accepted_but_bounded() public {
        guard.setPairConfig(key, _chainlinkConfig());
        stateView.setSqrtPrice(key.toId(), guard.sqrtFromRatio(2000e6 * 10_100 / 10_000, 1e18));
        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
        assertTrue(trusted);
        assertLe(devBps, 100);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Oracle failure and staleness
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Attack: the market moves while the oracle is stale. Expected: untrusted whether or not the pool still
     *      agrees with the stale answer, and trusted again only after a fresh agreeing update.
     */
    function test_stale_oracle_blocks_trust_regardless_of_pool_agreement() public {
        guard.setPairConfig(key, _chainlinkConfig());
        _assertTrusted();

        vm.warp(block.timestamp + 2 hours); // feed not updated
        _assertNotTrusted(); // pool unchanged and "agreeing", but the reference is stale

        _setPoolUsd(key, 2600); // market moved 30%
        _assertNotTrusted();

        ethUsdFeed.setAnswer(2600e8, block.timestamp); // feed catches up
        _assertTrusted();
    }

    function test_zero_negative_and_future_answers_are_never_trusted() public {
        guard.setPairConfig(key, _chainlinkConfig());
        int256[4] memory bad = [int256(0), int256(-1), int256(-2000e8), type(int256).min];
        for (uint256 i; i < bad.length; ++i) {
            ethUsdFeed.setAnswer(bad[i], block.timestamp);
            _assertNotTrusted();
        }
        ethUsdFeed.setAnswer(2000e8, block.timestamp + 1 days);
        _assertNotTrusted();
    }

    /**
     * @dev Attack: during a crash a feed clamps at its built-in minimum while the real price keeps falling, so a
     *      pool pushed to the clamp value would look "trusted". Expected: the owner's minAnswer must sit strictly
     *      above the feed's own clamp, and then the clamped answer is rejected.
     */
    function test_clamped_feed_answer_is_rejected_when_min_answer_sits_above_the_clamp() public {
        guard.setPairConfig(key, _chainlinkConfig()); // minAnswer = 1000e8
        uint256 feedClampsAt = 900e8; // the aggregator's internal floor, below our minAnswer
        ethUsdFeed.setAnswer(int256(feedClampsAt), block.timestamp);
        _setPoolUsd(key, 900); // attacker pushes the pool to the clamp value
        _assertNotTrusted();
    }

    // ------------------------------------------------------------------------------------------------------------
    // TWAP economics
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Attack: spike a V3 pool by 953 ticks (about 10%) for one 12 second block to drag the fallback TWAP.
     *      Expected: the mean tick moves by floor(953 * 12 / window), so a longer window makes the same spike
     *      far cheaper to ignore. The V4 spot, spiked by the full amount, is rejected.
     */
    function test_twap_manipulation_cost_scales_with_window() public {
        MockTwapPool pool = new MockTwapPool(address(weth), address(usdc));
        pool.setMeanTick(BASE_TICK);
        pool.setSpike(953, 12);
        stateView.setSqrtPrice(key.toId(), SqrtPriceMath.getSqrtPriceAtTick(BASE_TICK));

        uint256[3] memory windows = [uint256(600), 1800, 86_400];
        uint256[3] memory expectedTickShift = [uint256(19), 6, 0];
        uint256[3] memory observedDeviation;
        for (uint256 i; i < windows.length; ++i) {
            IPriceGuard.PairConfig memory config;
            config.v3Pool = address(pool);
            config.twapWindow = uint32(windows[i]);
            config.maxDeviationBps = 1000;
            // configuration happens before the spike so the initial check sees the clean price
            pool.setSpike(0, 0);
            guard.setPairConfig(key, config);
            pool.setSpike(953, 12);

            (, uint256 devBps) = guard.isPriceTrusted(key);
            observedDeviation[i] = devBps;
            assertApproxEqAbs(devBps, expectedTickShift[i], 1, "TWAP shift must equal floor(spike * seconds / window)");
        }
        assertGt(observedDeviation[0], observedDeviation[1]);
        assertGt(observedDeviation[1], observedDeviation[2]);

        // The attacker also moves the V4 spot by the full spike: nowhere near the barely-moved reference.
        IPriceGuard.PairConfig memory tight;
        tight.v3Pool = address(pool);
        tight.twapWindow = 600;
        tight.maxDeviationBps = 100;
        pool.setSpike(0, 0);
        guard.setPairConfig(key, tight);
        pool.setSpike(953, 12);
        stateView.setSqrtPrice(key.toId(), SqrtPriceMath.getSqrtPriceAtTick(BASE_TICK + 953));
        (bool trusted,) = guard.isPriceTrusted(key);
        assertFalse(trusted, "a 10% spot spike is outside tolerance even with a 10 minute TWAP");
    }

    /**
     * @dev KNOWN ISSUE (guide 12.4 "Thin v3 fallback manipulated", mitigated by owner pool selection): while
     *      Chainlink is unavailable the guard falls back to the V3 TWAP, and a V3 pool manipulated for the whole
     *      window agrees with a manipulated V4 pool. A fresh Chainlink answer immediately closes the hole.
     */
    function test_known_issue_fallback_can_be_fooled_only_while_chainlink_is_down() public {
        MockTwapPool pool = new MockTwapPool(address(weth), address(usdc));
        pool.setMeanTick(BASE_TICK);
        stateView.setSqrtPrice(key.toId(), SqrtPriceMath.getSqrtPriceAtTick(BASE_TICK));

        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.v3Pool = address(pool);
        config.twapWindow = 1800;
        config.maxDeviationBps = 100;
        guard.setPairConfig(key, config);
        _assertTrusted();

        // Attacker sustains +30% in both the thin V3 pool and the V4 pool.
        pool.setMeanTick(BASE_TICK + 2624);
        stateView.setSqrtPrice(key.toId(), SqrtPriceMath.getSqrtPriceAtTick(BASE_TICK + 2624));

        _assertRejectedForDeviation(); // fresh Chainlink at 2000 disagrees: it is never overridden by V3

        vm.warp(block.timestamp + 2 hours); // Chainlink goes stale
        (bool trusted,) = guard.isPriceTrusted(key);
        assertTrue(trusted, "documented residual risk: fallback agrees with the manipulated pool");

        ethUsdFeed.setAnswer(2000e8, block.timestamp); // Chainlink recovers
        _assertRejectedForDeviation();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Documented limitations
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev A single USD feed treats the quote token as exactly one dollar. A depeg inside the tolerance is not
     *      detected; beyond it the pool "looks" manipulated and trust is withdrawn (fail closed).
     */
    function test_stablecoin_depeg_is_only_noticed_beyond_the_tolerance() public {
        guard.setPairConfig(key, _chainlinkConfig());

        _setPoolUsd(key, 2010); // USDC at 0.995: ETH costs 2010.05 USDC
        _assertTrusted();

        _setPoolUsd(key, 2041); // USDC at 0.98
        _assertRejectedForDeviation();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Governance: compromised or racing owners
    // ------------------------------------------------------------------------------------------------------------

    function test_compromised_owner_is_bounded_by_the_hard_caps() public {
        IPriceGuard.PairConfig memory config = _chainlinkConfig();

        config.maxDeviationBps = 1001;
        vm.expectRevert(PriceGuard.InvalidDeviation.selector);
        guard.setPairConfig(key, config);

        config = _chainlinkConfig();
        config.maxDeviationBps = type(uint16).max;
        vm.expectRevert(PriceGuard.InvalidDeviation.selector);
        guard.setPairConfig(key, config);

        // Cannot loosen a feed that disagrees with the live pool even with the maximum tolerance.
        config = _chainlinkConfig();
        config.maxDeviationBps = 1000;
        ethUsdFeed.setAnswer(2400e8, block.timestamp); // 20% away from the pool at 2000
        vm.expectRevert(PriceGuard.InvalidInitialPrice.selector);
        guard.setPairConfig(key, config);
    }

    /**
     * @dev The owner (timelock) remains trusted: it can bless any oracle that agrees with the pool, including a
     *      manipulated one. The control for this is the timelock delay, not this contract.
     */
    function test_owner_can_bless_an_oracle_that_agrees_with_a_manipulated_pool() public {
        _setPoolUsd(key, 3000); // manipulated pool
        MockAggregator rogue = new MockAggregator(8);
        rogue.setAnswer(3000e8, block.timestamp);
        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.chainlinkFeed = address(rogue);
        guard.setPairConfig(key, config);
        _assertTrusted();
    }

    function test_nobody_can_front_run_the_first_configuration() public {
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        guard.setPairConfig(key, _chainlinkConfig());
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        guard.transferOwnership(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        guard.acceptOwnership();
        vm.stopPrank();

        vm.expectRevert(PriceGuard.NoConfig.selector);
        guard.isPriceTrusted(key);
        assertEq(guard.owner(), address(this));
    }

    function test_hijacking_a_pending_transfer_is_impossible() public {
        address timelock = makeAddr("timelock");
        address attacker = makeAddr("attacker");
        guard.transferOwnership(timelock);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        guard.acceptOwnership();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        guard.transferOwnership(attacker);

        assertEq(guard.pendingOwner(), timelock);
        assertEq(guard.owner(), address(this));
    }

    // ------------------------------------------------------------------------------------------------------------
    // L2 sequencer outage
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Timeline: sequencer goes down, comes back, and trust only returns after the full grace period, even
     *      though the pool and the oracle look perfectly consistent throughout.
     */
    function test_sequencer_outage_timeline() public {
        MockAggregator sequencer = new MockAggregator(0);
        PriceGuardHarness l2 = new PriceGuardHarness(stateView, address(sequencer), address(weth), address(this));
        sequencer.setAnswer(0, block.timestamp - 1 days);
        l2.setPairConfig(key, _chainlinkConfig());
        (bool trusted,) = l2.isPriceTrusted(key);
        assertTrue(trusted, "healthy before the outage");

        sequencer.setAnswer(1, block.timestamp); // sequencer goes down
        vm.warp(block.timestamp + 30 minutes);
        ethUsdFeed.setAnswer(2000e8, block.timestamp);
        (trusted,) = l2.isPriceTrusted(key);
        assertFalse(trusted, "down");

        sequencer.setAnswer(0, block.timestamp); // back up
        uint256 recoveredAt = block.timestamp;
        vm.warp(recoveredAt + 3600);
        ethUsdFeed.setAnswer(2000e8, block.timestamp);
        (trusted,) = l2.isPriceTrusted(key);
        assertFalse(trusted, "still inside the grace period");

        vm.warp(recoveredAt + 3601);
        ethUsdFeed.setAnswer(2000e8, block.timestamp);
        (trusted,) = l2.isPriceTrusted(key);
        assertTrue(trusted, "trusted again one second after the grace period");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Reentrancy through reference contracts
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Attack: a reference contract that is also the guard's owner reenters `setPairConfig` and
     *      `transferOwnership` during validation. Access control would allow it; the STATICCALL context must not.
     */
    function test_reference_contract_cannot_reenter_the_guard_during_validation() public {
        ReentrantOwnerFeed feed = new ReentrantOwnerFeed();
        PriceGuardHarness owned = new PriceGuardHarness(stateView, address(0), address(weth), address(feed));

        PoolKey memory victim = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(usdc)),
            fee: 100,
            tickSpacing: 1,
            hooks: address(0)
        });
        _setPoolUsd(victim, 2000);

        IPriceGuard.PairConfig memory mainConfig = _chainlinkConfig();
        mainConfig.chainlinkFeed = address(feed);
        IPriceGuard.PairConfig memory victimConfig = _chainlinkConfig(); // uses a plain feed, no recursion
        feed.arm(owned, key, mainConfig, victim, victimConfig);

        feed.configure(); // outer call succeeds, reentrant attempts are swallowed by the feed

        (IPriceGuard.PairConfig memory outer,,) = owned.configOf(key);
        (IPriceGuard.PairConfig memory inner,,) = owned.configOf(victim);
        assertEq(outer.maxDeviationBps, 100, "the intended configuration was stored");
        assertEq(inner.maxDeviationBps, 0, "the reentrant configuration must NOT have been stored");
        assertEq(owned.owner(), address(feed));
        assertEq(owned.pendingOwner(), address(0), "reentrant ownership transfer must NOT have started");
    }
}
