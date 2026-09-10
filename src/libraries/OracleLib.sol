// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AggregatorV3Interface} from "@chainlink/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @notice Reads a Chainlink price feed and refuses to return an answer it does not trust.
 * @dev Every price returned is scaled to 18 decimals so the rest of the protocol
 *      never has to think about a feed's native decimals.
 */
library OracleLib {
    error OracleLib__StalePrice(uint256 updatedAt, uint256 timeout);
    error OracleLib__InvalidPrice(int256 price);
    error OracleLib__IncompleteRound();

    uint256 private constant TIMEOUT = 3 hours;
    uint256 private constant TARGET_DECIMALS = 18;

    /**
     * @notice Returns the latest price from a feed, scaled to 18 decimals.
     * @dev Reverts instead of returning a price that is zero, negative, from an
     *      unfinished round, or older than TIMEOUT.
     */
    function staleCheckLatestRoundData(AggregatorV3Interface feed) internal view returns (uint256 priceScaledTo18) {
        (uint80 roundId, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();

        if (roundId == 0 || updatedAt == 0) {
            revert OracleLib__IncompleteRound();
        }

        // forge-lint: disable-next-line(block-timestamp)
        if (updatedAt > block.timestamp) {
            revert OracleLib__IncompleteRound();
        }

        if (answer <= 0) {
            revert OracleLib__InvalidPrice(answer);
        }

        uint256 secondsSinceUpdate = block.timestamp - updatedAt;
        if (secondsSinceUpdate > TIMEOUT) {
            revert OracleLib__StalePrice(updatedAt, TIMEOUT);
        }

        // casting to 'uint256' is safe because answer is checked to be > 0 above
        // forge-lint: disable-next-line(unsafe-typecast)
        priceScaledTo18 = _scaleTo18(uint256(answer), feed.decimals());
    }

    function _scaleTo18(uint256 value, uint8 fromDecimals) private pure returns (uint256) {
        if (fromDecimals == TARGET_DECIMALS) {
            return value;
        }
        if (fromDecimals < TARGET_DECIMALS) {
            return value * (10 ** (TARGET_DECIMALS - fromDecimals));
        }
        return value / (10 ** (fromDecimals - TARGET_DECIMALS));
    }

    function getTimeout() internal pure returns (uint256) {
        return TIMEOUT;
    }
}
