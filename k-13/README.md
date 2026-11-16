# K-13 — BuildersV4 `createSubnet` Without an Admin Check: Subnet Spoofing

**Severity requested: Medium.**
**Target:** `BuildersV4` (`0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9`) on
Base — `createSubnet` (L329–352), `_validateSubnet` (L419–435).

## The bug

`createSubnet(Subnet, SubnetMetadata)` is `public` with no access
control. `_validateSubnet` only checks: name non-empty, `admin != 0`,
`claimAdmin != 0`, `withdrawLockPeriodAfterDeposit >=
minimalWithdrawLockPeriod`. It never checks `msg.sender ==
subnet_.admin`, and there is no consent from the address named as
admin. Anyone (fresh key, no privilege) can create a subnet with:

- `admin` = a trusted project's address (spoofed), a dead address
  (`0xdead`), or even the MOR token contract itself
  (`0x7431aDa8a591C955a994a21710752EF9b882b8e3`) — which can never call
  `editSubnet`/`claim` at all;
- `claimAdmin` = the attacker;
- `withdrawLockPeriodAfterDeposit` = `type(uint128).max` (no upper bound);
- `minimalDeposit` = 1 wei.

`claim()` lets `admin` **or** `claimAdmin` send the subnet's entire
`pendingRewards` to any receiver. `withdraw()` blocks all withdrawals
while `block.timestamp <= lastDeposit + lock` — with a max lock,
withdrawals revert forever.

## Measured impact (Base fork)

Victim deposits 100,000 MOR → after 1 day, 74.30 MOR pending →
attacker claims exactly **74.30 MOR**; victim withdraw reverts.
Principal locked: 100,000 MOR (~$71,074). Theft: 74.30 MOR/day
(~$52.80/day) per 100,000 MOR staked. Live scale: 2,975,767 MOR
(~$2.1M) staked across BuildersV4 subnets. The spoofed admin can
reclaim a spoofed subnet via `editSubnet`, but already-stolen rewards
are gone permanently and victims stay locked 7 more days; the
dead-admin and MOR-contract-admin variants can never be fixed by
anyone.

## Reproduction

```bash
forge install foundry-rs/forge-std --no-commit
forge test -vvv
# BuildersDeep.t.sol — 5 tests, fork Base block 58,009,450
# BuildersDeep2.t.sol — 12 tests, fork Base block 58,020,029
#   (includes the MOR-contract-admin variant and negative PoCs for
#   the 10 unprivileged edit paths and the claimable-inflation check)
```

Fork RPC: `https://base-rpc.publicnode.com`. Attacker, victim, and
spoofed admin are separate fresh keys; the tests assert the attacker
cannot `editSubnet` (proving no privilege) while still achieving the
impact.

## Triage note

This needs victims to stake into the attacker's subnet, but the
victims are not "compromised" (no leaked key / malicious approval) —
they perform a normal protocol action and check the name + admin
on-chain, yet lose because the protocol's own registry certifies a
fake admin. The program's front-running clause expressly allows PoCs
showing third-party loss, which this PoC demonstrates.
