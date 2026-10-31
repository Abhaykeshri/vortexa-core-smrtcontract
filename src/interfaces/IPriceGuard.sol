// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "../libraries/Types.sol";

/**
 * @title PriceGuard Interface
 * @notice Defines the configuration and runtime checks used to validate pool prices against oracle references.
 * @dev Implementations are expected to compare a Uniswap V4 pool price with Chainlink and/or Uniswap V3 TWAP
 *      references and return trust status without mutating state during price checks.
 *
 *      Consumers (vault, swap executor, factory) call `isPriceTrusted` in the same transaction as any action that
 *      values shares or accepts a swap price, and never cache the result. Withdrawal paths must not call this
 *      interface, so an oracle outage can never trap user funds.
 */
interface IPriceGuard {
    /**
     * @notice Reference-oracle configuration for one Uniswap V4 pool.
     * @dev At least one of `chainlinkFeed` or `v3Pool` must be configured by the implementation. The Chainlink feed
     *      is the primary reference and the V3 TWAP is the fallback. A `maxDeviationBps` of zero marks an unset
     *      configuration, so implementations must reject zero when storing.
     */
    struct PairConfig {
        /**
         * @notice Chainlink AggregatorV3 feed used as the primary reference.
         */
        address chainlinkFeed;
        /**
         * @notice Whether the feed quotes token0 per token1 instead of token1 per token0, so the answer is inverted.
         */
        bool invertFeed;
        /**
         * @notice Maximum age, in seconds, accepted for the Chainlink answer.
         */
        uint32 maxStaleness;
        /**
         * @notice Minimum accepted Chainlink answer, in feed decimals; guards against clamped feeds.
         */
        uint256 minAnswer;
        /**
         * @notice Maximum accepted Chainlink answer, in feed decimals; guards against clamped feeds.
         */
        uint256 maxAnswer;
        /**
         * @notice Uniswap V3 pool used as the fallback TWAP reference.
         */
        address v3Pool;
        /**
         * @notice Whether the V3 pool's token ordering is reversed against the V4 pool key, so the TWAP is inverted.
         */
        bool invertV3;
        /**
         * @notice TWAP window, in seconds, used when reading the V3 fallback pool.
         */
        uint32 twapWindow;
        /**
         * @notice Maximum allowed deviation from the selected reference, denominated in basis points.
         */
        uint16 maxDeviationBps;
    }

    /**
     * @notice Emitted when a pool reference configuration is stored.
     * @dev Emitted by `setPairConfig` after validation and storage, so indexers always see the stored values.
     * @param poolId Uniswap V4 pool id derived from `key`.
     * @param key Uniswap V4 pool key configured by the owner.
     * @param config Oracle and deviation configuration stored for the pool.
     * @param decimals0 Cached decimals for `key.currency0`.
     * @param decimals1 Cached decimals for `key.currency1`.
     */
    event PairConfigSet(bytes32 indexed poolId, PoolKey key, PairConfig config, uint8 decimals0, uint8 decimals1);

    /**
     * @notice Stores or replaces the oracle configuration for a Uniswap V4 pool.
     * @dev Restricted to the owner, which is expected to be a timelock. Implementations must validate the
     *      configuration, cache both currencies' decimals, and confirm that the converted reference price agrees
     *      with the live pool price before storing, and must emit `PairConfigSet`.
     * @param key Pool key identifying the V4 pool.
     * @param config Oracle reference and deviation settings for the pool.
     */
    function setPairConfig(PoolKey calldata key, PairConfig calldata config) external;

    /**
     * @notice Checks whether the current V4 pool price is within the configured deviation from the reference price.
     * @dev Must not mutate state. Stale, missing or invalid oracle data returns `(false, type(uint256).max)` rather
     *      than reverting, so callers can raise one clear error; only a pool without a configuration reverts.
     * @param key Pool key identifying the V4 pool to check.
     * @return trusted True when the pool price is within the configured deviation and safety checks pass.
     * @return devBps Observed deviation in basis points, or `type(uint256).max` when no trusted reference is available.
     */
    function isPriceTrusted(PoolKey calldata key) external view returns (bool trusted, uint256 devBps);

    /**
     * @notice Returns the current trusted oracle reference price for a pool.
     * @dev Reverts when the pair is not configured or its oracle/reference is not currently usable.
     * @param key Pool key identifying the configured V4 pool.
     * @return sqrtPriceX96 Trusted reference price in Q64.96 format.
     */
    function referenceSqrtPriceX96(PoolKey calldata key) external view returns (uint160 sqrtPriceX96);

    /**
     * @notice Returns the stored oracle configuration and cached currency decimals for a pool.
     * @dev An unset pool returns a zeroed configuration; callers distinguish it by `maxDeviationBps == 0`.
     * @param key Pool key identifying the V4 pool.
     * @return config Stored pair configuration.
     * @return decimals0 Cached decimals for currency0.
     * @return decimals1 Cached decimals for currency1.
     */
    function configOf(PoolKey calldata key)
        external
        view
        returns (PairConfig memory config, uint8 decimals0, uint8 decimals1);
}
