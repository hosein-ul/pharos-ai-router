# Reference 03 — Bridge USDC into Pharos from another chain (CCTP V2)

Mirror of [02-cctp-bridge-out.md](02-cctp-bridge-out.md): source ∈ {ethereum, base, arbitrum, optimism, polygon, avalanche}, dest = pharos.

---

## 0. Preconditions

| Required | How to check |
|---|---|
| `AGENT_PRIVATE_KEY` set | `[ -n "$AGENT_PRIVATE_KEY" ]` |
| Sender holds ≥ amount USDC on source chain | balance check on source |
| Sender holds source-chain native (ETH/AVAX/POL) for burn gas | `cast balance` on source |
| Recipient holds ≥ ~0.001 PROS for mint gas on Pharos | `cast balance` on Pharos |
| **Pharos is a destination domain** — confirmed (domain 31) | from `assets/cctp-domains.json` |

## 1. Load constants

```bash
SRC="${1:?usage: bridge-in <src_chain> <amount> [recipient]}"
AMOUNT="${2:?amount in USDC}"
RECIPIENT="${3:-$(cast wallet address $AGENT_PRIVATE_KEY)}"

SRC_RPC=$(jq -r ".networks.$SRC.rpcUrl"     assets/networks.json)
PHAROS_RPC=$(jq -r '.networks.pharos.rpcUrl' assets/networks.json)
SRC_EXPLORER=$(jq -r ".networks.$SRC.explorerUrl" assets/networks.json)

USDC_SRC=$(jq -r ".usdc.$SRC.address"               assets/tokens.json)
TM_SRC=$(jq -r ".domains.$SRC.tokenMessenger"       assets/cctp-domains.json)
MT_PHAROS=$(jq -r '.domains.pharos.messageTransmitter' assets/cctp-domains.json)

SRC_DOMAIN=$(jq -r ".domains.$SRC.domain"    assets/cctp-domains.json)
PHAROS_DOMAIN=$(jq -r '.domains.pharos.domain' assets/cctp-domains.json)  # 31

AMOUNT_RAW=$(python -c "print(int(float('$AMOUNT') * 10**6))")
RECIPIENT_BYTES32="0x000000000000000000000000${RECIPIENT:2}"
DEST_CALLER="0x0000000000000000000000000000000000000000000000000000000000000000"
MAX_FEE=0
MIN_FINALITY=2000
```

## 2. Pre-flight

```bash
SENDER=$(cast wallet address "$AGENT_PRIVATE_KEY")

BAL_HEX=$(cast call "$USDC_SRC" "balanceOf(address)(uint256)" "$SENDER" --rpc-url "$SRC_RPC")
BAL=$(python -c "print(int('$BAL_HEX'.split()[0]))")
[ "$BAL" -lt "$AMOUNT_RAW" ] && { echo "ABORT: insufficient USDC on $SRC"; exit 1; }

GAS_SRC=$(cast balance "$SENDER" --rpc-url "$SRC_RPC")
[ "$GAS_SRC" = "0" ] && { echo "ABORT: zero gas on $SRC"; exit 1; }
```

## 3. Approve TokenMessenger on source (if needed)

```bash
ALLOW_HEX=$(cast call "$USDC_SRC" "allowance(address,address)(uint256)" "$SENDER" "$TM_SRC" --rpc-url "$SRC_RPC")
ALLOW=$(python -c "print(int('$ALLOW_HEX'.split()[0]))")

if [ "$ALLOW" -lt "$AMOUNT_RAW" ]; then
  cast send "$USDC_SRC" "approve(address,uint256)" "$TM_SRC" "$AMOUNT_RAW" \
    --rpc-url "$SRC_RPC" --private-key "$AGENT_PRIVATE_KEY"
fi
```

## 4. depositForBurn on source

```bash
BURN_TX=$(cast send "$TM_SRC" \
  "depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)" \
  "$AMOUNT_RAW" "$PHAROS_DOMAIN" "$RECIPIENT_BYTES32" "$USDC_SRC" \
  "$DEST_CALLER" "$MAX_FEE" "$MIN_FINALITY" \
  --rpc-url "$SRC_RPC" --private-key "$AGENT_PRIVATE_KEY" --json \
  | python -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")

echo "  burn on $SRC: $BURN_TX"
echo "  explorer: $SRC_EXPLORER/tx/$BURN_TX"
```

## 5. Poll Iris

```bash
ATTESTATION_URL="https://iris-api.circle.com/v2/messages/$SRC_DOMAIN/$BURN_TX"
# poll loop identical to 02-cctp-bridge-out.md §5
```

See [05-attestation-poll.md](05-attestation-poll.md).

## 6. receiveMessage on Pharos

```bash
MINT_TX=$(cast send "$MT_PHAROS" \
  "receiveMessage(bytes,bytes)" "$MESSAGE" "$ATTESTATION" \
  --rpc-url "$PHAROS_RPC" --private-key "$AGENT_PRIVATE_KEY" --json \
  | python -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")

echo "  mint on Pharos: $MINT_TX"
echo "  explorer: https://pharosscan.xyz/tx/$MINT_TX"
```

## 7. Verify

```bash
USDC_PHAROS=$(jq -r '.usdc.pharos.address' assets/tokens.json)
NEW=$(cast call "$USDC_PHAROS" "balanceOf(address)(uint256)" "$RECIPIENT" --rpc-url "$PHAROS_RPC")
echo "  new Pharos USDC balance: $(python -c "print(int('$NEW'.split()[0]) / 1e6)") USDC"
```

## 8. Alternative — Circle CLI on the source side

If the source chain is one Circle CLI supports (Base, Arbitrum, Polygon, Optimism, Avalanche, Ethereum), the user can use `circle bridge transfer` for the burn side; this skill only needs to handle the Pharos-side mint:

```bash
# 1) user runs (Circle CLI handles burn + attestation on Base):
circle bridge transfer --from base --to-address $RECIPIENT --amount 10 \
  --destination-chain pharos       # ← will fail: circle CLI doesn't know "pharos"

# 2) so use Circle for what it knows:
circle bridge transfer --from base --to-address $CIRCLE_RECEIVER --amount 10 \
  --destination-chain <some-circle-supported-chain>

# That doesn't reach Pharos directly. The reliable path is the cast flow above.
```

**Conclusion**: until Circle CLI lists Pharos, do the burn manually via `cast` on the source chain, then mint on Pharos as in §6. The mint is permissionless (anyone with the `(message, attestation)` pair can call it), so the agent can do both sides itself or delegate either side to a relayer.

## 9. Report

```
Bridged 10 USDC base → pharos
  burn:        0xabc...  (base, https://basescan.org/tx/0xabc)
  attestation: ready in 9m
  mint:        0xdef...  (pharos, https://pharosscan.xyz/tx/0xdef)
  new balance: 35.50 USDC on pharos
```
