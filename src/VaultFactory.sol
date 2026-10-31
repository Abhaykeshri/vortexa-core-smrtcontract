// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPriceGuard} from "./interfaces/IPriceGuard.sol";
import {IShapeLibrary} from "./interfaces/IShapeLibrary.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IStateViewLike} from "./interfaces/external/IStateViewLike.sol";
import {Currency, PoolKey, Strategy, VaultConfig} from "./libraries/Types.sol";
import {PoolIdLib} from "./libraries/PoolIdLib.sol";

/**
 * @title Vortexa Vault Factory
 * @notice Timelocked control plane and deterministic registry for immutable Vortexa vault clones.
 * @dev Owner changes affect new-vault policy and the live fee/role getters intentionally read by existing vaults;
 *      they can never rewrite an existing vault's configuration, strategy, implementation or custody state.
 */
// Ownership is the timelock by design (guide 10.4); every owner function validates its input and emits an event.
// aderyn-ignore-next-line(centralization-risk)
contract VaultFactory is IVaultFactory, Ownable2Step, ReentrancyGuard {
    using PoolIdLib for PoolKey;

    /**
     * @notice Absolute safety ceiling for the mutable business fee cap.
     */
    uint256 public constant ABSOLUTE_MAX_PROTOCOL_FEE_BPS = 1e4;

    /**
     * @notice Uniswap v4's largest tick magnitude (`TickMath.MAX_TICK`).
     */
    int256 internal constant MAX_TICK = 887_272;

    /**
     * @notice Uniswap v4 static LP fee denominator; a fee at or above it is not a valid static pool fee.
     */
    uint24 internal constant MAX_LP_FEE = 1e6;

    /**
     * @notice StateView shared by every compatible implementation.
     */
    IStateViewLike public immutable stateView;
    /**
     * @notice PriceGuard shared by every compatible implementation.
     */
    IPriceGuard public immutable priceGuard;
    /**
     * @notice ShapeLibrary used to validate new immutable vault configurations.
     */
    IShapeLibrary public immutable shapes;
    /**
     * @notice PositionManager shared by every compatible implementation.
     */
    address public immutable positionManager;
    /**
     * @notice Permit2 shared by every compatible implementation.
     */
    address public immutable permit2;
    /**
     * @notice PoolManager shared by every compatible implementation.
     */
    address public immutable poolManager;
    /**
     * @notice SwapExecutor shared by every compatible implementation.
     */
    address public immutable swapExecutor;

    /**
     * @notice Vault implementation cloned for new vaults; existing clones keep the implementation they were made from.
     */
    address public override implementation;
    /**
     * @notice Strategy contract currently approved for each kind of newly created vault.
     */
    mapping(Strategy kind => IStrategy strategy) public override strategyOf;
    /**
     * @notice New-vault creation policy keyed by V4 pool id.
     */
    mapping(bytes32 poolId => PoolRule rule) public override poolRule;
    /**
     * @notice Whether an address is a successfully initialized factory vault.
     */
    mapping(address vault => bool known) public override isVault;
    /**
     * @dev Every registered vault in creation order; never iterated on-chain (indexers page with `vaultAt`).
     */
    address[] private _vaults;
    /**
     * @notice Protocol fee on collected trading fees, in basis points; read live by every vault.
     */
    uint256 public override protocolFeeBps;
    /**
     * @notice Governance-adjustable cap on `protocolFeeBps`, itself at most `ABSOLUTE_MAX_PROTOCOL_FEE_BPS`.
     */
    uint256 public override maxProtocolFeeBps;
    /**
     * @notice Contract that receives protocol fees; read live by every vault.
     */
    address public override feeCollector;
    /**
     * @notice Pause-only emergency account; zero until governance sets it.
     */
    address public override guardian;
    /**
     * @notice Whether an account may execute keeper-only actions on existing vaults.
     */
    mapping(address keeper => bool authorized) public override isKeeper;

    /**
     * @notice A required address is zero.
     */
    error ZeroAddress();
    /**
     * @notice An address expected to contain deployed code does not.
     */
    error NotContract();
    /**
     * @notice A Vault implementation or its immutable dependency graph is incompatible.
     */
    error InvalidImplementation();
    /**
     * @notice A current or maximum protocol fee violates its configured bounds.
     */
    error InvalidProtocolFee();
    /**
     * @notice A pool with hooks was supplied even though M8 permits hookless pools only.
     */
    error HookNotAllowed();
    /**
     * @notice The requested pool is not approved for new vaults.
     */
    error PoolNotAllowed();
    /**
     * @notice StateView reports that the requested pool is not initialized.
     */
    error PoolNotInitialized();
    /**
     * @notice PriceGuard has no usable configuration for the requested pool.
     */
    error NoOracle();
    /**
     * @notice PriceGuard does not trust the requested pool's current price.
     */
    error PriceUntrusted();
    /**
     * @notice ShapeLibrary does not recognize the requested shape.
     */
    error InvalidShape();
    /**
     * @notice Pool or range geometry is unsorted, unaligned, empty, or out of bounds.
     */
    error InvalidGeometry();
    /**
     * @notice The requested deposit cap is zero or exceeds the pool policy.
     */
    error InvalidDepositCap();
    /**
     * @notice No strategy contract is registered for the requested strategy kind.
     */
    error StrategyNotSet();
    /**
     * @notice The requested ERC-20 share name or symbol is empty.
     */
    error EmptyMetadata();

    /**
     * @notice Emitted when governance changes the implementation used for future clones.
     */
    event ImplementationSet(address indexed oldImplementation, address indexed newImplementation);
    /**
     * @notice Emitted when governance changes a strategy used for future clones.
     */
    event StrategySet(Strategy indexed kind, address indexed oldStrategy, address indexed newStrategy);
    /**
     * @notice Emitted when governance replaces a pool's complete creation policy.
     */
    event PoolRuleSet(
        bytes32 indexed poolId, bool allowed, bool baseIsCurrency0, uint256 maxDepositCap, PoolKey poolKey
    );
    /**
     * @notice Emitted when governance changes the collector read by all vaults.
     */
    event FeeCollectorSet(address indexed oldCollector, address indexed newCollector);
    /**
     * @notice Emitted when governance adds or removes a keeper.
     */
    event KeeperSet(address indexed keeper, bool authorized);
    /**
     * @notice Emitted when governance changes the pause-only guardian.
     */
    event GuardianSet(address indexed oldGuardian, address indexed newGuardian);
    /**
     * @notice Emitted after a deterministic clone is initialized and registered.
     */
    event VaultCreated(
        address indexed vault,
        address indexed creator,
        bytes32 indexed poolId,
        Strategy strategy,
        address strategyContract,
        bytes32 salt
    );

    /**
     * @inheritdoc IVaultFactory
     */
    function owner() public view override(IVaultFactory, Ownable) returns (address account) {
        return super.owner();
    }

    /**
     * @notice Deploys the factory with its audited dependency set and initial fee policy.
     * @dev The implementation must already point at this factory's predicted address and match its dependencies.
     * @param initialOwner Temporary owner that must hand control to the timelock through Ownable2Step.
     * @param implementation_ Initial Vault implementation, preconfigured with this factory address.
     * @param stateView_ V4 StateView used for pool-existence checks.
     * @param priceGuard_ Oracle guard used for creation-time trust checks.
     * @param shapes_ Shape registry used for configuration checks.
     * @param feeCollector_ Initial production fee collector.
     * @param initialProtocolFeeBps Initial fee charged on collected trading fees.
     * @param initialMaxProtocolFeeBps Initial mutable business cap.
     */
    constructor(
        address initialOwner,
        address implementation_,
        IStateViewLike stateView_,
        IPriceGuard priceGuard_,
        IShapeLibrary shapes_,
        address feeCollector_,
        uint256 initialProtocolFeeBps,
        uint256 initialMaxProtocolFeeBps
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) || implementation_ == address(0) || address(stateView_) == address(0)
                || address(priceGuard_) == address(0) || address(shapes_) == address(0) || feeCollector_ == address(0)
        ) revert ZeroAddress();
        if (
            address(stateView_).code.length == 0 || address(priceGuard_).code.length == 0
                || address(shapes_).code.length == 0 || feeCollector_.code.length == 0
        ) revert NotContract();
        if (
            initialMaxProtocolFeeBps > ABSOLUTE_MAX_PROTOCOL_FEE_BPS || initialProtocolFeeBps > initialMaxProtocolFeeBps
        ) revert InvalidProtocolFee();

        stateView = stateView_;
        priceGuard = priceGuard_;
        shapes = shapes_;
        feeCollector = feeCollector_;
        protocolFeeBps = initialProtocolFeeBps;
        maxProtocolFeeBps = initialMaxProtocolFeeBps;

        _validateImplementationBase(implementation_);
        positionManager = _readAddress(implementation_, IVault.positionManager.selector);
        permit2 = _readAddress(implementation_, IVault.permit2.selector);
        poolManager = _readAddress(implementation_, bytes4(keccak256("poolManager()")));
        swapExecutor = _readAddress(implementation_, IVault.swapExecutor.selector);
        if (
            positionManager == address(0) || permit2 == address(0) || poolManager == address(0)
                || swapExecutor.code.length == 0
        ) revert InvalidImplementation();
        _validateExecutor(implementation_, swapExecutor);
        implementation = implementation_;
    }

    /**
     * @notice Sets the implementation used only for future clones.
     * @dev Requires the same factory and immutable dependency set as the audited initial implementation.
     * @param newImplementation Compatible Vault implementation.
     */
    // aderyn-ignore-next-line(centralization-risk)
    function setImplementation(address newImplementation) external onlyOwner {
        _validateImplementationBase(newImplementation);
        if (
            _readAddress(newImplementation, IVault.positionManager.selector) != positionManager
                || _readAddress(newImplementation, IVault.permit2.selector) != permit2
                || _readAddress(newImplementation, bytes4(keccak256("poolManager()"))) != poolManager
                || _readAddress(newImplementation, IVault.swapExecutor.selector) != swapExecutor
        ) revert InvalidImplementation();
        _validateExecutor(newImplementation, swapExecutor);
        address oldImplementation = implementation;
        implementation = newImplementation;
        emit ImplementationSet(oldImplementation, newImplementation);
    }

    /**
     * @notice Registers the strategy copied into future vaults of `kind`.
     * @dev Existing vaults retain their strategy address and are unaffected by registry updates.
     * @param kind Strategy selector.
     * @param strategy New stateless strategy contract.
     */
    // aderyn-ignore-next-line(centralization-risk)
    function setStrategy(Strategy kind, IStrategy strategy) external onlyOwner {
        if (address(strategy) == address(0)) revert ZeroAddress();
        if (address(strategy).code.length == 0) revert NotContract();
        address oldStrategy = address(strategyOf[kind]);
        strategyOf[kind] = strategy;
        emit StrategySet(kind, oldStrategy, address(strategy));
    }

    /**
     * @notice Sets the complete creation policy for one V4 pool.
     * @dev Hooked pools and enabled rules with a zero maximum deposit cap are rejected.
     * @param key Pool key whose id indexes the rule.
     * @param allowed Whether new vaults may target the pool.
     * @param baseIsCurrency0 Approved base-asset orientation.
     * @param maxDepositCap Maximum token1-denominated cap accepted for each new vault.
     */
    function setPoolAllowed(PoolKey calldata key, bool allowed, bool baseIsCurrency0, uint256 maxDepositCap)
        external
        // aderyn-ignore-next-line(centralization-risk)
        onlyOwner
    {
        if (key.hooks != address(0)) revert HookNotAllowed();
        if (allowed && maxDepositCap == 0) revert InvalidDepositCap();
        bytes32 poolId = key.toId();
        poolRule[poolId] = PoolRule(allowed, baseIsCurrency0, maxDepositCap);
        emit PoolRuleSet(poolId, allowed, baseIsCurrency0, maxDepositCap, key);
    }

    /**
     * @inheritdoc IVaultFactory
     */
    // aderyn-ignore-next-line(centralization-risk)
    function setProtocolFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > maxProtocolFeeBps) revert InvalidProtocolFee();
        uint256 oldFeeBps = protocolFeeBps;
        protocolFeeBps = newFeeBps;
        emit ProtocolFeeBpsSet(oldFeeBps, newFeeBps);
    }

    /**
     * @inheritdoc IVaultFactory
     */
    // aderyn-ignore-next-line(centralization-risk)
    function setMaxProtocolFeeBps(uint256 newMaxFeeBps) external onlyOwner {
        if (newMaxFeeBps > ABSOLUTE_MAX_PROTOCOL_FEE_BPS || newMaxFeeBps < protocolFeeBps) {
            revert InvalidProtocolFee();
        }
        uint256 oldMaxFeeBps = maxProtocolFeeBps;
        maxProtocolFeeBps = newMaxFeeBps;
        emit MaxProtocolFeeBpsSet(oldMaxFeeBps, newMaxFeeBps);
    }

    /**
     * @notice Updates the collector used by existing and future vaults.
     * @dev The new collector must be a deployed contract; vaults read this setting dynamically.
     * @param newFeeCollector Deployed collector contract.
     */
    // aderyn-ignore-next-line(centralization-risk)
    function setFeeCollector(address newFeeCollector) external onlyOwner {
        if (newFeeCollector == address(0)) revert ZeroAddress();
        if (newFeeCollector.code.length == 0) revert NotContract();
        address oldCollector = feeCollector;
        feeCollector = newFeeCollector;
        emit FeeCollectorSet(oldCollector, newFeeCollector);
    }

    /**
     * @notice Adds or removes a keeper.
     * @dev Keeper status is read dynamically by existing vaults and never grants pause or ownership powers.
     * @param keeper Keeper account.
     * @param authorized New authorization state.
     */
    // aderyn-ignore-next-line(centralization-risk)
    function setKeeper(address keeper, bool authorized) external onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        isKeeper[keeper] = authorized;
        emit KeeperSet(keeper, authorized);
    }

    /**
     * @notice Updates the pause-only guardian.
     * @dev A zero guardian is rejected so emergency pause authority cannot be silently disabled.
     * @param newGuardian Nonzero guardian Safe.
     */
    // aderyn-ignore-next-line(centralization-risk)
    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        address oldGuardian = guardian;
        guardian = newGuardian;
        emit GuardianSet(oldGuardian, newGuardian);
    }

    /**
     * @inheritdoc IVaultFactory
     */
    function createVault(VaultConfig calldata config, string calldata name, string calldata symbol)
        external
        nonReentrant
        returns (address vault)
    {
        if (bytes(name).length == 0 || bytes(symbol).length == 0) revert EmptyMetadata();
        VaultConfig memory normalized = _validatedConfig(config);
        IStrategy strategy = strategyOf[normalized.strategy];
        // The whole entry point is nonReentrant and registration must follow all validation and initialization.
        // aderyn-fp-next-line(reentrancy-state-change)
        (, int24 tick,,) = stateView.getSlot0(normalized.poolKey.toId());
        // The strategy is called statically and nonReentrant prevents any callback into factory mutation.
        // aderyn-fp-next-line(reentrancy-state-change)
        strategy.validateConfig(normalized, tick);

        bytes32 salt = _salt(msg.sender, normalized, name, symbol);
        vault = Clones.cloneDeterministic(implementation, salt);
        // Registration intentionally follows successful initialization; a revert atomically removes the clone.
        // aderyn-fp-next-line(reentrancy-state-change)
        IVault(vault).initialize(name, symbol, address(strategy), normalized);
        isVault[vault] = true;
        _vaults.push(vault);
        emit VaultCreated(vault, msg.sender, normalized.poolKey.toId(), normalized.strategy, address(strategy), salt);
    }

    /**
     * @inheritdoc IVaultFactory
     */
    function predictVaultAddress(
        address creator,
        VaultConfig calldata config,
        string calldata name,
        string calldata symbol
    ) external view returns (address predicted) {
        if (creator == address(0)) revert ZeroAddress();
        VaultConfig memory normalized = config;
        normalized.baseIsCurrency0 = poolRule[normalized.poolKey.toId()].baseIsCurrency0;
        predicted =
            Clones.predictDeterministicAddress(implementation, _salt(creator, normalized, name, symbol), address(this));
    }

    /**
     * @inheritdoc IVaultFactory
     */
    function vaultCount() external view returns (uint256 count) {
        return _vaults.length;
    }

    /**
     * @inheritdoc IVaultFactory
     */
    function vaultAt(uint256 index) external view returns (address vault) {
        return _vaults[index];
    }

    /**
     * @notice Validates and normalizes a requested immutable vault configuration.
     * @dev The approved base orientation replaces caller input before the configuration is salted or initialized.
     * @param requested Caller-supplied vault configuration.
     * @return config Normalized configuration safe to pass to the clone initializer.
     */
    function _validatedConfig(VaultConfig calldata requested) private view returns (VaultConfig memory config) {
        config = requested;
        if (config.poolKey.hooks != address(0)) revert HookNotAllowed();
        bytes32 poolId = config.poolKey.toId();
        PoolRule memory rule = poolRule[poolId];
        if (!rule.allowed) revert PoolNotAllowed();
        config.baseIsCurrency0 = rule.baseIsCurrency0;

        (uint160 sqrtPriceX96,,,) = stateView.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        (IPriceGuard.PairConfig memory oracleConfig,,) = priceGuard.configOf(config.poolKey);
        if (oracleConfig.maxDeviationBps == 0) revert NoOracle();
        (bool trusted,) = priceGuard.isPriceTrusted(config.poolKey);
        if (!trusted) revert PriceUntrusted();
        if (!shapes.isValidShape(config.shapeId)) revert InvalidShape();
        _validateGeometry(config);
        if (config.depositCap == 0 || config.depositCap > rule.maxDepositCap) revert InvalidDepositCap();
        if (address(strategyOf[config.strategy]) == address(0)) revert StrategyNotSet();
    }

    /**
     * @notice Validates V4 pool ordering, fee, spacing, alignment, and tick bounds.
     * @dev Uses widened signed arithmetic so range endpoints cannot overflow int24 calculations.
     * @param config Normalized configuration to validate.
     */
    function _validateGeometry(VaultConfig memory config) private pure {
        int256 spacing = int256(config.poolKey.tickSpacing);
        address currency0 = Currency.unwrap(config.poolKey.currency0);
        address currency1 = Currency.unwrap(config.poolKey.currency1);
        if (
            spacing <= 0 || uint160(currency0) >= uint160(currency1) || currency1 == address(0)
                || config.poolKey.fee >= MAX_LP_FEE || int256(config.centerTick) % spacing != 0
                || int256(config.ticksLeft) % spacing != 0 || int256(config.ticksRight) % spacing != 0
        ) revert InvalidGeometry();
        // Division truncates toward zero, which rounds a negative quotient up: the lowest usable aligned tick.
        int256 minUsable = (-MAX_TICK / spacing) * spacing;
        int256 maxUsable = (MAX_TICK / spacing) * spacing;
        int256 lower = int256(config.centerTick) - int256(config.ticksLeft);
        int256 upper = int256(config.centerTick) + int256(config.ticksRight);
        if (lower < minUsable || upper > maxUsable || upper <= lower) revert InvalidGeometry();
    }

    /**
     * @notice Derives the deterministic clone salt from its creator and complete immutable identity.
     * @dev Creator namespacing prevents two users requesting the same configuration from colliding.
     * @param creator Salt namespace owner.
     * @param config Normalized immutable vault configuration.
     * @param name Share-token name.
     * @param symbol Share-token symbol.
     * @return Salt used by EIP-1167 CREATE2 clone deployment.
     */
    function _salt(address creator, VaultConfig memory config, string calldata name, string calldata symbol)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(creator, config, name, symbol));
    }

    /**
     * @notice Validates a candidate implementation's factory, StateView, and PriceGuard identities.
     * @dev Static reads also reject contracts that omit or malform required getters.
     * @param candidate Candidate implementation address.
     */
    function _validateImplementationBase(address candidate) private view {
        if (candidate == address(0)) revert ZeroAddress();
        if (candidate.code.length == 0) revert InvalidImplementation();
        if (
            _readAddress(candidate, IVault.factory.selector) != address(this)
                || _readAddress(candidate, IVault.stateView.selector) != address(stateView)
                || _readAddress(candidate, IVault.priceGuard.selector) != address(priceGuard)
        ) revert InvalidImplementation();
    }

    /**
     * @notice Validates the executor's factory, guard, and M6 module relationship to a Vault implementation.
     * @dev The relationship is immutable and therefore required to match before any clone can use the candidate.
     * @param candidate Candidate Vault implementation.
     * @param executor SwapExecutor read from the candidate.
     */
    function _validateExecutor(address candidate, address executor) private view {
        if (
            _readAddress(executor, bytes4(keccak256("factory()"))) != address(this)
                || _readAddress(executor, bytes4(keccak256("priceGuard()"))) != address(priceGuard)
                || _readAddress(executor, bytes4(keccak256("vaultModule()")))
                    != _readAddress(candidate, IVault.m6Module.selector)
        ) revert InvalidImplementation();
    }

    /**
     * @notice Reads and strictly decodes one address-valued getter.
     * @dev Rejects failed calls, non-word return data, and dirty high-order bits.
     * @param target Contract to query.
     * @param selector Getter selector.
     * @return value Strictly decoded address.
     */
    function _readAddress(address target, bytes4 selector) private view returns (address value) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSelector(selector));
        if (!ok || data.length != 32) revert InvalidImplementation();
        uint256 word = abi.decode(data, (uint256));
        if (word >> 160 != 0) revert InvalidImplementation();
        value = address(uint160(word));
    }
}
