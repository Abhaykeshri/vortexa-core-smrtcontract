// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IStrategy} from "./IStrategy.sol";
import {PoolKey, Strategy, VaultConfig} from "../libraries/Types.sol";

/**
 * @title Vault Factory Minimal Interface
 * @notice M8 factory identity used by M4 vault clones.
 * @dev Real clone deployment and governance behavior belongs to M8; M4 only gates initialization by factory.
 */
interface IVaultFactory {
    /**
     * @notice Per-pool vault creation policy.
     */
    struct PoolRule {
        bool allowed;
        bool baseIsCurrency0;
        uint256 maxDepositCap;
    }

    /**
     * @notice Emitted when the current protocol fee changes.
     * @param oldFeeBps Previous current protocol fee in basis points.
     * @param newFeeBps New current protocol fee in basis points.
     */
    event ProtocolFeeBpsSet(uint256 oldFeeBps, uint256 newFeeBps);

    /**
     * @notice Emitted when the maximum permitted protocol fee changes.
     * @param oldMaxFeeBps Previous maximum protocol fee in basis points.
     * @param newMaxFeeBps New maximum protocol fee in basis points.
     */
    event MaxProtocolFeeBpsSet(uint256 oldMaxFeeBps, uint256 newMaxFeeBps);

    /**
     * @notice Returns the current protocol fee charged on collected trading fees.
     * @dev Mutable by authorized governance in the M5 mock and production M8 factory.
     * @return feeBps Current fee in basis points.
     */
    function protocolFeeBps() external view returns (uint256 feeBps);

    /**
     * @notice Returns the current maximum permitted protocol fee.
     * @dev Raj Sir confirmed this cap is mutable state, not a Solidity constant.
     * @return maxFeeBps Maximum fee in basis points.
     */
    function maxProtocolFeeBps() external view returns (uint256 maxFeeBps);

    /**
     * @notice Updates the current protocol fee.
     * @dev Must enforce `newFeeBps <= maxProtocolFeeBps`.
     * @param newFeeBps New current fee in basis points.
     */
    function setProtocolFeeBps(uint256 newFeeBps) external;

    /**
     * @notice Updates the maximum permitted protocol fee.
     * @dev Must enforce `protocolFeeBps <= newMaxFeeBps <= 10_000`.
     * @param newMaxFeeBps New maximum fee in basis points.
     */
    function setMaxProtocolFeeBps(uint256 newMaxFeeBps) external;

    /**
     * @notice Returns the protocol fee collector.
     * @dev Vaults transfer protocol fee amounts to this address during settlement.
     * @return collector Fee collector address.
     */
    function feeCollector() external view returns (address collector);

    /**
     * @notice Reports whether an address is authorized to run keeper-only vault actions.
     * @dev Used by M5 `compound`; production keeper administration belongs to M8.
     * @param keeper Candidate keeper address.
     * @return authorized True when `keeper` is authorized.
     */
    function isKeeper(address keeper) external view returns (bool authorized);

    /**
     * @notice Reports whether an address is a known vault.
     * @dev Included for future M8 compatibility; M4 does not rely on this for fund movement.
     * @param vault Candidate vault address.
     * @return known True when `vault` is registered.
     */
    function isVault(address vault) external view returns (bool known);

    /**
     * @notice Returns the guardian allowed to pause vaults.
     * @dev The guardian can pause deposits and rebalances but cannot unpause or move funds.
     * @return account Guardian address.
     */
    function guardian() external view returns (address account);

    /**
     * @notice Returns the factory owner (the timelock) allowed to unpause vaults.
     * @dev Only the owner can resume deposits after a pause.
     * @return account Owner address.
     */
    function owner() external view returns (address account);

    /**
     * @notice Returns the implementation used for newly created vaults.
     * @dev Existing vaults do not follow later implementation changes.
     * @return vaultImplementation Current EIP-1167 implementation.
     */
    function implementation() external view returns (address vaultImplementation);

    /**
     * @notice Returns the registered strategy contract for a strategy kind.
     * @dev Registry changes apply only to future vault creation.
     * @param kind Strategy enum value.
     * @return strategy Registered strategy.
     */
    function strategyOf(Strategy kind) external view returns (IStrategy strategy);

    /**
     * @notice Returns the creation rule for a pool id.
     * @dev The rule normalizes base orientation and bounds the per-vault deposit cap.
     * @param poolId V4 pool id.
     * @return allowed Whether new vaults may target the pool.
     * @return baseIsCurrency0 Approved base-asset orientation.
     * @return maxDepositCap Maximum per-vault deposit cap.
     */
    function poolRule(bytes32 poolId) external view returns (bool allowed, bool baseIsCurrency0, uint256 maxDepositCap);

    /**
     * @notice Creates and initializes a deterministic vault clone.
     * @dev Registration occurs only after successful initialization.
     * @param config Requested immutable configuration.
     * @param name Share-token name.
     * @param symbol Share-token symbol.
     * @return vault Created vault address.
     */
    function createVault(VaultConfig calldata config, string calldata name, string calldata symbol)
        external
        returns (address vault);

    /**
     * @notice Predicts a creator-specific deterministic vault address.
     * @dev Uses the current implementation and the pool rule's normalized base orientation.
     * @param creator Account whose salt namespace is used.
     * @param config Requested configuration; pool orientation is normalized from the pool rule.
     * @param name Share-token name.
     * @param symbol Share-token symbol.
     * @return predicted Predicted clone address.
     */
    function predictVaultAddress(
        address creator,
        VaultConfig calldata config,
        string calldata name,
        string calldata symbol
    ) external view returns (address predicted);

    /**
     * @notice Returns the number of registered vaults.
     * @dev The count increases only after successful clone initialization.
     * @return count Registry size.
     */
    function vaultCount() external view returns (uint256 count);

    /**
     * @notice Returns a registered vault by index.
     * @dev Reverts through Solidity bounds checking when `index` is not below `vaultCount()`.
     * @param index Registry index.
     * @return vault Vault address.
     */
    function vaultAt(uint256 index) external view returns (address vault);
}
