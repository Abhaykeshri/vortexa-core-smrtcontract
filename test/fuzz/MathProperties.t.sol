// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath as V4TickMath} from "uni-test/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "uni-test/v4-core/test/utils/LiquidityAmounts.sol";
import {IHooks} from "uni-test/v4-core/src/interfaces/IHooks.sol";
import {Currency as V4Currency} from "uni-test/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "uni-test/v4-core/src/types/PoolId.sol";
import {PoolKey as V4PoolKey} from "uni-test/v4-core/src/types/PoolKey.sol";
import {Currency, PoolKey} from "../../src/libraries/Types.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {PoolIdLib} from "../../src/libraries/PoolIdLib.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";

/**
 * @dev External wrappers so reverts can be observed with try/catch.
 */
contract MathPropertiesHarness {
    function sqrtAt(int24 tick) external pure returns (uint160) {
        return SqrtPriceMath.getSqrtPriceAtTick(tick);
    }

    function liquidityFor(uint160 sp, uint160 sa, uint160 sb, uint256 a0, uint256 a1) external pure returns (uint128) {
        return LiquidityMath.liquidityForAmounts(sp, sa, sb, a0, a1);
    }

    function amountsFor(uint160 sp, uint160 sa, uint160 sb, uint128 liquidity)
        external
        pure
        returns (uint256, uint256)
    {
        return LiquidityMath.amountsForLiquidity(sp, sa, sb, liquidity);
    }

    function v4LiquidityFor(uint160 sp, uint160 sa, uint160 sb, uint256 a0, uint256 a1)
        external
        pure
        returns (uint128)
    {
        return LiquidityAmounts.getLiquidityForAmounts(sp, sa, sb, a0, a1);
    }
}

/**
 * @dev Property tests for the M1 math and helper libraries over their whole input domain.
 */
contract MathPropertiesTest is Test {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;
    uint160 internal constant MIN_SQRT = 4295128739;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;

    MathPropertiesHarness internal h;

    function setUp() public {
        h = new MathPropertiesHarness();
    }

    // ------------------------------------------------------------------------------------------------------------
    // SqrtPriceMath
    // ------------------------------------------------------------------------------------------------------------

    function test_sqrt_price_anchor_values() public view {
        assertEq(h.sqrtAt(0), 1 << 96, "price 1.0 is exactly 2**96");
        assertEq(h.sqrtAt(MIN_TICK), MIN_SQRT);
        assertEq(h.sqrtAt(MAX_TICK), MAX_SQRT);
    }

    function testFuzz_sqrt_price_is_strictly_increasing(int24 tick) public view {
        tick = int24(bound(int256(tick), int256(MIN_TICK), int256(MAX_TICK) - 1));
        assertLt(h.sqrtAt(tick), h.sqrtAt(tick + 1));
    }

    /**
     * @dev Consecutive ticks differ by exactly sqrt(1.0001) = 1.00004999875006250..., within 1e-9 relative.
     */
    function testFuzz_sqrt_price_step_is_sqrt_of_1_0001(int24 tick) public view {
        tick = int24(bound(int256(tick), int256(MIN_TICK), int256(MAX_TICK) - 1));
        uint256 ratio = Math.mulDiv(h.sqrtAt(tick + 1), 1e18, h.sqrtAt(tick));
        assertApproxEqAbs(ratio, 1_000_049_998_750_062_500, 1e9);
    }

    /**
     * @dev price(t) * price(-t) = 1, so sqrtPrice(t) * sqrtPrice(-t) = 2**192, within 1e-9 relative.
     */
    function testFuzz_sqrt_price_is_symmetric_around_tick_zero(int24 tick) public view {
        tick = int24(bound(int256(tick), 0, int256(MAX_TICK)));
        uint256 product = uint256(h.sqrtAt(tick)) * uint256(h.sqrtAt(-tick));
        uint256 diff = product > (1 << 192) ? product - (1 << 192) : (1 << 192) - product;
        assertEq(Math.mulDiv(diff, 1e9, 1 << 192), 0, "product must be 2**192 within 1e-9");
    }

    function testFuzz_ticks_outside_the_supported_range_revert(int24 seed, bool above) public {
        int24 tick = above
            ? int24(bound(int256(seed), int256(MAX_TICK) + 1, int256(type(int24).max)))
            : int24(bound(int256(seed), int256(type(int24).min), int256(MIN_TICK) - 1));
        vm.expectRevert(SqrtPriceMath.InvalidTick.selector);
        h.sqrtAt(tick);
    }

    // ------------------------------------------------------------------------------------------------------------
    // LiquidityMath
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Amounts computed back from a liquidity never exceed the amounts used to compute it, over the full tick
     *      domain and the full uint256 amount domain. Overflow must revert, never silently truncate.
     */
    function testFuzz_round_trip_never_exceeds_inputs(int24 tA, int24 tB, int24 tP, uint256 a0, uint256 a1)
        public
        view
    {
        (uint160 sp, uint160 sa, uint160 sb) = _prices(tA, tB, tP);
        try h.liquidityFor(sp, sa, sb, a0, a1) returns (uint128 liquidity) {
            (uint256 x, uint256 y) = h.amountsFor(sp, sa, sb, liquidity);
            assertLe(x, a0, "token0 required exceeds token0 supplied");
            assertLe(y, a1, "token1 required exceeds token1 supplied");
        } catch {}
    }

    function testFuzz_liquidity_is_monotonic_in_amounts(
        int24 tA,
        int24 tB,
        int24 tP,
        uint128 a0,
        uint128 a1,
        uint64 d0,
        uint64 d1
    ) public view {
        (uint160 sp, uint160 sa, uint160 sb) = _prices(tA, tB, tP);
        try h.liquidityFor(sp, sa, sb, a0, a1) returns (uint128 base) {
            try h.liquidityFor(sp, sa, sb, uint256(a0) + d0, uint256(a1) + d1) returns (uint128 more) {
                assertGe(more, base);
            } catch {}
        } catch {}
    }

    /**
     * @dev Splitting a deposit in two never yields more liquidity than depositing it whole (floor rounding only
     *      ever loses dust), so there is no profit from splitting.
     */
    function testFuzz_liquidity_is_superadditive(
        int24 tA,
        int24 tB,
        int24 tP,
        uint64 a0,
        uint64 a1,
        uint64 b0,
        uint64 b1
    ) public view {
        (uint160 sp, uint160 sa, uint160 sb) = _prices(tA, tB, tP);
        try h.liquidityFor(sp, sa, sb, uint256(a0) + b0, uint256(a1) + b1) returns (uint128 whole) {
            uint256 parts = uint256(h.liquidityFor(sp, sa, sb, a0, a1)) + h.liquidityFor(sp, sa, sb, b0, b1);
            assertGe(whole, parts);
        } catch {}
    }

    function testFuzz_amounts_are_monotonic_in_liquidity(int24 tA, int24 tB, int24 tP, uint128 l1, uint128 l2)
        public
        view
    {
        (uint160 sp, uint160 sa, uint160 sb) = _prices(tA, tB, tP);
        (l1, l2) = l1 <= l2 ? (l1, l2) : (l2, l1);
        (uint256 x1, uint256 y1) = h.amountsFor(sp, sa, sb, l1);
        (uint256 x2, uint256 y2) = h.amountsFor(sp, sa, sb, l2);
        assertLe(x1, x2);
        assertLe(y1, y2);
    }

    function testFuzz_range_endpoint_order_is_irrelevant(int24 tA, int24 tB, int24 tP, uint128 a0, uint128 a1) public {
        (uint160 sp, uint160 sa, uint160 sb) = _prices(tA, tB, tP);
        try h.liquidityFor(sp, sa, sb, a0, a1) returns (uint128 forward) {
            assertEq(h.liquidityFor(sp, sb, sa, a0, a1), forward);
        } catch {
            vm.expectRevert();
            h.liquidityFor(sp, sb, sa, a0, a1);
        }
        (uint256 x, uint256 y) = h.amountsFor(sp, sa, sb, uint128(a0));
        (uint256 xr, uint256 yr) = h.amountsFor(sp, sb, sa, uint128(a0));
        assertEq(x, xr);
        assertEq(y, yr);
    }

    /**
     * @dev Below the range a position is entirely token0, above it entirely token1, and the "wrong" token is
     *      ignored when computing liquidity.
     */
    function testFuzz_single_sided_outside_the_range(int24 tA, int24 tB, uint128 a0, uint128 a1, uint128 liquidity)
        public
        view
    {
        (, uint160 sa, uint160 sb) = _prices(tA, tB, 0);

        (uint256 x, uint256 y) = h.amountsFor(sa, sa, sb, liquidity); // price exactly at the lower bound
        assertEq(y, 0);
        (x, y) = h.amountsFor(sb, sa, sb, liquidity); // price exactly at the upper bound
        assertEq(x, 0);

        try h.liquidityFor(sa, sa, sb, a0, a1) returns (uint128 below) {
            assertEq(below, h.liquidityFor(sa, sa, sb, a0, 0), "token1 must be ignored below the range");
        } catch {}
        try h.liquidityFor(sb, sa, sb, a0, a1) returns (uint128 above) {
            assertEq(above, h.liquidityFor(sb, sa, sb, 0, a1), "token0 must be ignored above the range");
        } catch {}
    }

    function testFuzz_zero_in_zero_out(int24 tA, int24 tB, int24 tP) public view {
        (uint160 sp, uint160 sa, uint160 sb) = _prices(tA, tB, tP);
        assertEq(h.liquidityFor(sp, sa, sb, 0, 0), 0);
        (uint256 x, uint256 y) = h.amountsFor(sp, sa, sb, 0);
        assertEq(x, 0);
        assertEq(y, 0);
    }

    /**
     * @dev A zero lower bound would divide by zero in token0 maths; it must be rejected up front for every price
     *      position, even when the upper bound is valid, and not only when both bounds are equal.
     */
    function test_a_zero_price_bound_is_rejected_even_when_the_other_bound_is_valid() public {
        uint160 valid = h.sqrtAt(0);
        uint160[3] memory prices = [uint160(1), valid, MAX_SQRT];
        for (uint256 i; i < prices.length; ++i) {
            vm.expectRevert(LiquidityMath.InvalidPriceRange.selector);
            h.liquidityFor(prices[i], 0, valid, 1e18, 1e18);
            vm.expectRevert(LiquidityMath.InvalidPriceRange.selector);
            h.amountsFor(prices[i], 0, valid, 1e18);
            vm.expectRevert(LiquidityMath.InvalidPriceRange.selector);
            h.liquidityFor(prices[i], valid, 0, 1e18, 1e18); // reversed order
        }
    }

    function test_overflowing_inputs_revert_instead_of_truncating() public {
        uint160 sa = h.sqrtAt(0);
        uint160 sb = h.sqrtAt(1); // the narrowest possible range
        vm.expectRevert();
        h.liquidityFor(sb, sa, sb, 0, type(uint256).max);
        vm.expectRevert();
        h.liquidityFor(sa, sa, sb, type(uint256).max, 0);
    }

    /**
     * @dev Over the whole tick domain our liquidity math agrees with Uniswap's, including when both overflow.
     */
    function testFuzz_liquidity_matches_v4_over_the_full_tick_domain(
        int24 tA,
        int24 tB,
        int24 tP,
        uint128 a0,
        uint128 a1
    ) public view {
        (uint160 sp, uint160 sa, uint160 sb) = _prices(tA, tB, tP);
        bool oursOk;
        bool theirsOk;
        uint128 ours;
        uint128 theirs;
        try h.liquidityFor(sp, sa, sb, a0, a1) returns (uint128 value) {
            oursOk = true;
            ours = value;
        } catch {}
        try h.v4LiquidityFor(sp, sa, sb, a0, a1) returns (uint128 value) {
            theirsOk = true;
            theirs = value;
        } catch {}
        assertEq(oursOk, theirsOk, "revert behaviour must match Uniswap");
        if (oursOk) assertEq(ours, theirs);
    }

    // ------------------------------------------------------------------------------------------------------------
    // PoolIdLib
    // ------------------------------------------------------------------------------------------------------------

    function testFuzz_pool_id_matches_v4_for_any_key(address c0, address c1, uint24 fee, int24 spacing, address hooks)
        public
        pure
    {
        PoolKey memory ours = PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, hooks);
        V4PoolKey memory theirs = V4PoolKey(V4Currency.wrap(c0), V4Currency.wrap(c1), fee, spacing, IHooks(hooks));
        assertEq(PoolIdLib.toId(ours), PoolId.unwrap(PoolIdLibrary.toId(theirs)));
    }

    /**
     * @dev Every one of the five fields participates in the id: changing any single field changes the id.
     */
    function testFuzz_pool_id_depends_on_every_field(address c0, address c1, uint24 fee, int24 spacing, address hooks)
        public
        pure
    {
        PoolKey memory base = PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, hooks);
        bytes32 id = PoolIdLib.toId(base);

        PoolKey memory k = base;
        k.currency0 = Currency.wrap(address(uint160(c0) ^ 1));
        assertTrue(PoolIdLib.toId(k) != id);

        k = base;
        k.currency1 = Currency.wrap(address(uint160(c1) ^ 1));
        assertTrue(PoolIdLib.toId(k) != id);

        k = base;
        k.fee = fee ^ 1;
        assertTrue(PoolIdLib.toId(k) != id);

        k = base;
        k.tickSpacing = spacing ^ 1;
        assertTrue(PoolIdLib.toId(k) != id);

        k = base;
        k.hooks = address(uint160(hooks) ^ 1);
        assertTrue(PoolIdLib.toId(k) != id);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Turns arbitrary ticks into a valid (current, lower, upper) sqrt price triple over the full domain with
     *      lower < upper strictly.
     */
    function _prices(int24 tA, int24 tB, int24 tP) internal view returns (uint160 sp, uint160 sa, uint160 sb) {
        int24 lower = int24(bound(int256(tA), int256(MIN_TICK), int256(MAX_TICK) - 1));
        int24 upper = int24(bound(int256(tB), int256(lower) + 1, int256(MAX_TICK)));
        int24 current = int24(bound(int256(tP), int256(MIN_TICK), int256(MAX_TICK)));
        sa = h.sqrtAt(lower);
        sb = h.sqrtAt(upper);
        sp = h.sqrtAt(current);
    }
}
