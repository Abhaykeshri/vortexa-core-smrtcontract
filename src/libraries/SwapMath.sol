// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "./Types.sol";

/**
 * @title Vortexa Swap Math
 * @notice Shared oracle-relative exact-input output-floor arithmetic for SwapExecutor and Zap.
 * @dev Applies the static pool fee before caller-selected slippage and always rounds output down.
 */
library SwapMath {
    /**
     * @dev Basis-point denominator.
     */
    uint256 internal constant BPS = 1e4;
    /**
     * @dev Uniswap fee denominator.
     */
    uint256 internal constant FEE_DENOMINATOR = 1e6;
    /**
     * @dev Q64.96 fixed-point scale.
     */
    uint256 internal constant Q96 = 1 << 96;

    /**
     * @notice The reference price or fee cannot produce a valid output floor.
     */
    error InvalidSwapMath();

    /**
     * @notice Computes minimum output after the pool fee and a caller-selected oracle slippage tolerance.
     * @dev Every conversion rounds down, against the caller. The caller must independently cap `slippageBps`.
     * @param key Pool key containing the static pool fee.
     * @param zeroForOne Swap direction.
     * @param amountIn Exact input amount.
     * @param sqrtReference Trusted oracle square-root price.
     * @param slippageBps Oracle-relative tolerance in basis points.
     * @return floor Minimum acceptable output.
     */
    function minAmountOut(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint160 sqrtReference,
        uint256 slippageBps
    ) internal pure returns (uint256 floor) {
        if (key.fee >= FEE_DENOMINATOR || slippageBps > BPS) revert InvalidSwapMath();
        uint256 priceX96 = Math.mulDiv(sqrtReference, sqrtReference, Q96);
        if (priceX96 == 0) revert InvalidSwapMath();
        uint256 gross = zeroForOne ? Math.mulDiv(amountIn, priceX96, Q96) : Math.mulDiv(amountIn, Q96, priceX96);
        gross = Math.mulDiv(gross, FEE_DENOMINATOR - key.fee, FEE_DENOMINATOR);
        floor = Math.mulDiv(gross, BPS - slippageBps, BPS);
    }
}
