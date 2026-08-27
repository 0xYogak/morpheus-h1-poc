# Morpheus Capital — cross-pool emission capture in DistributorV2

Foundry mainnet-fork proof of concept for a Morpheus Bug Bounty submission.

## Target

| | |
|---|---|
| Contract | `Distributor` (proxy) `0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A` |
| Implementation | `0x52f76e8be3dfabcc3b0ded02882a22be47dade03` (`version() == 2`) |
| Chain | Ethereum mainnet |
| Fork block | 25837000 (timestamp 1787718551) |

## The bug

`distributeRewards` splits the fixed per-period MOR emission across the five deposit pools in
proportion to each pool's measured yield, where yield is `balanceOf(yieldToken) - lastUnderlyingBalance`
(`DistributorV2.sol:409-442`). The `yieldToken` is a freely transferable ERC20 — the Aave aToken for
AAVE-strategy pools, the deposit token otherwise. Any address can raise one pool's measured yield by
transferring that token to the Distributor, which redirects the fixed emission toward that pool and
away from every other pool's stakers. The total emission split is unchanged; only the distribution
across pools moves.

An attacker who holds a position in the donated pool captures the redirected emission on its own
stake. At a dominant stake this is net-positive: `test_attackerNetPositive_singlePeriod` shows a
10 WBTC stake plus a single 0.01 WBTC (~$788) donation captures 2486.8 extra MOR in one period,
worth ~$5,115 against the sunk donation, a net of ~$4,327 per period, repeatable each period. Because
`DepositPool.stake()` calls `distributeRewards()` before crediting the new deposit
(`DepositPool.sol:256-259`), the attacker cannot capture the currently open period on a fresh stake;
the minimal profitable attack stakes, waits one period, then donates once in that period.

## Reproduce

One command. The only setup is an Ethereum archive RPC that serves state at block 25837000.

```bash
git clone https://github.com/0xYogak/morpheus-h1-poc.git
cd morpheus-h1-poc
MAINNET_RPC_URL=<eth-archive-rpc> forge test -vv
```

`forge-std` is vendored under `lib/`, so no `forge install` step is needed. `evm_version` is pinned to
`cancun` in `foundry.toml`; `paris` makes the Aave aToken delegatecalls revert `NotActivated`.

## No privileged accounts

The attacker receives WBTC from a whale transfer, supplies it to the Aave v3 Pool for real aWBTC, then
calls only the public `transfer` / `stake` / `distributeRewards`. There is no owner, admin, or multisig
prank in the exploit path.

## Tests

| Test | What it proves |
|---|---|
| `test_pinnedBlockNoWarpNoMock_shareDiversion` | 2141.08 MOR diverted at the pinned block, no warp, no oracle mock |
| `test_attackerNetPositive_singlePeriod` | attacker nets ~$4,327/period profit (10 WBTC stake + 0.01 WBTC donation, single period) |
| `test_realStakersLoseClaimableMor` | 6 real stETH stakers lose 59.29% of their earnings for one period |
| `test_atomicBundle_permanentLoss_realVictims` | single-tx diversion; 15 named stETH stakers stay 245.22 MOR below the honest control after the following period |
| `test_noveltyControl_normalYieldDay_totalMintUnchanged` | total pool credits move 2 wei while the wBTC share moves 2141 MOR (distinct branch from Code4rena 2025-08 Low-01) |
| `test_donationCapturesEmissionShare` | a 1.0 WBTC donation takes 98.31% of one period's emission |
| `test_economicCalibrationAttack` | a small repeated donation captures extra MOR versus an identical no-donation control |
| `test_fullAttackLifecycleValueCapture` | full stake-donate-claim lifecycle |

`evidence.txt` is the raw `forge test -vv` output from a clean run at block 25837000.
