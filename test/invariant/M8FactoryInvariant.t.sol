// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {SwapExecutor} from "../../src/SwapExecutor.sol";
import {Vault} from "../../src/Vault.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {NormalLPStrategy} from "../../src/strategies/NormalLPStrategy.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {IVaultFactory} from "../../src/interfaces/IVaultFactory.sol";
import {IPermit2Like} from "../../src/interfaces/external/IPermit2Like.sol";
import {IPositionManagerLike} from "../../src/interfaces/external/IPositionManagerLike.sol";
import {IUniversalRouterLike} from "../../src/interfaces/external/IUniversalRouterLike.sol";
import {Currency, PoolKey, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {MockPermit2, MockPositionManager, MockVaultPriceGuard, MockVaultStateView} from "../mocks/VaultMocks.sol";
import {MintableToken} from "../mocks/TokenMocks.sol";

contract M8FactoryHandler {
    uint256 internal constant SLOT_COUNT = 16;
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    VaultFactory public immutable factory;
    address public immutable owner;
    VaultConfig private _config;
    mapping(uint256 slot => address vault) public vaultForSlot;
    mapping(address vault => bytes32 configHash) public configHashOf;
    mapping(address vault => address strategy) public strategyOf;
    mapping(address vault => address implementation) public implementationOf;
    mapping(address vault => address predicted) public predictedOf;
    uint256 public successful;
    uint256 public governanceChanges;

    constructor(VaultFactory factory_, address owner_, VaultConfig memory config_) {
        factory = factory_;
        owner = owner_;
        _config = config_;
    }

    function create(uint8 rawSlot) external {
        uint256 slot = uint256(rawSlot) % SLOT_COUNT;
        string memory name = _name(slot);
        address predicted = factory.predictVaultAddress(address(this), _config, name, "M8");
        address vault = factory.createVault(_config, name, "M8");
        vaultForSlot[slot] = vault;
        configHashOf[vault] = keccak256(abi.encode(Vault(payable(vault)).config()));
        strategyOf[vault] = address(factory.strategyOf(_config.strategy));
        implementationOf[vault] = factory.implementation();
        predictedOf[vault] = predicted;
        ++successful;
    }

    // ---- governance actions between creations (the timelock in production) ----

    function setFee(uint256 bps) external {
        uint256 fee = bps % (factory.maxProtocolFeeBps() + 1); // read before the prank, which the next call consumes
        vm.prank(owner);
        factory.setProtocolFeeBps(fee);
        ++governanceChanges;
    }

    function flipRule(bool baseIsCurrency0, uint256 cap) external {
        vm.prank(owner);
        factory.setPoolAllowed(_config.poolKey, true, baseIsCurrency0, 100_000 ether + cap % 1e30);
        ++governanceChanges;
    }

    function rotateStrategy() external {
        NormalLPStrategy fresh =
            new NormalLPStrategy(NormalLPStrategy(address(factory.strategyOf(_config.strategy))).shapes());
        vm.prank(owner);
        factory.setStrategy(_config.strategy, fresh);
        ++governanceChanges;
    }

    function rotateImplementation() external {
        address fresh = M8FactoryInvariantTest(owner).deployImplementation();
        vm.prank(owner);
        factory.setImplementation(fresh);
        ++governanceChanges;
    }

    function nameForSlot(uint256 slot) external pure returns (string memory) {
        return _name(slot);
    }

    function config() external view returns (VaultConfig memory) {
        return _config;
    }

    function _name(uint256 slot) private pure returns (string memory) {
        return string(abi.encodePacked("M8-", bytes32(slot)));
    }
}

contract M8FactoryInvariantTest is StdInvariant, Test {
    uint256 private constant SLOT_COUNT = 16;

    VaultFactory private factory;
    M8FactoryHandler private handler;
    NormalLPStrategy private strategy;
    MockVaultStateView private stateView;
    MockVaultPriceGuard private guard;
    MockPermit2 private permit2;
    MockPositionManager private positionManager;
    ShapeLibrary private shapes;
    SwapExecutor private executor;
    address private predictedFactory;

    function setUp() public {
        stateView = new MockVaultStateView();
        guard = new MockVaultPriceGuard();
        permit2 = new MockPermit2();
        positionManager = new MockPositionManager(permit2, stateView);
        shapes = new ShapeLibrary();
        MintableToken token1 = new MintableToken();
        FeeCollector collector = new FeeCollector(address(this), address(0xBEEF));

        uint64 nonce = vm.getNonce(address(this));
        predictedFactory = vm.computeCreateAddress(address(this), nonce + 2);
        executor = new SwapExecutor(
            IUniversalRouterLike(address(0x1111)),
            IPermit2Like(address(permit2)),
            IVaultFactory(predictedFactory),
            IPriceGuard(address(guard)),
            address(0)
        );
        address implementation = deployImplementation();
        factory = new VaultFactory(
            address(this), implementation, stateView, IPriceGuard(address(guard)), shapes, address(collector), 0, 10_000
        );
        strategy = new NormalLPStrategy(shapes);
        factory.setStrategy(Strategy.NormalLP, strategy);

        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token1)), 500, 60, address(0));
        IPriceGuard.PairConfig memory oracle;
        oracle.maxDeviationBps = 100;
        guard.setPairConfig(key, oracle);
        factory.setPoolAllowed(key, true, true, 1_000_000 ether);

        VaultConfig memory config;
        config.poolKey = key;
        config.strategy = Strategy.NormalLP;
        config.shapeId = 1;
        config.centerTick = 0;
        config.ticksLeft = 600;
        config.ticksRight = 600;
        config.autoRebalance = true;
        config.depositCap = 100_000 ether;
        handler = new M8FactoryHandler(factory, address(this), config);
        targetContract(address(handler));
    }

    /**
     * A compatible Vault implementation (same factory, executor and dependencies), for governance rotations.
     */
    function deployImplementation() public returns (address) {
        return address(
            new Vault(
                IPositionManagerLike(address(positionManager)),
                stateView,
                IPermit2Like(address(permit2)),
                IPriceGuard(address(guard)),
                shapes,
                address(executor),
                predictedFactory,
                address(0x4444)
            )
        );
    }

    function invariant_registryContainsOnlyInitializedPredictedClones() public view {
        assertEq(factory.vaultCount(), handler.successful());
        for (uint256 slot; slot < SLOT_COUNT; ++slot) {
            address vault = handler.vaultForSlot(slot);
            if (vault == address(0)) continue;
            assertTrue(factory.isVault(vault));
            assertEq(vault, handler.predictedOf(vault), "created at the address predicted for it");
            assertEq(Vault(payable(vault)).factory(), address(factory));
        }
    }

    /**
     * M8 audit: governance changes (fee, pool rule and orientation, strategy, implementation) between creations
     * never reach an existing vault's configuration, strategy or code.
     */
    function invariant_governanceNeverRewritesAnExistingVault() public view {
        for (uint256 slot; slot < SLOT_COUNT; ++slot) {
            address vault = handler.vaultForSlot(slot);
            if (vault == address(0)) continue;
            assertEq(keccak256(abi.encode(Vault(payable(vault)).config())), handler.configHashOf(vault), "config");
            // Vault storage slot 11 is `_strategy` (layout checked against both modules)
            address stored = address(uint160(uint256(vm.load(vault, bytes32(uint256(11))))));
            assertEq(stored, handler.strategyOf(vault), "strategy");
            assertEq(_cloneTarget(vault), handler.implementationOf(vault), "implementation");
        }
    }

    function _cloneTarget(address clone) private view returns (address target) {
        bytes memory code = clone.code; // EIP-1167: 10-byte prefix, 20-byte implementation, 15-byte suffix
        assembly {
            target := shr(96, mload(add(add(code, 0x20), 10)))
        }
    }
}
