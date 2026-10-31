// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {NetworkConfig} from "../../script/NetworkConfigs.s.sol";
import {PriceGuard} from "../../src/PriceGuard.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {Vault} from "../../src/Vault.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {IPermit2Like} from "../../src/interfaces/external/IPermit2Like.sol";
import {IPositionManagerLike} from "../../src/interfaces/external/IPositionManagerLike.sol";
import {IStateViewLike} from "../../src/interfaces/external/IStateViewLike.sol";
import {Currency, PoolKey, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {PoolIdLib} from "../../src/libraries/PoolIdLib.sol";
import {MockFactory, MockFeeCollector, MockStrategy, MockSwapExecutor} from "../mocks/VaultMocks.sol";

interface IStateViewLiquidityLike is IStateViewLike {
    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
}

interface IPositionManagerLiquidityLike is IPositionManagerLike {
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);
}

contract VaultMainnetForkTest is Test {
    using PoolIdLib for PoolKey;

    address internal constant USER = address(0xA11CE);
    address internal constant SECOND_USER = address(0xB0B);
    uint256 internal constant FIRST_ETH_AMOUNT = 1 ether;
    uint256 internal constant FIRST_USDC_AMOUNT = 1_000e6;
    uint256 internal constant SECOND_ETH_AMOUNT = 0.5 ether;
    uint256 internal constant SECOND_USDC_AMOUNT = 500e6;
    uint256 internal constant IN_RANGE_ETH_AMOUNT = 1 ether;
    uint256 internal constant IN_RANGE_USDC_AMOUNT = 3_000e6;

    NetworkConfig.Configs internal configs;
    PriceGuard internal guard;
    ShapeLibrary internal shapes;
    MockStrategy internal strategy;
    Vault internal vault;
    PoolKey internal key;
    bytes32 internal poolId;

    function setUp() public {
        if (block.chainid != 1) vm.skip(true);

        configs = new NetworkConfig().getConfigs();
        key = configs.ethUsdcPoolKey;
        poolId = key.toId();

        _requireConfiguredMainnetDependencies();
        _requireInitializedV4Pool();

        guard = new PriceGuard(configs.stateView, configs.sequencerUptimeFeed, configs.nativeWrapper, address(this));
        try guard.setPairConfig(key, configs.ethUsdcPriceConfig) {}
        catch {
            vm.skip(true);
        }

        shapes = new ShapeLibrary();
        strategy = new MockStrategy();

        vault = _deployVault(_vaultConfigBelowCurrentPrice(), "Vortex Mainnet ETH USDC", "vETHUSDC");

        _fundAndApprove(USER, vault);
        _fundAndApprove(SECOND_USER, vault);
    }

    function test_mainnetInRangeEthUsdcDepositConsumesBothTokensAndMintsNft() public {
        Vault inRangeVault =
            _deployVault(_vaultConfigAroundCurrentPrice(key, poolId), "Vortex In Range ETH USDC", "vETHUSDC");
        _fundAndApprove(USER, inRangeVault);
        uint256 firstTokenId = IPositionManagerLike(configs.positionManager).nextTokenId();

        vm.prank(USER);
        (uint256 shares, uint256 used0, uint256 used1) =
            inRangeVault.depositPair{value: IN_RANGE_ETH_AMOUNT}(IN_RANGE_ETH_AMOUNT, IN_RANGE_USDC_AMOUNT, 1, USER);

        assertGt(shares, 0, "shares");
        assertGt(used0, 0, "ETH consumed");
        assertGt(used1, 0, "USDC consumed");
        assertLt(used0, IN_RANGE_ETH_AMOUNT, "ETH headroom/refund path remains available");
        assertLe(used1, IN_RANGE_USDC_AMOUNT, "USDC max respected");
        assertEq(inRangeVault.balanceOf(USER), shares, "receiver shares");
        assertEq(inRangeVault.totalSupply(), shares + 1_000, "dead shares");

        IPositionManagerLiquidityLike positionManager = IPositionManagerLiquidityLike(configs.positionManager);
        assertEq(positionManager.ownerOf(firstTokenId), address(inRangeVault), "position owner");
        assertGt(positionManager.getPositionLiquidity(firstTokenId), 0, "position liquidity");
    }

    function test_mainnetWethUsdcErc20PairDepositSettlesThroughPermit2AndPositionManager() public {
        PoolKey memory wethUsdc = _wethUsdcPoolKey();
        bytes32 wethUsdcPoolId = wethUsdc.toId();
        _requireInitializedPool(wethUsdcPoolId, "WETH/USDC V4 pool");
        guard.setPairConfig(wethUsdc, _wethUsdcPriceConfig());

        Vault wethVault = _deployVault(
            _vaultConfigAroundCurrentPrice(wethUsdc, wethUsdcPoolId), "Vortex Mainnet WETH USDC", "vWETHUSDC"
        );
        _fundAndApprove(USER, wethVault);
        uint256 firstTokenId = IPositionManagerLike(configs.positionManager).nextTokenId();
        uint256 userUsdcBefore = IERC20(configs.usdc).balanceOf(USER);
        uint256 userWethBefore = IERC20(configs.nativeWrapper).balanceOf(USER);

        vm.prank(USER);
        (uint256 shares, uint256 used0, uint256 used1) = wethVault.depositPair(3_000e6, 1 ether, 1, USER);

        assertGt(shares, 0, "shares");
        assertGt(used0, 0, "USDC consumed");
        assertGt(used1, 0, "WETH consumed");
        assertLe(used0, 3_000e6, "USDC max respected");
        assertLe(used1, 1 ether, "WETH max respected");
        assertEq(IERC20(configs.usdc).balanceOf(USER), userUsdcBefore - used0, "USDC settled");
        assertEq(IERC20(configs.nativeWrapper).balanceOf(USER), userWethBefore - used1, "WETH settled");
        assertEq(wethVault.balanceOf(USER), shares, "receiver shares");

        IPositionManagerLiquidityLike positionManager = IPositionManagerLiquidityLike(configs.positionManager);
        assertEq(positionManager.ownerOf(firstTokenId), address(wethVault), "position owner");
        assertGt(positionManager.getPositionLiquidity(firstTokenId), 0, "position liquidity");
    }

    function test_mainnetMultipleUsersReceiveFairSharesForEqualDeposits() public {
        Vault inRangeVault =
            _deployVault(_vaultConfigAroundCurrentPrice(key, poolId), "Vortex Fair ETH USDC", "vETHUSDC");
        _fundAndApprove(USER, inRangeVault);
        _fundAndApprove(SECOND_USER, inRangeVault);

        vm.prank(USER);
        (uint256 firstShares,,) =
            inRangeVault.depositPair{value: IN_RANGE_ETH_AMOUNT}(IN_RANGE_ETH_AMOUNT, IN_RANGE_USDC_AMOUNT, 1, USER);

        uint256 supplyAfterFirst = inRangeVault.totalSupply();
        uint256 assetsAfterFirst = inRangeVault.totalAssets();

        vm.prank(SECOND_USER);
        (uint256 secondShares,,) = inRangeVault.depositPair{value: IN_RANGE_ETH_AMOUNT}(
            IN_RANGE_ETH_AMOUNT, IN_RANGE_USDC_AMOUNT, 1, SECOND_USER
        );

        assertGt(firstShares, 0, "first shares");
        assertGt(secondShares, 0, "second shares");
        assertApproxEqAbs(secondShares, firstShares, 5_000, "equal deposits mint near-equal shares");
        assertEq(inRangeVault.balanceOf(USER), firstShares, "first user shares");
        assertEq(inRangeVault.balanceOf(SECOND_USER), secondShares, "second user shares");
        assertGt(inRangeVault.totalSupply(), supplyAfterFirst, "supply increased");
        assertGt(inRangeVault.totalAssets(), assetsAfterFirst, "assets increased");
    }

    function test_mainnetWithdrawPairDecreasesRealLpLiquidityAndPaysUser() public {
        uint256 firstTokenId = IPositionManagerLike(configs.positionManager).nextTokenId();

        vm.prank(USER);
        (uint256 shares,,) = vault.depositPair{value: FIRST_ETH_AMOUNT}(FIRST_ETH_AMOUNT, FIRST_USDC_AMOUNT, 1, USER);

        IPositionManagerLiquidityLike positionManager = IPositionManagerLiquidityLike(configs.positionManager);
        uint128 liquidityBefore = positionManager.getPositionLiquidity(firstTokenId);
        uint256 userUsdcBefore = IERC20(configs.usdc).balanceOf(USER);

        vm.prank(USER);
        (uint256 amount0, uint256 amount1) = vault.withdrawPair(shares / 2, 0, 0, USER);

        assertEq(amount0, 0, "below-range withdrawal should not return ETH principal");
        assertGt(amount1, 0, "USDC returned");
        assertEq(IERC20(configs.usdc).balanceOf(USER), userUsdcBefore + amount1, "USDC paid");
        assertLt(positionManager.getPositionLiquidity(firstTokenId), liquidityBefore, "NFT liquidity decreased");
        assertEq(positionManager.ownerOf(firstTokenId), address(vault), "vault still owns NFT");
        assertEq(vault.balanceOf(USER), shares - shares / 2, "shares burned");
    }

    function test_mainnetRepeatedDepositsReuseExistingInRangeNft() public {
        Vault inRangeVault =
            _deployVault(_vaultConfigAroundCurrentPrice(key, poolId), "Vortex Repeat ETH USDC", "vETHUSDC");
        _fundAndApprove(USER, inRangeVault);
        uint256 firstTokenId = IPositionManagerLike(configs.positionManager).nextTokenId();

        vm.prank(USER);
        inRangeVault.depositPair{value: IN_RANGE_ETH_AMOUNT}(IN_RANGE_ETH_AMOUNT, IN_RANGE_USDC_AMOUNT, 1, USER);

        IPositionManagerLiquidityLike positionManager = IPositionManagerLiquidityLike(configs.positionManager);
        uint128 liquidityAfterFirst = positionManager.getPositionLiquidity(firstTokenId);
        uint256 nextAfterFirst = positionManager.nextTokenId();

        vm.prank(USER);
        inRangeVault.depositPair{value: IN_RANGE_ETH_AMOUNT}(IN_RANGE_ETH_AMOUNT, IN_RANGE_USDC_AMOUNT, 1, USER);

        assertEq(positionManager.nextTokenId(), nextAfterFirst, "no extra NFT minted");
        assertGt(positionManager.getPositionLiquidity(firstTokenId), liquidityAfterFirst, "liquidity increased");
        assertEq(positionManager.ownerOf(firstTokenId), address(inRangeVault), "position owner");
    }

    function test_mainnetErc20PairRejectsNativeValue() public {
        PoolKey memory wethUsdc = _wethUsdcPoolKey();
        bytes32 wethUsdcPoolId = wethUsdc.toId();
        _requireInitializedPool(wethUsdcPoolId, "WETH/USDC V4 pool");
        guard.setPairConfig(wethUsdc, _wethUsdcPriceConfig());

        Vault wethVault = _deployVault(
            _vaultConfigAroundCurrentPrice(wethUsdc, wethUsdcPoolId), "Vortex Mainnet WETH USDC", "vWETHUSDC"
        );
        _fundAndApprove(USER, wethVault);

        vm.prank(USER);
        vm.expectRevert(Vault.InvalidNativeValue.selector);
        wethVault.depositPair{value: 1}(3_000e6, 1 ether, 1, USER);
    }

    function _deployVault(VaultConfig memory config, string memory name, string memory symbol)
        internal
        returns (Vault newVault)
    {
        MockFeeCollector collector = new MockFeeCollector(address(this));
        MockFactory factory = new MockFactory(0, 1_000, address(collector));
        Vault implementation = new Vault(
            IPositionManagerLike(configs.positionManager),
            configs.stateView,
            IPermit2Like(configs.permit2),
            guard,
            shapes,
            address(new MockSwapExecutor()),
            address(factory),
            configs.poolManager
        );
        newVault = Vault(payable(Clones.clone(address(implementation))));
        vm.prank(address(factory));
        newVault.initialize(name, symbol, address(strategy), config);
        factory.setVault(address(newVault), true);
    }

    function _fundAndApprove(address account, Vault targetVault) internal {
        vm.deal(account, 100 ether);
        deal(configs.usdc, account, 1_000_000e6);
        deal(configs.nativeWrapper, account, 1_000 ether);
        vm.startPrank(account);
        IERC20(configs.usdc).approve(address(targetVault), type(uint256).max);
        IERC20(configs.nativeWrapper).approve(address(targetVault), type(uint256).max);
        vm.stopPrank();
    }

    function test_mainnetDepositPairMintsRealPositionNftAndShares() public {
        uint256 firstTokenId = IPositionManagerLike(configs.positionManager).nextTokenId();

        vm.prank(USER);
        (uint256 shares, uint256 used0, uint256 used1) =
            vault.depositPair{value: FIRST_ETH_AMOUNT}(FIRST_ETH_AMOUNT, FIRST_USDC_AMOUNT, 1, USER);

        assertGt(shares, 0, "shares");
        assertEq(used0, 0, "below-range deposit should not consume ETH");
        assertGt(used1, 0, "used USDC");
        assertEq(vault.balanceOf(USER), shares, "receiver shares");
        assertEq(vault.totalSupply(), shares + 1_000, "dead shares");
        assertGt(vault.totalAssets(), 0, "assets");

        IPositionManagerLiquidityLike positionManager = IPositionManagerLiquidityLike(configs.positionManager);
        assertEq(positionManager.ownerOf(firstTokenId), address(vault), "position owner");
        assertGt(positionManager.getPositionLiquidity(firstTokenId), 0, "position liquidity");
    }

    function test_mainnetSecondDepositIncreasesExistingPositionLiquidityWithoutMintingNewNft() public {
        uint256 firstTokenId = IPositionManagerLike(configs.positionManager).nextTokenId();

        vm.prank(USER);
        (uint256 firstShares,,) =
            vault.depositPair{value: FIRST_ETH_AMOUNT}(FIRST_ETH_AMOUNT, FIRST_USDC_AMOUNT, 1, USER);

        IPositionManagerLiquidityLike positionManager = IPositionManagerLiquidityLike(configs.positionManager);
        uint128 firstLiquidity = positionManager.getPositionLiquidity(firstTokenId);
        uint256 nextAfterFirst = positionManager.nextTokenId();
        uint256 supplyAfterFirst = vault.totalSupply();

        vm.prank(USER);
        (uint256 secondShares, uint256 used0, uint256 used1) =
            vault.depositPair{value: SECOND_ETH_AMOUNT}(SECOND_ETH_AMOUNT, SECOND_USDC_AMOUNT, 1, USER);

        assertGt(firstShares, 0, "first shares");
        assertGt(secondShares, 0, "second shares");
        assertEq(used0, 0, "second deposit should not consume ETH");
        assertGt(used1, 0, "second used USDC");
        assertEq(positionManager.nextTokenId(), nextAfterFirst, "no new nft");
        assertEq(positionManager.ownerOf(firstTokenId), address(vault), "position owner");
        assertGt(positionManager.getPositionLiquidity(firstTokenId), firstLiquidity, "liquidity increased");
        assertGt(vault.totalSupply(), supplyAfterFirst, "supply increased");
    }

    function test_mainnetNativeEthRefundsUnusedInput() public {
        uint256 beforeBalance = USER.balance;

        vm.prank(USER);
        (uint256 shares, uint256 used0, uint256 used1) =
            vault.depositPair{value: FIRST_ETH_AMOUNT}(FIRST_ETH_AMOUNT, FIRST_USDC_AMOUNT, 1, USER);

        assertGt(shares, 0, "shares");
        assertEq(used0, 0, "unused ETH");
        assertGt(used1, 0, "used USDC");
        assertEq(USER.balance, beforeBalance, "ETH refunded");
    }

    function test_mainnetDepositPairRevertsForInvalidInputs() public {
        vm.startPrank(USER);

        vm.expectRevert(Vault.InvalidNativeValue.selector);
        vault.depositPair{value: FIRST_ETH_AMOUNT / 2}(FIRST_ETH_AMOUNT, FIRST_USDC_AMOUNT, 1, USER);

        vm.expectRevert(Vault.ZeroAddress.selector);
        vault.depositPair{value: FIRST_ETH_AMOUNT}(FIRST_ETH_AMOUNT, FIRST_USDC_AMOUNT, 1, address(0));

        vm.expectRevert(Vault.SlippageExceeded.selector);
        vault.depositPair{value: FIRST_ETH_AMOUNT}(FIRST_ETH_AMOUNT, FIRST_USDC_AMOUNT, type(uint256).max, USER);

        vm.stopPrank();
    }

    function _vaultConfigBelowCurrentPrice() internal view returns (VaultConfig memory config) {
        (, int24 tick,,) = configs.stateView.getSlot0(poolId);
        int24 center = tick - 120;

        config.poolKey = key;
        config.strategy = Strategy.NormalLP;
        config.shapeId = 7;
        config.centerTick = center;
        config.ticksLeft = 60;
        config.ticksRight = 60;
        config.driftTicks = 10;
        config.trailTicks = 0;
        config.autoRebalance = false;
        config.lockOnFill = false;
        config.depositCap = 0;
        config.baseIsCurrency0 = true;
    }

    function _vaultConfigAroundCurrentPrice(PoolKey memory poolKey, bytes32 targetPoolId)
        internal
        view
        returns (VaultConfig memory config)
    {
        (, int24 tick,,) = configs.stateView.getSlot0(targetPoolId);

        config.poolKey = poolKey;
        config.strategy = Strategy.NormalLP;
        config.shapeId = 7;
        config.centerTick = tick;
        config.ticksLeft = 120;
        config.ticksRight = 120;
        config.driftTicks = 10;
        config.trailTicks = 0;
        config.autoRebalance = false;
        config.lockOnFill = false;
        config.depositCap = 0;
        config.baseIsCurrency0 = Currency.unwrap(poolKey.currency0) == address(0);
    }

    function _wethUsdcPoolKey() internal view returns (PoolKey memory wethUsdc) {
        wethUsdc = PoolKey({
            currency0: Currency.wrap(configs.usdc),
            currency1: Currency.wrap(configs.nativeWrapper),
            fee: configs.ethUsdcPoolKey.fee,
            tickSpacing: configs.ethUsdcPoolKey.tickSpacing,
            hooks: address(0)
        });
    }

    function _wethUsdcPriceConfig() internal view returns (IPriceGuard.PairConfig memory config) {
        config = configs.ethUsdcPriceConfig;
        config.invertFeed = true;
        config.invertV3 = false;
    }

    function _requireConfiguredMainnetDependencies() internal view {
        require(address(configs.stateView) != address(0), "StateView missing");
        require(configs.poolManager != address(0), "PoolManager missing");
        require(configs.positionManager != address(0), "PositionManager missing");
        require(configs.permit2 != address(0), "Permit2 missing");
        require(configs.nativeWrapper != address(0), "WETH missing");
        require(configs.usdc != address(0), "USDC missing");
        require(Currency.unwrap(configs.ethUsdcPoolKey.currency0) == address(0), "ETH/USDC currency0 not native");
        require(Currency.unwrap(configs.ethUsdcPoolKey.currency1) == configs.usdc, "ETH/USDC currency1 not USDC");
    }

    function _requireInitializedV4Pool() internal view {
        _requireInitializedPool(poolId, "ETH/USDC V4 pool");
    }

    function _requireInitializedPool(bytes32 targetPoolId, string memory label) internal view {
        (uint160 sqrtPriceX96,,,) = configs.stateView.getSlot0(targetPoolId);
        require(sqrtPriceX96 != 0, "ETH/USDC V4 pool uninitialized");
        require(IStateViewLiquidityLike(address(configs.stateView)).getLiquidity(targetPoolId) != 0, label);
    }
}
