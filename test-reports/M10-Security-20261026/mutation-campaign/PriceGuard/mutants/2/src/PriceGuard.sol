// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPriceGuard} from "./interfaces/IPriceGuard.sol";
import {IAggregatorV3} from "./interfaces/external/IAggregatorV3.sol";
import {IStateViewLike} from "./interfaces/external/IStateViewLike.sol";
import {IUniswapV3PoolLike} from "./interfaces/external/IUniswapV3PoolLike.sol";
import {Currency, PoolKey} from "./libraries/Types.sol";
import {PoolIdLib} from "./libraries/PoolIdLib.sol";
import {SqrtPriceMath} from "./libraries/SqrtPriceMath.sol";

/**
 * @title PriceGuard
 * @notice Validates Uniswap V4 pool prices against Chainlink and Uniswap V3 TWAP references.
 * @dev Ownership uses OpenZeppelin Ownable2Step so the deployer can transfer control to a timelock that must
 *      explicitly accept ownership before managing pair configurations.
 *
 *      Reference selection: the Chainlink feed is tried first; if it is unset or its answer is rejected, the
 *      Uniswap V3 TWAP is used. If neither produces a price the pool is reported as untrusted.
 *
 *      Trust model: the owner is trusted to configure correct feeds, answer bounds, TWAP pools and deviation
 *      limits. Everything read at runtime (pool state, feeds, token metadata, sequencer feed) is untrusted and
 *      every failure maps to "not trusted" rather than a revert, except for a missing configuration.
 *
 *      The only state-changing function is `setPairConfig` (plus the inherited two-step ownership functions).
 *      Withdrawals in consumer contracts must never call this contract.
 */
// Ownership is an explicit deployment trust boundary; configuration updates remain fully validated.
// aderyn-ignore-next-line(centralization-risk)
contract PriceGuard is IPriceGuard, Ownable2Step {
    using PoolIdLib for PoolKey;

    /**
     * @notice A required address argument is zero.
     * @dev Thrown by the constructor when `stateView_`, `nativeWrapper_` or `owner_` is the zero address.
     */
    error ZeroAddress();
    /**
     * @notice A pair configuration does not include any usable reference oracle.
     * @dev Thrown by `setPairConfig` when both `chainlinkFeed` and `v3Pool` are zero.
     */
    error NoReference();
    /**
     * @notice The configured maximum deviation is outside the allowed bounds.
     * @dev Thrown by `setPairConfig` unless `maxDeviationBps` is within `[MIN_DEVIATION_BPS, MAX_DEVIATION_BPS]`.
     */
    error InvalidDeviation();
    /**
     * @notice The V3 TWAP window is below the required minimum.
     * @dev Thrown by `setPairConfig` when `v3Pool` is set and `twapWindow` is below `MIN_TWAP_WINDOW`.
     */
    error InvalidTwapWindow();
    /**
     * @notice The configured Chainlink feed cannot be queried as expected.
     * @dev Thrown by `setPairConfig` when `decimals()` on the feed reverts.
     */
    error InvalidFeed();
    /**
     * @notice Chainlink answer bounds are malformed.
     * @dev Thrown by `setPairConfig` when `minAnswer` is zero or not strictly below `maxAnswer`.
     */
    error InvalidAnswerBounds();
    /**
     * @notice The V3 fallback pool does not match the configured V4 pool tokens and orientation.
     * @dev Thrown by `setPairConfig` when the V3 pool's tokens differ from the pool key tokens (with the wrapped
     *      native token standing in for native ETH), or when the V3 token reads revert.
     */
    error InvalidV3Pool();
    /**
     * @notice No pair configuration exists for the requested pool.
     * @dev Thrown by `isPriceTrusted` when `maxDeviationBps` is zero, which is only the case for unset configs.
     */
    error NoConfig();
    /**
     * @notice No valid configured oracle reference can be produced.
     */
    error InvalidReference();
    /**
     * @notice A price ratio cannot be represented as a uint160 sqrtPriceX96 value.
     * @dev Thrown by `_sqrtFromRatio` when the square root of the Q192 ratio exceeds `type(uint160).max`.
     */
    error PriceOutOfRange();
    /**
     * @notice The configured reference price does not match the live pool price within the allowed deviation.
     * @dev Thrown by `setPairConfig` when the pool is uninitialized, the reference is unavailable at
     *      configuration time, or the initial deviation exceeds `maxDeviationBps`. This catches wrong feed
     *      orientation and wrong decimals before they are stored.
     */
    error InvalidInitialPrice();

    /**
     * @notice Highest token/feed decimal value accepted before exponentiation.
     * @dev `10 ** 77` is the largest power of ten that fits in a uint256, so larger values are rejected.
     */
    uint8 internal constant MAX_SAFE_DECIMALS = 77;
    /**
     * @notice Minimum allowed price deviation threshold, in basis points.
     * @dev A zero threshold is disallowed because `maxDeviationBps == 0` marks an unset configuration.
     */
    uint16 internal constant MIN_DEVIATION_BPS = 1;
    /**
     * @notice Basis-point denominator.
     */
    uint16 internal constant BPS_DENOMINATOR = 1e4;
    /**
     * @notice Maximum allowed price deviation threshold, in basis points.
     * @dev 1,000 bps equals 10 percent.
     */
    uint16 internal constant MAX_DEVIATION_BPS = 1_000;
    /**
     * @notice Minimum accepted Uniswap V3 TWAP window, in seconds.
     * @dev Short windows are cheap to manipulate on thin pools, so ten minutes is enforced as a floor.
     */
    uint32 internal constant MIN_TWAP_WINDOW = 600;
    /**
     * @notice Required grace period after an L2 sequencer comes back online, in seconds.
     * @dev Prices are not trusted until the sequencer has been up for strictly longer than this period.
     */
    uint32 internal constant SEQUENCER_GRACE_PERIOD = 3_600;

    /**
     * @notice Uniswap V4 StateView contract used to read pool slot0 values.
     * @dev Set once in the constructor and never changed.
     */
    IStateViewLike public immutable stateView;
    /**
     * @notice Optional Chainlink L2 sequencer uptime feed; zero address means L1 deployment.
     * @dev When zero, `_sequencerUp` always reports the sequencer as up.
     */
    address public immutable sequencerUptimeFeed;
    /**
     * @notice Wrapped native token used when a V4 pool key contains the native currency sentinel.
     * @dev Used only to match V4 native-ETH pools against V3 pools, which only hold ERC-20 tokens.
     */
    address public immutable nativeWrapper;

    /**
     * @dev Pair configuration per V4 pool id. An entry with `maxDeviationBps == 0` is treated as unset.
     */
    mapping(bytes32 poolId => PairConfig) private _config;
    /**
     * @dev Cached decimals of `currency0` per pool id, written when the configuration is set.
     */
    mapping(bytes32 poolId => uint8) private _dec0;
    /**
     * @dev Cached decimals of `currency1` per pool id, written when the configuration is set.
     */
    mapping(bytes32 poolId => uint8) private _dec1;

    /**
     * @notice Deploys PriceGuard with V4 StateView, optional sequencer feed, wrapped native token, and owner.
     * @dev `sequencerUptimeFeed_` may be zero for L1 deployments. `owner_` is expected to transfer ownership to
     *      a timelock and the timelock must accept ownership before production configuration management.
     *
     *      Reverts with `ZeroAddress` if `stateView_`, `nativeWrapper_` or `owner_` is the zero address.
     * @param stateView_ Uniswap V4 StateView contract.
     * @param sequencerUptimeFeed_ Optional Chainlink sequencer uptime feed, or zero on L1.
     * @param nativeWrapper_ Wrapped native token address for native currency normalization.
     * @param owner_ Initial temporary owner.
     */
    // `sequencerUptimeFeed_ == address(0)` intentionally means this is an L1 deployment.
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(IStateViewLike stateView_, address sequencerUptimeFeed_, address nativeWrapper_, address owner_)
        Ownable(owner_)
    {
        if (address(stateView_) == address(0) || nativeWrapper_ == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        stateView = stateView_;
        // Zero is the expected value on L1 deployments with no sequencer uptime feed.
        // forge-lint: disable-next-line(missing-zero-check)
        sequencerUptimeFeed = sequencerUptimeFeed_;
        nativeWrapper = nativeWrapper_;
    }

    /**
     * @notice Starts the two-step ownership transfer to `newOwner`.
     * @dev Overrides OpenZeppelin to preserve an explicit zero-address rejection. The transfer only completes
     *      once `newOwner` calls `acceptOwnership`, so a mistyped address cannot take over the contract.
     *
     *      Reverts with `OwnableInvalidOwner` when `newOwner` is the zero address and with
     *      `OwnableUnauthorizedAccount` when the caller is not the current owner.
     * @param newOwner Address that must later call `acceptOwnership`.
     */
    // Two-step ownership transfer prevents accidental handoff; the owner/timelock is trusted by design.
    // aderyn-ignore-next-line(centralization-risk)
    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == address(0)) revert Ownable.OwnableInvalidOwner(address(0));
        super.transferOwnership(newOwner);
    }

    /**
     * @inheritdoc IPriceGuard
     * @dev Validates oracle configuration, token decimals, initial live price alignment, then stores the config.
     *
     *      Order of operations: static validation of the config, decimals discovery for both currencies, a live
     *      deviation check against the pool, and only then the storage writes and the `PairConfigSet` event.
     *      All external calls made before the writes are `view` calls, so a hostile oracle or token cannot
     *      reenter and observe a partially written configuration.
     *
     *      Reverts with `NoReference`, `InvalidDeviation`, `InvalidFeed`, `InvalidAnswerBounds`,
     *      `InvalidTwapWindow`, `InvalidV3Pool` or `InvalidInitialPrice` for invalid inputs, and with
     *      `OwnableUnauthorizedAccount` for non-owner callers.
     */
    // Oracle configuration is an explicit owner/timelock responsibility and is validated below.
    // aderyn-ignore-next-line(centralization-risk)
    function setPairConfig(PoolKey calldata key, PairConfig calldata config) external onlyOwner {
        _validateConfig(key, config);
        bytes32 poolId = key.toId();
        uint8 decimals0 = _currencyDecimals(key.currency0);
        uint8 decimals1 = _currencyDecimals(key.currency1);
        _validateInitialPrice(poolId, config, decimals0, decimals1);

        _config[poolId] = config;
        _dec0[poolId] = decimals0;
        _dec1[poolId] = decimals1;

        emit PairConfigSet(poolId, key, config, decimals0, decimals1);
    }

    /**
     * @inheritdoc IPriceGuard
     * @dev Returns false instead of reverting when runtime oracle, sequencer, or TWAP reads fail after configuration.
     *
     *      The pool and reference prices are compared as squared square-root prices in Q96 using 512-bit
     *      `mulDiv`, and the deviation is measured relative to the reference price.
     *
     *      Reverts with `NoConfig` only when the pool has never been configured. A sequencer that is down or
     *      inside its grace period, a stale, zero, negative, clamped or reverting oracle answer, a reference price
     *      outside the representable range or rounding to zero, and a V3 pool with too little history all return
     *      `(false, type(uint256).max)`. A reference contract that returns malformed data (not decodable as the
     *      expected ABI types) still reverts, which fails closed for every consumer.
     */
    function isPriceTrusted(PoolKey calldata key) external view returns (bool trusted, uint256 devBps) {
        bytes32 poolId = key.toId();
        PairConfig memory config = _config[poolId];
        if (config.maxDeviationBps == 0) revert NoConfig();
        if (!_sequencerUp()) return (false, type(uint256).max);

        // forge-lint: disable-next-line(unused-return)
        (uint160 sqrtPool,,,) = stateView.getSlot0(poolId);
        (bool ok, uint160 sqrtRef) = _reference(config, _dec0[poolId], _dec1[poolId]);
        if (!ok) return (false, type(uint256).max);

        uint256 poolPriceX96 = Math.mulDiv(sqrtPool, sqrtPool, 1 << 96); // aderyn-ignore(literal-instead-of-constant)
        uint256 refPriceX96 = Math.mulDiv(sqrtRef, sqrtRef, 1 << 96); // aderyn-ignore(literal-instead-of-constant)
        // A reference that rounds to zero in Q96 cannot be used as a denominator; treat it as no reference.
        if (refPriceX96 == 0) return (false, type(uint256).max);
        /// BinaryOpMutation(`-` |==> `**`) of: `uint256 diff = poolPriceX96 > refPriceX96 ? poolPriceX96 - refPriceX96 : refPriceX96 - poolPriceX96;`
        uint256 diff = poolPriceX96 > refPriceX96 ? poolPriceX96 - refPriceX96 : refPriceX96**poolPriceX96;
        devBps = Math.mulDiv(diff, BPS_DENOMINATOR, refPriceX96);
        trusted = devBps <= config.maxDeviationBps;
    }

    /**
     * @inheritdoc IPriceGuard
     * @dev Uses the same configured oracle and sequencer checks as `isPriceTrusted`, but returns the reference
     * itself for callers that must value assets and enforce a swap floor at one consistent price snapshot.
     */
    function referenceSqrtPriceX96(PoolKey calldata key) external view returns (uint160 sqrtPriceX96) {
        bytes32 poolId = key.toId();
        PairConfig memory config = _config[poolId];
        if (config.maxDeviationBps == 0) revert NoConfig();
        if (!_sequencerUp()) revert InvalidReference();
        (bool ok, uint160 oracleSqrt) = _reference(config, _dec0[poolId], _dec1[poolId]);
        if (!ok || oracleSqrt == 0) revert InvalidReference();
        sqrtPriceX96 = oracleSqrt;
    }

    /**
     * @notice Returns the stored configuration and cached token decimals for a V4 pool.
     * @dev Returns zeroed values for pools that were never configured; it does not revert. Callers that need to
     *      distinguish "unset" should check `config.maxDeviationBps == 0`.
     * @param key Pool key identifying the V4 pool.
     * @return config Stored pair configuration.
     * @return decimals0 Cached decimals for `key.currency0`.
     * @return decimals1 Cached decimals for `key.currency1`.
     */
    function configOf(PoolKey calldata key)
        external
        view
        returns (PairConfig memory config, uint8 decimals0, uint8 decimals1)
    {
        bytes32 poolId = key.toId();
        return (_config[poolId], _dec0[poolId], _dec1[poolId]);
    }

    /**
     * @notice Statically validates a pair configuration before it is stored.
     * @dev Checks that at least one reference is set, the deviation is within bounds, the Chainlink feed answers
     *      `decimals()` with sane answer bounds, and the V3 fallback has a long enough window and matching tokens.
     *      Reverts with the error documented for each failing check.
     * @param key Pool key the configuration applies to.
     * @param config Configuration to validate.
     */
    function _validateConfig(PoolKey calldata key, PairConfig calldata config) private view {
        if (config.chainlinkFeed == address(0) && config.v3Pool == address(0)) revert NoReference();
        if (config.maxDeviationBps < MIN_DEVIATION_BPS || config.maxDeviationBps > MAX_DEVIATION_BPS) {
            revert InvalidDeviation();
        }

        if (config.chainlinkFeed != address(0)) {
            try IAggregatorV3(config.chainlinkFeed).decimals() returns (uint8) {}
            catch {
                revert InvalidFeed();
            }
            if (config.minAnswer == 0 || config.minAnswer >= config.maxAnswer) revert InvalidAnswerBounds();
        }

        if (config.v3Pool != address(0)) {
            if (config.twapWindow < MIN_TWAP_WINDOW) revert InvalidTwapWindow();
            _validateV3Tokens(key, config.v3Pool, config.invertV3);
        }
    }

    /**
     * @notice Checks that a V3 pool holds the same token pair as the V4 pool key.
     * @dev Native ETH in the key is mapped to `nativeWrapper`. When `invertV3` is true the V3 pool must list the
     *      tokens in the opposite order to the V4 key, otherwise in the same order. Reverts with `InvalidV3Pool`
     *      on a mismatch or if the V3 token reads revert.
     * @param key Pool key whose tokens are matched.
     * @param v3Pool Candidate Uniswap V3 pool.
     * @param invertV3 Whether the V3 pool's token ordering is reversed against the V4 key.
     */
    function _validateV3Tokens(PoolKey calldata key, address v3Pool, bool invertV3) private view {
        address key0 = _poolTokenAddress(key.currency0);
        address key1 = _poolTokenAddress(key.currency1);

        try IUniswapV3PoolLike(v3Pool).token0() returns (address token0) {
            address token1 = IUniswapV3PoolLike(v3Pool).token1();
            bool matches = invertV3 ? token0 == key1 && token1 == key0 : token0 == key0 && token1 == key1;
            if (!matches) revert InvalidV3Pool();
        } catch {
            revert InvalidV3Pool();
        }
    }

    /**
     * @notice Rejects configurations whose reference price disagrees with the live pool at configuration time.
     * @dev This is the on-chain sanity check for wrong feed orientation and wrong decimals: either mistake yields
     *      a very large deviation. Reverts with `InvalidInitialPrice` when the pool is uninitialized, the
     *      reference cannot be computed or rounds to zero in Q96, or the deviation exceeds `config.maxDeviationBps`.
     * @param poolId V4 pool id derived from the pool key.
     * @param config Candidate configuration being validated.
     * @param decimals0 Decimals of `currency0`.
     * @param decimals1 Decimals of `currency1`.
     */
    function _validateInitialPrice(bytes32 poolId, PairConfig calldata config, uint8 decimals0, uint8 decimals1)
        private
        view
    {
        // forge-lint: disable-next-line(unused-return)
        (uint160 sqrtPool,,,) = stateView.getSlot0(poolId);
        if (sqrtPool == 0) revert InvalidInitialPrice();

        (bool ok, uint160 sqrtRef) = _reference(config, decimals0, decimals1);
        if (!ok || sqrtRef == 0) revert InvalidInitialPrice();

        uint256 poolPriceX96 = Math.mulDiv(sqrtPool, sqrtPool, 1 << 96); // aderyn-ignore(literal-instead-of-constant)
        uint256 refPriceX96 = Math.mulDiv(sqrtRef, sqrtRef, 1 << 96); // aderyn-ignore(literal-instead-of-constant)
        if (refPriceX96 == 0) revert InvalidInitialPrice();
        uint256 diff = poolPriceX96 > refPriceX96 ? poolPriceX96 - refPriceX96 : refPriceX96 - poolPriceX96;
        uint256 devBps = Math.mulDiv(diff, BPS_DENOMINATOR, refPriceX96);
        if (devBps > config.maxDeviationBps) revert InvalidInitialPrice();
    }

    /**
     * @notice Resolves the reference sqrt price for a pool from its configured oracles.
     * @dev Tries Chainlink first and returns its price when accepted. Otherwise falls back to the V3 TWAP when a
     *      V3 pool is configured. Never reverts on oracle failures; it reports `ok == false` instead.
     * @param config Pair configuration to read the references from.
     * @param decimals0 Decimals of `currency0`.
     * @param decimals1 Decimals of `currency1`.
     * @return ok True when a usable reference price was produced.
     * @return sqrtPriceX96 Reference square-root price as a Q64.96 value, or zero when `ok` is false.
     */
    function _reference(PairConfig memory config, uint8 decimals0, uint8 decimals1)
        private
        view
        returns (bool ok, uint160 sqrtPriceX96)
    {
        if (config.chainlinkFeed != address(0)) {
            (ok, sqrtPriceX96) = _chainlinkSqrt(config, decimals0, decimals1);
            if (ok) return (ok, sqrtPriceX96);
        }

        if (config.v3Pool != address(0)) {
            return _v3Sqrt(config);
        }

        return (false, 0);
    }

    /**
     * @notice Converts the latest Chainlink answer into a Q64.96 square-root price in raw token units.
     * @dev Rejects (returns `ok == false`) when the answer fails `_validatedAnswer`, any decimals exceed
     *      `MAX_SAFE_DECIMALS`, the scaling multiplications overflow, or the resulting price ratio is too large to
     *      convert (see `_ratioFits`). The raw price is built by `_scaledRatio`.
     * @param config Pair configuration holding the feed address, staleness limit and answer bounds.
     * @param decimals0 Decimals of `currency0`.
     * @param decimals1 Decimals of `currency1`.
     * @return ok True when the answer passed every check.
     * @return sqrtPriceX96 Reference square-root price as a Q64.96 value, or zero when `ok` is false.
     */
    function _chainlinkSqrt(PairConfig memory config, uint8 decimals0, uint8 decimals1)
        private
        view
        returns (bool ok, uint160 sqrtPriceX96)
    {
        (bool answerOk, uint256 answer, uint256 feedDecimals) = _validatedAnswer(config);
        if (!answerOk) return (false, 0);
        if (feedDecimals > MAX_SAFE_DECIMALS || decimals0 > MAX_SAFE_DECIMALS || decimals1 > MAX_SAFE_DECIMALS) {
            return (false, 0);
        }

        (bool scaledOk, uint256 numerator, uint256 denominator) =
            _scaledRatio(config.invertFeed, answer, feedDecimals, decimals0, decimals1);
        if (!scaledOk || !_ratioFits(numerator, denominator)) return (false, 0);

        return (true, _sqrtFromRatio(numerator, denominator));
    }

    /**
     * @notice Reads the latest Chainlink round and validates freshness, sign and configured bounds.
     * @dev Returns `ok == false` when `latestRoundData` or `decimals` reverts, the answer is zero or negative,
     *      `updatedAt` is zero, in the future or older than `maxStaleness`, or the answer lies outside
     *      `[minAnswer, maxAnswer]` (clamped feeds). Both bounds are inclusive. Malformed return data still
     *      reverts, which fails closed.
     * @param config Pair configuration holding the feed address, staleness limit and answer bounds.
     * @return ok True when the answer passed every check.
     * @return answer The positive feed answer, or zero when `ok` is false.
     * @return feedDecimals Decimals of the feed answer, or zero when `ok` is false.
     */
    function _validatedAnswer(PairConfig memory config)
        private
        view
        returns (bool ok, uint256 answer, uint256 feedDecimals)
    {
        int256 rawAnswer = 0;
        uint256 updatedAt = 0;
        try IAggregatorV3(config.chainlinkFeed).latestRoundData() returns (
            uint80, int256 answer_, uint256, uint256 updatedAt_, uint80
        ) {
            rawAnswer = answer_;
            updatedAt = updatedAt_;
        } catch {
            return (false, 0, 0);
        }
        // Oracle freshness is inherently timestamp-based; callers receive false instead of a revert.
        // forge-lint: disable-next-line(block-timestamp)
        bool timestampInvalid = updatedAt == 0 || block.timestamp < updatedAt;
        // forge-lint: disable-next-line(block-timestamp)
        bool timestampStale = !timestampInvalid && block.timestamp - updatedAt > config.maxStaleness;
        if (rawAnswer <= 0 || timestampInvalid || timestampStale) return (false, 0, 0);

        // The answer was checked positive above.
        // forge-lint: disable-next-line(unsafe-typecast)
        answer = uint256(rawAnswer);
        if (answer < config.minAnswer || answer > config.maxAnswer) return (false, 0, 0);

        try IAggregatorV3(config.chainlinkFeed).decimals() returns (uint8 decimals_) {
            feedDecimals = decimals_;
        } catch {
            return (false, 0, 0);
        }
        return (true, answer, feedDecimals);
    }

    /**
     * @notice Builds the raw-unit price ratio `token1 raw units / token0 raw units` from a feed answer.
     * @dev With feed decimals `fd` and token decimals `d0`, `d1`:
     *      - a feed quoting token1 per token0 gives `answer * 10**d1 / (10**fd * 10**d0)`;
     *      - a feed quoting token0 per token1 (`invert`) gives `10**fd * 10**d1 / (answer * 10**d0)`.
     *      The inverted form must re-derive the decimals scaling instead of swapping the direct ratio, because
     *      the token decimals appear on opposite sides in the two cases. Swapping the direct ratio is only
     *      correct when `d0 == d1`.
     *
     *      Returns `ok == false` if any multiplication overflows. `answer` must be non-zero when `invert` is set.
     * @param invert Whether the feed quotes token0 per token1.
     * @param answer Positive feed answer.
     * @param feedDecimals Decimals of the feed answer; at most `MAX_SAFE_DECIMALS`.
     * @param decimals0 Decimals of `currency0`; at most `MAX_SAFE_DECIMALS`.
     * @param decimals1 Decimals of `currency1`; at most `MAX_SAFE_DECIMALS`.
     * @return ok True when both products fit in 256 bits.
     * @return numerator Numerator of the raw price ratio.
     * @return denominator Denominator of the raw price ratio.
     */
    function _scaledRatio(bool invert, uint256 answer, uint256 feedDecimals, uint8 decimals0, uint8 decimals1)
        internal
        pure
        returns (bool ok, uint256 numerator, uint256 denominator)
    {
        (bool answerScaledOk, uint256 answerScaled) = Math.tryMul(answer, 10 ** (invert ? decimals0 : decimals1)); // aderyn-ignore(literal-instead-of-constant)
        (bool feedScaledOk, uint256 feedScaled) =
            Math.tryMul(10 ** feedDecimals, 10 ** (invert ? decimals1 : decimals0)); // aderyn-ignore(literal-instead-of-constant)
        if (!answerScaledOk || !feedScaledOk) return (false, 0, 0);
        ok = true;
        (numerator, denominator) = invert ? (feedScaled, answerScaled) : (answerScaled, feedScaled);
    }

    /**
     * @notice Computes the Uniswap V3 time-weighted average price as a Q64.96 square-root price.
     * @dev Observes `[twapWindow, 0]`, takes the mean tick as `(cum1 - cum0) / window` rounded toward negative
     *      infinity, converts it with `SqrtPriceMath.getSqrtPriceAtTick` and inverts it when `invertV3` is set.
     *      A pool with too little history makes `observe` revert, which is reported as `ok == false` and never
     *      as a pass.
     * @param config Pair configuration holding the V3 pool, window and orientation.
     * @return ok True when the TWAP could be computed.
     * @return sqrtPriceX96 TWAP square-root price as a Q64.96 value, or zero when `ok` is false.
     */
    function _v3Sqrt(PairConfig memory config) private view returns (bool ok, uint160 sqrtPriceX96) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = config.twapWindow;
        secondsAgos[1] = 0;

        try IUniswapV3PoolLike(config.v3Pool).observe(secondsAgos) returns (
            int56[] memory tickCumulatives, uint160[] memory
        ) {
            if (tickCumulatives.length < 2) return (false, 0);
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int24 meanTick = _floorDivTick(delta, int56(uint56(config.twapWindow)));
            sqrtPriceX96 = SqrtPriceMath.getSqrtPriceAtTick(meanTick);
            if (config.invertV3) sqrtPriceX96 = _invertSqrtPrice(sqrtPriceX96);
            return (true, sqrtPriceX96);
        } catch {
            return (false, 0);
        }
    }

    /**
     * @notice Reports whether the L2 sequencer is up and past its grace period.
     * @dev Returns true when no sequencer feed is configured (L1). Otherwise the latest answer must be zero (up),
     *      the update timestamp must be set and not in the future, and strictly more than
     *      `SEQUENCER_GRACE_PERIOD` seconds must have passed since the sequencer came back. A reverting feed is
     *      treated as down.
     * @return up True when prices may be trusted with respect to sequencer health.
     */
    function _sequencerUp() private view returns (bool) {
        if (sequencerUptimeFeed == address(0)) return true;
        int256 answer = 0;
        uint256 updatedAt = 0;
        try IAggregatorV3(sequencerUptimeFeed).latestRoundData() returns (
            uint80, int256 answer_, uint256, uint256 updatedAt_, uint80
        ) {
            answer = answer_;
            updatedAt = updatedAt_;
        } catch {
            return false;
        }
        // Sequencer uptime feeds are timestamp-based by design.
        // forge-lint: disable-next-line(block-timestamp)
        if (answer != 0 || updatedAt == 0 || block.timestamp < updatedAt) return false;
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp - updatedAt > SEQUENCER_GRACE_PERIOD;
    }

    /**
     * @notice Reads the decimals of a pool currency.
     * @dev Native ETH is reported as 18 decimals without an external call. ERC-20 decimals are read through
     *      `IERC20Metadata`; a token without a valid `decimals()` makes the call revert.
     * @param currency Currency to inspect.
     * @return decimals Number of decimals of the currency.
     */
    function _currencyDecimals(Currency currency) private view returns (uint8) {
        address token = Currency.unwrap(currency);
        if (token == address(0)) return 18;
        return IERC20Metadata(token).decimals();
    }

    /**
     * @notice Maps a pool currency to the ERC-20 address used for V3 token matching.
     * @dev Native ETH (the zero address) is replaced by `nativeWrapper`; every other currency maps to itself.
     * @param currency Currency to map.
     * @return token ERC-20 address that represents the currency in a V3 pool.
     */
    function _poolTokenAddress(Currency currency) private view returns (address) {
        address token = Currency.unwrap(currency);
        if (token == address(0)) return nativeWrapper;
        return token;
    }

    /**
     * @notice Converts a price ratio into a Q64.96 square-root price.
     * @dev Computes `sqrt(numerator * 2**192 / denominator)` using 512-bit `mulDiv` followed by an integer square
     *      root. The result rounds down. Reverts with `PriceOutOfRange` if the root does not fit in a uint160 and
     *      with an OpenZeppelin `Math` error if `denominator` is zero or the intermediate overflows 256 bits.
     * @param numerator Numerator of the raw price ratio (token1 raw units).
     * @param denominator Denominator of the raw price ratio (token0 raw units).
     * @return sqrtPriceX96 Square-root price as a Q64.96 value.
     */
    function _sqrtFromRatio(uint256 numerator, uint256 denominator) internal pure returns (uint160 sqrtPriceX96) {
        uint256 ratioX192 = Math.mulDiv(numerator, 1 << 192, denominator);
        uint256 sqrtRatio = Math.sqrt(ratioX192);
        if (sqrtRatio > type(uint160).max) revert PriceOutOfRange();
        sqrtPriceX96 = SafeCast.toUint160(sqrtRatio);
    }

    /**
     * @notice Reports whether `numerator / denominator` is small enough for `_sqrtFromRatio` to convert.
     * @dev `_sqrtFromRatio` computes `numerator * 2**192 / denominator`, which only fits in 256 bits when
     *      `numerator < denominator * 2**64`. If `denominator * 2**64` itself overflows, every 256-bit numerator
     *      is smaller, so the ratio always fits. `denominator` must be non-zero.
     * @param numerator Numerator of the price ratio.
     * @param denominator Denominator of the price ratio.
     * @return fits True when the ratio can be converted without overflow.
     */
    function _ratioFits(uint256 numerator, uint256 denominator) internal pure returns (bool fits) {
        (bool ok, uint256 scaled) = Math.tryMul(denominator, 1 << 64);
        return !ok || numerator < scaled;
    }

    /**
     * @notice Inverts a Q64.96 square-root price, turning token1-per-token0 into token0-per-token1.
     * @dev Computes `2**192 / sqrtPriceX96` with full precision and checked narrowing. Reverts if the input is
     *      zero or the inverse does not fit in a uint160.
     * @param sqrtPriceX96 Square-root price to invert, as a Q64.96 value.
     * @return inverted Inverted square-root price as a Q64.96 value.
     */
    function _invertSqrtPrice(uint160 sqrtPriceX96) private pure returns (uint160) {
        return SafeCast.toUint160(Math.mulDiv(1 << 96, 1 << 96, sqrtPriceX96)); // aderyn-ignore(literal-instead-of-constant)
    }

    /**
     * @notice Divides two signed integers rounding toward negative infinity and narrows the result to a tick.
     * @dev Internal (not private) so test harnesses can exercise it directly, like `_sqrtFromRatio`.
     *      Solidity's `/` truncates toward zero, which is wrong for negative cumulative tick deltas. This helper
     *      subtracts one from the quotient when the division is inexact and the numerator is negative. Reverts if
     *      the result does not fit in an int24 or if `denominator` is zero.
     * @param numerator Dividend, a difference of V3 tick cumulatives.
     * @param denominator Divisor, the TWAP window in seconds.
     * @return tick Floor of `numerator / denominator` as an int24.
     */
    function _floorDivTick(int56 numerator, int56 denominator) internal pure returns (int24 tick) {
        int56 quotient = numerator / denominator;
        int56 remainder = numerator % denominator;
        if (remainder != 0 && numerator < 0) quotient -= 1;
        tick = SafeCast.toInt24(quotient);
    }
}
