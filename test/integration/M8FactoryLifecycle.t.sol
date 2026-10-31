// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {SwapExecutor} from "../../src/SwapExecutor.sol";
import {Vault} from "../../src/Vault.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {VaultLens} from "../../src/VaultLens.sol";
import {NormalLPStrategy} from "../../src/strategies/NormalLPStrategy.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {IVaultFactory} from "../../src/interfaces/IVaultFactory.sol";
import {IVaultLens} from "../../src/interfaces/IVaultLens.sol";
import {IPermit2Like} from "../../src/interfaces/external/IPermit2Like.sol";
import {IPositionManagerLike} from "../../src/interfaces/external/IPositionManagerLike.sol";
import {IUniversalRouterLike} from "../../src/interfaces/external/IUniversalRouterLike.sol";
import {Currency, PoolKey, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {MockPermit2, MockPositionManager, MockVaultPriceGuard, MockVaultStateView} from "../mocks/VaultMocks.sol";
import {MintableToken} from "../mocks/TokenMocks.sol";

contract M8FactoryLifecycleTest is Test {
    address private user = makeAddr("user");
    address private treasury = makeAddr("treasury");
    MockVaultStateView private stateView;
    MockVaultPriceGuard private guard;
    MockPermit2 private permit2;
    MockPositionManager private positionManager;
    ShapeLibrary private shapes;
    MintableToken private token1;
    FeeCollector private collector;
    VaultFactory private factory;
    PoolKey private key;

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
        SwapExecutor executor = new SwapExecutor(
            IUniversalRouterLike(address(0x1111)),
            IPermit2Like(address(permit2)),
            IVaultFactory(predictedFactory),
            IPriceGuard(address(guard)),
            address(0)
        );
        Vault implementation = new Vault(
            IPositionManagerLike(address(positionManager)),
            stateView,
            IPermit2Like(address(permit2)),
            IPriceGuard(address(guard)),
            shapes,
            address(executor),
            predictedFactory,
            address(0x4444)
        );
        factory = new VaultFactory(
            address(this),
            address(implementation),
            stateView,
            IPriceGuard(address(guard)),
            shapes,
            address(collector),
            100,
            2_500
        );
        factory.setStrategy(Strategy.NormalLP, new NormalLPStrategy(shapes));

        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token1)), 500, 60, address(0));
        IPriceGuard.PairConfig memory oracle;
        oracle.maxDeviationBps = 100;
        guard.setPairConfig(key, oracle);
        factory.setPoolAllowed(key, true, true, 1_000_000 ether);
    }

    function test_factoryCloneDepositLensAndCollectorLifecycle() public {
        VaultConfig memory config;
        config.poolKey = key;
        config.strategy = Strategy.NormalLP;
        config.shapeId = 1;
        config.centerTick = 0;
        config.ticksLeft = 600;
        config.ticksRight = 600;
        config.autoRebalance = true;
        config.depositCap = 100_000 ether;
        Vault vault = Vault(payable(factory.createVault(config, "Vortex Integration", "vINT")));
        VaultLens lens = new VaultLens(factory, stateView);

        token1.mint(user, 20 ether);
        vm.deal(user, 20 ether);
        vm.startPrank(user);
        token1.approve(address(vault), type(uint256).max);
        vault.depositPair{value: 10 ether}(10 ether, 10 ether, 1, user);
        vm.stopPrank();

        IVaultLens.VaultInfo memory info = lens.vaultInfo(address(vault));
        IVaultLens.UserPosition memory position = lens.userPosition(address(vault), user);
        assertTrue(factory.isVault(address(vault)));
        assertGt(info.totalShares, 0);
        assertTrue(info.accountingAvailable);
        assertEq(position.shares, vault.balanceOf(user));
        assertGt(position.amount0 + position.amount1, 0);

        token1.mint(address(collector), 1 ether);
        collector.collect(Currency.wrap(address(token1)));
        assertEq(token1.balanceOf(treasury), 1 ether);
    }
}
