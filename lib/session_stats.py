#!/usr/bin/env python3
"""Session statistics dashboard from JSONL session log.
Usage: python3 lib/session_stats.py <log_file>
"""
import json
import sys
from collections import defaultdict


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 lib/session_stats.py <log_file>", file=sys.stderr)
        sys.exit(1)

    log_path = sys.argv[1]
    sessions = []
    try:
        with open(log_path) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        sessions.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
    except FileNotFoundError:
        print(f"No session log found at {log_path}")
        sys.exit(1)

    if not sessions:
        print("No valid sessions found.")
        return

    total = len(sessions)
    errors = sum(1 for s in sessions if s.get("exit", 0) != 0)
    durations = [s.get("duration_s", 0) for s in sessions]
    avg_dur = sum(durations) / len(durations) if durations else 0

    print("=== LLM Provider Session Stats ===")
    print(f"Total sessions:  {total}")
    print(f"Errors:          {errors} ({errors / total * 100:.1f}% error rate)")
    print(f"Avg duration:    {avg_dur:.0f}s")
    print(f"Total time:      {sum(durations) / 3600:.1f}h")

    prov = defaultdict(lambda: {"count": 0, "errors": 0, "durations": []})
    for s in sessions:
        p = s.get("provider", "unknown")
        prov[p]["count"] += 1
        if s.get("exit", 0) != 0:
            prov[p]["errors"] += 1
        prov[p]["durations"].append(s.get("duration_s", 0))

    print(f"\n--- By Provider ---")
    print(f'{"Provider":<14s} | {"Sessions":<9s} | {"Errors":<7s} | {"Err%":<6s} | {"Avg Dur":<9s}')
    print(f'{"-" * 55}')
    for p in sorted(prov, key=lambda x: -prov[x]["count"]):
        st = prov[p]
        avg = sum(st["durations"]) / len(st["durations"]) if st["durations"] else 0
        ep = st["errors"] / st["count"] * 100 if st["count"] else 0
        print(f'{p:<14s} | {st["count"]:<9d} | {st["errors"]:<7d} | {ep:<5.1f}% | {avg:<8.0f}s')

    print(f"\n--- Recent 5 Sessions ---")
    print(f'{"Time":<22s} | {"Provider":<12s} | {"Model":<35s} | {"Dur":<7s} | Status')
    print(f'{"-" * 88}')
    for s in sessions[-5:]:
        exit_code = s.get("exit", "?")
        status = "OK" if exit_code == 0 else ("INT" if exit_code == 130 else f"ERR({exit_code})")
        sym = {"OK": "\033[32m✔\033[0m", "INT": "\033[33m⚡\033[0m"}.get(
            status, "\033[31m✗\033[0m")
        print(
            f'{s.get("ts", "?"):<22s} | {s.get("provider", "?"):<12s} | '
            f'{s.get("model", "?")[:35]:<35s} | {s.get("duration_s", 0):<7d} | {sym} {status}')


if __name__ == "__main__":
    main()
