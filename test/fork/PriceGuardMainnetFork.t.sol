// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {IAggregatorV3} from "../../src/interfaces/external/IAggregatorV3.sol";
import {IStateViewLike} from "../../src/interfaces/external/IStateViewLike.sol";
import {PriceGuard} from "../../src/PriceGuard.sol";
import {Currency, PoolKey} from "../../src/libraries/Types.sol";
import {PoolIdLib} from "../../src/libraries/PoolIdLib.sol";

interface IUniswapV3FactoryLike {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IStateViewLiquidityLike is IStateViewLike {
    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
}

contract RevertingAggregator {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("feed down");
    }
}

contract WrongDecimalsAggregator {
    function decimals() external pure returns (uint8) {
        return 18;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2_000 ether, block.timestamp, block.timestamp, 1);
    }
}

contract PriceGuardMainnetForkTest is Test {
    using PoolIdLib for PoolKey;

    address internal constant STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;
    address internal constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint24 internal constant V3_FEE_005 = 500;
    uint24 internal constant V4_FEE_005 = 500;
    int24 internal constant V4_TICK_SPACING_005 = 10;
    uint32 internal constant TWAP_WINDOW = 1_800;

    PriceGuard internal guard;
    PoolKey internal nativeEthUsdcKey;
    address internal v3EthUsdcPool;

    function setUp() public {
        if (block.chainid != 1) vm.skip(true);
        guard = new PriceGuard(IStateViewLike(STATE_VIEW), address(0), WETH, address(this));
        nativeEthUsdcKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: V4_FEE_005,
            tickSpacing: V4_TICK_SPACING_005,
            hooks: address(0)
        });
        v3EthUsdcPool = IUniswapV3FactoryLike(V3_FACTORY).getPool(USDC, WETH, V3_FEE_005);
        require(v3EthUsdcPool != address(0), "missing v3 ETH/USDC pool");
    }

    function test_mainnet_addresses_and_orientations_are_expected() public view {
        assertEq(IAggregatorV3(CHAINLINK_ETH_USD).decimals(), 8);
        assertEq(IERC20MetadataLike(USDC).decimals(), 6);
        assertEq(IERC20MetadataLike(WETH).decimals(), 18);
        assertEq(IUniswapV3PoolTokenLike(v3EthUsdcPool).token0(), USDC);
        assertEq(IUniswapV3PoolTokenLike(v3EthUsdcPool).token1(), WETH);
        assertEq(guard.sequencerUptimeFeed(), address(0));
    }

    function test_mainnet_v4_pool_price_is_trusted_against_chainlink() public {
        _requireInitializedV4Pool();

        guard.setPairConfig(nativeEthUsdcKey, _chainlinkConfig());

        (bool trusted, uint256 devBps) = guard.isPriceTrusted(nativeEthUsdcKey);

        assertTrue(trusted, "v4 price too far from Chainlink ETH/USD");
        assertLt(devBps, 1_000);
    }

    function test_mainnet_v3_twap_fallback_is_trusted_with_reversed_order() public {
        _requireInitializedV4Pool();

        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.chainlinkFeed = address(new RevertingAggregator());
        config.v3Pool = v3EthUsdcPool;
        config.invertV3 = true;
        config.twapWindow = TWAP_WINDOW;

        guard.setPairConfig(nativeEthUsdcKey, config);

        (bool trusted, uint256 devBps) = guard.isPriceTrusted(nativeEthUsdcKey);

        assertTrue(trusted, "v4 price too far from v3 TWAP");
        assertLt(devBps, 1_000);
    }

    function test_mainnet_wrong_feed_orientation_and_wrong_decimals_are_rejected() public {
        _requireInitializedV4Pool();

        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.invertFeed = true;
        vm.expectRevert(PriceGuard.InvalidInitialPrice.selector);
        guard.setPairConfig(nativeEthUsdcKey, config);

        config = _chainlinkConfig();
        config.chainlinkFeed = address(new WrongDecimalsAggregator());
        vm.expectRevert(PriceGuard.InvalidInitialPrice.selector);
        guard.setPairConfig(nativeEthUsdcKey, config);
    }

    function test_mainnet_manipulated_spot_price_is_rejected() public {
        IPriceGuard.PairConfig memory config = _chainlinkConfig();
        config.v3Pool = v3EthUsdcPool;
        config.invertV3 = true;
        config.twapWindow = TWAP_WINDOW;
        guard.setPairConfig(nativeEthUsdcKey, config);

        bytes32 poolId = nativeEthUsdcKey.toId();
        uint256 stateViewCodeSize = STATE_VIEW.code.length;
        vm.etch(STATE_VIEW, address(new MockForkStateView()).code);
        MockForkStateView(STATE_VIEW).setSqrtPrice(poolId, uint160(1 << 96));

        (bool trusted,) = guard.isPriceTrusted(nativeEthUsdcKey);
        assertFalse(trusted);
        assertGt(stateViewCodeSize, 0);
    }

    function _chainlinkConfig() private pure returns (IPriceGuard.PairConfig memory config) {
        config.chainlinkFeed = CHAINLINK_ETH_USD;
        config.maxStaleness = 2 hours;
        config.minAnswer = 100e8;
        config.maxAnswer = 20_000e8;
        config.maxDeviationBps = 1_000;
    }

    function _requireInitializedV4Pool() private view {
        bytes32 poolId = nativeEthUsdcKey.toId();
        (uint160 sqrtPriceX96,,,) = IStateViewLike(STATE_VIEW).getSlot0(poolId);
        uint128 liquidity = IStateViewLiquidityLike(STATE_VIEW).getLiquidity(poolId);
        require(sqrtPriceX96 > 0, "missing v4 ETH/USDC pool");
        require(liquidity > 0, "empty v4 ETH/USDC pool");
    }
}

interface IERC20MetadataLike {
    function decimals() external view returns (uint8);
}

interface IUniswapV3PoolTokenLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract MockForkStateView {
    mapping(bytes32 => uint160) internal sqrtPrices;

    function setSqrtPrice(bytes32 poolId, uint160 sqrtPriceX96) external {
        sqrtPrices[poolId] = sqrtPriceX96;
    }

    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return (sqrtPrices[poolId], 0, 0, 0);
    }
}
