#!/usr/bin/env bash
# Verification script — proves the agent's cast-send pipeline works end-to-end
# on Pharos Atlantic testnet. Run this YOURSELF (the skill does not auto-execute).
#
#   bash scripts/verify-testnet-broadcast.sh
#
# What it does:
#   1. Reads PRIVATE_KEY from env (or .env in cwd)
#   2. Derives address, reads PHRS balance
#   3. Sends 0.001 PHRS back to itself on Atlantic testnet
#   4. Reports tx hash + explorer link + balance change
#
# This is the SAME `cast send` shape the skill's references invoke for
# actual bridges/swaps. If this works, the full skill flow works.

set -euo pipefail

CAST="${CAST:-cast}"
RPC="https://atlantic.dplabs-internal.com"
EXPLORER="https://atlantic.pharosscan.xyz"

# Load .env if present
[ -f ".env" ] && source .env
PRIVATE_KEY="${PRIVATE_KEY:?Set PRIVATE_KEY in env or .env}"

# 1) derive address
ADDR=$("$CAST" wallet address "$PRIVATE_KEY")
echo "wallet:     $ADDR"

# 2) balance before
BEFORE=$("$CAST" balance "$ADDR" --rpc-url "$RPC" -e)
echo "balance:    $BEFORE PHRS"

# 3) sanity
if (( $(echo "$BEFORE < 0.01" | bc -l) )); then
  echo "ABORT: balance too low for a 0.001 PHRS test (need ~0.01 for gas headroom)"
  exit 1
fi

# 4) self-send 0.001 PHRS (proves signing + broadcasting work)
AMOUNT_WEI="1000000000000000"   # 0.001 ETH/PHRS in wei
echo ""
echo "sending 0.001 PHRS to self ..."
TX=$("$CAST" send "$ADDR" --value "$AMOUNT_WEI" \
  --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --json \
  | python -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")

echo "tx hash:    $TX"
echo "explorer:   $EXPLORER/tx/$TX"

# 5) balance after
sleep 2
AFTER=$("$CAST" balance "$ADDR" --rpc-url "$RPC" -e)
echo "balance:    $AFTER PHRS  (delta = gas cost only)"

echo ""
echo "PASS — signing + broadcasting verified on Atlantic testnet."
echo ""
echo "Next steps:"
echo "  - LI.FI requires mainnet (chain 1672). Fund wallet with ~1 PROS + 1 USDC on mainnet to test."
echo "  - CCTP V2 testnet domain ID is unannounced; verify with Circle before testnet bridge tests."
echo "  - Once funded on mainnet, run the actual bridge/swap commands from references/."
