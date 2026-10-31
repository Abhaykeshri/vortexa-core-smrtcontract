// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title Permit2 Minimal Interface
 * @notice Minimal Permit2 allowance surface used by the M4 vault and mocks.
 * @dev The vault grants exact temporary allowances to PositionManager, then revokes them after each call.
 */
interface IPermit2Like {
    /**
     * @notice Approves a spender to pull a token through Permit2 until an expiration timestamp.
     * @dev A zero amount revokes the allowance while leaving the nonce unchanged.
     * @param token ERC-20 token approved through Permit2.
     * @param spender Address allowed to pull `token`.
     * @param amount Maximum amount approved, narrowed to Permit2's uint160 allowance field.
     * @param expiration Timestamp at which the allowance expires.
     */
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}
