#!/usr/bin/env python3
"""Check if an OpenRouter model is available and show its details.
Usage: python3 lib/provider_health.py --model MODEL_ID (--models-json | --models-url URL)
"""
import argparse
import json
import sys


def check_model(models_data: dict, model_id: str) -> str:
    """Check model availability and return formatted status."""
    found = [m for m in models_data.get("data", []) if m["id"] == model_id]
    if not found:
        return f"  Model {model_id} not found on OpenRouter — may be unavailable"

    m = found[0]
    p = m.get("pricing", {})
    pin = float(p.get("prompt", 0) or 0) * 1e6
    pout = float(p.get("completion", 0) or 0) * 1e6
    ctx = m.get("context_length", 0)
    ctxs = f"{ctx // 1_000_000}M" if ctx >= 1_000_000 else f"{ctx // 1000}k"
    is_free = pin == 0 and pout == 0
    status = "FREE" if is_free else f"${pin:.2f}/M in"
    return f"  Model {model_id}: {status}, ctx: {ctxs} — available"


def main():
    parser = argparse.ArgumentParser(description="Check provider/model health")
    parser.add_argument("--model", required=True, help="Model ID to check")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--models-json", type=argparse.FileType("r"),
                       help="Path to models JSON file")
    group.add_argument("--models-url", help="URL to fetch models JSON from")

    args = parser.parse_args()

    if args.models_json:
        data = json.load(args.models_json)
    else:
        import urllib.request
        req = urllib.request.Request(args.models_url)
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.load(resp)

    print(check_model(data, args.model))


if __name__ == "__main__":
    main()
