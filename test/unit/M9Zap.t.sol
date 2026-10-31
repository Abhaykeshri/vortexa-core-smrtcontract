// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Vault} from "../../src/Vault.sol";
import {BuyTheDipStrategy} from "../../src/strategies/BuyTheDipStrategy.sol";
import {NormalLPStrategy} from "../../src/strategies/NormalLPStrategy.sol";
import {SellThePumpStrategy} from "../../src/strategies/SellThePumpStrategy.sol";
import {Zap} from "../../src/Zap.sol";
import {IZap} from "../../src/interfaces/IZap.sol";
import {IZapFactory, IZapSwapExecutor} from "../../src/interfaces/IZapDependencies.sol";
import {PoolKey, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {IV4Router} from "uni-test/v4-periphery/src/interfaces/IV4Router.sol";
import {M9ZapRealV4Base} from "../integration/M9ZapRealV4.t.sol";

contract M9ZapUnitTest is M9ZapRealV4Base {
    /**
     * Each case is an external self-call: after `vm.expectRevert`, a `new` of a contract from another file ends the
     * test body, so a second inline case would never run.
     */
    function test_constructorRejectsInvalidDependencies() public {
        address e = address(executor);
        address n = address(normal);
        address d = address(dip);
        address p = address(pump);
        address noCode = makeAddr("not-code");
        address[5][8] memory cases = [
            [address(0), e, n, d, p],
            [address(this), address(0), n, d, p],
            [address(this), e, noCode, d, p],
            [address(this), e, n, noCode, p],
            [address(this), e, n, d, noCode],
            [address(this), e, n, n, p],
            [address(this), e, n, d, n],
            [address(this), e, n, d, d]
        ];
        for (uint256 i; i < cases.length; ++i) {
            vm.expectRevert(Zap.InvalidDependency.selector);
            this.deployZap(cases[i]);
        }
        assertTrue(this.deployZap([address(this), e, n, d, p]) != address(0), "valid set deploys");
    }

    function deployZap(address[5] memory deps) external returns (address) {
        return address(new Zap(IZapFactory(deps[0]), IZapSwapExecutor(deps[1]), deps[2], deps[3], deps[4]));
    }

    function test_unknownVaultAndBadTokenRevert() public {
        vm.expectRevert(IZap.UnknownVault.selector);
        zap.quoteZap(makeAddr("unknown"), USDC_ADDR, 1e6);

        Vault vault = _unitNormalVault();
        vm.expectRevert(IZap.BadToken.selector);
        zap.quoteZap(address(vault), makeAddr("wrong-token"), 1e18);
    }

    function test_zeroAmountAndReceiverValidation() public {
        Vault vault = _unitNormalVault();
        vm.expectRevert(Zap.ZeroAmount.selector);
        zap.quoteZap(address(vault), USDC_ADDR, 0);

        vm.prank(alice);
        vm.expectRevert(Zap.ZeroAmount.selector);
        zap.zapDeposit(address(vault), USDC_ADDR, 0, 0, 0, alice);

        vm.expectRevert(IZap.ZeroReceiver.selector);
        zap.zapDeposit(address(vault), USDC_ADDR, 1e6, 0, 0, address(0));

        vm.expectRevert(Zap.SelfReceiver.selector);
        zap.zapDeposit(address(vault), USDC_ADDR, 1e6, 0, 0, address(zap));
    }

    function test_slippageAndNativeValueValidation() public {
        Vault vault = _unitNormalVault();
        vm.expectRevert(IZap.SlippageTooHigh.selector);
        zap.zapDeposit(address(vault), USDC_ADDR, 1e6, 0, 101, alice);

        vm.expectRevert(Zap.InvalidNativeValue.selector);
        zap.zapDeposit(address(vault), address(0), 1 ether, 0, 0, alice);

        vm.expectRevert(Zap.InvalidNativeValue.selector);
        zap.zapDeposit{value: 1}(address(vault), USDC_ADDR, 1e6, 0, 0, alice);
    }

    function test_minSharesProtectsDeposit() public {
        Vault vault = _unitNormalVault();
        vm.prank(alice);
        vm.expectRevert(Vault.SlippageExceeded.selector);
        zap.zapDeposit(address(vault), USDC_ADDR, 2_000e6, type(uint256).max, 100, alice);
    }

    function test_strategyIdentityCannotDivergeSilently() public {
        PoolKey memory key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);
        Vault vault = _newVaultWith(_normalConfigUnit(key, _alignUnit(tick, key.tickSpacing)), address(strategy));
        vm.expectRevert(Zap.UnsupportedStrategy.selector);
        zap.quoteZap(address(vault), USDC_ADDR, 1_000e6);
    }

    function test_emitsDepositEventAndLeavesNoAllowances() public {
        Vault vault = _unitNormalVault();
        uint256 amount = 3_000e6;
        (uint256 swapAmount,) = zap.quoteZap(address(vault), USDC_ADDR, amount);
        vm.expectEmit(true, true, false, false, address(zap));
        emit Zap.ZapRefunded(alice, address(vault), 0, 0);
        vm.expectEmit(true, true, true, false, address(zap));
        emit Zap.ZapDeposited(alice, address(vault), USDC_ADDR, amount, swapAmount, 0, bob);
        vm.prank(alice);
        uint256 shares = zap.zapDeposit(address(vault), USDC_ADDR, amount, 0, 100, bob);
        assertGt(shares, 0);
        assertEq(usdc.allowance(address(zap), address(vault)), 0);
        assertEq(usdc.allowance(address(zap), address(executor)), 0);
    }

    /**
     * `zapDeposit` binds each strategy kind to the contract pinned for it before any funds move: a vault running an
     * unknown strategy, or another deployment of the right kind that this Zap does not pin, is refused.
     */
    function test_zapDepositRejectsMismatchedStrategyContracts() public {
        PoolKey memory key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);
        VaultConfig memory normalCfg = _normalConfigUnit(key, _alignUnit(tick, key.tickSpacing));
        Vault[4] memory vaults = [
            _newVaultWith(normalCfg, address(strategy)),
            _newVaultWith(normalCfg, address(new NormalLPStrategy(shapes))),
            _newVaultWith(_oneSidedConfigUnit(key, Strategy.BuyTheDip), address(new BuyTheDipStrategy(shapes))),
            _newVaultWith(_oneSidedConfigUnit(key, Strategy.SellThePump), address(new SellThePumpStrategy(shapes)))
        ];
        for (uint256 i; i < vaults.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(Zap.UnsupportedStrategy.selector);
            zap.zapDeposit(address(vaults[i]), USDC_ADDR, 1_000e6, 0, 100, alice);
        }
    }

    /**
     * A registered vault must also be wired to this Zap's factory, executor and PriceGuard, and the executor to the
     * same factory; any foreign link is refused for quotes and deposits alike.
     */
    function test_zapRefusesARegisteredVaultWithForeignWiring() public {
        Vault vault = _unitNormalVault();
        address foreign = makeAddr("foreign");
        address[4] memory targets = [address(vault), address(vault), address(vault), address(executor)];
        string[4] memory getters = ["factory()", "swapExecutor()", "priceGuard()", "factory()"];
        for (uint256 i; i < targets.length; ++i) {
            vm.mockCall(targets[i], abi.encodeWithSignature(getters[i]), abi.encode(foreign));
            vm.expectRevert(Zap.InvalidVaultConfiguration.selector);
            zap.quoteZap(address(vault), USDC_ADDR, 1_000e6);
            vm.prank(alice);
            vm.expectRevert(Zap.InvalidVaultConfiguration.selector);
            zap.zapDeposit(address(vault), USDC_ADDR, 1_000e6, 0, 100, alice);
            vm.clearMockedCalls();
        }
    }

    /**
     * The Zap takes ETH only from the executor (swap output) and registered vaults (deposit refunds).
     */
    function test_zapRefusesEthFromAnyoneButTheExecutorOrAVault() public {
        Vault vault = _unitNormalVault();
        vm.prank(alice);
        (bool ok, bytes memory reason) = address(zap).call{value: 1}("");
        assertFalse(ok, "an EOA sent ETH");
        assertEq(bytes4(reason), Zap.InvalidEthSender.selector);
        address[2] memory allowed = [address(executor), address(vault)];
        for (uint256 i; i < allowed.length; ++i) {
            vm.deal(allowed[i], 1);
            vm.prank(allowed[i]);
            (ok,) = address(zap).call{value: 1}("");
            assertTrue(ok, "a trusted sender was refused");
        }
    }

    /**
     * The swap floor uses the caller's tolerance, not the executor cap: with the pool pushed against the zap's swap
     * (inside the oracle tolerance), a tight tolerance reverts and a loose one goes through.
     */
    function test_callerSlippageToleranceIsEnforced() public {
        Vault vault = _unitNormalVault();
        PoolKey memory key = _nativeUsdcKey();
        (, int24 start,,) = stateView.getSlot0(_poolId(key));
        for (uint256 i; i < 400; ++i) {
            (, int24 t,,) = stateView.getSlot0(_poolId(key));
            if (t >= start + 30) break;
            _swap(attacker, key, false, 2_000e6);
        }
        (bool trusted,) = guard.isPriceTrusted(key);
        assertTrue(trusted, "the push stays inside the oracle tolerance");

        vm.prank(alice);
        vm.expectPartialRevert(IV4Router.V4TooLittleReceived.selector);
        zap.zapDeposit(address(vault), USDC_ADDR, 10_000e6, 0, 10, alice);
        vm.prank(alice);
        assertGt(zap.zapDeposit(address(vault), USDC_ADDR, 10_000e6, 0, 100, alice), 0);
    }

    function _unitNormalVault() private returns (Vault vault) {
        PoolKey memory key = _nativeUsdcKey();
        int24 tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);
        vault = _newVaultWith(_normalConfigUnit(key, _alignUnit(tick, key.tickSpacing)), address(normal));
    }

    function _normalConfigUnit(PoolKey memory key, int24 center) private pure returns (VaultConfig memory config) {
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

    function _oneSidedConfigUnit(PoolKey memory key, Strategy kind) private pure returns (VaultConfig memory config) {
        bool below = kind == Strategy.BuyTheDip;
        config.poolKey = key;
        config.strategy = kind;
        config.shapeId = 3;
        config.ticksLeft = below ? int24(600) : int24(0);
        config.ticksRight = below ? int24(0) : int24(600);
        config.trailTicks = 100;
        config.autoRebalance = true;
        config.lockOnFill = true;
        config.baseIsCurrency0 = true;
    }

    function _alignUnit(int24 tick, int24 spacing) private pure returns (int24 aligned) {
        int256 quotient = int256(tick) / int256(spacing);
        if (tick < 0 && tick % spacing != 0) --quotient;
        aligned = int24(quotient * int256(spacing));
    }
}
