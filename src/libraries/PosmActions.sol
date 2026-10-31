// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title Position Manager Action Constants
 * @notice Action ids used when encoding calls for the Uniswap V4 periphery position manager.
 * @dev Action IDs are checked against the pinned v4-periphery Actions library in tests.
 *
 *      Each id is one byte of the `actions` argument passed to `PositionManager.modifyLiquidities`, paired with an
 *      ABI-encoded entry in the `params` array. The values must match the deployed PositionManager exactly; the
 *      fork tests assert them against the pinned release, so never edit them from memory.
 */
library PosmActions {
    /**
     * @notice Increase liquidity action id.
     * @dev Params: `(tokenId, liquidity, amount0Max, amount1Max, hookData)`. Adds liquidity to an existing position.
     */
    uint8 internal constant INCREASE_LIQUIDITY = 0x00;
    /**
     * @notice Decrease liquidity action id.
     * @dev Params: `(tokenId, liquidity, amount0Min, amount1Min, hookData)`. A liquidity of zero collects fees only.
     */
    uint8 internal constant DECREASE_LIQUIDITY = 0x01;
    /**
     * @notice Mint position action id.
     * @dev Params: `(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData)`. Creates a
     *      new position NFT owned by `owner`.
     */
    uint8 internal constant MINT_POSITION = 0x02;
    /**
     * @notice Burn position action id.
     * @dev Params: `(tokenId, amount0Min, amount1Min, hookData)`. Removes remaining liquidity and burns the NFT.
     */
    uint8 internal constant BURN_POSITION = 0x03;
    /**
     * @notice Settle a currency pair action id.
     * @dev Params: `(currency0, currency1)`. Pays the debts owed to the PoolManager from the caller.
     */
    uint8 internal constant SETTLE_PAIR = 0x0d;
    /**
     * @notice Take a currency pair action id.
     * @dev Params: `(currency0, currency1, recipient)`. Sends credits owed by the PoolManager to `recipient`.
     */
    uint8 internal constant TAKE_PAIR = 0x11;
    /**
     * @notice Close currency action id.
     * @dev Params: `(currency)`. Settles a negative currency delta from the caller or takes a positive one to the
     *      caller, whichever direction the delta requires.
     */
    uint8 internal constant CLOSE_CURRENCY = 0x12;
    /**
     * @notice Sweep currency action id.
     * @dev Params: `(currency, recipient)`. Returns the PositionManager's leftover balance, such as unused ETH.
     */
    uint8 internal constant SWEEP = 0x14;
}
