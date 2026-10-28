// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Like} from "./IERC20Like.sol";

/// @title VulnerableVault
/// @notice Simplified share vault used to demonstrate the donation (inflation) attack.
/// @dev NOT ERC-4626 compliant and NOT safe. It prices shares from the raw token balance
///      and has no virtual offset, so an attacker can inflate the share price by donating.
contract VulnerableVault {
    error ZeroShares();

    IERC20Like public immutable asset;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    constructor(IERC20Like _asset) {
        asset = _asset;
    }

    /// @dev Reads the real token balance, so direct transfers ("donations") change the price.
    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @dev Rounds down (correct for deposits). First depositor gets shares 1:1.
    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalShares;
        return supply == 0 ? assets : (assets * supply) / totalAssets();
    }

    /// @dev Rounds down (correct for redeems).
    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalShares;
        return supply == 0 ? shares : (shares * totalAssets()) / supply;
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
