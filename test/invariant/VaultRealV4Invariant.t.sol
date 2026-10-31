// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vault} from "../../src/Vault.sol";
import {Band, PoolKey, VaultConfig} from "../../src/libraries/Types.sol";
import {VaultRealV4Base} from "../integration/utils/VaultRealV4Base.sol";

/**
 * @title Vault handler on real Uniswap v4
 * @notice Random deposits (pair and ERC-4626), redemptions, fee-generating swaps, donations, forced ETH, time and
 *         pause attempts against one vault on the native ETH/USDC pool. Per-operation checks are recorded as ghost
 *         counters, which the invariants require to stay at zero.
 */
contract VaultRealV4Handler is VaultRealV4Base {
    Vault public vault;
    PoolKey internal _key;
    address[] internal _actors;
    bytes32 public configHash;

    uint256 public overpaidDeposits; // a depositor received shares worth more than they paid (beyond rounding)
    uint256 public unauthorizedPauses;
    uint256 public successfulPairDeposits;
    uint256 public successfulAssetDeposits;
    uint256 public successfulRedeems;
    uint256 public forcedEth;

    constructor() {
        setUp();
        _key = _nativeUsdcKey();
        int24 tick = _initPool(_key, 2000e6, 1e18, false);
        _seedExternalLiquidity(_key, tick, 1e15);
        vault = _newVault(_key, 0, tick, 6000, 6000);
        _actors.push(alice);
        _actors.push(bob);
        _actors.push(attacker);
        configHash = keccak256(abi.encode(vault.config()));
        _deposit(vault, alice, 50 ether, 150_000e6);
    }

    function realLiquidity(Band memory b) external view returns (uint128 liquidity) {
        (liquidity,,) =
            stateView.getPositionInfo(_poolId(_key), address(posm), b.tickLower, b.tickUpper, bytes32(b.tokenId));
    }

    function usdcBalanceOf(address who) external view returns (uint256) {
        return usdc.balanceOf(who);
    }

    function posmAddress() external view returns (address) {
        return address(posm);
    }

    function permit2Allowance(address owner_) external view returns (uint160 amount, uint48 expiration, uint48 nonce) {
        (uint160 a0,,) = permit2.allowance(owner_, USDC_ADDR, address(posm));
        return (a0, 0, 0);
    }

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    function depositPair(uint256 who, uint256 amount0, uint256 amount1) external {
        address actor = _actors[who % _actors.length];
        amount0 = bound(amount0, 1e12, 200 ether);
        amount1 = bound(amount1, 1e4, 600_000e6);
        (uint160 sp,,,) = stateView.getSlot0(_poolId(_key));
        uint256 navBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();
        vm.prank(actor);
        try vault.depositPair{value: amount0}(amount0, amount1, 0, actor) returns (
            uint256 shares, uint256 u0, uint256 u1
        ) {
            successfulPairDeposits++;
            uint256 paid = Math.mulDiv(u0, Math.mulDiv(sp, sp, 1 << 96), 1 << 96) + u1;
            uint256 worth = Math.mulDiv(shares, navBefore + paid, supplyBefore + shares);
            if (worth > paid + 2) overpaidDeposits++;
        } catch {}
    }

    function depositAsset(uint256 who, uint256 assets) external {
        address actor = _actors[who % _actors.length];
        assets = bound(assets, 1e4, 600_000e6);
        uint256 navBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();
        vm.prank(actor);
        try vault.deposit(assets, actor) returns (uint256 shares) {
            successfulAssetDeposits++;
            uint256 worth = Math.mulDiv(shares, navBefore + assets, supplyBefore + shares);
            if (worth > assets + 1) overpaidDeposits++;
        } catch {}
    }

    function redeem(uint256 who, uint256 fraction) external {
        address actor = _actors[who % _actors.length];
        uint256 shares = Math.mulDiv(vault.maxRedeem(actor), bound(fraction, 1, 10_000), 10_000);
        if (shares == 0) return;
        vm.prank(actor);
        try vault.redeem(shares, actor, actor) returns (uint256) {
            successfulRedeems++;
        } catch {}
    }

    function swapNoise(bool zeroForOne, uint256 size) external {
        if (zeroForOne) _swap(attacker, _key, true, bound(size, 0.01 ether, 20 ether));
        else _swap(attacker, _key, false, bound(size, 20e6, 40_000e6));
        _syncOracleToNativePool(_key); // keep the oracle following the market so activity can continue
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 10_000e6);
        vm.prank(attacker);
        usdc.transfer(address(vault), amount);
    }

    function forceEthIntoPositionManager(uint256 amount) external {
        amount = bound(amount, 1, 1 ether);
        vm.deal(address(posm), address(posm).balance + amount);
        forcedEth += amount;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 30 minutes));
        _syncOracleToNativePool(_key);
    }

    function pauseAttempt(uint256 who, bool doPause) external {
        address[4] memory callers = [guardianAccount, timelockAccount, attacker, alice];
        address caller = callers[who % 4];
        bool allowed = doPause ? (caller == guardianAccount || caller == timelockAccount) : caller == timelockAccount;
        vm.prank(caller);
        if (doPause) {
            try vault.pause() {
                if (!allowed && caller != guardianAccount) unauthorizedPauses++;
            } catch {}
        } else {
            try vault.unpause() {
                if (!allowed) unauthorizedPauses++;
            } catch {}
        }
    }
}

/**
 * forge-config: default.invariant.runs = 256
 * forge-config: default.invariant.depth = 64
 * forge-config: ci.invariant.runs = 1000
 * forge-config: ci.invariant.depth = 128
 */
contract VaultRealV4InvariantTest is StdInvariant {
    VaultRealV4Handler internal handler;
    Vault internal vault;

    function setUp() public {
        handler = new VaultRealV4Handler();
        vault = handler.vault();
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = VaultRealV4Handler.depositPair.selector;
        selectors[1] = VaultRealV4Handler.depositAsset.selector;
        selectors[2] = VaultRealV4Handler.redeem.selector;
        selectors[3] = VaultRealV4Handler.swapNoise.selector;
        selectors[4] = VaultRealV4Handler.donate.selector;
        selectors[5] = VaultRealV4Handler.forceEthIntoPositionManager.selector;
        selectors[6] = VaultRealV4Handler.warp.selector;
        selectors[7] = VaultRealV4Handler.pauseAttempt.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /**
     * Sanity: the handler really reaches successful deposits of both kinds and redemptions.
     */
    function test_handler_reaches_successful_deposits_and_redemptions() public {
        handler.depositPair(1, 2 ether, 6_000e6);
        handler.depositAsset(2, 5_000e6);
        handler.donate(1_000e6);
        handler.redeem(2, 10_000);
        handler.swapNoise(true, 1 ether);
        handler.depositPair(0, 1 ether, 3_000e6);
        require(handler.successfulPairDeposits() == 2, "pair deposits must succeed");
        require(handler.successfulAssetDeposits() == 1, "asset deposit must succeed");
        require(handler.successfulRedeems() == 1, "redeem must succeed");
        require(handler.overpaidDeposits() == 0);
    }

    function invariant_no_depositor_is_overpaid() public view {
        require(handler.overpaidDeposits() == 0, "a depositor received shares worth more than they paid");
    }

    function invariant_only_the_guardian_or_timelock_can_pause_and_only_the_timelock_can_unpause() public view {
        require(handler.unauthorizedPauses() == 0, "unauthorized pause or unpause succeeded");
    }

    function invariant_vault_owns_exactly_its_bands_and_stored_liquidity_is_real() public view {
        Band[] memory b = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            require(_posm().ownerOf(b[i].tokenId) == address(vault), "band NFT not owned by the vault");
            require(handler.realLiquidity(b[i]) == b[i].liquidity, "stored liquidity differs from the real position");
        }
        require(_posm().balanceOf(address(vault)) == b.length, "the vault holds an NFT it does not account for");
    }

    function invariant_position_manager_keeps_nothing_of_the_vault() public view {
        require(handler.usdcBalanceOf(address(_posm())) == 0, "PositionManager kept USDC");
        require(address(_posm()).balance <= handler.forcedEth(), "PositionManager kept ETH sent by the vault");
    }

    function invariant_no_standing_permit2_allowance() public view {
        (uint160 amount,,) = handler.permit2Allowance(address(vault));
        require(amount == 0, "a Permit2 allowance to the PositionManager was left standing");
    }

    function invariant_config_never_changes() public view {
        require(keccak256(abi.encode(vault.config())) == handler.configHash(), "config changed");
    }

    function invariant_share_supply_is_conserved() public view {
        address[] memory a = handler.actors();
        uint256 sum = vault.balanceOf(0x000000000000000000000000000000000000dEaD);
        for (uint256 i; i < a.length; ++i) {
            sum += vault.balanceOf(a[i]);
        }
        require(sum == vault.totalSupply(), "shares appeared or vanished");
    }

    function _posm() internal view returns (PosmView) {
        return PosmView(handler.posmAddress());
    }
}

interface PosmView {
    function ownerOf(uint256 id) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
}
