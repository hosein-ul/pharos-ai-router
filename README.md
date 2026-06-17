# pharos-ai-router

**Conversational cross-chain routing for AI agents on the Pharos Network ecosystem.**

Tell your agent in plain language. It bridges native Circle USDC between Pharos and 6 EVM majors via CCTP V2, swaps tokens on Pharos via Faroswap, and uses LI.FI for non-USDC bridges and atomic cross-chain swaps (e.g. **5 PROS on Pharos → USDC on Base in ~13 seconds** via LI.FI Intents).

The agent picks the cheapest route automatically: CCTP V2 for USDC pairs (zero fee), LI.FI for everything else, Faroswap for on-Pharos swaps.

[![Pharos Network](https://img.shields.io/badge/Pharos-Mainnet%201672-6B4FFF?style=flat-square)](https://pharos.xyz)
[![CCTP V2](https://img.shields.io/badge/Circle-CCTP%20V2%20Domain%2031-00C2A8?style=flat-square)](https://developers.circle.com/cctp/cctp-supported-blockchains)
[![LI.FI](https://img.shields.io/badge/LI.FI-Pharos%20(phr)-FFB800?style=flat-square)](https://li.quest/v1/chains)
[![Hackathon](https://img.shields.io/badge/AI%20Agent%20Carnival-Phase%201-FF6B35?style=flat-square)](https://dorahacks.io/hackathon/pharos-phase1/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)

---

## What it does

Turn a user message like

> "bridge 10 USDC from pharos to base"

into a verified, multi-step execution:

```
Bridged 10 USDC pharos → base
  burn:        0xabc...  (pharos)
  attestation: ready in 9m 42s
  mint:        0xdef...  (base)
  recipient:   0xRecipient...
  new balance: 110.00 USDC on base
```

Other intents the agent handles:

- `"send my 50 USDC to my arbitrum wallet"` — implicit source chain
- `"swap 5 PROS to USDC"` — Faroswap on Pharos
- `"convert 2 PROS to USDC on Polygon"` — multi-hop (swap then bridge)
- `"where are my USDC?"` — multi-chain balance read
- `"check status of 0xabc123"` — stuck-bridge recovery
- `"is it safe to send this?"` — pipes through `pharos-tx-guardrail`

---

## Why this exists

Two earlier skills in this set — [`pharos-tx-guardrail`](https://github.com/hosein-ul/pharos-tx-guardrail) and [`pharos-rwa-yield-router`](https://github.com/hosein-ul/pharos-rwa-yield-router) — are **read-only or local-only**. They don't give an agent the power to **move value across chains**, which is the heart of agentic-economy use cases (A2A payments, treasury management, cross-chain yield).

This skill closes that gap by composing four existing primitives instead of reinventing anything:

| Primitive | Role | Verified |
|---|---|---|
| **Circle CCTP V2** | Native USDC burn-and-mint across chains, zero fee | ✅ Pharos = domain 31, `0x28b5a0e9...` deployed |
| **LI.FI** | Universal cross-chain router for non-USDC and cross-chain swaps | ✅ Pharos = chain key `phr`, Diamond `0xFf70F4A1...` deployed, 6 tokens routed |
| **Faroswap** (DODO PMM fork) | On-Pharos same-chain swaps | ✅ Router `0xA5cA5Fbe...`, `mixSwap` selector confirmed |
| **Pharos's native Circle USDC** | The asset itself | ✅ `0xc879c018...`, `masterMinter()` confirms Circle FiatTokenProxy |

---

## Supported corridors

CCTP V2 (USDC ↔ USDC, zero fee, ~8–15 min) is bidirectional between Pharos and the 6 CCTP V2 mainnets:

| USDC corridor | Mechanism | Time | Fee |
|---|---|---|---|
| Pharos USDC ↔ Ethereum / Base / Arbitrum / Optimism / Polygon / Avalanche USDC | **CCTP V2 Standard** | 8–15 min | **$0** |

LI.FI covers cross-chain swaps and non-USDC bridges between Pharos and a **specific list of chain-token pairs** (manually verified — re-confirm at runtime via `/quote`):

| Pharos ↔ \<chain\> | Counter-tokens supported (bidirectional) | Mechanism |
|---|---|---|
| Ethereum | USDC, WETH, ETH | LI.FI Polymer / Intents |
| Polygon | USDC, USDT, ETH, POL | LI.FI Polymer / Intents |
| Arbitrum | USD0, USDC, ETH | LI.FI Polymer / Intents |
| **Base** ⭐ widest | USDT, USDT0, USDC, ETH | **LI.FI Intents** (atomic, ~13 sec) |
| HyperEVM | USDT0, USDC, HYPE | LI.FI Polymer / Intents |
| Ink | USDT0, USDC, WETH | LI.FI Polymer / Intents |
| Optimism | USDC, USDT0, ETH | LI.FI Polymer / Intents |

Faroswap handles same-chain swaps on Pharos via DODO `mixSwap`:

| Same-chain Pharos swap | Mechanism | Time | Fee |
|---|---|---|---|
| PROS ↔ USDC / USDT / WETH (and other Pharos tokens) | **Faroswap mixSwap** | seconds | DEX fee |

**Note:** LI.FI does **not** support every PROS pair on every chain. Avalanche, for example, has no LI.FI PROS route as of last check. The agent always re-verifies a corridor with `/quote` before execution — the matrix above is a fast hint, not a guarantee. The corresponding `assets/lifi.json` → `pharos_pros_supported_corridors` is the authoritative source for the agent.

Pharos does **not** yet support CCTP Fast Transfer; Standard Transfer takes 8–15 min depending on source-chain finality. For users in a hurry on USDC pairs, LI.FI's Polymer route (~18 min, ~0.25%) or LI.FI Intents (seconds, where available) are the alternatives the agent quotes in parallel.

---

## Install (one prompt, any AI agent)

This skill is **installed by the AI agent itself**, not by you. Copy the block below and paste it into Claude code (web / desktop/ terminal), Codex, Cursor, Windsurf, Openclaw, Hermes Cline, or any other AI agent that can run shell commands. It works the same everywhere.

> Install the Pharos Agent Skills from these GitHub repos:
>
> 1. `https://github.com/hosein-ul/pharos-skills` — contains two skills: `pharos-tx-guardrail` and `pharos-rwa-yield-router`.
> 2. `https://github.com/hosein-ul/pharos-ai-router` — the cross-chain skill.
> 
> Then read each `SKILL.md` and each repo's `references/00-bootstrap.md`. Install any tools you need yourself (don't ask me — just do it; everything required is open-source and free). When you're ready, tell me what you can help me do.
>
> Wait for my confirmation before broadcasting any blockchain transaction.

That's it. The agent handles cloning, installing Foundry's `cast` if it's missing, picking the right RPC endpoints — all of it. You shouldn't need to know what those words mean.

By default, if `AGENT_PRIVATE_KEY` is missing, the agent will generate a fresh key for you automatically using `cast wallet new`, save it to `.env` in the skill's root directory, print the address, and instruct you to fund it.

Alternatively, you can manually set `AGENT_PRIVATE_KEY` in your environment:

```bash
export AGENT_PRIVATE_KEY=0x<your dedicated agent wallet private key>
```

Or write it to `.env` directly. Treating the agent address as a hot wallet is highly recommended: fund it minimally and sweep it after tasks are complete. Full wallet model: [`references/13-wallet-and-security.md`](references/13-wallet-and-security.md). Optional extras: `DODO_API_KEY` (Faroswap quotes), `LIFI_API_KEY` (higher rate limit). Neither is needed for normal use.

---

## Quick reference

### Bridge 1 USDC from Pharos to Base

```bash
# Load constants
PHAROS_RPC=$(jq -r '.networks.pharos.rpcUrl' assets/networks.json)
BASE_RPC=$(jq -r '.networks.base.rpcUrl'     assets/networks.json)
USDC_PHAROS=$(jq -r '.usdc.pharos.address'   assets/tokens.json)
TM=$(jq -r '.domains.pharos.tokenMessenger'  assets/cctp-domains.json)
MT_BASE=$(jq -r '.domains.base.messageTransmitter' assets/cctp-domains.json)
RECIPIENT=$(cast wallet address $AGENT_PRIVATE_KEY)

# 1. Approve
cast send $USDC_PHAROS "approve(address,uint256)" $TM 1000000 \
  --rpc-url $PHAROS_RPC --private-key $AGENT_PRIVATE_KEY

# 2. Burn (CCTP V2 7-arg signature)
BURN_TX=$(cast send $TM \
  "depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)" \
  1000000 6 "0x000000000000000000000000${RECIPIENT:2}" $USDC_PHAROS \
  "0x0000000000000000000000000000000000000000000000000000000000000000" 0 2000 \
  --rpc-url $PHAROS_RPC --private-key $AGENT_PRIVATE_KEY --json \
  | python -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")

# 3. Poll Iris (8-15 min)
while true; do
  RESP=$(curl -s "https://iris-api.circle.com/v2/messages/31/$BURN_TX")
  STATUS=$(echo "$RESP" | python -c "import sys,json; print(json.load(sys.stdin).get('messages',[{}])[0].get('status','none'))")
  [ "$STATUS" = "complete" ] && break
  sleep 5
done
MSG=$(echo "$RESP" | python -c "import sys,json; print(json.load(sys.stdin)['messages'][0]['message'])")
ATT=$(echo "$RESP" | python -c "import sys,json; print(json.load(sys.stdin)['messages'][0]['attestation'])")

# 4. Mint on Base
cast send $MT_BASE "receiveMessage(bytes,bytes)" $MSG $ATT \
  --rpc-url $BASE_RPC --private-key $AGENT_PRIVATE_KEY
```

Full templates in [`references/02-cctp-bridge-out.md`](references/02-cctp-bridge-out.md).

### Cross-chain swap: 5 PROS on Pharos → USDC on Base (LI.FI Intents, ~13 sec)

```bash
SENDER=$(cast wallet address $AGENT_PRIVATE_KEY)

QUOTE=$(curl -s "https://li.quest/v1/quote?fromChain=1672&toChain=8453&fromToken=PROS&toToken=USDC&fromAmount=5000000000000000000&fromAddress=$SENDER")

TO=$(echo $QUOTE   | python -c "import sys,json; print(json.load(sys.stdin)['transactionRequest']['to'])")
DATA=$(echo $QUOTE | python -c "import sys,json; print(json.load(sys.stdin)['transactionRequest']['data'])")
VAL=$(echo $QUOTE  | python -c "import sys,json; print(json.load(sys.stdin)['transactionRequest'].get('value','0'))")

cast send $TO $DATA --value $VAL \
  --rpc-url https://rpc.pharos.xyz --private-key $AGENT_PRIVATE_KEY

# Poll LI.FI status (settles in ~13 sec for Intents)
curl "https://li.quest/v1/status?txHash=$TX&bridge=lifiIntents&fromChain=1672&toChain=8453"
```

Full template in [`references/09-lifi-bridge.md`](references/09-lifi-bridge.md).

### Swap 0.5 PROS to USDC on Pharos

```bash
SENDER=$(cast wallet address $AGENT_PRIVATE_KEY)
DEADLINE=$(python -c "import time; print(int(time.time()) + 1800)")
USDC=$(jq -r '.usdc.pharos.address' assets/tokens.json)

URL="https://api.dodoex.io/route-service/v2/widget/getdodoroute"
URL="$URL?chainId=1672&fromTokenAddress=0x0000000000000000000000000000000000000000"
URL="$URL&toTokenAddress=$USDC&fromAmount=500000000000000000&slippage=1"
URL="$URL&userAddr=$SENDER&deadLine=$DEADLINE&apikey=$DODO_API_KEY"

RESP=$(curl -s "$URL")
TO=$(echo $RESP | python -c "import sys,json; print(json.load(sys.stdin)['data']['to'])")
DATA=$(echo $RESP | python -c "import sys,json; print(json.load(sys.stdin)['data']['data'])")
VAL=$(echo $RESP | python -c "import sys,json; print(json.load(sys.stdin)['data'].get('value','0'))")

cast send $TO $DATA --value $VAL \
  --rpc-url https://rpc.pharos.xyz --private-key $AGENT_PRIVATE_KEY
```

Full templates in [`references/04-faroswap-swap.md`](references/04-faroswap-swap.md).

---

## File structure

```
pharos-ai-router/
├── SKILL.md                          ← agent entry point + Capability Index
├── assets/
│   ├── networks.json                 ← 7 chains: RPC + chain ID + explorer
│   ├── tokens.json                   ← USDC addresses (Circle-verified) + native + wrapped
│   ├── cctp-domains.json             ← CCTP V2 domain IDs + uniform CREATE2 addresses
│   ├── faroswap.json                 ← Router + DODO Route API config
│   └── lifi.json                     ← LI.FI endpoints + Pharos tokens + bridges
├── references/
│   ├── 01-intent-routing.md          ← intent parser + decision tree + balance discovery
│   ├── 02-cctp-bridge-out.md         ← Pharos → other chain, end-to-end
│   ├── 03-cctp-bridge-in.md          ← other chain → Pharos, end-to-end
│   ├── 04-faroswap-swap.md           ← Pharos-internal swap (API + fallback)
│   ├── 05-attestation-poll.md        ← Iris polling logic
│   ├── 06-multi-hop.md               ← chained swap+bridge (manual)
│   ├── 07-status-and-recovery.md     ← resume from tx hash, decode message, retry mint
│   ├── 08-safety-integration.md      ← optional pipe through pharos-tx-guardrail
│   ├── 09-lifi-bridge.md             ← LI.FI quote / sign / status / Intents / recovery
│   └── 10-route-selection.md         ← CCTP vs LI.FI decision rules + comparison
└── evals/
    └── evals.json                    ← 8 manual eval scenarios
```

---

## Verified contract addresses

### CCTP V2 (CREATE2-uniform across all chains)

| Contract | Address |
|---|---|
| TokenMessengerV2 | `0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d` |
| MessageTransmitterV2 | `0x81D40F21F12A8F0E3252Bccb954D722d4c464B64` |

Verified on-chain via `eth_getCode` on: Pharos, Ethereum, Base, Avalanche, Polygon, Optimism. Identical bytecode (4352 chars) confirms deterministic deployment.

### USDC (Circle FiatTokenProxy)

| Chain | Address | Decimals |
|---|---|---|
| Pharos | `0xc879c018db60520f4355c26ed1a6d572cdac1815` | 6 |
| Ethereum | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | 6 |
| Base | `0x833589fCD6eDb6E08f4c7C32A07bb15d2176aB5f` | 6 |
| Arbitrum | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | 6 |
| Optimism | `0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85` | 6 |
| Polygon | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` | 6 |
| Avalanche | `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E` | 6 |

### Faroswap (Pharos mainnet)

| Contract | Address | Note |
|---|---|---|
| Router | `0xA5cA5Fbe34e444F366B373170541ec6902b0F75c` | `mixSwap` selector `0x0a5ea466` confirmed |

### LI.FI (Pharos mainnet)

| Contract | Address | Note |
|---|---|---|
| LI.FI Diamond | `0xFf70F4A1d11995621854F3692acF286d8aCd04b2` | proxy; quote `transactionRequest.to` points here |

LI.FI bridge providers on Pharos: `glacis`, `gasZipBridge`, `polymer`, `polymerStandard`, `lifiIntents`. Same-chain exchanges: `fly`, `lifiIntentsDex`.

LI.FI tokens on Pharos (live from `GET https://li.quest/v1/tokens?chains=1672`):
| Symbol | Address | Decimals |
|---|---|---|
| PROS (native) | `0x0000000000000000000000000000000000000000` | 18 |
| USDC | `0xC879C018dB60520F4355C26eD1a6D572cdAC1815` | 6 |
| USDCe | `0x7126C3FeF4e6a680eeE09Fb039B2236F638384B0` | 6 |
| LINK | `0x51e2A24742Db77604B881d6781Ee16B5b8fcBE29` | 18 |
| WETH | `0x1f4b7011Ee3d53969bb67F59428a9ec0477856E9` | 18 |
| WPROS | `0x52C48d4213107b20bC583832b0d951FB9CA8F0B0` | 18 |

### CCTP Domain IDs

| Domain | Chain |
|---|---|
| 0 | Ethereum |
| 1 | Avalanche |
| 2 | Optimism |
| 3 | Arbitrum |
| 6 | Base |
| 7 | Polygon |
| 31 | **Pharos** |

---

## How the agent reasons

```
user message
     │
     ▼
┌──────────────────────┐
│ 01-intent-routing.md │   parse: (action, src, dst, in, out, amount, recipient)
└──────────────────────┘
     │
     ├─ bridge?  ──► 02 or 03 ──► 05 (poll) ──► destination mint
     ├─ swap?    ──► 04
     ├─ convert? ──► 06 (chains 04 + 02)
     ├─ status?  ──► 07 (find chain, query Iris, decode message)
     └─ balance? ──► 01 §4 (loop balanceOf)
```

Every state-changing tx is preceded by a safety contract: balance check, allowance check (exact-amount, never max), gas check, optional pipe through `pharos-tx-guardrail`.

---

## Companion skills

- [pharos-tx-guardrail](https://github.com/hosein-ul/pharos-tx-guardrail) — pre-execution 6-check risk score; pipe every `cast send` through it
- [pharos-rwa-yield-router](https://github.com/hosein-ul/pharos-rwa-yield-router) — read live APY across Pharos protocols; compose "bridge into pharos, then deposit"

Workflow:

```
human intent → pharos-ai-router routes funds → pharos-tx-guardrail gates risk → pharos-rwa-yield-router picks vault → deposit
```

---

## Hackathon

[Pharos AI Agent Carnival — Phase 1](https://dorahacks.io/hackathon/pharos-phase1/)

## Routing model (v0.3.0)

**LI.FI-first.** Every intent always starts with a LI.FI `/quote`. CCTP V2 and Faroswap are quoted **in parallel** only when the intent type matches (USDC↔USDC with Pharos, or same-chain Pharos swap). All quotes are then ranked by `(executionDuration, fee, output)` and presented to the user with the recommendation marked. The user picks one — they always see the runners-up.

Why this order:
- **CCTP V2 only carries USDC** (Circle protocol). So it can only ever win USDC↔USDC corridors. It often does win them — zero protocol fee — but only there.
- **LI.FI** routes any token across 70+ chains, including atomic cross-chain swaps (PROS on Pharos → USDC on Base in ~13 sec via Intents).
- **Faroswap** is only useful for same-chain Pharos swaps.

Try it: `bash scripts/rank-routes.sh pharos base USDC USDC 10` returns the live ranked list.

Decision logic and presentation contract live in [`references/10-route-selection.md`](references/10-route-selection.md). Live discovery (chains, tokens, corridor probes) lives in [`references/11-route-discovery.md`](references/11-route-discovery.md).

### Verified PROS-from-Pharos corridors (LI.FI, bidirectional)

| Destination chain | Counter-tokens |
|---|---|
| Ethereum | USDC, WETH, ETH |
| Polygon | USDC, USDT, ETH, POL |
| Arbitrum | USD0, USDC, ETH |
| **Base** ⭐ | USDT, USDT0, USDC, ETH (widest coverage) |
| HyperEVM | USDT0, USDC, HYPE |
| Ink | USDT0, USDC, WETH |
| Optimism | USDC, USDT0, ETH |

`assets/lifi.json` carries this list. Always re-verify a specific corridor with `/quote` before execution — LI.FI's routing graph updates continuously.

## Versioning

`0.3.0` — **LI.FI-first routing** with parallel quoting and explicit ranking. Adds [11-route-discovery.md](references/11-route-discovery.md). Adds `scripts/rank-routes.sh` runtime helper.

`0.2.0` — added LI.FI integration: non-USDC bridges, atomic cross-chain swaps via Intents.

`0.1.0` — CCTP V2 + Faroswap + manual multi-hop. USDC only.

Future: Fast Transfer when Circle enables on Pharos · USDT cross-chain via LayerZero · ERC-4337 gasless flows · LI.FI MCP server integration.

## License

MIT
