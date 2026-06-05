#!/usr/bin/env python3
"""Vercel AI Gateway model browser formatter.
Read the gateway's /v1/models JSON from stdin, output formatted text with live pricing.

Vercel's schema differs from OpenRouter's: pricing is {input, output} per-token strings,
context is `context_window`, and provider max output is `max_tokens` — hence a separate
parser from or_models.py.

Usage: python3 vai_models.py [--search QUERY] [--free|--paid] [--sort cheap|max_tokens|name]
"""
import argparse
import json
import sys


def _fmt_ctx(ctx: int) -> str:
    if ctx >= 1_000_000:
        return f"{ctx // 1_000_000}M"
    if ctx >= 1000:
        return f"{ctx // 1000}k"
    return str(ctx)


def main():
    parser = argparse.ArgumentParser(description="Format Vercel AI Gateway models")
    parser.add_argument("--search", default="", help="Filter by name/ID substring")
    parser.add_argument("--free", action="store_true", help="Free models only")
    parser.add_argument("--paid", action="store_true", help="Paid models only")
    parser.add_argument("--sort", choices=["cheap", "max_tokens", "name"], default="name")
    parser.add_argument("--all-types", action="store_true",
                        help="Include image/video/reranking models (default: language only)")
    args = parser.parse_args()

    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit("error: no valid JSON on stdin — the Vercel AI Gateway fetch likely failed (network/HTTP error).")
    search = args.search.lower()
    filt = "free" if args.free else ("paid" if args.paid else "all")

    models = []
    for m in data.get("data", []):
        # Claude Code only drives text models; image/video/reranking just add noise
        # (and most show $0 because they're priced per-asset, not per-token, which
        # makes --free look absurdly large). Default to language-only.
        if not args.all_types and m.get("type") != "language":
            continue
        mid = m["id"]
        name = m.get("name", mid)
        p = m.get("pricing", {}) or {}
        # Per-token string prices → per-million floats. Missing price = treat as free.
        pin = float(p.get("input", 0) or 0) * 1_000_000
        pout = float(p.get("output", 0) or 0) * 1_000_000
        ctx = m.get("context_window", 0) or 0
        max_out = m.get("max_tokens", 0) or 0
        is_free = pin == 0 and pout == 0

        if filt == "free" and not is_free:
            continue
        if filt == "paid" and is_free:
            continue
        if search and search not in mid.lower() and search not in name.lower():
            continue

        if is_free:
            pricing = "\033[32mFREE\033[0m"
            sort_price = -1.0
        else:
            pricing = f"${pin:.2f}/M in  ${pout:.2f}/M out"
            sort_price = pin

        models.append({
            "id": mid,
            "name": name,
            "ctx": _fmt_ctx(ctx),
            "pricing": pricing,
            "sort_price": sort_price,
            "is_free": is_free,
            "max_tokens": max_out,
        })

    if args.sort == "cheap":
        models.sort(key=lambda x: (0 if x["is_free"] else 1, x["sort_price"]))
    elif args.sort == "max_tokens":
        models.sort(key=lambda x: -x["max_tokens"])
    else:
        models.sort(key=lambda x: x["id"])

    free_count = sum(1 for m in models if m["is_free"])
    paid_count = len(models) - free_count
    hr = "─" * 90  # horizontal rule, reused below
    print(f"  Found {len(models)} models ({free_count} free, {paid_count} paid)")
    print(f"  {hr}")
    for m in models:
        print(f"  {m['id']:<48s} {m['ctx']:>6s} ctx   {m['pricing']}")
    print(f"  {hr}")
    print(f"  Total: {len(models)} models")


if __name__ == "__main__":
    main()
