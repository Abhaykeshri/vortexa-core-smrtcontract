// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {SwapExecutor} from "../../src/SwapExecutor.sol";
import {IPermit2Like} from "../../src/interfaces/external/IPermit2Like.sol";
import {IStateViewLike} from "../../src/interfaces/external/IStateViewLike.sol";
import {IUniversalRouterLike} from "../../src/interfaces/external/IUniversalRouterLike.sol";
import {Currency, PoolKey} from "../../src/libraries/Types.sol";
import {PoolIdLib} from "../../src/libraries/PoolIdLib.sol";
import {MockFactory, MockFeeCollector, MockVaultPriceGuard} from "../mocks/VaultMocks.sol";

contract SwapExecutorMainnetForkTest is Test {
    using PoolIdLib for PoolKey;

    address internal constant STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant UNIVERSAL_ROUTER = 0xab863E752Bf67D8DCDD929EaAe9Be9dc83Fb3BbB;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 internal constant Q96 = 1 << 96;

    MockFactory internal factory;
    MockVaultPriceGuard internal guard;
    SwapExecutor internal executor;

    function setUp() public {
        if (block.chainid != 1) vm.skip(true);
        factory = new MockFactory(0, 1_000, address(new MockFeeCollector(address(this))));
        guard = new MockVaultPriceGuard();
        executor =
            new SwapExecutor(IUniversalRouterLike(UNIVERSAL_ROUTER), IPermit2Like(PERMIT2), factory, guard, address(0));
        factory.setVault(address(this), true);
    }

    function test_mainnet_usdc_to_eth_uses_real_router_v4_command_and_permit2() public {
        PoolKey memory key = _nativeUsdcKey();
        (uint160 sqrtPrice,,,) = IStateViewLike(STATE_VIEW).getSlot0(key.toId());
        assertGt(sqrtPrice, 0, "ETH/USDC pool unavailable");
        guard.setReference(sqrtPrice);
        uint256 amountIn = 10e6;
        deal(USDC, address(this), amountIn);
        IERC20Like(USDC).approve(address(executor), amountIn);
        uint256 minOut = _floor(key, false, amountIn, sqrtPrice);
        uint256 beforeEth = address(this).balance;

        uint256 amountOut = executor.swapExactInput(key, false, amountIn, minOut);

        assertEq(address(this).balance - beforeEth, amountOut);
        assertGe(amountOut, minOut);
        assertEq(IERC20Like(USDC).balanceOf(address(executor)), 0);
    }

    function test_mainnet_native_eth_to_usdc_returns_real_measured_output() public {
        PoolKey memory key = _nativeUsdcKey();
        (uint160 sqrtPrice,,,) = IStateViewLike(STATE_VIEW).getSlot0(key.toId());
        assertGt(sqrtPrice, 0, "ETH/USDC pool unavailable");
        guard.setReference(sqrtPrice);
        uint256 amountIn = 0.01 ether;
        uint256 minOut = _floor(key, true, amountIn, sqrtPrice);
        uint256 beforeUsdc = IERC20Like(USDC).balanceOf(address(this));

        uint256 amountOut = executor.swapExactInput{value: amountIn}(key, true, amountIn, minOut);

        assertEq(IERC20Like(USDC).balanceOf(address(this)) - beforeUsdc, amountOut);
        assertGe(amountOut, minOut);
        assertEq(address(executor).balance, 0);
    }

    function _floor(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 sqrtPrice)
        internal
        pure
        returns (uint256 output)
    {
        uint256 priceX96 = Math.mulDiv(sqrtPrice, sqrtPrice, Q96);
        output = zeroForOne ? Math.mulDiv(amountIn, priceX96, Q96) : Math.mulDiv(amountIn, Q96, priceX96);
        output = Math.mulDiv(output, 1_000_000 - key.fee, 1_000_000);
        output = Math.mulDiv(output, 9_900, 10_000);
    }

    function _nativeUsdcKey() internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: 500,
            tickSpacing: 10,
            hooks: address(0)
        });
    }

    receive() external payable {}
}

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
