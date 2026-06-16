#!/usr/bin/env bash
# Quote ALL viable providers for a corridor and rank them by speed + fee + output.
# This is the runtime helper for the LI.FI-first routing workflow in
# references/10-route-selection.md.
#
# Usage:
#   bash scripts/rank-routes.sh <src_chain> <dst_chain> <token_in> <token_out> <amount_human>
#
# Examples:
#   bash scripts/rank-routes.sh pharos base USDC USDC 10
#   bash scripts/rank-routes.sh pharos base PROS USDC 1
#   bash scripts/rank-routes.sh pharos pharos PROS USDC 5
#
# Reads only. Never broadcasts. The agent calls this, picks a winner,
# then runs the matching reference doc to execute.

set -euo pipefail

SRC="${1:?src chain}"
DST="${2:?dst chain}"
TIN="${3:?token_in symbol}"
TOUT="${4:?token_out symbol}"
AMOUNT_HUMAN="${5:?amount, e.g. 10 or 0.5}"

# Resolve assets relative to skill root, regardless of cwd
SKILL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NETS="$SKILL_ROOT/assets/networks.json"
TOKS="$SKILL_ROOT/assets/tokens.json"
CCTP="$SKILL_ROOT/assets/cctp-domains.json"

# Sender — defaults to placeholder for quote-only mode
SENDER="${SENDER:-0x0000000000000000000000000000000000000001}"

# Map chain key -> chain id
SRC_ID=$(python -c "import json; print(json.load(open('$NETS'))['networks']['$SRC']['chainId'])")
DST_ID=$(python -c "import json; print(json.load(open('$NETS'))['networks']['$DST']['chainId'])")

# Decimals for amount
DEC=$(python -c "
import json
toks = json.load(open('$TOKS'))
sym = '$TIN'
if sym in ('PROS','ETH','POL','AVAX'):
    print(18)
elif sym in ('USDC','USDT'):
    print(6)
elif sym in ('WETH','WPROS','WPHRS','LINK','USDCe','USDT0','USD0','HYPE'):
    print(18)
else:
    print(18)
")
AMOUNT_RAW=$(python -c "print(int(float('$AMOUNT_HUMAN') * 10**$DEC))")

echo "=== Quoting routes for $AMOUNT_HUMAN $TIN ($SRC) -> $TOUT ($DST) ==="
echo

# Collect quotes into a JSON array, then rank at the end
TMPDIR=$(mktemp -d)
QUOTES_JSON="$TMPDIR/quotes.json"
echo "[]" > "$QUOTES_JSON"

push_quote() {
  local NAME="$1" EXEC="$2" FEE_USD="$3" OUT_RAW="$4" OUT_DEC="$5" NOTE="$6"
  python -c "
import json
qs = json.load(open('$QUOTES_JSON'))
qs.append({'name':'$NAME','exec_sec':$EXEC,'fee_usd':$FEE_USD,'out_raw':$OUT_RAW,'out_dec':$OUT_DEC,'note':'$NOTE'})
json.dump(qs, open('$QUOTES_JSON','w'))
"
}

# --- 1. LI.FI (always) ---
echo "[1/3] LI.FI ..."
URL="https://li.quest/v1/quote?fromChain=$SRC_ID&toChain=$DST_ID&fromToken=$TIN&toToken=$TOUT&fromAmount=$AMOUNT_RAW&fromAddress=$SENDER"
LIFI=$(curl -s "$URL")
if echo "$LIFI" | python -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'message' not in d else 1)" 2>/dev/null; then
  TOOL=$(echo "$LIFI" | python -c "import sys,json; print(json.load(sys.stdin)['tool'])")
  EXEC=$(echo "$LIFI" | python -c "import sys,json; print(json.load(sys.stdin)['estimate']['executionDuration'])")
  OUT=$(echo  "$LIFI" | python -c "import sys,json; print(json.load(sys.stdin)['estimate']['toAmount'])")
  FEE=$(echo  "$LIFI" | python -c "import sys,json; print(sum(float(f.get('amountUSD',0)) for f in json.load(sys.stdin)['estimate'].get('feeCosts',[])))")
  DEC_OUT=$(python -c "
sym='$TOUT'
print(6 if sym in ('USDC','USDT') else 18)
")
  push_quote "LI.FI ($TOOL)" "$EXEC" "$FEE" "$OUT" "$DEC_OUT" "https://docs.li.fi/"
  echo "  OK $TOOL  exec=${EXEC}s  fee=\$$FEE"
else
  ERR=$(echo "$LIFI" | python -c "import sys,json; print(json.load(sys.stdin).get('message','no quote')[:100])")
  echo "  NO  $ERR"
fi

# --- 2. CCTP V2 (only if USDC<->USDC and Pharos involved) ---
echo "[2/3] CCTP V2 ..."
if [ "$TIN" = "USDC" ] && [ "$TOUT" = "USDC" ] && { [ "$SRC" = "pharos" ] || [ "$DST" = "pharos" ]; }; then
  # CCTP V2 Standard: zero protocol fee, you receive full amount, ~8-15 min on Pharos
  push_quote "CCTP V2 Standard" 600 0 "$AMOUNT_RAW" 6 "Circle official, zero protocol fee"
  echo "  OK Standard  exec~600s  fee=\$0.00  receive=full amount"
else
  echo "  SKIP (needs USDC<->USDC with Pharos)"
fi

# --- 3. Faroswap (only same-chain Pharos) ---
echo "[3/3] Faroswap ..."
if [ "$SRC" = "pharos" ] && [ "$DST" = "pharos" ]; then
  if [ -n "${DODO_API_KEY:-}" ]; then
    DEADLINE=$(python -c "import time; print(int(time.time())+1800)")
    TIN_ADDR=$(python -c "
sym='$TIN'
if sym in ('PROS','ETH','NATIVE'): print('0x0000000000000000000000000000000000000000')
elif sym=='USDC': print('0xc879c018db60520f4355c26ed1a6d572cdac1815')
elif sym=='USDT': print('0xE7E84B8B4f39C507499c40B4ac199B050e2882d5')
else: print('0x0000000000000000000000000000000000000000')
")
    TOUT_ADDR=$(python -c "
sym='$TOUT'
if sym in ('PROS','ETH','NATIVE'): print('0x0000000000000000000000000000000000000000')
elif sym=='USDC': print('0xc879c018db60520f4355c26ed1a6d572cdac1815')
elif sym=='USDT': print('0xE7E84B8B4f39C507499c40B4ac199B050e2882d5')
else: print('0x0000000000000000000000000000000000000000')
")
    FW_URL="https://api.dodoex.io/route-service/v2/widget/getdodoroute?chainId=1672&fromTokenAddress=$TIN_ADDR&toTokenAddress=$TOUT_ADDR&fromAmount=$AMOUNT_RAW&slippage=1&userAddr=$SENDER&deadLine=$DEADLINE&apikey=$DODO_API_KEY"
    FW=$(curl -s "$FW_URL")
    if echo "$FW" | python -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('data',{}).get('to') else 1)" 2>/dev/null; then
      FW_OUT=$(echo "$FW" | python -c "import sys,json; print(json.load(sys.stdin)['data'].get('resAmount','0'))")
      DEC_OUT=$(python -c "sym='$TOUT'; print(6 if sym in ('USDC','USDT') else 18)")
      push_quote "Faroswap (DODO mixSwap)" 30 0 "$FW_OUT" "$DEC_OUT" "Pharos native DEX"
      echo "  OK mixSwap  exec~30s  fee=DEX-fee"
    else
      echo "  NO  no route from DODO API"
    fi
  else
    echo "  SKIP (DODO_API_KEY not set)"
  fi
else
  echo "  SKIP (not same-chain Pharos)"
fi

# --- Rank ---
echo
echo "=== Ranked routes (speed > fee > output) ==="
python <<EOF
import json
quotes = json.load(open('$QUOTES_JSON'))
if not quotes:
    print('  No viable routes found.')
    raise SystemExit(0)
ranked = sorted(quotes, key=lambda q: (q['exec_sec'], q['fee_usd'], -q['out_raw']))
for i, q in enumerate(ranked, 1):
    out_h = q['out_raw'] / (10 ** q['out_dec'])
    star = '  ★ recommended' if i == 1 else ''
    print(f"  {i}. {q['name']:30} exec {q['exec_sec']/60:6.1f} min   fee \${q['fee_usd']:.4f}   receive {out_h:.4f} $TOUT{star}")
    print(f"     {q['note']}")
EOF

rm -rf "$TMPDIR"
