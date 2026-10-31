// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title Uniswap V3 Pool Minimal Interface
 * @notice Minimal interface for validating pool tokens and reading TWAP data from a Uniswap V3 pool.
 * @dev PriceGuard uses this as a fallback reference when Chainlink is unavailable or invalid.
 *
 *      V3 TWAPs can be manipulated on thin pools and short windows, so only deep-liquidity pools with a window of
 *      at least ten minutes should be configured. V3 orders tokens by address, which can differ from the V4 key
 *      ordering when native ETH is involved; the pair configuration's `invertV3` flag compensates for that.
 */
interface IUniswapV3PoolLike {
    /**
     * @notice Returns the first token in the V3 pool's canonical ordering.
     * @dev The lower address of the pair. Reverts for contracts that are not V3 pools.
     * @return Address of token0.
     */
    function token0() external view returns (address);

    /**
     * @notice Returns the second token in the V3 pool's canonical ordering.
     * @dev The higher address of the pair. Reverts for contracts that are not V3 pools.
     * @return Address of token1.
     */
    function token1() external view returns (address);

    /**
     * @notice Returns cumulative tick observations for the requested lookback points.
     * @dev Reverts when the oracle history is shorter than the oldest requested point. The mean tick between two
     *      observations is the difference of the tick cumulatives divided by the elapsed seconds, rounded toward
     *      negative infinity.
     * @param secondsAgos Array of seconds-before-current timestamps to observe.
     * @return tickCumulatives Cumulative ticks at each requested observation point.
     * @return secondsPerLiquidityCumulativeX128s Cumulative seconds-per-liquidity values at each observation point.
     */
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
