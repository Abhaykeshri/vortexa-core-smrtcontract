// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title Uniswap V4 StateView Minimal Interface
 * @notice Minimal interface for reading slot0 state from a Uniswap V4 pool.
 * @dev PriceGuard uses `sqrtPriceX96` from `getSlot0` as the current pool price input.
 *
 *      This is a minimal, MIT-licensed interface declared by this project; it contains no Uniswap source. The
 *      pool id passed in is the keccak256 hash of the ABI-encoded `PoolKey` (see `PoolIdLib.toId`). Later
 *      milestones extend this interface with position and fee-growth reads.
 */
interface IStateViewLike {
    /**
     * @notice Reads slot0 for a V4 pool.
     * @dev An uninitialized pool returns a zero `sqrtPriceX96`, which callers must treat as "pool does not exist".
     *      The returned price is the instantaneous spot price and can be manipulated within a single transaction,
     *      so it must always be cross-checked against an external reference before being relied on.
     * @param poolId Pool id derived from a Uniswap V4 `PoolKey`.
     * @return sqrtPriceX96 Current square-root price as a Q64.96 value.
     * @return tick Current pool tick.
     * @return protocolFee Current protocol fee value.
     * @return lpFee Current LP fee value.
     */
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);

    /**
     * @notice Reads a V4 position's liquidity and last fee-growth checkpoints.
     * @dev The salt is the PositionManager NFT id encoded as bytes32 for positions minted by this vault.
     * @param poolId Pool id derived from a Uniswap V4 `PoolKey`.
     * @param owner Position owner recorded in the PoolManager, normally the PositionManager contract.
     * @param tickLower Lower tick of the position.
     * @param tickUpper Upper tick of the position.
     * @param salt Position salt, equal to `bytes32(tokenId)` for PositionManager NFTs.
     * @return liquidity Active position liquidity.
     * @return feeGrowthInside0LastX128 Last recorded fee growth for currency0.
     * @return feeGrowthInside1LastX128 Last recorded fee growth for currency1.
     */
    function getPositionInfo(bytes32 poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128);

    /**
     * @notice Reads current fee growth inside a V4 tick range.
     * @dev Fee growth counters wrap like Uniswap core; callers must use wrapping subtraction for pending fees.
     * @param poolId Pool id derived from a Uniswap V4 `PoolKey`.
     * @param tickLower Lower tick of the range.
     * @param tickUpper Upper tick of the range.
     * @return feeGrowthInside0X128 Current fee growth for currency0 inside the range.
     * @return feeGrowthInside1X128 Current fee growth for currency1 inside the range.
     */
    function getFeeGrowthInside(bytes32 poolId, int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128);
}
