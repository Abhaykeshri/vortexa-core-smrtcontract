// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NormalLPMath} from "../../src/libraries/NormalLPMath.sol";
import {SwapMath} from "../../src/libraries/SwapMath.sol";
import {Currency, PoolKey} from "../../src/libraries/Types.sol";

contract M9MathHarness {
    function size(uint24 fee, uint160 price, uint256 amount0, uint256 amount1, uint256 unit0, uint256 unit1)
        external
        pure
        returns (uint256 amount, bool zeroForOne)
    {
        return NormalLPMath.sizeSwap(fee, price, amount0, amount1, unit0, unit1);
    }

    function floor(PoolKey memory key, bool zeroForOne, uint256 amount, uint160 price, uint256 slippage)
        external
        pure
        returns (uint256)
    {
        return SwapMath.minAmountOut(key, zeroForOne, amount, price, slippage);
    }
}

contract M9ZapMathFuzzTest is Test {
    M9MathHarness private harness = new M9MathHarness();

    function testFuzz_swapSizeNeverExceedsAvailableInput(
        uint96 raw0,
        uint96 raw1,
        uint96 rawUnit0,
        uint96 rawUnit1,
        uint24 rawFee,
        uint160 rawPrice
    ) public view {
        uint256 amount0 = bound(raw0, 0, 1e30);
        uint256 amount1 = bound(raw1, 0, 1e30);
        uint256 unit0 = bound(rawUnit0, 1, 1e24);
        uint256 unit1 = bound(rawUnit1, 1, 1e24);
        uint24 fee = uint24(bound(rawFee, 0, 100_000));
        uint160 price = uint160(bound(rawPrice, 1 << 72, 1 << 112));
        (uint256 swapAmount, bool zeroForOne) = harness.size(fee, price, amount0, amount1, unit0, unit1);
        assertLe(swapAmount, zeroForOne ? amount0 : amount1);
    }

    function testFuzz_oracleFloorTightensAsSlippageFalls(
        uint96 rawAmount,
        uint160 rawPrice,
        uint16 rawLoose,
        uint16 rawTight,
        bool zeroForOne
    ) public view {
        uint256 amount = bound(rawAmount, 1, 1e28);
        uint160 price = uint160(bound(rawPrice, 1 << 72, 1 << 112));
        uint16 loose = uint16(bound(rawLoose, 0, 100));
        uint16 tight = uint16(bound(rawTight, 0, loose));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: 500,
            tickSpacing: 10,
            hooks: address(0)
        });
        uint256 looseFloor = harness.floor(key, zeroForOne, amount, price, loose);
        uint256 tightFloor = harness.floor(key, zeroForOne, amount, price, tight);
        assertGe(tightFloor, looseFloor);
    }

    /**
     * Both libraries refuse inputs they cannot price: a zero or Q96-underflowing square-root price, a fee of 100%
     * or more, a zero target ratio, and a slippage above 100%.
     */
    function test_mathRejectsUnpriceableInputs() public {
        uint160 one = uint160(1 << 96);
        vm.expectRevert(NormalLPMath.InvalidRatio.selector);
        harness.size(500, 0, 1e18, 0, 1, 1);
        vm.expectRevert(NormalLPMath.InvalidRatio.selector);
        harness.size(1e6, one, 1e18, 0, 1, 1);
        vm.expectRevert(NormalLPMath.InvalidRatio.selector);
        harness.size(500, uint160(1 << 47), 1e18, 0, 1, 1);
        vm.expectRevert(NormalLPMath.InvalidRatio.selector);
        harness.size(500, one, 1e18, 0, 0, 0);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: 1e6,
            tickSpacing: 10,
            hooks: address(0)
        });
        vm.expectRevert(SwapMath.InvalidSwapMath.selector);
        harness.floor(key, true, 1e18, one, 100);
        key.fee = 500;
        vm.expectRevert(SwapMath.InvalidSwapMath.selector);
        harness.floor(key, true, 1e18, one, 10_001);
        vm.expectRevert(SwapMath.InvalidSwapMath.selector);
        harness.floor(key, true, 1e18, uint160(1 << 47), 100);
    }

    function testFuzz_decimalScaleDoesNotChangeSwapFraction(uint64 rawAmount, uint8 rawDecimals) public view {
        uint256 amount = bound(rawAmount, 1e6, 1e12);
        uint256 scale = 10 ** bound(rawDecimals, 0, 12);
        (uint256 baseSwap, bool baseDirection) = harness.size(500, uint160(1 << 96), amount, 0, 1, 1);
        (uint256 scaledSwap, bool scaledDirection) =
            harness.size(500, uint160(1 << 96), amount * scale, 0, scale, scale);
        assertEq(scaledDirection, baseDirection);
        assertApproxEqAbs(scaledSwap, baseSwap * scale, scale + 1);
    }
}
