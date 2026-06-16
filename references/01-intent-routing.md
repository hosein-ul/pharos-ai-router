# Reference 01 — Intent routing

This file tells the agent how to parse a user message into a structured intent and route it to the correct reference file.

---

## 1. Intent schema

Every user message produces this struct in the agent's head:

```
{
  action:        "bridge" | "swap" | "convert" | "status" | "balance" | "quote",
  source_chain:  string | null,
  dest_chain:    string | null,
  token_in:      "USDC" | "PROS" | "PHRS" | "USDT" | "WETH" | string,
  token_out:     same enum or null,
  amount:        string,           // human-readable, e.g. "10" or "0.5"
  amount_unit:   "USDC" | "PROS" | "ETH" | "wei" | "raw",
  recipient:     "0x..." | "self", // "self" = sender address
  tx_hash:       "0x..." | null    // for status / recovery intents
}
```

Source/dest chains are the keys in `assets/networks.json` → `networks`: `pharos | ethereum | base | arbitrum | optimism | polygon | avalanche`.

## 2. Parsing rules

The agent parses by these rules, in order:

| User says | Sets |
|---|---|
| "from pharos to base" | source=pharos, dest=base |
| "to base" without source | source=defaultSource (pharos), dest=base |
| "from base" without dest | source=base, dest=defaultDestination (depends on intent) |
| "bridge" | action=bridge, token_in=token_out=USDC |
| "swap A for B" | action=swap, token_in=A, token_out=B |
| "convert A to B on X" | action=convert (swap+bridge), token_in=A, token_out=B, dest=X |
| "send 10 USDC to base" | action=bridge, amount=10 |
| "where are my USDC" | action=balance, token=USDC |
| "what's the route" | action=quote (dry-run) |
| "status of tx 0x..." | action=status, tx_hash=0x... |
| "0x...abc...def" recipient | recipient=that address |
| "to my wallet" or no recipient | recipient=self |

Number disambiguation: `"10 USDC"` → amount=10, unit=USDC. Convert to raw via `amount * 10**decimals` using `assets/tokens.json`.

## 3. Decision tree

```
if action == "balance":
    → load tokens.json, iterate each chain in networks.json
    → on each chain: cast call USDC.balanceOf(self) --rpc-url <rpc>
    → aggregate, report total + per-chain breakdown
    → see "Balance discovery" below

if action == "quote":  # dry-run, no spend
    → mimic the path the real action would take
    → report: estimated gas, expected output, slippage, finality time
    → DO NOT broadcast any tx

if action == "status" and tx_hash present:
    → see references/07-status-and-recovery.md

if action == "bridge":
    if source == "pharos":   → references/02-cctp-bridge-out.md
    else:                    → references/03-cctp-bridge-in.md

if action == "swap":
    if source == "pharos" and dest == "pharos":  → references/04-faroswap-swap.md
    else: ERROR — cross-chain swap requires "convert" intent

if action == "convert":
    → references/06-multi-hop.md
```

## 4. Balance discovery

Run this when user asks "where are my USDC" / "what do I hold" / "show balance":

```bash
NETWORKS=$(jq -r '.networks | keys[]' assets/networks.json)
WALLET="${AGENT_ADDRESS:?must be set}"

echo "USDC balance across chains for $WALLET"
echo "----------------------------------------"
for net in $NETWORKS; do
  RPC=$(jq -r ".networks.$net.rpcUrl" assets/networks.json)
  USDC=$(jq -r ".usdc.$net.address // empty" assets/tokens.json)
  [ -z "$USDC" ] && continue

  BAL_HEX=$(cast call "$USDC" "balanceOf(address)(uint256)" "$WALLET" --rpc-url "$RPC" 2>/dev/null)
  [ -z "$BAL_HEX" ] && BAL="rpc error" || BAL=$(python -c "print(int('$BAL_HEX'.split()[0]) / 1e6)")
  printf "  %-12s %s USDC\n" "$net" "$BAL"
done
```

Report format:
```
USDC balance for 0xAbc...123
  pharos        25.50 USDC
  base         100.00 USDC
  ethereum       0.00 USDC
  arbitrum      45.00 USDC
  ─────────────────────────
  TOTAL        170.50 USDC
```

## 5. Dry-run quote

For "what would it cost to bridge 100 USDC from pharos to base":

1. Read amount, decimals.
2. Look up CCTP V2 fee: Standard Transfer = 0 (no Circle fee).
3. Estimate source gas: `cast estimate <TokenMessenger> "depositForBurn(...)" ...` * `cast gas-price`.
4. Estimate destination gas: same on dest chain for receiveMessage.
5. Convert gas to USD via Chainlink (Pharos has feeds; on EVM majors use cached snapshot or external API).
6. Report:
```
Quote: bridge 100 USDC pharos → base
  CCTP V2 mode:       Standard (0 protocol fee)
  Pharos burn gas:    ~0.0001 PROS ($0.004)
  Base mint gas:      ~0.0005 ETH ($1.85)
  Expected finality:  8-15 min (Standard Transfer)
  Total cost:         ~$1.85
  You receive:        100.00 USDC on Base
```

## 6. Error pre-checks

Before routing to action references, validate:

| Check | Failure |
|---|---|
| Source chain exists in `networks.json` | Reject with list of valid chains |
| Dest chain exists in `cctp-domains.json` (if bridge) | Reject — not a CCTP chain |
| `AGENT_PRIVATE_KEY` is set in env | Reject — cannot sign |
| Amount > 0 | Reject |
| Recipient address is valid (40 hex chars) | Reject |
| Source chain RPC reachable: `cast block-number --rpc-url $RPC` | Warn user, retry with backoff |

If all green, hand off to the referenced action doc.

## 7. Routing examples

| User says | Action | Loads |
|---|---|---|
| "bridge 10 USDC from pharos to base" | bridge, src=pharos, dst=base, amt=10 | 02-cctp-bridge-out.md |
| "send 50 USDC to my wallet on arbitrum" | bridge, src=pharos (default), dst=arbitrum, amt=50, rcp=self | 02-cctp-bridge-out.md |
| "swap 5 PROS to USDC" | swap, src=pharos, dst=pharos, tokens=PROS/USDC | 04-faroswap-swap.md |
| "convert 10 PROS to USDC on Polygon" | convert (swap+bridge) | 06-multi-hop.md |
| "where do I have USDC" | balance | this file, §4 |
| "status of 0xabc..." | status | 07-status-and-recovery.md |
