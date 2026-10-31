// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Currency} from "../../src/libraries/Types.sol";
import {CurrencyLib} from "../../src/libraries/CurrencyLib.sol";
import {MintableToken, RevertingReceiver, GasHungryReceiver} from "../mocks/TokenMocks.sol";

contract CurrencyVault {
    using CurrencyLib for Currency;

    receive() external payable {}

    function send(Currency c, address to, uint256 amount) external {
        c.transfer(to, amount);
    }

    function balance(Currency c) external view returns (uint256) {
        return c.balanceOfSelf();
    }
}

/**
 * @dev Randomly funds a vault and sends native currency and an ERC-20 to a mix of well-behaved and hostile
 *      recipients. Conservation must hold no matter which sends succeed or revert.
 */
contract CurrencyHandler is Test {
    CurrencyVault public vault;
    MintableToken public token;
    address[] public recipients;

    uint256 public totalNativeFunded;
    uint256 public totalTokenMinted;
    uint256 public successfulSends;
    uint256 public revertedSends;

    constructor() {
        vault = new CurrencyVault();
        token = new MintableToken();
        recipients.push(makeAddr("r0"));
        recipients.push(makeAddr("r1"));
        recipients.push(address(new RevertingReceiver()));
        recipients.push(address(new GasHungryReceiver()));
    }

    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }

    function fund(uint96 nativeAmount, uint96 tokenAmount) external {
        vm.deal(address(this), nativeAmount);
        (bool ok,) = address(vault).call{value: nativeAmount}("");
        assertTrue(ok);
        totalNativeFunded += nativeAmount;
        token.mint(address(vault), tokenAmount);
        totalTokenMinted += tokenAmount;
    }

    function sendNative(uint256 recipientSeed, uint256 amount) external {
        address to = recipients[recipientSeed % recipients.length];
        amount = bound(amount, 0, address(vault).balance + 1); // sometimes more than the vault holds
        try vault.send(Currency.wrap(address(0)), to, amount) {
            successfulSends++;
        } catch {
            revertedSends++;
        }
    }

    function sendToken(uint256 recipientSeed, uint256 amount) external {
        address to = recipients[recipientSeed % recipients.length];
        amount = bound(amount, 0, token.balanceOf(address(vault)) + 1);
        try vault.send(Currency.wrap(address(token)), to, amount) {
            successfulSends++;
        } catch {
            revertedSends++;
        }
    }
}

contract CurrencyLibInvariantTest is StdInvariant, Test {
    CurrencyHandler internal handler;

    function setUp() public {
        handler = new CurrencyHandler();
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = CurrencyHandler.fund.selector;
        selectors[1] = CurrencyHandler.sendNative.selector;
        selectors[2] = CurrencyHandler.sendToken.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /**
     * @dev Native currency is conserved: whatever left the vault arrived at a recipient, and failed sends moved
     *      nothing.
     */
    function invariant_native_value_is_conserved() public view {
        uint256 total = address(handler.vault()).balance;
        for (uint256 i; i < handler.recipientCount(); ++i) {
            total += handler.recipients(i).balance;
        }
        assertEq(total, handler.totalNativeFunded());
    }

    function invariant_token_value_is_conserved() public view {
        uint256 total = handler.token().balanceOf(address(handler.vault()));
        for (uint256 i; i < handler.recipientCount(); ++i) {
            total += handler.token().balanceOf(handler.recipients(i));
        }
        assertEq(total, handler.totalTokenMinted());
        assertEq(handler.token().totalSupply(), handler.totalTokenMinted());
    }

    function invariant_balance_view_matches_reality() public view {
        CurrencyVault vault = handler.vault();
        assertEq(vault.balance(Currency.wrap(address(0))), address(vault).balance);
        assertEq(vault.balance(Currency.wrap(address(handler.token()))), handler.token().balanceOf(address(vault)));
    }

    function invariant_the_reverting_receiver_never_holds_funds() public view {
        assertEq(handler.recipients(2).balance, 0);
    }
}
