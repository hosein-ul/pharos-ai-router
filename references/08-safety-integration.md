# Reference 08 — Safety integration with `pharos-tx-guardrail`

Every `cast send` issued by this skill is a candidate to pipe through the [pharos-tx-guardrail](https://github.com/hosein-ul/pharos-tx-guardrail) skill before broadcasting. This file documents the optional integration.

The guardrail is also a Pharos Skill Engine skill. It runs 6 read-only checks against a planned transaction and returns a risk score 0–100 plus a verdict (`PROCEED` / `WARN` / `BLOCK`).

---

## 1. When to pipe through guardrail

| Tx type | Required? | Why |
|---|---|---|
| `approve()` on a token | Recommended | Pattern check catches `MAX_UINT256` and unknown spender |
| `depositForBurn()` on TokenMessengerV2 | Recommended | Confirms target is verified TokenMessenger and not a clone |
| `receiveMessage()` on MessageTransmitterV2 | Optional | Read-only on incoming attestation, but still confirms target |
| Swap calldata from DODO Route API | **Required** | API response is untrusted input — verify target is Faroswap router |

## 2. Integration command

The guardrail exposes a single entry point: given `target`, `calldata`, and `sender`, return risk score.

```bash
# Pseudocode — agent invokes the guardrail skill before broadcasting

VERDICT_JSON=$(pharos-tx-guardrail check \
  --target "$TARGET" \
  --calldata "$CALLDATA" \
  --sender "$SENDER" \
  --value "$VALUE" \
  --rpc-url "$RPC")

SCORE=$(echo "$VERDICT_JSON" | python -c "import sys,json; print(json.load(sys.stdin)['score'])")
VERDICT=$(echo "$VERDICT_JSON" | python -c "import sys,json; print(json.load(sys.stdin)['verdict'])")

case "$VERDICT" in
  PROCEED)
    cast send "$TARGET" "$CALLDATA" --value "$VALUE" \
      --rpc-url "$RPC" --private-key "$AGENT_PRIVATE_KEY"
    ;;
  WARN)
    echo "⚠️  guardrail WARN (score=$SCORE). Reason:"
    echo "$VERDICT_JSON" | python -c "import sys,json; r=json.load(sys.stdin); [print('  -',x) for x in r.get('findings',[])]"
    read -p "Continue anyway? [y/N] " yn
    [ "$yn" = "y" ] && cast send "$TARGET" "$CALLDATA" --value "$VALUE" \
      --rpc-url "$RPC" --private-key "$AGENT_PRIVATE_KEY"
    ;;
  BLOCK)
    echo "🛑 guardrail BLOCK (score=$SCORE). Aborted."
    echo "$VERDICT_JSON" | python -c "import sys,json; r=json.load(sys.stdin); [print('  -',x) for x in r.get('findings',[])]"
    exit 4
    ;;
esac
```

## 3. Practical recommendations

- Use guardrail by default for the **swap** step (DODO calldata is opaque).
- For CCTP `depositForBurn` and `receiveMessage`, the addresses are verified in `assets/cctp-domains.json`. The guardrail's value here is mainly confirming the agent hasn't been tricked into using a wrong address (e.g. a phishing edit to assets).
- Always run the guardrail on Pharos-side txs. EVM majors don't have a Pharos-specific guardrail; for those, rely on the safety-contract checks in §0 of [02-cctp-bridge-out.md](02-cctp-bridge-out.md) and [03-cctp-bridge-in.md](03-cctp-bridge-in.md).

## 4. Without the guardrail installed

If the guardrail skill is not installed, this skill still works. The safety-contract pre-flight checks (balance, allowance, target exists, sane calldata) provide a baseline. The guardrail adds additional inspection (`cast 4byte` decode of selectors, simulation, value-vs-balance ratio, etc.).

The agent should detect availability:
```bash
if command -v pharos-tx-guardrail >/dev/null 2>&1; then
  USE_GUARDRAIL=1
else
  USE_GUARDRAIL=0
  echo "(guardrail not installed — proceeding with built-in pre-flight only)"
fi
```

## 5. Cross-reference

See [pharos-tx-guardrail/references/tx-guardrail.md](https://github.com/hosein-ul/pharos-tx-guardrail/blob/main/references/tx-guardrail.md) for the full 6-check pipeline and dangerous-selector database.
