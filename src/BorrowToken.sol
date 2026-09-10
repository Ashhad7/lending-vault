// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title BorrowToken
 * @notice The USD-denominated token users borrow against their collateral.
 * @dev Has no logic of its own. All minting and burning is controlled by the
 *      LendingVault, which is set as the owner at deployment.
 */
contract BorrowToken is ERC20Burnable, Ownable {
    error BorrowToken__AmountMustBeMoreThanZero();
    error BorrowToken__BurnAmountExceedsBalance(uint256 balance, uint256 amount);
    error BorrowToken__CannotMintToZeroAddress();

    constructor(address initialOwner) ERC20("Borrow USD", "bUSD") Ownable(initialOwner) {}

    /// @notice Creates new tokens. Only the vault may call this.
    function mint(address to, uint256 amount) external onlyOwner returns (bool) {
        if (to == address(0)) {
            revert BorrowToken__CannotMintToZeroAddress();
        }
        if (amount == 0) {
            revert BorrowToken__AmountMustBeMoreThanZero();
        }
        _mint(to, amount);
        return true;
    }

    /// @notice Destroys tokens held by the vault. Only the vault may call this.
    function burn(uint256 amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (amount == 0) {
            revert BorrowToken__AmountMustBeMoreThanZero();
        }
        if (amount > balance) {
            revert BorrowToken__BurnAmountExceedsBalance(balance, amount);
        }
        super.burn(amount);
    }
}
