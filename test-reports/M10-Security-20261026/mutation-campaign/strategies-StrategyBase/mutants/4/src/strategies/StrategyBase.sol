// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IShapeLibrary} from "../interfaces/IShapeLibrary.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {Band, DepositMode, Plan, Strategy, VaultConfig} from "../libraries/Types.sol";

/**
 * @title Vortexa Strategy Base
 * @notice Shared immutable dependencies, reason codes, and tick helpers for M7 strategies.
 * @dev Strategies are stateless. The only external dependency is the immutable ShapeLibrary.
 */
abstract contract StrategyBase {
    /**
     * @notice A required dependency is the zero address.
     */
    error ZeroAddress();
    /**
     * @notice The configuration selects a different strategy.
     */
    error InvalidStrategy();
    /**
     * @notice Tick spacing or configured widths are invalid.
     */
    error InvalidRange();
    /**
     * @notice The selected shape is incompatible with the strategy.
     */
    error InvalidShape();
    /**
     * @notice A drift threshold is invalid.
     */
    error InvalidDrift();
    /**
     * @notice A trailing threshold is invalid.
     */
    error InvalidTrail();
    /**
     * @notice A calculated anchor cannot be represented safely.
     */
    error InvalidAnchor();
    /**
     * @notice Active bands are required by an edge operation.
     */
    error InvalidBands();

    /**
     * @notice No rebalance trigger, including the first-deposit planning context.
     */
    bytes32 public constant NONE = bytes32("NONE");
    /**
     * @notice Current tick left the active range.
     */
    bytes32 public constant OUT_OF_RANGE = bytes32("OUT_OF_RANGE");
    /**
     * @notice Current tick approached a Normal LP range edge.
     */
    bytes32 public constant DRIFT = bytes32("DRIFT");
    /**
     * @notice Price moved far enough to trail a one-sided range.
     */
    bytes32 public constant TRAIL = bytes32("TRAIL");
    /**
     * @notice A one-sided range fully converted and should lock idle.
     */
    bytes32 public constant FILLED = bytes32("FILLED");

    /**
     * @notice Lowest Uniswap tick.
     */
    int256 internal constant MIN_TICK = -887272;
    /**
     * @notice Highest Uniswap tick.
     */
    int256 internal constant MAX_TICK = 887272;

    /**
     * @notice Immutable band-shape calculator.
     */
    IShapeLibrary public immutable shapes;

    /**
     * @notice Stores the immutable ShapeLibrary dependency.
     * @dev Rejects the zero address so every plan can call a deployed calculator.
     * @param shapes_ Deployed ShapeLibrary.
     */
    constructor(IShapeLibrary shapes_) {
        if (address(shapes_) == address(0)) revert ZeroAddress();
        shapes = shapes_;
    }

    /**
     * @notice Rounds a tick down to a spacing boundary, including for negative ticks.
     * @dev Corrects Solidity's signed division, which truncates negative values toward zero.
     * @param tick Tick to round.
     * @param spacing Positive spacing.
     * @return result Greatest aligned tick not above `tick`.
     */
    function _floorToSpacing(int256 tick, int256 spacing) internal pure returns (int256 result) {
        if (spacing <= 0) revert InvalidRange();
        result = tick / spacing;
        if (tick < 0 && tick % spacing != 0) --result;
        result *= spacing;
    }

    /**
     * @notice Rounds a tick up to a spacing boundary, including for negative ticks.
     * @dev Negates mathematical floor division to obtain mathematical ceiling division.
     * @param tick Tick to round.
     * @param spacing Positive spacing.
     * @return result Smallest aligned tick not below `tick`.
     */
    function _ceilToSpacing(int256 tick, int256 spacing) internal pure returns (int256 result) {
        /// UnaryOperatorMutation(`-` |==> `--`) of: `result = -_floorToSpacing(-tick, spacing);`
        result = -_floorToSpacing(--tick, spacing);
    }

    /**
     * @notice Returns the outer edges of non-empty active bands.
     * @dev Reverts explicitly rather than producing an array-bounds panic for empty input.
     * @param bands Current active bands.
     * @return lower First lower tick.
     * @return upper Last upper tick.
     */
    function _edges(Band[] calldata bands) internal pure returns (int24 lower, int24 upper) {
        if (bands.length == 0) revert InvalidBands();
        lower = bands[0].tickLower;
        upper = bands[bands.length - 1].tickUpper;
    }

    /**
     * @notice Resolves whether a one-sided strategy places liquidity below price.
     * @dev Implements the guide identity `(BuyTheDip == baseIsCurrency0)`.
     * @param config Vault configuration.
     * @return True for a below-price range.
     */
    function _below(VaultConfig calldata config) internal pure returns (bool) {
        return (config.strategy == Strategy.BuyTheDip) == config.baseIsCurrency0;
    }

    /**
     * @notice Validates shared one-sided configuration rules.
     * @dev Restricts presets, relevant thresholds, and the zero-width side before vault initialization.
     * @param config Vault configuration.
     * @param expected Strategy implemented by the concrete contract.
     */
    function _validateOneSided(VaultConfig calldata config, Strategy expected) internal view {
        if (config.strategy != expected) revert InvalidStrategy();
        if (config.poolKey.tickSpacing <= 0) revert InvalidRange();
        if (config.shapeId != 3 && config.shapeId != 4 && config.shapeId != 7) revert InvalidShape();
        if (!shapes.isValidShape(config.shapeId)) revert InvalidShape();
        if (config.trailTicks == 0) revert InvalidTrail();
        if (config.driftTicks != 0) revert InvalidDrift();
        if (_below(config)) {
            if (config.ticksLeft <= 0 || config.ticksRight != 0) revert InvalidRange();
        } else if (config.ticksLeft != 0 || config.ticksRight <= 0) {
            revert InvalidRange();
        }
    }

    /**
     * @notice Returns the currency accepted by a one-sided configuration.
     * @dev A below-price range is entirely currency1; an above-price range is entirely currency0.
     * @param config Vault configuration.
     * @return mode Currency whose side of the range is entirely active.
     */
    function _oneSidedDepositMode(VaultConfig calldata config) internal pure returns (DepositMode mode) {
        mode = _below(config) ? DepositMode.Token1Only : DepositMode.Token0Only;
    }

    /**
     * @notice Reports whether deposits preserve a one-sided active range.
     * @dev Empty vaults accept their first deposit; active ranges use strict Uniswap boundary semantics.
     * @param config Vault configuration.
     * @param tick Current pool tick.
     * @param bands Active bands.
     * @return allowed True for an empty vault or a range wholly on its configured side.
     */
    function _oneSidedCanDeposit(VaultConfig calldata config, int24 tick, Band[] calldata bands)
        internal
        pure
        returns (bool allowed)
    {
        if (bands.length == 0) return true;
        (int24 lower, int24 upper) = _edges(bands);
        allowed = _below(config) ? tick >= upper : tick < lower;
    }

    /**
     * @notice Evaluates trail and fill boundaries for a one-sided range.
     * @dev Trail uses the guide's asymmetric exact boundaries and fill applies only when locking is enabled.
     * @param config Vault configuration.
     * @param tick Current pool tick.
     * @param bands Active bands.
     * @return needed Whether a rebalance is due.
     * @return reason Trigger reason.
     */
    function _oneSidedTrigger(VaultConfig calldata config, int24 tick, Band[] calldata bands)
        internal
        pure
        returns (bool needed, bytes32 reason)
    {
        if (bands.length == 0) return (false, NONE);
        (int24 lower, int24 upper) = _edges(bands);
        if (_below(config)) {
            if (int256(tick) >= int256(upper) + int256(uint256(config.trailTicks))) return (true, TRAIL);
            if (config.lockOnFill && tick < lower) return (true, FILLED);
        } else {
            if (int256(tick) < int256(lower) - int256(uint256(config.trailTicks))) return (true, TRAIL);
            if (config.lockOnFill && tick >= upper) return (true, FILLED);
        }
        return (false, NONE);
    }

    /**
     * @notice Builds a fresh one-sided plan anchored to the current tick.
     * @dev Ignores keeper center input and never requests a swap.
     * @param config Vault configuration.
     * @param tick Current pool tick.
     * @param reason Trigger reason.
     * @return plan_ Empty lock plan on fill, otherwise freshly shaped one-sided bands.
     */
    function _oneSidedPlan(VaultConfig calldata config, int24 tick, bytes32 reason)
        internal
        view
        returns (Plan memory plan_)
    {
        if (reason == FILLED && config.lockOnFill) {
            plan_.lockIdle = true;
            return plan_;
        }
        int256 spacing = int256(config.poolKey.tickSpacing);
        int256 anchor =
            _below(config) ? _floorToSpacing(int256(tick), spacing) : _ceilToSpacing(int256(tick) + 1, spacing);
        if (
            anchor < type(int24).min || anchor > type(int24).max || anchor < MIN_TICK - spacing
                || anchor > MAX_TICK + spacing
        ) {
            revert InvalidAnchor();
        }
        (plan_.bands, plan_.weightsBps) = shapes.computeBands(
            config.shapeId, int24(anchor), config.ticksLeft, config.ticksRight, config.poolKey.tickSpacing
        );
    }
}

/**
 * @title Vortexa Single-Sided Strategy Base
 * @notice Common implementation for Buy-the-Dip and Sell-the-Pump strategies.
 * @dev Concrete contracts supply only their immutable strategy discriminator.
 */
abstract contract SingleSidedStrategy is StrategyBase, IStrategy {
    /**
     * @notice Initializes the shared immutable dependency.
     * @dev Delegates zero-address validation to StrategyBase.
     * @param shapes_ Deployed ShapeLibrary.
     */
    constructor(IShapeLibrary shapes_) StrategyBase(shapes_) {}

    /**
     * @notice Returns the concrete strategy selector.
     * @dev Used to reject pairing a strategy contract with the wrong configuration enum.
     * @return kind Concrete strategy selector.
     */
    function _strategyKind() internal pure virtual returns (Strategy kind);

    /**
     * @inheritdoc IStrategy
     */
    function validateConfig(VaultConfig calldata config, int24 tick) external view {
        _validateOneSided(config, _strategyKind());
        // This call validates that the configuration can produce a plan and is used for revert semantics.
        // aderyn-fp-next-line(unchecked-return)
        _oneSidedPlan(config, tick, NONE);
    }

    /**
     * @inheritdoc IStrategy
     */
    function canDeposit(VaultConfig calldata config, int24 tick, Band[] calldata bands)
        external
        pure
        returns (bool allowed)
    {
        allowed = _oneSidedCanDeposit(config, tick, bands);
    }

    /**
     * @inheritdoc IStrategy
     */
    function depositMode(VaultConfig calldata config) external pure returns (DepositMode mode) {
        mode = _oneSidedDepositMode(config);
    }

    /**
     * @inheritdoc IStrategy
     */
    function checkTrigger(VaultConfig calldata config, int24 tick, Band[] calldata bands)
        external
        pure
        returns (bool needed, bytes32 reason)
    {
        return _oneSidedTrigger(config, tick, bands);
    }

    /**
     * @inheritdoc IStrategy
     */
    function plan(VaultConfig calldata config, int24 tick, int24, uint160, uint256, uint256, bytes32 reason)
        external
        view
        returns (Plan memory plan_)
    {
        plan_ = _oneSidedPlan(config, tick, reason);
    }
}
