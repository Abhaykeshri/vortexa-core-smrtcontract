// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFeeCollector} from "./interfaces/IFeeCollector.sol";
import {Currency} from "./libraries/Types.sol";
import {CurrencyLib} from "./libraries/CurrencyLib.sol";

/**
 * @title Vortexa Fee Collector
 * @notice Permissionlessly forwards accumulated protocol fees to a fixed owner-controlled recipient.
 * @dev The timelock controls only the recipient; collection never gives the caller custody or routing discretion.
 */
// The timelock owns only the recipient; collection is permissionless and never chooses a destination.
// aderyn-ignore-next-line(centralization-risk)
contract FeeCollector is IFeeCollector, Ownable2Step, ReentrancyGuard {
    using CurrencyLib for Currency;

    /**
     * @notice Fixed destination of every `collect`; only the owner (the timelock) can change it.
     */
    address public override recipient;

    /**
     * @notice A required owner or recipient address is zero.
     */
    error ZeroAddress();

    /**
     * @notice Emitted when governance updates the fixed recipient.
     */
    event RecipientSet(address indexed oldRecipient, address indexed newRecipient);
    /**
     * @notice Emitted after the full balance of one currency is forwarded.
     */
    event Collected(address indexed caller, address indexed token, address indexed recipient, uint256 amount);

    /**
     * @notice Deploys the collector with its temporary owner and treasury recipient.
     * @dev Both addresses must be nonzero; ownership should be handed to the timelock through Ownable2Step.
     * @param initialOwner Owner that must transfer control to the timelock.
     * @param recipient_ Initial fee recipient.
     */
    constructor(address initialOwner, address recipient_) Ownable(initialOwner) {
        if (initialOwner == address(0) || recipient_ == address(0)) revert ZeroAddress();
        recipient = recipient_;
    }

    /**
     * @inheritdoc IFeeCollector
     */
    function collect(Currency token) external nonReentrant returns (uint256 amount) {
        amount = token.balanceOfSelf();
        address destination = recipient;
        token.transfer(destination, amount); // aderyn-fp(unsafe-erc20-operation)
        emit Collected(msg.sender, Currency.unwrap(token), destination, amount);
    }

    /**
     * @inheritdoc IFeeCollector
     */
    // aderyn-ignore-next-line(centralization-risk)
    function setRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        address oldRecipient = recipient;
        recipient = newRecipient;
        emit RecipientSet(oldRecipient, newRecipient);
    }

    /**
     * @notice Accepts native protocol fees from vaults.
     * @dev Funds remain in the collector until a permissionless `collect` forwards the complete balance.
     */
    receive() external payable {}
}
