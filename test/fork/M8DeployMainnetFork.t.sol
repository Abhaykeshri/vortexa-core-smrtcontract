// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {DeployM8} from "../../script/DeployM8.s.sol";
import {NetworkConfig} from "../../script/NetworkConfigs.s.sol";
import {PostDeployM8Check} from "../../script/PostDeployM8Check.s.sol";
import {ScheduleM8Handover} from "../../script/ScheduleM8Handover.s.sol";
import {PriceGuard} from "../../src/PriceGuard.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {Vault} from "../../src/Vault.sol";
import {VaultM5Module} from "../../src/VaultM5Module.sol";
import {IVaultLens} from "../../src/interfaces/IVaultLens.sol";
import {PoolKey, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {PoolIdLib} from "../../src/libraries/PoolIdLib.sol";

contract ForkSafe {
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

/**
 * @title M8 deployment rehearsal on an Ethereum mainnet fork
 * @notice Runs `DeployM8` with mainnet rules against the real PositionManager, Permit2, Universal Router v2.2,
 *         PoolManager, StateView and Chainlink feed. A factory-created Normal LP vault then takes a first deposit
 *         whose swap goes through the real router (the executor checks the real registry). The timelock handover
 *         follows, and `PostDeployM8Check` must pass on the result.
 */
contract M8DeployMainnetForkTest is Test {
    using PoolIdLib for PoolKey;

    address internal constant USER = address(0xA11CE);
    NetworkConfig.Configs internal configs;

    function setUp() public {
        if (block.chainid != 1) vm.skip(true);
        configs = new NetworkConfig().getConfigs();
        if (configs.universalRouter.code.length == 0 || configs.positionManager.code.length == 0) vm.skip(true);
    }

    DeployM8 internal script;
    NetworkConfig.Configs internal c;
    DeployM8.Deployment internal d;

    function test_deployM8OnMainnetRunAFactoryVaultAndHandOver() public {
        _deploy();
        _factoryVaultLifecycle();
        _handoverAndCheck();
    }

    function _deploy() internal {
        script = new DeployM8();
        PriceGuard guard =
            new PriceGuard(configs.stateView, configs.sequencerUptimeFeed, configs.nativeWrapper, address(script));
        vm.prank(address(script));
        try guard.setPairConfig(configs.ethUsdcPoolKey, configs.ethUsdcPriceConfig) {}
        catch {
            vm.skip(true); // live pool and Chainlink disagree beyond the tolerance at this block
        }
        c = configs;
        c.priceGuard = address(guard);
        c.shapeLibrary = address(new ShapeLibrary());
        c.deploymentOwner = address(script);
        c.governanceSafe = address(new ForkSafe(3, 5));
        c.guardianSafe = address(new ForkSafe(2, 3));
        c.authorizedExecutor = address(this);
        c.treasury = makeAddr("treasury");
        c.zap = makeAddr("zap");
        c.timelockDelay = 48 hours;
        c.initialProtocolFeeBps = 1_000;
        c.initialMaxProtocolFeeBps = 2_500;
        c.ethUsdcMaxDepositCap = 10_000_000e6;
        d = script.deploy(c, address(script), vm.getNonce(address(script)));
        // the deployer still owns the factory before the handover: register a keeper
        vm.prank(address(script));
        d.vaultFactory.setKeeper(address(this), true);
    }

    /**
     * A Normal LP vault on the real ETH/USDC pool. The first deposit is USDC only, so the plan swaps through the real
     * Universal Router; the lens then matches the real exit to the wei.
     */
    function _factoryVaultLifecycle() internal {
        (, int24 tick,,) = c.stateView.getSlot0(c.ethUsdcPoolKey.toId());
        VaultConfig memory cfg;
        cfg.poolKey = c.ethUsdcPoolKey;
        cfg.strategy = Strategy.NormalLP;
        cfg.shapeId = 4;
        cfg.centerTick = _floor(tick, c.ethUsdcPoolKey.tickSpacing);
        cfg.ticksLeft = 600;
        cfg.ticksRight = 600;
        cfg.autoRebalance = true;
        cfg.depositCap = 1_000_000e6;
        vm.prank(USER);
        Vault vault = Vault(payable(d.vaultFactory.createVault(cfg, "Vortex Fork", "vFORK")));
        deal(c.usdc, USER, 20_000e6);
        vm.startPrank(USER);
        IERC20(c.usdc).approve(address(vault), type(uint256).max);
        (uint256 shares, uint256 used0,) = vault.depositPair(0, 10_000e6, 1, USER);
        vm.stopPrank();
        assertGt(shares, 0);
        assertEq(used0, 0, "no ETH supplied");
        (uint256 p0, uint256 p1) = VaultM5Module(vault.m5Module()).previewWithdrawPair(vault, shares);
        assertGt(p0, 0, "the first-deposit swap bought ETH through the real router");
        IVaultLens.UserPosition memory pos = d.vaultLens.userPosition(address(vault), USER);
        assertEq(pos.amount0, p0);
        assertEq(pos.amount1, p1);
        vm.prank(USER);
        (uint256 o0, uint256 o1) = vault.withdrawPair(shares, 0, 0, USER);
        assertEq(o0, p0, "lens preview equals the real exit (ETH)");
        assertEq(o1, p1, "lens preview equals the real exit (USDC)");
    }

    /**
     * The handover through the printed Safe transaction, then `PostDeployM8Check` on the final state.
     */
    function _handoverAndCheck() internal {
        c.timelock = address(d.timelock);
        c.vaultFactory = address(d.vaultFactory);
        c.feeCollector = address(d.feeCollector);
        c.vaultLens = address(d.vaultLens);
        c.vaultImplementation = address(d.vaultImplementation);
        c.swapExecutor = address(d.swapExecutor);
        c.normalStrategy = address(d.normalStrategy);
        c.dipStrategy = address(d.dipStrategy);
        c.pumpStrategy = address(d.pumpStrategy);
        ScheduleM8Handover handover = new ScheduleM8Handover();
        (address target, bytes memory data,) = handover.scheduleTransaction(c);
        vm.prank(c.governanceSafe);
        (bool ok,) = target.call(data);
        assertTrue(ok);
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = handover.actions(c);
        vm.warp(block.timestamp + c.timelockDelay);
        d.timelock.executeBatch(targets, values, payloads, bytes32(0), handover.HANDOVER_SALT());
        assertTrue(new PostDeployM8Check().check(c));
    }

    function _floor(int24 tick, int24 spacing) internal pure returns (int24 c) {
        c = (tick / spacing) * spacing;
        if (tick < 0 && c != tick) c -= spacing;
    }
}
