// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployM9} from "../../script/DeployM9.s.sol";
import {NetworkConfig} from "../../script/NetworkConfigs.s.sol";
import {PostDeployM8Check} from "../../script/PostDeployM8Check.s.sol";
import {PostDeployM9Check} from "../../script/PostDeployM9Check.s.sol";
import {ScheduleM8Handover} from "../../script/ScheduleM8Handover.s.sol";
import {PriceGuard} from "../../src/PriceGuard.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {Zap} from "../../src/Zap.sol";
import {IZapFactory, IZapSwapExecutor} from "../../src/interfaces/IZapDependencies.sol";
import {Strategy} from "../../src/libraries/Types.sol";
import {MockPermit2, MockPositionManager, MockVaultStateView} from "../mocks/VaultMocks.sol";
import {MintableToken} from "../mocks/TokenMocks.sol";

contract M9ScriptCodeMock {}

contract M9ScriptsTest is Test {
    DeployM9 private script;
    NetworkConfig.Configs private configs;

    function setUp() public {
        script = new DeployM9();
        MockVaultStateView stateView = new MockVaultStateView();
        MockPermit2 permit2 = new MockPermit2();
        MockPositionManager positionManager = new MockPositionManager(permit2, stateView);
        ShapeLibrary shapes = new ShapeLibrary();
        MintableToken wrapper = new MintableToken();
        PriceGuard guard = new PriceGuard(stateView, address(0), address(wrapper), address(script));

        configs.chainId = block.chainid;
        configs.stateView = stateView;
        configs.poolManager = address(new M9ScriptCodeMock());
        configs.positionManager = address(positionManager);
        configs.permit2 = address(permit2);
        configs.universalRouter = address(new M9ScriptCodeMock());
        configs.nativeWrapper = address(wrapper);
        configs.deploymentOwner = address(script);
        configs.priceGuard = address(guard);
        configs.shapeLibrary = address(shapes);
        configs.governanceSafe = address(this);
        configs.authorizedExecutor = address(this);
        configs.guardianSafe = makeAddr("guardian");
        configs.treasury = makeAddr("treasury");
        configs.timelockDelay = 2 days;
        configs.initialMaxProtocolFeeBps = 3_000;
    }

    function test_deployM9ResolvesAndVerifiesCompleteImmutableGraph() public {
        uint64 nonce = vm.getNonce(address(script));
        address predictedZap = vm.computeCreateAddress(address(script), nonce + 5);
        address predictedExecutor = vm.computeCreateAddress(address(script), nonce + 6);
        address predictedFactory = vm.computeCreateAddress(address(script), nonce + 8);
        DeployM9.Deployment memory d = script.deploy(configs, address(script), nonce);

        assertEq(address(d.zap), predictedZap);
        assertEq(address(d.swapExecutor), predictedExecutor);
        assertEq(address(d.vaultFactory), predictedFactory);
        assertEq(d.swapExecutor.zap(), address(d.zap));
        assertEq(address(d.zap.factory()), address(d.vaultFactory));
        assertEq(address(d.zap.executor()), address(d.swapExecutor));
        assertEq(address(d.vaultFactory.strategyOf(Strategy.NormalLP)), address(d.normalStrategy));
        assertGt(address(d.zap).code.length, 0);
        assertGt(address(d.swapExecutor).code.length, 0);
        assertGt(address(d.vaultFactory).code.length, 0);
    }

    function test_postDeployM9RejectsWrongZapAndPassesFinalizedGraph() public {
        DeployM9.Deployment memory d = script.deploy(configs, address(script), vm.getNonce(address(script)));
        _record(d);
        _handover(d);
        PostDeployM9Check post = new PostDeployM9Check();
        assertTrue(post.check(configs));

        Zap rogue = new Zap(
            IZapFactory(address(d.vaultFactory)),
            IZapSwapExecutor(address(d.swapExecutor)),
            address(d.normalStrategy),
            address(d.dipStrategy),
            address(d.pumpStrategy)
        );
        configs.zap = address(rogue);
        vm.expectRevert(abi.encodeWithSelector(PostDeployM8Check.CheckFailed.selector, bytes32("EXECUTOR_ZAP")));
        post.check(configs);
    }

    /**
     * Every M9 wiring check fires under its own name. Checks that `PostDeployM8Check` already performs first
     * (executor factory and guard, factory executor and strategies, executor and implementation code) are not repeated.
     */
    function test_postDeployM9NamesEveryMiswiredLink() public {
        DeployM9.Deployment memory d = script.deploy(configs, address(script), vm.getNonce(address(script)));
        _record(d);
        _handover(d);
        PostDeployM9Check post = new PostDeployM9Check();
        address wrong = makeAddr("wrong");
        address impl = address(d.vaultImplementation);
        address zapAddr = address(d.zap);

        _expectCheck(post, address(d.swapExecutor), abi.encodeWithSignature("zap()"), wrong, "EXECUTOR_ZAP");
        _expectCheck(post, zapAddr, abi.encodeWithSignature("factory()"), wrong, "ZAP_FACTORY");
        _expectCheck(post, zapAddr, abi.encodeWithSignature("executor()"), wrong, "ZAP_EXECUTOR");
        _expectCheck(post, impl, abi.encodeWithSignature("factory()"), wrong, "VAULT_FACTORY");
        _expectCheck(post, impl, abi.encodeWithSignature("swapExecutor()"), wrong, "VAULT_EXECUTOR");
        _expectCheck(post, impl, abi.encodeWithSignature("priceGuard()"), wrong, "VAULT_GUARD");
        _expectCheck(post, zapAddr, abi.encodeWithSignature("normalStrategy()"), wrong, "ZAP_NORMAL");
        _expectCheck(post, zapAddr, abi.encodeWithSignature("buyTheDipStrategy()"), wrong, "ZAP_DIP");
        _expectCheck(post, zapAddr, abi.encodeWithSignature("sellThePumpStrategy()"), wrong, "ZAP_PUMP");

        NetworkConfig.Configs memory bad = configs;
        bad.chainId = block.chainid + 1;
        vm.expectRevert(abi.encodeWithSelector(PostDeployM8Check.CheckFailed.selector, bytes32("CHAIN_ID")));
        post.check(bad);

        bad = configs;
        bad.zap = wrong;
        vm.expectRevert(abi.encodeWithSelector(PostDeployM8Check.CheckFailed.selector, bytes32("ZAP_CODE")));
        post.check(bad);

        assertTrue(post.check(configs), "graph still verifies after the negative cases");
    }

    function _expectCheck(PostDeployM9Check post, address target, bytes memory getter, address value, bytes32 name)
        private
    {
        vm.mockCall(target, getter, abi.encode(value));
        vm.expectRevert(abi.encodeWithSelector(PostDeployM8Check.CheckFailed.selector, name));
        post.check(configs);
        vm.clearMockedCalls();
    }

    function _record(DeployM9.Deployment memory d) private {
        configs.timelock = address(d.timelock);
        configs.feeCollector = address(d.feeCollector);
        configs.normalStrategy = address(d.normalStrategy);
        configs.dipStrategy = address(d.dipStrategy);
        configs.pumpStrategy = address(d.pumpStrategy);
        configs.zap = address(d.zap);
        configs.swapExecutor = address(d.swapExecutor);
        configs.vaultImplementation = address(d.vaultImplementation);
        configs.vaultFactory = address(d.vaultFactory);
        configs.vaultLens = address(d.vaultLens);
    }

    function _handover(DeployM9.Deployment memory d) private {
        ScheduleM8Handover handover = new ScheduleM8Handover();
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = handover.actions(configs);
        d.timelock.scheduleBatch(targets, values, payloads, bytes32(0), handover.HANDOVER_SALT(), configs.timelockDelay);
        vm.warp(block.timestamp + configs.timelockDelay);
        d.timelock.executeBatch(targets, values, payloads, bytes32(0), handover.HANDOVER_SALT());
    }
}
