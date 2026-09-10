// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BorrowToken} from "../../src/BorrowToken.sol";

contract BorrowTokenTest is Test {
    BorrowToken private token;

    address private owner = makeAddr("owner");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    function setUp() public {
        token = new BorrowToken(owner);
    }

    function test_HasCorrectNameAndSymbol() public view {
        assertEq(token.name(), "Borrow USD");
        assertEq(token.symbol(), "bUSD");
        assertEq(token.decimals(), 18);
    }

    function test_StartsWithZeroSupply() public view {
        assertEq(token.totalSupply(), 0);
    }

    function test_OwnerCanMint() public {
        vm.prank(owner);
        token.mint(alice, 100e18);

        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.totalSupply(), 100e18);
    }

    function test_NonOwnerCannotMint() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        token.mint(alice, 100e18);
    }

    function test_CannotMintZero() public {
        vm.prank(owner);
        vm.expectRevert(BorrowToken.BorrowToken__AmountMustBeMoreThanZero.selector);
        token.mint(alice, 0);
    }

    function test_CannotMintToZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(BorrowToken.BorrowToken__CannotMintToZeroAddress.selector);
        token.mint(address(0), 100e18);
    }

    function test_OwnerCanBurnOwnTokens() public {
        vm.startPrank(owner);
        token.mint(owner, 100e18);
        token.burn(40e18);
        vm.stopPrank();

        assertEq(token.balanceOf(owner), 60e18);
        assertEq(token.totalSupply(), 60e18);
    }

    function test_NonOwnerCannotBurn() public {
        vm.prank(owner);
        token.mint(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        token.burn(50e18);
    }

    function test_CannotBurnMoreThanBalance() public {
        vm.startPrank(owner);
        token.mint(owner, 10e18);
        vm.expectRevert(
            abi.encodeWithSelector(BorrowToken.BorrowToken__BurnAmountExceedsBalance.selector, 10e18, 50e18)
        );
        token.burn(50e18);
        vm.stopPrank();
    }

    function test_CannotBurnZero() public {
        vm.prank(owner);
        vm.expectRevert(BorrowToken.BorrowToken__AmountMustBeMoreThanZero.selector);
        token.burn(0);
    }

    function test_TransfersWorkNormally() public {
        vm.prank(owner);
        token.mint(alice, 100e18);

        vm.prank(alice);
        token.transfer(bob, 30e18);

        assertEq(token.balanceOf(alice), 70e18);
        assertEq(token.balanceOf(bob), 30e18);
    }

    function test_OwnershipCanBeTransferred() public {
        address vault = makeAddr("vault");

        vm.prank(owner);
        token.transferOwnership(vault);
        assertEq(token.owner(), vault);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        token.mint(alice, 1e18);

        vm.prank(vault);
        token.mint(alice, 1e18);
        assertEq(token.balanceOf(alice), 1e18);
    }

    function testFuzz_MintIncreasesSupplyByExactAmount(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        vm.prank(owner);
        token.mint(alice, amount);

        assertEq(token.totalSupply(), amount);
        assertEq(token.balanceOf(alice), amount);
    }
}
