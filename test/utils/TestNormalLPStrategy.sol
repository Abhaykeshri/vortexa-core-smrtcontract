// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IShapeLibrary} from "../../src/interfaces/IShapeLibrary.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {Band, DepositMode, Plan, VaultConfig} from "../../src/libraries/Types.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";

/**
 * @title Normal LP planner for rebalance tests
 * @notice Stand-in for the milestone 7 Normal LP strategy: re-centres the vault's shape on the keeper's center with
 *         the real `ShapeLibrary`, and sizes the swap with the guide 8.3 formula
 *         `k = V / (X * P + Y)`, `target0 = k X`, buying the scarce token with a fee gross-up.
 * @dev The trigger is a switch so tests decide when a rebalance is due. Deposit setup (`reason == "NONE"`) returns
 *      geometry only; executable first-deposit swaps are covered with the production NormalLPStrategy integration.
 */
contract TestNormalLPStrategy is IStrategy {
    uint256 internal constant PROBE = 1e18;
    uint256 internal constant Q96 = 1 << 96;

    IShapeLibrary public immutable shapes;
    bool public triggered = true;

    constructor(IShapeLibrary shapes_) {
        shapes = shapes_;
    }

    function setTriggered(bool on) external {
        triggered = on;
    }

    function canDeposit(VaultConfig calldata, int24, Band[] calldata) external pure returns (bool) {
        return true;
    }

    function validateConfig(VaultConfig calldata, int24) external pure {}

    function depositMode(VaultConfig calldata) external pure returns (DepositMode) {
        return DepositMode.BothTokens;
    }

    function checkTrigger(VaultConfig calldata, int24, Band[] calldata) external view returns (bool, bytes32) {
        return (triggered, bytes32("DRIFT"));
    }

    function plan(
        VaultConfig calldata config,
        int24,
        int24 newCenterTick,
        uint160 sqrtPriceX96,
        uint256 amount0,
        uint256 amount1,
        bytes32 reason
    ) external view returns (Plan memory p) {
        (p.bands, p.weightsBps) = shapes.computeBands(
            config.shapeId, newCenterTick, config.ticksLeft, config.ticksRight, config.poolKey.tickSpacing
        );
        if (reason != bytes32("NONE")) {
            _sizeSwap(p, config.poolKey.fee, sqrtPriceX96, amount0, amount1);
        }
    }

    function _sizeSwap(Plan memory p, uint24 fee, uint160 sqrtPriceX96, uint256 amount0, uint256 amount1)
        internal
        pure
    {
        (uint256 x, uint256 y) = _units(p, sqrtPriceX96);
        uint256 priceX96 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        uint256 target0 =
            Math.mulDiv(x, Math.mulDiv(amount0, priceX96, Q96) + amount1, Math.mulDiv(x, priceX96, Q96) + y);
        if (target0 > amount0) {
            uint256 deficitValue = Math.mulDiv(target0 - amount0, priceX96, Q96);
            p.swapAmountIn = Math.mulDiv(deficitValue, 1e6, 1e6 - fee);
            if (p.swapAmountIn > amount1) p.swapAmountIn = amount1;
            p.zeroForOne = false;
        } else {
            p.swapAmountIn = amount0 - target0;
            p.zeroForOne = true;
        }
        p.needsSwap = p.swapAmountIn != 0;
    }

    function _units(Plan memory p, uint160 sqrtPriceX96) internal pure returns (uint256 x, uint256 y) {
        for (uint256 i; i < p.bands.length; ++i) {
            (uint256 a0, uint256 a1) = LiquidityMath.amountsForLiquidity(
                sqrtPriceX96,
                SqrtPriceMath.getSqrtPriceAtTick(p.bands[i].tickLower),
                SqrtPriceMath.getSqrtPriceAtTick(p.bands[i].tickUpper),
                uint128(uint256(p.weightsBps[i]) * PROBE)
            );
            x += a0;
            y += a1;
        }
    }
}
