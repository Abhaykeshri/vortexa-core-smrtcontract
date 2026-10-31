// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Test} from "forge-std/Test.sol";
import {Vault} from "../../src/Vault.sol";
import {IPermit2Like} from "../../src/interfaces/external/IPermit2Like.sol";
import {IPositionManagerLike} from "../../src/interfaces/external/IPositionManagerLike.sol";
import {Currency, PoolKey, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {FeeOnTransferToken, MintableToken} from "../mocks/TokenMocks.sol";
import {
    MockPermit2,
    MockPositionManager,
    MockShapeLibrary,
    MockStrategy,
    MockSwapExecutor,
    MockVaultPriceGuard,
    MockVaultStateView
} from "../mocks/VaultMocks.sol";

contract VaultAttacksTest is Test {
    address internal user = address(0xA11CE);
    MintableToken internal token0;
    MintableToken internal token1;
    MockVaultPriceGuard internal priceGuard;
    MockStrategy internal strategy;
    Vault internal implementation;
    Vault internal vault;

    function setUp() public {
        token0 = new MintableToken();
        token1 = new MintableToken();
        MockPermit2 permit2 = new MockPermit2();
        MockVaultStateView stateView = new MockVaultStateView();
        MockPositionManager positionManager = new MockPositionManager(permit2, stateView);
        priceGuard = new MockVaultPriceGuard();
        strategy = new MockStrategy();
        implementation = new Vault(
            IPositionManagerLike(address(positionManager)),
            stateView,
            IPermit2Like(address(permit2)),
            priceGuard,
            new MockShapeLibrary(),
            address(new MockSwapExecutor()),
            address(this),
            address(0x4444)
        );
        vault = _newVault(_config(address(token1)));
        token0.mint(user, 1_000_000 ether);
        token1.mint(user, 1_000_000 ether);
        vm.startPrank(user);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function test_flash_manipulation_guard_blocks_deposit() public {
        priceGuard.setTrusted(false);

        vm.prank(user);
        vm.expectRevert(Vault.PriceUntrusted.selector);
        vault.depositPair(0, 100_000 ether, 1, user);
    }

    function test_fee_on_transfer_asset_cannot_sneak_value_shortfall() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        feeToken.mint(user, 1_000_000 ether);
        Vault feeVault = _newVault(_config(address(feeToken)));

        vm.startPrank(user);
        feeToken.approve(address(feeVault), type(uint256).max);
        vm.expectRevert(Vault.TokenTransferShortfall.selector);
        feeVault.depositPair(0, 100_000 ether, 1, user);
        vm.stopPrank();
    }

    function test_unsolicited_native_eth_is_rejected() public {
        vm.deal(user, 1 ether);

        vm.prank(user);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_zero_receiver_cannot_burn_refunds_or_shares() public {
        vm.prank(user);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vault.depositPair(0, 100_000 ether, 1, address(0));
    }

    function _newVault(VaultConfig memory cfg) internal returns (Vault newVault) {
        newVault = Vault(payable(Clones.clone(address(implementation))));
        newVault.initialize("Vortex", "vVTX", address(strategy), cfg);
    }

    function _config(address asset) internal view returns (VaultConfig memory config) {
        config.poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(asset),
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
