// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IShapeLibrary} from "../../src/interfaces/IShapeLibrary.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {Band} from "../../src/libraries/Types.sol";
import {BandRules} from "../utils/BandRules.sol";

/**
 * @dev Deterministic audit tests for ShapeLibrary: the rules the strategies and the vault depend on, edge cases of
 *      the numeric domain, and behaviour that is correct per the guide but easy to misread.
 */
contract ShapeLibraryBreakingTest is Test {
    ShapeLibrary internal shapes;

    function setUp() public {
        shapes = new ShapeLibrary();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Error precedence and exact revert reasons
    // ------------------------------------------------------------------------------------------------------------

    function test_invalid_shape_takes_precedence_over_invalid_input() public {
        vm.expectRevert(IShapeLibrary.InvalidShape.selector);
        shapes.computeBands(8, 0, -1, -1, 0);
        vm.expectRevert(IShapeLibrary.InvalidShape.selector);
        shapes.computeBands(255, 0, 10, 10, 10);
    }

    function test_invalid_input_takes_precedence_over_empty_range() public {
        vm.expectRevert(IShapeLibrary.InvalidInput.selector);
        shapes.computeBands(1, 0, 0, -1, 10); // would also be empty
        vm.expectRevert(IShapeLibrary.InvalidInput.selector);
        shapes.computeBands(6, 0, 0, 0, 0); // zero spacing even for the full range
    }

    function test_negative_widths_are_rejected_even_for_shapes_that_ignore_them() public {
        vm.expectRevert(IShapeLibrary.InvalidInput.selector);
        shapes.computeBands(5, 0, -1, 0, 10);
        vm.expectRevert(IShapeLibrary.InvalidInput.selector);
        shapes.computeBands(6, 0, 0, -1, 10);
    }

    function test_zero_width_on_an_aligned_center_is_an_empty_range_not_a_zero_width_band() public {
        for (uint8 shape = 0; shape < 5; ++shape) {
            if (shape == 5) continue;
            vm.expectRevert(IShapeLibrary.EmptyRange.selector);
            shapes.computeBands(shape, 600, 0, 0, 60);
        }
        // misaligned center: the range expands to one full spacing instead of reverting
        (Band[] memory bands,) = shapes.computeBands(1, 601, 0, 0, 60);
        assertEq(bands[0].tickLower, 600);
        assertEq(bands[0].tickUpper, 660);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Tick spacing extremes
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Uniswap v4 allows tick spacings up to 32,767; the usable range then shrinks to 27 spacings per side.
     */
    function test_uniswap_maximum_tick_spacing() public view {
        (Band[] memory bands, uint16[] memory weights) = shapes.computeBands(6, 0, 0, 0, 32_767);
        assertEq(bands.length, 1);
        assertEq(bands[0].tickLower, -27 * 32_767);
        assertEq(bands[0].tickUpper, 27 * 32_767);
        assertEq(BandRules.check(bands, weights, 32_767, 5), "");

        (bands, weights) = shapes.computeBands(0, 0, 500_000, 500_000, 32_767);
        assertEq(bands.length, 5);
        assertEq(BandRules.check(bands, weights, 32_767, 5), "");
    }

    function test_spacing_larger_than_the_usable_range_has_no_usable_ticks() public {
        // 887,272 / 887,273 = 0 spacings on either side: only tick zero is usable
        vm.expectRevert(IShapeLibrary.EmptyRange.selector);
        shapes.computeBands(6, 0, 0, 0, 887_273);
        vm.expectRevert(IShapeLibrary.EmptyRange.selector);
        shapes.computeBands(0, 0, 1_000_000, 1_000_000, type(int24).max);
        vm.expectRevert(IShapeLibrary.EmptyRange.selector);
        shapes.computeBands(5, 0, 0, 0, type(int24).max);
    }

    function test_spacing_one_covers_the_whole_tick_domain_with_five_bands() public view {
        (Band[] memory bands, uint16[] memory weights) = shapes.computeBands(4, 0, 2_000_000, 2_000_000, 1);
        assertEq(bands.length, 5);
        assertEq(bands[0].tickLower, -887_272);
        assertEq(bands[4].tickUpper, 887_272);
        assertEq(BandRules.check(bands, weights, 1, 5), "");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Centers outside the usable range
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev The library does not validate the center: a request whose window overlaps the usable range is clamped and
     *      served even though the center itself is outside it. The factory must validate centers (guide 10.1).
     */
    function test_center_outside_the_usable_range_is_clamped_not_rejected() public view {
        (Band[] memory bands,) = shapes.computeBands(1, 1_000_000, 500_000, 0, 60);
        assertEq(bands[0].tickLower, 499_980);
        assertEq(bands[0].tickUpper, 887_220, "upper clamped to the usable maximum");
    }

    function test_window_entirely_outside_the_usable_range_reverts() public {
        vm.expectRevert(IShapeLibrary.EmptyRange.selector);
        shapes.computeBands(1, 1_000_000, 10_000, 10_000, 60);
        vm.expectRevert(IShapeLibrary.EmptyRange.selector);
        shapes.computeBands(1, -1_000_000, 10_000, 10_000, 60);
    }

    function test_int24_extremes_for_every_shape_never_panic() public view {
        int24[3] memory centers = [type(int24).min, int24(0), type(int24).max];
        for (uint8 shape; shape < 8; ++shape) {
            for (uint256 c; c < centers.length; ++c) {
                (bool ok, bytes memory ret) = address(shapes)
                    .staticcall(
                        abi.encodeCall(
                            IShapeLibrary.computeBands, (shape, centers[c], type(int24).max, type(int24).max, 1)
                        )
                    );
                if (!ok) {
                    // the only acceptable failure is a documented error, never a Panic(uint256)
                    assertEq(bytes4(ret), IShapeLibrary.EmptyRange.selector);
                }
            }
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // The remainder rule (guide 5.2 step 4): behaviour to be aware of
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Only the last band absorbs the remainder, so for ranges barely wider than the band count it can be much
     *      wider than the others while carrying the same relative weight. Nine spacings over five bands give
     *      widths 1, 1, 1, 1, 5. The spec says so; the vault and UI should keep ranges well above the band count.
     */
    function test_known_behaviour_last_band_can_be_several_times_wider() public view {
        (Band[] memory bands,) = shapes.computeBands(0, 0, 0, 90, 10);
        assertEq(bands.length, 5);
        uint256[5] memory widths;
        for (uint256 i; i < 5; ++i) {
            widths[i] = uint256(int256(bands[i].tickUpper - bands[i].tickLower)) / 10;
        }
        assertEq(widths[0], 1);
        assertEq(widths[3], 1);
        assertEq(widths[4], 5, "last band absorbs the whole remainder");
    }

    /**
     * @dev The remainder never exceeds `bandCount - 1` spacings, so the last band is at most (bandCount - 1) / width
     *      wider than a regular one: at most 4% once each band spans 100 spacings, 10% at 40.
     */
    function test_remainder_is_bounded_by_band_count_minus_one() public view {
        for (uint256 steps = 5; steps < 400; ++steps) {
            (Band[] memory bands,) = shapes.computeBands(4, 0, 0, int24(int256(steps) * 10), 10);
            uint256 regular = steps / 5;
            uint256 last = uint256(int256(bands[4].tickUpper - bands[4].tickLower)) / 10;
            assertEq(last - regular, steps % 5);
            assertLe(last - regular, 4);
        }
    }

    /**
     * @dev The uniform fallback hands its remainder to the earliest bands, so those weights are not palindromic
     *      (3334, 3333, 3333). The difference is one basis point and is documented, not a defect.
     */
    function test_known_behaviour_uniform_fallback_weights_are_not_symmetric() public view {
        (, uint16[] memory weights) = shapes.computeBands(0, 0, 10, 20, 10); // 3 spacings < 5 bands
        assertEq(weights.length, 3);
        assertEq(weights[0], 3334);
        assertEq(weights[2], 3333);
    }

    function test_narrowest_possible_ranges_for_every_nominal_band_count() public view {
        for (uint256 steps = 1; steps <= 6; ++steps) {
            (Band[] memory bands, uint16[] memory weights) = shapes.computeBands(0, 0, 0, int24(int256(steps) * 10), 10);
            assertEq(bands.length, steps < 5 ? steps : 5);
            assertEq(BandRules.check(bands, weights, 10, 5), "");
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Interface and statelessness
    // ------------------------------------------------------------------------------------------------------------

    function test_isValidShape_is_exactly_zero_to_seven() public view {
        for (uint256 id; id < 256; ++id) {
            assertEq(shapes.isValidShape(uint8(id)), id < 8);
        }
    }

    function test_maxBands_matches_the_largest_preset() public view {
        uint256 largest;
        for (uint8 shape; shape < 8; ++shape) {
            (Band[] memory bands,) = shapes.computeBands(shape, 0, 100_000, 100_000, 1);
            if (bands.length > largest) largest = bands.length;
        }
        assertEq(largest, shapes.maxBands());
        assertEq(shapes.maxBands(), 5);
    }

    function test_the_library_is_stateless_and_rejects_ether() public {
        for (uint256 slot; slot < 16; ++slot) {
            assertEq(vm.load(address(shapes), bytes32(slot)), bytes32(0));
        }
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(shapes).call{value: 1 wei}("");
        assertFalse(ok);
        (ok,) = address(shapes).call{value: 1 wei}(abi.encodeCall(IShapeLibrary.maxBands, ()));
        assertFalse(ok, "non-payable functions reject ETH");
        assertEq(address(shapes).balance, 0);
    }

    function test_returned_bands_never_carry_token_ids_or_liquidity() public view {
        for (uint8 shape; shape < 8; ++shape) {
            (Band[] memory bands,) = shapes.computeBands(shape, 100, 5_000, 5_000, 10);
            for (uint256 i; i < bands.length; ++i) {
                assertEq(bands[i].tokenId, 0);
                assertEq(bands[i].liquidity, 0);
            }
        }
    }
}
