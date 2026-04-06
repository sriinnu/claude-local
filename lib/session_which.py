#!/usr/bin/env python3
"""Intelligent provider recommendation based on task type and error history.
Usage: python3 lib/session_which.py [--task TASK] [--log LOG_FILE]
"""
import argparse
import json
import sys
from collections import defaultdict


PROVIDERS = {
    "lcp-local": {
        "free": True,
        "privacy": "local",
        "latency": "fast-once-loaded",
        "tasks": ["all"],
        "notes": "Private, offline, unlimited context. Needs RAM + GPU.",
    },
    "openrouter-free": {
        "free": True,
        "privacy": "cloud",
        "latency": "variable",
        "tasks": ["code", "reasoning", "general", "fast"],
        "notes": "Free tier: 25+ models. Rate-limited, lower priority.",
    },
    "zai": {
        "free": False,
        "privacy": "cloud",
        "latency": "medium",
        "tasks": ["general", "fast"],
        "notes": "Z.AI GLM models. Cost-effective, good Chinese/English.",
    },
    "minimax": {
        "free": False,
        "privacy": "cloud",
        "latency": "medium",
        "tasks": ["general", "creative"],
        "notes": "MiniMax M2.7. Experimental, long context.",
    },
}


def main():
    parser = argparse.ArgumentParser(description="Recommend provider for task")
    parser.add_argument("--task", default="general", help="Task type")
    parser.add_argument("--log", default="", help="Session log file path")
    args = parser.parse_args()

    task = args.task
    error_rates = {}

    if args.log:
        try:
            sessions = []
            with open(args.log) as f:
                for line in f:
                    line = line.strip()
                    if line:
                        try:
                            sessions.append(json.loads(line))
                        except json.JSONDecodeError:
                            continue
            for p in PROVIDERS:
                matching = [s for s in sessions if s.get("provider", "") == p]
                if matching:
                    errors = sum(
                        1 for s in matching
                        if s.get("exit", 0) != 0 and s.get("exit", 0) != 130
                    )
                    error_rates[p] = errors / len(matching) if matching else 0
        except FileNotFoundError:
            pass

    scores = []
    for pid, info in PROVIDERS.items():
        score = 0
        if task in info["tasks"] or "all" in info["tasks"]:
            score += 10
        if info["free"]:
            score += 5
        if info["privacy"] == "local":
            score += 3
        if pid in error_rates:
            score -= error_rates[pid] * 20
        scores.append((score, pid, info))

    scores.sort(key=lambda x: -x[0])

    print(f"Task: {task}")
    print(f"{'-' * 60}")
    print()
    for rank, (score, pid, info) in enumerate(scores, 1):
        marker = "[REC]" if rank == 1 else "   "
        err = f" ({error_rates[pid]:.0%} error rate)" if pid in error_rates else ""
        print(
            f'{marker} {rank}. {pid:<18s} [{"FREE" if info["free"] else "PAID":<4s}] '
            f'{info["privacy"]} | latency: {info["latency"]}{err}'
        )
        print(f'     {info["notes"]}')
        if task == "code" and pid == "openrouter-free":
            print(f"     -> Best free: qwen/qwen3-coder:free (262k ctx, code-specialized)")
        if task == "reasoning" and pid == "openrouter-free":
            print(f"     -> Best free: qwen/qwen3.6-plus:free (1M ctx) or openai/gpt-oss-120b:free")
        if task == "fast" and pid == "openrouter-free":
            print(f"     -> Best free: nvidia/nemotron-3-nano-30b-a3b:free (256k, lightweight)")
        print()

    print("Usage:")
    print(f'  orf              - OpenRouter free models')
    print(f'  zai              - Z.AI GLM')
    print(f'  minimax          - MiniMax')
    print(f'  lcp              - Local (llama.cpp)')
    print(f'  llp-quick        - Launch best free model immediately')


if __name__ == "__main__":
    main()
