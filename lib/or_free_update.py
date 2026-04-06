#!/usr/bin/env python3
"""Refresh OpenRouter free models list for shell config.
Reads model listing JSON from stdin, outputs formatted entries.

Usage: cat models.json | python3 or_free_update.py
"""
import json
import sys


def main():
    data = json.load(sys.stdin)
    free = []
    for m in data.get("data", []):
        p = m.get("pricing", {})
        if str(p.get("prompt", "1")) == "0" and str(p.get("completion", "1")) == "0":
            mid = m["id"]
            name = m.get("name", "")
            ctx = m.get("context_length", 0)
            if ctx >= 1_000_000:
                ctxs = f"{ctx // 1_000_000}M"
            elif ctx >= 1000:
                ctxs = f"{ctx // 1000}k"
            else:
                ctxs = str(ctx)
            free.append((mid, name, ctxs))

    for mid, name, ctxs in sorted(free):
        print(f'  "{mid:<50s} | {name:<25s} | ctx:{ctxs}"')
    print(f"\nTotal: {len(free)} free models")
    print("Copy the output above to update _OR_FREE_MODELS in ~/.claude_config.zsh")


if __name__ == "__main__":
    main()
