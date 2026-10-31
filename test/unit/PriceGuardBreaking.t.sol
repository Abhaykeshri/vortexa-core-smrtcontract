// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {PriceGuard} from "../../src/PriceGuard.sol";
import {Currency, PoolKey} from "../../src/libraries/Types.sol";
import {PoolIdLib} from "../../src/libraries/PoolIdLib.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {PriceGuardBase} from "../utils/PriceGuardBase.sol";
import {
    MockToken,
    MockSettableDecimalsToken,
    MockStateView,
    MockAggregator,
    MockTwapPool,
    MockStateWritingFeed,
    MockStateWritingToken,
    MockGarbageFeed,
    PriceGuardHarness
} from "../mocks/PriceGuardMocks.sol";

/**
 * @dev Audit-driven tests that try to break PriceGuard: exact boundaries, orientation and decimals, native ETH
 *      mapping, configuration replacement, static-call safety, fail-closed behaviour and liveness at the edges of
 *      the numeric domain.
 */
contract PriceGuardBreakingTest is PriceGuardBase {
    using PoolIdLib for PoolKey;

    int24 internal constant NATIVE_USDC_TICK = -200_310; // about 2000 USDC per ETH in raw units

    // ------------------------------------------------------------------------------------------------------------
    // Exact boundaries
    // ------------------------------------------------------------------------------------------------------------

    function test_staleness_boundary_is_inclusive() public {
        guard.setPairConfig(key, _chainlinkConfig());

        ethUsdFeed.setAnswer(2000e8, block.timestamp - 1 hours);
        _assertTrusted();

        ethUsdFeed.setAnswer(2000e8, block.timestamp - 1 hours - 1);
        _assertNotTrusted();
    }

    function test_answer_bounds_are_inclusive() public {
        guard.setPairConfig(key, _chainlinkConfig());

        ethUsdFeed.setAnswer(1000e8, block.timestamp);
        _setPoolUsd(key, 1000);
        _assertTrusted();
        ethUsdFeed.setAnswer(1000e8 - 1, block.timestamp);
        _assertNotTrusted();

        ethUsdFeed.setAnswer(5000e8, block.timestamp);
        _setPoolUsd(key, 5000);
        _assertTrusted();
        ethUsdFeed.setAnswer(5000e8 + 1, block.timestamp);
        _assertNotTrusted();
    }

    function test_sequencer_grace_period_boundary_is_exact() public {
        (PriceGuardHarness l2Guard, MockAggregator sequencer) = _l2Guard();

        sequencer.setAnswer(0, block.timestamp - 3600);
        (bool trusted,) = l2Guard.isPriceTrusted(key);
        assertFalse(trusted, "exactly at grace period must not be trusted");

        sequencer.setAnswer(0, block.timestamp - 3601);
        (trusted,) = l2Guard.isPriceTrusted(key);
        assertTrue(trusted, "one second past the grace period is trusted");
    }

    function test_sequencer_invalid_answers_are_never_trusted() public {
        (PriceGuardHarness l2Guard, MockAggregator sequencer) = _l2Guard();

        int256[3] memory downAnswers = [int256(1), int256(2), int256(-1)];
        for (uint256 i; i < downAnswers.length; ++i) {
            sequencer.setAnswer(downAnswers[i], block.timestamp - 1 days);
            (bool trusted, uint256 devBps) = l2Guard.isPriceTrusted(key);
            assertFalse(trusted);
            assertEq(devBps, type(uint256).max);
        }

        sequencer.setAnswer(0, 0); // never updated
        (bool trusted2,) = l2Guard.isPriceTrusted(key);
        assertFalse(trusted2);

        sequencer.setAnswer(0, block.timestamp + 1); // timestamp from the future
        (trusted2,) = l2Guard.isPriceTrusted(key);
        assertFalse(trusted2);
    }

    /**
     * @dev Binary-searches the pool price at which trust flips, above and below the reference, and proves the
     *      flip happens at exactly `maxDeviationBps` (measured as floor(diff * 10_000 / ref)).
     */
    function test_deviation_boundary_is_exact_above_and_below_reference() public {
        guard.setPairConfig(key, _chainlinkConfig()); // 100 bps
        uint160 sqrtRef = guard.sqrtFromRatio(2000 * 10 ** 6, 10 ** 18);

        uint160 lastTrustedUp = _searchBoundary(sqrtRef, uint160(uint256(sqrtRef) * 11 / 10));
        uint160 lastTrustedDown = _searchBoundary(sqrtRef, uint160(uint256(sqrtRef) * 9 / 10));
        assertGt(lastTrustedUp, sqrtRef);
        assertLt(lastTrustedDown, sqrtRef);

        _assertBoundary(sqrtRef, lastTrustedUp, lastTrustedUp + 1);
        _assertBoundary(sqrtRef, lastTrustedDown, lastTrustedDown - 1);
    }

    /**
     * @dev Documents that devBps is floored: the real deviation at the trust boundary can be up to
     *      `maxDeviationBps + 0.9999` bps. The guide's formula floors; this test pins the bound at < 1 bp extra.
     */
    function test_floor_rounding_extends_effective_tolerance_by_less_than_one_bp() public {
        guard.setPairConfig(key, _chainlinkConfig());
        uint160 sqrtRef = guard.sqrtFromRatio(2000 * 10 ** 6, 10 ** 18);
        uint160 edge = _searchBoundary(sqrtRef, uint160(uint256(sqrtRef) * 11 / 10));

        uint256 refP = Math.mulDiv(sqrtRef, sqrtRef, 1 << 96);
        uint256 edgeP = Math.mulDiv(edge, edge, 1 << 96);
        assertLt((edgeP - refP) * 10_000, 101 * refP, "real deviation must stay below max + 1 bp");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Orientation and decimals
    // ------------------------------------------------------------------------------------------------------------

    function test_wrong_invert_feed_flag_is_rejected_at_configuration() public {
        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.invertFeed = true;
        vm.expectRevert(PriceGuard.InvalidInitialPrice.selector);
        guard.setPairConfig(key, config);
    }

    function test_wrong_feed_decimals_are_rejected_at_configuration() public {
        MockAggregator feed18 = new MockAggregator(18);
        feed18.setAnswer(2000e8, block.timestamp); // an 8-decimal answer on an 18-decimal feed
        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.chainlinkFeed = address(feed18);
        config.minAnswer = 1;
        config.maxAnswer = type(uint256).max;
        vm.expectRevert(PriceGuard.InvalidInitialPrice.selector);
        guard.setPairConfig(key, config);

        feed18.setAnswer(2000e18, block.timestamp); // the same price expressed correctly
        guard.setPairConfig(key, config);
        _assertTrusted();
    }

    /**
     * @dev USDC (6 decimals) sorts below WETH (18), so a USDC/WETH ERC-20 pool has token0 = USDC. Chainlink's
     *      ETH/USD feed quotes USD per ETH, i.e. token0 per token1, which needs invertFeed = true. The raw price
     *      must account for the *different* decimals of the two tokens.
     */
    function test_inverted_feed_with_unequal_decimals_matches_pool() public {
        PoolKey memory usdcWeth = _usdcWethKey();
        stateView.setSqrtPrice(usdcWeth.toId(), guard.sqrtFromRatio(1e18, 2000 * 10 ** 6));

        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.invertFeed = true;
        guard.setPairConfig(usdcWeth, config);

        (bool trusted, uint256 devBps) = guard.isPriceTrusted(usdcWeth);
        assertTrue(trusted, "inverted ETH/USD feed must match the USDC/WETH pool");
        assertLe(devBps, 1);

        // Reference moves with the feed: a 5% higher ETH/USD answer is far outside the 1% limit.
        ethUsdFeed.setAnswer(2100e8, block.timestamp);
        (trusted,) = guard.isPriceTrusted(usdcWeth);
        assertFalse(trusted);
    }

    function test_non_inverted_flag_is_rejected_for_a_pool_that_needs_inversion() public {
        PoolKey memory usdcWeth = _usdcWethKey();
        stateView.setSqrtPrice(usdcWeth.toId(), guard.sqrtFromRatio(1e18, 2000 * 10 ** 6));

        vm.expectRevert(PriceGuard.InvalidInitialPrice.selector);
        guard.setPairConfig(usdcWeth, _chainlinkConfig());
    }

    function test_inverted_feed_with_equal_decimals() public {
        MockToken usdt = new MockToken("Tether", "USDT", 6);
        PoolKey memory stableKey = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(usdt)),
            fee: 100,
            tickSpacing: 1,
            hooks: address(0)
        });
        // Feed quotes USDC per USDT = 0.9990 (token0 per token1) => token1 per token0 = 1.001001...
        MockAggregator feed = new MockAggregator(8);
        feed.setAnswer(99_900_000, block.timestamp);
        stateView.setSqrtPrice(stableKey.toId(), guard.sqrtFromRatio(1e8, 99_900_000));

        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.chainlinkFeed = address(feed);
        config.invertFeed = true;
        config.minAnswer = 90_000_000;
        config.maxAnswer = 110_000_000;
        guard.setPairConfig(stableKey, config);

        (bool trusted,) = guard.isPriceTrusted(stableKey);
        assertTrue(trusted);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Native ETH <-> WETH mapping
    // ------------------------------------------------------------------------------------------------------------

    function test_native_pool_uses_18_decimals_and_chainlink() public {
        PoolKey memory nativeKey = _nativeKey();
        _setPoolUsd(nativeKey, 2000);

        guard.setPairConfig(nativeKey, _chainlinkConfig());

        (, uint8 decimals0, uint8 decimals1) = guard.configOf(nativeKey);
        assertEq(decimals0, 18);
        assertEq(decimals1, 6);
        (bool trusted,) = guard.isPriceTrusted(nativeKey);
        assertTrue(trusted);
    }

    function test_native_pool_maps_to_wrapped_token_in_v3_pool_in_both_orderings() public {
        PoolKey memory nativeKey = _nativeKey();
        stateView.setSqrtPrice(nativeKey.toId(), SqrtPriceMath.getSqrtPriceAtTick(NATIVE_USDC_TICK));

        // V3 pool ordered like the V4 key: (WETH, USDC).
        MockTwapPool sameOrder = new MockTwapPool(address(weth), address(usdc));
        sameOrder.setMeanTick(NATIVE_USDC_TICK);
        IPriceGuard.PairConfig memory config;
        config.v3Pool = address(sameOrder);
        config.twapWindow = 1800;
        config.maxDeviationBps = 1;
        guard.setPairConfig(nativeKey, config);
        (bool trusted, uint256 devBps) = guard.isPriceTrusted(nativeKey);
        assertTrue(trusted);
        assertEq(devBps, 0);

        // V3 pool ordered the other way: (USDC, WETH) with invertV3 = true. Its mean tick is the negation.
        MockTwapPool reversed = new MockTwapPool(address(usdc), address(weth));
        reversed.setMeanTick(-NATIVE_USDC_TICK);
        config.v3Pool = address(reversed);
        config.invertV3 = true;
        guard.setPairConfig(nativeKey, config);
        (trusted, devBps) = guard.isPriceTrusted(nativeKey);
        assertTrue(trusted);
        assertLe(devBps, 1);
    }

    function test_native_pool_rejects_mismatched_v3_orientation_and_native_in_v3() public {
        PoolKey memory nativeKey = _nativeKey();
        IPriceGuard.PairConfig memory config;
        config.twapWindow = 1800;
        config.maxDeviationBps = 100;

        config.v3Pool = address(new MockTwapPool(address(weth), address(usdc)));
        config.invertV3 = true; // flag says reversed, pool is not
        vm.expectRevert(PriceGuard.InvalidV3Pool.selector);
        guard.setPairConfig(nativeKey, config);

        config.v3Pool = address(new MockTwapPool(address(usdc), address(weth)));
        config.invertV3 = false; // flag says same order, pool is reversed
        vm.expectRevert(PriceGuard.InvalidV3Pool.selector);
        guard.setPairConfig(nativeKey, config);

        // A "V3 pool" that lists the zero address instead of WETH can never match a native key.
        config.v3Pool = address(new MockTwapPool(address(0), address(usdc)));
        vm.expectRevert(PriceGuard.InvalidV3Pool.selector);
        guard.setPairConfig(nativeKey, config);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Key identity and configuration replacement
    // ------------------------------------------------------------------------------------------------------------

    function test_config_does_not_apply_to_any_mutated_pool_key() public {
        guard.setPairConfig(key, _chainlinkConfig());

        PoolKey memory k = key;
        k.fee = key.fee + 1;
        _assertNoConfig(k);

        k = key;
        k.tickSpacing = key.tickSpacing + 1;
        _assertNoConfig(k);

        k = key;
        k.hooks = address(0xdEaD);
        _assertNoConfig(k);

        k = key;
        (k.currency0, k.currency1) = (key.currency1, key.currency0);
        _assertNoConfig(k);

        (IPriceGuard.PairConfig memory unset,,) = guard.configOf(k);
        assertEq(unset.maxDeviationBps, 0);
    }

    function test_reconfiguration_fully_replaces_previous_oracle_and_emits_event() public {
        guard.setPairConfig(key, _chainlinkConfig());

        MockAggregator secondFeed = new MockAggregator(8);
        secondFeed.setAnswer(2000e8, block.timestamp);
        IPriceGuard.PairConfig memory replacement = _chainlinkConfig();
        replacement.chainlinkFeed = address(secondFeed);
        replacement.maxDeviationBps = 50;

        vm.expectEmit(true, false, false, true, address(guard));
        emit IPriceGuard.PairConfigSet(key.toId(), key, replacement, 18, 6);
        guard.setPairConfig(key, replacement);

        // The first feed is now irrelevant, even if it breaks.
        ethUsdFeed.setAnswer(0, block.timestamp);
        _assertTrusted();

        // The tighter limit of the second config is the one in force: +0.6% is rejected, it was fine at 1%.
        _setPoolUsd(key, 2012);
        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
        assertFalse(trusted);
        assertGt(devBps, 50);
    }

    function test_decimals_are_cached_at_set_time_and_reconfiguration_rejects_a_changed_token() public {
        MockSettableDecimalsToken token = new MockSettableDecimalsToken(6);
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(token)),
            fee: 500,
            tickSpacing: 10,
            hooks: address(0)
        });
        stateView.setSqrtPrice(k.toId(), guard.sqrtFromRatio(2000 * 10 ** 6, 10 ** 18));
        guard.setPairConfig(k, _chainlinkConfig());

        token.setDecimals(8); // token changes behind our back
        (bool trusted,) = guard.isPriceTrusted(k);
        assertTrue(trusted, "cached decimals keep the old, consistent conversion");
        (,, uint8 cached1) = guard.configOf(k);
        assertEq(cached1, 6);

        vm.expectRevert(PriceGuard.InvalidInitialPrice.selector);
        guard.setPairConfig(k, _chainlinkConfig()); // reconfiguring re-reads decimals and notices the mismatch
    }

    function test_configuration_is_rejected_for_uninitialized_or_unsorted_pools() public {
        PoolKey memory unsorted = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(0)),
            fee: 500,
            tickSpacing: 10,
            hooks: address(0)
        });
        vm.expectRevert(PriceGuard.InvalidInitialPrice.selector);
        guard.setPairConfig(unsorted, _chainlinkConfig());

        PoolKey memory hooked = key;
        hooked.hooks = address(0xBEEF);
        vm.expectRevert(PriceGuard.InvalidInitialPrice.selector);
        guard.setPairConfig(hooked, _chainlinkConfig());
    }

    function test_configuration_is_rejected_when_oracle_is_stale_at_set_time() public {
        ethUsdFeed.setAnswer(2000e8, block.timestamp - 2 hours);
        vm.expectRevert(PriceGuard.InvalidInitialPrice.selector);
        guard.setPairConfig(key, _chainlinkConfig());
    }

    function test_configuration_is_rejected_for_non_contract_token() public {
        PoolKey memory k = key;
        k.currency1 = Currency.wrap(address(0x1234)); // an EOA, not an ERC-20
        vm.expectRevert();
        guard.setPairConfig(k, _chainlinkConfig());
    }

    // ------------------------------------------------------------------------------------------------------------
    // Holds no funds, static-call safety, fail closed
    // ------------------------------------------------------------------------------------------------------------

    function test_guard_rejects_eth_and_unknown_calls() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(guard).call{value: 1 wei}("");
        assertFalse(ok);
        (ok,) = address(guard).call{value: 1 wei}(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok);
        (ok,) = address(guard).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok);
        assertEq(address(guard).balance, 0);
    }

    function test_feed_cannot_write_state_during_validation_or_runtime() public {
        MockStateWritingFeed feed = new MockStateWritingFeed();
        feed.setAnswer(2000e8, block.timestamp);
        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.chainlinkFeed = address(feed);

        feed.setWriteMode(true);
        vm.expectRevert(PriceGuard.InvalidFeed.selector);
        guard.setPairConfig(key, config);
        assertEq(feed.writes(), 0, "STATICCALL must prevent writes");

        feed.setWriteMode(false);
        guard.setPairConfig(key, config);
        _assertTrusted();

        feed.setWriteMode(true);
        _assertNotTrusted();
        assertEq(feed.writes(), 0);
    }

    function test_token_cannot_write_state_while_decimals_are_read() public {
        MockStateWritingToken token = new MockStateWritingToken();
        PoolKey memory k = key;
        k.currency1 = Currency.wrap(address(token));

        vm.expectRevert();
        guard.setPairConfig(k, _chainlinkConfig());

        assertEq(token.writes(), 0);
        (IPriceGuard.PairConfig memory stored,,) = guard.configOf(k);
        assertEq(stored.maxDeviationBps, 0, "no partial configuration may be stored");
    }

    function test_malformed_feed_response_never_yields_trust() public {
        MockGarbageFeed feed = new MockGarbageFeed();
        feed.setAnswer(2000e8, block.timestamp);
        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.chainlinkFeed = address(feed);
        guard.setPairConfig(key, config);
        _assertTrusted();

        feed.setGarbage(true);
        assertFalse(_trustedOrFalse(key), "undecodable oracle data must never be trusted");

        // And it cannot be configured in that state either.
        vm.expectRevert();
        guard.setPairConfig(_usdcWethKey(), config);
    }

    function test_state_view_failure_never_yields_trust() public {
        guard.setPairConfig(key, _chainlinkConfig());
        stateView.setRevertGetSlot0(true);
        assertFalse(_trustedOrFalse(key));

        vm.expectRevert();
        guard.setPairConfig(key, _chainlinkConfig());
    }

    // ------------------------------------------------------------------------------------------------------------
    // Liveness at the edges of the numeric domain (isPriceTrusted must report false, not revert)
    // ------------------------------------------------------------------------------------------------------------

    function test_absurd_chainlink_answer_is_reported_untrusted_not_reverted() public {
        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.minAnswer = 1;
        config.maxAnswer = type(uint256).max;
        guard.setPairConfig(key, config);

        ethUsdFeed.setAnswer(1e40, block.timestamp); // ratio far above 2**64
        _assertNotTrusted();
    }

    function test_tiny_answer_on_inverted_feed_is_reported_untrusted_not_reverted() public {
        PoolKey memory usdcWeth = _usdcWethKey();
        stateView.setSqrtPrice(usdcWeth.toId(), guard.sqrtFromRatio(1e18, 2000 * 10 ** 6));
        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.invertFeed = true;
        config.minAnswer = 1;
        config.maxAnswer = type(uint256).max;
        guard.setPairConfig(usdcWeth, config);

        ethUsdFeed.setAnswer(1, block.timestamp); // inverted ratio becomes astronomically large
        (bool trusted, uint256 devBps) = guard.isPriceTrusted(usdcWeth);
        assertFalse(trusted);
        assertEq(devBps, type(uint256).max);
    }

    function test_extreme_twap_ticks_never_revert_and_never_trust() public {
        int24[2] memory extremeTicks = [SqrtPriceMath.MIN_TICK, SqrtPriceMath.MAX_TICK];
        for (uint256 inv; inv < 2; ++inv) {
            for (uint256 i; i < extremeTicks.length; ++i) {
                MockTwapPool pool = inv == 1
                    ? new MockTwapPool(address(usdc), address(weth))
                    : new MockTwapPool(address(weth), address(usdc));
                pool.setMeanTick(0);
                stateView.setSqrtPrice(key.toId(), SqrtPriceMath.getSqrtPriceAtTick(0));

                IPriceGuard.PairConfig memory config;
                config.v3Pool = address(pool);
                config.invertV3 = inv == 1;
                config.twapWindow = 600;
                config.maxDeviationBps = 1000;
                guard.setPairConfig(key, config);
                _assertTrusted();

                pool.setMeanTick(extremeTicks[i]);
                (bool trusted,) = guard.isPriceTrusted(key); // must not revert
                assertFalse(trusted);
            }
        }
    }

    function test_twap_reference_rounding_to_zero_is_rejected_at_configuration() public {
        MockTwapPool pool = new MockTwapPool(address(weth), address(usdc));
        pool.setMeanTick(SqrtPriceMath.MIN_TICK);
        stateView.setSqrtPrice(key.toId(), SqrtPriceMath.getSqrtPriceAtTick(SqrtPriceMath.MIN_TICK));

        IPriceGuard.PairConfig memory config;
        config.v3Pool = address(pool);
        config.twapWindow = 600;
        config.maxDeviationBps = 1000;
        vm.expectRevert(PriceGuard.InvalidInitialPrice.selector);
        guard.setPairConfig(key, config);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Ownership edge cases
    // ------------------------------------------------------------------------------------------------------------

    function test_second_transfer_replaces_pending_owner() public {
        address first = address(0xA1);
        address second = address(0xB2);
        guard.transferOwnership(first);
        guard.transferOwnership(second);
        assertEq(guard.pendingOwner(), second);

        vm.prank(first);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, first));
        guard.acceptOwnership();

        vm.prank(second);
        guard.acceptOwnership();
        assertEq(guard.owner(), second);
    }

    /**
     * @dev KNOWN ISSUE (see docs/known-issues.md): OpenZeppelin's `renounceOwnership` is inherited, so the owner
     *      (the timelock) can permanently freeze configuration. Existing configurations keep working.
     */
    function test_known_issue_renounce_ownership_freezes_configuration_but_not_reads() public {
        guard.setPairConfig(key, _chainlinkConfig());
        guard.renounceOwnership();

        assertEq(guard.owner(), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        guard.setPairConfig(key, _chainlinkConfig());
        _assertTrusted();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _nativeKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(usdc)),
            fee: 500,
            tickSpacing: 10,
            hooks: address(0)
        });
    }

    function _usdcWethKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(weth)),
            fee: 500,
            tickSpacing: 10,
            hooks: address(0)
        });
    }

    function _l2Guard() internal returns (PriceGuardHarness l2Guard, MockAggregator sequencer) {
        sequencer = new MockAggregator(0);
        l2Guard = new PriceGuardHarness(stateView, address(sequencer), address(weth), address(this));
        sequencer.setAnswer(0, block.timestamp - 2 hours);
        l2Guard.setPairConfig(key, _chainlinkConfig());
    }

    function _assertNoConfig(PoolKey memory k) internal {
        vm.expectRevert(PriceGuard.NoConfig.selector);
        guard.isPriceTrusted(k);
    }

    function _trustedAt(uint160 sqrtPool) internal returns (bool trusted) {
        stateView.setSqrtPrice(key.toId(), sqrtPool);
        (trusted,) = guard.isPriceTrusted(key);
    }

    /**
     * @dev Returns the last trusted price between a trusted price `good` and an untrusted price `bad`.
     */
    function _searchBoundary(uint160 good, uint160 bad) internal returns (uint160) {
        assertTrue(_trustedAt(good));
        assertFalse(_trustedAt(bad));
        while (good + 1 < bad || bad + 1 < good) {
            uint160 mid = good < bad ? good + (bad - good) / 2 : bad + (good - bad) / 2;
            if (_trustedAt(mid)) good = mid;
            else bad = mid;
        }
        return good;
    }

    function _assertBoundary(uint160 sqrtRef, uint160 lastTrusted, uint160 firstUntrusted) internal {
        uint256 refP = Math.mulDiv(sqrtRef, sqrtRef, 1 << 96);

        stateView.setSqrtPrice(key.toId(), lastTrusted);
        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
        assertTrue(trusted);
        assertEq(devBps, 100, "last trusted price sits at exactly maxDeviationBps");

        stateView.setSqrtPrice(key.toId(), firstUntrusted);
        (trusted, devBps) = guard.isPriceTrusted(key);
        assertFalse(trusted);
        assertEq(devBps, 101, "the next sqrt step is exactly one basis point over");
        assertGe(_absDiff(Math.mulDiv(firstUntrusted, firstUntrusted, 1 << 96), refP) * 10_000, 101 * refP);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
