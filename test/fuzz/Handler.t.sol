// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LendingVault} from "../../src/LendingVault.sol";
import {BorrowToken} from "../../src/BorrowToken.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

/**
 * @title Handler
 * @notice Steers the invariant fuzzer toward valid calls. Without this, almost
 *         every random call would revert and the invariants would never be
 *         meaningfully exercised.
 * @dev allowPriceDrops splits the two campaigns. With it false the price can
 *      only rise, which isolates whether user actions alone can break solvency.
 */
contract Handler is Test {
    LendingVault private immutable vault;
    BorrowToken private immutable borrowToken;
    MockWETH private immutable weth;
    MockV3Aggregator private immutable feed;
    bool private immutable allowPriceDrops;

    address[] private actors;
    address private currentActor;

    uint256 public depositCalls;
    uint256 public borrowCalls;
    uint256 public repayCalls;
    uint256 public withdrawCalls;
    uint256 public liquidateCalls;
    uint256 public priceUpdateCalls;

    uint256 private constant MAX_DEPOSIT = 100e18;
    uint256 private constant MIN_PRICE = 500e8;
    uint256 private constant START_PRICE = 3000e8;
    uint256 private constant MAX_PRICE = 5000e8;

    constructor(address _vault, address _weth, address _borrowToken, address _feed, bool _allowPriceDrops) {
        vault = LendingVault(_vault);
        weth = MockWETH(_weth);
        borrowToken = BorrowToken(_borrowToken);
        feed = MockV3Aggregator(_feed);
        allowPriceDrops = _allowPriceDrops;

        for (uint256 i = 0; i < 5; i++) {
            address actor = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(actor);

            weth.mint(actor, 1000e18);
            vm.startPrank(actor);
            weth.approve(address(vault), type(uint256).max);
            IERC20(address(borrowToken)).approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    modifier useActor(uint256 seed) {
        currentActor = actors[bound(seed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    function deposit(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        amount = bound(amount, 1e15, MAX_DEPOSIT);

        uint256 held = weth.balanceOf(currentActor);
        if (held < amount) {
            vm.stopPrank();
            weth.mint(currentActor, amount - held);
            vm.startPrank(currentActor);
        }

        vault.depositCollateral(amount);
        depositCalls++;
    }

    function borrow(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        uint256 headroom = vault.getMaxBorrowable(currentActor);
        if (headroom == 0) return;

        // Bias toward the ceiling: positions parked at a health factor near 1
        // are the ones a price move can actually push into liquidation.
        amount = bound(amount, (headroom * 7) / 10, headroom);
        if (amount == 0) return;

        try vault.borrow(amount) {
            borrowCalls++;
        } catch {}
    }

    function repay(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        uint256 debt = vault.getDebt(currentActor);
        uint256 held = borrowToken.balanceOf(currentActor);
        uint256 coverable = debt < held ? debt : held;
        if (coverable == 0) return;

        amount = bound(amount, 1, coverable);
        try vault.repay(amount) {
            repayCalls++;
        } catch {}
    }

    function withdraw(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        uint256 balance = vault.getCollateralBalance(currentActor);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);
        try vault.withdrawCollateral(amount) {
            withdrawCalls++;
        } catch {}
    }

    function liquidate(uint256 actorSeed, uint256 victimSeed, uint256 amount) external useActor(actorSeed) {
        address victim = actors[bound(victimSeed, 0, actors.length - 1)];
        if (victim == currentActor) return;
        if (vault.getHealthFactor(victim) >= 1e18) return;

        uint256 debt = vault.getDebt(victim);
        if (debt == 0) return;

        uint256 held = borrowToken.balanceOf(currentActor);
        if (held < debt) {
            vm.stopPrank();
            _fundLiquidator(currentActor, debt - held);
            vm.startPrank(currentActor);
        }

        amount = bound(amount, 1, debt);

        try vault.liquidate(victim, amount) {
            liquidateCalls++;
        } catch {}
    }

    function updatePrice(uint256 newPrice) external {
        (, int256 current,,,) = feed.latestRoundData();

        // casting to 'uint256' is safe because the mock feed never holds a negative price
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 floorPrice = allowPriceDrops ? MIN_PRICE : uint256(current);
        uint256 price = bound(newPrice, floorPrice, MAX_PRICE);

        // casting to 'int256' is safe because price is bounded below 2^255
        // forge-lint: disable-next-line(unsafe-typecast)
        feed.updateAnswer(int256(price));
        priceUpdateCalls++;
    }

    /// @dev Mints collateral for the liquidator and borrows the bUSD they need.
    function _fundLiquidator(address liquidator, uint256 needed) private {
        // 20x over-collateralised so the liquidator's own position survives a
        // crash. Without this the final health check in liquidate() rejects
        // almost every attempt and the path is never exercised.
        uint256 collateral = (vault.getTokenAmountFromUsd(needed) * 20) + 10e18;
        weth.mint(liquidator, collateral);

        vm.startPrank(liquidator);
        vault.depositCollateral(collateral);
        uint256 headroom = vault.getMaxBorrowable(liquidator);
        if (headroom >= needed) {
            vault.borrow(needed);
        }
        vm.stopPrank();
    }

    /// @dev A deliberate sharp drop. Does nothing in the stable campaign.
    function crashPrice(uint256 seed) external {
        if (!allowPriceDrops) return;

        (, int256 current,,,) = feed.latestRoundData();

        // casting to 'uint256' is safe because the mock feed never holds a negative price
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 next = (uint256(current) * (10000 - bound(seed, 3000, 7000))) / 10000;
        if (next < MIN_PRICE) next = MIN_PRICE;

        // casting to 'int256' is safe because next is bounded below MAX_PRICE
        // forge-lint: disable-next-line(unsafe-typecast)
        feed.updateAnswer(int256(next));
        priceUpdateCalls++;
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }

    function anyActorIsUnhealthy() external view returns (bool) {
        for (uint256 i = 0; i < actors.length; i++) {
            if (vault.getHealthFactor(actors[i]) < 1e18) {
                return true;
            }
        }
        return false;
    }
}
