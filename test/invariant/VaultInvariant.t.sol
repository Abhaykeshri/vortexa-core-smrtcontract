// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
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

contract VaultInvariantHandler is Test {
    Vault public vault;
    MintableToken public token1;
    address public user = address(0xBEEF);
    uint256 public totalDeposited;
    uint256 public totalIdleMinted;
    uint256 public totalWithdrawn;

    constructor(Vault vault_, MintableToken token1_) {
        vault = vault_;
        token1 = token1_;
        token1.mint(user, type(uint128).max);
        vm.prank(user);
        token1.approve(address(vault), type(uint256).max);
    }

    function deposit(uint96 rawAssets) external {
        uint256 assets = bound(uint256(rawAssets), 10_000, 1_000_000 ether);
        vm.prank(user);
        try vault.deposit(assets, user) {
            totalDeposited += assets;
        } catch {}
    }

    function withdraw(uint96 rawAssets) external {
        if (vault.balanceOf(user) == 0) return;

        uint256 idleTopUp = 1_000 ether;
        token1.mint(address(vault), idleTopUp);
        totalIdleMinted += idleTopUp;

        uint256 maxAssets = vault.maxWithdraw(user);
        if (maxAssets == 0) return;

        uint256 assets = bound(uint256(rawAssets), 1, maxAssets);
        vm.prank(user);
        try vault.withdraw(assets, user, user) {
            totalWithdrawn += assets;
        } catch {}
    }
}

contract VaultInvariantTest is StdInvariant, Test {
    Vault internal vault;
    MintableToken internal token1;
    VaultInvariantHandler internal handler;

    function setUp() public {
        MintableToken token0 = new MintableToken();
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
        vault.initialize("Vortex", "vVTX", address(new MockStrategy()), _config(token0, token1));
        handler = new VaultInvariantHandler(vault, token1);
        targetContract(address(handler));
    }

    function invariant_total_supply_equals_user_plus_locked_shares() public view {
        assertEq(
            vault.totalSupply(),
            vault.balanceOf(handler.user()) + vault.balanceOf(0x000000000000000000000000000000000000dEaD)
        );
    }

    function invariant_successful_deposits_create_nonzero_assets() public view {
        if (handler.totalDeposited() > 0) assertGt(vault.totalAssets(), 0);
    }

    function invariant_withdrawals_never_exceed_funded_value() public view {
        assertLe(handler.totalWithdrawn(), handler.totalDeposited() + handler.totalIdleMinted());
    }

    function invariant_max_withdraw_is_idle_asset_bounded() public view {
        assertLe(vault.maxWithdraw(handler.user()), token1.balanceOf(address(vault)));
    }

    function _config(MintableToken token0, MintableToken token1_) internal pure returns (VaultConfig memory config) {
        config.poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1_)),
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
