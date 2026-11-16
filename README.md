# Morpheus Bug Bounty — Proof-of-Concept Repositories

Two validated findings against the Morpheus smart contracts (program at
https://mor.org/bug-bounty, reports submitted by email to devs@mor.org).
Each folder is a standalone Foundry project; each test file only imports
`forge-std`.

## Findings

### 1. `cap-a1/` — DistributorV2 yield-share inflation via direct aToken donation (ask: High)

`DistributorV2.distributeRewards` measures each pool's yield as the raw
increase in `balanceOf(aToken)` / `balanceOf(stETH)` minus
`lastUnderlyingBalance`, without checking where the increase came from.
Anyone can transfer aToken/stETH directly to the Distributor, inflate a
target pool's yield, and divert a share of the fixed ~2,857 MOR/day
emission to that pool.

Measured on a mainnet fork (block 26,424,044): a $450/day aUSDT donation
with a $330,564 USDT stake (90% of the USDT pool) diverts 1,264 MOR/day
(~$898/day, ~$328k/year) from other stakers; attacker net +$359/day
(~$131k/year). A cheap route ($36,729 stake + $100/day donation) nets
+$73/day. Realized cash profit was verified via an on-chain QuoterV2
simulation on the deepest MOR pool (Arbitrum Uniswap V3, $636k
liquidity): net realized +$347.61/day (96.9% of mark-to-market), so the
High argument is cash-backed. Donation is sunk (swept to L1Sender);
stake is withdrawable.

### 2. `k-13/` — BuildersV4 `createSubnet` without an admin check: subnet spoofing (ask: Medium)

`BuildersV4.createSubnet` is `public` with no access control.
`_validateSubnet` never checks `msg.sender == subnet_.admin`, so anyone
can create a subnet with `admin` = a trusted project's address (or a
dead address, or even the MOR token contract itself), `claimAdmin` =
themselves, and `withdrawLockPeriodAfterDeposit` = `type(uint128).max`.
Victims staking into the spoofed subnet get their principal locked and
their rewards stolen via `claim()`.

Measured on a Base fork (block 58,009,450): victim deposits 100,000 MOR
→ 74.30 MOR pending after 1 day → attacker claims exactly 74.30 MOR;
victim withdraw reverts. Impact: 100,000 MOR (~$71,074) principal
locked; 74.30 MOR/day (~$52.80/day) stolen per 100,000 MOR staked.
Live scale: 2,975,767 MOR (~$2.1M) staked in BuildersV4.

## Reproduction

```bash
# CAP-A1 (Ethereum mainnet fork, block 26,424,044)
cd cap-a1
forge install foundry-rs/forge-std --no-commit
forge test -vvv   # 9 tests in the original suite + deep-dive suites

# K-13 (Base fork, blocks 58,009,450 and 58,020,029)
cd k-13
forge install foundry-rs/forge-std --no-commit
forge test -vvv   # 5 tests (BuildersDeep) + 12 tests (BuildersDeep2)
```

Both suites need RPC access to a public endpoint
(`https://eth.drpc.org` for CAP-A1, `https://base-rpc.publicnode.com`
for K-13); without it the fork setup fails. No protocol logic is
mocked — only external Chainlink feed answers are pinned in the CAP-A1
tests (see the test headers).

## Disclosure notes (also in the emailed reports)

- CAP-A1 shares a code area with C4 Low [01] (dust donation forcing a
  mint on a zero-yield day). It is substantively different: Low [01] is
  the `totalYield == 0` branch with no victim losing share; CAP-A1 is
  share inflation on a normal non-zero-yield day with measured victims
  and systematic quantified profit. The full comparison is in the
  emailed report.
- K-13 needs victims to stake into the attacker's subnet. The victims
  are not "compromised" (no leaked key / malicious approval) — they
  perform a normal protocol action and check the name + admin on-chain,
  yet lose because the protocol's own registry certifies a fake admin.
  The program's front-running clause expressly allows PoCs showing
  third-party loss, which this PoC demonstrates.
