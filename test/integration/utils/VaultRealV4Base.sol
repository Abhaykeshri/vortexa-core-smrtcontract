// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolManager} from "uni-test/v4-core/src/PoolManager.sol";
import {IPoolManager} from "uni-test/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "uni-test/v4-core/src/interfaces/IHooks.sol";
import {Currency as V4Currency} from "uni-test/v4-core/src/types/Currency.sol";
import {PoolKey as V4PoolKey} from "uni-test/v4-core/src/types/PoolKey.sol";
import {PoolId} from "uni-test/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {TickMath as V4TickMath} from "uni-test/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "uni-test/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "uni-test/v4-core/src/test/PoolSwapTest.sol";
import {StateView} from "uni-test/v4-periphery/src/lens/StateView.sol";
import {IPoolManager as IPoolManagerP} from "uni-test/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PositionManager} from "uni-test/v4-periphery/src/PositionManager.sol";
import {IPositionDescriptor} from "uni-test/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "uni-test/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PriceGuard} from "../../../src/PriceGuard.sol";
import {ShapeLibrary} from "../../../src/ShapeLibrary.sol";
import {Vault} from "../../../src/Vault.sol";
import {IPriceGuard} from "../../../src/interfaces/IPriceGuard.sol";
import {ISwapExecutor} from "../../../src/interfaces/ISwapExecutor.sol";
import {IPositionManagerLike} from "../../../src/interfaces/external/IPositionManagerLike.sol";
import {IPermit2Like} from "../../../src/interfaces/external/IPermit2Like.sol";
import {IStateViewLike} from "../../../src/interfaces/external/IStateViewLike.sol";
import {Band, Currency, DepositMode, PoolKey, Strategy, VaultConfig} from "../../../src/libraries/Types.sol";
import {PoolIdLib} from "../../../src/libraries/PoolIdLib.sol";
import {MockAggregator, MockStateView, PriceGuardHarness} from "../../mocks/PriceGuardMocks.sol";
import {MockStrategy} from "../../mocks/VaultMocks.sol";
import {Permit2Double} from "./Permit2Double.sol";
import {UniversalRouterDouble} from "./UniversalRouterDouble.sol";
import {SwapExecutor} from "../../../src/SwapExecutor.sol";
import {IVaultFactory} from "../../../src/interfaces/IVaultFactory.sol";
import {IUniversalRouterLike} from "../../../src/interfaces/external/IUniversalRouterLike.sol";
import {IPoolManager as IPoolManagerR} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract TestToken is ERC20 {
    uint8 private immutable _d;

    constructor(uint8 d) ERC20("T", "T") {
        _d = d;
    }

    function decimals() public view override returns (uint8) {
        return _d;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title Real Uniswap v4 fixture for vault tests
 * @notice Deploys the real v4 PoolManager, PositionManager and StateView in-process together with the real
 *         PriceGuard and ShapeLibrary, so vault deposits exercise Uniswap's actual action decoding, settlement,
 *         native ETH handling, NFT minting and fee accounting.
 * @dev USDC and WETH test tokens are etched on their mainnet addresses so the currency ordering matches production
 *      (USDC < WETH). Permit2 is a rule-faithful double (see `Permit2Double`).
 */
abstract contract VaultRealV4Base is Test {
    using PoolIdLib for PoolKey;

    address internal constant USDC_ADDR = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH_ADDR = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    PoolManager internal manager;
    StateView internal stateView;
    PositionManager internal posm;
    Permit2Double internal permit2;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;
    PriceGuardHarness internal guard;
    ShapeLibrary public shapes;
    MockAggregator internal ethUsd;
    MockStrategy internal strategy;
    Vault internal implementation;
    UniversalRouterDouble internal router;
    SwapExecutor internal executor;
    TestToken internal usdc;
    TestToken internal weth;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    receive() external payable {}

    address internal guardianAccount = makeAddr("guardian");
    address internal timelockAccount = makeAddr("timelock");

    /**
     * Factory role getters used by Vault.pause / Vault.unpause (this test contract plays the factory).
     */
    function guardian() external view returns (address) {
        return guardianAccount;
    }

    function owner() external view returns (address) {
        return timelockAccount;
    }

    /**
     * Factory fee and keeper surface read by the M5 vault paths (defaults: no protocol fee, no keepers).
     */
    uint256 internal factoryFeeBps;
    address internal factoryFeeCollector = makeAddr("feeCollector");
    bool internal factoryReadsRevert;
    mapping(address => bool) internal factoryKeepers;

    function protocolFeeBps() external view returns (uint256) {
        require(!factoryReadsRevert, "factory down");
        return factoryFeeBps;
    }

    function feeCollector() external view returns (address) {
        require(!factoryReadsRevert, "factory down");
        return factoryFeeCollector;
    }

    function isKeeper(address account) external view returns (bool) {
        return factoryKeepers[account];
    }

    mapping(address => bool) internal factoryVaults;

    function isVault(address account) external view returns (bool) {
        return factoryVaults[account];
    }

    function setUp() public virtual {
        vm.warp(10 days);
        manager = new PoolManager(address(this));
        stateView = new StateView(IPoolManagerP(address(manager)));
        permit2 = new Permit2Double();
        posm = new PositionManager(
            IPoolManagerP(address(manager)),
            IAllowanceTransfer(address(permit2)),
            100_000,
            IPositionDescriptor(address(0)),
            IWETH9(WETH_ADDR)
        );
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        shapes = new ShapeLibrary();

        vm.etch(USDC_ADDR, address(new TestToken(6)).code);
        vm.etch(WETH_ADDR, address(new TestToken(18)).code);
        usdc = TestToken(USDC_ADDR);
        weth = TestToken(WETH_ADDR);

        guard = new PriceGuardHarness(MockStateView(address(stateView)), address(0), WETH_ADDR, address(this));
        ethUsd = new MockAggregator(8);
        ethUsd.setAnswer(2000e8, block.timestamp);
        strategy = new MockStrategy();

        router = new UniversalRouterDouble(IPoolManagerR(address(manager)), IAllowanceTransfer(address(permit2)));
        address[4] memory actors = [address(this), alice, bob, attacker];
        for (uint256 i; i < actors.length; ++i) {
            usdc.mint(actors[i], 1e30);
            weth.mint(actors[i], 1e30);
            vm.deal(actors[i], 1e9 ether);
            vm.startPrank(actors[i]);
            usdc.approve(address(lpRouter), type(uint256).max);
            weth.approve(address(lpRouter), type(uint256).max);
            usdc.approve(address(swapRouter), type(uint256).max);
            weth.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
        executor = new SwapExecutor(
            IUniversalRouterLike(address(router)),
            IPermit2Like(address(permit2)),
            IVaultFactory(address(this)),
            IPriceGuard(address(guard)),
            _executorZap()
        );
        implementation = new Vault(
            IPositionManagerLike(address(posm)),
            IStateViewLike(address(stateView)),
            IPermit2Like(address(permit2)),
            IPriceGuard(address(guard)),
            shapes,
            address(executor),
            address(this),
            address(manager)
        );
    }

    /**
     * M9 fixtures override this hook with the CREATE address at which they deploy Zap after base setup.
     */
    function _executorZap() internal view virtual returns (address) {
        return address(0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Pools
    // ------------------------------------------------------------------------------------------------------------

    function _nativeUsdcKey() internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(USDC_ADDR), 500, 10, address(0));
    }

    function _usdcWethKey() internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(USDC_ADDR), Currency.wrap(WETH_ADDR), 500, 10, address(0));
    }

    /**
     * raw price: token1 raw units per token0 raw unit, as numerator / denominator
     */
    function _initPool(PoolKey memory key, uint256 num, uint256 den, bool inverted) internal returns (int24 tick) {
        manager.initialize(_v4(key), guard.sqrtFromRatio(num, den));
        (, tick,,) = stateView.getSlot0(_poolId(key));
        IPriceGuard.PairConfig memory c;
        c.chainlinkFeed = address(ethUsd);
        c.invertFeed = inverted;
        c.maxStaleness = 1 hours;
        c.minAnswer = 100e8;
        c.maxAnswer = 20_000e8;
        c.maxDeviationBps = 100;
        guard.setPairConfig(key, c);
    }

    /**
     * Deep external liquidity so swaps have something to trade against.
     */
    function _seedExternalLiquidity(PoolKey memory key, int24 tick, uint128 liquidity) internal {
        int24 lower = (tick - 60_000) / key.tickSpacing * key.tickSpacing;
        int24 upper = (tick + 60_000) / key.tickSpacing * key.tickSpacing;
        lpRouter.modifyLiquidity{value: Currency.unwrap(key.currency0) == address(0) ? 1e8 ether : 0}(
            _v4(key), IPoolManager.ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), bytes32("seed")), ""
        );
    }

    function _swap(address who, PoolKey memory key, bool zeroForOne, uint256 amountIn) internal {
        uint256 value = Currency.unwrap(key.currency0) == address(0) && zeroForOne ? amountIn : 0;
        vm.prank(who);
        swapRouter.swap{value: value}(
            _v4(key),
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? V4TickMath.MIN_SQRT_PRICE + 1 : V4TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /**
     * Moves the ETH/USD mock feed to the pool's current price (native/USDC pool: answer = raw price * 1e20).
     */
    function _syncOracleToNativePool(PoolKey memory key) internal {
        (uint160 sp,,,) = stateView.getSlot0(_poolId(key));
        uint256 answer = Math.mulDiv(Math.mulDiv(sp, sp, 1 << 96), 1e20, 1 << 96);
        ethUsd.setAnswer(int256(answer), block.timestamp);
    }

    /**
     * Same for the USDC/WETH pool, whose raw price is WETH raw per USDC raw: answer = 1e20 / raw price.
     */
    function _syncOracleToUsdcWethPool(PoolKey memory key) internal {
        (uint160 sp,,,) = stateView.getSlot0(_poolId(key));
        uint256 answer = Math.mulDiv(1e20, 1 << 96, Math.mulDiv(sp, sp, 1 << 96));
        ethUsd.setAnswer(int256(answer), block.timestamp);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Vaults
    // ------------------------------------------------------------------------------------------------------------

    function _newVault(PoolKey memory key, uint8 shapeId, int24 center, int24 left, int24 right)
        internal
        returns (Vault vault)
    {
        VaultConfig memory cfg;
        cfg.poolKey = key;
        cfg.strategy = Strategy.NormalLP;
        cfg.shapeId = shapeId;
        cfg.centerTick = center;
        cfg.ticksLeft = left;
        cfg.ticksRight = right;
        cfg.autoRebalance = true;
        cfg.baseIsCurrency0 = true;
        return _newVaultWith(cfg, address(strategy));
    }

    /**
     * Clone, initialize (this contract is the factory), register with the factory and approve the actors.
     */
    function _newVaultWith(VaultConfig memory cfg, address strategy_) internal returns (Vault vault) {
        vault = Vault(payable(Clones.clone(address(implementation))));
        vault.initialize("Vortex", "VTX", strategy_, cfg);
        factoryVaults[address(vault)] = true;
        address[3] memory users = [alice, bob, attacker];
        for (uint256 i; i < users.length; ++i) {
            vm.startPrank(users[i]);
            usdc.approve(address(vault), type(uint256).max);
            weth.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _deposit(Vault vault, address who, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 shares, uint256 used0, uint256 used1)
    {
        bool native = Currency.unwrap(vault.config().poolKey.currency0) == address(0);
        vm.prank(who);
        return vault.depositPair{value: native ? amount0 : 0}(amount0, amount1, 0, who);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Conversions
    // ------------------------------------------------------------------------------------------------------------

    function _poolId(PoolKey memory key) internal pure returns (PoolId) {
        return PoolId.wrap(key.toId());
    }

    function _v4(PoolKey memory key) internal pure returns (V4PoolKey memory) {
        return V4PoolKey({
            currency0: V4Currency.wrap(Currency.unwrap(key.currency0)),
            currency1: V4Currency.wrap(Currency.unwrap(key.currency1)),
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: IHooks(key.hooks)
        });
    }
}
