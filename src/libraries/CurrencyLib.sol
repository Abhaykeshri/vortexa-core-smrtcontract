// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "./Types.sol";

/**
 * @title Currency Library
 * @notice Utilities for handling native ETH and ERC-20 currencies through the shared `Currency` type.
 * @dev The zero address is treated as native ETH. Non-zero currency values are treated as ERC-20 token addresses.
 *
 *      ERC-20 transfers go through OpenZeppelin `SafeERC20`, so tokens that return `false` or nothing are handled
 *      and failures revert. Native sends forward all remaining gas to the recipient, so every call site that
 *      sends native currency must provide its own reentrancy protection (checks-effects-interactions plus a
 *      `nonReentrant` guard).
 */
library CurrencyLib {
    using SafeERC20 for IERC20;

    /**
     * @notice Native ETH transfer failed.
     * @dev Thrown by `transfer` when the low-level call to the recipient returns false, for example because the
     *      recipient reverts or has no payable `receive`.
     */
    error NativeTransferFailed();

    /**
     * @notice Reports whether a currency represents native ETH.
     * @dev Native ETH is encoded as the zero address, matching Uniswap's `Currency` encoding.
     * @param currency The currency to inspect.
     * @return isNativeCurrency True when the currency address is zero.
     */
    function isNative(Currency currency) internal pure returns (bool isNativeCurrency) {
        return Currency.unwrap(currency) == address(0);
    }

    /**
     * @notice Reads this contract's balance of a currency.
     * @dev Because this is an internal library function, `address(this)` is the calling contract. For native
     *      currency the balance already includes any `msg.value` of the current call, so callers snapshotting
     *      idle ETH during a payable function must subtract `msg.value` themselves. For ERC-20 currencies the
     *      call reverts if the token has no code or does not implement `balanceOf`.
     * @param currency The currency to inspect.
     * @return balance The native or ERC-20 balance held by the calling contract.
     */
    function balanceOfSelf(Currency currency) internal view returns (uint256 balance) {
        return isNative(currency) ? address(this).balance : IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }

    /**
     * @notice Transfers a currency, skipping zero-value transfers.
     * @dev Returns early when `amount` is zero so tokens that revert on zero-value transfers never block a flow.
     *      Native sends forward normal gas and therefore must only be used in a reentrancy-protected flow.
     *
     *      Reverts with `NativeTransferFailed` when a native send fails, and with the `SafeERC20` errors when an
     *      ERC-20 transfer fails or returns false.
     * @param currency The currency to transfer.
     * @param recipient The transfer recipient.
     * @param amount The amount to transfer.
     */
    function transfer(Currency currency, address recipient, uint256 amount) internal {
        if (amount == 0) return;

        if (isNative(currency)) {
            (bool success,) = recipient.call{value: amount}("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(Currency.unwrap(currency)).safeTransfer(recipient, amount);
        }
    }
}
