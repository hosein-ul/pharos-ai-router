---
name: omnichain-usdc-router
description: >
  Conversational cross-chain USDC router for AI agents. Bridges native Circle
  USDC between Pharos Network and 6 major EVM chains via CCTP V2, and swaps
  tokens on Pharos via Faroswap. Use whenever a user says "bridge X USDC from
  <chain> to <chain>", "swap X for Y on Pharos", "convert PROS to USDC on Base",
  "send my USDC to Arbitrum", or "check status of my bridge". Supports
  multi-hop intents (swap then bridge). Read-only on the safe path: every
  cast send is preceded by a balance/allowance/policy check.
version: 0.1.0
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
---

# omnichain-usdc-router

This skill turns natural-language transfer intents into verified, multi-step on-chain executions.

## What this skill is

A composition layer over three primitives that already exist on-chain:

1. **Circle CCTP V2** — native USDC burn-and-mint across chains, zero protocol fee on Standard Transfer, official Pharos support as domain 31.
2. **Faroswap** — Pharos's native DEX (DODO PMM fork) for on-chain swaps.
3. **Native gas tokens** — PROS on Pharos, ETH on EVM majors, used only for the source-side gas of each transaction.

This skill does **not** implement its own contracts. It uses uniform CCTP V2 addresses (CREATE2-deployed everywhere) and Faroswap's published router. All addresses are in `assets/`.

## Supported corridors

| Source | Destination | Mechanism | Native Token Needed |
|---|---|---|---|
| Pharos USDC | Ethereum / Base / Arbitrum / Optimism / Polygon / Avalanche USDC | CCTP V2 Standard | PROS on Pharos (source gas), ETH/AVAX/POL on destination (mint gas) |
| Ethereum / Base / Arbitrum / Optimism / Polygon / Avalanche USDC | Pharos USDC | CCTP V2 Standard | Source-chain native (burn gas), PROS on Pharos (mint gas) |
| PROS ↔ USDC / USDT / WETH on Pharos | — | Faroswap mixSwap | PROS for gas |
| PROS on Pharos | USDC on any supported chain | Swap (Faroswap) + Bridge (CCTP) | PROS + destination gas |

## Capability Index

The agent reads user intent, matches it to a row below, and loads the linked reference for exact command templates.

| User Intent | Action | Reference |
|---|---|---|
| "bridge N USDC from pharos to \<chain\>" | CCTP burn on Pharos → mint on dest | [references/02-cctp-bridge-out.md](references/02-cctp-bridge-out.md) |
| "bridge N USDC from \<chain\> to pharos" | CCTP burn on src → mint on Pharos | [references/03-cctp-bridge-in.md](references/03-cctp-bridge-in.md) |
| "send my USDC to \<chain\>" | Read source from wallet, route via CCTP | [references/02-cctp-bridge-out.md](references/02-cctp-bridge-out.md) |
| "swap X for Y on pharos" | Faroswap router via DODO Route API | [references/04-faroswap-swap.md](references/04-faroswap-swap.md) |
| "convert PROS to USDC on \<chain\>" | Faroswap then CCTP, chained | [references/06-multi-hop.md](references/06-multi-hop.md) |
| "where are my USDC?" | Multi-chain balance read | [references/01-intent-routing.md](references/01-intent-routing.md#balance-discovery) |
| "check status of tx 0x..." | Poll Iris, finish receiveMessage if pending | [references/07-status-and-recovery.md](references/07-status-and-recovery.md) |
| "my bridge is stuck" | Resume from burn-tx-hash, retry receive | [references/07-status-and-recovery.md](references/07-status-and-recovery.md#stuck-bridge) |
| "what's the route for X→Y?" | Dry-run quote, no spend | [references/01-intent-routing.md](references/01-intent-routing.md#dry-run) |
| "is it safe to send this tx?" | Pipe through pharos-tx-guardrail | [references/08-safety-integration.md](references/08-safety-integration.md) |

## How the agent picks a path

```
user intent
   │
   ▼
parse: (action, source_chain, dest_chain, token_in, token_out, amount, recipient)
   │
   ├── action == "bridge" and token_in == token_out == "USDC" ────► CCTP path
   │       └── source == "pharos" ? 02-cctp-bridge-out : 03-cctp-bridge-in
   │
   ├── action == "swap" and source == dest == "pharos" ───────────► 04-faroswap-swap
   │
   ├── action == "convert" and (source != dest or token_in != token_out)
   │       └── needs swap AND bridge ────────────────────────────► 06-multi-hop
   │
   ├── action == "status" / "check" ──────────────────────────────► 07-status-and-recovery
   │
   └── action == "balance" / "where" ─────────────────────────────► 01-intent-routing#balance-discovery
```

Full decision tree and parameter extraction: [references/01-intent-routing.md](references/01-intent-routing.md).

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
│   └── faroswap.json        ← Faroswap router + DODO API config
├── references/
│   ├── 01-intent-routing.md
│   ├── 02-cctp-bridge-out.md
│   ├── 03-cctp-bridge-in.md
│   ├── 04-faroswap-swap.md
│   ├── 05-attestation-poll.md
│   ├── 06-multi-hop.md
│   ├── 07-status-and-recovery.md
│   └── 08-safety-integration.md
└── evals/
    └── evals.json
```

## Companion skills

- [pharos-tx-guardrail](https://github.com/hosein-ul/pharos-tx-guardrail) — pre-execution security checks (6-check pipeline)
- [pharos-rwa-yield-router](https://github.com/hosein-ul/pharos-rwa-yield-router) — read live APY, compose post-bridge deposit intents

## Versioning

`0.1.0` — Pharos ↔ 6 EVM CCTP V2 chains + Faroswap swap + multi-hop + recovery. USDC only.

Future: USDT/WETH bridging via LayerZero, Relay.link integration for non-CCTP routes, Fast Transfer when Circle enables on Pharos.
