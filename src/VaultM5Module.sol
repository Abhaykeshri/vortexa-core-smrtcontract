// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceGuard} from "./interfaces/IPriceGuard.sol";
import {ISwapExecutor} from "./interfaces/ISwapExecutor.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IPositionManagerLike} from "./interfaces/external/IPositionManagerLike.sol";
import {IPermit2Like} from "./interfaces/external/IPermit2Like.sol";
import {IStateViewLike} from "./interfaces/external/IStateViewLike.sol";
import {Band, Currency, Plan, Strategy, VaultConfig} from "./libraries/Types.sol";
import {CurrencyLib} from "./libraries/CurrencyLib.sol";
import {LiquidityMath} from "./libraries/LiquidityMath.sol";
import {PoolIdLib} from "./libraries/PoolIdLib.sol";
import {PosmActions} from "./libraries/PosmActions.sol";
import {SqrtPriceMath} from "./libraries/SqrtPriceMath.sol";

/**
 * @title Vault M5 Module
 * @notice Delegatecall module holding the size-heavy M5 vault operations: pair withdrawal, fee collection,
 *         compounding, the deposit-side protocol fee and the rebalance-readiness view.
 * @dev Deployed by the `Vault` implementation constructor and reachable only through the vault's fixed wrappers,
 *      which pass the vault's own immutable dependencies. Its storage declarations must stay identical, slot for
 *      slot, to `Vault`'s. State-changing entry points refuse direct calls, so the module's own (empty) storage is
 *      never used.
 */
contract VaultM5Module {
    using CurrencyLib for Currency;
    using SafeERC20 for IERC20;

    /**
     * @notice Caller is not authorized for the requested action.
     */
    error NotAuthorized();
    /**
     * @notice A required address argument or configured address is zero.
     */
    error ZeroAddress();
    /**
     * @notice The vault is paused for actions that remain pause-gated.
     */
    error IsPaused();
    /**
     * @notice PriceGuard does not currently trust the pool price.
     */
    error PriceUntrusted();
    /**
     * @notice The operation produced less than the caller's minimum output.
     */
    error SlippageExceeded();
    /**
     * @notice A zero amount was supplied where a positive value is required.
     */
    error ZeroValue();
    /**
     * @notice The requested liquidity operation would produce no usable liquidity.
     */
    error ZeroLiquidity();
    /**
     * @notice A Permit2 approval amount does not fit Permit2's uint160 allowance field.
     */
    error PermitAmountTooLarge();

    /**
     * @notice ERC-20 Transfer event emitted when delegated burns occur.
     * @param from Share owner whose shares were burned.
     * @param to Always the zero address for burns.
     * @param value Shares burned.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @notice Probe liquidity used to derive proportional add-liquidity scale factors.
     */
    uint256 internal constant LIQUIDITY_PROBE = 1e18;
    /**
     * @notice Divisor that reserves settlement headroom when increasing liquidity.
     */
    uint128 internal constant LIQUIDITY_HEADROOM_DIVISOR = 1e8;
    /**
     * @notice Basis-point denominator.
     */
    uint256 internal constant BPS_DENOMINATOR = 1e4;
    /**
     * @notice Q96 fixed-point denominator used for oracle-value conversions.
     */
    uint256 internal constant Q96 = 1 << 96;
    /**
     * @notice Uniswap fee denominator (hundredths of a basis point).
     */
    uint256 internal constant FEE_DENOMINATOR = 1e6;
    /**
     * @notice Maximum first-deposit swap value, matching the M6 rebalance brake.
     */
    uint256 internal constant MAX_SWAP_BPS = 6_000;
    /**
     * @notice Hard one-percent slippage bound for an atomic first-deposit swap.
     */
    uint256 internal constant MAX_SLIPPAGE_BPS = 100;
    /**
     * @notice Per-band dust retained to avoid exact-edge settlement reverts.
     */
    uint256 internal constant SETTLEMENT_DUST_PER_BAND = 2;
    /**
     * @notice Absolute ceiling on the protocol fee: 100 percent of the collected trading fees.
     * @dev The business cap is mutable factory state (`IVaultFactory.maxProtocolFeeBps`, at most 10,000 bps), so
     *      the vault only enforces the safety bound: a factory value above 100 percent is clamped, so the fee can
     *      never reach principal and payouts can never underflow. Must equal `Vault.MAX_PROTOCOL_FEE_BPS`.
     */
    uint256 internal constant MAX_PROTOCOL_FEE_BPS = 1e4;
    /**
     * @notice Gas forwarded to the fee collector for a best-effort native protocol-fee transfer during withdrawal.
     * @dev Ample for an empty `receive()` or a Safe-style proxy, small enough that a gas-burning collector cannot
     *      starve the rest of the withdrawal.
     */
    // Referenced from inline assembly in _safeTransfer; Aderyn does not resolve that use.
    // aderyn-fp-next-line(unused-state-variable)
    uint256 internal constant FEE_TRANSFER_GAS = 1e5;
    /**
     * @notice Minimum time between rebalances (guide 13.3, 30 minutes).
     * @dev `checkRebalance` reports `COOLDOWN` inside the window, matching the milestone 6 rebalance gate.
     */
    uint256 internal constant COOLDOWN = 30 minutes;
    /**
     * @notice Maximum number of strategy bands accepted by the vault.
     */
    uint256 internal constant MAX_BANDS = 5;
    /**
     * @notice Lowest Uniswap tick.
     */
    int256 internal constant MIN_TICK = -887272;
    /**
     * @notice Highest Uniswap tick.
     */
    int256 internal constant MAX_TICK = 887272;

    /**
     * @notice Values carried across one in-kind withdrawal preview.
     * @dev Grouped in memory to keep the preview below the stack limit.
     */
    struct PreviewCache {
        uint256 supply;
        IStateViewLike stateView;
        address positionManager;
        bytes32 poolId;
        uint160 sqrtPrice;
        uint256 pending0;
        uint256 pending1;
        uint256 principal0;
        uint256 principal1;
        uint256 feeBps;
    }

    /**
     * @notice Runtime values carried across one delegated pair withdrawal.
     * @dev Grouped in memory to keep the withdrawal below the stack limit.
     */
    struct WithdrawCache {
        uint256 supplyBefore;
        uint256 idle0;
        uint256 idle1;
        uint256 pending0;
        uint256 pending1;
        uint256 delta0;
        uint256 delta1;
        uint256 protocolFee0;
        uint256 protocolFee1;
        IPositionManagerLike positionManager;
    }

    /**
     * @notice This module's own address, used to refuse direct (non-delegated) calls.
     */
    address private immutable _self;

    /**
     * @notice Storage slot mirror for Vault.name.
     */
    string public name;
    /**
     * @notice Storage slot mirror for Vault.symbol.
     */
    string public symbol;
    /**
     * @notice Storage slot mirror for Vault.totalSupply.
     */
    uint256 public totalSupply;
    /**
     * @notice Storage slot mirror for Vault.lastRebalance.
     */
    uint64 public lastRebalance;
    /**
     * @notice Storage slot mirror for Vault.paused.
     */
    // Written by Vault through delegatecall; Slither cannot see that storage.
    // slither-disable-next-line uninitialized-state
    bool public paused;
    /**
     * @notice Storage slot mirror for Vault.filled.
     */
    bool public filled;
    /**
     * @notice Storage slot mirror for Vault._initialized.
     */
    // Storage-layout mirror of Vault._initialized; required for safe delegatecall execution.
    // aderyn-fp-next-line(unused-state-variable)
    bool private _initialized;
    /**
     * @notice Storage slot mirror for Vault._cfg.
     */
    // Written by Vault through delegatecall; Slither cannot see that storage.
    // slither-disable-next-line uninitialized-state
    VaultConfig private _cfg;
    /**
     * @notice Storage slot mirror for Vault._poolId.
     */
    // Written by Vault through delegatecall; Slither cannot see that storage.
    // slither-disable-next-line uninitialized-state
    bytes32 private _poolId;
    /**
     * @notice Storage slot mirror for Vault._strategy.
     */
    // Written by Vault through delegatecall; Slither cannot see that storage.
    // slither-disable-next-line uninitialized-state
    IStrategy private _strategy;
    /**
     * @notice Storage slot mirror for Vault._bands.
     */
    Band[] private _bands;
    /**
     * @notice Share balances mirrored from Vault storage during delegated execution.
     */
    mapping(address account => uint256 balance) public balanceOf;
    /**
     * @notice Share allowances mirrored from Vault storage during delegated execution.
     */
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    /**
     * @notice Restricts state-changing entry points to delegated execution inside a vault.
     * @dev A direct call would run against this module's empty storage; refusing it removes that surface entirely.
     */
    modifier onlyDelegated() {
        if (address(this) == _self) revert NotAuthorized();
        _;
    }

    /**
     * @notice Records the module address for the delegation check.
     * @dev Deployed once by the Vault implementation constructor.
     */
    constructor() {
        _self = address(this);
    }

    /**
     * @notice Validates the stored strategy/configuration pair against the live pool tick during initialization.
     * @dev Executes in Vault storage through the immutable module before initialization returns.
     */
    function validateStrategy() external view onlyDelegated {
        (, int24 tick,,) = IVault(address(this)).stateView().getSlot0(_poolId);
        _strategy.validateConfig(_cfg, tick);
    }

    /**
     * @notice Builds, validates, and executes the strategy plan used by a vault's first pair deposit.
     * @dev A Normal LP swap is executed atomically through the immutable M6 executor. The swap is independently
     *      bounded to 60% of supplied oracle value, uses a one-percent oracle-derived minimum output, and leaves no
     *      ERC-20 allowance behind. One-sided strategies may never request a swap.
     * @param sqrtPrice Current pool square-root price.
     * @param tick Current pool tick.
     * @param amount0 Supplied currency0 budget.
     * @param amount1 Supplied currency1 budget.
     * @return bands Validated target bands.
     * @return weights Validated relative weights.
     * @return postAmount0 Currency0 budget remaining after the optional swap.
     * @return postAmount1 Currency1 budget remaining after the optional swap.
     */
    function depositPlan(uint160 sqrtPrice, int24 tick, uint256 amount0, uint256 amount1)
        external
        payable
        onlyDelegated
        returns (Band[] memory bands, uint16[] memory weights, uint256 postAmount0, uint256 postAmount1)
    {
        Plan memory plan_ = _strategy.plan(_cfg, tick, _cfg.centerTick, sqrtPrice, amount0, amount1, bytes32("NONE"));
        if (plan_.lockIdle) revert IVault.InvalidPlan();
        _validateDepositBands(plan_.bands, plan_.weightsBps, tick);
        if (plan_.needsSwap != (plan_.swapAmountIn != 0)) revert IVault.InvalidPlan();
        if (_cfg.strategy != Strategy.NormalLP && plan_.needsSwap) revert IVault.InvalidPlan();
        if (plan_.needsSwap && plan_.swapAmountIn > (plan_.zeroForOne ? amount0 : amount1)) {
            revert IVault.InvalidPlan();
        }
        postAmount0 = amount0;
        postAmount1 = amount1;
        if (plan_.needsSwap) {
            uint256 amountOut = _executeDepositSwap(plan_, amount0, amount1);
            if (plan_.zeroForOne) {
                postAmount0 -= plan_.swapAmountIn;
                postAmount1 += amountOut;
            } else {
                postAmount1 -= plan_.swapAmountIn;
                postAmount0 += amountOut;
            }
        }
        return (plan_.bands, plan_.weightsBps, postAmount0, postAmount1);
    }

    /**
     * @notice Liquidity to add to each existing band for a later pair deposit.
     * @dev Executes in Vault storage through delegatecall and shares `_liquidityForExisting` with `compound`, so
     *      deposits and compounding size existing bands identically. Reverts with `ZeroLiquidity` when the budgets
     *      cannot fund every band. Payable because it is reached from the payable `depositPair` (delegatecall keeps
     *      `msg.value`); it moves no funds.
     * @param sp Current pool square-root price.
     * @param amount0 Currency0 budget.
     * @param amount1 Currency1 budget.
     * @return addLiq Liquidity to add per band.
     */
    function depositLiquidity(uint160 sp, uint256 amount0, uint256 amount1)
        external
        payable
        onlyDelegated
        returns (uint128[] memory addLiq)
    {
        addLiq = _liquidityForExisting(sp, amount0, amount1);
    }

    /**
     * @notice Executes an independently bounded Normal LP first-deposit swap.
     * @dev Uses the trusted reference for validation and delegates measured execution to the immutable executor.
     * @param plan_ Validated strategy plan.
     * @param amount0 Supplied currency0 budget.
     * @param amount1 Supplied currency1 budget.
     * @return amountOut Measured output returned by the swap executor.
     */
    function _executeDepositSwap(Plan memory plan_, uint256 amount0, uint256 amount1)
        private
        returns (uint256 amountOut)
    {
        IVault self = IVault(address(this));
        address executor = self.swapExecutor();
        if (executor == address(0)) revert IVault.InvalidPlan();

        uint160 referenceSqrtPrice = self.priceGuard().referenceSqrtPriceX96(_cfg.poolKey);
        _validateDepositSwapSize(plan_, amount0, amount1, referenceSqrtPrice);
        amountOut = _callDepositSwap(executor, plan_, _depositMinimumOutput(plan_, referenceSqrtPrice));
    }

    /**
     * @notice Enforces the 60% oracle-value cap for a first-deposit swap.
     * @dev Values both the complete deposit and the proposed input at one trusted reference price.
     * @param plan_ Validated strategy plan containing the proposed input and direction.
     * @param amount0 Supplied currency0 budget.
     * @param amount1 Supplied currency1 budget.
     * @param referenceSqrtPrice Trusted reference square-root price.
     */
    function _validateDepositSwapSize(Plan memory plan_, uint256 amount0, uint256 amount1, uint160 referenceSqrtPrice)
        private
        view
    {
        uint256 priceX96 = Math.mulDiv(referenceSqrtPrice, referenceSqrtPrice, Q96);
        if (priceX96 == 0 || _cfg.poolKey.fee >= FEE_DENOMINATOR) revert IVault.InvalidPlan();
        uint256 totalValue = Math.mulDiv(amount0, priceX96, Q96) + amount1;
        uint256 inputValue = plan_.zeroForOne ? Math.mulDiv(plan_.swapAmountIn, priceX96, Q96) : plan_.swapAmountIn;
        if (inputValue > Math.mulDiv(totalValue, MAX_SWAP_BPS, BPS_DENOMINATOR)) {
            revert IVault.SwapTooLarge();
        }
    }

    /**
     * @notice Computes the oracle-derived output floor after pool fee and one-percent slippage.
     * @dev Floors every conversion so the executor receives a conservative minimum.
     * @param plan_ Validated strategy plan containing the proposed input and direction.
     * @param referenceSqrtPrice Trusted reference square-root price.
     * @return minOut Minimum acceptable swap output.
     */
    function _depositMinimumOutput(Plan memory plan_, uint160 referenceSqrtPrice)
        private
        view
        returns (uint256 minOut)
    {
        uint256 priceX96 = Math.mulDiv(referenceSqrtPrice, referenceSqrtPrice, Q96);
        minOut = plan_.zeroForOne
            ? Math.mulDiv(plan_.swapAmountIn, priceX96, Q96)
            : Math.mulDiv(plan_.swapAmountIn, Q96, priceX96);
        minOut = Math.mulDiv(minOut, FEE_DENOMINATOR - _cfg.poolKey.fee, FEE_DENOMINATOR);
        minOut = Math.mulDiv(minOut, BPS_DENOMINATOR - MAX_SLIPPAGE_BPS, BPS_DENOMINATOR);
    }

    /**
     * @notice Grants an exact allowance, calls the executor, and revokes the allowance.
     * @dev Native input is forwarded as value; ERC-20 input receives no standing post-call allowance.
     * @param executor Immutable swap executor selected by the vault implementation.
     * @param plan_ Validated strategy plan containing the proposed input and direction.
     * @param minOut Minimum acceptable output derived from the trusted reference.
     * @return amountOut Measured output returned by the executor.
     */
    function _callDepositSwap(address executor, Plan memory plan_, uint256 minOut) private returns (uint256 amountOut) {
        Currency input = plan_.zeroForOne ? _cfg.poolKey.currency0 : _cfg.poolKey.currency1;
        bool native = input.isNative();
        if (!native) IERC20(Currency.unwrap(input)).forceApprove(executor, plan_.swapAmountIn);
        amountOut = ISwapExecutor(executor).swapExactInput{value: native ? plan_.swapAmountIn : 0}(
            _cfg.poolKey, plan_.zeroForOne, plan_.swapAmountIn, minOut
        );
        if (!native) IERC20(Currency.unwrap(input)).forceApprove(executor, 0);
    }

    /**
     * @notice Validates first-deposit band geometry, weights, and one-sided placement.
     * @dev Rejects persistent position state, gaps, invalid alignment, bad weights, and the wrong price side.
     * @param bands Candidate bands.
     * @param weights Candidate weights.
     * @param tick Current pool tick.
     */
    function _validateDepositBands(Band[] memory bands, uint16[] memory weights, int24 tick) private view {
        uint256 count = bands.length;
        if (count == 0 || count > MAX_BANDS || count != weights.length) revert IVault.InvalidPlan();
        int24 spacing = _cfg.poolKey.tickSpacing;
        if (spacing <= 0) revert IVault.InvalidPlan();
        bool below = (_cfg.strategy == Strategy.BuyTheDip) == _cfg.baseIsCurrency0;
        uint256 totalWeight;
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 i = 0; i < count; ++i) {
            Band memory band = bands[i];
            if (
                band.tokenId != 0 || band.liquidity != 0 || band.tickUpper <= band.tickLower
                    || band.tickLower % spacing != 0 || band.tickUpper % spacing != 0 || band.tickLower < MIN_TICK
                    || band.tickUpper > MAX_TICK || (i != 0 && bands[i - 1].tickUpper != band.tickLower)
            ) revert IVault.InvalidPlan();
            if (_cfg.strategy != Strategy.NormalLP && (below ? band.tickUpper > tick : band.tickLower <= tick)) {
                revert IVault.InvalidPlan();
            }
            if (weights[i] == 0) revert IVault.InvalidPlan();
            totalWeight += weights[i];
        }
        if (totalWeight != BPS_DENOMINATOR) revert IVault.InvalidPlan();
    }

    /**
     * @notice Burns the caller's shares and pays out their proportional share of both currencies (guide 7.2).
     * @dev Order: read supply, idle balances and per-band pending fees; burn; lower stored liquidity; one
     *      `modifyLiquidities` with DECREASE_LIQUIDITY per non-empty band and TAKE_PAIR to the vault; measure the
     *      balance delta; take the protocol fee from the collected fees only; pay
     *      `(delta - F) + f * (idle + F - protocolFee)`. Withdrawal depends on nothing but the PositionManager and
     *      token transfers: the factory is read only when fees are pending, through non-reverting reads, and the
     *      fee transfer is best-effort, so a broken factory or fee collector forfeits the fee instead of blocking the
     *      exit. Bands with zero stored liquidity are skipped (Uniswap reverts on modifying an empty position). The
     *      currency1 leg is paid before the currency0 leg, so a native-ETH receiver only ever observes final state.
     *      Same signature as `Vault.withdrawPair`, which forwards its calldata unchanged; the vault's dependencies
     *      are read back from its own immutable getters, and only when there are bands.
     * @param shares Shares to burn.
     * @param min0 Minimum currency0 output.
     * @param min1 Minimum currency1 output.
     * @param receiver Payout receiver.
     * @return amount0 Currency0 paid to the receiver.
     * @return amount1 Currency1 paid to the receiver.
     */
    // This module is reachable only by delegatecall from Vault.withdrawPair, whose external entry point is
    // nonReentrant. Slither analyzes the module in isolation and cannot observe that caller-side guard.
    // slither-disable-next-line reentrancy-balance
    function withdrawPair(uint256 shares, uint256 min0, uint256 min1, address receiver)
        external
        onlyDelegated
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0) revert ZeroValue();
        if (receiver == address(0)) revert ZeroAddress();

        WithdrawCache memory cache;
        cache.supplyBefore = totalSupply;
        cache.idle0 = _balance(_cfg.poolKey.currency0);
        cache.idle1 = _balance(_cfg.poolKey.currency1);
        uint128[] memory removeLiq;
        bool callPositionManager;
        if (_bands.length != 0) {
            // The Vault wrapper already holds the shared transient non-reentrancy lock.
            // aderyn-fp-next-line(reentrancy-state-change)
            cache.positionManager = IVault(address(this)).positionManager();
            // aderyn-fp-next-line(reentrancy-state-change)
            (removeLiq, callPositionManager) =
                _withdrawPlan(cache.positionManager, IVault(address(this)).stateView(), shares, cache);
        }

        balanceOf[msg.sender] -= shares;
        totalSupply = cache.supplyBefore - shares;
        emit Transfer(msg.sender, address(0), shares);

        if (callPositionManager) _removeLiquidity(cache.positionManager, removeLiq, cache);
        if (cache.pending0 != 0 || cache.pending1 != 0) {
            (cache.protocolFee0, cache.protocolFee1) = _payProtocolFee(cache.pending0, cache.pending1, false);
        }

        amount0 = _withdrawPayout(cache.delta0, cache.pending0, cache.protocolFee0, cache.idle0, shares, cache);
        amount1 = _withdrawPayout(cache.delta1, cache.pending1, cache.protocolFee1, cache.idle1, shares, cache);
        if (amount0 < min0 || amount1 < min1) revert SlippageExceeded();

        emit IVault.PairWithdrawn(msg.sender, receiver, msg.sender, shares, amount0, amount1);
        _cfg.poolKey.currency1.transfer(receiver, amount1); // aderyn-fp(unsafe-erc20-operation)
        _cfg.poolKey.currency0.transfer(receiver, amount0); // aderyn-fp(unsafe-erc20-operation)
    }

    /**
     * @notice Collects accrued trading fees from every non-empty band and pays the protocol cut (guide 7.3).
     * @dev Permissionless. One DECREASE_LIQUIDITY of zero per band plus TAKE_PAIR to the vault; the measured
     *      balance increase is exactly the collected fees. The protocol fee transfer must succeed here; if the
     *      collector is broken the call reverts and the fees stay in the positions. Same signature as
     *      `Vault.collectFees`, which forwards its calldata.
     * @return fee0 Gross currency0 fees collected.
     * @return fee1 Gross currency1 fees collected.
     */
    function collectFees() external onlyDelegated returns (uint256 fee0, uint256 fee1) {
        bytes memory data = _encodeDecrease(new uint128[](_bands.length));
        if (data.length == 0) return (0, 0);
        (fee0, fee1) = _modifyAndMeasure(IVault(address(this)).positionManager(), data);
        (uint256 protocolFee0, uint256 protocolFee1) = _payProtocolFee(fee0, fee1, true);
        emit IVault.FeesCollected(fee0, fee1, protocolFee0, protocolFee1);
    }

    /**
     * @notice Reinvests idle balances into the existing bands without minting shares (guide 7.3).
     * @dev Keeper-only, pause-gated and PriceGuard-gated. INCREASE_LIQUIDITY also credits each band's accrued fees
     *      into the same settlement, so the spend is measured as `idle + creditedFees - balanceAfter` (saturating),
     *      and the protocol cut of those credited fees is paid afterwards, exactly as `collectFees` would. Same
     *      signature as `Vault.compound`, which forwards its calldata.
     * @return used0 Currency0 consumed from idle.
     * @return used1 Currency1 consumed from idle.
     */
    function compound() external onlyDelegated returns (uint256 used0, uint256 used1) {
        IVault self = IVault(address(this));
        // The Vault wrapper already holds the shared transient non-reentrancy lock.
        // aderyn-fp-next-line(reentrancy-state-change)
        IPositionManagerLike positionManager = self.positionManager();
        (uint256 amount0, uint256 amount1, uint128[] memory addLiq) = _compoundPlan(self);
        // aderyn-fp-next-line(reentrancy-state-change)
        (uint256 fees0, uint256 fees1) = _pendingTotal(self.stateView(), positionManager);
        uint256 bandCount = _bands.length;
        // aderyn-ignore-next-line(costly-loop)
        for (uint256 i = 0; i < bandCount;) {
            _bands[i].liquidity += addLiq[i];
            unchecked {
                ++i;
            }
        }
        _callPositionManager(positionManager, self.permit2(), addLiq, amount0, amount1);
        used0 = _used(amount0, fees0, _balance(_cfg.poolKey.currency0));
        used1 = _used(amount1, fees1, _balance(_cfg.poolKey.currency1));
        // The call is made for its checked transfer effects; its accounting tuple is not needed here.
        // aderyn-fp-next-line(unchecked-return)
        _payProtocolFee(fees0, fees1, true);
        emit IVault.Compounded(msg.sender, used0, used1);
    }

    /**
     * @notice Pays the protocol cut of fees that a deposit's INCREASE_LIQUIDITY credited into the vault.
     * @dev Called by `Vault` right after a pair deposit with the fees it computed before the PositionManager call.
     *      Without it every deposit would sweep all pending fees to the holders and silently cancel the protocol
     *      fee on them (guide invariant 7). The vault values pending fees net of this cut, so the depositor's share
     *      price already excludes it. `payable` only because the delegatecall carries the deposit's `msg.value`;
     *      the function never reads or moves it.
     * @param fee0 Currency0 fees credited by the deposit.
     * @param fee1 Currency1 fees credited by the deposit.
     * @return protocolFee0 Currency0 sent to the fee collector.
     * @return protocolFee1 Currency1 sent to the fee collector.
     */
    function payDepositProtocolFee(uint256 fee0, uint256 fee1)
        external
        payable
        onlyDelegated
        returns (uint256 protocolFee0, uint256 protocolFee1)
    {
        if (fee0 == 0 && fee1 == 0) return (0, 0);
        (protocolFee0, protocolFee1) = _payProtocolFee(fee0, fee1, true);
    }

    /**
     * @notice Previews `withdrawPair(shares)` to the wei: what burning `shares` would pay right now.
     * @dev Same arithmetic as `withdrawPair`, from StateView reads, balances and the factory's fee only: for every
     *      non-empty band the principal of `floor(L * shares / supply)` at the current price, rounded down exactly as
     *      Uniswap pays a removal, plus `floor(shares * (idle + F - protocolFee) / supply)`. Called directly on the
     *      module (`VaultM5Module(vault.m5Module())`), never through delegatecall, and changes nothing. Reverts with
     *      `ZeroValue` for zero shares or more shares than exist.
     * @param vault Vault to preview.
     * @param shares Shares that would be burned.
     * @return amount0 Currency0 the withdrawal would pay.
     * @return amount1 Currency1 the withdrawal would pay.
     */
    function previewWithdrawPair(IVault vault, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        PreviewCache memory p;
        p.supply = vault.totalSupply();
        if (shares == 0 || shares > p.supply) revert ZeroValue();
        VaultConfig memory cfg = vault.config();
        p.stateView = vault.stateView();
        p.positionManager = address(vault.positionManager());
        p.poolId = PoolIdLib.toId(cfg.poolKey);
        (p.sqrtPrice,,,) = p.stateView.getSlot0(p.poolId);
        Band[] memory bandList = vault.bands();
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 i = 0; i < bandList.length;) {
            if (bandList[i].liquidity != 0) _previewBand(p, bandList[i], shares);
            unchecked {
                ++i;
            }
        }
        if (p.pending0 != 0 || p.pending1 != 0) p.feeBps = _protocolFeeBps(vault.factory());
        amount0 = p.principal0 + _previewShare(p, shares, _balanceOf(cfg.poolKey.currency0, address(vault)), p.pending0);
        amount1 = p.principal1 + _previewShare(p, shares, _balanceOf(cfg.poolKey.currency1, address(vault)), p.pending1);
    }

    /**
     * @notice The idle-plus-net-fees part of a previewed payout for one currency.
     * @dev `floor(shares * (idle + F - floor(F * feeBps / 10_000)) / supply)`, as in `_withdrawPayout`.
     * @param p Preview cache (supply and effective fee).
     * @param shares Shares that would be burned.
     * @param idle Vault idle balance.
     * @param pending Pending fees that the withdrawal would collect.
     * @return amount Share of idle and net fees.
     */
    function _previewShare(PreviewCache memory p, uint256 shares, uint256 idle, uint256 pending)
        private
        pure
        returns (uint256 amount)
    {
        amount = Math.mulDiv(shares, idle + pending - Math.mulDiv(pending, p.feeBps, BPS_DENOMINATOR), p.supply);
    }

    /**
     * @notice Reports whether a rebalance is warranted and every vault-side gate would allow it now.
     * @dev Called through `staticcall` by `Vault.checkRebalance`, reading the vault back through its public views.
     *      Gates, in the order milestone 6's rebalance applies them: `PAUSED`, `AUTO_OFF`, `COOLDOWN`, `PRICE`
     *      (untrusted or reverting PriceGuard), then the strategy trigger.
     * @param vault Vault to inspect.
     * @param strategy Strategy copied into the vault at initialization.
     * @return needed True when the strategy says keeper work is needed and no gate blocks it.
     * @return reason Strategy reason or the blocking gate's label.
     */
    function checkRebalance(IVault vault, IStrategy strategy) external view returns (bool needed, bytes32 reason) {
        if (vault.paused()) return (false, bytes32("PAUSED"));
        VaultConfig memory cfg = vault.config();
        if (!cfg.autoRebalance) return (false, bytes32("AUTO_OFF"));
        if (block.timestamp < uint256(vault.lastRebalance()) + COOLDOWN) return (false, bytes32("COOLDOWN"));
        try vault.priceGuard().isPriceTrusted(cfg.poolKey) returns (bool trusted, uint256) {
            if (!trusted) return (false, bytes32("PRICE"));
        } catch {
            return (false, bytes32("PRICE"));
        }
        (, int24 tick,,) = vault.stateView().getSlot0(PoolIdLib.toId(cfg.poolKey));
        return strategy.checkTrigger(cfg, tick, vault.bands());
    }

    /**
     * @notice Reads every non-empty band's pending fees and the liquidity this withdrawal removes from it.
     * @dev Runs before any state change or external call that could move fee growth. Fills `pending0/1` in
     *      `cache`. The PositionManager is needed when any liquidity is removed or any fee is pending; a tiny
     *      withdrawal that removes nothing and collects nothing pays only the idle share without calling it.
     * @param positionManager Trusted PositionManager-compatible contract.
     * @param stateView Trusted StateView-compatible contract.
     * @param shares Shares being burned.
     * @param cache Withdrawal cache; `supplyBefore` is read, `pending0/1` are written.
     * @return removeLiq Liquidity to remove per band, `floor(L * shares / supply)`.
     * @return callPositionManager True when a PositionManager call is needed.
     */
    function _withdrawPlan(
        IPositionManagerLike positionManager,
        IStateViewLike stateView,
        uint256 shares,
        WithdrawCache memory cache
    ) private view returns (uint128[] memory removeLiq, bool callPositionManager) {
        uint256 bandCount = _bands.length;
        removeLiq = new uint128[](bandCount);
        for (uint256 i = 0; i < bandCount;) {
            Band storage band = _bands[i];
            if (band.liquidity != 0) {
                (uint256 f0, uint256 f1) = _pendingFees(stateView, positionManager, band);
                cache.pending0 += f0;
                cache.pending1 += f1;
                removeLiq[i] = uint128(Math.mulDiv(band.liquidity, shares, cache.supplyBefore));
                if (removeLiq[i] != 0 || f0 != 0 || f1 != 0) callPositionManager = true;
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Lowers stored band liquidity, then removes it (and collects all fees) in one PositionManager call.
     * @dev The payload is encoded before stored liquidity changes so bands emptied by this withdrawal are still
     *      included; storage is updated before the external call. Writes the measured deltas into `cache`.
     * @param positionManager Trusted PositionManager-compatible contract.
     * @param removeLiq Liquidity to remove per band.
     * @param cache Withdrawal cache; `delta0/1` are written.
     */
    function _removeLiquidity(
        IPositionManagerLike positionManager,
        uint128[] memory removeLiq,
        WithdrawCache memory cache
    ) private {
        bytes memory data = _encodeDecrease(removeLiq);
        uint256 bandCount = _bands.length;
        // aderyn-ignore-next-line(costly-loop)
        for (uint256 i = 0; i < bandCount;) {
            _bands[i].liquidity -= removeLiq[i];
            unchecked {
                ++i;
            }
        }
        (cache.delta0, cache.delta1) = _modifyAndMeasure(positionManager, data);
    }

    /**
     * @notice Computes a compound plan after keeper, pause, liquidity and price checks.
     * @dev Kept separate so compound finishes all external read checks before mutating band liquidity.
     * @param self This vault, read through its immutable getters.
     * @return amount0 Current idle currency0 budget.
     * @return amount1 Current idle currency1 budget.
     * @return addLiq Liquidity to add per active band.
     */
    function _compoundPlan(IVault self)
        private
        view
        returns (uint256 amount0, uint256 amount1, uint128[] memory addLiq)
    {
        if (!IVaultFactory(self.factory()).isKeeper(msg.sender)) revert NotAuthorized();
        if (paused) revert IsPaused();
        if (_bands.length == 0) revert ZeroLiquidity();
        (bool trusted,) = self.priceGuard().isPriceTrusted(_cfg.poolKey);
        if (!trusted) revert PriceUntrusted();
        amount0 = _balance(_cfg.poolKey.currency0);
        amount1 = _balance(_cfg.poolKey.currency1);
        (uint160 sp,,,) = self.stateView().getSlot0(_poolId);
        addLiq = _liquidityForExisting(sp, amount0, amount1);
    }

    /**
     * @notice Adds one non-empty band's pending fees and the principal a withdrawal of `shares` removes from it.
     * @dev Mirrors `_withdrawPlan` and Uniswap's removal rounding (both amounts rounded down).
     * @param p Preview cache; `pending0/1` and `principal0/1` are accumulated.
     * @param band Band to preview.
     * @param shares Shares that would be burned.
     */
    function _previewBand(PreviewCache memory p, Band memory band, uint256 shares) private view {
        _previewFees(p, band);
        (uint256 amount0, uint256 amount1) = LiquidityMath.amountsForLiquidity(
            p.sqrtPrice,
            SqrtPriceMath.getSqrtPriceAtTick(band.tickLower),
            SqrtPriceMath.getSqrtPriceAtTick(band.tickUpper),
            uint128(Math.mulDiv(band.liquidity, shares, p.supply))
        );
        p.principal0 += amount0;
        p.principal1 += amount1;
    }

    /**
     * @notice Adds one band's pending fees to the preview, exactly as `_pendingFees` computes them.
     * @dev Wrapping subtraction of fee-growth snapshots, as in Uniswap.
     * @param p Preview cache; `pending0/1` are accumulated.
     * @param band Band to inspect.
     */
    function _previewFees(PreviewCache memory p, Band memory band) private view {
        (uint128 liquidity, uint256 last0, uint256 last1) = p.stateView
            .getPositionInfo(p.poolId, p.positionManager, band.tickLower, band.tickUpper, bytes32(band.tokenId));
        (uint256 now0, uint256 now1) = p.stateView.getFeeGrowthInside(p.poolId, band.tickLower, band.tickUpper);
        unchecked {
            p.pending0 += Math.mulDiv(liquidity, now0 - last0, 1 << 128); // aderyn-ignore(literal-instead-of-constant)
            p.pending1 += Math.mulDiv(liquidity, now1 - last1, 1 << 128); // aderyn-ignore(literal-instead-of-constant)
        }
    }

    /**
     * @notice Reads an account's balance of a currency.
     * @dev Native balance for the zero address, ERC-20 `balanceOf` otherwise.
     * @param currency Currency to inspect.
     * @param account Account to inspect.
     * @return amount Balance.
     */
    function _balanceOf(Currency currency, address account) private view returns (uint256 amount) {
        address token = Currency.unwrap(currency);
        amount = token == address(0) ? account.balance : IERC20(token).balanceOf(account);
    }

    /**
     * @notice Reads the vault's balance of a currency.
     * @dev Under delegatecall `address(this)` is the vault.
     * @param currency Currency to inspect.
     * @return amount Current balance.
     */
    function _balance(Currency currency) private view returns (uint256 amount) {
        amount = currency.balanceOfSelf();
    }

    /**
     * @notice Runs one PositionManager call and measures the vault's balance increase in both currencies.
     * @dev Used for DECREASE + TAKE_PAIR batches, which only ever credit the vault.
     * @param positionManager Trusted PositionManager-compatible contract.
     * @param data Encoded `modifyLiquidities` payload.
     * @return delta0 Currency0 received.
     * @return delta1 Currency1 received.
     */
    function _modifyAndMeasure(IPositionManagerLike positionManager, bytes memory data)
        private
        returns (uint256 delta0, uint256 delta1)
    {
        uint256 pre0 = _balance(_cfg.poolKey.currency0);
        uint256 pre1 = _balance(_cfg.poolKey.currency1);
        positionManager.modifyLiquidities(data, block.timestamp);
        delta0 = _balance(_cfg.poolKey.currency0) - pre0;
        delta1 = _balance(_cfg.poolKey.currency1) - pre1;
    }

    /**
     * @notice Computes pending fees for a band from fee-growth snapshots.
     * @dev Uses wrapping subtraction, matching Uniswap fee-growth counter semantics; equals what Uniswap credits on
     *      the next modification of the position.
     * @param stateView Trusted StateView-compatible contract.
     * @param positionManager Trusted PositionManager-compatible contract.
     * @param band Active band to inspect.
     * @return fee0 Pending currency0 fees.
     * @return fee1 Pending currency1 fees.
     */
    function _pendingFees(IStateViewLike stateView, IPositionManagerLike positionManager, Band storage band)
        private
        view
        returns (uint256 fee0, uint256 fee1)
    {
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
     * @notice Sums pending fees across all bands.
     * @dev These are the fees an INCREASE_LIQUIDITY on every band credits into its settlement.
     * @param stateView Trusted StateView-compatible contract.
     * @param positionManager Trusted PositionManager-compatible contract.
     * @return fees0 Total pending currency0 fees.
     * @return fees1 Total pending currency1 fees.
     */
    function _pendingTotal(IStateViewLike stateView, IPositionManagerLike positionManager)
        private
        view
        returns (uint256 fees0, uint256 fees1)
    {
        uint256 bandCount = _bands.length;
        for (uint256 i = 0; i < bandCount;) {
            (uint256 f0, uint256 f1) = _pendingFees(stateView, positionManager, _bands[i]);
            fees0 += f0;
            fees1 += f1;
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Encodes DECREASE_LIQUIDITY for every band with stored liquidity, then TAKE_PAIR to the vault.
     * @dev Must be called before stored liquidity is lowered. A zero amount collects fees only. Bands with zero
     *      stored liquidity are skipped because Uniswap reverts on modifying an empty position. Returns empty bytes
     *      when no band qualifies.
     * @param removeLiq Liquidity to remove per band (zero to collect fees only).
     * @return data Encoded PositionManager action payload, or empty when there is nothing to call.
     */
    function _encodeDecrease(uint128[] memory removeLiq) private view returns (bytes memory data) {
        uint256 bandCount = _bands.length;
        uint256 live;
        for (uint256 i = 0; i < bandCount;) {
            if (_bands[i].liquidity != 0) ++live;
            unchecked {
                ++i;
            }
        }
        if (live == 0) return data;
        bytes memory actions;
        bytes[] memory params = new bytes[](live + 1);
        uint256 j;
        for (uint256 i = 0; i < bandCount;) {
            if (_bands[i].liquidity != 0) {
                actions = abi.encodePacked(actions, PosmActions.DECREASE_LIQUIDITY);
                params[j++] = abi.encode(_bands[i].tokenId, uint256(removeLiq[i]), uint128(0), uint128(0), bytes(""));
            }
            unchecked {
                ++i;
            }
        }
        actions = abi.encodePacked(actions, PosmActions.TAKE_PAIR);
        params[live] = abi.encode(_cfg.poolKey.currency0, _cfg.poolKey.currency1, address(this));
        data = abi.encode(actions, params);
    }

    /**
     * @notice Sends the protocol cut of collected trading fees to the factory's fee collector.
     * @dev `protocolFee = floor(fee * bps / 10_000)` per currency, where `bps` is the factory's current fee clamped
     *      to `MAX_PROTOCOL_FEE_BPS` (zero if the factory read reverts), so it never exceeds the fees and never
     *      touches principal. Strict mode (collect, compound, deposit) reverts if the collector is
     *      unset or a transfer fails. Lenient mode (withdraw) instead leaves the undeliverable part in the vault for
     *      the remaining holders and emits `ProtocolFeeForfeited`, so no exit can be blocked by the fee path.
     *      The factory is this vault's immutable `factory()`.
     * @param fee0 Gross currency0 fees.
     * @param fee1 Gross currency1 fees.
     * @param strict True to revert on delivery failure, false to forfeit instead.
     * @return protocolFee0 Currency0 protocol fee owed (and, in strict mode, transferred).
     * @return protocolFee1 Currency1 protocol fee owed (and, in strict mode, transferred).
     */
    function _payProtocolFee(uint256 fee0, uint256 fee1, bool strict)
        private
        returns (uint256 protocolFee0, uint256 protocolFee1)
    {
        address factory = IVault(address(this)).factory();
        uint256 feeBps = _protocolFeeBps(factory);
        protocolFee0 = Math.mulDiv(fee0, feeBps, BPS_DENOMINATOR);
        protocolFee1 = Math.mulDiv(fee1, feeBps, BPS_DENOMINATOR);
        if (protocolFee0 == 0 && protocolFee1 == 0) return (0, 0);
        address collector = _feeCollector(factory);
        if (!strict) {
            _deliverOrForfeit(collector, protocolFee0, protocolFee1);
            return (protocolFee0, protocolFee1);
        }
        if (collector == address(0)) revert ZeroAddress();
        _cfg.poolKey.currency0.transfer(collector, protocolFee0); // aderyn-fp(unsafe-erc20-operation)
        _cfg.poolKey.currency1.transfer(collector, protocolFee1); // aderyn-fp(unsafe-erc20-operation)
    }

    /**
     * @notice Best-effort delivery of a withdrawal's protocol fee.
     * @dev Whatever cannot be delivered (unset collector, reverting or gas-burning receiver, token blacklist) stays
     *      in the vault as idle balance for the remaining holders and is reported through `ProtocolFeeForfeited`.
     *      The withdrawer's payout is computed from the owed fee either way, so it never depends on delivery.
     * @param collector Fee collector, possibly zero.
     * @param protocolFee0 Currency0 protocol fee owed.
     * @param protocolFee1 Currency1 protocol fee owed.
     */
    function _deliverOrForfeit(address collector, uint256 protocolFee0, uint256 protocolFee1) private {
        uint256 sent0;
        uint256 sent1;
        if (collector != address(0)) {
            if (_tryTransfer(_cfg.poolKey.currency0, collector, protocolFee0)) sent0 = protocolFee0;
            if (_tryTransfer(_cfg.poolKey.currency1, collector, protocolFee1)) sent1 = protocolFee1;
        }
        if (sent0 != protocolFee0 || sent1 != protocolFee1) {
            emit IVault.ProtocolFeeForfeited(protocolFee0 - sent0, protocolFee1 - sent1);
        }
    }

    /**
     * @notice Reads the factory's protocol fee, clamped to `MAX_PROTOCOL_FEE_BPS`.
     * @dev Never reverts: a reverting factory or a malformed return reads as zero. `Vault._protocolFeeBps` applies
     *      the identical rule when valuing pending fees, so valuation and collection always agree.
     * @param factory Trusted factory.
     * @return feeBps Effective protocol fee in basis points.
     */
    function _protocolFeeBps(address factory) private view returns (uint256 feeBps) {
        feeBps = _readFactoryWord(factory, IVaultFactory.protocolFeeBps.selector);
        if (feeBps > MAX_PROTOCOL_FEE_BPS) feeBps = MAX_PROTOCOL_FEE_BPS;
    }

    /**
     * @notice Reads the factory's fee collector.
     * @dev Never reverts: a reverting factory, a malformed return or a value that is not an address reads as zero.
     * @param factory Trusted factory.
     * @return collector Fee collector, or zero.
     */
    function _feeCollector(address factory) private view returns (address collector) {
        uint256 word = _readFactoryWord(factory, IVaultFactory.feeCollector.selector);
        if (word >> 160 == 0) collector = address(uint160(word));
    }

    /**
     * @notice Reads one 32-byte word from a zero-argument factory getter without ever reverting.
     * @dev Returns zero when the call reverts or returns fewer than 32 bytes. Copies at most 32 bytes of return
     *      data.
     * @param factory Trusted factory.
     * @param selector Getter selector.
     * @return word First return word, or zero.
     */
    function _readFactoryWord(address factory, bytes4 selector) private view returns (uint256 word) {
        assembly ("memory-safe") {
            mstore(0x00, selector)
            let ok := staticcall(gas(), factory, 0x00, 0x04, 0x00, 0x20)
            if and(ok, gt(returndatasize(), 0x1f)) { word := mload(0x00) }
        }
    }

    /**
     * @notice Transfers a currency without ever reverting.
     * @dev Native ETH is sent with `FEE_TRANSFER_GAS` gas and no return-data copy; ERC-20 uses a raw `transfer`
     *      call accepting either no return data or `true`. Used only for the best-effort withdrawal fee.
     * @param currency Currency to send.
     * @param to Recipient.
     * @param amount Amount to send; zero succeeds without a call.
     * @return ok True when the transfer succeeded.
     */
    function _tryTransfer(Currency currency, address to, uint256 amount) private returns (bool ok) {
        if (amount == 0) return true;
        address token = Currency.unwrap(currency);
        if (token == address(0)) {
            assembly ("memory-safe") {
                ok := call(FEE_TRANSFER_GAS, to, amount, 0, 0, 0, 0)
            }
            return ok;
        }
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), shr(96, shl(96, to)))
            mstore(add(m, 0x24), amount)
            ok := call(gas(), token, 0, m, 0x44, 0x00, 0x20)
            ok := and(ok, or(iszero(returndatasize()), and(gt(returndatasize(), 31), eq(mload(0x00), 1))))
        }
    }

    /**
     * @notice Computes the shareholder payout for one currency (guide 7.2 step 7).
     * @dev `(delta - pending)` is the principal removed, guarded against Uniswap's one-wei rounding; the share of
     *      idle plus net fees rounds down, leaving dust with the remaining holders.
     * @param delta Total currency received from the PositionManager call.
     * @param pending Pending trading fees collected by that call.
     * @param protocolFee Protocol fee owed out of `pending` (whether or not it could be delivered).
     * @param idle Idle balance before the withdrawal.
     * @param shares Shares being burned.
     * @param cache Withdrawal cache holding the supply before the burn.
     * @return amount Currency amount owed to the withdrawing shareholder.
     */
    function _withdrawPayout(
        uint256 delta,
        uint256 pending,
        uint256 protocolFee,
        uint256 idle,
        uint256 shares,
        WithdrawCache memory cache
    ) private pure returns (uint256 amount) {
        uint256 principal = delta > pending ? delta - pending : 0;
        amount = principal + Math.mulDiv(shares, idle + pending - protocolFee, cache.supplyBefore);
    }

    /**
     * @notice What a compound actually took from idle in one currency.
     * @dev `pre + fees - post`, clamped at zero (forced ETH swept back from the PositionManager can leave the vault
     *      with more than it started) and capped at `pre`.
     * @param pre Idle balance before the PositionManager call.
     * @param fees Fees credited into the settlement.
     * @param post Balance after the call.
     * @return used Amount of idle consumed.
     */
    function _used(uint256 pre, uint256 fees, uint256 post) private pure returns (uint256 used) {
        uint256 available = pre + fees;
        used = available > post ? available - post : 0;
        if (used > pre) used = pre;
    }

    /**
     * @notice Computes add-liquidity amounts for existing bands.
     * @dev Keeps the stored liquidity proportions, measured on a copy scaled so the first band holds the first-deposit
     *      probe (`LIQUIDITY_PROBE * 10,000`), and reserves settlement headroom.
     * @param sp Current pool sqrt price.
     * @param amount0 Idle currency0 available.
     * @param amount1 Idle currency1 available.
     * @return addLiq Liquidity to add per band.
     */
    function _liquidityForExisting(uint160 sp, uint256 amount0, uint256 amount1)
        private
        view
        returns (uint128[] memory addLiq)
    {
        uint256 unit0;
        uint256 unit1;
        uint256 bandCount = _bands.length;
        uint256 base = _bands[0].liquidity;
        addLiq = new uint128[](bandCount);
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 i = 0; i < bandCount;) {
            // Same probe-scaled sizing as `Vault._liquidityForExisting`: the token amounts of a small stored
            // liquidity round down by up to a unit per band, which overstated the scale enough for compounding a
            // large idle balance to pull more than the budget.
            addLiq[i] = _toUint128(Math.mulDiv(_bands[i].liquidity, LIQUIDITY_PROBE * BPS_DENOMINATOR, base));
            (uint256 a0, uint256 a1) = LiquidityMath.amountsForLiquidity(
                sp,
                SqrtPriceMath.getSqrtPriceAtTick(_bands[i].tickLower),
                SqrtPriceMath.getSqrtPriceAtTick(_bands[i].tickUpper),
                addLiq[i]
            );
            unit0 += a0;
            unit1 += a1;
            unchecked {
                ++i;
            }
        }

        uint256 scale = _scale(unit0, unit1, amount0, amount1, bandCount);
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 i = 0; i < bandCount;) {
            addLiq[i] = _withSettlementHeadroom(_toUint128(Math.mulDiv(addLiq[i], scale, LIQUIDITY_PROBE)));
            if (addLiq[i] == 0) revert ZeroLiquidity();
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Computes the scale factor for adding liquidity.
     * @dev Chooses the limiting token and subtracts per-band settlement dust.
     * @param unit0 Currency0 needed for the existing liquidity.
     * @param unit1 Currency1 needed for the existing liquidity.
     * @param amount0 Currency0 budget.
     * @param amount1 Currency1 budget.
     * @param bandCount Number of active bands.
     * @return scale Fixed-point liquidity scale.
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
     * @notice Applies settlement headroom to an add-liquidity amount.
     * @dev Keeps a tiny reserve to absorb rounding and settlement dust.
     * @param liquidity Raw liquidity amount.
     * @return adjusted Liquidity after headroom.
     */
    function _withSettlementHeadroom(uint128 liquidity) private pure returns (uint128 adjusted) {
        uint128 headroom = liquidity / LIQUIDITY_HEADROOM_DIVISOR;
        if (headroom == 0) headroom = 1;
        adjusted = liquidity > headroom ? liquidity - headroom : 0;
    }

    /**
     * @notice Approves Permit2 and calls PositionManager to increase liquidity.
     * @dev Revokes allowances after the call, leaving no standing Permit2 approval.
     * @param positionManager Trusted PositionManager-compatible contract.
     * @param permit2 Trusted Permit2-compatible contract.
     * @param addLiq Liquidity to add per band.
     * @param amount0 Maximum currency0 spend.
     * @param amount1 Maximum currency1 spend.
     */
    function _callPositionManager(
        IPositionManagerLike positionManager,
        IPermit2Like permit2,
        uint128[] memory addLiq,
        uint256 amount0,
        uint256 amount1
    ) private {
        _approvePosm(permit2, positionManager, amount0, amount1);
        positionManager.modifyLiquidities{value: _cfg.poolKey.currency0.isNative() ? amount0 : 0}(
            _encodeIncrease(addLiq, amount0, amount1), block.timestamp
        );
        _revokePosm(permit2, positionManager, amount0, amount1);
    }

    /**
     * @notice Encodes an increase-liquidity batch for all active bands.
     * @dev Settles each currency with CLOSE_CURRENCY, which pays a debt or takes a credit (fee credits can exceed
     *      the debt), then sweeps unused native ETH back to the vault.
     * @param addLiq Liquidity to add per band.
     * @param max0 Maximum currency0 spend.
     * @param max1 Maximum currency1 spend.
     * @return data Encoded PositionManager action payload.
     */
    function _encodeIncrease(uint128[] memory addLiq, uint256 max0, uint256 max1)
        private
        view
        returns (bytes memory data)
    {
        bool native = _cfg.poolKey.currency0.isNative() && max0 > 0;
        bytes memory actions;
        uint256 bandCount = _bands.length;
        bytes[] memory params = new bytes[](bandCount + 2 + (native ? 1 : 0));
        for (uint256 i = 0; i < bandCount;) {
            actions = abi.encodePacked(actions, PosmActions.INCREASE_LIQUIDITY);
            params[i] = abi.encode(_bands[i].tokenId, uint256(addLiq[i]), _toUint128(max0), _toUint128(max1), bytes(""));
            unchecked {
                ++i;
            }
        }
        actions = abi.encodePacked(actions, PosmActions.CLOSE_CURRENCY, PosmActions.CLOSE_CURRENCY);
        params[bandCount] = abi.encode(_cfg.poolKey.currency0);
        params[bandCount + 1] = abi.encode(_cfg.poolKey.currency1);
        if (native) {
            actions = abi.encodePacked(actions, PosmActions.SWEEP);
            params[bandCount + 2] = abi.encode(_cfg.poolKey.currency0, address(this));
        }
        data = abi.encode(actions, params);
    }

    /**
     * @notice Grants exact Permit2 allowances needed by PositionManager.
     * @dev Native currencies do not require approvals.
     * @param permit2 Trusted Permit2-compatible contract.
     * @param positionManager Trusted PositionManager-compatible contract.
     * @param amount0 Currency0 approval amount.
     * @param amount1 Currency1 approval amount.
     */
    function _approvePosm(IPermit2Like permit2, IPositionManagerLike positionManager, uint256 amount0, uint256 amount1)
        private
    {
        _approvePosmCurrency(permit2, positionManager, _cfg.poolKey.currency0, amount0);
        _approvePosmCurrency(permit2, positionManager, _cfg.poolKey.currency1, amount1);
    }

    /**
     * @notice Revokes Permit2 allowances granted for PositionManager.
     * @dev Resets only currencies that were previously approved.
     * @param permit2 Trusted Permit2-compatible contract.
     * @param positionManager Trusted PositionManager-compatible contract.
     * @param amount0 Currency0 amount that determined whether approval was granted.
     * @param amount1 Currency1 amount that determined whether approval was granted.
     */
    function _revokePosm(IPermit2Like permit2, IPositionManagerLike positionManager, uint256 amount0, uint256 amount1)
        private
    {
        _approvePosmCurrency(permit2, positionManager, _cfg.poolKey.currency0, amount0 == 0 ? 0 : type(uint256).max);
        _approvePosmCurrency(permit2, positionManager, _cfg.poolKey.currency1, amount1 == 0 ? 0 : type(uint256).max);
    }

    /**
     * @notice Updates Permit2 allowance for one currency.
     * @dev Reverts when an ERC-20 approval amount exceeds Permit2's uint160 field; `type(uint256).max` is the
     *      revocation sentinel and sets the allowance to zero.
     * @param permit2 Trusted Permit2-compatible contract.
     * @param positionManager Trusted PositionManager-compatible contract.
     * @param currency Currency to approve.
     * @param amount Approval amount, or the max sentinel for revocation.
     */
    function _approvePosmCurrency(
        IPermit2Like permit2,
        IPositionManagerLike positionManager,
        Currency currency,
        uint256 amount
    ) private {
        if (currency.isNative()) return;
        uint160 permitAmount;
        if (amount == type(uint256).max) {
            permitAmount = 0;
        } else {
            if (amount > type(uint160).max) revert PermitAmountTooLarge();
            permitAmount = uint160(amount);
        }
        permit2.approve(Currency.unwrap(currency), address(positionManager), permitAmount, uint48(block.timestamp)); // aderyn-fp(unsafe-erc20-operation)
    }

    /**
     * @notice Casts a value to uint128 and reverts if it would truncate.
     * @dev Uses a compact bare revert to keep the delegated module small.
     * @param value Value to cast.
     * @return casted Value represented as uint128.
     */
    function _toUint128(uint256 value) private pure returns (uint128 casted) {
        assembly ("memory-safe") {
            if shr(128, value) { revert(0x00, 0x00) }
            casted := value
        }
    }
}
