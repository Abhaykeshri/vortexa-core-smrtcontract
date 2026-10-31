// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {PriceGuard} from "../../src/PriceGuard.sol";
import {Currency, PoolKey} from "../../src/libraries/Types.sol";
import {PoolIdLib} from "../../src/libraries/PoolIdLib.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {MockToken, MockStateView, MockAggregator, MockTwapPool, PriceGuardHarness} from "../mocks/PriceGuardMocks.sol";

/**
 * @dev Drives PriceGuard through random sequences of everything an owner, a stranger, a feed, a pool, the
 *      sequencer or the clock can do. Ghost variables record the model; invariants compare it with the contract.
 *      Two configurable pools are managed (WETH/USDC and native/USDC); a third is never configured.
 */
contract PriceGuardHandler is Test {
    using PoolIdLib for PoolKey;

    uint256 internal constant POOLS = 2;

    PriceGuardHarness public guard;
    MockStateView public stateView;
    MockToken public weth;
    MockToken public usdc;
    MockAggregator public sequencer;
    MockAggregator[POOLS] public feeds;
    MockTwapPool[POOLS] public twapPools;
    PoolKey[3] internal _keys;
    address[] internal _actors;

    // Model
    address public ghostOwner;
    address public ghostPending;
    bool[POOLS] public ghostConfigured;
    bytes32[POOLS] public ghostConfigHash;

    // Evidence counters
    uint256 public unauthorizedSuccesses;
    uint256 public successfulConfigs;
    uint256 public successfulTransfers;
    uint256 public acceptedOwnerships;
    uint256 public rejectedConfigAttempts;

    constructor() {
        vm.warp(30 days);
        weth = new MockToken("Wrapped Ether", "WETH", 18);
        usdc = new MockToken("USD Coin", "USDC", 6);
        stateView = new MockStateView();
        sequencer = new MockAggregator(0);
        guard = new PriceGuardHarness(stateView, address(sequencer), address(weth), address(this));
        ghostOwner = address(this);

        _actors.push(makeAddr("alice"));
        _actors.push(makeAddr("bob"));
        _actors.push(makeAddr("carol"));
        _actors.push(makeAddr("timelock"));

        _keys[0] = PoolKey(Currency.wrap(address(weth)), Currency.wrap(address(usdc)), 500, 10, address(0));
        _keys[1] = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usdc)), 500, 10, address(0));
        _keys[2] = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usdc)), 3000, 60, address(0));

        for (uint256 i; i < POOLS; ++i) {
            feeds[i] = new MockAggregator(8);
            feeds[i].setAnswer(2000e8, block.timestamp);
            twapPools[i] = new MockTwapPool(address(weth), address(usdc));
            twapPools[i].setMeanTick(-200_311);
            _alignPoolToFeed(i);
        }
        sequencer.setAnswer(0, block.timestamp - 2 hours);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Views for the invariant contract
    // ------------------------------------------------------------------------------------------------------------

    function keyAt(uint256 i) external view returns (PoolKey memory) {
        return _keys[i];
    }

    function poolCount() external pure returns (uint256) {
        return POOLS;
    }

    // ------------------------------------------------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------------------------------------------------

    function setConfig(
        uint256 callerSeed,
        uint256 poolSeed,
        uint256 flags,
        uint16 maxDeviation,
        uint32 staleness,
        uint256 minAnswer,
        uint256 maxAnswer,
        uint32 window
    ) external {
        uint256 idx = poolSeed % POOLS;
        address caller = _pickCaller(callerSeed);

        // Boundary-seeking parameters: pick from tables of edge values so that the interesting limits (0, 1, 599,
        // 600, 1000, 1001, ...) are hit often, and fall back to a bounded random value otherwise.
        IPriceGuard.PairConfig memory config;
        config.chainlinkFeed = flags & 1 != 0 ? address(feeds[idx]) : address(0);
        config.maxStaleness = uint32(_pick(staleness, [uint256(0), 3600, 2 days, 1, 7200, 0, 3600, 2 days], 2 days));
        config.minAnswer = _pick(minAnswer, [uint256(0), 1, 1000e8, 2000e8, 2000e8 + 1, 1999e8, 1000e8, 1], 3000e8);
        config.maxAnswer = _pick(maxAnswer, [uint256(0), 1, 2000e8, 2000e8 - 1, 5000e8, 9000e8, 9000e8, 5000e8], 9000e8);
        config.v3Pool = flags & 2 != 0 ? address(twapPools[idx]) : address(0);
        config.invertV3 = flags & 12 == 12; // rare: the pools are ordered like the keys
        config.twapWindow = uint32(_pick(window, [uint256(0), 599, 600, 1800, 7200, 600, 1800, 601], 7200));
        config.maxDeviationBps = uint16(_pick(maxDeviation, [uint256(0), 1, 100, 1000, 1001, 1100, 50, 65_535], 1100));

        // Give configuration a realistic chance of succeeding: refresh and align the world first.
        if (flags & 16 != 0) {
            feeds[idx].setAnswer(2000e8, block.timestamp);
            _alignPoolToFeed(idx);
        } else if (flags & 32 != 0) {
            _alignPoolToTwap(idx);
        }

        vm.prank(caller);
        try guard.setPairConfig(_keys[idx], config) {
            if (caller != ghostOwner) unauthorizedSuccesses++;
            successfulConfigs++;
            ghostConfigured[idx] = true;
            ghostConfigHash[idx] = _configHash(idx);
        } catch {
            rejectedConfigAttempts++;
        }
    }

    /**
     * @dev The real owner applies one of eight presets (five valid, three deliberately invalid) after the world is
     *      aligned, so that configured states with each kind of reference are reached reliably.
     */
    function forceConfig(uint256 poolSeed, uint256 preset) external {
        uint256 idx = poolSeed % POOLS;
        preset = preset % 8;
        feeds[idx].setAnswer(2000e8, block.timestamp);
        feeds[idx].setRevertLatestRoundData(false);
        feeds[idx].setRevertDecimals(false);
        twapPools[idx].setMeanTick(-200_311);
        twapPools[idx].setShouldRevert(false);
        _alignPoolToFeed(idx);

        IPriceGuard.PairConfig memory c;
        if (preset == 0 || preset == 2 || preset == 3 || preset == 4 || preset == 5 || preset == 6) {
            c.chainlinkFeed = address(feeds[idx]);
            c.maxStaleness = 3600;
            c.minAnswer = 1000e8;
            c.maxAnswer = 5000e8;
        }
        if (preset == 1 || preset == 2 || preset == 4 || preset == 7) {
            c.v3Pool = address(twapPools[idx]);
            c.twapWindow = 1800;
        }
        c.maxDeviationBps = 100;
        if (preset == 1) c.maxDeviationBps = 1000;
        if (preset == 2) c.maxDeviationBps = 50;
        if (preset == 3 || preset == 4) {
            c.minAnswer = 1;
            c.maxAnswer = type(uint256).max; // lets absurd answers through the bounds check
            c.maxStaleness = 2 days;
        }
        if (preset == 4) c.twapWindow = 600;
        if (preset == 5) {
            c.minAnswer = 2000e8;
            c.maxAnswer = 2000e8; // invalid: min must be strictly below max
        }
        if (preset == 6) c.maxDeviationBps = 1001; // invalid: above the cap
        if (preset == 7) c.twapWindow = 599; // invalid: below the minimum window

        vm.prank(ghostOwner);
        try guard.setPairConfig(_keys[idx], c) {
            successfulConfigs++;
            ghostConfigured[idx] = true;
            ghostConfigHash[idx] = _configHash(idx);
        } catch {
            rejectedConfigAttempts++;
        }
    }

    function moveFeed(uint256 poolSeed, uint256 mode, uint256 magnitude, uint32 age) external {
        uint256 idx = poolSeed % POOLS;
        age = uint32(bound(age, 0, 3 days));
        int256 answer;
        uint256 m = mode % 7;
        if (m == 0) answer = int256(bound(magnitude, 500e8, 6000e8));
        else if (m == 1) answer = 0;
        else if (m == 2) answer = -int256(bound(magnitude, 1, 1e9));
        else if (m == 3) answer = 1e40;
        else if (m == 4) answer = 1;
        else if (m == 5) answer = type(int256).max;
        else answer = 2000e8;
        feeds[idx].setAnswer(answer, block.timestamp - age);
    }

    function breakFeed(uint256 poolSeed, bool roundData, bool decimals_) external {
        uint256 idx = poolSeed % POOLS;
        feeds[idx].setRevertLatestRoundData(roundData);
        feeds[idx].setRevertDecimals(decimals_);
    }

    function moveTwap(uint256 poolSeed, int24 tick, bool breakHistory) external {
        uint256 idx = poolSeed % POOLS;
        twapPools[idx].setMeanTick(
            int24(bound(int256(tick), int256(SqrtPriceMath.MIN_TICK), int256(SqrtPriceMath.MAX_TICK)))
        );
        twapPools[idx].setShouldRevert(breakHistory);
    }

    function movePool(uint256 poolSeed, uint256 mode, uint256 x) external {
        uint256 idx = poolSeed % POOLS;
        uint256 m = mode % 5;
        if (m == 0) {
            stateView.setSqrtPrice(_keys[idx].toId(), 0);
        } else if (m == 1) {
            _alignPoolToFeed(idx);
        } else if (m == 2) {
            _alignPoolToFeedScaled(idx, bound(x, 5000, 20_000));
        } else if (m == 3) {
            stateView.setSqrtPrice(_keys[idx].toId(), uint160(bound(x, 1, type(uint160).max)));
        } else {
            _alignPoolToTwap(idx);
        }
    }

    function setSequencer(uint256 mode, uint32 age) external {
        age = uint32(bound(age, 0, 2 days));
        sequencer.setAnswer(mode % 3 == 0 ? int256(1) : int256(0), block.timestamp - age);
    }

    function warp(uint32 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 2 days));
    }

    function transferOwnership(uint256 callerSeed, uint256 newOwnerSeed) external {
        address caller = _pickCaller(callerSeed);
        address newOwner = newOwnerSeed % 5 == 0 ? address(0) : _actors[newOwnerSeed % _actors.length];
        vm.prank(caller);
        try guard.transferOwnership(newOwner) {
            if (caller != ghostOwner) unauthorizedSuccesses++;
            else ghostPending = newOwner;
            successfulTransfers++;
        } catch {}
    }

    function acceptOwnership(uint256 callerSeed) external {
        address caller = _pickCaller(callerSeed);
        vm.prank(caller);
        try guard.acceptOwnership() {
            if (caller != ghostPending) {
                unauthorizedSuccesses++;
            } else {
                ghostOwner = caller;
                ghostPending = address(0);
                acceptedOwnerships++;
            }
        } catch {}
    }

    // ------------------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------------------

    function _pickCaller(uint256 seed) internal view returns (address) {
        if (seed % 2 == 0) return ghostOwner;
        if (seed % 4 == 1 && ghostPending != address(0)) return ghostPending;
        return _actors[seed % _actors.length];
    }

    /**
     * @dev Half of the time returns an entry of `table` (chosen by `seed`), otherwise a random value in `[0, max]`.
     */
    function _pick(uint256 seed, uint256[8] memory table, uint256 max) internal pure returns (uint256) {
        if (seed % 2 == 0) return table[(seed / 2) % 8];
        return bound(seed / 2, 0, max);
    }

    function _configHash(uint256 idx) internal view returns (bytes32) {
        (IPriceGuard.PairConfig memory c, uint8 d0, uint8 d1) = guard.configOf(_keys[idx]);
        return keccak256(abi.encode(c, d0, d1));
    }

    function _alignPoolToFeed(uint256 idx) internal {
        _alignPoolToFeedScaled(idx, 10_000);
    }

    function _alignPoolToFeedScaled(uint256 idx, uint256 scaleBps) internal {
        int256 answer = feeds[idx].answer();
        if (answer <= 0 || answer > 1e30) return;
        try guard.sqrtFromRatio(uint256(answer) * 10 ** 6 * scaleBps / 10_000, 10 ** 26) returns (uint160 sqrtPrice) {
            stateView.setSqrtPrice(_keys[idx].toId(), sqrtPrice);
        } catch {}
    }

    function _alignPoolToTwap(uint256 idx) internal {
        stateView.setSqrtPrice(_keys[idx].toId(), SqrtPriceMath.getSqrtPriceAtTick(twapPools[idx].meanTick()));
    }
}

contract PriceGuardInvariantTest is StdInvariant, Test {
    using PoolIdLib for PoolKey;

    PriceGuardHandler internal handler;
    PriceGuardHarness internal guard;

    function setUp() public {
        handler = new PriceGuardHandler();
        guard = handler.guard();

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = PriceGuardHandler.setConfig.selector;
        selectors[1] = PriceGuardHandler.moveFeed.selector;
        selectors[2] = PriceGuardHandler.breakFeed.selector;
        selectors[3] = PriceGuardHandler.moveTwap.selector;
        selectors[4] = PriceGuardHandler.movePool.selector;
        selectors[5] = PriceGuardHandler.setSequencer.selector;
        selectors[6] = PriceGuardHandler.warp.selector;
        selectors[7] = PriceGuardHandler.transferOwnership.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        bytes4[] memory more = new bytes4[](2);
        more[0] = PriceGuardHandler.acceptOwnership.selector;
        more[1] = PriceGuardHandler.forceConfig.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: more}));
        targetContract(address(handler));
    }

    /**
     * @dev Sanity check that the handler reaches the interesting states, so the invariants below are not vacuous.
     */
    function test_handler_can_configure_trust_and_hand_over_ownership() public {
        PoolKey memory key0 = handler.keyAt(0);
        // seeds select table entries: even seed => table[seed / 2]
        // maxDeviation 100 (idx 2), staleness 3600 (idx 1), min 1000e8 (idx 2), max 5000e8 (idx 4), window 600 (idx 2)
        handler.setConfig(0, 0, 1 | 16, 4, 2, 4, 8, 4);
        assertEq(handler.successfulConfigs(), 1, "owner can configure with a fresh aligned feed");
        (bool trusted,) = guard.isPriceTrusted(key0);
        assertTrue(trusted);

        handler.setConfig(1, 1, 1 | 16, 4, 2, 4, 8, 4); // a stranger tries (odd seed, no pending owner)
        assertEq(handler.successfulConfigs(), 1);
        assertEq(handler.unauthorizedSuccesses(), 0);

        handler.transferOwnership(0, 3); // owner nominates the "timelock"
        assertEq(handler.ghostPending(), makeAddr("timelock"));
        handler.acceptOwnership(1); // the pending owner accepts
        assertEq(handler.acceptedOwnerships(), 1);
        assertEq(guard.owner(), handler.ghostOwner());
    }

    function invariant_strangers_can_never_change_state() public view {
        assertEq(handler.unauthorizedSuccesses(), 0);
    }

    function invariant_ownership_matches_the_model_and_is_never_zero() public view {
        assertEq(guard.owner(), handler.ghostOwner());
        assertEq(guard.pendingOwner(), handler.ghostPending());
        assertTrue(guard.owner() != address(0));
    }

    function invariant_configuration_changes_only_through_successful_set_calls() public view {
        for (uint256 i; i < handler.poolCount(); ++i) {
            PoolKey memory key = handler.keyAt(i);
            (IPriceGuard.PairConfig memory c, uint8 d0, uint8 d1) = guard.configOf(key);
            assertEq(c.maxDeviationBps != 0, handler.ghostConfigured(i), "configured flag drifted");
            if (handler.ghostConfigured(i)) {
                assertEq(keccak256(abi.encode(c, d0, d1)), handler.ghostConfigHash(i), "config changed unexpectedly");
            }
        }
    }

    function invariant_stored_configurations_always_satisfy_the_validation_rules() public view {
        for (uint256 i; i < handler.poolCount(); ++i) {
            (IPriceGuard.PairConfig memory c, uint8 d0, uint8 d1) = guard.configOf(handler.keyAt(i));
            if (c.maxDeviationBps == 0) continue;
            assertGe(c.maxDeviationBps, 1);
            assertLe(c.maxDeviationBps, 1000);
            assertTrue(c.chainlinkFeed != address(0) || c.v3Pool != address(0), "no reference");
            if (c.chainlinkFeed != address(0)) {
                assertGt(c.minAnswer, 0);
                assertLt(c.minAnswer, c.maxAnswer);
            }
            if (c.v3Pool != address(0)) assertGe(c.twapWindow, 600);
            assertEq(d0, 18, "currency0 is WETH or native: 18 decimals");
            assertEq(d1, 6, "currency1 is USDC: 6 decimals");
        }
    }

    /**
     * @dev Liveness plus a model check of every trusted verdict: the call never reverts for a configured pool,
     *      `trusted` is exactly `devBps <= max`, and trust implies a healthy sequencer and a usable reference.
     */
    function invariant_trust_verdicts_are_consistent_and_never_revert() public view {
        for (uint256 i; i < handler.poolCount(); ++i) {
            PoolKey memory key = handler.keyAt(i);
            (IPriceGuard.PairConfig memory c,,) = guard.configOf(key);
            if (c.maxDeviationBps == 0) continue;

            try guard.isPriceTrusted(key) returns (bool trusted, uint256 devBps) {
                assertEq(trusted, devBps <= c.maxDeviationBps, "trusted must equal devBps <= max");
                if (trusted) {
                    assertTrue(_sequencerHealthy(), "trusted while the sequencer is down or in grace");
                    assertTrue(_chainlinkUsable(i, c) || _v3Usable(i, c), "trusted without any usable reference");
                }

                // Source selection: whenever the primary oracle is usable it alone decides the verdict, whatever the
                // V3 fallback says. Skipped while the sequencer is down (then devBps is the sentinel).
                MockAggregator feed = handler.feeds(i);
                if (_sequencerHealthy() && _chainlinkUsable(i, c) && feed.answer() <= 1e30) {
                    assertEq(devBps, _modelChainlinkDeviation(i, key), "usable Chainlink must be the reference");
                }
            } catch {
                assertTrue(false, "isPriceTrusted reverted for a configured pool");
            }
        }
    }

    function invariant_unconfigured_pools_always_revert_with_no_config() public view {
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(handler.usdc())), 3000, 60, address(0));
        try guard.isPriceTrusted(key) {
            assertTrue(false, "an unconfigured pool must revert");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), PriceGuard.NoConfig.selector);
        }
        (IPriceGuard.PairConfig memory c,,) = guard.configOf(key);
        assertEq(c.maxDeviationBps, 0);
    }

    function invariant_the_guard_never_holds_assets() public view {
        assertEq(address(guard).balance, 0);
        assertEq(handler.weth().balanceOf(address(guard)), 0);
        assertEq(handler.usdc().balanceOf(address(guard)), 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Model helpers (read the mocks directly, never the guard)
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Deviation of the pool from a Chainlink-only reference (WETH/native 18 decimals, USDC 6, 8-decimal feed).
     */
    function _modelChainlinkDeviation(uint256 i, PoolKey memory key) internal view returns (uint256) {
        uint256 answer = uint256(handler.feeds(i).answer());
        uint160 refSqrt = guard.sqrtFromRatio(answer * 10 ** 6, 10 ** 26);
        uint160 poolSqrt = handler.stateView().sqrtPrices(key.toId());
        uint256 refP = Math.mulDiv(refSqrt, refSqrt, 1 << 96);
        if (refP == 0) return type(uint256).max;
        uint256 poolP = Math.mulDiv(poolSqrt, poolSqrt, 1 << 96);
        uint256 diff = poolP > refP ? poolP - refP : refP - poolP;
        return Math.mulDiv(diff, 10_000, refP);
    }

    function _sequencerHealthy() internal view returns (bool) {
        MockAggregator seq = handler.sequencer();
        uint256 updatedAt = seq.updatedAt();
        return seq.answer() == 0 && updatedAt != 0 && block.timestamp >= updatedAt && block.timestamp - updatedAt > 3600;
    }

    function _chainlinkUsable(uint256 i, IPriceGuard.PairConfig memory c) internal view returns (bool) {
        if (c.chainlinkFeed == address(0)) return false;
        MockAggregator feed = handler.feeds(i);
        if (feed.revertLatestRoundData() || feed.revertDecimals()) return false;
        int256 answer = feed.answer();
        uint256 updatedAt = feed.updatedAt();
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) return false;
        if (block.timestamp - updatedAt > c.maxStaleness) return false;
        return uint256(answer) >= c.minAnswer && uint256(answer) <= c.maxAnswer;
    }

    function _v3Usable(uint256 i, IPriceGuard.PairConfig memory c) internal view returns (bool) {
        return c.v3Pool != address(0) && !handler.twapPools(i).shouldRevert();
    }
}
