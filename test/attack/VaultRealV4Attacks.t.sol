// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "uni-test/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest as import_PoolSwapTest} from "uni-test/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey as import_V4PoolKey} from "uni-test/v4-core/src/types/PoolKey.sol";
import {Vault} from "../../src/Vault.sol";
import {Band, Currency, DepositMode, PoolKey} from "../../src/libraries/Types.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {PosmActions} from "../../src/libraries/PosmActions.sol";
import {VaultRealV4Base} from "../integration/utils/VaultRealV4Base.sol";

/**
 * @title Vault attacks against real Uniswap v4
 * @notice Every test states the behaviour the developer guide requires and drives the vault through the real v4
 *         PoolManager, PositionManager and StateView. A failure is a vault defect.
 */
contract VaultRealV4AttacksTest is VaultRealV4Base {
    // ------------------------------------------------------------------------------------------------------------
    // Settlement after fees accrue
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice Adding liquidity to a position that has earned fees credits those fees into the same settlement. When
     *         the fees exceed what a deposit owes in some currency, `SETTLE_PAIR` reverts with `DeltaNotNegative`, so
     *         deposits are blocked. Deposits must keep working, and the depositor must not receive the existing
     *         holders' fees.
     */
    function test_deposits_keep_working_after_fees_accrue_and_fees_stay_with_existing_holders() public {
        PoolKey memory key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, 1e15);
        Vault vault = _newVault(key, 1, tick, 2000, 2000);
        (uint256 aliceShares,,) = _deposit(vault, alice, 100 ether, 300_000e6);
        _churn(key, 10);
        _syncOracleToNativePool(key);

        uint256 navBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();
        (uint256 bobShares, uint256 used0, uint256 used1) = _deposit(vault, bob, 0.001 ether, 3e6);
        assertGt(bobShares, 0);

        // Bob's shares are worth no more than what he paid (value at the same price).
        (uint160 sp,,,) = stateView.getSlot0(_poolId(key));
        uint256 paid = Math.mulDiv(used0, Math.mulDiv(sp, sp, 1 << 96), 1 << 96) + used1;
        uint256 bobClaim = Math.mulDiv(bobShares, vault.totalAssets(), vault.totalSupply());
        assertLe(bobClaim, paid + 2, "the new depositor must not capture the existing holders' fees");
        // Alice's claim did not shrink.
        assertGe(
            Math.mulDiv(aliceShares, vault.totalAssets(), vault.totalSupply()) + 2,
            Math.mulDiv(aliceShares, navBefore, supplyBefore),
            "existing holders keep their fees"
        );
    }

    /**
     * @notice Same defect on an ERC-20 pool, where fees in token1 exceed a token1-light deposit.
     */
    function test_erc20_pool_deposits_keep_working_after_fees_accrue() public {
        PoolKey memory key = _usdcWethKey();
        int24 tick = _initPool(key, 1e18, 2000e6, true);
        _seedExternalLiquidity(key, tick, 1e18);
        Vault vault = _newVault(key, 1, tick, 2000, 2000);
        _deposit(vault, alice, 300_000e6, 100 ether);
        for (uint256 i; i < 10; ++i) {
            _swap(attacker, key, true, 100_000e6);
            _swap(attacker, key, false, 50 ether);
        }
        _syncOracleToUsdcWethPool(key);
        (uint256 shares,,) = _deposit(vault, bob, 3e6, 0.001 ether);
        assertGt(shares, 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Forced ETH
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice ETH can be forced into the PositionManager (for example by `selfdestruct`). `SWEEP` then returns more
     *         ETH than the vault sent, the measured `pre - post` underflows, and native deposits revert for everyone.
     */
    function test_forced_eth_in_the_position_manager_cannot_block_native_deposits() public {
        PoolKey memory key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        Vault vault = _newVault(key, 0, tick, 4000, 4000);
        _deposit(vault, alice, 10 ether, 30_000e6);

        vm.deal(address(posm), 1 ether); // forced, as selfdestruct would
        (uint256 shares,,) = _deposit(vault, bob, 1 ether, 3_000e6);
        assertGt(shares, 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Valuation at a manipulated spot price
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice ERC-4626 `redeem` pays idle token1 at a value computed from the pool's spot price with no oracle check.
     *         An attacker who holds shares pushes the price up, redeems more token1 than the shares are worth, and
     *         pushes it back. Single-asset exits must not be priced from an untrusted spot price.
     */
    function test_redeem_at_a_manipulated_spot_price_cannot_take_other_holders_funds() public {
        PoolKey memory key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, 1e14);
        Vault vault = _newVault(key, 0, tick, 4000, 4000);
        _deposit(vault, alice, 100 ether, 300_000e6);
        (uint256 attackerShares,,) = _deposit(vault, attacker, 10 ether, 30_000e6);
        usdc.mint(address(vault), 500_000e6); // idle token1, e.g. collected fees or refunds

        uint256 fairAssets = vault.previewRedeem(attackerShares);
        _swap(attacker, key, false, 2_000_000e6); // buy ETH: the vault's ETH looks far more valuable

        vm.startPrank(attacker);
        try vault.redeem(vault.maxRedeem(attacker), attacker, attacker) returns (uint256 assets) {
            // if redemption is allowed at all, it must not pay more than the fair value of the shares redeemed
            assertLe(assets, fairAssets + fairAssets / 100, "redeemed far above fair value at a manipulated price");
        } catch {}
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Price moved by a token hook between the oracle check and the mint
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice A hook-bearing token (ERC-777 style) lets the depositor run code during `transferFrom`, after the vault
     *         checked the oracle and snapshotted the price. If the hook moves the pool price, the vault adds
     *         liquidity at the manipulated price. The deposit must revert instead.
     */
    function test_a_token_hook_cannot_move_the_price_between_the_check_and_the_mint() public {
        HookToken hookToken = new HookToken();
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(hookToken)), 500, 10, address(0));
        hookToken.mint(address(this), 1e30);
        hookToken.mint(attacker, 1e30);
        hookToken.approve(address(lpRouter), type(uint256).max);
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, 1e14);
        Vault vault = _newVault(key, 0, tick, 4000, 4000);
        vm.prank(attacker);
        hookToken.approve(address(vault), type(uint256).max);

        PriceMover mover = new PriceMover(swapRouter, hookToken);
        hookToken.mint(address(mover), 1e30);
        vm.deal(address(mover), 1e6 ether);
        hookToken.setHook(attacker, address(mover));
        mover.arm(_v4(key), 100 ether);

        vm.prank(attacker);
        // Surplus ETH lets the mint succeed even at the lower (manipulated) price, so only the vault's own check stops it.
        vm.expectRevert(Vault.PriceMovedDuringDeposit.selector);
        vault.depositPair{value: 1_000 ether}(1_000 ether, 30_000e6, 0, attacker);
    }

    /**
     * @notice Slither flags band storage written after the PositionManager call (`reentrancy-eth`). A token hook that
     *         fires while the vault pays inside Uniswap's settlement can read the vault's views, but it can neither
     *         re-enter any state-changing vault function (all are `nonReentrant`) nor move the price (the
     *         PoolManager is already unlocked by the PositionManager, so a nested swap reverts).
     */
    function test_a_hook_inside_settlement_cannot_reenter_the_vault_or_move_the_price() public {
        HookToken hookToken = new HookToken();
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(hookToken)), 500, 10, address(0));
        hookToken.mint(address(this), 1e30);
        hookToken.mint(alice, 1e30);
        hookToken.approve(address(lpRouter), type(uint256).max);
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, 1e14);
        Vault vault = _newVault(key, 0, tick, 4000, 4000);
        vm.prank(alice);
        hookToken.approve(address(vault), type(uint256).max);

        SettlementProbe probe = new SettlementProbe(vault, swapRouter);
        vm.deal(address(probe), 10 ether);
        probe.arm(_v4(key));
        hookToken.setHook(address(vault), address(probe)); // fires when the vault is the sender: inside settlement

        (uint160 before,,,) = stateView.getSlot0(_poolId(key));
        vm.prank(alice);
        vault.depositPair{value: 10 ether}(10 ether, 30_000e6, 0, alice);
        (uint160 afterDeposit,,,) = stateView.getSlot0(_poolId(key));

        assertTrue(probe.fired(), "the hook ran inside settlement");
        assertFalse(probe.redeemSucceeded(), "re-entering redeem must fail");
        assertFalse(probe.depositSucceeded(), "re-entering deposit must fail");
        assertFalse(probe.swapSucceeded(), "a nested swap must fail");
        assertEq(afterDeposit, before, "the price did not move");
    }

    // ------------------------------------------------------------------------------------------------------------
    // NFTs the vault did not ask for
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice Guide 12.4: a foreign position NFT sent to the vault is rejected unless the vault expects it.
     */
    function test_a_foreign_position_nft_cannot_be_pushed_into_the_vault() public {
        PoolKey memory key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        Vault vault = _newVault(key, 0, tick, 4000, 4000);

        uint256 tokenId = posm.nextTokenId();
        usdc.approve(address(permit2), type(uint256).max);
        permit2.approve(USDC_ADDR, address(posm), type(uint160).max, uint48(block.timestamp + 1));
        bytes memory actions = abi.encodePacked(
            uint8(PosmActions.MINT_POSITION), uint8(PosmActions.SETTLE_PAIR), uint8(PosmActions.SWEEP)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            (tick - 600) / 10 * 10,
            (tick - 600) / 10 * 10 + 1200,
            uint256(1e12),
            uint128(1e30),
            uint128(1e30),
            address(this),
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, address(this));
        posm.modifyLiquidities{value: 10 ether}(abi.encode(actions, params), block.timestamp);
        assertEq(posm.ownerOf(tokenId), address(this));

        vm.expectRevert(Vault.UnexpectedNft.selector);
        posm.safeTransferFrom(address(this), address(vault), tokenId);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Accounting accuracy against Uniswap's own numbers
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice The fees the vault reports as pending equal what Uniswap pays when they are collected.
     */
    function test_pending_fees_equal_what_uniswap_pays_on_collection() public {
        PoolKey memory key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, 1e15);
        Vault vault = _newVault(key, 0, tick, 4000, 4000);
        _deposit(vault, alice, 100 ether, 300_000e6);
        _churn(key, 6);

        uint256 navWithFees = vault.totalAssets();
        Band[] memory b = vault.bands();
        (uint160 sp,,,) = stateView.getSlot0(_poolId(key));
        uint256 principal = _positionValue(b, sp);

        // collect for real, as the vault would (prank as the NFT owner): DECREASE_LIQUIDITY(0) + TAKE_PAIR
        uint256 before0 = address(this).balance;
        uint256 before1 = usdc.balanceOf(address(this));
        bytes memory actions;
        bytes[] memory params = new bytes[](b.length + 1);
        for (uint256 i; i < b.length; ++i) {
            actions = abi.encodePacked(actions, uint8(PosmActions.DECREASE_LIQUIDITY));
            params[i] = abi.encode(b[i].tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        }
        actions = abi.encodePacked(actions, uint8(PosmActions.TAKE_PAIR));
        params[b.length] = abi.encode(key.currency0, key.currency1, address(this));
        vm.prank(address(vault));
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        uint256 got0 = address(this).balance - before0;
        uint256 got1 = usdc.balanceOf(address(this)) - before1;
        assertGt(got0 + got1, 0, "the churn must have produced fees");

        uint256 feesValue = Math.mulDiv(got0, Math.mulDiv(sp, sp, 1 << 96), 1 << 96) + got1;
        assertApproxEqAbs(navWithFees, principal + feesValue, 2 * b.length + 2, "pending fees must match collection");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Share price attacks
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice First-depositor inflation (guide 12.4): the attacker never profits and the victim's loss is at most the
     *         value of one share.
     */
    function test_first_depositor_inflation_never_profits() public {
        PoolKey memory key = _usdcWethKey();
        int24 tick = _initPool(key, 1e18, 2000e6, true);
        Vault vault = _newVault(key, 0, tick, 4000, 4000);

        uint256 attackerStart = weth.balanceOf(attacker) + usdc.balanceOf(attacker) / 2000; // rough, same units below
        (uint256 attackerShares, uint256 a0, uint256 a1) = _deposit(vault, attacker, 20e6, 0.01 ether);
        vm.prank(attacker);
        weth.transfer(address(vault), 100 ether); // donation to inflate the share price

        (uint256 victimShares, uint256 v0, uint256 v1) = _deposit(vault, alice, 20_000e6, 10 ether);
        (uint160 sp,,,) = stateView.getSlot0(_poolId(key));
        uint256 victimPaid = _valueAt(v0, v1, sp);
        uint256 victimClaim = Math.mulDiv(victimShares, vault.totalAssets(), vault.totalSupply());
        uint256 oneShare = Math.mulDiv(1, vault.totalAssets(), vault.totalSupply()) + 1;
        assertGe(victimClaim + oneShare, victimPaid, "victim loses at most one share of value");

        uint256 attackerClaim = Math.mulDiv(attackerShares, vault.totalAssets(), vault.totalSupply());
        uint256 attackerPaid = _valueAt(a0, a1, sp) + 100 ether;
        assertLe(attackerClaim, attackerPaid, "the attacker never gets more than it put in");
        attackerStart;
    }

    // ------------------------------------------------------------------------------------------------------------
    // Deposit sizes
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice Any deposit size either succeeds or fails with one of the vault's own documented errors, never inside
     *         Uniswap's settlement (rounding pushing a charge above the approved amount).
     */
    function testFuzz_deposit_sizes_never_fail_inside_uniswap_settlement(uint256 amount0, uint256 amount1, uint8 shape)
        public
    {
        PoolKey memory key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        Vault vault = _newVault(key, uint8(bound(shape, 0, 4)), tick, 3000, 3000);
        amount0 = bound(amount0, 1, 1e24);
        amount1 = bound(amount1, 1, 1e18);
        vm.prank(alice);
        try vault.depositPair{value: amount0}(amount0, amount1, 0, alice) returns (uint256, uint256, uint256) {}
        catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            assertTrue(
                sel == Vault.ZeroLiquidity.selector || sel == Vault.FirstDepositTooSmall.selector
                    || sel == Vault.ZeroValue.selector,
                "a deposit failed inside Uniswap settlement instead of with a vault error"
            );
        }
        // a second deposit of the same shape behaves the same way
        vm.prank(bob);
        try vault.depositPair{value: amount0}(amount0, amount1, 0, bob) returns (uint256, uint256, uint256) {}
        catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            assertTrue(
                sel == Vault.ZeroLiquidity.selector || sel == Vault.FirstDepositTooSmall.selector
                    || sel == Vault.ZeroValue.selector,
                "second deposit failed inside Uniswap settlement"
            );
        }
    }

    /**
     * Recheck (2026-10-23): the later deposit is sized independently of the first. A later deposit thousands of times
     * larger than the vault (after a dust first deposit, or once only the dead shares are left) used to be sized
     * from rounded-down token amounts of the small stored liquidity and pulled more than its budget inside Uniswap
     * settlement. Any later deposit must either settle inside its budget or fail with a vault error.
     */
    function testFuzz_any_later_deposit_size_settles_inside_its_budget(
        uint256 first0,
        uint256 first1,
        uint256 later0,
        uint256 later1,
        uint8 shape
    ) public {
        PoolKey memory key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        Vault vault = _newVault(key, uint8(bound(shape, 0, 4)), tick, 3000, 3000);
        first0 = bound(first0, 1, 1e24);
        first1 = bound(first1, 1, 1e18);
        later0 = bound(later0, 1, 1e24);
        later1 = bound(later1, 1, 1e18);
        vm.prank(alice);
        try vault.depositPair{value: first0}(first0, first1, 0, alice) returns (uint256, uint256, uint256) {}
        catch {
            return; // first-deposit failures are covered above
        }
        vm.prank(bob);
        try vault.depositPair{value: later0}(later0, later1, 0, bob) returns (uint256, uint256, uint256) {}
        catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            assertTrue(
                sel == Vault.ZeroLiquidity.selector || sel == Vault.ZeroValue.selector,
                "a later deposit failed inside Uniswap settlement instead of with a vault error"
            );
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _churn(PoolKey memory key, uint256 rounds) internal {
        for (uint256 i; i < rounds; ++i) {
            _swap(attacker, key, true, 50 ether);
            _swap(attacker, key, false, 100_000e6);
        }
    }

    function _positionValue(Band[] memory b, uint160 sp) internal pure returns (uint256 total) {
        for (uint256 i; i < b.length; ++i) {
            (uint256 x, uint256 y) = LiquidityMath.amountsForLiquidity(
                sp,
                SqrtPriceMath.getSqrtPriceAtTick(b[i].tickLower),
                SqrtPriceMath.getSqrtPriceAtTick(b[i].tickUpper),
                b[i].liquidity
            );
            total += _valueAt(x, y, sp);
        }
    }

    function _valueAt(uint256 a0, uint256 a1, uint160 sp) internal pure returns (uint256) {
        return Math.mulDiv(a0, Math.mulDiv(sp, sp, 1 << 96), 1 << 96) + a1;
    }
}

interface ITokenHook {
    function onTokenSend() external;
}

/**
 * @dev ERC-20 that calls a per-sender hook on `transferFrom`, like an ERC-777 `tokensToSend` hook.
 */
contract HookToken is ERC20 {
    mapping(address => address) public hookOf;

    constructor() ERC20("Hook", "HOOK") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHook(address account, address hook) external {
        hookOf[account] = hook;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        address hook = hookOf[from];
        if (hook != address(0)) ITokenHook(hook).onTokenSend();
        return super.transferFrom(from, to, value);
    }
}

/**
 * @dev Swaps a large amount through the pool when the hook fires, moving the price inside the vault's deposit.
 */
contract PriceMover is ITokenHook {
    import_PoolSwapTest public immutable router;
    HookToken public immutable token;
    bytes internal _key;
    uint256 public amount;
    bool public fired;

    constructor(import_PoolSwapTest router_, HookToken token_) {
        router = router_;
        token = token_;
        token_.approve(address(router_), type(uint256).max);
    }

    function arm(import_V4PoolKey memory key, uint256 amount_) external {
        _key = abi.encode(key);
        amount = amount_;
    }

    function onTokenSend() external {
        if (fired) return;
        fired = true;
        import_V4PoolKey memory key = abi.decode(_key, (import_V4PoolKey));
        router.swap{value: amount}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: 4295128740
            }),
            import_PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    receive() external payable {}
}

/**
 * @dev Fires while the vault pays the PoolManager inside the PositionManager's settlement, and tries everything.
 */
contract SettlementProbe is ITokenHook {
    Vault public immutable vault;
    import_PoolSwapTest public immutable router;
    bytes internal _key;
    bool public fired;
    bool public redeemSucceeded;
    bool public depositSucceeded;
    bool public swapSucceeded;
    uint256 public sharesSeen;

    constructor(Vault vault_, import_PoolSwapTest router_) {
        vault = vault_;
        router = router_;
    }

    function arm(import_V4PoolKey memory key) external {
        _key = abi.encode(key);
    }

    function onTokenSend() external {
        if (fired) return;
        fired = true;
        sharesSeen = vault.totalSupply(); // views are readable (documented read-only reentrancy window)
        try vault.redeem(1, address(this), address(this)) {
            redeemSucceeded = true;
        } catch {}
        try vault.deposit(1e6, address(this)) {
            depositSucceeded = true;
        } catch {}
        import_V4PoolKey memory key = abi.decode(_key, (import_V4PoolKey));
        try router.swap{value: 1 ether}(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 4295128740}),
            import_PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            swapSucceeded = true;
        } catch {}
    }

    receive() external payable {}
}

