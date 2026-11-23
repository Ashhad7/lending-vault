// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployVault} from "../../script/DeployVault.s.sol";

contract DeployVaultTest is Test {
    DeployVault private deployer;
    DeployVault.Deployment private deployment;

    address private sender = makeAddr("deployer");

    function setUp() public {
        deployer = new DeployVault();
        deployment = deployer.deploy(sender);
    }

    function test_AllContractsDeployed() public view {
        assertTrue(address(deployment.vault) != address(0));
        assertTrue(address(deployment.borrowToken) != address(0));
        assertTrue(deployment.weth != address(0));
        assertTrue(deployment.priceFeed != address(0));
    }

    function test_VaultOwnsBorrowTokenAfterDeployment() public view {
        assertEq(deployment.borrowToken.owner(), address(deployment.vault));
    }

    function test_DeployerCannotMintAfterDeployment() public {
        vm.prank(sender);
        vm.expectRevert();
        deployment.borrowToken.mint(sender, 1e18);
    }

    function test_VaultWiredToCorrectAddresses() public view {
        assertEq(deployment.vault.getCollateralToken(), deployment.weth);
        assertEq(deployment.vault.getBorrowToken(), address(deployment.borrowToken));
        assertEq(deployment.vault.getPriceFeed(), deployment.priceFeed);
    }

    function test_PriceFeedReturnsUsableValue() public view {
        assertEq(deployment.vault.getUsdValue(1e18), 3000e18);
    }
}
