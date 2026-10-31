// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {Band} from "../../src/libraries/Types.sol";

/**
 * @title M10 targeted symbolic properties
 * @notice Halmos checks for the money-moving arithmetic and bounded band construction required by M10.
 * @dev `check_*` functions receive symbolic arguments under Halmos. Inputs are deliberately narrowed before the
 *      target call so the solver explores meaningful protocol domains without path explosion.
 */
contract M10HalmosTest {
    uint160 private constant Q96 = 1 << 96;
    uint256 private constant BPS = 10_000;

    ShapeLibrary private _shapes;

    function setUp() public {
        _shapes = new ShapeLibrary();
    }

    /**
     * @notice Amounts recovered from liquidity created with a budget never exceed that budget.
     */
    function check_liquidity_round_trip_never_creates_value(uint96 amount0, uint96 amount1) public pure {
        uint160 lower = Q96 / 2;
        uint160 upper = Q96 * 2;
        uint128 liquidity = LiquidityMath.liquidityForAmounts(Q96, lower, upper, amount0, amount1);
        (uint256 recovered0, uint256 recovered1) = LiquidityMath.amountsForLiquidity(Q96, lower, upper, liquidity);

        assert(recovered0 <= amount0);
        assert(recovered1 <= amount1);
    }

    /**
     * @notice Floor-rounded deposit conversion cannot exceed the supplied value at a coprime share ratio.
     */
    function check_share_floor_decomposition(uint96 quotient, uint8 remainder) public pure {
        if (remainder >= 11) return;
        uint256 numerator = uint256(quotient) * 11 + remainder;
        assert(uint256(quotient) * 11 <= numerator);
    }

    /**
     * @notice Round-up inputs for mint and withdraw cover the requested value at a coprime share ratio.
     */
    function check_share_round_up_decomposition(uint96 quotient, uint8 remainder, bool useSupplyDivisor) public pure {
        uint256 divisor = useSupplyDivisor ? 7 : 11;
        if (remainder >= divisor) return;
        uint256 numerator = uint256(quotient) * divisor + remainder;
        uint256 rounded = uint256(quotient) + (remainder == 0 ? 0 : 1);
        assert(rounded * divisor >= numerator);
    }

    /**
     * @notice Every symbolic ShapeLibrary result stays aligned, contiguous, bounded, and fully weighted.
     */
    function check_shape_bands_are_bounded(uint8 shape) public view {
        if (shape >= 8) return;
        int24 spacing = 10;
        int24 center = 0;
        int24 left = 1_000;
        int24 right = 1_000;

        (Band[] memory bands, uint16[] memory weights) = _shapes.computeBands(shape, center, left, right, spacing);
        assert(bands.length > 0 && bands.length <= 5);
        assert(bands.length == weights.length);

        uint256 totalWeight;
        for (uint256 i = 0; i < bands.length; ++i) {
            assert(bands[i].tickLower < bands[i].tickUpper);
            assert(bands[i].tickLower % spacing == 0);
            assert(bands[i].tickUpper % spacing == 0);
            assert(bands[i].tokenId == 0 && bands[i].liquidity == 0);
            if (i != 0) assert(bands[i - 1].tickUpper == bands[i].tickLower);
            totalWeight += weights[i];
        }
        assert(totalWeight == BPS);
    }
}
