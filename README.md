# CheckpointHook

[![CI](https://github.com/tfrmma/checkpoint-hook/actions/workflows/ci.yml/badge.svg)](https://github.com/tfrmma/checkpoint-hook/actions/workflows/ci.yml)

A Uniswap v4 hook that combines sandwich-resistant swap execution with JIT-liquidity penalties in
a single pool-level MEV mitigation. Built on top of OpenZeppelin's `uniswap-hooks` library rather
than reimplementing either mechanism from scratch.

## Overview

CheckpointHook composes two independently reasoned-about MEV defenses:

**1. Sandwich resistance (sr-AMM).** The hook checkpoints the pool's `sqrtPriceX96` at the start of
every block and enforces that no swap within that block can fill at a price better than the
checkpoint. This breaks the atomicity a sandwich attacker depends on: the closing (backrun) leg
can never recover more value than was spent opening the position, because there is no price
improvement left to harvest within the same block.

This design comes from ["A Sandwich-Resistant AMM"](https://www.umbraresearch.xyz/writings/sandwich-resistant-amm)
(Umbra Research, 2024) and is implemented here via OpenZeppelin's `AntiSandwichHook`.

**2. JIT-liquidity resistance.** The sr-AMM paper explicitly identifies a bypass: an attacker can
add liquidity atomically around a victim's trade, collect the swap fee, and withdraw before the
block ends, all without exposure to the checkpoint mechanism. CheckpointHook closes this gap using
OpenZeppelin's `LiquidityPenaltyHook`, which withholds fee collection for positions modified within
a configurable block window and redistributes the withheld amount to LPs who were genuinely in
range.

### What this repository adds

The upstream library provides the two mechanisms as independent, composable building blocks. This
repository's contribution is:

- Combining both into a single hook contract, including the diamond-inheritance resolution
  required by Solidity when two base contracts share `BaseHook` as a common ancestor.
- A configurable policy for the value captured by the anti-sandwich mechanism: it is minted to the
  hook as an ERC-6909 claim and is either donated back to in-range liquidity providers (default)
  or routed to a governance-controlled treasury for later redemption.
- Governance and treasury management (`Ownable2Step`), with a dedicated `unlock`/`unlockCallback`
  flow for redeeming treasury claims into the underlying ERC-20.
- A `minTickSpacing` floor enforced at pool initialization, bounding the worst case of
  `AntiSandwichHook`'s tick-crossing loop (see Known limitations) by refusing to attach to pools
  below it in the first place.
- A test suite that includes a direct economic comparison: the identical sandwich-attack sequence
  run against a hook-protected pool and against a vanilla pool, demonstrating the mitigation's
  effect rather than asserting it in isolation.

## Why build on OpenZeppelin's `uniswap-hooks` instead of from scratch

`AntiSandwichHook` and `LiquidityPenaltyHook` were included in a scoped OpenZeppelin audit round
and are maintained against upstream Uniswap v4 changes. Re-deriving checkpoint timing, ERC-6909
claim accounting, and JIT fee-share math independently would mean re-establishing correctness
properties that an audit has already verified once, without adding value. The composition and fee
routing logic in this repository are new code and are not covered by that audit.

## Repository structure

```
src/
  CheckpointHook.sol                   Hook contract
script/
  DeployCheckpointHook.s.sol           CREATE2 / HookMiner deployment script
  DeployTimelock.s.sol                 TimelockController deployment + ownership handover
test/
  CheckpointHook.t.sol                 Unit and economic-simulation tests
  CheckpointHookTimelock.t.sol         Timelocked governance handover tests
  utils/
    CheckpointHookTestBase.sol         Shared test fixtures
```

## Getting started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Install dependencies

This repository ships source only. Dependencies are pulled via `forge install` rather than vendored
in the repo (roughly 100 MB of nested submodules otherwise). Run these inside a git repository
(`git init` first if you haven't already), `forge install` uses git submodules under the hood:

```bash
forge install foundry-rs/forge-std@v1.11.0
forge install OpenZeppelin/uniswap-hooks@v1.2.1
```

The second command recursively pulls `uniswap-hooks`' own pinned copies of `v4-core`,
`v4-periphery`, and `openzeppelin-contracts`, matching `foundry.toml`'s remappings. Use the exact
versions above, the hook is built and tested against them specifically.

### Build

```bash
forge build
```

### Test

```bash
forge test -vv
```

The suite covers 25 cases across two files, of which three form the core proof of the hook's effect:

| Test | Purpose |
|---|---|
| `test_sandwichAttack_isUnprofitableWithinSameBlock` | Runs a full frontrun, victim, backrun sequence against the protected pool with fixed trade sizes and asserts the attacker ends the block at a net loss. |
| `testFuzz_sandwichAttack_neverProfitable` | Same sequence, fuzzed across liquidity depth (1e17-1e26) and both trade sizes (1e10-3e18) over 1000 runs, each against a freshly deployed pool. Confirms the property holds generally rather than for one hand-picked set of numbers. |
| `test_baseline_sandwichAttack_isProfitableWithoutTheHook` | Runs the identical fixed-size sequence against an unprotected pool and asserts the attacker is profitable there, establishing the baseline the other two are measured against. |

The remaining tests cover governance access control, permission-flag encoding, the tick-spacing
guard, JIT-penalty donation, and normal swap execution. The timelocked governance handover has its
own file, `CheckpointHookTimelock.t.sol`.

## Deployment

```bash
export POOL_MANAGER=0x...          # target chain's Uniswap v4 PoolManager
export GOVERNANCE_ADDRESS=0x...    # recommended: a timelocked multisig, not an EOA
export TREASURY_ADDRESS=0x...
export BLOCK_NUMBER_OFFSET=5       # optional, JIT-protection window in blocks, defaults to 5
export MIN_TICK_SPACING=60         # optional, floor on pools this hook can attach to, defaults to 60

forge script script/DeployCheckpointHook.s.sol:DeployCheckpointHook \
  --rpc-url <RPC_URL> \
  --private-key <DEPLOYER_KEY> \
  --broadcast --verify
```

The script mines a CREATE2 salt via `HookMiner` so the deployed address encodes the hook's required
permission flags, and deploys through the canonical deterministic deployer
(`0x4e59b44847b379578588920cA78FbF26c0B4956C`), which must already be present on the target chain.

### Moving governance to a timelock

`GOVERNANCE_ADDRESS` above can be an EOA to start (simpler for testnets or an initial bootstrap),
but before real value is at risk, hand it off to an OpenZeppelin `TimelockController` so
`setTreasury`, `setFeeDestination`, and `setMinTickSpacing` all go through a mandatory delay.
`CheckpointHook` itself needed no changes for this, `Ownable2Step` already accepts any address as
owner, `TimelockController` is designed to be dropped in as one.

```bash
export HOOK_ADDRESS=0x...
export MIN_DELAY=172800            # 2 days, in seconds
export PROPOSERS=0x...,0x...       # must include the broadcaster to also schedule step 2 below
export EXECUTORS=0x0000000000000000000000000000000000000000   # open role, or a comma list

forge script script/DeployTimelock.s.sol:DeployTimelock \
  --rpc-url <RPC_URL> \
  --private-key <CURRENT_GOVERNANCE_KEY> \
  --broadcast
```

This is a two-step handover by design (`Ownable2Step` requires the new owner to accept, and a
timelock can only act through its own schedule/execute flow, there's no way to make it atomic).
The script deploys the timelock, calls `transferOwnership`, and if the broadcaster holds
`PROPOSER_ROLE`, schedules the `acceptOwnership()` call too. Once `MIN_DELAY` has elapsed, finish
it by calling `execute()` on the timelock with the same target/payload/predecessor/salt the script
logged, from any address holding `EXECUTOR_ROLE` (or anyone, if `EXECUTORS` was left open). After
that, `hook.owner()` is the timelock, and every governance change needs its own
schedule-wait-execute cycle.

## Known limitations

This is a mitigation, not a guarantee of zero MEV.

- **Block-boundary sandwiching.** A builder controlling two consecutive blocks, or colluding with
  the next block's builder, can place the frontrun and victim trade at the end of block *N* and the
  backrun at the start of block *N+1*, since the price checkpoint resets every block.
- **Single-direction protection.** `AntiSandwichHook` protects only the `!zeroForOne` direction, a
  documented limitation of the upstream library. Symmetric protection would roughly double
  `beforeSwap` gas cost, a tradeoff this repository does not take.
- **Tick-crossing loop, partially bounded.** `beforeSwap` iterates every initialized tick crossed
  since the last checkpoint, once per block. `minTickSpacing` (enforced at pool initialization,
  defaults to 60 in the deploy script) bounds the worst case by refusing to attach to pools with
  too small a spacing, but it reduces the risk rather than eliminating it: a large enough
  intra-block price move can still make that loop expensive even at a sane spacing. Lowering
  `minTickSpacing` via governance only affects pools initialized afterward, it can't retroactively
  change an existing pool's `tickSpacing`.
- **Wider intra-block price drift.** Reducing in-block arbitrage means this pool's price can drift
  further from the global reference price intra-block than a vanilla AMM would. Account for this
  when sourcing external price feeds from this pool.
- **Application-layer scope.** This does not replace private order flow or RPC-level protection for
  latency-sensitive flow, and does not mitigate attacks occurring entirely outside this AMM.

## Security status

This code has not undergone an independent, professional third-party audit. It builds on
OpenZeppelin's `uniswap-hooks` library, which underwent a scoped audit round covering the two base
mechanisms; the composition, fee-routing, and treasury logic in this repository are not covered by
that audit. Do not deploy with third-party funds at risk without an independent review.
.
## License

MIT
