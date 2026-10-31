// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vault} from "../../src/Vault.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {IShapeLibrary} from "../../src/interfaces/IShapeLibrary.sol";
import {ISwapExecutor} from "../../src/interfaces/ISwapExecutor.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {IPositionManagerLike} from "../../src/interfaces/external/IPositionManagerLike.sol";
import {IPermit2Like} from "../../src/interfaces/external/IPermit2Like.sol";
import {IStateViewLike} from "../../src/interfaces/external/IStateViewLike.sol";
import {Band, DepositMode, PoolKey, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {MockSwapExecutor} from "../mocks/VaultMocks.sol";
import {TamperedShapeLibrary} from "./ShapeLibraryAttacks.t.sol";
import {VaultRealV4Base} from "../integration/utils/VaultRealV4Base.sol";

/**
 * @dev Receives a native refund and tries to reenter the vault from `receive`.
 */
contract ReentrantDepositor {
    Vault public immutable vault;
    bool public reentered;
    bool public reentrySucceeded;

    constructor(Vault vault_) {
        vault = vault_;
    }

    function depositTooMuchEth() external payable {
        vault.depositPair{value: msg.value}(msg.value, 30_000e6, 0, address(this));
    }

    function approveUsdc(address usdc) external {
        (bool ok,) = usdc.call(abi.encodeWithSignature("approve(address,uint256)", address(vault), type(uint256).max));
        require(ok);
    }

    receive() external payable {
        if (msg.sender != address(vault) || reentered) return;
        reentered = true;
        try vault.depositPair{value: 1 ether}(1 ether, 3_000e6, 0, address(this)) {
            reentrySucceeded = true;
        } catch {}
    }
}

/**
 * @title Vault control paths against real Uniswap v4
 * @notice Pause roles, withdrawal liveness while paused, refund reentrancy, caps on both deposit paths, strategy
 *         gates, oracle gating of priced exits, and a tampered shape library.
 */
contract VaultRealV4ControlsTest is VaultRealV4Base {
    Vault internal vault;
    PoolKey internal key;
    int24 internal tick;

    function setUp() public override {
        super.setUp();
        implementation = new Vault(
            IPositionManagerLike(address(posm)),
            IStateViewLike(address(stateView)),
            IPermit2Like(address(permit2)),
            IPriceGuard(address(guard)),
            shapes,
            address(new MockSwapExecutor()),
            address(this),
            address(manager)
        );
        key = _nativeUsdcKey();
        tick = _initPool(key, 2000e6, 1e18, false);
        vault = _newVault(key, 0, tick, 4000, 4000);
        _deposit(vault, alice, 10 ether, 30_000e6);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Pause
    // ------------------------------------------------------------------------------------------------------------

    function test_only_guardian_or_factory_can_pause_and_only_timelock_or_factory_can_unpause() public {
        vm.prank(attacker);
        vm.expectRevert(Vault.NotAuthorized.selector);
        vault.pause();

        vm.prank(guardianAccount);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(guardianAccount);
        vm.expectRevert(Vault.NotAuthorized.selector);
        vault.unpause(); // the guardian cannot unpause

        vm.prank(attacker);
        vm.expectRevert(Vault.NotAuthorized.selector);
        vault.unpause();

        vm.prank(timelockAccount);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_pause_blocks_both_deposit_paths_but_never_withdrawals() public {
        vm.prank(bob);
        vault.deposit(10_000e6, bob); // idle USDC that bob can later redeem

        vm.prank(guardianAccount);
        vault.pause();

        vm.prank(bob);
        vm.expectRevert(Vault.IsPaused.selector);
        vault.depositPair{value: 1 ether}(1 ether, 3_000e6, 0, bob);

        assertEq(vault.maxDeposit(bob), 0);
        vm.prank(bob);
        vm.expectRevert(Vault.ExceedsMax.selector);
        vault.deposit(1_000e6, bob);

        uint256 shares = vault.maxRedeem(bob);
        assertGt(shares, 0, "withdrawals stay open while paused");
        vm.prank(bob);
        vault.redeem(shares, bob, bob);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Reentrancy through a native refund
    // ------------------------------------------------------------------------------------------------------------

    function test_a_reentrant_refund_receiver_cannot_reenter() public {
        ReentrantDepositor depositor = new ReentrantDepositor(vault);
        usdc.mint(address(depositor), 1e12);
        depositor.approveUsdc(USDC_ADDR);
        vm.deal(address(this), 1_000 ether);
        depositor.depositTooMuchEth{value: 100 ether}(); // most ETH is refunded, which calls `receive`
        assertTrue(depositor.reentered(), "the refund reached the receiver");
        assertFalse(depositor.reentrySucceeded(), "the reentrant deposit must fail");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Caps
    // ------------------------------------------------------------------------------------------------------------

    function test_deposit_cap_applies_to_both_paths() public {
        Vault capped = Vault(payable(Clones.clone(address(implementation))));
        VaultConfig memory cfg = vault.config();
        cfg.depositCap = 50_000e6; // in token1 units
        capped.initialize("Capped", "CAP", address(strategy), cfg);
        vm.startPrank(alice);
        usdc.approve(address(capped), type(uint256).max);
        capped.depositPair{value: 10 ether}(10 ether, 30_000e6, 0, alice); // about 40k of value
        vm.expectRevert(Vault.DepositCapExceeded.selector);
        capped.depositPair{value: 10 ether}(10 ether, 30_000e6, 0, alice);
        uint256 room = capped.maxDeposit(alice);
        assertLt(room, 15_000e6);
        vm.expectRevert(Vault.ExceedsMax.selector);
        capped.deposit(room + 1, alice);
        capped.deposit(room, alice);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Strategy gates
    // ------------------------------------------------------------------------------------------------------------

    function test_strategy_deposit_modes_are_enforced_on_both_paths() public {
        strategy.setMode(DepositMode.Token0Only);
        assertEq(vault.maxDeposit(bob), 0, "token1 deposits are closed for a token0-only strategy");
        vm.prank(bob);
        vm.expectRevert(Vault.InvalidDepositMode.selector);
        vault.depositPair{value: 1 ether}(1 ether, 3_000e6, 0, bob);

        strategy.setMode(DepositMode.BothTokens);
        strategy.setAllowed(false);
        assertEq(vault.maxDeposit(bob), 0);
        vm.prank(bob);
        vm.expectRevert(Vault.DepositNotAllowed.selector);
        vault.depositPair{value: 1 ether}(1 ether, 3_000e6, 0, bob);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Priced exits need a trusted price
    // ------------------------------------------------------------------------------------------------------------

    function test_priced_exits_close_while_the_oracle_is_stale() public {
        vm.prank(bob);
        vault.deposit(10_000e6, bob);
        vm.warp(block.timestamp + 2 hours); // the feed goes stale
        assertEq(vault.maxRedeem(bob), 0);
        assertEq(vault.maxWithdraw(bob), 0);
        vm.prank(bob);
        vm.expectRevert(Vault.PriceUntrusted.selector);
        vault.redeem(1, bob, bob);
        vm.prank(bob);
        vm.expectRevert(Vault.PriceUntrusted.selector);
        vault.withdraw(1, bob, bob);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Rounding and NFT ownership
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Guide rule 5: shares round down. The minted amount is exactly floor(supply * valueUsed / valueBefore),
     *      with the supplied and refunded values taken at the same pool price. Valuing each side before subtraction
     *      also matches the vault's conservative rounding convention.
     */
    function testFuzz_pair_deposit_shares_are_exactly_the_floor(uint256 amount0, uint256 amount1) public {
        amount0 = bound(amount0, 0.01 ether, 50 ether);
        amount1 = bound(amount1, 10e6, 150_000e6);
        (uint160 sp,,,) = stateView.getSlot0(_poolId(key));
        uint256 valueBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();
        (uint256 shares, uint256 used0, uint256 used1) = _deposit(vault, bob, amount0, amount1);
        uint256 priceX96 = Math.mulDiv(sp, sp, 1 << 96);
        uint256 suppliedValue = Math.mulDiv(amount0, priceX96, 1 << 96) + amount1;
        uint256 refundValue = Math.mulDiv(amount0 - used0, priceX96, 1 << 96) + (amount1 - used1);
        uint256 valueUsed = suppliedValue - refundValue;
        // The depositor is credited with the lesser of what they paid and what the vault's value really grew by
        // (same price, same valuation): Uniswap's round-up and any swap cost stay with the depositor.
        uint256 added = vault.totalAssets() - valueBefore;
        if (added < valueUsed) valueUsed = added;
        assertEq(shares, Math.mulDiv(supplyBefore, valueUsed, valueBefore), "shares must be the exact floor");
    }

    function testFuzz_asset_deposit_shares_are_exactly_the_floor(uint256 assets) public {
        assets = bound(assets, 1e4, 1_000_000e6);
        uint256 valueBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();
        vm.prank(bob);
        uint256 shares = vault.deposit(assets, bob);
        assertEq(shares, Math.mulDiv(supplyBefore, assets, valueBefore));
    }

    /**
     * @dev If the PositionManager minted a band NFT to anyone but the vault (a hostile or mis-encoded owner), the
     *      first deposit must revert instead of recording a position the vault does not own.
     */
    function test_first_deposit_reverts_if_a_band_nft_is_not_owned_by_the_vault() public {
        Vault fresh = _newVault(key, 1, tick, 4000, 4000);
        uint256 nextId = posm.nextTokenId();
        vm.mockCall(address(posm), abi.encodeWithSignature("ownerOf(uint256)", nextId), abi.encode(attacker));
        vm.prank(alice);
        vm.expectRevert(Vault.InvalidPositionOwner.selector);
        fresh.depositPair{value: 1 ether}(1 ether, 3_000e6, 0, alice);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Tampered shape library
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @dev Guide 5.3 and 9.5: the vault re-checks strategy output even when it originated in a tampered shape
     *      calculator. Each tampering must stop the first deposit before any token moves.
     */
    function test_tampered_library_output_is_rejected_before_any_token_moves() public {
        TamperedShapeLibrary tampered = new TamperedShapeLibrary();
        implementation = new Vault(
            IPositionManagerLike(address(posm)),
            IStateViewLike(address(stateView)),
            IPermit2Like(address(permit2)),
            IPriceGuard(address(guard)),
            IShapeLibrary(address(tampered)),
            address(0),
            address(this),
            address(manager)
        );
        // Gap, Overlap, Misaligned, OutOfRange, TooManyBands, WeightsTooLow, WeightsTooHigh, WeightsLengthMismatch,
        // EmptyBand, InvertedBand, NoBands (CarriesTokenId / CarriesLiquidity are overwritten by the vault anyway)
        uint8[11] memory modes = [uint8(1), 2, 3, 4, 5, 6, 7, 8, 9, 10, 13];
        for (uint256 i; i < modes.length; ++i) {
            tampered.setMode(TamperedShapeLibrary.Mode(modes[i]));
            Vault v = _newVault(key, 0, tick, 4000, 4000);
            (Band[] memory maliciousBands, uint16[] memory maliciousWeights) =
                tampered.computeBands(0, tick, 4000, 4000, key.tickSpacing);
            strategy.setPlan(maliciousBands, maliciousWeights, false, false, 0, false);
            uint256 before = usdc.balanceOf(alice);
            vm.prank(alice);
            vm.expectRevert(IVault.InvalidPlan.selector);
            v.depositPair{value: 1 ether}(1 ether, 3_000e6, 0, alice);
            assertEq(usdc.balanceOf(alice), before);
        }
    }
}
