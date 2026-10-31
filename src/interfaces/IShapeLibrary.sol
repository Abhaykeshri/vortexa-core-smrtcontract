// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Band} from "../libraries/Types.sol";

/**
 * @title Shape Library Interface
 * @notice Computes aligned liquidity bands and relative weights from preset shape parameters.
 * @dev Implementations are expected to be pure, stateless, deterministic, and bounded to at most five bands.
 */
interface IShapeLibrary {
    /**
     * @notice Input parameters are malformed.
     */
    error InvalidInput();

    /**
     * @notice Shape id is not supported.
     */
    error InvalidShape();

    /**
     * @notice Computed or clamped range is empty.
     */
    error EmptyRange();

    /**
     * @notice Computes contiguous aligned bands and relative liquidity weights for a shape preset.
     * @param shapeId Preset id from 0 to 7.
     * @param centerTick Center tick used to derive the range.
     * @param ticksLeft Non-negative ticks to the left of center.
     * @param ticksRight Non-negative ticks to the right of center.
     * @param tickSpacing Positive tick spacing used for alignment and usable bounds.
     * @return bands Contiguous aligned bands with zero token id and zero liquidity.
     * @return weights Relative liquidity weights in basis points, summing to 10,000.
     * @dev Reverts when the shape id is unsupported, inputs are malformed, or the aligned/clamped range is empty.
     */
    function computeBands(uint8 shapeId, int24 centerTick, int24 ticksLeft, int24 ticksRight, int24 tickSpacing)
        external
        pure
        returns (Band[] memory bands, uint16[] memory weights);

    /**
     * @notice Returns the maximum number of bands any preset can produce.
     * @return Maximum band count.
     * @dev This is a fixed M3 interface limit used by downstream planning code.
     */
    function maxBands() external pure returns (uint8);

    /**
     * @notice Reports whether a shape id is supported.
     * @param shapeId Shape id to inspect.
     * @return True when `shapeId` is in the supported preset range.
     * @dev Valid shape ids are contiguous from 0 through 7.
     */
    function isValidShape(uint8 shapeId) external pure returns (bool);
}
