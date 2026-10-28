// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Like} from "./IERC20Like.sol";

/// @title SafeVault
/// @notice Same vault as VulnerableVault, plus "virtual shares and assets" (an OpenZeppelin-style offset).
/// @dev Simplified and NOT audited. The offset makes the donation attack lose money for the attacker.
contract SafeVault {
    error ZeroShares();

    uint256 private constant VIRTUAL_SHARES = 1000; // 10 ** 3 offset on shares
    uint256 private constant VIRTUAL_ASSETS = 1;

    IERC20Like public immutable asset;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    constructor(IERC20Like _asset) {
        asset = _asset;
    }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @dev Rounds down (correct for deposits).
    function convertToShares(uint256 assets) public view returns (uint256) {
        return (assets * (totalShares + VIRTUAL_SHARES)) / (totalAssets() + VIRTUAL_ASSETS);
    }

    /// @dev Rounds down (correct for redeems).
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return (shares * (totalAssets() + VIRTUAL_ASSETS)) / (totalShares + VIRTUAL_SHARES);
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        shares = convertToShares(assets); // must be computed BEFORE the transfer
        if (shares == 0) revert ZeroShares();
        asset.transferFrom(msg.sender, address(this), assets);
        totalShares += shares;
        sharesOf[msg.sender] += shares;
    }

    function redeem(uint256 shares) external returns (uint256 assets) {
        assets = convertToAssets(shares);
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        asset.transfer(msg.sender, assets);
    }
}
