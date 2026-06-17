# Reference 13 — Wallet model & operational security

This skill assumes the AI agent has its **own dedicated wallet**, separate from the user's main wallet. This file documents how that key is provided, how it should be scoped, and what the user should expect.

---

## 1. The wallet model

The skill reads a single environment variable:

```
AGENT_PRIVATE_KEY=0x<64 hex chars>
```

`cast` consumes it via `--private-key` for every `send`. The key is never logged, persisted, or transmitted anywhere except to the local RPC endpoint as part of a signed transaction.

The address derived from the key is referred to as the **agent address**. All funds the skill moves come from this address. All bridged funds land at this address by default (the user can override `RECIPIENT` per call).

**This is intentionally a thin wallet model.** There is no key management, no rotation, no policy enforcement at the skill layer. The skill assumes the operator has already decided:

- What chain(s) to fund the agent address on
- How much capital to entrust to the agent
- How to revoke if the key leaks (transfer remaining funds out)

The skill is the executor, not the custodian.

## 2. Recommended provisioning

For real use:

1. **Generate a fresh key.** Never reuse a key that has ever held mainnet funds. `cast wallet new --json` works.
2. **Fund it minimally.** Treat the agent address as a hot wallet. Send only what you're willing to lose to a single mistake.
3. **One agent = one key.** Don't share `AGENT_PRIVATE_KEY` across multiple agents or sessions. If you run two skills, run them with two keys.
4. **Periodic sweep.** When an agent completes a task, transfer the remaining balance back to your cold wallet. The skill's `balance discovery` flow (see [01-intent-routing.md](01-intent-routing.md#balance-discovery)) makes this easy.
5. **Rotate after every public exposure.** If you ever paste the key in a logfile, screenshot, terminal-share, or AI chat, retire that key. Generate a new one. Sweep the old address.

## 3. What the agent will and will not do

| Action | Behavior |
|---|---|
| Read balances on any chain | ✅ always |
| Quote any route via LI.FI / CCTP / Faroswap | ✅ always (no key needed for read) |
| `approve` an exact amount before a swap | ✅ — scope is always `amount_raw`, never `MAX_UINT256` |
| `cast send` a tx the user just confirmed | ✅ |
| Sign a tx without user confirmation | ❌ never |
| Send to a recipient not in the intent | ❌ never |
| Approve a spender that doesn't appear in the route | ❌ never |
| Echo, log, or transmit the private key | ❌ never |

The user-confirmation step is explicit in [10-route-selection.md](10-route-selection.md#9-the-presentation-contract). The agent always shows the ranked routes, marks the recommendation, and waits for "yes" / route number before broadcasting.

## 4. Where this fits in the broader ecosystem

This thin-key model is the **simplest workable wallet for an agent on Pharos today**. It maps cleanly to:

- **Circle Agent Wallet** for chains Circle supports (Pharos is not in their list yet — see [`use-agent-wallet`](https://developers.circle.com/agent-stack/agent-wallets) Circle skill if you're also operating on Base / Arbitrum / Ethereum)
- **Coinbase AgentKit** / **Skyfire** / similar agent-wallet abstractions on EVM majors
- **ERC-4337 smart-account** session keys when Pharos's account-abstraction story matures

When Pharos has a native smart-wallet / session-key story, the skill can swap the env-var pattern for a `userOp`-based one. The reference docs that touch signing live in `02-cctp-bridge-out.md`, `03-cctp-bridge-in.md`, `04-faroswap-swap.md`, and `09-lifi-bridge.md` — those are the only places to update.

## 5. Wallet Initialization (How it is handled)

- **Default automated creation**: If `AGENT_PRIVATE_KEY` is missing in the environment, the agent will run `cast wallet new --json` (or generate it programmatically) to create a fresh hot wallet. It saves the key to `.env` in the skill's root directory (which must be listed in `.gitignore`), shows the address to the user, and asks them to fund it.
- **Out-of-band funding**: The user must fund this newly generated hot wallet with native gas tokens and assets.
- **Persistence**: The wallet is persisted locally in the `.env` file across sessions.
- **Headed/Headless operation**: The skill does **not** integrate with browser-extension wallets (MetaMask, Rabby, etc.) directly. Those are for humans. The agent uses the local file-based signing key for autonomous headless transactions.

## 6. Pre-flight (safety contract) on every state-changing call

The skill enforces these checks **before** every `cast send`:

1. `cast balance` of the source token on the source chain ≥ `amount_raw`. Abort if not.
2. `cast balance` of the **native gas token** on the source chain > 0. Abort if zero.
3. If `approve` is needed: read current allowance first. Skip approve if it's already ≥ `amount_raw`. Otherwise approve to **exactly** `amount_raw`.
4. Pass the planned tx through [`pharos-tx-guardrail`](https://github.com/hosein-ul/pharos-tx-guardrail) if installed ([08-safety-integration.md](08-safety-integration.md)).
5. Resolve and verify token addresses per [12-token-resolution.md](12-token-resolution.md) — abort on any mismatch.

The agent stops on the first failure with a human-readable reason, and never proceeds.

## 7. What you (the operator) sign up for

Running this skill means:

- The agent will move funds on your behalf, within the explicit confirmation flow, from the address derived from `AGENT_PRIVATE_KEY`.
- The agent will **not** move funds outside that flow.
- The agent will fail-safe on any address mismatch, balance shortfall, or guardrail-flagged risk.
- The key itself is your responsibility. The skill keeps it out of its own logs but cannot protect you from a compromised host, a wide-permission file on disk, or a careless screenshot.

When in doubt: less funding, fresher key, sweep more often.
