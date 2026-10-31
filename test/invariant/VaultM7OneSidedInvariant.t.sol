// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vault} from "../../src/Vault.sol";
import {VaultM5Module} from "../../src/VaultM5Module.sol";
import {BuyTheDipStrategy} from "../../src/strategies/BuyTheDipStrategy.sol";
import {Band, Currency, PoolKey, RebalanceParams, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {VaultRealV4Base} from "../integration/utils/VaultRealV4Base.sol";

/**
 * @title One-sided (Buy the Dip) lifecycle handler on real Uniswap v4
 * @notice Single-sided deposits, ERC-4626 deposits, withdrawals, redemptions, trends through and away from the range,
 *         TRAIL and FILLED rebalances (lock-on-fill), fee collection and compounding. `native` selects the ETH/USDC
 *         pool (base is currency0, range below the price) or the USDC/WETH pool (base is currency1, range above).
 */
contract OneSidedHandler is VaultRealV4Base {
    uint128 internal constant DEEP = 2e17;

    bool public immutable native;
    bool public below;
    Vault public vault;
    BuyTheDipStrategy public dip;
    PoolKey internal _key;
    address[] internal _actors;
    address public keeper = makeAddr("keeper");

    uint256 public ghostFee0;
    uint256 public ghostFee1;
    uint256 public sideViolations;
    uint256 public swapsDuringRebalance;
    uint256 public filledWithBands;
    uint256 public previewMismatches;
    uint256 public failedWithdrawals;
    uint256 public unexpectedDepositFailures;
    bytes4 public lastUnexpectedDepositError;
    uint256 public rebalances;
    uint256 public fills;

    constructor(bool native_) {
        native = native_;
        setUp();
        dip = new BuyTheDipStrategy(shapes);
        _key = native ? _nativeUsdcKey() : _usdcWethKey();
        int24 tick = native ? _initPool(_key, 2000e6, 1e18, false) : _initPool(_key, 1e18, 2000e6, true);
        _seedExternalLiquidity(_key, tick, DEEP);
        VaultConfig memory cfg;
        cfg.poolKey = _key;
        cfg.strategy = Strategy.BuyTheDip;
        cfg.baseIsCurrency0 = native;
        below = native; // Buy the Dip: below the price when the base is currency0
        cfg.shapeId = 4;
        cfg.centerTick = (tick / 10) * 10;
        cfg.ticksLeft = below ? int24(600) : int24(0);
        cfg.ticksRight = below ? int24(0) : int24(600);
        cfg.trailTicks = 200;
        cfg.lockOnFill = true;
        cfg.autoRebalance = true;
        vault = _newVaultWith(cfg, address(dip));
        _actors.push(alice);
        _actors.push(bob);
        factoryKeepers[keeper] = true;
        factoryFeeBps = 1_000;
        // Both handlers share the canonical USDC; separate collectors keep each fee ghost exact.
        factoryFeeCollector = makeAddr(native ? "collectorNative" : "collectorErc20");
    }

    function seed() external {
        _depositSided(alice, 20e18);
        _checkSide();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------------------------------------------------

    function deposit(uint256 who, uint256 size) external {
        address actor = _actors[who % _actors.length];
        (uint256 f0, uint256 f1) = pending();
        uint256 bandsBefore = vault.bands().length;
        // from dust (a fraction of a cent) to 20 ETH of value: tiny and huge deposits against each other
        if (_depositSided(actor, bound(size, 1e10, 20e18))) {
            _addFee(f0, f1);
            if (bandsBefore == 0) _checkSide();
        }
    }

    function depositAsset(uint256 who, uint256 assets) external {
        address actor = _actors[who % _actors.length];
        assets = bound(assets, 1e4, native ? 20_000e6 : 10 ether);
        vm.prank(actor);
        try vault.deposit(assets, actor) returns (uint256) {} catch {}
    }

    function withdrawPair(uint256 who, uint256 fraction) external {
        address actor = _actors[who % _actors.length];
        uint256 shares = Math.mulDiv(vault.balanceOf(actor), bound(fraction, 1, 10_000), 10_000);
        if (shares == 0) return;
        (uint256 p0, uint256 p1) = VaultM5Module(vault.m5Module()).previewWithdrawPair(vault, shares);
        (uint256 f0, uint256 f1) = pending();
        vm.prank(actor);
        try vault.withdrawPair(shares, 0, 0, actor) returns (uint256 o0, uint256 o1) {
            if (o0 != p0 || o1 != p1) previewMismatches++;
            _addFee(f0, f1);
        } catch {
            failedWithdrawals++;
        }
    }

    function collectFees() external {
        (uint256 f0, uint256 f1) = pending();
        try vault.collectFees() returns (uint256, uint256) {
            _addFee(f0, f1);
        } catch {}
    }

    function compound() external {
        (uint256 f0, uint256 f1) = pending();
        vm.prank(keeper);
        try vault.compound() returns (uint256, uint256) {
            _addFee(f0, f1);
        } catch {}
    }

    /**
     * Moves the price; `size` is in ETH (18 decimals) and converted to USDC at 2,000 when USDC is sold.
     */
    function trend(bool down, uint256 size) external {
        uint256 eth = bound(size, 1e17, 60 ether);
        _swap(attacker, _key, down, native == down ? eth : (eth * 2000e6) / 1 ether);
        _syncOracle();
    }

    function rebalance(uint256 slippage) external {
        (, int24 tick,,) = stateView.getSlot0(_poolId(_key));
        (uint256 f0, uint256 f1) = pending();
        vm.recordLogs();
        vm.prank(keeper);
        try vault.rebalance(
            RebalanceParams({newCenterTick: (tick / 10) * 10, maxSlippageBps: uint16(bound(slippage, 1, 100))})
        ) {
            rebalances++;
            _addFee(f0, f1);
            if (_executorSwapped()) swapsDuringRebalance++;
            if (vault.filled()) {
                fills++;
                if (vault.bands().length != 0) filledWithBands++;
            } else {
                _checkSide();
            }
        } catch {}
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 minutes, 45 minutes));
        _syncOracle();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Probes
    // ------------------------------------------------------------------------------------------------------------

    function probeEveryoneExits() external returns (uint256 failures, uint256 paid, uint256 reported) {
        uint256 snap = vm.snapshotState();
        (uint160 sp,,,) = stateView.getSlot0(_poolId(_key));
        reported = vault.totalAssets();
        for (uint256 i; i < _actors.length; ++i) {
            uint256 shares = vault.balanceOf(_actors[i]);
            if (shares == 0) continue;
            vm.prank(_actors[i]);
            try vault.withdrawPair(shares, 0, 0, _actors[i]) returns (uint256 o0, uint256 o1) {
                paid += Math.mulDiv(o0, Math.mulDiv(sp, sp, 1 << 96), 1 << 96) + o1;
            } catch {
                failures++;
            }
        }
        vm.revertToState(snap);
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

    function collector() external view returns (address) {
        return factoryFeeCollector;
    }

    function balanceOfToken(address token, address who) external view returns (uint256) {
        return token == address(0) ? who.balance : TokenView(token).balanceOf(who);
    }

    function currencies() external view returns (address c0, address c1) {
        return (Currency.unwrap(_key.currency0), Currency.unwrap(_key.currency1));
    }

    function posmAddress() external view returns (address) {
        return address(posm);
    }

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    // ------------------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------------------

    /**
     * Deposits the token the range takes (currency1 below the price, currency0 above); `size` is in 18-decimal
     * units of value.
     */
    function _depositSided(address who, uint256 size) internal returns (bool ok) {
        uint256 a0;
        uint256 a1;
        if (below) {
            a1 = native ? (size * 2000e6) / 1 ether : size; // USDC on ETH/USDC, WETH on USDC/WETH
        } else {
            a0 = native ? size : (size * 2000e6) / 1 ether;
        }
        vm.prank(who);
        try vault.depositPair{value: native ? a0 : 0}(a0, a1, 0, who) returns (uint256, uint256, uint256) {
            ok = true;
        } catch (bytes memory reason) {
            // Expected refusals: closed deposit window or filled vault, untrusted price, sizes too small to mint.
            // Anything else (for example a settlement error inside Uniswap) is a liveness bug.
            bytes4 sel = bytes4(reason);
            if (
                sel != Vault.DepositNotAllowed.selector && sel != Vault.PriceUntrusted.selector
                    && sel != Vault.ZeroLiquidity.selector && sel != Vault.ZeroValue.selector
                    && sel != Vault.FirstDepositTooSmall.selector
            ) {
                unexpectedDepositFailures++;
                lastUnexpectedDepositError = sel;
            }
        }
    }

    function _checkSide() internal {
        (, int24 tick,,) = stateView.getSlot0(_poolId(_key));
        Band[] memory b = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            if (below ? b[i].tickUpper > tick : b[i].tickLower <= tick) {
                sideViolations++;
            }
        }
    }

    function _executorSwapped() internal view returns (bool found) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(executor)) found = true;
        }
    }

    function _syncOracle() internal {
        if (native) _syncOracleToNativePool(_key);
        else _syncOracleToUsdcWethPool(_key);
    }

    function _addFee(uint256 f0, uint256 f1) internal {
        ghostFee0 += (f0 * factoryFeeBps) / 10_000;
        ghostFee1 += (f1 * factoryFeeBps) / 10_000;
    }
}

interface TokenView {
    function balanceOf(address who) external view returns (uint256);
}

/**
 * forge-config: default.invariant.runs = 128
 * forge-config: default.invariant.depth = 64
 * forge-config: ci.invariant.runs = 1000
 * forge-config: ci.invariant.depth = 128
 */
contract VaultM7OneSidedInvariantTest is Test {
    OneSidedHandler internal belowHandler;
    OneSidedHandler internal aboveHandler;

    function setUp() public {
        belowHandler = new OneSidedHandler(true);
        aboveHandler = new OneSidedHandler(false);
        belowHandler.seed();
        aboveHandler.seed();
        _target(belowHandler);
        _target(aboveHandler);
    }

    function _target(OneSidedHandler h) internal {
        bytes4[] memory s = new bytes4[](10);
        s[0] = OneSidedHandler.deposit.selector;
        s[1] = OneSidedHandler.depositAsset.selector;
        s[2] = OneSidedHandler.withdrawPair.selector;
        s[3] = OneSidedHandler.collectFees.selector;
        s[4] = OneSidedHandler.compound.selector;
        s[5] = OneSidedHandler.trend.selector;
        s[6] = OneSidedHandler.trend.selector;
        s[7] = OneSidedHandler.rebalance.selector;
        s[8] = OneSidedHandler.rebalance.selector;
        s[9] = OneSidedHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: s}));
        targetContract(address(h));
    }

    /**
     * Sanity: TRAIL and FILLED rebalances both happen, in both orientations.
     */
    function test_handlers_reach_trail_and_fill() public {
        OneSidedHandler[2] memory hs = [belowHandler, aboveHandler];
        for (uint256 i; i < 2; ++i) {
            OneSidedHandler h = hs[i];
            bool below = h.below();
            // run away from the range (TRAIL), then through it (FILLED)
            for (uint256 k; k < 4; ++k) {
                h.trend(!below, 60 ether);
            }
            h.warp(31 minutes);
            h.rebalance(100);
            for (uint256 k; k < 10; ++k) {
                h.trend(below, 60 ether);
            }
            h.warp(31 minutes);
            h.rebalance(100);
            require(h.rebalances() == 2, "TRAIL then FILLED rebalances");
            require(h.fills() == 1, "the range filled and locked idle");
            _check(h);
        }
    }

    function invariant_one_sided_rules_and_custody() public {
        _check(belowHandler);
        _check(aboveHandler);
    }

    function _check(OneSidedHandler h) internal {
        require(h.sideViolations() == 0, "a range was minted on the wrong side of the price");
        require(h.swapsDuringRebalance() == 0, "a one-sided rebalance swapped");
        require(h.filledWithBands() == 0, "a filled vault kept bands");
        require(h.previewMismatches() == 0, "preview differed from the withdrawal");
        require(h.failedWithdrawals() == 0, "a withdrawal reverted");
        require(h.unexpectedDepositFailures() == 0, "a deposit failed with an unexpected error");
        Vault v = h.vault();
        if (v.filled()) {
            require(v.bands().length == 0, "filled vault with bands");
            require(v.maxDeposit(address(1)) == 0, "filled vault open for deposits");
        }
        (address c0, address c1) = h.currencies();
        address col = h.collector();
        assertEq(h.balanceOfToken(c0, col), h.ghostFee0(), "protocol fee currency0");
        assertEq(h.balanceOfToken(c1, col), h.ghostFee1(), "protocol fee currency1");
        (uint256 failures, uint256 paid, uint256 reported) = h.probeEveryoneExits();
        require(failures == 0, "a holder could not exit");
        require(paid <= reported + 30, "exits exceed totalAssets");
        Band[] memory b = v.bands();
        for (uint256 i; i < b.length; ++i) {
            require(PosmOwner(h.posmAddress()).ownerOf(b[i].tokenId) == address(v), "band NFT not owned");
        }
        require(PosmOwner(h.posmAddress()).balanceOf(address(v)) == b.length, "orphaned NFT");
        address[] memory a = h.actors();
        uint256 sum = v.balanceOf(0x000000000000000000000000000000000000dEaD);
        for (uint256 i; i < a.length; ++i) {
            sum += v.balanceOf(a[i]);
        }
        require(sum == v.totalSupply(), "share supply");
    }
}

interface PosmOwner {
    function ownerOf(uint256 id) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
}
