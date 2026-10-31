// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceGuard} from "./IPriceGuard.sol";
import {IPermit2Like} from "./external/IPermit2Like.sol";
import {IPositionManagerLike} from "./external/IPositionManagerLike.sol";
import {IStateViewLike} from "./external/IStateViewLike.sol";
import {Band, RebalanceParams, VaultConfig} from "../libraries/Types.sol";

/**
 * @title Vault Interface
 * @notice ERC-4626-compatible vault plus the guide's dual-token deposit, pair withdrawal, fee and view surface.
 * @dev `asset()` is always pool `currency1`; pair deposits and withdrawals use both pool currencies.
 */
interface IVault {
    /**
     * @notice Caller is not an authorized keeper.
     */
    error NotKeeper();
    /**
     * @notice Automatic rebalance is disabled in the vault configuration.
     */
    error AutoRebalanceOff();
    /**
     * @notice The 30-minute rebalance cooldown has not elapsed.
     */
    error CooldownActive();
    /**
     * @notice The strategy reported no active rebalance trigger.
     */
    error NothingToDo();
    /**
     * @notice Keeper-proposed center is more than 200 ticks from spot.
     */
    error CenterTooFar();
    /**
     * @notice Planned swap exceeds the vault's 60 percent value cap.
     */
    error SwapTooLarge();
    /**
     * @notice Post-rebalance oracle value violates the caller's bounded loss.
     */
    error LossTooLarge();
    /**
     * @notice Requested rebalance slippage exceeds the one-percent hard cap.
     */
    error SlippageTooHigh();
    /**
     * @notice Strategy plan failed independent vault validation.
     */
    error InvalidPlan();

    /**
     * @notice Emitted after a clone is fully initialized and its token approvals are established.
     * @param strategy Immutable strategy selected for the vault.
     * @param poolId Uniswap v4 pool identifier derived from the immutable configuration.
     */
    event VaultInitialized(address indexed strategy, bytes32 indexed poolId);

    /**
     * @notice Emitted after a PDF-style pair deposit deploys liquidity and mints shares.
     * @param caller Account that supplied the deposit.
     * @param receiver Account that received shares.
     * @param used0 Amount of currency0 actually deployed.
     * @param used1 Amount of currency1 actually deployed.
     * @param shares Shares minted to `receiver`.
     */
    event PairDeposited(address indexed caller, address indexed receiver, uint256 used0, uint256 used1, uint256 shares);

    /**
     * @notice Emitted after pair shares are withdrawn for both pool currencies.
     * @param caller Account that burned the shares.
     * @param receiver Account that received both currencies.
     * @param owner Share owner (always the caller).
     * @param shares Shares burned.
     * @param amount0 Currency0 paid to `receiver`.
     * @param amount1 Currency1 paid to `receiver`.
     */
    event PairWithdrawn(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    );

    /**
     * @notice Emitted after trading fees are collected and protocol fees are transferred.
     * @param fee0 Gross currency0 fees collected.
     * @param fee1 Gross currency1 fees collected.
     * @param protocolFee0 Currency0 sent to the fee collector.
     * @param protocolFee1 Currency1 sent to the fee collector.
     */
    event FeesCollected(uint256 fee0, uint256 fee1, uint256 protocolFee0, uint256 protocolFee1);

    /**
     * @notice Emitted after a keeper reinvests idle balances into the existing bands.
     * @param keeper Keeper that ran the compound.
     * @param used0 Currency0 deployed from idle.
     * @param used1 Currency1 deployed from idle.
     */
    event Compounded(address indexed keeper, uint256 used0, uint256 used1);

    /**
     * @notice Emitted when a withdrawal could not deliver the protocol fee and left it with the holders instead.
     * @dev Withdrawals never depend on the fee collector: an unset, reverting, blacklisted or gas-burning
     *      collector forfeits the fee for that withdrawal rather than blocking the exit.
     * @param protocolFee0 Currency0 protocol fee that was not delivered.
     * @param protocolFee1 Currency1 protocol fee that was not delivered.
     */
    event ProtocolFeeForfeited(uint256 protocolFee0, uint256 protocolFee1);

    /**
     * @notice Emitted after all old positions are replaced by a validated strategy plan.
     */
    event Rebalanced(
        address indexed keeper, int24 oldCenterTick, int24 newCenterTick, uint256 valueBefore, uint256 valueAfter
    );

    /**
     * @notice Initializes a clone with metadata, strategy, and immutable vault configuration.
     * @dev Callable exactly once by the constructor-configured factory.
     * @param name_ ERC-20 share name.
     * @param symbol_ ERC-20 share symbol.
     * @param strategy_ Strategy contract used for deposit gates and rebalance triggers.
     * @param config_ Immutable vault configuration.
     */
    function initialize(string calldata name_, string calldata symbol_, address strategy_, VaultConfig calldata config_)
        external;

    /**
     * @notice Deposits both pool currencies according to the M4 developer guide.
     * @dev Native ETH is accepted only when `currency0` is native and must equal `amount0`.
     * @param amount0 Maximum currency0 amount supplied.
     * @param amount1 Maximum currency1 amount supplied.
     * @param minShares Minimum acceptable shares.
     * @param receiver Share recipient.
     * @return shares Shares minted.
     * @return used0 Currency0 amount deployed.
     * @return used1 Currency1 amount deployed.
     */
    function depositPair(uint256 amount0, uint256 amount1, uint256 minShares, address receiver)
        external
        payable
        returns (uint256 shares, uint256 used0, uint256 used1);

    /**
     * @notice Burns the caller's shares and withdraws the proportional pool currencies.
     * @dev Does not depend on pause state, PriceGuard, keepers, the factory or the fee collector.
     * @param shares Shares to burn.
     * @param min0 Minimum accepted currency0 output.
     * @param min1 Minimum accepted currency1 output.
     * @param receiver Receiver of withdrawn currencies.
     * @return amount0 Currency0 amount paid to receiver.
     * @return amount1 Currency1 amount paid to receiver.
     */
    function withdrawPair(uint256 shares, uint256 min0, uint256 min1, address receiver)
        external
        returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Collects accrued trading fees from all active positions.
     * @dev Permissionless; protocol fees are deducted from collected trading fees only.
     * @return fee0 Gross currency0 trading fees collected.
     * @return fee1 Gross currency1 trading fees collected.
     */
    function collectFees() external returns (uint256 fee0, uint256 fee1);

    /**
     * @notice Reinvests idle balances into existing bands without minting shares.
     * @dev Keeper-only and PriceGuard-gated because it adds liquidity at the current pool price.
     * @return used0 Currency0 amount deployed.
     * @return used1 Currency1 amount deployed.
     */
    function compound() external returns (uint256 used0, uint256 used1);

    /**
     * @notice Atomically removes all positions and applies a bounded strategy plan.
     * @dev Keeper-only; protected by cooldown, oracle, center, swap-size, and final-value brakes.
     * @param params Hostile keeper inputs independently bounded by the vault.
     */
    function rebalance(RebalanceParams calldata params) external;

    /**
     * @notice Reports whether the strategy wants a rebalance and every vault-side gate would allow it.
     * @dev Never changes state. Gates, in order: pause, auto-rebalance, cooldown, PriceGuard, strategy trigger.
     * @return needed True when keeper action is warranted now.
     * @return reason Strategy reason, or the label of the gate that blocked.
     */
    function checkRebalance() external view returns (bool needed, bytes32 reason);

    /**
     * @notice Pauses deposits and keeper actions.
     * @dev Callable only by the factory or its guardian.
     */
    function pause() external;

    /**
     * @notice Resumes deposits and keeper actions.
     * @dev Callable only by the factory or its owner; the guardian cannot unpause.
     */
    function unpause() external;

    /**
     * @notice Returns the immutable vault configuration.
     * @dev Never changes after initialization.
     * @return vaultConfig Stored configuration.
     */
    function config() external view returns (VaultConfig memory vaultConfig);

    /**
     * @notice Returns the active liquidity bands.
     * @dev Empty until the first pair deposit.
     * @return activeBands Current bands with stored liquidity.
     */
    function bands() external view returns (Band[] memory activeBands);

    /**
     * @notice Returns whether deposits and keeper actions are paused.
     * @dev Withdrawals ignore this flag.
     * @return isPaused Current pause flag.
     */
    function paused() external view returns (bool isPaused);

    /**
     * @notice Returns the timestamp of the last rebalance.
     * @dev Zero until the first rebalance (milestone 6).
     * @return timestamp Last rebalance time.
     */
    function lastRebalance() external view returns (uint64 timestamp);

    /**
     * @notice Returns the PriceGuard used by this vault.
     * @dev Immutable per implementation.
     * @return guard PriceGuard address.
     */
    function priceGuard() external view returns (IPriceGuard guard);

    /**
     * @notice Returns the total share supply, including the locked dead shares.
     * @dev Standard ERC-20 view.
     * @return supply Total shares.
     */
    function totalSupply() external view returns (uint256 supply);

    /**
     * @notice Returns the token1-denominated ERC-4626 total asset value.
     * @dev May revert when downstream pool accounting is unavailable.
     * @return assets Current token1-denominated value.
     */
    function totalAssets() external view returns (uint256 assets);

    /**
     * @notice Returns an account's vault share balance.
     * @dev Shares use the vault's native ERC-20 accounting.
     * @param account Account to inspect.
     * @return shares Share balance.
     */
    function balanceOf(address account) external view returns (uint256 shares);

    /**
     * @notice Returns the share-token name.
     * @dev Set once by factory-controlled initialization.
     * @return vaultName ERC-20 name.
     */
    function name() external view returns (string memory vaultName);

    /**
     * @notice Returns the share-token symbol.
     * @dev Set once by factory-controlled initialization.
     * @return vaultSymbol ERC-20 symbol.
     */
    function symbol() external view returns (string memory vaultSymbol);

    /**
     * @notice Returns whether a lock-on-fill vault has entered its terminal filled state.
     * @dev A filled vault keeps withdrawals available while deposits and future rebalances remain disabled.
     * @return isFilled True when deposits and future rebalances are permanently disabled.
     */
    function filled() external view returns (bool isFilled);

    /**
     * @notice Returns the PositionManager that holds this vault's position NFTs.
     * @dev Immutable per implementation.
     * @return manager PositionManager address.
     */
    function positionManager() external view returns (IPositionManagerLike manager);

    /**
     * @notice Returns the Permit2 contract the vault approves for PositionManager settlement.
     * @dev Immutable per implementation; allowances are exact and revoked after each call.
     * @return allowanceContract Permit2 address.
     */
    function permit2() external view returns (IPermit2Like allowanceContract);

    /**
     * @notice Returns the factory whose fee settings, keepers, guardian and owner this vault reads.
     * @dev Immutable per implementation.
     * @return vaultFactory Factory address.
     */
    function factory() external view returns (address vaultFactory);

    /**
     * @notice Returns the M5 module that runs this vault's withdraw, fee and compound logic.
     * @dev Constructor-created by the implementation; also serves `previewWithdrawPair(vault, shares)`, the in-kind
     *      withdrawal preview (guide 7.4), called directly on the module.
     * @return module M5 module address.
     */
    function m5Module() external view returns (address module);

    /**
     * @notice Returns the immutable M6 rebalance module.
     * @dev Constructor-selected and shared by implementation clones.
     * @return module M6 module address.
     */
    function m6Module() external view returns (address module);

    /**
     * @notice Returns the immutable swap executor.
     * @dev Zero is supported only by legacy M0-M5 test deployments, where rebalance is unavailable.
     * @return executor Swap executor address.
     */
    function swapExecutor() external view returns (address executor);

    /**
     * @notice Returns the StateView used by this vault.
     * @dev Immutable per implementation.
     * @return lens StateView address.
     */
    function stateView() external view returns (IStateViewLike lens);
}
