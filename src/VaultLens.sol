// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVault} from "./interfaces/IVault.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IVaultLens} from "./interfaces/IVaultLens.sol";
import {IStateViewLike} from "./interfaces/external/IStateViewLike.sol";
import {VaultM5Module} from "./VaultM5Module.sol";
import {Band, VaultConfig} from "./libraries/Types.sol";
import {PoolIdLib} from "./libraries/PoolIdLib.sol";

/**
 * @title Vortexa Vault Lens
 * @notice Privilege-free, failure-aware dashboard batching for factory-created vaults.
 * @dev A failed optional accounting or pool-state read is reported through availability flags instead of making
 *      an entire dashboard batch unusable. Core identity/configuration reads still fail closed for malformed vaults.
 */
contract VaultLens is IVaultLens {
    using PoolIdLib for *;

    /**
     * @notice Maximum number of vaults accepted by one bounded batch call.
     */
    uint256 public constant MAX_BATCH = 50;

    /**
     * @notice Factory whose registry defines the only accepted vault addresses.
     */
    IVaultFactory public immutable factory;
    /**
     * @notice StateView used to read live V4 pool state.
     */
    IStateViewLike public immutable stateView;

    /**
     * @notice A required constructor or user address is zero.
     */
    error ZeroAddress();
    /**
     * @notice The requested address is not registered by the configured factory.
     */
    error UnknownVault();
    /**
     * @notice A batch exceeds the fixed maximum size.
     */
    error TooMany();

    /**
     * @notice Deploys the lens for one factory and StateView.
     * @dev Both dependencies are immutable and must be nonzero.
     * @param factory_ Factory whose registry defines known vaults.
     * @param stateView_ V4 StateView used for live pool state.
     */
    constructor(IVaultFactory factory_, IStateViewLike stateView_) {
        if (address(factory_) == address(0) || address(stateView_) == address(0)) revert ZeroAddress();
        factory = factory_;
        stateView = stateView_;
    }

    /**
     * @inheritdoc IVaultLens
     */
    function vaultInfo(address vault) public view returns (VaultInfo memory info) {
        if (!factory.isVault(vault)) revert UnknownVault();
        IVault instance = IVault(vault);
        info.vault = vault;
        info.name = instance.name();
        info.symbol = instance.symbol();
        info.config = instance.config();
        info.totalShares = instance.totalSupply();
        info.bands = instance.bands();
        info.lastRebalance = instance.lastRebalance();
        info.paused = instance.paused();
        info.filled = instance.filled();
        info.protocolFeeBps = factory.protocolFeeBps();
        info.feeCollector = factory.feeCollector();

        info.accountingAvailable = true;
        try instance.totalAssets() returns (uint256 assets) {
            info.totalAssets = assets;
        } catch {
            info.accountingAvailable = false;
        }
        if (info.totalShares != 0) {
            try VaultM5Module(instance.m5Module()).previewWithdrawPair(instance, info.totalShares) returns (
                uint256 amount0, uint256 amount1
            ) {
                info.totalAssets0 = amount0;
                info.totalAssets1 = amount1;
            } catch {
                info.accountingAvailable = false;
            }
        }

        try stateView.getSlot0(info.config.poolKey.toId()) returns (uint160 sqrtPriceX96, int24 tick, uint24, uint24) {
            info.poolSqrtPriceX96 = sqrtPriceX96;
            info.poolTick = tick;
            info.poolStateAvailable = sqrtPriceX96 != 0;
            info.inRange = _inRange(info.bands, tick);
        } catch {
            info.poolStateAvailable = false;
        }
    }

    /**
     * @inheritdoc IVaultLens
     */
    function vaultsInfo(address[] calldata vaults) external view returns (VaultInfo[] memory info) {
        uint256 length = vaults.length;
        if (length > MAX_BATCH) revert TooMany();
        info = new VaultInfo[](length);
        // An unregistered vault fails the whole batch closed (`UnknownVault`), by design.
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 i = 0; i < length;) {
            info[i] = vaultInfo(vaults[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @inheritdoc IVaultLens
     */
    function userPosition(address vault, address user) external view returns (UserPosition memory position) {
        if (!factory.isVault(vault)) revert UnknownVault();
        if (user == address(0)) revert ZeroAddress();
        IVault instance = IVault(vault);
        position.shares = instance.balanceOf(user);
        position.accountingAvailable = true;
        if (position.shares == 0) return position;
        try VaultM5Module(instance.m5Module()).previewWithdrawPair(instance, position.shares) returns (
            uint256 amount0, uint256 amount1
        ) {
            position.amount0 = amount0;
            position.amount1 = amount1;
        } catch {
            position.accountingAvailable = false;
        }
    }

    /**
     * @notice Reports whether a live tick belongs to any currently stored half-open band.
     * @dev Empty band sets and gaps between bands return false.
     * @param bands Vault bands to inspect.
     * @param tick Current pool tick.
     * @return inRange True when `tick` is inside at least one band.
     */
    function _inRange(Band[] memory bands, int24 tick) private pure returns (bool inRange) {
        uint256 length = bands.length;
        for (uint256 i = 0; i < length;) {
            if (tick >= bands[i].tickLower && tick < bands[i].tickUpper) return true;
            unchecked {
                ++i;
            }
        }
    }
}
