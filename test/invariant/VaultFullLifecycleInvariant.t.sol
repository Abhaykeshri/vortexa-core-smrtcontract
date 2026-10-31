// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vault} from "../../src/Vault.sol";
import {VaultM5Module} from "../../src/VaultM5Module.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {CurrencyLib} from "../../src/libraries/CurrencyLib.sol";
import {Band, PoolKey, RebalanceParams, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {VaultRealV4Base} from "../integration/utils/VaultRealV4Base.sol";
import {NormalLPStrategy} from "../../src/strategies/NormalLPStrategy.sol";

/**
 * @title Full-lifecycle handler (M4 + M5 + M6 together) on real Uniswap v4
 * @notice One five-band vault on the native ETH/USDC pool driven by every public entry point at once: pair and
 *         ERC-4626 deposits, mints, withdrawals and redemptions, fee collection, compounding, keeper rebalances with
 *         hostile centers and tolerances, organic volume, attacker price pushes, donations, ETH forced into the
 *         vault, the PositionManager and the executor, pause, oracle outages, protocol-fee changes (above 100% too)
 *         and broken fee collectors. Every per-operation property is recorded as a ghost counter.
 */
contract VaultFullLifecycleHandler is VaultRealV4Base {
    uint128 internal constant DEEP = 2e17;

    Vault public vault;
    NormalLPStrategy public planner;
    PoolKey internal _key;
    address[] internal _actors;
    address public keeper = makeAddr("keeper");
    address public goodCollector;
    address internal _rejecting;
    bytes32 public configHash;
    bool public oracleDown;

    uint256 public ghostFee0;
    uint256 public ghostFee1;
    uint256 public forcedPosmEth;
    uint256 public forcedExecutorEth;
    uint256 public donatedExecutorUsdc;

    uint256 public previewMismatches;
    uint256 public failedWithdrawals;
    uint256 public overpaidDeposits;
    uint256 public lossViolations;
    uint256 public viewActionMismatches;
    uint256 public rebalances;
    uint256 public pairDeposits;
    uint256 public assetDeposits;
    uint256 public assetExits;
    uint256 public unexpectedFailures;
    bytes4 public lastUnexpectedFailure;

    constructor() {
        setUp();
        planner = new NormalLPStrategy(shapes);
        _key = _nativeUsdcKey();
        int24 tick = _initPool(_key, 2000e6, 1e18, false);
        _seedExternalLiquidity(_key, tick, DEEP);
        VaultConfig memory cfg;
        cfg.poolKey = _key;
        cfg.strategy = Strategy.NormalLP;
        cfg.shapeId = 0; // five-band bell
        cfg.centerTick = tick / 10 * 10;
        cfg.ticksLeft = 1_000;
        cfg.ticksRight = 1_000;
        cfg.driftTicks = 900; // production Normal LP: DRIFT once the price is more than 100 ticks off-centre
        cfg.autoRebalance = true;
        cfg.baseIsCurrency0 = true;
        vault = _newVaultWith(cfg, address(planner));
        _actors.push(alice);
        _actors.push(bob);
        _actors.push(attacker);
        factoryKeepers[keeper] = true;
        factoryFeeBps = 1_000;
        goodCollector = factoryFeeCollector;
        _rejecting = address(new EthRejecter());
        configHash = keccak256(abi.encode(vault.config()));
    }

    /**
     * First deposit, made after construction: the production Normal LP plan may swap on a first deposit, and the
     * swap executor calls back into this contract (it plays the factory), which has no code while constructing.
     */
    function seed() external {
        _deposit(vault, alice, 40 ether, 120_000e6);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Entry points
    // ------------------------------------------------------------------------------------------------------------

    function depositPair(uint256 who, uint256 amount0, uint256 amount1) external {
        address actor = _actors[who % _actors.length];
        amount0 = bound(amount0, 0.01 ether, 30 ether);
        amount1 = bound(amount1, 20e6, 90_000e6);
        (uint160 sp,,,) = stateView.getSlot0(_poolId(_key));
        (uint256 f0, uint256 f1) = pending();
        uint256 navBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();
        vm.prank(actor);
        try vault.depositPair{value: amount0}(amount0, amount1, 0, actor) returns (
            uint256 shares, uint256 u0, uint256 u1
        ) {
            pairDeposits++;
            _addFee(f0, f1);
            uint256 paid = _valueAt(u0, u1, sp);
            if (Math.mulDiv(shares, navBefore + paid, supplyBefore + shares) > paid + 2) overpaidDeposits++;
        } catch (bytes memory reason) {
            _expectedFailure(reason);
        }
    }

    function depositAsset(uint256 who, uint256 assets) external {
        address actor = _actors[who % _actors.length];
        assets = bound(assets, 1e4, 90_000e6);
        uint256 navBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();
        uint256 preview = vault.previewDeposit(assets);
        vm.prank(actor);
        try vault.deposit(assets, actor) returns (uint256 shares) {
            assetDeposits++;
            if (shares != preview) previewMismatches++;
            if (Math.mulDiv(shares, navBefore + assets, supplyBefore + shares) > assets + 1) overpaidDeposits++;
        } catch {}
    }

    function mintShares(uint256 who, uint256 shares) external {
        address actor = _actors[who % _actors.length];
        shares = bound(shares, 1e4, 1e11);
        uint256 preview = vault.previewMint(shares);
        vm.prank(actor);
        try vault.mint(shares, actor) returns (uint256 assets) {
            assetDeposits++;
            if (assets != preview) previewMismatches++;
        } catch {}
    }

    function withdrawPair(uint256 who, uint256 fraction) external {
        address actor = _actors[who % _actors.length];
        uint256 shares = Math.mulDiv(vault.balanceOf(actor), bound(fraction, 1, 10_000), 10_000);
        if (shares == 0) return;
        (uint256 p0, uint256 p1) = VaultM5Module(vault.m5Module()).previewWithdrawPair(vault, shares);
        (uint256 f0, uint256 f1) = pending();
        vm.prank(actor);
        try vault.withdrawPair(shares, 0, 0, actor) returns (uint256 out0, uint256 out1) {
            if (out0 != p0 || out1 != p1) previewMismatches++;
            _addFee(f0, f1);
        } catch {
            failedWithdrawals++;
        }
    }

    function redeem(uint256 who, uint256 fraction) external {
        address actor = _actors[who % _actors.length];
        uint256 shares = Math.mulDiv(vault.maxRedeem(actor), bound(fraction, 1, 10_000), 10_000);
        if (shares == 0) return;
        uint256 preview = vault.previewRedeem(shares);
        vm.prank(actor);
        try vault.redeem(shares, actor, actor) returns (uint256 assets) {
            assetExits++;
            if (assets != preview) previewMismatches++;
        } catch {}
    }

    function withdrawAsset(uint256 who, uint256 fraction) external {
        address actor = _actors[who % _actors.length];
        uint256 assets = Math.mulDiv(vault.maxWithdraw(actor), bound(fraction, 1, 10_000), 10_000);
        if (assets == 0) return;
        uint256 preview = vault.previewWithdraw(assets);
        vm.prank(actor);
        try vault.withdraw(assets, actor, actor) returns (uint256 shares) {
            assetExits++;
            if (shares != preview) previewMismatches++;
        } catch {}
    }

    function collectFees() external {
        (uint256 f0, uint256 f1) = pending();
        try vault.collectFees() returns (uint256, uint256) {
            _addFee(f0, f1);
        } catch {}
    }

    function compound(uint256 usdcIdle, uint256 ethIdle) external {
        usdc.mint(address(vault), bound(usdcIdle, 0, 10_000e6));
        vm.deal(address(vault), address(vault).balance + bound(ethIdle, 0, 5 ether));
        (uint256 f0, uint256 f1) = pending();
        vm.prank(keeper);
        try vault.compound() returns (uint256, uint256) {
            _addFee(f0, f1);
        } catch (bytes memory reason) {
            _expectedFailure(reason);
        }
    }

    function rebalance(int256 centerOffset, uint256 slippage) external {
        (, int24 tick,,) = stateView.getSlot0(_poolId(_key));
        int24 center = int24(int256(tick) + bound(centerOffset, -250, 250)) / 10 * 10;
        uint16 slip = uint16(bound(slippage, 0, 120));
        uint160 ref;
        try guard.referenceSqrtPriceX96(_key) returns (uint160 r) {
            ref = r;
        } catch {}
        uint256 before = ref == 0 ? 0 : valueAtRef(ref);
        (uint256 f0, uint256 f1) = pending();
        (bool needed, bytes32 reason) = vault.checkRebalance();
        bool gateBlocks = reason == bytes32("PAUSED") || reason == bytes32("AUTO_OFF") || reason == bytes32("COOLDOWN")
            || reason == bytes32("PRICE");
        vm.prank(keeper);
        try vault.rebalance(RebalanceParams({newCenterTick: center, maxSlippageBps: slip})) {
            rebalances++;
            _addFee(f0, f1);
            if (valueAtRef(ref) + 2 < Math.mulDiv(before, 10_000 - slip, 10_000)) lossViolations++;
            if (!needed || gateBlocks) viewActionMismatches++; // succeeded although the view said it would not
        } catch {}
    }

    function organicVolume(uint256 size) external {
        _swap(attacker, _key, true, bound(size, 0.1 ether, 10 ether));
        _swap(attacker, _key, false, bound(size, 200e6, 20_000e6));
        if (!oracleDown) _syncOracleToNativePool(_key);
    }

    function attackerPush(bool down, uint256 size) external {
        if (down) _swap(attacker, _key, true, bound(size, 0.1 ether, 15 ether));
        else _swap(attacker, _key, false, bound(size, 200e6, 30_000e6));
    }

    function trendAndFollow(bool down, uint256 size) external {
        if (down) _swap(attacker, _key, true, bound(size, 1 ether, 25 ether));
        else _swap(attacker, _key, false, bound(size, 2_000e6, 50_000e6));
        if (!oracleDown) _syncOracleToNativePool(_key);
    }

    function donate(uint256 usdcAmount, uint256 ethAmount) external {
        usdc.mint(address(vault), bound(usdcAmount, 0, 5_000e6));
        vm.deal(address(vault), address(vault).balance + bound(ethAmount, 0, 2 ether));
    }

    function forceIntoInfrastructure(uint256 posmEth, uint256 executorEth, uint256 executorUsdc) external {
        posmEth = bound(posmEth, 0, 1 ether);
        executorEth = bound(executorEth, 0, 1 ether);
        executorUsdc = bound(executorUsdc, 0, 1_000e6);
        vm.deal(address(posm), address(posm).balance + posmEth);
        vm.deal(address(executor), address(executor).balance + executorEth);
        usdc.mint(address(executor), executorUsdc);
        forcedPosmEth += posmEth;
        forcedExecutorEth += executorEth;
        donatedExecutorUsdc += executorUsdc;
    }

    function togglePause(bool doPause) external {
        vm.prank(doPause ? guardianAccount : timelockAccount);
        if (doPause) vault.pause();
        else vault.unpause();
    }

    function toggleOracle(bool down) external {
        oracleDown = down;
        if (down) {
            vm.mockCallRevert(address(guard), abi.encodeWithSelector(IPriceGuard.isPriceTrusted.selector), "down");
            vm.mockCallRevert(
                address(guard), abi.encodeWithSelector(IPriceGuard.referenceSqrtPriceX96.selector), "down"
            );
        } else {
            vm.clearMockedCalls();
            _syncOracleToNativePool(_key);
        }
    }

    function setProtocolFee(uint256 bps) external {
        factoryFeeBps = bound(bps, 0, 15_000);
    }

    function setCollector(uint256 mode) external {
        mode %= 3;
        factoryFeeCollector = mode == 0 ? goodCollector : mode == 1 ? address(0) : _rejecting;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 minutes, 45 minutes));
        if (!oracleDown) _syncOracleToNativePool(_key);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Probes
    // ------------------------------------------------------------------------------------------------------------

    function probeEveryoneExits() external returns (uint256 failures, uint256 paidValue, uint256 allowed) {
        uint256 snap = vm.snapshotState();
        (uint160 sp,,,) = stateView.getSlot0(_poolId(_key));
        allowed = vault.totalAssets();
        if (factoryFeeCollector != goodCollector) {
            (uint256 f0, uint256 f1) = pending();
            uint256 bps = _bps();
            allowed += _valueAt(f0 * bps / 10_000, f1 * bps / 10_000, sp);
        }
        for (uint256 i; i < _actors.length; ++i) {
            uint256 shares = vault.balanceOf(_actors[i]);
            if (shares == 0) continue;
            vm.prank(_actors[i]);
            try vault.withdrawPair(shares, 0, 0, _actors[i]) returns (uint256 out0, uint256 out1) {
                paidValue += _valueAt(out0, out1, sp);
            } catch {
                failures++;
            }
        }
        vm.revertToState(snap);
    }

    /**
     * @notice ERC-4626 `max*` and `preview*` views must never revert, in any state (paused, oracle down, filled).
     */
    function erc4626ViewsRevert() external view returns (bool reverted) {
        address a = _actors[0];
        try vault.maxDeposit(a) returns (uint256) {}
        catch {
            return true;
        }
        try vault.maxMint(a) returns (uint256) {}
        catch {
            return true;
        }
        try vault.maxWithdraw(a) returns (uint256) {}
        catch {
            return true;
        }
        try vault.maxRedeem(a) returns (uint256) {}
        catch {
            return true;
        }
        try vault.totalAssets() returns (uint256) {}
        catch {
            return true;
        }
        try vault.previewRedeem(1e9) returns (uint256) {}
        catch {
            return true;
        }
        try vault.checkRebalance() returns (bool, bytes32) {}
        catch {
            return true;
        }
    }

    function valueAtRef(uint160 ref) public view returns (uint256) {
        if (ref == 0) return 0;
        uint256 amount0 = address(vault).balance;
        uint256 amount1 = usdc.balanceOf(address(vault));
        (uint256 f0, uint256 f1) = pending();
        uint256 bps = _bps();
        amount0 += f0 - f0 * bps / 10_000;
        amount1 += f1 - f1 * bps / 10_000;
        Band[] memory b = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            (uint256 x, uint256 y) = LiquidityMath.amountsForLiquidity(
                ref,
                SqrtPriceMath.getSqrtPriceAtTick(b[i].tickLower),
                SqrtPriceMath.getSqrtPriceAtTick(b[i].tickUpper),
                b[i].liquidity
            );
            amount0 += x;
            amount1 += y;
        }
        return _valueAt(amount0, amount1, ref);
    }

    function pending() public view returns (uint256 f0, uint256 f1) {
        Band[] memory b = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            (uint128 liq, uint256 last0, uint256 last1) = stateView.getPositionInfo(
                _poolId(_key), address(posm), b[i].tickLower, b[i].tickUpper, bytes32(b[i].tokenId)
            );
            (uint256 now0, uint256 now1) = stateView.getFeeGrowthInside(_poolId(_key), b[i].tickLower, b[i].tickUpper);
            unchecked {
                f0 += Math.mulDiv(liq, now0 - last0, 1 << 128);
                f1 += Math.mulDiv(liq, now1 - last1, 1 << 128);
            }
        }
    }

    function realLiquidity(Band memory b) external view returns (uint128 liquidity) {
        (liquidity,,) =
            stateView.getPositionInfo(_poolId(_key), address(posm), b.tickLower, b.tickUpper, bytes32(b.tokenId));
    }

    function usdcOf(address who) external view returns (uint256) {
        return usdc.balanceOf(who);
    }

    function posmAddress() external view returns (address) {
        return address(posm);
    }

    function executorAddress() external view returns (address) {
        return address(executor);
    }

    function routerAddress() external view returns (address) {
        return address(router);
    }

    function standingAllowances() external view returns (uint256 total) {
        (uint160 a,,) = permit2.allowance(address(vault), USDC_ADDR, address(posm));
        (uint160 b,,) = permit2.allowance(address(executor), USDC_ADDR, address(router));
        total = uint256(a) + b + usdc.allowance(address(executor), address(permit2))
            + usdc.allowance(address(vault), address(executor));
    }

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    function _bps() internal view returns (uint256) {
        return factoryFeeBps < 10_000 ? factoryFeeBps : 10_000;
    }

    /**
     * Deposits and compounds may only fail for a reason this handler provoked: pause, an untrusted or reverting
     * oracle (mocked to revert with "down"), an unset or ETH-rejecting fee collector (strict fee paths), or sizes
     * too small to mint. Anything else (a Uniswap settlement error, for example) is a liveness bug.
     */
    function _expectedFailure(bytes memory reason) internal {
        bytes4 sel = bytes4(reason);
        if (
            sel != Vault.IsPaused.selector && sel != Vault.PriceUntrusted.selector && sel != Vault.ZeroAddress.selector
                && sel != Vault.ZeroLiquidity.selector && sel != Vault.ZeroValue.selector
                && sel != Vault.DepositNotAllowed.selector && sel != Vault.FirstDepositTooSmall.selector
                && sel != CurrencyLib.NativeTransferFailed.selector && sel != bytes4("down")
        ) {
            unexpectedFailures++;
            lastUnexpectedFailure = sel;
        }
    }

    function _addFee(uint256 f0, uint256 f1) internal {
        if (factoryFeeCollector != goodCollector) return;
        uint256 bps = _bps();
        ghostFee0 += f0 * bps / 10_000;
        ghostFee1 += f1 * bps / 10_000;
    }

    function _valueAt(uint256 a0, uint256 a1, uint160 sp) internal pure returns (uint256) {
        return Math.mulDiv(a0, Math.mulDiv(sp, sp, 1 << 96), 1 << 96) + a1;
    }
}

contract EthRejecter {
    receive() external payable {
        revert("no ETH");
    }
}

/**
 * forge-config: default.invariant.runs = 256
 * forge-config: default.invariant.depth = 64
 * forge-config: ci.invariant.runs = 1000
 * forge-config: ci.invariant.depth = 128
 */
contract VaultFullLifecycleInvariantTest is Test {
    VaultFullLifecycleHandler internal handler;
    Vault internal vault;

    function setUp() public {
        handler = new VaultFullLifecycleHandler();
        handler.seed();
        vault = handler.vault();
        bytes4[] memory s = new bytes4[](22);
        s[0] = VaultFullLifecycleHandler.depositPair.selector;
        s[1] = VaultFullLifecycleHandler.depositAsset.selector;
        s[2] = VaultFullLifecycleHandler.mintShares.selector;
        s[3] = VaultFullLifecycleHandler.withdrawPair.selector;
        s[4] = VaultFullLifecycleHandler.redeem.selector;
        s[5] = VaultFullLifecycleHandler.withdrawAsset.selector;
        s[6] = VaultFullLifecycleHandler.collectFees.selector;
        s[7] = VaultFullLifecycleHandler.compound.selector;
        s[8] = VaultFullLifecycleHandler.rebalance.selector;
        s[9] = VaultFullLifecycleHandler.rebalance.selector;
        s[10] = VaultFullLifecycleHandler.organicVolume.selector;
        s[11] = VaultFullLifecycleHandler.attackerPush.selector;
        s[12] = VaultFullLifecycleHandler.trendAndFollow.selector;
        s[13] = VaultFullLifecycleHandler.donate.selector;
        s[14] = VaultFullLifecycleHandler.forceIntoInfrastructure.selector;
        s[15] = VaultFullLifecycleHandler.togglePause.selector;
        s[16] = VaultFullLifecycleHandler.toggleOracle.selector;
        s[17] = VaultFullLifecycleHandler.setProtocolFee.selector;
        s[18] = VaultFullLifecycleHandler.setCollector.selector;
        s[19] = VaultFullLifecycleHandler.warp.selector;
        s[20] = VaultFullLifecycleHandler.warp.selector;
        s[21] = VaultFullLifecycleHandler.depositPair.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: s}));
        targetContract(address(handler));
    }

    /**
     * Sanity: every feature really succeeds under this handler, including a five-band rebalance.
     */
    function test_handler_reaches_every_feature() public {
        handler.depositPair(1, 5 ether, 15_000e6);
        handler.depositAsset(2, 10_000e6);
        handler.mintShares(2, 1e9);
        handler.organicVolume(5 ether);
        handler.collectFees();
        handler.compound(5_000e6, 2 ether);
        handler.trendAndFollow(true, 25 ether);
        handler.trendAndFollow(true, 25 ether);
        handler.trendAndFollow(true, 25 ether);
        handler.warp(31 minutes);
        (bool needed, bytes32 reason) = vault.checkRebalance();
        emit log_named_bytes32("trigger", reason);
        require(needed, "the production strategy must ask for a rebalance after the trend");
        handler.rebalance(0, 100);
        handler.redeem(2, 5_000);
        handler.withdrawAsset(2, 5_000);
        handler.withdrawPair(1, 5_000);
        require(handler.pairDeposits() == 1, "pair deposit");
        require(handler.assetDeposits() == 2, "ERC-4626 deposit and mint");
        require(handler.rebalances() == 1, "five-band rebalance");
        require(vault.bands().length == 5, "five bands re-entered");
        require(handler.assetExits() >= 1, "ERC-4626 exits");
        _checkAll();
    }

    function invariant_everything() public {
        _checkAll();
    }

    function _checkAll() internal {
        address c = handler.goodCollector();
        require(c.balance == handler.ghostFee0(), "ETH protocol fee differs from feeBps of collected fees");
        require(handler.usdcOf(c) == handler.ghostFee1(), "USDC protocol fee differs");
        require(handler.previewMismatches() == 0, "a preview differed from the real exit");
        require(handler.failedWithdrawals() == 0, "a pair withdrawal reverted");
        require(handler.unexpectedFailures() == 0, "a deposit or compound failed for an unexpected reason");
        require(handler.overpaidDeposits() == 0, "a depositor was overpaid");
        require(handler.lossViolations() == 0, "a rebalance lost more than its tolerance");
        require(handler.viewActionMismatches() == 0, "checkRebalance disagreed with rebalance");
        require(!handler.erc4626ViewsRevert(), "an ERC-4626 view reverted");

        (uint256 failures, uint256 paid, uint256 allowed) = handler.probeEveryoneExits();
        require(failures == 0, "a holder could not exit");
        require(paid <= allowed + 50, "holders could withdraw more than totalAssets");

        Band[] memory b = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            require(PosmLike(handler.posmAddress()).ownerOf(b[i].tokenId) == address(vault), "band NFT not owned");
            require(handler.realLiquidity(b[i]) == b[i].liquidity, "stored liquidity differs");
        }
        require(PosmLike(handler.posmAddress()).balanceOf(address(vault)) == b.length, "orphaned NFT");
        require(handler.usdcOf(handler.posmAddress()) == 0, "PositionManager kept USDC");
        require(handler.posmAddress().balance <= handler.forcedPosmEth(), "PositionManager kept vault ETH");
        require(handler.executorAddress().balance <= handler.forcedExecutorEth(), "executor kept vault ETH");
        require(handler.usdcOf(handler.executorAddress()) <= handler.donatedExecutorUsdc(), "executor kept USDC");
        require(handler.usdcOf(handler.routerAddress()) == 0, "router kept USDC");
        require(handler.routerAddress().balance == 0, "router kept ETH");
        require(handler.standingAllowances() == 0, "standing allowance");
        require(keccak256(abi.encode(vault.config())) == handler.configHash(), "config changed");

        address[] memory a = handler.actors();
        uint256 sum = vault.balanceOf(0x000000000000000000000000000000000000dEaD);
        for (uint256 i; i < a.length; ++i) {
            sum += vault.balanceOf(a[i]);
        }
        require(sum == vault.totalSupply(), "shares appeared or vanished");
    }
}

interface PosmLike {
    function ownerOf(uint256 id) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
}
