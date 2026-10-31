// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
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
import {IPriceGuard} from "../src/interfaces/IPriceGuard.sol";
import {IShapeLibrary} from "../src/interfaces/IShapeLibrary.sol";
import {IVaultFactory} from "../src/interfaces/IVaultFactory.sol";
import {IPermit2Like} from "../src/interfaces/external/IPermit2Like.sol";
import {IPositionManagerLike} from "../src/interfaces/external/IPositionManagerLike.sol";
import {IUniversalRouterLike} from "../src/interfaces/external/IUniversalRouterLike.sol";
import {Strategy} from "../src/libraries/Types.sol";
import {NetworkConfig} from "./NetworkConfigs.s.sol";

/**
 * @title M8 Deployment Script
 * @notice Deploys the immutable M8 graph and starts its two-step timelock ownership handover.
 * @dev SwapExecutor, Vault and VaultFactory form an immutable address cycle. The script resolves it by predicting
 *      the factory's ordinary CREATE address from the configured deployer nonce. CREATE2 cannot resolve this cycle
 *      because each candidate address changes the other contracts' init-code hashes.
 */
contract DeployM8 is Script {
    uint256 public constant MAINNET_MIN_DELAY = 48 hours;
    uint64 private constant FACTORY_NONCE_OFFSET = 7;

    error MissingGovernanceConfig();
    error MissingDependency();
    error InvalidMainnetDelay();
    error InvalidSafeConfiguration(address safe);
    error WrongChainId(uint256 configured, uint256 actual);
    error InvalidStartingNonce();
    error UnexpectedFactoryAddress(address expected, address actual);
    error PriceGuardOwnerMismatch(address actualOwner, address expectedOwner);
    error ZapRequiredOnMainnet();

    struct Deployment {
        TimelockController timelock;
        FeeCollector feeCollector;
        NormalLPStrategy normalStrategy;
        BuyTheDipStrategy dipStrategy;
        SellThePumpStrategy pumpStrategy;
        SwapExecutor swapExecutor;
        Vault vaultImplementation;
        VaultFactory vaultFactory;
        VaultLens vaultLens;
    }

    /**
     * @notice Broadcasts an M8 deployment using only chain-selected NetworkConfig values.
     * @dev Mainnet config intentionally contains zero placeholders for governance and existing Vortexa deployments;
     *      populate known addresses in NetworkConfigs.s.sol before running this function.
     */
    function run() external returns (Deployment memory deployed, NetworkConfig.Configs memory configs) {
        configs = new NetworkConfig().getConfigs();

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        configs.deploymentOwner = deployer;
        uint64 startingNonce = vm.getNonce(deployer);
        deployed = deploy(configs, deployer, startingNonce);
        vm.stopBroadcast();
    }

    /**
     * @notice Deploys M8 from an explicitly supplied owner and starting nonce.
     * @dev Exposed for deterministic dry-run and script tests. The calling address must equal `deployer` because
     *      ordinary CREATE address prediction is sender-specific.
     */
    function deploy(NetworkConfig.Configs memory configs, address deployer, uint64 startingNonce)
        public
        returns (Deployment memory deployed)
    {
        if (deployer == address(0) || configs.deploymentOwner != deployer) {
            revert InvalidStartingNonce();
        }
        _validate(configs);
        if (vm.getNonce(deployer) != startingNonce) revert InvalidStartingNonce();

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
        deployed.swapExecutor = new SwapExecutor(
            IUniversalRouterLike(configs.universalRouter),
            IPermit2Like(configs.permit2),
            IVaultFactory(predictedFactory),
            IPriceGuard(configs.priceGuard),
            configs.zap
        );
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
        if (address(deployed.vaultFactory) != predictedFactory) {
            revert UnexpectedFactoryAddress(predictedFactory, address(deployed.vaultFactory));
        }
        deployed.vaultLens = new VaultLens(deployed.vaultFactory, configs.stateView);

        deployed.vaultFactory.setStrategy(Strategy.NormalLP, deployed.normalStrategy);
        deployed.vaultFactory.setStrategy(Strategy.BuyTheDip, deployed.dipStrategy);
        deployed.vaultFactory.setStrategy(Strategy.SellThePump, deployed.pumpStrategy);
        if (configs.guardianSafe != address(0)) deployed.vaultFactory.setGuardian(configs.guardianSafe);
        if (configs.ethUsdcMaxDepositCap != 0) {
            deployed.vaultFactory.setPoolAllowed(configs.ethUsdcPoolKey, true, true, configs.ethUsdcMaxDepositCap);
        }

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
            // SwapExecutor's Zap is immutable and VaultFactory pins the executor, so a production graph deployed
            // without the Zap can never add it: the M9 Zap would need a new executor, implementation and factory.
            // Guide 13.1 deploys the Zap inside the same nonce-predicted sequence.
            if (configs.zap == address(0)) revert ZapRequiredOnMainnet();
            if (configs.timelockDelay < MAINNET_MIN_DELAY) revert InvalidMainnetDelay();
            if (configs.guardianSafe == address(0)) revert MissingGovernanceConfig();
            _validateSafe(configs.governanceSafe, 3, 5);
            _validateSafe(configs.guardianSafe, 2, 3);
        }
    }

    function _handoffPriceGuard(address guard, address deployer, address timelock) private {
        address currentOwner = PriceGuard(guard).owner();
        if (currentOwner == timelock) return;
        if (currentOwner != deployer) revert PriceGuardOwnerMismatch(currentOwner, deployer);
        PriceGuard(guard).transferOwnership(timelock);
    }

    /**
     * @notice Requires a Safe with at least `minThreshold` signatures out of at least `minOwners` owners.
     * @dev Guide 10.4 asks for "at least 3 of 5" (governance) and 2 of 3 (guardian); a stronger Safe, such as
     *      4 of 7, must not block deployment, so both bounds are minimums.
     */
    function _validateSafe(address safe, uint256 minThreshold, uint256 minOwners) private view {
        if (safe.code.length == 0) revert InvalidSafeConfiguration(safe);
        uint256 threshold;
        try IGnosisSafeLike(safe).getThreshold() returns (uint256 value) {
            threshold = value;
        } catch {
            revert InvalidSafeConfiguration(safe);
        }
        try IGnosisSafeLike(safe).getOwners() returns (address[] memory owners) {
            if (threshold < minThreshold || owners.length < minOwners || threshold > owners.length) {
                revert InvalidSafeConfiguration(safe);
            }
        } catch {
            revert InvalidSafeConfiguration(safe);
        }
    }
}

interface IGnosisSafeLike {
    function getThreshold() external view returns (uint256 threshold);

    function getOwners() external view returns (address[] memory owners);
}
