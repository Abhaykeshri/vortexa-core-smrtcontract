// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title Liquidity Math
 * @notice Computes Uniswap-style liquidity and token amounts for Q64.96 price ranges.
 * @dev Functions match the pinned Uniswap V4 math behavior used by M1 differential tests.
 *
 *      Rounding policy: liquidity and token amounts are always rounded down, so the amounts Uniswap pulls for the
 *      computed liquidity never exceed the amounts supplied as inputs. Dust stays with the caller.
 *
 *      Safety: all products use OpenZeppelin full-precision `Math.mulDiv`, which guards the 512-bit
 *      intermediate, and all `uint128` narrowing is checked and reverts instead of truncating. Production code
 *      imports no Uniswap source; Uniswap's `LiquidityAmounts` is used only as a test oracle.
 */
library LiquidityMath {
    /**
     * @notice Price range endpoints are zero or equal after sorting.
     * @dev Thrown when the lower endpoint is zero (division by zero risk) or both endpoints are equal (empty range).
     */
    error InvalidPriceRange();

    /**
     * @notice Fixed-point scaling factor for Q64.96 values.
     * @dev Equal to `2**96`.
     */
    uint256 internal constant Q96 = 1 << 96;

    /**
     * @notice Computes the maximum liquidity supported by token amounts in a price range.
     * @dev Range endpoints are normalized; full-precision multiplication and checked narrowing prevent overflow.
     *
     *      Behavior by price position:
     *      - current price at or below the lower bound: only currency0 limits liquidity;
     *      - current price at or above the upper bound: only currency1 limits liquidity;
     *      - current price inside the range: the smaller of the two single-token liquidities is returned, so the
     *        scarcer token limits the position.
     *
     *      Reverts with `InvalidPriceRange` for a zero or empty range and with an OpenZeppelin `SafeCast` error
     *      if the result does not fit in a uint128.
     * @param sqrtPriceX96 The current Q64.96 square-root price.
     * @param sqrtPriceAX96 One boundary of the Q64.96 price range.
     * @param sqrtPriceBX96 The other boundary of the Q64.96 price range.
     * @param amount0 The available currency0 amount.
     * @param amount1 The available currency1 amount.
     * @return liquidity The largest uint128 liquidity supported by both amounts.
     */
    function liquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        (uint160 sqrtA, uint160 sqrtB) = _sort(sqrtPriceAX96, sqrtPriceBX96);
        if (sqrtPriceX96 <= sqrtA) {
            return _liquidityForAmount0(sqrtA, sqrtB, amount0);
        }
        if (sqrtPriceX96 >= sqrtB) {
            return _liquidityForAmount1(sqrtA, sqrtB, amount1);
        }

        uint128 liquidity0 = _liquidityForAmount0(sqrtPriceX96, sqrtB, amount0);
        uint128 liquidity1 = _liquidityForAmount1(sqrtA, sqrtPriceX96, amount1);
        return liquidity0 < liquidity1 ? liquidity0 : liquidity1;
    }

    /**
     * @notice Computes token amounts required by liquidity in a price range.
     * @dev Range endpoints are normalized and all divisions round down.
     *
     *      Below the range the position is entirely currency0, above it entirely currency1, and inside the
     *      range it holds both. Feeding the result back into `liquidityForAmounts` never yields more liquidity
     *      than was passed in.
     *
     *      Reverts with `InvalidPriceRange` for a zero or empty range.
     * @param sqrtPriceX96 The current Q64.96 square-root price.
     * @param sqrtPriceAX96 One boundary of the Q64.96 price range.
     * @param sqrtPriceBX96 The other boundary of the Q64.96 price range.
     * @param liquidity The uint128 liquidity to value.
     * @return amount0 The currency0 amount, rounded down.
     * @return amount1 The currency1 amount, rounded down.
     */
    function amountsForLiquidity(uint160 sqrtPriceX96, uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtA, uint160 sqrtB) = _sort(sqrtPriceAX96, sqrtPriceBX96);
        if (sqrtPriceX96 <= sqrtA) {
            return (_amount0ForLiquidity(sqrtA, sqrtB, liquidity), 0);
        }
        if (sqrtPriceX96 >= sqrtB) {
            return (0, _amount1ForLiquidity(sqrtA, sqrtB, liquidity));
        }
        return
            (_amount0ForLiquidity(sqrtPriceX96, sqrtB, liquidity), _amount1ForLiquidity(sqrtA, sqrtPriceX96, liquidity));
    }

    /**
     * @notice Computes the liquidity that `amount0` of currency0 supports across `[sqrtA, sqrtB]`.
     * @dev Evaluates `amount0 * (sqrtA * sqrtB / Q96) / (sqrtB - sqrtA)` and rounds down. Requires
     *      `sqrtA < sqrtB`, which `_sort` guarantees. Reverts if the result exceeds a uint128.
     * @param sqrtA Lower Q64.96 square-root price bound.
     * @param sqrtB Upper Q64.96 square-root price bound.
     * @param amount0 Available currency0 amount.
     * @return liquidity Liquidity supported by `amount0`, rounded down.
     */
    function _liquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) private pure returns (uint128) {
        uint256 intermediate = Math.mulDiv(sqrtA, sqrtB, Q96);
        return SafeCast.toUint128(Math.mulDiv(amount0, intermediate, sqrtB - sqrtA));
    }

    /**
     * @notice Computes the liquidity that `amount1` of currency1 supports across `[sqrtA, sqrtB]`.
     * @dev Evaluates `amount1 * Q96 / (sqrtB - sqrtA)` and rounds down. Requires `sqrtA < sqrtB`, which `_sort`
     *      guarantees. Reverts if the result exceeds a uint128.
     * @param sqrtA Lower Q64.96 square-root price bound.
     * @param sqrtB Upper Q64.96 square-root price bound.
     * @param amount1 Available currency1 amount.
     * @return liquidity Liquidity supported by `amount1`, rounded down.
     */
    function _liquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) private pure returns (uint128) {
        return SafeCast.toUint128(Math.mulDiv(amount1, Q96, sqrtB - sqrtA));
    }

    /**
     * @notice Computes the currency0 amount held by `liquidity` across `[sqrtA, sqrtB]`.
     * @dev Evaluates `liquidity * Q96 * (sqrtB - sqrtA) / sqrtB / sqrtA` with two successive floor divisions, the
     *      same order as Uniswap, so the result rounds down.
     * @param sqrtA Lower Q64.96 square-root price bound; must be non-zero.
     * @param sqrtB Upper Q64.96 square-root price bound.
     * @param liquidity Liquidity to value.
     * @return amount0 Currency0 amount, rounded down.
     */
    function _amount0ForLiquidity(uint160 sqrtA, uint160 sqrtB, uint128 liquidity) private pure returns (uint256) {
        return Math.mulDiv(uint256(liquidity) << 96, sqrtB - sqrtA, sqrtB) / sqrtA;
    }

    /**
     * @notice Computes the currency1 amount held by `liquidity` across `[sqrtA, sqrtB]`.
     * @dev Evaluates `liquidity * (sqrtB - sqrtA) / Q96` and rounds down.
     * @param sqrtA Lower Q64.96 square-root price bound.
     * @param sqrtB Upper Q64.96 square-root price bound.
     * @param liquidity Liquidity to value.
     * @return amount1 Currency1 amount, rounded down.
     */
    function _amount1ForLiquidity(uint160 sqrtA, uint160 sqrtB, uint128 liquidity) private pure returns (uint256) {
        return Math.mulDiv(liquidity, sqrtB - sqrtA, Q96);
    }

    /**
     * @notice Orders two price bounds and rejects degenerate ranges.
     * @dev Reverts with `InvalidPriceRange` when the smaller bound is zero or when both bounds are equal, which
     *      protects every later division from a zero denominator.
     * @param a First price bound.
     * @param b Second price bound.
     * @return lower The smaller of the two bounds.
     * @return upper The larger of the two bounds.
     */
    function _sort(uint160 a, uint160 b) private pure returns (uint160 lower, uint160 upper) {
        (lower, upper) = a < b ? (a, b) : (b, a);
        if (lower == 0 || lower == upper) revert InvalidPriceRange();
    }
}
