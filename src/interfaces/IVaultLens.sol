// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Band, VaultConfig} from "../libraries/Types.sol";

/**
 * @title Vault Lens Interface
 * @notice Read-only dashboard aggregation for factory-created vaults.
 * @dev Availability flags distinguish legitimate zero values from optional downstream read failures.
 */
interface IVaultLens {
    /**
     * @notice Aggregated state for one vault.
     */
    struct VaultInfo {
        address vault;
        string name;
        string symbol;
        VaultConfig config;
        uint256 totalShares;
        uint256 totalAssets;
        uint256 totalAssets0;
        uint256 totalAssets1;
        uint256 protocolFeeBps;
        address feeCollector;
        uint160 poolSqrtPriceX96;
        int24 poolTick;
        Band[] bands;
        uint64 lastRebalance;
        bool inRange;
        bool paused;
        bool filled;
        bool accountingAvailable;
        bool poolStateAvailable;
    }

    /**
     * @notice A user's shares and exact current in-kind withdrawal preview.
     */
    struct UserPosition {
        uint256 shares;
        uint256 amount0;
        uint256 amount1;
        bool accountingAvailable;
    }

    /**
     * @notice Returns aggregated information for a registered vault.
     * @dev Reverts for unknown vaults; optional accounting and pool failures are represented by flags.
     * @param vault Vault to inspect.
     * @return info Aggregated vault information.
     */
    function vaultInfo(address vault) external view returns (VaultInfo memory info);

    /**
     * @notice Returns aggregated information for at most fifty registered vaults.
     * @dev Preserves input order and applies the same registered-vault checks as `vaultInfo`.
     * @param vaults Vaults to inspect.
     * @return info Aggregated information in input order.
     */
    function vaultsInfo(address[] calldata vaults) external view returns (VaultInfo[] memory info);

    /**
     * @notice Returns a user's shares and current pair-token position.
     * @dev A failed optional withdrawal preview sets `accountingAvailable` false rather than reverting.
     * @param vault Registered vault.
     * @param user Account to inspect.
     * @return position User position.
     */
    function userPosition(address vault, address user) external view returns (UserPosition memory position);
}
