// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PriceGuard} from "../../src/PriceGuard.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {Currency} from "../../src/libraries/Types.sol";
import {DeployPriceGuard} from "../../script/DeployPriceGuard.s.sol";
import {NetworkConfig} from "../../script/NetworkConfigs.s.sol";

contract PriceGuardScriptsTest is Test {
    address internal constant STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;
    address internal constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant V3_ETH_USDC_005_POOL = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;

    address internal constant OWNER = address(0xA11CE);
    address internal constant TIMELOCK = address(0);

    function test_mainnet_config_contains_expected_dependencies() public {
        vm.chainId(1);
        NetworkConfig.Configs memory configs = new NetworkConfig().getConfigs();

        assertEq(configs.chainId, 1);
        assertEq(address(configs.stateView), STATE_VIEW);
        assertEq(configs.sequencerUptimeFeed, address(0));
        assertEq(configs.nativeWrapper, WETH);
        assertEq(configs.deploymentOwner, address(0));
        assertEq(configs.timelock, address(0));
        assertEq(configs.uniswapV3Factory, V3_FACTORY);
        assertEq(configs.usdc, USDC);
        assertEq(Currency.unwrap(configs.ethUsdcPoolKey.currency0), address(0));
        assertEq(Currency.unwrap(configs.ethUsdcPoolKey.currency1), USDC);
        assertEq(configs.ethUsdcPoolKey.fee, 500);
        assertEq(configs.ethUsdcPoolKey.tickSpacing, 10);
        assertEq(configs.ethUsdcPoolKey.hooks, address(0));

        IPriceGuard.PairConfig memory priceConfig = configs.ethUsdcPriceConfig;
        assertEq(priceConfig.chainlinkFeed, CHAINLINK_ETH_USD);
        assertFalse(priceConfig.invertFeed);
        assertEq(priceConfig.maxStaleness, 2 hours);
        assertEq(priceConfig.minAnswer, 100e8);
        assertEq(priceConfig.maxAnswer, 20_000e8);
        assertEq(priceConfig.v3Pool, V3_ETH_USDC_005_POOL);
        assertTrue(priceConfig.invertV3);
        assertEq(priceConfig.twapWindow, 1_800);
        assertEq(priceConfig.maxDeviationBps, 1_000);
    }

    function test_unknown_chain_id_reverts() public {
        vm.chainId(31_337);

        NetworkConfig networkConfig = new NetworkConfig();

        vm.expectRevert(abi.encodeWithSelector(NetworkConfig.UnsupportedNetwork.selector, 31_337));
        networkConfig.getConfigs();
    }

    function test_deploy_reverts_when_owner_is_zero() public {
        NetworkConfig.Configs memory configs;
        DeployPriceGuard deployPriceGuard = new DeployPriceGuard();

        vm.expectRevert(DeployPriceGuard.MissingDeploymentOwner.selector);
        deployPriceGuard.deploy(configs);
    }

    function test_run_uses_caller_as_deployment_owner_when_network_config_owner_is_zero() public {
        vm.chainId(1);
        DeployPriceGuard deployPriceGuard = new DeployPriceGuard();

        (PriceGuard guard, NetworkConfig.Configs memory configs) = deployPriceGuard.run();

        assertEq(guard.owner(), address(this));
        assertEq(configs.deploymentOwner, address(this));
        assertEq(configs.timelock, address(0));
    }

    function test_deploy_wires_constructor_from_network_config() public {
        vm.chainId(1);

        NetworkConfig.Configs memory configs = new NetworkConfig().getConfigs();
        configs.deploymentOwner = OWNER;
        configs.timelock = TIMELOCK;
        PriceGuard guard = new DeployPriceGuard().deploy(configs);

        assertEq(address(guard.stateView()), address(configs.stateView));
        assertEq(guard.sequencerUptimeFeed(), configs.sequencerUptimeFeed);
        assertEq(guard.nativeWrapper(), configs.nativeWrapper);
        assertEq(guard.owner(), OWNER);
        assertEq(configs.deploymentOwner, OWNER);
        assertEq(configs.timelock, TIMELOCK);
    }
}
