// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {ShapeLibrary} from "../../src/ShapeLibrary.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {IPriceGuard} from "../../src/interfaces/IPriceGuard.sol";
import {IShapeLibrary} from "../../src/interfaces/IShapeLibrary.sol";
import {IStateViewLike} from "../../src/interfaces/external/IStateViewLike.sol";
import {VaultConfig} from "../../src/libraries/Types.sol";
import {MockVaultPriceGuard, MockVaultStateView} from "../mocks/VaultMocks.sol";

/**
 * A Vault-shaped implementation whose dependency getters are set freely, to drive each factory check on its own.
 * An unset `factory()` returns the caller, so a factory reading it during construction sees its own address.
 * `mode` 1 returns 64 bytes, 2 returns a word with dirty high bits, 3 reverts (for the getter named by `bad`).
 */
contract FakeImplementation {
    mapping(bytes4 => address) public value;
    bytes4 public bad;
    uint8 public mode;

    function set(bytes4 selector, address v) external {
        value[selector] = v;
    }

    function setMalformed(bytes4 selector, uint8 mode_) external {
        bad = selector;
        mode = mode_;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        bytes4 sel = msg.sig;
        if (sel == bad && mode == 1) return abi.encode(value[sel], uint256(0));
        if (sel == bad && mode == 2) return abi.encode(uint256(uint160(value[sel])) | (uint256(1) << 200));
        if (sel == bad && mode == 3) revert("nope");
        // an unset `factory()` answers with the caller: the factory being built or administering this contract
        if (sel == bytes4(keccak256("factory()")) && value[sel] == address(0)) return abi.encode(msg.sender);
        return abi.encode(value[sel]);
    }
}

contract M8FactoryValidationTest is Test {
    bytes4 internal constant FACTORY = bytes4(keccak256("factory()"));
    bytes4 internal constant STATE_VIEW = bytes4(keccak256("stateView()"));
    bytes4 internal constant PRICE_GUARD = bytes4(keccak256("priceGuard()"));
    bytes4 internal constant POSM = bytes4(keccak256("positionManager()"));
    bytes4 internal constant PERMIT2 = bytes4(keccak256("permit2()"));
    bytes4 internal constant POOL_MANAGER = bytes4(keccak256("poolManager()"));
    bytes4 internal constant EXECUTOR = bytes4(keccak256("swapExecutor()"));
    bytes4 internal constant M6_MODULE = bytes4(keccak256("m6Module()"));
    bytes4 internal constant VAULT_MODULE = bytes4(keccak256("vaultModule()"));

    MockVaultStateView internal stateView;
    MockVaultPriceGuard internal guard;
    ShapeLibrary internal shapes;
    FeeCollector internal collector;
    FakeImplementation internal executor;
    address internal module = makeAddr("m6Module");

    function setUp() public {
        stateView = new MockVaultStateView();
        guard = new MockVaultPriceGuard();
        shapes = new ShapeLibrary();
        collector = new FeeCollector(address(this), makeAddr("treasury"));
        executor = new FakeImplementation();
        executor.set(PRICE_GUARD, address(guard));
        executor.set(VAULT_MODULE, module);
    }

    /**
     * Constructor guards: zero addresses, dependencies without code, and fee bounds. Deployments that must revert go
     * through an external self-call: an expected revert inside a `new` of another file's contract would otherwise end
     * the test early (forge deploys it through a cheatcode).
     */
    function test_constructorRejectsZeroCodeAndFeeMisconfiguration() public {
        FakeImplementation impl = _compatible();
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        this.deployRaw(address(impl), address(0), 0, 10_000);
        vm.expectRevert(VaultFactory.NotContract.selector);
        this.deployRaw(address(impl), makeAddr("eoaCollector"), 0, 10_000);
        vm.expectRevert(VaultFactory.InvalidProtocolFee.selector);
        this.deployRaw(address(impl), address(collector), 0, 10_001);
        vm.expectRevert(VaultFactory.InvalidProtocolFee.selector);
        this.deployRaw(address(impl), address(collector), 2_501, 2_500);
        VaultFactory ok = this.deployRaw(address(impl), address(collector), 2_500, 2_500);
        assertEq(ok.protocolFeeBps(), 2_500);
        assertEq(ok.maxProtocolFeeBps(), 2_500);
    }

    /**
     * The executor must belong to this factory and guard, and serve the implementation's M6 module. Each case starts
     * from a wiring that deploys, then breaks exactly one link.
     */
    function test_constructorRejectsAnExecutorBoundElsewhere() public {
        FakeImplementation impl = _compatible();
        this.deployRaw(address(impl), address(collector), 0, 10_000); // the baseline is accepted

        executor.set(FACTORY, makeAddr("otherFactory"));
        vm.expectRevert(VaultFactory.InvalidImplementation.selector);
        this.deployRaw(address(impl), address(collector), 0, 10_000);
        executor.set(FACTORY, address(0));

        executor.set(PRICE_GUARD, makeAddr("otherGuard"));
        vm.expectRevert(VaultFactory.InvalidImplementation.selector);
        this.deployRaw(address(impl), address(collector), 0, 10_000);
        executor.set(PRICE_GUARD, address(guard));

        impl.set(M6_MODULE, makeAddr("otherModule"));
        vm.expectRevert(VaultFactory.InvalidImplementation.selector);
        this.deployRaw(address(impl), address(collector), 0, 10_000);
        impl.set(M6_MODULE, module);

        this.deployRaw(address(impl), address(collector), 0, 10_000); // and the restored wiring deploys again
    }

    /**
     * `setImplementation` refuses a change of any single dependency, and an executor relationship that differs.
     */
    function test_setImplementationRejectsEachDependencyChange() public {
        VaultFactory factory = this.deployRaw(address(_compatible()), address(collector), 0, 10_000);

        bytes4[8] memory deps = [FACTORY, STATE_VIEW, PRICE_GUARD, POSM, PERMIT2, POOL_MANAGER, EXECUTOR, M6_MODULE];
        for (uint256 i; i < deps.length; ++i) {
            FakeImplementation candidate = _compatible();
            candidate.set(deps[i], makeAddr(string.concat("other-", vm.toString(i))));
            vm.expectRevert(VaultFactory.InvalidImplementation.selector);
            factory.setImplementation(address(candidate));
        }
        FakeImplementation good = _compatible();
        factory.setImplementation(address(good));
        assertEq(factory.implementation(), address(good));
    }

    /**
     * Getters are decoded strictly: extra return data, dirty high bits or a revert all count as incompatible.
     */
    function test_getterDecodingIsStrict() public {
        VaultFactory factory = this.deployRaw(address(_compatible()), address(collector), 0, 10_000);
        for (uint8 mode = 1; mode <= 3; ++mode) {
            FakeImplementation candidate = _compatible();
            candidate.setMalformed(POSM, mode);
            vm.expectRevert(VaultFactory.InvalidImplementation.selector);
            factory.setImplementation(address(candidate));
        }
    }

    /**
     * Coverage gaps: an implementation reporting a zero dependency, a zero or code-less candidate, and a zero creator.
     */
    function test_zeroDependenciesCandidatesAndCreatorsAreRefused() public {
        FakeImplementation impl = _compatible();
        impl.set(POSM, address(0));
        vm.expectRevert(VaultFactory.InvalidImplementation.selector);
        this.deployRaw(address(impl), address(collector), 0, 10_000);

        VaultFactory factory = this.deployRaw(address(_compatible()), address(collector), 0, 10_000);
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.setImplementation(address(0));
        vm.expectRevert(VaultFactory.InvalidImplementation.selector);
        factory.setImplementation(makeAddr("eoaImplementation"));

        VaultConfig memory config;
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.predictVaultAddress(address(0), config, "N", "S");
    }

    function _compatible() internal returns (FakeImplementation impl) {
        impl = new FakeImplementation();
        impl.set(STATE_VIEW, address(stateView));
        impl.set(PRICE_GUARD, address(guard));
        impl.set(POSM, address(0x1001));
        impl.set(PERMIT2, address(0x1002));
        impl.set(POOL_MANAGER, address(0x1003));
        impl.set(EXECUTOR, address(executor));
        impl.set(M6_MODULE, module);
    }

    /**
     * External so `vm.expectRevert` can catch a reverting constructor and the test continues.
     */
    function deployRaw(address impl, address feeCollector, uint256 fee, uint256 maxFee)
        external
        returns (VaultFactory)
    {
        return new VaultFactory(
            address(this),
            impl,
            IStateViewLike(address(stateView)),
            IPriceGuard(address(guard)),
            IShapeLibrary(address(shapes)),
            feeCollector,
            fee,
            maxFee
        );
    }
}
