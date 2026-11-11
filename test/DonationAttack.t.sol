// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockToken} from "../src/MockToken.sol";
import {VulnerableVault} from "../src/VulnerableVault.sol";
import {SafeVault} from "../src/SafeVault.sol";

contract FalseReturnToken is IERC20 {
    function totalSupply() external pure override returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure override returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure override returns (bool) {
        return false;
    }

    function allowance(address, address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function approve(address, uint256) external pure override returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure override returns (bool) {
        return false;
    }
}

contract FalseTransferToken is MockToken {
    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}

contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;

            super._update(from, to, value - fee);
            super._update(from, address(0), fee);
        } else {
            super._update(from, to, value);
        }
    }
}

interface IVault {
    function deposit(uint256 assets) external returns (uint256);
    function sharesOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

contract ReentrantAttemptToken is ERC20 {
    IVault public targetVault;

    bool public armed;
    bool public reentryBlocked;
    bool public reentrySucceeded;

    bytes4 public reentryFailureSelector;

    constructor() ERC20("Reentrant Attempt Token", "RAT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTargetVault(IVault vault) external {
        targetVault = vault;
    }

    function arm() external {
        armed = true;
        reentryBlocked = false;
        reentrySucceeded = false;
        reentryFailureSelector = bytes4(0);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        bool success = super.transferFrom(from, to, value);

        _attemptReentry();

        return success;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        bool success = super.transfer(to, value);

        _attemptReentry();

        return success;
    }

    function _attemptReentry() internal {
        if (!armed) {
            return;
        }

        armed = false;

        uint256 reentryAmount = 1e18;

        _mint(address(this), reentryAmount);
        _approve(address(this), address(targetVault), type(uint256).max);

        try targetVault.deposit(reentryAmount) returns (uint256) {
            reentrySucceeded = true;
        } catch (bytes memory reason) {
            reentryBlocked = true;

            if (reason.length >= 4) {
                bytes4 selector;

                assembly {
                    selector := mload(add(reason, 32))
                }

                reentryFailureSelector = selector;
            }
        }
    }
}

contract DonationAttackTest is Test {
    uint256 internal constant DONATION = 1e18;
    uint256 internal constant VICTIM_DEPOSIT = 2e18 - 1;

    bytes4 internal constant ZERO_SHARES_SELECTOR = bytes4(keccak256("ZeroShares()"));

    MockToken internal token;

    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");

    function setUp() public {
        token = new MockToken();
    }

    function _revertSelector(bytes memory reason) internal pure returns (bytes4 selector) {
        if (reason.length >= 4) {
            assembly {
                selector := mload(add(reason, 32))
            }
        }
    }

    function _runAttack(IVault vault, uint256 donation, uint256 victimDeposit)
        internal
        returns (uint256 attackerSpent, uint256 attackerValue, uint256 victimValue, bool victimDepositSucceeded)
    {
        token.mint(attacker, donation + 1);
        token.mint(victim, victimDeposit);

        vm.startPrank(attacker);

        token.approve(address(vault), type(uint256).max);
        vault.deposit(1);

        assertTrue(token.transfer(address(vault), donation), "donation transfer failed");

        vm.stopPrank();

        vm.startPrank(victim);

        token.approve(address(vault), type(uint256).max);

        try vault.deposit(victimDeposit) {
            victimDepositSucceeded = true;
        } catch (bytes memory reason) {
            assertEq(_revertSelector(reason), ZERO_SHARES_SELECTOR, "unexpected victim deposit revert");
        }

        vm.stopPrank();

        attackerSpent = donation + 1;

        attackerValue = vault.convertToAssets(vault.sharesOf(attacker));

        victimValue = vault.convertToAssets(vault.sharesOf(victim));
    }

    function test_vulnerableVault_attackerProfitsFromVictim() public {
        VulnerableVault vault = new VulnerableVault(IERC20(address(token)));

        (uint256 spent, uint256 attackerValue, uint256 victimValue, bool victimDepositSucceeded) =
            _runAttack(IVault(address(vault)), DONATION, VICTIM_DEPOSIT);

        assertTrue(victimDepositSucceeded, "victim deposit should succeed");

        assertEq(vault.sharesOf(victim), 1);
        assertGt(attackerValue, spent, "attacker should profit");
        assertLt(victimValue, VICTIM_DEPOSIT);

        assertGt(VICTIM_DEPOSIT - victimValue, 0.49e18, "victim should lose about half");
    }

    function test_safeVault_attackFails() public {
        SafeVault vault = new SafeVault(IERC20(address(token)));

        (uint256 spent, uint256 attackerValue, uint256 victimValue, bool victimDepositSucceeded) =
            _runAttack(IVault(address(vault)), DONATION, VICTIM_DEPOSIT);

        assertTrue(victimDepositSucceeded, "victim deposit should succeed in this scenario");

        assertLt(attackerValue, spent, "attacker should lose money");

        assertLt((VICTIM_DEPOSIT - victimValue) * 1000, VICTIM_DEPOSIT, "victim should lose less than 0.1%");
    }

    function testFuzz_safeVault_attackerNeverProfits(uint256 donation, uint256 victimDeposit) public {
        donation = bound(donation, 1, 1e30);
        victimDeposit = bound(victimDeposit, 1, 1e30);

        SafeVault vault = new SafeVault(IERC20(address(token)));

        (uint256 spent, uint256 attackerValue,, bool victimDepositSucceeded) =
            _runAttack(IVault(address(vault)), donation, victimDeposit);

        assertLe(attackerValue, spent, "attacker must never profit");

        if (!victimDepositSucceeded) {
            assertEq(vault.sharesOf(victim), 0, "victim must have no shares after rejected deposit");
        }
    }

    function test_safeVault_rejectsZeroAssetAddress() public {
        vm.expectRevert(SafeVault.ZeroAssetAddress.selector);
        new SafeVault(IERC20(address(0)));
    }

    function test_vulnerableVault_rejectsZeroAssetAddress() public {
        vm.expectRevert(VulnerableVault.ZeroAssetAddress.selector);
        new VulnerableVault(IERC20(address(0)));
    }

    function test_safeVault_depositAndRedeemRestoresUserBalance() public {
        uint256 depositAmount = 10e18;

        SafeVault vault = new SafeVault(IERC20(address(token)));

        token.mint(victim, depositAmount);

        vm.startPrank(victim);

        token.approve(address(vault), depositAmount);

        uint256 shares = vault.deposit(depositAmount);

        uint256 assetsReceived = vault.redeem(shares);

        vm.stopPrank();

        assertEq(assetsReceived, depositAmount, "incorrect redeemed assets");
        assertEq(vault.sharesOf(victim), 0, "shares should be zero");
        assertEq(vault.totalShares(), 0, "total shares should be zero");
        assertEq(vault.totalAssets(), 0, "vault assets should be zero");
        assertEq(token.balanceOf(victim), depositAmount, "user balance not restored");
    }

    function test_safeVault_cannotRedeemMoreSharesThanOwned() public {
        uint256 depositAmount = 10e18;

        SafeVault vault = new SafeVault(IERC20(address(token)));

        token.mint(victim, depositAmount);

        vm.startPrank(victim);

        token.approve(address(vault), depositAmount);

        uint256 shares = vault.deposit(depositAmount);

        vm.expectRevert();
        vault.redeem(shares + 1);

        vm.stopPrank();

        assertEq(vault.sharesOf(victim), shares, "user shares changed");
        assertEq(vault.totalShares(), shares, "total shares changed");
        assertEq(vault.totalAssets(), depositAmount, "vault assets changed");
        assertEq(token.balanceOf(victim), 0, "user balance changed");
    }

    function test_safeVault_revertsWhenTransferFromReturnsFalse() public {
        FalseReturnToken falseToken = new FalseReturnToken();
        SafeVault vault = new SafeVault(IERC20(address(falseToken)));

        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("SafeERC20FailedOperation(address)")), address(falseToken))
        );

        vault.deposit(1);

        assertEq(vault.totalShares(), 0);
        assertEq(vault.sharesOf(address(this)), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function test_vulnerableVault_revertsWhenTransferFromReturnsFalse() public {
        FalseReturnToken falseToken = new FalseReturnToken();
        VulnerableVault vault = new VulnerableVault(IERC20(address(falseToken)));

        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("SafeERC20FailedOperation(address)")), address(falseToken))
        );

        vault.deposit(1);

        assertEq(vault.totalShares(), 0);
        assertEq(vault.sharesOf(address(this)), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function test_safeVault_revertsWhenTransferReturnsFalse() public {
        FalseTransferToken falseToken = new FalseTransferToken();
        SafeVault vault = new SafeVault(IERC20(address(falseToken)));

        uint256 amount = 10e18;
        falseToken.mint(address(this), amount);

        falseToken.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount);

        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("SafeERC20FailedOperation(address)")), address(falseToken))
        );

        vault.redeem(shares);

        assertEq(vault.sharesOf(address(this)), shares);
        assertEq(vault.totalShares(), shares);
        assertEq(vault.totalAssets(), amount);
        assertEq(falseToken.balanceOf(address(this)), 0);
    }

    function test_safeVault_rejectsZeroDeposit() public {
        SafeVault vault = new SafeVault(IERC20(address(token)));

        vm.expectRevert(SafeVault.ZeroShares.selector);
        vault.deposit(0);

        assertEq(vault.totalShares(), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function test_vulnerableVault_rejectsZeroDeposit() public {
        VulnerableVault vault = new VulnerableVault(IERC20(address(token)));

        vm.expectRevert(VulnerableVault.ZeroShares.selector);
        vault.deposit(0);

        assertEq(vault.totalShares(), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function test_safeVault_allowsZeroRedeem() public {
        SafeVault vault = new SafeVault(IERC20(address(token)));

        uint256 assetsReceived = vault.redeem(0);

        assertEq(assetsReceived, 0);
        assertEq(vault.totalShares(), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function test_vulnerableVault_allowsZeroRedeem() public {
        VulnerableVault vault = new VulnerableVault(IERC20(address(token)));

        uint256 assetsReceived = vault.redeem(0);

        assertEq(assetsReceived, 0);
        assertEq(vault.totalShares(), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function test_safeVault_usesReceivedAmountForFeeOnTransferToken() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        SafeVault vault = new SafeVault(IERC20(address(feeToken)));

        uint256 amount = 100e18;
        uint256 fee = amount / 100;
        uint256 received = amount - fee;

        feeToken.mint(address(this), amount);
        feeToken.approve(address(vault), amount);

        uint256 shares = vault.deposit(amount);

        uint256 expectedShares = received * 1000;

        assertEq(vault.totalAssets(), received, "vault did not receive expected net amount");
        assertEq(shares, expectedShares, "shares must be based on received assets");
        assertEq(vault.sharesOf(address(this)), expectedShares, "incorrect user share balance");
    }

    function test_safeVault_feeOnTransferTokenChargesFeeOnRedeem() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        SafeVault vault = new SafeVault(IERC20(address(feeToken)));

        uint256 amount = 100e18;
        uint256 depositFee = amount / 100;
        uint256 received = amount - depositFee;

        feeToken.mint(address(this), amount);
        feeToken.approve(address(vault), amount);

        uint256 shares = vault.deposit(amount);

        uint256 userBalanceBefore = feeToken.balanceOf(address(this));

        uint256 assetsReturned = vault.redeem(shares);

        uint256 redemptionFee = assetsReturned / 100;
        uint256 expectedReceived = assetsReturned - redemptionFee;

        assertEq(
            feeToken.balanceOf(address(this)), userBalanceBefore + expectedReceived, "incorrect net redemption amount"
        );

        assertEq(vault.totalAssets(), 0, "vault should have no remaining assets");
        assertEq(vault.totalShares(), 0, "vault should have no remaining shares");
        assertEq(assetsReturned, received, "unexpected gross redemption amount");
    }

    function test_safeVault_convertToShares() public {
        SafeVault vault = new SafeVault(IERC20(address(token)));

        // Check conversion when the vault is empty.
        assertEq(vault.convertToShares(1e18), 1e21, "incorrect empty vault conversion");

        // Deposit assets using a standard ERC20 token.
        uint256 depositAmount = 10e18;

        token.mint(address(this), depositAmount);
        token.approve(address(vault), depositAmount);

        uint256 mintedShares = vault.deposit(depositAmount);

        assertEq(mintedShares, 10e21, "incorrect minted shares");

        // Check conversion after the first deposit.
        assertEq(vault.convertToShares(2e18), 2e21, "incorrect conversion after deposit");
    }

    function test_vulnerableVault_convertToShares() public {
        VulnerableVault vault = new VulnerableVault(IERC20(address(token)));

        // Check conversion when the vault is empty.
        assertEq(vault.convertToShares(1e18), 1e18, "incorrect empty vault conversion");

        // Deposit assets using a standard ERC20 token.
        uint256 depositAmount = 10e18;

        token.mint(address(this), depositAmount);
        token.approve(address(vault), depositAmount);

        uint256 mintedShares = vault.deposit(depositAmount);

        assertEq(mintedShares, 10e18, "incorrect minted shares");

        // Check conversion after the first deposit.
        assertEq(vault.convertToShares(2e18), 2e18, "incorrect conversion after deposit");
    }

    function test_safeVault_blocksReentrancyDuringDeposit() public {
        ReentrantAttemptToken reentrantToken = new ReentrantAttemptToken();
        SafeVault vault = new SafeVault(IERC20(address(reentrantToken)));

        reentrantToken.setTargetVault(IVault(address(vault)));

        uint256 amount = 10e18;
        reentrantToken.mint(address(this), amount);
        reentrantToken.approve(address(vault), type(uint256).max);

        reentrantToken.arm();

        uint256 shares = vault.deposit(amount);

        assertTrue(reentrantToken.reentryBlocked());
        assertFalse(reentrantToken.reentrySucceeded());

        assertEq(
            reentrantToken.reentryFailureSelector(),
            bytes4(keccak256("ReentrancyGuardReentrantCall()")),
            "Unexpected reentrancy failure reason"
        );

        assertEq(vault.totalShares(), shares);
        assertEq(vault.sharesOf(address(this)), shares);
        assertEq(vault.totalAssets(), amount);
    }

    function test_vulnerableVault_blocksReentrancyDuringDeposit() public {
        ReentrantAttemptToken reentrantToken = new ReentrantAttemptToken();
        VulnerableVault vault = new VulnerableVault(IERC20(address(reentrantToken)));

        reentrantToken.setTargetVault(IVault(address(vault)));

        uint256 amount = 10e18;
        reentrantToken.mint(address(this), amount);
        reentrantToken.approve(address(vault), type(uint256).max);

        reentrantToken.arm();

        uint256 shares = vault.deposit(amount);

        assertTrue(reentrantToken.reentryBlocked());
        assertFalse(reentrantToken.reentrySucceeded());

        assertEq(
            reentrantToken.reentryFailureSelector(),
            bytes4(keccak256("ReentrancyGuardReentrantCall()")),
            "Unexpected reentrancy failure reason"
        );

        assertEq(vault.totalShares(), shares);
        assertEq(vault.sharesOf(address(this)), shares);
        assertEq(vault.totalAssets(), amount);
    }

    function test_safeVault_blocksReentrancyDuringRedeem() public {
        ReentrantAttemptToken reentrantToken = new ReentrantAttemptToken();
        SafeVault vault = new SafeVault(IERC20(address(reentrantToken)));

        reentrantToken.setTargetVault(IVault(address(vault)));

        uint256 amount = 10e18;

        reentrantToken.mint(address(this), amount);
        reentrantToken.approve(address(vault), type(uint256).max);

        vault.deposit(amount);

        uint256 initialShares = vault.sharesOf(address(this));
        uint256 sharesToRedeem = initialShares / 2;

        reentrantToken.arm();

        uint256 assetsRedeemed = vault.redeem(sharesToRedeem);

        assertTrue(reentrantToken.reentryBlocked());
        assertFalse(reentrantToken.reentrySucceeded());

        assertEq(
            reentrantToken.reentryFailureSelector(),
            bytes4(keccak256("ReentrancyGuardReentrantCall()")),
            "Unexpected reentrancy failure reason"
        );

        assertEq(vault.totalShares(), initialShares - sharesToRedeem);
        assertEq(vault.sharesOf(address(this)), initialShares - sharesToRedeem);
        assertEq(vault.totalAssets(), amount - assetsRedeemed);
    }

    function test_vulnerableVault_blocksReentrancyDuringRedeem() public {
        ReentrantAttemptToken reentrantToken = new ReentrantAttemptToken();
        VulnerableVault vault = new VulnerableVault(IERC20(address(reentrantToken)));

        reentrantToken.setTargetVault(IVault(address(vault)));

        uint256 amount = 10e18;

        reentrantToken.mint(address(this), amount);
        reentrantToken.approve(address(vault), type(uint256).max);

        vault.deposit(amount);

        uint256 initialShares = vault.sharesOf(address(this));
        uint256 sharesToRedeem = initialShares / 2;

        reentrantToken.arm();

        uint256 assetsRedeemed = vault.redeem(sharesToRedeem);

        assertTrue(reentrantToken.reentryBlocked());
        assertFalse(reentrantToken.reentrySucceeded());

        assertEq(
            reentrantToken.reentryFailureSelector(),
            bytes4(keccak256("ReentrancyGuardReentrantCall()")),
            "Unexpected reentrancy failure reason"
        );

        assertEq(vault.totalShares(), initialShares - sharesToRedeem);
        assertEq(vault.sharesOf(address(this)), initialShares - sharesToRedeem);
        assertEq(vault.totalAssets(), amount - assetsRedeemed);
    }
}
