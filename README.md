# ERC-4626 Donation Attack Lab

A small Foundry project that shows the ERC-4626 "donation / inflation" attack and one way to fix it.

> Built while learning, with the help of an AI assistant (Claude). Simplified vaults, **not audited, not for production**.

## What is in here

| File | What it does |
|------|--------------|
| `src/VulnerableVault.sol` | Prices shares from the raw token balance. No protection. |
| `src/SafeVault.sol` | Same vault with virtual shares/assets (OpenZeppelin-style offset). |
| `test/DonationAttack.t.sol` | Exploit test, defence test, and a fuzz test. |

## The attack in plain words

1. The attacker deposits 1 wei and gets 1 share.
2. The attacker sends 1 token straight to the vault (a "donation"). One share is now worth about 1 token.
3. The victim deposits almost 2 tokens but gets only 1 share (division rounds down).
4. The pool holds ~3 tokens for 2 shares, so the victim's share is worth ~1.5 tokens.
   **Victim loses ~0.5 token. Attacker spent ~1 token and gets back ~1.5.**

## The fix

`SafeVault` adds virtual shares and assets to the price formula:

```
shares = assets * (totalShares + 1000) / (totalAssets + 1)
```

With this, the same attack costs the attacker about half of what they put in, and the victim loses less than 0.1%.

## Run it

```bash
git clone --recurse-submodules https://github.com/HesamQorbani/erc4626-donation-attack-lab.git
cd erc4626-donation-attack-lab
forge test -vv
```

## Limits (known)

- Simplified vaults: not full ERC-4626 (no `preview*`, `max*`, `mint`, `withdraw`).
- Only one attack path is tested. The fuzz test checks "the attacker never profits" for this specific attack.
- Planning to: add real invariant tests with a handler that can donate, and compare against OpenZeppelin's `ERC4626`.
