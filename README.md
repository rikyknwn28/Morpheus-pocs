# Morpheus (mor.org) — Bug Bounty PoCs

Foundry proof-of-concept tests for 4 findings in Morpheus SmartContracts
(HEAD `07f6032`), submitted to `devs@mor.org`. Each folder is a standalone
Foundry project. All tests pass (17/17) with Foundry 1.9.0.

## Setup (per folder)

```bash
cd <finding>
forge install foundry-rs/forge-std --no-commit
forge test
```

Public RPC endpoints are used for the mainnet forks (no API key needed).

## Findings

### l2mr-01 — Critical — L2MessageReceiver sender check can never pass
`L2MessageReceiverFork.t.sol` — 3 tests. Live Arbitrum One fork at pinned
block 525696000, against the real deployed proxy
`0xd4a8ECcBe696295e68572A98b1aA70Aa9277d427`. The LayerZero v1 path is
`[receiver, sender]`, but the receiver extracts the "sender" as the first
20 bytes (its own address), so `require(sender_ == config.sender)` never
holds: every MOR mint fails into `failedMessages` and `retryMessage` always
reverts. The reversed-path control mints, proving the defect is exactly the
extraction. Real path: no mint + stored failed. Retry: reverts. Reversed
path: mints.

### diamond-01 — High — Session approval not bound to user
`MarketplaceDiamond.t.sol` (+ `src/IDiamond.sol`) — 6 tests. Base fork at
block 59607993. The provider-signed approval carries the intended user, but
`_extractProviderApproval` discards it and `_validateSession` never compares
it to `user_`, so anyone holding an (approval, signature) pair can front-run
and open the session as themselves.

### cp-01 — High — Donated yield inflates a small pool's share (profitable)
`DonationYieldShare.t.sol` — 4 tests. Ethereum mainnet fork at block
26450840. `DistributorV2` measures yield as raw token-balance growth, so a
direct donation counts as yield in full. Dominating the tiny USDT pool and
donating $400 of real aUSDT diverts ~40.7% of the window's MOR (attacker
pending 1,773 MOR vs 128 control, net +~$729/window, repeatable daily).
Distinct from Code4rena Aug 2025 Low [01] (same root cause, but that report
is about *forcing minting on a zero-yield day* with dust and no profit;
this is a *profitable cross-pool share theft*).

### bb-01 — Medium — Subnet admin can permanently lock all stakers' MOR
`BB01_AdminLock.t.sol` — 4 tests. Base fork at block 59,604,000. Raising
`withdrawLockPeriodAfterDeposit` after deposits exist makes
`lastDeposit + lock` overflow (`type(uint128).max`), so `withdraw()`
reverts with panic 0x11 forever. BuildersV4 holds ~3M MOR.

## Notes
- No live transactions were made; all PoCs run on local mainnet forks.
- `evm_version` is set explicitly per project (osaka/paris) because the
  forked contracts use post-Shanghai features.
