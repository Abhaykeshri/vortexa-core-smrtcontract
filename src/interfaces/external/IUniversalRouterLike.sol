// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title Universal Router Minimal Interface
 * @notice Minimal pinned Universal Router v2.2.0 execution surface used by SwapExecutor.
 * @dev The ABI matches commit 64027f3 without importing third-party source into production contracts.
 */
interface IUniversalRouterLike {
    /**
     * @notice Executes encoded Universal Router commands before a deadline.
     * @dev The caller supplies one input blob per command.
     * @param commands Packed command identifiers.
     * @param inputs ABI-encoded command inputs.
     * @param deadline Latest accepted execution timestamp.
     */
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}
