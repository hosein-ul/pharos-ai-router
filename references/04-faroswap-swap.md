# Reference 04 — Swap tokens on Pharos via Faroswap

Faroswap is Pharos's native DEX, a DODO PMM (Proactive Market Maker) fork. The router executes `mixSwap` calls whose parameters are built from a routing graph. There are two practical paths:

1. **DODO Route API** (recommended when `DODO_API_KEY` is set) — server returns ready-to-send calldata.
2. **Direct router** (fallback) — agent constructs a single-hop swap manually. Only works when an existing PMM pool exists for the pair.

---

## 0. Load constants

```bash
TOKEN_IN_SYM="${1:?usage: swap <in_sym> <out_sym> <amount>}"
TOKEN_OUT_SYM="${2:?}"
AMOUNT_IN="${3:?human-readable}"
SLIPPAGE_BPS="${4:-100}"   # default 1%

PHAROS_RPC=$(jq -r '.networks.pharos.rpcUrl' assets/networks.json)
ROUTER=$(jq -r '.router.address' assets/faroswap.json)

# Resolve token addresses + decimals from tokens.json / faroswap.json
case "$TOKEN_IN_SYM" in
  PROS|NATIVE) TOKEN_IN_ADDR="0x0000000000000000000000000000000000000000"; DEC_IN=18 ;;
  USDC) TOKEN_IN_ADDR=$(jq -r '.usdc.pharos.address' assets/tokens.json); DEC_IN=6 ;;
  USDT) TOKEN_IN_ADDR=$(jq -r '.stables_other.pharos.USDT' assets/tokens.json); DEC_IN=6 ;;
  WPHRS) TOKEN_IN_ADDR=$(jq -r '.wrapped.pharos.WPHRS' assets/tokens.json); DEC_IN=18 ;;
  WETH)  TOKEN_IN_ADDR=$(jq -r '.wrapped.pharos.WETH' assets/tokens.json); DEC_IN=18 ;;
  *) echo "Unknown input token: $TOKEN_IN_SYM"; exit 1 ;;
esac

case "$TOKEN_OUT_SYM" in
  PROS|NATIVE) TOKEN_OUT_ADDR="0x0000000000000000000000000000000000000000"; DEC_OUT=18 ;;
  USDC) TOKEN_OUT_ADDR=$(jq -r '.usdc.pharos.address' assets/tokens.json); DEC_OUT=6 ;;
  USDT) TOKEN_OUT_ADDR=$(jq -r '.stables_other.pharos.USDT' assets/tokens.json); DEC_OUT=6 ;;
  WPHRS) TOKEN_OUT_ADDR=$(jq -r '.wrapped.pharos.WPHRS' assets/tokens.json); DEC_OUT=18 ;;
  WETH)  TOKEN_OUT_ADDR=$(jq -r '.wrapped.pharos.WETH' assets/tokens.json); DEC_OUT=18 ;;
  *) echo "Unknown output token: $TOKEN_OUT_SYM"; exit 1 ;;
esac

AMOUNT_RAW=$(python -c "print(int(float('$AMOUNT_IN') * 10**$DEC_IN))")
SENDER=$(cast wallet address "$AGENT_PRIVATE_KEY")
DEADLINE=$(python -c "import time; print(int(time.time()) + 1800)")
```

## 1. Choose path

```bash
if [ -n "$DODO_API_KEY" ]; then
  # use DODO Route API → §2
  USE_API=1
else
  # direct router fallback → §3
  USE_API=0
fi
```

## 2. DODO Route API path (preferred)

```bash
URL="https://api.dodoex.io/route-service/v2/widget/getdodoroute"
URL="$URL?chainId=1672"
URL="$URL&fromTokenAddress=$TOKEN_IN_ADDR"
URL="$URL&toTokenAddress=$TOKEN_OUT_ADDR"
URL="$URL&fromAmount=$AMOUNT_RAW"
URL="$URL&slippage=$(python -c "print($SLIPPAGE_BPS / 100)")"  # API expects percent
URL="$URL&userAddr=$SENDER"
URL="$URL&deadLine=$DEADLINE"
URL="$URL&apikey=$DODO_API_KEY"

RESP=$(curl -s "$URL")
echo "$RESP" | python -m json.tool

TO=$(echo   "$RESP" | python -c "import sys,json; print(json.load(sys.stdin)['data']['to'])")
DATA=$(echo "$RESP" | python -c "import sys,json; print(json.load(sys.stdin)['data']['data'])")
VAL=$(echo  "$RESP" | python -c "import sys,json; print(json.load(sys.stdin)['data'].get('value','0'))")
OUT_RAW=$(echo "$RESP" | python -c "import sys,json; print(json.load(sys.stdin)['data'].get('resAmount','0'))")
```

Approve (if ERC-20 input):
```bash
if [ "$TOKEN_IN_ADDR" != "0x0000000000000000000000000000000000000000" ]; then
  ALLOW=$(cast call "$TOKEN_IN_ADDR" "allowance(address,address)(uint256)" "$SENDER" "$TO" --rpc-url "$PHAROS_RPC")
  ALLOW_INT=$(python -c "print(int('$ALLOW'.split()[0]))")
  if [ "$ALLOW_INT" -lt "$AMOUNT_RAW" ]; then
    cast send "$TOKEN_IN_ADDR" "approve(address,uint256)" "$TO" "$AMOUNT_RAW" \
      --rpc-url "$PHAROS_RPC" --private-key "$AGENT_PRIVATE_KEY"
  fi
fi
```

Execute:
```bash
SWAP_TX=$(cast send "$TO" "$DATA" --value "$VAL" \
  --rpc-url "$PHAROS_RPC" --private-key "$AGENT_PRIVATE_KEY" --json \
  | python -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")

echo "  swap tx: $SWAP_TX"
echo "  explorer: https://pharosscan.xyz/tx/$SWAP_TX"
```

## 3. Direct router fallback (no API key)

> Use only when you know a direct PMM pool exists for the pair. For multi-hop or PMM-bypass routes, the API is required.

The router selector confirmed by bytecode scan is `0x0a5ea466` = `mixSwap(...)`. Constructing valid `mixAdapters`, `mixPairs`, `assetTo`, `directions`, `moreInfos` from scratch is non-trivial; it requires knowledge of deployed pool addresses.

Practical fallback:

1. If the pair is `PROS ↔ WPHRS`, use the wrapped-token contract directly (no swap needed):
   ```bash
   # wrap PROS → WPHRS
   cast send $WPHRS_ADDR "deposit()" --value $AMOUNT_RAW \
     --rpc-url "$PHAROS_RPC" --private-key "$AGENT_PRIVATE_KEY"

   # unwrap WPHRS → PROS
   cast send $WPHRS_ADDR "withdraw(uint256)" $AMOUNT_RAW \
     --rpc-url "$PHAROS_RPC" --private-key "$AGENT_PRIVATE_KEY"
   ```

2. For other pairs without API key, ABORT with a message guiding the user to obtain a `DODO_API_KEY` from https://open.dodoex.io.

```bash
echo "FALLBACK MODE: pair $TOKEN_IN_SYM → $TOKEN_OUT_SYM needs DODO Route API."
echo "  Set DODO_API_KEY env var (https://open.dodoex.io) and rerun."
echo "  Or use the Faroswap web app: https://faroswap.xyz/swap"
exit 3
```

## 4. Slippage check after swap

```bash
USDC_BAL_HEX=$(cast call "$TOKEN_OUT_ADDR" "balanceOf(address)(uint256)" "$SENDER" --rpc-url "$PHAROS_RPC")
USDC_BAL=$(python -c "print(int('$USDC_BAL_HEX'.split()[0]))")
echo "  new $TOKEN_OUT_SYM balance: $(python -c "print($USDC_BAL / 10**$DEC_OUT)")"
```

## 5. Quote-only mode (dry-run)

Same call as §2 but **don't** broadcast — just print expected output:

```bash
RESP=$(curl -s "$URL")
echo "$RESP" | python -c "
import sys, json
d = json.load(sys.stdin)['data']
print(f'  to: {d[\"to\"]}')
print(f'  expected out: {int(d.get(\"resAmount\",0)) / 10**$DEC_OUT} $TOKEN_OUT_SYM')
print(f'  price impact: {d.get(\"priceImpact\",\"n/a\")}')
print(f'  route: {d.get(\"route\",\"n/a\")}')
"
```

## 6. Report to user

```
Swapped 5 PROS → 4.91 USDC on Pharos
  router:   0xA5cA5Fbe34e444F366B373170541ec6902b0F75c
  tx:       0xabc...  (https://pharosscan.xyz/tx/0xabc)
  slippage: 0.4% (within 1.0% tolerance)
  new USDC balance: 30.41 USDC
```

## 7. Errors

| Error | Cause | Fix |
|---|---|---|
| `Invalid API key in request` | DODO_API_KEY missing/wrong | Set env var |
| `cast send` reverts with `INSUFFICIENT_OUTPUT_AMOUNT` | slippage exceeded between quote and execute | Re-quote (price moved) |
| `cast send` reverts with `EXPIRED` | deadline passed | Re-quote with fresh deadline |
| API returns empty `data` | no route available for pair | No liquidity — try wrap/unwrap if PROS↔WPHRS, else abort |
