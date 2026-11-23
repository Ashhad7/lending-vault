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
 * @title InvariantsVolatile
 * @notice Campaign two: the price moves freely between $500 and $5000.
 * @dev Over-collateralisation is deliberately NOT asserted here. No lending
 *      protocol can guarantee it through a price crash; that is what
 *      liquidation exists to correct. What must hold is that insolvency only
 *      ever traces back to a position the protocol has already flagged as
 *      liquidatable, and that the accounting stays exact throughout.
 */
contract InvariantsVolatile is StdInvariant, Test {
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

        handler = new Handler(address(vault), address(weth), address(borrowToken), address(feed), true);
        targetContract(address(handler));
    }

    /// @notice Insolvency can only exist when at least one position is liquidatable.
    function invariant_InsolvencyImpliesALiquidatablePosition() public view {
        uint256 totalDebt = borrowToken.totalSupply();
        if (totalDebt == 0) return;

        uint256 collateralValue = vault.getUsdValue(weth.balanceOf(address(vault)));
        if (collateralValue < totalDebt * 2) {
            assertTrue(handler.anyActorIsUnhealthy());
        }
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

    /// @notice View functions must never revert on a fresh price.
    function invariant_GettersDoNotRevert() public view {
        address[] memory actors = handler.getActors();
        for (uint256 i = 0; i < actors.length; i++) {
            vault.getHealthFactor(actors[i]);
            vault.getMaxBorrowable(actors[i]);
            vault.getAccountInfo(actors[i]);
        }
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
