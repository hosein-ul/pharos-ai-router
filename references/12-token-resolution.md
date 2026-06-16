# Reference 12 — Token resolution & verification (anti-scam)

**Rule:** Never trust a third-party API to resolve a token symbol to an address. Always resolve symbols to checksummed addresses **first**, pass addresses to the API, then **verify the response uses the same addresses you sent**.

If the verification fails, **ABORT**. A mismatched address means either the API is buggy, the registry is stale, or someone is trying to substitute a scam token. There is no legitimate scenario where the agent should silently proceed.

This file is consumed by every action that takes a token symbol from the user.

---

## 1. The resolution function

```bash
# Resolve a (symbol, chain) pair to a checksummed address from the canonical registry.
# Returns 0 (success) with the address on stdout, or 1 (failure) with a reason on stderr.
#
# Usage: ADDR=$(resolve_token USDC 8453) || exit 1
resolve_token() {
  local SYM="$1"
  local CHAIN_ID="$2"
  local REG="assets/token-registry.json"

  local ADDR
  ADDR=$(python -c "
import json, sys
reg = json.load(open('$REG'))
tok = reg['tokens'].get('$SYM')
if tok is None:
    print(f'unknown symbol: $SYM', file=sys.stderr); sys.exit(1)
addr = tok.get('$CHAIN_ID')
if addr is None:
    print(f'$SYM not registered on chain $CHAIN_ID', file=sys.stderr); sys.exit(1)
print(addr)
")
  if [ -z "$ADDR" ]; then return 1; fi
  echo "$ADDR"
}

# Resolve the decimals for a symbol (chain-independent for these tokens)
resolve_decimals() {
  local SYM="$1"
  python -c "
import json
reg = json.load(open('assets/token-registry.json'))
print(reg['tokens'].get('$SYM',{}).get('_decimals', 18))
"
}
```

## 2. The verification function (post-quote)

```bash
# After LI.FI returns a quote, confirm the action.fromToken.address and
# action.toToken.address match what we passed. If LI.FI substituted a
# different address, abort.
#
# Usage: verify_quote_tokens "$QUOTE_JSON" "$EXPECTED_FROM_ADDR" "$EXPECTED_TO_ADDR"
verify_quote_tokens() {
  local QUOTE="$1"
  local EXPECTED_FROM="$2"
  local EXPECTED_TO="$3"

  python <<EOF
import json, sys
q = json.loads('''$QUOTE''')
act = q.get('action', {})
got_from = (act.get('fromToken', {}).get('address') or '').lower()
got_to   = (act.get('toToken',   {}).get('address') or '').lower()
exp_from = '$EXPECTED_FROM'.lower()
exp_to   = '$EXPECTED_TO'.lower()

if got_from != exp_from:
    print(f'TOKEN MISMATCH (from): expected {exp_from} got {got_from}', file=sys.stderr)
    sys.exit(2)
if got_to != exp_to:
    print(f'TOKEN MISMATCH (to): expected {exp_to} got {got_to}', file=sys.stderr)
    sys.exit(2)
print('tokens verified', file=sys.stderr)
EOF
}
```

## 3. The full pattern (use this in every bridge / swap flow)

```bash
# Inputs from user
SYM_IN="USDC"
SYM_OUT="USDC"
CHAIN_IN=1672    # Pharos
CHAIN_OUT=8453   # Base
AMOUNT_HUMAN="10"
SENDER=$(cast wallet address "$AGENT_PRIVATE_KEY")

# STEP 1: Resolve symbols to addresses LOCALLY
ADDR_IN=$(resolve_token "$SYM_IN"  "$CHAIN_IN")  || { echo "no $SYM_IN on $CHAIN_IN";  exit 1; }
ADDR_OUT=$(resolve_token "$SYM_OUT" "$CHAIN_OUT") || { echo "no $SYM_OUT on $CHAIN_OUT"; exit 1; }
DEC_IN=$(resolve_decimals "$SYM_IN")
AMOUNT_RAW=$(python -c "print(int(float('$AMOUNT_HUMAN') * 10**$DEC_IN))")

echo "resolved: $SYM_IN on chain $CHAIN_IN = $ADDR_IN"
echo "resolved: $SYM_OUT on chain $CHAIN_OUT = $ADDR_OUT"

# STEP 2: Pass ADDRESSES (not symbols) to LI.FI
URL="https://li.quest/v1/quote?fromChain=$CHAIN_IN&toChain=$CHAIN_OUT"
URL="$URL&fromToken=$ADDR_IN&toToken=$ADDR_OUT"
URL="$URL&fromAmount=$AMOUNT_RAW&fromAddress=$SENDER"
QUOTE=$(curl -s "$URL")

# STEP 3: Verify the response used the addresses we sent
verify_quote_tokens "$QUOTE" "$ADDR_IN" "$ADDR_OUT" || {
  echo "ABORT: token address mismatch in LI.FI response. Possible scam or stale registry."
  exit 2
}

# STEP 4: Now safe to extract transactionRequest and broadcast
# (continue with 09-lifi-bridge.md)
```

## 4. When the user gives an address instead of a symbol

If the user pastes `0x...` directly, **don't** look it up in the registry — use it as-is, but **warn** if it's not in the registry:

```bash
if [[ "$INPUT" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
  # raw address — pass through, optionally warn
  REGISTERED=$(python -c "
import json
reg = json.load(open('assets/token-registry.json'))
for sym, t in reg['tokens'].items():
    if t.get('$CHAIN_ID','').lower() == '$INPUT'.lower():
        print(sym); break
")
  if [ -z "$REGISTERED" ]; then
    echo "WARN: $INPUT is not in our token registry. Proceed only if you trust it."
  else
    echo "address recognized as $REGISTERED"
  fi
  ADDR_IN="$INPUT"
fi
```

## 5. When a corridor needs a token NOT in our registry

For tokens like `USDT0` on chains we don't yet have registered, the agent must look up the address via LI.FI's `/tokens` endpoint at runtime, but should **prompt the user** for confirmation before using the discovered address:

```bash
# Fetch from LI.FI live
DISCOVERED=$(curl -s "https://li.quest/v1/tokens?chains=$CHAIN_OUT" \
  | python -c "
import sys, json
for t in json.load(sys.stdin).get('tokens',{}).get('$CHAIN_OUT',[]):
    if t.get('symbol','').upper() == 'USDT0':
        print(t['address']); break
")

if [ -n "$DISCOVERED" ]; then
  echo "LI.FI advertises USDT0 on chain $CHAIN_OUT at $DISCOVERED."
  echo "This address is NOT in our local registry. Continue? [y/N]"
  read confirm
  [ "$confirm" = "y" ] || exit 1
  ADDR_OUT="$DISCOVERED"
fi
```

## 6. Pre-flight sanity checks (on top of address resolution)

Before any `cast send`, even with a verified address, the agent should:

1. `cast code $ADDR_IN --rpc-url $RPC` — confirm contract exists (non-empty bytecode)
2. `cast call $ADDR_IN "symbol()(string)" --rpc-url $RPC` — confirm the on-chain symbol matches what the user asked for. If `USDC` on-chain comes back as `Tether USD`, abort.
3. `cast call $ADDR_IN "decimals()(uint8)" --rpc-url $RPC` — confirm decimals match the registry.

```bash
sanity_check_token() {
  local ADDR="$1" RPC="$2" EXPECTED_SYM="$3" EXPECTED_DEC="$4"
  local CODE_LEN ONCHAIN_SYM ONCHAIN_DEC
  CODE_LEN=$(cast code "$ADDR" --rpc-url "$RPC" 2>/dev/null | wc -c)
  [ "$CODE_LEN" -lt 100 ] && { echo "ABORT: no contract at $ADDR"; return 1; }

  if [ "$ADDR" != "0x0000000000000000000000000000000000000000" ]; then
    ONCHAIN_SYM=$(cast call "$ADDR" "symbol()(string)" --rpc-url "$RPC" 2>/dev/null | tr -d '"')
    ONCHAIN_DEC=$(cast call "$ADDR" "decimals()(uint8)" --rpc-url "$RPC" 2>/dev/null)
    if [ -n "$ONCHAIN_SYM" ] && [ "$ONCHAIN_SYM" != "$EXPECTED_SYM" ]; then
      echo "ABORT: on-chain symbol '$ONCHAIN_SYM' != expected '$EXPECTED_SYM' for $ADDR"
      return 1
    fi
    if [ -n "$ONCHAIN_DEC" ] && [ "$ONCHAIN_DEC" != "$EXPECTED_DEC" ]; then
      echo "ABORT: on-chain decimals $ONCHAIN_DEC != expected $EXPECTED_DEC for $ADDR"
      return 1
    fi
  fi
  return 0
}
```

This is the **last line of defense** against a registry that's been tampered with. Even if `token-registry.json` has been edited maliciously, the on-chain `symbol()` and `decimals()` calls would catch the mismatch.

## 7. Composition with the rest of the skill

Order of operations for every bridge / swap intent:

```
1. resolve_token (this file)
2. sanity_check_token (this file)  ← optional but recommended
3. quote via LI.FI / CCTP / Faroswap (refs 09 / 02 / 03 / 04)
4. verify_quote_tokens (this file)
5. rank-routes (ref 10)
6. user confirmation
7. pharos-tx-guardrail check (ref 08)
8. approve (exact amount, never MAX_UINT256)
9. cast send (broadcast)
10. poll status (ref 05 for CCTP, ref 09 for LI.FI)
```

Skipping step 1 or step 4 is the most common scam vector. Never skip them.
