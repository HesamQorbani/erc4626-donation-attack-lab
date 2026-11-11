// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VulnerableVault
/// @notice Simplified share vault demonstrating the ERC-4626 donation attack.
/// @dev Intentionally vulnerable to share-price inflation through direct donations.
///      NOT ERC-4626 compliant and NOT intended for production use.
contract VulnerableVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroShares();
    error ZeroAssetAddress();

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
        uint256 supply = totalShares;

        return supply == 0 ? assets : Math.mulDiv(assets, supply, totalAssets());
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalShares;

        return supply == 0 ? shares : Math.mulDiv(shares, totalAssets(), supply);
    }

    function deposit(uint256 assets) external nonReentrant returns (uint256 shares) {
        shares = convertToShares(assets);

        if (shares == 0) {
            revert ZeroShares();
        }

        totalShares += shares;
        sharesOf[msg.sender] += shares;

        // convertToShares reads the token balance through STATICCALL.
        // This event is emitted before safeTransferFrom.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Deposit(msg.sender, assets, shares);

        asset.safeTransferFrom(msg.sender, address(this), assets);
    }

    function redeem(uint256 shares) external nonReentrant returns (uint256 assets) {
        assets = convertToAssets(shares);

        sharesOf[msg.sender] -= shares;
        totalShares -= shares;

        // convertToAssets reads the token balance through STATICCALL.
        // This event is emitted before the outgoing token transfer.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Redeem(msg.sender, shares, assets);

        asset.safeTransfer(msg.sender, assets);
    }
}
