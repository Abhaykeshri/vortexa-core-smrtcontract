// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vault} from "../../src/Vault.sol";
import {Band, PoolKey, RebalanceParams, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";
import {VaultRealV4Base} from "../integration/utils/VaultRealV4Base.sol";
import {TestNormalLPStrategy} from "../utils/TestNormalLPStrategy.sol";

/**
 * @title M6 lifecycle handler on real Uniswap v4
 * @notice Random deposits, withdrawals, attacker price pushes, organic volume, keeper rebalances with hostile centers
 *         and tolerances, fee collections, compounds, protocol-fee changes and time, on the native ETH/USDC pool,
 *         with swaps through the real V4Router pipeline. Ghosts record the protocol fee owed on every collection and
 *         every rebalance whose loss at the oracle price exceeded the keeper's tolerance.
 */
contract VaultM6RealV4Handler is VaultRealV4Base {
    uint128 internal constant DEEP = 2e17;

    Vault public vault;
    TestNormalLPStrategy public planner;
    PoolKey internal _key;
    address[] internal _actors;
    address public keeper = makeAddr("keeper");
    bytes32 public configHash;

    uint256 public ghostFee0;
    uint256 public ghostFee1;
    uint256 public lossBoundViolations;
    uint256 public cooldownViolations;
    uint256 public failedWithdrawals;
    uint256 public rebalances;
    uint256 public lastRebalanceSeen;

    constructor() {
        setUp();
        planner = new TestNormalLPStrategy(shapes);
        _key = _nativeUsdcKey();
        int24 tick = _initPool(_key, 2000e6, 1e18, false);
        _seedExternalLiquidity(_key, tick, DEEP);
        VaultConfig memory cfg;
        cfg.poolKey = _key;
        cfg.strategy = Strategy.NormalLP;
        cfg.shapeId = 1;
        cfg.centerTick = tick / 10 * 10;
        cfg.ticksLeft = 600;
        cfg.ticksRight = 600;
        cfg.autoRebalance = true;
        cfg.baseIsCurrency0 = true;
        vault = _newVaultWith(cfg, address(planner));
        _actors.push(alice);
        _actors.push(bob);
        factoryKeepers[keeper] = true;
        factoryFeeBps = 1_000;
        configHash = keccak256(abi.encode(vault.config()));
        _deposit(vault, alice, 40 ether, 120_000e6);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------------------------------------------------

    function depositPair(uint256 who, uint256 amount0, uint256 amount1) external {
        address actor = _actors[who % _actors.length];
        amount0 = bound(amount0, 0.01 ether, 30 ether);
        amount1 = bound(amount1, 20e6, 90_000e6);
        (uint256 f0, uint256 f1) = pending();
        vm.prank(actor);
        try vault.depositPair{value: amount0}(amount0, amount1, 0, actor) returns (uint256, uint256, uint256) {
            _addFee(f0, f1);
        } catch {}
    }

    function withdrawPair(uint256 who, uint256 fraction) external {
        address actor = _actors[who % _actors.length];
        uint256 shares = Math.mulDiv(vault.balanceOf(actor), bound(fraction, 1, 10_000), 10_000);
        if (shares == 0) return;
        (uint256 f0, uint256 f1) = pending();
        vm.prank(actor);
        try vault.withdrawPair(shares, 0, 0, actor) returns (uint256, uint256) {
            _addFee(f0, f1);
        } catch {
            failedWithdrawals++;
        }
    }

    function organicVolume(uint256 size) external {
        _swap(attacker, _key, true, bound(size, 0.1 ether, 10 ether));
        _swap(attacker, _key, false, bound(size, 200e6, 20_000e6));
        _syncOracleToNativePool(_key);
    }

    /**
     * Attacker moves the pool without the oracle following (sandwich set-up, or pushing beyond tolerance).
     */
    function attackerPush(bool down, uint256 size) external {
        if (down) _swap(attacker, _key, true, bound(size, 0.1 ether, 15 ether));
        else _swap(attacker, _key, false, bound(size, 200e6, 30_000e6));
    }

    function trendAndFollow(bool down, uint256 size) external {
        if (down) _swap(attacker, _key, true, bound(size, 1 ether, 25 ether));
        else _swap(attacker, _key, false, bound(size, 2_000e6, 50_000e6));
        _syncOracleToNativePool(_key);
    }

    function rebalance(int256 centerOffset, uint256 slippage) external {
        (, int24 tick,,) = stateView.getSlot0(_poolId(_key));
        int24 center = int24(int256(tick) + bound(centerOffset, -250, 250)) / 10 * 10;
        uint16 slip = uint16(bound(slippage, 0, 120));
        uint160 ref;
        try guard.referenceSqrtPriceX96(_key) returns (uint160 r) {
            ref = r;
        } catch {
            return;
        }
        uint256 before = valueAtRef(ref);
        (uint256 f0, uint256 f1) = pending();
        vm.prank(keeper);
        try vault.rebalance(RebalanceParams({newCenterTick: center, maxSlippageBps: slip})) {
            rebalances++;
            _addFee(f0, f1);
            if (lastRebalanceSeen != 0 && block.timestamp < lastRebalanceSeen + 30 minutes) cooldownViolations++;
            lastRebalanceSeen = block.timestamp;
            if (valueAtRef(ref) + 2 < Math.mulDiv(before, 10_000 - slip, 10_000)) lossBoundViolations++;
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
        } catch {}
    }

    function setProtocolFee(uint256 bps) external {
        factoryFeeBps = bound(bps, 0, 15_000);
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 minutes, 45 minutes));
        _syncOracleToNativePool(_key);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Probes
    // ------------------------------------------------------------------------------------------------------------

    function probeEveryoneExits() external returns (uint256 failures, uint256 paidValue, uint256 reported) {
        uint256 snap = vm.snapshotState();
        (uint160 sp,,,) = stateView.getSlot0(_poolId(_key));
        reported = vault.totalAssets();
        for (uint256 i; i < _actors.length; ++i) {
            uint256 shares = vault.balanceOf(_actors[i]);
            if (shares == 0) continue;
            vm.prank(_actors[i]);
            try vault.withdrawPair(shares, 0, 0, _actors[i]) returns (uint256 out0, uint256 out1) {
                paidValue += Math.mulDiv(out0, Math.mulDiv(sp, sp, 1 << 96), 1 << 96) + out1;
            } catch {
                failures++;
            }
        }
        vm.revertToState(snap);
    }

    function valueAtRef(uint160 ref) public view returns (uint256) {
        uint256 amount0 = address(vault).balance;
        uint256 amount1 = usdc.balanceOf(address(vault));
        (uint256 f0, uint256 f1) = pending();
        uint256 bps = factoryFeeBps < 10_000 ? factoryFeeBps : 10_000;
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
        return Math.mulDiv(amount0, Math.mulDiv(ref, ref, 1 << 96), 1 << 96) + amount1;
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
        return factoryFeeCollector;
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

    function _addFee(uint256 f0, uint256 f1) internal {
        uint256 bps = factoryFeeBps < 10_000 ? factoryFeeBps : 10_000;
        ghostFee0 += f0 * bps / 10_000;
        ghostFee1 += f1 * bps / 10_000;
    }
}

/**
 * forge-config: default.invariant.runs = 256
 * forge-config: default.invariant.depth = 64
 * forge-config: ci.invariant.runs = 1000
 * forge-config: ci.invariant.depth = 128
 */
contract VaultM6RealV4InvariantTest is Test {
    VaultM6RealV4Handler internal handler;
    Vault internal vault;

    function setUp() public {
        handler = new VaultM6RealV4Handler();
        vault = handler.vault();
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = VaultM6RealV4Handler.depositPair.selector;
        selectors[1] = VaultM6RealV4Handler.withdrawPair.selector;
        selectors[2] = VaultM6RealV4Handler.organicVolume.selector;
        selectors[3] = VaultM6RealV4Handler.attackerPush.selector;
        selectors[4] = VaultM6RealV4Handler.trendAndFollow.selector;
        selectors[5] = VaultM6RealV4Handler.rebalance.selector;
        selectors[6] = VaultM6RealV4Handler.rebalance.selector;
        selectors[7] = VaultM6RealV4Handler.collectFees.selector;
        selectors[8] = VaultM6RealV4Handler.compound.selector;
        selectors[9] = VaultM6RealV4Handler.setProtocolFee.selector;
        selectors[10] = VaultM6RealV4Handler.warp.selector;
        selectors[11] = VaultM6RealV4Handler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /**
     * Sanity: rebalances (with swaps) really happen under the handler, alongside collections and exits.
     */
    function test_handler_reaches_successful_rebalances() public {
        handler.organicVolume(5 ether);
        handler.trendAndFollow(true, 20 ether);
        handler.warp(31 minutes);
        handler.rebalance(0, 60);
        handler.withdrawPair(0, 3_000);
        handler.trendAndFollow(false, 40_000e6);
        handler.warp(31 minutes);
        handler.rebalance(30, 100);
        require(handler.rebalances() == 2, "both rebalances must succeed");
        require(handler.ghostFee0() + handler.ghostFee1() > 0, "fees charged");
        invariant_protocol_fee_is_exact();
        invariant_rebalance_loss_never_exceeds_the_keeper_tolerance();
        invariant_every_holder_can_exit_and_exits_never_exceed_total_assets();
        invariant_custody_is_clean();
    }

    function invariant_protocol_fee_is_exact() public view {
        address c = handler.collector();
        require(c.balance == handler.ghostFee0(), "ETH protocol fee differs from feeBps of collected fees");
        require(handler.usdcOf(c) == handler.ghostFee1(), "USDC protocol fee differs");
    }

    function invariant_rebalance_loss_never_exceeds_the_keeper_tolerance() public view {
        require(handler.lossBoundViolations() == 0, "a rebalance lost more than its tolerance at the oracle price");
        require(handler.cooldownViolations() == 0, "two rebalances inside the cooldown");
    }

    function invariant_every_holder_can_exit_and_exits_never_exceed_total_assets() public {
        require(handler.failedWithdrawals() == 0, "a withdrawal reverted");
        (uint256 failures, uint256 paid, uint256 reported) = handler.probeEveryoneExits();
        require(failures == 0, "a holder could not withdraw");
        require(paid <= reported + 30, "holders could withdraw more than totalAssets");
    }

    function invariant_custody_is_clean() public view {
        Band[] memory b = vault.bands();
        for (uint256 i; i < b.length; ++i) {
            require(PosmView(handler.posmAddress()).ownerOf(b[i].tokenId) == address(vault), "band NFT not owned");
            require(handler.realLiquidity(b[i]) == b[i].liquidity, "stored liquidity differs from the position");
        }
        require(PosmView(handler.posmAddress()).balanceOf(address(vault)) == b.length, "orphaned NFT");
        require(handler.usdcOf(handler.posmAddress()) == 0, "PositionManager kept USDC");
        require(handler.usdcOf(handler.executorAddress()) == 0, "executor kept USDC");
        require(handler.executorAddress().balance == 0, "executor kept ETH");
        require(handler.usdcOf(handler.routerAddress()) == 0, "router kept USDC");
        require(handler.routerAddress().balance == 0, "router kept ETH");
        require(handler.standingAllowances() == 0, "standing allowance");
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

interface PosmView {
    function ownerOf(uint256 id) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
}
