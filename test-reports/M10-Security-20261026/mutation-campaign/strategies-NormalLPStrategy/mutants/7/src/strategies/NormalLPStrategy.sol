// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IShapeLibrary} from "../interfaces/IShapeLibrary.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {Band, DepositMode, Plan, Strategy, VaultConfig} from "../libraries/Types.sol";
import {LiquidityMath} from "../libraries/LiquidityMath.sol";
import {NormalLPMath} from "../libraries/NormalLPMath.sol";
import {SqrtPriceMath} from "../libraries/SqrtPriceMath.sol";
import {StrategyBase} from "./StrategyBase.sol";

/**
 * @title Normal LP Strategy
 * @notice Stateless two-sided liquidity planner with out-of-range and edge-drift triggers.
 * @dev Swap sizing follows the M6 unit-liquidity target formula and includes pool-fee gross-up.
 */
contract NormalLPStrategy is StrategyBase, IStrategy {
    /**
     * @notice Fixed-point denominator used by Uniswap square-root prices.
     */
    uint256 internal constant Q96 = 1 << 96;
    /**
     * @notice Probe liquidity used to derive the shape's token ratio.
     */
    uint256 internal constant LIQUIDITY_PROBE = 1e18;
    /**
     * @notice Uniswap fee denominator.
     */
    uint256 internal constant FEE_DENOMINATOR = 1e6;
    /**
     * @notice The pool price or fee cannot support swap sizing.
     */
    error InvalidPrice();

    /**
     * @notice Initializes the immutable ShapeLibrary dependency.
     * @dev Reverts through StrategyBase when the dependency is zero.
     * @param shapes_ Deployed ShapeLibrary.
     */
    constructor(IShapeLibrary shapes_) StrategyBase(shapes_) {}

    /**
     * @inheritdoc IStrategy
     */
    function validateConfig(VaultConfig calldata config, int24) external view {
        if (config.strategy != Strategy.NormalLP) revert InvalidStrategy();
        if (config.poolKey.tickSpacing <= 0 || config.ticksLeft <= 0 || config.ticksRight <= 0) {
            revert InvalidRange();
        }
        if (config.shapeId == 5 || config.shapeId == 6 || !shapes.isValidShape(config.shapeId)) {
            revert InvalidShape();
        }
        if (config.driftTicks >= uint24(config.ticksLeft) || config.driftTicks >= uint24(config.ticksRight)) {
            revert InvalidDrift();
        }
        if (config.trailTicks != 0 || config.lockOnFill) revert InvalidTrail();
        // This call validates shape feasibility by reverting; its generated arrays are not needed here.
        // aderyn-fp-next-line(unchecked-return)
        shapes.computeBands(
            config.shapeId, config.centerTick, config.ticksLeft, config.ticksRight, config.poolKey.tickSpacing
        );
    }

    /**
     * @inheritdoc IStrategy
     */
    function canDeposit(VaultConfig calldata, int24, Band[] calldata) external pure returns (bool) {
        return true;
    }

    /**
     * @inheritdoc IStrategy
     */
    function depositMode(VaultConfig calldata) external pure returns (DepositMode) {
        return DepositMode.BothTokens;
    }

    /**
     * @inheritdoc IStrategy
     */
    function checkTrigger(VaultConfig calldata config, int24 tick, Band[] calldata bands)
        external
        pure
        returns (bool needed, bytes32 reason)
    {
        if (bands.length == 0) return (false, NONE);
        (int24 lower, int24 upper) = _edges(bands);
        if (tick < lower || tick >= upper) return (true, OUT_OF_RANGE);
        uint256 drift = config.driftTicks;
        if (
            drift != 0
                && (int256(tick) - int256(lower) < int256(drift) || int256(upper) - int256(tick) <= int256(drift))
        ) return (true, DRIFT);
        return (false, NONE);
    }

    /**
     * @inheritdoc IStrategy
     */
    function plan(
        VaultConfig calldata config,
        int24,
        int24 newCenterTick,
        uint160 sqrtPriceX96,
        uint256 amount0,
        uint256 amount1,
        bytes32
    ) external view returns (Plan memory plan_) {
        (plan_.bands, plan_.weightsBps) = shapes.computeBands(
            config.shapeId, newCenterTick, config.ticksLeft, config.ticksRight, config.poolKey.tickSpacing
        );
        _sizeSwap(plan_, config.poolKey.fee, sqrtPriceX96, amount0, amount1);
    }

    /**
     * @notice Sizes the swap needed to approach the target unit-liquidity token ratio.
     * @dev Uses full-precision arithmetic and rounds deficit purchases upward before capping them to holdings.
     * @param plan_ Plan whose bands and weights define the target ratio.
     * @param fee Pool fee in millionths.
     * @param sqrtPriceX96 Current square-root price.
     * @param amount0 Available currency0.
     * @param amount1 Available currency1.
     */
    function _sizeSwap(Plan memory plan_, uint24 fee, uint160 sqrtPriceX96, uint256 amount0, uint256 amount1)
        private
        pure
    {
        if (sqrtPriceX96 == 0 || fee >= FEE_DENOMINATOR) revert InvalidPrice();
        (uint256 unit0, uint256 unit1) = _unitAmounts(plan_, sqrtPriceX96);
        uint256 priceX96 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        if (priceX96 == 0 || Math.mulDiv(unit0, priceX96, Q96) + unit1 == 0) revert InvalidPrice();
        (plan_.swapAmountIn, plan_.zeroForOne) =
            NormalLPMath.sizeSwap(fee, sqrtPriceX96, amount0, amount1, unit0, unit1);
        /// AssignmentMutation(`plan_.swapAmountIn != 0` |==> `true`) of: `plan_.needsSwap = plan_.swapAmountIn != 0;`
        plan_.needsSwap = true;
    }

    /**
     * @notice Computes aggregate token requirements for weighted probe liquidity.
     * @dev Each basis-point weight scales the common probe before token amounts are summed.
     * @param plan_ Plan containing target bands and weights.
     * @param sqrtPriceX96 Current square-root price.
     * @return unit0 Currency0 required by the weighted probe.
     * @return unit1 Currency1 required by the weighted probe.
     */
    function _unitAmounts(Plan memory plan_, uint160 sqrtPriceX96) private pure returns (uint256 unit0, uint256 unit1) {
        // aderyn-ignore-next-line(require-revert-in-loop)
        for (uint256 i = 0; i < plan_.bands.length; ++i) {
            (uint256 amount0, uint256 amount1) = LiquidityMath.amountsForLiquidity(
                sqrtPriceX96,
                SqrtPriceMath.getSqrtPriceAtTick(plan_.bands[i].tickLower),
                SqrtPriceMath.getSqrtPriceAtTick(plan_.bands[i].tickUpper),
                uint128(uint256(plan_.weightsBps[i]) * LIQUIDITY_PROBE)
            );
            unit0 += amount0;
            unit1 += amount1;
        }
    }
}
