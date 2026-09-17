#!/usr/bin/env python3
"""Check whether one specific OpenRouter model is still zero-priced.

Companion to or_free_update.py — that one refreshes the whole cached free-list;
this one re-verifies a single model id live, right before `orf` would actually
spend money on it. Split out as its own script (not inlined `python3 -c` in
zsh) specifically so the model id — which comes straight from user input via
`orf <model-id>` — goes in as an argv value, never spliced into Python source.
An earlier inline version interpolated it into a string literal and was
exploitable: `orf "x' or __import__('os').system('...') or 'x"` ran arbitrary
code.

Usage:
  curl -sf https://openrouter.ai/api/v1/models -H "Authorization: Bearer $KEY" \\
    | python3 or_price_check.py <model-id>

Exit codes (the zsh caller branches on these, not on stdout text):
  0 — free, or model id not found in the catalog (nothing to warn about)
  1 — confirmed non-zero pricing; "prompt,completion" printed on stdout
  2 — couldn't tell (bad/missing JSON on stdin, or an unexpected shape) —
      caller should say "unverified", not stay silent as if it checked
"""
import json
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: or_price_check.py <model-id> < models.json", file=sys.stderr)
        return 2

    model = sys.argv[1]

    try:
        data = json.load(sys.stdin)
        for m in data.get("data", []) or []:
            if m.get("id") == model:
                pricing = m.get("pricing", {}) or {}
                # Compare numerically, not by string equality — OpenRouter isn't
                # guaranteed to always spell zero as the literal string "0"
                # (could be "0.0", a JSON number, etc.).
                prompt = float(pricing.get("prompt", 0) or 0)
                completion = float(pricing.get("completion", 0) or 0)
                if prompt != 0 or completion != 0:
                    print(f"{prompt},{completion}")
                    return 1
                return 0
        return 0  # not found in the catalog at all — nothing to flag
    except (json.JSONDecodeError, TypeError, AttributeError, ValueError):
        # Covers a failed fetch (empty/non-JSON stdin) AND a parseable-but-
        # unexpected shape (e.g. an error envelope) — both are "couldn't tell",
        # not "confirmed free", so they get their own exit code rather than
        # silently falling through as if verified.
        return 2


if __name__ == "__main__":
    sys.exit(main())
