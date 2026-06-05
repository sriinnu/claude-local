#!/usr/bin/env python3
"""OpenRouter model browser formatter.
Read model listing JSON from stdin, output formatted text with ANSI colors.

Usage: python3 or_models.py [--search QUERY] [--free|--paid] [--sort cheap|max_tokens|name]
"""
import argparse
import json
import sys


def main():
    parser = argparse.ArgumentParser(description="Format OpenRouter models")
    parser.add_argument("--search", default="", help="Filter by name/ID substring")
    parser.add_argument("--free", action="store_true", help="Free models only")
    parser.add_argument("--paid", action="store_true", help="Paid models only")
    parser.add_argument("--sort", choices=["cheap", "max_tokens", "name"], default="name")
    args = parser.parse_args()

    data = json.load(sys.stdin)
    search = args.search.lower()
    filt = "free" if args.free else ("paid" if args.paid else "all")
    sort_by = args.sort

    models = []
    for m in data.get("data", []):
        mid = m["id"]
        name = m.get("name", mid)
        p = m.get("pricing", {})
        prompt_cost = float(p.get("prompt", 0) or 0)
        comp_cost = float(p.get("completion", 0) or 0)
        ctx = m.get("context_length", 0)
        is_free = prompt_cost == 0 and comp_cost == 0

        if filt == "free" and not is_free:
            continue
        if filt == "paid" and is_free:
            continue

        if search and search not in mid.lower() and search not in name.lower():
            continue

        if ctx >= 1_000_000:
            ctxs = f"{ctx // 1_000_000}M"
        elif ctx >= 1000:
            ctxs = f"{ctx // 1000}k"
        else:
            ctxs = str(ctx)

        if is_free:
            pricing = "\033[32mFREE\033[0m"
            sort_price = -1
        else:
            pin = prompt_cost * 1_000_000
            pout = comp_cost * 1_000_000
            pricing = f"${pin:.2f}/M in  ${pout:.2f}/M out"
            sort_price = pin

        max_tokens = m.get("top_provider", {}).get("max_completion_tokens", 0)

        models.append({
            "id": mid,
            "name": name,
            "ctx": ctxs,
            "pricing": pricing,
            "sort_price": sort_price,
            "is_free": is_free,
            "max_tokens": max_tokens,
        })

    if sort_by == "cheap":
        models.sort(key=lambda x: (0 if x["is_free"] else 1, x["sort_price"]))
    elif sort_by == "max_tokens":
        models.sort(key=lambda x: -x["max_tokens"])
    else:
        models.sort(key=lambda x: x["id"])

    free_count = sum(1 for m in models if m["is_free"])
    paid_count = len(models) - free_count
    hr = "\u2500" * 90  # horizontal rule, reused below
    print(f"  Found {len(models)} models ({free_count} free, {paid_count} paid)")
    print(f"  {hr}")
    for m in models:
        print(f"  {m['id']:<55s} {m['ctx']:>6s} ctx   {m['pricing']}")
    print(f"  {hr}")
    print(f"  Total: {len(models)} models")


if __name__ == "__main__":
    main()
