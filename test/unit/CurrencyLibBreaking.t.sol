// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "../../src/libraries/Types.sol";
import {CurrencyLib} from "../../src/libraries/CurrencyLib.sol";
import {
    MintableToken,
    FeeOnTransferToken,
    FalseReturningToken,
    NoReturnToken,
    RevertingToken,
    ZeroTransferRevertingToken,
    BlacklistToken,
    GasHungryReceiver,
    RevertingReceiver
} from "../mocks/TokenMocks.sol";

contract CurrencyHarness {
    using CurrencyLib for Currency;

    function balance(Currency c) external view returns (uint256) {
        return c.balanceOfSelf();
    }

    function send(Currency c, address to, uint256 amount) external {
        c.transfer(to, amount);
    }

    /**
     * @dev Reports the native balance seen inside a payable call (it already includes msg.value).
     */
    function balanceInsidePayableCall() external payable returns (uint256) {
        return Currency.wrap(address(0)).balanceOfSelf();
    }

    receive() external payable {}
}

/**
 * @dev A vault that pays out BEFORE zeroing the balance: the textbook reentrancy bug that CurrencyLib's native
 *      transfer enables if a call site skips checks-effects-interactions.
 */
contract UnsafeNativeVault {
    using CurrencyLib for Currency;

    mapping(address => uint256) public balances;

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    function withdraw() external {
        uint256 amount = balances[msg.sender];
        Currency.wrap(address(0)).transfer(msg.sender, amount); // interaction first: WRONG
        balances[msg.sender] = 0;
    }
}

/**
 * @dev The same vault written with checks-effects-interactions.
 */
contract SafeNativeVault {
    using CurrencyLib for Currency;

    mapping(address => uint256) public balances;

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    function withdraw() external {
        uint256 amount = balances[msg.sender];
        balances[msg.sender] = 0; // effect first
        Currency.wrap(address(0)).transfer(msg.sender, amount);
    }
}

interface IWithdrawable {
    function deposit() external payable;
    function withdraw() external;
}

contract ReentrantAttacker {
    IWithdrawable public immutable vault;
    uint256 public reentries;

    constructor(IWithdrawable vault_) {
        vault = vault_;
    }

    function attack() external payable {
        vault.deposit{value: msg.value}();
        vault.withdraw();
    }

    receive() external payable {
        if (address(vault).balance >= msg.value && reentries < 5) {
            reentries++;
            vault.withdraw();
        }
    }
}

contract CurrencyLibBreakingTest is Test {
    Currency internal constant NATIVE = Currency.wrap(address(0));

    CurrencyHarness internal h;
    address internal alice = makeAddr("alice");

    function setUp() public {
        h = new CurrencyHarness();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Zero amounts never touch the token
    // ------------------------------------------------------------------------------------------------------------

    function test_zero_amount_transfer_makes_no_external_call() public {
        ZeroTransferRevertingToken token = new ZeroTransferRevertingToken();
        token.mint(address(h), 5);
        h.send(Currency.wrap(address(token)), alice, 0); // would revert if the token were called

        RevertingReceiver receiver = new RevertingReceiver();
        h.send(NATIVE, address(receiver), 0); // would revert if the receiver were called
        RevertingToken always = new RevertingToken();
        h.send(Currency.wrap(address(always)), alice, 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Hostile ERC-20 behaviours
    // ------------------------------------------------------------------------------------------------------------

    function test_no_return_value_token_transfers_succeed() public {
        NoReturnToken usdtLike = new NoReturnToken();
        usdtLike.mint(address(h), 100);
        h.send(Currency.wrap(address(usdtLike)), alice, 40);
        assertEq(usdtLike.balanceOf(alice), 40);
        assertEq(usdtLike.balanceOf(address(h)), 60);
    }

    function test_false_returning_token_reverts() public {
        FalseReturningToken token = new FalseReturningToken();
        token.mint(address(h), 100);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        h.send(Currency.wrap(address(token)), alice, 1);
    }

    function test_reverting_and_blacklisting_tokens_revert() public {
        RevertingToken always = new RevertingToken();
        vm.expectRevert("always reverts");
        h.send(Currency.wrap(address(always)), alice, 1);

        BlacklistToken bl = new BlacklistToken();
        bl.mint(address(h), 10);
        bl.blacklist(alice);
        vm.expectRevert("blacklisted");
        h.send(Currency.wrap(address(bl)), alice, 1);
        assertEq(bl.balanceOf(address(h)), 10, "failed transfer moved nothing");
    }

    /**
     * @dev CurrencyLib reports success for a fee-on-transfer token but the recipient gets less. Call sites that
     *      account in received amounts (the vault and zap) must measure balance deltas, never trust `amount`.
     */
    function test_fee_on_transfer_token_delivers_less_than_requested() public {
        FeeOnTransferToken token = new FeeOnTransferToken();
        token.mint(address(h), 1000);
        h.send(Currency.wrap(address(token)), alice, 1000);
        assertLt(token.balanceOf(alice), 1000);
        assertEq(token.balanceOf(alice), 990);
    }

    function test_insufficient_balance_reverts_for_both_currency_kinds() public {
        MintableToken token = new MintableToken();
        token.mint(address(h), 5);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(h), 5, 6));
        h.send(Currency.wrap(address(token)), alice, 6);

        vm.deal(address(h), 1 ether);
        vm.expectRevert(CurrencyLib.NativeTransferFailed.selector);
        h.send(NATIVE, alice, 1 ether + 1);
    }

    function test_non_contract_token_address_cannot_be_used() public {
        Currency fake = Currency.wrap(address(0x1234)); // an EOA masquerading as a token
        vm.expectRevert();
        h.send(fake, alice, 1);
        vm.expectRevert();
        h.balance(fake);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Native currency behaviour that call sites must account for
    // ------------------------------------------------------------------------------------------------------------

    function test_native_send_forwards_more_than_the_2300_gas_stipend() public {
        GasHungryReceiver receiver = new GasHungryReceiver();
        vm.deal(address(h), 1 ether);
        h.send(NATIVE, address(receiver), 1 ether);
        assertEq(address(receiver).balance, 1 ether);
        assertGt(receiver.sink(), 0, "receiver ran more code than a 2300-gas stipend allows");
    }

    function test_native_send_to_a_reverting_receiver_reverts_and_moves_nothing() public {
        RevertingReceiver receiver = new RevertingReceiver();
        vm.deal(address(h), 1 ether);
        vm.expectRevert(CurrencyLib.NativeTransferFailed.selector);
        h.send(NATIVE, address(receiver), 1 ether);
        assertEq(address(h).balance, 1 ether);
    }

    /**
     * @dev KNOWN ISSUE (call-site responsibility, see docs/known-issues.md): a native transfer to the zero address
     *      succeeds and burns the ETH, unlike ERC-20s which revert. Every call site must reject a zero receiver.
     */
    function test_known_issue_native_transfer_to_zero_address_burns_funds() public {
        vm.deal(address(h), 1 ether);
        h.send(NATIVE, address(0), 1 ether);
        assertEq(address(h).balance, 0);
        assertEq(address(0).balance, 1 ether);

        MintableToken token = new MintableToken();
        token.mint(address(h), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        h.send(Currency.wrap(address(token)), address(0), 1);
    }

    /**
     * @dev The vault pitfall from the guide: inside a payable call the balance already includes msg.value.
     */
    function test_native_balance_inside_a_payable_call_includes_msg_value() public {
        vm.deal(address(h), 3 ether);
        vm.deal(address(this), 2 ether);
        uint256 seen = h.balanceInsidePayableCall{value: 2 ether}();
        assertEq(seen, 5 ether, "callers must subtract msg.value when snapshotting idle ETH");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Reentrancy: the library forwards control, so call sites must use checks-effects-interactions
    // ------------------------------------------------------------------------------------------------------------

    function test_reentrancy_drains_a_vault_that_pays_before_updating_state() public {
        UnsafeNativeVault vault = new UnsafeNativeVault();
        vm.deal(address(this), 11 ether);
        vault.deposit{value: 10 ether}(); // an innocent depositor

        ReentrantAttacker attacker = new ReentrantAttacker(IWithdrawable(address(vault)));
        attacker.attack{value: 1 ether}();

        assertGt(address(attacker).balance, 1 ether, "attacker extracted other depositors' funds");
    }

    function test_checks_effects_interactions_makes_the_same_attack_fail() public {
        SafeNativeVault vault = new SafeNativeVault();
        vm.deal(address(this), 11 ether);
        vault.deposit{value: 10 ether}();

        ReentrantAttacker attacker = new ReentrantAttacker(IWithdrawable(address(vault)));
        attacker.attack{value: 1 ether}();

        assertEq(address(attacker).balance, 1 ether, "attacker only gets its own deposit back");
        assertEq(address(vault).balance, 10 ether);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Conservation
    // ------------------------------------------------------------------------------------------------------------

    function testFuzz_native_transfer_conserves_value(uint96 funded, uint96 amount) public {
        vm.deal(address(h), funded);
        uint256 recipientBefore = alice.balance;
        if (amount > funded) {
            vm.expectRevert(CurrencyLib.NativeTransferFailed.selector);
            h.send(NATIVE, alice, amount);
            return;
        }
        h.send(NATIVE, alice, amount);
        assertEq(address(h).balance + alice.balance, uint256(funded) + recipientBefore);
        assertEq(alice.balance - recipientBefore, amount);
    }

    function testFuzz_erc20_transfer_conserves_value(uint128 funded, uint128 amount) public {
        MintableToken token = new MintableToken();
        token.mint(address(h), funded);
        if (amount > funded) {
            vm.expectRevert();
            h.send(Currency.wrap(address(token)), alice, amount);
            return;
        }
        h.send(Currency.wrap(address(token)), alice, amount);
        assertEq(token.balanceOf(address(h)) + token.balanceOf(alice), funded);
        assertEq(h.balance(Currency.wrap(address(token))), uint256(funded) - amount);
    }
}
