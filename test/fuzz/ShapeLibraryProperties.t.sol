// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IShapeLibrary} from "../../src/interfaces/IShapeLibrary.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {Band} from "../../src/libraries/Types.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {BandRules} from "../utils/BandRules.sol";
import {ShapeModel} from "../utils/ShapeModel.sol";

/**
 * @dev Property tests for ShapeLibrary over the whole input domain: full int24 centers and widths, every tick
 *      spacing up to int24 max (Uniswap v4 allows up to 32,767), negative and zero inputs, and invalid shape ids.
 *      Unlike the older fuzz suite, reverts are never swallowed: each call must either match the independent
 *      `ShapeModel` exactly or revert with exactly the error the model predicts.
 */
contract ShapeLibraryPropertiesTest is Test {
    ShapeLibrary internal shapes;

    struct Args {
        uint8 shape;
        int24 center;
        int24 left;
        int24 right;
        int24 spacing;
    }

    function setUp() public {
        shapes = new ShapeLibrary();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Exact specification
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Output and revert reason equal the independent model for every input, including invalid ones.
     */
    function testFuzz_matches_the_independent_specification(
        uint8 shapeSeed,
        int24 center,
        uint256 leftSeed,
        uint256 rightSeed,
        uint256 spacingSeed
    ) public view {
        Args memory a = _args(shapeSeed, center, leftSeed, rightSeed, spacingSeed);
        (uint8 status, Band[] memory expectedBands, uint16[] memory expectedWeights) =
            ShapeModel.compute(a.shape, a.center, a.left, a.right, a.spacing);
        (bool ok, bytes memory ret) = _call(a);

        if (status != ShapeModel.OK) {
            assertFalse(ok, "model says revert but the call succeeded");
            assertEq(bytes4(ret), ShapeModel.selectorFor(status), "wrong revert reason");
            return;
        }
        assertTrue(ok, "model says success but the call reverted");
        (Band[] memory bands, uint16[] memory weights) = abi.decode(ret, (Band[], uint16[]));
        assertEq(keccak256(abi.encode(bands)), keccak256(abi.encode(expectedBands)), "bands differ from the model");
        assertEq(keccak256(abi.encode(weights)), keccak256(abi.encode(expectedWeights)), "weights differ");
    }

    /**
     * @dev Every successful result passes the checks the vault must repeat before minting (guide 5.3 and 9.5).
     */
    function testFuzz_every_result_passes_the_vault_recheck(
        uint8 shapeSeed,
        int24 center,
        uint256 leftSeed,
        uint256 rightSeed,
        uint256 spacingSeed
    ) public view {
        Args memory a = _args(shapeSeed, center, leftSeed, rightSeed, spacingSeed);
        (bool ok, bytes memory ret) = _call(a);
        if (!ok) return;
        (Band[] memory bands, uint16[] memory weights) = abi.decode(ret, (Band[], uint16[]));
        assertEq(BandRules.check(bands, weights, a.spacing, shapes.maxBands()), "");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Shape-table fidelity and band widths
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev With enough room the band count and weights are exactly the guide's table; otherwise the band count is
     *      the number of spacings available with uniform weights.
     */
    function testFuzz_band_count_and_weights_follow_the_guide_table(
        uint8 shapeSeed,
        int24 center,
        uint256 leftSeed,
        uint256 rightSeed,
        uint256 spacingSeed
    ) public view {
        Args memory a = _args(shapeSeed, center, leftSeed, rightSeed, spacingSeed);
        (bool ok, bytes memory ret) = _call(a);
        if (!ok) return;
        (Band[] memory bands, uint16[] memory weights) = abi.decode(ret, (Band[], uint16[]));

        uint256[8] memory nominalCount = [uint256(5), 1, 3, 3, 5, 1, 1, 1];
        uint256 spacingsAvailable =
            uint256(int256(bands[bands.length - 1].tickUpper) - bands[0].tickLower) / uint256(int256(a.spacing));
        if (spacingsAvailable >= nominalCount[a.shape]) {
            assertEq(bands.length, nominalCount[a.shape]);
            (, uint16[] memory table) = ShapeModel.nominal(a.shape);
            assertEq(keccak256(abi.encode(weights)), keccak256(abi.encode(table)));
        } else {
            assertEq(bands.length, spacingsAvailable);
            assertEq(keccak256(abi.encode(weights)), keccak256(abi.encode(ShapeModel.uniform(bands.length))));
        }
    }

    /**
     * @dev Every band except the last has the regular width floor(steps / n); the last absorbs the remainder.
     */
    function testFuzz_only_the_last_band_absorbs_the_remainder(
        uint8 shapeSeed,
        int24 center,
        uint256 leftSeed,
        uint256 rightSeed,
        uint256 spacingSeed
    ) public view {
        Args memory a = _args(shapeSeed, center, leftSeed, rightSeed, spacingSeed);
        (bool ok, bytes memory ret) = _call(a);
        if (!ok) return;
        (Band[] memory bands,) = abi.decode(ret, (Band[], uint16[]));

        uint256 n = bands.length;
        uint256 s = uint256(int256(a.spacing));
        uint256 steps = uint256(int256(bands[n - 1].tickUpper) - bands[0].tickLower) / s;
        uint256 regular = steps / n;
        for (uint256 i; i + 1 < n; ++i) {
            assertEq(uint256(int256(bands[i].tickUpper) - bands[i].tickLower) / s, regular, "regular band width");
        }
        assertEq(uint256(int256(bands[n - 1].tickUpper) - bands[n - 1].tickLower) / s, regular + steps % n);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Coverage of the requested range (what the strategies rely on)
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Unless clamped by the usable range, the bands cover [center - left, center + right] and overshoot by
     *      less than one tick spacing on each side.
     */
    function testFuzz_bands_cover_the_requested_range_tightly(
        uint8 shapeSeed,
        int24 center,
        uint256 leftSeed,
        uint256 rightSeed,
        uint256 spacingSeed
    ) public view {
        Args memory a = _args(shapeSeed, center, leftSeed, rightSeed, spacingSeed);
        if (a.shape == 5 || a.shape == 6) return;
        (bool ok, bytes memory ret) = _call(a);
        if (!ok) return;
        (Band[] memory bands,) = abi.decode(ret, (Band[], uint16[]));

        int256 s = a.spacing;
        int256 want0 = int256(a.center) - a.left;
        int256 want1 = int256(a.center) + a.right;
        int256 minUsable = -(887_272 / s) * s;
        int256 maxUsable = (887_272 / s) * s;
        if (want0 >= minUsable) {
            assertLe(bands[0].tickLower, want0, "lower edge must not be above the requested lower tick");
            assertGt(int256(bands[0].tickLower) + s, want0, "lower edge overshoots by a full spacing or more");
        }
        if (want1 <= maxUsable) {
            int256 top = bands[bands.length - 1].tickUpper;
            assertGe(top, want1, "upper edge must not be below the requested upper tick");
            assertLt(top - s, want1, "upper edge overshoots by a full spacing or more");
        }
    }

    /**
     * @dev M7 contract. A one-sided range anchored at an aligned tick ends exactly at the anchor (left only) or
     *      starts exactly at it (right only), so a range anchored at floor(tick) never reaches above the pool tick
     *      and one anchored at ceil(tick + 1) always starts above it.
     */
    function testFuzz_one_sided_ranges_stay_strictly_on_their_side_of_the_pool_tick(
        uint8 shapeSeed,
        int24 tickSeed,
        uint256 widthSeed,
        uint256 spacingSeed
    ) public view {
        uint8[4] memory uniformShapes = [uint8(3), 4, 7, 1];
        uint8 shape = uniformShapes[shapeSeed % 4];
        int24 spacing = _spacing(spacingSeed);
        if (spacing <= 0) return;
        int256 s = spacing;
        int24 tick = int24(bound(int256(tickSeed), -887_272, 887_272));
        int24 width = int24(int256(bound(widthSeed, 1, 200_000)));

        int256 anchorBelow = ShapeModel.fdiv(tick, s) * s; // floor: top edge, so tick >= anchor
        int256 anchorAbove = ShapeModel.fdiv(int256(tick) + 1 + s - 1, s) * s; // ceil(tick + 1): bottom edge

        if (anchorBelow >= -887_272 && anchorBelow <= 887_272 && anchorBelow <= int256(type(int24).max)) {
            try shapes.computeBands(shape, int24(anchorBelow), width, 0, spacing) returns (
                Band[] memory bands, uint16[] memory
            ) {
                assertEq(bands[bands.length - 1].tickUpper, anchorBelow, "upper edge is the anchor");
                assertLe(bands[bands.length - 1].tickUpper, tick, "entirely at or below the pool tick");
            } catch {}
        }
        if (anchorAbove >= -887_272 && anchorAbove <= 887_272) {
            try shapes.computeBands(shape, int24(anchorAbove), 0, width, spacing) returns (
                Band[] memory bands, uint16[] memory
            ) {
                assertEq(bands[0].tickLower, anchorAbove, "lower edge is the anchor");
                assertGt(bands[0].tickLower, tick, "entirely above the pool tick");
            } catch {}
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Monotonicity, equivalences, mirroring
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Asking for a wider range never shrinks the covered range.
     */
    function testFuzz_widening_never_shrinks_the_range(
        uint8 shapeSeed,
        int24 center,
        uint256 leftSeed,
        uint256 rightSeed,
        uint256 spacingSeed,
        uint24 extraLeft,
        uint24 extraRight
    ) public view {
        Args memory a = _args(shapeSeed, center, leftSeed, rightSeed, spacingSeed);
        if (a.shape == 5 || a.shape == 6) return;
        if (a.left < 0 || a.right < 0 || a.spacing <= 0) return; // invalid requests are covered elsewhere
        Args memory wider = Args(
            a.shape,
            a.center,
            int24(int256(bound(uint256(extraLeft), uint256(int256(a.left)), uint256(int256(type(int24).max))))),
            int24(int256(bound(uint256(extraRight), uint256(int256(a.right)), uint256(int256(type(int24).max))))),
            a.spacing
        );
        (bool ok1, bytes memory r1) = _call(a);
        (bool ok2, bytes memory r2) = _call(wider);
        if (!ok1 || !ok2) return;
        (Band[] memory b1,) = abi.decode(r1, (Band[], uint16[]));
        (Band[] memory b2,) = abi.decode(r2, (Band[], uint16[]));
        assertLe(b2[0].tickLower, b1[0].tickLower);
        assertGe(b2[b2.length - 1].tickUpper, b1[b1.length - 1].tickUpper);
    }

    function testFuzz_shapes_1_and_7_are_identical(
        int24 center,
        uint256 leftSeed,
        uint256 rightSeed,
        uint256 spacingSeed
    ) public view {
        Args memory a = _args(1, center, leftSeed, rightSeed, spacingSeed);
        (bool okA, bytes memory retA) = _call(a);
        a.shape = 7;
        (bool okB, bytes memory retB) = _call(a);
        assertEq(okA, okB);
        assertEq(keccak256(retA), keccak256(retB));
    }

    function testFuzz_full_range_ignores_center_and_widths(
        int24 centerA,
        int24 centerB,
        uint256 leftSeed,
        uint256 rightSeed,
        uint256 spacingSeed
    ) public view {
        Args memory a = _args(6, centerA, leftSeed, rightSeed, spacingSeed);
        Args memory b = _args(6, centerB, rightSeed, leftSeed, spacingSeed);
        // only compare when both inputs are valid, so the reverts for negative widths do not mask the property
        if (a.left < 0 || a.right < 0 || b.left < 0 || b.right < 0 || a.spacing <= 0) return;
        (bool okA, bytes memory retA) = _call(a);
        (bool okB, bytes memory retB) = _call(b);
        assertEq(okA, okB);
        assertEq(keccak256(retA), keccak256(retB));
    }

    function testFuzz_single_tick_is_one_spacing_at_the_aligned_center(
        int24 center,
        uint256 leftSeed,
        uint256 rightSeed,
        uint256 spacingSeed
    ) public view {
        Args memory a = _args(5, center, leftSeed, rightSeed, spacingSeed);
        (bool ok, bytes memory ret) = _call(a);
        if (!ok) return;
        (Band[] memory bands, uint16[] memory weights) = abi.decode(ret, (Band[], uint16[]));
        assertEq(bands.length, 1);
        assertEq(weights[0], 10_000);
        assertEq(int256(bands[0].tickUpper) - bands[0].tickLower, a.spacing, "exactly one spacing wide");
        assertLe(bands[0].tickLower, a.center, "starts at the center rounded down");
        assertGt(int256(bands[0].tickLower) + a.spacing, a.center, "and contains the center");
    }

    /**
     * @dev Mirroring the request (negate the center, swap the widths) mirrors the covered range exactly, because
     *      floor(-x) = -ceil(x) and the usable range is symmetric. Individual band edges mirror only when the band
     *      width divides evenly; otherwise the remainder moves to the other end (documented asymmetry).
     */
    function testFuzz_mirrored_requests_mirror_the_range(
        uint8 shapeSeed,
        int24 centerSeed,
        uint256 leftSeed,
        uint256 rightSeed,
        uint256 spacingSeed
    ) public view {
        Args memory a = _args(
            shapeSeed, int24(bound(int256(centerSeed), -8_000_000, 8_000_000)), leftSeed, rightSeed, spacingSeed
        );
        if (a.shape == 5) return; // the single-tick anchor is a floor, deliberately not mirror symmetric
        Args memory m = Args(a.shape, -a.center, a.right, a.left, a.spacing); // a copy, not an alias
        (bool ok1, bytes memory r1) = _call(a);
        (bool ok2, bytes memory r2) = _call(m);
        assertEq(ok1, ok2, "mirrored request succeeds or fails together");
        if (!ok1) return;
        (Band[] memory b1, uint16[] memory w1) = abi.decode(r1, (Band[], uint16[]));
        (Band[] memory b2, uint16[] memory w2) = abi.decode(r2, (Band[], uint16[]));

        assertEq(b2[0].tickLower, -b1[b1.length - 1].tickUpper, "range mirrors: lower");
        assertEq(b2[b2.length - 1].tickUpper, -b1[0].tickLower, "range mirrors: upper");
        assertEq(b1.length, b2.length);

        uint256 steps = uint256(int256(b1[b1.length - 1].tickUpper) - b1[0].tickLower) / uint256(int256(a.spacing));
        if (steps % b1.length == 0) {
            for (uint256 i; i < b1.length; ++i) {
                assertEq(b2[i].tickLower, -b1[b1.length - 1 - i].tickUpper, "edges mirror when widths are even");
                // palindromic tables stay palindromic; the uniform fallback is not (its remainder goes first)
                if (a.shape != 1 && a.shape != 7 && a.shape != 6 && steps >= _nominalCount(a.shape)) {
                    assertEq(w1[i], w2[i]);
                    assertEq(w1[i], w1[b1.length - 1 - i], "palindromic weights");
                }
            }
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Integration with the M1 math the vault will use
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Band edges are valid, strictly increasing Uniswap prices, and the amounts of the bands add up to the
     *      amounts of the whole range (rounding only), which proves the bands are contiguous and non-overlapping in
     *      the arithmetic the vault actually uses.
     */
    function testFuzz_band_amounts_add_up_to_the_whole_range(
        uint8 shapeSeed,
        int24 center,
        uint256 leftSeed,
        uint256 rightSeed,
        uint256 spacingSeed,
        int24 priceTick,
        uint128 liquidity
    ) public view {
        Args memory a = _args(shapeSeed, center, leftSeed, rightSeed, spacingSeed);
        (bool ok, bytes memory ret) = _call(a);
        if (!ok) return;
        (Band[] memory bands,) = abi.decode(ret, (Band[], uint16[]));

        uint160 sp = SqrtPriceMath.getSqrtPriceAtTick(int24(bound(int256(priceTick), -887_272, 887_272)));
        uint128 liq = uint128(bound(uint256(liquidity), 1e6, 1e27));

        uint256 sum0;
        uint256 sum1;
        uint160 previous;
        for (uint256 i; i < bands.length; ++i) {
            uint160 sa = SqrtPriceMath.getSqrtPriceAtTick(bands[i].tickLower);
            uint160 sb = SqrtPriceMath.getSqrtPriceAtTick(bands[i].tickUpper);
            assertLt(sa, sb);
            if (i > 0) assertEq(sa, previous, "shared edge has the same price");
            previous = sb;
            (uint256 x, uint256 y) = LiquidityMath.amountsForLiquidity(sp, sa, sb, liq);
            sum0 += x;
            sum1 += y;
        }
        (uint256 whole0, uint256 whole1) = LiquidityMath.amountsForLiquidity(
            sp,
            SqrtPriceMath.getSqrtPriceAtTick(bands[0].tickLower),
            SqrtPriceMath.getSqrtPriceAtTick(bands[bands.length - 1].tickUpper),
            liq
        );
        // each band rounds down once per token, and so does the whole: allow one unit per band plus one
        assertApproxEqAbs(sum0, whole0, bands.length + 1, "token0 amounts do not add up");
        assertApproxEqAbs(sum1, whole1, bands.length + 1, "token1 amounts do not add up");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Gas
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev No input, valid or not, costs more than the guide's 50,000 gas budget.
     */
    function testFuzz_gas_stays_below_50000_for_any_input(
        uint8 shapeSeed,
        int24 center,
        uint256 leftSeed,
        uint256 rightSeed,
        uint256 spacingSeed
    ) public view {
        Args memory a = _args(shapeSeed, center, leftSeed, rightSeed, spacingSeed);
        uint256 before = gasleft();
        _call(a);
        uint256 used = before - gasleft();
        assertLt(used, 50_000);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Input shaping
    // ------------------------------------------------------------------------------------------------------------

    function _call(Args memory a) internal view returns (bool ok, bytes memory ret) {
        return address(shapes)
            .staticcall(abi.encodeCall(IShapeLibrary.computeBands, (a.shape, a.center, a.left, a.right, a.spacing)));
    }

    function _args(uint8 shapeSeed, int24 center, uint256 leftSeed, uint256 rightSeed, uint256 spacingSeed)
        internal
        pure
        returns (Args memory a)
    {
        a.shape = uint8(bound(uint256(shapeSeed), 0, 8)); // 8 is invalid on purpose
        a.center = center;
        a.left = _width(leftSeed);
        a.right = _width(rightSeed);
        a.spacing = _spacing(spacingSeed);
    }

    /**
     * @dev Mix of invalid negatives, zero, small, medium and full-range widths.
     */
    function _width(uint256 seed) internal pure returns (int24) {
        uint256 kind = seed % 8;
        uint256 value = seed / 8;
        if (kind == 0) return -int24(int256(bound(value, 1, 100)));
        if (kind == 1) return 0;
        if (kind <= 4) return int24(int256(bound(value, 1, 5_000)));
        if (kind <= 6) return int24(int256(bound(value, 1, 1_800_000)));
        return int24(int256(bound(value, 0, uint256(int256(type(int24).max)))));
    }

    /**
     * @dev Mix of invalid (<= 0), tiny, common, Uniswap-max (32,767) and absurd spacings.
     */
    function _spacing(uint256 seed) internal pure returns (int24) {
        uint256 kind = seed % 8;
        uint256 value = seed / 8;
        if (kind == 0) return -int24(int256(bound(value, 0, 100)));
        if (kind == 1) return int24(int256(bound(value, 1, 10)));
        if (kind <= 3) return int24(int256(bound(value, 1, 200)));
        if (kind <= 5) return int24(int256(bound(value, 1, 32_767)));
        if (kind == 6) return int24(int256(bound(value, 32_767, 900_000)));
        return int24(int256(bound(value, 1, uint256(int256(type(int24).max)))));
    }

    function _nominalCount(uint8 shape) internal pure returns (uint256) {
        if (shape == 0 || shape == 4) return 5;
        if (shape == 2 || shape == 3) return 3;
        return 1;
    }
}
