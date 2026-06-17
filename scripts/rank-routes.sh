#!/usr/bin/env bash
# Quote ALL viable providers for a corridor and rank them by speed + fee + output.
# This is the runtime helper for the LI.FI-first routing workflow in
# references/10-route-selection.md.
#
# SECURITY: User-provided symbols are resolved to checksummed addresses from
# assets/token-registry.json BEFORE any external API call. After receiving
# a quote, the response's fromToken / toToken addresses are verified to
# match what we sent. Mismatches abort with a clear error.
#
# Usage:
#   bash scripts/rank-routes.sh <src_chain> <dst_chain> <token_in> <token_out> <amount_human>
#
# Examples:
#   bash scripts/rank-routes.sh pharos base USDC USDC 10
#   bash scripts/rank-routes.sh pharos base PROS USDC 1
#   bash scripts/rank-routes.sh pharos pharos PROS USDC 5

set -euo pipefail

# Resolve python executable (wraps python3 if python is not mapped)
if ! command -v python &> /dev/null && command -v python3 &> /dev/null; then
  python() {
    python3 "$@"
  }
fi

SRC="${1:?src chain key, e.g. pharos / base / arbitrum}"
DST="${2:?dst chain key}"
TIN="${3:?token_in symbol, e.g. USDC / PROS}"
TOUT="${4:?token_out symbol}"
AMOUNT_HUMAN="${5:?amount, e.g. 10 or 0.5}"

SKILL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SKILL_ROOT"

NETS="assets/networks.json"
TOKS="assets/token-registry.json"

SENDER="${SENDER:-0x0000000000000000000000000000000000000001}"

# --- Chain ID lookup ---
SRC_ID=$(python -c "import json; print(json.load(open('$NETS'))['networks']['$SRC']['chainId'])")
DST_ID=$(python -c "import json; print(json.load(open('$NETS'))['networks']['$DST']['chainId'])")

# --- Token resolution: symbol+chainId -> checksummed address ---
resolve_token_or_die() {
  local SYM="$1" CHAIN_ID="$2"
  local ADDR
  ADDR=$(python -c "
import json, sys
reg = json.load(open('$TOKS'))['tokens']
t = reg.get('$SYM')
if t is None:
    print('UNKNOWN_SYMBOL', file=sys.stderr); sys.exit(1)
a = t.get('$CHAIN_ID')
if a is None:
    print(f'NO_REGISTRY for $SYM on chain $CHAIN_ID', file=sys.stderr); sys.exit(1)
print(a)
") || { echo "ABORT: cannot resolve $SYM on chain $CHAIN_ID" >&2; exit 1; }
  echo "$ADDR"
}

resolve_decimals() {
  local SYM="$1"
  python -c "
import json
print(json.load(open('$TOKS'))['tokens'].get('$SYM',{}).get('_decimals', 18))
"
}

ADDR_IN=$(resolve_token_or_die  "$TIN"  "$SRC_ID")
ADDR_OUT=$(resolve_token_or_die "$TOUT" "$DST_ID")
DEC_IN=$(resolve_decimals "$TIN")
DEC_OUT=$(resolve_decimals "$TOUT")
AMOUNT_RAW=$(python -c "print(int(float('$AMOUNT_HUMAN') * 10**$DEC_IN))")

echo "=== Quoting routes for $AMOUNT_HUMAN $TIN ($SRC) -> $TOUT ($DST) ==="
echo "    src token: $ADDR_IN  (chain $SRC_ID, $DEC_IN dec)"
echo "    dst token: $ADDR_OUT  (chain $DST_ID, $DEC_OUT dec)"
echo

QUOTES_JSON=".rank-routes-quotes.json"
echo "[]" > "$QUOTES_JSON"
trap 'rm -f "$QUOTES_JSON"' EXIT

push_quote() {
  local NAME="$1" EXEC="$2" FEE_USD="$3" OUT_RAW="$4" OUT_DEC="$5" NOTE="$6"
  python -c "
import json
qs = json.load(open('$QUOTES_JSON'))
qs.append({'name':'$NAME','exec_sec':$EXEC,'fee_usd':$FEE_USD,'out_raw':$OUT_RAW,'out_dec':$OUT_DEC,'note':'$NOTE'})
json.dump(qs, open('$QUOTES_JSON','w'))
"
}

# --- 1. LI.FI (always) — using ADDRESSES not symbols ---
# LI.FI matches addresses case-insensitively but its query parser is strict, so lowercase first
ADDR_IN_LC=$(python -c "print('$ADDR_IN'.lower())")
ADDR_OUT_LC=$(python -c "print('$ADDR_OUT'.lower())")
echo "[1/3] LI.FI ..."
URL="https://li.quest/v1/quote?fromChain=$SRC_ID&toChain=$DST_ID&fromToken=$ADDR_IN_LC&toToken=$ADDR_OUT_LC&fromAmount=$AMOUNT_RAW&fromAddress=$SENDER"
LIFI=$(curl -s "$URL")
if echo "$LIFI" | python -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'message' not in d else 1)" 2>/dev/null; then
  # Post-quote token verification
  VERIFY=$(echo "$LIFI" | python -c "
import sys, json
d = json.load(sys.stdin)
act = d.get('action', {})
got_from = (act.get('fromToken', {}).get('address') or '').lower()
got_to   = (act.get('toToken',   {}).get('address') or '').lower()
exp_from = '$ADDR_IN'.lower()
exp_to   = '$ADDR_OUT'.lower()
if got_from != exp_from or got_to != exp_to:
    print('MISMATCH')
else:
    print('OK')
")
  if [ "$VERIFY" != "OK" ]; then
    echo "  ABORT: LI.FI returned token addresses that don't match what we sent (possible scam mapping)" >&2
  else
    TOOL=$(echo "$LIFI" | python -c "import sys,json; print(json.load(sys.stdin)['tool'])")
    EXEC=$(echo "$LIFI" | python -c "import sys,json; print(json.load(sys.stdin)['estimate']['executionDuration'])")
    OUT=$(echo  "$LIFI" | python -c "import sys,json; print(json.load(sys.stdin)['estimate']['toAmount'])")
    FEE=$(echo  "$LIFI" | python -c "import sys,json; print(sum(float(f.get('amountUSD',0)) for f in json.load(sys.stdin)['estimate'].get('feeCosts',[])))")
    push_quote "LI.FI ($TOOL)" "$EXEC" "$FEE" "$OUT" "$DEC_OUT" "tokens verified, https://docs.li.fi"
    echo "  OK  $TOOL  exec=${EXEC}s  fee=\$$FEE  tokens verified"
  fi
else
  ERR=$(echo "$LIFI" | python -c "import sys,json; print(json.load(sys.stdin).get('message','no quote')[:120])")
  echo "  NO  $ERR"
fi

# --- 2. CCTP V2 (only if USDC<->USDC and Pharos involved) ---
echo "[2/3] CCTP V2 ..."
if [ "$TIN" = "USDC" ] && [ "$TOUT" = "USDC" ] && { [ "$SRC" = "pharos" ] || [ "$DST" = "pharos" ]; }; then
  # CCTP V2 Standard: zero protocol fee, full amount, ~10 min average on Pharos
  push_quote "CCTP V2 Standard" 600 0 "$AMOUNT_RAW" 6 "Circle official, zero protocol fee, USDC<->USDC only"
  echo "  OK  Standard  exec~600s  fee=\$0.00  full amount, official Circle"
else
  echo "  SKIP (CCTP V2 supports USDC<->USDC with Pharos only)"
fi

# --- 3. Faroswap (only same-chain Pharos, requires DODO_API_KEY) ---
echo "[3/3] Faroswap ..."
if [ "$SRC" = "pharos" ] && [ "$DST" = "pharos" ]; then
  if [ -n "${DODO_API_KEY:-}" ]; then
    DEADLINE=$(python -c "import time; print(int(time.time())+1800)")
    FW_URL="https://api.dodoex.io/route-service/v2/widget/getdodoroute?chainId=1672"
    FW_URL="$FW_URL&fromTokenAddress=$ADDR_IN&toTokenAddress=$ADDR_OUT&fromAmount=$AMOUNT_RAW"
    FW_URL="$FW_URL&slippage=1&userAddr=$SENDER&deadLine=$DEADLINE&apikey=$DODO_API_KEY"
    FW=$(curl -s "$FW_URL")
    if echo "$FW" | python -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('data',{}).get('to') else 1)" 2>/dev/null; then
      FW_OUT=$(echo "$FW" | python -c "import sys,json; print(json.load(sys.stdin)['data'].get('resAmount','0'))")
      push_quote "Faroswap (DODO mixSwap)" 30 0 "$FW_OUT" "$DEC_OUT" "Pharos native DEX, DODO PMM"
      echo "  OK  mixSwap  exec~30s"
    else
      echo "  NO  no route from DODO API"
    fi
  else
    echo "  SKIP (set DODO_API_KEY to enable Faroswap)"
  fi
else
  echo "  SKIP (Faroswap only handles same-chain Pharos swaps)"
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
    star = '  <-- recommended' if i == 1 else ''
    print(f"  {i}. {q['name']:30} exec {q['exec_sec']/60:6.1f} min   fee \${q['fee_usd']:.4f}   receive {out_h:.4f} $TOUT{star}")
    print(f"     {q['note']}")
EOF
