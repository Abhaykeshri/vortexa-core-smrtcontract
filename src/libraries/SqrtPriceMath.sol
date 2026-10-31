// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title Square-Root Price Math
 * @notice Converts Uniswap ticks into Q64.96 square-root prices.
 * @dev The implementation is independently tested against pinned Uniswap V4 TickMath outputs.
 *
 *      This is an independent implementation, not a copy of Uniswap source, so production code carries no
 *      BUSL-licensed material. Uniswap's `TickMath` is used only as a differential test oracle: results must
 *      match exactly for every tested tick, including both boundaries.
 *
 *      Only the forward direction (tick to price) is provided. The inverse is never needed on-chain because the
 *      current tick comes from `StateView.getSlot0` and prices are converted to ticks off-chain.
 */
library SqrtPriceMath {
    /**
     * @notice Tick is outside the supported Uniswap range.
     * @dev Thrown by `getSqrtPriceAtTick` when `tick` is below `MIN_TICK` or above `MAX_TICK`.
     */
    error InvalidTick();

    /**
     * @notice Minimum supported Uniswap tick.
     * @dev The price at this tick is the smallest sqrt price Uniswap supports.
     */
    int24 internal constant MIN_TICK = -887272;
    /**
     * @notice Maximum supported Uniswap tick.
     * @dev The price at this tick is the largest sqrt price Uniswap supports.
     */
    int24 internal constant MAX_TICK = 887272;

    /**
     * @notice Converts a tick to its Q64.96 square-root price.
     * @dev Uses the independently implemented bitwise exponentiation and rounds the Q128.128 result up to Q64.96.
     *
     *      The loop-free algorithm multiplies one precomputed Q128.128 constant per set bit of `|tick|`. The
     *      constants are nearest-integer rounded values of `2^128 / sqrt(1.0001)^(2^k)` for `k = 0..18`, matching
     *      the pinned Uniswap implementation (a literal floor would not reproduce Uniswap's outputs). For positive
     *      ticks the ratio is inverted. The final Q128.128 to Q64.96 conversion rounds up.
     *
     *      Reverts with `InvalidTick` when `tick` is outside `[MIN_TICK, MAX_TICK]`.
     * @param tick The tick in the inclusive Uniswap v4 range.
     * @return sqrtPriceX96 The square root of 1.0001^tick, scaled by 2^96.
     */
    function getSqrtPriceAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (tick < MIN_TICK || tick > MAX_TICK) revert InvalidTick();

        // Tick was range-checked above, so its absolute value is always a small non-negative int24.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 absTick = uint256(uint24(tick < 0 ? -tick : tick));
        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;

        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128; // aderyn-ignore(literal-instead-of-constant)
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128; // aderyn-ignore(literal-instead-of-constant)
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128; // aderyn-ignore(literal-instead-of-constant)
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128; // aderyn-ignore(literal-instead-of-constant)
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128; // aderyn-ignore(literal-instead-of-constant)
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128; // aderyn-ignore(literal-instead-of-constant)
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128; // aderyn-ignore(literal-instead-of-constant)
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128; // aderyn-ignore(literal-instead-of-constant)
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128; // aderyn-ignore(literal-instead-of-constant)
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128; // aderyn-ignore(literal-instead-of-constant)
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128; // aderyn-ignore(literal-instead-of-constant)
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128; // aderyn-ignore(literal-instead-of-constant)
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128; // aderyn-ignore(literal-instead-of-constant)
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128; // aderyn-ignore(literal-instead-of-constant)
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128; // aderyn-ignore(literal-instead-of-constant)
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128; // aderyn-ignore(literal-instead-of-constant)
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128; // aderyn-ignore(literal-instead-of-constant)
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128; // aderyn-ignore(literal-instead-of-constant)
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128; // aderyn-ignore(literal-instead-of-constant)

        if (tick > 0) ratio = type(uint256).max / ratio;
        uint256 rounded = (ratio >> 32) + (ratio & type(uint32).max == 0 ? 0 : 1);
        sqrtPriceX96 = SafeCast.toUint160(rounded);
    }
}
