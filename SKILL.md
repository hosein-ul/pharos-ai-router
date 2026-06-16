---
name: omnichain-usdc-router
description: >
  Conversational cross-chain router for AI agents. Bridges native Circle USDC
  between Pharos Network and 6 major EVM chains via CCTP V2, swaps tokens on
  Pharos via Faroswap, and uses LI.FI for non-USDC bridges and atomic
  cross-chain swaps (e.g. PROS on Pharos to USDC on Base in ~13 seconds via
  LI.FI Intents). Use whenever a user says "bridge X USDC from <chain> to
  <chain>", "swap X for Y on Pharos", "convert PROS to USDC on Base", "send
  my USDC to Arbitrum", or "check status of my bridge". Picks the cheapest
  route automatically: CCTP V2 for USDC pairs (zero fee), LI.FI for everything
  else. Read-only on the safe path: every cast send is preceded by a
  balance / allowance / policy check.
version: 0.2.0
requires:
  anyBins:
    - cast
    - curl
    - python
env:
  - name: AGENT_PRIVATE_KEY
    required: true
    purpose: signing key for cast send. Never logged, never echoed.
  - name: DODO_API_KEY
    required: false
    purpose: enables Faroswap route quotes via DODO Route API. If absent, swap falls back to direct router constructions for simple pairs only.
  - name: LIFI_API_KEY
    required: false
    purpose: raises LI.FI rate limit from 200 req / 2 hours to 200 req / minute. Skill works without it.
---

# omnichain-usdc-router

This skill turns natural-language transfer intents into verified, multi-step on-chain executions.

## What this skill is

A composition layer over four primitives that already exist on-chain:

1. **Circle CCTP V2** — native USDC burn-and-mint across chains, zero protocol fee on Standard Transfer, official Pharos support as domain 31. **Default route for USDC↔USDC.**
2. **LI.FI** — universal cross-chain router. Official Pharos support (chain key `phr`). Used for non-USDC bridges, atomic cross-chain swaps via LI.FI Intents (~13 sec), and Pharos coverage to 70+ chains beyond the 6 CCTP majors.
3. **Faroswap** — Pharos's native DEX (DODO PMM fork) for on-chain swaps.
4. **Native gas tokens** — PROS on Pharos, ETH on EVM majors, used only for source-side gas.

This skill does **not** implement its own contracts. It uses uniform CCTP V2 addresses (CREATE2-deployed everywhere), the LI.FI Diamond on Pharos, and Faroswap's published router. All addresses are in `assets/`.

## Supported corridors

| Source | Destination | Mechanism | Time | Fee |
|---|---|---|---|---|
| Pharos USDC | Ethereum / Base / Arbitrum / Optimism / Polygon / Avalanche USDC | **CCTP V2 Standard** | 8–15 min | 0 |
| Ethereum / Base / Arbitrum / Optimism / Polygon / Avalanche USDC | Pharos USDC | **CCTP V2 Standard** | 8–15 min | 0 |
| PROS ↔ USDC / USDT / WETH on Pharos | — | **Faroswap mixSwap** | seconds | DEX |
| **PROS / LINK / WETH** on Pharos | **USDC / native** on any LI.FI-supported chain | **LI.FI Intents** (atomic swap+bridge) | ~13 sec to ~1 min | 0.1–0.3% |
| Any token | Any token (70+ chains via LI.FI) | **LI.FI** (Polymer / Glacis / Intents) | seconds–20 min | 0–0.3% |
| PROS on Pharos | USDC on any chain (manual mode) | Faroswap → CCTP, chained | 10–20 min | DEX + 0 |

The agent picks the cheapest viable route automatically; see [references/10-route-selection.md](references/10-route-selection.md).

## Capability Index

The agent reads user intent, matches it to a row below, and loads the linked reference for exact command templates.

| User Intent | Action | Reference |
|---|---|---|
| "bridge N USDC from pharos to \<chain\>" | CCTP V2 burn on Pharos → mint on dest | [02-cctp-bridge-out.md](references/02-cctp-bridge-out.md) |
| "bridge N USDC from \<chain\> to pharos" | CCTP V2 burn on src → mint on Pharos | [03-cctp-bridge-in.md](references/03-cctp-bridge-in.md) |
| "send my USDC to \<chain\>" | Pick CCTP V2 (cheapest), route via [02](references/02-cctp-bridge-out.md) | [02-cctp-bridge-out.md](references/02-cctp-bridge-out.md) |
| "swap X for Y on pharos" | Faroswap router via DODO Route API | [04-faroswap-swap.md](references/04-faroswap-swap.md) |
| **"convert PROS to USDC on \<chain\>"** | **LI.FI Intents (atomic, ~13s)** | [09-lifi-bridge.md](references/09-lifi-bridge.md) |
| **"swap PROS for USDC on Base"** | **LI.FI Intents** (single signature, cross-chain) | [09-lifi-bridge.md](references/09-lifi-bridge.md) |
| **"bridge LINK / WETH from \<chain\> to pharos"** | **LI.FI** (CCTP carries USDC only) | [09-lifi-bridge.md](references/09-lifi-bridge.md) |
| **"give me both routes"** / "compare routes" | Quote CCTP + LI.FI side-by-side | [10-route-selection.md](references/10-route-selection.md#quote-both) |
| "convert PROS to USDC on \<chain\> (manual)" | Faroswap then CCTP, chained | [06-multi-hop.md](references/06-multi-hop.md) |
| "where are my USDC?" | Multi-chain balance read | [01-intent-routing.md](references/01-intent-routing.md#balance-discovery) |
| "check status of CCTP tx 0x..." | Poll Iris, finish receiveMessage if pending | [07-status-and-recovery.md](references/07-status-and-recovery.md) |
| **"check status of LI.FI tx 0x..."** | **Poll LI.FI /status endpoint** | [09-lifi-bridge.md](references/09-lifi-bridge.md#poll-status) |
| "my bridge is stuck" | Resume from tx hash, retry receive or LI.FI status | [07-status-and-recovery.md](references/07-status-and-recovery.md#stuck-bridge) |
| "what's the route for X→Y?" | Dry-run quote, no spend | [01-intent-routing.md](references/01-intent-routing.md#dry-run) |
| "is it safe to send this tx?" | Pipe through pharos-tx-guardrail | [08-safety-integration.md](references/08-safety-integration.md) |

## How the agent picks a path

```
user intent
   │
   ▼
parse: (action, source_chain, dest_chain, token_in, token_out, amount, recipient)
   │
   ▼
route-selection (references/10-route-selection.md)
   │
   ├── same chain + swap ───────────────────────────────► 04-faroswap-swap
   │
   ├── USDC → USDC and one chain is pharos ─────────────► 02 or 03 (CCTP V2, zero fee)
   │
   ├── cross-chain token-flip (PROS↔USDC, LINK→USDC, …) ► 09-lifi-bridge (LI.FI Intents)
   │
   ├── non-USDC token bridge ───────────────────────────► 09-lifi-bridge
   │
   ├── status / check tx ───────────────────────────────► 07 (CCTP) or 09 (LI.FI)
   │
   └── balance / "where" ───────────────────────────────► 01#balance-discovery
```

Full decision tree and parameter extraction: [references/01-intent-routing.md](references/01-intent-routing.md). Full route comparison: [references/10-route-selection.md](references/10-route-selection.md).

## Safety contract

Before every state-changing `cast send`, the agent **must**:

1. Read sender balance for the token being moved. Abort if insufficient.
2. Read native gas balance on the source chain. Abort if cannot cover gas.
3. If approve is needed: read current allowance first. Skip approve if already sufficient.
4. Log the planned tx in a single human-readable line **before** sending: target, function, params, gas estimate, USD value (via Chainlink on Pharos, no oracle on EVM majors → use input amount).
5. Optionally pipe through `pharos-tx-guardrail` (see [08-safety-integration.md](references/08-safety-integration.md)).

## Network defaults

- Default source chain: `pharos` (from `assets/networks.json` → `defaultSource`)
- Default destination chain for outbound bridge: `base` (from `assets/networks.json` → `defaultDestination`)
- Standard Transfer is the only CCTP V2 mode supported on Pharos (Fast Transfer not yet available)
- Slippage default on Faroswap: 1% (100 bps)
- Swap deadline default: 30 minutes

## Files

```
omnichain-usdc-router/
├── SKILL.md                 ← you are here
├── assets/
│   ├── networks.json        ← RPC, chain ID, explorer per chain
│   ├── tokens.json          ← USDC addresses + decimals
│   ├── cctp-domains.json    ← CCTP V2 domain IDs + contract addresses + ABIs
│   ├── faroswap.json        ← Faroswap router + DODO API config
│   └── lifi.json            ← LI.FI endpoints + Pharos token/bridge registry
├── references/
│   ├── 01-intent-routing.md
│   ├── 02-cctp-bridge-out.md
│   ├── 03-cctp-bridge-in.md
│   ├── 04-faroswap-swap.md
│   ├── 05-attestation-poll.md
│   ├── 06-multi-hop.md
│   ├── 07-status-and-recovery.md
│   ├── 08-safety-integration.md
│   ├── 09-lifi-bridge.md       ← LI.FI quote / sign / status, with Intents and Polymer examples
│   └── 10-route-selection.md   ← CCTP vs LI.FI vs Faroswap decision rules
└── evals/
    └── evals.json
```

## Companion skills

- [pharos-tx-guardrail](https://github.com/hosein-ul/pharos-tx-guardrail) — pre-execution security checks (6-check pipeline)
- [pharos-rwa-yield-router](https://github.com/hosein-ul/pharos-rwa-yield-router) — read live APY, compose post-bridge deposit intents

## Versioning

`0.2.0` — adds **LI.FI integration**: non-USDC bridges to/from Pharos (LINK, WETH, USDCe, PROS), atomic cross-chain swaps via LI.FI Intents (PROS→USDC@Base in ~13 sec), route-selection logic that compares CCTP vs LI.FI per intent.

`0.1.0` — Pharos ↔ 6 EVM CCTP V2 chains + Faroswap swap + multi-hop (manual) + recovery. USDC only.

Future: Fast Transfer when Circle enables on Pharos · USDT cross-chain via LayerZero · ERC-4337 gasless flows.
