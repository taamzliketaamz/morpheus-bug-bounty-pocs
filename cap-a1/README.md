# CAP-A1 — DistributorV2 Yield-Share Inflation via Direct aToken Donation

**Severity requested: High** (Medium-upper-end is the floor).
**Target:** `DistributorV2` (`0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A`,
impl V2) — `distributeRewards`, L700–748 & L771–782, Ethereum mainnet.

## The bug

`distributeRewards` measures each pool's yield as the raw increase in
`balanceOf(aToken)` / `balanceOf(stETH)` minus `lastUnderlyingBalance`,
without checking the source of the increase. Transferring aToken/stETH
directly to the Distributor counts as yield and inflates that pool's
share of the fixed ~2,857 MOR/day emission.

## Measured impact (mainnet fork, block 26,424,044)

| Scenario | Stake | Donation/day | MOR diverted/day | Attacker net/day |
|---|---|---|---|---|
| S09 (90% of USDT pool) | $330,564 USDT | $450 aUSDT | 1,264 MOR (~$898) | +$359 (~$131k/year) |
| S05 (50% of USDT pool) | $36,729 USDT | $100 aUSDT | ~244 MOR | +$73 (~$35k/year) |

A 100 stETH victim loses 12.01 MOR/day (−47%). Donation is sunk
(swept to L1Sender); stake is withdrawable (7-day lock, 14-day claim).
The same mechanism was proven for the stETH pool (10 stETH donation →
share 89.27% → 99.72%).

Cash-realized profit was verified with an on-chain QuoterV2 simulation
on the deepest MOR pool (Arbitrum Uniswap V3, $636,143 liquidity):
selling the extra 1,137.74 MOR costs 0.54%; net realized S09
+$347.61/day (96.9% of mark-to-market). Even a 14-day lump sum
(18,000 MOR) costs only 4.09%.

## Reproduction

```bash
forge install foundry-rs/forge-std --no-commit
forge test -vvv
# 9 tests: 7 scenarios (CapA1.t.sol) + 2 probes (Probe.t.sol, Probe2.t.sol)
# Deep-dive suites: DeepDive.t.sol (12 tests), DeepDive2.t.sol (5 tests)
```

Fork: Ethereum mainnet block **26,424,044**, RPC
`https://eth.drpc.org`. Only external Chainlink feed answers are pinned
(`vm.mockCall` on `getChainLinkDataFeedLatestAnswer`); no protocol
logic is mocked. Attacker and victim are ordinary `makeAddr`
addresses with no privilege.

## Why this is not C4 Low [01]

Low [01] is a ~$2 dust donation forcing a mint on a zero-yield day
(the `totalYield == 0` branch), with no victim losing share, and the
zero-yield window was proven unforceable. CAP-A1 is share inflation on
a normal non-zero-yield day, with measured victims (100 stETH staker
−47%) and systematic quantified profit (+$359/day, every day). Same
primitive, different substance — disclosed here so the triager can
judge the grouping risk (assessed medium–high) on the facts.
