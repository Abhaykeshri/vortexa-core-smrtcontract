// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "uni-test/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "uni-test/v4-core/src/interfaces/IHooks.sol";
import {Currency as V4Currency} from "uni-test/v4-core/src/types/Currency.sol";
import {PoolKey as V4PoolKey} from "uni-test/v4-core/src/types/PoolKey.sol";
import {TickMath as V4TickMath} from "uni-test/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "uni-test/v4-core/src/test/PoolSwapTest.sol";
import {DeployM9} from "../../script/DeployM9.s.sol";
import {NetworkConfig} from "../../script/NetworkConfigs.s.sol";
import {PostDeployM9Check} from "../../script/PostDeployM9Check.s.sol";
import {ScheduleM8Handover} from "../../script/ScheduleM8Handover.s.sol";
import {PriceGuard} from "../../src/PriceGuard.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {ISwapExecutor} from "../../src/interfaces/ISwapExecutor.sol";
import {Vault} from "../../src/Vault.sol";
import {Currency, PoolKey, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {PoolIdLib} from "../../src/libraries/PoolIdLib.sol";

contract M9ForkSafe {
    uint256 public getThreshold;
    address[] internal _owners;

    constructor(uint256 threshold, uint256 ownerCount) {
        getThreshold = threshold;
        for (uint256 i; i < ownerCount; ++i) {
            _owners.push(address(uint160(0x9000 + i)));
        }
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }
}

contract M9ZapMainnetForkTest is Test {
    using PoolIdLib for PoolKey;

    address internal constant USER = address(0xA11CE);
    address internal constant HOLDER = address(0xB0B);
    address internal constant ATTACKER = address(0xBAD);
    NetworkConfig.Configs internal base;
    NetworkConfig.Configs internal configs;
    DeployM9 internal script;
    DeployM9.Deployment internal deployment;
    Vault internal vault;

    function setUp() public {
        if (block.chainid != 1) vm.skip(true);
        base = new NetworkConfig().getConfigs();
        if (base.universalRouter.code.length == 0 || base.positionManager.code.length == 0) vm.skip(true);
        _deploy();
        _createVault();
    }

    function test_realMainnetUsdcAndNativeZapThenHandover() public {
        deal(configs.usdc, USER, 30_000e6);
        vm.deal(USER, 20 ether);
        vm.startPrank(USER);
        IERC20(configs.usdc).approve(address(deployment.zap), type(uint256).max);
        uint256 usdcShares = deployment.zap.zapDeposit(address(vault), configs.usdc, 10_000e6, 0, 100, USER);
        uint256 ethShares = deployment.zap.zapDeposit{value: 2 ether}(address(vault), address(0), 2 ether, 0, 100, USER);
        vm.stopPrank();

        assertGt(usdcShares, 0);
        assertGt(ethShares, 0);
        assertEq(address(deployment.zap).balance, 0);
        assertEq(IERC20(configs.usdc).balanceOf(address(deployment.zap)), 0);
        assertEq(IERC20(configs.usdc).allowance(address(deployment.zap), address(vault)), 0);
        assertEq(IERC20(configs.usdc).allowance(address(deployment.zap), address(deployment.swapExecutor)), 0);

        _handover();
        assertTrue(new PostDeployM9Check().check(configs));
    }

    function test_realPoolRejectsDivergentOracleReference() public {
        deal(configs.usdc, USER, 10_000e6);
        vm.prank(USER);
        IERC20(configs.usdc).approve(address(deployment.zap), type(uint256).max);
        address feed = configs.ethUsdcPriceConfig.chainlinkFeed;
        vm.mockCall(
            feed,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(100e8), block.timestamp, block.timestamp, uint80(1))
        );
        vm.prank(USER);
        vm.expectRevert(ISwapExecutor.UntrustedPrice.selector);
        deployment.zap.zapDeposit(address(vault), configs.usdc, 5_000e6, 0, 100, USER);
    }

    /**
     * Guide 11 sandwich simulation on the real pool. An attacker pushes the price as far as the configured oracle
     * tolerance allows (in either direction), a 50,000 USDC zap runs, and the attacker unwinds. The zap either reverts
     * without moving funds, or the zapper's exit (shares withdrawn at once, plus refunds), valued at the oracle
     * reference, stays inside `maxDeviationBps + MAX_SLIPPAGE_BPS + pool fee`.
     */
    function test_realPoolSandwichedZapStaysInsideTheConfiguredBound() public {
        PoolSwapTest router = new PoolSwapTest(IPoolManager(configs.poolManager));
        (bool trusted,) = PriceGuard(configs.priceGuard).isPriceTrusted(configs.ethUsdcPoolKey);
        if (!trusted) vm.skip(true);
        deal(configs.usdc, HOLDER, 100_000e6);
        vm.startPrank(HOLDER);
        IERC20(configs.usdc).approve(address(deployment.zap), type(uint256).max);
        deployment.zap.zapDeposit(address(vault), configs.usdc, 100_000e6, 1, 100, HOLDER);
        vm.stopPrank();
        deal(configs.usdc, ATTACKER, 2_000_000_000e6);
        vm.deal(ATTACKER, 1_000_000 ether);
        vm.prank(ATTACKER);
        IERC20(configs.usdc).approve(address(router), type(uint256).max);
        deal(configs.usdc, USER, 50_000e6);
        vm.prank(USER);
        IERC20(configs.usdc).approve(address(deployment.zap), type(uint256).max);

        uint256 bound = configs.ethUsdcPriceConfig.maxDeviationBps + 100 + configs.ethUsdcPoolKey.fee / 100 + 1;
        uint256 snap = vm.snapshotState();
        for (uint256 d; d < 2; ++d) {
            vm.revertToState(snap);
            (bool reverted, uint256 pushBps, uint256 lossBps) = _sandwich(router, d == 0);
            emit log_named_uint(d == 0 ? "push down (bps)" : "push up (bps)", pushBps);
            emit log_named_uint(reverted ? "zap reverted, loss (bps)" : "zapper loss (bps)", lossBps);
            assertLe(lossBps, bound, "zapper lost more than the configured bound");
        }
    }

    function _sandwich(PoolSwapTest router, bool sellEth)
        private
        returns (bool reverted, uint256 pushBps, uint256 lossBps)
    {
        uint160 ref = PriceGuard(configs.priceGuard).referenceSqrtPriceX96(configs.ethUsdcPoolKey);
        uint256 refPrice = Math.mulDiv(ref, ref, 1 << 96);
        uint256 eth0 = ATTACKER.balance;
        uint256 usdc0 = IERC20(configs.usdc).balanceOf(ATTACKER);
        pushBps = _push(router, sellEth, refPrice);

        uint256 amount = 50_000e6;
        uint256 userEth = USER.balance;
        uint256 userUsdc = IERC20(configs.usdc).balanceOf(USER);
        vm.prank(USER);
        (bool success, bytes memory ret) = address(deployment.zap)
            .call(
                abi.encodeCall(deployment.zap.zapDeposit, (address(vault), configs.usdc, amount, 1, uint16(100), USER))
            );
        // back-run: return what the push took out
        uint256 back = sellEth ? IERC20(configs.usdc).balanceOf(ATTACKER) - usdc0 : ATTACKER.balance - eth0;
        if (back != 0) _attackerSwap(router, !sellEth, back);

        if (!success) {
            assertEq(IERC20(configs.usdc).balanceOf(USER), userUsdc, "a refused zap moved USDC");
            assertEq(USER.balance, userEth, "a refused zap moved ETH");
            return (true, pushBps, 0);
        }
        vm.prank(USER);
        vault.withdrawPair(abi.decode(ret, (uint256)), 0, 0, USER);
        uint256 value = Math.mulDiv(USER.balance - userEth, refPrice, 1 << 96) + IERC20(configs.usdc).balanceOf(USER)
            + amount - userUsdc;
        lossBps = value >= amount ? 0 : Math.mulDiv(amount - value, 10_000, amount);
    }

    /**
     * Pushes the pool in chunks while PriceGuard still trusts it; returns the push in bps of the reference price.
     */
    function _push(PoolSwapTest router, bool sellEth, uint256 refPrice) private returns (uint256 pushBps) {
        // grow the chunk while the guard trusts the pool, halve it after a step that breaks trust
        uint256 chunk = sellEth ? 20 ether : 60_000e6;
        uint256 minChunk = sellEth ? 0.5 ether : 1_500e6;
        for (uint256 i; i < 80 && chunk >= minChunk; ++i) {
            uint256 s = vm.snapshotState();
            _attackerSwap(router, sellEth, chunk);
            (bool ok,) = PriceGuard(configs.priceGuard).isPriceTrusted(configs.ethUsdcPoolKey);
            if (ok) {
                vm.deleteStateSnapshot(s);
                chunk *= 2;
            } else {
                vm.revertToStateAndDelete(s);
                chunk /= 2;
            }
        }
        (uint160 pushed,,,) = configs.stateView.getSlot0(configs.ethUsdcPoolKey.toId());
        uint256 nowPrice = Math.mulDiv(pushed, pushed, 1 << 96);
        pushBps = Math.mulDiv(refPrice > nowPrice ? refPrice - nowPrice : nowPrice - refPrice, 10_000, refPrice);
    }

    function _attackerSwap(PoolSwapTest router, bool zeroForOne, uint256 amountIn) private {
        PoolKey memory key = configs.ethUsdcPoolKey;
        vm.prank(ATTACKER);
        router.swap{value: zeroForOne ? amountIn : 0}(
            V4PoolKey({
                currency0: V4Currency.wrap(Currency.unwrap(key.currency0)),
                currency1: V4Currency.wrap(Currency.unwrap(key.currency1)),
                fee: key.fee,
                tickSpacing: key.tickSpacing,
                hooks: IHooks(key.hooks)
            }),
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? V4TickMath.MIN_SQRT_PRICE + 1 : V4TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _deploy() private {
        script = new DeployM9();
        PriceGuard guard = new PriceGuard(base.stateView, base.sequencerUptimeFeed, base.nativeWrapper, address(script));
        vm.prank(address(script));
        try guard.setPairConfig(base.ethUsdcPoolKey, base.ethUsdcPriceConfig) {}
        catch {
            vm.skip(true);
        }
        configs = base;
        configs.priceGuard = address(guard);
        configs.shapeLibrary = address(new ShapeLibrary());
        configs.deploymentOwner = address(script);
        configs.governanceSafe = address(new M9ForkSafe(3, 5));
        configs.guardianSafe = address(new M9ForkSafe(2, 3));
        configs.authorizedExecutor = address(this);
        configs.treasury = makeAddr("m9-treasury");
        configs.timelockDelay = 48 hours;
        configs.initialProtocolFeeBps = 1_000;
        configs.initialMaxProtocolFeeBps = 2_500;
        configs.ethUsdcMaxDepositCap = 10_000_000e6;
        deployment = script.deploy(configs, address(script), vm.getNonce(address(script)));
        _record();
    }

    function _createVault() private {
        (, int24 tick,,) = configs.stateView.getSlot0(configs.ethUsdcPoolKey.toId());
        VaultConfig memory cfg;
        cfg.poolKey = configs.ethUsdcPoolKey;
        cfg.strategy = Strategy.NormalLP;
        cfg.shapeId = 4;
        cfg.centerTick = _floor(tick, configs.ethUsdcPoolKey.tickSpacing);
        cfg.ticksLeft = 600;
        cfg.ticksRight = 600;
        cfg.autoRebalance = true;
        cfg.depositCap = 1_000_000e6;
        vm.prank(USER);
        vault = Vault(payable(deployment.vaultFactory.createVault(cfg, "Vortex M9 Fork", "vM9")));
    }

    function _record() private {
        configs.timelock = address(deployment.timelock);
        configs.feeCollector = address(deployment.feeCollector);
        configs.normalStrategy = address(deployment.normalStrategy);
        configs.dipStrategy = address(deployment.dipStrategy);
        configs.pumpStrategy = address(deployment.pumpStrategy);
        configs.zap = address(deployment.zap);
        configs.swapExecutor = address(deployment.swapExecutor);
        configs.vaultImplementation = address(deployment.vaultImplementation);
        configs.vaultFactory = address(deployment.vaultFactory);
        configs.vaultLens = address(deployment.vaultLens);
    }

    function _handover() private {
        ScheduleM8Handover handover = new ScheduleM8Handover();
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = handover.actions(configs);
        bytes32 salt = handover.HANDOVER_SALT();
        vm.prank(configs.governanceSafe);
        deployment.timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, configs.timelockDelay);
        vm.warp(block.timestamp + configs.timelockDelay);
        deployment.timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
    }

    function _floor(int24 tick, int24 spacing) private pure returns (int24 aligned) {
        aligned = (tick / spacing) * spacing;
        if (tick < 0 && aligned != tick) aligned -= spacing;
    }
}
