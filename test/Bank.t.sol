// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Bank} from "../src/Bank.sol";

contract BankTest is Test {
    Bank public bank;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public dave = makeAddr("dave");

    receive() external payable {}

    function setUp() public {
        bank = new Bank();
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
        vm.deal(dave, 10 ether);
    }

    function test_DirectDepositRecordsBalance() public {
        vm.prank(alice);
        (bool success, ) = payable(address(bank)).call{value: 2 ether}("");
        require(success, "direct deposit failed");

        assertEq(bank.balances(alice), 2 ether);
        assertEq(bank.topDepositors(0), alice);
        assertEq(bank.getTopDepositors().length, 1);
    }

    function test_ExplicitDepositRecordsBalance() public {
        vm.prank(bob);
        bank.deposit{value: 3 ether}();

        assertEq(bank.balances(bob), 3 ether);
        assertEq(bank.topDepositors(0), bob);
    }

    function test_TopThreeDepositorsAreSorted() public {
        _deposit(alice, 1 ether);
        _deposit(bob, 3 ether);
        _deposit(carol, 2 ether);
        _deposit(dave, 2.5 ether);

        assertEq(bank.getTopDepositors().length, 3);
        assertEq(bank.topDepositors(0), bob);
        assertEq(bank.topDepositors(1), dave);
        assertEq(bank.topDepositors(2), carol);

        _deposit(alice, 4 ether);

        assertEq(bank.getTopDepositors().length, 3);
        assertEq(bank.topDepositors(0), alice);
        assertEq(bank.topDepositors(1), bob);
        assertEq(bank.topDepositors(2), dave);
    }

    function test_OnlyOwnerCanWithdraw() public {
        _deposit(alice, 5 ether);

        vm.prank(alice);
        vm.expectRevert("Bank: caller is not the owner");
        bank.withdraw();

        uint256 ownerStart = address(this).balance;
        bank.withdraw(2 ether);

        assertEq(address(bank).balance, 3 ether);
        assertEq(address(this).balance, ownerStart + 2 ether);
    }

    function test_WithdrawAllSendsFullBalanceToOwner() public {
        _deposit(alice, 4 ether);

        uint256 ownerStart = address(this).balance;
        bank.withdraw();

        assertEq(address(bank).balance, 0);
        assertEq(address(this).balance, ownerStart + 4 ether);
    }

    function _deposit(address user, uint256 amount) private {
        vm.prank(user);
        (bool success, ) = payable(address(bank)).call{value: amount}("");
        require(success, "deposit failed");
    }
}
