// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolManager} from "uni-test/v4-core/src/PoolManager.sol";
import {IPoolManager} from "uni-test/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "uni-test/v4-core/src/interfaces/IHooks.sol";
import {Currency as V4Currency} from "uni-test/v4-core/src/types/Currency.sol";
import {PoolId} from "uni-test/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {PoolKey as V4PoolKey} from "uni-test/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "uni-test/v4-core/src/types/BalanceDelta.sol";
import {TickMath as V4TickMath} from "uni-test/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "uni-test/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "uni-test/v4-core/src/test/PoolSwapTest.sol";
import {StateView} from "uni-test/v4-periphery/src/lens/StateView.sol";
import {IPoolManager as IPoolManagerP} from "uni-test/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PriceGuard} from "../../src/PriceGuard.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {IStateViewLike} from "../../src/interfaces/external/IStateViewLike.sol";
import {Band, Currency, PoolKey} from "../../src/libraries/Types.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {PoolIdLib} from "../../src/libraries/PoolIdLib.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {DepositPlanner} from "../utils/DepositPlanner.sol";
import {MockAggregator, MockStateView, PriceGuardHarness} from "../mocks/PriceGuardMocks.sol";

contract DecimalsToken is ERC20 {
    uint8 private immutable _d;

    constructor(uint8 d) ERC20("T", "T") {
        _d = d;
    }

    function decimals() public view override returns (uint8) {
        return _d;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @dev End-to-end tests against the REAL Uniswap v4 PoolManager and the REAL periphery StateView, deployed
 *      in-process. This replaces the mocked StateView of the unit tests and stands in for the mainnet fork tests
 *      (which need an RPC): it proves that our pool ids, StateView ABI, tick maths, liquidity maths and shape
 *      bands agree with Uniswap's own contracts.
 */
contract RealV4IntegrationTest is Test {
    using PoolIdLib for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    // mainnet addresses, with test tokens etched on them so the currency ordering matches production (USDC < WETH)
    address internal constant USDC_ADDR = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH_ADDR = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    PoolManager internal manager;
    StateView internal stateView;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;
    PriceGuardHarness internal guard;
    ShapeLibrary internal shapes;
    MockAggregator internal feed;
    DecimalsToken internal usdc;
    DecimalsToken internal weth;

    receive() external payable {}

    function setUp() public {
        vm.warp(10 days);
        manager = new PoolManager(address(this));
        stateView = new StateView(IPoolManagerP(address(manager)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        shapes = new ShapeLibrary();

        vm.etch(USDC_ADDR, address(new DecimalsToken(6)).code);
        vm.etch(WETH_ADDR, address(new DecimalsToken(18)).code);
        usdc = DecimalsToken(USDC_ADDR);
        weth = DecimalsToken(WETH_ADDR);
        for (uint256 i; i < 2; ++i) {
            DecimalsToken t = i == 0 ? usdc : weth;
            t.mint(address(this), 1e36);
            t.approve(address(lpRouter), type(uint256).max);
            t.approve(address(swapRouter), type(uint256).max);
        }
        vm.deal(address(this), 1_000_000 ether);

        guard = new PriceGuardHarness(MockStateView(address(stateView)), address(0), WETH_ADDR, address(this));
        feed = new MockAggregator(8);
        feed.setAnswer(2000e8, block.timestamp);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Pool ids and the real StateView
    // ------------------------------------------------------------------------------------------------------------

    function test_our_pool_id_and_the_real_state_view_agree() public {
        PoolKey memory key = _nativeUsdcKey();
        uint160 sqrtPrice = guard.sqrtFromRatio(2000e6, 1e18);
        manager.initialize(_v4(key), sqrtPrice);

        (uint160 viaStateView,,,) = stateView.getSlot0(_poolId(key));
        assertEq(viaStateView, sqrtPrice, "StateView must be addressable with PoolIdLib.toId");

        // The guard reads through the same ABI.
        guard.setPairConfig(key, _chainlinkConfig(false));
        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
        assertTrue(trusted);
        assertEq(devBps, 0);
    }

    function test_uninitialized_real_pool_cannot_be_configured() public {
        PoolKey memory key = _nativeUsdcKey();
        vm.expectRevert(PriceGuard.InvalidInitialPrice.selector);
        guard.setPairConfig(key, _chainlinkConfig(false));
    }

    // ------------------------------------------------------------------------------------------------------------
    // ShapeLibrary bands and LiquidityMath against the real PoolManager
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Adds liquidity for every ShapeLibrary band of every preset and compares what the real PoolManager
     *      charges with `LiquidityMath`. Uniswap rounds amounts up when adding liquidity and `LiquidityMath` rounds
     *      down, so the difference is 0, 1 or 2 units per band and token, never negative.
     */
    function test_every_preset_bands_charge_what_liquidity_math_predicts_native_pool() public {
        PoolKey memory key = _nativeUsdcKey();
        uint160 sqrtPrice = guard.sqrtFromRatio(2000e6, 1e18);
        manager.initialize(_v4(key), sqrtPrice);
        (, int24 tick,,) = stateView.getSlot0(_poolId(key));

        uint256 salt;
        for (uint8 shape; shape < 8; ++shape) {
            if (shape == 6) continue; // full range is covered separately (it needs far larger amounts)
            (Band[] memory bands, uint16[] memory weights) =
                shapes.computeBands(shape, tick, 3000, 3000, key.tickSpacing);
            for (uint256 i; i < bands.length; ++i) {
                uint128 liquidity = uint128(uint256(weights[i]) * 1e12);
                _assertBandCharge(key, bands[i], liquidity, bytes32(++salt));
            }
        }
    }

    function test_every_preset_bands_charge_what_liquidity_math_predicts_erc20_pool() public {
        PoolKey memory key = _usdcWethKey();
        uint160 sqrtPrice = guard.sqrtFromRatio(1e18, 2000e6);
        manager.initialize(_v4(key), sqrtPrice);
        (, int24 tick,,) = stateView.getSlot0(_poolId(key));

        uint256 salt;
        for (uint8 shape; shape < 8; ++shape) {
            if (shape == 6) continue;
            (Band[] memory bands, uint16[] memory weights) =
                shapes.computeBands(shape, tick, 3000, 3000, key.tickSpacing);
            for (uint256 i; i < bands.length; ++i) {
                uint128 liquidity = uint128(uint256(weights[i]) * 1e8);
                _assertBandCharge(key, bands[i], liquidity, bytes32(++salt));
            }
        }
    }

    function _assertBandCharge(PoolKey memory key, Band memory band, uint128 liquidity, bytes32 salt) internal {
        (uint160 sp,,,) = stateView.getSlot0(_poolId(key));
        (uint256 predicted0, uint256 predicted1) = LiquidityMath.amountsForLiquidity(
            sp,
            SqrtPriceMath.getSqrtPriceAtTick(band.tickLower),
            SqrtPriceMath.getSqrtPriceAtTick(band.tickUpper),
            liquidity
        );
        BalanceDelta delta = lpRouter.modifyLiquidity{value: 100_000 ether}(
            _v4(key),
            IPoolManager.ModifyLiquidityParams({
                tickLower: band.tickLower,
                tickUpper: band.tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            ""
        );
        uint256 charged0 = uint256(int256(-delta.amount0()));
        uint256 charged1 = uint256(int256(-delta.amount1()));
        assertGe(charged0, predicted0, "real charge below the rounded-down prediction (token0)");
        assertGe(charged1, predicted1, "real charge below the rounded-down prediction (token1)");
        assertLe(charged0 - predicted0, 2, "token0 rounding gap");
        assertLe(charged1 - predicted1, 2, "token1 rounding gap");
    }

    /**
     * @dev The guide's deposit planning (5.1 and 5.3) end to end against the real pool: scale the weighted bands to
     *      the scarcer token, add liquidity, and compare with what the caller was willing to pay.
     *      Note for M4: Uniswap rounds the charge UP by up to 2 units per band and token, while the planner rounds
     *      down. Here the planner's own rounding keeps the charge under the budget, but a planner that spends the
     *      budget exactly could be charged a few units more, so the vault should not pass the deposited amount as a
     *      hard `amountMax` without a small margin.
     */
    function test_deposit_planning_for_a_shape_against_the_real_pool() public {
        PoolKey memory key = _nativeUsdcKey();
        manager.initialize(_v4(key), guard.sqrtFromRatio(2000e6, 1e18));
        (uint160 sp, int24 tick,,) = stateView.getSlot0(_poolId(key));

        uint256 a0 = 10 ether;
        uint256 a1 = 100_000e6; // plenty of USDC, so ETH is the scarcer token
        (Band[] memory bands, uint16[] memory weights) = shapes.computeBands(0, tick, 4000, 4000, key.tickSpacing);
        uint128[] memory liquidities = DepositPlanner.plan(sp, bands, weights, a0, a1);

        uint256 charged0;
        uint256 charged1;
        for (uint256 i; i < bands.length; ++i) {
            if (liquidities[i] == 0) continue;
            BalanceDelta d = lpRouter.modifyLiquidity{value: 100 ether}(
                _v4(key),
                IPoolManager.ModifyLiquidityParams({
                    tickLower: bands[i].tickLower,
                    tickUpper: bands[i].tickUpper,
                    liquidityDelta: int256(uint256(liquidities[i])),
                    salt: bytes32(i)
                }),
                ""
            );
            charged0 += uint256(int256(-d.amount0()));
            charged1 += uint256(int256(-d.amount1()));
        }
        emit log_named_uint("planned token0 budget", a0);
        emit log_named_uint("charged token0", charged0);
        emit log_named_uint("charged token1", charged1);

        // Rounding can push the charge a few units above the budget, but never by more than 2 per band.
        assertLe(charged0, a0 + 2 * bands.length, "token0 charge far above budget");
        assertLe(charged1, a1 + 2 * bands.length, "token1 charge far above budget");
        // The scarcer token is used almost completely (dust only).
        assertGe(charged0, a0 - a0 / 1e6, "scarcer token should be used to within one part per million");
    }

    /**
     * @dev Every Uniswap fee tier (spacing 1, 10, 60, 200) with every preset, including the single tick and the full
     *      range, is accepted by the real PoolManager, and removing the liquidity returns what was charged up to the
     *      rounding Uniswap applies (down on removal, up on addition: at most 2 units per band and token).
     */
    function test_all_fee_tiers_and_presets_round_trip_through_the_real_pool() public {
        uint24[4] memory fees = [uint24(100), 500, 3000, 10_000];
        int24[4] memory spacings = [int24(1), 10, 60, 200];
        for (uint256 t; t < fees.length; ++t) {
            PoolKey memory key =
                PoolKey(Currency.wrap(address(0)), Currency.wrap(USDC_ADDR), fees[t], spacings[t], address(0));
            manager.initialize(_v4(key), guard.sqrtFromRatio(2000e6, 1e18));
            (, int24 tick,,) = stateView.getSlot0(_poolId(key));
            for (uint8 shape; shape < 8; ++shape) {
                (Band[] memory bands, uint16[] memory weights) =
                    shapes.computeBands(shape, tick, 5000, 5000, spacings[t]);
                for (uint256 i; i < bands.length; ++i) {
                    _roundTrip(key, bands[i], uint128(uint256(weights[i]) * 1e8), bytes32(uint256(shape) * 16 + i));
                }
            }
        }
    }

    function _roundTrip(PoolKey memory key, Band memory band, uint128 liquidity, bytes32 salt) internal {
        BalanceDelta added = lpRouter.modifyLiquidity{value: 100_000 ether}(
            _v4(key),
            IPoolManager.ModifyLiquidityParams(band.tickLower, band.tickUpper, int256(uint256(liquidity)), salt),
            ""
        );
        BalanceDelta removed = lpRouter.modifyLiquidity(
            _v4(key),
            IPoolManager.ModifyLiquidityParams(band.tickLower, band.tickUpper, -int256(uint256(liquidity)), salt),
            ""
        );
        int256 net0 = int256(added.amount0()) + int256(removed.amount0());
        int256 net1 = int256(added.amount1()) + int256(removed.amount1());
        assertLe(net0, 0, "removal cannot return more than was charged");
        assertLe(net1, 0, "removal cannot return more than was charged");
        assertGe(net0, -2, "token0 round-trip loss above 2 units");
        assertGe(net1, -2, "token1 round-trip loss above 2 units");
    }

    /**
     * @dev Pools at the extremes of the tick domain: bands are clamped to the last usable tick for the spacing and the
     *      real PoolManager accepts them.
     */
    function test_bands_at_the_edges_of_the_tick_domain_are_accepted_by_the_real_pool() public {
        int24[2] memory startTicks = [int24(880_000), int24(-880_000)];
        for (uint256 e; e < 2; ++e) {
            PoolKey memory key =
                PoolKey(Currency.wrap(address(0)), Currency.wrap(USDC_ADDR), 3000 + uint24(e), 60, address(0));
            manager.initialize(_v4(key), SqrtPriceMath.getSqrtPriceAtTick(startTicks[e]));
            (, int24 tick,,) = stateView.getSlot0(_poolId(key));
            assertEq(tick, startTicks[e]);
            for (uint8 shape; shape < 8; ++shape) {
                (Band[] memory bands, uint16[] memory weights) = shapes.computeBands(shape, tick, 30_000, 30_000, 60);
                assertLe(bands[bands.length - 1].tickUpper, 887_220);
                assertGe(bands[0].tickLower, -887_220);
                for (uint256 i; i < bands.length; ++i) {
                    _assertBandCharge(
                        key, bands[i], uint128(uint256(weights[i]) / 1000), bytes32(uint256(shape) * 16 + i)
                    );
                }
            }
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // PriceGuard against real swaps
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Pushes the real pool price down with a ladder of real swaps. After every swap the guard's verdict and
     *      deviation equal an independent computation from the real slot0, and trust flips exactly when the
     *      deviation crosses the limit.
     */
    function test_guard_tracks_a_ladder_of_real_swaps_native_pool() public {
        PoolKey memory key = _nativeUsdcKey();
        _seedLiquidity(key, guard.sqrtFromRatio(2000e6, 1e18), 1e13);
        guard.setPairConfig(key, _chainlinkConfig(false));

        bool everTrusted;
        bool everUntrusted;
        bool previousTrusted = true;
        for (uint256 step; step < 40; ++step) {
            _swap(key, true, 4 ether); // sell ETH: price falls
            (uint160 sp,,,) = stateView.getSlot0(_poolId(key));
            uint256 expectedDev = _independentDeviation(sp, 2000e8, 8, 18, 6);

            (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
            assertEq(devBps, expectedDev, "guard deviation must equal the independent computation");
            assertEq(trusted, expectedDev <= 100, "trust must flip exactly at the limit");
            if (trusted) everTrusted = true;
            else everUntrusted = true;
            if (!trusted) previousTrusted = false;
            // once untrusted while price keeps falling it must stay untrusted
            if (!previousTrusted) assertFalse(trusted);
        }
        assertTrue(everTrusted, "the ladder starts inside the tolerance");
        assertTrue(everUntrusted, "and ends outside it");
    }

    /**
     * @dev The USDC/WETH ERC-20 pool where token0 (USDC, 6 decimals) has fewer decimals than token1 (WETH, 18): the
     *      case that the guide's inverted-feed formula got wrong. Ethereum mainnet orders these two tokens exactly
     *      this way, so this is the production configuration of the most common ERC-20 pair.
     */
    function test_inverted_feed_against_the_real_usdc_weth_pool() public {
        PoolKey memory key = _usdcWethKey();
        _seedLiquidity(key, guard.sqrtFromRatio(1e18, 2000e6), 1e15);

        // the old (swapped-ratio) maths cannot even be configured: wrong orientation is rejected
        vm.expectRevert(PriceGuard.InvalidInitialPrice.selector);
        guard.setPairConfig(key, _chainlinkConfig(false));

        guard.setPairConfig(key, _chainlinkConfig(true));
        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
        assertTrue(trusted);
        assertEq(devBps, 0);

        // Oracle moves 0.5%: still inside the 1% tolerance. 2% : outside.
        feed.setAnswer(2010e8, block.timestamp);
        (trusted,) = guard.isPriceTrusted(key);
        assertTrue(trusted);
        feed.setAnswer(2040e8, block.timestamp);
        (trusted,) = guard.isPriceTrusted(key);
        assertFalse(trusted);
        feed.setAnswer(2000e8, block.timestamp);

        // Real swaps: buying WETH with USDC (zeroForOne) pushes the WETH price up, i.e. the oracle ETH/USD reference
        // (inverted) disagrees more and more.
        for (uint256 step; step < 30; ++step) {
            _swap(key, true, 20_000e6);
            (uint160 sp,,,) = stateView.getSlot0(_poolId(key));
            // reference in raw WETH-per-USDC terms: 1e18 / (2000e6) -> the pool's own units
            uint256 expectedDev = _independentDeviationInverted(sp, 2000e8, 8, 6, 18);
            (trusted, devBps) = guard.isPriceTrusted(key);
            assertEq(devBps, expectedDev, "inverted guard deviation must equal the independent computation");
            assertEq(trusted, expectedDev <= 100);
        }
    }

    /**
     * @dev What a manipulator can gain from a deposit-style valuation at the manipulated price, relative to the
     *      oracle value, never exceeds the deviation the guard allows. Value is measured in token1 units for a fixed
     *      basket of 1 ETH and 2000 USDC.
     */
    function test_valuation_error_under_manipulation_is_bounded_by_the_guard_tolerance() public {
        PoolKey memory key = _nativeUsdcKey();
        _seedLiquidity(key, guard.sqrtFromRatio(2000e6, 1e18), 1e13);
        guard.setPairConfig(key, _chainlinkConfig(false));

        uint256 maxMispricingBps;
        uint256 maxDeviationReached;
        for (uint256 step; step < 40; ++step) {
            _swap(key, true, 1 ether);
            (bool trusted, uint256 priceDeviation) = guard.isPriceTrusted(key);
            if (!trusted) break;
            if (priceDeviation > maxDeviationReached) maxDeviationReached = priceDeviation;
            (uint160 sp,,,) = stateView.getSlot0(_poolId(key));
            uint256 poolPriceX96 = Math.mulDiv(sp, sp, 1 << 96); // token1 raw per token0 raw, Q96
            uint256 oraclePriceX96 = Math.mulDiv(2000e6, 1 << 96, 1e18);
            uint256 basket0 = 1 ether;
            uint256 basket1 = 2000e6;
            uint256 poolValue = Math.mulDiv(basket0, poolPriceX96, 1 << 96) + basket1;
            uint256 oracleValue = Math.mulDiv(basket0, oraclePriceX96, 1 << 96) + basket1;
            uint256 diff = poolValue > oracleValue ? poolValue - oracleValue : oracleValue - poolValue;
            uint256 mispricing = Math.mulDiv(diff, 10_000, oracleValue);
            if (mispricing > maxMispricingBps) maxMispricingBps = mispricing;
            assertLe(mispricing, 100, "valuation error above the guard tolerance while trusted");
        }
        emit log_named_uint("largest valuation error while trusted (bps)", maxMispricingBps);
        assertGt(maxDeviationReached, 80, "the ladder must reach the edge of the tolerance, or the test proves nothing");
        assertLe(maxMispricingBps, maxDeviationReached, "value error cannot exceed the price deviation");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _seedLiquidity(PoolKey memory key, uint160 sqrtPrice, uint256 weightScale) internal {
        manager.initialize(_v4(key), sqrtPrice);
        (, int24 tick,,) = stateView.getSlot0(_poolId(key));
        (Band[] memory bands, uint16[] memory weights) = shapes.computeBands(0, tick, 20_000, 20_000, key.tickSpacing);
        for (uint256 i; i < bands.length; ++i) {
            lpRouter.modifyLiquidity{value: 500_000 ether}(
                _v4(key),
                IPoolManager.ModifyLiquidityParams({
                    tickLower: bands[i].tickLower,
                    tickUpper: bands[i].tickUpper,
                    liquidityDelta: int256(uint256(weights[i]) * weightScale),
                    salt: bytes32(i)
                }),
                ""
            );
        }
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swap{value: Currency.unwrap(key.currency0) == address(0) && zeroForOne ? amountIn : 0}(
            _v4(key),
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? V4TickMath.MIN_SQRT_PRICE + 1 : V4TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /**
     * @dev Deviation of the pool from a direct feed (token1 per token0), computed without the guard.
     */
    function _independentDeviation(uint160 sp, uint256 answer, uint8 fd, uint8 d0, uint8 d1)
        internal
        view
        returns (uint256)
    {
        uint160 refSqrt = guard.sqrtFromRatio(answer * 10 ** d1, 10 ** fd * 10 ** d0);
        return _deviation(sp, refSqrt);
    }

    /**
     * @dev Deviation for a feed that quotes token0 per token1 (inverted), derived from first principles:
     *      raw price (token1 raw per token0 raw) = 10**fd * 10**d1 / (answer * 10**d0).
     */
    function _independentDeviationInverted(uint160 sp, uint256 answer, uint8 fd, uint8 d0, uint8 d1)
        internal
        view
        returns (uint256)
    {
        uint160 refSqrt = guard.sqrtFromRatio(10 ** fd * 10 ** d1, answer * 10 ** d0);
        return _deviation(sp, refSqrt);
    }

    function _deviation(uint160 sp, uint160 refSqrt) internal pure returns (uint256) {
        uint256 refP = Math.mulDiv(refSqrt, refSqrt, 1 << 96);
        uint256 poolP = Math.mulDiv(sp, sp, 1 << 96);
        uint256 diff = poolP > refP ? poolP - refP : refP - poolP;
        return Math.mulDiv(diff, 10_000, refP);
    }

    function _chainlinkConfig(bool invert) internal view returns (IPriceGuard.PairConfig memory c) {
        c.chainlinkFeed = address(feed);
        c.invertFeed = invert;
        c.maxStaleness = 1 hours;
        c.minAnswer = 100e8;
        c.maxAnswer = 20_000e8;
        c.maxDeviationBps = 100;
    }

    function _nativeUsdcKey() internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(USDC_ADDR), 500, 10, address(0));
    }

    function _usdcWethKey() internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(USDC_ADDR), Currency.wrap(WETH_ADDR), 500, 10, address(0));
    }

    function _poolId(PoolKey memory key) internal pure returns (PoolId) {
        return PoolId.wrap(key.toId());
    }

    function _v4(PoolKey memory key) internal pure returns (V4PoolKey memory) {
        return V4PoolKey({
            currency0: V4Currency.wrap(Currency.unwrap(key.currency0)),
            currency1: V4Currency.wrap(Currency.unwrap(key.currency1)),
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: IHooks(key.hooks)
        });
    }
}
