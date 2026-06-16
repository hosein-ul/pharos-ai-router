# Reference 10 — Route selection: CCTP vs LI.FI vs Faroswap

When the user's intent could be served by more than one path, the agent uses this decision rule to pick the **best** route — favoring **lower fee**, **shorter execution**, and **non-custodial Circle-native USDC** where applicable.

---

## 1. Decision table

```
intent: move(amount, in_token, in_chain) → (out_token, out_chain)
```

| `in_token` | `out_token` | `in_chain` | `out_chain` | Best route | Reason |
|---|---|---|---|---|---|
| USDC | USDC | pharos | EVM major | **CCTP V2** ([02](02-cctp-bridge-out.md)) | zero fee, official |
| USDC | USDC | EVM major | pharos | **CCTP V2** ([03](03-cctp-bridge-in.md)) | zero fee, official |
| USDC | USDC | EVM major A | EVM major B (neither pharos) | **LI.FI** ([09](09-lifi-bridge.md)) | this skill's scope is Pharos-centric; for non-Pharos pairs LI.FI is the universal router |
| PROS | USDC | pharos | EVM major | **LI.FI Intents** ([09](09-lifi-bridge.md)) | atomic in ~13 sec; manual swap+bridge takes 15+ min |
| USDC | PROS | EVM major | pharos | **LI.FI Intents** ([09](09-lifi-bridge.md)) | atomic |
| PROS | USDC | pharos | pharos | **Faroswap** ([04](04-faroswap-swap.md)) | same-chain swap, no bridge needed |
| USDC | PROS | pharos | pharos | **Faroswap** ([04](04-faroswap-swap.md)) | same-chain swap |
| LINK / WETH / USDCe | USDC | pharos | EVM major | **LI.FI** ([09](09-lifi-bridge.md)) | CCTP only carries USDC |
| any token | any token | EVM major A | EVM major B | **LI.FI** ([09](09-lifi-bridge.md)) | universal router |
| PROS | ETH | pharos | arbitrum | **LI.FI** if available, else fall back to Faroswap (PROS→USDC) + CCTP (USDC→arb) + LI.FI (USDC→ETH on arb) | depends on liquidity |

## 2. Algorithmic version

```
def pick_route(in_token, out_token, in_chain, out_chain):
    if in_chain == out_chain == 'pharos':
        return Faroswap   # ref 04

    if in_token == out_token == 'USDC':
        if 'pharos' in (in_chain, out_chain):
            return CCTP_V2   # ref 02 / 03
        else:
            return LiFi      # ref 09

    if (in_token == 'PROS' or out_token == 'PROS') and in_chain != out_chain:
        return LiFi_Intents  # ref 09 (preferred — atomic, seconds)
        # fallback: ref 06 multi-hop (Faroswap then CCTP)

    if in_token == 'USDC' and out_token != 'USDC' and out_chain == 'pharos':
        # bridge USDC in via CCTP, then swap on Pharos
        return [CCTP_V2_in, Faroswap]   # multi-hop, ref 06

    if in_token != 'USDC' and out_token == 'USDC' and in_chain == 'pharos':
        # swap on Pharos, then bridge USDC out via CCTP
        return [Faroswap, CCTP_V2_out]  # multi-hop, ref 06
        # OR single-shot LI.FI Intents if available

    # everything else
    return LiFi   # ref 09
```

## 3. When the agent should try a fallback

CCTP attestation polling timed out after 20 min (rare on Pharos but possible) — **don't** re-burn. Either:
- Wait longer (attestation may still come; message+attestation pair is valid forever)
- Hand the user a `(message, attestation)` once Iris catches up

If the user can't wait, **don't** fall through to LI.FI for the **same USDC** — the funds are already burned on the source. LI.FI cannot un-burn them. The only path is to mint on the destination via `receiveMessage` whenever the attestation arrives.

For a **new** USDC transfer where the source has had repeated CCTP issues in the same session, the agent can ask the user: "CCTP looks slow today — want me to use LI.FI's Polymer route instead? It's 0.25% fee but skips Circle's attestation step."

## 4. Cost & time table (rough)

| Route | Fee | Time | Custody |
|---|---|---|---|
| CCTP V2 Standard | $0 protocol + gas | 8–15 min | non-custodial (Circle attestation) |
| LI.FI Intents | varies by route (often 0.1–0.3%) | seconds–1 min | non-custodial |
| LI.FI Polymer Standard | ~0.25% | ~18 min | non-custodial |
| LI.FI Glacis | varies | 5–20 min | non-custodial |
| Faroswap (same-chain) | DEX fees (~0.1–0.3%) | seconds | non-custodial |

Gas costs are extra on every route. Pharos gas is cheap (sub-cent). Destination EVM-major gas varies.

## 5. Quote both, let the user pick

When the user says "what's the best route for X→Y", the agent should quote both:

```bash
# CCTP path (if applicable): estimate gas only, no protocol fee
# LI.FI path: hit /quote, read estimate.toAmount and estimate.executionDuration
```

Then present:
```
Two routes available for 10 USDC pharos → base:
  1. CCTP V2 Standard    fee $0.00    you receive 10.00 USDC   eta 8-15 min
  2. LI.FI Polymer       fee $0.025   you receive  9.975 USDC  eta 18 min
Defaulting to CCTP V2 (cheaper). Override with --bridge lifi.
```

## 6. Skill-level defaults

- Default route for USDC↔USDC involving Pharos: **CCTP V2**
- Default route for cross-chain non-USDC or token-flip intents: **LI.FI Intents** when available, **LI.FI Polymer** otherwise
- Default same-chain swap on Pharos: **Faroswap** (via DODO Route API or wrap/unwrap fallback)

These defaults can be overridden by user input (e.g. "bridge using LI.FI") or by environment hints (e.g. `OMNICHAIN_PREFER=lifi`).
