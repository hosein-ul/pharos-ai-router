# Reference 05 — Iris attestation polling

After a CCTP V2 `depositForBurn` is confirmed on the source chain, Circle's Iris service must finalize the message before it can be minted on the destination. This reference is the polling logic used by [02-cctp-bridge-out.md](02-cctp-bridge-out.md), [03-cctp-bridge-in.md](03-cctp-bridge-in.md), and [07-status-and-recovery.md](07-status-and-recovery.md).

---

## 1. Endpoint

| Network | URL |
|---|---|
| Mainnet | `https://iris-api.circle.com/v2/messages/{sourceDomain}/{txHash}` |
| Sandbox/Testnet | `https://iris-api-sandbox.circle.com/v2/messages/{sourceDomain}/{txHash}` |

`{sourceDomain}` = the CCTP V2 domain of the **chain that burned** (not the destination). From `assets/cctp-domains.json`. For Pharos = 31.

`{txHash}` = the transaction hash returned by the burn `cast send`.

No auth headers required. GET only.

## 2. Response shape

```json
{
  "messages": [
    {
      "attestation": "0x...",          // hex bytes, present when status is "complete"
      "message": "0x...",              // hex bytes, the message body to pass to receiveMessage
      "eventNonce": "12345",
      "cctpVersion": 2,
      "status": "pending_confirmations" | "ready" | "complete"
    }
  ]
}
```

Status values seen in practice:
- `pending_confirmations` — source tx not yet final, Iris still waiting
- `ready` — finalized, attestation being signed (rare, transient)
- `complete` — `message` + `attestation` ready to consume
- HTTP 404 — tx not indexed yet (retry in 30s)

## 3. Polling function

```bash
poll_iris_attestation() {
  local DOMAIN="$1"
  local TX="$2"
  local MAX_ATTEMPTS="${3:-240}"     # 240 * 5s = 20 min
  local URL="https://iris-api.circle.com/v2/messages/$DOMAIN/$TX"
  local ATTEMPT=0

  echo "[iris] polling $URL"
  while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
    local RESP
    RESP=$(curl -s -w "\n%{http_code}" "$URL")
    local CODE
    CODE=$(echo "$RESP" | tail -n1)
    local BODY
    BODY=$(echo "$RESP" | head -n -1)

    case "$CODE" in
      200)
        local STATUS
        STATUS=$(echo "$BODY" | python -c "import sys,json; r=json.load(sys.stdin); print(r.get('messages',[{}])[0].get('status','none'))")
        case "$STATUS" in
          complete)
            local MSG ATT
            MSG=$(echo "$BODY" | python -c "import sys,json; print(json.load(sys.stdin)['messages'][0]['message'])")
            ATT=$(echo "$BODY" | python -c "import sys,json; print(json.load(sys.stdin)['messages'][0]['attestation'])")
            printf '%s\n%s\n' "$MSG" "$ATT"
            return 0
            ;;
          pending_confirmations|ready)
            printf "[iris] status=%s, attempt %d/%d\n" "$STATUS" "$((ATTEMPT+1))" "$MAX_ATTEMPTS" >&2
            ;;
          none)
            printf "[iris] empty messages array, attempt %d/%d\n" "$((ATTEMPT+1))" "$MAX_ATTEMPTS" >&2
            ;;
        esac
        ;;
      404)
        printf "[iris] tx not indexed yet (404), attempt %d/%d\n" "$((ATTEMPT+1))" "$MAX_ATTEMPTS" >&2
        ;;
      *)
        printf "[iris] http %s, attempt %d/%d\n" "$CODE" "$((ATTEMPT+1))" "$MAX_ATTEMPTS" >&2
        ;;
    esac

    ATTEMPT=$((ATTEMPT + 1))
    sleep 5
  done

  echo "[iris] TIMEOUT after $MAX_ATTEMPTS attempts (~$((MAX_ATTEMPTS*5/60)) min)" >&2
  return 2
}
```

Use it from any bridge flow:
```bash
RESULT=$(poll_iris_attestation 31 "$BURN_TX")
MESSAGE=$(echo "$RESULT" | sed -n '1p')
ATTESTATION=$(echo "$RESULT" | sed -n '2p')
```

## 4. Expected wait time

| Source chain | Standard Transfer ETA |
|---|---|
| Pharos → \* | 8–15 min (Pharos finality is sub-second but Iris waits for 2000-block confirmation) |
| Ethereum → \* | 13–19 min (finality is the dominant factor) |
| Base / Arbitrum / Optimism → \* | 8–15 min |
| Polygon → \* | 5–10 min |
| Avalanche → \* | 1–3 min |

Pharos does **not** support Fast Transfer (would be <1 min if it did). When/if Circle enables Fast Transfer on Pharos, update `cctp-domains.json` and switch to `minFinalityThreshold = 1000` + `maxFee > 0`.

## 5. Recovery hook

If the polling loop times out, the burn tx is still valid on-chain; the message exists, just the attestation hasn't been signed yet. The agent must:

1. Persist `BURN_TX` and `SRC_DOMAIN` somewhere the user can recover them (stdout log, a status file, or pass back to the agent).
2. Tell the user explicitly: "burn confirmed at \<tx\>; attestation not ready within 20 min — run `status` later with this tx hash".
3. When the user comes back with the tx, re-run §3 polling — it will succeed if Iris caught up.

The receiveMessage step is permissionless, so any wallet (the user's, a relayer, or the agent itself) can call it with the eventual `(message, attestation)` pair.
