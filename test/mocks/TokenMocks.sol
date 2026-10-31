// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @dev Plain mintable ERC-20.
 */
contract MintableToken is ERC20 {
    constructor() ERC20("Mintable", "MNT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @dev Calls a target's permissionless fee entry point during `approve` to probe initialization reentrancy.
 */
contract InitializationReentrantToken is ERC20 {
    address public target;
    bool public attempted;
    bool public reentrySucceeded;

    constructor() ERC20("Initialization Reentrant", "IRE") {}

    function arm(address target_) external {
        target = target_;
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        if (target != address(0) && !attempted) {
            attempted = true;
            (reentrySucceeded,) = target.call(abi.encodeWithSignature("collectFees()"));
        }
        return super.approve(spender, value);
    }
}

/**
 * @dev Charges a 1% fee on every transfer: the recipient receives less than `amount`.
 */
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/**
 * @dev `transfer` returns false instead of reverting (the ERC-20 spec allows it; SafeERC20 must catch it).
 */
contract FalseReturningToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/**
 * @dev USDT-style token: `transfer` has no return value at all.
 */
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

/**
 * @dev Reverts on every transfer.
 */
contract RevertingToken {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure {
        revert("always reverts");
    }
}

/**
 * @dev Reverts when the amount is zero, like several real tokens.
 */
contract ZeroTransferRevertingToken is ERC20 {
    constructor() ERC20("NoZero", "NZ") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(value != 0, "zero transfer");
        super._update(from, to, value);
    }
}

/**
 * @dev Reverts when sending to a blacklisted recipient.
 */
contract BlacklistToken is ERC20 {
    mapping(address => bool) public blacklisted;

    constructor() ERC20("Blacklist", "BL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function blacklist(address account) external {
        blacklisted[account] = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blacklisted[to], "blacklisted");
        super._update(from, to, value);
    }
}

/**
 * @dev Native receiver that burns gas, proving native sends are not limited to the 2300 gas stipend.
 */
contract GasHungryReceiver {
    uint256 public sink;

    receive() external payable {
        for (uint256 i; i < 50; ++i) {
            sink += i + 1;
        }
    }
}

/**
 * @dev Native receiver that always reverts.
 */
contract RevertingReceiver {
    receive() external payable {
        revert("no ETH");
    }
}
