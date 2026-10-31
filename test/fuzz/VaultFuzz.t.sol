// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/Vault.sol";
import {IPermit2Like} from "../../src/interfaces/external/IPermit2Like.sol";
import {IPositionManagerLike} from "../../src/interfaces/external/IPositionManagerLike.sol";
import {Currency, PoolKey, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {MintableToken} from "../mocks/TokenMocks.sol";
import {
    MockPermit2,
    MockPositionManager,
    MockShapeLibrary,
    MockStrategy,
    MockSwapExecutor,
    MockVaultPriceGuard,
    MockVaultStateView
} from "../mocks/VaultMocks.sol";

contract VaultFuzzTest is Test {
    address internal user = address(0xA11CE);
    address internal receiver = address(0xB0B);
    MintableToken internal token0;
    MintableToken internal token1;
    Vault internal vault;

    function setUp() public {
        token0 = new MintableToken();
        token1 = new MintableToken();
        MockPermit2 permit2 = new MockPermit2();
        MockVaultStateView stateView = new MockVaultStateView();
        MockPositionManager positionManager = new MockPositionManager(permit2, stateView);
        Vault implementation = new Vault(
            IPositionManagerLike(address(positionManager)),
            stateView,
            IPermit2Like(address(permit2)),
            new MockVaultPriceGuard(),
            new MockShapeLibrary(),
            address(new MockSwapExecutor()),
            address(this),
            address(0x4444)
        );
        vault = Vault(payable(Clones.clone(address(implementation))));
        vault.initialize("Vortex", "vVTX", address(new MockStrategy()), _config());
        token1.mint(user, type(uint128).max);
        vm.prank(user);
        token1.approve(address(vault), type(uint256).max);
    }

    function testFuzz_erc4626_previewDeposit_never_overstates_assets(uint96 rawAssets) public view {
        uint256 assets = bound(uint256(rawAssets), 10_000, 1_000_000 ether);
        uint256 shares = vault.previewDeposit(assets);
        assertLe(vault.previewRedeem(shares), assets);
    }

    function testFuzz_deposit_mints_no_more_than_preview(uint96 rawAssets) public {
        uint256 assets = bound(uint256(rawAssets), 10_000, 1_000_000 ether);
        uint256 preview = vault.previewDeposit(assets);
        vm.prank(user);
        uint256 minted = vault.deposit(assets, user);
        assertEq(minted, preview);
    }

    function testFuzz_withdraw_burns_previewed_shares_and_transfers_idle_assets(uint96 rawDeposit, uint96 rawWithdraw)
        public
    {
        uint256 depositAssets = bound(uint256(rawDeposit), 100_000, 1_000_000 ether);
        vm.prank(user);
        vault.deposit(depositAssets, user);

        uint256 idleAssets = depositAssets / 4;
        token1.mint(address(vault), idleAssets);
        uint256 assets = bound(uint256(rawWithdraw), 1, idleAssets);
        uint256 previewShares = vault.previewWithdraw(assets);
        uint256 supplyBefore = vault.totalSupply();
        uint256 userSharesBefore = vault.balanceOf(user);

        vm.prank(user);
        uint256 burned = vault.withdraw(assets, receiver, user);

        assertEq(burned, previewShares);
        assertEq(token1.balanceOf(receiver), assets);
        assertEq(vault.totalSupply(), supplyBefore - burned);
        assertEq(vault.balanceOf(user), userSharesBefore - burned);
    }

    function testFuzz_redeem_returns_previewed_idle_assets(uint96 rawDeposit, uint96 rawRedeem) public {
        uint256 depositAssets = bound(uint256(rawDeposit), 100_000, 1_000_000 ether);
        vm.prank(user);
        uint256 minted = vault.deposit(depositAssets, user);

        uint256 idleAssets = depositAssets / 4;
        token1.mint(address(vault), idleAssets);
        uint256 shares = bound(uint256(rawRedeem), 1, vault.maxRedeem(user));
        uint256 previewAssets = vault.previewRedeem(shares);
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(user);
        uint256 assets = vault.redeem(shares, receiver, user);

        assertEq(assets, previewAssets);
        assertEq(token1.balanceOf(receiver), assets);
        assertEq(vault.totalSupply(), supplyBefore - shares);
        assertEq(vault.balanceOf(user), minted - shares);
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
}
