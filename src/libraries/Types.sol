// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title Core Shared Types
 * @notice Shared value types, structs, and enums used by Vortexa core contracts.
 * @dev M0-M2 primarily use `Currency` and `PoolKey`; later milestone structs are defined here to keep ABI types
 *      consistent across modules.
 *
 *      Every struct and enum lives in this one file so that interfaces and contracts import identical
 *      definitions. Field order is part of the ABI: `PoolKey` must match Uniswap's field order exactly because it
 *      is hashed into the pool id, and the other structs are final shapes that downstream interfaces rely on.
 */

/**
 * @notice Currency identifier where the zero address represents native ETH and non-zero values represent ERC-20s.
 * @dev Same encoding as Uniswap's `Currency`. Only `currency0` of a pool can be native ETH because Uniswap sorts
 *      currencies by address and the zero address sorts first.
 */
type Currency is address;

/**
 * @notice Minimal Uniswap V4 pool key used to derive pool ids and read pool state.
 * @dev The field order must match Uniswap's `PoolKey` exactly, because the pool id is the keccak256 hash of the
 *      ABI-encoded struct. Currencies are sorted by address, `currency0 < currency1`.
 */
struct PoolKey {
    /**
     * @notice First currency in the pool key ordering.
     */
    Currency currency0;
    /**
     * @notice Second currency in the pool key ordering.
     */
    Currency currency1;
    /**
     * @notice Pool LP fee in hundredths of a bip, matching Uniswap V4 fee encoding.
     */
    uint24 fee;
    /**
     * @notice Pool tick spacing.
     */
    int24 tickSpacing;
    /**
     * @notice Hook contract address, or zero when the pool has no hooks.
     */
    address hooks;
}

/**
 * @notice High-level strategy selector for later vault planning milestones.
 * @dev The numeric values are stored in vault configuration and emitted in events, so new strategies must only be
 *      appended and existing members must never be reordered.
 */
enum Strategy {
    /**
     * @notice Standard liquidity provision without directional trigger behavior.
     */
    NormalLP,
    /**
     * @notice Strategy intended to add or rebalance liquidity when price falls.
     */
    BuyTheDip,
    /**
     * @notice Strategy intended to add or rebalance liquidity when price rises.
     */
    SellThePump
}

/**
 * @notice Deposit token selection mode for later vault deposit flows.
 * @dev Reported by a strategy to tell the vault which tokens it accepts. One-sided strategies accept a single
 *      token because their bands sit entirely on one side of the pool price.
 */
enum DepositMode {
    /**
     * @notice Deposit both pool currencies.
     */
    BothTokens,
    /**
     * @notice Deposit only currency0.
     */
    Token0Only,
    /**
     * @notice Deposit only currency1.
     */
    Token1Only
}

/**
 * @notice One liquidity band in a planned or active position set.
 * @dev Planned bands (returned by the shape library) carry zero `tokenId` and `liquidity`. Active bands record the
 *      PositionManager NFT the vault owns for the band. Ticks must be multiples of the pool's tick spacing and lie
 *      within the usable tick range; bands of one vault must be contiguous and non-overlapping.
 */
struct Band {
    /**
     * @notice Lower tick boundary for the band.
     */
    int24 tickLower;
    /**
     * @notice Upper tick boundary for the band.
     */
    int24 tickUpper;
    /**
     * @notice Position manager token id associated with the band.
     */
    uint256 tokenId;
    /**
     * @notice Active liquidity assigned to the band.
     */
    uint128 liquidity;
}

/**
 * @notice User-facing vault strategy configuration used by later milestones.
 * @dev Written once when a vault is initialized and immutable afterwards: no privileged function may change it.
 *      The factory overwrites `baseIsCurrency0` with the value from the pool rule so a creator cannot flip it.
 *      One-sided strategies use `trailTicks` and `lockOnFill`; Normal LP uses `driftTicks`.
 */
struct VaultConfig {
    /**
     * @notice Pool key targeted by the vault.
     */
    PoolKey poolKey;
    /**
     * @notice Strategy selected for the vault.
     */
    Strategy strategy;
    /**
     * @notice Shape identifier used by the planning logic.
     */
    uint8 shapeId;
    /**
     * @notice Center tick around which bands are planned.
     */
    int24 centerTick;
    /**
     * @notice Distance in ticks from the center to the lower edge of the range.
     */
    int24 ticksLeft;
    /**
     * @notice Distance in ticks from the center to the upper edge of the range.
     */
    int24 ticksRight;
    /**
     * @notice Normal LP: act when the pool tick is within this many ticks of a range edge.
     */
    uint24 driftTicks;
    /**
     * @notice One-sided strategies: act when the price has moved this many ticks away from the range.
     */
    uint24 trailTicks;
    /**
     * @notice Whether keepers may rebalance this vault.
     */
    bool autoRebalance;
    /**
     * @notice One-sided strategies: remove liquidity and hold idle once the range is fully converted.
     */
    bool lockOnFill;
    /**
     * @notice Maximum total vault value, denominated in token1 units; zero means no cap.
     */
    uint256 depositCap;
    /**
     * @notice Whether the volatile base asset is `poolKey.currency0`; the other currency is the quote asset.
     */
    bool baseIsCurrency0;
}

/**
 * @notice Output of planning logic describing bands and optional swap intent.
 * @dev Produced by a strategy and never trusted by the vault: the vault re-checks band alignment, weights, the
 *      single-sided rule and the swap size before any token moves. `swapAmountIn` must be zero for every strategy
 *      other than Normal LP. When `lockIdle` is true, `bands` is empty and no swap is requested.
 */
struct Plan {
    /**
     * @notice Planned liquidity bands.
     */
    Band[] bands;
    /**
     * @notice Band weights in basis points.
     */
    uint16[] weightsBps;
    /**
     * @notice Whether executing the plan requires a swap.
     */
    bool needsSwap;
    /**
     * @notice Swap direction when `needsSwap` is true.
     */
    bool zeroForOne;
    /**
     * @notice Input amount for the planned swap.
     */
    uint256 swapAmountIn;
    /**
     * @notice Whether remaining idle assets should be locked.
     */
    bool lockIdle;
}

/**
 * @notice Parameters supplied to a rebalance operation.
 * @dev Supplied by a keeper, who is trusted for liveness only. Both values are treated as hostile: the vault
 *      bounds the center against the real pool tick and the slippage against its own loss check.
 */
struct RebalanceParams {
    /**
     * @notice Suggested center tick for the new position set; ignored by one-sided strategies.
     */
    int24 newCenterTick;
    /**
     * @notice Maximum accepted value loss for the rebalance, in basis points, measured at the oracle price.
     */
    uint16 maxSlippageBps;
}
