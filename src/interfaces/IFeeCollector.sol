// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "../libraries/Types.sol";

/**
 * @title Fee Collector Minimal Interface
 * @notice M8 fee collector surface consumed by M5 tests and mocks.
 * @dev Production M8 owns implementation details; M5 only relies on this small collection surface.
 */
interface IFeeCollector {
    /**
     * @notice Sends the full balance of a currency to the configured recipient.
     * @dev Callable by anyone so protocol fees cannot be stuck behind keeper availability.
     * @param token Currency to collect; zero address represents native ETH.
     * @return amount Amount forwarded to the recipient.
     */
    function collect(Currency token) external returns (uint256 amount);

    /**
     * @notice Updates the recipient that receives collected balances.
     * @dev Production authorization is owned by M8 governance; mocks use owner-only authorization.
     * @param recipient New recipient address.
     */
    function setRecipient(address recipient) external;

    /**
     * @notice Returns the current recipient.
     * @dev Used by tests and operational tooling to verify forwarding configuration.
     * @return recipient Recipient address.
     */
    function recipient() external view returns (address recipient);
}
