#!/usr/bin/env python3
"""Refresh the OpenRouter free-model list used by claude_config.zsh.

I read the OpenRouter `/models` JSON from stdin, pick out anything with
zero-priced prompt *and* completion, and either print the formatted block
to stdout (dry run) or splice it straight into the shell config so the
`orf` picker sees the new models without copy-paste.

Usage:
  # Dry run — just print, don't touch any files
  curl -sf https://openrouter.ai/api/v1/models | python3 or_free_update.py

  # In-place edit of claude_config.zsh
  curl -sf https://openrouter.ai/api/v1/models \\
    | python3 or_free_update.py --config ~/…/llama-cpp-setup/claude_config.zsh
"""
import argparse
import datetime
import json
import re
import sys


def _format_ctx(ctx: int) -> str:
    if ctx >= 1_000_000:
        return f"{ctx // 1_000_000}M"
    if ctx >= 1000:
        return f"{ctx // 1000}k"
    return str(ctx)


def _is_zero_priced(pricing: dict) -> bool:
    return str(pricing.get("prompt", "1")) == "0" and str(pricing.get("completion", "1")) == "0"


def _extract_free(data: dict) -> list[tuple[str, str, str]]:
    # A model counts as "free" if its id ends with :free OR it's zero-priced on
    # both prompt and completion. Union catches zero-priced non-suffixed models
    # (elephant-alpha, openrouter/free) and future `:free` promos that aren't $0.
    free = []
    for m in data.get("data", []):
        mid = m["id"]
        if mid.endswith(":free") or _is_zero_priced(m.get("pricing", {})):
            free.append((mid, m.get("name", ""), _format_ctx(m.get("context_length", 0))))
    free.sort()
    return free


def _render_entries(free: list[tuple[str, str, str]]) -> list[str]:
    return [f'  "{mid:<50s} | {name:<25s} | ctx:{ctxs}"' for mid, name, ctxs in free]


def _render_block(free: list[tuple[str, str, str]], today: str) -> str:
    lines = [f"# Free model registry (updated {today})", "_OR_FREE_MODELS=("]
    lines.extend(_render_entries(free))
    lines.append(")")
    return "\n".join(lines)


# Matches the whole block — date comment, array opener, entries, closing paren.
# DOTALL so `.*?` spans the entry lines; non-greedy so we stop at the first `)`.
_BLOCK_RE = re.compile(
    r"# Free model registry \(updated [^)]*\)\n_OR_FREE_MODELS=\(\n.*?\n\)",
    re.DOTALL,
)


def _splice(path: str, block: str) -> None:
    with open(path, "r") as f:
        contents = f.read()
    new_contents, n = _BLOCK_RE.subn(block, contents, count=1)
    if n == 0:
        sys.exit(f"error: couldn't find _OR_FREE_MODELS block in {path}")
    with open(path, "w") as f:
        f.write(new_contents)


def main() -> None:
    ap = argparse.ArgumentParser(description="Refresh OpenRouter free-model list")
    ap.add_argument("--config", help="Path to claude_config.zsh; omit for dry-run to stdout")
    args = ap.parse_args()

    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit("error: no valid JSON on stdin — the OpenRouter fetch likely failed (network/HTTP error). Nothing was changed.")

    free = _extract_free(payload)
    if not free:
        sys.exit("error: OpenRouter returned zero free models — refusing to overwrite the list with an empty block.")
    today = datetime.date.today().isoformat()
    block = _render_block(free, today)

    if args.config:
        _splice(args.config, block)
        print(f"✓ Updated {args.config} — {len(free)} free models (dated {today})")
        print(f"  Re-source your shell to pick up changes: source {args.config}")
    else:
        print(block)
        print(f"\nTotal: {len(free)} free models")
        print("Re-run with --config <path> to write in place.")


if __name__ == "__main__":
    main()
