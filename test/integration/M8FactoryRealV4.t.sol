// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {SwapExecutor} from "../../src/SwapExecutor.sol";
import {Vault} from "../../src/Vault.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {VaultLens} from "../../src/VaultLens.sol";
import {VaultM5Module} from "../../src/VaultM5Module.sol";
import {BuyTheDipStrategy} from "../../src/strategies/BuyTheDipStrategy.sol";
import {NormalLPStrategy} from "../../src/strategies/NormalLPStrategy.sol";
import {SellThePumpStrategy} from "../../src/strategies/SellThePumpStrategy.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {IVaultFactory} from "../../src/interfaces/IVaultFactory.sol";
import {IVaultLens} from "../../src/interfaces/IVaultLens.sol";
import {IPermit2Like} from "../../src/interfaces/external/IPermit2Like.sol";
import {IStateViewLike} from "../../src/interfaces/external/IStateViewLike.sol";
import {IPositionManagerLike} from "../../src/interfaces/external/IPositionManagerLike.sol";
import {IUniversalRouterLike} from "../../src/interfaces/external/IUniversalRouterLike.sol";
import {Band, Currency, PoolKey, RebalanceParams, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {VaultRealV4Base} from "./utils/VaultRealV4Base.sol";

interface BalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title M8 end to end on real Uniswap v4
 * @notice The production VaultFactory, FeeCollector, VaultLens, SwapExecutor and strategies, wired exactly as
 *         `DeployM8` wires them (nonce-predicted factory), driving vaults on the real PoolManager, PositionManager,
 *         StateView, PriceGuard and V4Router pipeline. No fixture plays the factory here.
 */
contract M8FactoryRealV4Test is VaultRealV4Base {
    uint128 internal constant DEEP = 2e17;

    VaultFactory internal factory;
    FeeCollector internal collector;
    VaultLens internal lens;
    SwapExecutor internal realExecutor;
    Vault internal realImplementation;
    NormalLPStrategy internal normal;
    BuyTheDipStrategy internal dip;
    SellThePumpStrategy internal pump;

    address internal keeper = makeAddr("keeper");
    address internal guardianSafe = makeAddr("guardianSafe");
    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator");

    PoolKey internal key;
    Vault internal vault;

    function setUp() public override {
        super.setUp();
        normal = new NormalLPStrategy(shapes);
        dip = new BuyTheDipStrategy(shapes);
        pump = new SellThePumpStrategy(shapes);
        collector = new FeeCollector(address(this), treasury);

        uint64 nonce = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), nonce + 2);
        realExecutor = new SwapExecutor(
            IUniversalRouterLike(address(router)),
            IPermit2Like(address(permit2)),
            IVaultFactory(predicted),
            guard,
            address(0)
        );
        realImplementation = new Vault(
            IPositionManagerLike(address(posm)),
            IStateViewLike(address(stateView)),
            IPermit2Like(address(permit2)),
            guard,
            shapes,
            address(realExecutor),
            predicted,
            address(manager)
        );
        factory = new VaultFactory(
            address(this),
            address(realImplementation),
            IStateViewLike(address(stateView)),
            guard,
            shapes,
            address(collector),
            1_000,
            2_500
        );
        assertEq(address(factory), predicted, "nonce prediction");
        lens = new VaultLens(factory, IStateViewLike(address(stateView)));

        factory.setStrategy(Strategy.NormalLP, normal);
        factory.setStrategy(Strategy.BuyTheDip, dip);
        factory.setStrategy(Strategy.SellThePump, pump);
        factory.setKeeper(keeper, true);
        factory.setGuardian(guardianSafe);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Lifecycles
    // ------------------------------------------------------------------------------------------------------------

    /**
     * Native ETH/USDC Normal LP: the first deposit swaps through the executor (which checks the real registry),
     * fees accrue, the protocol fee reaches the real FeeCollector in both currencies (native through the withdraw
     * stipend), the collector flushes to the treasury, and a keeper registered in the factory re-centres with a swap.
     */
    function test_native_normal_lp_lifecycle_through_the_real_factory() public {
        _createNormal(_nativeUsdcKey(), true);
        (uint256 shares,,) = _deposit(vault, alice, 0, 40_000e6); // USDC only: the plan swaps about half
        assertGt(vault.bands().length, 0);
        _deposit(vault, bob, 10 ether, 20_000e6);

        _trade(6);
        vm.prank(alice);
        vault.withdrawPair(shares / 2, 0, 0, alice);
        assertGt(address(collector).balance, 0, "native protocol fee reached the collector");
        assertGt(usdc.balanceOf(address(collector)), 0, "USDC protocol fee reached the collector");

        uint256 eth = address(collector).balance;
        collector.collect(Currency.wrap(address(0)));
        collector.collect(Currency.wrap(USDC_ADDR));
        assertEq(treasury.balance, eth, "collector forwards native fees");
        assertEq(address(collector).balance, 0);
        assertEq(usdc.balanceOf(address(collector)), 0);

        Band[] memory b = vault.bands();
        _moveTickTo(b[0].tickLower - 50, true);
        _rebalance(100);
        b = vault.bands();
        (, int24 tick,,) = stateView.getSlot0(_poolId(key));
        assertTrue(tick >= b[0].tickLower && tick < b[b.length - 1].tickUpper, "keeper re-centred");
    }

    /**
     * ERC-20/ERC-20 USDC/WETH Normal LP through the factory: first-deposit swap, fees and a re-centring swap.
     */
    function test_erc20_normal_lp_lifecycle_through_the_real_factory() public {
        _createNormal(_usdcWethKey(), false);
        _deposit(vault, alice, 0, 10 ether); // WETH only: the plan swaps about half to USDC
        _deposit(vault, bob, 20_000e6, 10 ether);
        _trade(6);
        vm.prank(keeper);
        vault.collectFees();
        assertGt(weth.balanceOf(address(collector)) + usdc.balanceOf(address(collector)), 0, "fees collected");
        Band[] memory b = vault.bands();
        _moveTickTo(b[b.length - 1].tickUpper + 50, false);
        _rebalance(100);
        b = vault.bands();
        (, int24 tick,,) = stateView.getSlot0(_poolId(key));
        assertTrue(tick >= b[0].tickLower && tick < b[b.length - 1].tickUpper, "keeper re-centred");
    }

    /**
     * The pool rule fixes the base orientation: a creator who asks for the opposite gets the rule's value, so a
     * Buy the Dip vault on ETH/USDC always sits below the price and takes USDC.
     */
    function test_pool_rule_fixes_the_one_sided_orientation() public {
        key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, DEEP);
        factory.setPoolAllowed(key, true, true, 10_000_000e6);
        VaultConfig memory cfg = _oneSidedConfig(Strategy.BuyTheDip, tick, true);
        cfg.baseIsCurrency0 = false; // the creator asks for the other orientation
        cfg.ticksLeft = 0;
        cfg.ticksRight = 1_000; // and the geometry that would match it
        vm.prank(creator);
        vm.expectRevert(); // the strategy rejects the flipped geometry under the rule's orientation
        factory.createVault(cfg, "Dip", "DIP");

        cfg = _oneSidedConfig(Strategy.BuyTheDip, tick, true);
        cfg.baseIsCurrency0 = false; // flag alone flipped: normalized back
        vm.prank(creator);
        vault = Vault(payable(factory.createVault(cfg, "Dip", "DIP")));
        assertTrue(vault.config().baseIsCurrency0, "orientation comes from the pool rule");
        _approveVault();
        _deposit(vault, alice, 0, 40_000e6);
        Band[] memory b = vault.bands();
        assertLe(int256(b[b.length - 1].tickUpper), int256(tick), "ladder below the price");
    }

    /**
     * Governance changes reach existing vaults exactly where the design says: the live fee and collector, keeper
     * revocation and guardian pause. The vault's config, strategy and implementation stay fixed.
     */
    function test_governance_reaches_existing_vaults_only_through_the_live_getters() public {
        _createNormal(_nativeUsdcKey(), true);
        _deposit(vault, alice, 10 ether, 20_000e6);
        bytes32 configHash = keccak256(abi.encode(vault.config()));

        // a new collector and a new fee apply to the next collection
        FeeCollector newCollector = new FeeCollector(address(this), treasury);
        factory.setFeeCollector(address(newCollector));
        factory.setProtocolFeeBps(2_500);
        _trade(4);
        (uint256 pending0, uint256 pending1) = _pending();
        vm.prank(keeper);
        vault.collectFees();
        assertEq(address(newCollector).balance, Math.mulDiv(pending0, 2_500, 10_000), "new fee, new collector (ETH)");
        assertEq(usdc.balanceOf(address(newCollector)), Math.mulDiv(pending1, 2_500, 10_000), "(USDC)");
        assertEq(address(collector).balance, 0, "the old collector receives nothing");

        // a registry change never rewrites the vault
        factory.setStrategy(Strategy.NormalLP, new NormalLPStrategy(shapes));
        assertEq(keccak256(abi.encode(vault.config())), configHash);

        // keeper revocation
        factory.setKeeper(keeper, false);
        vm.prank(keeper);
        vm.expectRevert();
        vault.compound();

        // guardian pauses, cannot unpause; the factory owner unpauses; exits never pause
        vm.prank(guardianSafe);
        vault.pause();
        vm.prank(alice);
        vm.expectRevert();
        vault.depositPair{value: 1 ether}(1 ether, 2_000e6, 0, alice);
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.withdrawPair(aliceShares / 4, 0, 0, alice);
        vm.prank(guardianSafe);
        vm.expectRevert();
        vault.unpause();
        vault.unpause(); // this test contract owns the factory (stands in for the timelock)
        _deposit(vault, alice, 1 ether, 2_000e6);
    }

    /**
     * The lens over real vaults reports exactly what the vault and its in-kind preview report.
     */
    function test_lens_matches_the_vault_on_real_pools() public {
        _createNormal(_nativeUsdcKey(), true);
        (uint256 shares,,) = _deposit(vault, alice, 10 ether, 20_000e6);
        _trade(3);
        IVaultLens.VaultInfo memory info = lens.vaultInfo(address(vault));
        assertTrue(info.accountingAvailable && info.poolStateAvailable);
        assertEq(info.totalAssets, vault.totalAssets());
        assertEq(info.totalShares, vault.totalSupply());
        assertEq(info.protocolFeeBps, factory.protocolFeeBps());
        (uint256 p0, uint256 p1) = VaultM5Module(vault.m5Module()).previewWithdrawPair(vault, shares);
        IVaultLens.UserPosition memory pos = lens.userPosition(address(vault), alice);
        assertEq(pos.shares, shares);
        assertEq(pos.amount0, p0);
        assertEq(pos.amount1, p1);
        vm.prank(alice);
        (uint256 o0, uint256 o1) = vault.withdrawPair(shares, 0, 0, alice);
        assertEq(o0, p0, "lens preview equals the real exit (0)");
        assertEq(o1, p1, "lens preview equals the real exit (1)");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _createNormal(PoolKey memory k, bool native) internal {
        key = k;
        int24 tick = native ? _initPool(k, 2000e6, 1e18, false) : _initPool(k, 1e18, 2000e6, true);
        _seedExternalLiquidity(k, tick, DEEP);
        factory.setPoolAllowed(k, true, native, native ? 10_000_000e6 : 10_000 ether);
        VaultConfig memory cfg;
        cfg.poolKey = k;
        cfg.strategy = Strategy.NormalLP;
        cfg.shapeId = 4;
        cfg.centerTick = _floor(tick, k.tickSpacing);
        cfg.ticksLeft = 600;
        cfg.ticksRight = 600;
        cfg.autoRebalance = true;
        cfg.depositCap = native ? 5_000_000e6 : 5_000 ether;
        vm.prank(creator);
        vault = Vault(payable(factory.createVault(cfg, "Vortex", "VTX")));
        _approveVault();
    }

    function _oneSidedConfig(Strategy kind, int24 tick, bool below) internal view returns (VaultConfig memory cfg) {
        cfg.poolKey = key;
        cfg.strategy = kind;
        cfg.shapeId = 4;
        cfg.centerTick = _floor(tick, key.tickSpacing);
        cfg.ticksLeft = below ? int24(1_000) : int24(0);
        cfg.ticksRight = below ? int24(0) : int24(1_000);
        cfg.trailTicks = 300;
        cfg.autoRebalance = true;
        cfg.depositCap = 5_000_000e6;
    }

    function _approveVault() internal {
        address[3] memory users = [alice, bob, attacker];
        for (uint256 i; i < users.length; ++i) {
            vm.startPrank(users[i]);
            usdc.approve(address(vault), type(uint256).max);
            weth.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _trade(uint256 rounds) internal {
        bool native = Currency.unwrap(key.currency0) == address(0);
        for (uint256 i; i < rounds; ++i) {
            _swap(attacker, key, true, native ? 5 ether : 10_000e6);
            _swap(attacker, key, false, native ? 10_000e6 : 5 ether);
        }
        _syncOracle();
    }

    function _moveTickTo(int24 target, bool down) internal {
        bool native = Currency.unwrap(key.currency0) == address(0);
        for (uint256 i; i < 400; ++i) {
            (, int24 t,,) = stateView.getSlot0(_poolId(key));
            if (down ? t <= target : t >= target) break;
            if (down) _swap(attacker, key, true, native ? 10 ether : 20_000e6);
            else _swap(attacker, key, false, native ? 20_000e6 : 10 ether);
        }
        vm.warp(block.timestamp + 31 minutes);
        _syncOracle();
    }

    function _syncOracle() internal {
        if (Currency.unwrap(key.currency0) == address(0)) _syncOracleToNativePool(key);
        else _syncOracleToUsdcWethPool(key);
    }

    function _rebalance(uint16 slippage) internal {
        (, int24 tick,,) = stateView.getSlot0(_poolId(key));
        vm.prank(keeper);
        vault.rebalance(RebalanceParams({newCenterTick: _floor(tick, key.tickSpacing), maxSlippageBps: slippage}));
    }

    function _pending() internal view returns (uint256 f0, uint256 f1) {
        Band[] memory b = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            (uint128 liq, uint256 last0, uint256 last1) = stateView.getPositionInfo(
                _poolId(key), address(posm), b[i].tickLower, b[i].tickUpper, bytes32(b[i].tokenId)
            );
            (uint256 now0, uint256 now1) = stateView.getFeeGrowthInside(_poolId(key), b[i].tickLower, b[i].tickUpper);
            unchecked {
                f0 += Math.mulDiv(liq, now0 - last0, 1 << 128);
                f1 += Math.mulDiv(liq, now1 - last1, 1 << 128);
            }
        }
    }

    function _floor(int24 tick, int24 spacing) internal pure returns (int24 c) {
        c = (tick / spacing) * spacing;
        if (tick < 0 && c != tick) c -= spacing;
    }
}
