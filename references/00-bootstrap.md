# Reference 00 — Agent self-bootstrap

**This file is for you, the AI agent.** The user doesn't read it. If you're loading this skill for the first time, follow these steps before doing anything else.

The whole point is: **the user should not be asked to install anything.** You install what you need yourself.

---

## 1. Tools you need

Three command-line tools are required:

| Tool | What for | How to check |
|---|---|---|
| `cast` (Foundry) | reads on-chain state and signs/sends transactions | `cast --version` |
| `curl` | hits LI.FI, DODO, Iris APIs | `curl --version` |
| `python` (3.x) | JSON parsing in helper scripts | `python --version` or `python3 --version` |

`curl` and `python` are on virtually every modern OS. The only one you might need to install is `cast`.

## 2. Installing `cast` if it's missing

If `cast --version` fails on the user's shell, install Foundry quietly:

```bash
# One-liner — installs Foundry binaries to ~/.foundry/bin
curl -L https://foundry.paradigm.xyz | bash

# Adds binaries to PATH for this shell
source ~/.bashrc || source ~/.zshrc || true
export PATH="$HOME/.foundry/bin:$PATH"

# Activates the toolchain (downloads cast, forge, anvil)
foundryup
```

Don't ask the user "do you want to install Foundry?" — just install it. It's tiny, well-known, and doesn't touch system files outside `~/.foundry`.

If the install fails (no curl, sandboxed shell, etc.), then surface a clear message to the user with the install URL: `https://book.getfoundry.sh/getting-started/installation`.

## 3. Network endpoints — no setup needed

These are all open and require no API keys:

| Endpoint | Use | Auth |
|---|---|---|
| `https://rpc.pharos.xyz` | Pharos mainnet RPC (chain 1672) | none |
| `https://atlantic.dplabs-internal.com` | Pharos testnet RPC (chain 688689) | none |
| `https://li.quest/v1` | LI.FI quote / status / chains | none for 200 req / 2hr |
| `https://iris-api.circle.com/v2` | CCTP V2 attestation | none |
| EVM-major RPCs | bridging destinations | see `assets/networks.json` |

All are already in `assets/networks.json` and `assets/lifi.json`. Don't ask the user for any URL.

## 4. Wallet Onboarding — Default Creation & Alternatives

For **read-only** actions (balance, quote, status check) you don't need a key. When the user needs to execute state-changing actions (bridge, swap, deposit) and `AGENT_PRIVATE_KEY` is missing in the environment:

### Default Path: Automated Wallet Generation
1. Generate a new private key and address using `cast wallet new --json` (or python ecdsa key generation if cast fails).
2. Save/persist it locally in a `.env` file in the root directory of this skill (e.g. `AGENT_PRIVATE_KEY=0x...`) so it persists across agent sessions. Make sure `.env` is listed in `.gitignore` so it is never committed.
3. Print the generated **agent wallet address** to the user.
4. Instruct the user clearly to **fund this address** with native gas tokens (e.g., PROS on Pharos, ETH on Base) and the tokens they wish to swap/bridge.
5. Emphasize that they should back up the private key printed once.

### Alternative Paths
If the user prefers not to use the auto-generated wallet, present these alternatives:
1. **Existing Private Key**: Tell the user they can manually set `AGENT_PRIVATE_KEY` in their system environment variables or write it to the `.env` file directly.
2. **Developer Controlled Wallets (DCW) / MPC (e.g., Circle DCW)**: Explain that Circle Developer Controlled Wallets allow managing wallets programmatically via API keys without storing raw private keys locally. (Note: Pharos is currently not natively supported by Circle DCW, but major chains like Base/Arbitrum are).

## 5. What to do after bootstrap

Once `cast`, `curl`, and `python` are all available, tell the user **what you can now help with** in plain language. Example:

> Pharos Agent Skill installed and ready. I can:
>
> - quote the cheapest way to move USDC between Pharos and Base / Ethereum / Arbitrum / Optimism / Polygon / Avalanche
> - swap any token-pair on Pharos via Faroswap, or cross-chain via LI.FI (PROS on Pharos to USDC on Base in about 13 seconds)
> - read your USDC balances on every supported chain at once
> - check the status of a stuck bridge and finish the mint if it's ready
>
> What would you like to do?

That's the user's first useful interaction. Don't dump file paths or technical setup at them.

## 6. Failure modes & graceful degradation

| If… | Then… |
|---|---|
| `cast` install fails | Tell user: "I need Foundry's `cast` to do on-chain reads and signing. Install instructions: https://book.getfoundry.sh/getting-started/installation. Then ask me to set up again." |
| RPC for chain X is down | Try the alternate RPC in `assets/networks.json`, then warn user if both fail |
| LI.FI returns 429 | Back off 30 sec and retry once. Tell user "LI.FI is rate-limited right now, retrying in 30 sec." |
| LI.FI says "no quote" | Tell the user that pair isn't supported and offer alternatives from the verified PROS corridor matrix |
| AGENT_PRIVATE_KEY missing | Stop before sending. Tell user how to set it (env var only — never paste in chat). |

Recover quietly when possible, surface to the user only when you can't.

## 7. One-time vs every-session

These bootstrap actions are **session-level**: check tools at the start of each new session, install if missing, then proceed. Don't re-install on every command — that's wasted user time.

Cache nothing about the user's key. Cache no persistent state beyond what the user sees in their terminal scrollback.
