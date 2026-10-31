// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {IShapeLibrary} from "../../src/interfaces/IShapeLibrary.sol";
import {BuyTheDipStrategy} from "../../src/strategies/BuyTheDipStrategy.sol";
import {NormalLPStrategy} from "../../src/strategies/NormalLPStrategy.sol";
import {SellThePumpStrategy} from "../../src/strategies/SellThePumpStrategy.sol";
import {StrategyBase} from "../../src/strategies/StrategyBase.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {Band, Currency, DepositMode, Plan, PoolKey, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";

contract StrategyHarness is StrategyBase {
    constructor(ShapeLibrary shapes_) StrategyBase(shapes_) {}

    function floorToSpacing(int256 tick, int256 spacing) external pure returns (int256) {
        return _floorToSpacing(tick, spacing);
    }

    function ceilToSpacing(int256 tick, int256 spacing) external pure returns (int256) {
        return _ceilToSpacing(tick, spacing);
    }

    function edges(Band[] calldata bands) external pure returns (int24 lower, int24 upper) {
        return _edges(bands);
    }
}

contract StrategiesTest is Test {
    bytes32 internal constant NONE = bytes32("NONE");
    bytes32 internal constant OUT_OF_RANGE = bytes32("OUT_OF_RANGE");
    bytes32 internal constant DRIFT = bytes32("DRIFT");
    bytes32 internal constant TRAIL = bytes32("TRAIL");
    bytes32 internal constant FILLED = bytes32("FILLED");

    ShapeLibrary internal shapes;
    StrategyHarness internal harness;
    NormalLPStrategy internal normal;
    BuyTheDipStrategy internal buy;
    SellThePumpStrategy internal sell;

    function setUp() public {
        shapes = new ShapeLibrary();
        harness = new StrategyHarness(shapes);
        normal = new NormalLPStrategy(shapes);
        buy = new BuyTheDipStrategy(shapes);
        sell = new SellThePumpStrategy(shapes);
    }

    function test_negativeTickRoundingExactBoundaries() public view {
        assertEq(harness.floorToSpacing(-61, 60), -120);
        assertEq(harness.ceilToSpacing(-61, 60), -60);
        assertEq(harness.floorToSpacing(-60, 60), -60);
        assertEq(harness.ceilToSpacing(-60, 60), -60);
        assertEq(harness.floorToSpacing(61, 60), 60);
        assertEq(harness.ceilToSpacing(61, 60), 120);
    }

    function test_baseRejectsZeroDependencySpacingAndEmptyEdges() public {
        vm.expectRevert(StrategyBase.ZeroAddress.selector);
        new StrategyHarness(ShapeLibrary(address(0)));
        vm.expectRevert(StrategyBase.InvalidRange.selector);
        harness.floorToSpacing(0, 0);
        vm.expectRevert(StrategyBase.InvalidBands.selector);
        harness.edges(new Band[](0));
    }

    /// forge-config: default.fuzz.runs = 100000
    function testFuzz_roundingProperties100k(int24 rawTick, uint24 rawSpacing) public view {
        int256 tick = bound(int256(rawTick), -887272, 887272);
        int256 spacing = int256(bound(uint256(rawSpacing), 1, 32767));
        int256 floorTick = harness.floorToSpacing(tick, spacing);
        int256 ceilTick = harness.ceilToSpacing(tick, spacing);
        assertLe(floorTick, tick);
        assertGe(ceilTick, tick);
        assertLt(tick - floorTick, spacing);
        assertLt(ceilTick - tick, spacing);
        assertEq(floorTick % spacing, 0);
        assertEq(ceilTick % spacing, 0);
    }

    /// forge-config: default.fuzz.runs = 100000
    function testFuzz_oneSidedAlignmentAndOrientation100k(int24 rawTick, bool buyKind, bool baseIsCurrency0)
        public
        view
    {
        int24 tick = int24(bound(int256(rawTick), -887000, 887000));
        Strategy kind = buyKind ? Strategy.BuyTheDip : Strategy.SellThePump;
        bool below = buyKind == baseIsCurrency0;
        VaultConfig memory config = _oneSidedConfig(kind, baseIsCurrency0, below);
        Plan memory p = buyKind
            ? buy.plan(config, tick, 0, SqrtPriceMath.getSqrtPriceAtTick(tick), 0, 0, TRAIL)
            : sell.plan(config, tick, 0, SqrtPriceMath.getSqrtPriceAtTick(tick), 0, 0, TRAIL);
        assertGt(p.bands.length, 0);
        assertEq(p.bands[0].tickLower % config.poolKey.tickSpacing, 0);
        assertEq(p.bands[p.bands.length - 1].tickUpper % config.poolKey.tickSpacing, 0);
        if (below) assertLe(p.bands[p.bands.length - 1].tickUpper, tick);
        else assertGt(p.bands[0].tickLower, tick);
        assertFalse(p.needsSwap);
    }

    function test_normalTriggerBoundaries() public view {
        VaultConfig memory config = _normalConfig();
        Band[] memory bands = _bands(-120, 120);
        _assertTrigger(normal, config, -121, bands, true, OUT_OF_RANGE);
        _assertTrigger(normal, config, -120, bands, true, DRIFT);
        _assertTrigger(normal, config, -60, bands, false, NONE);
        _assertTrigger(normal, config, 60, bands, true, DRIFT);
        _assertTrigger(normal, config, 120, bands, true, OUT_OF_RANGE);
    }

    function test_normalPlanIsBoundedAndSwapConsistent() public view {
        VaultConfig memory config = _normalConfig();
        Plan memory p = normal.plan(config, 0, 0, SqrtPriceMath.getSqrtPriceAtTick(0), 1 ether, 0, DRIFT);
        assertGt(p.bands.length, 0);
        assertLe(p.bands.length, 5);
        assertTrue(p.needsSwap);
        assertTrue(p.zeroForOne);
        assertGt(p.swapAmountIn, 0);
        assertLe(p.swapAmountIn, 1 ether);
        assertFalse(p.lockIdle);
        _assertWeights(p.weightsBps);
    }

    function test_normalPlanCoversBothSwapDirectionsAndZeroHoldings() public view {
        VaultConfig memory config = _normalConfig();
        uint160 price = SqrtPriceMath.getSqrtPriceAtTick(0);
        Plan memory buy0 = normal.plan(config, 0, 0, price, 0, 1 ether, DRIFT);
        assertTrue(buy0.needsSwap);
        assertFalse(buy0.zeroForOne);
        assertLe(buy0.swapAmountIn, 1 ether);

        Plan memory empty = normal.plan(config, 0, 0, price, 0, 0, DRIFT);
        assertFalse(empty.needsSwap);
        assertEq(empty.swapAmountIn, 0);
    }

    function test_normalPlanRejectsInvalidPriceAndFee() public {
        VaultConfig memory config = _normalConfig();
        vm.expectRevert(NormalLPStrategy.InvalidPrice.selector);
        normal.plan(config, 0, 0, 0, 1 ether, 1 ether, DRIFT);
        config.poolKey.fee = 1_000_000;
        vm.expectRevert(NormalLPStrategy.InvalidPrice.selector);
        normal.plan(config, 0, 0, SqrtPriceMath.getSqrtPriceAtTick(0), 1 ether, 1 ether, DRIFT);
    }

    function test_oneSidedModesBothStrategiesAndOrientations() public view {
        VaultConfig memory config = _oneSidedConfig(Strategy.BuyTheDip, true, true);
        assertEq(uint256(buy.depositMode(config)), uint256(DepositMode.Token1Only));
        config = _oneSidedConfig(Strategy.BuyTheDip, false, false);
        assertEq(uint256(buy.depositMode(config)), uint256(DepositMode.Token0Only));
        config = _oneSidedConfig(Strategy.SellThePump, false, true);
        assertEq(uint256(sell.depositMode(config)), uint256(DepositMode.Token1Only));
        config = _oneSidedConfig(Strategy.SellThePump, true, false);
        assertEq(uint256(sell.depositMode(config)), uint256(DepositMode.Token0Only));
    }

    function test_belowRangeDepositAndTriggerBoundaries() public view {
        VaultConfig memory config = _oneSidedConfig(Strategy.BuyTheDip, true, true);
        Band[] memory bands = _bands(-120, -60);
        assertFalse(buy.canDeposit(config, -61, bands));
        assertTrue(buy.canDeposit(config, -60, bands));
        _assertTrigger(buy, config, -121, bands, true, FILLED);
        _assertTrigger(buy, config, -120, bands, false, NONE);
        _assertTrigger(buy, config, -1, bands, false, NONE);
        _assertTrigger(buy, config, 0, bands, true, TRAIL);
    }

    function test_aboveRangeDepositAndTriggerBoundaries() public view {
        VaultConfig memory config = _oneSidedConfig(Strategy.SellThePump, true, false);
        Band[] memory bands = _bands(60, 120);
        assertTrue(sell.canDeposit(config, 59, bands));
        assertFalse(sell.canDeposit(config, 60, bands));
        _assertTrigger(sell, config, -1, bands, true, TRAIL);
        _assertTrigger(sell, config, 0, bands, false, NONE);
        _assertTrigger(sell, config, 119, bands, false, NONE);
        _assertTrigger(sell, config, 120, bands, true, FILLED);
    }

    function test_oneSidedPlanIgnoresKeeperCenterAndLocksOnFill() public view {
        VaultConfig memory config = _oneSidedConfig(Strategy.BuyTheDip, true, true);
        Plan memory a = buy.plan(config, -1, -700000, SqrtPriceMath.getSqrtPriceAtTick(-1), 0, 1 ether, TRAIL);
        Plan memory b = buy.plan(config, -1, 700000, SqrtPriceMath.getSqrtPriceAtTick(-1), 0, 1 ether, TRAIL);
        assertEq(a.bands[0].tickLower, b.bands[0].tickLower);
        assertEq(a.bands[a.bands.length - 1].tickUpper, -60);
        assertFalse(a.needsSwap);

        Plan memory locked = buy.plan(config, -121, 0, SqrtPriceMath.getSqrtPriceAtTick(-121), 0, 1 ether, FILLED);
        assertTrue(locked.lockIdle);
        assertEq(locked.bands.length, 0);
        assertFalse(locked.needsSwap);
    }

    function test_emptyBandsAndDisabledLockReturnNone() public view {
        Band[] memory empty = new Band[](0);
        VaultConfig memory normalConfig = _normalConfig();
        _assertTrigger(normal, normalConfig, 0, empty, false, NONE);
        VaultConfig memory config = _oneSidedConfig(Strategy.BuyTheDip, true, true);
        config.lockOnFill = false;
        _assertTrigger(buy, config, -121, _bands(-120, -60), false, NONE);
        assertTrue(buy.canDeposit(config, 0, empty));
    }

    function test_validateConfigRejectsInvalidStrategyFields() public {
        VaultConfig memory config = _normalConfig();
        config.shapeId = 6;
        vm.expectRevert(StrategyBase.InvalidShape.selector);
        normal.validateConfig(config, 0);

        config = _normalConfig();
        config.driftTicks = uint24(config.ticksLeft);
        vm.expectRevert(StrategyBase.InvalidDrift.selector);
        normal.validateConfig(config, 0);

        config = _oneSidedConfig(Strategy.BuyTheDip, true, true);
        config.trailTicks = 0;
        vm.expectRevert(StrategyBase.InvalidTrail.selector);
        buy.validateConfig(config, 0);

        config = _oneSidedConfig(Strategy.BuyTheDip, true, true);
        config.ticksRight = 60;
        vm.expectRevert(StrategyBase.InvalidRange.selector);
        buy.validateConfig(config, 0);

        config = _oneSidedConfig(Strategy.BuyTheDip, true, true);
        config.poolKey.tickSpacing = 0;
        vm.expectRevert(StrategyBase.InvalidRange.selector);
        buy.validateConfig(config, 0);

        config = _oneSidedConfig(Strategy.SellThePump, true, false);
        vm.expectRevert(StrategyBase.InvalidStrategy.selector);
        buy.validateConfig(config, 0);

        config = _normalConfig();
        config.lockOnFill = true;
        vm.expectRevert(StrategyBase.InvalidTrail.selector);
        normal.validateConfig(config, 0);
    }

    function test_validateConfigAcceptsAllStrategiesAndOrientations() public view {
        normal.validateConfig(_normalConfig(), 0);
        buy.validateConfig(_oneSidedConfig(Strategy.BuyTheDip, true, true), -1);
        buy.validateConfig(_oneSidedConfig(Strategy.BuyTheDip, false, false), -1);
        sell.validateConfig(_oneSidedConfig(Strategy.SellThePump, true, false), -1);
        sell.validateConfig(_oneSidedConfig(Strategy.SellThePump, false, true), -1);
    }

    // ------------------------------------------------------------------------------------------------------------
    // M7 audit: gaps found by mutation (every test below fails on at least one surviving mutant)
    // ------------------------------------------------------------------------------------------------------------

    /**
     * Guide 5.1 and 9.4: one-sided strategies accept only the uniform shapes 3, 4 and 7, never a drift, and
     * exactly one non-zero width on the correct side, for both strategies and both base orientations.
     */
    function test_oneSidedConfigRejectsBellShapesDriftAndTheWrongWidth() public {
        uint8[5] memory bell = [uint8(0), 1, 2, 5, 6];
        uint8[3] memory uniform = [uint8(3), 4, 7];
        for (uint256 k; k < 4; ++k) {
            Strategy kind = k < 2 ? Strategy.BuyTheDip : Strategy.SellThePump;
            bool base0 = k % 2 == 0;
            bool below = (kind == Strategy.BuyTheDip) == base0;
            VaultConfig memory config = _oneSidedConfig(kind, base0, below);
            for (uint256 i; i < bell.length; ++i) {
                config.shapeId = bell[i];
                vm.expectRevert(StrategyBase.InvalidShape.selector);
                _validate(kind, config, 0);
            }
            for (uint256 i; i < uniform.length; ++i) {
                config.shapeId = uniform[i];
                _validate(kind, config, 0);
            }

            config = _oneSidedConfig(kind, base0, below);
            config.driftTicks = 1;
            vm.expectRevert(StrategyBase.InvalidDrift.selector);
            _validate(kind, config, 0);

            // the side that must be zero is set as well
            config = _oneSidedConfig(kind, base0, below);
            if (below) config.ticksRight = 60;
            else config.ticksLeft = 60;
            vm.expectRevert(StrategyBase.InvalidRange.selector);
            _validate(kind, config, 0);
        }
    }

    /**
     * Normal LP needs a positive width on both sides: a zero right width is a range error, not a drift error.
     */
    function test_normalConfigRejectsAZeroWidthOnEitherSide() public {
        VaultConfig memory config = _normalConfig();
        config.driftTicks = 0;
        config.ticksRight = 0;
        vm.expectRevert(StrategyBase.InvalidRange.selector);
        normal.validateConfig(config, 0);
        config.ticksRight = 120;
        config.ticksLeft = 0;
        vm.expectRevert(StrategyBase.InvalidRange.selector);
        normal.validateConfig(config, 0);
    }

    /**
     * `validateConfig` also checks that the range can be built at the live tick: an above-price ladder with no usable
     * tick left above the price is refused at initialization instead of failing on the first deposit.
     */
    function test_oneSidedConfigRejectsALadderThatCannotBeBuiltAtTheLiveTick() public {
        VaultConfig memory above = _oneSidedConfig(Strategy.SellThePump, true, false);
        sell.validateConfig(above, 0);
        vm.expectRevert(IShapeLibrary.EmptyRange.selector);
        sell.validateConfig(above, 887_200);

        VaultConfig memory below = _oneSidedConfig(Strategy.BuyTheDip, true, true);
        buy.validateConfig(below, 0);
        vm.expectRevert(IShapeLibrary.EmptyRange.selector);
        buy.validateConfig(below, -887_200);
    }

    /**
     * Anchors outside Uniswap's tick domain (by more than one spacing) are refused with `InvalidAnchor` on both sides.
     */
    function test_oneSidedPlanRejectsAnchorsOutsideTheTickDomain() public {
        VaultConfig memory below = _oneSidedConfig(Strategy.BuyTheDip, true, true);
        // floor(-887392, 60) = -887400 < MIN_TICK - 60
        vm.expectRevert(StrategyBase.InvalidAnchor.selector);
        buy.plan(below, -887_392, 0, 1, 0, 0, TRAIL);
        VaultConfig memory above = _oneSidedConfig(Strategy.SellThePump, true, false);
        // ceil(887393, 60) = 887400 > MAX_TICK + 60
        vm.expectRevert(StrategyBase.InvalidAnchor.selector);
        sell.plan(above, 887_392, 0, 1, 0, 0, TRAIL);
    }

    /**
     * Only a lock-on-fill vault locks idle on FILLED; without the flag a FILLED plan is an ordinary re-anchor.
     */
    function test_filledPlanWithoutLockOnFillReanchors() public view {
        VaultConfig memory config = _oneSidedConfig(Strategy.BuyTheDip, true, true);
        config.lockOnFill = false;
        Plan memory p = buy.plan(config, -121, 0, SqrtPriceMath.getSqrtPriceAtTick(-121), 0, 1 ether, FILLED);
        assertFalse(p.lockIdle);
        assertGt(p.bands.length, 0);
        assertEq(p.bands[p.bands.length - 1].tickUpper, -180, "anchored at floor(-121, 60)");
    }

    /**
     * Guide 8.3 swap sizing: after paying the pool fee at the planning price, the bought amount covers the whole
     * shortfall of the scarce token (every buy-side conversion rounds up), unless the input is capped at holdings,
     * including when the planned range sits entirely on one side of the price.
     */
    function testFuzz_normalSwapCoversTheShortfallAfterTheFee(
        int24 rawTick,
        int16 rawOffset,
        uint96 rawA0,
        uint96 rawA1,
        bool feeTier
    ) public view {
        VaultConfig memory config = _normalConfig();
        config.poolKey.fee = feeTier ? 3000 : 10_000;
        int24 tick = int24(bound(rawTick, -50_000, 50_000));
        // the keeper's center may leave the price outside the new range (a single-token target)
        int24 center = int24(harness.floorToSpacing(tick + bound(rawOffset, -600, 600), 60));
        uint160 sp = SqrtPriceMath.getSqrtPriceAtTick(tick);
        uint256 a0 = rawA0;
        uint256 a1 = rawA1;
        Plan memory p = normal.plan(config, tick, center, sp, a0, a1, DRIFT);
        assertEq(p.needsSwap, p.swapAmountIn != 0);
        (uint256 target0, uint256 target1) = _targets(p, sp, a0, a1);

        // direction: buy whichever token is short of the target split; no swap when neither is
        if (target0 > a0 && a1 != 0) {
            assertTrue(p.needsSwap && !p.zeroForOne, "token0 is short: sell token1");
        } else if (target0 <= a0 && target1 > a1 && a0 != 0) {
            assertTrue(p.needsSwap && p.zeroForOne, "token1 is short: sell token0");
        } else {
            assertFalse(p.needsSwap, "nothing is short");
            return;
        }

        uint256 priceX96 = Math.mulDiv(sp, sp, 1 << 96);
        uint256 net = Math.mulDiv(p.swapAmountIn, 1e6 - config.poolKey.fee, 1e6);
        if (!p.zeroForOne) {
            assertLe(p.swapAmountIn, a1, "never more than the holding");
            uint256 bought = Math.mulDiv(net, 1 << 96, priceX96);
            if (p.swapAmountIn < a1) assertGe(bought, target0 - a0, "shortfall of token0 not covered");
        } else {
            assertLe(p.swapAmountIn, a0, "never more than the holding");
            uint256 bought = Math.mulDiv(net, priceX96, 1 << 96);
            if (p.swapAmountIn < a0) assertGe(bought, target1 - a1, "shortfall of token1 not covered");
        }
    }

    /**
     * Normal LP refuses a configuration of another kind, always takes both tokens, never closes deposits, and refuses
     * to plan at a price whose Q96 square rounds to zero.
     */
    function test_normalRejectsOtherKindsAndUnplannablePrices() public {
        vm.expectRevert(StrategyBase.InvalidStrategy.selector);
        normal.validateConfig(_oneSidedConfig(Strategy.BuyTheDip, true, true), 0);

        VaultConfig memory config = _normalConfig();
        assertEq(uint256(normal.depositMode(config)), uint256(DepositMode.BothTokens));
        assertTrue(normal.canDeposit(config, 887_000, _bands(-120, 120)));

        vm.expectRevert(NormalLPStrategy.InvalidPrice.selector);
        normal.plan(config, 0, 0, 4_295_128_739, 1 ether, 1 ether, DRIFT);
    }

    function _targets(Plan memory p, uint160 sp, uint256 a0, uint256 a1)
        private
        pure
        returns (uint256 target0, uint256 target1)
    {
        uint256 x;
        uint256 y;
        for (uint256 i; i < p.bands.length; ++i) {
            (uint256 u0, uint256 u1) = LiquidityMath.amountsForLiquidity(
                sp,
                SqrtPriceMath.getSqrtPriceAtTick(p.bands[i].tickLower),
                SqrtPriceMath.getSqrtPriceAtTick(p.bands[i].tickUpper),
                uint128(uint256(p.weightsBps[i]) * 1e18)
            );
            x += u0;
            y += u1;
        }
        uint256 priceX96 = Math.mulDiv(sp, sp, 1 << 96);
        uint256 value = Math.mulDiv(a0, priceX96, 1 << 96) + a1;
        uint256 denominator = Math.mulDiv(x, priceX96, 1 << 96) + y;
        target0 = Math.mulDiv(x, value, denominator);
        target1 = Math.mulDiv(y, value, denominator);
    }

    function _validate(Strategy kind, VaultConfig memory config, int24 tick) private view {
        if (kind == Strategy.BuyTheDip) buy.validateConfig(config, tick);
        else sell.validateConfig(config, tick);
    }

    function _normalConfig() private pure returns (VaultConfig memory config) {
        config.poolKey = PoolKey({
            currency0: Currency.wrap(address(1)),
            currency1: Currency.wrap(address(2)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        config.strategy = Strategy.NormalLP;
        config.shapeId = 2;
        config.centerTick = 0;
        config.ticksLeft = 120;
        config.ticksRight = 120;
        config.driftTicks = 60;
    }

    function _oneSidedConfig(Strategy strategy, bool baseIsCurrency0, bool below)
        private
        pure
        returns (VaultConfig memory config)
    {
        config = _normalConfig();
        config.strategy = strategy;
        config.shapeId = 3;
        config.driftTicks = 0;
        config.trailTicks = 60;
        config.lockOnFill = true;
        config.baseIsCurrency0 = baseIsCurrency0;
        config.ticksLeft = below ? int24(120) : int24(0);
        config.ticksRight = below ? int24(0) : int24(120);
    }

    function _bands(int24 lower, int24 upper) private pure returns (Band[] memory bands) {
        bands = new Band[](1);
        bands[0] = Band({tickLower: lower, tickUpper: upper, tokenId: 1, liquidity: 1});
    }

    function _assertTrigger(
        NormalLPStrategy strategy,
        VaultConfig memory config,
        int24 tick,
        Band[] memory bands,
        bool expected,
        bytes32 reason
    ) private pure {
        (bool needed, bytes32 actual) = strategy.checkTrigger(config, tick, bands);
        assertEq(needed, expected);
        assertEq(actual, reason);
    }

    function _assertTrigger(
        BuyTheDipStrategy strategy,
        VaultConfig memory config,
        int24 tick,
        Band[] memory bands,
        bool expected,
        bytes32 reason
    ) private pure {
        (bool needed, bytes32 actual) = strategy.checkTrigger(config, tick, bands);
        assertEq(needed, expected);
        assertEq(actual, reason);
    }

    function _assertTrigger(
        SellThePumpStrategy strategy,
        VaultConfig memory config,
        int24 tick,
        Band[] memory bands,
        bool expected,
        bytes32 reason
    ) private pure {
        (bool needed, bytes32 actual) = strategy.checkTrigger(config, tick, bands);
        assertEq(needed, expected);
        assertEq(actual, reason);
    }

    function _assertWeights(uint16[] memory weights) private pure {
        uint256 total;
        for (uint256 i; i < weights.length; ++i) {
            total += weights[i];
        }
        assertEq(total, 10_000);
    }
}
