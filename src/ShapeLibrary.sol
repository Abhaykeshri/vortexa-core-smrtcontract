// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IShapeLibrary} from "./interfaces/IShapeLibrary.sol";
import {Band} from "./libraries/Types.sol";

/**
 * @title Shape Library
 * @notice Converts preset shape parameters into aligned contiguous liquidity bands and weights.
 * @dev Pure, stateless M3 implementation. All intermediate tick arithmetic uses int256 and casts to int24 only after
 *      clamping to the usable Uniswap tick range.
 */
contract ShapeLibrary is IShapeLibrary {
    /**
     * @notice Minimum global Uniswap tick.
     */
    int256 internal constant MIN_TICK = -887272;
    /**
     * @notice Maximum global Uniswap tick.
     */
    int256 internal constant MAX_TICK = 887272;
    /**
     * @notice Maximum number of bands returned by any preset.
     */
    uint8 internal constant MAX_BANDS = 5;
    /**
     * @notice Sum of all returned relative liquidity weights.
     */
    uint16 internal constant TOTAL_WEIGHT_BPS = 1e4;

    /**
     * @inheritdoc IShapeLibrary
     */
    function computeBands(uint8 shapeId, int24 centerTick, int24 ticksLeft, int24 ticksRight, int24 tickSpacing)
        external
        pure
        returns (Band[] memory bands, uint16[] memory weights)
    {
        if (!isValidShape(shapeId)) revert InvalidShape();
        if (tickSpacing <= 0 || ticksLeft < 0 || ticksRight < 0) revert InvalidInput();

        int256 spacing = int256(tickSpacing);
        (int256 lower, int256 upper) = _range(shapeId, centerTick, ticksLeft, ticksRight, spacing);
        int256 minUsable = _ceilDiv(MIN_TICK, spacing) * spacing;
        int256 maxUsable = _floorDiv(MAX_TICK, spacing) * spacing;

        if (lower < minUsable) lower = minUsable;
        if (upper > maxUsable) upper = maxUsable;
        if (upper <= lower) revert EmptyRange();

        (uint8 bandCount, uint16[] memory presetWeights) = _preset(shapeId);
        uint256 steps = SafeCast.toUint256(upper - lower) / SafeCast.toUint256(spacing);
        if (steps < bandCount) {
            bandCount = SafeCast.toUint8(steps);
            presetWeights = _uniform(bandCount);
        }

        uint256 width = steps / bandCount;
        bands = new Band[](bandCount);
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint8 i; i < bandCount; ++i) {
            int256 widthInt = SafeCast.toInt256(width);
            int256 tickLower = lower + widthInt * SafeCast.toInt256(uint256(i)) * spacing;
            int256 tickUpper = i == bandCount - 1 ? upper : tickLower + widthInt * spacing;
            bands[i] = Band({
                tickLower: SafeCast.toInt24(tickLower), tickUpper: SafeCast.toInt24(tickUpper), tokenId: 0, liquidity: 0
            });
        }
        weights = presetWeights;
    }

    /**
     * @inheritdoc IShapeLibrary
     */
    function maxBands() external pure returns (uint8) {
        return MAX_BANDS;
    }

    /**
     * @inheritdoc IShapeLibrary
     */
    function isValidShape(uint8 shapeId) public pure returns (bool) {
        return shapeId < 8;
    }

    /**
     * @notice Computes the unclamped aligned tick range for a supported shape.
     * @dev Shape 5 ignores left/right widths and creates one spacing interval; shape 6 returns global endpoints.
     * @param shapeId Supported shape preset id.
     * @param centerTick Tick around which the range is derived.
     * @param ticksLeft Non-negative distance to the left of `centerTick`.
     * @param ticksRight Non-negative distance to the right of `centerTick`.
     * @param spacing Positive tick spacing used for alignment.
     * @return lower Aligned lower tick before usable-range clamping.
     * @return upper Aligned upper tick before usable-range clamping.
     */
    function _range(uint8 shapeId, int24 centerTick, int24 ticksLeft, int24 ticksRight, int256 spacing)
        private
        pure
        returns (int256 lower, int256 upper)
    {
        // aderyn-ignore-next-line(literal-instead-of-constant)
        if (shapeId == 5) {
            lower = _floorToSpacing(centerTick, spacing);
            upper = lower + spacing;
            return (lower, upper);
        }

        if (shapeId == 6) {
            return (MIN_TICK, MAX_TICK);
        }

        lower = _floorToSpacing(int256(centerTick) - int256(ticksLeft), spacing);
        upper = _ceilToSpacing(int256(centerTick) + int256(ticksRight), spacing);
    }

    /**
     * @notice Returns the nominal band count and weights for a supported preset.
     * @dev Shapes 1, 5, 6, and 7 share a single-band default weight.
     * @param shapeId Supported shape preset id.
     * @return bandCount Nominal number of bands before narrow-range reduction.
     * @return weights Relative liquidity weights in basis points.
     */
    function _preset(uint8 shapeId) private pure returns (uint8 bandCount, uint16[] memory weights) {
        if (shapeId == 0) {
            weights = new uint16[](5); // aderyn-ignore(literal-instead-of-constant)
            weights[0] = 1000; // aderyn-ignore(literal-instead-of-constant)
            weights[1] = 2000; // aderyn-ignore(literal-instead-of-constant)
            weights[2] = 4000;
            weights[3] = 2000; // aderyn-ignore(literal-instead-of-constant)
            weights[4] = 1000; // aderyn-ignore(literal-instead-of-constant)
            return (5, weights); // aderyn-ignore(literal-instead-of-constant)
        }

        if (shapeId == 2) {
            weights = new uint16[](3); // aderyn-ignore(literal-instead-of-constant)
            weights[0] = 2500; // aderyn-ignore(literal-instead-of-constant)
            weights[1] = 5000;
            weights[2] = 2500; // aderyn-ignore(literal-instead-of-constant)
            return (3, weights); // aderyn-ignore(literal-instead-of-constant)
        }

        // aderyn-ignore-next-line(literal-instead-of-constant)
        if (shapeId == 3) {
            weights = new uint16[](3); // aderyn-ignore(literal-instead-of-constant)
            weights[0] = 3333; // aderyn-ignore(literal-instead-of-constant)
            weights[1] = 3334;
            weights[2] = 3333; // aderyn-ignore(literal-instead-of-constant)
            return (3, weights); // aderyn-ignore(literal-instead-of-constant)
        }

        if (shapeId == 4) {
            weights = new uint16[](5); // aderyn-ignore(literal-instead-of-constant)
            // aderyn-ignore-next-line(literal-instead-of-constant)
            for (uint8 i; i < 5; ++i) {
                weights[i] = 2000; // aderyn-ignore(literal-instead-of-constant)
            }
            return (5, weights); // aderyn-ignore(literal-instead-of-constant)
        }

        weights = new uint16[](1);
        weights[0] = TOTAL_WEIGHT_BPS;
        return (1, weights);
    }

    /**
     * @notice Builds fallback weights for a reduced band count.
     * @dev Remainder basis points are assigned to earlier bands so the sum remains exactly 10,000.
     * @param bandCount Reduced nonzero band count.
     * @return weights Uniform fallback weights in basis points.
     */
    function _uniform(uint8 bandCount) private pure returns (uint16[] memory weights) {
        weights = new uint16[](bandCount);
        uint16 base = uint16(TOTAL_WEIGHT_BPS / bandCount);
        uint16 remainder = uint16(TOTAL_WEIGHT_BPS % bandCount);
        for (uint8 i; i < bandCount; ++i) {
            weights[i] = base + (i < remainder ? 1 : 0);
        }
    }

    /**
     * @notice Rounds a tick down to the nearest multiple of spacing.
     * @dev Uses mathematical floor division, including for negative ticks.
     * @param tick Tick to align.
     * @param spacing Positive tick spacing.
     * @return Aligned tick less than or equal to `tick`.
     */
    function _floorToSpacing(int256 tick, int256 spacing) private pure returns (int256) {
        return _floorDiv(tick, spacing) * spacing;
    }

    /**
     * @notice Rounds a tick up to the nearest multiple of spacing.
     * @dev Uses mathematical ceiling division, including for negative ticks.
     * @param tick Tick to align.
     * @param spacing Positive tick spacing.
     * @return Aligned tick greater than or equal to `tick`.
     */
    function _ceilToSpacing(int256 tick, int256 spacing) private pure returns (int256) {
        return _ceilDiv(tick, spacing) * spacing;
    }

    /**
     * @notice Divides and rounds toward negative infinity.
     * @dev Corrects Solidity signed division, which otherwise truncates toward zero.
     * @param numerator Signed numerator.
     * @param denominator Nonzero signed denominator.
     * @return quotient Floor-rounded quotient.
     */
    function _floorDiv(int256 numerator, int256 denominator) private pure returns (int256 quotient) {
        quotient = numerator / denominator;
        int256 remainder = numerator % denominator;
        if (remainder != 0 && ((remainder < 0) != (denominator < 0))) quotient -= 1;
    }

    /**
     * @notice Divides and rounds toward positive infinity.
     * @dev Implemented through floor division to preserve negative tick correctness.
     * @param numerator Signed numerator.
     * @param denominator Nonzero signed denominator.
     * @return Ceiling-rounded quotient.
     */
    function _ceilDiv(int256 numerator, int256 denominator) private pure returns (int256) {
        return -_floorDiv(-numerator, denominator);
    }
}
