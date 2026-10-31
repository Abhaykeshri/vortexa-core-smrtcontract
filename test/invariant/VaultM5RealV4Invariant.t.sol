// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vault} from "../../src/Vault.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {Band, PoolKey} from "../../src/libraries/Types.sol";
import {VaultRealV4Base} from "../integration/utils/VaultRealV4Base.sol";

/**
 * @title M5 lifecycle handler on real Uniswap v4
 * @notice Random pair and ERC-4626 deposits, pair withdrawals, redemptions, fee-generating swaps, fee collection,
 *         keeper compounds, protocol-fee changes (including values above the cap), pause and oracle outages against
 *         one vault on the native ETH/USDC pool. Every fee-collecting action adds `floor(F * effectiveBps / 10_000)`
 *         to a ghost total, computed from Uniswap's own fee growth before the action.
 */
contract VaultM5RealV4Handler is VaultRealV4Base {
    uint256 internal constant MAX_PROTOCOL_FEE_BPS = 10_000;

    Vault public vault;
    PoolKey internal _key;
    address[] internal _actors;
    address public keeper = makeAddr("keeper");
    bytes32 public configHash;

    uint256 public ghostFee0;
    uint256 public ghostFee1;
    uint256 public mispricedWithdrawals;
    uint256 public overpaidDeposits;
    uint256 public failedWithdrawals;
    uint256 public forcedEth;
    bool public oracleDown;
    address public goodCollector;
    address internal _rejectingCollector;

    uint256 public pairWithdrawals;
    uint256 public collections;
    uint256 public compounds;
    uint256 public pairDeposits;

    constructor() {
        setUp();
        _key = _nativeUsdcKey();
        int24 tick = _initPool(_key, 2000e6, 1e18, false);
        _seedExternalLiquidity(_key, tick, 1e15);
        vault = _newVault(_key, 1, tick, 3000, 3000);
        _actors.push(alice);
        _actors.push(bob);
        _actors.push(attacker);
        factoryKeepers[keeper] = true;
        factoryFeeBps = 1_000;
        goodCollector = factoryFeeCollector;
        _rejectingCollector = address(new EthRejectingCollector());
        configHash = keccak256(abi.encode(vault.config()));
        _deposit(vault, alice, 50 ether, 150_000e6);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------------------------------------------------

    function depositPair(uint256 who, uint256 amount0, uint256 amount1) external {
        address actor = _actors[who % _actors.length];
        amount0 = bound(amount0, 1e12, 100 ether);
        amount1 = bound(amount1, 1e4, 300_000e6);
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
        } catch {}
    }

    function depositAsset(uint256 who, uint256 assets) external {
        address actor = _actors[who % _actors.length];
        assets = bound(assets, 1e4, 300_000e6);
        vm.prank(actor);
        try vault.deposit(assets, actor) returns (uint256) {} catch {}
    }

    function withdrawPair(uint256 who, uint256 fraction) external {
        address actor = _actors[who % _actors.length];
        uint256 shares = Math.mulDiv(vault.balanceOf(actor), bound(fraction, 1, 10_000), 10_000);
        if (shares == 0) return;
        (uint160 sp,,,) = stateView.getSlot0(_poolId(_key));
        (uint256 f0, uint256 f1) = pending();
        uint256 expected = Math.mulDiv(shares, vault.totalAssets(), vault.totalSupply());
        vm.prank(actor);
        try vault.withdrawPair(shares, 0, 0, actor) returns (uint256 out0, uint256 out1) {
            pairWithdrawals++;
            _addFee(f0, f1);
            uint256 got = _valueAt(out0, out1, sp);
            uint256 diff = got > expected ? got - expected : expected - got;
            if (diff > 10 + expected / 1e9) mispricedWithdrawals++;
        } catch {
            failedWithdrawals++;
        }
    }

    function redeem(uint256 who, uint256 fraction) external {
        address actor = _actors[who % _actors.length];
        uint256 shares = Math.mulDiv(vault.maxRedeem(actor), bound(fraction, 1, 10_000), 10_000);
        if (shares == 0) return;
        vm.prank(actor);
        try vault.redeem(shares, actor, actor) returns (uint256) {} catch {}
    }

    function collectFees() external {
        (uint256 f0, uint256 f1) = pending();
        vm.prank(attacker);
        try vault.collectFees() returns (uint256 fee0, uint256 fee1) {
            collections++;
            if (fee0 != f0 || fee1 != f1) mispricedWithdrawals++; // collected fees must equal Uniswap's pending fees
            _addFee(f0, f1);
        } catch {}
    }

    function compound(uint256 usdcIdle, uint256 ethIdle) external {
        usdc.mint(address(vault), bound(usdcIdle, 0, 20_000e6));
        vm.deal(address(vault), address(vault).balance + bound(ethIdle, 0, 10 ether));
        (uint256 f0, uint256 f1) = pending();
        vm.prank(keeper);
        try vault.compound() returns (uint256, uint256) {
            compounds++;
            _addFee(f0, f1);
        } catch {}
    }

    function swapNoise(bool zeroForOne, uint256 size) external {
        if (zeroForOne) _swap(attacker, _key, true, bound(size, 0.01 ether, 20 ether));
        else _swap(attacker, _key, false, bound(size, 20e6, 40_000e6));
        if (!oracleDown) _syncOracleToNativePool(_key);
    }

    /**
     * Healthy collector, unset collector, or a contract that rejects ETH: fee paths that must deliver revert, and
     * withdrawals forfeit the fee instead of failing.
     */
    function setCollector(uint256 mode) external {
        mode = mode % 3;
        factoryFeeCollector = mode == 0 ? goodCollector : mode == 1 ? address(0) : _rejectingCollector;
    }

    function setProtocolFee(uint256 bps) external {
        factoryFeeBps = bound(bps, 0, 20_000); // above 10,000 exercises the vault's clamp
    }

    function togglePause(bool doPause) external {
        if (doPause) {
            vm.prank(guardianAccount);
            vault.pause();
        } else {
            vm.prank(timelockAccount);
            vault.unpause();
        }
    }

    function toggleOracle(bool down) external {
        oracleDown = down;
        if (down) {
            vm.mockCallRevert(address(guard), abi.encodeWithSelector(IPriceGuard.isPriceTrusted.selector), "down");
        } else {
            vm.clearMockedCalls();
            _syncOracleToNativePool(_key);
        }
    }

    function forceEthIntoPositionManager(uint256 amount) external {
        amount = bound(amount, 1, 1 ether);
        vm.deal(address(posm), address(posm).balance + amount);
        forcedEth += amount;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 30 minutes));
        if (!oracleDown) _syncOracleToNativePool(_key);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Probes used by the invariants (not fuzz targets)
    // ------------------------------------------------------------------------------------------------------------

    /**
     * @notice Every holder exits in turn; returns how many exits failed, the summed exit value and the value the
     *         vault reported before (plus any protocol fee a broken collector will forfeit to the holders). All state
     *         is rolled back.
     */
    function probeEveryoneExits() external returns (uint256 failures, uint256 paidValue, uint256 reported) {
        uint256 snap = vm.snapshotState();
        (uint160 sp,,,) = stateView.getSlot0(_poolId(_key));
        reported = vault.totalAssets();
        if (factoryFeeCollector != goodCollector) {
            // a protocol fee the first exit cannot deliver stays with the holders: allow exactly that much more
            (uint256 f0, uint256 f1) = pending();
            uint256 bps = factoryFeeBps < MAX_PROTOCOL_FEE_BPS ? factoryFeeBps : MAX_PROTOCOL_FEE_BPS;
            reported += _valueAt(f0 * bps / 10_000, f1 * bps / 10_000, sp);
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

    function collector() external view returns (address) {
        return goodCollector;
    }

    function usdcBalanceOf(address who) external view returns (uint256) {
        return usdc.balanceOf(who);
    }

    function posmAddress() external view returns (address) {
        return address(posm);
    }

    function permit2Allowance(address owner_) external view returns (uint160 amount) {
        (amount,,) = permit2.allowance(owner_, USDC_ADDR, address(posm));
    }

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    function _addFee(uint256 f0, uint256 f1) internal {
        if (factoryFeeCollector != goodCollector) return; // the ghost tracks the healthy collector only
        uint256 bps = factoryFeeBps < MAX_PROTOCOL_FEE_BPS ? factoryFeeBps : MAX_PROTOCOL_FEE_BPS;
        ghostFee0 += f0 * bps / 10_000;
        ghostFee1 += f1 * bps / 10_000;
    }

    function _valueAt(uint256 a0, uint256 a1, uint160 sp) internal pure returns (uint256) {
        return Math.mulDiv(a0, Math.mulDiv(sp, sp, 1 << 96), 1 << 96) + a1;
    }
}

/**
 * forge-config: default.invariant.runs = 256
 * forge-config: default.invariant.depth = 64
 * forge-config: ci.invariant.runs = 1000
 * forge-config: ci.invariant.depth = 128
 */
contract VaultM5RealV4InvariantTest is Test {
    VaultM5RealV4Handler internal handler;
    Vault internal vault;

    function setUp() public {
        handler = new VaultM5RealV4Handler();
        vault = handler.vault();
        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = VaultM5RealV4Handler.depositPair.selector;
        selectors[1] = VaultM5RealV4Handler.depositAsset.selector;
        selectors[2] = VaultM5RealV4Handler.withdrawPair.selector;
        selectors[3] = VaultM5RealV4Handler.redeem.selector;
        selectors[4] = VaultM5RealV4Handler.collectFees.selector;
        selectors[5] = VaultM5RealV4Handler.compound.selector;
        selectors[6] = VaultM5RealV4Handler.swapNoise.selector;
        selectors[7] = VaultM5RealV4Handler.setProtocolFee.selector;
        selectors[8] = VaultM5RealV4Handler.togglePause.selector;
        selectors[9] = VaultM5RealV4Handler.toggleOracle.selector;
        selectors[10] = VaultM5RealV4Handler.forceEthIntoPositionManager.selector;
        selectors[11] = VaultM5RealV4Handler.warp.selector;
        selectors[12] = VaultM5RealV4Handler.swapNoise.selector;
        selectors[13] = VaultM5RealV4Handler.setCollector.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /**
     * Sanity: every action really succeeds at least once, including withdrawals under pause and oracle outage.
     */
    function test_handler_reaches_every_fee_path() public {
        handler.swapNoise(true, 5 ether);
        handler.swapNoise(false, 20_000e6);
        handler.depositPair(1, 2 ether, 6_000e6);
        handler.swapNoise(true, 5 ether);
        handler.collectFees();
        handler.swapNoise(false, 20_000e6);
        handler.compound(5_000e6, 2 ether);
        handler.setProtocolFee(13_900);
        handler.swapNoise(true, 5 ether);
        handler.togglePause(true);
        handler.toggleOracle(true);
        handler.withdrawPair(0, 5_000);
        require(handler.pairDeposits() == 1, "pair deposit must succeed");
        require(handler.collections() == 1, "collect must succeed");
        require(handler.compounds() == 1, "compound must succeed");
        require(handler.pairWithdrawals() == 1, "withdraw must succeed while paused and oracle down");
        require(handler.ghostFee0() > 0 && handler.ghostFee1() > 0, "fees must have been charged");
        handler.swapNoise(false, 20_000e6);
        handler.setCollector(2);
        handler.withdrawPair(0, 5_000);
        handler.setCollector(1);
        handler.swapNoise(true, 5 ether);
        handler.withdrawPair(0, 5_000);
        require(handler.pairWithdrawals() == 3, "withdrawals must survive a broken collector");
        invariant_protocol_fee_is_exactly_fee_bps_of_collected_fees();
        invariant_every_holder_can_exit_and_exits_never_exceed_total_assets();
        invariant_withdrawals_pay_the_reported_share_value();
    }

    function invariant_protocol_fee_is_exactly_fee_bps_of_collected_fees() public view {
        address c = handler.collector();
        require(c.balance == handler.ghostFee0(), "ETH protocol fee differs from feeBps of collected fees");
        require(handler.usdcBalanceOf(c) == handler.ghostFee1(), "USDC protocol fee differs");
    }

    function invariant_every_holder_can_exit_and_exits_never_exceed_total_assets() public {
        (uint256 failures, uint256 paid, uint256 reported) = handler.probeEveryoneExits();
        require(failures == 0, "a holder could not withdraw");
        require(paid <= reported + 30, "holders could withdraw more than totalAssets");
    }

    function invariant_withdrawals_pay_the_reported_share_value() public view {
        require(handler.mispricedWithdrawals() == 0, "a withdrawal or collection paid a different value");
        require(handler.failedWithdrawals() == 0, "a withdrawal reverted");
        require(handler.overpaidDeposits() == 0, "a depositor received shares worth more than they paid");
    }

    function invariant_custody_is_clean() public view {
        Band[] memory b = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            require(PosmView(handler.posmAddress()).ownerOf(b[i].tokenId) == address(vault), "band NFT not owned");
            require(handler.realLiquidity(b[i]) == b[i].liquidity, "stored liquidity differs from the position");
        }
        require(handler.usdcBalanceOf(handler.posmAddress()) == 0, "PositionManager kept USDC");
        require(handler.posmAddress().balance <= handler.forcedEth(), "PositionManager kept vault ETH");
        require(handler.permit2Allowance(address(vault)) == 0, "standing Permit2 allowance");
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
}

contract EthRejectingCollector {
    receive() external payable {
        revert("no ETH");
    }
}

interface PosmView {
    function ownerOf(uint256 id) external view returns (address);
}
