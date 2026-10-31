// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Band, DepositMode, Plan, VaultConfig} from "../libraries/Types.sol";

/**
 * @title Strategy Minimal Interface
 * @notice M7 strategy surface consumed by the M4 vault deposit gate.
 * @dev M4 uses mocks for this interface; real strategy business logic belongs to M7.
 */
interface IStrategy {
    /**
     * @notice Reverts when a vault configuration is incompatible with this strategy.
     * @dev Called once during vault initialization before configuration is stored.
     * @param config Immutable vault configuration to validate.
     * @param tick Pool tick used to validate tick-dependent planning bounds.
     */
    function validateConfig(VaultConfig calldata config, int24 tick) external view;

    /**
     * @notice Reports whether a deposit is currently allowed for a vault.
     * @dev The vault treats the result as advisory only and still validates amounts, price trust, and bands.
     * @param config Immutable vault configuration.
     * @param tick Current V4 pool tick.
     * @param bands Current active vault bands.
     * @return allowed True when deposits may proceed.
     */
    function canDeposit(VaultConfig calldata config, int24 tick, Band[] calldata bands)
        external
        view
        returns (bool allowed);

    /**
     * @notice Returns which pool currencies the strategy accepts for direct pair deposits.
     * @dev The vault enforces the returned mode before pulling funds.
     * @param config Immutable vault configuration, including base-token orientation.
     * @return mode Accepted deposit token mode.
     */
    function depositMode(VaultConfig calldata config) external view returns (DepositMode mode);

    /**
     * @notice Reports whether a vault should rebalance.
     * @dev M5 uses a mock implementation; production strategy logic belongs to M7.
     * @param config Immutable vault configuration.
     * @param tick Current V4 pool tick.
     * @param bands Current active vault bands.
     * @return needed True when a rebalance should be considered.
     * @return reason Strategy-specific trigger reason.
     */
    function checkTrigger(VaultConfig calldata config, int24 tick, Band[] calldata bands)
        external
        view
        returns (bool needed, bytes32 reason);

    /**
     * @notice Produces a bounded rebalance plan for the vault to independently validate.
     * @dev The vault treats every returned field as untrusted and revalidates it before moving funds.
     * @param config Vault configuration.
     * @param tick Current pool tick.
     * @param newCenterTick Keeper-proposed center tick.
     * @param sqrtPriceX96 Trusted pool price snapshot.
     * @param amount0 Available currency0.
     * @param amount1 Available currency1.
     * @param reason Trigger reason returned by `checkTrigger`.
     * @return plan_ Strategy plan containing target bands and optional swap intent.
     */
    function plan(
        VaultConfig calldata config,
        int24 tick,
        int24 newCenterTick,
        uint160 sqrtPriceX96,
        uint256 amount0,
        uint256 amount1,
        bytes32 reason
    ) external view returns (Plan memory plan_);
}
