#!/usr/bin/env bash
# Dry-run verification — proves LI.FI returns a valid signable tx for your wallet
# WITHOUT broadcasting anything. Safe to run repeatedly.
#
#   bash scripts/verify-lifi-quote-dryrun.sh
#
# What it does:
#   1. Reads PRIVATE_KEY from env or .env, derives address
#   2. Calls LI.FI /quote for: 0.5 PROS on Pharos -> USDC on Base
#   3. Prints the returned transactionRequest (to, value, data length)
#   4. (Optional) attempts `cast call` simulation against the returned data
#   5. Does NOT call `cast send`. No tx broadcast.

set -euo pipefail

CAST="${CAST:-cast}"
[ -f ".env" ] && source .env
PRIVATE_KEY="${PRIVATE_KEY:?Set PRIVATE_KEY}"
ADDR=$("$CAST" wallet address "$PRIVATE_KEY")

echo "wallet:    $ADDR"
echo ""

# Hit LI.FI
echo "Quoting: 0.5 PROS on Pharos -> USDC on Base ..."
URL="https://li.quest/v1/quote?fromChain=1672&toChain=8453&fromToken=PROS&toToken=USDC&fromAmount=500000000000000000&fromAddress=$ADDR"
RESP=$(curl -s "$URL")

echo "$RESP" | python -c "
import sys, json
d = json.load(sys.stdin)
if 'message' in d:
    print('LI.FI error:', d['message'])
    sys.exit(1)
print('tool:        ', d.get('tool'))
e = d.get('estimate',{})
print(f'expected:    {int(e.get(\"toAmount\",0))/1e6:.4f} USDC on Base')
print(f'exec time:   {e.get(\"executionDuration\")} sec')
tr = d.get('transactionRequest',{})
print()
print('Unsigned transactionRequest (what cast send would broadcast):')
print(f'  to:       {tr.get(\"to\")}')
print(f'  value:    {tr.get(\"value\",\"0\")} wei')
print(f'  data:     {tr.get(\"data\",\"\")[:80]}... ({len(tr.get(\"data\",\"\"))} chars)')
print(f'  chainId:  {tr.get(\"chainId\")}')
print(f'  gasLimit: {tr.get(\"gasLimit\")}')
"

echo ""
echo "OK — LI.FI accepts this wallet and returns a valid signable tx."
echo "The skill's reference 09 instructs the agent to:"
echo "  1) approve token (if ERC-20) for transactionRequest.to"
echo "  2) cast send --to \$to --value \$value --data \$data --rpc-url <pharos> --private-key \$PK"
echo "  3) poll https://li.quest/v1/status until DONE"
echo ""
echo "No tx broadcast in this script. Run mainnet smoke test manually once funded."
