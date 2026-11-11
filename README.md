# ERC-4626 Donation Attack Lab

![CI](https://github.com/HesamQorbani/erc4626-donation-attack-lab/actions/workflows/test.yml/badge.svg)

A Foundry-based educational lab demonstrating the ERC-4626 donation (inflation) attack and exploring how virtual assets and virtual shares can reduce its impact.

> **Educational project only.** The code was developed with AI assistance. The author ran the test suite. These contracts are simplified examples, have not been professionally audited, and are not intended for production use.

## Overview

In a share-based vault, users deposit assets and receive shares representing their ownership.

A donation attack can manipulate the vault's asset-to-share exchange rate. In a vulnerable implementation, an attacker can deposit a very small amount, donate additional tokens directly to the vault, and cause a later depositor to receive fewer shares because the conversion rounds down.

This lab compares two simplified vault implementations:

- **`VulnerableVault`** — uses the vault's actual token balance to calculate share conversions, making it vulnerable to the demonstrated inflation attack.
- **`SafeVault`** — uses virtual assets and virtual shares to make the same attack substantially less profitable for the attacker and reduce the victim's loss.

## Project structure

| File | Description |
|---|---|
| `src/VulnerableVault.sol` | Simplified vault demonstrating the donation attack |
| `src/SafeVault.sol` | Vault using virtual assets and virtual shares |
| `src/MockToken.sol` | Test ERC-20 token; unrestricted minting is intended for testing only |
| `test/DonationAttack.t.sol` | Attack, mitigation, token-behavior, conversion, and reentrancy tests |
| `foundry.toml` | Foundry configuration |
| `foundry.lock` | Locked dependency revisions |
| `.github/workflows/test.yml` | GitHub Actions workflow running the test suite |

## How the attack works

The demonstration uses the following sequence:

1. The attacker deposits **1 wei** and receives 1 share in the vulnerable vault.
2. The attacker transfers **1 token** directly to the vault as a donation.
3. The victim deposits **2 tokens minus 1 wei**.
4. Because the exchange-rate calculation rounds down, the victim receives only 1 share.
5. The attacker and victim each hold 1 share, while the vault holds approximately 3 tokens.

In this test scenario, each share is worth approximately 1.5 tokens.

The attacker spent approximately 1 token and receives a share worth approximately 1.5 tokens. The victim deposited almost 2 tokens but receives a share worth approximately 1.5 tokens.

**The victim loses approximately 0.5 token in this specific scenario.**

This is a simplified demonstration of share-price inflation through direct donations and rounding.

## The mitigation

`SafeVault` uses virtual assets and virtual shares in its conversion formulas.

The constants are:

```solidity
uint256 private constant VIRTUAL_SHARES = 1000;
uint256 private constant VIRTUAL_ASSETS = 1;
```

The share conversion formula is:

```solidity
shares = Math.mulDiv(
    assetsReceived,
    totalShares + VIRTUAL_SHARES,
    assetsBefore + VIRTUAL_ASSETS
);
```

The virtual values affect the exchange-rate calculation without requiring actual tokens or shares to be deposited.

### Results in the tested scenario

| Metric | VulnerableVault | SafeVault |
|---|---:|---:|
| Attacker's initial deposit | 1 wei | 1 wei |
| Direct donation | 1 token | 1 token |
| Victim's deposit | 2 tokens − 1 wei | 2 tokens − 1 wei |
| Victim's shares | 1 | 3,999 |
| Approximate victim loss | 0.5 token | 0.00016669445 token |

For `SafeVault`, the attacker's initial deposit and donation together cost approximately 1 token, while the value of the attacker's shares after the victim's deposit is approximately 0.50008334722 token.

These figures are specific to the test inputs and the vault's share-to-asset conversion. They are not universal guarantees for every token, deposit size, or vault configuration.

## Implementation details

### VulnerableVault

- Calculates shares using the vault's actual token balance.
- Does not account for virtual assets or virtual shares.
- Demonstrates how direct donations can change the exchange rate.
- Uses `SafeERC20` for token transfers.
- Uses `ReentrancyGuard` on deposit and redemption entry points.

### SafeVault

- Uses virtual assets and virtual shares in conversion calculations.
- Uses `Math.mulDiv` for full-precision multiplication and division.
- Uses `SafeERC20` for token transfers.
- Accounts for the actual amount received during deposits, which is relevant for fee-on-transfer tokens.
- Uses `ReentrancyGuard` on deposit and redemption entry points.

## Test coverage

The current test suite contains **22 tests**, including a fuzz test configured for **1,000 runs**.

The tests cover:

- The donation attack against `VulnerableVault`.
- The mitigation behavior of `SafeVault`.
- Fuzz testing of the demonstrated attack scenario.
- Zero-address constructor validation.
- Deposit and redemption behavior.
- Rejection of transfers that return `false`.
- Zero-value deposit and redemption behavior.
- Fee-on-transfer token accounting.
- Share and asset conversion calculations.
- Specific reentrancy attempts during deposits and redemptions.

### Fuzz test scope

`testFuzz_safeVault_attackerNeverProfits` checks the attacker's outcome across generated donation and victim-deposit values within the bounds defined in the test.

This is evidence about the tested attack model. It is **not** a proof that the vault is secure against every possible attack or token implementation.

### Coverage results

The latest recorded `forge coverage` run reported:

| Contract / file | Lines | Statements | Branches | Functions |
|---|---:|---:|---:|---:|
| `MockToken.sol` | 100% | 100% | — | 100% |
| `SafeVault.sol` | 100% | 100% | 100% | 100% |
| `VulnerableVault.sol` | 100% | 100% | 100% | 100% |
| `DonationAttack.t.sol` | 78.57% | 81.40% | 100% | 76.47% |
| **Total** | **89.19%** | **91.40%** | **100%** | **87.10%** |

Coverage measures which code paths were exercised by the tests. It does not establish the absence of vulnerabilities.

## Requirements

- Foundry
- Solidity compiler 0.8.24
- Git with submodule support

The project uses:

- OpenZeppelin Contracts v5.7.0
- forge-std v1.17.0

Dependency revisions are recorded in `foundry.lock`.

## Run locally

Clone the repository with its submodules:

```bash
git clone --recurse-submodules https://github.com/HesamQorbani/erc4626-donation-attack-lab.git
cd erc4626-donation-attack-lab
```

Build:

```bash
forge build
```

Run tests:

```bash
forge test -vv
```

Check formatting:

```bash
forge fmt --check
```

Run the linter:

```bash
forge lint
```

Generate a coverage report:

```bash
forge coverage
```

## Known limitations

This project is an educational lab, not a complete ERC-4626 implementation.

- It does not implement the complete ERC-4626 interface, including the standard `deposit(uint256,address)`, `mint`, `withdraw`, `preview*`, and `max*` functions.
- The fuzz test focuses on one defined donation-attack scenario; it is not a comprehensive invariant-testing system.
- The reentrancy tests cover specific nested deposit attempts, not every possible malicious token behavior.
- Fee-on-transfer behavior is tested, but rebasing tokens and arbitrary malicious tokens are not comprehensively tested.
- `convertToShares` is a quote based on the current vault state. The actual shares minted by `SafeVault.deposit` depend on the amount received by the vault.
- For fee-on-transfer tokens, the amount received by a redeemer can be lower than the gross amount calculated by the vault.
- The contracts do not provide a minimum-shares-out parameter for deposit slippage protection.
- `MockToken` allows unrestricted minting and is intended for testing only.

## Security disclaimer

The project demonstrates a specific vulnerability pattern and a mitigation technique. It is not a security audit, production vault, or recommendation to deploy these contracts with real assets.

A production implementation would require a much broader review of token compatibility, rounding behavior, access control, economic assumptions, edge cases, and the complete ERC-4626 specification.

## Author

**Hesam Qorbani**

- GitHub: [HesamQorbani](https://github.com/HesamQorbani)
- Project repository: [erc4626-donation-attack-lab](https://github.com/HesamQorbani/erc4626-donation-attack-lab)

---

*Built as a Solidity and Foundry learning project to study vault share accounting, donation attacks, rounding behavior, token interactions, and mitigation techniques.*