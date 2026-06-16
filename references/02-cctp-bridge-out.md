# Reference 02 — Bridge USDC from Pharos to another chain (CCTP V2)

End-to-end flow for `source=pharos, dest={ethereum,base,arbitrum,optimism,polygon,avalanche}`, token=USDC.

---

## 0. Preconditions

| Required | How to check |
|---|---|
| `AGENT_PRIVATE_KEY` is set | `[ -n "$AGENT_PRIVATE_KEY" ]` |
| Sender has ≥ `amount` USDC on Pharos | `cast call $USDC_PHAROS "balanceOf(address)(uint256)" $SENDER --rpc-url $PHAROS_RPC` |
| Sender has ≥ ~0.001 PROS for gas on Pharos | `cast balance $SENDER --rpc-url $PHAROS_RPC` |
| Recipient has ≥ ~$1 equivalent native on dest chain (for mint gas) | `cast balance $RECIPIENT --rpc-url $DEST_RPC` |
| Destination chain has CCTP V2 deployed | check `assets/cctp-domains.json` |

## 1. Load constants

```bash
DEST="${1:?usage: bridge-out <dest> <amount> [recipient]}"
AMOUNT="${2:?amount in USDC, e.g. 10 or 10.5}"
RECIPIENT="${3:-$(cast wallet address $AGENT_PRIVATE_KEY)}"

# Network endpoints
PHAROS_RPC=$(jq -r '.networks.pharos.rpcUrl'  assets/networks.json)
DEST_RPC=$(jq -r   ".networks.$DEST.rpcUrl"   assets/networks.json)
DEST_EXPLORER=$(jq -r ".networks.$DEST.explorerUrl" assets/networks.json)

# CCTP V2 contracts
USDC_PHAROS=$(jq -r '.usdc.pharos.address'         assets/tokens.json)
TM_PHAROS=$(jq -r   '.domains.pharos.tokenMessenger' assets/cctp-domains.json)
MT_DEST=$(jq -r     ".domains.$DEST.messageTransmitter" assets/cctp-domains.json)

# Pharos = source domain 31, dest domain from registry
SRC_DOMAIN=$(jq -r '.domains.pharos.domain' assets/cctp-domains.json)   # 31
DEST_DOMAIN=$(jq -r ".domains.$DEST.domain" assets/cctp-domains.json)

# Compute raw amount: USDC has 6 decimals
AMOUNT_RAW=$(python -c "print(int(float('$AMOUNT') * 10**6))")

# bytes32 mint recipient = padded address
RECIPIENT_BYTES32="0x000000000000000000000000${RECIPIENT:2}"
# destinationCaller = 0x0 → permissionless mint (anyone can call receiveMessage)
DEST_CALLER="0x0000000000000000000000000000000000000000000000000000000000000000"

# Standard Transfer = maxFee 0, minFinalityThreshold = 2000 ("finalized")
MAX_FEE=0
MIN_FINALITY=2000
```

## 2. Pre-flight checks

```bash
SENDER=$(cast wallet address "$AGENT_PRIVATE_KEY")

BAL_HEX=$(cast call "$USDC_PHAROS" "balanceOf(address)(uint256)" "$SENDER" --rpc-url "$PHAROS_RPC")
BAL=$(python -c "print(int('$BAL_HEX'.split()[0]))")
if [ "$BAL" -lt "$AMOUNT_RAW" ]; then
  echo "ABORT: insufficient USDC on Pharos. Have $BAL raw, need $AMOUNT_RAW raw."
  exit 1
fi

GAS=$(cast balance "$SENDER" --rpc-url "$PHAROS_RPC")
if [ "$GAS" = "0" ]; then
  echo "ABORT: zero PROS for gas. Send PROS to $SENDER first."
  exit 1
fi
```

## 3. Approve (only if current allowance < AMOUNT_RAW)

```bash
ALLOW_HEX=$(cast call "$USDC_PHAROS" "allowance(address,address)(uint256)" "$SENDER" "$TM_PHAROS" --rpc-url "$PHAROS_RPC")
ALLOW=$(python -c "print(int('$ALLOW_HEX'.split()[0]))")

if [ "$ALLOW" -lt "$AMOUNT_RAW" ]; then
  echo "Approving TokenMessenger to spend $AMOUNT USDC..."
  APPROVE_TX=$(cast send "$USDC_PHAROS" "approve(address,uint256)" "$TM_PHAROS" "$AMOUNT_RAW" \
    --rpc-url "$PHAROS_RPC" --private-key "$AGENT_PRIVATE_KEY" --json | python -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")
  echo "  approve tx: $APPROVE_TX"
fi
```

> **NEVER** approve `MAX_UINT256` here. The skill scopes allowance to the exact amount per bridge.

## 4. Call depositForBurn (V2 signature)

```bash
echo "Burning $AMOUNT USDC on Pharos (domain $SRC_DOMAIN) → $DEST (domain $DEST_DOMAIN)..."

BURN_TX=$(cast send "$TM_PHAROS" \
  "depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)" \
  "$AMOUNT_RAW" "$DEST_DOMAIN" "$RECIPIENT_BYTES32" "$USDC_PHAROS" \
  "$DEST_CALLER" "$MAX_FEE" "$MIN_FINALITY" \
  --rpc-url "$PHAROS_RPC" --private-key "$AGENT_PRIVATE_KEY" --json \
  | python -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")

echo "  burn tx: $BURN_TX"
echo "  explorer: https://pharosscan.xyz/tx/$BURN_TX"
```

> If `cast send` errors with `selector not found` or similar, the deployed router may still expose the **V1** signature. Fall back:
> ```bash
> cast send "$TM_PHAROS" "depositForBurn(uint256,uint32,bytes32,address)" \
>   "$AMOUNT_RAW" "$DEST_DOMAIN" "$RECIPIENT_BYTES32" "$USDC_PHAROS" \
>   --rpc-url "$PHAROS_RPC" --private-key "$AGENT_PRIVATE_KEY"
> ```
> Confirm correct signature by simulating `cast call $TM_PHAROS "depositForBurn..." --from $SENDER` first.

## 5. Poll Iris API for attestation

See [05-attestation-poll.md](05-attestation-poll.md) for the polling loop. Quick form:

```bash
SRC_DOMAIN=31
ATTESTATION_URL="https://iris-api.circle.com/v2/messages/$SRC_DOMAIN/$BURN_TX"

echo "Waiting for Circle attestation (Standard Transfer, expect 8-15 min)..."
ATTESTATION=""
MESSAGE=""
ATTEMPT=0
MAX_ATTEMPTS=240   # 240 * 5s = 20 min

while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
  RESP=$(curl -s "$ATTESTATION_URL")
  STATUS=$(echo "$RESP" | python -c "import sys,json; r=json.load(sys.stdin); print(r.get('messages',[{}])[0].get('status','none'))")
  if [ "$STATUS" = "complete" ]; then
    MESSAGE=$(echo "$RESP" | python -c "import sys,json; print(json.load(sys.stdin)['messages'][0]['message'])")
    ATTESTATION=$(echo "$RESP" | python -c "import sys,json; print(json.load(sys.stdin)['messages'][0]['attestation'])")
    echo "  attestation ready."
    break
  fi
  ATTEMPT=$((ATTEMPT + 1))
  sleep 5
done

if [ -z "$ATTESTATION" ]; then
  echo "TIMEOUT: attestation not ready after 20 min. Save BURN_TX=$BURN_TX and retry later with 07-status-and-recovery.md"
  exit 2
fi
```

## 6. Call receiveMessage on destination chain

```bash
echo "Minting USDC on $DEST..."

MINT_TX=$(cast send "$MT_DEST" \
  "receiveMessage(bytes,bytes)" "$MESSAGE" "$ATTESTATION" \
  --rpc-url "$DEST_RPC" --private-key "$AGENT_PRIVATE_KEY" --json \
  | python -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")

echo "  mint tx: $MINT_TX"
echo "  explorer: $DEST_EXPLORER/tx/$MINT_TX"
```

## 7. Verify

```bash
USDC_DEST=$(jq -r ".usdc.$DEST.address" assets/tokens.json)
NEW_BAL_HEX=$(cast call "$USDC_DEST" "balanceOf(address)(uint256)" "$RECIPIENT" --rpc-url "$DEST_RPC")
NEW_BAL=$(python -c "print(int('$NEW_BAL_HEX'.split()[0]) / 1e6)")
echo "  new $DEST USDC balance for $RECIPIENT: $NEW_BAL USDC"
echo "Done."
```

## 8. Report to user

The agent reports in a single block, like:

```
Bridged 10 USDC pharos → base
  burn:        0xabc...  (pharos, https://pharosscan.xyz/tx/0xabc)
  attestation: ready in 9m 42s
  mint:        0xdef...  (base, https://basescan.org/tx/0xdef)
  recipient:   0xRecipient...
  new balance: 110.00 USDC on base
```

## 9. Things that can go wrong

| Failure | What to do |
|---|---|
| Burn tx reverts: "insufficient allowance" | Step 3 was skipped or under-allowed. Re-run. |
| Burn tx reverts: "invalid destination domain" | Dest chain not in `cctp-domains.json`. Validate input. |
| Iris API returns 404 for tx | Wait ~30s and retry; first index can lag |
| Iris status stuck at `pending_confirmations` | Standard Transfer waits for finality (~2000 blocks on Pharos). Just wait. |
| receiveMessage reverts: "message already used" | Bridge already completed. Check dest USDC balance — likely already minted. |
| receiveMessage reverts: "invalid attestation" | Pull a fresh `message` + `attestation` from Iris; old payload corrupted |

Recovery flow (resume from BURN_TX) is in [07-status-and-recovery.md](07-status-and-recovery.md).
