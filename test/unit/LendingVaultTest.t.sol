// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LendingVault} from "../../src/LendingVault.sol";
import {BorrowToken} from "../../src/BorrowToken.sol";
import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract LendingVaultTest is Test {
    LendingVault private vault;
    BorrowToken private borrowToken;
    MockWETH private weth;
    MockV3Aggregator private feed;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    uint8 private constant FEED_DECIMALS = 8;
    int256 private constant ETH_PRICE = 3000e8;
    uint256 private constant START_TIME = 1_700_000_000;
    uint256 private constant ONE_ETH = 1e18;
    uint256 private constant SAFE_DEBT = 1000e18;

    function setUp() public {
        vm.warp(START_TIME);

        weth = new MockWETH();
        feed = new MockV3Aggregator(FEED_DECIMALS, ETH_PRICE);
        borrowToken = new BorrowToken(address(this));
        vault = new LendingVault(address(weth), address(feed), address(borrowToken));
        borrowToken.transferOwnership(address(vault));

        weth.mint(alice, 100e18);
        weth.mint(bob, 100e18);

        vm.prank(alice);
        weth.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        weth.approve(address(vault), type(uint256).max);
    }

    modifier withDeposit(address user, uint256 amount) {
        vm.prank(user);
        vault.depositCollateral(amount);
        _;
    }

    modifier withPosition(address user, uint256 collateral, uint256 debt) {
        vm.startPrank(user);
        vault.depositAndBorrow(collateral, debt);
        IERC20(address(borrowToken)).approve(address(vault), type(uint256).max);
        vm.stopPrank();
        _;
    }

    //Constructor

    function test_ConstructorSetsAddresses() public view {
        assertEq(vault.getCollateralToken(), address(weth));
        assertEq(vault.getBorrowToken(), address(borrowToken));
        assertEq(vault.getPriceFeed(), address(feed));
    }

    function test_ConstructorRevertsOnZeroAddress() public {
        vm.expectRevert(LendingVault.LendingVault__ZeroAddress.selector);
        new LendingVault(address(0), address(feed), address(borrowToken));
    }

    function test_VaultOwnsBorrowToken() public view {
        assertEq(borrowToken.owner(), address(vault));
    }

    //Price and conversion tests

    function test_GetUsdValue() public view {
        assertEq(vault.getUsdValue(2e18), 6000e18);
    }

    function test_GetTokenAmountFromUsd() public view {
        assertEq(vault.getTokenAmountFromUsd(6000e18), 2e18);
    }

    //Deposit tests

    function test_DepositMovesTokensAndRecordsBalance() public withDeposit(alice, ONE_ETH) {
        assertEq(vault.getCollateralBalance(alice), ONE_ETH);
        assertEq(weth.balanceOf(address(vault)), ONE_ETH);
        assertEq(weth.balanceOf(alice), 99e18);
    }

    function test_DepositRevertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert(LendingVault.LendingVault__AmountMustBeMoreThanZero.selector);
        vault.depositCollateral(0);
    }

    function test_DepositRevertsWithoutApproval() public {
        address carol = makeAddr("carol");
        weth.mint(carol, 1e18);

        vm.prank(carol);
        vm.expectRevert();
        vault.depositCollateral(1e18);
    }

    function test_HealthFactorIsMaxWithNoDebt() public withDeposit(alice, ONE_ETH) {
        assertEq(vault.getHealthFactor(alice), type(uint256).max);
    }

    //Borrow tests

    function test_BorrowMintsTokensAndRecordsDebt() public withPosition(alice, ONE_ETH, SAFE_DEBT) {
        assertEq(borrowToken.balanceOf(alice), SAFE_DEBT);
        assertEq(vault.getDebt(alice), SAFE_DEBT);
        assertEq(borrowToken.totalSupply(), SAFE_DEBT);
    }

    function test_HealthFactorIsOnePointFive() public withPosition(alice, ONE_ETH, SAFE_DEBT) {
        assertEq(vault.getHealthFactor(alice), 1.5e18);
    }

    function test_CanBorrowExactlyToTheLimit() public withDeposit(alice, ONE_ETH) {
        vm.prank(alice);
        vault.borrow(1500e18);
        assertEq(vault.getHealthFactor(alice), 1e18);
    }

    function test_CannotBorrowOneWeiPastTheLimit() public withDeposit(alice, ONE_ETH) {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LendingVault.LendingVault__HealthFactorBelowMinimum.selector, 999999999999999999)
        );
        vault.borrow(1500e18 + 1);
    }

    function test_CannotBorrowWithNoCollateral() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LendingVault.LendingVault__HealthFactorBelowMinimum.selector, 0));
        vault.borrow(1e18);
    }

    function test_GetMaxBorrowable() public withDeposit(alice, ONE_ETH) {
        assertEq(vault.getMaxBorrowable(alice), 1500e18);

        vm.prank(alice);
        vault.borrow(1000e18);
        assertEq(vault.getMaxBorrowable(alice), 500e18);
    }

    function test_BorrowRevertsOnStalePrice() public withDeposit(alice, ONE_ETH) {
        vm.warp(START_TIME + 3 hours + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OracleLib.OracleLib__StalePrice.selector, START_TIME, 3 hours));
        vault.borrow(100e18);
    }

    //Repay testss

    function test_RepayBurnsTokensAndReducesDebt() public withPosition(alice, ONE_ETH, SAFE_DEBT) {
        vm.prank(alice);
        vault.repay(400e18);

        assertEq(vault.getDebt(alice), 600e18);
        assertEq(borrowToken.balanceOf(alice), 600e18);
        assertEq(borrowToken.totalSupply(), 600e18);
    }

    function test_CannotRepayMoreThanOwed() public withPosition(alice, ONE_ETH, SAFE_DEBT) {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LendingVault.LendingVault__InsufficientDebt.selector, SAFE_DEBT, SAFE_DEBT + 1)
        );
        vault.repay(SAFE_DEBT + 1);
    }

    //Withdraw tests

    function test_WithdrawWithNoDebtReturnsEverything() public withDeposit(alice, ONE_ETH) {
        vm.prank(alice);
        vault.withdrawCollateral(ONE_ETH);

        assertEq(vault.getCollateralBalance(alice), 0);
        assertEq(weth.balanceOf(alice), 100e18);
    }

    function test_CannotWithdrawMoreThanDeposited() public withDeposit(alice, ONE_ETH) {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LendingVault.LendingVault__InsufficientCollateral.selector, ONE_ETH, ONE_ETH + 1)
        );
        vault.withdrawCollateral(ONE_ETH + 1);
    }

    function test_CannotWithdrawIfItBreaksHealthFactor() public withPosition(alice, ONE_ETH, SAFE_DEBT) {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LendingVault.LendingVault__HealthFactorBelowMinimum.selector, 0.75e18));
        vault.withdrawCollateral(0.5e18);
    }

    function test_RepayAndWithdrawInOneTransaction() public withPosition(alice, ONE_ETH, SAFE_DEBT) {
        vm.prank(alice);
        vault.repayAndWithdraw(SAFE_DEBT, ONE_ETH);

        assertEq(vault.getDebt(alice), 0);
        assertEq(vault.getCollateralBalance(alice), 0);
        assertEq(weth.balanceOf(alice), 100e18);
        assertEq(borrowToken.totalSupply(), 0);
    }

    /*Liquidation tests*/

    function test_CannotLiquidateHealthyPosition() public withPosition(alice, ONE_ETH, SAFE_DEBT) {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LendingVault.LendingVault__PositionIsHealthy.selector, 1.5e18));
        vault.liquidate(alice, 100e18);
    }

    function test_LiquidationTransfersCollateralWithBonus()
        public
        withPosition(alice, ONE_ETH, SAFE_DEBT)
        withPosition(bob, 10e18, 5000e18)
    {
        feed.updateAnswer(1900e8);
        assertEq(vault.getHealthFactor(alice), 0.95e18);

        uint256 expectedSeize = vault.getCollateralToSeize(alice, 500e18);
        uint256 bobWethBefore = weth.balanceOf(bob);

        vm.prank(bob);
        vault.liquidate(alice, 500e18);

        assertEq(weth.balanceOf(bob), bobWethBefore + expectedSeize);
        assertEq(vault.getDebt(alice), 500e18);
        assertEq(borrowToken.balanceOf(bob), 4500e18);
        assertGt(vault.getHealthFactor(alice), 1e18);
    }

    function test_LiquidationBonusIsTenPercent()
        public
        withPosition(alice, ONE_ETH, SAFE_DEBT)
        withPosition(bob, 10e18, 5000e18)
    {
        feed.updateAnswer(1900e8);

        uint256 seized = vault.getCollateralToSeize(alice, 500e18);
        uint256 baseAmount = vault.getTokenAmountFromUsd(500e18);

        assertEq(seized, baseAmount + (baseAmount * 10) / 100);
        assertGt(vault.getUsdValue(seized), 500e18);
    }

    function test_SeizureIsCappedAtAvailableCollateral() public withPosition(alice, ONE_ETH, SAFE_DEBT) {
        feed.updateAnswer(900e8);
        assertEq(vault.getCollateralToSeize(alice, SAFE_DEBT), ONE_ETH);
    }

    function test_LiquidatorPositionMustStayHealthy()
        public
        withPosition(alice, ONE_ETH, SAFE_DEBT)
        withPosition(bob, 1e18, 1500e18)
    {
        feed.updateAnswer(1900e8);

        vm.prank(bob);
        vm.expectRevert();
        vault.liquidate(alice, 500e18);
    }

    /*Fuzz Tests*/

    function testFuzz_DepositThenWithdrawAlwaysReturnsFunds(uint256 amount) public {
        amount = bound(amount, 1, 100e18);

        vm.startPrank(alice);
        vault.depositCollateral(amount);
        vault.withdrawCollateral(amount);
        vm.stopPrank();

        assertEq(weth.balanceOf(alice), 100e18);
        assertEq(vault.getCollateralBalance(alice), 0);
    }

    function testFuzz_CanNeverBorrowAboveHalfCollateralValue(uint256 collateral, uint256 debt) public {
        collateral = bound(collateral, 1e15, 100e18);
        debt = bound(debt, 1, 1_000_000e18);

        uint256 ceiling = vault.getUsdValue(collateral) / 2;

        vm.startPrank(alice);
        vault.depositCollateral(collateral);

        if (debt > ceiling) {
            vm.expectRevert();
            vault.borrow(debt);
        } else {
            vault.borrow(debt);
            assertGe(vault.getHealthFactor(alice), 1e18);
        }
        vm.stopPrank();
    }

    function testFuzz_HealthFactorFallsAsPriceFalls(uint256 newPrice) public {
        newPrice = bound(newPrice, 1e8, 3000e8);

        vm.startPrank(alice);
        vault.depositAndBorrow(ONE_ETH, SAFE_DEBT);
        vm.stopPrank();

        uint256 before = vault.getHealthFactor(alice);
        // casting to 'int256' is safe because newPrice is bounded to 3000e8
        // forge-lint: disable-next-line(unsafe-typecast)
        feed.updateAnswer(int256(newPrice));

        assertLe(vault.getHealthFactor(alice), before);
    }
}
