// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Vault} from "../../src/Vault.sol";
import {ISwapExecutor} from "../../src/interfaces/ISwapExecutor.sol";
import {IPermit2Like} from "../../src/interfaces/external/IPermit2Like.sol";
import {IPositionManagerLike} from "../../src/interfaces/external/IPositionManagerLike.sol";
import {VaultM6Module} from "../../src/VaultM6Module.sol";
import {Band, Currency, PoolKey, RebalanceParams, Strategy} from "../../src/libraries/Types.sol";
import {CurrencyLib} from "../../src/libraries/CurrencyLib.sol";
import {MockShapeLibrary} from "../mocks/VaultMocks.sol";
import {VaultM6Test} from "../unit/VaultM6.t.sol";

contract ReentrantSwapExecutor is ISwapExecutor {
    using CurrencyLib for Currency;

    address public immutable vaultModule = address(new VaultM6Module());
    Vault public target;
    bytes4 public reentryError;

    function setTarget(Vault target_) external {
        target = target_;
    }

    function swap(Currency, Currency, uint256, uint256) external payable returns (uint256) {
        revert InvalidInput();
    }

    function swapExactInput(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256)
        external
        payable
        returns (uint256)
    {
        (bool ok, bytes memory reason) = address(target)
            .call(abi.encodeCall(Vault.rebalance, (RebalanceParams({newCenterTick: 0, maxSlippageBps: 100}))));
        assert(!ok);
        if (reason.length >= 4) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(reason, 0x20))
            }
            reentryError = selector;
        }
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        output.transfer(msg.sender, amountIn);
        return amountIn;
    }
}

contract VaultM6AttacksTest is VaultM6Test {
    function test_swap_executor_callback_cannot_reenter_rebalance() public {
        ReentrantSwapExecutor attacker = new ReentrantSwapExecutor();
        Vault attackImplementation = new Vault(
            IPositionManagerLike(address(positionManager)),
            stateView,
            IPermit2Like(address(permit2)),
            priceGuard,
            new MockShapeLibrary(),
            address(attacker),
            address(factory),
            address(0x4444)
        );
        Vault attacked = Vault(payable(Clones.clone(address(attackImplementation))));
        vm.prank(address(factory));
        attacked.initialize("Attack Vault", "ATK", address(strategy), _config(Strategy.NormalLP, true, false));
        factory.setVault(address(attacked), true);
        attacker.setTarget(attacked);
        token1.mint(user, 100_000 ether);
        vm.startPrank(user);
        token1.approve(address(attacked), type(uint256).max);
        attacked.depositPair(0, 100_000 ether, 1, user);
        vm.stopPrank();

        Band[] memory target = new Band[](1);
        target[0] = Band({tickLower: -60, tickUpper: 60, tokenId: 0, liquidity: 0});
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;
        strategy.setPlan(target, weights, true, false, 50_000 ether, false);
        strategy.setRebalance(true, bytes32("DRIFT"));
        token0.mint(address(attacker), 50_000 ether);

        vm.prank(keeper);
        attacked.rebalance(RebalanceParams({newCenterTick: 0, maxSlippageBps: 100}));

        assertEq(attacker.reentryError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(positionManager.ownerOf(attacked.bands()[0].tokenId), address(attacked));
    }
}
