// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IShapeLibrary} from "../../src/interfaces/IShapeLibrary.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {Band} from "../../src/libraries/Types.sol";
import {BandRules} from "../utils/BandRules.sol";
import {ShapeModel} from "../utils/ShapeModel.sol";

/**
 * @dev Calls the library with arbitrary parameters in arbitrary order, from arbitrary senders, with arbitrary
 *      time and ETH movements in between, and records any disagreement with the specification model, any result
 *      that fails the vault-side re-check, and the worst gas seen.
 */
contract ShapeLibraryHandler is Test {
    ShapeLibrary public shapes;
    bytes32 public immutable CODE_HASH;

    uint256 public calls;
    uint256 public successes;
    uint256 public reverts;
    uint256 public modelMismatches;
    uint256 public recheckFailures;
    uint256 public maxBandsSeen;
    uint256 public worstGas;
    uint256[8] public successesPerShape;

    constructor() {
        shapes = new ShapeLibrary();
        CODE_HASH = address(shapes).codehash;
    }

    struct Call {
        uint8 shape;
        int24 center;
        int24 left;
        int24 right;
        int24 spacing;
    }

    function compute(
        uint8 shapeSeed,
        int24 center,
        uint256 leftSeed,
        uint256 rightSeed,
        uint256 spacingSeed,
        address sender
    ) external {
        Call memory c = Call(
            uint8(bound(uint256(shapeSeed), 0, 8)), center, _width(leftSeed), _width(rightSeed), _spacing(spacingSeed)
        );

        vm.prank(sender);
        uint256 before = gasleft();
        (bool ok, bytes memory ret) = address(shapes)
            .staticcall(abi.encodeCall(IShapeLibrary.computeBands, (c.shape, c.center, c.left, c.right, c.spacing)));
        uint256 used = before - gasleft();
        if (used > worstGas) worstGas = used;
        calls++;
        _verify(c, ok, ret);
    }

    function _verify(Call memory c, bool ok, bytes memory ret) internal {
        (uint8 status, Band[] memory expectedBands, uint16[] memory expectedWeights) =
            ShapeModel.compute(c.shape, c.center, c.left, c.right, c.spacing);
        if (!ok) {
            reverts++;
            if (status == ShapeModel.OK || bytes4(ret) != ShapeModel.selectorFor(status)) modelMismatches++;
            return;
        }
        successes++;
        successesPerShape[c.shape]++;
        (Band[] memory bands, uint16[] memory weights) = abi.decode(ret, (Band[], uint16[]));
        if (
            status != ShapeModel.OK || keccak256(abi.encode(bands)) != keccak256(abi.encode(expectedBands))
                || keccak256(abi.encode(weights)) != keccak256(abi.encode(expectedWeights))
        ) modelMismatches++;
        if (bytes(BandRules.check(bands, weights, c.spacing, 5)).length != 0) recheckFailures++;
        if (bands.length > maxBandsSeen) maxBandsSeen = bands.length;
    }

    /**
     * @dev Noise between calls: time, block number and stray ETH sent to the library must change nothing.
     */
    function disturb(uint32 secs, uint32 blocks_, uint96 wei_) external {
        vm.warp(block.timestamp + bound(secs, 0, 30 days));
        vm.roll(block.number + bound(blocks_, 0, 1_000_000));
        vm.deal(address(this), wei_);
        (bool ok,) = address(shapes).call{value: wei_}("");
        if (wei_ > 0 && ok) modelMismatches++; // the library must never accept ETH
    }

    function _width(uint256 seed) internal pure returns (int24) {
        uint256 kind = seed % 8;
        uint256 value = seed / 8;
        if (kind == 0) return -int24(int256(bound(value, 1, 100)));
        if (kind == 1) return 0;
        if (kind <= 4) return int24(int256(bound(value, 1, 5_000)));
        if (kind <= 6) return int24(int256(bound(value, 1, 1_800_000)));
        return int24(int256(bound(value, 0, uint256(int256(type(int24).max)))));
    }

    function _spacing(uint256 seed) internal pure returns (int24) {
        uint256 kind = seed % 8;
        uint256 value = seed / 8;
        if (kind == 0) return -int24(int256(bound(value, 0, 100)));
        if (kind == 1) return int24(int256(bound(value, 1, 10)));
        if (kind <= 3) return int24(int256(bound(value, 1, 200)));
        if (kind <= 5) return int24(int256(bound(value, 1, 32_767)));
        if (kind == 6) return int24(int256(bound(value, 32_767, 900_000)));
        return int24(int256(bound(value, 1, uint256(int256(type(int24).max)))));
    }
}

contract ShapeLibraryInvariantTest is StdInvariant, Test {
    ShapeLibraryHandler internal handler;

    function setUp() public {
        handler = new ShapeLibraryHandler();
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = ShapeLibraryHandler.compute.selector;
        selectors[1] = ShapeLibraryHandler.disturb.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /**
     * @dev Sanity: the handler really exercises successes and failures of every kind, so the invariants are not
     *      vacuous.
     */
    function test_handler_reaches_successes_and_every_revert_reason() public {
        handler.compute(0, 0, 8 * 100 + 3, 8 * 100 + 3, 8 * 10 + 2, address(0xA1)); // 5 bands, spacing ~11
        assertEq(handler.successes(), 1);
        handler.compute(8, 0, 1, 1, 8 * 5 + 2, address(0xA1)); // invalid shape
        handler.compute(1, 0, 0, 0, 8 * 5 + 2, address(0xA1)); // empty range
        handler.compute(1, 0, 8 * 5, 1, 8 * 5 + 2, address(0xA1)); // negative width
        assertEq(handler.reverts(), 3);
        assertEq(handler.modelMismatches(), 0);
    }

    function invariant_results_always_equal_the_specification() public view {
        assertEq(handler.modelMismatches(), 0);
    }

    function invariant_every_result_passes_the_vault_recheck() public view {
        assertEq(handler.recheckFailures(), 0);
    }

    function invariant_never_more_than_five_bands_and_never_over_budget_gas() public view {
        assertLe(handler.maxBandsSeen(), 5);
        assertLt(handler.worstGas(), 50_000);
    }

    function invariant_the_library_is_stateless_ether_free_and_unchanged() public view {
        ShapeLibrary shapes = handler.shapes();
        assertEq(address(shapes).codehash, handler.CODE_HASH());
        assertEq(address(shapes).balance, 0);
        for (uint256 slot; slot < 8; ++slot) {
            assertEq(vm.load(address(shapes), bytes32(slot)), bytes32(0));
        }
    }
}
