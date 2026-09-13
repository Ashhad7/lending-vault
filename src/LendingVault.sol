// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
import {BorrowToken} from "./BorrowToken.sol";

/**
 * @title LendingVault
 * @notice An over-collateralised borrowing vault. Users deposit WETH and mint
 *         bUSD against it. Positions that fall below a health factor of 1 can be
 *         liquidated by anyone for a 10% bonus.
 * @dev All internal accounting is in 18 decimals. Rounding always favours the
 *      protocol. Collateral is a single asset in this version.
 */
contract LendingVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using OracleLib for AggregatorV3Interface;

    error LendingVault__AmountMustBeMoreThanZero();
    error LendingVault__ZeroAddress();
    error LendingVault__HealthFactorBelowMinimum(uint256 healthFactor);
    error LendingVault__InsufficientCollateral(uint256 balance, uint256 requested);
    error LendingVault__InsufficientDebt(uint256 debt, uint256 requested);
    error LendingVault__PositionIsHealthy(uint256 healthFactor);
    error LendingVault__HealthFactorNotImproved(uint256 startingHealthFactor, uint256 endingHealthFactor);

    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    IERC20 private immutable i_collateralToken;
    AggregatorV3Interface private immutable i_priceFeed;
    BorrowToken private immutable i_borrowToken;

    mapping(address user => uint256 amount) private s_collateralDeposited;
    mapping(address user => uint256 amount) private s_debtMinted;

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed from, address indexed to, uint256 amount);
    event DebtMinted(address indexed user, uint256 amount);
    event DebtBurned(address indexed onBehalfOf, address indexed payer, uint256 amount);
    event Liquidated(address indexed user, address indexed liquidator, uint256 debtCovered, uint256 collateralSeized);

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert LendingVault__AmountMustBeMoreThanZero();
        }
        _;
    }

    constructor(address collateralToken, address priceFeed, address borrowToken) {
        if (collateralToken == address(0) || priceFeed == address(0) || borrowToken == address(0)) {
            revert LendingVault__ZeroAddress();
        }
        i_collateralToken = IERC20(collateralToken);
        i_priceFeed = AggregatorV3Interface(priceFeed);
        i_borrowToken = BorrowToken(borrowToken);
    }

    /*//////////////////////////////////////////////////////////////
                             BORROWER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits collateral and mints debt in one transaction.
    function depositAndBorrow(uint256 collateralAmount, uint256 debtAmount) external {
        depositCollateral(collateralAmount);
        borrow(debtAmount);
    }

    /// @notice Deposits collateral. Caller must have approved this contract first.
    function depositCollateral(uint256 amount) public moreThanZero(amount) nonReentrant {
        s_collateralDeposited[msg.sender] += amount;
        emit CollateralDeposited(msg.sender, amount);
        i_collateralToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Mints bUSD against deposited collateral.
    function borrow(uint256 amount) public moreThanZero(amount) nonReentrant {
        s_debtMinted[msg.sender] += amount;
        emit DebtMinted(msg.sender, amount);
        _revertIfHealthFactorBroken(msg.sender);
        i_borrowToken.mint(msg.sender, amount);
    }

    /// @notice Burns bUSD to reduce the caller's own debt.
    function repay(uint256 amount) public moreThanZero(amount) nonReentrant {
        _burnDebt(amount, msg.sender, msg.sender);
        _revertIfHealthFactorBroken(msg.sender);
    }

    /// @notice Withdraws collateral, provided the position stays healthy.
    function withdrawCollateral(uint256 amount) public moreThanZero(amount) nonReentrant {
        _withdrawCollateral(amount, msg.sender, msg.sender);
        _revertIfHealthFactorBroken(msg.sender);
    }

    /// @notice Repays all debt and withdraws collateral in one transaction.
    function repayAndWithdraw(uint256 debtAmount, uint256 collateralAmount)
        external
        moreThanZero(debtAmount)
        moreThanZero(collateralAmount)
        nonReentrant
    {
        _burnDebt(debtAmount, msg.sender, msg.sender);
        _withdrawCollateral(collateralAmount, msg.sender, msg.sender);
        _revertIfHealthFactorBroken(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            LIQUIDATOR ACTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Repays part of an unhealthy user's debt and seizes their collateral
     *         plus a 10% bonus.
     * @dev The seizure is capped at the user's remaining collateral, so a position
     *      worth less than its debt can still be partially recovered. Call
     *      getCollateralToSeize first to check the trade is profitable.
     */
    function liquidate(address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant {
        uint256 startingHealthFactor = _healthFactor(user);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert LendingVault__PositionIsHealthy(startingHealthFactor);
        }

        uint256 collateralToSeize = _collateralToSeize(user, debtToCover);

        _withdrawCollateral(collateralToSeize, user, msg.sender);
        _burnDebt(debtToCover, user, msg.sender);

        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= startingHealthFactor) {
            revert LendingVault__HealthFactorNotImproved(startingHealthFactor, endingHealthFactor);
        }

        emit Liquidated(user, msg.sender, debtToCover, collateralToSeize);
        _revertIfHealthFactorBroken(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL PLUMBING
    //////////////////////////////////////////////////////////////*/

    function _withdrawCollateral(uint256 amount, address from, address to) private {
        uint256 balance = s_collateralDeposited[from];
        if (amount > balance) {
            revert LendingVault__InsufficientCollateral(balance, amount);
        }
        s_collateralDeposited[from] = balance - amount;
        emit CollateralWithdrawn(from, to, amount);
        i_collateralToken.safeTransfer(to, amount);
    }

    function _burnDebt(uint256 amount, address onBehalfOf, address payer) private {
        uint256 debt = s_debtMinted[onBehalfOf];
        if (amount > debt) {
            revert LendingVault__InsufficientDebt(debt, amount);
        }
        s_debtMinted[onBehalfOf] = debt - amount;
        emit DebtBurned(onBehalfOf, payer, amount);
        IERC20(address(i_borrowToken)).safeTransferFrom(payer, address(this), amount);
        i_borrowToken.burn(amount);
    }

    function _collateralToSeize(address user, uint256 debtToCover) private view returns (uint256) {
        uint256 baseCollateral = _getTokenAmountFromUsd(debtToCover);
        uint256 bonus = (baseCollateral * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 total = baseCollateral + bonus;

        uint256 available = s_collateralDeposited[user];
        return total > available ? available : total;
    }

    function _revertIfHealthFactorBroken(address user) private view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert LendingVault__HealthFactorBelowMinimum(healthFactor);
        }
    }

    function _healthFactor(address user) private view returns (uint256) {
        uint256 debt = s_debtMinted[user];
        if (debt == 0) {
            return type(uint256).max;
        }
        uint256 collateralValueUsd = _getUsdValue(s_collateralDeposited[user]);
        uint256 adjustedCollateral = (collateralValueUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (adjustedCollateral * PRECISION) / debt;
    }

    function _getUsdValue(uint256 tokenAmount) private view returns (uint256) {
        uint256 price = i_priceFeed.staleCheckLatestRoundData();
        return (price * tokenAmount) / PRECISION;
    }

    function _getTokenAmountFromUsd(uint256 usdAmount) private view returns (uint256) {
        uint256 price = i_priceFeed.staleCheckLatestRoundData();
        return (usdAmount * PRECISION) / price;
    }

    /*//////////////////////////////////////////////////////////////
                                 GETTERS
    //////////////////////////////////////////////////////////////*/

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getAccountInfo(address user)
        external
        view
        returns (uint256 debt, uint256 collateralAmount, uint256 collateralValueUsd)
    {
        debt = s_debtMinted[user];
        collateralAmount = s_collateralDeposited[user];
        collateralValueUsd = _getUsdValue(collateralAmount);
    }

    function getCollateralToSeize(address user, uint256 debtToCover) external view returns (uint256) {
        return _collateralToSeize(user, debtToCover);
    }

    function getMaxBorrowable(address user) external view returns (uint256) {
        uint256 collateralValueUsd = _getUsdValue(s_collateralDeposited[user]);
        uint256 ceiling = (collateralValueUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        uint256 debt = s_debtMinted[user];
        return ceiling > debt ? ceiling - debt : 0;
    }

    function getUsdValue(uint256 tokenAmount) external view returns (uint256) {
        return _getUsdValue(tokenAmount);
    }

    function getTokenAmountFromUsd(uint256 usdAmount) external view returns (uint256) {
        return _getTokenAmountFromUsd(usdAmount);
    }

    function getCollateralBalance(address user) external view returns (uint256) {
        return s_collateralDeposited[user];
    }

    function getDebt(address user) external view returns (uint256) {
        return s_debtMinted[user];
    }

    function getCollateralToken() external view returns (address) {
        return address(i_collateralToken);
    }

    function getBorrowToken() external view returns (address) {
        return address(i_borrowToken);
    }

    function getPriceFeed() external view returns (address) {
        return address(i_priceFeed);
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }
}
