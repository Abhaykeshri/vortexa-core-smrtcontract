// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {BuyTheDipStrategy} from "../../src/strategies/BuyTheDipStrategy.sol";
import {NormalLPStrategy} from "../../src/strategies/NormalLPStrategy.sol";
import {SellThePumpStrategy} from "../../src/strategies/SellThePumpStrategy.sol";
import {Vault} from "../../src/Vault.sol";
import {Zap} from "../../src/Zap.sol";
import {IZapFactory, IZapSwapExecutor} from "../../src/interfaces/IZapDependencies.sol";
import {Currency, PoolKey, Strategy, VaultConfig} from "../../src/libraries/Types.sol";
import {VaultRealV4Base} from "./utils/VaultRealV4Base.sol";

abstract contract M9ZapRealV4Base is VaultRealV4Base {
    uint128 internal constant DEEP_LIQUIDITY = 2e18;

    NormalLPStrategy internal normal;
    BuyTheDipStrategy internal dip;
    SellThePumpStrategy internal pump;
    Zap internal zap;

    function setUp() public virtual override {
        super.setUp();
        normal = new NormalLPStrategy(shapes);
        dip = new BuyTheDipStrategy(shapes);
        pump = new SellThePumpStrategy(shapes);
        zap = new Zap(
            IZapFactory(address(this)),
            IZapSwapExecutor(address(executor)),
            address(normal),
            address(dip),
            address(pump)
        );
        assertEq(executor.zap(), address(zap), "predicted Zap mismatch");
        address[3] memory users = [alice, bob, attacker];
        for (uint256 i; i < users.length; ++i) {
            vm.startPrank(users[i]);
            usdc.approve(address(zap), type(uint256).max);
            weth.approve(address(zap), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _executorZap() internal view override returns (address) {
        return vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 5);
    }
}

contract M9ZapRealV4Test is M9ZapRealV4Base {
    function test_nativeEthToNormalLpFirstAndSubsequentDeposit() public {
        (PoolKey memory key, int24 tick) = _nativePool();
        Vault vault = _newVaultWith(_normalConfig(key, _align(tick, key.tickSpacing)), address(normal));

        (uint256 swapAmount, uint256 quote) = zap.quoteZap(address(vault), address(0), 10 ether);
        assertGt(swapAmount, 0);
        vm.prank(alice);
        uint256 first = zap.zapDeposit{value: 10 ether}(address(vault), address(0), 10 ether, quote, 50, alice);
        assertGt(first, 0);
        assertGe(first, quote);

        (swapAmount, quote) = zap.quoteZap(address(vault), address(0), 4 ether);
        assertGt(swapAmount, 0);
        vm.prank(alice);
        uint256 second = zap.zapDeposit{value: 4 ether}(address(vault), address(0), 4 ether, quote, 50, alice);
        assertGt(second, 0);
        assertEq(address(zap).balance, 0);
        assertEq(usdc.balanceOf(address(zap)), 0);
        assertEq(usdc.allowance(address(zap), address(vault)), 0);
        assertEq(usdc.allowance(address(zap), address(executor)), 0);
    }

    function test_usdcToNormalLpAndQuoteIsConservative() public {
        (PoolKey memory key, int24 tick) = _nativePool();
        Vault vault = _newVaultWith(_normalConfig(key, _align(tick, key.tickSpacing)), address(normal));
        uint256 amount = 20_000e6;
        (uint256 swapAmount, uint256 quote) = zap.quoteZap(address(vault), USDC_ADDR, amount);
        assertGt(swapAmount, 0);
        vm.prank(alice);
        uint256 shares = zap.zapDeposit(address(vault), USDC_ADDR, amount, quote, 75, bob);
        assertGt(shares, 0);
        assertGe(shares, quote);
        assertEq(vault.balanceOf(bob), shares);
        _assertClean(vault);
    }

    function test_buyDipCorrectCurrencyAvoidsSwap() public {
        (PoolKey memory key, int24 tick) = _nativePool();
        Vault vault = _newVaultWith(_oneSidedConfig(key, Strategy.BuyTheDip, true), address(dip));
        (uint256 swapAmount, uint256 quote) = zap.quoteZap(address(vault), USDC_ADDR, 5_000e6);
        assertEq(swapAmount, 0);
        vm.prank(alice);
        uint256 shares = zap.zapDeposit(address(vault), USDC_ADDR, 5_000e6, quote, 20, alice);
        assertGt(shares, 0);
        assertLe(vault.bands()[vault.bands().length - 1].tickUpper, tick);
        _assertClean(vault);
    }

    function test_buyDipOppositeNativeCurrencySwapsAll() public {
        (PoolKey memory key,) = _nativePool();
        Vault vault = _newVaultWith(_oneSidedConfig(key, Strategy.BuyTheDip, true), address(dip));
        (uint256 swapAmount, uint256 quote) = zap.quoteZap(address(vault), address(0), 2 ether);
        assertEq(swapAmount, 2 ether);
        vm.prank(alice);
        uint256 shares = zap.zapDeposit{value: 2 ether}(address(vault), address(0), 2 ether, quote, 100, alice);
        assertGt(shares, 0);
        _assertClean(vault);
    }

    function test_sellPumpCorrectNativeCurrencyAvoidsSwap() public {
        (PoolKey memory key, int24 tick) = _nativePool();
        Vault vault = _newVaultWith(_oneSidedConfig(key, Strategy.SellThePump, false), address(pump));
        (uint256 swapAmount, uint256 quote) = zap.quoteZap(address(vault), address(0), 2 ether);
        assertEq(swapAmount, 0);
        vm.prank(alice);
        uint256 shares = zap.zapDeposit{value: 2 ether}(address(vault), address(0), 2 ether, quote, 20, alice);
        assertGt(shares, 0);
        assertGt(vault.bands()[0].tickLower, tick);
        _assertClean(vault);
    }

    function test_sellPumpOppositeUsdcCurrencySwapsAll() public {
        (PoolKey memory key,) = _nativePool();
        Vault vault = _newVaultWith(_oneSidedConfig(key, Strategy.SellThePump, false), address(pump));
        uint256 amount = 4_000e6;
        (uint256 swapAmount, uint256 quote) = zap.quoteZap(address(vault), USDC_ADDR, amount);
        assertEq(swapAmount, amount);
        vm.prank(alice);
        uint256 shares = zap.zapDeposit(address(vault), USDC_ADDR, amount, quote, 100, alice);
        assertGt(shares, 0);
        _assertClean(vault);
    }

    function testFuzz_normalZapRetainsNoUserFunds(uint96 rawAmount, bool nativeInput) public {
        (PoolKey memory key, int24 tick) = _nativePool();
        Vault vault = _newVaultWith(_normalConfig(key, _align(tick, key.tickSpacing)), address(normal));
        uint256 amount =
            nativeInput ? bound(uint256(rawAmount), 0.1 ether, 20 ether) : bound(uint256(rawAmount), 200e6, 40_000e6);
        address token = nativeInput ? address(0) : USDC_ADDR;
        vm.prank(alice);
        uint256 shares = zap.zapDeposit{value: nativeInput ? amount : 0}(address(vault), token, amount, 0, 100, alice);
        assertGt(shares, 0);
        _assertClean(vault);
    }

    function _nativePool() private returns (PoolKey memory key, int24 tick) {
        key = _nativeUsdcKey();
        tick = _initPool(key, 2000e6, 1e18, false);
        _seedExternalLiquidity(key, tick, DEEP_LIQUIDITY);
    }

    function _assertClean(Vault vault) private view {
        assertEq(address(zap).balance, 0);
        assertEq(usdc.balanceOf(address(zap)), 0);
        assertEq(usdc.allowance(address(zap), address(vault)), 0);
        assertEq(usdc.allowance(address(zap), address(executor)), 0);
    }

    function _normalConfig(PoolKey memory key, int24 center) private pure returns (VaultConfig memory config) {
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

    function _oneSidedConfig(PoolKey memory key, Strategy kind, bool below)
        private
        pure
        returns (VaultConfig memory config)
    {
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

    function _align(int24 tick, int24 spacing) private pure returns (int24 aligned) {
        int256 quotient = int256(tick) / int256(spacing);
        if (tick < 0 && tick % spacing != 0) --quotient;
        aligned = int24(quotient * int256(spacing));
    }
}
