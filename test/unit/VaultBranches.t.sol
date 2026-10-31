// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Vault} from "../../src/Vault.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {IShapeLibrary} from "../../src/interfaces/IShapeLibrary.sol";
import {ISwapExecutor} from "../../src/interfaces/ISwapExecutor.sol";
import {IPositionManagerLike} from "../../src/interfaces/external/IPositionManagerLike.sol";
import {IPermit2Like} from "../../src/interfaces/external/IPermit2Like.sol";
import {IStateViewLike} from "../../src/interfaces/external/IStateViewLike.sol";
import {Currency, DepositMode, PoolKey, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {InitializationReentrantToken, MintableToken} from "../mocks/TokenMocks.sol";
import {
    MockPermit2,
    MockVaultStateView,
    MockPositionManager,
    MockVaultPriceGuard,
    MockShapeLibrary,
    MockSwapExecutor,
    MockStrategy
} from "../mocks/VaultMocks.sol";

/**
 * @title Vault validation and edge branches
 * @notice Fast mock-based coverage of every reachable guard: construction, initialization, ERC-20 share edges,
 *         ERC-4626 limits and conversions, deposit-mode and value guards, Permit2 bounds and the NFT callback.
 */
contract VaultBranchesTest is Test {
    address internal user = address(0xA11CE);
    MintableToken internal token0;
    MintableToken internal token1;
    MockPermit2 internal permit2;
    MockVaultStateView internal stateView;
    MockPositionManager internal positionManager;
    MockVaultPriceGuard internal priceGuard;
    MockShapeLibrary internal shapes;
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
        strategy = new MockStrategy();
        implementation = _implementation(address(new MockSwapExecutor()));
        vault = _clone(_config());
        token0.mint(user, type(uint192).max);
        token1.mint(user, type(uint192).max);
        vm.startPrank(user);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Construction and initialization
    // ------------------------------------------------------------------------------------------------------------

    function test_constructor_rejects_every_zero_dependency() public {
        for (uint256 i; i < 7; ++i) {
            address[7] memory deps = [
                address(positionManager),
                address(stateView),
                address(permit2),
                address(priceGuard),
                address(shapes),
                address(this),
                address(0x4444)
            ];
            deps[i] = address(0);
            vm.expectRevert(Vault.ZeroAddress.selector);
            this.deployVault(deps);
        }
    }

    // An expected revert inside a `new` of another file's contract ends the test early (forge deploys it through a
    // cheatcode), so each reverting deployment goes through an external self-call and the checks after it run.
    function deployVault(address[7] memory deps) external returns (Vault) {
        return new Vault(
            IPositionManagerLike(deps[0]),
            IStateViewLike(deps[1]),
            IPermit2Like(deps[2]),
            IPriceGuard(deps[3]),
            IShapeLibrary(deps[4]),
            address(0),
            deps[5],
            deps[6]
        );
    }

    function test_initialize_guards() public {
        Vault fresh = Vault(payable(Clones.clone(address(implementation))));
        vm.prank(user);
        vm.expectRevert(Vault.NotAuthorized.selector);
        fresh.initialize("V", "V", address(strategy), _config());

        vm.expectRevert(Vault.ZeroAddress.selector);
        fresh.initialize("V", "V", address(0), _config());

        VaultConfig memory cfg = _config();
        cfg.poolKey.currency1 = Currency.wrap(address(0));
        vm.expectRevert(Vault.ZeroAddress.selector);
        fresh.initialize("V", "V", address(strategy), cfg);

        cfg = _config();
        cfg.poolKey.hooks = address(0xBEEF);
        vm.expectRevert(Vault.NotAuthorized.selector);
        fresh.initialize("V", "V", address(strategy), cfg);

        fresh.initialize("V", "V", address(strategy), _config());
        vm.expectRevert(Vault.AlreadyInitialized.selector);
        fresh.initialize("V", "V", address(strategy), _config());
    }

    function test_initialize_blocks_token_approval_reentrancy() public {
        Vault fresh = Vault(payable(Clones.clone(address(implementation))));
        InitializationReentrantToken hostileToken = new InitializationReentrantToken();
        hostileToken.arm(address(fresh));
        VaultConfig memory cfg = _config();
        cfg.poolKey.currency0 = Currency.wrap(address(hostileToken));

        fresh.initialize("V", "V", address(strategy), cfg);

        assertTrue(hostileToken.attempted(), "approval callback was not reached");
        assertFalse(hostileToken.reentrySucceeded(), "initialization callback reentered the vault");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Shares as an ERC-20
    // ------------------------------------------------------------------------------------------------------------

    function test_share_transfer_approve_and_zero_address_guards() public {
        vm.prank(user);
        vault.depositPair(100 ether, 100 ether, 0, user);
        vm.startPrank(user);
        assertTrue(vault.transfer(address(0xB0B), 1));
        assertEq(vault.balanceOf(address(0xB0B)), 1);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vault.transfer(address(0), 1);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vault.approve(address(0), 1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------------------
    // ERC-4626 conversions and limits
    // ------------------------------------------------------------------------------------------------------------

    function test_conversions_before_any_deposit() public view {
        assertEq(vault.convertToShares(5_000), 4_000, "first deposit locks 1,000");
        assertEq(vault.convertToShares(500), 0);
        assertEq(vault.convertToAssets(777), 777);
        assertEq(vault.previewMint(10), 1_010);
        assertEq(vault.previewWithdraw(1), 0, "nothing to withdraw from an empty vault");
    }

    function test_cap_reached_closes_asset_deposits() public {
        VaultConfig memory cfg = _config();
        cfg.depositCap = 50_000;
        Vault capped = _clone(cfg);
        vm.startPrank(user);
        token1.approve(address(capped), type(uint256).max);
        capped.deposit(50_000, user);
        assertEq(capped.maxDeposit(user), 0);
        assertEq(capped.maxMint(user), 0);
        vm.expectRevert(Vault.ExceedsMax.selector);
        capped.mint(1, user);
        vm.stopPrank();
    }

    function test_withdraw_and_redeem_guards() public {
        vm.prank(user);
        vault.deposit(100_000, user);
        vm.startPrank(user);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vault.withdraw(1, address(0), user);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vault.redeem(1, address(0), user);
        vm.expectRevert(Vault.ExceedsMax.selector);
        vault.withdraw(type(uint128).max, user, user);
        vm.expectRevert(Vault.ExceedsMax.selector);
        vault.redeem(type(uint128).max, user, user);
        vm.stopPrank();
    }

    function test_max_redeem_is_capped_by_the_owner_balance() public {
        vm.prank(user);
        vault.deposit(100_000, user);
        token1.mint(address(vault), 10 ** 30); // much more idle than the owner's claim
        assertEq(vault.maxRedeem(user), vault.balanceOf(user));
    }

    function test_mint_entry_point() public {
        vm.prank(user);
        vault.deposit(100_000, user);
        uint256 preview = vault.previewMint(1_000);
        vm.prank(user);
        uint256 assets = vault.mint(1_000, user);
        assertEq(assets, preview);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Pair deposit guards
    // ------------------------------------------------------------------------------------------------------------

    function test_both_tokens_mode_rejects_an_empty_deposit() public {
        strategy.setMode(DepositMode.BothTokens);
        vm.prank(user);
        vm.expectRevert(Vault.InvalidDepositMode.selector);
        vault.depositPair(0, 0, 0, user);
    }

    function test_amounts_beyond_uint128_revert_before_position_manager_encoding() public {
        uint256[2] memory sizes = [uint256(type(uint128).max) + 1, uint256(type(uint160).max) + 1];
        for (uint256 i; i < sizes.length; ++i) {
            vm.prank(user);
            vm.expectRevert();
            vault.depositPair(sizes[i], sizes[i], 0, user);
        }
    }

    function test_tiny_deposits_fail_with_zero_liquidity() public {
        vm.prank(user);
        vm.expectRevert(Vault.ZeroLiquidity.selector);
        vault.depositPair(3, 3, 0, user);
    }

    // ------------------------------------------------------------------------------------------------------------
    // NFT callback
    // ------------------------------------------------------------------------------------------------------------

    function test_nft_callback_accepted_only_during_the_vaults_own_call() public {
        positionManager.setSafeMint(true); // the mock now calls onERC721Received while minting
        vm.prank(user);
        vault.depositPair(100 ether, 100 ether, 0, user);
        assertEq(positionManager.ownerOf(1), address(vault));

        vm.prank(address(positionManager)); // right sender, but outside the vault's call
        vm.expectRevert(Vault.UnexpectedNft.selector);
        vault.onERC721Received(address(this), address(0), 99, "");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _implementation(address swapExecutor) internal returns (Vault) {
        return new Vault(
            IPositionManagerLike(address(positionManager)),
            stateView,
            IPermit2Like(address(permit2)),
            priceGuard,
            shapes,
            swapExecutor,
            address(this),
            address(0x4444)
        );
    }

    function _clone(VaultConfig memory cfg) internal returns (Vault v) {
        v = Vault(payable(Clones.clone(address(implementation))));
        v.initialize("Vortex", "VTX", address(strategy), cfg);
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
        config.baseIsCurrency0 = true;
    }
}
