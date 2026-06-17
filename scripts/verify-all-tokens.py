#!/usr/bin/env python3
"""
Verifies every (symbol, chain, address) triple in assets/token-registry.json
by calling symbol() + decimals() on-chain through public RPCs.

Run from skill root:
    python scripts/verify-all-tokens.py
"""
import json
import sys
import urllib.request
import urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "assets" / "token-registry.json"

CHAIN_RPC = {
    "1":     ["https://ethereum.publicnode.com", "https://eth.drpc.org", "https://1rpc.io/eth", "https://cloudflare-eth.com"],
    "10":    ["https://optimism.publicnode.com", "https://optimism.drpc.org", "https://1rpc.io/op", "https://mainnet.optimism.io"],
    "137":   ["https://polygon-bor-rpc.publicnode.com", "https://polygon.drpc.org", "https://1rpc.io/plg", "https://polygon-rpc.com"],
    "8453":  ["https://mainnet.base.org", "https://base.drpc.org", "https://1rpc.io/base", "https://base.llamarpc.com"],
    "42161": ["https://arbitrum-one.publicnode.com", "https://arbitrum.drpc.org", "https://1rpc.io/arb", "https://arb1.arbitrum.io/rpc"],
    "43114": ["https://avalanche-c-chain.publicnode.com", "https://avalanche.drpc.org", "https://1rpc.io/avax", "https://api.avax.network/ext/bc/C/rpc"],
    "1672":  ["https://rpc.pharos.xyz"],
    "688689":["https://atlantic.dplabs-internal.com"],
}

UA = "Mozilla/5.0 (compatible; pharos-skill-verify/1.0)"

CHAIN_NAME = {
    "1": "ethereum", "10": "optimism", "137": "polygon",
    "8453": "base", "42161": "arbitrum", "43114": "avalanche",
    "1672": "pharos", "688689": "pharos-testnet",
}

ZERO = "0x0000000000000000000000000000000000000000"

def rpc_call(url, addr, data):
    payload = json.dumps({
        "jsonrpc": "2.0",
        "method": "eth_call",
        "params": [{"to": addr, "data": data}, "latest"],
        "id": 1,
    }).encode()
    req = urllib.request.Request(url, data=payload,
                                 headers={"Content-Type": "application/json", "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=3) as r:
        body = json.loads(r.read())
    return body.get("result", "")

def decode_string(hex_data: str) -> str:
    if not hex_data or hex_data == "0x" or len(hex_data) < 130:
        return ""
    try:
        length = int(hex_data[66:130], 16)
        raw = bytes.fromhex(hex_data[130:130 + length * 2])
        return raw.decode("utf-8", errors="replace").strip().replace("\x00", "")
    except Exception:
        return ""

def decode_uint(hex_data: str) -> int:
    if not hex_data or hex_data == "0x":
        return -1
    try:
        return int(hex_data, 16)
    except Exception:
        return -1

def check_token(expected_sym, chain_id, addr, expected_dec):
    rpcs = CHAIN_RPC.get(chain_id)
    chain_name = CHAIN_NAME.get(chain_id, chain_id)
    if not rpcs:
        return ("SKIP", f"no RPC for chain {chain_id}")

    if addr.lower() == ZERO:
        return ("OK", "native token (zero address)")

    last_err = None
    sym_hex = dec_hex = code_hex = None
    for rpc in rpcs:
        try:
            payload = json.dumps({"jsonrpc":"2.0","method":"eth_getCode",
                                  "params":[addr,"latest"],"id":1}).encode()
            req = urllib.request.Request(rpc, data=payload,
                                         headers={"Content-Type":"application/json","User-Agent":UA})
            code_hex = json.loads(urllib.request.urlopen(req, timeout=3).read()).get("result","") or ""
            if len(code_hex) < 100:
                last_err = f"empty bytecode via {rpc.split('//')[1].split('/')[0]}"
                code_hex = None
                continue
            sym_hex = rpc_call(rpc, addr, "0x95d89b41")
            dec_hex = rpc_call(rpc, addr, "0x313ce567")
            break
        except Exception as e:
            last_err = str(e)[:60]
            continue

    if code_hex is None:
        return ("RPC_ERR", last_err or "all RPCs failed")

    if len(code_hex) < 100:
        return ("FAIL", f"no contract at address (bytecode={len(code_hex)} chars)")

    got_sym = decode_string(sym_hex)
    got_dec = decode_uint(dec_hex)

    # Build the set of acceptable symbols (the registry key + any _aliases + _onchain_symbol)
    accept = {expected_sym.lower()}
    body = json.loads(REGISTRY.read_text(encoding="utf-8"))["tokens"].get(expected_sym, {})
    for a in body.get("_aliases", []):
        accept.add(a.lower())
    if body.get("_onchain_symbol"):
        accept.add(body["_onchain_symbol"].lower())

    sym_match = got_sym.lower() in accept
    dec_match = (expected_dec is None) or (got_dec == expected_dec)

    if sym_match and dec_match:
        return ("OK", f"symbol='{got_sym}' decimals={got_dec}")
    elif not sym_match:
        return ("MISMATCH_SYM", f"expected='{expected_sym}' got='{got_sym}' decimals={got_dec}")
    else:
        return ("MISMATCH_DEC", f"symbol='{got_sym}' expected_dec={expected_dec} got_dec={got_dec}")


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except AttributeError:
        pass
    reg = json.loads(REGISTRY.read_text(encoding="utf-8"))
    tokens = reg["tokens"]

    results = []
    print(f"{'TOKEN':10} {'CHAIN':14} {'ADDRESS':44} {'STATUS':14} DETAILS")
    print("-" * 110)

    for sym, body in tokens.items():
        expected_dec = body.get("_decimals")
        for k, v in body.items():
            if k.startswith("_") or not isinstance(v, str) or not v.startswith("0x"):
                continue
            chain_id = k
            addr = v
            status, detail = check_token(sym, chain_id, addr, expected_dec)
            chain_name = CHAIN_NAME.get(chain_id, chain_id)
            marker = {
                "OK": "[OK]",
                "FAIL": "[FAIL]",
                "MISMATCH_SYM": "[SYM_MISMATCH]",
                "MISMATCH_DEC": "[DEC_MISMATCH]",
                "RPC_ERR": "[RPC_ERR]",
                "SKIP": "[SKIP]",
            }.get(status, status)
            print(f"{sym:10} {chain_name:14} {addr:44} {marker:14} {detail}")
            results.append({"sym": sym, "chain": chain_name, "addr": addr, "status": status, "detail": detail})

    print()
    summary = {}
    for r in results:
        summary[r["status"]] = summary.get(r["status"], 0) + 1
    print(f"SUMMARY: {summary}")

    # Exit non-zero if any FAIL or MISMATCH
    bad = sum(c for s, c in summary.items() if s in ("FAIL", "MISMATCH_SYM", "MISMATCH_DEC"))
    sys.exit(0 if bad == 0 else 2)

if __name__ == "__main__":
    main()
