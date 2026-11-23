// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LendingVault} from "../src/LendingVault.sol";
import {BorrowToken} from "../src/BorrowToken.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {MockWETH} from "../test/mocks/MockWETH.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";

/**
 * @title DeployVault
 * @notice Deploys the full protocol and hands minting control to the vault.
 * @dev The broadcast sender is passed in explicitly rather than inferred.
 *      Under a broadcast, both contract creations and outbound calls are made
 *      by that sender, so naming it keeps the token's owner and the caller of
 *      transferOwnership the same account. Inferring it from msg.sender or
 *      address(this) breaks when deploy() is called directly from a test.
 */
contract DeployVault is Script {
    struct Deployment {
        LendingVault vault;
        BorrowToken borrowToken;
        address weth;
        address priceFeed;
    }

    function run() external returns (Deployment memory) {
        return deploy(msg.sender);
    }

    function deploy(address deployer) public returns (Deployment memory) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();

        vm.startBroadcast(deployer);

        address weth = config.weth;
        if (weth == address(0)) {
            weth = address(new MockWETH());
        }

        address priceFeed = config.priceFeed;
        if (priceFeed == address(0)) {
            priceFeed =
                address(new MockV3Aggregator(helperConfig.MOCK_FEED_DECIMALS(), helperConfig.MOCK_INITIAL_PRICE()));
        }

        BorrowToken borrowToken = new BorrowToken(deployer);
        LendingVault vault = new LendingVault(weth, priceFeed, address(borrowToken));
        borrowToken.transferOwnership(address(vault));

        vm.stopBroadcast();

        console.log("network:      ", config.name);
        console.log("WETH:         ", weth);
        console.log("price feed:   ", priceFeed);
        console.log("BorrowToken:  ", address(borrowToken));
        console.log("LendingVault: ", address(vault));

        return Deployment({vault: vault, borrowToken: borrowToken, weth: weth, priceFeed: priceFeed});
    }
}
