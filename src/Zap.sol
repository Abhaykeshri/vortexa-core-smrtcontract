// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IShapeLibrary} from "./interfaces/IShapeLibrary.sol";
import {IZapFactory, IZapSwapExecutor, IZapVault} from "./interfaces/IZapDependencies.sol";
import {IZap} from "./interfaces/IZap.sol";
import {Band, Currency, DepositMode, PoolKey, Strategy, VaultConfig} from "./libraries/Types.sol";
import {CurrencyLib} from "./libraries/CurrencyLib.sol";
import {LiquidityMath} from "./libraries/LiquidityMath.sol";
import {NormalLPMath} from "./libraries/NormalLPMath.sol";
import {PoolIdLib} from "./libraries/PoolIdLib.sol";
import {SqrtPriceMath} from "./libraries/SqrtPriceMath.sol";

/**
 * @title Vortexa Single-Token Zap
 * @notice Converts one vault currency through the immutable SwapExecutor and deposits through `depositPair`.
 * @dev Supports only the three strategy contracts fixed in the constructor. Every balance and refund is measured
 *      relative to the balance present before the call, so unsolicited dust is never spent for or paid to a user.
 */
contract Zap is IZap, ReentrancyGuardTransient {
    using CurrencyLib for Currency;
    using PoolIdLib for PoolKey;
    using SafeERC20 for IERC20;

    /**
     * @dev Q64.96 fixed-point scale.
     */
    uint256 private constant Q96 = 1 << 96;
    /**
     * @dev Representative liquidity used to derive target token proportions.
     */
    uint256 private constant LIQUIDITY_PROBE = 1e18;
    /**
     * @dev Weight scale of the first-deposit probe (`LIQUIDITY_PROBE * PROBE_WEIGHT` per full-weight band).
     */
    uint256 private constant PROBE_WEIGHT = 1e4;
    /**
     * @dev Quote-only headroom divisor protecting against rounding optimism.
     */
    uint256 private constant LIQUIDITY_HEADROOM_DIVISOR = 1e8;
    /**
     * @dev Quote-only per-band raw-unit settlement reserve.
     */
    uint256 private constant SETTLEMENT_DUST_PER_BAND = 2;
    /**
     * @dev Quote-only token1-unit reserve for the vault's floored value differences.
     */
    uint256 private constant QUOTE_VALUE_RESERVE = 2;
    /**
     * @dev Quote-only relative margin (1 ppm) covering band-by-band rounding of the vault's own sizing.
     */
    uint256 private constant QUOTE_MARGIN_DIVISOR = 1e6;

    /**
     * @notice A required immutable dependency is zero, duplicated, or not deployed where deployment order allows.
     */
    error InvalidDependency();
    /**
     * @notice A zero input amount was supplied.
     */
    error ZeroAmount();
    /**
     * @notice The Zap itself cannot receive the minted shares.
     */
    error SelfReceiver();
    /**
     * @notice The vault strategy is not one of the three immutable audited strategy contracts.
     */
    error UnsupportedStrategy();
    /**
     * @notice Native value does not exactly match the selected native input.
     */
    error InvalidNativeValue();
    /**
     * @notice A token balance delta did not equal the amount crossing the trust boundary.
     */
    error TokenTransferShortfall();
    /**
     * @notice A balance fell below the pre-call dust snapshot.
     */
    error BalanceContaminated();
    /**
     * @notice The registered vault exposes an invalid or incompatible dependency graph or pool key.
     */
    error InvalidVaultConfiguration();
    /**
     * @notice A vault returned values inconsistent with the supplied deposit budget.
     */
    error InvalidDepositResult();
    /**
     * @notice Native ETH arrived from neither the executor nor a registered vault.
     */
    error InvalidEthSender();

    /**
     * @notice Emitted after a complete single-token deposit.
     * @param caller Account that supplied the input and received refunds.
     * @param vault Destination vault.
     * @param tokenIn Input token, or address zero for native ETH.
     * @param amountIn Exact input amount.
     * @param swapAmount Amount offered to the executor.
     * @param shares Shares minted to `receiver`.
     * @param receiver Share receiver.
     */
    event ZapDeposited(
        address indexed caller,
        address indexed vault,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 swapAmount,
        uint256 shares,
        address receiver
    );

    /**
     * @notice Emitted when call-local leftovers are returned.
     * @param caller Refund receiver and original payer.
     * @param vault Vault whose deposit produced the leftovers.
     * @param refund0 Currency0 returned.
     * @param refund1 Currency1 returned.
     */
    event ZapRefunded(address indexed caller, address indexed vault, uint256 refund0, uint256 refund1);

    /**
     * @notice Factory whose registry defines accepted vaults.
     */
    IZapFactory public immutable factory;
    /**
     * @notice Sole swap execution dependency.
     */
    IZapSwapExecutor public immutable executor;
    /**
     * @notice Approved NormalLP strategy identity.
     */
    address public immutable normalStrategy;
    /**
     * @notice Approved BuyTheDip strategy identity.
     */
    address public immutable buyTheDipStrategy;
    /**
     * @notice Approved SellThePump strategy identity.
     */
    address public immutable sellThePumpStrategy;

    /**
     * @notice In-memory swap and target-ratio plan.
     * @dev Prevents stack pressure while keeping all calculations call-local.
     */
    struct PlanCache {
        PoolKey key;
        uint160 sqrtPriceX96;
        uint256 unit0;
        uint256 unit1;
        uint256 swapAmount;
        uint256 bandCount;
        bool zeroForOne;
    }

    /**
     * @notice In-memory balance snapshots and validated deposit data.
     * @dev Separates pre-existing balances from assets received during the current call.
     */
    struct DepositCache {
        IZapVault vault;
        VaultConfig config;
        PlanCache plan;
        uint256 base0;
        uint256 base1;
        uint256 amount0;
        uint256 amount1;
    }

    /**
     * @notice Fixes the complete M9 dependency and supported-strategy set.
     * @dev Factory and executor may be precomputed addresses without code during cyclic deployment; post-deployment
     *      verification proves their bytecode and mutual wiring. Strategy contracts are deployed earlier and must
     *      already contain code.
     * @param factory_ Predicted or deployed VaultFactory.
     * @param executor_ Predicted or deployed SwapExecutor.
     * @param normalStrategy_ Audited NormalLP strategy.
     * @param buyTheDipStrategy_ Audited BuyTheDip strategy.
     * @param sellThePumpStrategy_ Audited SellThePump strategy.
     */
    constructor(
        IZapFactory factory_,
        IZapSwapExecutor executor_,
        address normalStrategy_,
        address buyTheDipStrategy_,
        address sellThePumpStrategy_
    ) {
        if (
            address(factory_) == address(0) || address(executor_) == address(0) || normalStrategy_.code.length == 0
                || buyTheDipStrategy_.code.length == 0 || sellThePumpStrategy_.code.length == 0
                || normalStrategy_ == buyTheDipStrategy_ || normalStrategy_ == sellThePumpStrategy_
                || buyTheDipStrategy_ == sellThePumpStrategy_
        ) revert InvalidDependency();
        factory = factory_;
        executor = executor_;
        normalStrategy = normalStrategy_;
        buyTheDipStrategy = buyTheDipStrategy_;
        sellThePumpStrategy = sellThePumpStrategy_;
    }

    /**
     * @inheritdoc IZap
     */
    function zapDeposit(
        address vault,
        address tokenIn,
        uint256 amountIn,
        uint256 minShares,
        uint16 maxSlippageBps,
        address receiver
    ) external payable nonReentrant returns (uint256 shares) {
        if (receiver == address(0)) revert ZeroReceiver();
        if (receiver == address(this)) revert SelfReceiver();
        if (amountIn == 0) revert ZeroAmount();
        if (maxSlippageBps > executor.MAX_SLIPPAGE_BPS()) revert SlippageTooHigh();

        DepositCache memory cache;
        cache.vault = _validatedVault(vault);
        cache.config = cache.vault.config();
        _validateInput(cache.config.poolKey, tokenIn, amountIn);
        _validateStrategy(cache.vault, cache.config.strategy);

        cache.base0 = _baseBalance(cache.config.poolKey.currency0, msg.value);
        cache.base1 = _baseBalance(cache.config.poolKey.currency1, 0);
        _collectInput(tokenIn, amountIn);

        cache.plan = _plan(cache.vault, cache.config, tokenIn, amountIn);
        if (cache.plan.swapAmount != 0) _executeSwap(cache.plan, maxSlippageBps);

        cache.amount0 = _callBalance(cache.config.poolKey.currency0, cache.base0);
        cache.amount1 = _callBalance(cache.config.poolKey.currency1, cache.base1);
        shares = _deposit(cache, vault, minShares, receiver);
        (uint256 refund0, uint256 refund1) = _refund(cache);

        if (refund0 != 0 || refund1 != 0) emit ZapRefunded(msg.sender, vault, refund0, refund1);
        emit ZapDeposited(msg.sender, vault, tokenIn, amountIn, cache.plan.swapAmount, shares, receiver);
    }

    /**
     * @inheritdoc IZap
     */
    function quoteZap(address vault, address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256 swapAmount, uint256 expectedShares)
    {
        if (amountIn == 0) revert ZeroAmount();
        IZapVault instance = _validatedVault(vault);
        VaultConfig memory config = instance.config();
        _validateToken(config.poolKey, tokenIn);
        _validateStrategy(instance, config.strategy);
        PlanCache memory plan = _plan(instance, config, tokenIn, amountIn);
        swapAmount = plan.swapAmount;

        (uint256 amount0, uint256 amount1) = _quotedBalances(instance, tokenIn, amountIn, plan);
        uint256 value = _estimatedDepositValue(plan, amount0, amount1);
        expectedShares = value == 0 ? 0 : instance.previewDeposit(value);
    }

    /**
     * @notice Validates a destination vault.
     * @dev Resolves a registered vault and proves its factory, executor and PriceGuard wiring.
     * @param vault Candidate vault address.
     * @return instance Validated vault interface.
     */
    function _validatedVault(address vault) private view returns (IZapVault instance) {
        if (!factory.isVault(vault)) revert UnknownVault();
        instance = IZapVault(vault);
        if (
            instance.factory() != address(factory) || instance.swapExecutor() != address(executor)
                || address(executor.factory()) != address(factory)
                || address(instance.priceGuard()) != address(executor.priceGuard())
        ) revert InvalidVaultConfiguration();
    }

    /**
     * @notice Validates the vault's strategy identity.
     * @dev Binds a supported strategy enum to the exact immutable implementation approved at deployment.
     * @param vault Validated destination vault.
     * @param kind Strategy discriminator stored by the vault.
     */
    function _validateStrategy(IZapVault vault, Strategy kind) private view {
        address actual = address(vault.strategy());
        if (kind == Strategy.NormalLP) {
            if (actual != normalStrategy) revert UnsupportedStrategy();
        } else if (kind == Strategy.BuyTheDip) {
            if (actual != buyTheDipStrategy) revert UnsupportedStrategy();
        } else if (kind == Strategy.SellThePump) {
            if (actual != sellThePumpStrategy) revert UnsupportedStrategy();
        } else {
            revert UnsupportedStrategy();
        }
    }

    /**
     * @notice Validates the caller's input and native value.
     * @dev Validates the input currency and exact native value semantics.
     * @param key Vault pool key.
     * @param tokenIn Caller-supplied input currency.
     * @param amountIn Exact input amount.
     */
    function _validateInput(PoolKey memory key, address tokenIn, uint256 amountIn) private view {
        _validateToken(key, tokenIn);
        bool nativeInput = tokenIn == address(0);
        if ((nativeInput && msg.value != amountIn) || (!nativeInput && msg.value != 0)) revert InvalidNativeValue();
    }

    /**
     * @notice Validates one pool currency address.
     * @dev Validates pool ordering, hook policy and membership of the input currency.
     * @param key Vault pool key.
     * @param tokenIn Input currency to validate.
     */
    function _validateToken(PoolKey memory key, address tokenIn) private pure {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        if (
            tokenIn != token0 && tokenIn != token1 || token0 == token1 || token1 == address(0) || token0 > token1
                || key.hooks != address(0) || key.tickSpacing <= 0
        ) revert BadToken();
    }

    /**
     * @notice Collects the exact requested input.
     * @dev Pulls an ERC-20 input and rejects any balance-delta shortfall; native input is already present.
     * @param tokenIn ERC-20 address or zero for native ETH.
     * @param amountIn Exact amount expected from the caller.
     */
    function _collectInput(address tokenIn, uint256 amountIn) private {
        if (tokenIn == address(0)) return;
        IERC20 token = IERC20(tokenIn);
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amountIn);
        if (token.balanceOf(address(this)) - beforeBalance != amountIn) revert TokenTransferShortfall();
    }

    /**
     * @notice Builds the supported strategy's deposit plan.
     * @dev Reproduces supported strategy deposit geometry and sizes any required swap.
     * @param vault Validated vault.
     * @param config Vault configuration.
     * @param tokenIn Input currency.
     * @param amountIn Input amount.
     * @return plan Call-local swap and ratio plan.
     */
    function _plan(IZapVault vault, VaultConfig memory config, address tokenIn, uint256 amountIn)
        private
        view
        returns (PlanCache memory plan)
    {
        plan.key = config.poolKey;
        (plan.sqrtPriceX96,,,) = vault.stateView().getSlot0(config.poolKey.toId());
        if (plan.sqrtPriceX96 == 0) revert InvalidVaultConfiguration();
        address token0 = Currency.unwrap(config.poolKey.currency0);
        uint256 amount0 = tokenIn == token0 ? amountIn : 0;
        uint256 amount1 = tokenIn == token0 ? 0 : amountIn;

        if (config.strategy == Strategy.NormalLP) {
            (plan.unit0, plan.unit1, plan.bandCount) = _normalUnits(vault, config, plan.sqrtPriceX96);
            (plan.swapAmount, plan.zeroForOne) =
                NormalLPMath.sizeSwap(config.poolKey.fee, plan.sqrtPriceX96, amount0, amount1, plan.unit0, plan.unit1);
        } else {
            bool below = (config.strategy == Strategy.BuyTheDip) == config.baseIsCurrency0;
            DepositMode mode = below ? DepositMode.Token1Only : DepositMode.Token0Only;
            plan.zeroForOne = mode == DepositMode.Token1Only;
            bool inputIs0 = tokenIn == token0;
            bool correctInput = mode == DepositMode.Token0Only ? inputIs0 : !inputIs0;
            plan.swapAmount = correctInput ? 0 : amountIn;
            (plan.unit0, plan.unit1, plan.bandCount) = _oneSidedUnits(vault, config, plan.sqrtPriceX96);
        }
    }

    /**
     * @notice Derives the NormalLP target token proportions.
     * @dev Aggregates representative token requirements across active or first-deposit NormalLP bands.
     * @param vault Validated vault.
     * @param config Vault configuration.
     * @param sqrtPriceX96 Current pool price.
     * @return unit0 Representative currency0 requirement.
     * @return unit1 Representative currency1 requirement.
     * @return bandCount Number of bands included.
     */
    function _normalUnits(IZapVault vault, VaultConfig memory config, uint160 sqrtPriceX96)
        private
        view
        returns (uint256 unit0, uint256 unit1, uint256 bandCount)
    {
        Band[] memory bandList = vault.bands();
        bandCount = bandList.length;
        if (bandCount == 0) {
            IShapeLibrary shapeLibrary = factory.shapes();
            uint16[] memory weights;
            (bandList, weights) = shapeLibrary.computeBands(
                config.shapeId, config.centerTick, config.ticksLeft, config.ticksRight, config.poolKey.tickSpacing
            );
            bandCount = bandList.length;
            // aderyn-ignore-next-line(require-revert-in-loop)
            for (uint256 i = 0; i < bandCount; ++i) {
                (uint256 a0, uint256 a1) = LiquidityMath.amountsForLiquidity(
                    sqrtPriceX96,
                    SqrtPriceMath.getSqrtPriceAtTick(bandList[i].tickLower),
                    SqrtPriceMath.getSqrtPriceAtTick(bandList[i].tickUpper),
                    uint128(uint256(weights[i]) * LIQUIDITY_PROBE)
                );
                unit0 += a0;
                unit1 += a1;
            }
        } else {
            (unit0, unit1) = _unitsFromActiveBands(bandList, sqrtPriceX96);
        }
    }

    /**
     * @notice Derives one-sided target token proportions.
     * @dev Aggregates representative requirements across active or planned one-sided bands.
     * @param vault Validated vault.
     * @param config Vault configuration.
     * @param sqrtPriceX96 Current pool price.
     * @return unit0 Representative currency0 requirement.
     * @return unit1 Representative currency1 requirement.
     * @return bandCount Number of bands included.
     */
    function _oneSidedUnits(IZapVault vault, VaultConfig memory config, uint160 sqrtPriceX96)
        private
        view
        returns (uint256 unit0, uint256 unit1, uint256 bandCount)
    {
        Band[] memory bandList = vault.bands();
        bandCount = bandList.length;
        if (bandCount == 0) {
            (, int24 tick,,) = vault.stateView().getSlot0(config.poolKey.toId());
            uint16[] memory weights;
            (bandList, weights) = _plannedOneSidedBands(config, tick);
            bandCount = bandList.length;
            // aderyn-ignore-next-line(require-revert-in-loop)
            for (uint256 i = 0; i < bandCount; ++i) {
                (uint256 a0, uint256 a1) = LiquidityMath.amountsForLiquidity(
                    sqrtPriceX96,
                    SqrtPriceMath.getSqrtPriceAtTick(bandList[i].tickLower),
                    SqrtPriceMath.getSqrtPriceAtTick(bandList[i].tickUpper),
                    uint128(uint256(weights[i]) * LIQUIDITY_PROBE)
                );
                unit0 += a0;
                unit1 += a1;
            }
        } else {
            (unit0, unit1) = _unitsFromActiveBands(bandList, sqrtPriceX96);
        }
    }

    /**
     * @notice Builds first-deposit one-sided bands.
     * @dev Mirrors the approved one-sided strategy's signed anchor and ShapeLibrary plan.
     * @param config Vault configuration.
     * @param tick Current pool tick.
     * @return bands Planned first-deposit bands.
     * @return weights Planned band weights.
     */
    function _plannedOneSidedBands(VaultConfig memory config, int24 tick)
        private
        view
        returns (Band[] memory bands, uint16[] memory weights)
    {
        int256 spacing = int256(config.poolKey.tickSpacing);
        bool below = (config.strategy == Strategy.BuyTheDip) == config.baseIsCurrency0;
        int256 anchor = below ? _floorToSpacing(tick, spacing) : _ceilToSpacing(int256(tick) + 1, spacing);
        if (anchor < type(int24).min || anchor > type(int24).max) revert InvalidVaultConfiguration();
        return factory.shapes()
            .computeBands(
                config.shapeId, int24(anchor), config.ticksLeft, config.ticksRight, config.poolKey.tickSpacing
            );
    }

    /**
     * @notice Derives target proportions from active bands.
     * @dev Totals the token requirements of a copy of the bands' liquidity scaled so the first band holds the
     *      first-deposit probe (`LIQUIDITY_PROBE * 10,000`), exactly as the vault sizes later deposits
     *      (`VaultM5Module.depositLiquidity`). The token amounts of small stored liquidity (a dust first deposit, or
     *      only the dead shares after a full exit) round down by up to a unit per band, which skewed the split: a
     *      1,000 USDC zap into a dead-shares vault left 0.146% of its input undeployed instead of 0.05%.
     * @param bands Active vault bands.
     * @param sqrtPriceX96 Current pool price.
     * @return unit0 Active currency0 requirement.
     * @return unit1 Active currency1 requirement.
     */
    function _unitsFromActiveBands(Band[] memory bands, uint160 sqrtPriceX96)
        private
        pure
        returns (uint256 unit0, uint256 unit1)
    {
        uint256 base = bands[0].liquidity;
        if (base == 0) revert InvalidVaultConfiguration();
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 i = 0; i < bands.length; ++i) {
            (uint256 a0, uint256 a1) = LiquidityMath.amountsForLiquidity(
                sqrtPriceX96,
                SqrtPriceMath.getSqrtPriceAtTick(bands[i].tickLower),
                SqrtPriceMath.getSqrtPriceAtTick(bands[i].tickUpper),
                SafeCast.toUint128(Math.mulDiv(bands[i].liquidity, LIQUIDITY_PROBE * PROBE_WEIGHT, base))
            );
            unit0 += a0;
            unit1 += a1;
        }
    }

    /**
     * @notice Executes the planned trusted swap.
     * @dev Executes the planned swap through the sole trusted executor with an oracle-derived floor.
     * @param plan Validated call-local plan.
     * @param maxSlippageBps Caller-selected tolerance within the executor cap.
     */
    function _executeSwap(PlanCache memory plan, uint16 maxSlippageBps) private {
        Currency input = plan.zeroForOne ? plan.key.currency0 : plan.key.currency1;
        Currency output = plan.zeroForOne ? plan.key.currency1 : plan.key.currency0;
        uint160 referencePrice = executor.priceGuard().referenceSqrtPriceX96(plan.key);
        uint256 minOut =
            executor.minOutFromReference(plan.key, plan.zeroForOne, plan.swapAmount, referencePrice, maxSlippageBps);
        uint256 outputBefore = output.balanceOfSelf();
        bool nativeInput = input.isNative();
        if (!nativeInput) IERC20(Currency.unwrap(input)).forceApprove(address(executor), plan.swapAmount);
        uint256 reported = executor.swapExactInput{value: nativeInput ? plan.swapAmount : 0}(
            plan.key, plan.zeroForOne, plan.swapAmount, minOut
        );
        if (!nativeInput) IERC20(Currency.unwrap(input)).forceApprove(address(executor), 0);
        uint256 outputAfter = output.balanceOfSelf();
        if (outputAfter < outputBefore || outputAfter - outputBefore != reported) revert TokenTransferShortfall();
    }

    /**
     * @notice Deposits the call-local pair into the vault.
     * @dev Grants exact temporary allowances and deposits both call-local currency balances.
     * @param cache Validated balances and configuration.
     * @param vault Destination vault address.
     * @param minShares Minimum acceptable shares.
     * @param receiver Share receiver.
     * @return shares Shares reported by the vault.
     */
    // The ETH goes only to a factory-registered vault whose factory, executor and PriceGuard `_validatedVault` checked.
    // slither-disable-next-line arbitrary-send-eth
    function _deposit(DepositCache memory cache, address vault, uint256 minShares, address receiver)
        private
        returns (uint256 shares)
    {
        _approveVault(cache.config.poolKey, vault, cache.amount0, cache.amount1);
        uint256 used0;
        uint256 used1;
        // `_validatedVault` binds this interface to the factory registry before `_deposit` is reached.
        // slither-disable-next-line arbitrary-send-eth
        (shares, used0, used1) = cache.vault
        .depositPair{value: cache.config.poolKey.currency0.isNative() ? cache.amount0 : 0}(
            cache.amount0, cache.amount1, minShares, receiver
        );
        _revokeVault(cache.config.poolKey, vault, cache.amount0, cache.amount1);
        if (shares < minShares || used0 > cache.amount0 || used1 > cache.amount1) revert InvalidDepositResult();
    }

    /**
     * @notice Refunds all call-local leftovers.
     * @dev Returns only current-call leftovers and proves pre-existing balances remain untouched.
     * @param cache Initial balance snapshots and pool currencies.
     * @return refund0 Currency0 returned to the caller.
     * @return refund1 Currency1 returned to the caller.
     */
    function _refund(DepositCache memory cache) private returns (uint256 refund0, uint256 refund1) {
        refund0 = _callBalance(cache.config.poolKey.currency0, cache.base0);
        refund1 = _callBalance(cache.config.poolKey.currency1, cache.base1);
        cache.config.poolKey.currency1.transfer(msg.sender, refund1); // aderyn-fp(unsafe-erc20-operation)
        cache.config.poolKey.currency0.transfer(msg.sender, refund0); // aderyn-fp(unsafe-erc20-operation)
        if (
            cache.config.poolKey.currency0.balanceOfSelf() != cache.base0
                || cache.config.poolKey.currency1.balanceOfSelf() != cache.base1
        ) revert BalanceContaminated();
    }

    /**
     * @notice Estimates post-swap balances for a quote.
     * @dev Applies the executor hard-cap floor to estimate conservative post-swap token balances.
     * @param vault Validated vault supplying the trusted reference price.
     * @param tokenIn Quoted input currency.
     * @param amountIn Quoted input amount.
     * @param plan Swap and ratio plan.
     * @return amount0 Estimated currency0 balance.
     * @return amount1 Estimated currency1 balance.
     */
    function _quotedBalances(IZapVault vault, address tokenIn, uint256 amountIn, PlanCache memory plan)
        private
        view
        returns (uint256 amount0, uint256 amount1)
    {
        bool inputIs0 = tokenIn == Currency.unwrap(plan.key.currency0);
        amount0 = inputIs0 ? amountIn : 0;
        amount1 = inputIs0 ? 0 : amountIn;
        if (plan.swapAmount == 0) return (amount0, amount1);
        uint160 referencePrice = vault.priceGuard().referenceSqrtPriceX96(plan.key);
        uint256 amountOut = executor.minOutFromReference(
            plan.key, plan.zeroForOne, plan.swapAmount, referencePrice, uint16(executor.MAX_SLIPPAGE_BPS())
        );
        if (plan.zeroForOne) {
            amount0 -= plan.swapAmount;
            amount1 += amountOut;
        } else {
            amount1 -= plan.swapAmount;
            amount0 += amountOut;
        }
    }

    /**
     * @notice Estimates the portion of balances deployable as liquidity.
     * @dev Estimates deployable token1 value with per-band dust and liquidity-rounding headroom, then discounts the
     *      per-band settlement reserve from each used leg so the quote never exceeds what the vault credits.
     * @param plan Target token proportions and current price.
     * @param amount0 Estimated available currency0.
     * @param amount1 Estimated available currency1.
     * @return value Conservative token1-denominated value.
     */
    function _estimatedDepositValue(PlanCache memory plan, uint256 amount0, uint256 amount1)
        private
        pure
        returns (uint256 value)
    {
        uint256 dust = plan.bandCount * SETTLEMENT_DUST_PER_BAND;
        uint256 scale = type(uint256).max;
        if (plan.unit0 != 0) {
            uint256 budget0 = amount0 > dust ? amount0 - dust : 0;
            scale = Math.mulDiv(budget0, LIQUIDITY_PROBE, plan.unit0);
        }
        if (plan.unit1 != 0) {
            uint256 budget1 = amount1 > dust ? amount1 - dust : 0;
            uint256 scale1 = Math.mulDiv(budget1, LIQUIDITY_PROBE, plan.unit1);
            if (scale1 < scale) scale = scale1;
        }
        if (scale == 0 || scale == type(uint256).max) return 0;
        uint256 headroom = scale / LIQUIDITY_HEADROOM_DIVISOR;
        if (headroom == 0) headroom = 1;
        if (scale <= headroom) return 0;
        scale -= headroom;
        uint256 used0 = Math.mulDiv(plan.unit0, scale, LIQUIDITY_PROBE);
        uint256 used1 = Math.mulDiv(plan.unit1, scale, LIQUIDITY_PROBE);
        // The vault credits the minted position at its token amounts rounded down, up to a raw unit per band and
        // token; without a swap (whose worst-case floor otherwise dominates) that rounding alone made the quote
        // promise a few raw units more than the deposit mints. Discount the same per-band reserve from each leg.
        used0 = used0 > dust ? used0 - dust : 0;
        used1 = used1 > dust ? used1 - dust : 0;
        uint256 priceX96 = Math.mulDiv(plan.sqrtPriceX96, plan.sqrtPriceX96, Q96);
        value = Math.mulDiv(used0, priceX96, Q96) + used1;
        // The vault credits a difference of separately floored valuations of liquidity it sizes band by band, a
        // little below one floored valuation of the same amounts: keep a 1 ppm margin plus a couple of token1 units
        // so the quote never exceeds what the deposit mints.
        uint256 margin = value / QUOTE_MARGIN_DIVISOR + QUOTE_VALUE_RESERVE;
        value = value > margin ? value - margin : 0;
    }

    /**
     * @notice Approves exact vault input amounts.
     * @dev Grants the vault exact non-native allowances.
     * @param key Vault pool key.
     * @param vault Destination vault.
     * @param amount0 Currency0 allowance amount.
     * @param amount1 Currency1 allowance amount.
     */
    function _approveVault(PoolKey memory key, address vault, uint256 amount0, uint256 amount1) private {
        if (!key.currency0.isNative() && amount0 != 0) {
            IERC20(Currency.unwrap(key.currency0)).forceApprove(vault, amount0);
        }
        if (amount1 != 0) IERC20(Currency.unwrap(key.currency1)).forceApprove(vault, amount1);
    }

    /**
     * @notice Clears vault input allowances.
     * @dev Revokes every vault allowance granted by the current call.
     * @param key Vault pool key.
     * @param vault Destination vault.
     * @param amount0 Original currency0 allowance amount.
     * @param amount1 Original currency1 allowance amount.
     */
    function _revokeVault(PoolKey memory key, address vault, uint256 amount0, uint256 amount1) private {
        if (!key.currency0.isNative() && amount0 != 0) IERC20(Currency.unwrap(key.currency0)).forceApprove(vault, 0);
        if (amount1 != 0) IERC20(Currency.unwrap(key.currency1)).forceApprove(vault, 0);
    }

    /**
     * @notice Returns a protected pre-call balance snapshot.
     * @dev Snapshots a pre-call balance by excluding native value already credited to this call.
     * @param currency Currency to inspect.
     * @param nativeValue Native value credited at call entry, or zero for ERC-20.
     * @return base Pre-existing balance.
     */
    function _baseBalance(Currency currency, uint256 nativeValue) private view returns (uint256 base) {
        uint256 balance = currency.balanceOfSelf();
        if (balance < nativeValue) revert BalanceContaminated();
        base = balance - nativeValue;
    }

    /**
     * @notice Returns the balance attributable to this call.
     * @dev Returns the balance attributable to the current call above its protected base.
     * @param currency Currency to inspect.
     * @param base Protected pre-existing balance.
     * @return amount Current-call balance.
     */
    function _callBalance(Currency currency, uint256 base) private view returns (uint256 amount) {
        uint256 balance = currency.balanceOfSelf();
        if (balance < base) revert BalanceContaminated();
        amount = balance - base;
    }

    /**
     * @notice Floors a tick to its spacing.
     * @dev Rounds a signed tick toward negative infinity to a spacing boundary.
     * @param tick Tick to align.
     * @param spacing Positive tick spacing.
     * @return result Aligned floor.
     */
    function _floorToSpacing(int256 tick, int256 spacing) private pure returns (int256 result) {
        result = tick / spacing;
        if (tick < 0 && tick % spacing != 0) --result;
        result *= spacing;
    }

    /**
     * @notice Ceils a tick to its spacing.
     * @dev Rounds a signed tick toward positive infinity to a spacing boundary.
     * @param tick Tick to align.
     * @param spacing Positive tick spacing.
     * @return result Aligned ceiling.
     */
    function _ceilToSpacing(int256 tick, int256 spacing) private pure returns (int256 result) {
        result = -_floorToSpacing(-tick, spacing);
    }

    /**
     * @notice Accepts native swap output or a native vault refund during `zapDeposit`.
     * @dev Forced ETH remains isolated as pre-existing dust by the per-call balance snapshots.
     */
    receive() external payable {
        if (msg.sender != address(executor) && !factory.isVault(msg.sender)) revert InvalidEthSender();
    }
}
