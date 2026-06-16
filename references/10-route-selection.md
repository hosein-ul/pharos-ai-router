# Reference 10 — Route selection (LI.FI-first workflow)

This is **the** decision file. Every bridge/swap intent passes through this routing logic before any `cast send` happens.

The policy is simple: **LI.FI is the universal default**. CCTP V2 and Faroswap are specialized alternatives we quote *in addition* when the intent type matches. The agent collects all viable quotes, ranks them, and shows the user the best option (with the runners-up so they can override).

---

## 1. Why LI.FI-first?

| Provider | What it can do | What it can't |
|---|---|---|
| **LI.FI** | Any token ↔ any token across 70+ chains. Cross-chain swaps atomic via Intents. Aggregates Polymer, Glacis, gas.zip, Fly, etc. Returns ready-to-sign calldata. | Some Pharos pairs have no route (e.g. PROS → AVAX). Polymer USDC↔USDC corridor costs 0.25% vs CCTP's 0%. |
| **CCTP V2** | **ONLY USDC ↔ USDC.** Zero protocol fee. Official Circle. | No non-USDC tokens. No cross-chain swaps. ~8–15 min on Pharos (Standard Transfer only). |
| **Faroswap** | Same-chain Pharos swaps via DODO PMM. | Not cross-chain. ABI requires DODO Route API for non-trivial routes. |

LI.FI covers the broadest surface, so it's the first call. CCTP comes in **only** when both tokens are USDC and at least one side is Pharos. Faroswap comes in **only** when the user wants a same-chain Pharos swap.

---

## 2. The workflow (in order)

```
intent: {action, src_chain, dst_chain, token_in, token_out, amount, recipient}
   │
   ▼
┌──────────────────────────────────────────────────────────────┐
│ STEP 1 — Pre-checks                                          │
│   - balances on src_chain (token_in + native gas)            │
│   - recipient + amount valid                                 │
│   - if any fail: ABORT with reason                           │
└──────────────────────────────────────────────────────────────┘
   │
   ▼
┌──────────────────────────────────────────────────────────────┐
│ STEP 2 — Always quote LI.FI first                            │
│   GET https://li.quest/v1/quote                              │
│   Capture: tool, executionDuration, toAmount, feeCosts,      │
│            transactionRequest                                │
└──────────────────────────────────────────────────────────────┘
   │
   ▼
┌──────────────────────────────────────────────────────────────┐
│ STEP 3 — Conditionally quote specialized providers           │
│                                                              │
│   if token_in == token_out == "USDC"                         │
│      and ("pharos" in {src_chain, dst_chain}):              │
│        ALSO quote CCTP V2 (always available, zero fee)      │
│                                                              │
│   if src_chain == dst_chain == "pharos":                    │
│        ALSO quote Faroswap (via DODO API or direct router)  │
└──────────────────────────────────────────────────────────────┘
   │
   ▼
┌──────────────────────────────────────────────────────────────┐
│ STEP 4 — Rank all quotes                                     │
│   sort by: (executionDuration asc, totalFeeUSD asc,         │
│             toAmountMin desc)                                │
│   filter: must succeed (route exists, no FAILED state)       │
└──────────────────────────────────────────────────────────────┘
   │
   ▼
┌──────────────────────────────────────────────────────────────┐
│ STEP 5 — Present to user + ask confirmation                  │
│   show: ranked list with recommendation flag                 │
│   user picks: top one (default) or overrides                 │
└──────────────────────────────────────────────────────────────┘
   │
   ▼
┌──────────────────────────────────────────────────────────────┐
│ STEP 6 — Execute the chosen route                            │
│   LI.FI    → references/09-lifi-bridge.md                    │
│   CCTP V2  → references/02 / 03                              │
│   Faroswap → references/04                                   │
└──────────────────────────────────────────────────────────────┘
```

---

## 3. Worked example — "bridge 10 USDC from pharos to base"

This is the case where the agent has the **most options**.

```bash
SENDER=$(cast wallet address "$AGENT_PRIVATE_KEY")
AMOUNT_RAW=10000000   # 10 USDC, 6 decimals

# --- STEP 2: LI.FI ---
LIFI_RESP=$(curl -s "https://li.quest/v1/quote?fromChain=1672&toChain=8453&fromToken=USDC&toToken=USDC&fromAmount=$AMOUNT_RAW&fromAddress=$SENDER")
LIFI_TOOL=$(echo "$LIFI_RESP" | python -c "import sys,json; print(json.load(sys.stdin).get('tool','none'))")
LIFI_EXEC=$(echo "$LIFI_RESP" | python -c "import sys,json; print(json.load(sys.stdin).get('estimate',{}).get('executionDuration','?'))")
LIFI_OUT=$(echo  "$LIFI_RESP" | python -c "import sys,json; e=json.load(sys.stdin).get('estimate',{}); print(int(e.get('toAmount',0))/1e6)")
LIFI_FEE=$(echo  "$LIFI_RESP" | python -c "import sys,json; e=json.load(sys.stdin).get('estimate',{}); print(sum(float(f.get('amountUSD',0)) for f in e.get('feeCosts',[])))")

# --- STEP 3: CCTP V2 (token_in == token_out == USDC and pharos is involved → yes) ---
CCTP_EXEC_SEC=600   # ~10 min average, agent can refine via cast gas-price + estimate
CCTP_FEE=0          # protocol fee zero, gas only
CCTP_OUT=10.00      # full amount, no protocol fee

# --- STEP 4: rank ---
python <<EOF
routes = [
  {"name":"LI.FI ($LIFI_TOOL)",      "exec":$LIFI_EXEC, "fee":$LIFI_FEE, "out":$LIFI_OUT},
  {"name":"CCTP V2 Standard",         "exec":$CCTP_EXEC_SEC, "fee":$CCTP_FEE, "out":$CCTP_OUT},
]
ranked = sorted(routes, key=lambda r: (r['exec'], r['fee'], -r['out']))
for i, r in enumerate(ranked, 1):
    star = "  ★ recommended" if i == 1 else ""
    print(f"{i}. {r['name']:30}  exec {r['exec']/60:5.1f} min   fee \${r['fee']:.4f}   receive {r['out']:.2f} USDC{star}")
EOF
```

Typical output:
```
1. CCTP V2 Standard                exec  10.0 min   fee $0.0000   receive 10.00 USDC  ★ recommended
2. LI.FI (polymerStandard)         exec  18.0 min   fee $0.0250   receive  9.98 USDC
```

User confirms → run `references/02-cctp-bridge-out.md`.

If user says "use LI.FI instead" → run `references/09-lifi-bridge.md`.

---

## 4. Worked example — "swap 1 PROS for USDC on base"

CCTP can't help (input is PROS, not USDC). Faroswap can't help (cross-chain). LI.FI is the **only** route.

```bash
LIFI_RESP=$(curl -s "https://li.quest/v1/quote?fromChain=1672&toChain=8453&fromToken=PROS&toToken=USDC&fromAmount=1000000000000000000&fromAddress=$SENDER")
```

Returns `tool=lifiIntents`, `exec=13 sec`, expected ~0.55 USDC. Agent presents one route, executes via `references/09-lifi-bridge.md`.

---

## 5. Worked example — "swap 5 PROS for USDC on pharos"

Same chain, so LI.FI and Faroswap both apply. CCTP is out (input is PROS).

```bash
# LI.FI (will route through Fly DEX on Pharos via lifiIntentsDex)
LIFI_RESP=$(curl -s "https://li.quest/v1/quote?fromChain=1672&toChain=1672&fromToken=PROS&toToken=USDC&fromAmount=5000000000000000000&fromAddress=$SENDER")

# Faroswap (DODO Route API — needs $DODO_API_KEY)
if [ -n "$DODO_API_KEY" ]; then
  FW_RESP=$(curl -s "https://api.dodoex.io/route-service/v2/widget/getdodoroute?chainId=1672&fromTokenAddress=0x0000000000000000000000000000000000000000&toTokenAddress=0xc879c018db60520f4355c26ed1a6d572cdac1815&fromAmount=5000000000000000000&slippage=1&userAddr=$SENDER&deadLine=99999999&apikey=$DODO_API_KEY")
fi

# Rank and pick. Same-chain LI.FI is usually instant too. Compare output amounts.
```

---

## 6. Pharos PROS corridor table (manually verified)

LI.FI does NOT support every PROS pair. Use this as a quick hint, but **always re-verify with `/quote` at runtime** — coverage changes.

Bidirectional PROS support (Pharos ↔ chain):

| Destination chain | Supported counter-tokens |
|---|---|
| Ethereum | USDC, WETH, ETH |
| Polygon | USDC, USDT, ETH, POL |
| Arbitrum | USD0, USDC, ETH |
| **Base** ⭐ | USDT, USDT0, USDC, ETH (widest coverage) |
| HyperEVM | USDT0, USDC, HYPE |
| Ink | USDT0, USDC, WETH |
| Optimism | USDC, USDT0, ETH |

Source of truth: `assets/lifi.json` → `pharos_pros_supported_corridors`. Refresh via `references/11-route-discovery.md`.

---

## 7. When LI.FI returns no route

If LI.FI's `/quote` returns `code: 1011` ("No available quotes"):

```
Was the corridor USDC↔USDC and Pharos involved?
   ├── yes → use CCTP V2 (always works, never depends on LI.FI's routing graph)
   └── no  → report to user: "no cross-chain route for X→Y at this time"
              suggest alternatives:
                a) different destination token (e.g. ETH instead of WETH)
                b) two-hop: first swap to USDC on Pharos (Faroswap), then bridge
                c) wait — LI.FI adds routes regularly
```

---

## 8. Speed vs fee priorities

Default ranking is `(executionDuration asc, totalFeeUSD asc, toAmountMin desc)`.

The user can override:

| User said | Re-rank by |
|---|---|
| "cheapest" | `(totalFeeUSD asc, toAmountMin desc, executionDuration asc)` |
| "fastest" | `(executionDuration asc, …)` (default) |
| "max output" | `(toAmountMin desc, totalFeeUSD asc, executionDuration asc)` |
| "no fees" / "zero fee" | filter to fee == 0 first, then rank by speed |

Tell the agent: parse the user's adjective into a ranking, don't silently override.

---

## 9. The presentation contract

Whenever there are 2+ routes, the agent **must** show all of them ranked, with the recommendation marked. Format:

```
3 routes for 10 USDC pharos → base:

1. CCTP V2 Standard           exec  10 min   fee $0.00   receive 10.00 USDC  ★ recommended
   bridge contract: 0x28b5a0e9...  (Circle official)
2. LI.FI Polymer Standard     exec  18 min   fee $0.03   receive  9.98 USDC
   bridge contract: 0xFf70F4A1... (LI.FI Diamond)
3. LI.FI Intents              exec   2 min   fee $0.04   receive  9.96 USDC
   bridge contract: 0xFf70F4A1... (LI.FI Diamond)

Recommended: option 1 (free, official Circle path).
Reply "1" to proceed, or specify another option / "cancel".
```

Never silently pick. Always show the comparison.
