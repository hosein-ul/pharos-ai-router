# Reference 06 — Multi-hop intents (swap then bridge, bridge then swap)

When the user wants something like "convert 5 PROS to USDC on Arbitrum", the agent must chain a Faroswap swap (on Pharos) with a CCTP bridge (Pharos → Arbitrum). This reference defines how to sequence those steps safely.

---

## 1. Intent shapes that route here

| User says | Plan |
|---|---|
| "convert N PROS to USDC on \<chain\>" | swap PROS→USDC on Pharos, then CCTP bridge to \<chain\> |
| "swap my N PROS for USDC on Base" | same as above |
| "give me USDC on Arbitrum from my PROS" | same |
| "bring N USDC from Base into R25 vault" | bridge USDC base→pharos (this skill), then yield-router deposits (companion skill) |

Step types:

- `S_SWAP_PHAROS` — Faroswap swap on Pharos, per [04-faroswap-swap.md](04-faroswap-swap.md)
- `S_BRIDGE_OUT` — Pharos USDC → other chain, per [02-cctp-bridge-out.md](02-cctp-bridge-out.md)
- `S_BRIDGE_IN` — other chain USDC → Pharos, per [03-cctp-bridge-in.md](03-cctp-bridge-in.md)

The legal multi-hop plans in V1:

| Source token | Source chain | Destination token | Destination chain | Plan |
|---|---|---|---|---|
| PROS | Pharos | USDC | EVM chain ≠ Pharos | [S_SWAP_PHAROS(PROS→USDC), S_BRIDGE_OUT] |
| USDC | EVM chain | PROS | Pharos | [S_BRIDGE_IN, S_SWAP_PHAROS(USDC→PROS)] |
| USDT/WETH | Pharos | USDC | EVM chain | [S_SWAP_PHAROS(→USDC), S_BRIDGE_OUT] |

## 2. Pre-flight checks for the entire plan

Run **all** of these before executing **any** step:

1. Sender's balance covers `step_1.input_amount` in `step_1.input_token`.
2. Sender has gas on every chain the plan touches.
3. Each chain's RPC responds (`cast block-number`).
4. Expected output of step N is sufficient input for step N+1 (use dry-run quotes).
5. Sum of all gas + fees < some sensible threshold (e.g. < 5% of total amount unless user overrides with `--accept-fees`).

If any check fails: abort the whole plan, report which check failed. No partial execution.

## 3. Sequencing rules

- **No parallelism.** Each step waits for the previous to fully complete (including attestation for bridges).
- **Checkpointing.** After each step, persist `{step_index, tx_hash, output_amount}` to stdout in a deterministic format the agent can re-read.
- **Idempotence.** A step never resends a tx if it has the same intent + a recent successful tx hash for the same params.

Example checkpoint log line:
```
CHECKPOINT step=1 type=S_SWAP_PHAROS in=5_PROS out=4.91_USDC tx=0xabc... ts=2026-06-17T10:23:14Z
```

## 4. Example flow: 5 PROS → USDC on Arbitrum

```bash
PHAROS_RPC=$(jq -r '.networks.pharos.rpcUrl' assets/networks.json)
SENDER=$(cast wallet address "$AGENT_PRIVATE_KEY")
USDC_PHAROS=$(jq -r '.usdc.pharos.address' assets/tokens.json)

# Step 1: swap 5 PROS → USDC on Pharos (Faroswap)
echo "STEP 1: swap 5 PROS → USDC on Pharos"
USDC_BEFORE_HEX=$(cast call "$USDC_PHAROS" "balanceOf(address)(uint256)" "$SENDER" --rpc-url "$PHAROS_RPC")
USDC_BEFORE=$(python -c "print(int('$USDC_BEFORE_HEX'.split()[0]))")

# (run the swap, per 04-faroswap-swap.md)
bash references/_runner_swap.sh PROS USDC 5 100

# Read post-swap balance to get exact output
USDC_AFTER_HEX=$(cast call "$USDC_PHAROS" "balanceOf(address)(uint256)" "$SENDER" --rpc-url "$PHAROS_RPC")
USDC_AFTER=$(python -c "print(int('$USDC_AFTER_HEX'.split()[0]))")
GOT_USDC=$((USDC_AFTER - USDC_BEFORE))

echo "  got: $(python -c "print($GOT_USDC / 1e6)") USDC"
echo "CHECKPOINT step=1 type=S_SWAP_PHAROS in=5_PROS out=$(python -c "print($GOT_USDC / 1e6)")_USDC"

# Step 2: bridge the received USDC to Arbitrum
echo "STEP 2: bridge USDC pharos → arbitrum"
# pass GOT_USDC as raw (already 6-decimal) — bridge-out reads human form so convert back
HUMAN_AMOUNT=$(python -c "print($GOT_USDC / 1e6)")
bash references/_runner_bridge_out.sh arbitrum "$HUMAN_AMOUNT"

echo "CHECKPOINT step=2 type=S_BRIDGE_OUT in=${HUMAN_AMOUNT}_USDC dest=arbitrum"
echo "DONE"
```

(`_runner_*.sh` are thin wrappers around the snippets in the corresponding reference docs; the agent doesn't need scripts on disk — these are just labels for the actions described in those docs.)

## 5. Failure handling

If step 1 (swap) fails:
- Nothing is in motion. Report failure, original PROS still in wallet. No recovery needed.

If step 1 succeeds, step 2 (burn) fails:
- USDC is in wallet on Pharos. User has the option to:
  - Retry step 2 with current USDC balance.
  - Keep the USDC on Pharos (intent partially satisfied: "got USDC, just not on the dest chain").
- Report both options.

If step 2 burn succeeds, attestation polling times out:
- USDC is burned on Pharos, attestation in flight. User has the option to:
  - Re-run status check later (see [07-status-and-recovery.md](07-status-and-recovery.md)).
  - Burn is irreversible at this point — the mint will eventually succeed.

If receiveMessage on destination fails:
- Have a valid `(message, attestation)` pair. Retry on destination, or pass to a relayer.

## 6. Reverse direction example: USDC on Base → PROS on Pharos

Plan: `[S_BRIDGE_IN(base→pharos, USDC), S_SWAP_PHAROS(USDC→PROS)]`

```
STEP 1: bridge X USDC base → pharos     (see 03-cctp-bridge-in.md)
  → wait for attestation
  → mint on pharos
  → checkpoint: USDC arrived on pharos
STEP 2: swap X USDC → PROS on pharos    (see 04-faroswap-swap.md)
  → checkpoint: got Y PROS
DONE
```

## 7. Report to user (multi-hop summary)

```
Converted 5 PROS → 4.91 USDC on Arbitrum
  step 1/2  swap   5 PROS → 4.91 USDC on pharos
                   tx 0xabc...  (https://pharosscan.xyz/tx/0xabc)
  step 2/2  bridge 4.91 USDC pharos → arbitrum (CCTP V2)
                   burn 0xdef...  (https://pharosscan.xyz/tx/0xdef)
                   attestation 9m 17s
                   mint 0xghi...  (https://arbiscan.io/tx/0xghi)
  total time:    14 min
  total cost:    ~$2.10 (0.01 PROS + 0.0006 ETH)
  recipient:     0xRecipient...
  new arbitrum USDC balance: 9.91 USDC
```
