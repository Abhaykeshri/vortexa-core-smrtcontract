// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script} from "forge-std/Script.sol";
import {BuyTheDipStrategy} from "../src/strategies/BuyTheDipStrategy.sol";
import {NormalLPStrategy} from "../src/strategies/NormalLPStrategy.sol";
import {SellThePumpStrategy} from "../src/strategies/SellThePumpStrategy.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {SwapExecutor} from "../src/SwapExecutor.sol";
import {Vault} from "../src/Vault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {VaultLens} from "../src/VaultLens.sol";
import {Zap} from "../src/Zap.sol";
import {IPriceGuard} from "../src/interfaces/IPriceGuard.sol";
import {IShapeLibrary} from "../src/interfaces/IShapeLibrary.sol";
import {IVaultFactory} from "../src/interfaces/IVaultFactory.sol";
import {IZapFactory, IZapSwapExecutor} from "../src/interfaces/IZapDependencies.sol";
import {IPermit2Like} from "../src/interfaces/external/IPermit2Like.sol";
import {IPositionManagerLike} from "../src/interfaces/external/IPositionManagerLike.sol";
import {IUniversalRouterLike} from "../src/interfaces/external/IUniversalRouterLike.sol";
import {Strategy} from "../src/libraries/Types.sol";
import {NetworkConfig} from "./NetworkConfigs.s.sol";

/**
 * @title M9 Deployment Script
 * @notice Deploys the complete immutable M9 graph and starts the timelock ownership handover.
 * @dev Zap, SwapExecutor, Vault and VaultFactory form an immutable address graph. Their ordinary CREATE addresses
 *      are predicted from the broadcast deployer's starting nonce and each prediction is checked after deployment.
 */
contract DeployM9 is Script {
    uint256 public constant MAINNET_MIN_DELAY = 48 hours;
    uint64 private constant ZAP_NONCE_OFFSET = 5;
    uint64 private constant EXECUTOR_NONCE_OFFSET = 6;
    uint64 private constant FACTORY_NONCE_OFFSET = 8;

    error MissingGovernanceConfig();
    error MissingDependency();
    error InvalidMainnetDelay();
    error InvalidSafeConfiguration(address safe);
    error WrongChainId(uint256 configured, uint256 actual);
    error InvalidStartingNonce();
    error UnexpectedAddress(bytes32 component, address expected, address actual);
    error MissingDeployedCode(bytes32 component, address target);
    error PriceGuardOwnerMismatch(address actualOwner, address expectedOwner);

    struct Deployment {
        TimelockController timelock;
        FeeCollector feeCollector;
        NormalLPStrategy normalStrategy;
        BuyTheDipStrategy dipStrategy;
        SellThePumpStrategy pumpStrategy;
        Zap zap;
        SwapExecutor swapExecutor;
        Vault vaultImplementation;
        VaultFactory vaultFactory;
        VaultLens vaultLens;
    }

    /**
     * @notice Broadcasts an M9 deployment using only chain-selected NetworkConfig values.
     */
    function run() external returns (Deployment memory deployed, NetworkConfig.Configs memory configs) {
        configs = new NetworkConfig().getConfigs();
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        configs.deploymentOwner = deployer;
        deployed = deploy(configs, deployer, vm.getNonce(deployer));
        vm.stopBroadcast();
        _populate(configs, deployed);
    }

    /**
     * @notice Deploys M9 from an explicitly supplied sender and nonce.
     * @dev The current CREATE sender must be `deployer`; this entry point supports deterministic script tests.
     */
    function deploy(NetworkConfig.Configs memory configs, address deployer, uint64 startingNonce)
        public
        returns (Deployment memory deployed)
    {
        if (deployer == address(0) || configs.deploymentOwner != deployer || vm.getNonce(deployer) != startingNonce) {
            revert InvalidStartingNonce();
        }
        _validate(configs);

        address predictedZap = vm.computeCreateAddress(deployer, startingNonce + ZAP_NONCE_OFFSET);
        address predictedExecutor = vm.computeCreateAddress(deployer, startingNonce + EXECUTOR_NONCE_OFFSET);
        address predictedFactory = vm.computeCreateAddress(deployer, startingNonce + FACTORY_NONCE_OFFSET);
        address[] memory proposers = new address[](1);
        proposers[0] = configs.governanceSafe;
        address[] memory executors = new address[](1);
        executors[0] = configs.authorizedExecutor;

        deployed.timelock = new TimelockController(configs.timelockDelay, proposers, executors, deployer);
        deployed.feeCollector = new FeeCollector(deployer, configs.treasury);
        deployed.normalStrategy = new NormalLPStrategy(IShapeLibrary(configs.shapeLibrary));
        deployed.dipStrategy = new BuyTheDipStrategy(IShapeLibrary(configs.shapeLibrary));
        deployed.pumpStrategy = new SellThePumpStrategy(IShapeLibrary(configs.shapeLibrary));
        deployed.zap = new Zap(
            IZapFactory(predictedFactory),
            IZapSwapExecutor(predictedExecutor),
            address(deployed.normalStrategy),
            address(deployed.dipStrategy),
            address(deployed.pumpStrategy)
        );
        _expectAddress("ZAP", predictedZap, address(deployed.zap));
        deployed.swapExecutor = new SwapExecutor(
            IUniversalRouterLike(configs.universalRouter),
            IPermit2Like(configs.permit2),
            IVaultFactory(predictedFactory),
            IPriceGuard(configs.priceGuard),
            address(deployed.zap)
        );
        _expectAddress("EXECUTOR", predictedExecutor, address(deployed.swapExecutor));
        deployed.vaultImplementation = new Vault(
            IPositionManagerLike(configs.positionManager),
            configs.stateView,
            IPermit2Like(configs.permit2),
            IPriceGuard(configs.priceGuard),
            IShapeLibrary(configs.shapeLibrary),
            address(deployed.swapExecutor),
            predictedFactory,
            configs.poolManager
        );
        deployed.vaultFactory = new VaultFactory(
            deployer,
            address(deployed.vaultImplementation),
            configs.stateView,
            IPriceGuard(configs.priceGuard),
            IShapeLibrary(configs.shapeLibrary),
            address(deployed.feeCollector),
            configs.initialProtocolFeeBps,
            configs.initialMaxProtocolFeeBps
        );
        _expectAddress("FACTORY", predictedFactory, address(deployed.vaultFactory));
        deployed.vaultLens = new VaultLens(deployed.vaultFactory, configs.stateView);

        deployed.vaultFactory.setStrategy(Strategy.NormalLP, deployed.normalStrategy);
        deployed.vaultFactory.setStrategy(Strategy.BuyTheDip, deployed.dipStrategy);
        deployed.vaultFactory.setStrategy(Strategy.SellThePump, deployed.pumpStrategy);
        if (configs.guardianSafe != address(0)) deployed.vaultFactory.setGuardian(configs.guardianSafe);
        if (configs.ethUsdcMaxDepositCap != 0) {
            deployed.vaultFactory.setPoolAllowed(configs.ethUsdcPoolKey, true, true, configs.ethUsdcMaxDepositCap);
        }

        _checkCode(deployed);
        deployed.vaultFactory.transferOwnership(address(deployed.timelock));
        deployed.feeCollector.transferOwnership(address(deployed.timelock));
        _handoffPriceGuard(configs.priceGuard, deployer, address(deployed.timelock));
        deployed.timelock.renounceRole(deployed.timelock.DEFAULT_ADMIN_ROLE(), deployer);
    }

    function _validate(NetworkConfig.Configs memory configs) private view {
        if (configs.chainId != block.chainid) revert WrongChainId(configs.chainId, block.chainid);
        if (
            configs.governanceSafe == address(0) || configs.authorizedExecutor == address(0)
                || configs.treasury == address(0)
        ) revert MissingGovernanceConfig();
        if (
            address(configs.stateView).code.length == 0 || configs.poolManager.code.length == 0
                || configs.positionManager.code.length == 0 || configs.permit2.code.length == 0
                || configs.universalRouter.code.length == 0 || configs.priceGuard.code.length == 0
                || configs.shapeLibrary.code.length == 0
        ) revert MissingDependency();
        if (configs.chainId == 1) {
            if (configs.timelockDelay < MAINNET_MIN_DELAY) revert InvalidMainnetDelay();
            if (configs.guardianSafe == address(0)) revert MissingGovernanceConfig();
            _validateSafe(configs.governanceSafe, 3, 5);
            _validateSafe(configs.guardianSafe, 2, 3);
        }
    }

    function _checkCode(Deployment memory deployed) private view {
        _requireCode("ZAP", address(deployed.zap));
        _requireCode("EXECUTOR", address(deployed.swapExecutor));
        _requireCode("VAULT_IMPLEMENTATION", address(deployed.vaultImplementation));
        _requireCode("FACTORY", address(deployed.vaultFactory));
    }

    function _expectAddress(bytes32 component, address expected, address actual) private pure {
        if (actual != expected) revert UnexpectedAddress(component, expected, actual);
    }

    function _requireCode(bytes32 component, address target) private view {
        if (target.code.length == 0) revert MissingDeployedCode(component, target);
    }

    function _populate(NetworkConfig.Configs memory configs, Deployment memory deployed) private pure {
        configs.timelock = address(deployed.timelock);
        configs.feeCollector = address(deployed.feeCollector);
        configs.normalStrategy = address(deployed.normalStrategy);
        configs.dipStrategy = address(deployed.dipStrategy);
        configs.pumpStrategy = address(deployed.pumpStrategy);
        configs.zap = address(deployed.zap);
        configs.swapExecutor = address(deployed.swapExecutor);
        configs.vaultImplementation = address(deployed.vaultImplementation);
        configs.vaultFactory = address(deployed.vaultFactory);
        configs.vaultLens = address(deployed.vaultLens);
    }

    function _handoffPriceGuard(address guard, address deployer, address timelock) private {
        address currentOwner = PriceGuard(guard).owner();
        if (currentOwner == timelock) return;
        if (currentOwner != deployer) revert PriceGuardOwnerMismatch(currentOwner, deployer);
        PriceGuard(guard).transferOwnership(timelock);
    }

    function _validateSafe(address safe, uint256 minThreshold, uint256 minOwners) private view {
        if (safe.code.length == 0) revert InvalidSafeConfiguration(safe);
        uint256 threshold;
        try IGnosisSafeM9(safe).getThreshold() returns (uint256 value) {
            threshold = value;
        } catch {
            revert InvalidSafeConfiguration(safe);
        }
        try IGnosisSafeM9(safe).getOwners() returns (address[] memory owners) {
            if (threshold < minThreshold || owners.length < minOwners || threshold > owners.length) {
                revert InvalidSafeConfiguration(safe);
            }
        } catch {
            revert InvalidSafeConfiguration(safe);
        }
    }
}

interface IGnosisSafeM9 {
    function getThreshold() external view returns (uint256 threshold);

    function getOwners() external view returns (address[] memory owners);
}
