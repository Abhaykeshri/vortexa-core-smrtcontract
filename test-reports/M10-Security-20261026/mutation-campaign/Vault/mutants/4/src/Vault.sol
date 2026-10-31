// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {IPriceGuard} from "./interfaces/IPriceGuard.sol";
import {IShapeLibrary} from "./interfaces/IShapeLibrary.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {ISwapExecutor} from "./interfaces/ISwapExecutor.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IPositionManagerLike} from "./interfaces/external/IPositionManagerLike.sol";
import {IPermit2Like} from "./interfaces/external/IPermit2Like.sol";
import {IStateViewLike} from "./interfaces/external/IStateViewLike.sol";
import {VaultM5Module} from "./VaultM5Module.sol";
import {Currency, DepositMode, Band, PoolKey, RebalanceParams, VaultConfig} from "./libraries/Types.sol";
import {CurrencyLib} from "./libraries/CurrencyLib.sol";
import {LiquidityMath} from "./libraries/LiquidityMath.sol";
import {PoolIdLib} from "./libraries/PoolIdLib.sol";
import {PosmActions} from "./libraries/PosmActions.sol";
import {SqrtPriceMath} from "./libraries/SqrtPriceMath.sol";

/**
 * @title Vortexa Vault
 * @notice M4 vault with ERC-4626 shares and a dual-token Uniswap V4 liquidity deposit extension.
 * @dev Non-upgradeable implementation intended to be used behind EIP-1167 clones. Constructor immutables are
 *      shared by clones, while `initialize` writes clone-local config exactly once. ERC-4626 accounting is
 *      denominated in `currency1`, which must be an ERC-20. `depositPair` preserves the developer guide's
 *      two-token deposit flow; standard ERC-4626 entry points are conservative wrappers around the same value
 *      accounting and never accept native ETH as the asset.
 */
contract Vault is IVault, ReentrancyGuardTransient {
    using CurrencyLib for Currency;
    using PoolIdLib for PoolKey;
    using SafeERC20 for IERC20;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.BooleanSlot;

    /**
     * @notice Caller is not authorized for the requested operation.
     */
    error NotAuthorized();
    /**
     * @notice A required address is zero.
     */
    error ZeroAddress();
    /**
     * @notice The vault is already initialized.
     */
    error AlreadyInitialized();
    /**
     * @notice The implementation contract cannot be initialized.
     */
    error ImplementationLocked();
    /**
     * @notice Deposits are paused.
     */
    error IsPaused();
    /**
     * @notice PriceGuard did not trust the current pool price.
     */
    error PriceUntrusted();
    /**
     * @notice The strategy does not currently allow deposits.
     */
    error DepositNotAllowed();
    /**
     * @notice Supplied assets do not match the strategy deposit mode.
     */
    error InvalidDepositMode();
    /**
     * @notice Native ETH amount does not match the expected pool currency amount.
     */
    error InvalidNativeValue();
    /**
     * @notice Shares or assets were below the caller-supplied limit.
     */
    error SlippageExceeded();
    /**
     * @notice Deposit would exceed the configured cap.
     */
    error DepositCapExceeded();
    /**
     * @notice The measured deposit value is zero.
     */
    error ZeroValue();
    /**
     * @notice First deposit is below the guide's anti-inflation minimum.
     */
    error FirstDepositTooSmall();
    /**
     * @notice A token transferred less than the requested amount.
     */
    error TokenTransferShortfall();
    /**
     * @notice A computed liquidity amount is zero.
     */
    error ZeroLiquidity();
    /**
     * @notice PositionManager did not mint the expected NFT to the vault.
     */
    error InvalidPositionOwner();
    /**
     * @notice ERC-4626 operation exceeds currently liquid asset limits.
     */
    error ExceedsMax();
    /**
     * @notice ETH was received from an unapproved sender.
     */
    error InvalidEthSender();
    /**
     * @notice The pool price changed between the deposit's oracle check and its liquidity addition.
     * @dev Only code run during the token pulls (for example an ERC-777 style hook) can move the price there.
     */
    error PriceMovedDuringDeposit();
    /**
     * @notice An NFT arrived outside the vault's own PositionManager call, or from another contract.
     */
    error UnexpectedNft();
    /**
     * @notice A Permit2 approval amount does not fit Permit2's uint160 allowance field.
     * @dev Raised by the M5 module during `compound`; declared here so it is part of the vault's ABI.
     */
    // Retained in the public Vault ABI because delegate modules revert with this selector.
    // aderyn-fp-next-line(unused-error)
    error PermitAmountTooLarge();

    /**
     * @notice Emitted when ERC-4626 assets are deposited for shares.
     * @param caller Account that supplied assets.
     * @param owner Account that received shares.
     * @param assets Amount of ERC-4626 asset supplied.
     * @param shares Shares minted.
     */
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);

    /**
     * @notice Emitted when ERC-4626 shares are redeemed or withdrawn.
     * @param caller Account that initiated the withdrawal.
     * @param receiver Account that received assets.
     * @param owner Account whose shares were burned.
     * @param assets ERC-4626 asset amount paid out.
     * @param shares Shares burned.
     */
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    /**
     * @notice Emitted when an account changes a share allowance.
     * @param owner Share owner.
     * @param spender Approved spender.
     * @param value Approved share amount.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @notice Emitted when deposits and rebalances are paused.
     * @param account Guardian or factory that paused the vault.
     */
    event Paused(address indexed account);

    /**
     * @notice Emitted when deposits and rebalances are resumed.
     * @param account Factory or factory owner that unpaused the vault.
     */
    event Unpaused(address indexed account);

    /**
     * @notice Emitted when shares move between accounts.
     * @param from Sender of shares.
     * @param to Receiver of shares.
     * @param value Share amount moved.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @notice Minimum shares permanently locked on the first deposit.
     */
    uint256 internal constant MIN_LOCK_SHARES = 1_000;
    /**
     * @notice Dead receiver for locked first-deposit shares.
     */
    address internal constant DEAD_SHARES = 0x000000000000000000000000000000000000dEaD;
    /**
     * @notice Q96 fixed-point scale used by Uniswap sqrt prices.
     */
    uint256 internal constant Q96 = 1 << 96;
    /**
     * @notice Probe liquidity scale used to avoid zero-amount floors when sizing first-deposit bands.
     */
    uint256 internal constant LIQUIDITY_PROBE = 1e18;
    /**
     * @notice Tiny liquidity haircut used to leave settlement headroom for Uniswap's rounded-up token deltas.
     */
    uint128 internal constant LIQUIDITY_HEADROOM_DIVISOR = 1e8;
    /**
     * @notice Basis-point denominator.
     */
    uint16 internal constant BPS_DENOMINATOR = 1e4;
    /**
     * @notice Absolute ceiling on the protocol fee: 100 percent of collected trading fees.
     * @dev The business cap is mutable factory state; the vault only enforces the safety bound so a misconfigured
     *      factory can never reach principal. Must equal `VaultM5Module.MAX_PROTOCOL_FEE_BPS`.
     */
    uint256 internal constant MAX_PROTOCOL_FEE_BPS = 1e4;
    /**
     * @notice Token units reserved per band and currency for Uniswap rounding the charge up when adding liquidity.
     * @dev Uniswap rounds each band's required amount up by at most one unit; two leaves a margin. Without this
     *      reserve, a deposit that uses its budget exactly can be charged more than the exact Permit2 allowance.
     */
    uint256 internal constant SETTLEMENT_DUST_PER_BAND = 2;
    /**
     * @dev Transient flag set only while the vault's own PositionManager call runs; gates `onERC721Received`.
     */
    bytes32 private constant _EXPECTING_NFT_SLOT = keccak256("vortexa.vault.expectingPositionNft");

    /**
     * @notice Runtime values carried across one deposit execution.
     * @dev Keeps the measured deposit flow readable and avoids stack pressure.
     */
    struct DepositCache {
        /**
         * @notice Current pool sqrt price.
         */
        uint160 sp;
        /**
         * @notice Current pool tick.
         */
        int24 tick;
        /**
         * @notice Pre-deposit token1-denominated vault value.
         */
        uint256 valueBefore;
        /**
         * @notice Pre-PositionManager currency0 balance.
         */
        uint256 pre0;
        /**
         * @notice Pre-PositionManager currency1 balance.
         */
        uint256 pre1;
        /**
         * @notice First predicted PositionManager token id.
         */
        uint256 nextTokenId;
        /**
         * @notice Currency0 fees that PositionManager credits into the settlement of existing bands.
         */
        uint256 fees0;
        /**
         * @notice Currency1 fees that PositionManager credits into the settlement of existing bands.
         */
        uint256 fees1;
        /**
         * @notice Currency budgets remaining after an optional first-deposit swap.
         */
        uint256 budget0;
        uint256 budget1;
        /**
         * @notice Currency amounts returned to the payer after liquidity settlement.
         */
        uint256 refund0;
        uint256 refund1;
    }

    /**
     * @notice Uniswap V4 PositionManager dependency.
     */
    IPositionManagerLike public immutable positionManager;
    /**
     * @notice Uniswap V4 StateView dependency.
     */
    IStateViewLike public immutable stateView;
    /**
     * @notice Permit2 dependency used by PositionManager settlement.
     */
    IPermit2Like public immutable permit2;
    /**
     * @notice PriceGuard dependency used before any share valuation deposit.
     */
    IPriceGuard public immutable priceGuard;
    /**
     * @notice Factory authorized to initialize clones.
     */
    address public immutable factory;
    /**
     * @notice Uniswap V4 PoolManager allowed to send native ETH to the vault.
     */
    address public immutable poolManager;
    /**
     * @notice Immutable delegatecall target for size-heavy M5 state-changing operations.
     */
    address public immutable m5Module;
    /**
     * @notice Immutable swap executor used by M6 rebalances.
     */
    address public immutable swapExecutor;
    /**
     * @notice Immutable delegatecall target for M6 rebalance logic.
     */
    address public immutable m6Module;
    /**
     * @dev Implementation address used to reject direct initialization while allowing EIP-1167 clones.
     */
    address private immutable _implementation;

    /**
     * @notice ERC-20 share name.
     */
    string public name;
    /**
     * @notice ERC-20 share symbol.
     */
    string public symbol;
    /**
     * @notice ERC-20 share decimals.
     */
    uint8 public constant decimals = 18;
    /**
     * @notice Total ERC-20 share supply.
     */
    uint256 public totalSupply;
    /**
     * @notice Last rebalance timestamp reserved for later milestones.
     */
    uint64 public lastRebalance;
    /**
     * @notice Whether deposits and rebalances are paused.
     */
    bool public paused;
    /**
     * @notice Set by a lock-on-fill (`FILLED`) rebalance: the vault then holds idle tokens, refuses every deposit and
     *         never rebalances again; withdrawals stay open.
     */
    // Written only by the M6 rebalance module through delegatecall, which Slither cannot follow.
    // slither-disable-next-line uninitialized-state
    bool public filled;
    /**
     * @dev Clone initialization flag.
     */
    bool private _initialized;
    /**
     * @dev Immutable vault configuration written once in `initialize`.
     */
    VaultConfig private _cfg;
    /**
     * @dev Cached pool id for `_cfg.poolKey`.
     */
    bytes32 private _poolId;
    /**
     * @dev Strategy gate used by M4 deposits.
     */
    IStrategy private _strategy;
    /**
     * @dev Active bands owned by this vault.
     */
    Band[] private _bands;
    /**
     * @notice Share balances.
     */
    mapping(address account => uint256 balance) public balanceOf;
    /**
     * @notice Share allowances.
     */
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    /**
     * @notice Deploys the vault implementation with immutable dependencies.
     * @dev Every nonzero dependency is shared by clones. The reserved swap executor slot preserves constructor
     *      compatibility for later swap execution milestones without adding M6 behavior in M5.
     * @param positionManager_ Uniswap V4 PositionManager.
     * @param stateView_ Uniswap V4 StateView.
     * @param permit2_ Permit2 allowance contract.
     * @param priceGuard_ PriceGuard oracle guard.
     * @param shapes_ ShapeLibrary band generator.
     * @param swapExecutor_ M6 swap executor, or zero for legacy M0-M5-only test deployments.
     * @param factory_ Authorized clone factory.
     * @param poolManager_ Uniswap V4 PoolManager.
     */
    constructor(
        IPositionManagerLike positionManager_,
        IStateViewLike stateView_,
        IPermit2Like permit2_,
        IPriceGuard priceGuard_,
        IShapeLibrary shapes_,
        address swapExecutor_,
        address factory_,
        address poolManager_
    ) {
        if (
            address(positionManager_) == address(0) || address(stateView_) == address(0)
                || address(permit2_) == address(0) || address(priceGuard_) == address(0)
                || address(shapes_) == address(0) || factory_ == address(0) || poolManager_ == address(0)
        ) revert ZeroAddress();
        positionManager = positionManager_;
        stateView = stateView_;
        permit2 = permit2_;
        priceGuard = priceGuard_;
        factory = factory_;
        poolManager = poolManager_;
        swapExecutor = swapExecutor_;
        m5Module = address(new VaultM5Module());
        if (swapExecutor_ != address(0)) {
            // The implementation is still under construction and cannot be reentered externally.
            // aderyn-fp-next-line(reentrancy-state-change)
            m6Module = ISwapExecutor(swapExecutor_).vaultModule();
            if (m6Module.code.length == 0) revert ZeroAddress();
        } else {
            m6Module = address(0);
        }
        _implementation = address(this);
    }

    /**
     * @inheritdoc IVault
     */
    function initialize(string calldata name_, string calldata symbol_, address strategy_, VaultConfig calldata config_)
        external
        nonReentrant
    {
        if (address(this) == _implementation) revert ImplementationLocked();
        if (msg.sender != factory) revert NotAuthorized();
        if (_initialized) revert AlreadyInitialized();
        if (strategy_ == address(0)) revert ZeroAddress();
        if (Currency.unwrap(config_.poolKey.currency1) == address(0)) {
            revert ZeroAddress();
        }
        if (config_.poolKey.hooks != address(0)) revert NotAuthorized();

        _initialized = true;
        name = name_;
        symbol = symbol_;
        _strategy = IStrategy(strategy_);
        _cfg = config_;
        _poolId = config_.poolKey.toId();
        // The call is validation-by-revert; no return payload is required.
        // aderyn-fp-next-line(unchecked-return)
        _delegateM5(abi.encodeCall(VaultM5Module.validateStrategy, ()));

        _approvePermit2Max(config_.poolKey.currency0);
        _approvePermit2Max(config_.poolKey.currency1);
        emit VaultInitialized(strategy_, _poolId);
    }

    /**
     * @notice Returns the ERC-4626 underlying asset.
     * @dev The accounting asset is always pool `currency1`, which must be an ERC-20.
     * @return assetToken ERC-20 asset address.
     */
    function asset() external view returns (address) {
        return Currency.unwrap(_cfg.poolKey.currency1);
    }

    /**
     * @notice Returns the initialized vault configuration.
     * @dev Exposes the immutable clone-local config for tests, front ends, and later milestones.
     * @return vaultConfig Vault configuration.
     */
    function config() external view returns (VaultConfig memory vaultConfig) {
        return _cfg;
    }

    /**
     * @notice Returns the strategy fixed when this vault was initialized.
     * @dev M9 uses this identity to reject unsupported or registry-replaced strategies safely.
     * @return vaultStrategy Immutable clone-local strategy contract.
     */
    function strategy() external view returns (IStrategy vaultStrategy) {
        return _strategy;
    }

    /**
     * @notice Returns all active bands.
     * @dev The returned array is copied from storage; band count is capped at five.
     * @return activeBands Active vault bands.
     */
    function bands() external view returns (Band[] memory activeBands) {
        return _bands;
    }

    /**
     * @notice Returns total vault assets denominated in token1 units.
     * @dev Includes active liquidity, pending fees net of the protocol fee (what holders keep once they are
     *      collected), idle token0 valued at current spot, and idle token1.
     * @return assets Total token1-denominated asset value.
     */
    function totalAssets() public view returns (uint256 assets) {
        (uint160 sp,,,) = stateView.getSlot0(_poolId);
        (uint256 amount0, uint256 amount1) = _totalAmounts(sp, 0);
        assets = _value(amount0, amount1, sp);
    }

    /**
     * @notice Converts ERC-4626 asset units to shares.
     * @dev Rounds down as required by ERC-4626.
     * @param assets Asset amount in token1 units.
     * @return shares Share amount.
     */
    function convertToShares(uint256 assets) public view returns (uint256 shares) {
        uint256 supply = totalSupply;
        if (supply == 0) {
            return assets > MIN_LOCK_SHARES ? assets - MIN_LOCK_SHARES : 0;
        }
        uint256 total = totalAssets();
        shares = total == 0 ? 0 : Math.mulDiv(assets, supply, total);
    }

    /**
     * @notice Converts shares to ERC-4626 asset units.
     * @dev Rounds down as required by ERC-4626.
     * @param shares Share amount.
     * @return assets Asset amount in token1 units.
     */
    function convertToAssets(uint256 shares) public view returns (uint256 assets) {
        uint256 supply = totalSupply;
        if (supply == 0) return shares;
        assets = Math.mulDiv(shares, totalAssets(), supply);
    }

    /**
     * @notice Previews shares minted by depositing assets.
     * @dev Rounds down and ignores transaction-time slippage, matching ERC-4626 preview semantics.
     * @param assets Asset amount in token1 units.
     * @return shares Share amount.
     */
    function previewDeposit(uint256 assets) external view returns (uint256 shares) {
        return convertToShares(assets);
    }

    /**
     * @notice Previews assets needed to mint shares.
     * @dev Rounds up so callers provide enough assets.
     * @param shares Share amount requested.
     * @return assets Asset amount in token1 units.
     */
    function previewMint(uint256 shares) public view returns (uint256 assets) {
        uint256 supply = totalSupply;
        if (supply == 0) return shares + MIN_LOCK_SHARES;
        assets = _mulDivUp(shares, totalAssets(), supply);
    }

    /**
     * @notice Previews shares burned to withdraw assets.
     * @dev Rounds up so enough shares are burned.
     * @param assets Asset amount in token1 units.
     * @return shares Share amount.
     */
    function previewWithdraw(uint256 assets) public view returns (uint256 shares) {
        uint256 supply = totalSupply;
        uint256 total = totalAssets();
        shares = total == 0 ? 0 : _mulDivUp(assets, supply, total);
    }

    /**
     * @notice Previews assets returned by redeeming shares.
     * @dev Rounds down as required by ERC-4626.
     * @param shares Share amount.
     * @return assets Asset amount in token1 units.
     */
    function previewRedeem(uint256 shares) external view returns (uint256 assets) {
        return convertToAssets(shares);
    }

    /**
     * @notice Returns maximum assets currently acceptable from a receiver.
     * @dev Zero while deposits are paused, the price is untrusted, the strategy refuses deposits or accepts token0
     *      only, or the cap is reached; unbounded when there is no cap. Never reverts.
     * @param receiver Prospective share receiver.
     * @return assets Maximum token1 assets.
     */
    function maxDeposit(address receiver) public view returns (uint256 assets) {
        if (receiver == address(0) || paused || filled || !_assetDepositsOpen()) {
            return 0;
        }
        uint256 cap = _cfg.depositCap;
        if (cap == 0) return type(uint256).max;
        uint256 current = totalAssets();
        assets = current >= cap ? 0 : cap - current;
    }

    /**
     * @notice Returns maximum shares currently mintable for a receiver.
     * @dev Derived from `maxDeposit`; unbounded when deposits are uncapped. Never reverts.
     * @param receiver Prospective share receiver.
     * @return shares Maximum share amount.
     */
    function maxMint(address receiver) public view returns (uint256 shares) {
        uint256 assets = maxDeposit(receiver);
        if (assets == type(uint256).max) return type(uint256).max;
        shares = convertToShares(assets);
    }

    /**
     * @notice Returns maximum idle ERC-4626 assets withdrawable by an owner.
     * @dev M4 does not implement M5 liquidity removal, so this is bounded to idle token1 liquidity. Single-asset
     *      exits value shares at the pool price, so they are offered only while PriceGuard trusts that price
     *      (zero otherwise). The oracle-free pro-rata exit of the guide belongs to M5.
     * @param owner Share owner.
     * @return assets Maximum withdrawable token1 assets.
     */
    function maxWithdraw(address owner) public view returns (uint256 assets) {
        if (!_priceTrustedView()) return 0;
        uint256 ownerAssets = convertToAssets(balanceOf[owner]);
        uint256 liquid = _assetBalance();
        assets = ownerAssets < liquid ? ownerAssets : liquid;
    }

    /**
     * @notice Returns maximum shares redeemable by an owner under current idle liquidity.
     * @dev M4 does not implement M5 liquidity removal, so this is bounded by `maxWithdraw` (zero while the price is
     *      untrusted).
     * @param owner Share owner.
     * @return shares Maximum redeemable shares.
     */
    function maxRedeem(address owner) public view returns (uint256 shares) {
        uint256 withdrawable = maxWithdraw(owner);
        uint256 liquidShares = previewWithdraw(withdrawable);
        uint256 ownerShares = balanceOf[owner];
        shares = ownerShares < liquidShares ? ownerShares : liquidShares;
    }

    /**
     * @notice Deposits ERC-4626 asset tokens and mints shares.
     * @dev Takes exactly `assets` of token1 and holds it as idle balance; idle token1 is valued one to one, so the
     *      shares minted equal `previewDeposit(assets)` in the same transaction. Deploying idle funds into the bands is
     *      a later compounding step. Native ETH is never accepted here.
     * @param assets Token1 asset amount.
     * @param receiver Share receiver.
     * @return shares Shares minted.
     */
    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        if (assets > maxDeposit(receiver)) revert ExceedsMax();
        shares = _depositAsset(assets, receiver);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @notice Deposits enough ERC-4626 assets to mint a requested share amount.
     * @dev Takes `previewMint(shares)` of token1 (rounded up) and holds it as idle balance.
     * @param shares Requested shares.
     * @param receiver Share receiver.
     * @return assets Token1 assets supplied.
     */
    function mint(uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        if (shares > maxMint(receiver)) revert ExceedsMax();
        assets = previewMint(shares);
        uint256 minted = _depositAsset(assets, receiver);
        if (minted < shares) revert SlippageExceeded();
        emit Deposit(msg.sender, receiver, assets, minted);
    }

    /**
     * @notice Withdraws idle ERC-4626 assets by burning shares.
     * @dev Pays from idle token1 only (full LP unwinding is `withdrawPair`); bounded by `maxWithdraw`. Reverts with
     *      `PriceUntrusted` while PriceGuard does not trust the pool price, because the payout is priced from it.
     * @param assets Token1 assets requested.
     * @param receiver Asset receiver.
     * @param owner Share owner.
     * @return shares Shares burned.
     */
    function withdraw(uint256 assets, address receiver, address owner) external nonReentrant returns (uint256 shares) {
        if (receiver == address(0)) revert ZeroAddress();
        _requireTrustedPrice();
        if (assets > maxWithdraw(owner)) revert ExceedsMax();
        shares = previewWithdraw(assets);
        _exitAsset(assets, shares, receiver, owner);
    }

    /**
     * @notice Redeems shares for idle ERC-4626 assets.
     * @dev Pays from idle token1 only (full LP unwinding is `withdrawPair`); bounded by `maxRedeem`. Reverts with
     *      `PriceUntrusted` while PriceGuard does not trust the pool price, because the payout is priced from it.
     * @param shares Shares to redeem.
     * @param receiver Asset receiver.
     * @param owner Share owner.
     * @return assets Token1 assets paid.
     */
    function redeem(uint256 shares, address receiver, address owner) external nonReentrant returns (uint256 assets) {
        if (receiver == address(0)) revert ZeroAddress();
        _requireTrustedPrice();
        if (shares > maxRedeem(owner)) revert ExceedsMax();
        assets = convertToAssets(shares);
        _exitAsset(assets, shares, receiver, owner);
    }

    /**
     * @notice Shared tail of the ERC-4626 exits: spend allowance, burn, pay token1, emit `Withdraw`.
     * @dev Callers have already checked the receiver, the price trust and the `max*` bound.
     * @param assets Token1 paid out.
     * @param shares Shares burned.
     * @param receiver Asset receiver.
     * @param owner Share owner.
     */
    function _exitAsset(uint256 assets, uint256 shares, address receiver, address owner) private {
        _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        _cfg.poolKey.currency1.transfer(receiver, assets); // aderyn-fp(unsafe-erc20-operation)
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /**
     * @notice Approves a spender to use shares.
     * @dev Standard ERC-20 approval with no allowance side effects.
     * @param spender Share spender.
     * @param value Share allowance.
     * @return ok True on success.
     */
    function approve(address spender, uint256 value) external returns (bool ok) {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        ok = true;
    }

    /**
     * @notice Transfers shares to another account.
     * @dev Reverts on zero receiver to avoid burning shares accidentally.
     * @param to Share receiver.
     * @param value Share amount.
     * @return ok True on success.
     */
    function transfer(address to, uint256 value) external returns (bool ok) {
        _transfer(msg.sender, to, value);
        ok = true;
    }

    /**
     * @notice Transfers shares using an allowance.
     * @dev Infinite allowances are not decreased.
     * @param from Share owner.
     * @param to Share receiver.
     * @param value Share amount.
     * @return ok True on success.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool ok) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        ok = true;
    }

    /**
     * @inheritdoc IVault
     */
    function depositPair(uint256 amount0, uint256 amount1, uint256 minShares, address receiver)
        external
        payable
        nonReentrant
        returns (uint256 shares, uint256 used0, uint256 used1)
    {
        return _depositPair(amount0, amount1, minShares, receiver, msg.sender, msg.value);
    }

    /**
     * @inheritdoc IVault
     */
    function withdrawPair(uint256, uint256, uint256, address)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        return _delegateM5Pair(msg.data);
    }

    /**
     * @inheritdoc IVault
     */
    function collectFees() external nonReentrant returns (uint256 fee0, uint256 fee1) {
        return _delegateM5Pair(msg.data);
    }

    /**
     * @inheritdoc IVault
     */
    function compound() external nonReentrant returns (uint256 used0, uint256 used1) {
        return _delegateM5Pair(msg.data);
    }

    /**
     * @inheritdoc IVault
     */
    function rebalance(RebalanceParams calldata) external nonReentrant {
        address module = m6Module;
        if (module == address(0)) revert ZeroAddress();
        // forge-policy: allow-controlled-delegatecall - module is read once from the immutable swap executor.
        // Not `memory-safe`: the calldata is copied over memory from offset zero; nothing reads memory afterwards.
        assembly {
            calldatacopy(0, 0, calldatasize())
            // forge-policy: allow-controlled-delegatecall - immutable constructor-selected module.
            let ok := delegatecall(gas(), module, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) {
                revert(0, returndatasize())
            }
        }
    }

    /**
     * @inheritdoc IVault
     * @dev Evaluated by the M5 module through `staticcall`; the module reads this vault back through its public
     *      views, so only the vault address and the strategy are encoded here.
     */
    function checkRebalance() external view returns (bool needed, bytes32 reason) {
        (bool ok, bytes memory ret) =
            m5Module.staticcall(abi.encodeWithSelector(VaultM5Module.checkRebalance.selector, this, _strategy));
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        (needed, reason) = abi.decode(ret, (bool, bytes32));
    }

    /**
     * @notice Handles safe ERC-721 receives from the trusted PositionManager.
     * @dev Accepts a position NFT only from the PositionManager and only while the vault's own `modifyLiquidities`
     *      call is running (guide 12.4); anything else reverts with `UnexpectedNft`. Accounting never reads NFT
     *      balances, so this is defence in depth against stray or griefing transfers.
     * @return selector The ERC-721 receiver selector.
     */
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(positionManager) || !_EXPECTING_NFT_SLOT.asBoolean().tload()) {
            revert UnexpectedNft();
        }
        return 0x150b7a02;
    }

    /**
     * @notice Pauses deposits (and, in later milestones, rebalances).
     * @dev Callable by the factory or the factory's guardian. Withdrawals are never paused.
     */
    function pause() external nonReentrant {
        paused = true;
        if (msg.sender != factory && msg.sender != IVaultFactory(factory).guardian()) revert NotAuthorized();
        emit Paused(msg.sender);
    }

    /**
     * @notice Resumes deposits.
     * @dev Callable by the factory or the factory's owner (the timelock); the guardian cannot unpause.
     */
    function unpause() external nonReentrant {
        paused = false;
        if (msg.sender != factory && msg.sender != IVaultFactory(factory).owner()) revert NotAuthorized();
        emit Unpaused(msg.sender);
    }

    /**
     * @notice Accepts native ETH from approved Uniswap dependencies only.
     * @dev Prevents accidental donations from inflating idle native accounting.
     */
    receive() external payable {
        if (msg.sender != address(positionManager) && msg.sender != poolManager && msg.sender != swapExecutor) {
            revert InvalidEthSender();
        }
    }

    /**
     * @notice Executes the guide's measured pair-deposit flow.
     * @dev Pulls funds, encodes PositionManager actions, measures actual use, mints conservative shares and refunds.
     *      The depositor's cost per currency is `pre + creditedFees - post`: adding liquidity to an existing band
     *      also credits that band's accrued fees into the same settlement, and those fees belong to the existing
     *      holders (they were already part of `valueBefore`), so they must not reduce what the depositor is charged.
     *      The protocol cut of those credited fees is then paid through the M5 module, as on every other path that
     *      collects fees; `valueBefore` already excluded it.
     * @param amount0 Maximum currency0 amount.
     * @param amount1 Maximum currency1 amount.
     * @param minShares Minimum accepted shares.
     * @param receiver Share receiver.
     * @param payer Account that supplies ERC-20 funds.
     * @param nativeValue Native ETH sent with the call.
     * @return shares Shares minted.
     * @return used0 Currency0 actually deployed.
     * @return used1 Currency1 actually deployed.
     */
    // Every entry point is nonReentrant; the calls go to the immutable M5 module and PositionManager, and band
    // storage written after them is the documented read-only window (docs/known-issues.md, M4).
    // Slither cannot propagate the external nonReentrant guard through this internal function or the immutable
    // delegate module. Any callback into a Vault entry point is rejected before these cached balances are reused.
    // slither-disable-next-line reentrancy-eth,reentrancy-balance
    function _depositPair(
        uint256 amount0,
        uint256 amount1,
        uint256 minShares,
        address receiver,
        address payer,
        uint256 nativeValue
    ) private returns (uint256 shares, uint256 used0, uint256 used1) {
        _preDepositChecks(amount0, amount1, receiver, nativeValue);
        DepositCache memory cache = _depositCacheBeforeFunds(nativeValue);
        _pullExact(_cfg.poolKey.currency0, payer, amount0, nativeValue);
        _pullExact(_cfg.poolKey.currency1, payer, amount1, 0);
        _requirePriceUnchanged(cache.sp);

        Band[] memory target;
        uint128[] memory addLiq;
        (target, addLiq, cache.budget0, cache.budget1) = _plan(cache.sp, cache.tick, amount0, amount1);
        cache.pre0 = _balance(_cfg.poolKey.currency0);
        cache.pre1 = _balance(_cfg.poolKey.currency1);
        cache.nextTokenId = _bands.length == 0 ? positionManager.nextTokenId() : 0;
        (cache.fees0, cache.fees1) = _creditedFees();

        _callPositionManager(target, addLiq, cache.budget0, cache.budget1);

        used0 = _used(cache.pre0, cache.fees0, _balance(_cfg.poolKey.currency0), cache.budget0);
        used1 = _used(cache.pre1, cache.fees1, _balance(_cfg.poolKey.currency1), cache.budget1);
        if (_bands.length == 0) {
            _storeMintedBands(target, addLiq, cache.nextTokenId);
        } else {
            _increaseStoredLiquidity(addLiq);
        }
        // This call is made for its checked transfer effects; the returned fee tuple is not needed here.
        // aderyn-fp-next-line(unchecked-return)
        _delegateM5Pair(abi.encodeWithSelector(VaultM5Module.payDepositProtocolFee.selector, cache.fees0, cache.fees1));

        cache.refund0 = cache.budget0 - used0;
        cache.refund1 = cache.budget1 - used1;
        used0 = amount0 > cache.refund0 ? amount0 - cache.refund0 : 0;
        used1 = amount1 > cache.refund1 ? amount1 - cache.refund1 : 0;
        uint256 refundValue = _value(cache.refund0, cache.refund1, cache.sp);
        uint256 valueUsed = _value(amount0, amount1, cache.sp);
        valueUsed = valueUsed > refundValue ? valueUsed - refundValue : 0;
        // Credit only what the deposit really added, valued exactly as `valueBefore` was (same price, net fees).
        // A first-band deposit may swap part of the depositor's tokens; the swap's fee, price impact and slippage
        // must stay with the depositor, never with existing holders.
        (uint256 after0, uint256 after1) = _totalAmounts(cache.sp, 0);
        uint256 added = _value(after0 - cache.refund0, after1 - cache.refund1, cache.sp);
        added = added > cache.valueBefore ? added - cache.valueBefore : 0;
        if (added < valueUsed) valueUsed = added;
        if (valueUsed == 0) revert ZeroValue();
        shares = _sharesFor(valueUsed, cache.valueBefore);
        if (shares < minShares) revert SlippageExceeded();
        _enforceCap(cache.valueBefore + valueUsed);
        _mint(receiver, shares);
        _refund(payer, cache.refund0, cache.refund1);
        emit PairDeposited(payer, receiver, used0, used1, shares);
    }

    /**
     * @notice Grants allowances, calls PositionManager, and revokes allowances.
     * @dev Kept as one helper so the exact-allowance lifecycle is hard to bypass.
     * @param target Target bands.
     * @param addLiq Liquidity delta per band.
     * @param amount0 Maximum currency0 input.
     * @param amount1 Maximum currency1 input.
     */
    function _callPositionManager(Band[] memory target, uint128[] memory addLiq, uint256 amount0, uint256 amount1)
        private
    {
        _approvePosm(amount0, amount1);
        bytes memory data = _encodeAdd(target, addLiq, amount0, amount1);
        _EXPECTING_NFT_SLOT.asBoolean().tstore(true);
        positionManager.modifyLiquidities{value: _nativeIn(amount0)}(data, block.timestamp);
        _EXPECTING_NFT_SLOT.asBoolean().tstore(false);
        _revokePosm(amount0, amount1);
    }

    /**
     * @notice Builds the pre-fund deposit cache.
     * @dev Reads price, asks strategy, and values the vault before pulling user funds.
     * @param nativeValue Incoming native ETH to exclude from idle accounting.
     * @return cache Pre-fund deposit cache.
     */
    function _depositCacheBeforeFunds(uint256 nativeValue) private view returns (DepositCache memory cache) {
        (cache.sp, cache.tick,,) = stateView.getSlot0(_poolId);
        if (!_strategy.canDeposit(_cfg, cache.tick, _bands)) {
            revert DepositNotAllowed();
        }
        (uint256 before0, uint256 before1) = _totalAmounts(cache.sp, nativeValue);
        cache.valueBefore = _value(before0, before1, cache.sp);
    }

    /**
     * @notice Runs checks that do not require moving user funds.
     * @dev Includes pause, receiver, oracle trust, mode, and native-value validation.
     * @param amount0 Currency0 amount.
     * @param amount1 Currency1 amount.
     * @param receiver Share receiver.
     * @param nativeValue Native ETH supplied.
     */
    function _preDepositChecks(uint256 amount0, uint256 amount1, address receiver, uint256 nativeValue) private view {
        if (paused) revert IsPaused();
        if (filled) revert DepositNotAllowed();
        if (receiver == address(0)) revert ZeroAddress();
        _requireTrustedPrice();
        _checkDepositMode(_strategy.depositMode(_cfg), amount0, amount1);
        bool native0 = _cfg.poolKey.currency0.isNative();
        if ((native0 && nativeValue != amount0) || (!native0 && nativeValue != 0)) revert InvalidNativeValue();
    }

    /**
     * @notice Validates supplied amounts against a strategy deposit mode.
     * @dev Keeps ERC-4626 token1-only deposits compatible with one-sided strategies. An empty deposit is refused in
     *      every mode, so a one-sided vault reports the same error as a two-sided one.
     * @param mode Strategy-reported deposit mode.
     * @param amount0 Currency0 amount.
     * @param amount1 Currency1 amount.
     */
    function _checkDepositMode(DepositMode mode, uint256 amount0, uint256 amount1) private pure {
        if (
            (amount0 == 0 && amount1 == 0) || (mode == DepositMode.Token0Only && amount1 != 0)
                || (mode == DepositMode.Token1Only && amount0 != 0)
        ) revert InvalidDepositMode();
    }

    /**
     * @notice Pulls an exact ERC-20 amount or validates native ETH already received.
     * @dev ERC-20 balance deltas reject fee-on-transfer and rebasing behavior at the trust boundary.
     * @param currency Currency being supplied.
     * @param payer Account supplying ERC-20 funds.
     * @param amount Requested amount.
     * @param nativeValue Native ETH associated with this currency.
     */
    function _pullExact(Currency currency, address payer, uint256 amount, uint256 nativeValue) private {
        if (amount == 0) return;
        if (currency.isNative()) {
            if (nativeValue != amount) revert InvalidNativeValue();
            return;
        }
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(payer, address(this), amount);
        if (token.balanceOf(address(this)) - beforeBalance != amount) {
            revert TokenTransferShortfall();
        }
    }

    /**
     * @notice Builds target bands and liquidity additions.
     * @dev The first deposit uses the strategy plan (`VaultM5Module.depositPlan`); later deposits increase the
     *      existing bands proportionally (`VaultM5Module.depositLiquidity`).
     * @param sp Current pool sqrt price.
     * @param tick Current pool tick.
     * @param amount0 Available currency0 amount.
     * @param amount1 Available currency1 amount.
     * @return target Target bands.
     * @return addLiq Liquidity delta per band.
     * @return budget0 Currency0 available after an optional first-deposit swap.
     * @return budget1 Currency1 available after an optional first-deposit swap.
     */
    function _plan(uint160 sp, int24 tick, uint256 amount0, uint256 amount1)
        private
        returns (Band[] memory target, uint128[] memory addLiq, uint256 budget0, uint256 budget1)
    {
        budget0 = amount0;
        budget1 = amount1;
        if (_bands.length == 0) {
            uint16[] memory weights;
            (target, weights, budget0, budget1) = _delegateDepositPlan(sp, tick, amount0, amount1);
            (sp,,,) = stateView.getSlot0(_poolId);
            addLiq = _liquidityForNewBands(sp, target, weights, budget0, budget1);
        } else {
            target = _bands;
            // Later deposits share the module's existing-band sizing with `compound` (one implementation).
            addLiq = abi.decode(
                _delegateM5(abi.encodeCall(VaultM5Module.depositLiquidity, (sp, amount0, amount1))), (uint128[])
            );
        }
    }

    /**
     * @notice Computes first-deposit liquidity from weighted bands.
     * @dev Finds the largest common scalar supported by supplied amounts, then computes per-band liquidity.
     * @param sp Current pool sqrt price.
     * @param target Candidate bands.
     * @param weights Relative liquidity weights in basis points.
     * @param amount0 Available currency0 amount.
     * @param amount1 Available currency1 amount.
     * @return addLiq Liquidity delta per band.
     */
    function _liquidityForNewBands(
        uint160 sp,
        Band[] memory target,
        uint16[] memory weights,
        uint256 amount0,
        uint256 amount1
    ) private pure returns (uint128[] memory addLiq) {
        uint256 unit0;
        uint256 unit1;
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 i = 0; i < target.length;) {
            (uint256 a0, uint256 a1) = LiquidityMath.amountsForLiquidity(
                sp,
                SqrtPriceMath.getSqrtPriceAtTick(target[i].tickLower),
                SqrtPriceMath.getSqrtPriceAtTick(target[i].tickUpper),
                _toUint128(uint256(weights[i]) * LIQUIDITY_PROBE)
            );
            unit0 += a0;
            unit1 += a1;
            unchecked {
                /// UnaryOperatorMutation(`++` |==> `~`) of: `++i;`
                ~i;
            }
        }
        uint256 scale = _scale(unit0, unit1, amount0, amount1, target.length);

        addLiq = new uint128[](target.length);
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 i = 0; i < target.length;) {
            addLiq[i] = _withSettlementHeadroom(_toUint128(uint256(weights[i]) * scale));
            if (addLiq[i] == 0) revert ZeroLiquidity();
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Leaves a tiny amount of unused liquidity capacity for rounded-up PositionManager settlement deltas.
     * @dev Returns zero when the planned liquidity is too small to leave any meaningful settlement headroom.
     * @param liquidity Planned liquidity before headroom.
     * @return adjusted Planned liquidity after headroom.
     */
    function _withSettlementHeadroom(uint128 liquidity) private pure returns (uint128 adjusted) {
        uint128 headroom = liquidity / LIQUIDITY_HEADROOM_DIVISOR;
        if (headroom == 0) headroom = 1;
        adjusted = liquidity > headroom ? liquidity - headroom : 0;
    }

    /**
     * @notice Encodes the PositionManager action batch for minting or increasing liquidity.
     * @dev Uses only non-deprecated explicit-liquidity actions, closes each currency (pay a debt or take a fee
     *      credit) and appends a native sweep when ETH was forwarded.
     * @param target Target bands.
     * @param addLiq Liquidity delta per band.
     * @param max0 Maximum currency0 input.
     * @param max1 Maximum currency1 input.
     * @return data Encoded `(actions, params)` accepted by PositionManager.
     */
    function _encodeAdd(Band[] memory target, uint128[] memory addLiq, uint256 max0, uint256 max1)
        private
        view
        returns (bytes memory data)
    {
        bool first = _bands.length == 0;
        bool native = _cfg.poolKey.currency0.isNative() && max0 > 0;
        bytes memory actions;
        bytes[] memory params = new bytes[](target.length + 2 + (native ? 1 : 0));
        for (uint256 i = 0; i < target.length;) {
            actions = abi.encodePacked(actions, first ? PosmActions.MINT_POSITION : PosmActions.INCREASE_LIQUIDITY);
            params[i] = first
                ? abi.encode(
                    _cfg.poolKey,
                    target[i].tickLower,
                    target[i].tickUpper,
                    uint256(addLiq[i]),
                    _toUint128(max0),
                    _toUint128(max1),
                    address(this),
                    bytes("")
                )
                : abi.encode(target[i].tokenId, uint256(addLiq[i]), _toUint128(max0), _toUint128(max1), bytes(""));
            unchecked {
                ++i;
            }
        }
        // CLOSE_CURRENCY settles a debt or takes a credit, whichever the delta is. SETTLE_PAIR would revert with
        // DeltaNotNegative whenever the fees credited by INCREASE_LIQUIDITY exceed what the deposit owes.
        actions = abi.encodePacked(actions, PosmActions.CLOSE_CURRENCY, PosmActions.CLOSE_CURRENCY);
        params[target.length] = abi.encode(_cfg.poolKey.currency0);
        params[target.length + 1] = abi.encode(_cfg.poolKey.currency1);
        if (native) {
            actions = abi.encodePacked(actions, PosmActions.SWEEP);
            params[target.length + 2] = abi.encode(_cfg.poolKey.currency0, address(this));
        }
        data = abi.encode(actions, params);
    }

    /**
     * @notice Casts a value to uint128 after upstream liquidity planning has bounded it.
     * @dev Kept centralized so the size-critical cast is easy to audit.
     * @param value Value to cast.
     * @return casted Value truncated to uint128.
     */
    function _toUint128(uint256 value) private pure returns (uint128 casted) {
        assembly ("memory-safe") {
            if shr(128, value) {
                revert(0x00, 0x00)
            }
            casted := value
        }
    }

    /**
     * @notice Computes `ceil(x * y / d)` using full-precision multiplication.
     * @dev Adds one when `mulmod` detects a nonzero remainder.
     * @param x Multiplicand.
     * @param y Multiplier.
     * @param d Divisor.
     * @return z Rounded-up quotient.
     */
    function _mulDivUp(uint256 x, uint256 y, uint256 d) private pure returns (uint256 z) {
        z = Math.mulDiv(x, y, d);
        if (mulmod(x, y, d) != 0) ++z;
    }

    /**
     * @notice Approves exact Permit2 allowances for PositionManager settlement.
     * @dev Allowances are granted only for positive ERC-20 sides and are revoked after the call.
     * @param amount0 Currency0 amount.
     * @param amount1 Currency1 amount.
     */
    function _approvePosm(uint256 amount0, uint256 amount1) private {
        _approvePosmCurrency(_cfg.poolKey.currency0, amount0);
        _approvePosmCurrency(_cfg.poolKey.currency1, amount1);
    }

    /**
     * @notice Revokes temporary Permit2 allowances.
     * @dev A failed revoke reverts the whole transaction, preventing standing allowances.
     * @param amount0 Currency0 amount.
     * @param amount1 Currency1 amount.
     */
    function _revokePosm(uint256 amount0, uint256 amount1) private {
        _approvePosmCurrency(_cfg.poolKey.currency0, amount0 == 0 ? 0 : type(uint256).max);
        _approvePosmCurrency(_cfg.poolKey.currency1, amount1 == 0 ? 0 : type(uint256).max);
    }

    /**
     * @notice Sets a Permit2 allowance for one currency.
     * @dev `type(uint256).max` is an internal sentinel used to revoke to zero.
     * @param currency Currency whose token is approved.
     * @param amount Allowance amount or revoke sentinel.
     */
    function _approvePosmCurrency(Currency currency, uint256 amount) private {
        if (currency.isNative()) return;
        uint160 permitAmount;
        if (amount == type(uint256).max) {
            permitAmount = 0;
        } else {
            assembly ("memory-safe") {
                if shr(160, amount) {
                    revert(0x00, 0x00)
                }
            }
            permitAmount = uint160(amount);
        }
        permit2.approve(Currency.unwrap(currency), address(positionManager), permitAmount, uint48(block.timestamp)); // aderyn-fp(unsafe-erc20-operation)
    }

    /**
     * @notice Grants Permit2 unlimited token approval from the clone to Permit2.
     * @dev This is the standard token-to-Permit2 approval; Permit2-to-PositionManager allowances remain exact.
     * @param currency Currency to approve if it is an ERC-20.
     */
    function _approvePermit2Max(Currency currency) private {
        if (!currency.isNative()) {
            IERC20(Currency.unwrap(currency)).forceApprove(address(permit2), type(uint256).max);
        }
    }

    /**
     * @notice Returns native value forwarded to PositionManager.
     * @dev Only native currency0 may carry ETH into `modifyLiquidities`.
     * @param amount0 Currency0 amount.
     * @return value Native value to forward.
     */
    function _nativeIn(uint256 amount0) private view returns (uint256 value) {
        value = _cfg.poolKey.currency0.isNative() ? amount0 : 0;
    }

    /**
     * @notice Stores freshly minted band NFT ids and liquidity.
     * @dev Verifies each predicted PositionManager owner is the vault before state is committed.
     * @param target Bands minted.
     * @param addLiq Liquidity per minted band.
     * @param firstTokenId First predicted PositionManager token id.
     */
    function _storeMintedBands(Band[] memory target, uint128[] memory addLiq, uint256 firstTokenId) private {
        // aderyn-ignore-next-line(costly-loop,require-revert-in-loop)
        for (uint256 i = 0; i < target.length;) {
            uint256 tokenId = firstTokenId + i;
            if (positionManager.ownerOf(tokenId) != address(this)) {
                revert InvalidPositionOwner();
            }
            target[i].tokenId = tokenId;
            target[i].liquidity = addLiq[i];
            _bands.push(target[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Increases stored liquidity for existing bands.
     * @dev PositionManager has already accepted the action batch when this is called.
     * @param addLiq Liquidity deltas.
     */
    function _increaseStoredLiquidity(uint128[] memory addLiq) private {
        uint256 bandCount = _bands.length;
        // aderyn-ignore-next-line(costly-loop)
        for (uint256 i = 0; i < bandCount;) {
            _bands[i].liquidity += addLiq[i];
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Executes a trusted M5 module operation in this vault's storage context.
     * @dev `m5Module` is constructor-created by the implementation and immutable for every clone.
     * @param data Encoded module calldata.
     * @return amount0 First module return word.
     * @return amount1 Second module return word.
     */
    function _delegateM5Pair(bytes memory data) private returns (uint256 amount0, uint256 amount1) {
        bytes memory ret = _delegateM5(data);
        assembly {
            amount0 := mload(add(ret, 0x20))
            amount1 := mload(add(ret, 0x40))
        }
    }

    /**
     * @notice Delegates first-deposit strategy planning and validation to the storage-mirrored module.
     * @dev Bubbles module validation errors and decodes only validated target data.
     * @param sqrtPrice Current pool square-root price.
     * @param tick Current pool tick.
     * @param amount0 Supplied currency0 budget.
     * @param amount1 Supplied currency1 budget.
     * @return target Validated target bands.
     * @return weights Validated relative weights.
     * @return budget0 Currency0 available after the optional swap.
     * @return budget1 Currency1 available after the optional swap.
     */
    function _delegateDepositPlan(uint160 sqrtPrice, int24 tick, uint256 amount0, uint256 amount1)
        private
        returns (Band[] memory target, uint16[] memory weights, uint256 budget0, uint256 budget1)
    {
        bytes memory data = abi.encodeCall(VaultM5Module.depositPlan, (sqrtPrice, tick, amount0, amount1));
        bytes memory ret = _delegateM5(data);
        (target, weights, budget0, budget1) = abi.decode(ret, (Band[], uint16[], uint256, uint256));
    }

    /**
     * @notice Executes one trusted storage-mirrored M5 module operation.
     * @dev Centralizes immutable-target delegation and exact revert-data bubbling.
     * @param data Encoded module call.
     * @return ret Raw module return data.
     */
    function _delegateM5(bytes memory data) private returns (bytes memory ret) {
        bool ok;
        // forge-policy: allow-controlled-delegatecall - target is constructor-created and immutable.
        (ok, ret) = m5Module.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /**
     * @notice Computes shares for a measured deposit value.
     * @dev First deposit locks dead shares; later deposits use floor division against pre-deposit value.
     * @param valueUsed Measured token1-denominated value contributed.
     * @param valueBefore Pre-deposit total value.
     * @return shares Shares minted to receiver.
     */
    function _sharesFor(uint256 valueUsed, uint256 valueBefore) private view returns (uint256 shares) {
        if (totalSupply == 0) {
            if (valueUsed < MIN_LOCK_SHARES * 10) revert FirstDepositTooSmall();
            return valueUsed - MIN_LOCK_SHARES;
        }
        if (valueBefore == 0) revert ZeroValue();
        shares = Math.mulDiv(totalSupply, valueUsed, valueBefore);
    }

    /**
     * @notice Enforces deposit cap in token1 units.
     * @dev A zero cap means uncapped.
     * @param postValue Post-deposit token1-denominated total value.
     */
    function _enforceCap(uint256 postValue) private view {
        uint256 cap = _cfg.depositCap;
        if (cap != 0 && postValue > cap) revert DepositCapExceeded();
    }

    /**
     * @notice Refunds unused deposit amounts to the payer.
     * @dev Receiver zero checks happen before deposit, so native refunds cannot burn funds. The currency1 refund is
     *      sent first so that a native-ETH payer, whose `receive` runs code, only ever observes final vault state.
     * @param payer Refund recipient.
     * @param refund0 Currency0 refund amount.
     * @param refund1 Currency1 refund amount.
     */
    function _refund(address payer, uint256 refund0, uint256 refund1) private {
        _cfg.poolKey.currency1.transfer(payer, refund1); // aderyn-fp(unsafe-erc20-operation)
        _cfg.poolKey.currency0.transfer(payer, refund0); // aderyn-fp(unsafe-erc20-operation)
    }

    /**
     * @notice Single-asset ERC-4626 deposit: token1 held idle, shares priced at the guarded vault value.
     * @dev Checks pause, receiver and oracle trust, values the vault before pulling, pulls exactly `assets` with a
     *      balance-delta check, then mints. Reverts with `ZeroValue` if the deposit would mint nothing.
     * @param assets Token1 amount.
     * @param receiver Share receiver.
     * @return shares Shares minted.
     */
    function _depositAsset(uint256 assets, address receiver) private returns (uint256 shares) {
        if (paused) revert IsPaused();
        if (filled || !_assetDepositsOpen()) revert DepositNotAllowed();
        if (receiver == address(0)) revert ZeroAddress();
        _requireTrustedPrice();
        uint256 valueBefore = totalAssets();
        _pullExact(_cfg.poolKey.currency1, msg.sender, assets, 0);
        shares = _sharesFor(assets, valueBefore);
        if (shares == 0) revert ZeroValue();
        _enforceCap(valueBefore + assets);
        _mint(receiver, shares);
    }

    /**
     * @notice Whether single-asset (token1) deposits are currently possible.
     * @dev Requires a trusted price, a strategy that accepts token1 and currently allows deposits.
     * @return open True when `deposit` and `mint` would not be refused by the oracle or the strategy.
     */
    function _assetDepositsOpen() private view returns (bool open) {
        if (!_priceTrustedView()) return false;
        if (_strategy.depositMode(_cfg) == DepositMode.Token0Only) return false;
        (, int24 tick,,) = stateView.getSlot0(_poolId);
        open = _strategy.canDeposit(_cfg, tick, _bands);
    }

    /**
     * @notice Largest common liquidity scale the budgets allow, after reserving settlement dust.
     * @dev `unit0`/`unit1` are the token amounts of the probe liquidity. Each budget first reserves
     *      `SETTLEMENT_DUST_PER_BAND` units per band for Uniswap's round-up. Reverts with `ZeroLiquidity` when the
     *      budgets cannot fund any liquidity.
     * @param unit0 Currency0 needed by the probe liquidity.
     * @param unit1 Currency1 needed by the probe liquidity.
     * @param amount0 Currency0 budget.
     * @param amount1 Currency1 budget.
     * @param bandCount Number of bands that will be settled.
     * @return scale Liquidity scale relative to the probe, in `LIQUIDITY_PROBE` fixed point.
     */
    function _scale(uint256 unit0, uint256 unit1, uint256 amount0, uint256 amount1, uint256 bandCount)
        private
        pure
        returns (uint256 scale)
    {
        uint256 dust = SETTLEMENT_DUST_PER_BAND * bandCount;
        uint256 budget0 = amount0 > dust ? amount0 - dust : 0;
        uint256 budget1 = amount1 > dust ? amount1 - dust : 0;
        scale = type(uint256).max;
        if (unit0 > 0) scale = Math.mulDiv(budget0, LIQUIDITY_PROBE, unit0);
        if (unit1 > 0) {
            uint256 scale1 = Math.mulDiv(budget1, LIQUIDITY_PROBE, unit1);
            scale = scale1 < scale ? scale1 : scale;
        }
        if (scale == 0 || scale == type(uint256).max) revert ZeroLiquidity();
    }

    /**
     * @notice Fees the PositionManager will credit into this deposit's settlement.
     * @dev Adding liquidity to an existing position collects all of its accrued fees into the same delta. Computed
     *      right before the call, after the token pulls, so nothing can change them in between.
     * @return fees0 Currency0 fees across all bands.
     * @return fees1 Currency1 fees across all bands.
     */
    function _creditedFees() private view returns (uint256 fees0, uint256 fees1) {
        uint256 bandCount = _bands.length;
        for (uint256 i = 0; i < bandCount; ++i) {
            (uint256 f0, uint256 f1) = _pendingFees(_bands[i]);
            fees0 += f0;
            fees1 += f1;
        }
    }

    /**
     * @notice What the deposit actually cost in one currency.
     * @dev `pre + fees - post`, clamped at zero (ETH forced into the PositionManager and swept back can make the
     *      vault end with more than it started; the surplus is a donation, not a negative cost) and capped at the
     *      deposited amount, so the refund can never exceed what the depositor provided.
     * @param pre Vault balance right before the PositionManager call.
     * @param fees Fees credited into the settlement.
     * @param post Vault balance right after the call.
     * @param supplied Amount the depositor supplied.
     * @return used Amount of the depositor's funds consumed.
     */
    function _used(uint256 pre, uint256 fees, uint256 post, uint256 supplied) private pure returns (uint256 used) {
        uint256 available = pre + fees;
        used = available > post ? available - post : 0;
        if (used > supplied) used = supplied;
    }

    /**
     * @notice Reverts if the pool price moved after the deposit snapshot.
     * @dev Between the oracle check and the liquidity addition the only external calls are the token pulls; a
     *      token with transfer hooks could use them to move the price and make the vault add liquidity at a
     *      manipulated price. Any change at all reverts with `PriceMovedDuringDeposit`.
     * @param snapshot Sqrt price read before the pulls.
     */
    function _requirePriceUnchanged(uint160 snapshot) private view {
        (uint160 sp,,,) = stateView.getSlot0(_poolId);
        if (sp != snapshot) revert PriceMovedDuringDeposit();
    }

    /**
     * @notice Reverts unless PriceGuard trusts the pool price now.
     * @dev Used by single-asset ERC-4626 exits, which pay out at a value derived from the pool price.
     */
    function _requireTrustedPrice() private view {
        (bool trusted,) = priceGuard.isPriceTrusted(_cfg.poolKey);
        if (!trusted) revert PriceUntrusted();
    }

    /**
     * @notice Non-reverting trust check for ERC-4626 `max*` views, which must never revert.
     * @dev A revert inside PriceGuard (for example `NoConfig`) is reported as untrusted.
     * @return trusted True when PriceGuard trusts the pool price.
     */
    function _priceTrustedView() private view returns (bool trusted) {
        try priceGuard.isPriceTrusted(_cfg.poolKey) returns (bool ok, uint256) {
            trusted = ok;
        } catch {
            trusted = false;
        }
    }

    /**
     * @notice Computes the vault's raw token amounts: idle, band principal at `sp`, and pending fees net of the
     *         protocol fee.
     * @dev Excludes incoming native `msg.value` from idle currency0 during deposit snapshots. Pending fees are
     *      summed across bands first and the protocol cut is `floor(F * feeBps / 10_000)` on the sum, exactly what
     *      `withdrawPair`, `collectFees`, `compound` and deposits charge when the fees are collected.
     * @param sp Current pool sqrt price.
     * @param excludeNativeValue Native amount to subtract from idle currency0.
     * @return amount0 Total currency0 amount.
     * @return amount1 Total currency1 amount.
     */
    function _totalAmounts(uint160 sp, uint256 excludeNativeValue)
        private
        view
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = _balance(_cfg.poolKey.currency0);
        if (_cfg.poolKey.currency0.isNative()) amount0 -= excludeNativeValue;
        amount1 = _balance(_cfg.poolKey.currency1);
        uint256 bandCount = _bands.length;
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 i = 0; i < bandCount;) {
            (uint256 b0, uint256 b1) = LiquidityMath.amountsForLiquidity(
                sp,
                SqrtPriceMath.getSqrtPriceAtTick(_bands[i].tickLower),
                SqrtPriceMath.getSqrtPriceAtTick(_bands[i].tickUpper),
                _bands[i].liquidity
            );
            amount0 += b0;
            amount1 += b1;
            unchecked {
                ++i;
            }
        }
        (uint256 fees0, uint256 fees1) = _creditedFees();
        if (fees0 != 0 || fees1 != 0) {
            uint256 feeBps = _protocolFeeBps();
            amount0 += fees0 - Math.mulDiv(fees0, feeBps, BPS_DENOMINATOR);
            amount1 += fees1 - Math.mulDiv(fees1, feeBps, BPS_DENOMINATOR);
        }
    }

    /**
     * @notice The protocol fee the vault charges on collected trading fees, clamped to `MAX_PROTOCOL_FEE_BPS`.
     * @dev Never reverts (a reverting factory or malformed return reads as zero) and applies the same rule as the
     *      M5 module, so the value reported for pending fees is exactly what holders keep once they are collected.
     *      A raw `staticcall` keeps this within the EIP-170 size budget.
     * @return feeBps Effective protocol fee in basis points.
     */
    function _protocolFeeBps() private view returns (uint256 feeBps) {
        address target = factory;
        bytes4 selector = IVaultFactory.protocolFeeBps.selector;
        assembly ("memory-safe") {
            mstore(0x00, selector)
            let ok := staticcall(gas(), target, 0x00, 0x04, 0x00, 0x20)
            if and(ok, gt(returndatasize(), 0x1f)) {
                feeBps := mload(0x00)
            }
        }
        if (feeBps > MAX_PROTOCOL_FEE_BPS) feeBps = MAX_PROTOCOL_FEE_BPS;
    }

    /**
     * @notice Computes pending fees for a band from StateView fee-growth snapshots.
     * @dev Uses wrapping subtraction, matching Uniswap fee-growth counter semantics.
     * @param band Active band.
     * @return fee0 Pending currency0 fees.
     * @return fee1 Pending currency1 fees.
     */
    function _pendingFees(Band storage band) private view returns (uint256 fee0, uint256 fee1) {
        (uint128 liquidity, uint256 last0, uint256 last1) = stateView.getPositionInfo(
            _poolId, address(positionManager), band.tickLower, band.tickUpper, bytes32(band.tokenId)
        );
        (uint256 now0, uint256 now1) = stateView.getFeeGrowthInside(_poolId, band.tickLower, band.tickUpper);
        unchecked {
            fee0 = Math.mulDiv(liquidity, now0 - last0, 1 << 128); // aderyn-ignore(literal-instead-of-constant)
            fee1 = Math.mulDiv(liquidity, now1 - last1, 1 << 128); // aderyn-ignore(literal-instead-of-constant)
        }
    }

    /**
     * @notice Values token amounts in token1 units at a sqrt price.
     * @dev Uses spot price only after PriceGuard has approved deposit valuation in the same transaction.
     * @param amount0 Currency0 amount.
     * @param amount1 Currency1 amount.
     * @param sp Current pool sqrt price.
     * @return value_ Token1-denominated value.
     */
    function _value(uint256 amount0, uint256 amount1, uint160 sp) private pure returns (uint256 value_) {
        uint256 priceX96 = Math.mulDiv(sp, sp, Q96);
        value_ = Math.mulDiv(amount0, priceX96, Q96) + amount1;
    }

    /**
     * @notice Reads this vault's balance of a currency.
     * @dev Native balance is `address(this).balance`; ERC-20 balance uses `balanceOf`.
     * @param currency Currency to inspect.
     * @return amount Balance amount.
     */
    function _balance(Currency currency) private view returns (uint256 amount) {
        amount = currency.balanceOfSelf();
    }

    /**
     * @notice Reads this vault's idle ERC-4626 asset balance.
     * @dev Used by M4 idle-bounded withdraw and redeem limits.
     * @return amount Asset token balance.
     */
    function _assetBalance() private view returns (uint256 amount) {
        amount = _balance(_cfg.poolKey.currency1);
    }

    /**
     * @notice Mints shares.
     * @dev On the first mint, locks `MIN_LOCK_SHARES` to the dead address before minting receiver shares.
     * @param to Share receiver.
     * @param value Share amount.
     */
    function _mint(address to, uint256 value) private {
        if (to == address(0)) revert ZeroAddress();
        if (totalSupply == 0) {
            totalSupply = MIN_LOCK_SHARES;
            balanceOf[DEAD_SHARES] = MIN_LOCK_SHARES;
            emit Transfer(address(0), DEAD_SHARES, MIN_LOCK_SHARES);
        }
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    /**
     * @notice Burns shares.
     * @dev Used by ERC-4626 withdrawal and redemption flows.
     * @param from Share owner.
     * @param value Share amount.
     */
    function _burn(address from, uint256 value) private {
        balanceOf[from] -= value;
        totalSupply -= value;
        emit Transfer(from, address(0), value);
    }

    /**
     * @notice Moves shares between accounts.
     * @dev Rejects zero receiver; underflow reverts if balance is insufficient.
     * @param from Share sender.
     * @param to Share receiver.
     * @param value Share amount.
     */
    function _transfer(address from, address to, uint256 value) private {
        if (to == address(0)) revert ZeroAddress();
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }

    /**
     * @notice Spends share allowance when caller is not owner.
     * @dev Infinite allowances remain unchanged.
     * @param owner Share owner.
     * @param spender Share spender.
     * @param value Share amount.
     */
    function _spendAllowance(address owner, address spender, uint256 value) private {
        if (owner == spender) return;
        uint256 current = allowance[owner][spender];
        if (current != type(uint256).max) {
            uint256 remaining = current - value;
            allowance[owner][spender] = remaining;
            emit Approval(owner, spender, remaining);
        }
    }
}
