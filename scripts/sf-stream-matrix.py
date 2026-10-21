#!/usr/bin/env python3 -I
"""SiliconFlow /v1/messages stream matrix — does a model survive Claude Code's real request shape?

Claude Code always streams, and a single-turn stream smoke is not enough: on 2026-10-21
deepseek-ai/DeepSeek-V4.1-Flash passed every single-turn test and then, as soon as the history
held one tool_use/tool_result pair, SiliconFlow's Anthropic translator started tool_use blocks with
id:"" name:"" — Claude Code logged "No such tool available:" and ended the turn as
"[Tool use interrupted]" (41 of 92 tool calls in one session).

Usage:
  sf-stream-matrix.py <slug> [runs=4] [variants]      variants = comma list, default = all
  sf-stream-matrix.py <slug> [runs]   loo             leave-one-out bisect from the full shape

Variants: baseline (one tool, one turn), one Claude Code trait each (+thinking_adaptive,
+betas_header, +max_tokens_32k, +43_tools, +long_system, +tool_history, +effort_ctxmgmt), ALL
(everything Claude Code 2.1.306 sends), and the tool-history pairs that matter
(thinking+hist, disabled+hist, enabled1k+hist, enabled16k+hist, nothink+hist).

A row is OK when every run yields exactly one tool_use block with a non-empty id and name. Flaky
failures are the norm for this bug — use runs >= 6 before trusting a 0.  Key comes from the
keychain (SILICONFLOW_API_KEY) and is never printed. ~$0.001 per run on the Flash models.
"""
import copy, json, subprocess, sys, time, urllib.error, urllib.request

key = subprocess.run(["security", "find-generic-password", "-s", "SILICONFLOW_API_KEY", "-w"],
                     capture_output=True, text=True).stdout.strip()
if not key:
    sys.exit("SILICONFLOW_API_KEY not in the keychain")
M = sys.argv[1] if len(sys.argv) > 1 else "zai-org/GLM-5.3-Flash"
N = int(sys.argv[2]) if len(sys.argv) > 2 else 4
URL = "https://api.siliconflow.com/v1/messages"
# The beta list Claude Code 2.1.306 sends (from a session's api-request rows).
BETAS = ("claude-code-20250219,interleaved-thinking-2025-05-14,thinking-token-count-2026-05-13,"
         "context-management-2025-06-27,prompt-caching-scope-2026-01-05,mid-conversation-tool-changes-2026-07-01,"
         "advanced-tool-use-2025-11-20,effort-2025-11-24,thinking-display-updates-2026-08-18,afk-mode-2026-01-31")


def tool(name, props, req, desc="x" * 300):
    return {"name": name, "description": desc,
            "input_schema": {"type": "object", "properties": props, "required": req}}


bash = tool("Bash", {"command": {"type": "string"}, "description": {"type": "string"}, "timeout": {"type": "number"}}, ["command"])
read = tool("Read", {"file_path": {"type": "string"}, "offset": {"type": "number"}, "limit": {"type": "number"}}, ["file_path"])
edit = tool("Edit", {"file_path": {"type": "string"}, "old_string": {"type": "string"}, "new_string": {"type": "string"},
                     "replace_all": {"type": "boolean"}}, ["file_path", "old_string", "new_string"])
many = [bash, read, edit] + [tool(f"Tool{i}", {f"p{j}": {"type": "string", "description": "d" * 80} for j in range(6)},
                                  ["p0"], "desc " * 120) for i in range(40)]

PROMPT = "Use the Bash tool to run: ls -la /tmp"
hist = [
    {"role": "user", "content": "list src"},
    {"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_01A", "name": "Bash", "input": {"command": "ls src"}}]},
    {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_01A", "content": "app.rs\nscan.rs\nlive.rs"}]},
    {"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_01B", "name": "Read", "input": {"file_path": "src/app.rs", "limit": 40}}]},
    {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_01B",
                                  "content": "\n".join(f"{i}\tfn f{i}() {{}}" for i in range(40))}]},
    {"role": "user", "content": PROMPT},
]
longsys = [{"type": "text", "text": ("You are Claude Code. " * 20 + "\n") * 600}]  # ~250k chars
adaptive = {"thinking": {"type": "adaptive", "display": "updates"}}
effort = {"output_config": {"effort": "high"},
          "context_management": {"edits": [{"type": "clear_thinking_20251015", "keep": "all"}]}}

base = {"model": M, "max_tokens": 300, "stream": True, "tools": [bash],
        "messages": [{"role": "user", "content": PROMPT}]}

variants = {
    "baseline": ({}, {}),
    "+thinking_adaptive": (adaptive, {}),
    "+betas_header": ({}, {"anthropic-beta": BETAS}),
    "+max_tokens_32k": ({"max_tokens": 32000}, {}),
    "+43_tools": ({"tools": many}, {}),
    "+long_system": ({"system": longsys}, {}),
    "+tool_history": ({"messages": hist}, {}),
    "+effort_ctxmgmt": (effort, {}),
    "ALL": ({**adaptive, **effort, "max_tokens": 32000, "tools": many, "system": longsys, "messages": hist},
            {"anthropic-beta": BETAS}),
    "thinking+hist": ({**adaptive, "messages": hist}, {}),
    "disabled+hist": ({"thinking": {"type": "disabled"}, "messages": hist}, {}),
    "enabled1k+hist": ({"thinking": {"type": "enabled", "budget_tokens": 1024}, "messages": hist}, {}),
    "enabled16k+hist": ({"thinking": {"type": "enabled", "budget_tokens": 16000}, "messages": hist}, {}),
    "nothink+hist": ({"messages": hist}, {}),
}

ALL_PATCH, ALL_HDR = variants["ALL"]
if len(sys.argv) > 3 and sys.argv[3] == "loo":
    drops = {"thinking": ["thinking"], "max_tokens_32k": ["max_tokens"], "43_tools": ["tools"],
             "long_system": ["system"], "tool_history": ["messages"],
             "effort_ctxmgmt": ["output_config", "context_management"], "betas_header": None}
    variants = {}
    for name, keys in drops.items():
        p = {k: v for k, v in ALL_PATCH.items() if keys is None or k not in keys}
        variants["ALL-" + name] = (p, {} if keys is None else dict(ALL_HDR))
    sel = list(variants)
else:
    sel = sys.argv[3].split(",") if len(sys.argv) > 3 else list(variants)


def run(body, hdr):
    req = urllib.request.Request(URL, json.dumps(body).encode(),
                                 {"content-type": "application/json", "x-api-key": key,
                                  "anthropic-version": "2023-06-01", **hdr})
    try:
        lines = urllib.request.urlopen(req, timeout=120).read().decode().splitlines()
    except urllib.error.HTTPError as e:
        return "HTTP%d %s" % (e.code, e.read().decode()[:120])
    except Exception as e:
        return "ERR %s" % type(e).__name__
    starts, deltas, text = [], 0, ""
    for l in lines:
        if not l.startswith("data:"):
            continue
        try:
            d = json.loads(l[5:])
        except ValueError:
            continue
        if d.get("type") == "content_block_start":
            starts.append(d["content_block"])
        elif d.get("type") == "content_block_delta":
            dl = d["delta"]
            if dl.get("type") == "input_json_delta":
                deltas += 1
            if dl.get("type") == "text_delta":
                text += dl.get("text", "")
    tus = [s for s in starts if s.get("type") == "tool_use"]
    blank = [s for s in tus if not s.get("id") or not s.get("name")]
    ok = len(tus) == 1 and not blank
    return ("OK" if ok else "BAD") + f" tu={len(tus)} blank={len(blank)} json_deltas={deltas} blocks={len(starts)} text={len(text)}"


print(f"model {M}, {N} runs per variant")
for name in sel:
    patch, hdr = variants[name]
    body = copy.deepcopy(base)
    body.update(patch)
    res = []
    for _ in range(N):
        res.append(run(body, hdr))
        time.sleep(0.3)
    bad = sum(1 for r in res if not r.startswith("OK"))
    print(f"{name:20s} bad {bad}/{N}  | " + " ; ".join(res), flush=True)
