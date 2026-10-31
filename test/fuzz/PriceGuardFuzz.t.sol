// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {Currency, PoolKey} from "../../src/libraries/Types.sol";
import {PoolIdLib} from "../../src/libraries/PoolIdLib.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {PriceGuardBase} from "../utils/PriceGuardBase.sol";
import {MockToken, MockAggregator, MockV3Pool, MockTwapPool} from "../mocks/PriceGuardMocks.sol";

/**
 * @dev Property tests for PriceGuard. Every property is stated independently of the implementation's own
 *      arithmetic where possible (exact floor sqrt, equivalent non-inverted answer, floor division identity).
 */
contract PriceGuardFuzzTest is PriceGuardBase {
    using PoolIdLib for PoolKey;

    // ------------------------------------------------------------------------------------------------------------
    // _sqrtFromRatio
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev s = floor(sqrt(numerator * 2**192 / denominator)) exactly: s^2 <= target < (s+1)^2.
     */
    function testFuzz_sqrtFromRatio_is_the_exact_floor_square_root(uint128 numerator, uint128 denominator) public view {
        denominator = uint128(bound(denominator, 1, type(uint128).max));
        numerator = uint128(bound(numerator, 1, Math.min(type(uint128).max, (uint256(denominator) << 64) - 1)));

        uint256 s = guard.sqrtFromRatio(numerator, denominator);
        uint256 target = Math.mulDiv(numerator, 1 << 192, denominator);

        assertLe(s * s, target, "s^2 must not exceed the target");
        if (s + 1 < (1 << 128)) assertGt((s + 1) * (s + 1), target, "(s+1)^2 must exceed the target");
    }

    function testFuzz_sqrtFromRatio_is_monotonic(uint64 n1, uint64 n2, uint64 d1, uint64 d2) public view {
        n1 = uint64(bound(n1, 1, type(uint64).max));
        n2 = uint64(bound(n2, n1, type(uint64).max));
        d1 = uint64(bound(d1, 1, type(uint64).max));
        d2 = uint64(bound(d2, d1, type(uint64).max));

        assertLe(guard.sqrtFromRatio(n1, d1), guard.sqrtFromRatio(n2, d1), "larger numerator, larger price");
        assertGe(guard.sqrtFromRatio(n1, d1), guard.sqrtFromRatio(n1, d2), "larger denominator, smaller price");
    }

    function testFuzz_sqrtFromRatio_reverts_only_outside_the_representable_domain(
        uint256 numerator,
        uint256 denominator
    ) public view {
        denominator = bound(denominator, 1, type(uint256).max);
        numerator = bound(numerator, 0, type(uint256).max);

        // The ratio must stay below 2**64 for numerator * 2**192 / denominator to fit in 256 bits.
        (bool ok, uint256 scaled) = Math.tryMul(denominator, 1 << 64);
        bool inDomain = !ok || numerator < scaled;

        try guard.sqrtFromRatio(numerator, denominator) returns (uint160 s) {
            assertTrue(inDomain, "returned a value for an out-of-domain ratio");
            assertLt(uint256(s), 1 << 128);
        } catch {
            assertFalse(inDomain, "reverted for an in-domain ratio");
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Internal helpers, tested directly (one tick is 0.9999 bp, below devBps resolution, so black-box checks cannot
    // see a one-tick error)
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev floor(a / b) satisfies b * q <= a < b * (q + 1) for every sign of `a`, exactly.
     */
    function testFuzz_floorDivTick_is_exact_floor_division(int56 numerator, int56 denominator) public view {
        denominator = int56(bound(int256(denominator), 1, 7 days));
        int256 n = bound(int256(numerator), -887_272 * int256(denominator), 887_272 * int256(denominator));
        int256 d = int256(denominator);

        int256 q = guard.floorDivTick(int56(n), denominator);
        assertLe(d * q, n, "quotient too large (rounded toward zero for a negative numerator?)");
        assertGt(d * (q + 1), n, "quotient too small");
    }

    function test_floorDivTick_known_negative_cases() public view {
        assertEq(guard.floorDivTick(-1, 600), -1);
        assertEq(guard.floorDivTick(-599, 600), -1);
        assertEq(guard.floorDivTick(-600, 600), -1);
        assertEq(guard.floorDivTick(-601, 600), -2);
        assertEq(guard.floorDivTick(1, 600), 0);
        assertEq(guard.floorDivTick(599, 600), 0);
        assertEq(guard.floorDivTick(0, 600), 0);
    }

    function testFuzz_ratioFits_is_exactly_the_mulDiv_domain(uint256 numerator, uint256 denominator) public view {
        denominator = bound(denominator, 1, type(uint256).max);
        bool expected = true;
        // numerator * 2**192 / denominator fits in 256 bits  <=>  the result of mulDiv would not overflow
        if (denominator <= type(uint192).max) {
            // numerator * 2**192 / denominator < 2**256  <=>  numerator < denominator * 2**64
            expected = numerator < (denominator << 64);
        }
        assertEq(guard.ratioFits(numerator, denominator), expected);
    }

    /**
     * @dev Exact edge of the convertible domain: numerator == denominator * 2**64 is the first value that no
     *      longer fits, and `_sqrtFromRatio` reverts at precisely that point.
     */
    function test_ratioFits_and_sqrtFromRatio_agree_at_the_exact_boundary() public {
        uint256[4] memory denominators = [uint256(1), 10, 1e18, type(uint128).max];
        for (uint256 i; i < denominators.length; ++i) {
            uint256 edge = denominators[i] << 64;
            assertTrue(guard.ratioFits(edge - 1, denominators[i]), "one below the edge fits");
            assertFalse(guard.ratioFits(edge, denominators[i]), "the edge itself does not fit");
            guard.sqrtFromRatio(edge - 1, denominators[i]); // must not revert
            vm.expectRevert();
            guard.sqrtFromRatio(edge, denominators[i]); // must revert
        }
        // A denominator so large that denominator * 2**64 overflows: every numerator fits.
        assertTrue(guard.ratioFits(type(uint256).max, type(uint256).max));
    }

    function test_scaledRatio_orientation_cases() public view {
        // WETH(18) / USDC(6), ETH/USD 2000.00 with 8 decimals: direct feed => USDC raw per WETH raw = 2e-9.
        (bool ok, uint256 n, uint256 d) = guard.scaledRatio(false, 2000e8, 8, 18, 6);
        assertTrue(ok);
        assertEq(n, 2000e8 * 1e6);
        assertEq(d, 1e8 * 1e18);

        // USDC(6) / WETH(18): the same feed quotes token0 per token1 => WETH raw per USDC raw = 5e8.
        (ok, n, d) = guard.scaledRatio(true, 2000e8, 8, 6, 18);
        assertTrue(ok);
        assertEq(n, 1e8 * 1e18, "numerator: 10**fd * 10**d1");
        assertEq(d, 2000e8 * 1e6, "denominator: answer * 10**d0");
        assertEq(n / d, 5e8);
    }

    function test_scaledRatio_overflow_is_reported_not_reverted() public view {
        (bool ok,,) = guard.scaledRatio(false, type(uint256).max, 8, 18, 18);
        assertFalse(ok);
        (ok,,) = guard.scaledRatio(true, type(uint256).max, 8, 18, 18);
        assertFalse(ok);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Chainlink conversion: any decimals, either orientation
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev For every decimals combination and both feed orientations, a pool priced at the same human price as
     *      the feed is trusted with a deviation of at most one basis point. The equivalent non-inverted answer
     *      (`10**(2*fd) / answer`) gives an independent derivation of the pool price for inverted feeds.
     */
    function testFuzz_chainlink_reference_matches_pool_for_any_decimals_and_orientation(
        uint8 decimals0,
        uint8 decimals1,
        uint8 feedDecimals,
        uint256 answerSeed,
        bool invert
    ) public {
        decimals0 = uint8(bound(decimals0, 0, 18));
        decimals1 = uint8(bound(decimals1, 0, 18));
        feedDecimals = uint8(bound(feedDecimals, 8, 18));
        (uint256 answer, uint256 directAnswer) = _answers(feedDecimals, answerSeed, invert);

        PoolKey memory k = _tokenKey(decimals0, decimals1);
        stateView.setSqrtPrice(k.toId(), _poolSqrt(directAnswer, feedDecimals, decimals0, decimals1));
        _configureFeed(k, feedDecimals, answer, invert);

        (bool trusted, uint256 devBps) = guard.isPriceTrusted(k);
        assertTrue(trusted, "pool at the feed's price must be trusted");
        assertLe(devBps, 1);
    }

    /**
     * @dev Returns the feed answer and the equivalent non-inverted answer (token1 per token0).
     */
    function _answers(uint8 feedDecimals, uint256 answerSeed, bool invert)
        private
        pure
        returns (uint256 answer, uint256 directAnswer)
    {
        uint256 unit = 10 ** feedDecimals;
        // Human price token1/token0 stays within [1e-3, 10] so the raw ratio stays inside the convertible domain.
        // For an inverted feed the quote is its reciprocal, i.e. within [0.1, 1000].
        answer = invert ? bound(answerSeed, unit / 10, unit * 1000) : bound(answerSeed, unit / 1000, unit * 10);
        directAnswer = invert ? (unit * unit) / answer : answer;
    }

    function _tokenKey(uint8 decimals0, uint8 decimals1) private returns (PoolKey memory) {
        MockToken t0 = new MockToken("T0", "T0", decimals0);
        MockToken t1 = new MockToken("T1", "T1", decimals1);
        return PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 500,
            tickSpacing: 10,
            hooks: address(0)
        });
    }

    function _poolSqrt(uint256 directAnswer, uint8 feedDecimals, uint8 decimals0, uint8 decimals1)
        private
        view
        returns (uint160)
    {
        return guard.sqrtFromRatio(directAnswer * 10 ** decimals1, 10 ** feedDecimals * 10 ** decimals0);
    }

    function _configureFeed(PoolKey memory k, uint8 feedDecimals, uint256 answer, bool invert) private {
        MockAggregator feed = new MockAggregator(feedDecimals);
        feed.setAnswer(int256(answer), block.timestamp);
        IPriceGuard.PairConfig memory config;
        config.chainlinkFeed = address(feed);
        config.invertFeed = invert;
        config.maxStaleness = 1 hours;
        config.minAnswer = 1;
        config.maxAnswer = type(uint256).max;
        config.maxDeviationBps = 1;
        guard.setPairConfig(k, config);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Deviation arithmetic
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev A pool x bps above or below the reference reports a deviation of x (or x - 1 from sqrt flooring), and
     *      `trusted` is exactly `devBps <= max` on both sides.
     */
    function testFuzz_deviation_tracks_the_price_move_and_trust_follows_the_limit(uint16 moveBps, bool above) public {
        moveBps = uint16(bound(moveBps, 1, 2000));
        guard.setPairConfig(key, _chainlinkConfig()); // 100 bps limit, reference 2000 USDC per ETH

        uint256 factor = above ? 10_000 + moveBps : 10_000 - moveBps;
        stateView.setSqrtPrice(key.toId(), guard.sqrtFromRatio(2_000 * 10 ** 6 * factor / 10_000, 10 ** 18));

        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
        assertApproxEqAbs(devBps, moveBps, 1);
        assertEq(trusted, devBps <= 100, "trusted must equal devBps <= max");
    }

    /**
     * @dev For any pool sqrt price at all (including zero and uint160 max) the call never reverts, and the result
     *      equals an independent computation of the deviation.
     */
    function testFuzz_trust_matches_independent_deviation_for_any_pool_price(uint160 poolSqrt) public {
        guard.setPairConfig(key, _chainlinkConfig());
        stateView.setSqrtPrice(key.toId(), poolSqrt);

        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);

        uint160 refSqrt = guard.sqrtFromRatio(2_000 * 10 ** 6, 10 ** 18);
        uint256 refP = Math.mulDiv(refSqrt, refSqrt, 1 << 96);
        uint256 poolP = Math.mulDiv(poolSqrt, poolSqrt, 1 << 96);
        uint256 diff = poolP > refP ? poolP - refP : refP - poolP;
        assertEq(devBps, Math.mulDiv(diff, 10_000, refP));
        assertEq(trusted, devBps <= 100);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Freshness and bounds: trust implies a fresh, positive, in-bounds answer
    // ------------------------------------------------------------------------------------------------------------

    function testFuzz_trust_implies_fresh_positive_in_bounds_answer(int256 answer, uint32 age) public {
        guard.setPairConfig(key, _chainlinkConfig()); // staleness 1h, bounds [1000e8, 5000e8]
        age = uint32(bound(age, 0, 3 days));
        ethUsdFeed.setAnswer(answer, block.timestamp - age);
        // Put the pool exactly where this answer would place it, when representable, to give trust its best chance.
        if (answer > 0 && uint256(answer) >= 1000e8 && uint256(answer) <= 5000e8) {
            stateView.setSqrtPrice(key.toId(), guard.sqrtFromRatio(uint256(answer) * 10 ** 6, 10 ** 26));
        }

        (bool trusted,) = guard.isPriceTrusted(key);
        if (trusted) {
            assertGt(answer, 0);
            assertGe(uint256(answer), 1000e8);
            assertLe(uint256(answer), 5000e8);
            assertLe(age, 1 hours);
        }
        if (answer > 0 && uint256(answer) >= 1000e8 && uint256(answer) <= 5000e8 && age <= 1 hours) {
            assertTrue(trusted, "a fresh in-bounds answer with an aligned pool must be trusted");
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // V3 TWAP: floor division of the tick cumulative difference
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev The mean tick is floor(delta / window) even for negative deltas. The expected value is computed with an
     *      independent identity: floor(a / b) = (a - ((a mod b) + b) mod b) / b.
     */
    function testFuzz_twap_mean_tick_is_floor_division(int256 deltaSeed, uint32 window) public {
        window = uint32(bound(window, 600, 7 days));
        int256 w = int256(uint256(window));
        int256 delta = bound(deltaSeed, -300_000 * w, 300_000 * w);
        int256 remainder = ((delta % w) + w) % w;
        int24 expectedTick = int24((delta - remainder) / w);

        MockV3Pool pool = new MockV3Pool(address(weth), address(usdc));
        pool.setTickDelta(int56(delta));
        stateView.setSqrtPrice(key.toId(), SqrtPriceMath.getSqrtPriceAtTick(expectedTick));

        IPriceGuard.PairConfig memory config;
        config.v3Pool = address(pool);
        config.twapWindow = window;
        config.maxDeviationBps = 1;
        guard.setPairConfig(key, config);

        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
        assertTrue(trusted);
        assertEq(devBps, 0, "reference must be exactly the floored mean tick");
    }

    /**
     * @dev Reversing the V3 token order (invertV3) negates the tick: the reference must land on the price at -tick.
     */
    function testFuzz_twap_inversion_negates_the_tick(int24 tick) public {
        tick = int24(bound(int256(tick), -300_000, 300_000));
        MockTwapPool pool = new MockTwapPool(address(usdc), address(weth));
        pool.setMeanTick(-tick);
        stateView.setSqrtPrice(key.toId(), SqrtPriceMath.getSqrtPriceAtTick(tick));

        IPriceGuard.PairConfig memory config;
        config.v3Pool = address(pool);
        config.invertV3 = true;
        config.twapWindow = 1800;
        config.maxDeviationBps = 1;
        guard.setPairConfig(key, config);

        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
        assertTrue(trusted);
        assertLe(devBps, 1);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Access control
    // ------------------------------------------------------------------------------------------------------------

    function testFuzz_only_the_owner_can_change_anything(address caller, address target) public {
        vm.assume(caller != address(this));
        vm.assume(caller != address(0));
        assumeNotForgeAddress(caller);
        assumeNotPrecompile(caller);

        vm.startPrank(caller);
        vm.expectRevert();
        guard.setPairConfig(key, _chainlinkConfig());
        vm.expectRevert();
        guard.transferOwnership(target);
        vm.expectRevert();
        guard.renounceOwnership();
        vm.expectRevert();
        guard.acceptOwnership();
        vm.stopPrank();

        assertEq(guard.owner(), address(this));
        assertEq(guard.pendingOwner(), address(0));
        (IPriceGuard.PairConfig memory stored,,) = guard.configOf(key);
        assertEq(stored.maxDeviationBps, 0);
    }
}
