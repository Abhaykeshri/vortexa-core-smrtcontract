// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPriceGuard} from "../src/interfaces/IPriceGuard.sol";
import {IStateViewLike} from "../src/interfaces/external/IStateViewLike.sol";
import {Currency, PoolKey} from "../src/libraries/Types.sol";

/**
 * @title Network Configurations
 * @notice Provides chain-id selected deployment and PriceGuard pair configuration values.
 * @dev Unknown networks revert explicitly so deployment scripts never continue with zero-address dependencies.
 */
contract NetworkConfig is Script {
    /**
     * @notice Requested chain id has no configured deployment parameters.
     * @param chainId Unsupported `block.chainid` value.
     */
    error UnsupportedNetwork(uint256 chainId);

    /**
     * @notice Network-specific values needed to deploy and configure M2 PriceGuard.
     */
    struct Configs {
        /**
         * @notice Chain id this config targets.
         */
        uint256 chainId;
        /**
         * @notice Uniswap V4 StateView used by PriceGuard.
         */
        IStateViewLike stateView;
        /**
         * @notice Uniswap V4 PoolManager used by the vault.
         */
        address poolManager;
        /**
         * @notice Uniswap V4 PositionManager used by the vault.
         */
        address positionManager;
        /**
         * @notice Permit2 contract used by PositionManager token settlement.
         */
        address permit2;
        /**
         * @notice Official Uniswap Universal Router 2.2.0 on Ethereum mainnet.
         */
        address universalRouter;
        /**
         * @notice Optional Chainlink L2 sequencer uptime feed; zero for Ethereum mainnet.
         */
        address sequencerUptimeFeed;
        /**
         * @notice Wrapped native token used when V4 pool keys use native ETH.
         */
        address nativeWrapper;
        /**
         * @notice Initial PriceGuard owner; left zero here and set to the deployer by the deployment script.
         */
        address deploymentOwner;
        /**
         * @notice Intended timelock owner; zero until the target deployment's timelock address is chosen.
         */
        address timelock;
        /**
         * @notice Main ETH/USDC V4 pool key used for M2 PriceGuard configuration.
         */
        PoolKey ethUsdcPoolKey;
        /**
         * @notice Main ETH/USDC oracle configuration for M2 PriceGuard.
         */
        IPriceGuard.PairConfig ethUsdcPriceConfig;
        /**
         * @notice Deployed Vortexa PriceGuard; zero until deployed.
         */
        address priceGuard;
        /**
         * @notice Deployed Vortexa ShapeLibrary; zero until deployed.
         */
        address shapeLibrary;
        /**
         * @notice Deployed M6 SwapExecutor; zero until M6 deployment.
         */
        address swapExecutor;
        /**
         * @notice Deployed M4 Vault implementation; zero until deployed.
         */
        address vaultImplementation;
        /**
         * @notice Deployed M8 VaultFactory; zero until M8 deployment.
         */
        address vaultFactory;
        /**
         * @notice Deployed M8 FeeCollector; zero until M8 deployment.
         */
        address feeCollector;
        /**
         * @notice Deployed M8 VaultLens; zero until M8 deployment.
         */
        address vaultLens;
        /**
         * @notice Deployed M8 NormalLPStrategy; zero until M8 deployment.
         */
        address normalStrategy;
        /**
         * @notice Deployed M8 BuyTheDipStrategy; zero until M8 deployment.
         */
        address dipStrategy;
        /**
         * @notice Deployed M8 SellThePumpStrategy; zero until M8 deployment.
         */
        address pumpStrategy;
        /**
         * @notice Optional immutable Zap authorized by SwapExecutor.
         */
        address zap;
        /**
         * @notice Safe granted the timelock proposer/canceller roles.
         */
        address governanceSafe;
        /**
         * @notice Restricted account granted the timelock executor role.
         */
        address authorizedExecutor;
        /**
         * @notice Pause-only guardian configured in VaultFactory.
         */
        address guardianSafe;
        /**
         * @notice Fixed production recipient configured in FeeCollector.
         */
        address treasury;
        /**
         * @notice Timelock minimum delay for governance operations.
         */
        uint256 timelockDelay;
        /**
         * @notice Initial protocol fee charged on collected trading fees.
         */
        uint256 initialProtocolFeeBps;
        /**
         * @notice Initial governance-adjustable protocol-fee cap.
         */
        uint256 initialMaxProtocolFeeBps;
        /**
         * @notice Maximum deposit cap accepted for new ETH/USDC vaults.
         */
        uint256 ethUsdcMaxDepositCap;
        /**
         * @notice Uniswap V3 factory used to verify or derive fallback pool dependencies.
         */
        address uniswapV3Factory;
        /**
         * @notice Mainnet USDC token address.
         */
        address usdc;
    }

    /**
     * @notice Ethereum mainnet chain id.
     */
    uint256 internal constant ETHEREUM_MAINNET_CHAIN_ID = 1;
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
// Ethereum Sepolia dependencies
address internal constant SEPOLIA_STATE_VIEW =
    0xe1dd9c3fa50edb962e442f60dfbc432e24537e4c;

address internal constant SEPOLIA_POOL_MANAGER =
    0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

address internal constant SEPOLIA_POSITION_MANAGER =
    0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;

address internal constant SEPOLIA_PERMIT2 =
    0x000000000022D473030F116dDEE9F6B43aC78BA3;

address internal constant SEPOLIA_UNIVERSAL_ROUTER =
    0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;

address internal constant SEPOLIA_CHAINLINK_ETH_USD =
    0x694AA1769357215DE4FAC081bf1f309aDC325306;

address internal constant SEPOLIA_WETH =
    0xfff9976782d46cc05630d1f6ebab18b2324d6b14;

address internal constant SEPOLIA_USDC =
    0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    /**
     * @notice Ethereum mainnet Uniswap V4 StateView.
     */
    address internal constant MAINNET_STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;
    /**
     * @notice Ethereum mainnet Uniswap V4 PoolManager.
     */
    address internal constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    /**
     * @notice Ethereum mainnet Uniswap V4 PositionManager.
     */
    address internal constant MAINNET_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    /**
     * @notice Ethereum mainnet Permit2.
     */
    address internal constant MAINNET_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /**
     * @notice Official Uniswap Universal Router 2.2.0 on Ethereum mainnet.
     */
    address internal constant MAINNET_UNIVERSAL_ROUTER = 0xab863E752Bf67D8DCDD929EaAe9Be9dc83Fb3BbB;
    /**
     * @notice Ethereum mainnet Chainlink ETH/USD feed.
     */
    address internal constant MAINNET_CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    /**
     * @notice Ethereum mainnet Uniswap V3 factory.
     */
    address internal constant MAINNET_UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    /**
     * @notice Ethereum mainnet WETH token.
     */
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    /**
     * @notice Ethereum mainnet USDC token.
     */
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /**
     * @notice Ethereum mainnet Uniswap V3 WETH/USDC 0.05% pool used as TWAP fallback.
     */
    address internal constant MAINNET_V3_ETH_USDC_005_POOL = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;

    /**
     * @notice ETH/USDC V4 pool fee tier used by the M2 fork tests.
     */
    uint24 internal constant V4_ETH_USDC_FEE = 500;
    /**
     * @notice ETH/USDC V4 pool tick spacing used by the M2 fork tests.
     */
    int24 internal constant V4_ETH_USDC_TICK_SPACING = 10;
    /**
     * @notice V3 fallback TWAP window for ETH/USDC, in seconds.
     */
    uint32 internal constant ETH_USDC_TWAP_WINDOW = 1_800;
    /**
     * @notice Maximum allowed ETH/USDC deviation from reference price, in basis points.
     */
    uint16 internal constant ETH_USDC_MAX_DEVIATION_BPS = 1_000;

    /**
     * @notice Returns the configuration for the current chain id.
     * @return configs Network-specific deployment and PriceGuard configuration.
     */
    function getConfigs() public view returns (Configs memory configs) {
    if (block.chainid == ETHEREUM_MAINNET_CHAIN_ID) {
        return _mainnet();
    }

    if (block.chainid == SEPOLIA_CHAIN_ID) {
        return _sepolia();
    }

    revert UnsupportedNetwork(block.chainid);
}

    /**
     * @notice Builds the Ethereum mainnet configuration.
     * @return configs Ethereum mainnet deployment and PriceGuard configuration.
     */
    function _mainnet() private pure returns (Configs memory configs) {
        configs.chainId = ETHEREUM_MAINNET_CHAIN_ID;
        configs.stateView = IStateViewLike(MAINNET_STATE_VIEW);
        configs.poolManager = MAINNET_POOL_MANAGER;
        configs.positionManager = MAINNET_POSITION_MANAGER;
        configs.permit2 = MAINNET_PERMIT2;
        configs.universalRouter = MAINNET_UNIVERSAL_ROUTER;
        configs.sequencerUptimeFeed = address(0);
        configs.nativeWrapper = MAINNET_WETH;
        configs.deploymentOwner = address(0);
        configs.timelock = address(0);
        configs.ethUsdcPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(MAINNET_USDC),
            fee: V4_ETH_USDC_FEE,
            tickSpacing: V4_ETH_USDC_TICK_SPACING,
            hooks: address(0)
        });
        configs.ethUsdcPriceConfig = IPriceGuard.PairConfig({
            chainlinkFeed: MAINNET_CHAINLINK_ETH_USD,
            invertFeed: false,
            maxStaleness: 2 hours,
            minAnswer: 100e8,
            maxAnswer: 20_000e8,
            v3Pool: MAINNET_V3_ETH_USDC_005_POOL,
            invertV3: true,
            twapWindow: ETH_USDC_TWAP_WINDOW,
            maxDeviationBps: ETH_USDC_MAX_DEVIATION_BPS
        });
        configs.priceGuard = address(0);
        configs.shapeLibrary = address(0);
        configs.swapExecutor = address(0);
        configs.vaultImplementation = address(0);
        configs.vaultFactory = address(0);
        configs.feeCollector = address(0);
        configs.vaultLens = address(0);
        configs.normalStrategy = address(0);
        configs.dipStrategy = address(0);
        configs.pumpStrategy = address(0);
        configs.zap = address(0);
        configs.governanceSafe = address(0);
        configs.authorizedExecutor = address(0);
        configs.guardianSafe = address(0);
        configs.treasury = address(0);
        configs.timelockDelay = 48 hours;
        configs.initialProtocolFeeBps = 0;
        configs.initialMaxProtocolFeeBps = 10_000;
        configs.ethUsdcMaxDepositCap = 0;
        configs.uniswapV3Factory = MAINNET_UNISWAP_V3_FACTORY;
        configs.usdc = MAINNET_USDC;
    }
function _sepolia() private pure returns (Configs memory configs) {
    configs.chainId = SEPOLIA_CHAIN_ID;
    configs.priceGuard = 0x16e9bB9aB0A03Eefd5407b6A1DE187Fe0455917B;
    configs.shapeLibrary = 0x100a9A2eB0444E60eA593BE853dBBb8E324dd9C1;

    configs.stateView = IStateViewLike(SEPOLIA_STATE_VIEW);
    configs.poolManager = SEPOLIA_POOL_MANAGER;
    configs.positionManager = SEPOLIA_POSITION_MANAGER;
    configs.permit2 = SEPOLIA_PERMIT2;
    configs.universalRouter = SEPOLIA_UNIVERSAL_ROUTER;

    configs.sequencerUptimeFeed = address(0);
    configs.nativeWrapper = SEPOLIA_WETH;

    configs.deploymentOwner = address(0);

    configs.ethUsdcPoolKey = PoolKey({
        currency0: Currency.wrap(address(0)),
        currency1: Currency.wrap(SEPOLIA_USDC),
        fee: V4_ETH_USDC_FEE,
        tickSpacing: 20,
        hooks: address(0)
    });

    configs.ethUsdcPriceConfig = IPriceGuard.PairConfig({
        chainlinkFeed: SEPOLIA_CHAINLINK_ETH_USD,
        invertFeed: false,
        maxStaleness: 2 hours,
        minAnswer: 100e8,
        maxAnswer: 20_000e8,
        v3Pool: address(0),
        invertV3: false,
        twapWindow: ETH_USDC_TWAP_WINDOW,
        maxDeviationBps: ETH_USDC_MAX_DEVIATION_BPS
    });

    configs.timelock = 0x6C96C7A454e26a8Ced91f0F54638E9e0c3e6C954;
    configs.swapExecutor = 0xF75eB1D043E33ad8Fa581bff63D6452Bc752A011;
    configs.vaultImplementation = 0x145bf19548AbcDd5a0355596de00E4d8992a6B60;
    configs.vaultFactory = 0xAf7bDb2E8E756af55c24B01fD2Cc0a7A79C1Aa21;
    configs.feeCollector = 0xe3FFe17a8f006dD0F4e13DE51335a6Ff20E4b31f;
    configs.vaultLens = 0x1A0bAD964be3F7e787a982865C5db6Dc1684Ce1d;
    configs.normalStrategy = 0x8d5294A4B8F71078131620584F4cd21F6078FbF8;
    configs.dipStrategy = 0x21D9626CCA2f3992Ab677b7E303A0BB039f6df78;
    configs.pumpStrategy = 0x8ef913e037daceE310d7F965cDBAdf6981357E4D;
    configs.zap = 0x657bfeB41365D7c8EC805D2e57506a4A035739eF;
    configs.timelockDelay = 48 hours;
    configs.initialProtocolFeeBps = 0;
    configs.initialMaxProtocolFeeBps = 10_000;
    configs.ethUsdcMaxDepositCap = 1_000_000_000;

    configs.uniswapV3Factory = address(0);
    configs.governanceSafe = 0x7cbaa5370f5d0ae1b8d61581c020859a84c55583;
    configs.authorizedExecutor = 0x7cbaa5370f5d0ae1b8d61581c020859a84c55583;
    configs.treasury = 0x7cbaa5370f5d0ae1b8d61581c020859a84c55583;
    configs.usdc = SEPOLIA_USDC;
}
}

