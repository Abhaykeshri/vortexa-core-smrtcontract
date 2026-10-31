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

/**
 * @title SwapExecutor against the deployed Universal Router on an ERC-20/ERC-20 v4 pool
 * @notice The guide (8.1) requires a fork test that fails loudly on any `ExactInputSingleParams` layout mismatch.
 *         The native ETH/USDC pool cannot detect one (a zero `currency0` makes a mis-encoded struct decode by
 *         accident), so this runs both directions on the mainnet USDC/WETH 0.05% v4 pool.
 */
contract SwapExecutorErc20PoolForkTest is Test {
    using PoolIdLib for PoolKey;

    address internal constant STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant UNIVERSAL_ROUTER = 0xab863E752Bf67D8DCDD929EaAe9Be9dc83Fb3BbB;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
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

    function test_mainnet_usdc_to_weth_on_an_erc20_v4_pool() public {
        _swapAndCheck(true, 200e6, USDC, WETH);
    }

    function test_mainnet_weth_to_usdc_on_an_erc20_v4_pool() public {
        _swapAndCheck(false, 0.05 ether, WETH, USDC);
    }

    function _swapAndCheck(bool zeroForOne, uint256 amountIn, address tokenIn, address tokenOut) internal {
        PoolKey memory key = _usdcWethKey();
        (uint160 sqrtPrice,,,) = IStateViewLike(STATE_VIEW).getSlot0(key.toId());
        assertGt(sqrtPrice, 0, "USDC/WETH v4 pool unavailable");
        guard.setReference(sqrtPrice);
        deal(tokenIn, address(this), amountIn);
        IERC20Like(tokenIn).approve(address(executor), amountIn);
        uint256 minOut = _floor(key, zeroForOne, amountIn, sqrtPrice);
        uint256 before = IERC20Like(tokenOut).balanceOf(address(this));

        uint256 amountOut = executor.swapExactInput(key, zeroForOne, amountIn, minOut);

        assertEq(IERC20Like(tokenOut).balanceOf(address(this)) - before, amountOut, "measured output delivered");
        assertGe(amountOut, minOut);
        assertEq(IERC20Like(tokenIn).balanceOf(address(executor)), 0, "executor kept input");
        assertEq(IERC20Like(tokenOut).balanceOf(address(executor)), 0, "executor kept output");
        assertEq(IERC20Like(tokenIn).allowance(address(executor), PERMIT2), 0, "standing approval");
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

    function _usdcWethKey() internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(USDC), currency1: Currency.wrap(WETH), fee: 500, tickSpacing: 10, hooks: address(0)
        });
    }
}

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}
