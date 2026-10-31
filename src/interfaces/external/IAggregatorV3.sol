// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title Chainlink AggregatorV3 Minimal Interface
 * @notice Minimal subset of the Chainlink AggregatorV3 interface required by PriceGuard.
 * @dev Used for both price feeds and optional L2 sequencer uptime feeds.
 *
 *      Only the two functions PriceGuard needs are declared. For a sequencer uptime feed an `answer` of zero means
 *      the sequencer is up and `updatedAt` is the time it last changed state. Callers must treat every returned
 *      value as untrusted and validate sign, freshness and bounds themselves.
 */
interface IAggregatorV3 {
    /**
     * @notice Returns the number of decimals used by feed answers.
     * @dev Reverts or misbehaves for contracts that are not Chainlink aggregators; callers should wrap the call.
     * @return Feed answer decimals.
     */
    function decimals() external view returns (uint8);

    /**
     * @notice Returns data for the latest completed oracle round.
     * @dev May revert if the feed has no completed round. The `answer` can be zero or negative and may be clamped
     *      to the feed's built-in minimum or maximum during extreme market moves.
     * @return roundId Latest round id.
     * @return answer Latest answer for the feed.
     * @return startedAt Timestamp when the round started.
     * @return updatedAt Timestamp when the round was last updated.
     * @return answeredInRound Round id in which the answer was computed.
     */
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
