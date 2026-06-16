# Reference 11 — Route discovery (what's possible right now?)

When the user asks open-ended questions like:

- "what can I do with my PROS?"
- "which chains can I bridge to from Pharos?"
- "is USDC bridgable to Hyperliquid?"
- "show me all routes from Pharos to Base"

…the agent uses this file to discover available corridors **live** from LI.FI's API instead of guessing from a hardcoded list.

This is the **read-only inspection layer**. It never signs or sends. It produces a menu the agent then offers to the user, who then picks one and triggers the actual execution flow ([10-route-selection.md](10-route-selection.md)).

---

## 1. Discover supported chains

```bash
LIFI_BASE="https://li.quest/v1"
curl -s "$LIFI_BASE/chains?chainTypes=EVM" \
  | python -c "
import sys, json
chains = json.load(sys.stdin).get('chains', [])
mainnets = [c for c in chains if c.get('mainnet', True)]
print(f'LI.FI supports {len(mainnets)} EVM mainnets')
print()
print(f'{\"key\":8} {\"id\":8} {\"name\"}')
for c in sorted(mainnets, key=lambda c: c.get('id', 0)):
    print(f'{c.get(\"key\",\"?\"):8} {c.get(\"id\",0):<8} {c.get(\"name\",\"?\")}')
"
```

Use this when the user asks "what chains does this skill support?" or before quoting an unfamiliar destination.

## 2. Discover tokens on a given chain

```bash
CHAIN_ID="${1:-1672}"   # default: Pharos
curl -s "$LIFI_BASE/tokens?chains=$CHAIN_ID" \
  | python -c "
import sys, json
tokens = json.load(sys.stdin).get('tokens', {}).get('$CHAIN_ID', [])
print(f'{len(tokens)} tokens on chain $CHAIN_ID via LI.FI')
print()
for t in tokens:
    print(f\"  {t.get('symbol','?'):10} {t.get('address','?'):42} dec={t.get('decimals','?')}\")
"
```

Example for Pharos (1672):
```
6 tokens on chain 1672 via LI.FI
  PROS       0x0000000000000000000000000000000000000000  dec=18
  USDCe      0x7126C3FeF4e6a680eeE09Fb039B2236F638384B0  dec=6
  USDC       0xC879C018dB60520F4355C26eD1a6D572cdAC1815  dec=6
  LINK       0x51e2A24742Db77604B881d6781Ee16B5b8fcBE29  dec=18
  WETH       0x1f4b7011Ee3d53969bb67F59428a9ec0477856E9  dec=18
  WPROS      0x52C48d4213107b20bC583832b0d951FB9CA8F0B0  dec=18
```

## 3. Discover bridges & exchanges active on a chain

```bash
curl -s "$LIFI_BASE/tools?chains=$CHAIN_ID" \
  | python -c "
import sys, json
d = json.load(sys.stdin)
print('bridges:  ', [b['key'] for b in d.get('bridges',[])])
print('exchanges:', [e['key'] for e in d.get('exchanges',[])])
"
```

For Pharos as of 2026-06-16:
```
bridges:   ['glacis', 'gasZipBridge', 'polymer', 'polymerStandard', 'lifiIntents']
exchanges: ['fly', 'lifiIntentsDex']
```

## 4. Probe a corridor — is X→Y on (chain A → chain B) supported?

The fastest answer is a sample `/quote`. If it returns a `transactionRequest`, the corridor is live.

```bash
probe_corridor() {
  local SRC_CHAIN="$1"     # e.g. 1672
  local DST_CHAIN="$2"     # e.g. 8453
  local SRC_TOKEN="$3"     # symbol like PROS or address
  local DST_TOKEN="$4"
  local PROBE_AMOUNT="${5:-1000000000000000000}"   # 1 unit of an 18-dec token
  local FROM="${6:-0x0000000000000000000000000000000000000001}"

  local URL="$LIFI_BASE/quote?fromChain=$SRC_CHAIN&toChain=$DST_CHAIN&fromToken=$SRC_TOKEN&toToken=$DST_TOKEN&fromAmount=$PROBE_AMOUNT&fromAddress=$FROM"
  curl -s "$URL" | python -c "
import sys, json
d = json.load(sys.stdin)
if 'message' in d:
    print('NO  -', d.get('message','')[:120])
else:
    e = d.get('estimate', {})
    print(f'YES - tool={d.get(\"tool\")} exec={e.get(\"executionDuration\")}s')
"
}

# Examples
probe_corridor 1672 8453   PROS  USDC                # PROS → USDC on Base
probe_corridor 1672 8453   PROS  USDT0               # PROS → USDT0 on Base
probe_corridor 1672 137    PROS  POL                 # PROS → POL on Polygon
probe_corridor 1672 43114  PROS  USDC                # PROS → USDC on Avalanche (likely NO)
```

## 5. Bulk discovery — "what can I do with my PROS?"

The agent should not run dozens of probes blindly. Use the **manually-verified matrix** in `assets/lifi.json` → `pharos_pros_supported_corridors`, then probe the **specific** corridor the user picks.

```bash
python <<EOF
import json
data = json.load(open('assets/lifi.json'))
corridors = data['pharos_pros_supported_corridors']['PROS_corridors']

print('Verified PROS corridors from Pharos (bidirectional):')
print()
print(f'{"chain":12} | {"counter-tokens"}')
print('-' * 70)
for chain, tokens in corridors.items():
    print(f'{chain:12} | {", ".join(tokens)}')
print()
print('Widest coverage:', data['pharos_pros_supported_corridors']['_widest_coverage_chain'])
EOF
```

Tell the user: "Pick a chain and a target token from this list, and I'll get a live quote." Then drop into [10-route-selection.md](10-route-selection.md).

## 6. Discover all routes between two chains (advanced)

The `/advanced/routes` endpoint returns multiple route options for a transfer, sorted by LI.FI's own preference. Useful when the agent wants to show the user 3–5 alternatives in one call.

```bash
curl -s -X POST "$LIFI_BASE/advanced/routes" \
  -H "Content-Type: application/json" \
  -d "{
    \"fromChainId\": 1672,
    \"toChainId\": 8453,
    \"fromTokenAddress\": \"0x0000000000000000000000000000000000000000\",
    \"toTokenAddress\": \"USDC\",
    \"fromAmount\": \"1000000000000000000\",
    \"fromAddress\": \"$SENDER\"
  }" \
  | python -c "
import sys, json
d = json.load(sys.stdin)
routes = d.get('routes', [])
print(f'{len(routes)} routes found')
for i, r in enumerate(routes[:5], 1):
    steps = r.get('steps', [])
    tools = ' → '.join(s.get('toolDetails',{}).get('name', s.get('tool','?')) for s in steps)
    e = r.get('toAmount','?')
    print(f'{i}. {tools}  out={e}')
"
```

## 7. When to use which discovery call

| User intent | Use |
|---|---|
| "what chains?" | §1 chains list |
| "what tokens on X?" | §2 tokens on chain |
| "what can I do with my PROS?" | §5 matrix from `assets/lifi.json` + suggest probes |
| "is X→Y supported?" | §4 single probe |
| "all routes from A to B" | §6 advanced/routes |
| ready to actually move funds | hand off to [10-route-selection.md](10-route-selection.md) |
