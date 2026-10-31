// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LiquidityAmounts} from "uni-test/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath as V4TickMath} from "uni-test/v4-core/src/libraries/TickMath.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {Band} from "../../src/libraries/Types.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {DepositPlanner} from "../utils/DepositPlanner.sol";
import {BandRules} from "../utils/BandRules.sol";

/**
 * @dev Cross-milestone properties: ShapeLibrary (M3) bands and weights fed through LiquidityMath/SqrtPriceMath (M1)
 *      the way the vault will (guide 5.1/5.3), for any pool price, shape, range and budgets.
 */
contract DepositPlanPropertiesTest is Test {
    ShapeLibrary internal shapes;

    function setUp() public {
        shapes = new ShapeLibrary();
    }

    struct Scenario {
        uint8 shape;
        int24 center;
        int24 left;
        int24 right;
        int24 spacing;
        int24 priceTick;
        uint256 a0;
        uint256 a1;
    }

    function _scenario(
        uint8 shapeSeed,
        int24 centerSeed,
        uint256 leftSeed,
        uint256 rightSeed,
        uint256 spacingSeed,
        int24 priceSeed,
        uint256 a0,
        uint256 a1
    ) internal pure returns (Scenario memory s) {
        s.shape = uint8(bound(uint256(shapeSeed), 0, 7));
        s.spacing = int24(int256(bound(spacingSeed, 1, 200)));
        s.center = int24(bound(int256(centerSeed), -880_000, 880_000));
        s.left = int24(int256(bound(leftSeed, 0, 300_000)));
        s.right = int24(int256(bound(rightSeed, 0, 300_000)));
        s.priceTick = int24(bound(int256(priceSeed), -887_272, 887_272));
        s.a0 = a0;
        s.a1 = a1;
    }

    /**
     * @dev Whatever the budgets and wherever the price is, the planned liquidity never needs more than the
     *      budgets (rounded-down maths), so the vault can never over-pull from a depositor on this path.
     */
    function testFuzz_plan_never_exceeds_the_budgets(
        uint8 shapeSeed,
        int24 centerSeed,
        uint256 leftSeed,
        uint256 rightSeed,
        uint256 spacingSeed,
        int24 priceSeed,
        uint128 a0,
        uint128 a1
    ) public view {
        Scenario memory s = _scenario(
            shapeSeed, centerSeed, leftSeed, rightSeed, spacingSeed, priceSeed, uint256(a0), uint256(a1)
        );
        (bool ok, bytes memory ret) = address(shapes)
            .staticcall(abi.encodeCall(ShapeLibrary.computeBands, (s.shape, s.center, s.left, s.right, s.spacing)));
        if (!ok) return;
        (Band[] memory bands, uint16[] memory weights) = abi.decode(ret, (Band[], uint16[]));
        uint160 sp = SqrtPriceMath.getSqrtPriceAtTick(s.priceTick);

        try this.planAndRequire(sp, bands, weights, s.a0, s.a1) returns (uint256 need0, uint256 need1, uint256) {
            assertLe(need0, s.a0, "token0 requirement above budget");
            assertLe(need1, s.a1, "token1 requirement above budget");
        } catch {
            // overflow of uint128 liquidity is allowed to revert, but never to return a wrong plan
        }
    }

    /**
     * @dev With realistic budgets the scarcer token is used almost completely (the rest is rounding dust), so the
     *      deposit is not silently under-deployed.
     */
    function testFuzz_plan_uses_the_scarcer_token_almost_completely(
        uint8 shapeSeed,
        int24 centerSeed,
        uint256 leftSeed,
        uint256 rightSeed,
        uint256 spacingSeed,
        int24 priceSeed,
        uint256 a0Seed,
        uint256 a1Seed
    ) public view {
        Scenario memory s = _scenario(shapeSeed, centerSeed, leftSeed, rightSeed, spacingSeed, priceSeed, 0, 0);
        s.a0 = bound(a0Seed, 1e18, 1e27);
        s.a1 = bound(a1Seed, 1e18, 1e27);
        (bool ok, bytes memory ret) = address(shapes)
            .staticcall(abi.encodeCall(ShapeLibrary.computeBands, (s.shape, s.center, s.left, s.right, s.spacing)));
        if (!ok) return;
        (Band[] memory bands, uint16[] memory weights) = abi.decode(ret, (Band[], uint16[]));
        uint160 sp = SqrtPriceMath.getSqrtPriceAtTick(s.priceTick);

        try this.planAndRequire(sp, bands, weights, s.a0, s.a1) returns (
            uint256 need0, uint256 need1, uint256 minLiquidity
        ) {
            // at least one of the two budgets is used to within a few parts per million, unless the position
            // needs so little of that token that nothing meaningful is being deployed at all
            // At extreme low raw prices floor(sa * sb / 2^96) is a tiny integer, which Uniswap's own formula shares and which
            // costs up to 50% of token0 (see test_known_issue_liquidity_for_amounts_loses_precision_at_extreme_low_prices).
            if (_lowPrecisionRegime(bands)) return;
            // When one unit of liquidity is a visible fraction of the budget (a full-range band at a tiny price: one unit
            // can be worth 1.8e19 wei), integer granularity dominates and no planner can do better.
            if (minLiquidity < 1e6) return;
            // A token that the position needs only a few units of (an extreme price) limits liquidity by integer
            // granularity: one wei of a 3,700 wei requirement is already 0.03% of the position. No planner can do
            // better there, so such regimes are excluded from the utilisation property.
            // (A requirement of exactly zero is real only when the price is outside the whole range; inside the
            // range it can also mean "less than one wei", which is the same granularity effect.)
            bool oneSided = s.priceTick <= bands[0].tickLower || s.priceTick >= bands[bands.length - 1].tickUpper;
            if (!oneSided && (need0 < 1e9 || need1 < 1e9)) return;
            if (oneSided && ((need0 > 0 && need0 < 1e9) || (need1 > 0 && need1 < 1e9))) return;
            bool token0Tight = need0 + s.a0 / 100_000 >= s.a0;
            bool token1Tight = need1 + s.a1 / 100_000 >= s.a1;
            bool nothingDeployed = need0 == 0 && need1 == 0;
            assertTrue(token0Tight || token1Tight || nothingDeployed, "neither budget is close to fully used");
        } catch {}
    }

    /**
     * @dev DOCUMENTED HAZARD for M4 (witness found by the fuzzer). Scaling a unit liquidity by the weights rounds the
     *      unit amounts down once and then multiplies the error up, so the plan can need slightly more than the
     *      budget. In this witness the excess is about 3e8 units on a budget of 1.9e26 (1.5e-18 relative), harmless
     *      in size but a guaranteed revert if the amount were passed to Uniswap as a hard maximum. The guide's method
     *      (allot amounts per band, then `liquidityForAmounts`) never exceeds the budget.
     */
    function test_naive_unit_scaling_overshoots_a_budget_but_the_guide_method_does_not() public view {
        Scenario memory s = _scenario(
            19,
            -54,
            26_118_355_617_800_564_958_128,
            788_520_410_146,
            36_294_695_847_481_933_054_787,
            3,
            189_125_644_476_866_345_464_498_259,
            76_395_137_297_915_652_857_096_704_167
        );
        (Band[] memory bands, uint16[] memory weights) =
            shapes.computeBands(s.shape, s.center, s.left, s.right, s.spacing);
        uint160 sp = SqrtPriceMath.getSqrtPriceAtTick(s.priceTick);

        (uint256 naiveNeed0,) =
            DepositPlanner.required(sp, bands, DepositPlanner.planNaive(sp, bands, weights, s.a0, s.a1));
        assertGt(naiveNeed0, s.a0, "witness: the naive plan needs more token0 than the budget");

        (uint256 need0, uint256 need1) =
            DepositPlanner.required(sp, bands, DepositPlanner.plan(sp, bands, weights, s.a0, s.a1));
        assertLe(need0, s.a0, "the guide method respects the token0 budget");
        assertLe(need1, s.a1, "the guide method respects the token1 budget");
    }

    /**
     * @dev DOCUMENTED PRECISION HAZARD for M4 (witness found by the fuzzer). With the price far above the range the
     *      weighted unit amounts of token1 are around 1e39, so a scale rounded to 1e18 fixed point is a small integer
     *      (about 1.4e5) and rounding it loses about 2e-5 of the budget. Keeping the scale as the ratio
     *      `budget / total` and applying it in one `mulDiv` loses under 2e-9, which is the integer granularity of a liquidity of only ~1e8.
     */
    function test_rounding_the_scale_to_fixed_point_wastes_budget_at_extreme_prices() public view {
        (Band[] memory bands, uint16[] memory weights) = shapes.computeBands(0, 845_209, 99_732, 3, 200);
        uint160 sp = SqrtPriceMath.getSqrtPriceAtTick(865_219); // far above the whole range
        uint256 a0 = 1e18;
        uint256 a1 = 139_424_544_719_819_440_924_125_998;

        (, uint256 naiveNeed1) =
            DepositPlanner.required(sp, bands, DepositPlanner.planNaive(sp, bands, weights, a0, a1));
        (, uint256 need1) = DepositPlanner.required(sp, bands, DepositPlanner.plan(sp, bands, weights, a0, a1));

        assertLt(naiveNeed1 * 1_000_000, a1 * 999_999, "fixed-point scaling leaves more than 1e-6 of the budget unused");
        assertGe(
            need1 * 10_000_000, a1 * 9_999_999, "ratio scaling deploys to within 1e-7 (limited by integer liquidity)"
        );
        assertLe(need1, a1);
    }

    /**
     * @dev True when some band's `floor(sa * sb / 2^96)` is small enough for that floor to cost more than ~1e-9.
     */
    function _lowPrecisionRegime(Band[] memory bands) internal pure returns (bool) {
        for (uint256 i; i < bands.length; ++i) {
            uint160 sa = SqrtPriceMath.getSqrtPriceAtTick(bands[i].tickLower);
            uint160 sb = SqrtPriceMath.getSqrtPriceAtTick(bands[i].tickUpper);
            if (Math.mulDiv(sa, sb, 1 << 96) < 1e9) return true;
        }
        return false;
    }

    /**
     * @dev KNOWN LIMITATION (inherited from Uniswap, informational). `liquidityForAmounts` computes
     *      `amount0 * floor(sa * sb / 2^96) / (sb - sa)`. When the raw price is tiny (here about 2.5e-29, tick
     *      -659,271) the floored intermediate is 1 or 2 and the result can be off by tens of percent, so token0 is
     *      under-deployed (and refunded) instead of lost. Our function equals Uniswap's `LiquidityAmounts` on this
     *      witness, so it is not a defect of M1; a two-step `mulDiv(mulDiv(a0, sa, sb - sa), sb, 2^96)` would be more
     *      accurate, but would no longer match Uniswap bit for bit.
     */
    function test_known_issue_liquidity_for_amounts_loses_precision_at_extreme_low_prices() public pure {
        uint160 sa = SqrtPriceMath.getSqrtPriceAtTick(-666_496);
        uint160 sb = SqrtPriceMath.getSqrtPriceAtTick(-659_116);
        uint160 sp = SqrtPriceMath.getSqrtPriceAtTick(-880_000); // below the band: only token0
        uint256 a0 = 4e18;

        uint128 ours = LiquidityMath.liquidityForAmounts(sp, sa, sb, a0, 0);
        uint128 uniswap = LiquidityAmounts.getLiquidityForAmounts(sp, sa, sb, a0, 0);
        assertEq(ours, uniswap, "identical to Uniswap's own function");

        uint256 accurate = Math.mulDiv(Math.mulDiv(a0, sa, sb - sa), sb, 1 << 96);
        assertGt(uint256(accurate), uint256(ours) * 125 / 100, "a more accurate formula would deploy at least 25% more");
        (uint256 used,) = LiquidityMath.amountsForLiquidity(sp, sa, sb, ours);
        assertLt(used, a0 * 80 / 100, "about a quarter of the token0 budget is left undeployed");
    }

    /**
     * @dev External so that the property tests can observe reverts with try/catch.
     */
    function planAndRequire(uint160 sp, Band[] memory bands, uint16[] memory weights, uint256 a0, uint256 a1)
        external
        pure
        returns (uint256, uint256, uint256)
    {
        uint128[] memory liquidities = DepositPlanner.plan(sp, bands, weights, a0, a1);
        uint256 minLiquidity = type(uint256).max;
        for (uint256 i; i < liquidities.length; ++i) {
            if (liquidities[i] != 0 && liquidities[i] < minLiquidity) minLiquidity = liquidities[i];
        }
        (uint256 need0, uint256 need1) = DepositPlanner.required(sp, bands, liquidities);
        return (need0, need1, minLiquidity);
    }

    /**
     * @dev Bands entirely above the price need only token0, those entirely below only token1 (guide 5.3), so a
     *      one-sided budget deploys into exactly the matching bands and never asks for the other token.
     */
    function testFuzz_a_one_token_budget_is_planned_without_the_other_token(
        uint8 shapeSeed,
        int24 centerSeed,
        uint256 leftSeed,
        uint256 rightSeed,
        uint256 spacingSeed,
        uint256 amountSeed
    ) public view {
        Scenario memory s = _scenario(shapeSeed, centerSeed, leftSeed, rightSeed, spacingSeed, 0, 0, 0);
        (bool ok, bytes memory ret) = address(shapes)
            .staticcall(abi.encodeCall(ShapeLibrary.computeBands, (s.shape, s.center, s.left, s.right, s.spacing)));
        if (!ok) return;
        (Band[] memory bands, uint16[] memory weights) = abi.decode(ret, (Band[], uint16[]));

        // put the price just below the whole range: only token0 is required
        int24 below = bands[0].tickLower;
        if (below <= -887_272) return;
        uint160 sp = SqrtPriceMath.getSqrtPriceAtTick(below - 1);
        uint256 amount = bound(amountSeed, 1e18, 1e27);
        try this.planAndRequire(sp, bands, weights, amount, 0) returns (uint256 need0, uint256 need1, uint256) {
            assertEq(need1, 0, "range above the price must not require token1");
            assertLe(need0, amount);
        } catch {}
    }
}
