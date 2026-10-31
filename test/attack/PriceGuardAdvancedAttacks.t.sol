// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {PriceGuard} from "../../src/PriceGuard.sol";
import {Currency, PoolKey} from "../../src/libraries/Types.sol";
import {PoolIdLib} from "../../src/libraries/PoolIdLib.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {PriceGuardBase} from "../utils/PriceGuardBase.sol";
import {
    MockAggregator,
    MockMutableDecimalsFeed,
    MockStateView,
    MockTwapPool,
    PriceGuardHarness
} from "../mocks/PriceGuardMocks.sol";

/**
 * @dev A consumer that checks trust, then makes an external call the attacker controls, then values at spot. With
 *      `recheck` it checks again after the call (what the guide demands); without it, the check is stale.
 */
contract CallbackConsumer {
    using PoolIdLib for PoolKey;

    PriceGuard public immutable GUARD;
    MockStateView public immutable STATE_VIEW;
    bool public recheck;
    PoolKey internal _key;

    error PriceUntrusted();

    constructor(PriceGuard guard_, MockStateView stateView_, PoolKey memory key_, bool recheck_) {
        GUARD = guard_;
        STATE_VIEW = stateView_;
        _key = key_;
        recheck = recheck_;
    }

    /**
     * @dev Returns the value, in token1 units, credited for `ethAmount` of token0 at the spot price.
     */
    function creditFor(uint256 ethAmount, address hook) external returns (uint256) {
        (bool trusted,) = GUARD.isPriceTrusted(_key);
        if (!trusted) revert PriceUntrusted();
        Hook(hook).onTransfer(); // e.g. an ERC-777 style token hook the depositor controls
        if (recheck) {
            (trusted,) = GUARD.isPriceTrusted(_key);
            if (!trusted) revert PriceUntrusted();
        }
        (uint160 sp,,,) = STATE_VIEW.getSlot0(_key.toId());
        return Math.mulDiv(ethAmount, Math.mulDiv(sp, sp, 1 << 96), 1 << 96);
    }
}

contract Hook {
    MockStateView public immutable STATE_VIEW;
    bytes32 public immutable POOL_ID;
    uint160 public manipulatedSqrt;

    constructor(MockStateView stateView_, bytes32 poolId_) {
        STATE_VIEW = stateView_;
        POOL_ID = poolId_;
    }

    function arm(uint160 manipulatedSqrt_) external {
        manipulatedSqrt = manipulatedSqrt_;
    }

    function onTransfer() external {
        STATE_VIEW.setSqrtPrice(POOL_ID, manipulatedSqrt);
    }
}

/**
 * @dev Further attacks on PriceGuard that go beyond the first attack suite: raw ABI abuse, check-then-act races,
 *      the economic ceiling of a deposit sandwich, pool isolation, gas, and operational misconfiguration.
 */
contract PriceGuardAdvancedAttacksTest is PriceGuardBase {
    using PoolIdLib for PoolKey;

    // ------------------------------------------------------------------------------------------------------------
    // Raw ABI abuse: pool id aliasing and malformed calldata
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev A PoolKey is hashed after decoding, so two different byte strings must never decode to the same key. A
     *      value with dirty high bits has to be rejected by the decoder instead of aliasing a configured pool.
     */
    function test_dirty_abi_words_in_the_pool_key_are_rejected_not_aliased() public {
        guard.setPairConfig(key, _chainlinkConfig());
        bytes memory valid = abi.encodeCall(guard.isPriceTrusted, (key));
        (bool ok,) = address(guard).staticcall(valid);
        assertTrue(ok, "the clean encoding works");

        // word indexes within the key: 0 currency0, 1 currency1, 2 fee, 3 tickSpacing, 4 hooks
        uint256[5] memory dirtyBits =
            [uint256(1) << 160, uint256(1) << 160, uint256(1) << 24, uint256(1) << 24, uint256(1) << 160];
        for (uint256 word; word < 5; ++word) {
            bytes memory dirty = abi.encodeCall(guard.isPriceTrusted, (key));
            _orWord(dirty, word, dirtyBits[word]);
            (ok,) = address(guard).staticcall(dirty);
            assertFalse(ok, "dirty high bits must make the decoder revert");
        }
    }

    function test_negative_tick_spacing_must_be_sign_extended() public view {
        PoolKey memory negSpacing = key;
        negSpacing.tickSpacing = -60;
        bytes memory good = abi.encodeCall(guard.isPriceTrusted, (negSpacing));
        (bool ok, bytes memory ret) = address(guard).staticcall(good);
        assertFalse(ok); // decodes fine but has no configuration
        assertEq(bytes4(ret), PriceGuard.NoConfig.selector);

        // the same value without sign extension (0x00FFFFC4) is a different number and must be rejected
        bytes memory unextended = abi.encodeCall(guard.isPriceTrusted, (negSpacing));
        _setWord(unextended, 3, uint256(0x00FFFFC4));
        (ok, ret) = address(guard).staticcall(unextended);
        assertFalse(ok);
        assertTrue(bytes4(ret) != PriceGuard.NoConfig.selector, "must fail in the decoder, not alias a valid key");
    }

    function test_truncated_and_padded_calldata() public {
        guard.setPairConfig(key, _chainlinkConfig());
        bytes memory valid = abi.encodeCall(guard.isPriceTrusted, (key));

        bytes memory truncated = new bytes(valid.length - 1);
        for (uint256 i; i < truncated.length; ++i) {
            truncated[i] = valid[i];
        }
        (bool ok,) = address(guard).staticcall(truncated);
        assertFalse(ok, "short calldata reverts");

        (bool okPadded, bytes memory padded) = address(guard).staticcall(bytes.concat(valid, hex"deadbeef"));
        (bool okClean, bytes memory clean) = address(guard).staticcall(valid);
        assertTrue(okPadded && okClean);
        assertEq(keccak256(padded), keccak256(clean), "trailing bytes change nothing");
    }

    function test_dirty_key_cannot_reconfigure_either() public {
        bytes memory call = abi.encodeCall(guard.setPairConfig, (key, _chainlinkConfig()));
        _orWord(call, 2, uint256(1) << 24); // fee word with a dirty bit
        (bool ok,) = address(guard).call(call);
        assertFalse(ok);
        (IPriceGuard.PairConfig memory stored,,) = guard.configOf(key);
        assertEq(stored.maxDeviationBps, 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Check-then-act race (the guide: "never cache the result", "snapshot before any external call")
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Attack: trust is checked first, then a depositor-controlled hook runs and moves the pool by +50%, then the
     *      consumer values at spot. Without a second check the consumer credits 50% too much; with the second check
     *      the call reverts.
     */
    function test_stale_trust_across_an_external_call_is_exploitable_unless_rechecked() public {
        guard.setPairConfig(key, _chainlinkConfig());
        uint160 inflated = guard.sqrtFromRatio(3000 * 10 ** 6, 10 ** 18);

        Hook hook = new Hook(stateView, key.toId());
        hook.arm(inflated);
        CallbackConsumer naive = new CallbackConsumer(guard, stateView, key, false);
        uint256 fair = 2000 * 10 ** 6; // one ETH at 2000 USDC
        uint256 credited = naive.creditFor(1 ether, address(hook));
        assertGt(credited, fair * 14 / 10, "a stale check lets the hook inflate the credit by about 50%");

        _setPoolUsd(key, 2000); // reset
        CallbackConsumer safe = new CallbackConsumer(guard, stateView, key, true);
        vm.expectRevert(CallbackConsumer.PriceUntrusted.selector);
        safe.creditFor(1 ether, address(hook));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Economic ceiling of a deposit sandwich
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev A vault values deposits at spot. Attacker pushes the pool DOWN by `moveBps`, deposits `deposit` USDC while
     *      ETH is underpriced, the price returns, and the attacker redeems. Whenever the guard calls the price
     *      trusted, the attacker's gain is at most `deposit * m / (1 - m)` for a deviation m, so the deviation limit is a
     *      hard ceiling on the profit (before fees): about 1.01% of the deposit at the 1% limit. Beyond the limit the guard refuses.
     */
    function testFuzz_sandwich_profit_is_capped_by_the_deviation_limit(
        uint64 vaultEth,
        uint64 vaultUsdc,
        uint64 depositUsdc,
        uint16 moveBps
    ) public {
        guard.setPairConfig(key, _chainlinkConfig()); // 100 bps limit around 2000 USDC per ETH
        uint256 a0 = bound(uint256(vaultEth), 1 ether, 1_000_000 ether); // vault ETH
        uint256 a1 = bound(uint256(vaultUsdc), 1e6, 1_000_000_000e6); // vault USDC
        uint256 d = bound(uint256(depositUsdc), 1e6, 1_000_000_000e6);
        uint256 move = bound(uint256(moveBps), 0, 400);

        uint256 truePrice = 2000 * 10 ** 6; // USDC raw per ETH
        uint256 spotPrice = truePrice * (10_000 - move) / 10_000;
        stateView.setSqrtPrice(key.toId(), guard.sqrtFromRatio(spotPrice, 10 ** 18));

        (bool trusted, uint256 devBps) = guard.isPriceTrusted(key);
        if (!trusted) {
            assertGt(move, 90, "only a large move can be refused");
            return;
        }

        (uint160 sp,,,) = stateView.getSlot0(key.toId());
        uint256 spotPerEth = Math.mulDiv(Math.mulDiv(sp, sp, 1 << 96), 1 ether, 1 << 96);
        uint256 gain = _sandwichGain(a0, a1, d, spotPerEth, truePrice);
        // exact ceiling: gain / deposit <= m / (1 - m), reached by an all-ETH vault and a tiny deposit; devBps is floored,
        // so the real move can be one basis point larger than reported
        assertLe(
            gain * (10_000 - devBps - 1),
            d * (devBps + 1) + 4 * 10_000,
            "profit above the ceiling implied by the guard tolerance"
        );
    }

    /**
     * @dev Shares are priced at the pool's spot price (both in USDC raw units); after the price returns, the attacker
     *      owns minted / (existing + minted) of the whole vault at its true value.
     */
    function _sandwichGain(uint256 a0, uint256 a1, uint256 d, uint256 spotPerEth, uint256 truePrice)
        private
        pure
        returns (uint256)
    {
        uint256 navSpot = Math.mulDiv(a0, spotPerEth, 1 ether) + a1;
        uint256 navTrue = Math.mulDiv(a0, truePrice, 1 ether) + a1;
        uint256 existingShares = 1e18;
        uint256 minted = Math.mulDiv(existingShares, d, navSpot);
        uint256 redeemValue = Math.mulDiv(minted, navTrue + d, existingShares + minted);
        return redeemValue > d ? redeemValue - d : 0;
    }

    // ------------------------------------------------------------------------------------------------------------
    // Isolation between pools
    // ------------------------------------------------------------------------------------------------------------

    function testFuzz_one_pools_price_and_configuration_never_affect_another(
        uint256 priceA,
        uint16 devA,
        bool reconfigureA
    ) public {
        PoolKey memory keyB = key;
        keyB.fee = 500;
        keyB.tickSpacing = 10;
        _setPoolUsd(keyB, 2000);
        guard.setPairConfig(key, _chainlinkConfig());
        guard.setPairConfig(keyB, _chainlinkConfig());

        (bool trustedB, uint256 devB) = guard.isPriceTrusted(keyB);
        (IPriceGuard.PairConfig memory beforeB, uint8 d0, uint8 d1) = guard.configOf(keyB);
        bytes32 hashBefore = keccak256(abi.encode(beforeB, d0, d1));

        stateView.setSqrtPrice(key.toId(), uint160(bound(priceA, 1, type(uint160).max))); // anything for A
        if (reconfigureA) {
            IPriceGuard.PairConfig memory c = _chainlinkConfig();
            c.maxDeviationBps = uint16(bound(devA, 1, 1000));
            _setPoolUsd(key, 2000); // make the reconfiguration valid
            guard.setPairConfig(key, c);
        }

        (bool trustedB2, uint256 devB2) = guard.isPriceTrusted(keyB);
        (IPriceGuard.PairConfig memory afterB, uint8 e0, uint8 e1) = guard.configOf(keyB);
        assertEq(trustedB2, trustedB);
        assertEq(devB2, devB);
        assertEq(keccak256(abi.encode(afterB, e0, e1)), hashBefore, "pool B's stored configuration must not change");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Gas
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev The slowest path: L2 sequencer check, a failed Chainlink read (stale), then the V3 TWAP fallback.
     */
    function test_worst_case_gas_of_the_trust_check() public {
        MockAggregator sequencer = new MockAggregator(0);
        PriceGuardHarness l2 = new PriceGuardHarness(stateView, address(sequencer), address(weth), address(this));
        sequencer.setAnswer(0, block.timestamp - 1 days);
        MockTwapPool pool = new MockTwapPool(address(weth), address(usdc));
        pool.setMeanTick(-200_311);
        stateView.setSqrtPrice(key.toId(), SqrtPriceMath.getSqrtPriceAtTick(-200_311));
        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.v3Pool = address(pool);
        config.twapWindow = 1800;
        l2.setPairConfig(key, config);
        ethUsdFeed.setAnswer(2000e8, block.timestamp - 2 hours); // stale: forces the fallback

        uint256 before = gasleft();
        (bool trusted,) = l2.isPriceTrusted(key);
        uint256 used = before - gasleft();
        emit log_named_uint("worst-case isPriceTrusted gas", used);
        assertTrue(trusted);
        assertLt(used, 120_000, "a trust check must stay cheap enough to run on every deposit and rebalance");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Operational failures
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev A feed upgrade that changes `decimals` without the owner reconfiguring must not produce a trusted price:
     *      the answer bounds are in feed decimals, so a 10^10 larger answer falls outside them.
     */
    function test_feed_decimals_change_fails_closed_until_the_owner_reconfigures() public {
        MockMutableDecimalsFeed feed = new MockMutableDecimalsFeed(8);
        feed.setAnswer(2000e8, block.timestamp);
        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.chainlinkFeed = address(feed);
        guard.setPairConfig(key, config);
        _assertTrusted();

        feed.setDecimals(18);
        feed.setAnswer(2000e18, block.timestamp); // same human price, new scale
        _assertNotTrusted();

        feed.setAnswer(2000e8, block.timestamp); // inconsistent: 18 decimals reported with an 8-decimal answer
        _assertRejectedForDeviation();
    }

    /**
     * @dev A sequencer address with no code (a typo at deployment) is accepted by the constructor, after which every
     *      trust check reverts. This fails closed, but it is silent until the first deposit: PostDeployCheck must
     *      verify the sequencer feed has code and a recent update.
     */
    function test_known_issue_sequencer_address_without_code_bricks_trust_checks_closed() public {
        PriceGuardHarness broken = new PriceGuardHarness(stateView, address(0xdead), address(weth), address(this));
        broken.setPairConfig(key, _chainlinkConfig()); // configuration does not consult the sequencer
        vm.expectRevert();
        broken.isPriceTrusted(key);
        // fail closed: consumers see a revert, never `trusted == true`
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Word `index` of the first argument (calldata offset 4 + 32 * index).
     */
    function _setWord(bytes memory data, uint256 index, uint256 value) internal pure {
        uint256 offset = 4 + 32 * index;
        assembly ("memory-safe") {
            mstore(add(add(data, 0x20), offset), value)
        }
    }

    function _orWord(bytes memory data, uint256 index, uint256 bits) internal pure {
        uint256 offset = 4 + 32 * index;
        uint256 current;
        assembly ("memory-safe") {
            current := mload(add(add(data, 0x20), offset))
        }
        _setWord(data, index, current | bits);
    }
}
