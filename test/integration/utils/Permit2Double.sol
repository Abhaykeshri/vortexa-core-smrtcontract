// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Permit2 allowance double
 * @notice Implements the subset of Uniswap Permit2's AllowanceTransfer that the v4 PositionManager uses, with the
 *         same rules: an allowance is (amount, expiration) per (owner, token, spender); `transferFrom` reverts when
 *         the allowance has expired (`block.timestamp > expiration`) or is too small, and decrements it unless it is
 *         `type(uint160).max`; an expiration of zero means "this block".
 * @dev Uniswap's Permit2 is pinned to solc 0.8.17 and cannot be compiled by this project's pinned 0.8.26, so the
 *      in-process integration tests use this double. The mainnet fork tests exercise the real Permit2.
 */
contract Permit2Double {
    struct Allowance {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    error AllowanceExpired(uint256 deadline);
    error InsufficientAllowance(uint256 amount);

    mapping(address owner => mapping(address token => mapping(address spender => Allowance))) public allowances;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        Allowance storage a = allowances[msg.sender][token][spender];
        a.amount = amount;
        a.expiration = expiration == 0 ? uint48(block.timestamp) : expiration;
    }

    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce)
    {
        Allowance memory a = allowances[owner][token][spender];
        return (a.amount, a.expiration, a.nonce);
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        Allowance storage a = allowances[from][token][msg.sender];
        if (block.timestamp > a.expiration) revert AllowanceExpired(a.expiration);
        if (a.amount != type(uint160).max) {
            if (amount > a.amount) revert InsufficientAllowance(a.amount);
            unchecked {
                a.amount -= amount;
            }
        }
        require(IERC20(token).transferFrom(from, to, amount), "transfer failed");
    }
}
