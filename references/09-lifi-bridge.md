# Reference 09 — LI.FI bridge & cross-chain swap

LI.FI is a universal cross-chain router. It supports **Pharos mainnet** (chain ID 1672, key `phr`) with 6 tokens and 5 bridge providers. We use it for:

- Cross-chain **swaps** (e.g. PROS on Pharos → USDC on Base) atomically in ~13 seconds via **LI.FI Intents**
- Bridging **non-USDC** tokens (LINK, WETH, USDCe) between Pharos and 70+ chains
- Fallback when CCTP attestation is delayed

> For pure USDC ↔ USDC, **CCTP V2 is preferred** (zero fee). See [02-cctp-bridge-out.md](02-cctp-bridge-out.md) and [10-route-selection.md](10-route-selection.md) for the decision rule.

---

## 1. Endpoint & auth

```
Base URL: https://li.quest/v1
Auth:     none required for <200 reqs / 2 hours
          optional header: x-lifi-api-key: <key>   (200 reqs/minute)
```

LI.FI is **non-custodial**. The quote endpoint returns an unsigned `transactionRequest`; the agent signs and broadcasts it with `cast send`. LI.FI never holds the funds.

## 2. Discover what's possible

```bash
LIFI_BASE="https://li.quest/v1"

# What chains? confirm Pharos (1672, key "phr")
curl -s "$LIFI_BASE/chains" | python -c "
import sys, json
for c in json.load(sys.stdin).get('chains',[]):
    if c.get('id') == 1672:
        print('Pharos:', c.get('name'), 'key:', c.get('key'))
        break
"

# What tokens does LI.FI know on Pharos?
curl -s "$LIFI_BASE/tokens?chains=1672" | python -c "
import sys, json
for t in json.load(sys.stdin).get('tokens',{}).get('1672',[]):
    print(f'  {t[\"symbol\"]:10} {t[\"address\"]:42} dec={t[\"decimals\"]}')
"

# What bridge providers serve Pharos?
curl -s "$LIFI_BASE/tools?chains=1672" | python -c "
import sys, json
d = json.load(sys.stdin)
print('bridges:  ', [b['key'] for b in d.get('bridges',[])])
print('exchanges:', [e['key'] for e in d.get('exchanges',[])])
"
```

The expected output is captured in `assets/lifi.json` for reference, but the live API is the source of truth — call it before each session if the agent needs current tool availability.

## 3. Get a quote (the canonical call)

```bash
# Required
FROM_CHAIN="${1:?source chain id, e.g. 1672 for Pharos}"
TO_CHAIN="${2:?destination chain id, e.g. 8453 for Base}"
FROM_TOKEN="${3:?symbol or address, e.g. PROS or 0xC879...}"
TO_TOKEN="${4:?symbol or address, e.g. USDC}"
FROM_AMOUNT="${5:?raw amount in smallest unit}"
FROM_ADDRESS="${6:-$(cast wallet address $AGENT_PRIVATE_KEY)}"

# Optional
SLIPPAGE="${7:-0.005}"   # 0.5%

URL="https://li.quest/v1/quote"
URL="$URL?fromChain=$FROM_CHAIN"
URL="$URL&toChain=$TO_CHAIN"
URL="$URL&fromToken=$FROM_TOKEN"
URL="$URL&toToken=$TO_TOKEN"
URL="$URL&fromAmount=$FROM_AMOUNT"
URL="$URL&fromAddress=$FROM_ADDRESS"
URL="$URL&slippage=$SLIPPAGE"

HEADERS=()
[ -n "$LIFI_API_KEY" ] && HEADERS=(-H "x-lifi-api-key: $LIFI_API_KEY")

QUOTE=$(curl -s "${HEADERS[@]}" "$URL")

# Sanity check
echo "$QUOTE" | python -c "
import sys, json
d = json.load(sys.stdin)
if 'message' in d:
    print('LI.FI ERROR:', d.get('message'))
    print('code:', d.get('code'))
    sys.exit(2)

print('Route:')
print(f'  tool:           {d.get(\"tool\")} ({d.get(\"toolDetails\",{}).get(\"name\")})')
e = d.get('estimate',{})
print(f'  toAmount:       {e.get(\"toAmount\")}  (min {e.get(\"toAmountMin\")})')
print(f'  exec time:      {e.get(\"executionDuration\")} sec')
print(f'  fees:           {sum(float(f.get(\"amountUSD\",0)) for f in e.get(\"feeCosts\",[]))} USD')
print(f'  gas (src):      {sum(float(g.get(\"amountUSD\",0)) for g in e.get(\"gasCosts\",[]))} USD')
print()
tr = d.get('transactionRequest',{})
print('TX to sign:')
print(f'  to:      {tr.get(\"to\")}')
print(f'  value:   {tr.get(\"value\",\"0\")} wei')
print(f'  data:    ({len(tr.get(\"data\",\"\"))} chars)')
print(f'  chainId: {tr.get(\"chainId\")}')
print(f'  gasLimit: {tr.get(\"gasLimit\")}')
"
```

## 4. Approve (only when `fromToken` is ERC-20, not native)

```bash
FROM_ADDR_OF_TOKEN=$(echo "$QUOTE" | python -c "import sys,json; d=json.load(sys.stdin); print(d.get('action',{}).get('fromToken',{}).get('address',''))")
SPENDER=$(echo "$QUOTE" | python -c "import sys,json; print(json.load(sys.stdin)['transactionRequest']['to'])")
AMOUNT_RAW=$(echo "$QUOTE" | python -c "import sys,json; print(json.load(sys.stdin)['action']['fromAmount'])")

if [ "$FROM_ADDR_OF_TOKEN" != "0x0000000000000000000000000000000000000000" ]; then
  ALLOW=$(cast call "$FROM_ADDR_OF_TOKEN" "allowance(address,address)(uint256)" "$FROM_ADDRESS" "$SPENDER" --rpc-url "$RPC")
  ALLOW_INT=$(python -c "print(int('$ALLOW'.split()[0]))")
  if [ "$ALLOW_INT" -lt "$AMOUNT_RAW" ]; then
    cast send "$FROM_ADDR_OF_TOKEN" "approve(address,uint256)" "$SPENDER" "$AMOUNT_RAW" \
      --rpc-url "$RPC" --private-key "$AGENT_PRIVATE_KEY"
  fi
fi
```

> **Approve exactly `AMOUNT_RAW`, never `MAX_UINT256`.** The skill scopes allowance per quote.

## 5. Sign & broadcast

```bash
TO=$(echo "$QUOTE"   | python -c "import sys,json; print(json.load(sys.stdin)['transactionRequest']['to'])")
DATA=$(echo "$QUOTE" | python -c "import sys,json; print(json.load(sys.stdin)['transactionRequest']['data'])")
VAL=$(echo "$QUOTE"  | python -c "import sys,json; print(json.load(sys.stdin)['transactionRequest'].get('value','0'))")
GAS=$(echo "$QUOTE"  | python -c "import sys,json; print(json.load(sys.stdin)['transactionRequest'].get('gasLimit','0'))")

TX=$(cast send "$TO" "$DATA" --value "$VAL" --gas-limit "$GAS" \
  --rpc-url "$RPC" --private-key "$AGENT_PRIVATE_KEY" --json \
  | python -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")

echo "  source tx: $TX"
TOOL=$(echo "$QUOTE" | python -c "import sys,json; print(json.load(sys.stdin)['tool'])")
echo "  bridge:    $TOOL"
```

## 6. Poll `/status`

```bash
poll_lifi_status() {
  local TX="$1"
  local TOOL="$2"
  local FROM_CHAIN="$3"
  local TO_CHAIN="$4"
  local MAX_ATTEMPTS="${5:-90}"   # 90 * 10s = 15 min

  local URL="https://li.quest/v1/status?txHash=$TX&bridge=$TOOL&fromChain=$FROM_CHAIN&toChain=$TO_CHAIN"
  local A=0
  while [ "$A" -lt "$MAX_ATTEMPTS" ]; do
    local R
    R=$(curl -s "$URL")
    local S SU
    S=$(echo  "$R" | python -c "import sys,json; print(json.load(sys.stdin).get('status','?'))")
    SU=$(echo "$R" | python -c "import sys,json; print(json.load(sys.stdin).get('substatus','?'))")
    case "$S" in
      DONE)
        if [ "$SU" = "COMPLETED" ]; then
          local RX
          RX=$(echo "$R" | python -c "import sys,json; d=json.load(sys.stdin); print(d.get('receiving',{}).get('txHash',''))")
          echo "  COMPLETED  dest tx: $RX"
          return 0
        elif [ "$SU" = "PARTIAL" ]; then
          echo "  PARTIAL: received different token, see status response"
          echo "$R" | python -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('receiving',{}), indent=2))"
          return 0
        elif [ "$SU" = "REFUNDED" ]; then
          echo "  REFUNDED to source"
          return 3
        fi
        ;;
      FAILED)
        echo "  FAILED: $(echo "$R" | python -c "import sys,json; print(json.load(sys.stdin).get('substatusMessage','no detail'))")"
        return 4
        ;;
      PENDING|NOT_FOUND)
        printf "  status=%s sub=%s attempt %d/%d\n" "$S" "$SU" "$((A+1))" "$MAX_ATTEMPTS"
        ;;
    esac
    A=$((A+1))
    sleep 10
  done
  echo "  TIMEOUT after $MAX_ATTEMPTS attempts"
  return 2
}

poll_lifi_status "$TX" "$TOOL" "$FROM_CHAIN" "$TO_CHAIN"
```

## 7. Worked examples

### A) Plain bridge: USDC Pharos → USDC Base via Polymer

```bash
# 10 USDC, ~18 min, 0.25% fee (vs CCTP V2 free + 8-15 min)
QUOTE=$(curl -s "https://li.quest/v1/quote?fromChain=1672&toChain=8453&fromToken=USDC&toToken=USDC&fromAmount=10000000&fromAddress=$SENDER")
# tool: polymerStandard
# If you want LI.FI to skip a specific bridge, pass &denyBridges=polymerStandard
```

### B) Cross-chain swap (the LI.FI Intents superpower)

```bash
# 5 PROS on Pharos → USDC on Base — atomic, ~13 sec
QUOTE=$(curl -s "https://li.quest/v1/quote?fromChain=1672&toChain=8453&fromToken=PROS&toToken=USDC&fromAmount=5000000000000000000&fromAddress=$SENDER")
# tool: lifiIntents
# steps: PROS→USDC via Fly (Pharos DEX), then USDC→USDC via Intents bridge
```

### C) Force a specific bridge

```bash
# Avoid Polymer, use Glacis instead
URL="$URL&denyBridges=polymerStandard,polymer"
# Or explicitly allow only one
URL="$URL&allowBridges=glacis"
```

## 8. Edge cases & errors

| LI.FI says | Why | What to do |
|---|---|---|
| `Could not find token '0xabc' on chain 'N'` | Address not in LI.FI registry | Use the canonical symbol (`USDC`), or fetch `/tokens?chains=N` first |
| `No available quotes for the requested transfer` | No route between these tokens/chains | Suggest a different bridge target (e.g. swap to USDC first on source, then bridge) |
| `code: 1011 — slippage too low` | Default 0.5% too tight | Re-quote with `slippage=0.01` (1%) and warn user |
| `429 Too Many Requests` | Hit free-tier rate limit | Backoff exponentially, or set `LIFI_API_KEY` env var |
| status stuck at `PENDING` 30+ min | Bridge provider issue | Switch to `/status` with `tool` query later; consider CCTP V2 fallback for USDC pairs |
| status returns `DONE + PARTIAL` | Destination swap leg failed; user got bridged-form (e.g. USDCe instead of USDC) | Report the actual received token; offer to swap it via [04-faroswap-swap.md](04-faroswap-swap.md) if it landed on Pharos |
| status returns `DONE + REFUNDED` | Bridge failed safely | Funds back on source chain — re-attempt with different route |

## 9. Recovery — "my LI.FI bridge is stuck"

```bash
# User supplies the source tx hash + bridge tool name
LIFI_STATUS_URL="https://li.quest/v1/status?txHash=$TX&bridge=$TOOL&fromChain=$SRC&toChain=$DST"
curl -s "$LIFI_STATUS_URL" | python -m json.tool
```

LI.FI tracks the cross-chain hop itself; the agent does **not** need to call `receiveMessage` like CCTP. If status reaches `DONE`, the destination tx hash is in `receiving.txHash`.

## 10. Report

```
Bridged via LI.FI (polymerStandard)
  source:  10.00 USDC on pharos
  tx (src): 0xabc...  (https://pharosscan.xyz/tx/0xabc)
  bridge:  Polymer (Standard), exec 18m 11s
  fees:    0.025 USD
  status:  DONE / COMPLETED
  receive: 9.975 USDC on base
  tx (dst): 0xdef...  (https://basescan.org/tx/0xdef)
```

For LI.FI Intents (atomic swaps):

```
Cross-chain swap via LI.FI Intents
  in:      5.0 PROS on pharos
  out:     2.7768 USDC on base
  steps:   PROS→USDC (Fly DEX) + USDC→USDC (Intents bridge)
  exec:    13 sec
  tx (src): 0xabc...  tx (dst): 0xdef...
```
