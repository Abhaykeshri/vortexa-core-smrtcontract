// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {Vault} from "../../src/Vault.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {VaultLens} from "../../src/VaultLens.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {SwapExecutor} from "../../src/SwapExecutor.sol";
import {NormalLPStrategy} from "../../src/strategies/NormalLPStrategy.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {IPermit2Like} from "../../src/interfaces/external/IPermit2Like.sol";
import {IPositionManagerLike} from "../../src/interfaces/external/IPositionManagerLike.sol";
import {IUniversalRouterLike} from "../../src/interfaces/external/IUniversalRouterLike.sol";
import {Currency, PoolKey, RebalanceParams, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {PoolIdLib} from "../../src/libraries/PoolIdLib.sol";
import {IVaultLens} from "../../src/interfaces/IVaultLens.sol";
import {IVaultFactory} from "../../src/interfaces/IVaultFactory.sol";
import {IStateViewLike} from "../../src/interfaces/external/IStateViewLike.sol";
import {MockPermit2, MockPositionManager, MockVaultPriceGuard, MockVaultStateView} from "../mocks/VaultMocks.sol";
import {FalseReturningToken, MintableToken} from "../mocks/TokenMocks.sol";

contract M8Test is Test {
    using PoolIdLib for PoolKey;

    uint256 private constant DELAY = 48 hours;

    MockVaultStateView private stateView;
    MockVaultPriceGuard private guard;
    MockPermit2 private permit2;
    MockPositionManager private positionManager;
    ShapeLibrary private shapes;
    MintableToken private token1;
    FeeCollector private collector;
    SwapExecutor private executorContract;
    Vault private implementationContract;
    VaultFactory private factory;
    NormalLPStrategy private strategy;
    VaultLens private lens;
    PoolKey private key;

    address private guardian = makeAddr("guardianSafe");
    address private keeper = makeAddr("keeper");
    address private treasury = makeAddr("treasury");
    address private user = makeAddr("user");

    function setUp() public {
        stateView = new MockVaultStateView();
        guard = new MockVaultPriceGuard();
        permit2 = new MockPermit2();
        positionManager = new MockPositionManager(permit2, stateView);
        shapes = new ShapeLibrary();
        token1 = new MintableToken();
        collector = new FeeCollector(address(this), treasury);

        uint64 nonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nonce + 2);
        executorContract = new SwapExecutor(
            IUniversalRouterLike(address(0x1111)),
            IPermit2Like(address(permit2)),
            // The constructor only stores the predicted address; the factory is deployed two CREATEs later.
            // forge-lint: disable-next-line(unsafe-typecast)
            IVaultFactory(predictedFactory),
            IPriceGuard(address(guard)),
            address(0)
        );
        implementationContract = new Vault(
            IPositionManagerLike(address(positionManager)),
            stateView,
            IPermit2Like(address(permit2)),
            IPriceGuard(address(guard)),
            shapes,
            address(executorContract),
            predictedFactory,
            address(0x4444)
        );
        factory = new VaultFactory(
            address(this),
            address(implementationContract),
            stateView,
            IPriceGuard(address(guard)),
            shapes,
            address(collector),
            100,
            2_500
        );
        assertEq(address(factory), predictedFactory, "nonce prediction");

        strategy = new NormalLPStrategy(shapes);
        factory.setStrategy(Strategy.NormalLP, strategy);
        factory.setGuardian(guardian);
        factory.setKeeper(keeper, true);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token1)), 500, 60, address(0));
        IPriceGuard.PairConfig memory oracle;
        oracle.maxDeviationBps = 100;
        guard.setPairConfig(key, oracle);
        factory.setPoolAllowed(key, true, true, 1_000_000 ether);
        lens = new VaultLens(factory, stateView);
    }

    function test_factoryCreatesPredictedCloneAndNormalizesConfig() public {
        VaultConfig memory requested = _config();
        requested.baseIsCurrency0 = false;
        address predicted = factory.predictVaultAddress(user, requested, "Vortex", "VTX");
        vm.prank(user);
        address created = factory.createVault(requested, "Vortex", "VTX");

        assertEq(created, predicted);
        assertTrue(factory.isVault(created));
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.vaultAt(0), created);
        assertEq(Vault(payable(created)).factory(), address(factory));
        assertTrue(Vault(payable(created)).config().baseIsCurrency0);
        vm.prank(user);
        vm.expectRevert();
        factory.createVault(requested, "Vortex", "VTX");
    }

    function testFuzz_predictionIsCreatorSpecific(address creatorA, address creatorB) public view {
        vm.assume(creatorA != address(0) && creatorB != address(0) && creatorA != creatorB);
        VaultConfig memory config = _config();
        assertTrue(
            factory.predictVaultAddress(creatorA, config, "Vortex", "VTX")
                != factory.predictVaultAddress(creatorB, config, "Vortex", "VTX")
        );
    }

    function testFuzz_misalignedCenterCannotCreateVault(int24 center) public {
        vm.assume(center % key.tickSpacing != 0);
        VaultConfig memory config = _config();
        config.centerTick = center;
        vm.expectRevert(VaultFactory.InvalidGeometry.selector);
        factory.createVault(config, "Misaligned", "MIS");
    }

    function test_factoryRejectsCreationPolicyFailures() public {
        VaultConfig memory config = _config();

        PoolKey memory unapproved = config.poolKey;
        unapproved.fee = 3_000;
        config.poolKey = unapproved;
        vm.expectRevert(VaultFactory.PoolNotAllowed.selector);
        factory.createVault(config, "Bad", "BAD");

        config = _config();
        guard.setTrusted(false);
        vm.expectRevert(VaultFactory.PriceUntrusted.selector);
        factory.createVault(config, "Bad", "BAD");
        guard.setTrusted(true);

        stateView.setSlot0(0, 0);
        vm.expectRevert(VaultFactory.PoolNotInitialized.selector);
        factory.createVault(config, "Bad", "BAD");
        stateView.setSlot0(uint160(1 << 96), 0);

        config.centerTick = 1;
        vm.expectRevert(VaultFactory.InvalidGeometry.selector);
        factory.createVault(config, "Bad", "BAD");

        config = _config();
        config.depositCap = 1_000_001 ether;
        vm.expectRevert(VaultFactory.InvalidDepositCap.selector);
        factory.createVault(config, "Bad", "BAD");
    }

    function test_factoryRejectsHooksMissingOracleStrategyAndBadShape() public {
        VaultConfig memory config = _config();
        config.poolKey.hooks = address(0xBEEF);
        vm.expectRevert(VaultFactory.HookNotAllowed.selector);
        factory.createVault(config, "Bad", "BAD");

        config = _config();
        config.shapeId = 8;
        vm.expectRevert(VaultFactory.InvalidShape.selector);
        factory.createVault(config, "Bad", "BAD");

        PoolKey memory other = key;
        other.fee = 3_000;
        factory.setPoolAllowed(other, true, true, 1_000_000 ether);
        config = _config();
        config.poolKey = other;
        vm.expectRevert(VaultFactory.NoOracle.selector);
        factory.createVault(config, "Bad", "BAD");

        factory.setStrategy(Strategy.NormalLP, strategy);
        // A strategy kind without a registry entry is rejected before clone deployment.
        config = _config();
        config.strategy = Strategy.BuyTheDip;
        vm.expectRevert(VaultFactory.StrategyNotSet.selector);
        factory.createVault(config, "Bad", "BAD");
    }

    function test_failedStrategyValidationCannotRegisterOrConsumeCloneAddress() public {
        VaultConfig memory config = _config();
        address predicted = factory.predictVaultAddress(address(this), config, "Retry", "RTY");
        vm.mockCallRevert(address(strategy), abi.encodeWithSelector(IStrategy.validateConfig.selector), bytes("bad"));
        vm.expectRevert(bytes("bad"));
        factory.createVault(config, "Retry", "RTY");
        assertEq(factory.vaultCount(), 0);
        assertFalse(factory.isVault(predicted));
        assertEq(predicted.code.length, 0);

        vm.clearMockedCalls();
        assertEq(factory.createVault(config, "Retry", "RTY"), predicted);
    }

    function test_initializerFailureRollsBackCloneAndRegistry() public {
        FalseReturningToken bad = new FalseReturningToken();
        PoolKey memory badKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(bad)), 500, 60, address(0));
        IPriceGuard.PairConfig memory oracle;
        oracle.maxDeviationBps = 100;
        guard.setPairConfig(badKey, oracle);
        factory.setPoolAllowed(badKey, true, true, 1_000_000 ether);
        VaultConfig memory config = _config();
        config.poolKey = badKey;
        address predicted = factory.predictVaultAddress(address(this), config, "Broken", "BRK");

        vm.expectRevert();
        factory.createVault(config, "Broken", "BRK");
        assertEq(factory.vaultCount(), 0);
        assertFalse(factory.isVault(predicted));
        assertEq(predicted.code.length, 0);
    }

    function test_implementationMustPreserveEveryExposedImmutableDependency() public {
        MockVaultStateView wrongStateView = new MockVaultStateView();
        Vault incompatible = new Vault(
            IPositionManagerLike(address(positionManager)),
            wrongStateView,
            IPermit2Like(address(permit2)),
            IPriceGuard(address(guard)),
            shapes,
            address(executorContract),
            address(factory),
            address(0x4444)
        );
        vm.expectRevert(VaultFactory.InvalidImplementation.selector);
        factory.setImplementation(address(incompatible));

        Vault compatible = new Vault(
            IPositionManagerLike(address(positionManager)),
            stateView,
            IPermit2Like(address(permit2)),
            IPriceGuard(address(guard)),
            shapes,
            address(executorContract),
            address(factory),
            address(0x4444)
        );
        factory.setImplementation(address(compatible));
        assertEq(factory.implementation(), address(compatible));
    }

    function test_feeKeeperGuardianAndImplementationAdministration() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        factory.setProtocolFeeBps(200);
        factory.setProtocolFeeBps(2_500);
        vm.expectRevert(VaultFactory.InvalidProtocolFee.selector);
        factory.setProtocolFeeBps(2_501);
        factory.setMaxProtocolFeeBps(5_000);
        factory.setProtocolFeeBps(5_000);
        vm.expectRevert(VaultFactory.InvalidProtocolFee.selector);
        factory.setMaxProtocolFeeBps(4_999);
        vm.expectRevert(VaultFactory.InvalidProtocolFee.selector);
        factory.setMaxProtocolFeeBps(10_001);
        assertTrue(factory.isKeeper(keeper));
        assertEq(factory.guardian(), guardian);

        vm.expectRevert(VaultFactory.InvalidImplementation.selector);
        factory.setImplementation(address(strategy));
    }

    function test_existingVaultIsUnaffectedByRegistryAndImplementationPolicyChanges() public {
        Vault created = Vault(payable(factory.createVault(_config(), "Old", "OLD")));
        VaultConfig memory beforeConfig = created.config();
        NormalLPStrategy replacement = new NormalLPStrategy(shapes);
        factory.setStrategy(Strategy.NormalLP, replacement);
        assertEq(keccak256(abi.encode(created.config())), keccak256(abi.encode(beforeConfig)));
        assertEq(factory.vaultAt(0), address(created));
    }

    /**
     * M8 exit gate (guide 10, "Role matrix tests pass"): every privileged entry point called by every role. A call a
     * role may make never fails with an authorization error; a call it may not make fails with exactly that error.
     * Owner = the timelock (this test contract), plus the guardian, a keeper and an unprivileged user.
     */
    function test_roleMatrix() public {
        Vault vault = Vault(payable(factory.createVault(_config(), "Matrix", "MTX")));
        FeeCollector otherCollector = new FeeCollector(address(this), treasury);
        address[4] memory roles = [address(this), guardian, keeper, user];
        bytes memory ownerOnly = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0));

        // factory administration: owner only
        bytes[10] memory admin = [
            abi.encodeCall(VaultFactory.setProtocolFeeBps, (200)),
            abi.encodeCall(VaultFactory.setMaxProtocolFeeBps, (3_000)),
            abi.encodeCall(VaultFactory.setFeeCollector, (address(otherCollector))),
            abi.encodeCall(VaultFactory.setKeeper, (makeAddr("newKeeper"), true)),
            abi.encodeCall(VaultFactory.setGuardian, (makeAddr("newGuardian"))),
            abi.encodeCall(VaultFactory.setPoolAllowed, (key, false, true, 0)),
            abi.encodeCall(VaultFactory.setStrategy, (Strategy.NormalLP, IStrategy(address(strategy)))),
            abi.encodeCall(VaultFactory.setImplementation, (address(implementationContract))),
            abi.encodeWithSignature("transferOwnership(address)", makeAddr("successor")),
            abi.encodeWithSignature("renounceOwnership()")
        ];
        for (uint256 c; c < admin.length; ++c) {
            for (uint256 r; r < roles.length; ++r) {
                _expectRole(roles[r], address(factory), admin[c], r == 0, _withAccount(ownerOnly, roles[r]));
            }
        }

        // collector: recipient and ownership are owner only, collection is open to everyone
        for (uint256 r; r < roles.length; ++r) {
            bytes memory denied = _withAccount(ownerOnly, roles[r]);
            _expectRole(
                roles[r], address(collector), abi.encodeCall(FeeCollector.setRecipient, (treasury)), r == 0, denied
            );
            _expectRole(
                roles[r],
                address(collector),
                abi.encodeWithSignature("transferOwnership(address)", user),
                r == 0,
                denied
            );
            _expectRole(
                roles[r],
                address(collector),
                abi.encodeCall(FeeCollector.collect, (Currency.wrap(address(0)))),
                true,
                ""
            );
        }

        // vault creation is permissionless
        for (uint256 r; r < roles.length; ++r) {
            _expectRole(
                roles[r],
                address(factory),
                abi.encodeCall(VaultFactory.createVault, (_config(), "Any", vm.toString(r))),
                true,
                ""
            );
        }

        // vault: guardian pauses, owner unpauses, keepers compound and rebalance, anyone collects, nobody re-initializes
        bytes memory notAuthorized = abi.encodeWithSelector(Vault.NotAuthorized.selector);
        for (uint256 r; r < roles.length; ++r) {
            _expectRole(roles[r], address(vault), abi.encodeCall(Vault.pause, ()), roles[r] == guardian, notAuthorized);
            _expectRole(roles[r], address(vault), abi.encodeCall(Vault.unpause, ()), r == 0, notAuthorized);
            _expectRole(roles[r], address(vault), abi.encodeCall(Vault.compound, ()), roles[r] == keeper, notAuthorized);
            _expectRole(
                roles[r],
                address(vault),
                abi.encodeCall(Vault.rebalance, (RebalanceParams({newCenterTick: 0, maxSlippageBps: 50}))),
                roles[r] == keeper,
                abi.encodeWithSelector(IVault.NotKeeper.selector)
            );
            _expectRole(roles[r], address(vault), abi.encodeCall(Vault.collectFees, ()), true, "");
            _expectRole(
                roles[r],
                address(vault),
                abi.encodeCall(Vault.initialize, ("X", "X", address(strategy), _config())),
                false,
                notAuthorized
            );
        }
    }

    /**
     * Calls `target` as `caller` in a throwaway snapshot. Allowed: the call must not fail with `denied`. Not allowed:
     * it must fail with exactly `denied`.
     */
    function _expectRole(address caller, address target, bytes memory data, bool allowed, bytes memory denied) private {
        uint256 snap = vm.snapshotState();
        vm.prank(caller);
        (bool ok, bytes memory ret) = target.call(data);
        if (allowed) {
            assertTrue(ok || keccak256(ret) != keccak256(denied), "an allowed role was refused for authorization");
        } else {
            assertFalse(ok, "an unauthorized role succeeded");
            assertEq(ret, denied, "an unauthorized role failed with the wrong error");
        }
        vm.revertToState(snap);
    }

    function _withAccount(bytes memory selectorAndZero, address account) private pure returns (bytes memory out) {
        out = abi.encodeWithSelector(bytes4(selectorAndZero), account);
    }

    /**
     * M8 audit (mutation gaps): every geometry boundary, a zero cap and empty metadata are refused at creation.
     */
    function test_createVaultRefusesEveryGeometryBoundaryZeroCapAndEmptyMetadata() public {
        VaultConfig memory config = _config();
        config.ticksLeft = 610;
        _expectCreate(config, VaultFactory.InvalidGeometry.selector);
        config = _config();
        config.ticksRight = 610;
        _expectCreate(config, VaultFactory.InvalidGeometry.selector);
        config = _config();
        config.centerTick = -887_220; // lowest usable tick for spacing 60
        _expectCreate(config, VaultFactory.InvalidGeometry.selector);
        config = _config();
        config.centerTick = 887_220; // highest usable tick
        _expectCreate(config, VaultFactory.InvalidGeometry.selector);
        config = _config();
        config.ticksLeft = 0;
        config.ticksRight = 0;
        _expectCreate(config, VaultFactory.InvalidGeometry.selector);
        config = _config();
        config.depositCap = 0;
        _expectCreate(config, VaultFactory.InvalidDepositCap.selector);

        // pool keys the allowlist would accept but that cannot be Uniswap pools for a vault
        config = _config();
        config.poolKey.fee = 1_000_000;
        _allow(config.poolKey);
        _expectCreate(config, VaultFactory.InvalidGeometry.selector);
        config = _config();
        config.poolKey.tickSpacing = 0;
        _allow(config.poolKey);
        _expectCreate(config, VaultFactory.InvalidGeometry.selector);
        config = _config();
        (config.poolKey.currency0, config.poolKey.currency1) = (config.poolKey.currency1, config.poolKey.currency0);
        _allow(config.poolKey);
        _expectCreate(config, VaultFactory.InvalidGeometry.selector);

        // an unsorted ERC-20/ERC-20 key (both currencies nonzero, so only the ordering check can refuse it)
        config = _config();
        MintableToken tokenA = new MintableToken();
        (address lo, address hi) =
            address(tokenA) < address(token1) ? (address(tokenA), address(token1)) : (address(token1), address(tokenA));
        config.poolKey.currency0 = Currency.wrap(hi);
        config.poolKey.currency1 = Currency.wrap(lo);
        _allow(config.poolKey);
        _expectCreate(config, VaultFactory.InvalidGeometry.selector);

        vm.expectRevert(VaultFactory.EmptyMetadata.selector);
        factory.createVault(_config(), "", "SYM");
        vm.expectRevert(VaultFactory.EmptyMetadata.selector);
        factory.createVault(_config(), "Name", "");
    }

    /**
     * M8 audit (mutation gaps): every administrative setter validates its input.
     */
    function test_settersValidateTheirInput() public {
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.setStrategy(Strategy.NormalLP, IStrategy(address(0)));
        vm.expectRevert(VaultFactory.NotContract.selector);
        factory.setStrategy(Strategy.NormalLP, IStrategy(makeAddr("eoa")));
        PoolKey memory hooked = key;
        hooked.hooks = address(0xBEEF);
        vm.expectRevert(VaultFactory.HookNotAllowed.selector);
        factory.setPoolAllowed(hooked, false, true, 0);
        vm.expectRevert(VaultFactory.InvalidDepositCap.selector);
        factory.setPoolAllowed(key, true, true, 0);
        factory.setPoolAllowed(key, false, true, 0); // disabling needs no cap
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.setFeeCollector(address(0));
        vm.expectRevert(VaultFactory.NotContract.selector);
        factory.setFeeCollector(makeAddr("eoaCollector"));
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.setKeeper(address(0), true);
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.setGuardian(address(0));
    }

    /**
     * M8 audit (mutation gaps): the prediction applies the pool rule's orientation exactly like `createVault`, so a
     * creator who asks for the other orientation still gets the predicted address.
     */
    function test_predictionAppliesTheRuleOrientation() public {
        VaultConfig memory config = _config();
        config.baseIsCurrency0 = false; // the rule says true
        address predicted = factory.predictVaultAddress(user, config, "Flip", "FLP");
        vm.prank(user);
        address created = factory.createVault(config, "Flip", "FLP");
        assertEq(created, predicted);
        assertTrue(Vault(payable(created)).config().baseIsCurrency0);
    }

    /**
     * M8 audit (mutation gap): the collector refuses a zero recipient at construction as well as in `setRecipient`.
     */
    function test_feeCollectorConstructorRefusesZeroAddresses() public {
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        this.deployCollector(address(this), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        this.deployCollector(address(0), treasury);
        assertEq(this.deployCollector(address(this), treasury).recipient(), treasury);
    }

    /**
     * External so `vm.expectRevert` catches a reverting constructor (see `PriceGuard.t.sol`).
     */
    function deployCollector(address owner_, address recipient_) external returns (FeeCollector) {
        return new FeeCollector(owner_, recipient_);
    }

    /**
     * M8 audit (mutation gaps): lens guards, the half-open in-range test at both band edges, the pool-availability
     * flag for an uninitialized price, and the accounting flag when only `totalAssets` fails.
     */
    function test_lensGuardsBoundariesAndAvailabilityFlags() public {
        vm.expectRevert(VaultLens.ZeroAddress.selector);
        this.deployLens(IVaultFactory(address(factory)), IStateViewLike(address(0)));
        vm.expectRevert(VaultLens.ZeroAddress.selector);
        this.deployLens(IVaultFactory(address(0)), stateView);

        Vault created = Vault(payable(factory.createVault(_config(), "Edges", "EDG")));
        token1.mint(user, 20 ether);
        vm.deal(user, 20 ether);
        vm.startPrank(user);
        token1.approve(address(created), type(uint256).max);
        created.depositPair{value: 10 ether}(10 ether, 10 ether, 1, user);
        vm.stopPrank();

        vm.expectRevert(VaultLens.UnknownVault.selector);
        lens.userPosition(user, user);
        vm.expectRevert(VaultLens.ZeroAddress.selector);
        lens.userPosition(address(created), address(0));

        int24 lower = created.bands()[0].tickLower;
        int24 upper = created.bands()[created.bands().length - 1].tickUpper;
        (uint160 sp,) = (uint160(1 << 96), int24(0));
        stateView.setSlot0(sp, lower);
        assertTrue(lens.vaultInfo(address(created)).inRange, "the lower edge is inside");
        stateView.setSlot0(sp, upper - 1);
        assertTrue(lens.vaultInfo(address(created)).inRange, "one tick below the upper edge is inside");
        stateView.setSlot0(sp, upper);
        assertFalse(lens.vaultInfo(address(created)).inRange, "the upper edge is outside");
        stateView.setSlot0(sp, lower - 1);
        assertFalse(lens.vaultInfo(address(created)).inRange, "below the lower edge is outside");

        stateView.setSlot0(0, 0);
        assertFalse(lens.vaultInfo(address(created)).poolStateAvailable, "an uninitialized price is unavailable");
        stateView.setSlot0(sp, 0);

        vm.mockCallRevert(address(created), abi.encodeWithSelector(Vault.totalAssets.selector), bytes("assets"));
        IVaultLens.VaultInfo memory info = lens.vaultInfo(address(created));
        assertFalse(info.accountingAvailable, "a failing totalAssets is reported");
        assertGt(info.totalAssets0 + info.totalAssets1, 0, "the in-kind preview still answers");
        vm.clearMockedCalls();
    }

    /**
     * External so `vm.expectRevert` catches a reverting constructor.
     */
    function deployLens(IVaultFactory factory_, IStateViewLike stateView_) external returns (VaultLens) {
        return new VaultLens(factory_, stateView_);
    }

    function _expectCreate(VaultConfig memory config, bytes4 selector) private {
        vm.expectRevert(selector);
        factory.createVault(config, "Bad", "BAD");
    }

    function _allow(PoolKey memory k) private {
        IPriceGuard.PairConfig memory oracle;
        oracle.maxDeviationBps = 100;
        guard.setPairConfig(k, oracle);
        factory.setPoolAllowed(k, true, true, 1_000_000 ether);
    }

    function test_guardianCanOnlyPauseAndOwnerCanUnpause() public {
        Vault created = Vault(payable(factory.createVault(_config(), "Pause", "PAU")));
        vm.prank(guardian);
        created.pause();
        assertTrue(created.paused());
        vm.prank(guardian);
        vm.expectRevert(Vault.NotAuthorized.selector);
        created.unpause();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        factory.setProtocolFeeBps(200);
        created.unpause();
        assertFalse(created.paused());
    }

    function test_ownershipRenunciationRemainsOpenZeppelinCompatible() public {
        factory.renounceOwnership();
        collector.renounceOwnership();
        assertEq(factory.owner(), address(0));
        assertEq(collector.owner(), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.setProtocolFeeBps(200);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        collector.setRecipient(user);
    }

    function test_feeCollectorNativeTokenRepeatedAndAuthorization() public {
        vm.deal(address(collector), 3 ether);
        vm.prank(user);
        collector.collect(Currency.wrap(address(0)));
        assertEq(treasury.balance, 3 ether);
        vm.prank(user);
        assertEq(collector.collect(Currency.wrap(address(0))), 0);

        token1.mint(address(collector), 5 ether);
        vm.prank(user);
        collector.collect(Currency.wrap(address(token1)));
        assertEq(token1.balanceOf(treasury), 5 ether);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        collector.setRecipient(user);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        collector.setRecipient(address(0));
    }

    function test_feeCollectorRevertsOnFailedTokenTransfer() public {
        FalseReturningToken bad = new FalseReturningToken();
        bad.mint(address(collector), 1 ether);
        vm.expectRevert();
        collector.collect(Currency.wrap(address(bad)));
    }

    function test_feeCollectorBlocksRecipientReentrancyWithoutLosingFunds() public {
        ReenteringRecipient recipient = new ReenteringRecipient(collector);
        collector.setRecipient(address(recipient));
        vm.deal(address(collector), 2 ether);

        vm.prank(user);
        collector.collect(Currency.wrap(address(0)));

        assertTrue(recipient.attempted());
        assertFalse(recipient.reentrySucceeded());
        assertEq(address(recipient).balance, 2 ether);
        assertEq(address(collector).balance, 0);
    }

    function test_lensHandlesEmptyAndNonemptyVaultAndBatchLimit() public {
        Vault created = Vault(payable(factory.createVault(_config(), "Lens", "LEN")));
        IVaultLens.VaultInfo memory empty = lens.vaultInfo(address(created));
        assertEq(empty.totalShares, 0);
        assertEq(empty.totalAssets0, 0);
        assertEq(empty.totalAssets1, 0);
        assertTrue(empty.accountingAvailable);
        assertTrue(empty.poolStateAvailable);

        token1.mint(user, 20 ether);
        vm.deal(user, 20 ether);
        vm.startPrank(user);
        token1.approve(address(created), type(uint256).max);
        created.depositPair{value: 10 ether}(10 ether, 10 ether, 1, user);
        vm.stopPrank();

        IVaultLens.UserPosition memory position = lens.userPosition(address(created), user);
        assertGt(position.shares, 0);
        assertTrue(position.accountingAvailable);
        assertGt(position.amount0 + position.amount1, 0);
        IVaultLens.VaultInfo memory populated = lens.vaultInfo(address(created));
        assertTrue(populated.accountingAvailable);
        assertGt(populated.totalAssets0 + populated.totalAssets1, 0);

        address[] memory fifty = new address[](50);
        for (uint256 i; i < fifty.length; ++i) {
            fifty[i] = address(created);
        }
        assertEq(lens.vaultsInfo(fifty).length, 50);
        address[] memory fiftyOne = new address[](51);
        vm.expectRevert(VaultLens.TooMany.selector);
        lens.vaultsInfo(fiftyOne);
        vm.expectRevert(VaultLens.UnknownVault.selector);
        lens.vaultInfo(user);
    }

    function test_lensReportsOptionalAccountingAndPoolReadFailures() public {
        Vault created = Vault(payable(factory.createVault(_config(), "Fail-safe", "FAIL")));
        token1.mint(user, 20 ether);
        vm.deal(user, 20 ether);
        vm.startPrank(user);
        token1.approve(address(created), type(uint256).max);
        created.depositPair{value: 10 ether}(10 ether, 10 ether, 1, user);
        vm.stopPrank();

        vm.mockCallRevert(
            address(stateView), abi.encodeWithSelector(IStateViewLike.getPositionInfo.selector), bytes("accounting")
        );
        IVaultLens.VaultInfo memory unavailable = lens.vaultInfo(address(created));
        assertFalse(unavailable.accountingAvailable);
        assertFalse(lens.userPosition(address(created), user).accountingAvailable);
        vm.clearMockedCalls();

        vm.mockCallRevert(
            address(stateView), abi.encodeWithSelector(IStateViewLike.getSlot0.selector, key.toId()), bytes("state")
        );
        unavailable = lens.vaultInfo(address(created));
        assertFalse(unavailable.accountingAvailable);
        assertFalse(unavailable.poolStateAvailable);
        vm.clearMockedCalls();
    }

    function test_timelockHasRestrictedExecutionAndCompletesOwnershipHandover() public {
        address proposer = makeAddr("governanceSafe");
        address authorizedExecutor = makeAddr("authorizedExecutor");
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = authorizedExecutor;
        TimelockController timelock = new TimelockController(DELAY, proposers, executors, address(this));

        collector.transferOwnership(address(timelock));
        bytes memory data = abi.encodeCall(collector.acceptOwnership, ());
        bytes32 salt = keccak256("accept collector ownership");
        vm.prank(proposer);
        timelock.schedule(address(collector), 0, data, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(user);
        vm.expectRevert();
        timelock.execute(address(collector), 0, data, bytes32(0), salt);
        vm.prank(authorizedExecutor);
        timelock.execute(address(collector), 0, data, bytes32(0), salt);
        assertEq(collector.owner(), address(timelock));

        bytes memory update = abi.encodeCall(collector.setRecipient, (user));
        bytes32 cancelSalt = keccak256("cancel recipient update");
        vm.prank(proposer);
        timelock.schedule(address(collector), 0, update, bytes32(0), cancelSalt, DELAY);
        bytes32 id = timelock.hashOperation(address(collector), 0, update, bytes32(0), cancelSalt);
        vm.prank(proposer);
        timelock.cancel(id);
        assertFalse(timelock.isOperation(id));

        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
    }

    function _config() private view returns (VaultConfig memory config) {
        config.poolKey = key;
        config.strategy = Strategy.NormalLP;
        config.shapeId = 1;
        config.centerTick = 0;
        config.ticksLeft = 600;
        config.ticksRight = 600;
        config.autoRebalance = true;
        config.depositCap = 100_000 ether;
    }
}

contract ReenteringRecipient {
    FeeCollector private immutable _collector;
    bool public attempted;
    bool public reentrySucceeded;

    constructor(FeeCollector collector_) {
        _collector = collector_;
    }

    receive() external payable {
        attempted = true;
        (reentrySucceeded,) = address(_collector).call(abi.encodeCall(_collector.collect, (Currency.wrap(address(0)))));
    }
}
