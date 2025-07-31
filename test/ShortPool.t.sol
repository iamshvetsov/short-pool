// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ShortPool} from "../src/ShortPool.sol";

contract ShortPoolTest is Test {
    ShortPool public shortPool;

    address public owner;
    address public user1;
    address public user2;
    address public liquidator;

    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant CUSTOM_TOKEN = 0x1234567890123456789012345678901234567890;

    address constant WBTC_PRICE_FEED = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant WETH_PRICE_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    int256 constant INITIAL_WBTC_PRICE = 100000e18;
    int256 constant INITIAL_WETH_PRICE = 3000e18;

    event PositionOpened(address indexed user, uint256 nonce, address indexed token, uint256 entryPrice, uint256 size);
    event PositionClosed(address indexed user, uint256 nonce, uint256 closePrice, int256 withdrawalAmount);
    event PositionLiquidated(address indexed user, uint256 nonce);

    function setUp() public {
        shortPool = new ShortPool();

        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        liquidator = makeAddr("liquidator");

        vm.mockCall(
            WBTC_PRICE_FEED,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), INITIAL_WBTC_PRICE, uint256(block.timestamp), uint256(block.timestamp), uint80(1))
        );
        vm.mockCall(WBTC_PRICE_FEED, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));

        vm.mockCall(
            WETH_PRICE_FEED,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), INITIAL_WETH_PRICE, uint256(block.timestamp), uint256(block.timestamp), uint80(1))
        );
        vm.mockCall(WETH_PRICE_FEED, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));

        vm.deal(address(shortPool), 100 ether);
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        vm.deal(liquidator, 1 ether);
    }

    function test_Constructor() public view {
        assertEq(shortPool.owner(), owner);
        assertEq(shortPool.supportedTokens(WBTC), WBTC_PRICE_FEED);
        assertEq(shortPool.supportedTokens(WETH), WETH_PRICE_FEED);
    }

    function test_SetSupportedToken() public {
        address customPriceFeed = address(0x3333);
        shortPool.setSupportedToken(CUSTOM_TOKEN, customPriceFeed);

        assertEq(shortPool.supportedTokens(CUSTOM_TOKEN), customPriceFeed);
    }

    function test_SetSupportedToken_RevertInvalidToken() public {
        vm.expectRevert("Invalid token");
        shortPool.setSupportedToken(address(0), address(0x3333));
    }

    function test_SetSupportedToken_RevertInvalidPriceFeed() public {
        vm.expectRevert("Invalid price feed");
        shortPool.setSupportedToken(CUSTOM_TOKEN, address(0));
    }

    function test_SetSupportedToken_RevertAlreadySet() public {
        address customPriceFeed = address(0x3333);
        shortPool.setSupportedToken(CUSTOM_TOKEN, customPriceFeed);

        vm.expectRevert("Price feed is already set for the token");
        shortPool.setSupportedToken(CUSTOM_TOKEN, customPriceFeed);
    }

    function test_SetSupportedToken_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        shortPool.setSupportedToken(CUSTOM_TOKEN, address(0x3333));
    }

    function test_Withdraw() public {
        uint256 initialBalance = address(this).balance;
        uint256 withdrawAmount = 5 ether;
        shortPool.withdraw(withdrawAmount);

        assertEq(address(this).balance, initialBalance + withdrawAmount);
        assertEq(address(shortPool).balance, 100 ether - withdrawAmount);
    }

    function test_Withdraw_RevertInsufficientBalance() public {
        vm.expectRevert("Insufficient balance");
        shortPool.withdraw(200 ether);
    }

    function test_Withdraw_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        shortPool.withdraw(1 ether);
    }

    function test_OpenPosition() public {
        vm.startPrank(user1);

        uint256 positionValue = 1 ether;
        uint256 expectedSize = (positionValue * uint256(INITIAL_WETH_PRICE)) / uint256(INITIAL_WBTC_PRICE);

        vm.expectEmit(true, true, false, true);
        emit PositionOpened(user1, 0, WBTC, uint256(INITIAL_WBTC_PRICE), expectedSize);

        shortPool.openPosition{value: positionValue}(WBTC);
        (
            address token,
            uint256 entryPrice,
            uint256 size,
            ShortPool.PositionStatus status,
            uint256 closePrice
        ) = shortPool.positions(user1, 0);

        assertEq(token, WBTC);
        assertEq(entryPrice, uint256(INITIAL_WBTC_PRICE));
        assertEq(size, expectedSize);
        assertEq(uint256(status), uint256(ShortPool.PositionStatus.Open));
        assertEq(closePrice, 0);

        vm.stopPrank();
    }

    function test_OpenPosition_RevertTooSmall() public {
        vm.startPrank(user1);

        vm.expectRevert("Position size is too small");
        shortPool.openPosition{value: 0.005 ether}(WBTC);

        vm.stopPrank();
    }

    function test_OpenPosition_RevertUnsupportedToken() public {
        vm.startPrank(user1);

        vm.expectRevert("Unsupported token");
        shortPool.openPosition{value: 1 ether}(CUSTOM_TOKEN);

        vm.stopPrank();
    }

    function test_ClosePosition_Profit() public {
        vm.startPrank(user1);

        shortPool.openPosition{value: 1 ether}(WBTC);

        vm.mockCall(
            WBTC_PRICE_FEED,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(90000e18), block.timestamp, block.timestamp, uint80(1))
        );

        uint256 userBalanceBefore = user1.balance;

        vm.expectEmit(true, false, false, false);
        emit PositionClosed(user1, 0, 90000e18, 0);

        shortPool.closePosition(0);
        (, , , ShortPool.PositionStatus status, uint256 closePrice) = shortPool.positions(user1, 0);

        assertEq(uint256(status), uint256(ShortPool.PositionStatus.Closed));
        assertEq(closePrice, 90000e18);
        assertTrue(user1.balance > userBalanceBefore);

        vm.stopPrank();
    }

    function test_ClosePosition_Loss() public {
        vm.startPrank(user1);

        shortPool.openPosition{value: 1 ether}(WBTC);

        vm.mockCall(
            WBTC_PRICE_FEED,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(200000e18), block.timestamp, block.timestamp, uint80(1))
        );

        shortPool.closePosition(0);
        (, , , ShortPool.PositionStatus status, uint256 closePrice) = shortPool.positions(user1, 0);

        assertEq(uint256(status), uint256(ShortPool.PositionStatus.Liquidated));
        assertEq(closePrice, type(uint256).max);

        vm.stopPrank();
    }

    function test_ClosePosition_RevertInvalidNonce() public {
        vm.startPrank(user1);

        vm.expectRevert("Invalid nonce");
        shortPool.closePosition(0);

        vm.stopPrank();
    }

    function test_ClosePosition_RevertNotOpen() public {
        vm.startPrank(user1);

        shortPool.openPosition{value: 1 ether}(WBTC);
        shortPool.closePosition(0);

        vm.expectRevert("Position is not open");
        shortPool.closePosition(0);

        vm.stopPrank();
    }

    function test_LiquidatePosition() public {
        vm.startPrank(user1);
        shortPool.openPosition{value: 1 ether}(WBTC);
        vm.stopPrank();

        vm.mockCall(
            WBTC_PRICE_FEED,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(200000e18), block.timestamp, block.timestamp, uint80(1))
        );

        vm.startPrank(liquidator);
        vm.expectEmit(true, false, false, true);
        emit PositionLiquidated(user1, 0);

        shortPool.liquidatePosition(user1, 0);
        vm.stopPrank();

        (, , , ShortPool.PositionStatus status, uint256 closePrice) = shortPool.positions(user1, 0);

        assertEq(uint256(status), uint256(ShortPool.PositionStatus.Liquidated));
        assertEq(closePrice, type(uint256).max);
    }

    function test_LiquidatePosition_RevertNotEligible() public {
        vm.startPrank(user1);
        shortPool.openPosition{value: 1 ether}(WBTC);
        vm.stopPrank();

        vm.mockCall(
            WBTC_PRICE_FEED,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(110000e18), block.timestamp, block.timestamp, uint80(1))
        );

        vm.startPrank(liquidator);
        vm.expectRevert("Position is not eligible for liquidation");
        shortPool.liquidatePosition(user1, 0);
        vm.stopPrank();
    }

    function test_LiquidatePosition_RevertInvalidNonce() public {
        vm.startPrank(liquidator);

        vm.expectRevert("Invalid nonce");
        shortPool.liquidatePosition(user1, 0);

        vm.stopPrank();
    }

    function test_MultiplePositions() public {
        vm.startPrank(user1);

        shortPool.openPosition{value: 1 ether}(WBTC);
        shortPool.openPosition{value: 0.5 ether}(WBTC);

        (address token1, , , ShortPool.PositionStatus status1, ) = shortPool.positions(user1, 0);
        (address token2, , , ShortPool.PositionStatus status2, ) = shortPool.positions(user1, 1);

        assertEq(token1, WBTC);
        assertEq(token2, WBTC);
        assertEq(uint256(status1), uint256(ShortPool.PositionStatus.Open));
        assertEq(uint256(status2), uint256(ShortPool.PositionStatus.Open));

        vm.stopPrank();
    }

    function test_DifferentUsers() public {
        vm.startPrank(user1);
        shortPool.openPosition{value: 1 ether}(WBTC);
        vm.stopPrank();

        vm.startPrank(user2);
        shortPool.openPosition{value: 0.8 ether}(WBTC);
        vm.stopPrank();

        (address token1, , , , ) = shortPool.positions(user1, 0);
        (address token2, , , , ) = shortPool.positions(user2, 0);

        assertEq(token1, WBTC);
        assertEq(token2, WBTC);

        vm.startPrank(user1);
        vm.expectRevert("Invalid nonce");
        shortPool.closePosition(1);
        vm.stopPrank();
    }

    function test_PriceFeedDecimals() public {
        address feed8Decimals = address(0x1111);
        address feed6Decimals = address(0x2222);

        vm.mockCall(
            feed8Decimals,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(5000000000), block.timestamp, block.timestamp, uint80(1))
        );
        vm.mockCall(feed8Decimals, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));

        vm.mockCall(
            feed6Decimals,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(50000000), block.timestamp, block.timestamp, uint80(1))
        );
        vm.mockCall(feed6Decimals, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));

        shortPool.setSupportedToken(feed8Decimals, feed8Decimals);
        shortPool.setSupportedToken(feed6Decimals, feed6Decimals);

        assertEq(shortPool.supportedTokens(feed8Decimals), feed8Decimals);
        assertEq(shortPool.supportedTokens(feed6Decimals), feed6Decimals);
    }

    function testFuzz_OpenPosition(uint256 positionValue) public {
        positionValue = bound(positionValue, 0.011 ether, 5 ether);

        vm.startPrank(user1);
        vm.deal(user1, positionValue);

        shortPool.openPosition{value: positionValue}(WBTC);

        (address token, uint256 entryPrice, uint256 size, ShortPool.PositionStatus status, ) = shortPool.positions(
            user1,
            0
        );

        assertEq(token, WBTC);
        assertEq(entryPrice, uint256(INITIAL_WBTC_PRICE));
        assertTrue(size > 0);
        assertEq(uint256(status), uint256(ShortPool.PositionStatus.Open));

        vm.stopPrank();
    }

    receive() external payable {}
}
