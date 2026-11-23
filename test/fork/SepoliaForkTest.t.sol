// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/shared/interfaces/AggregatorV3Interface.sol";
import {LendingVault} from "../../src/LendingVault.sol";
import {BorrowToken} from "../../src/BorrowToken.sol";
import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

/**
 * @title SepoliaForkTest
 * @notice Runs the protocol against the real Chainlink ETH/USD aggregator on
 *         Sepolia rather than a mock we control.
 * @dev Collateral is still a local MockWETH. The point of forking is to prove
 *      the oracle layer works against the genuine feed contract, including its
 *      real decimals, heartbeat and round structure.
 */
contract SepoliaForkTest is Test {
    address private constant SEPOLIA_ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    LendingVault private vault;
    BorrowToken private borrowToken;
    MockWETH private weth;
    AggregatorV3Interface private feed;

    address private alice = makeAddr("alice");

    bool private forkAvailable;

    modifier onlyOnFork() {
        if (!forkAvailable) return;
        _;
    }

    function setUp() public {
        string memory rpcUrl = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            return;
        }

        try vm.createSelectFork(rpcUrl) {
            forkAvailable = true;
        } catch {
            return;
        }

        require(block.chainid == 11155111, "not forking Sepolia");

        feed = AggregatorV3Interface(SEPOLIA_ETH_USD_FEED);
        weth = new MockWETH();
        borrowToken = new BorrowToken(address(this));
        vault = new LendingVault(address(weth), SEPOLIA_ETH_USD_FEED, address(borrowToken));
        borrowToken.transferOwnership(address(vault));

        weth.mint(alice, 100e18);
        vm.startPrank(alice);
        weth.approve(address(vault), type(uint256).max);
        IERC20(address(borrowToken)).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            THE REAL FEED
    //////////////////////////////////////////////////////////////*/

    function test_RealFeedHasEightDecimals() public view onlyOnFork {
        assertEq(feed.decimals(), 8);
    }

    function test_RealFeedReturnsAPlausiblePrice() public view onlyOnFork {
        uint256 price = vault.getUsdValue(1e18);

        assertGt(price, 100e18);
        assertLt(price, 100_000e18);
    }

    function test_RealFeedDataIsFresh() public view onlyOnFork {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();

        assertGt(answer, 0);
        assertLe(block.timestamp - updatedAt, 3 hours);
    }

    function test_OracleLibRejectsTheRealFeedOnceItGoesStale() public onlyOnFork {
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        vm.warp(updatedAt + 3 hours + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OracleLib.OracleLib__StalePrice.selector, updatedAt, 3 hours));
        vault.depositAndBorrow(1e18, 1);
    }

    /*//////////////////////////////////////////////////////////////
                        FULL LIFECYCLE ON FORK
    //////////////////////////////////////////////////////////////*/

    function test_FullLifecycleAgainstRealPrice() public onlyOnFork {
        uint256 collateral = 1e18;
        uint256 ceiling = vault.getUsdValue(collateral) / 2;
        uint256 debt = ceiling / 2;

        vm.startPrank(alice);
        vault.depositAndBorrow(collateral, debt);

        assertEq(vault.getDebt(alice), debt);
        assertEq(borrowToken.balanceOf(alice), debt);
        assertApproxEqRel(vault.getHealthFactor(alice), 2e18, 0.01e18);

        vault.repayAndWithdraw(debt, collateral);
        vm.stopPrank();

        assertEq(vault.getDebt(alice), 0);
        assertEq(vault.getCollateralBalance(alice), 0);
        assertEq(weth.balanceOf(alice), 100e18);
        assertEq(borrowToken.totalSupply(), 0);
    }

    function test_BorrowingPastTheLimitRevertsAtRealPrice() public onlyOnFork {
        uint256 collateral = 1e18;
        uint256 ceiling = vault.getUsdValue(collateral) / 2;

        vm.startPrank(alice);
        vault.depositCollateral(collateral);

        vm.expectRevert();
        vault.borrow(ceiling + 1e18);
        vm.stopPrank();
    }

    function test_LiquidationWorksWhenTheRealPriceIsMockedDown() public onlyOnFork {
        uint256 collateral = 1e18;
        uint256 debt = vault.getUsdValue(collateral) / 2;

        vm.startPrank(alice);
        vault.depositAndBorrow(collateral, debt);
        vm.stopPrank();

        assertApproxEqRel(vault.getHealthFactor(alice), 1e18, 0.01e18);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredIn) =
            feed.latestRoundData();

        vm.mockCall(
            SEPOLIA_ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(roundId, (answer * 80) / 100, startedAt, updatedAt, answeredIn)
        );

        uint256 healthAfterCrash = vault.getHealthFactor(alice);
        assertLt(healthAfterCrash, 1e18);

        address bob = makeAddr("bob");
        weth.mint(bob, 100e18);
        vm.startPrank(bob);
        weth.approve(address(vault), type(uint256).max);
        IERC20(address(borrowToken)).approve(address(vault), type(uint256).max);
        vault.depositAndBorrow(50e18, debt);

        uint256 wethBefore = weth.balanceOf(bob);
        uint256 seized = vault.getCollateralToSeize(alice, debt / 2);
        vault.liquidate(alice, debt / 2);
        vm.stopPrank();

        assertEq(weth.balanceOf(bob), wethBefore + seized);
        assertGt(vault.getHealthFactor(alice), healthAfterCrash);
        assertGt(vault.getHealthFactor(alice), 1e18);

        vm.clearMockedCalls();
    }
}
