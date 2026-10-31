// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title Normal LP Ratio Math
 * @notice Shared pool-fee-aware swap sizing for a target unit-liquidity token ratio.
 * @dev Uses raw-token Uniswap price units so token decimals remain embedded in the ratio.
 */
library NormalLPMath {
    /**
     * @dev Q64.96 fixed-point scale.
     */
    uint256 internal constant Q96 = 1 << 96;
    /**
     * @dev Uniswap fee denominator.
     */
    uint256 internal constant FEE_DENOMINATOR = 1e6;

    /**
     * @notice The price, pool fee, or target ratio is invalid.
     */
    error InvalidRatio();

    /**
     * @notice Sizes the swap needed to approach a supplied unit-liquidity token ratio.
     * @dev Deficit purchases and fee gross-up round upward, matching the audited NormalLP strategy behavior.
     * @param fee Pool fee in millionths.
     * @param sqrtPriceX96 Current pool square-root price.
     * @param amount0 Available currency0.
     * @param amount1 Available currency1.
     * @param unit0 Currency0 required by a representative target position.
     * @param unit1 Currency1 required by a representative target position.
     * @return swapAmountIn Exact input amount to swap.
     * @return zeroForOne True when currency0 is the swap input.
     */
    function sizeSwap(uint24 fee, uint160 sqrtPriceX96, uint256 amount0, uint256 amount1, uint256 unit0, uint256 unit1)
        internal
        pure
        returns (uint256 swapAmountIn, bool zeroForOne)
    {
        if (sqrtPriceX96 == 0 || fee >= FEE_DENOMINATOR) revert InvalidRatio();
        uint256 priceX96 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        if (priceX96 == 0) revert InvalidRatio();
        uint256 unit0Value = Math.mulDiv(unit0, priceX96, Q96);
        uint256 denominator = unit0Value + unit1;
        if (denominator == 0) revert InvalidRatio();
        uint256 totalValue = Math.mulDiv(amount0, priceX96, Q96) + amount1;
        uint256 target0 = Math.mulDiv(unit0, totalValue, denominator);
        uint256 target1 = Math.mulDiv(unit1, totalValue, denominator);
        uint256 feeFactor = FEE_DENOMINATOR - fee;

        if (target0 > amount0) {
            uint256 deficitValue = Math.mulDiv(target0 - amount0, priceX96, Q96, Math.Rounding.Ceil);
            swapAmountIn = Math.mulDiv(deficitValue, FEE_DENOMINATOR, feeFactor, Math.Rounding.Ceil);
            if (swapAmountIn > amount1) swapAmountIn = amount1;
        } else if (target1 > amount1) {
            uint256 token0Needed = Math.mulDiv(target1 - amount1, Q96, priceX96, Math.Rounding.Ceil);
            swapAmountIn = Math.mulDiv(token0Needed, FEE_DENOMINATOR, feeFactor, Math.Rounding.Ceil);
            if (swapAmountIn > amount0) swapAmountIn = amount0;
            zeroForOne = true;
        }
    }
}
