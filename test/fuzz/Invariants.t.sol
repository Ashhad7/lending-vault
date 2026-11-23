// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test, console} from "forge-std/Test.sol";
import {LendingVault} from "../../src/LendingVault.sol";
import {BorrowToken} from "../../src/BorrowToken.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {Handler} from "./Handler.t.sol";

/**
 * @title Invariants
 * @notice Campaign one: the price never falls below its starting value.
 * @dev This isolates the question of whether user actions alone can ever make
 *      the protocol insolvent. They must not. Price-driven insolvency is
 *      covered separately in InvariantsVolatile.
 */
contract Invariants is StdInvariant, Test {
    LendingVault private vault;
    BorrowToken private borrowToken;
    MockWETH private weth;
    MockV3Aggregator private feed;
    Handler private handler;

    function setUp() public {
        vm.warp(1_700_000_000);

        weth = new MockWETH();
        feed = new MockV3Aggregator(8, 3000e8);
        borrowToken = new BorrowToken(address(this));
        vault = new LendingVault(address(weth), address(feed), address(borrowToken));
        borrowToken.transferOwnership(address(vault));

        handler = new Handler(address(vault), address(weth), address(borrowToken), address(feed), false);
        targetContract(address(handler));
    }

    /// @notice With prices never falling, collateral must always cover twice the debt.
    function invariant_UserActionsCannotCauseInsolvency() public view {
        uint256 totalDebt = borrowToken.totalSupply();
        if (totalDebt == 0) return;

        uint256 collateralValue = vault.getUsdValue(weth.balanceOf(address(vault)));
        assertGe(collateralValue, totalDebt * 2);
    }

    /// @notice With prices never falling, no position can ever become liquidatable.
    function invariant_NoPositionBecomesUnhealthy() public view {
        assertFalse(handler.anyActorIsUnhealthy());
    }

    /// @notice Every bUSD in circulation must be backed by recorded debt.
    function invariant_TotalSupplyMatchesSumOfDebts() public view {
        address[] memory actors = handler.getActors();
        uint256 summedDebt;
        for (uint256 i = 0; i < actors.length; i++) {
            summedDebt += vault.getDebt(actors[i]);
        }
        assertEq(summedDebt, borrowToken.totalSupply());
    }

    /// @notice The vault's WETH balance must equal the sum of what it recorded.
    function invariant_CollateralBalanceMatchesSumOfDeposits() public view {
        address[] memory actors = handler.getActors();
        uint256 summedCollateral;
        for (uint256 i = 0; i < actors.length; i++) {
            summedCollateral += vault.getCollateralBalance(actors[i]);
        }
        assertEq(summedCollateral, weth.balanceOf(address(vault)));
    }

    /// @notice The vault must never hold bUSD, since it burns everything it receives.
    function invariant_VaultHoldsNoBorrowToken() public view {
        assertEq(borrowToken.balanceOf(address(vault)), 0);
    }

    function invariant_CallSummary() public view {
        console.log("deposits:   ", handler.depositCalls());
        console.log("borrows:    ", handler.borrowCalls());
        console.log("repays:     ", handler.repayCalls());
        console.log("withdraws:  ", handler.withdrawCalls());
        console.log("liquidates: ", handler.liquidateCalls());
        console.log("price moves:", handler.priceUpdateCalls());
    }
}
