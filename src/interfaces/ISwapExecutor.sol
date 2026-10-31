// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, PoolKey} from "../libraries/Types.sol";

/**
 * @title Swap Executor Minimal Interface
 * @notice M6 single-asset conversion hook used by ERC-4626 entry points.
 * @dev M4 tests use a deterministic mock; production swap policy is intentionally deferred to M6.
 */
interface ISwapExecutor {
    /**
     * @notice Emitted after a measured exact-input swap returns output to its caller.
     */
    event SwapExecuted(address indexed caller, PoolKey key, bool zeroForOne, uint256 amountIn, uint256 amountOut);

    /**
     * @notice Caller is neither a registered vault nor the immutable Zap.
     */
    error UnauthorizedCaller();
    /**
     * @notice Swap arguments do not identify a valid nonzero conversion.
     */
    error InvalidInput();
    /**
     * @notice PriceGuard does not currently trust the pool.
     */
    error UntrustedPrice();
    /**
     * @notice Caller output floor is below the executor's oracle floor.
     */
    error SlippageTooHigh();
    /**
     * @notice Router output is lower than required.
     */
    error InsufficientOutput();

    /**
     * @notice Returns the immutable Vault M6 delegatecall module.
     * @dev Vault implementations read this once during construction.
     * @return module M6 module address.
     */
    function vaultModule() external view returns (address module);
    /**
     * @notice Converts one vault currency into the other.
     * @dev Implementations must enforce caller-supplied slippage and return the measured output.
     * @param tokenIn Currency being spent.
     * @param tokenOut Currency being received.
     * @param amountIn Amount of `tokenIn` offered.
     * @param minAmountOut Minimum accepted output amount.
     * @return amountOut Measured amount of `tokenOut` received by the caller.
     */
    function swap(Currency tokenIn, Currency tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        payable
        returns (uint256 amountOut);

    /**
     * @notice Swaps one currency of a registered vault through Uniswap Universal Router V4_SWAP.
     * @dev Enforces authorization, oracle floor, measured deltas, and allowance revocation.
     * @param key V4 pool key.
     * @param zeroForOne Swap direction.
     * @param amountIn Exact input amount.
     * @param minAmountOut Caller minimum output.
     * @return amountOut Measured output amount.
     */
    function swapExactInput(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minAmountOut)
        external
        payable
        returns (uint256 amountOut);
}
