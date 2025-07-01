// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract ShortPool is Ownable, ReentrancyGuard {
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    enum PositionStatus {
        Open,
        Closed,
        Liquidated
    }

    struct Position {
        address token;
        uint256 entryPrice;
        uint256 size;
        PositionStatus status;
        uint256 closePrice;
    }

    event PositionOpened(address indexed user, uint256 nonce, address indexed token, uint256 entryPrice, uint256 size);
    event PositionClosed(address indexed user, uint256 nonce, uint256 closePrice, int256 withdrawalAmount);
    event PositionLiquidated(address indexed user, uint256 nonce);

    mapping(address => address) public supportedTokens;
    mapping(address => Position[]) public positions;

    modifier validOpenPosition(address user, uint256 nonce) {
        require(nonce < positions[user].length, "Invalid nonce");
        require(positions[user][nonce].status == PositionStatus.Open, "Position is not open");

        _;
    }

    constructor() Ownable(msg.sender) {
        supportedTokens[WBTC] = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
        supportedTokens[WETH] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    }

    function setSupportedToken(address _token, address _priceFeed) external onlyOwner {
        require(_token != address(0), "Invalid token");
        require(_priceFeed != address(0), "Invalid price feed");
        require(supportedTokens[_token] == address(0), "Price feed is already set for the token");

        supportedTokens[_token] = _priceFeed;
    }

    function withdraw(uint256 _amount) external onlyOwner nonReentrant {
        require(_amount <= address(this).balance, "Insufficient balance");

        (bool success, ) = msg.sender.call{value: _amount}("");

        require(success, "Withdrawal failed");
    }

    function openPosition(address _token) external payable nonReentrant {
        require(msg.value > 0.01 ether, "Position size is too small");

        uint256 ethPrice = _getNormalizedPrice(WETH);
        uint256 entryPrice = _getNormalizedPrice(_token);
        uint256 size = (msg.value * ethPrice) / entryPrice;

        require(size > 0, "Invalid position size");

        positions[msg.sender].push(
            Position({token: _token, entryPrice: entryPrice, size: size, status: PositionStatus.Open, closePrice: 0})
        );

        emit PositionOpened(msg.sender, positions[msg.sender].length - 1, _token, entryPrice, size);
    }

    function closePosition(uint256 _nonce) external nonReentrant validOpenPosition(msg.sender, _nonce) {
        Position storage position = positions[msg.sender][_nonce];

        (int256 withdrawalAmount, uint256 closePrice) = _calculateWithdrawalAmount(position);

        if (withdrawalAmount > 0) {
            require(address(this).balance >= uint256(withdrawalAmount), "Insufficient balance");

            (bool success, ) = msg.sender.call{value: uint256(withdrawalAmount)}("");

            require(success, "Withdrawal failed");

            position.status = PositionStatus.Closed;
            position.closePrice = closePrice;

            emit PositionClosed(msg.sender, _nonce, closePrice, withdrawalAmount);
        } else {
            position.status = PositionStatus.Liquidated;
            position.closePrice = type(uint256).max;

            emit PositionLiquidated(msg.sender, _nonce);
        }
    }

    function liquidatePosition(address _user, uint256 _nonce) external nonReentrant validOpenPosition(_user, _nonce) {
        Position storage position = positions[_user][_nonce];

        (int256 withdrawalAmount, ) = _calculateWithdrawalAmount(position);

        require(withdrawalAmount <= 0, "Position is not eligible for liquidation");

        position.status = PositionStatus.Liquidated;
        position.closePrice = type(uint256).max;

        emit PositionLiquidated(_user, _nonce);
    }

    function _getNormalizedPrice(address _token) internal view returns (uint256) {
        address priceFeed = supportedTokens[_token];

        require(priceFeed != address(0), "Unsupported token");

        (, int256 tokenPrice, , , ) = AggregatorV3Interface(priceFeed).latestRoundData();
        uint8 tokenDecimals = AggregatorV3Interface(priceFeed).decimals();

        require(tokenPrice > 0, "Invalid token price");

        if (tokenDecimals < 18) {
            return uint256(tokenPrice) * (10**(18 - tokenDecimals));
        } else if (tokenDecimals > 18) {
            return uint256(tokenPrice) / (10**(tokenDecimals - 18));
        } else {
            return uint256(tokenPrice);
        }
    }

    function _calculateWithdrawalAmount(Position storage _position) internal view returns (int256, uint256) {
        uint256 ethPrice = _getNormalizedPrice(WETH);
        uint256 closePrice = _getNormalizedPrice(_position.token);

        int256 pnl = int256(_position.entryPrice) - int256(closePrice);
        int256 withdrawalAmount = ((int256(_position.entryPrice) + pnl) * int256(_position.size)) / int256(ethPrice);

        return (withdrawalAmount, closePrice);
    }
}
