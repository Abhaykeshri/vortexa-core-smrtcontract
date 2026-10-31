// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPriceGuard} from "./interfaces/IPriceGuard.sol";
import {IPermit2Like} from "./interfaces/external/IPermit2Like.sol";
import {IUniversalRouterLike} from "./interfaces/external/IUniversalRouterLike.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {ISwapExecutor} from "./interfaces/ISwapExecutor.sol";
import {VaultM6Module} from "./VaultM6Module.sol";
import {Currency, PoolKey} from "./libraries/Types.sol";
import {CurrencyLib} from "./libraries/CurrencyLib.sol";
import {SwapMath} from "./libraries/SwapMath.sol";

/**
 * @title SwapExecutor
 * @notice Executes one exact-input Uniswap V4 swap for a registered vault or configured Zap.
 * @dev ERC-20 input is pulled from the caller with `transferFrom` and verified by balance delta, so the executor only
 *      ever spends what the caller provided in the same call: an unsolicited balance can neither be spent nor block
 *      later swaps. Native input must arrive as an exact `msg.value`. Unspent input is refunded, all router
 *      allowances are revoked, and the measured output is sent to the caller.
 */
contract SwapExecutor is ReentrancyGuard, ISwapExecutor {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using CurrencyLib for Currency;

    /**
     * @dev Hard oracle slippage ceiling in basis points.
     */
    uint256 public constant MAX_SLIPPAGE_BPS = 100;
    /**
     * @dev Basis-point denominator.
     */
    uint256 private constant FEE_DENOMINATOR = 1e6;
    /**
     * @dev Q64.96 fixed-point scale used to reject unusable references with the established error.
     */
    uint256 private constant Q96 = 1 << 96;
    /**
     * @dev Universal Router v2.2.0 V4_SWAP command id.
     */
    uint8 private constant V4_SWAP = 0x10;
    /**
     * @dev V4 exact-input-single action id from the pinned periphery.
     */
    uint8 private constant SWAP_EXACT_IN_SINGLE = 0x06;
    /**
     * @dev V4 settle-all action id from the pinned periphery.
     */
    uint8 private constant SETTLE_ALL = 0x0c;
    /**
     * @dev V4 take-all action id from the pinned periphery.
     */
    uint8 private constant TAKE_ALL = 0x0f;

    /**
     * @notice Pinned Universal Router dependency.
     */
    IUniversalRouterLike public immutable universalRouter;
    /**
     * @notice Permit2 dependency used for exact router allowances.
     */
    IPermit2Like public immutable permit2;
    /**
     * @notice Factory used to authorize registered vault callers.
     */
    IVaultFactory public immutable factory;
    /**
     * @notice Oracle guard used to enforce the output floor.
     */
    IPriceGuard public immutable priceGuard;
    /**
     * @notice Immutable Zap caller allowed alongside factory vaults.
     */
    address public immutable zap;
    /**
     * @notice Immutable M6 module consumed by Vault implementations.
     */
    address public immutable vaultModule;

    /**
     * @notice A required constructor dependency is zero.
     */
    error ZeroAddress();
    /**
     * @notice Supplied native value or pre-funded ERC-20 balance is not the exact input.
     */
    error InputBalanceMismatch();
    /**
     * @notice An amount does not fit the pinned router's uint128 fields.
     */
    error AmountTooLarge();

    /**
     * @notice Exact-input single-pool swap parameters of the pinned V4Router (`IV4Router.ExactInputSingleParams`).
     * @dev Field order and types must match the pinned periphery exactly. The struct is dynamic (it ends in `bytes`),
     *      so it is ABI-encoded as one value: the router's decoder reads a leading offset word to locate it.
     */
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    /**
     * @notice Deploys the executor and its immutable Vault module.
     * @dev All fund-moving dependencies are immutable and no owner setter exists.
     * @param router_ Pinned Universal Router deployment.
     * @param permit2_ Permit2 deployment.
     * @param factory_ Factory used for vault authorization.
     * @param guard_ Trusted PriceGuard.
     * @param zap_ Optional authorized Zap address.
     */
    constructor(
        IUniversalRouterLike router_,
        IPermit2Like permit2_,
        IVaultFactory factory_,
        IPriceGuard guard_,
        address zap_
    ) {
        if (
            address(router_) == address(0) || address(permit2_) == address(0) || address(factory_) == address(0)
                || address(guard_) == address(0)
        ) revert ZeroAddress();
        universalRouter = router_;
        permit2 = permit2_;
        factory = factory_;
        priceGuard = guard_;
        zap = zap_;
        vaultModule = address(new VaultM6Module());
    }

    /**
     * @inheritdoc ISwapExecutor
     * @dev A pool key is mandatory for oracle and fee validation, so this legacy entry point always rejects.
     */
    function swap(Currency, Currency, uint256, uint256) external payable returns (uint256) {
        revert InvalidInput();
    }

    /**
     * @inheritdoc ISwapExecutor
     */
    function swapExactInput(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minAmountOut)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        return _swap(key, zeroForOne, amountIn, minAmountOut);
    }

    /**
     * @notice Validates funding and oracle bounds, executes the router, then returns measured output.
     * @dev Exact temporary approvals are revoked before output is transferred.
     * @param key V4 pool key.
     * @param zeroForOne Swap direction.
     * @param amountIn Exact input amount.
     * @param minAmountOut Caller output floor.
     * @return amountOut Measured output returned to the caller.
     */
    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 minAmountOut)
        private
        returns (uint256 amountOut)
    {
        if (!factory.isVault(msg.sender) && msg.sender != zap) revert UnauthorizedCaller();
        if (amountIn == 0 || Currency.unwrap(key.currency0) == Currency.unwrap(key.currency1)) revert InvalidInput();
        if (amountIn > type(uint128).max || minAmountOut > type(uint128).max) revert AmountTooLarge();
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        uint256 beforeIn;
        if (input.isNative()) {
            if (msg.value != amountIn) revert InputBalanceMismatch();
        } else {
            if (msg.value != 0) revert InputBalanceMismatch();
            beforeIn = _pullExact(input, amountIn);
            IERC20(Currency.unwrap(input)).forceApprove(address(permit2), amountIn);
            // Permit2 approval has no ERC-20 boolean return value.
            // aderyn-fp-next-line(unsafe-erc20-operation)
            permit2.approve(
                Currency.unwrap(input), address(universalRouter), uint160(amountIn), uint48(block.timestamp)
            );
        }
        uint256 beforeOut = output.balanceOfSelf();

        (bool trusted,) = priceGuard.isPriceTrusted(key);
        if (!trusted) revert UntrustedPrice();
        uint160 sqrtReference = priceGuard.referenceSqrtPriceX96(key);
        uint256 floor = _oracleFloor(key, zeroForOne, amountIn, sqrtReference);
        if (minAmountOut < floor) revert SlippageTooHigh();
        _executeRouter(key, zeroForOne, amountIn, minAmountOut, input, output);

        uint256 refund;
        if (!input.isNative()) {
            permit2.approve(Currency.unwrap(input), address(universalRouter), 0, uint48(block.timestamp)); // aderyn-fp(unsafe-erc20-operation)
            IERC20(Currency.unwrap(input)).forceApprove(address(permit2), 0);
            uint256 afterIn = input.balanceOfSelf();
            refund = afterIn > beforeIn ? afterIn - beforeIn : 0;
        }
        uint256 afterOut = output.balanceOfSelf();
        if (afterOut < beforeOut) revert InsufficientOutput();
        amountOut = afterOut - beforeOut;
        if (amountOut < minAmountOut || amountOut < floor) revert InsufficientOutput();
        input.transfer(msg.sender, refund); // aderyn-fp(unsafe-erc20-operation)
        output.transfer(msg.sender, amountOut); // aderyn-fp(unsafe-erc20-operation)
        emit SwapExecuted(msg.sender, key, zeroForOne, amountIn, amountOut);
    }

    /**
     * @notice Pulls exactly `amountIn` of an ERC-20 from the caller and verifies it by balance delta.
     * @dev Rejects fee-on-transfer and rebasing behaviour. Returns the balance held before the pull, so anything
     *      already sitting in the executor is excluded from this call's spend and refund.
     * @param input ERC-20 input currency.
     * @param amountIn Amount to pull.
     * @return beforeIn Executor balance of `input` before the pull.
     */
    function _pullExact(Currency input, uint256 amountIn) private returns (uint256 beforeIn) {
        beforeIn = input.balanceOfSelf();
        IERC20(Currency.unwrap(input)).safeTransferFrom(msg.sender, address(this), amountIn);
        /// BinaryOpMutation(`-` |==> `**`) of: `if (input.balanceOfSelf() - beforeIn != amountIn) revert InputBalanceMismatch();`
        if (input.balanceOfSelf()**beforeIn != amountIn) revert InputBalanceMismatch();
    }

    /**
     * @notice Encodes and submits the pinned V4 exact-input Universal Router command.
     * @dev `ExactInputSingleParams` is encoded as a single struct value (with its head offset), which is what the
     *      pinned V4Router's `decodeSwapExactInSingleParams` expects. Encoding its fields as separate arguments
     *      only decodes by accident when `currency0` is native (address zero) and breaks every ERC-20 pool.
     * @param key V4 pool key.
     * @param zeroForOne Swap direction.
     * @param amountIn Exact input amount.
     * @param minAmountOut Minimum output amount.
     * @param input Input currency.
     * @param output Output currency.
     */
    function _executeRouter(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        Currency input,
        Currency output
    ) private {
        bytes memory actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn.toUint128(),
                amountOutMinimum: minAmountOut.toUint128(),
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(input, amountIn);
        params[2] = abi.encode(output, minAmountOut);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        universalRouter.execute{value: input.isNative() ? amountIn : 0}(
            abi.encodePacked(V4_SWAP), inputs, block.timestamp
        );
    }

    /**
     * @notice Computes the minimum oracle-valued output after pool fee and the hard slippage cap.
     * @dev Uses full-precision arithmetic and floors each conversion in the conservative direction.
     * @param key V4 pool key containing the LP fee.
     * @param zeroForOne Swap direction.
     * @param amountIn Exact input amount.
     * @param sqrtReference Trusted reference square-root price.
     * @return floor Minimum acceptable output.
     */
    function _oracleFloor(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 sqrtReference)
        private
        pure
        returns (uint256 floor)
    {
        if (key.fee >= FEE_DENOMINATOR || Math.mulDiv(sqrtReference, sqrtReference, Q96) == 0) {
            revert UntrustedPrice();
        }
        floor = SwapMath.minAmountOut(key, zeroForOne, amountIn, sqrtReference, MAX_SLIPPAGE_BPS);
    }

    /**
     * @notice Computes an oracle-derived output floor for callers and integrations.
     * @dev The executor still independently applies its hard-cap floor inside every swap.
     * @param key V4 pool key.
     * @param zeroForOne Swap direction.
     * @param amountIn Exact input amount.
     * @param sqrtReference Trusted reference square-root price.
     * @param slippageBps Requested oracle-relative tolerance.
     * @return floor Minimum acceptable output.
     */
    function minOutFromReference(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint160 sqrtReference,
        uint16 slippageBps
    ) external pure returns (uint256 floor) {
        if (slippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh();
        floor = SwapMath.minAmountOut(key, zeroForOne, amountIn, sqrtReference, slippageBps);
    }

    /**
     * @notice Accepts native output from the Universal Router.
     * @dev Measured balance deltas prevent pre-existing ETH from being reported as swap output.
     */
    receive() external payable {}
}
