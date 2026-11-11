// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SafeVault
/// @notice Simplified vault demonstrating virtual shares and assets
///         as a mitigation for the ERC-4626 donation attack.
/// @dev Supports fee-on-transfer tokens by accounting for actual
///      received assets. NOT ERC-4626 compliant and NOT audited
///      for production use.
contract SafeVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroShares();
    error ZeroAssetAddress();

    uint256 private constant VIRTUAL_SHARES = 1000;
    uint256 private constant VIRTUAL_ASSETS = 1;

    IERC20 public immutable asset;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    event Deposit(address indexed caller, uint256 assets, uint256 shares);
    event Redeem(address indexed caller, uint256 shares, uint256 assets);

    constructor(IERC20 _asset) {
        if (address(_asset) == address(0)) {
            revert ZeroAssetAddress();
        }

        asset = _asset;
    }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, totalShares + VIRTUAL_SHARES, totalAssets() + VIRTUAL_ASSETS);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, totalAssets() + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    function deposit(uint256 assets) external nonReentrant returns (uint256 shares) {
        uint256 assetsBefore = totalAssets();

        asset.safeTransferFrom(msg.sender, address(this), assets);

        uint256 assetsReceived = totalAssets() - assetsBefore;

        shares = Math.mulDiv(assetsReceived, totalShares + VIRTUAL_SHARES, assetsBefore + VIRTUAL_ASSETS);

        if (shares == 0) {
            revert ZeroShares();
        }

        totalShares += shares;
        sharesOf[msg.sender] += shares;

        // The actual received amount is known only after safeTransferFrom.
        // All state-changing vault entry points are protected by nonReentrant.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Deposit(msg.sender, assetsReceived, shares);
    }

    function redeem(uint256 shares) external nonReentrant returns (uint256 assets) {
        assets = convertToAssets(shares);

        sharesOf[msg.sender] -= shares;
        totalShares -= shares;

        // The preceding balanceOf call uses STATICCALL.
        // This event is emitted before the outgoing token transfer.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Redeem(msg.sender, shares, assets);

        asset.safeTransfer(msg.sender, assets);
    }
}
