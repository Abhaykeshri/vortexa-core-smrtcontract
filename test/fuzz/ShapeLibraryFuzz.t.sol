// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {Band} from "../../src/libraries/Types.sol";

contract ShapeLibraryFuzzTest is Test {
    ShapeLibrary internal shapes;
    int256 private constant MIN_TICK = -887272;
    int256 private constant MAX_TICK = 887272;
    uint16 private constant TOTAL_WEIGHT_BPS = 10_000;

    function setUp() public {
        shapes = new ShapeLibrary();
    }

    function testFuzz_computeBands_properties(
        uint8 rawShape,
        int24 center,
        int24 rawLeft,
        int24 rawRight,
        uint16 rawSpacing
    ) public view {
        uint8 shapeId = uint8(bound(rawShape, 0, 7));
        int24 spacing = int24(uint24(bound(rawSpacing, 1, 200)));
        int24 left = int24(bound(rawLeft, 0, 20_000));
        int24 right = int24(bound(rawRight, 0, 20_000));

        try shapes.computeBands(shapeId, center, left, right, spacing) returns (
            Band[] memory bands, uint16[] memory weights
        ) {
            _assertInvariants(bands, weights, spacing);
            (Band[] memory expectedBands, uint16[] memory expectedWeights) =
                _referenceCompute(shapeId, center, left, right, spacing);
            assertEq(keccak256(abi.encode(bands)), keccak256(abi.encode(expectedBands)));
            assertEq(keccak256(abi.encode(weights)), keccak256(abi.encode(expectedWeights)));
            _assertDeterministic(shapeId, center, left, right, spacing, bands, weights);
        } catch {}
    }

    function testFuzz_invalid_inputs_revert(uint8 invalidShape, int24 center, int24 left, int24 right, int24 spacing)
        public
    {
        invalidShape = uint8(bound(invalidShape, 8, type(uint8).max));
        vm.expectRevert();
        shapes.computeBands(invalidShape, center, left, right, spacing);

        vm.expectRevert();
        shapes.computeBands(0, center, left, right, 0);

        int24 negativeLeft = int24(bound(left, type(int24).min, -1));
        vm.expectRevert();
        shapes.computeBands(0, center, negativeLeft, right, 1);

        int24 negativeRight = int24(bound(right, type(int24).min, -1));
        vm.expectRevert();
        shapes.computeBands(0, center, left, negativeRight, 1);
    }

    function _assertInvariants(Band[] memory bands, uint16[] memory weights, int24 spacing) private pure {
        assertGe(bands.length, 1);
        assertLe(bands.length, 5);
        assertEq(bands.length, weights.length);

        int24 minUsable = int24(_ceilDiv(MIN_TICK, spacing) * spacing);
        int24 maxUsable = int24(_floorDiv(MAX_TICK, spacing) * spacing);
        uint256 sum;
        for (uint256 i; i < bands.length; ++i) {
            assertLt(bands[i].tickLower, bands[i].tickUpper);
            assertEq(bands[i].tickLower % spacing, 0);
            assertEq(bands[i].tickUpper % spacing, 0);
            assertGe(bands[i].tickLower, minUsable);
            assertLe(bands[i].tickUpper, maxUsable);
            if (i > 0) assertEq(bands[i - 1].tickUpper, bands[i].tickLower);
            assertEq(bands[i].tokenId, 0);
            assertEq(bands[i].liquidity, 0);
            sum += weights[i];
        }
        assertEq(sum, 10_000);
    }

    function _assertDeterministic(
        uint8 shapeId,
        int24 center,
        int24 left,
        int24 right,
        int24 spacing,
        Band[] memory bands,
        uint16[] memory weights
    ) private view {
        (Band[] memory bandsAgain, uint16[] memory weightsAgain) =
            shapes.computeBands(shapeId, center, left, right, spacing);
        assertEq(keccak256(abi.encode(bands)), keccak256(abi.encode(bandsAgain)));
        assertEq(keccak256(abi.encode(weights)), keccak256(abi.encode(weightsAgain)));
    }

    function _referenceCompute(uint8 shapeId, int24 center, int24 left, int24 right, int24 spacing)
        private
        pure
        returns (Band[] memory bands, uint16[] memory weights)
    {
        int256 spacing256 = int256(spacing);
        int256 lower;
        int256 upper;
        if (shapeId == 5) {
            lower = _roundDownToSpacing(center, spacing256);
            upper = lower + spacing256;
        } else if (shapeId == 6) {
            lower = MIN_TICK;
            upper = MAX_TICK;
        } else {
            lower = _roundDownToSpacing(int256(center) - int256(left), spacing256);
            upper = _roundUpToSpacing(int256(center) + int256(right), spacing256);
        }

        int256 minUsable = _roundUpToSpacing(MIN_TICK, spacing256);
        int256 maxUsable = _roundDownToSpacing(MAX_TICK, spacing256);
        lower = lower < minUsable ? minUsable : lower;
        upper = upper > maxUsable ? maxUsable : upper;

        (uint8 bandCount, uint16[] memory presetWeights) = _referencePreset(shapeId);
        uint256 intervals = uint256(upper - lower) / uint256(spacing256);
        if (intervals < bandCount) {
            bandCount = uint8(intervals);
            presetWeights = _referenceUniformWeights(bandCount);
        }

        uint256 regularWidth = intervals / bandCount;
        bands = new Band[](bandCount);
        for (uint8 i; i < bandCount; ++i) {
            int256 tickLower = lower + int256(regularWidth * uint256(i)) * spacing256;
            int256 tickUpper = i == bandCount - 1 ? upper : tickLower + int256(regularWidth) * spacing256;
            bands[i] = Band({tickLower: int24(tickLower), tickUpper: int24(tickUpper), tokenId: 0, liquidity: 0});
        }
        weights = presetWeights;
    }

    function _referencePreset(uint8 shapeId) private pure returns (uint8 bandCount, uint16[] memory weights) {
        if (shapeId == 0) return (5, _weights5(1000, 2000, 4000, 2000, 1000));
        if (shapeId == 2) return (3, _weights3(2500, 5000, 2500));
        if (shapeId == 3) return (3, _weights3(3333, 3334, 3333));
        if (shapeId == 4) return (5, _weights5(2000, 2000, 2000, 2000, 2000));
        weights = new uint16[](1);
        weights[0] = TOTAL_WEIGHT_BPS;
        return (1, weights);
    }

    function _referenceUniformWeights(uint8 bandCount) private pure returns (uint16[] memory weights) {
        weights = new uint16[](bandCount);
        uint16 base = TOTAL_WEIGHT_BPS / bandCount;
        uint16 remainder = TOTAL_WEIGHT_BPS % bandCount;
        for (uint8 i; i < bandCount; ++i) {
            weights[i] = base + (i < remainder ? 1 : 0);
        }
    }

    function _weights3(uint16 a, uint16 b, uint16 c) private pure returns (uint16[] memory weights) {
        weights = new uint16[](3);
        weights[0] = a;
        weights[1] = b;
        weights[2] = c;
    }

    function _weights5(uint16 a, uint16 b, uint16 c, uint16 d, uint16 e)
        private
        pure
        returns (uint16[] memory weights)
    {
        weights = new uint16[](5);
        weights[0] = a;
        weights[1] = b;
        weights[2] = c;
        weights[3] = d;
        weights[4] = e;
    }

    function _roundDownToSpacing(int256 tick, int256 spacing) private pure returns (int256) {
        return _floorDiv(tick, spacing) * spacing;
    }

    function _roundUpToSpacing(int256 tick, int256 spacing) private pure returns (int256) {
        return _ceilDiv(tick, spacing) * spacing;
    }

    function _floorDiv(int256 a, int256 b) private pure returns (int256) {
        int256 q = a / b;
        int256 r = a % b;
        return r != 0 && ((r < 0) != (b < 0)) ? q - 1 : q;
    }

    function _ceilDiv(int256 a, int256 b) private pure returns (int256) {
        return -_floorDiv(-a, b);
    }
}
