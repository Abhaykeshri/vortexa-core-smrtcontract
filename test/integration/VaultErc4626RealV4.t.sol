// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Vault} from "../../src/Vault.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {ISwapExecutor} from "../../src/interfaces/ISwapExecutor.sol";
import {IPositionManagerLike} from "../../src/interfaces/external/IPositionManagerLike.sol";
import {IPermit2Like} from "../../src/interfaces/external/IPermit2Like.sol";
import {IStateViewLike} from "../../src/interfaces/external/IStateViewLike.sol";
import {PoolKey, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {MockSwapExecutor} from "../mocks/VaultMocks.sol";
import {VaultRealV4Base} from "./utils/VaultRealV4Base.sol";

/**
 * @title ERC-4626 conformance against real Uniswap v4
 * @notice EIP-4626 requires: `deposit(assets)` succeeds for any `assets <= maxDeposit(receiver)`; `previewDeposit`
 *         never overstates the shares minted; `previewMint` never understates the assets taken; the `max*` views
 *         never revert. The vault is an in-range Normal LP vault on the native ETH/USDC pool, `asset()` = USDC.
 */
contract VaultErc4626RealV4Test is VaultRealV4Base {
    Vault internal vault;
    PoolKey internal key;

    function setUp() public override {
        super.setUp();
        // an implementation with a (mock) swap executor, so the ERC-4626 entry points are switched on
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
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        vault = _newVault(key, 0, tick, 4000, 4000);
        _deposit(vault, alice, 10 ether, 30_000e6); // an existing LP position
    }

    function testFuzz_deposit_succeeds_up_to_maxDeposit_and_mints_at_least_the_preview(uint256 assets) public {
        uint256 max = vault.maxDeposit(bob);
        if (max == 0) return;
        assets = bound(assets, 1e4, max < 1e15 ? max : 1e15);
        uint256 preview = vault.previewDeposit(assets);
        vm.prank(bob);
        uint256 shares = vault.deposit(assets, bob);
        assertGe(shares, preview, "previewDeposit must not overstate the shares minted");
    }

    function testFuzz_mint_takes_at_most_the_preview(uint256 shares) public {
        if (vault.maxMint(bob) == 0) return;
        shares = bound(shares, 1e3, 1e12);
        uint256 preview = vault.previewMint(shares);
        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 assets = vault.mint(shares, bob);
        assertLe(before - usdc.balanceOf(bob), preview, "previewMint must not understate the assets taken");
        assertGe(vault.balanceOf(bob), shares);
        assertLe(assets, preview);
    }

    function test_max_views_never_revert_even_without_an_oracle_configuration() public {
        // a vault on a pool PriceGuard has never heard of: isPriceTrusted reverts with NoConfig
        PoolKey memory other = PoolKey(key.currency0, key.currency1, 3000, 60, address(0));
        manager.initialize(_v4(other), guard.sqrtFromRatio(2000e6, 1e18));
        Vault unconfigured = _newVault(other, 0, 0, 600, 600);
        unconfigured.maxDeposit(bob);
        unconfigured.maxMint(bob);
        unconfigured.maxWithdraw(bob);
        unconfigured.maxRedeem(bob);
    }
}
