// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title Vortexa Single-Token Zap Interface
 * @notice Converts one vault currency into the mix required by a Vortexa vault and deposits it atomically.
 * @dev Restricts execution to a factory-registered vault and the protocol SwapExecutor.
 */
interface IZap {
    /**
     * @notice The supplied vault was not created by the immutable factory.
     */
    error UnknownVault();
    /**
     * @notice The supplied input token is not one of the vault currencies.
     */
    error BadToken();
    /**
     * @notice The requested slippage exceeds the executor's hard limit.
     */
    error SlippageTooHigh();
    /**
     * @notice The share receiver is the zero address.
     */
    error ZeroReceiver();

    /**
     * @notice Deposits one vault currency, swapping only the required part through the trusted SwapExecutor.
     * @dev Native ETH is represented by `address(0)`. Any call-local leftovers are returned to the caller.
     * @param vault Factory-created destination vault.
     * @param tokenIn Input currency, or address zero for native ETH.
     * @param amountIn Exact input amount.
     * @param minShares Minimum acceptable shares.
     * @param maxSlippageBps Maximum oracle-relative swap slippage in basis points.
     * @param receiver Account receiving vault shares.
     * @return shares Shares minted by the vault.
     */
    function zapDeposit(
        address vault,
        address tokenIn,
        uint256 amountIn,
        uint256 minShares,
        uint16 maxSlippageBps,
        address receiver
    ) external payable returns (uint256 shares);

    /**
     * @notice Estimates the input portion swapped and conservatively estimated shares.
     * @dev The quote is not an execution guarantee; callers must protect execution with `minShares`.
     * @param vault Factory-created destination vault.
     * @param tokenIn Input currency, or address zero for native ETH.
     * @param amountIn Input amount to quote.
     * @return swapAmount Portion of `amountIn` expected to be swapped.
     * @return expectedShares Conservative share estimate.
     */
    function quoteZap(address vault, address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256 swapAmount, uint256 expectedShares);
}
