// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {Vault} from "../../src/Vault.sol";
import {BuyTheDipStrategy} from "../../src/strategies/BuyTheDipStrategy.sol";
import {StrategyBase} from "../../src/strategies/StrategyBase.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {IPermit2Like} from "../../src/interfaces/external/IPermit2Like.sol";
import {IPositionManagerLike} from "../../src/interfaces/external/IPositionManagerLike.sol";
import {Band, Currency, DepositMode, PoolKey, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {FeeOnTransferToken, MintableToken} from "../mocks/TokenMocks.sol";
import {
    MockPermit2,
    MockFactory,
    MockFeeCollector,
    MockPositionManager,
    MockShapeLibrary,
    MockStrategy,
    MockSwapExecutor,
    MockVaultPriceGuard,
    MockVaultStateView
} from "../mocks/VaultMocks.sol";

contract VaultTest is Test {
    event ProtocolFeeBpsSet(uint256 oldFeeBps, uint256 newFeeBps);
    event MaxProtocolFeeBpsSet(uint256 oldMaxFeeBps, uint256 newMaxFeeBps);

    address internal user = address(0xA11CE);
    address internal receiver = address(0xB0B);
    MintableToken internal token0;
    MintableToken internal token1;
    MockPermit2 internal permit2;
    MockVaultStateView internal stateView;
    MockPositionManager internal positionManager;
    MockVaultPriceGuard internal priceGuard;
    MockShapeLibrary internal shapes;
    MockSwapExecutor internal swapExecutor;
    MockStrategy internal strategy;
    Vault internal implementation;
    Vault internal vault;

    function setUp() public {
        token0 = new MintableToken();
        token1 = new MintableToken();
        permit2 = new MockPermit2();
        stateView = new MockVaultStateView();
        positionManager = new MockPositionManager(permit2, stateView);
        priceGuard = new MockVaultPriceGuard();
        shapes = new MockShapeLibrary();
        swapExecutor = new MockSwapExecutor();
        strategy = new MockStrategy();
        implementation = new Vault(
            IPositionManagerLike(address(positionManager)),
            stateView,
            IPermit2Like(address(permit2)),
            priceGuard,
            shapes,
            address(swapExecutor),
            address(this),
            address(0x4444)
        );
        vault = Vault(payable(Clones.clone(address(implementation))));
        vault.initialize("Vortex ETH USDC", "vETHUSDC", address(strategy), _config());
        token0.mint(user, 1_000_000 ether);
        token1.mint(user, 1_000_000 ether);
        vm.startPrank(user);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function test_initialize_sets_metadata_and_asset() public view {
        assertEq(vault.name(), "Vortex ETH USDC");
        assertEq(vault.symbol(), "vETHUSDC");
        assertEq(vault.asset(), address(token1));
        assertEq(vault.decimals(), 18);
    }

    function test_implementation_cannot_be_initialized() public {
        vm.expectRevert(Vault.ImplementationLocked.selector);
        implementation.initialize("Bad", "BAD", address(strategy), _config());
    }

    function test_depositPair_mints_locked_and_receiver_shares() public {
        vm.prank(user);
        (uint256 shares, uint256 used0, uint256 used1) = vault.depositPair(0, 100_000 ether, 1, receiver);

        assertGt(shares, 0);
        assertEq(used0, 0);
        assertEq(used1, 100_000 ether);
        assertEq(vault.balanceOf(receiver), shares);
        assertEq(vault.balanceOf(0x000000000000000000000000000000000000dEaD), 1_000);
        assertEq(vault.totalSupply(), shares + 1_000);
        assertEq(positionManager.ownerOf(1), address(vault));
    }

    function test_second_depositPair_increases_existing_position() public {
        vm.prank(user);
        vault.depositPair(0, 100_000 ether, 1, receiver);
        uint128 firstLiquidity = positionManager.liquidityOf(1);

        vm.prank(user);
        (uint256 shares,, uint256 used1) = vault.depositPair(0, 50_000 ether, 1, receiver);

        assertGt(shares, 0);
        assertEq(used1, 50_000 ether);
        assertGt(positionManager.liquidityOf(1), firstLiquidity);
        assertEq(positionManager.nextTokenId(), 2);
    }

    function test_erc4626_deposit_uses_currency1_asset() public {
        vm.prank(user);
        uint256 shares = vault.deposit(100_000 ether, receiver);

        assertGt(shares, 0);
        assertEq(vault.balanceOf(receiver), shares);
        // ERC-4626 deposits are held as idle token1 (valued one to one) until a later compounding step.
        assertEq(IERC20(vault.asset()).balanceOf(address(vault)), 100_000 ether);
        assertEq(IERC20(vault.asset()).balanceOf(address(positionManager)), 0);
        assertEq(shares, vault.previewDeposit(0) + 100_000 ether - 1_000, "first deposit locks 1,000 shares");
    }

    function test_price_untrusted_reverts_depositPair() public {
        priceGuard.setTrusted(false);

        vm.prank(user);
        vm.expectRevert(Vault.PriceUntrusted.selector);
        vault.depositPair(0, 100_000 ether, 1, receiver);
    }

    function test_minShares_and_cap_are_enforced() public {
        vm.prank(user);
        vm.expectRevert(Vault.SlippageExceeded.selector);
        vault.depositPair(0, 100_000 ether, type(uint256).max, receiver);

        Vault capped = _newVault(_configWithCap(50_000 ether));
        vm.startPrank(user);
        token0.approve(address(capped), type(uint256).max);
        token1.approve(address(capped), type(uint256).max);
        vm.expectRevert(Vault.DepositCapExceeded.selector);
        capped.depositPair(0, 100_000 ether, 1, receiver);
        vm.stopPrank();
    }

    function test_fee_on_transfer_asset_reverts() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        feeToken.mint(user, 1_000_000 ether);
        VaultConfig memory cfg = _config();
        cfg.poolKey.currency1 = Currency.wrap(address(feeToken));
        Vault feeVault = _newVault(cfg);

        vm.startPrank(user);
        feeToken.approve(address(feeVault), type(uint256).max);
        vm.expectRevert(Vault.TokenTransferShortfall.selector);
        feeVault.depositPair(0, 100_000 ether, 1, receiver);
        vm.stopPrank();
    }

    function test_native_pool_requires_exact_msg_value_and_refunds_unused_native() public {
        VaultConfig memory cfg = _config();
        cfg.poolKey.currency0 = Currency.wrap(address(0));
        Vault nativeVault = _newVault(cfg);
        vm.deal(user, 10 ether);

        vm.startPrank(user);
        token1.approve(address(nativeVault), type(uint256).max);
        vm.expectRevert(Vault.InvalidNativeValue.selector);
        nativeVault.depositPair{value: 0.5 ether}(1 ether, 100_000 ether, 1, receiver);

        uint256 beforeBalance = user.balance;
        nativeVault.depositPair{value: 1 ether}(1 ether, 100_000 ether, 1, receiver);
        assertEq(user.balance, beforeBalance);
        vm.stopPrank();
    }

    function test_deposit_modes_are_enforced() public {
        strategy.setMode(DepositMode.Token1Only);
        vm.prank(user);
        vm.expectRevert(Vault.InvalidDepositMode.selector);
        vault.depositPair(1 ether, 100_000 ether, 1, receiver);
    }

    function test_strategy_rejects_depositPair() public {
        strategy.setAllowed(false);

        vm.prank(user);
        vm.expectRevert(Vault.DepositNotAllowed.selector);
        vault.depositPair(0, 100_000 ether, 1, receiver);
    }

    function test_firstDepositStrategySwapIsIndependentlyCappedAtSixtyPercent() public {
        Band[] memory bands_ = new Band[](1);
        bands_[0] = Band({tickLower: -60, tickUpper: 60, tokenId: 0, liquidity: 0});
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        strategy.setPlan(bands_, weights, true, true, 121 ether, false);

        vm.prank(user);
        vm.expectRevert(IVault.SwapTooLarge.selector);
        vault.depositPair(200 ether, 0, 1, receiver);
    }

    /**
     * M7 audit: a strategy may not lock idle on the first deposit; the funds would sit in the vault with no bands.
     */
    function test_firstDepositRejectsALockIdlePlan() public {
        (Band[] memory bands_, uint16[] memory weights) = _bandsOf(-60, 60, 1);
        strategy.setPlan(bands_, weights, false, false, 0, true);

        vm.prank(user);
        vm.expectRevert(IVault.InvalidPlan.selector);
        vault.depositPair(1 ether, 1 ether, 1, receiver);
    }

    /**
     * M7 audit: a first-deposit swap may not spend more of the input token than the depositor supplied, even when
     * the input is well below the 60% value cap.
     */
    function test_firstDepositRejectsASwapAboveTheSuppliedInput() public {
        (Band[] memory bands_, uint16[] memory weights) = _bandsOf(-60, 60, 1);
        strategy.setPlan(bands_, weights, true, true, 2 ether, false);

        vm.prank(user);
        vm.expectRevert(IVault.InvalidPlan.selector);
        vault.depositPair(1 ether, 100 ether, 1, receiver);
    }

    /**
     * M7 audit: `needsSwap` and `swapAmountIn` must agree in both directions.
     */
    function test_firstDepositRejectsInconsistentSwapFlags() public {
        (Band[] memory bands_, uint16[] memory weights) = _bandsOf(-60, 60, 1);
        strategy.setPlan(bands_, weights, false, false, 1 ether, false);
        vm.prank(user);
        vm.expectRevert(IVault.InvalidPlan.selector);
        vault.depositPair(10 ether, 10 ether, 1, receiver);

        strategy.setPlan(bands_, weights, true, false, 0, false);
        vm.prank(user);
        vm.expectRevert(IVault.InvalidPlan.selector);
        vault.depositPair(10 ether, 10 ether, 1, receiver);
    }

    /**
     * M7 audit: first-deposit geometry is capped at five bands and every band needs a non-zero weight.
     */
    function test_firstDepositRejectsSixBandsAndZeroWeights() public {
        (Band[] memory six, uint16[] memory sixWeights) = _bandsOf(-180, 180, 6);
        strategy.setPlan(six, sixWeights, false, false, 0, false);
        vm.prank(user);
        vm.expectRevert(IVault.InvalidPlan.selector);
        vault.depositPair(10 ether, 10 ether, 1, receiver);

        (Band[] memory two, uint16[] memory twoWeights) = _bandsOf(-60, 60, 2);
        twoWeights[0] = 0;
        twoWeights[1] = 10_000;
        strategy.setPlan(two, twoWeights, false, false, 0, false);
        vm.prank(user);
        vm.expectRevert(IVault.InvalidPlan.selector);
        vault.depositPair(10 ether, 10 ether, 1, receiver);
    }

    /**
     * M7 audit: one-sided strategies never swap; a Buy the Dip plan that asks for one is refused, and the same ladder
     * without the swap is accepted.
     */
    function test_firstDepositRejectsASwapFromAOneSidedStrategy() public {
        Vault oneSided = _oneSidedVault(true);
        (Band[] memory bands_, uint16[] memory weights) = _bandsOf(-120, -60, 1);
        strategy.setPlan(bands_, weights, true, false, 1 ether, false);

        vm.prank(user);
        vm.expectRevert(IVault.InvalidPlan.selector);
        oneSided.depositPair(0, 10 ether, 1, receiver);

        strategy.setPlan(bands_, weights, false, false, 0, false);
        vm.prank(user);
        (uint256 shares,,) = oneSided.depositPair(0, 10 ether, 1, receiver);
        assertGt(shares, 0);
    }

    /**
     * M7 audit: the single-sided rule is exact. Below the price a band may end at the tick but not one tick above
     * it; above the price a band may start one tick above the tick but not at it.
     */
    function test_firstDepositOneSidedBoundaryIsExact() public {
        Vault below = _oneSidedVault(true);
        stateView.setSlot0(SqrtPriceMath.getSqrtPriceAtTick(59), 59);
        (Band[] memory crossing, uint16[] memory weights) = _bandsOf(0, 60, 1);
        strategy.setPlan(crossing, weights, false, false, 0, false);
        vm.prank(user);
        vm.expectRevert(IVault.InvalidPlan.selector);
        below.depositPair(0, 10 ether, 1, receiver);

        Vault above = _oneSidedVault(false);
        stateView.setSlot0(SqrtPriceMath.getSqrtPriceAtTick(60), 60);
        (crossing, weights) = _bandsOf(60, 120, 1);
        strategy.setPlan(crossing, weights, false, false, 0, false);
        vm.prank(user);
        vm.expectRevert(IVault.InvalidPlan.selector);
        above.depositPair(10 ether, 0, 1, receiver);
    }

    /**
     * M7 audit: the first-deposit swap passes the guide's oracle floor (reference output, less the pool fee, less
     * 1%), leaves no allowance even when the executor pulls less than approved, and its output joins the deposit
     * budget: the vault keeps nothing but the unpulled wei.
     */
    function test_firstDepositSwapUsesTheOracleFloorRevokesAndDeploysTheOutput() public {
        _firstDepositSwap(false);
    }

    function test_firstDepositSwapZeroForOneUsesTheOracleFloorRevokesAndDeploysTheOutput() public {
        _firstDepositSwap(true);
    }

    /**
     * M7 audit: initialization validates the configuration through the strategy at the live tick; a production
     * strategy paired with a configuration of another kind, or an invalid ladder, never becomes a vault.
     */
    function test_initializeValidatesTheConfigurationThroughTheStrategy() public {
        BuyTheDipStrategy dip = new BuyTheDipStrategy(new ShapeLibrary());
        Vault clone = Vault(payable(Clones.clone(address(implementation))));
        vm.expectRevert(StrategyBase.InvalidStrategy.selector);
        clone.initialize("Bad", "BAD", address(dip), _config());

        VaultConfig memory config = _oneSidedConfig(true);
        config.shapeId = 1;
        vm.expectRevert(StrategyBase.InvalidShape.selector);
        clone.initialize("Bad", "BAD", address(dip), config);

        clone.initialize("Dip", "DIP", address(dip), _oneSidedConfig(true));
        assertEq(clone.name(), "Dip");
    }

    function _firstDepositSwap(bool zeroForOne) private {
        uint160 reference_ = SqrtPriceMath.getSqrtPriceAtTick(6_932); // about 2.0 token1 per token0
        priceGuard.setReference(reference_);
        uint256 amountIn = 1 ether;
        uint256 priceX96 = Math.mulDiv(reference_, reference_, 1 << 96);
        uint256 expected =
            zeroForOne ? Math.mulDiv(amountIn, priceX96, 1 << 96) : Math.mulDiv(amountIn, 1 << 96, priceX96);
        expected = Math.mulDiv(expected, 1e6 - 500, 1e6);
        expected = Math.mulDiv(expected, 9_900, 10_000);

        uint256 out = expected + 1;
        swapExecutor.setExecuteTransfers(true);
        swapExecutor.setPullShortfall(1);
        swapExecutor.setConfiguredOutput(out);
        (zeroForOne ? token1 : token0).mint(address(swapExecutor), out);
        (Band[] memory bands_, uint16[] memory weights) = _bandsOf(-60, 60, 1);
        strategy.setPlan(bands_, weights, true, zeroForOne, amountIn, false);

        vm.prank(user);
        vault.depositPair(10 ether, 10 ether, 1, receiver);

        MintableToken input = zeroForOne ? token0 : token1;
        MintableToken output = zeroForOne ? token1 : token0;
        assertEq(swapExecutor.lastMinOut(), expected, "oracle floor");
        assertEq(input.allowance(address(vault), address(swapExecutor)), 0, "executor allowance revoked");
        assertEq(input.balanceOf(address(vault)), 1, "only the unpulled wei stays");
        assertEq(output.balanceOf(address(vault)), 0, "the swap output is deployed or refunded");
    }

    function _oneSidedConfig(bool below) private view returns (VaultConfig memory config) {
        config = _config();
        config.strategy = Strategy.BuyTheDip;
        config.baseIsCurrency0 = below; // Buy the Dip is below the price when the base is currency0
        config.shapeId = 3;
        config.driftTicks = 0;
        config.trailTicks = 60;
        config.ticksLeft = below ? int24(120) : int24(0);
        config.ticksRight = below ? int24(0) : int24(120);
    }

    function _oneSidedVault(bool below) private returns (Vault oneSided) {
        oneSided = Vault(payable(Clones.clone(address(implementation))));
        oneSided.initialize("Vortex dip", "vDIP", address(strategy), _oneSidedConfig(below));
        vm.startPrank(user);
        token0.approve(address(oneSided), type(uint256).max);
        token1.approve(address(oneSided), type(uint256).max);
        vm.stopPrank();
    }

    /**
     * `count` contiguous equal bands from `lower` to `upper` (spacing 60) with weights summing to 10,000.
     */
    function _bandsOf(int24 lower, int24 upper, uint256 count)
        private
        pure
        returns (Band[] memory bands_, uint16[] memory weights)
    {
        bands_ = new Band[](count);
        weights = new uint16[](count);
        int24 width = (upper - lower) / int24(int256(count));
        uint256 left = 10_000;
        for (uint256 i; i < count; ++i) {
            int24 lo = lower + width * int24(int256(i));
            bands_[i] = Band({tickLower: lo, tickUpper: i + 1 == count ? upper : lo + width, tokenId: 0, liquidity: 0});
            weights[i] = i + 1 == count ? uint16(left) : uint16(10_000 / count);
            left -= weights[i];
        }
    }

    function test_erc20_share_transfer_and_allowance() public {
        vm.prank(user);
        uint256 shares = vault.deposit(100_000 ether, user);

        vm.prank(user);
        vault.approve(receiver, shares);
        vm.prank(receiver);
        vault.transferFrom(user, receiver, shares);

        assertEq(vault.balanceOf(receiver), shares);
        assertEq(vault.allowance(user, receiver), 0);
    }

    function test_preview_functions_are_consistent_after_deposit() public {
        vm.prank(user);
        vault.deposit(100_000 ether, receiver);

        uint256 shares = vault.previewDeposit(10_000 ether);
        uint256 assets = vault.previewRedeem(shares);
        assertLe(assets, 10_000 ether);
        assertEq(vault.previewRedeem(shares), vault.convertToAssets(shares));
    }

    function test_idle_asset_withdraw_and_redeem_limits_are_reflected() public {
        token1.mint(address(vault), 10_000 ether);
        vm.prank(user);
        uint256 shares = vault.deposit(100_000 ether, user);

        uint256 maxWithdraw = vault.maxWithdraw(user);
        uint256 ownerAssets = vault.convertToAssets(vault.balanceOf(user));
        uint256 idle = token1.balanceOf(address(vault));
        assertEq(maxWithdraw, ownerAssets < idle ? ownerAssets : idle, "bounded by the owner's claim and idle token1");
        uint256 maxRedeem = vault.maxRedeem(user);
        uint256 liquidShares = vault.previewWithdraw(maxWithdraw);
        assertEq(maxRedeem, vault.balanceOf(user) < liquidShares ? vault.balanceOf(user) : liquidShares);

        vm.prank(user);
        uint256 burned = vault.withdraw(1_000 ether, receiver, user);
        assertEq(token1.balanceOf(receiver), 1_000 ether);
        assertEq(vault.balanceOf(user), shares - burned);
    }

    function test_full_idle_redeem_burns_user_shares_without_decreasing_lp_nft() public {
        vm.prank(user);
        vault.depositPair(100 ether, 100 ether, 0, user); // creates the LP NFT (id 1)
        vm.prank(user);
        uint256 shares = vault.deposit(100_000 ether, user);
        uint128 liquidityBefore = positionManager.liquidityOf(1);

        token1.mint(address(vault), 1e50);
        shares = vault.balanceOf(user);
        uint256 assets = vault.previewRedeem(shares);

        vm.prank(user);
        uint256 redeemed = vault.redeem(shares, receiver, user);

        assertEq(redeemed, assets);
        assertEq(vault.balanceOf(user), 0);
        assertEq(token1.balanceOf(receiver), assets);
        assertEq(positionManager.liquidityOf(1), liquidityBefore);
        assertEq(positionManager.ownerOf(1), address(vault));
    }

    function test_factory_mock_fee_setters_validate_authorization_and_limits() public {
        MockFeeCollector collector = new MockFeeCollector(receiver);
        MockFactory factory = new MockFactory(100, 1_000, address(collector));

        assertEq(factory.protocolFeeBps(), 100);
        assertEq(factory.maxProtocolFeeBps(), 1_000);

        vm.prank(user);
        vm.expectRevert(MockFactory.NotOwner.selector);
        factory.setProtocolFeeBps(200);

        vm.expectRevert(MockFactory.InvalidProtocolFee.selector);
        factory.setProtocolFeeBps(1_001);

        vm.expectEmit(true, true, true, true, address(factory));
        emit ProtocolFeeBpsSet(100, 500);
        factory.setProtocolFeeBps(500);
        assertEq(factory.protocolFeeBps(), 500);

        vm.expectRevert(MockFactory.InvalidProtocolFee.selector);
        factory.setMaxProtocolFeeBps(499);

        vm.expectRevert(MockFactory.InvalidProtocolFee.selector);
        factory.setMaxProtocolFeeBps(10_001);

        vm.expectEmit(true, true, true, true, address(factory));
        emit MaxProtocolFeeBpsSet(1_000, 2_000);
        factory.setMaxProtocolFeeBps(2_000);
        assertEq(factory.maxProtocolFeeBps(), 2_000);
        factory.setProtocolFeeBps(250);
        factory.setMaxProtocolFeeBps(250);
        assertEq(factory.maxProtocolFeeBps(), 250);
    }

    function test_factory_mock_constructor_rejects_invalid_fee_configuration() public {
        MockFeeCollector collector = new MockFeeCollector(receiver);

        vm.expectRevert(MockFactory.InvalidProtocolFee.selector);
        this.deployMockFactory(1_001, 1_000, address(collector));

        vm.expectRevert(MockFactory.InvalidProtocolFee.selector);
        this.deployMockFactory(0, 10_001, address(collector));

        vm.expectRevert(MockFactory.InvalidProtocolFee.selector);
        this.deployMockFactory(0, 1_000, address(0));
    }

    // An expected revert inside a `new` of another file's contract ends the test early (forge deploys it through a
    // cheatcode), so each reverting deployment goes through an external self-call and the checks after it run.
    function deployMockFactory(uint256 fee, uint256 maxFee, address collector) external returns (MockFactory) {
        return new MockFactory(fee, maxFee, collector);
    }

    function test_collectFees_reads_current_factory_fee_and_leaves_net_fees_idle() public {
        (Vault feeVault, MockFactory factory, MockFeeCollector collector) = _newM5Vault(100, 1_000);
        vm.startPrank(user);
        token1.approve(address(feeVault), type(uint256).max);
        feeVault.depositPair(0, 100_000 ether, 1, user);
        vm.stopPrank();

        uint128 liquidity = positionManager.liquidityOf(1);
        uint256 fee1 = 1_000 ether;
        token1.mint(address(positionManager), fee1);
        stateView.setFees(0, fee1 * (1 << 128) / liquidity);

        feeVault.collectFees();
        assertApproxEqAbs(token1.balanceOf(address(collector)), 10 ether, 1);
        assertApproxEqAbs(token1.balanceOf(address(feeVault)), 990 ether, 1);

        factory.setProtocolFeeBps(500);
        token1.mint(address(positionManager), fee1);
        stateView.setFees(0, 2 * fee1 * (1 << 128) / liquidity);

        feeVault.collectFees();
        assertApproxEqAbs(token1.balanceOf(address(collector)), 60 ether, 2);
        assertApproxEqAbs(token1.balanceOf(address(feeVault)), 1_940 ether, 2);
    }

    function test_collectFees_does_not_double_count_or_rededuct_unchanged_fees() public {
        (Vault feeVault,, MockFeeCollector collector) = _newM5Vault(1_000, 2_000);
        vm.startPrank(user);
        token1.approve(address(feeVault), type(uint256).max);
        feeVault.depositPair(0, 100_000 ether, 1, user);
        vm.stopPrank();

        uint128 liquidity = positionManager.liquidityOf(1);
        uint256 fee1 = 1_000 ether;
        token1.mint(address(positionManager), fee1);
        stateView.setFees(0, fee1 * (1 << 128) / liquidity);

        feeVault.collectFees();
        uint256 collectorAfterFirst = token1.balanceOf(address(collector));
        uint256 vaultAfterFirst = token1.balanceOf(address(feeVault));

        feeVault.collectFees();

        assertEq(token1.balanceOf(address(collector)), collectorAfterFirst);
        assertEq(token1.balanceOf(address(feeVault)), vaultAfterFirst);
    }

    function test_withdrawPair_works_when_paused_oracle_reverts_and_pays_protocol_fee_from_fees_only() public {
        (Vault feeVault,, MockFeeCollector collector) = _newM5Vault(1_000, 2_000);
        vm.startPrank(user);
        token1.approve(address(feeVault), type(uint256).max);
        (uint256 shares,,) = feeVault.depositPair(0, 100_000 ether, 1, user);
        vm.stopPrank();

        uint128 liquidity = positionManager.liquidityOf(1);
        uint256 fee1 = 1_000 ether;
        token1.mint(address(positionManager), fee1);
        stateView.setFees(0, fee1 * (1 << 128) / liquidity);
        priceGuard.setRevert(true);

        vm.prank(user);
        (uint256 out0, uint256 out1) = feeVault.withdrawPair(shares / 2, 0, 0, receiver);

        assertEq(out0, 0);
        assertGt(out1, 0);
        assertApproxEqAbs(token1.balanceOf(address(collector)), 100 ether, 1);
        assertEq(feeVault.balanceOf(user), shares - shares / 2);
    }

    function test_withdrawPair_works_when_paused_without_keeper_or_oracle() public {
        (Vault feeVault,,) = _newM5Vault(0, 1_000);
        vm.startPrank(user);
        token1.approve(address(feeVault), type(uint256).max);
        (uint256 shares,,) = feeVault.depositPair(0, 100_000 ether, 1, user);
        vm.stopPrank();

        priceGuard.setRevert(true);
        vm.store(address(feeVault), bytes32(uint256(3)), bytes32(uint256(1 << 64)));

        vm.prank(user);
        (uint256 out0, uint256 out1) = feeVault.withdrawPair(shares / 4, 0, 0, receiver);

        assertEq(out0, 0);
        assertGt(out1, 0);
        assertEq(feeVault.balanceOf(user), shares - shares / 4);
    }

    function test_withdrawPair_enforces_minimum_outputs() public {
        (Vault feeVault,,) = _newM5Vault(0, 1_000);
        vm.startPrank(user);
        token1.approve(address(feeVault), type(uint256).max);
        (uint256 shares,,) = feeVault.depositPair(0, 100_000 ether, 1, user);
        vm.expectRevert(Vault.SlippageExceeded.selector);
        feeVault.withdrawPair(shares / 2, 1, type(uint256).max, receiver);
        vm.stopPrank();
    }

    function test_compound_is_keeper_only_and_mints_no_shares() public {
        (Vault feeVault, MockFactory factory,) = _newM5Vault(0, 1_000);
        vm.startPrank(user);
        token1.approve(address(feeVault), type(uint256).max);
        feeVault.depositPair(0, 100_000 ether, 1, user);
        vm.stopPrank();

        token1.mint(address(feeVault), 10_000 ether);
        uint256 supplyBefore = feeVault.totalSupply();
        uint128 liquidityBefore = positionManager.liquidityOf(1);

        vm.prank(user);
        vm.expectRevert(Vault.NotAuthorized.selector);
        feeVault.compound();

        factory.setKeeper(user, true);
        vm.prank(user);
        (, uint256 used1) = feeVault.compound();

        assertGt(used1, 0);
        assertEq(feeVault.totalSupply(), supplyBefore);
        assertGt(positionManager.liquidityOf(1), liquidityBefore);
    }

    function test_compound_requires_trusted_price() public {
        (Vault feeVault, MockFactory factory,) = _newM5Vault(0, 1_000);
        vm.startPrank(user);
        token1.approve(address(feeVault), type(uint256).max);
        feeVault.depositPair(0, 100_000 ether, 1, user);
        vm.stopPrank();

        token1.mint(address(feeVault), 10_000 ether);
        factory.setKeeper(user, true);
        priceGuard.setTrusted(false);

        vm.prank(user);
        vm.expectRevert(Vault.PriceUntrusted.selector);
        feeVault.compound();
    }

    function test_compound_reverts_when_idle_budget_exceeds_position_manager_uint128_limit() public {
        (Vault feeVault, MockFactory factory,) = _newM5Vault(0, 1_000);
        vm.startPrank(user);
        token1.approve(address(feeVault), type(uint256).max);
        feeVault.depositPair(0, 100_000 ether, 1, user);
        vm.stopPrank();

        token1.mint(address(feeVault), uint256(type(uint128).max) + 1);
        factory.setKeeper(user, true);

        vm.prank(user);
        vm.expectRevert();
        feeVault.compound();
    }

    function test_checkRebalance_uses_strategy_mock_and_gates() public {
        vm.warp(10 days);
        VaultConfig memory cfg = _config();
        cfg.autoRebalance = true;
        Vault rebalanceVault = _newVault(cfg);
        strategy.setRebalance(true, bytes32("DRIFT"));

        (bool needed, bytes32 reason) = rebalanceVault.checkRebalance();
        assertTrue(needed);
        assertEq(reason, bytes32("DRIFT"));

        priceGuard.setTrusted(false);
        (needed, reason) = rebalanceVault.checkRebalance();
        assertFalse(needed);
        assertEq(reason, bytes32("PRICE"));

        priceGuard.setTrusted(true);
        priceGuard.setRevert(true);
        (needed, reason) = rebalanceVault.checkRebalance();
        assertFalse(needed);
        assertEq(reason, bytes32("PRICE"), "a reverting PriceGuard reads as untrusted");
        priceGuard.setRevert(false);
    }

    /**
     * Cooldown (guide 7.4 / 13.3): within 30 minutes of the last rebalance the view reports COOLDOWN; pause and
     * auto-rebalance-off are reported before it.
     */
    function test_checkRebalance_reports_cooldown_pause_and_auto_off() public {
        vm.warp(10 days);
        VaultConfig memory cfg = _config();
        cfg.autoRebalance = true;
        Vault rebalanceVault = _newVault(cfg);
        strategy.setRebalance(true, bytes32("DRIFT"));

        // lastRebalance is the low 64 bits of slot 3 (paused is the next byte).
        vm.store(address(rebalanceVault), bytes32(uint256(3)), bytes32(uint256(block.timestamp - 10)));
        (bool needed, bytes32 reason) = rebalanceVault.checkRebalance();
        assertFalse(needed);
        assertEq(reason, bytes32("COOLDOWN"));
        assertEq(rebalanceVault.lastRebalance(), block.timestamp - 10);

        vm.warp(block.timestamp + 30 minutes - 11);
        (needed, reason) = rebalanceVault.checkRebalance();
        assertEq(reason, bytes32("COOLDOWN"), "one second before the cooldown ends");
        vm.warp(block.timestamp + 1);
        (needed, reason) = rebalanceVault.checkRebalance();
        assertTrue(needed);
        assertEq(reason, bytes32("DRIFT"));

        rebalanceVault.pause();
        (needed, reason) = rebalanceVault.checkRebalance();
        assertEq(reason, bytes32("PAUSED"));

        cfg.autoRebalance = false;
        Vault manualVault = _newVault(cfg);
        (needed, reason) = manualVault.checkRebalance();
        assertFalse(needed);
        assertEq(reason, bytes32("AUTO_OFF"));
    }

    /**
     * A band above the price takes token0 only: the deposit and the compound grant and revoke only the token0
     * Permit2 allowance (the token1 allowance stays zero throughout).
     */
    function test_token0_only_deposit_and_compound_touch_only_the_token0_allowance() public {
        // the mock band is [-120, -60]; a price below it makes the band token0-only
        stateView.setSlot0(SqrtPriceMath.getSqrtPriceAtTick(-200), -200);
        (Vault oneSided, MockFactory factory,) = _newM5Vault(0, 1_000);
        vm.startPrank(user);
        token0.approve(address(oneSided), type(uint256).max);
        (,, uint256 used1) = oneSided.depositPair(100_000 ether, 0, 1, user);
        vm.stopPrank();
        assertEq(used1, 0);

        token0.mint(address(oneSided), 1_000 ether);
        factory.setKeeper(user, true);
        vm.prank(user);
        (uint256 c0, uint256 c1) = oneSided.compound();
        assertGt(c0, 0);
        assertEq(c1, 0);
    }

    function test_withdrawPair_rejects_zero_shares_and_zero_receiver() public {
        (Vault feeVault,,) = _newM5Vault(0, 1_000);
        vm.startPrank(user);
        token1.approve(address(feeVault), type(uint256).max);
        feeVault.depositPair(0, 100_000 ether, 1, user);
        vm.expectRevert(Vault.ZeroValue.selector);
        feeVault.withdrawPair(0, 0, 0, user);
        vm.expectRevert(Vault.ZeroAddress.selector);
        feeVault.withdrawPair(1, 0, 0, address(0));
        vm.stopPrank();
    }

    function test_compound_without_bands_or_with_only_dust_reverts_ZeroLiquidity() public {
        (Vault feeVault, MockFactory factory,) = _newM5Vault(0, 1_000);
        factory.setKeeper(user, true);
        vm.prank(user);
        vm.expectRevert(Vault.ZeroLiquidity.selector);
        feeVault.compound();

        vm.startPrank(user);
        token1.approve(address(feeVault), type(uint256).max);
        feeVault.depositPair(0, 100_000 ether, 1, user);
        vm.stopPrank();
        deal(address(token1), address(feeVault), 1); // below the per-band settlement reserve
        vm.prank(user);
        vm.expectRevert(Vault.ZeroLiquidity.selector);
        feeVault.compound();
    }

    function test_share_transfer_to_zero_reverts() public {
        vm.prank(user);
        vault.depositPair(0, 100_000 ether, 1, user);
        vm.prank(user);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vault.transfer(address(0), 1);
    }

    function test_maxRedeem_is_limited_by_the_owners_own_shares() public {
        vm.prank(user);
        vault.deposit(100_000 ether, user);
        vm.prank(user);
        vault.transfer(receiver, 10);
        assertEq(vault.maxRedeem(receiver), 10, "a small holder can redeem all of their shares");
    }

    function test_maxRedeem_is_limited_by_idle_liquidity_for_a_pair_holder() public {
        vm.prank(user);
        (uint256 shares,,) = vault.depositPair(0, 100_000 ether, 1, user);
        vm.prank(user);
        vault.deposit(10 ether, receiver);
        uint256 limit = vault.maxRedeem(user);
        assertLt(limit, shares, "a pair holder is limited by the idle token1 available");
        assertEq(limit, vault.previewWithdraw(vault.maxWithdraw(user)));
    }

    function test_conversions_return_zero_instead_of_reverting_when_the_vault_value_reads_zero() public {
        stateView.setSlot0(SqrtPriceMath.getSqrtPriceAtTick(-200), -200);
        vm.startPrank(user);
        vault.depositPair(100_000 ether, 0, 1, user); // token0 only
        vm.stopPrank();
        stateView.setSlot0(0, -887272); // a zero price values token0 at nothing
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.convertToShares(1 ether), 0);
        assertEq(vault.previewWithdraw(1 ether), 0);
    }

    /**
     * A zero-asset ERC-4626 deposit passes the `maxDeposit` bound (0 <= 0), so the inner pause and receiver guards
     * must still refuse it.
     */
    function test_zero_asset_deposit_still_checks_receiver_and_pause() public {
        vm.prank(user);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vault.deposit(0, address(0));
        vault.pause();
        vm.prank(user);
        vm.expectRevert(Vault.IsPaused.selector);
        vault.deposit(0, user);
    }

    function test_checkRebalance_bubbles_a_strategy_revert() public {
        vm.warp(10 days);
        VaultConfig memory cfg = _config();
        cfg.autoRebalance = true;
        Vault rebalanceVault = _newVault(cfg);
        vm.mockCallRevert(address(strategy), abi.encodeWithSelector(MockStrategy.checkTrigger.selector), "boom");
        vm.expectRevert(bytes("boom"));
        rebalanceVault.checkRebalance();
    }

    function _newVault(VaultConfig memory cfg) internal returns (Vault newVault) {
        newVault = Vault(payable(Clones.clone(address(implementation))));
        newVault.initialize("Vortex ETH USDC", "vETHUSDC", address(strategy), cfg);
    }

    function _newM5Vault(uint256 feeBps, uint256 maxFeeBps)
        internal
        returns (Vault newVault, MockFactory factory, MockFeeCollector collector)
    {
        collector = new MockFeeCollector(receiver);
        factory = new MockFactory(feeBps, maxFeeBps, address(collector));
        Vault impl = new Vault(
            IPositionManagerLike(address(positionManager)),
            stateView,
            IPermit2Like(address(permit2)),
            priceGuard,
            shapes,
            address(swapExecutor),
            address(factory),
            address(0x4444)
        );
        newVault = Vault(payable(Clones.clone(address(impl))));
        vm.prank(address(factory));
        newVault.initialize("Vortex ETH USDC", "vETHUSDC", address(strategy), _config());
        factory.setVault(address(newVault), true);
    }

    function _config() internal view returns (VaultConfig memory config) {
        config.poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 500,
            tickSpacing: 60,
            hooks: address(0)
        });
        config.strategy = Strategy.NormalLP;
        config.shapeId = 1;
        config.centerTick = -90;
        config.ticksLeft = 30;
        config.ticksRight = 30;
        config.driftTicks = 10;
        config.trailTicks = 0;
        config.autoRebalance = false;
        config.lockOnFill = false;
        config.depositCap = 0;
        config.baseIsCurrency0 = true;
    }

    function _configWithCap(uint256 cap) internal view returns (VaultConfig memory config) {
        config = _config();
        config.depositCap = cap;
    }
}
