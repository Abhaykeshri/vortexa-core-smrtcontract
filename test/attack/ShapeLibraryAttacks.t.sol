// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IShapeLibrary} from "../../src/interfaces/IShapeLibrary.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {Band} from "../../src/libraries/Types.sol";
import {BandRules} from "../utils/BandRules.sol";

/**
 * @dev A "shape library" that behaves like the real one except for one deliberate defect per mode, standing in for
 *      a malicious or buggy contract address handed to a vault. Used to prove the vault-side re-check
 *      (`BandRules`) rejects every kind of tampering the guide worries about (section 5.3).
 */
contract TamperedShapeLibrary {
    enum Mode {
        Honest,
        Gap,
        Overlap,
        Misaligned,
        OutOfRange,
        TooManyBands,
        WeightsTooLow,
        WeightsTooHigh,
        WeightsLengthMismatch,
        EmptyBand,
        InvertedBand,
        CarriesTokenId,
        CarriesLiquidity,
        NoBands
    }

    Mode public mode;
    ShapeLibrary internal immutable HONEST;

    constructor() {
        HONEST = new ShapeLibrary();
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function computeBands(uint8 shapeId, int24 center, int24 left, int24 right, int24 spacing)
        external
        view
        returns (Band[] memory bands, uint16[] memory weights)
    {
        (bands, weights) = HONEST.computeBands(shapeId, center, left, right, spacing);
        Mode m = mode;
        if (m == Mode.Gap) {
            bands[1].tickLower += spacing;
        } else if (m == Mode.Overlap) {
            bands[1].tickLower -= spacing;
        } else if (m == Mode.Misaligned) {
            bands[0].tickLower += 1;
        } else if (m == Mode.OutOfRange) {
            // the first multiple of `spacing` above the usable maximum: aligned, so only the range rule can catch it
            bands[bands.length - 1].tickUpper = int24((887_272 / spacing + 1) * spacing);
        } else if (m == Mode.TooManyBands) {
            Band[] memory more = new Band[](bands.length + 1);
            for (uint256 i; i < bands.length; ++i) {
                more[i] = bands[i];
            }
            more[bands.length] =
                Band(bands[bands.length - 1].tickUpper, bands[bands.length - 1].tickUpper + spacing, 0, 0);
            bands = more;
            weights = new uint16[](more.length);
            weights[0] = 10_000;
        } else if (m == Mode.WeightsTooLow) {
            weights[0] -= 1;
        } else if (m == Mode.WeightsTooHigh) {
            weights[0] += 1;
        } else if (m == Mode.WeightsLengthMismatch) {
            uint16[] memory shorter = new uint16[](weights.length - 1);
            for (uint256 i; i < shorter.length; ++i) {
                shorter[i] = weights[i];
            }
            weights = shorter;
        } else if (m == Mode.EmptyBand) {
            bands[0].tickUpper = bands[0].tickLower;
        } else if (m == Mode.InvertedBand) {
            (bands[0].tickLower, bands[0].tickUpper) = (bands[0].tickUpper, bands[0].tickLower);
        } else if (m == Mode.CarriesTokenId) {
            bands[0].tokenId = 1;
        } else if (m == Mode.CarriesLiquidity) {
            bands[0].liquidity = 1;
        } else if (m == Mode.NoBands) {
            bands = new Band[](0);
            weights = new uint16[](0);
        }
    }
}

contract ShapeLibraryAttacksTest is Test {
    ShapeLibrary internal shapes;
    TamperedShapeLibrary internal tampered;

    function setUp() public {
        shapes = new ShapeLibrary();
        tampered = new TamperedShapeLibrary();
    }

    // ------------------------------------------------------------------------------------------------------------
    // A malicious library address (guide 5.3: "the vault re-checks this before minting")
    // ------------------------------------------------------------------------------------------------------------

    function test_the_recheck_accepts_an_honest_library() public view {
        (Band[] memory bands, uint16[] memory weights) = tampered.computeBands(0, 0, 5000, 5000, 10);
        assertEq(BandRules.check(bands, weights, 10, 5), "");
    }

    function test_the_recheck_rejects_every_kind_of_tampering() public {
        string[13] memory expected = [
            "gap or overlap",
            "gap or overlap",
            "misaligned tick",
            "outside usable range",
            "too many bands",
            "weights do not sum to 10000",
            "weights do not sum to 10000",
            "weights length mismatch",
            "empty or inverted band",
            "empty or inverted band",
            "planned band carries state",
            "planned band carries state",
            "no bands"
        ];
        for (uint256 i; i < expected.length; ++i) {
            tampered.setMode(TamperedShapeLibrary.Mode(i + 1));
            (Band[] memory bands, uint16[] memory weights) = tampered.computeBands(0, 0, 5000, 5000, 10);
            assertEq(BandRules.check(bands, weights, 10, 5), expected[i], "tampering must be detected");
        }
    }

    /**
     * @dev Weights that sum to 10,000 but bands that overlap would double-count liquidity; both rules matter alone.
     */
    function test_each_rule_is_independently_necessary() public view {
        (Band[] memory bands, uint16[] memory weights) = shapes.computeBands(2, 0, 3000, 3000, 60);
        assertEq(BandRules.check(bands, weights, 60, 5), "");
        assertEq(BandRules.check(bands, weights, 60, 2), "too many bands", "a lower cap is enforced");
        assertEq(BandRules.check(bands, weights, 0, 5), "spacing not positive");
        assertEq(BandRules.check(bands, weights, 61, 5), "misaligned tick", "wrong spacing is caught");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Hostile callers
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev The result depends only on the arguments: not on the caller, tx.origin, block data or balance.
     */
    function test_result_is_independent_of_caller_and_block_context() public {
        (Band[] memory a, uint16[] memory wa) = shapes.computeBands(0, -1234, 777, 4242, 10);

        vm.prank(address(0xBAD), address(0xBAD0));
        vm.warp(123_456_789);
        vm.roll(99_999_999);
        vm.deal(address(shapes), 0);
        (Band[] memory b, uint16[] memory wb) = shapes.computeBands(0, -1234, 777, 4242, 10);

        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)));
        assertEq(keccak256(abi.encode(wa)), keccak256(abi.encode(wb)));
    }

    /**
     * @dev Band count and gas are bounded for adversarial inputs: nothing an attacker passes can create more than
     *      five bands or cost more than the 50,000 gas budget.
     */
    function test_adversarial_inputs_cannot_inflate_band_count_or_gas() public view {
        uint256 worstGas;
        uint256 worstBands;
        for (uint8 shape; shape < 8; ++shape) {
            (uint256 gasUsed, uint256 bandCount) = _sweepShape(shape);
            if (gasUsed > worstGas) worstGas = gasUsed;
            if (bandCount > worstBands) worstBands = bandCount;
        }
        assertLe(worstBands, 5);
        assertLt(worstGas, 50_000);
    }

    function _sweepShape(uint8 shape) private view returns (uint256 worstGas, uint256 worstBands) {
        int24[7] memory centers =
            [type(int24).min, int24(-887_272), int24(-1), int24(0), int24(1), int24(887_272), type(int24).max];
        int24[6] memory widths = [int24(0), 1, 59, 887_272, 8_000_000, type(int24).max];
        int24[6] memory spacings = [int24(1), 2, 60, 200, 32_767, type(int24).max];
        for (uint256 c; c < 7; ++c) {
            for (uint256 w; w < 6; ++w) {
                for (uint256 s; s < 6; ++s) {
                    (uint256 used, uint256 count) = _probe(shape, centers[c], widths[w], widths[5 - w], spacings[s]);
                    if (used > worstGas) worstGas = used;
                    if (count > worstBands) worstBands = count;
                }
            }
        }
    }

    function _probe(uint8 shape, int24 center, int24 left, int24 right, int24 spacing)
        private
        view
        returns (uint256 used, uint256 count)
    {
        uint256 before = gasleft();
        (bool ok, bytes memory ret) = address(shapes)
            .staticcall(abi.encodeCall(IShapeLibrary.computeBands, (shape, center, left, right, spacing)));
        used = before - gasleft();
        if (ok) {
            (Band[] memory bands,) = abi.decode(ret, (Band[], uint16[]));
            count = bands.length;
        }
    }
}
