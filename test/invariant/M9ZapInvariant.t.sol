// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vault} from "../../src/Vault.sol";
import {Zap} from "../../src/Zap.sol";
import {PoolKey, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {M9ZapRealV4Base} from "../integration/M9ZapRealV4.t.sol";

contract M9ZapInvariantTest is M9ZapRealV4Base {
    Vault internal invariantVault;
    M9ZapHandler internal handler;

    function setUp() public override {
        super.setUp();
        PoolKey memory key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY * 10);
        invariantVault = _newVaultWith(_invariantConfig(key, _alignInvariant(tick, key.tickSpacing)), address(normal));
        handler = new M9ZapHandler(zap, invariantVault, IERC20(USDC_ADDR));
        usdc.mint(address(handler), 10_000_000e6);
        vm.deal(address(handler), 10_000 ether);
        handler.approveZap();
        targetContract(address(handler));
    }

    function invariant_zapRetainsNoCallLocalAssets() public view {
        assertEq(address(zap).balance, 0);
        assertEq(usdc.balanceOf(address(zap)), 0);
    }

    function invariant_zapLeavesNoStandingApprovals() public view {
        assertEq(usdc.allowance(address(zap), address(invariantVault)), 0);
        assertEq(usdc.allowance(address(zap), address(executor)), 0);
    }

    function invariant_successfulCallsAlwaysMintShares() public view {
        assertEq(handler.successes() == 0, invariantVault.balanceOf(address(handler)) == 0);
    }

    /**
     * Small zaps into a deep, oracle-aligned pool must never fail; a swallowed revert would hide a liveness bug.
     */
    function invariant_zapsNeverFail() public view {
        assertEq(handler.failures(), 0, "a zap reverted");
    }

    function _invariantConfig(PoolKey memory key, int24 center) private pure returns (VaultConfig memory config) {
        config.poolKey = key;
        config.strategy = Strategy.NormalLP;
        config.shapeId = 2;
        config.centerTick = center;
        config.ticksLeft = 600;
        config.ticksRight = 600;
        config.driftTicks = 100;
        config.autoRebalance = true;
        config.baseIsCurrency0 = true;
    }

    function _alignInvariant(int24 tick, int24 spacing) private pure returns (int24 aligned) {
        int256 quotient = int256(tick) / int256(spacing);
        if (tick < 0 && tick % spacing != 0) --quotient;
        aligned = int24(quotient * int256(spacing));
    }
}

contract M9ZapHandler {
    Zap internal immutable zap;
    Vault internal immutable vault;
    IERC20 internal immutable usdc;
    uint256 public successes;
    uint256 public failures;
    bytes4 public lastFailure;

    constructor(Zap zap_, Vault vault_, IERC20 usdc_) {
        zap = zap_;
        vault = vault_;
        usdc = usdc_;
    }

    function approveZap() external {
        usdc.approve(address(zap), type(uint256).max);
    }

    function depositNative() external {
        try zap.zapDeposit{value: 0.01 ether}(address(vault), address(0), 0.01 ether, 0, 100, address(this)) {
            ++successes;
        } catch (bytes memory reason) {
            ++failures;
            lastFailure = bytes4(reason);
        }
    }

    function depositUsdc() external {
        try zap.zapDeposit(address(vault), address(usdc), 20e6, 0, 100, address(this)) {
            ++successes;
        } catch (bytes memory reason) {
            ++failures;
            lastFailure = bytes4(reason);
        }
    }

    receive() external payable {}
}
