// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {PriceGuard} from "../../src/PriceGuard.sol";
import {
    MockToken,
    MockExtremeDecimalsToken,
    MockStateView,
    MockAggregator,
    MockMalformedV3Pool,
    MockBadAggregator,
    MockV3Pool,
    MockBrokenV3Pool,
    PriceGuardHarness
} from "../mocks/PriceGuardMocks.sol";
import {Currency, PoolKey} from "../../src/libraries/Types.sol";
import {PoolIdLib} from "../../src/libraries/PoolIdLib.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";

contract PriceGuardTest is Test {
    using PoolIdLib for PoolKey;

    MockToken internal weth;
    MockToken internal usdc;
    MockStateView internal stateView;
    MockAggregator internal ethUsdFeed;
    PriceGuardHarness internal guard;
    PoolKey internal key;
    address internal timelock = address(0xBEEF);

    function setUp() public {
        vm.warp(10 days);
        weth = new MockToken("Wrapped Ether", "WETH", 18);
        usdc = new MockToken("USD Coin", "USDC", 6);
        stateView = new MockStateView();
        ethUsdFeed = new MockAggregator(8);
        guard = new PriceGuardHarness(stateView, address(0), address(weth), address(this));

        key = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });

        stateView.setSqrtPrice(key.toId(), guard.sqrtFromRatio(2000 * 10 ** 6, 10 ** 18));
        ethUsdFeed.setAnswer(2000e8, block.timestamp);
    }

    function test_chainlink_price_inside_deviation_is_trusted() public {
        guard.setPairConfig(key, _chainlinkConfig());

        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);

        assertTrue(trusted);
        assertEq(devBps, 0);
    }

    function test_config_getter_returns_stored_config_and_decimals() public {
        IPriceGuard.PairConfig memory expected = _chainlinkConfig();
        guard.setPairConfig(key, expected);

        (IPriceGuard.PairConfig memory actual, uint8 decimals0, uint8 decimals1) = guard.configOf(key);

        assertEq(actual.chainlinkFeed, expected.chainlinkFeed);
        assertEq(actual.maxDeviationBps, expected.maxDeviationBps);
        assertEq(decimals0, 18);
        assertEq(decimals1, 6);
    }

    function test_constructor_rejects_zero_required_addresses() public {
        vm.expectRevert(PriceGuard.ZeroAddress.selector);
        this.deployHarness(MockStateView(address(0)), address(0), address(weth), address(this));

        vm.expectRevert(PriceGuard.ZeroAddress.selector);
        this.deployHarness(stateView, address(0), address(0), address(this));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        this.deployHarness(stateView, address(0), address(weth), address(0));

        assertTrue(address(this.deployHarness(stateView, address(0), address(weth), address(this))) != address(0));
    }

    // An expected revert inside a `new` of another file's contract ends the test early (forge deploys it through a
    // cheatcode), so each reverting deployment goes through an external self-call and the checks after it run.
    function deployHarness(MockStateView stateView_, address sequencer, address wrapper, address owner_)
        external
        returns (PriceGuardHarness)
    {
        return new PriceGuardHarness(stateView_, sequencer, wrapper, owner_);
    }

    function test_deviation_above_limit_is_not_trusted() public {
        guard.setPairConfig(key, _chainlinkConfig());
        stateView.setSqrtPrice(key.toId(), guard.sqrtFromRatio(2101 * 10 ** 6, 10 ** 18));

        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);

        assertFalse(trusted);
        assertGt(devBps, 100);
    }

    function test_deviation_exactly_at_limit_is_trusted() public {
        guard.setPairConfig(key, _chainlinkConfig());
        stateView.setSqrtPrice(key.toId(), guard.sqrtFromRatio(2020 * 10 ** 6, 10 ** 18));

        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);

        assertTrue(trusted);
        assertLe(devBps, 100);

        stateView.setSqrtPrice(key.toId(), guard.sqrtFromRatio(2021 * 10 ** 6, 10 ** 18));
        (trusted, devBps) = guard.isPriceTrusted(key);
        assertFalse(trusted);
        assertGt(devBps, 100);
    }

    function test_stale_zero_negative_and_clamped_chainlink_answers_are_not_trusted() public {
        guard.setPairConfig(key, _chainlinkConfig());

        ethUsdFeed.setAnswer(2000e8, block.timestamp - 2 hours);
        _assertNotTrustedMaxDeviation();

        ethUsdFeed.setAnswer(0, block.timestamp);
        _assertNotTrustedMaxDeviation();

        ethUsdFeed.setAnswer(-1, block.timestamp);
        _assertNotTrustedMaxDeviation();

        ethUsdFeed.setAnswer(999e8, block.timestamp);
        _assertNotTrustedMaxDeviation();

        ethUsdFeed.setAnswer(5001e8, block.timestamp);
        _assertNotTrustedMaxDeviation();
    }

    function test_future_reverted_and_runtime_bad_chainlink_answers_are_not_trusted() public {
        guard.setPairConfig(key, _chainlinkConfig());

        ethUsdFeed.setAnswer(2000e8, block.timestamp + 1);
        _assertNotTrustedMaxDeviation();

        ethUsdFeed.setAnswer(2000e8, block.timestamp);
        ethUsdFeed.setRevertLatestRoundData(true);
        _assertNotTrustedMaxDeviation();

        ethUsdFeed.setRevertLatestRoundData(false);
        ethUsdFeed.setRevertDecimals(true);
        _assertNotTrustedMaxDeviation();
    }

    function test_chainlink_arithmetic_overflow_falls_back_to_v3() public {
        MockV3Pool v3Pool = new MockV3Pool(address(weth), address(usdc));
        v3Pool.setTickDelta(0);

        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.minAnswer = 1;
        config.maxAnswer = type(uint256).max;
        config.v3Pool = address(v3Pool);
        config.twapWindow = 600;
        ethUsdFeed.setAnswer(type(int256).max, block.timestamp);
        stateView.setSqrtPrice(key.toId(), SqrtPriceMath.getSqrtPriceAtTick(0));

        guard.setPairConfig(key, config);

        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
        assertTrue(trusted);
        assertEq(devBps, 0);
    }

    function test_invalid_oracle_decimals_are_not_trusted_and_can_fallback_to_v3() public {
        MockAggregator invalidDecimalsFeed = new MockAggregator(78);
        invalidDecimalsFeed.setAnswer(2000e8, block.timestamp);
        MockV3Pool v3Pool = new MockV3Pool(address(weth), address(usdc));
        v3Pool.setTickDelta(0);

        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.chainlinkFeed = address(invalidDecimalsFeed);
        config.minAnswer = 1;
        config.maxAnswer = type(uint256).max;
        config.v3Pool = address(v3Pool);
        config.twapWindow = 600;
        stateView.setSqrtPrice(key.toId(), SqrtPriceMath.getSqrtPriceAtTick(0));

        guard.setPairConfig(key, config);
        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
        assertTrue(trusted);
        assertEq(devBps, 0);
    }

    function test_extreme_token_decimals_do_not_overflow_chainlink_path() public {
        MockExtremeDecimalsToken extreme = new MockExtremeDecimalsToken();
        PoolKey memory extremeKey = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(extreme)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        MockAggregator feed = new MockAggregator(8);
        feed.setAnswer(2000e8, block.timestamp);

        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.chainlinkFeed = address(feed);
        config.minAnswer = 1;
        config.maxAnswer = type(uint256).max;
        vm.expectRevert(PriceGuard.InvalidInitialPrice.selector);
        guard.setPairConfig(extremeKey, config);
    }

    function test_missing_config_reverts() public {
        vm.expectRevert(PriceGuard.NoConfig.selector);
        guard.isPriceTrusted(key);
    }

    function test_only_owner_can_set_config() public {
        vm.prank(address(0x1234));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0x1234)));
        guard.setPairConfig(key, _chainlinkConfig());
    }

    function test_two_step_ownership_lifecycle_transfers_control_to_timelock() public {
        guard.transferOwnership(timelock);

        assertEq(guard.owner(), address(this));
        assertEq(guard.pendingOwner(), timelock);

        vm.prank(timelock);
        guard.acceptOwnership();

        assertEq(guard.owner(), timelock);
        assertEq(guard.pendingOwner(), address(0));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        guard.setPairConfig(key, _chainlinkConfig());

        vm.prank(timelock);
        guard.setPairConfig(key, _chainlinkConfig());
    }

    function test_pending_owner_cannot_configure_before_acceptance() public {
        guard.transferOwnership(timelock);

        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, timelock));
        guard.setPairConfig(key, _chainlinkConfig());
    }

    function test_old_owner_rejected_after_acceptance() public {
        guard.transferOwnership(timelock);
        vm.prank(timelock);
        guard.acceptOwnership();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        guard.transferOwnership(address(0xCAFE));
    }

    function test_only_pending_owner_can_accept_and_zero_transfer_is_rejected() public {
        guard.transferOwnership(timelock);

        vm.prank(address(0xCAFE));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xCAFE)));
        guard.acceptOwnership();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        guard.transferOwnership(address(0));
    }

    function test_config_validation_rejects_bad_inputs() public {
        IPriceGuard.PairConfig memory config = _chainlinkConfig();

        config.chainlinkFeed = address(0);
        vm.expectRevert(PriceGuard.NoReference.selector);
        guard.setPairConfig(key, config);

        config = _chainlinkConfig();
        config.maxDeviationBps = 0;
        vm.expectRevert(PriceGuard.InvalidDeviation.selector);
        guard.setPairConfig(key, config);

        config = _chainlinkConfig();
        config.maxDeviationBps = 1001;
        vm.expectRevert(PriceGuard.InvalidDeviation.selector);
        guard.setPairConfig(key, config);

        config = _chainlinkConfig();
        config.minAnswer = 10;
        config.maxAnswer = 10;
        vm.expectRevert(PriceGuard.InvalidAnswerBounds.selector);
        guard.setPairConfig(key, config);

        config = _chainlinkConfig();
        config.chainlinkFeed = address(new MockBadAggregator());
        vm.expectRevert(PriceGuard.InvalidFeed.selector);
        guard.setPairConfig(key, config);
    }

    function test_sequencer_down_and_grace_period_are_not_trusted() public {
        MockAggregator sequencer = new MockAggregator(0);
        PriceGuardHarness l2Guard = new PriceGuardHarness(stateView, address(sequencer), address(weth), address(this));
        sequencer.setAnswer(1, block.timestamp - 2 hours);
        l2Guard.setPairConfig(key, _chainlinkConfig());

        (bool trusted, uint256 devBps) = l2Guard.isPriceTrusted(key);
        assertFalse(trusted);
        assertEq(devBps, type(uint256).max);

        sequencer.setAnswer(0, block.timestamp - 10 minutes);
        (trusted, devBps) = l2Guard.isPriceTrusted(key);
        assertFalse(trusted);
        assertEq(devBps, type(uint256).max);

        sequencer.setAnswer(0, block.timestamp - 2 hours);
        (trusted, devBps) = l2Guard.isPriceTrusted(key);
        assertTrue(trusted);
        assertEq(devBps, 0);
    }

    function test_sequencer_feed_revert_is_not_trusted() public {
        MockAggregator sequencer = new MockAggregator(0);
        PriceGuardHarness l2Guard = new PriceGuardHarness(stateView, address(sequencer), address(weth), address(this));
        sequencer.setAnswer(0, block.timestamp - 2 hours);
        sequencer.setRevertLatestRoundData(true);
        l2Guard.setPairConfig(key, _chainlinkConfig());

        (bool trusted, uint256 devBps) = l2Guard.isPriceTrusted(key);
        assertFalse(trusted);
        assertEq(devBps, type(uint256).max);
    }

    function test_zero_max_staleness_requires_current_block_timestamp() public {
        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.maxStaleness = 0;
        guard.setPairConfig(key, config);

        ethUsdFeed.setAnswer(2000e8, block.timestamp - 1);
        _assertNotTrustedMaxDeviation();

        ethUsdFeed.setAnswer(2000e8, block.timestamp);
        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
        assertTrue(trusted);
        assertEq(devBps, 0);
    }

    function test_v3_fallback_is_used_when_chainlink_is_bad() public {
        MockV3Pool v3Pool = new MockV3Pool(address(weth), address(usdc));
        v3Pool.setTickDelta(0);

        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.v3Pool = address(v3Pool);
        config.twapWindow = 600;
        ethUsdFeed.setAnswer(0, block.timestamp);
        stateView.setSqrtPrice(key.toId(), SqrtPriceMath.getSqrtPriceAtTick(0));

        guard.setPairConfig(key, config);
        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);

        assertTrue(trusted);
        assertEq(devBps, 0);
    }

    function test_v3_reversed_order_and_floor_negative_tick() public {
        MockV3Pool v3Pool = new MockV3Pool(address(usdc), address(weth));
        v3Pool.setTickDelta(599);

        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.chainlinkFeed = address(0);
        config.v3Pool = address(v3Pool);
        config.invertV3 = true;
        config.twapWindow = 600;
        config.maxDeviationBps = 1;

        uint160 expected = SqrtPriceMath.getSqrtPriceAtTick(-1);
        stateView.setSqrtPrice(key.toId(), expected);

        guard.setPairConfig(key, config);
        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);

        assertTrue(trusted);
        assertEq(devBps, 0);
    }

    function test_v3_short_history_is_not_trusted() public {
        MockV3Pool v3Pool = new MockV3Pool(address(weth), address(usdc));
        v3Pool.setShouldRevert(true);

        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.chainlinkFeed = address(0);
        config.v3Pool = address(v3Pool);
        config.twapWindow = 600;

        vm.expectRevert(PriceGuard.InvalidInitialPrice.selector);
        guard.setPairConfig(key, config);
    }

    function test_malformed_twap_response_is_not_trusted_and_does_not_panic() public {
        MockMalformedV3Pool v3Pool = new MockMalformedV3Pool(address(weth), address(usdc));
        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.chainlinkFeed = address(0);
        config.v3Pool = address(v3Pool);
        config.twapWindow = 600;
        stateView.setSqrtPrice(key.toId(), SqrtPriceMath.getSqrtPriceAtTick(0));

        guard.setPairConfig(key, config);
        v3Pool.setShortArray(true);

        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
        assertFalse(trusted);
        assertEq(devBps, type(uint256).max);
    }

    function test_extreme_pool_sqrt_prices_do_not_overflow_deviation_check() public {
        guard.setPairConfig(key, _chainlinkConfig());

        stateView.setSqrtPrice(key.toId(), type(uint160).max);
        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
        assertFalse(trusted);
        assertGt(devBps, 100);

        stateView.setSqrtPrice(key.toId(), 0);
        (trusted, devBps) = guard.isPriceTrusted(key);
        assertFalse(trusted);
        assertEq(devBps, 10_000);
    }

    function test_v3_config_rejects_short_window_and_wrong_tokens() public {
        MockV3Pool v3Pool = new MockV3Pool(address(weth), address(usdc));
        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.v3Pool = address(v3Pool);
        config.twapWindow = 599;
        vm.expectRevert(PriceGuard.InvalidTwapWindow.selector);
        guard.setPairConfig(key, config);

        MockV3Pool wrongPool = new MockV3Pool(address(usdc), address(weth));
        config.twapWindow = 600;
        config.v3Pool = address(wrongPool);
        vm.expectRevert(PriceGuard.InvalidV3Pool.selector);
        guard.setPairConfig(key, config);

        config.v3Pool = address(new MockBrokenV3Pool());
        vm.expectRevert(PriceGuard.InvalidV3Pool.selector);
        guard.setPairConfig(key, config);
    }

    function testFuzz_sqrtFromRatio_matches_squared_ratio(uint64 numerator, uint64 denominator) public view {
        numerator = uint64(bound(numerator, 1, type(uint64).max));
        denominator = uint64(bound(denominator, 1, type(uint64).max));

        uint160 sqrtPrice = guard.sqrtFromRatio(numerator, denominator);
        uint256 squared = uint256(sqrtPrice) * sqrtPrice;
        uint256 target = MathLike.mulDiv(uint256(numerator), 1 << 192, uint256(denominator));

        assertLe(squared, target);
        assertLt(target - squared, (uint256(sqrtPrice) << 1) + 1);
    }

    function _chainlinkConfig() private view returns (IPriceGuard.PairConfig memory config) {
        config.chainlinkFeed = address(ethUsdFeed);
        config.maxStaleness = 1 hours;
        config.minAnswer = 1000e8;
        config.maxAnswer = 5000e8;
        config.maxDeviationBps = 100;
    }

    function _assertNotTrustedMaxDeviation() private view {
        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
        assertFalse(trusted);
        assertEq(devBps, type(uint256).max);
    }
}

library MathLike {
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        result = x * y / denominator;
    }
}
