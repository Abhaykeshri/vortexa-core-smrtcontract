// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/Vault.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {IPermit2Like} from "../../src/interfaces/external/IPermit2Like.sol";
import {IPositionManagerLike} from "../../src/interfaces/external/IPositionManagerLike.sol";
import {Band, Currency, PoolKey, RebalanceParams, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {MintableToken} from "../mocks/TokenMocks.sol";
import {
    MockFactory,
    MockFeeCollector,
    MockPermit2,
    MockPositionManager,
    MockShapeLibrary,
    MockStrategy,
    MockSwapExecutor,
    MockVaultPriceGuard,
    MockVaultStateView
} from "../mocks/VaultMocks.sol";

contract VaultM6Test is Test {
    address internal keeper = address(0xBEEF);
    address internal user = address(0xA11CE);
    MintableToken internal token0;
    MintableToken internal token1;
    MockPermit2 internal permit2;
    MockVaultStateView internal stateView;
    MockPositionManager internal positionManager;
    MockVaultPriceGuard internal priceGuard;
    MockStrategy internal strategy;
    MockFactory internal factory;
    MockFeeCollector internal collector;
    MockSwapExecutor internal executor;
    Vault internal implementation;
    Vault internal vault;

    function setUp() public virtual {
        token0 = new MintableToken();
        token1 = new MintableToken();
        permit2 = new MockPermit2();
        stateView = new MockVaultStateView();
        positionManager = new MockPositionManager(permit2, stateView);
        priceGuard = new MockVaultPriceGuard();
        strategy = new MockStrategy();
        executor = new MockSwapExecutor();
        collector = new MockFeeCollector(address(this));
        factory = new MockFactory(500, 1_000, address(collector));
        implementation = new Vault(
            IPositionManagerLike(address(positionManager)),
            stateView,
            IPermit2Like(address(permit2)),
            priceGuard,
            new MockShapeLibrary(),
            address(executor),
            address(factory),
            address(0x4444)
        );
        vault = Vault(payable(Clones.clone(address(implementation))));
        vm.prank(address(factory));
        vault.initialize("M6 Vault", "M6", address(strategy), _config(Strategy.NormalLP, true, false));
        factory.setVault(address(vault), true);
        factory.setKeeper(keeper, true);

        token1.mint(user, 100_000 ether);
        vm.startPrank(user);
        token1.approve(address(vault), type(uint256).max);
        vault.depositPair(0, 100_000 ether, 1, user);
        vm.stopPrank();
        strategy.setRebalance(true, bytes32("DRIFT"));
        _setSingleBandPlan(-60, 0);
        vm.warp(30 minutes);
    }

    function test_rebalance_burns_old_nft_mints_new_nft_and_preserves_supply() public {
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(keeper);
        vault.rebalance(RebalanceParams({newCenterTick: 0, maxSlippageBps: 100}));

        Band[] memory active = vault.bands();
        assertEq(active.length, 1);
        assertEq(active[0].tokenId, 2);
        assertEq(positionManager.ownerOf(1), address(0));
        assertEq(positionManager.ownerOf(2), address(vault));
        assertEq(vault.totalSupply(), supplyBefore);
        assertEq(vault.lastRebalance(), block.timestamp);
        assertFalse(vault.filled());
    }

    function test_rebalance_gates_keeper_pause_trigger_center_and_slippage() public {
        vm.expectRevert(IVault.NotKeeper.selector);
        vault.rebalance(RebalanceParams({newCenterTick: 0, maxSlippageBps: 100}));

        vault.pause();
        vm.prank(keeper);
        vm.expectRevert(Vault.IsPaused.selector);
        vault.rebalance(RebalanceParams({newCenterTick: 0, maxSlippageBps: 100}));
        vault.unpause();

        strategy.setRebalance(false, bytes32(0));
        vm.prank(keeper);
        vm.expectRevert(IVault.NothingToDo.selector);
        vault.rebalance(RebalanceParams({newCenterTick: 0, maxSlippageBps: 100}));
        strategy.setRebalance(true, bytes32("DRIFT"));

        vm.prank(keeper);
        vm.expectRevert(IVault.CenterTooFar.selector);
        vault.rebalance(RebalanceParams({newCenterTick: 201, maxSlippageBps: 100}));

        vm.prank(keeper);
        vm.expectRevert(IVault.SlippageTooHigh.selector);
        vault.rebalance(RebalanceParams({newCenterTick: 0, maxSlippageBps: 101}));
    }

    function test_invalid_plan_reverts_atomically_without_orphaning_old_nft() public {
        Band[] memory malformed = new Band[](1);
        malformed[0] = Band({tickLower: -59, tickUpper: 0, tokenId: 0, liquidity: 0});
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        strategy.setPlan(malformed, weights, false, false, 0, false);

        vm.prank(keeper);
        vm.expectRevert(IVault.InvalidPlan.selector);
        vault.rebalance(RebalanceParams({newCenterTick: 0, maxSlippageBps: 100}));

        Band[] memory active = vault.bands();
        assertEq(active[0].tokenId, 1);
        assertEq(positionManager.ownerOf(1), address(vault));
        assertEq(vault.lastRebalance(), 0);
    }

    function test_cooldown_blocks_second_rebalance() public {
        vm.prank(keeper);
        vault.rebalance(RebalanceParams({newCenterTick: 0, maxSlippageBps: 100}));

        vm.prank(keeper);
        vm.expectRevert(IVault.CooldownActive.selector);
        vault.rebalance(RebalanceParams({newCenterTick: 0, maxSlippageBps: 100}));
    }

    function test_untrusted_price_and_auto_rebalance_off_revert_before_position_changes() public {
        priceGuard.setTrusted(false);
        vm.prank(keeper);
        vm.expectRevert(Vault.PriceUntrusted.selector);
        vault.rebalance(RebalanceParams({newCenterTick: 0, maxSlippageBps: 100}));
        priceGuard.setTrusted(true);

        Vault disabled = _newVault(_config(Strategy.NormalLP, false, false));
        vm.prank(keeper);
        vm.expectRevert(IVault.AutoRebalanceOff.selector);
        disabled.rebalance(RebalanceParams({newCenterTick: 0, maxSlippageBps: 100}));
    }

    /**
     * M7 audit: PriceGuard trust is re-checked after the burn and fee callbacks. A price that stops being trusted
     * while the old positions are burned reverts the whole rebalance and the old position stays in place.
     */
    function test_trust_is_rechecked_after_the_burn_and_fee_callbacks() public {
        bytes[] memory answers = new bytes[](2);
        answers[0] = abi.encode(true, uint256(0));
        answers[1] = abi.encode(false, type(uint256).max);
        vm.mockCalls(address(priceGuard), abi.encodeWithSelector(MockVaultPriceGuard.isPriceTrusted.selector), answers);
        uint256 tokenId = vault.bands()[0].tokenId;

        vm.prank(keeper);
        vm.expectRevert(Vault.PriceUntrusted.selector);
        vault.rebalance(RebalanceParams({newCenterTick: 0, maxSlippageBps: 100}));
        assertEq(vault.bands()[0].tokenId, tokenId);
        assertEq(positionManager.ownerOf(tokenId), address(vault));
    }

    function test_swap_size_cap_uses_input_value_and_rolls_back_burn() public {
        Band[] memory target = new Band[](1);
        target[0] = Band({tickLower: -60, tickUpper: 0, tokenId: 0, liquidity: 0});
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        strategy.setPlan(target, weights, true, false, 70_000 ether, false);

        vm.prank(keeper);
        vm.expectRevert(IVault.SwapTooLarge.selector);
        vault.rebalance(RebalanceParams({newCenterTick: 0, maxSlippageBps: 100}));

        assertEq(positionManager.ownerOf(1), address(vault));
        assertEq(vault.bands()[0].tokenId, 1);
    }

    function test_lock_idle_removes_positions_sets_filled_and_keeps_withdrawals_open() public {
        Vault locked = _newVault(_config(Strategy.BuyTheDip, true, true));
        token1.mint(user, 100_000 ether);
        vm.startPrank(user);
        token1.approve(address(locked), type(uint256).max);
        locked.depositPair(0, 100_000 ether, 1, user);
        vm.stopPrank();
        Band[] memory noBands = new Band[](0);
        uint16[] memory noWeights = new uint16[](0);
        strategy.setPlan(noBands, noWeights, false, false, 0, true);

        vm.prank(keeper);
        locked.rebalance(RebalanceParams({newCenterTick: 0, maxSlippageBps: 100}));

        assertTrue(locked.filled());
        assertEq(locked.bands().length, 0);
        assertEq(locked.maxDeposit(user), 0);
        vm.prank(user);
        vm.expectRevert(Vault.DepositNotAllowed.selector);
        locked.depositPair(0, 1 ether, 1, user);
        uint256 shares = locked.balanceOf(user);
        vm.prank(user);
        (, uint256 amount1) = locked.withdrawPair(shares, 0, 1, user);
        assertGt(amount1, 0);
    }

    function test_rebalance_protocol_fee_is_deducted_only_from_pending_fees() public {
        Band[] memory active = vault.bands();
        uint128 liquidity = active[0].liquidity;
        uint256 growth = (uint256(1_000 ether) << 128) / liquidity;
        uint256 pending = uint256(liquidity) * growth / (uint256(1) << 128);
        token0.mint(address(positionManager), pending);
        stateView.setFees(growth, 0);
        uint256 expectedProtocolFee = pending * 500 / 10_000;

        vm.prank(keeper);
        vault.rebalance(RebalanceParams({newCenterTick: 0, maxSlippageBps: 100}));

        assertEq(token0.balanceOf(address(collector)), expectedProtocolFee);
        assertGt(token1.balanceOf(address(positionManager)), 0, "principal was re-deployed, not charged as fee");
    }

    function test_rebalance_executes_bounded_swap_and_mints_without_changing_shares() public {
        Band[] memory target = new Band[](1);
        target[0] = Band({tickLower: -60, tickUpper: 60, tokenId: 0, liquidity: 0});
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        uint256 swapAmount = 50_000 ether;
        strategy.setPlan(target, weights, true, false, swapAmount, false);
        executor.setExecuteTransfers(true);
        token0.mint(address(executor), swapAmount);
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(keeper);
        vault.rebalance(RebalanceParams({newCenterTick: 0, maxSlippageBps: 100}));

        assertEq(token1.balanceOf(address(executor)), swapAmount);
        assertEq(vault.totalSupply(), supplyBefore);
        assertEq(positionManager.ownerOf(vault.bands()[0].tokenId), address(vault));
    }

    function test_plan_with_nonzero_position_state_or_wrong_weights_is_rejected() public {
        Band[] memory target = new Band[](1);
        target[0] = Band({tickLower: -60, tickUpper: 0, tokenId: 99, liquidity: 1});
        uint16[] memory weights = new uint16[](1);
        weights[0] = 9_999;
        strategy.setPlan(target, weights, false, false, 0, false);

        vm.prank(keeper);
        vm.expectRevert(IVault.InvalidPlan.selector);
        vault.rebalance(RebalanceParams({newCenterTick: 0, maxSlippageBps: 100}));
        assertEq(positionManager.ownerOf(1), address(vault));
    }

    function test_final_oracle_value_brake_reverts_the_entire_swap_and_position_lifecycle() public {
        Band[] memory target = new Band[](1);
        target[0] = Band({tickLower: -60, tickUpper: 60, tokenId: 0, liquidity: 0});
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        strategy.setPlan(target, weights, true, false, 50_000 ether, false);
        executor.setExecuteTransfers(true);
        executor.setConfiguredOutput(40_000 ether);
        token0.mint(address(executor), 40_000 ether);

        vm.prank(keeper);
        vm.expectRevert(IVault.LossTooLarge.selector);
        vault.rebalance(RebalanceParams({newCenterTick: 0, maxSlippageBps: 100}));

        assertEq(positionManager.ownerOf(1), address(vault));
        assertEq(vault.bands()[0].tokenId, 1);
        assertEq(token0.balanceOf(address(executor)), 40_000 ether);
        assertEq(token1.balanceOf(address(executor)), 0);
    }

    function _setSingleBandPlan(int24 lower, int24 upper) internal {
        Band[] memory target = new Band[](1);
        target[0] = Band({tickLower: lower, tickUpper: upper, tokenId: 0, liquidity: 0});
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        strategy.setPlan(target, weights, false, false, 0, false);
    }

    function _newVault(VaultConfig memory config) internal returns (Vault newVault) {
        newVault = Vault(payable(Clones.clone(address(implementation))));
        vm.prank(address(factory));
        newVault.initialize("M6 Vault", "M6", address(strategy), config);
        factory.setVault(address(newVault), true);
    }

    function _config(Strategy kind, bool autoRebalance, bool lockOnFill)
        internal
        view
        returns (VaultConfig memory config)
    {
        config.poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 500,
            tickSpacing: 60,
            hooks: address(0)
        });
        config.strategy = kind;
        config.shapeId = 1;
        config.centerTick = -90;
        config.ticksLeft = 30;
        config.ticksRight = 30;
        config.driftTicks = 10;
        config.autoRebalance = autoRebalance;
        config.lockOnFill = lockOnFill;
        config.baseIsCurrency0 = true;
    }
}
