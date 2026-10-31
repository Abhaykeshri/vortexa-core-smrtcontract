// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Vault} from "../../src/Vault.sol";
import {Zap} from "../../src/Zap.sol";
import {ISwapExecutor} from "../../src/interfaces/ISwapExecutor.sol";
import {IZap} from "../../src/interfaces/IZap.sol";
import {PoolKey, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {M9ZapRealV4Base} from "../integration/M9ZapRealV4.t.sol";

contract M9ZapAttacksTest is M9ZapRealV4Base {
    function test_feeOnTransferStyleShortfallReverts() public {
        Vault vault = _attackVault();
        vm.mockCall(USDC_ADDR, abi.encodeWithSignature("transferFrom(address,address,uint256)"), abi.encode(true));
        vm.prank(alice);
        vm.expectRevert(Zap.TokenTransferShortfall.selector);
        zap.zapDeposit(address(vault), USDC_ADDR, 2_000e6, 0, 100, alice);
    }

    function test_forcedDustCannotBeStolenOrUsedToSubsidizeDeposit() public {
        Vault vault = _attackVault();
        uint256 donatedUsdc = 777e6;
        uint256 donatedEth = 3 ether;
        usdc.transfer(address(zap), donatedUsdc);
        vm.deal(address(zap), donatedEth);

        vm.prank(alice);
        uint256 shares = zap.zapDeposit(address(vault), USDC_ADDR, 2_000e6, 0, 100, alice);

        assertGt(shares, 0);
        assertEq(usdc.balanceOf(address(zap)), donatedUsdc);
        assertEq(address(zap).balance, donatedEth);
    }

    function test_oracleDeviationAfterSandwichLegReverts() public {
        Vault vault = _attackVault();
        _swap(attacker, _nativeUsdcKey(), true, 500 ether);
        vm.prank(alice);
        vm.expectRevert(ISwapExecutor.UntrustedPrice.selector);
        zap.zapDeposit(address(vault), USDC_ADDR, 10_000e6, 0, 100, alice);
    }

    function test_unauthorizedCallerCannotUseExecutor() public {
        PoolKey memory key = _nativeUsdcKey();
        vm.prank(attacker);
        vm.expectRevert(ISwapExecutor.UnauthorizedCaller.selector);
        executor.swapExactInput(key, true, 1 ether, 0);
    }

    function test_invalidVaultExecutorPairingIsRejectedBeforeFundsMove() public {
        Vault vault = _attackVault();
        factoryVaults[address(vault)] = false;
        uint256 beforeBalance = usdc.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(IZap.UnknownVault.selector);
        zap.zapDeposit(address(vault), USDC_ADDR, 2_000e6, 0, 100, alice);
        assertEq(usdc.balanceOf(alice), beforeBalance);
    }

    function test_reentrantNativeRefundReceiverCannotEnterZap() public {
        Vault vault = _attackVault();
        ReentrantM9Receiver receiver = new ReentrantM9Receiver(zap, vault);
        vm.deal(address(receiver), 5 ether);
        receiver.attack{value: 2 ether}();
        assertFalse(receiver.reentered());
        assertGt(vault.balanceOf(address(receiver)), 0);
    }

    function _attackVault() private returns (Vault vault) {
        PoolKey memory key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);
        vault = _newVaultWith(_normalConfigAttack(key, _alignAttack(tick, key.tickSpacing)), address(normal));
    }

    function _normalConfigAttack(PoolKey memory key, int24 center) private pure returns (VaultConfig memory config) {
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

    function _alignAttack(int24 tick, int24 spacing) private pure returns (int24 aligned) {
        int256 quotient = int256(tick) / int256(spacing);
        if (tick < 0 && tick % spacing != 0) --quotient;
        aligned = int24(quotient * int256(spacing));
    }
}

contract ReentrantM9Receiver {
    Zap private immutable zap;
    Vault private immutable vault;
    bool public reentered;

    constructor(Zap zap_, Vault vault_) {
        zap = zap_;
        vault = vault_;
    }

    function attack() external payable {
        zap.zapDeposit{value: msg.value}(address(vault), address(0), msg.value, 0, 100, address(this));
    }

    receive() external payable {
        try zap.zapDeposit{value: 1}(address(vault), address(0), 1, 0, 0, address(this)) {
            reentered = true;
        } catch {}
    }
}
