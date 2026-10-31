// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {V4Router} from "uni-test/v4-periphery/src/V4Router.sol";
import {ReentrancyLock} from "uni-test/v4-periphery/src/base/ReentrancyLock.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/**
 * @title Universal Router double for in-process tests
 * @notice Runs the real Uniswap v4 `V4Router` action pipeline (the exact code the Universal Router inherits) behind
 *         the Universal Router's `execute(commands, inputs, deadline)` entry point, with the Universal Router's
 *         payment rule: a payer other than the router pays through Permit2 `transferFrom`.
 * @dev Only the `V4_SWAP` command (0x10) is supported, which is all `SwapExecutor` uses. Parameter decoding,
 *      settlement, `SETTLE_ALL`/`TAKE_ALL` and slippage checks are Uniswap's own, so an encoding mismatch fails here
 *      exactly as it would on mainnet.
 */
contract UniversalRouterDouble is V4Router, ReentrancyLock {
    uint256 internal constant V4_SWAP = 0x10;
    uint256 internal constant COMMAND_TYPE_MASK = 0x3f;

    IAllowanceTransfer public immutable permit2;

    error TransactionDeadlinePassed();
    error LengthMismatch();
    error InvalidCommandType(uint256 commandType);

    constructor(IPoolManager poolManager_, IAllowanceTransfer permit2_) V4Router(poolManager_) {
        permit2 = permit2_;
    }

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable isNotLocked {
        if (block.timestamp > deadline) revert TransactionDeadlinePassed();
        if (commands.length != inputs.length) revert LengthMismatch();
        for (uint256 i; i < commands.length; ++i) {
            uint256 command = uint8(commands[i]) & COMMAND_TYPE_MASK;
            if (command != V4_SWAP) revert InvalidCommandType(command);
            _executeActions(inputs[i]);
        }
    }

    function _pay(Currency token, address payer, uint256 amount) internal override {
        if (payer == address(this)) {
            token.transfer(address(poolManager), amount);
        } else {
            permit2.transferFrom(payer, address(poolManager), uint160(amount), Currency.unwrap(token));
        }
    }

    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    receive() external payable {}
}
