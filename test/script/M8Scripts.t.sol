// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {PriceGuard} from "../../src/PriceGuard.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {Strategy} from "../../src/libraries/Types.sol";
import {DeployM8} from "../../script/DeployM8.s.sol";
import {NetworkConfig} from "../../script/NetworkConfigs.s.sol";
import {PostDeployM8Check} from "../../script/PostDeployM8Check.s.sol";
import {ScheduleM8Handover} from "../../script/ScheduleM8Handover.s.sol";
import {MockPermit2, MockPositionManager, MockVaultStateView} from "../mocks/VaultMocks.sol";
import {MintableToken} from "../mocks/TokenMocks.sol";

contract M8ScriptCodeMock {}

contract M8SafeMock {
    uint256 public getThreshold;
    address[] internal _owners;

    constructor(uint256 threshold, uint256 owners) {
        getThreshold = threshold;
        for (uint256 i; i < owners; ++i) {
            _owners.push(address(uint160(0x5afe + i)));
        }
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }
}

contract M8ScriptsTest is Test {
    DeployM8 private script;
    NetworkConfig.Configs private configs;

    function setUp() public {
        script = new DeployM8();
        MockVaultStateView stateView = new MockVaultStateView();
        MockPermit2 permit2 = new MockPermit2();
        MockPositionManager positionManager = new MockPositionManager(permit2, stateView);
        ShapeLibrary shapes = new ShapeLibrary();
        M8ScriptCodeMock router = new M8ScriptCodeMock();
        M8ScriptCodeMock poolManager = new M8ScriptCodeMock();
        MintableToken wrapper = new MintableToken();
        PriceGuard guard = new PriceGuard(stateView, address(0), address(wrapper), address(script));

        configs.chainId = 31_337;
        configs.stateView = stateView;
        configs.poolManager = address(poolManager);
        configs.positionManager = address(positionManager);
        configs.permit2 = address(permit2);
        configs.universalRouter = address(router);
        configs.nativeWrapper = address(wrapper);
        configs.deploymentOwner = address(script);
        configs.priceGuard = address(guard);
        configs.shapeLibrary = address(shapes);
        configs.governanceSafe = address(this);
        configs.authorizedExecutor = address(this);
        configs.guardianSafe = makeAddr("guardian");
        configs.treasury = makeAddr("treasury");
        configs.timelockDelay = 2 days;
        configs.initialProtocolFeeBps = 100;
        configs.initialMaxProtocolFeeBps = 3_000;
    }

    function test_deployResolvesImmutableCycleAndStartsRestrictedHandover() public {
        uint64 nonce = vm.getNonce(address(script));
        address predictedFactory = vm.computeCreateAddress(address(script), nonce + 7);
        DeployM8.Deployment memory deployed = script.deploy(configs, address(script), nonce);

        assertEq(address(deployed.vaultFactory), predictedFactory);
        assertEq(address(deployed.swapExecutor.factory()), predictedFactory);
        assertEq(deployed.vaultImplementation.factory(), predictedFactory);
        assertEq(address(deployed.vaultFactory.strategyOf(Strategy.NormalLP)), address(deployed.normalStrategy));
        assertEq(address(deployed.vaultFactory.strategyOf(Strategy.BuyTheDip)), address(deployed.dipStrategy));
        assertEq(address(deployed.vaultFactory.strategyOf(Strategy.SellThePump)), address(deployed.pumpStrategy));
        assertEq(deployed.vaultFactory.guardian(), configs.guardianSafe);
        assertEq(deployed.vaultFactory.pendingOwner(), address(deployed.timelock));
        assertEq(deployed.feeCollector.pendingOwner(), address(deployed.timelock));
        assertEq(PriceGuard(configs.priceGuard).pendingOwner(), address(deployed.timelock));
        assertTrue(deployed.timelock.hasRole(deployed.timelock.PROPOSER_ROLE(), configs.governanceSafe));
        assertTrue(deployed.timelock.hasRole(deployed.timelock.EXECUTOR_ROLE(), configs.authorizedExecutor));
        assertFalse(deployed.timelock.hasRole(deployed.timelock.EXECUTOR_ROLE(), address(0)));
        assertFalse(deployed.timelock.hasRole(deployed.timelock.DEFAULT_ADMIN_ROLE(), address(script)));
    }

    function test_handoverScheduleAndExecutionCompletesAllOwnershipTransfers() public {
        uint64 nonce = vm.getNonce(address(script));
        DeployM8.Deployment memory deployed = script.deploy(configs, address(script), nonce);
        configs.timelock = address(deployed.timelock);
        configs.vaultFactory = address(deployed.vaultFactory);
        configs.feeCollector = address(deployed.feeCollector);

        ScheduleM8Handover handover = new ScheduleM8Handover();
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = handover.actions(configs);
        deployed.timelock
            .scheduleBatch(targets, values, payloads, bytes32(0), handover.HANDOVER_SALT(), configs.timelockDelay);
        bytes32 operationId =
            deployed.timelock.hashOperationBatch(targets, values, payloads, bytes32(0), handover.HANDOVER_SALT());
        assertTrue(deployed.timelock.isOperationPending(operationId));

        vm.warp(block.timestamp + configs.timelockDelay);
        deployed.timelock.executeBatch(targets, values, payloads, bytes32(0), handover.HANDOVER_SALT());

        assertEq(deployed.vaultFactory.owner(), address(deployed.timelock));
        assertEq(deployed.feeCollector.owner(), address(deployed.timelock));
        assertEq(PriceGuard(configs.priceGuard).owner(), address(deployed.timelock));
    }

    /**
     * M8 audit: the post-deploy check fails before the timelock accepted ownership, passes after the handover, and
     * fails for every role the deployer could have kept or granted itself while it still owned the contracts. An
     * unset deployer address fails instead of skipping the check (the network config ships it as zero).
     */
    function test_postDeployCheckRequiresTheHandoverAndAnInertDeployer() public {
        uint64 nonce = vm.getNonce(address(script));
        DeployM8.Deployment memory d = script.deploy(configs, address(script), nonce);
        _recordDeployment(d);
        PostDeployM8Check post = new PostDeployM8Check();

        vm.expectRevert(abi.encodeWithSelector(PostDeployM8Check.CheckFailed.selector, bytes32("FACTORY_OWNER")));
        post.check(configs);

        _handover(d);
        assertTrue(post.check(configs));

        uint256 snap = vm.snapshotState();
        configs.deploymentOwner = address(0);
        _expectCheck(post, "DEPLOYER_UNSET");
        vm.revertToState(snap);

        vm.prank(address(d.timelock));
        d.vaultFactory.setKeeper(address(script), true);
        _expectCheck(post, "DEPLOYER_KEEPER");
        vm.revertToState(snap);

        vm.startPrank(address(d.timelock));
        d.timelock.grantRole(d.timelock.PROPOSER_ROLE(), address(script));
        vm.stopPrank();
        _expectCheck(post, "DEPLOYER_PROPOSER");
        vm.revertToState(snap);

        vm.startPrank(address(d.timelock));
        d.timelock.grantRole(d.timelock.CANCELLER_ROLE(), address(script));
        vm.stopPrank();
        _expectCheck(post, "DEPLOYER_CANCELLER");
        vm.revertToState(snap);

        vm.prank(address(d.timelock));
        d.vaultFactory.transferOwnership(makeAddr("successor"));
        _expectCheck(post, "FACTORY_PENDING_OWNER");
        vm.revertToState(snap);

        vm.startPrank(address(d.timelock));
        d.timelock.grantRole(d.timelock.DEFAULT_ADMIN_ROLE(), address(script));
        vm.stopPrank();
        _expectCheck(post, "DEPLOYER_ADMIN");
        vm.revertToState(snap);

        vm.startPrank(address(d.timelock));
        d.timelock.grantRole(d.timelock.EXECUTOR_ROLE(), address(0));
        vm.stopPrank();
        _expectCheck(post, "OPEN_EXECUTION");
        vm.revertToState(snap);

        address successor = makeAddr("guardSuccessor");
        vm.prank(address(d.timelock));
        PriceGuard(configs.priceGuard).transferOwnership(successor);
        vm.prank(successor);
        PriceGuard(configs.priceGuard).acceptOwnership();
        _expectCheck(post, "GUARD_OWNER");
        vm.revertToState(snap);

        // a configuration that names the deployer as guardian is itself refused
        vm.prank(address(d.timelock));
        d.vaultFactory.setGuardian(address(script));
        configs.guardianSafe = address(script);
        _expectCheck(post, "DEPLOYER_GUARDIAN");
        vm.revertToState(snap);
    }

    /**
     * M8 audit: a Safe cannot sign a forge broadcast, so the handover script now prints the exact timelock call for
     * the Safe owners. That call, sent from the proposer, schedules exactly the handover operation, which completes
     * after the delay.
     */
    function test_printedSafeTransactionSchedulesTheHandover() public {
        uint64 nonce = vm.getNonce(address(script));
        DeployM8.Deployment memory d = script.deploy(configs, address(script), nonce);
        _recordDeployment(d);
        ScheduleM8Handover handover = new ScheduleM8Handover();
        (address target, bytes memory data, bytes32 operationId) = handover.scheduleTransaction(configs);
        assertEq(target, address(d.timelock));

        vm.prank(configs.governanceSafe);
        (bool ok,) = target.call(data);
        assertTrue(ok, "the printed Safe transaction schedules the batch");
        assertTrue(d.timelock.isOperationPending(operationId));
        assertEq(d.timelock.getTimestamp(operationId), block.timestamp + configs.timelockDelay);

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = handover.actions(configs);
        vm.warp(block.timestamp + configs.timelockDelay);
        vm.prank(configs.authorizedExecutor);
        d.timelock.executeBatch(targets, values, payloads, bytes32(0), handover.HANDOVER_SALT());
        assertEq(d.vaultFactory.owner(), address(d.timelock));
    }

    /**
     * M8 audit: governance needs at least 3 of 5 and the guardian at least 2 of 3; a stronger Safe is accepted, a
     * weaker one is refused.
     */
    function test_mainnetAcceptsStrongerSafesAndRefusesWeakerOnes() public {
        vm.chainId(1);
        configs.chainId = 1;
        configs.zap = makeAddr("zap");
        configs.timelockDelay = 48 hours;
        configs.authorizedExecutor = makeAddr("executor");

        configs.governanceSafe = address(new M8SafeMock(2, 5));
        configs.guardianSafe = address(new M8SafeMock(2, 3));
        vm.expectRevert(abi.encodeWithSelector(DeployM8.InvalidSafeConfiguration.selector, configs.governanceSafe));
        script.deploy(configs, address(script), vm.getNonce(address(script)));

        configs.governanceSafe = address(new M8SafeMock(3, 4));
        vm.expectRevert(abi.encodeWithSelector(DeployM8.InvalidSafeConfiguration.selector, configs.governanceSafe));
        script.deploy(configs, address(script), vm.getNonce(address(script)));

        configs.governanceSafe = address(new M8SafeMock(4, 7));
        configs.guardianSafe = address(new M8SafeMock(1, 3));
        vm.expectRevert(abi.encodeWithSelector(DeployM8.InvalidSafeConfiguration.selector, configs.guardianSafe));
        script.deploy(configs, address(script), vm.getNonce(address(script)));

        configs.guardianSafe = address(new M8SafeMock(3, 4));
        DeployM8.Deployment memory d = script.deploy(configs, address(script), vm.getNonce(address(script)));
        assertEq(d.vaultFactory.guardian(), configs.guardianSafe, "4-of-7 governance and 3-of-4 guardian accepted");
    }

    function _recordDeployment(DeployM8.Deployment memory d) private {
        configs.timelock = address(d.timelock);
        configs.vaultFactory = address(d.vaultFactory);
        configs.feeCollector = address(d.feeCollector);
        configs.vaultLens = address(d.vaultLens);
        configs.vaultImplementation = address(d.vaultImplementation);
        configs.swapExecutor = address(d.swapExecutor);
        configs.normalStrategy = address(d.normalStrategy);
        configs.dipStrategy = address(d.dipStrategy);
        configs.pumpStrategy = address(d.pumpStrategy);
    }

    function _handover(DeployM8.Deployment memory d) private {
        ScheduleM8Handover handover = new ScheduleM8Handover();
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = handover.actions(configs);
        d.timelock.scheduleBatch(targets, values, payloads, bytes32(0), handover.HANDOVER_SALT(), configs.timelockDelay);
        vm.warp(block.timestamp + configs.timelockDelay);
        d.timelock.executeBatch(targets, values, payloads, bytes32(0), handover.HANDOVER_SALT());
    }

    function _expectCheck(PostDeployM8Check post, bytes32 name) private {
        vm.expectRevert(abi.encodeWithSelector(PostDeployM8Check.CheckFailed.selector, name));
        post.check(configs);
    }

    /**
     * M8 audit: the executor's Zap is immutable and the factory pins the executor, so a mainnet graph deployed
     * without the Zap could never add the M9 Zap. Mainnet deployment requires it.
     */
    function test_mainnetDeploymentRequiresTheZap() public {
        vm.chainId(1);
        configs.chainId = 1;
        configs.timelockDelay = 48 hours;
        vm.expectRevert(DeployM8.ZapRequiredOnMainnet.selector);
        script.deploy(configs, address(script), vm.getNonce(address(script)));
    }

    function test_deployRejectsMainnetDelayBelowFortyEightHours() public {
        vm.chainId(1);
        configs.chainId = 1;
        configs.zap = makeAddr("zap");
        configs.timelockDelay = 48 hours - 1;
        uint64 nonce = vm.getNonce(address(script));

        vm.expectRevert(DeployM8.InvalidMainnetDelay.selector);
        script.deploy(configs, address(script), nonce);
    }

    function test_mainnetRejectsAddressesThatAreNotConfiguredSafes() public {
        vm.chainId(1);
        configs.chainId = 1;
        configs.zap = makeAddr("zap");
        configs.timelockDelay = 48 hours;
        uint64 nonce = vm.getNonce(address(script));

        vm.expectRevert(abi.encodeWithSelector(DeployM8.InvalidSafeConfiguration.selector, configs.governanceSafe));
        script.deploy(configs, address(script), nonce);
    }
}
