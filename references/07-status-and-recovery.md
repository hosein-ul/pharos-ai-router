# Reference 07 — Status check & recovery for stuck bridges

When a CCTP bridge stalls — Iris hasn't issued an attestation, or the mint on the destination chain hasn't been called — the agent needs to be able to **resume** from a burn tx hash alone, without any state from the original session.

This is the recovery contract.

---

## 1. Status of a tx — "check status of 0xabc..."

The agent must figure out, from a tx hash alone, what stage the bridge is at.

```bash
TX="${1:?usage: status <tx_hash>}"

# 1. Find which chain the tx is on
SRC_CHAIN=""
SRC_DOMAIN=""
for net in $(jq -r '.networks | keys[]' assets/networks.json); do
  RPC=$(jq -r ".networks.$net.rpcUrl" assets/networks.json)
  RECEIPT=$(cast receipt "$TX" --rpc-url "$RPC" 2>/dev/null)
  if [ -n "$RECEIPT" ] && echo "$RECEIPT" | grep -q "blockNumber"; then
    SRC_CHAIN="$net"
    SRC_DOMAIN=$(jq -r ".domains.$net.domain" assets/cctp-domains.json)
    break
  fi
done

if [ -z "$SRC_CHAIN" ]; then
  echo "Could not find $TX on any known chain."
  exit 1
fi

echo "Tx $TX is on $SRC_CHAIN (domain $SRC_DOMAIN)"
```

2. Determine if it was a depositForBurn:

```bash
# Pull the logs, look for the MessageSent event signature
# Event: MessageSent(bytes message)
# Topic0: 0x8c5261...   (keccak("MessageSent(bytes)") )
TX_RECEIPT=$(cast receipt "$TX" --rpc-url "$RPC" --json)
MESSAGE_SENT_TOPIC="0x8c5261668696ce22758910d05bab8f186d6eb247ceac2af2e82c7dc17669b036"

HAS_MESSAGE=$(echo "$TX_RECEIPT" | python -c "
import sys, json
r = json.load(sys.stdin)
logs = r.get('logs', [])
for log in logs:
    if log.get('topics', [''])[0].lower() == '$MESSAGE_SENT_TOPIC':
        print('yes')
        sys.exit()
print('no')
")

if [ "$HAS_MESSAGE" = "no" ]; then
  echo "Tx is not a CCTP burn. Nothing to recover."
  exit 0
fi
```

3. Check Iris for attestation:

```bash
ATTESTATION_URL="https://iris-api.circle.com/v2/messages/$SRC_DOMAIN/$TX"
RESP=$(curl -s "$ATTESTATION_URL")
STATUS=$(echo "$RESP" | python -c "import sys,json; r=json.load(sys.stdin); print(r.get('messages',[{}])[0].get('status','none'))")

case "$STATUS" in
  complete)
    echo "Attestation READY. Run mint with:"
    MSG=$(echo "$RESP" | python -c "import sys,json; print(json.load(sys.stdin)['messages'][0]['message'])")
    ATT=$(echo "$RESP" | python -c "import sys,json; print(json.load(sys.stdin)['messages'][0]['attestation'])")
    # decode destination domain from the message bytes (CCTP V2 message format)
    # bytes 8..11 of message = destinationDomain
    DEST_DOMAIN=$(python -c "
m = '$MSG'.removeprefix('0x')
print(int(m[16:24], 16))
")
    DEST_CHAIN=$(jq -r ".domains | to_entries[] | select(.value.domain == $DEST_DOMAIN) | .key" assets/cctp-domains.json)
    MT_DEST=$(jq -r ".domains.$DEST_CHAIN.messageTransmitter" assets/cctp-domains.json)
    DEST_RPC=$(jq -r ".networks.$DEST_CHAIN.rpcUrl" assets/networks.json)

    echo "  mint chain: $DEST_CHAIN (domain $DEST_DOMAIN)"
    echo "  message transmitter: $MT_DEST"
    echo "  message length: $(python -c "print(len('$MSG')//2 - 1)") bytes"
    ;;
  pending_confirmations)
    echo "Attestation PENDING (Iris waiting for source finality). Try again in 5-10 min."
    ;;
  ready)
    echo "Attestation almost ready. Retry in 30s."
    ;;
  none)
    echo "Iris has no record yet. Either tx is too recent, or it wasn't a CCTP burn."
    ;;
esac
```

## 2. Resume a stuck bridge — "my bridge is stuck"

If status check shows `complete`, the agent can mint right away:

```bash
# (vars from §1 above: $MSG, $ATT, $DEST_CHAIN, $MT_DEST, $DEST_RPC)

MINT_TX=$(cast send "$MT_DEST" \
  "receiveMessage(bytes,bytes)" "$MSG" "$ATT" \
  --rpc-url "$DEST_RPC" --private-key "$AGENT_PRIVATE_KEY" --json \
  | python -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")

echo "Mint complete: $MINT_TX"
echo "Explorer: $(jq -r ".networks.$DEST_CHAIN.explorerUrl" assets/networks.json)/tx/$MINT_TX"
```

If status is `pending_confirmations`, just wait and re-check.

## 3. "I lost my burn tx hash"

The agent can scan recent blocks on Pharos for `MessageSent` events from the sender, but Pharos's RPC limits `eth_getLogs` to **1000 blocks per query**. The agent must chunk:

```bash
SENDER=$(cast wallet address "$AGENT_PRIVATE_KEY")
PHAROS_RPC=$(jq -r '.networks.pharos.rpcUrl' assets/networks.json)
TM=$(jq -r '.domains.pharos.tokenMessenger' assets/cctp-domains.json)
LATEST=$(cast block-number --rpc-url "$PHAROS_RPC")
LOOKBACK=$((LATEST - 50000))  # last ~50k blocks ≈ recent activity

CHUNK_SIZE=1000
for FROM_BLOCK in $(seq "$LOOKBACK" "$CHUNK_SIZE" "$LATEST"); do
  TO_BLOCK=$((FROM_BLOCK + CHUNK_SIZE - 1))
  [ "$TO_BLOCK" -gt "$LATEST" ] && TO_BLOCK="$LATEST"

  LOGS=$(cast logs --from-block "$FROM_BLOCK" --to-block "$TO_BLOCK" \
    --address "$TM" \
    "MessageSent(bytes)" \
    --rpc-url "$PHAROS_RPC" --json)

  echo "$LOGS" | python -c "
import sys, json
for log in json.load(sys.stdin):
    print(log.get('transactionHash'), 'block', int(log.get('blockNumber','0x0'), 16))
"
done
```

The agent reports the candidate txs and lets the user pick. (In practice, the user almost always has the hash from a previous session log.)

## 4. Refund scenarios

CCTP V2 does not have a direct refund — once burned, USDC must be minted on the named destination domain. There is no "cancel" message.

If the user burned to the wrong destination domain:
- The mint will succeed on **that wrong chain**.
- The user then needs a second bridge from that chain back to where they want it.
- This skill can chain those, but only the user can confirm intent.

If the destination chain is permanently unreachable (e.g. RPC dead for a long time):
- The `(message, attestation)` is valid forever. Any future call to `receiveMessage` on that chain mints the USDC.
- The agent can hand the message + attestation off to a relayer service if available.

## 5. Output format

```
Bridge status: 0xabc...
  source chain:        pharos (domain 31)
  burn timestamp:      2026-06-17T10:23:14Z (12 min ago)
  amount:              10 USDC
  destination domain:  6 (base)
  recipient:           0xRecipient...
  iris status:         complete
  message ready:       yes (304 bytes)
  attestation ready:   yes
  → run mint on base now? [Y/n]
```

If pending:
```
Bridge status: 0xabc...
  source chain:        pharos (domain 31)
  burn timestamp:      3 min ago
  iris status:         pending_confirmations
  expected ready:      ~5-10 more minutes
  → recheck later
```
