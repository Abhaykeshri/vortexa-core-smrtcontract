// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Band} from "../../src/libraries/Types.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";

/**
 * @dev Test-side model of the vault's deposit planning from the developer guide (sections 5.1 and 5.3): the bands
 *      carry relative liquidity weights, so token amounts are linear in a common scale `k`. Compute the unit
 *      amounts of the weighted bands, take the largest `k` the scarcer token allows, and derive each band's
 *      liquidity. Overflow reverts instead of truncating. Reusable as the oracle for the M4 vault tests.
 */
library DepositPlanner {
    uint128 internal constant UNIT = 1e18;

    /**
     * @dev The guide's method (5.3): the scarcer token fixes how much of every band's weighted unit amounts can be
     *      afforded; each band is allotted `unitAmount * weight * budget / total` of each token, rounded down, so the
     *      allotments sum to at most the budget; `liquidityForAmounts` then turns each allotment into liquidity and
     *      never needs more than it was given, so the plan cannot exceed either budget.
     *
     *      The scale is kept as the ratio `budget / total` and applied inside a single `mulDiv`. Rounding it to a
     *      fixed-point number first (as `planNaive` does) loses up to ~1e-5 of the budget at extreme prices, where
     *      the unit amounts are huge and the rounded scale is a small integer.
     */
    function plan(uint160 sp, Band[] memory bands, uint16[] memory weights, uint256 a0, uint256 a1)
        internal
        pure
        returns (uint128[] memory liquidities)
    {
        (uint256[] memory x, uint256[] memory y, uint256 totalX, uint256 totalY) = _unitAmounts(sp, bands, weights);
        liquidities = new uint128[](bands.length);
        if (totalX == 0 && totalY == 0) return liquidities;

        // token0 is the scarcer token when a0 / totalX <= a1 / totalY
        bool token0Limits = totalX > 0 && (totalY == 0 || Math.mulDiv(a0, totalY, totalX) <= a1);
        for (uint256 i; i < bands.length; ++i) {
            uint256 allot0;
            uint256 allot1;
            if (token0Limits) {
                allot0 = Math.mulDiv(x[i] * weights[i], a0, totalX);
                allot1 = Math.mulDiv(y[i] * weights[i], a0, totalX);
            } else {
                allot0 = Math.mulDiv(x[i] * weights[i], a1, totalY);
                allot1 = Math.mulDiv(y[i] * weights[i], a1, totalY);
            }
            liquidities[i] = _bandLiquidity(sp, bands[i], allot0, allot1);
        }
    }

    function _bandLiquidity(uint160 sp, Band memory band, uint256 allot0, uint256 allot1)
        private
        pure
        returns (uint128)
    {
        return LiquidityMath.liquidityForAmounts(
            sp,
            SqrtPriceMath.getSqrtPriceAtTick(band.tickLower),
            SqrtPriceMath.getSqrtPriceAtTick(band.tickUpper),
            allot0,
            allot1
        );
    }

    /**
     * @dev The naive method: scale a unit liquidity by the weights. The unit amounts are rounded down once and then
     *      multiplied up, so when a token's unit amount rounds to (or near) zero that token's budget is effectively
     *      ignored and the plan can need more than was deposited. Kept only to document and measure the hazard.
     */
    function planNaive(uint160 sp, Band[] memory bands, uint16[] memory weights, uint256 a0, uint256 a1)
        internal
        pure
        returns (uint128[] memory liquidities)
    {
        (,, uint256 totalX, uint256 totalY) = _unitAmounts(sp, bands, weights);
        uint256 s = _scale(totalX, totalY, a0, a1);
        liquidities = new uint128[](bands.length);
        if (s == type(uint256).max) return liquidities;
        for (uint256 i; i < bands.length; ++i) {
            liquidities[i] = SafeCast.toUint128(Math.mulDiv(uint256(UNIT) * weights[i], s, 1e18));
        }
    }

    function _unitAmounts(uint160 sp, Band[] memory bands, uint16[] memory weights)
        private
        pure
        returns (uint256[] memory x, uint256[] memory y, uint256 totalX, uint256 totalY)
    {
        x = new uint256[](bands.length);
        y = new uint256[](bands.length);
        for (uint256 i; i < bands.length; ++i) {
            (x[i], y[i]) = LiquidityMath.amountsForLiquidity(
                sp,
                SqrtPriceMath.getSqrtPriceAtTick(bands[i].tickLower),
                SqrtPriceMath.getSqrtPriceAtTick(bands[i].tickUpper),
                UNIT
            );
            totalX += x[i] * weights[i];
            totalY += y[i] * weights[i];
        }
    }

    /**
     * @dev Largest scale (1e18 fixed point) with scale * totalX <= a0 and scale * totalY <= a1.
     */
    function _scale(uint256 totalX, uint256 totalY, uint256 a0, uint256 a1) private pure returns (uint256 s) {
        s = type(uint256).max;
        if (totalX > 0) s = Math.min(s, Math.mulDiv(a0, 1e18, totalX));
        if (totalY > 0) s = Math.min(s, Math.mulDiv(a1, 1e18, totalY));
    }

    /**
     * @dev Token amounts the planned liquidities require at `sp`, using the (rounding-down) LiquidityMath.
     */
    function required(uint160 sp, Band[] memory bands, uint128[] memory liquidities)
        internal
        pure
        returns (uint256 total0, uint256 total1)
    {
        for (uint256 i; i < bands.length; ++i) {
            (uint256 x, uint256 y) = LiquidityMath.amountsForLiquidity(
                sp,
                SqrtPriceMath.getSqrtPriceAtTick(bands[i].tickLower),
                SqrtPriceMath.getSqrtPriceAtTick(bands[i].tickUpper),
                liquidities[i]
            );
            total0 += x;
            total1 += y;
        }
    }
}
