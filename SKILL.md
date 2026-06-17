---
name: pharos-ai-router
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
version: 0.4.0
requires:
  anyBins:
    - cast
    - curl
    - python
  autoInstall: true
  bootstrap: references/00-bootstrap.md
env:
  - name: AGENT_PRIVATE_KEY
    required: onBroadcast
    purpose: signing key for cast send. Never logged, never echoed. Only requested when the user actually asks to broadcast a tx — never on first install.
  - name: DODO_API_KEY
    required: false
    purpose: enables Faroswap route quotes via DODO Route API. If absent, swap falls back to direct router constructions for simple pairs only.
  - name: LIFI_API_KEY
    required: false
    purpose: raises LI.FI rate limit from 200 req / 2 hours to 200 req / minute. Skill works without it.
---

> **Agent**: before doing anything else, read [`references/00-bootstrap.md`](references/00-bootstrap.md). It tells you how to install `cast` yourself if it's missing, which RPC endpoints to use (no API keys), and what to tell the user after install. Do not ask the user for tool installation — handle it.


# pharos-ai-router

This skill turns natural-language transfer intents into verified, multi-step on-chain executions.

## What this skill is

A composition layer over four primitives that already exist on-chain:

1. **Circle CCTP V2** — native USDC burn-and-mint across chains, zero protocol fee on Standard Transfer, official Pharos support as domain 31. **Default route for USDC↔USDC.**
2. **LI.FI** — universal cross-chain router. Official Pharos support (chain key `phr`). Used for non-USDC bridges, atomic cross-chain swaps via LI.FI Intents (~13 sec), and Pharos coverage to 70+ chains beyond the 6 CCTP majors.
3. **Faroswap** — Pharos's native DEX (DODO PMM fork) for on-chain swaps.
4. **Native gas tokens** — PROS on Pharos, ETH on EVM majors, used only for source-side gas.

This skill does **not** implement its own contracts. It uses uniform CCTP V2 addresses (CREATE2-deployed everywhere), the LI.FI Diamond on Pharos, and Faroswap's published router. All addresses are in `assets/`.

## Supported corridors

**CCTP V2** — USDC ↔ USDC, zero fee, bidirectional between Pharos and 6 mainnets:

| USDC corridor | Mechanism | Time | Fee |
|---|---|---|---|
| Pharos USDC ↔ Ethereum / Base / Arbitrum / Optimism / Polygon / Avalanche USDC | CCTP V2 Standard | 8–15 min | $0 |

**LI.FI** — non-USDC bridges and cross-chain swaps. Coverage is **chain-token specific**, not "any token to any chain". Verified bidirectional pairs from Pharos:

| Pharos ↔ \<chain\> | Counter-tokens (bidirectional) |
|---|---|
| Ethereum | USDC, WETH, ETH |
| Polygon | USDC, USDT, ETH, POL |
| Arbitrum | USD0, USDC, ETH |
| **Base** ⭐ widest coverage | USDT, USDT0, USDC, ETH |
| HyperEVM | USDT0, USDC, HYPE |
| Ink | USDT0, USDC, WETH |
| Optimism | USDC, USDT0, ETH |

Avalanche has **no** LI.FI PROS route at this time. Other pairs not listed should be re-verified with `/quote` before assumption.

**Faroswap** — same-chain swaps on Pharos via DODO `mixSwap`:

| Same-chain swap | Mechanism | Time |
|---|---|---|
| PROS ↔ USDC / USDT / WETH (and other Pharos tokens) | Faroswap mixSwap | seconds |

The agent quotes all applicable providers in parallel and ranks by speed, fee, and output. See [references/10-route-selection.md](references/10-route-selection.md) for the decision logic. The matrix above is the **starting hint** — the source of truth at runtime is `assets/lifi.json` → `pharos_pros_supported_corridors` + a live `/quote` call.

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
| **"what can I do with my PROS?"** | Live discovery via LI.FI + Pharos matrix | [11-route-discovery.md](references/11-route-discovery.md) |
| **"which chains can I bridge to?"** | LI.FI /chains live query | [11-route-discovery.md](references/11-route-discovery.md#1-discover-supported-chains) |
| **"is X→Y supported?"** | Single probe via LI.FI /quote | [11-route-discovery.md](references/11-route-discovery.md#4-probe-a-corridor) |
| **"give me cheapest / fastest / max output"** | Re-rank by user's adjective | [10-route-selection.md](references/10-route-selection.md#8-speed-vs-fee-priorities) |

## How the agent picks a path — LI.FI-first

**Important architectural rule:** LI.FI is the universal default. CCTP V2 and Faroswap are specialized add-on quotes that the agent fetches *in parallel* when the intent type matches. The agent then ranks all returned quotes by speed → fee → output, and shows the user the best option (plus runners-up so they can override).

```
parse intent (action, src, dst, token_in, token_out, amount)
        │
        ▼
┌───────────────────────────────────────────────────────────┐
│  STEP 1   Always quote LI.FI /quote                      │
│           — covers 95% of corridors including swaps      │
└───────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────┐
│  STEP 2   Add specialized quotes if intent matches:      │
│                                                           │
│    USDC↔USDC + Pharos    →  ALSO quote CCTP V2 (free)   │
│    same-chain Pharos     →  ALSO quote Faroswap         │
└───────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────┐
│  STEP 3   Rank all quotes:                               │
│           (executionDuration asc, fee asc, output desc)  │
└───────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────┐
│  STEP 4   Show ranked list to user, mark recommendation, │
│           wait for confirmation                          │
└───────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────┐
│  STEP 5   Execute the picked route                       │
│           LI.FI    → references/09-lifi-bridge.md        │
│           CCTP V2  → references/02 / 03                  │
│           Faroswap → references/04                       │
└───────────────────────────────────────────────────────────┘
```

Why LI.FI is default: it covers the broadest token + chain surface and returns ready-to-sign calldata. CCTP V2 wins specifically on USDC↔USDC (zero protocol fee), but only there. Faroswap matters only for same-chain Pharos swaps.

Discovery questions ("what can I do with my PROS?") go through [references/11-route-discovery.md](references/11-route-discovery.md) (read-only LI.FI inspection).

Full decision tree + parameter extraction: [references/01-intent-routing.md](references/01-intent-routing.md). Full route comparison + presentation contract: [references/10-route-selection.md](references/10-route-selection.md).

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
pharos-ai-router/
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
│   ├── 10-route-selection.md   ← LI.FI-first workflow + parallel quote + ranking + presentation
│   ├── 11-route-discovery.md   ← Live discovery: chains, tokens, tools, corridor probes
│   ├── 12-token-resolution.md  ← Anti-scam: symbol→address resolution + post-quote verification
│   └── 13-wallet-and-security.md ← Agent wallet model, env var, sweep policy, pre-flight
└── evals/
    └── evals.json
```

## Companion skills

- [pharos-tx-guardrail](https://github.com/hosein-ul/pharos-tx-guardrail) — pre-execution security checks (6-check pipeline)
- [pharos-rwa-yield-router](https://github.com/hosein-ul/pharos-rwa-yield-router) — read live APY, compose post-bridge deposit intents

## Versioning

`0.4.0` — **Hardened for mainnet**: adds canonical `assets/token-registry.json` (chain×symbol → checksummed address). `rank-routes.sh` now resolves user symbols to addresses locally, then verifies the LI.FI / DODO response uses the same addresses it sent (aborts on mismatch). Adds [12-token-resolution.md](references/12-token-resolution.md) (anti-scam pattern) and [13-wallet-and-security.md](references/13-wallet-and-security.md) (agent wallet model). Audit caught and corrected a wrong Base USDC address propagated from prior assets — the new flow would have caught it at quote time.

`0.3.0` — **LI.FI-first routing**: LI.FI is now the universal default; CCTP V2 and Faroswap are quoted in parallel only when the intent type matches (USDC↔USDC, same-chain Pharos). All quotes are ranked by (speed, fee, output) and presented to the user with the recommendation marked. Adds [11-route-discovery.md](references/11-route-discovery.md) for live discovery queries. Adds verified PROS-from-Pharos corridor matrix to `assets/lifi.json`.

`0.2.0` — added **LI.FI integration**: non-USDC bridges, atomic cross-chain swaps via Intents (PROS→USDC@Base in ~13 sec).

`0.1.0` — CCTP V2 + Faroswap + manual multi-hop. USDC only.

Future: Fast Transfer when Circle enables on Pharos · USDT cross-chain via LayerZero · ERC-4337 gasless flows.
