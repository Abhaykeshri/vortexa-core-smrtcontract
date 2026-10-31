// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath as V4TickMath} from "uni-test/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "uni-test/v4-core/test/utils/LiquidityAmounts.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";

contract MathDifferentialTest is Test {
    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = 887272;

    function test_tick_boundaries_match_v4() public pure {
        assertEq(SqrtPriceMath.getSqrtPriceAtTick(MIN_TICK), V4TickMath.getSqrtPriceAtTick(MIN_TICK));
        assertEq(SqrtPriceMath.getSqrtPriceAtTick(-1), V4TickMath.getSqrtPriceAtTick(-1));
        assertEq(SqrtPriceMath.getSqrtPriceAtTick(0), V4TickMath.getSqrtPriceAtTick(0));
        assertEq(SqrtPriceMath.getSqrtPriceAtTick(1), V4TickMath.getSqrtPriceAtTick(1));
        assertEq(SqrtPriceMath.getSqrtPriceAtTick(MAX_TICK), V4TickMath.getSqrtPriceAtTick(MAX_TICK));
    }

    function test_tick_samples_match_v4() public pure {
        for (int24 tick = MIN_TICK; tick <= MAX_TICK; tick += 97) {
            assertEq(SqrtPriceMath.getSqrtPriceAtTick(tick), V4TickMath.getSqrtPriceAtTick(tick));
        }
    }

    function testFuzz_tick_matches_v4(int24 tick) public pure {
        tick = int24(bound(int256(tick), int256(MIN_TICK), int256(MAX_TICK)));
        assertEq(SqrtPriceMath.getSqrtPriceAtTick(tick), V4TickMath.getSqrtPriceAtTick(tick));
    }

    function testFuzz_liquidityForAmounts_matches_v4(int24 tickA, int24 tickB, int24 tick, uint128 raw0, uint128 raw1)
        public
        pure
    {
        tickA = int24(bound(int256(tickA), -100000, 99990));
        tickB = int24(bound(int256(tickB), int256(tickA) + 10, 100000));
        tick = int24(bound(int256(tick), -100000, 100000));
        uint256 amount0 = uint256(raw0) % 1e18;
        uint256 amount1 = uint256(raw1) % 1e18;

        uint160 sqrtA = V4TickMath.getSqrtPriceAtTick(tickA);
        uint160 sqrtB = V4TickMath.getSqrtPriceAtTick(tickB);
        uint160 sqrtP = V4TickMath.getSqrtPriceAtTick(tick);

        assertEq(
            LiquidityMath.liquidityForAmounts(sqrtP, sqrtA, sqrtB, amount0, amount1),
            LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtA, sqrtB, amount0, amount1)
        );
    }

    function testFuzz_amountsForLiquidity_match_v4(int24 tickA, int24 tickB, int24 tick, uint128 liquidity)
        public
        pure
    {
        tickA = int24(bound(int256(tickA), -887272, 887262));
        tickB = int24(bound(int256(tickB), int256(tickA) + 10, 887272));
        tick = int24(bound(int256(tick), -887272, 887272));
        uint160 sqrtA = V4TickMath.getSqrtPriceAtTick(tickA);
        uint160 sqrtB = V4TickMath.getSqrtPriceAtTick(tickB);
        uint160 sqrtP = V4TickMath.getSqrtPriceAtTick(tick);

        (uint256 amount0, uint256 amount1) = LiquidityMath.amountsForLiquidity(sqrtP, sqrtA, sqrtB, liquidity);
        (uint256 expected0, uint256 expected1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, liquidity);
        assertApproxEqAbs(amount0, expected0, 1);
        assertApproxEqAbs(amount1, expected1, 1);
    }

    function test_round_trip_amounts_do_not_exceed_inputs() public pure {
        uint160 sqrtA = V4TickMath.getSqrtPriceAtTick(-120);
        uint160 sqrtB = V4TickMath.getSqrtPriceAtTick(180);
        uint160 sqrtP = V4TickMath.getSqrtPriceAtTick(20);
        uint256 amount0 = 1e18;
        uint256 amount1 = 2e18;
        uint128 liquidity = LiquidityMath.liquidityForAmounts(sqrtP, sqrtA, sqrtB, amount0, amount1);
        (uint256 used0, uint256 used1) = LiquidityMath.amountsForLiquidity(sqrtP, sqrtA, sqrtB, liquidity);

        assertLe(used0, amount0);
        assertLe(used1, amount1);
    }
}
