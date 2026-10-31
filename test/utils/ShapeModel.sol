// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IShapeLibrary} from "../../src/interfaces/IShapeLibrary.sol";
import {Band} from "../../src/libraries/Types.sol";

/**
 * @dev An independent executable specification of `ShapeLibrary.computeBands`, written from the developer guide
 *      (section 5.2) in a deliberately different formulation from the implementation: everything is computed in
 *      units of tick spacings, floor division uses a positive remainder, ceiling division uses the
 *      `floor((a + b - 1) / b)` identity, and widths are derived from edge indices.
 */
library ShapeModel {
    uint8 internal constant OK = 0;
    uint8 internal constant INVALID_SHAPE = 1;
    uint8 internal constant INVALID_INPUT = 2;
    uint8 internal constant EMPTY_RANGE = 3;

    int256 internal constant EDGE = 887_272;

    function selectorFor(uint8 status) internal pure returns (bytes4) {
        if (status == INVALID_SHAPE) return IShapeLibrary.InvalidShape.selector;
        if (status == INVALID_INPUT) return IShapeLibrary.InvalidInput.selector;
        if (status == EMPTY_RANGE) return IShapeLibrary.EmptyRange.selector;
        return bytes4(0);
    }

    function compute(uint8 shapeId, int24 center, int24 left, int24 right, int24 spacing)
        internal
        pure
        returns (uint8 status, Band[] memory bands, uint16[] memory weights)
    {
        if (shapeId > 7) return (INVALID_SHAPE, bands, weights);
        if (spacing <= 0 || left < 0 || right < 0) return (INVALID_INPUT, bands, weights);

        int256 s = spacing;
        // usable range in spacing units
        int256 minU = -fdiv(EDGE, s); // ceil(-EDGE / s) == -floor(EDGE / s)
        int256 maxU = fdiv(EDGE, s);

        int256 lowU;
        int256 upU;
        if (shapeId == 5) {
            lowU = fdiv(center, s);
            upU = lowU + 1;
        } else if (shapeId == 6) {
            lowU = minU;
            upU = maxU;
        } else {
            lowU = fdiv(int256(center) - int256(left), s);
            upU = fdiv(int256(center) + int256(right) + s - 1, s);
        }
        if (lowU < minU) lowU = minU;
        if (upU > maxU) upU = maxU;
        if (upU <= lowU) return (EMPTY_RANGE, bands, weights);

        uint256 steps = uint256(upU - lowU);
        uint256 n;
        (n, weights) = nominal(shapeId);
        if (steps < n) {
            n = steps;
            weights = uniform(n);
        }

        uint256 per = steps / n;
        bands = new Band[](n);
        for (uint256 i; i < n; ++i) {
            int256 a = lowU + int256(i * per);
            int256 b = i + 1 == n ? upU : a + int256(per);
            bands[i] = Band({tickLower: int24(a * s), tickUpper: int24(b * s), tokenId: 0, liquidity: 0});
        }
        return (OK, bands, weights);
    }

    /**
     * @dev Weight tables from the guide, section 5.1.
     */
    function nominal(uint8 shapeId) internal pure returns (uint256 n, uint16[] memory w) {
        if (shapeId == 0) {
            w = new uint16[](5);
            (w[0], w[1], w[2], w[3], w[4]) = (1000, 2000, 4000, 2000, 1000);
        } else if (shapeId == 2) {
            w = new uint16[](3);
            (w[0], w[1], w[2]) = (2500, 5000, 2500);
        } else if (shapeId == 3) {
            w = new uint16[](3);
            (w[0], w[1], w[2]) = (3333, 3334, 3333);
        } else if (shapeId == 4) {
            w = new uint16[](5);
            for (uint256 i; i < 5; ++i) {
                w[i] = 2000;
            }
        } else {
            w = new uint16[](1);
            w[0] = 10_000;
        }
        n = w.length;
    }

    /**
     * @dev Uniform fallback: floor(10000 / n) each, the remainder spread one basis point at a time from the front.
     */
    function uniform(uint256 n) internal pure returns (uint16[] memory w) {
        w = new uint16[](n);
        uint256 base = 10_000 / n;
        uint256 extra = 10_000 - base * n;
        for (uint256 i; i < n; ++i) {
            w[i] = uint16(base + (i < extra ? 1 : 0));
        }
    }

    /**
     * @dev Floor division using a positive remainder (different from the implementation's sign correction).
     */
    function fdiv(int256 a, int256 b) internal pure returns (int256) {
        int256 r = ((a % b) + b) % b; // b > 0 always here
        return (a - r) / b;
    }
}
