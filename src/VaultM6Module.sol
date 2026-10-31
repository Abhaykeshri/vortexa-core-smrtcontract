// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {IPriceGuard} from "./interfaces/IPriceGuard.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {ISwapExecutor} from "./interfaces/ISwapExecutor.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IPermit2Like} from "./interfaces/external/IPermit2Like.sol";
import {IPositionManagerLike} from "./interfaces/external/IPositionManagerLike.sol";
import {IStateViewLike} from "./interfaces/external/IStateViewLike.sol";
import {Band, Currency, Plan, RebalanceParams, Strategy, VaultConfig} from "./libraries/Types.sol";
import {CurrencyLib} from "./libraries/CurrencyLib.sol";
import {LiquidityMath} from "./libraries/LiquidityMath.sol";
import {PosmActions} from "./libraries/PosmActions.sol";
import {SqrtPriceMath} from "./libraries/SqrtPriceMath.sol";

/**
 * @title Vault M6 Module
 * @notice Size-isolated implementation of the atomic M6 rebalance lifecycle.
 * @dev Called only by an immutable Vault delegatecall target. The storage declarations below intentionally mirror
 *      Vault exactly and must never be reordered or extended independently.
 */
contract VaultM6Module {
    using CurrencyLib for Currency;
    using SafeERC20 for IERC20;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.BooleanSlot;

    /**
     * @dev Basis-point denominator.
     */
    uint256 internal constant BPS = 1e4;
    /**
     * @dev Uniswap fee denominator.
     */
    uint256 internal constant FEE_DENOMINATOR = 1e6;
    /**
     * @dev Q64.96 fixed-point scale.
     */
    uint256 internal constant Q96 = 1 << 96;
    /**
     * @dev Q128 fee-growth scale.
     */
    uint256 internal constant Q128 = 1 << 128;
    /**
     * @dev Minimum delay between successful rebalances.
     */
    uint256 internal constant COOLDOWN = 30 minutes;
    /**
     * @dev Maximum keeper center distance from spot in ticks.
     */
    uint256 internal constant MAX_CENTER_DRIFT = 200;
    /**
     * @dev Maximum swap input value as a share of vault value.
     */
    uint256 internal constant MAX_SWAP_BPS = 6_000;
    /**
     * @dev Maximum caller-selected loss tolerance.
     */
    uint256 internal constant MAX_SLIPPAGE_BPS = 100;
    /**
     * @dev Maximum strategy plan band count.
     */
    uint256 internal constant MAX_BANDS = 5;
    /**
     * @dev Probe liquidity used to size weighted bands.
     */
    uint256 internal constant LIQUIDITY_PROBE = 1e18;
    /**
     * @dev Per-band token reserve for settlement rounding.
     */
    uint256 internal constant SETTLEMENT_DUST_PER_BAND = 2;
    /**
     * @dev Liquidity haircut denominator used for settlement headroom.
     */
    uint128 internal constant LIQUIDITY_HEADROOM_DIVISOR = 1e8;
    /**
     * @dev Lowest usable Uniswap tick.
     */
    int256 internal constant MIN_TICK = -887272;
    /**
     * @dev Highest usable Uniswap tick.
     */
    int256 internal constant MAX_TICK = 887272;
    /**
     * @dev Vault-shared transient slot gating expected NFT callbacks.
     */
    bytes32 private constant _EXPECTING_NFT_SLOT = keccak256("vortexa.vault.expectingPositionNft");

    /**
     * @dev Module deployment address used to reject direct calls.
     */
    address private immutable _self = address(this);

    /**
     * @notice Vault is paused.
     */
    error IsPaused();
    /**
     * @notice PriceGuard does not trust the pool.
     */
    error PriceUntrusted();
    /**
     * @notice A newly minted position is not held by the vault.
     */
    error InvalidPositionOwner();
    /**
     * @notice A temporary Permit2 allowance cannot fit uint160.
     */
    error PermitAmountTooLarge();
    /**
     * @notice The factory's fee collector is unset while a protocol fee is owed.
     */
    error ZeroAddress();

    /**
     * @notice Runtime values retained across one rebalance.
     * @dev Stack-pressure cache with no independent storage allocation.
     */
    struct RebalanceCache {
        IVault self;
        address factory;
        IStateViewLike stateView;
        IPositionManagerLike positionManager;
        uint160 poolSqrtPrice;
        uint160 referenceSqrtPrice;
        int24 tick;
        int24 oldCenter;
        bytes32 reason;
        uint256 valueBefore;
    }

    // Vault storage mirror. Do not insert module state in this section.
    string public name;
    string public symbol;
    uint256 public totalSupply;
    uint64 public lastRebalance;
    // Written by Vault (initialize, pause, lock-idle) through delegatecall; Slither cannot see that storage.
    // slither-disable-next-line uninitialized-state
    bool public paused;
    bool public filled;
    // Storage-layout mirror of Vault._initialized; required for safe delegatecall execution.
    // aderyn-fp-next-line(unused-state-variable)
    bool private _initialized;
    // Written by Vault (initialize, pause, lock-idle) through delegatecall; Slither cannot see that storage.
    // slither-disable-next-line uninitialized-state
    VaultConfig private _cfg;
    // Written by Vault (initialize, pause, lock-idle) through delegatecall; Slither cannot see that storage.
    // slither-disable-next-line uninitialized-state
    bytes32 private _poolId;
    // Written by Vault (initialize, pause, lock-idle) through delegatecall; Slither cannot see that storage.
    // slither-disable-next-line uninitialized-state
    IStrategy private _strategy;
    Band[] private _bands;
    /**
     * @dev Mirrored Vault share balances.
     */
    mapping(address account => uint256 balance) public balanceOf;
    /**
     * @dev Mirrored Vault share allowances.
     */
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    /**
     * @notice Restricts entry points to Vault storage context.
     * @dev Direct module calls cannot mutate a vault and are rejected.
     */
    // Kept as an explicit security boundary even though there is currently one external entry point.
    // aderyn-ignore-next-line(modifier-used-only-once)
    modifier onlyDelegated() {
        if (address(this) == _self) revert IVault.InvalidPlan();
        _;
    }

    /**
     * @notice Executes a complete keeper-triggered rebalance in the calling vault's storage context.
     * @dev Every external effect is inside the Vault's non-reentrant delegatecall. Any failed validation, swap,
     *      mint, custody check, or final loss check atomically restores the old positions and accounting.
     * @param p Keeper-proposed center and bounded loss tolerance.
     */
    // Runs under Vault's transient nonReentrant lock; the calls go to the immutable PositionManager and the fee
    // collector, and every state write after them is part of the same atomic rebalance.
    // slither-disable-next-line reentrancy-eth
    function rebalance(RebalanceParams calldata p) external onlyDelegated {
        RebalanceCache memory cache;
        cache.self = IVault(address(this));
        // All calls below execute under the delegating Vault's transient non-reentrancy lock.
        // aderyn-fp-next-line(reentrancy-state-change)
        cache.factory = cache.self.factory();
        // aderyn-fp-next-line(reentrancy-state-change)
        if (!IVaultFactory(cache.factory).isKeeper(msg.sender)) revert IVault.NotKeeper();
        if (paused) revert IsPaused();
        if (!_cfg.autoRebalance) revert IVault.AutoRebalanceOff();
        if (block.timestamp < uint256(lastRebalance) + COOLDOWN) revert IVault.CooldownActive();
        if (p.maxSlippageBps > MAX_SLIPPAGE_BPS) revert IVault.SlippageTooHigh();

        // aderyn-fp-next-line(reentrancy-state-change)
        IPriceGuard guard = cache.self.priceGuard();
        // aderyn-fp-next-line(reentrancy-state-change)
        (bool trusted,) = guard.isPriceTrusted(_cfg.poolKey);
        if (!trusted) revert PriceUntrusted();
        // aderyn-fp-next-line(reentrancy-state-change)
        cache.stateView = cache.self.stateView();
        // aderyn-fp-next-line(reentrancy-state-change)
        (cache.poolSqrtPrice, cache.tick,,) = cache.stateView.getSlot0(_poolId);
        // aderyn-fp-next-line(reentrancy-state-change)
        (bool act, bytes32 reason) = _strategy.checkTrigger(_cfg, cache.tick, _bands);
        cache.reason = reason;
        if (!act) revert IVault.NothingToDo();
        if (_absDiff(p.newCenterTick, cache.tick) > MAX_CENTER_DRIFT) revert IVault.CenterTooFar();

        // aderyn-fp-next-line(reentrancy-state-change)
        cache.referenceSqrtPrice = guard.referenceSqrtPriceX96(_cfg.poolKey);
        // aderyn-fp-next-line(reentrancy-state-change)
        cache.positionManager = cache.self.positionManager();
        cache.oldCenter = _currentCenter();
        cache.valueBefore = _valueRef(cache.referenceSqrtPrice, cache.stateView, cache.positionManager, cache.factory);
        (uint256 fee0, uint256 fee1) = _pendingTotal(cache.stateView, cache.positionManager);
        _burnAll(cache.positionManager);
        _payProtocolFee(cache.factory, fee0, fee1);

        // aderyn-fp-next-line(reentrancy-state-change)
        (cache.poolSqrtPrice, cache.tick,,) = cache.stateView.getSlot0(_poolId);
        // aderyn-fp-next-line(reentrancy-state-change)
        (trusted,) = guard.isPriceTrusted(_cfg.poolKey);
        if (!trusted) revert PriceUntrusted();
        // aderyn-fp-next-line(reentrancy-state-change)
        Plan memory plan = _strategy.plan(
            _cfg,
            cache.tick,
            p.newCenterTick,
            cache.poolSqrtPrice,
            _balance(_cfg.poolKey.currency0),
            _balance(_cfg.poolKey.currency1),
            cache.reason
        );
        _validatePlan(plan, cache.tick, cache.referenceSqrtPrice);

        delete _bands;
        if (plan.lockIdle) {
            filled = true;
            _finish(p, cache, cache.tick);
            return;
        }

        if (plan.needsSwap) {
            // aderyn-fp-next-line(reentrancy-state-change)
            _swap(cache.self.swapExecutor(), plan, p.maxSlippageBps, cache.referenceSqrtPrice);
        }
        // aderyn-fp-next-line(reentrancy-state-change)
        (cache.poolSqrtPrice,,,) = cache.stateView.getSlot0(_poolId);
        _mintBands(cache.self, cache.positionManager, cache.poolSqrtPrice, plan);
        filled = false;
        _finish(p, cache, _currentCenter());
    }

    /**
     * @notice Enforces final oracle-value loss and records successful completion.
     * @dev Uses the same reference price captured before removal.
     * @param p Keeper parameters containing the loss tolerance.
     * @param cache Rebalance cache holding the value before, the reference price, the dependencies and the previous
     *        center.
     * @param newCenter Actual center of the resulting bands, or the execution tick for a lock-idle plan.
     */
    function _finish(RebalanceParams calldata p, RebalanceCache memory cache, int24 newCenter) private {
        uint256 valueAfter = _valueRef(cache.referenceSqrtPrice, cache.stateView, cache.positionManager, cache.factory);
        if (valueAfter < Math.mulDiv(cache.valueBefore, BPS - p.maxSlippageBps, BPS)) revert IVault.LossTooLarge();
        lastRebalance = uint64(block.timestamp);
        emit IVault.Rebalanced(msg.sender, cache.oldCenter, newCenter, cache.valueBefore, valueAfter);
    }

    /**
     * @notice The center of the positions the vault holds now.
     * @dev Midpoint of the outer edges of the current bands, rounded toward negative infinity; the configured center
     *      when the vault holds no bands (before the first deposit or after a lock-idle rebalance). The configuration
     *      is immutable, so `_cfg.centerTick` alone would report the initial center forever.
     * @return center Current center tick.
     */
    function _currentCenter() private view returns (int24 center) {
        uint256 count = _bands.length;
        if (count == 0) return _cfg.centerTick;
        int256 sum = int256(_bands[0].tickLower) + int256(_bands[count - 1].tickUpper);
        int256 half = sum / 2;
        if (sum < 0 && half * 2 != sum) half -= 1;
        center = int24(half);
    }

    /**
     * @notice Independently validates every safety-relevant strategy plan field.
     * @dev Rejects malformed bands, weights, one-sided ranges, swaps, and lock-idle plans.
     * @param plan Untrusted strategy output.
     * @param tick Pool tick captured at the trigger.
     * @param referenceSqrtPrice Trusted oracle reference used for swap-size valuation.
     */
    function _validatePlan(Plan memory plan, int24 tick, uint160 referenceSqrtPrice) private view {
        if (plan.lockIdle) {
            if (
                plan.bands.length != 0 || plan.weightsBps.length != 0 || plan.needsSwap || plan.swapAmountIn != 0
                    || _cfg.strategy == Strategy.NormalLP || !_cfg.lockOnFill
            ) revert IVault.InvalidPlan();
            return;
        }
        uint256 count = plan.bands.length;
        if (count == 0 || count > MAX_BANDS || count != plan.weightsBps.length) revert IVault.InvalidPlan();
        int24 spacing = _cfg.poolKey.tickSpacing;
        if (spacing <= 0) revert IVault.InvalidPlan();
        uint256 totalWeight;
        bool below = (_cfg.strategy == Strategy.BuyTheDip) == _cfg.baseIsCurrency0;
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 i = 0; i < count; ++i) {
            Band memory band = plan.bands[i];
            if (
                band.tokenId != 0 || band.liquidity != 0 || band.tickUpper <= band.tickLower
                    || band.tickLower % spacing != 0 || band.tickUpper % spacing != 0 || band.tickLower < MIN_TICK
                    || band.tickUpper > MAX_TICK || (i != 0 && plan.bands[i - 1].tickUpper != band.tickLower)
            ) revert IVault.InvalidPlan();
            if (_cfg.strategy != Strategy.NormalLP) {
                if (below ? band.tickUpper > tick : band.tickLower <= tick) revert IVault.InvalidPlan();
            }
            if (plan.weightsBps[i] == 0) revert IVault.InvalidPlan();
            totalWeight += plan.weightsBps[i];
        }
        if (totalWeight != BPS) revert IVault.InvalidPlan();
        if (_cfg.strategy != Strategy.NormalLP && (plan.needsSwap || plan.swapAmountIn != 0)) {
            revert IVault.InvalidPlan();
        }
        if (plan.needsSwap != (plan.swapAmountIn != 0)) revert IVault.InvalidPlan();
        if (plan.needsSwap) {
            uint256 inputValue = plan.zeroForOne ? _value(plan.swapAmountIn, 0, referenceSqrtPrice) : plan.swapAmountIn;
            uint256 vaultValue =
                _value(_balance(_cfg.poolKey.currency0), _balance(_cfg.poolKey.currency1), referenceSqrtPrice);
            if (inputValue > Math.mulDiv(vaultValue, MAX_SWAP_BPS, BPS)) revert IVault.SwapTooLarge();
            Currency input = plan.zeroForOne ? _cfg.poolKey.currency0 : _cfg.poolKey.currency1;
            if (plan.swapAmountIn > _balance(input)) revert IVault.SwapTooLarge();
        }
    }

    /**
     * @notice Performs one exact-input swap through the executor.
     * @dev Native input is sent as value; ERC-20 input is pulled by the executor against an exact allowance that is
     *      reset to zero afterwards, so no approval is left standing.
     * @param executor Immutable swap executor.
     * @param plan Validated strategy plan.
     * @param maxSlippageBps Keeper tolerance bounded by the vault hard cap.
     * @param referenceSqrtPrice Trusted oracle reference.
     */
    // The ETH goes to the vault's immutable swap executor, read from the vault's own getter.
    // slither-disable-next-line arbitrary-send-eth
    function _swap(address executor, Plan memory plan, uint16 maxSlippageBps, uint160 referenceSqrtPrice) private {
        Currency input = plan.zeroForOne ? _cfg.poolKey.currency0 : _cfg.poolKey.currency1;
        uint256 minOut = _minimumOutput(plan.zeroForOne, plan.swapAmountIn, referenceSqrtPrice, maxSlippageBps);
        bool native = input.isNative();
        if (!native) IERC20(Currency.unwrap(input)).forceApprove(executor, plan.swapAmountIn);
        ISwapExecutor(executor).swapExactInput{value: native ? plan.swapAmountIn : 0}(
            _cfg.poolKey, plan.zeroForOne, plan.swapAmountIn, minOut
        );
        if (!native) IERC20(Currency.unwrap(input)).forceApprove(executor, 0);
    }

    /**
     * @notice Computes a reference output floor after pool fee and caller slippage.
     * @dev Floors each full-precision conversion conservatively.
     * @param zeroForOne Swap direction.
     * @param amountIn Exact input amount.
     * @param sqrtPrice Trusted square-root reference price.
     * @param slippageBps Accepted slippage in basis points.
     * @return minOut Minimum output passed to SwapExecutor.
     */
    function _minimumOutput(bool zeroForOne, uint256 amountIn, uint160 sqrtPrice, uint16 slippageBps)
        private
        view
        returns (uint256 minOut)
    {
        uint256 priceX96 = Math.mulDiv(sqrtPrice, sqrtPrice, Q96);
        if (priceX96 == 0 || _cfg.poolKey.fee >= FEE_DENOMINATOR) revert IVault.InvalidPlan();
        minOut = zeroForOne ? Math.mulDiv(amountIn, priceX96, Q96) : Math.mulDiv(amountIn, Q96, priceX96);
        minOut = Math.mulDiv(minOut, FEE_DENOMINATOR - _cfg.poolKey.fee, FEE_DENOMINATOR);
        minOut = Math.mulDiv(minOut, BPS - slippageBps, BPS);
    }

    /**
     * @notice Burns every recorded position and takes both currency credits.
     * @dev Pinned PositionManager burn removes all residual liquidity before destroying each NFT.
     * @param positionManager Trusted position manager.
     */
    function _burnAll(IPositionManagerLike positionManager) private {
        uint256 count = _bands.length;
        if (count == 0) return;
        bytes memory actions;
        bytes[] memory params = new bytes[](count + 1);
        for (uint256 i; i < count; ++i) {
            actions = abi.encodePacked(actions, PosmActions.BURN_POSITION);
            params[i] = abi.encode(_bands[i].tokenId, uint128(0), uint128(0), bytes(""));
        }
        actions = abi.encodePacked(actions, PosmActions.TAKE_PAIR);
        params[count] = abi.encode(_cfg.poolKey.currency0, _cfg.poolKey.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    /**
     * @notice Mints and records every validated target band.
     * @dev Sets the shared NFT callback gate, revokes allowances, and verifies custody before storage writes.
     * @param self Calling vault interface for immutable dependencies.
     * @param positionManager Trusted position manager.
     * @param sqrtPrice Current pool square-root price.
     * @param plan Validated strategy plan.
     */
    // The ETH goes to the vault's immutable PositionManager, read from the vault's own getter.
    // slither-disable-next-line arbitrary-send-eth
    function _mintBands(IVault self, IPositionManagerLike positionManager, uint160 sqrtPrice, Plan memory plan)
        private
    {
        uint256 amount0 = _balance(_cfg.poolKey.currency0);
        uint256 amount1 = _balance(_cfg.poolKey.currency1);
        uint128[] memory liquidity = _liquidityForPlan(sqrtPrice, plan, amount0, amount1);
        uint256 firstTokenId = positionManager.nextTokenId();
        IPermit2Like permit2 = self.permit2();
        _approve(permit2, positionManager, _cfg.poolKey.currency0, amount0);
        _approve(permit2, positionManager, _cfg.poolKey.currency1, amount1);
        _EXPECTING_NFT_SLOT.asBoolean().tstore(true);
        positionManager.modifyLiquidities{value: _cfg.poolKey.currency0.isNative() ? amount0 : 0}(
            _encodeMint(plan.bands, liquidity, amount0, amount1), block.timestamp
        );
        _EXPECTING_NFT_SLOT.asBoolean().tstore(false);
        _approve(permit2, positionManager, _cfg.poolKey.currency0, 0);
        _approve(permit2, positionManager, _cfg.poolKey.currency1, 0);
        // aderyn-ignore-next-line(costly-loop,require-revert-in-loop)
        for (uint256 i = 0; i < plan.bands.length; ++i) {
            uint256 tokenId = firstTokenId + i;
            if (positionManager.ownerOf(tokenId) != address(this)) revert InvalidPositionOwner();
            plan.bands[i].tokenId = tokenId;
            plan.bands[i].liquidity = liquidity[i];
            _bands.push(plan.bands[i]);
        }
    }

    /**
     * @notice Sizes weighted plan bands against current vault balances.
     * @dev Uses the scarcer currency and reserves settlement headroom.
     * @param sqrtPrice Current pool square-root price.
     * @param plan Validated target bands and weights.
     * @param amount0 Currency0 budget.
     * @param amount1 Currency1 budget.
     * @return liquidity Liquidity assigned to each target band.
     */
    function _liquidityForPlan(uint160 sqrtPrice, Plan memory plan, uint256 amount0, uint256 amount1)
        private
        pure
        returns (uint128[] memory liquidity)
    {
        uint256 unit0;
        uint256 unit1;
        uint256 count = plan.bands.length;
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 i = 0; i < count; ++i) {
            (uint256 a0, uint256 a1) = LiquidityMath.amountsForLiquidity(
                sqrtPrice,
                SqrtPriceMath.getSqrtPriceAtTick(plan.bands[i].tickLower),
                SqrtPriceMath.getSqrtPriceAtTick(plan.bands[i].tickUpper),
                _toUint128(uint256(plan.weightsBps[i]) * LIQUIDITY_PROBE)
            );
            unit0 += a0;
            unit1 += a1;
        }
        uint256 dust = SETTLEMENT_DUST_PER_BAND * count;
        uint256 budget0 = amount0 > dust ? amount0 - dust : 0;
        uint256 budget1 = amount1 > dust ? amount1 - dust : 0;
        uint256 scale = type(uint256).max;
        if (unit0 != 0) scale = Math.mulDiv(budget0, LIQUIDITY_PROBE, unit0);
        if (unit1 != 0) {
            uint256 scale1 = Math.mulDiv(budget1, LIQUIDITY_PROBE, unit1);
            if (scale1 < scale) scale = scale1;
        }
        if (scale == 0 || scale == type(uint256).max) revert IVault.InvalidPlan();
        liquidity = new uint128[](count);
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 i = 0; i < count; ++i) {
            uint128 raw = _toUint128(uint256(plan.weightsBps[i]) * scale);
            uint128 headroom = raw / LIQUIDITY_HEADROOM_DIVISOR;
            if (headroom == 0) headroom = 1;
            if (raw <= headroom) revert IVault.InvalidPlan();
            liquidity[i] = raw - headroom;
        }
    }

    /**
     * @notice Encodes mint, close-currency, and optional native sweep actions.
     * @dev Uses explicit liquidity and bounded settlement fields for every band.
     * @param bands_ Target bands.
     * @param liquidity Liquidity per band.
     * @param max0 Maximum currency0 spend.
     * @param max1 Maximum currency1 spend.
     * @return data PositionManager action payload.
     */
    function _encodeMint(Band[] memory bands_, uint128[] memory liquidity, uint256 max0, uint256 max1)
        private
        view
        returns (bytes memory data)
    {
        bool native = _cfg.poolKey.currency0.isNative() && max0 != 0;
        bytes memory actions;
        bytes[] memory params = new bytes[](bands_.length + 2 + (native ? 1 : 0));
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 i = 0; i < bands_.length; ++i) {
            actions = abi.encodePacked(actions, PosmActions.MINT_POSITION);
            params[i] = abi.encode(
                _cfg.poolKey,
                bands_[i].tickLower,
                bands_[i].tickUpper,
                uint256(liquidity[i]),
                _toUint128(max0),
                _toUint128(max1),
                address(this),
                bytes("")
            );
        }
        actions = abi.encodePacked(actions, PosmActions.CLOSE_CURRENCY, PosmActions.CLOSE_CURRENCY);
        params[bands_.length] = abi.encode(_cfg.poolKey.currency0);
        params[bands_.length + 1] = abi.encode(_cfg.poolKey.currency1);
        if (native) {
            actions = abi.encodePacked(actions, PosmActions.SWEEP);
            params[bands_.length + 2] = abi.encode(_cfg.poolKey.currency0, address(this));
        }
        data = abi.encode(actions, params);
    }

    /**
     * @notice Sets or revokes one exact Permit2 allowance for PositionManager.
     * @dev Native currencies require no approval and oversized values revert.
     * @param permit2 Permit2 dependency.
     * @param manager PositionManager spender.
     * @param currency Currency being approved.
     * @param amount Exact allowance, or zero to revoke.
     */
    function _approve(IPermit2Like permit2, IPositionManagerLike manager, Currency currency, uint256 amount) private {
        if (currency.isNative()) return;
        if (amount > type(uint160).max) revert PermitAmountTooLarge();
        permit2.approve(Currency.unwrap(currency), address(manager), uint160(amount), uint48(block.timestamp)); // aderyn-fp(unsafe-erc20-operation)
    }

    /**
     * @notice Pays the current protocol cut from pending trading fees only.
     * @dev Same rule as every M5 fee path: the factory fee is read without reverting (zero on failure or malformed
     *      data), clamped at 100 percent of the fees, and must be delivered (the rebalance reverts otherwise). It
     *      never includes principal.
     * @param factory Factory supplying fee configuration and collector.
     * @param fee0 Gross currency0 trading fees.
     * @param fee1 Gross currency1 trading fees.
     */
    function _payProtocolFee(address factory, uint256 fee0, uint256 fee1) private {
        uint256 feeBps = _protocolFeeBps(factory);
        uint256 protocolFee0 = Math.mulDiv(fee0, feeBps, BPS);
        uint256 protocolFee1 = Math.mulDiv(fee1, feeBps, BPS);
        if (protocolFee0 != 0 || protocolFee1 != 0) {
            uint256 word = _readFactoryWord(factory, IVaultFactory.feeCollector.selector);
            address collector = word >> 160 == 0 ? address(uint160(word)) : address(0);
            if (collector == address(0)) revert ZeroAddress();
            _cfg.poolKey.currency0.transfer(collector, protocolFee0); // aderyn-fp(unsafe-erc20-operation)
            _cfg.poolKey.currency1.transfer(collector, protocolFee1); // aderyn-fp(unsafe-erc20-operation)
        }
        emit IVault.FeesCollected(fee0, fee1, protocolFee0, protocolFee1);
    }

    /**
     * @notice Values idle balances, liquidity, and net pending fees at one oracle price.
     * @dev Pending protocol fees are excluded from shareholder value.
     * @param referenceSqrtPrice Fixed oracle square-root price.
     * @param stateView Trusted V4 state lens.
     * @param positionManager Trusted position manager.
     * @param factory Factory supplying the current protocol fee.
     * @return value_ Vault value denominated in currency1.
     */
    function _valueRef(
        uint160 referenceSqrtPrice,
        IStateViewLike stateView,
        IPositionManagerLike positionManager,
        address factory
    ) private view returns (uint256 value_) {
        uint256 amount0 = _balance(_cfg.poolKey.currency0);
        uint256 amount1 = _balance(_cfg.poolKey.currency1);
        (uint256 fees0, uint256 fees1) = _pendingTotal(stateView, positionManager);
        uint256 feeBps = _protocolFeeBps(factory);
        amount0 += fees0 - Math.mulDiv(fees0, feeBps, BPS);
        amount1 += fees1 - Math.mulDiv(fees1, feeBps, BPS);
        uint256 bandCount = _bands.length;
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 i = 0; i < bandCount; ++i) {
            (uint256 principal0, uint256 principal1) = LiquidityMath.amountsForLiquidity(
                referenceSqrtPrice,
                SqrtPriceMath.getSqrtPriceAtTick(_bands[i].tickLower),
                SqrtPriceMath.getSqrtPriceAtTick(_bands[i].tickUpper),
                _bands[i].liquidity
            );
            amount0 += principal0;
            amount1 += principal1;
        }
        value_ = _value(amount0, amount1, referenceSqrtPrice);
    }

    /**
     * @notice Reads the factory's protocol fee, clamped at 100 percent of fees.
     * @dev Never reverts: a reverting factory or a malformed return reads as zero, exactly as `Vault` and
     *      `VaultM5Module` read it, so valuation and collection agree on every path.
     * @param factory Trusted factory.
     * @return feeBps Effective protocol fee in basis points.
     */
    function _protocolFeeBps(address factory) private view returns (uint256 feeBps) {
        feeBps = _readFactoryWord(factory, IVaultFactory.protocolFeeBps.selector);
        if (feeBps > BPS) feeBps = BPS;
    }

    /**
     * @notice Reads one 32-byte word from a zero-argument factory getter without ever reverting.
     * @dev Returns zero when the call reverts or returns fewer than 32 bytes. The call and the size check are
     *      separate statements: Yul evaluates arguments right to left.
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
     * @notice Sums pending trading fees across all recorded positions.
     * @dev Uses wrapping fee-growth subtraction as Uniswap V4 does.
     * @param stateView Trusted V4 state lens.
     * @param positionManager Position owner in PoolManager accounting.
     * @return fee0 Pending currency0 fee.
     * @return fee1 Pending currency1 fee.
     */
    function _pendingTotal(IStateViewLike stateView, IPositionManagerLike positionManager)
        private
        view
        returns (uint256 fee0, uint256 fee1)
    {
        uint256 bandCount = _bands.length;
        for (uint256 i = 0; i < bandCount; ++i) {
            Band storage band = _bands[i];
            (uint128 liquidity, uint256 last0, uint256 last1) = stateView.getPositionInfo(
                _poolId, address(positionManager), band.tickLower, band.tickUpper, bytes32(band.tokenId)
            );
            (uint256 now0, uint256 now1) = stateView.getFeeGrowthInside(_poolId, band.tickLower, band.tickUpper);
            unchecked {
                fee0 += Math.mulDiv(liquidity, now0 - last0, Q128);
                fee1 += Math.mulDiv(liquidity, now1 - last1, Q128);
            }
        }
    }

    /**
     * @notice Converts two currency balances into currency1 value.
     * @dev Uses full-precision Q64.96 price arithmetic.
     * @param amount0 Currency0 amount.
     * @param amount1 Currency1 amount.
     * @param sqrtPrice Square-root price.
     * @return value_ Currency1-denominated value.
     */
    function _value(uint256 amount0, uint256 amount1, uint160 sqrtPrice) private pure returns (uint256 value_) {
        uint256 priceX96 = Math.mulDiv(sqrtPrice, sqrtPrice, Q96);
        value_ = amount1 + Math.mulDiv(amount0, priceX96, Q96);
    }

    /**
     * @notice Reads the vault's balance of one currency.
     * @dev Delegate execution makes address(this) the vault.
     * @param currency Currency to inspect.
     * @return amount Current vault balance.
     */
    function _balance(Currency currency) private view returns (uint256 amount) {
        return currency.balanceOfSelf();
    }

    /**
     * @notice Computes absolute distance between two ticks.
     * @dev Widens before subtraction to avoid int24 overflow.
     * @param a First tick.
     * @param b Second tick.
     * @return distance Absolute tick distance.
     */
    function _absDiff(int24 a, int24 b) private pure returns (uint256 distance) {
        int256 delta = int256(a) - int256(b);
        return uint256(delta < 0 ? -delta : delta);
    }

    /**
     * @notice Safely narrows an amount for pinned periphery fields.
     * @dev Reverts instead of truncating.
     * @param value Value to narrow.
     * @return casted Checked uint128 value.
     */
    function _toUint128(uint256 value) private pure returns (uint128 casted) {
        if (value > type(uint128).max) revert IVault.InvalidPlan();
        casted = uint128(value);
    }
}
