// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title MockV3Aggregator
 * @notice A fake Chainlink price feed  full control, for tests only.
 */
contract MockV3Aggregator {
    uint256 public constant version = 4;

    uint8 public decimals;
    uint256 public latestRound;

    mapping(uint256 => int256) public getAnswer;
    mapping(uint256 => uint256) public getTimestamp;
    mapping(uint256 => uint256) private getStartedAt;

    constructor(uint8 _decimals, int256 _initialAnswer) {
        decimals = _decimals;
        updateAnswer(_initialAnswer);
    }

    /// @notice Writes a new price using the current block timestamp.
    function updateAnswer(int256 _answer) public {
        latestRound++;
        getAnswer[latestRound] = _answer;
        getTimestamp[latestRound] = block.timestamp;
        getStartedAt[latestRound] = block.timestamp;
    }

    /// @notice Writes a round with full control over the round id and timestamps.
    function updateRoundData(uint80 _roundId, int256 _answer, uint256 _timestamp, uint256 _startedAt) public {
        latestRound = _roundId;
        getAnswer[_roundId] = _answer;
        getTimestamp[_roundId] = _timestamp;
        getStartedAt[_roundId] = _startedAt;
    }

    function getRoundData(uint80 _roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, getAnswer[_roundId], getStartedAt[_roundId], getTimestamp[_roundId], _roundId);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        // casting to 'uint80' is safe because this mock never exceeds a handful of rounds
        // forge-lint: disable-next-line(unsafe-typecast)
        uint80 round = uint80(latestRound);
        return (round, getAnswer[latestRound], getStartedAt[latestRound], getTimestamp[latestRound], round);
    }

    function description() external pure returns (string memory) {
        return "MockV3Aggregator";
    }
}
