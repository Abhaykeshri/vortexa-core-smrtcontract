// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Actions} from "uni-test/v4-periphery/src/libraries/Actions.sol";
import {IHooks} from "uni-test/v4-core/src/interfaces/IHooks.sol";
import {Currency as V4Currency} from "uni-test/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "uni-test/v4-core/src/types/PoolId.sol";
import {PoolKey as V4PoolKey} from "uni-test/v4-core/src/types/PoolKey.sol";
import {Currency as ProjectCurrency, PoolKey as ProjectPoolKey} from "../../src/libraries/Types.sol";
import {CurrencyLib} from "../../src/libraries/CurrencyLib.sol";
import {LiquidityMath} from "../../src/libraries/LiquidityMath.sol";
import {PoolIdLib} from "../../src/libraries/PoolIdLib.sol";
import {PosmActions} from "../../src/libraries/PosmActions.sol";
import {SqrtPriceMath} from "../../src/libraries/SqrtPriceMath.sol";

contract RejectNativeTransfer {
    receive() external payable {
        revert();
    }
}

contract CurrencyLibHarness {
    using CurrencyLib for ProjectCurrency;

    function isNative(ProjectCurrency currency) external pure returns (bool) {
        return currency.isNative();
    }

    function balance(ProjectCurrency currency) external view returns (uint256) {
        return currency.balanceOfSelf();
    }

    function send(ProjectCurrency currency, address recipient, uint256 amount) external {
        currency.transfer(recipient, amount);
    }
}

contract TestCurrencyToken is ERC20 {
    constructor() ERC20("Test Currency", "TST") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
}

contract SqrtPriceMathHarness {
    function getSqrtPriceAtTick(int24 tick) external pure returns (uint160) {
        return SqrtPriceMath.getSqrtPriceAtTick(tick);
    }
}

contract LiquidityMathHarness {
    function amounts(uint160 sqrtPrice, uint160 sqrtA, uint160 sqrtB, uint128 liquidity)
        external
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return LiquidityMath.amountsForLiquidity(sqrtPrice, sqrtA, sqrtB, liquidity);
    }
}

contract M1HelpersTest is Test {
    function test_pool_id_matches_v4_encoding() public pure {
        ProjectPoolKey memory projectKey = ProjectPoolKey({
            currency0: ProjectCurrency.wrap(address(0x1234)),
            currency1: ProjectCurrency.wrap(address(0x5678)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0x9abc)
        });
        V4PoolKey memory v4Key = V4PoolKey({
            currency0: V4Currency.wrap(address(0x1234)),
            currency1: V4Currency.wrap(address(0x5678)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0x9abc))
        });

        assertEq(PoolIdLib.toId(projectKey), PoolId.unwrap(PoolIdLibrary.toId(v4Key)));
    }

    function test_posm_actions_match_pinned_v4_periphery() public pure {
        assertEq(PosmActions.INCREASE_LIQUIDITY, Actions.INCREASE_LIQUIDITY);
        assertEq(PosmActions.DECREASE_LIQUIDITY, Actions.DECREASE_LIQUIDITY);
        assertEq(PosmActions.MINT_POSITION, Actions.MINT_POSITION);
        assertEq(PosmActions.BURN_POSITION, Actions.BURN_POSITION);
        assertEq(PosmActions.SETTLE_PAIR, Actions.SETTLE_PAIR);
        assertEq(PosmActions.TAKE_PAIR, Actions.TAKE_PAIR);
        assertEq(PosmActions.CLOSE_CURRENCY, Actions.CLOSE_CURRENCY);
        assertEq(PosmActions.SWEEP, Actions.SWEEP);
    }

    function test_currency_native_detection_and_balance() public {
        CurrencyLibHarness harness = new CurrencyLibHarness();
        TestCurrencyToken token = new TestCurrencyToken();
        ProjectCurrency nativeCurrency = ProjectCurrency.wrap(address(0));
        ProjectCurrency tokenCurrency = ProjectCurrency.wrap(address(token));

        assertTrue(harness.isNative(nativeCurrency));
        assertFalse(harness.isNative(tokenCurrency));
        assertEq(harness.balance(nativeCurrency), 0);
        assertEq(harness.balance(tokenCurrency), 0);
        token.mint(address(harness), 5);
        assertEq(harness.balance(tokenCurrency), 5);
        harness.send(tokenCurrency, address(this), 5);
        assertEq(token.balanceOf(address(this)), 5);
        harness.send(nativeCurrency, address(this), 0);
        harness.send(tokenCurrency, address(this), 0);

        address payable recipient = payable(makeAddr("nativeRecipient"));
        vm.deal(address(harness), 1 ether);
        harness.send(nativeCurrency, recipient, 1 ether);
        assertEq(address(recipient).balance, 1 ether);
    }

    function test_sqrt_price_rejects_out_of_bounds_tick() public {
        SqrtPriceMathHarness harness = new SqrtPriceMathHarness();
        vm.expectRevert(SqrtPriceMath.InvalidTick.selector);
        harness.getSqrtPriceAtTick(887273);
    }

    function test_currency_native_transfer_reverts_on_failure() public {
        CurrencyLibHarness harness = new CurrencyLibHarness();
        RejectNativeTransfer recipient = new RejectNativeTransfer();
        ProjectCurrency nativeCurrency = ProjectCurrency.wrap(address(0));
        vm.deal(address(harness), 1 ether);

        vm.expectRevert(CurrencyLib.NativeTransferFailed.selector);
        harness.send(nativeCurrency, address(recipient), 1 ether);
    }

    function test_liquidity_math_rejects_zero_or_equal_price_bounds() public {
        LiquidityMathHarness harness = new LiquidityMathHarness();
        vm.expectRevert(LiquidityMath.InvalidPriceRange.selector);
        harness.amounts(1, 0, 0, 1);

        vm.expectRevert(LiquidityMath.InvalidPriceRange.selector);
        harness.amounts(1, 1, 1, 1);
    }
}
