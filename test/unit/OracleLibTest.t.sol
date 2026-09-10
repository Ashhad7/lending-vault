// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "@chainlink/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

/// @dev Wraps the library so its reverts happen inside a real external call.
contract OracleLibHarness {
    using OracleLib for AggregatorV3Interface;

    function read(address feed) external view returns (uint256) {
        return AggregatorV3Interface(feed).staleCheckLatestRoundData();
    }
}

contract OracleLibTest is Test {
    MockV3Aggregator private feed;
    OracleLibHarness private harness;

    uint8 private constant FEED_DECIMALS = 8;
    int256 private constant STARTING_PRICE = 3000e8;
    uint256 private constant TIMEOUT = 3 hours;
    uint256 private constant START_TIME = 1_700_000_000;

    function setUp() public {
        vm.warp(START_TIME);
        feed = new MockV3Aggregator(FEED_DECIMALS, STARTING_PRICE);
        harness = new OracleLibHarness();
    }

    function test_ReturnsPriceScaledTo18Decimals() public view {
        assertEq(harness.read(address(feed)), 3000e18);
    }

    function test_RevertsWhenPriceIsZero() public {
        feed.updateAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(OracleLib.OracleLib__InvalidPrice.selector, int256(0)));
        harness.read(address(feed));
    }

    function test_RevertsWhenPriceIsNegative() public {
        feed.updateAnswer(-1);
        vm.expectRevert(abi.encodeWithSelector(OracleLib.OracleLib__InvalidPrice.selector, int256(-1)));
        harness.read(address(feed));
    }

    function test_RevertsWhenPriceIsStale() public {
        vm.warp(START_TIME + TIMEOUT + 1);
        vm.expectRevert(
            abi.encodeWithSelector(OracleLib.OracleLib__StalePrice.selector, START_TIME, TIMEOUT)
        );
        harness.read(address(feed));
    }

    function test_DoesNotRevertExactlyAtTimeout() public {
        vm.warp(START_TIME + TIMEOUT);
        assertEq(harness.read(address(feed)), 3000e18);
    }

    function test_RevertsWhenRoundIdIsZero() public {
        feed.updateRoundData(0, STARTING_PRICE, block.timestamp, block.timestamp);
        vm.expectRevert(OracleLib.OracleLib__IncompleteRound.selector);
        harness.read(address(feed));
    }

    function test_RevertsWhenTimestampIsInTheFuture() public {
        feed.updateRoundData(1, STARTING_PRICE, block.timestamp + 1, block.timestamp);
        vm.expectRevert(OracleLib.OracleLib__IncompleteRound.selector);
        harness.read(address(feed));
    }

    function test_HandlesFeedWithEighteenDecimals() public {
        MockV3Aggregator wideFeed = new MockV3Aggregator(18, 3000e18);
        assertEq(harness.read(address(wideFeed)), 3000e18);
    }

    function testFuzz_AnyFreshPositivePriceScalesCorrectly(uint256 rawPrice) public {
        rawPrice = bound(rawPrice, 1, 1e18);
        // casting to 'int256' is safe because rawPrice is bounded to 1e18
        // forge-lint: disable-next-line(unsafe-typecast)
        feed.updateAnswer(int256(rawPrice));
        assertEq(harness.read(address(feed)), rawPrice * 1e10);
    }

    function testFuzz_AnyPriceOlderThanTimeoutReverts(uint256 secondsPassed) public {
        secondsPassed = bound(secondsPassed, TIMEOUT + 1, 365 days);
        vm.warp(START_TIME + secondsPassed);
        vm.expectRevert(
            abi.encodeWithSelector(OracleLib.OracleLib__StalePrice.selector, START_TIME, TIMEOUT)
        );
        harness.read(address(feed));
    }
}