// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwapExecutor} from "../../src/SwapExecutor.sol";
import {ISwapExecutor} from "../../src/interfaces/ISwapExecutor.sol";
import {IPermit2Like} from "../../src/interfaces/external/IPermit2Like.sol";
import {IUniversalRouterLike} from "../../src/interfaces/external/IUniversalRouterLike.sol";
import {Currency, PoolKey} from "../../src/libraries/Types.sol";
import {SwapMath} from "../../src/libraries/SwapMath.sol";
import {FeeOnTransferToken, MintableToken} from "../mocks/TokenMocks.sol";
import {MockFactory, MockFeeCollector, MockPermit2, MockVaultPriceGuard} from "../mocks/VaultMocks.sol";

contract MockUniversalRouter is IUniversalRouterLike {
    MockPermit2 internal immutable permit2;
    uint256 public consumeDivisor = 1;
    bool public shortOutput;

    function setConsumeDivisor(uint256 divisor) external {
        consumeDivisor = divisor;
    }

    /**
     * A router that ignores `amountOutMinimum` and pays half the input.
     */
    function setShortOutput(bool on) external {
        shortOutput = on;
    }

    constructor(MockPermit2 permit2_) {
        permit2 = permit2_;
    }

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256) external payable {
        require(commands.length == 1 && uint8(commands[0]) == 0x10, "command");
        (bytes memory actions, bytes[] memory params) = abi.decode(inputs[0], (bytes, bytes[]));
        require(actions.length == 3 && uint8(actions[0]) == 0x06, "actions");
        SwapExecutor.ExactInputSingleParams memory swapParams =
            abi.decode(params[0], (SwapExecutor.ExactInputSingleParams));
        (PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 minOut) =
            (swapParams.poolKey, swapParams.zeroForOne, swapParams.amountIn, swapParams.amountOutMinimum);
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        address inputToken = Currency.unwrap(input);
        address outputToken = Currency.unwrap(output);
        if (inputToken == address(0)) {
            require(msg.value == amountIn, "value");
        } else {
            permit2.transferFrom(msg.sender, address(this), uint160(amountIn / consumeDivisor), inputToken);
        }
        uint256 amountOut = shortOutput ? amountIn / 2 : amountIn;
        require(shortOutput || amountOut >= minOut, "minimum");
        if (outputToken == address(0)) {
            (bool ok,) = msg.sender.call{value: amountOut}("");
            require(ok, "native output");
        } else {
            MintableToken(outputToken).mint(msg.sender, amountOut);
        }
    }

    receive() external payable {}
}

contract SwapExecutorTest is Test {
    MintableToken internal token0;
    MintableToken internal token1;
    MockPermit2 internal permit2;
    MockFactory internal factory;
    MockVaultPriceGuard internal guard;
    MockUniversalRouter internal router;
    SwapExecutor internal executor;

    function setUp() public {
        token0 = new MintableToken();
        token1 = new MintableToken();
        permit2 = new MockPermit2();
        factory = new MockFactory(0, 1_000, address(new MockFeeCollector(address(this))));
        guard = new MockVaultPriceGuard();
        router = new MockUniversalRouter(permit2);
        executor = new SwapExecutor(router, IPermit2Like(address(permit2)), factory, guard, address(0xBEEF));
        factory.setVault(address(this), true);
        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 10 ether);
    }

    function test_erc20_swap_uses_measured_delta_and_revokes_both_allowances() public {
        uint256 amountIn = 1 ether;
        token0.approve(address(executor), amountIn);

        uint256 amountOut = executor.swapExactInput(_ercKey(), true, amountIn, 0.99 ether);

        assertEq(amountOut, amountIn);
        assertEq(token1.balanceOf(address(this)), 11 ether);
        assertEq(token0.balanceOf(address(executor)), 0);
        assertEq(token1.balanceOf(address(executor)), 0);
        assertEq(permit2.allowance(address(executor), address(token0), address(router)), 0);
        assertEq(token0.allowance(address(executor), address(permit2)), 0);
    }

    function test_native_input_is_forwarded_and_erc20_output_is_returned() public {
        uint256 amountOut = executor.swapExactInput{value: 1 ether}(_nativeKey(), true, 1 ether, 0.99 ether);
        assertEq(amountOut, 1 ether);
        assertEq(token1.balanceOf(address(this)), 11 ether);
        assertEq(address(executor).balance, 0);
    }

    function test_erc20_input_can_return_measured_native_output() public {
        vm.deal(address(router), 2 ether);
        token1.approve(address(executor), 1 ether);
        uint256 beforeBalance = address(this).balance;

        uint256 amountOut = executor.swapExactInput(_nativeKey(), false, 1 ether, 0.99 ether);

        assertEq(amountOut, 1 ether);
        assertEq(address(this).balance, beforeBalance + 1 ether);
        assertEq(address(executor).balance, 0);
    }

    function test_unauthorized_caller_and_untrusted_oracle_revert() public {
        factory.setVault(address(this), false);
        vm.expectRevert(ISwapExecutor.UnauthorizedCaller.selector);
        executor.swapExactInput(_ercKey(), true, 1 ether, 0.99 ether);

        factory.setVault(address(this), true);
        token0.approve(address(executor), 1 ether);
        guard.setTrusted(false);
        vm.expectRevert(ISwapExecutor.UntrustedPrice.selector);
        executor.swapExactInput(_ercKey(), true, 1 ether, 0.99 ether);
    }

    function test_oracle_floor_and_uint128_bounds_are_enforced_before_router_call() public {
        token0.approve(address(executor), 1 ether);
        vm.expectRevert(ISwapExecutor.SlippageTooHigh.selector);
        executor.swapExactInput(_ercKey(), true, 1 ether, 0.98 ether);

        vm.expectRevert(SwapExecutor.AmountTooLarge.selector);
        executor.swapExactInput(_ercKey(), true, uint256(type(uint128).max) + 1, 0);
    }

    function test_min_out_from_reference_matches_the_enforced_swap_math() public view {
        PoolKey memory key = _ercKey();
        uint160 referencePrice = uint160(1 << 96);
        uint256 amountIn = 1 ether;
        uint16 slippageBps = 75;

        assertEq(
            executor.minOutFromReference(key, true, amountIn, referencePrice, slippageBps),
            SwapMath.minAmountOut(key, true, amountIn, referencePrice, slippageBps)
        );
        assertEq(
            executor.minOutFromReference(key, false, amountIn, referencePrice, slippageBps),
            SwapMath.minAmountOut(key, false, amountIn, referencePrice, slippageBps)
        );
    }

    /**
     * An unsolicited balance in the executor is never spent (input is pulled from the caller and measured by
     * delta) and never blocks later swaps (the old exact-balance check let a 1-wei donation block every swap of a
     * token forever).
     */
    function test_unsolicited_erc20_is_never_spent_and_never_blocks_swaps() public {
        token0.transfer(address(executor), 2 ether);
        vm.expectRevert(); // no allowance: nothing to pull, the donation cannot be used
        executor.swapExactInput(_ercKey(), true, 1 ether, 0.99 ether);

        token0.approve(address(executor), 1 ether);
        uint256 amountOut = executor.swapExactInput(_ercKey(), true, 1 ether, 0.99 ether);
        assertEq(amountOut, 1 ether);
        assertEq(token0.balanceOf(address(executor)), 2 ether, "the donation is untouched");
        assertEq(token0.allowance(address(this), address(executor)), 0);
    }

    /**
     * If the router settles less than the full input (a partial fill), the unspent input goes back to the caller
     * instead of staying in the executor.
     */
    function test_unspent_input_is_refunded_to_the_caller() public {
        router.setConsumeDivisor(2);
        token0.approve(address(executor), 1 ether);
        uint256 before0 = token0.balanceOf(address(this));
        executor.swapExactInput(_ercKey(), true, 1 ether, 0.99 ether);
        assertEq(before0 - token0.balanceOf(address(this)), 0.5 ether, "only the consumed half is spent");
        assertEq(token0.balanceOf(address(executor)), 0, "nothing stranded in the executor");
        assertEq(permit2.allowance(address(executor), address(token0), address(router)), 0, "unused allowance revoked");
    }

    /**
     * The executor measures the output itself: a router that ignores the minimum cannot short-change the caller.
     */
    function test_a_router_that_ignores_the_minimum_cannot_short_change_the_caller() public {
        router.setShortOutput(true);
        token0.approve(address(executor), 1 ether);
        vm.expectRevert(ISwapExecutor.InsufficientOutput.selector);
        executor.swapExactInput(_ercKey(), true, 1 ether, 0.99 ether);
    }

    function test_native_input_requires_exact_value_and_erc20_input_rejects_value() public {
        vm.expectRevert(SwapExecutor.InputBalanceMismatch.selector);
        executor.swapExactInput{value: 0.5 ether}(_nativeKey(), true, 1 ether, 0.99 ether);
        token0.approve(address(executor), 1 ether);
        vm.expectRevert(SwapExecutor.InputBalanceMismatch.selector);
        executor.swapExactInput{value: 1}(_ercKey(), true, 1 ether, 0.99 ether);
    }

    function test_constructor_legacy_entry_and_degenerate_inputs_are_rejected() public {
        vm.expectRevert(SwapExecutor.ZeroAddress.selector);
        this.deployExecutor(IUniversalRouterLike(address(0)));
        vm.expectRevert(ISwapExecutor.InvalidInput.selector);
        executor.swap(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 1, 0);
        vm.expectRevert(ISwapExecutor.InvalidInput.selector);
        executor.swapExactInput(_ercKey(), true, 0, 0);
        PoolKey memory same = _ercKey();
        same.currency1 = same.currency0;
        vm.expectRevert(ISwapExecutor.InvalidInput.selector);
        executor.swapExactInput(same, true, 1 ether, 0);
    }

    function test_a_reference_price_that_rounds_to_zero_is_untrusted() public {
        guard.setReference(1);
        token0.approve(address(executor), 1 ether);
        vm.expectRevert(ISwapExecutor.UntrustedPrice.selector);
        executor.swapExactInput(_ercKey(), true, 1 ether, 0);
    }

    function test_fee_on_transfer_input_is_rejected() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(address(this), 10 ether);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(fot) < address(token1) ? address(fot) : address(token1)),
            currency1: Currency.wrap(address(fot) < address(token1) ? address(token1) : address(fot)),
            fee: 500,
            tickSpacing: 60,
            hooks: address(0)
        });
        bool zeroForOne = Currency.unwrap(key.currency0) == address(fot);
        fot.approve(address(executor), 1 ether);
        vm.expectRevert(SwapExecutor.InputBalanceMismatch.selector);
        executor.swapExactInput(key, zeroForOne, 1 ether, 0);
    }

    function _ercKey() internal view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 500,
            tickSpacing: 60,
            hooks: address(0)
        });
    }

    function _nativeKey() internal view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: 500,
            tickSpacing: 60,
            hooks: address(0)
        });
    }

    receive() external payable {}

    // An expected revert inside a `new` of another file's contract ends the test early (forge deploys it through a
    // cheatcode), so each reverting deployment goes through an external self-call and the checks after it run.
    function deployExecutor(IUniversalRouterLike router_) external returns (SwapExecutor) {
        return new SwapExecutor(router_, IPermit2Like(address(permit2)), factory, guard, address(0));
    }
}
