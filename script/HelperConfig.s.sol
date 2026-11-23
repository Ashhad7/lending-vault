// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";

/**
 * @title HelperConfig
 * @notice Supplies the right external addresses for whichever chain the script
 *         is running against.
 * @dev address(0) means "no live contract here, deploy a mock instead". The
 *      deploy script handles that, because a contract created outside a
 *      broadcast would not be a real deployment.
 */
contract HelperConfig is Script {
    error HelperConfig__UnsupportedChain(uint256 chainId);

    struct NetworkConfig {
        address priceFeed;
        address weth;
        string name;
    }

    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant ANVIL_CHAIN_ID = 31337;

    address public constant SEPOLIA_ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    uint8 public constant MOCK_FEED_DECIMALS = 8;
    int256 public constant MOCK_INITIAL_PRICE = 3000e8;

    function getConfig() public view returns (NetworkConfig memory) {
        if (block.chainid == SEPOLIA_CHAIN_ID) {
            return getSepoliaConfig();
        }
        if (block.chainid == ANVIL_CHAIN_ID) {
            return getAnvilConfig();
        }
        revert HelperConfig__UnsupportedChain(block.chainid);
    }

    /// @dev Real Chainlink feed. Collateral is a mintable mock so anyone can
    ///      try the deployment without hunting for testnet WETH.
    function getSepoliaConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({priceFeed: SEPOLIA_ETH_USD_FEED, weth: address(0), name: "sepolia"});
    }

    function getAnvilConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({priceFeed: address(0), weth: address(0), name: "anvil"});
    }
}
