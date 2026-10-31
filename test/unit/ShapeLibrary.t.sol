// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IShapeLibrary} from "../../src/interfaces/IShapeLibrary.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {Band} from "../../src/libraries/Types.sol";

contract ShapeLibraryTest is Test {
    ShapeLibrary internal shapes;
    int256 private constant MIN_TICK = -887272;
    int256 private constant MAX_TICK = 887272;
    uint16 private constant TOTAL_WEIGHT_BPS = 10_000;

    function setUp() public {
        shapes = new ShapeLibrary();
    }

    function test_presets_and_metadata() public view {
        assertEq(shapes.maxBands(), 5);
        for (uint8 i = 0; i < 8; ++i) {
            assertTrue(shapes.isValidShape(i));
        }
        assertFalse(shapes.isValidShape(8));
        assertFalse(shapes.isValidShape(type(uint8).max));
    }

    function test_golden_all_presets_spacing_10() public view {
        _assertShape(
            0,
            0,
            50,
            50,
            10,
            _ticks(-50, -30, -10, 10, 30),
            _ticks(-30, -10, 10, 30, 50),
            _weights(1000, 2000, 4000, 2000, 1000)
        );
        _assertShape(1, 0, 50, 50, 10, _ticks(-50), _ticks(50), _weights(10000));
        _assertShape(2, 0, 50, 50, 10, _ticks(-50, -20, 10), _ticks(-20, 10, 50), _weights(2500, 5000, 2500));
        _assertShape(3, 0, 50, 50, 10, _ticks(-50, -20, 10), _ticks(-20, 10, 50), _weights(3333, 3334, 3333));
        _assertShape(
            4,
            0,
            50,
            50,
            10,
            _ticks(-50, -30, -10, 10, 30),
            _ticks(-30, -10, 10, 30, 50),
            _weights(2000, 2000, 2000, 2000, 2000)
        );
        _assertShape(5, 3, 50, 50, 10, _ticks(0), _ticks(10), _weights(10000));
        _assertShape(6, 0, 50, 50, 10, _ticks(-887270), _ticks(887270), _weights(10000));
        _assertShape(7, 0, 50, 50, 10, _ticks(-50), _ticks(50), _weights(10000));
    }

    function test_golden_spacing_variants_positive_negative_and_zero_centers() public view {
        int24[4] memory spacings = [int24(1), int24(10), int24(60), int24(200)];
        int24[3] memory centers = [int24(-37), int24(0), int24(37)];
        for (uint256 s; s < spacings.length; ++s) {
            for (uint256 c; c < centers.length; ++c) {
                (Band[] memory bands, uint16[] memory weights) =
                    shapes.computeBands(4, centers[c], 121, 121, spacings[s]);
                _assertInvariants(bands, weights, spacings[s]);
                if (bands.length == 5) {
                    for (uint256 i; i < weights.length; ++i) {
                        assertEq(weights[i], 2000);
                    }
                } else {
                    for (uint256 i; i < weights.length; ++i) {
                        assertApproxEqAbs(weights[i], uint256(10_000 / weights.length), 1);
                    }
                }
            }
        }
    }

    function test_negative_floor_and_ceil_alignment() public view {
        _assertShape(1, -1, 0, 1, 10, _ticks(-10), _ticks(0), _weights(10000));
        _assertShape(1, -11, 1, 0, 10, _ticks(-20), _ticks(-10), _weights(10000));
        _assertShape(1, -61, 0, 1, 60, _ticks(-120), _ticks(-60), _weights(10000));
    }

    function test_differential_boundary_vectors() public view {
        int24[8] memory centers = [
            int24(type(int24).min),
            int24(-887272),
            int24(-887271),
            int24(-1),
            int24(0),
            int24(1),
            int24(887271),
            int24(type(int24).max)
        ];
        int24[7] memory widths = [int24(0), int24(1), int24(9), int24(10), int24(59), int24(60), int24(type(int24).max)];
        int24[7] memory spacings = [int24(1), int24(2), int24(3), int24(10), int24(60), int24(200), int24(887272)];

        for (uint8 shapeId; shapeId < 8; ++shapeId) {
            for (uint256 c; c < centers.length; ++c) {
                for (uint256 w; w < widths.length; ++w) {
                    for (uint256 s; s < spacings.length; ++s) {
                        _assertMatchesReferenceOrReverts(
                            shapeId, centers[c], widths[w], widths[widths.length - 1 - w], spacings[s]
                        );
                    }
                }
            }
        }
    }

    function test_boundaries_and_clamping() public {
        _assertShape(1, -887260, 1000, 100, 60, _ticks(-887220), _ticks(-887160), _weights(10000));
        _assertShape(1, 887260, 100, 1000, 60, _ticks(887160), _ticks(887220), _weights(10000));
        _assertShape(6, 0, 0, 0, 200, _ticks(-887200), _ticks(887200), _weights(10000));
        vm.expectRevert(IShapeLibrary.EmptyRange.selector);
        shapes.computeBands(5, -887272, 0, 0, 60);
        vm.expectRevert(IShapeLibrary.EmptyRange.selector);
        shapes.computeBands(5, 887272, 0, 0, 60);
        _assertShape(6, 0, 0, 0, 887272, _ticks(-887272), _ticks(887272), _weights(10000));
    }

    function test_reduces_band_count_and_uses_uniform_weights() public view {
        _assertShape(0, 0, 10, 10, 10, _ticks(-10, 0), _ticks(0, 10), _weights(5000, 5000));
        _assertShape(4, 0, 10, 20, 10, _ticks(-10, 0, 10), _ticks(0, 10, 20), _weights(3334, 3333, 3333));
        _assertShape(0, 0, 10, 20, 10, _ticks(-10, 0, 10), _ticks(0, 10, 20), _weights(3334, 3333, 3333));
        _assertShape(0, 0, 10, 30, 10, _ticks(-10, 0, 10, 20), _ticks(0, 10, 20, 30), _weights(2500, 2500, 2500, 2500));
    }

    function test_reverts_for_invalid_inputs_and_empty_ranges() public {
        vm.expectRevert(IShapeLibrary.InvalidShape.selector);
        shapes.computeBands(8, 0, 10, 10, 10);

        vm.expectRevert(IShapeLibrary.InvalidInput.selector);
        shapes.computeBands(0, 0, 10, 10, 0);

        vm.expectRevert(IShapeLibrary.InvalidInput.selector);
        shapes.computeBands(0, 0, -1, 10, 10);

        vm.expectRevert(IShapeLibrary.InvalidInput.selector);
        shapes.computeBands(0, 0, 10, -1, 10);

        vm.expectRevert(IShapeLibrary.InvalidInput.selector);
        shapes.computeBands(0, 0, 10, 10, -1);

        vm.expectRevert(IShapeLibrary.EmptyRange.selector);
        shapes.computeBands(1, 0, 0, 0, 10);

        vm.expectRevert(IShapeLibrary.EmptyRange.selector);
        shapes.computeBands(1, type(int24).min, 0, 1, 200);
    }

    function test_extreme_int24_inputs_do_not_overflow() public {
        (Band[] memory bands, uint16[] memory weights) =
            shapes.computeBands(6, type(int24).min, type(int24).max, type(int24).max, 200);
        _assertInvariants(bands, weights, 200);
        assertEq(bands[0].tickLower, -887200);
        assertEq(bands[0].tickUpper, 887200);

        vm.expectRevert(IShapeLibrary.EmptyRange.selector);
        shapes.computeBands(0, type(int24).min, type(int24).max, 0, type(int24).max);
    }

    function test_computeBands_worst_case_gas_below_50000() public {
        uint256 beforeGas = gasleft();
        shapes.computeBands(0, 0, 120_000, 120_000, 1);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("computeBands worst-case gas", used);
        assertLt(used, 50_000);
    }

    function test_computeBands_all_presets_gas_below_50000() public {
        for (uint8 shapeId; shapeId < 8; ++shapeId) {
            uint256 beforeGas = gasleft();
            shapes.computeBands(shapeId, -12345, 120_000, 234_567, 1);
            uint256 used = beforeGas - gasleft();
            emit log_named_uint(string.concat("computeBands gas preset ", vm.toString(shapeId)), used);
            assertLt(used, 50_000);
        }
    }

    function _assertShape(
        uint8 shapeId,
        int24 center,
        int24 left,
        int24 right,
        int24 spacing,
        int24[] memory lowers,
        int24[] memory uppers,
        uint16[] memory expectedWeights
    ) private view {
        (Band[] memory bands, uint16[] memory weights) = shapes.computeBands(shapeId, center, left, right, spacing);
        assertEq(bands.length, lowers.length);
        assertEq(weights.length, expectedWeights.length);
        for (uint256 i; i < bands.length; ++i) {
            assertEq(bands[i].tickLower, lowers[i]);
            assertEq(bands[i].tickUpper, uppers[i]);
            assertEq(bands[i].tokenId, 0);
            assertEq(bands[i].liquidity, 0);
            assertEq(weights[i], expectedWeights[i]);
        }
        _assertInvariants(bands, weights, spacing);
    }

    function _assertMatchesReferenceOrReverts(uint8 shapeId, int24 center, int24 left, int24 right, int24 spacing)
        private
        view
    {
        try shapes.computeBands(shapeId, center, left, right, spacing) returns (
            Band[] memory actualBands, uint16[] memory actualWeights
        ) {
            (Band[] memory expectedBands, uint16[] memory expectedWeights) =
                _referenceCompute(shapeId, center, left, right, spacing);
            assertEq(keccak256(abi.encode(actualBands)), keccak256(abi.encode(expectedBands)));
            assertEq(keccak256(abi.encode(actualWeights)), keccak256(abi.encode(expectedWeights)));
            _assertInvariants(actualBands, actualWeights, spacing);
        } catch (bytes memory reason) {
            assertTrue(
                keccak256(reason) == keccak256(abi.encodeWithSelector(IShapeLibrary.EmptyRange.selector))
                    || keccak256(reason) == keccak256(abi.encodeWithSelector(IShapeLibrary.InvalidInput.selector))
            );
        }
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
        if (shapeId == 0) return (5, _weights(1000, 2000, 4000, 2000, 1000));
        if (shapeId == 2) return (3, _weights(2500, 5000, 2500));
        if (shapeId == 3) return (3, _weights(3333, 3334, 3333));
        if (shapeId == 4) return (5, _weights(2000, 2000, 2000, 2000, 2000));
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

    function _weights(uint16 a) private pure returns (uint16[] memory out) {
        out = new uint16[](1);
        out[0] = a;
    }

    function _weights(uint16 a, uint16 b) private pure returns (uint16[] memory out) {
        out = new uint16[](2);
        out[0] = a;
        out[1] = b;
    }

    function _weights(uint16 a, uint16 b, uint16 c) private pure returns (uint16[] memory out) {
        out = new uint16[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function _weights(uint16 a, uint16 b, uint16 c, uint16 d) private pure returns (uint16[] memory out) {
        out = new uint16[](4);
        out[0] = a;
        out[1] = b;
        out[2] = c;
        out[3] = d;
    }

    function _weights(uint16 a, uint16 b, uint16 c, uint16 d, uint16 e) private pure returns (uint16[] memory out) {
        out = new uint16[](5);
        out[0] = a;
        out[1] = b;
        out[2] = c;
        out[3] = d;
        out[4] = e;
    }

    function _ticks(int24 a) private pure returns (int24[] memory out) {
        out = new int24[](1);
        out[0] = a;
    }

    function _ticks(int24 a, int24 b) private pure returns (int24[] memory out) {
        out = new int24[](2);
        out[0] = a;
        out[1] = b;
    }

    function _ticks(int24 a, int24 b, int24 c) private pure returns (int24[] memory out) {
        out = new int24[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function _ticks(int24 a, int24 b, int24 c, int24 d) private pure returns (int24[] memory out) {
        out = new int24[](4);
        out[0] = a;
        out[1] = b;
        out[2] = c;
        out[3] = d;
    }

    function _ticks(int24 a, int24 b, int24 c, int24 d, int24 e) private pure returns (int24[] memory out) {
        out = new int24[](5);
        out[0] = a;
        out[1] = b;
        out[2] = c;
        out[3] = d;
        out[4] = e;
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
