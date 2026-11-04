#!/usr/bin/env python3
"""lane-sync: what each Claude Code lane serves today, and whether it survives Claude Code.

Three questions, kept apart: does the id exist (the provider's list, or kosha + OpenRouter as guesses
where a plan has no list), does this key get it (an 8-token call), does it work in Claude Code (stream,
tool call, tool history, because single-turn clean has lied before, then a real `claude -p` that must
repeat a random token, because clean streams don't prove the model follows the prompt).

    lane-sync.py banner <lane> <opus> <sonnet> <haiku>   launch path: stderr banner, stdout slots + picker
    lane-sync.py show [lane] [grep]                      verdicts, no model calls
    lane-sync.py test <lane> [--limit N]                 run the ladder on what's pending
    lane-sync.py accept <lane> <new-id> [--replace old]  point a slot at a verified id
    lane-sync.py revert <lane> [old-id]                  undo an accept
    lane-sync.py sweep                                   every lane with a key (the daily launchd job)
    lane-sync.py selftest                                planted bad streams must be flagged

The launch path fails open: on any error the launcher keeps its hardcoded ids. New ids reach /model by
themselves; a default slot only moves on `accept`. Keys come from the keychain by name and are never
printed or put on argv. Probes send only the synthetic prompts below, never repo content: the real
`claude -p` runs with a throwaway HOME and config in an empty folder, so no CLAUDE.md or memory goes along.
"""
import argparse
import contextlib
import datetime
import fcntl
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ANTHROPIC_VERSION = "2023-06-01"
FETCH_TIMEOUT = 2.5      # launch path, per socket operation
BANNER_DEADLINE = 4      # launch path, whole command (seconds)
RETEST_PASS_DAYS = 7     # same id, new behaviour: deepseek-flash changed weights under one name
RETEST_FAIL_DAYS = 14    # providers fix things: V4.1-Flash-1017 went from shredded to clean
RUN_COOLDOWN = 600       # at most one background run per lane per 10 minutes
BLOCKED_COOLDOWN = 21600 # a lane with an empty wallet or dead key: try again in 6 hours
SWEEP_SKIP = 21600       # the daily job skips a lane tested in the last 6 hours (login + 07:30)
FULL_LADDERS = 5         # full ladders per run: bounds spend
SMOKE_CALLS = 30         # 8-token "is this served" calls per run
REAL_PROMPT_RUNS = 3     # real `claude -p` runs per model
MAX_ROWS = 8             # banner rows per section
MAX_PICKER_ADDS = 12

LANES = {
    "siliconflow": {"base": "https://api.siliconflow.com", "key": "SILICONFLOW_API_KEY",
                    "list": "https://api.siliconflow.com/v1/models", "kosha": "siliconflow",
                    "control": "zai-org/GLM-5.3-Flash"},
    "qwen": {"base": "https://token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic",
             "key": "QWEN_API_KEY", "list": None, "kosha": "alibaba", "or_prefix": "qwen/",
             "control": "qwen3.8-flash"},
    "deepseek": {"base": "https://api.deepseek.com/anthropic", "key": "DEEPSEEK_API_KEY",
                 "list": "https://api.deepseek.com/models", "kosha": "deepseek", "control": "deepseek-flash"},
    "kimi-us": {"base": "https://api.kimi.ai/coding", "key": "KIMI_US_API_KEY",
                "list": "https://api.kimi.ai/coding/v1/models", "kosha": "", "control": "k3-256k"},
    "kimi-cn": {"base": "https://api.moonshot.cn/anthropic", "key": "KIMI_API_KEY",
                "list": "https://api.moonshot.cn/v1/models", "kosha": "moonshot-cn", "control": None},
    "zai": {"base": "https://api.z.ai/api/anthropic", "key": "ZAI_API_KEY",
            "list": "https://api.z.ai/api/anthropic/v1/models", "kosha": "zai", "control": "glm-5.3-flash"},
    "minimax": {"base": "https://api.minimax.io/anthropic", "key": "MINIMAX_API_KEY",
                "list": "https://api.minimax.io/anthropic/v1/models", "kosha": "minimax",
                "control": "MiniMax-M3.1-Flash"},
    "openrouter": {"base": "https://openrouter.ai/api", "key": "OPENROUTER_API_KEY",
                   "list": "https://openrouter.ai/api/v1/models", "kosha": "openrouter",
                   "control": "anthropic/claude-haiku-5.5", "auto_test": False},
    "vercel": {"base": "https://ai-gateway.vercel.sh", "key": "AI_GATEWAY_API_KEY",
               "list": "https://ai-gateway.vercel.sh/v1/models", "kosha": "vercel",
               "control": "anthropic/claude-haiku-5.5", "auto_test": False},
}
# Launcher names and provider ids, so `lanes qwen-cc` means what you'd expect. OpenRouter and Vercel list
# 400+ ids each: they get the news, but only an explicit `lanes test` spends money on them.
ALIASES = {"openrouter-free": "openrouter", "openrouter-paid": "openrouter", "orf": "openrouter",
           "fable": "openrouter", "glmflash": "openrouter", "qwenflash": "openrouter",
           "geminiflash": "openrouter", "musespark": "openrouter", "llp-quick": "openrouter",
           "kimi": "kimi-cn", "kimi-china": "kimi-cn", "vai": "vercel", "sf": "siliconflow",
           "qwen-cc": "qwen", "qwen-ds": "qwen", "qwen-glm": "qwen", "qwen-plus": "qwen",
           "deepseekflash": "deepseek", "minimaxflash": "minimax"}

# What we already measured by hand, so day one isn't blank. Dated, so they expire and get re-tested.
_SF_DAY = "2026-10-21"
SEEDS = {
    "siliconflow": {
        "zai-org/GLM-5.3-Flash": ("pass", "multi-turn 30/30", _SF_DAY),
        "deepseek-ai/DeepSeek-V4-Flash": ("pass", "multi-turn verified", _SF_DAY),
        "moonshotai/Kimi-K3": ("pass", "multi-turn verified", _SF_DAY),
        "Qwen/Qwen3-Coder-30B-A3B-Instruct": ("pass", "multi-turn verified", _SF_DAY),
        "deepseek-ai/DeepSeek-V4.1-Flash": ("broken", "blank tool id/name after the first tool turn", _SF_DAY),
        "deepseek-ai/DeepSeek-V4.1-Flash-1017": ("broken", "empty text, shredded tool calls", _SF_DAY),
        "zai-org/GLM-5.3": ("broken", "400 stop-must-be-array on tool history", _SF_DAY),
        "moonshotai/Kimi-K2.7-Code": ("broken", "streams no text", _SF_DAY),
        "stepfun-ai/Step-3.5-Flash": ("broken", "streams no text", _SF_DAY),
        "MiniMaxAI/MiniMax-M3": ("broken", "<think> leaks into text", _SF_DAY),
        "Qwen/Qwen3.8-27B": ("broken", "tool JSON fragmented", _SF_DAY),
        "Qwen/Qwen3.6-35B-A3B": ("broken", "tool JSON fragmented, blank ids", _SF_DAY),
        "deepseek-ai/DeepSeek-V3.2": ("broken", "never calls tools", _SF_DAY),
        "ByteDance-Seed/Seed-OSS-36B-Instruct": ("broken", "never calls tools", _SF_DAY),
        "openai/gpt-oss-20b": ("broken", "no function calling", _SF_DAY),
        "openai/gpt-oss-120b": ("broken", "no function calling", _SF_DAY),
    },
    "qwen": {i: ("pass", "8-token smoke", "2026-10-19") for i in (
        "qwen3.8-max", "qwen3.7-max", "qwen3.7-plus", "qwen3.8-flash", "qwen3.6-flash",
        "deepseek-v4-pro", "deepseek-v4.1-flash", "glm-5.3", "glm-5.2")},
}

NOT_CHAT = re.compile(r"FLUX|Wan-AI|image|video|tts|asr|embed|rerank|whisper|ocr|realtime|speech|"
                      r"CosyVoice|IndexTTS|moderation|transcribe|sora|veo", re.I)
DATED = re.compile(r"-20\d\d-\d\d-\d\d$|-latest$")
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@+\-]{0,120}(\[[0-9a-z]+\])?$")
KEYISH = re.compile(r"\b(?:sk|ak|ek|key|vck)[-_][A-Za-z0-9_-]{4,}\S*|\beyJ[A-Za-z0-9_-]{8,}\S*")
CONTROL = re.compile("[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2066-\u2069]")   # escapes, bidi
BALANCE = re.compile(r"balance|quota|insufficient|recharge|unpurchased|credit|suspended|arrear", re.I)

TOOLS = [{"name": "Bash", "description": "Run a shell command",
          "input_schema": {"type": "object", "properties": {"command": {"type": "string"}},
                           "required": ["command"]}},
         {"name": "Read", "description": "Read a file",
          "input_schema": {"type": "object", "properties": {"file_path": {"type": "string"}},
                           "required": ["file_path"]}}]
SINGLE_PROMPT = "First say exactly: pong. Then use the Bash tool to run exactly: echo probe-ok"
HISTORY = [{"role": "user", "content": "list src"},
           {"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_01A", "name": "Bash",
                                              "input": {"command": "ls src"}}]},
           {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_01A",
                                         "content": "app.rs\nscan.rs"},
                                        {"type": "text", "text": "Use the Bash tool to run exactly: echo probe-ok"}]}]


class LaneDeadline(BaseException):
    """The launch deadline. Not an OSError: `except OSError` must never mistake it for a bad file."""


def resolve_lane(name):
    lane = ALIASES.get(name, name)
    if lane not in lane_table():
        raise SystemExit(f"unknown lane: {name} (known: {', '.join(lane_table())})")
    return lane


def today():
    return datetime.date.today().isoformat()


def state_dir():
    d = os.environ.get("LANE_SYNC_STATE_DIR") or os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "lcp", "lanes")
    os.makedirs(d, exist_ok=True)
    return d


def lane_table():
    override = os.environ.get("LANE_SYNC_TEST_LANES")   # tests point lanes at a fake server
    return json.loads(override) if override else LANES


def log(msg):
    print(f"{datetime.datetime.now().isoformat(timespec='seconds')} {msg}", flush=True)


# ---- classifiers: pure functions, so a planted bad stream can prove they fire ------------------------

def sse_events(raw):
    out = []
    for line in raw.splitlines():
        if line.startswith("data:"):
            payload = line[5:].strip()
            if payload and payload != "[DONE]":
                with contextlib.suppress(ValueError):
                    event = json.loads(payload)
                    if isinstance(event, dict):
                        out.append(event)
    return out


def _tool_blocks(events):
    return [e["content_block"] for e in events if e.get("type") == "content_block_start"
            and isinstance(e.get("content_block"), dict) and e["content_block"].get("type") == "tool_use"]


def classify_single(raw):
    """Problems in a first-turn stream, as short reasons. Empty list means clean."""
    events = sse_events(raw)
    errs = [e for e in events if e.get("type") == "error"]
    if errs:
        return ["stream error: " + clean(json.dumps(errs[0]))[:60]]
    deltas = [e.get("delta", {}) for e in events if e.get("type") == "content_block_delta"]
    text = "".join(d.get("text", "") for d in deltas if d.get("type") == "text_delta")
    args = "".join(d.get("partial_json", "") for d in deltas if d.get("type") == "input_json_delta")
    blocks = _tool_blocks(events)
    bad = []
    if "<think" in text:
        bad.append("<think> leaks into text")
    if "pong" not in text.lower():
        bad.append("streams no text" if not text.strip() else "wrong text")
    if not blocks:
        bad.append("never calls tools")
    elif len(blocks) > 1:
        bad.append(f"tool call split into {len(blocks)} blocks")
    if any(not (b.get("id") and b.get("name")) for b in blocks):
        bad.append("blank tool id/name")
    if blocks:
        try:
            ok = "probe-ok" in str(json.loads(args or "{}").get("command", ""))
        except (ValueError, AttributeError):
            ok = False
        if not ok:
            bad.append("tool JSON unparsable or wrong")
    return bad


def classify_history(raw):
    """Problems in a stream that follows a tool turn (the V4.1-Flash failure)."""
    events = sse_events(raw)
    errs = [e for e in events if e.get("type") == "error"]
    if errs:
        return ["stream error after a tool turn"]
    blocks = _tool_blocks(events)
    if not blocks:
        return ["no tool call after a tool turn"]
    if any(not (b.get("id") and b.get("name")) for b in blocks):
        return ["blank tool id/name after a tool turn"]
    if len(blocks) > 1:
        return [f"tool call split into {len(blocks)} blocks after a tool turn"]
    return []


def _sse(*events):
    return "\n".join("data: " + json.dumps(e) for e in events)


def _good_stream():
    return _sse({"type": "content_block_start", "content_block": {"type": "text", "text": ""}},
                {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "pong"}},
                {"type": "content_block_start",
                 "content_block": {"type": "tool_use", "id": "t1", "name": "Bash"}},
                {"type": "content_block_delta",
                 "delta": {"type": "input_json_delta", "partial_json": '{"command":"echo probe-ok"}'}})


def selftest():
    """The checker must flag each failure we've actually hit, and pass a clean stream."""
    tool_start = {"type": "content_block_start", "content_block": {"type": "tool_use", "id": "", "name": ""}}
    text = {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "pong"}}
    arg = {"type": "content_block_delta", "delta": {"type": "input_json_delta", "partial_json": '{"command":"echo probe-ok"}'}}
    planted = {
        "empty text + shredded": (classify_single, _sse(tool_start, tool_start, arg)),
        "blank id": (classify_single, _sse(text, tool_start, arg)),
        "think leak": (classify_single, _sse({"type": "content_block_delta", "delta": {"type": "text_delta", "text": "<think>pong"}}, arg)),
        "no tools": (classify_single, _sse(text)),
        "history blank": (classify_history, _sse(tool_start, arg)),
        "history none": (classify_history, _sse(text)),
    }
    missed = [name for name, (fn, raw) in planted.items() if not fn(raw)]
    if classify_single(_good_stream()) or classify_history(_good_stream()):
        missed.append("clean stream flagged")
    return missed


# ---- network ---------------------------------------------------------------------------------------

def clean(s):
    return CONTROL.sub("", re.sub(r"\s+", " ", KEYISH.sub("[key]", str(s))))[:160]


def get_key(lane):
    name = lane_table()[lane]["key"]
    override = os.environ.get("LANE_SYNC_TEST_KEY")
    if override is not None:
        return override
    r = subprocess.run(["security", "find-generic-password", "-s", name, "-w"],
                       capture_output=True, text=True, check=False)
    return r.stdout.strip() if r.returncode == 0 else ""


def fetch_ids(lane, key, timeout=FETCH_TIMEOUT):
    """Live ids from the provider's list route. None when it can't be read."""
    url = lane_table()[lane].get("list")
    if not url:
        return None
    headers = {"User-Agent": "lane-sync/1", "anthropic-version": ANTHROPIC_VERSION}
    if key:
        headers |= {"Authorization": "Bearer " + key, "x-api-key": key}
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=timeout) as r:
            body = json.load(r)
    except (OSError, ValueError):
        return None
    items = body.get("data", body) if isinstance(body, dict) else body
    if not isinstance(items, list):
        return None
    ids = set()
    for m in items:
        i = m.get("id") or m.get("name") if isinstance(m, dict) else None
        if isinstance(i, str) and SAFE_ID.match(i) and not NOT_CHAT.search(i):
            ids.add(i)
    return ids or None


def post(lane, key, body, timeout=90):
    """(status, text). status 0 means the request never got an answer."""
    base = lane_table()[lane]["base"]
    req = urllib.request.Request(base + "/v1/messages", json.dumps(body).encode(), {
        "content-type": "application/json", "x-api-key": key, "Authorization": "Bearer " + key,
        "anthropic-version": ANTHROPIC_VERSION, "User-Agent": "lane-sync/1"})
    def scrub(data):   # some providers echo the Authorization header back in their errors
        text = data.decode("utf-8", "replace")
        return text.replace(key, "[key]") if len(key) >= 8 else text   # a short string would eat the JSON
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, scrub(r.read())
    except urllib.error.HTTPError as e:
        with e:
            return e.code, scrub(e.read())
    except (OSError, ValueError) as e:
        return 0, type(e).__name__


def error_text(raw):
    try:
        d = json.loads(raw)
        e = d.get("error", d) if isinstance(d, dict) else raw
        return clean(e.get("message") or e) if isinstance(e, dict) else clean(e)
    except ValueError:
        return clean(raw)


class Budget:
    def __init__(self, ladders, smokes):
        self.ladders, self.smokes, self._lock = ladders, smokes, threading.Lock()

    def take(self, kind):
        with self._lock:
            if getattr(self, kind) <= 0:
                return False
            setattr(self, kind, getattr(self, kind) - 1)
            return True


# Nothing here can touch the machine: read-only tools in an empty folder, everything else off.
BLOCKED_TOOLS = "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,Agent,Task"
API_ERROR = re.compile(r"API Error: (\d{3})")
_real_claude_slots = threading.Semaphore(2)   # each one is a full process; this Mac has panicked on memory


def find_claude():
    override = os.environ.get("LANE_SYNC_CLAUDE")
    if override is not None:
        return None if override == "none" else override
    extra = [os.path.expanduser("~/.local/bin"), "/opt/homebrew/bin", "/usr/local/bin"]   # launchd's PATH is bare
    return shutil.which("claude", path=os.pathsep.join([os.environ.get("PATH", ""), *extra]))


def isolated_env(lane, key, model, home):
    """Everything claude needs to reach this lane and nothing of yours: no other keys, no ~/.claude."""
    env = child_env()
    env |= {"HOME": home, "CLAUDE_CONFIG_DIR": os.path.join(home, "config"),
            "ANTHROPIC_BASE_URL": lane_table()[lane]["base"], "ANTHROPIC_AUTH_TOKEN": key,
            "ANTHROPIC_MODEL": model, "ANTHROPIC_DEFAULT_OPUS_MODEL": model, "ANTHROPIC_DEFAULT_FABLE_MODEL": model,
            "ANTHROPIC_DEFAULT_SONNET_MODEL": model, "ANTHROPIC_DEFAULT_HAIKU_MODEL": model,
            "ANTHROPIC_SMALL_FAST_MODEL": model, "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "DISABLE_COST_WARNINGS": "1"}
    return env


def real_prompt_once(lane, key, model):
    """(True, "") followed the prompt, (False, why) didn't, (None, why) learned nothing about the model."""
    claude = find_claude()
    nonce = "ZX" + secrets.token_hex(4)
    with tempfile.TemporaryDirectory(prefix="lane-sync-") as home:
        work = os.path.join(home, "work")
        os.makedirs(work)
        try:
            with _real_claude_slots:
                r = subprocess.run([claude, "-p", f"Reply with exactly this token and nothing else: {nonce}",
                                    "--disallowedTools", BLOCKED_TOOLS],
                                   cwd=work, env=isolated_env(lane, key, model, home), stdin=subprocess.DEVNULL,
                                   capture_output=True, text=True, timeout=180, check=False)
        except (OSError, subprocess.TimeoutExpired) as e:
            return None, f"claude run failed: {type(e).__name__}"
    out = r.stdout + r.stderr
    if nonce in r.stdout and r.returncode == 0:
        return True, ""
    api = API_ERROR.search(out)
    if api and api.group(1) not in ("401", "402", "403", "429") and not api.group(1).startswith("5"):
        return False, f"HTTP {api.group(1)} from Claude Code's real request"   # the wire is the bug here
    if r.returncode != 0:
        return None, "claude exited with an error" + (f" (HTTP {api.group(1)})" if api else "")
    return False, "ignored the prompt"


def real_prompt(lane, key, model, runs=REAL_PROMPT_RUNS):
    """(verdict, note). A single miss is noted, not fatal: models are noisy, a pattern isn't."""
    if not find_claude():
        return "pass", "real prompt not run (no claude on PATH)"
    misses, why = 0, set()
    for _ in range(runs):
        followed, reason = real_prompt_once(lane, key, model)
        if followed is None:
            return None, reason
        if not followed:
            misses += 1
            why.add(reason)
    if misses >= 2:
        return "broken", f"{misses}/{runs} real prompts: " + "; ".join(sorted(why))
    return "pass", f"real prompt {runs - misses}/{runs}"


def _transient(status, raw):
    return status == 0 or status == 429 or status == 402 or status >= 500 or bool(BALANCE.search(raw))


def ladder(lane, key, model, budget=None, runs=3, guess=False):
    """(verdict, reason). verdict None means nothing was learned: quota, rate limit, outage, or no budget.

    verdict "auth" stops the run: the key is the problem, and it says nothing about the model."""
    # A listed id learns nothing from a smoke it can't follow up. A guess does: "not on this plan".
    if budget and ((not guess and budget.ladders <= 0) or not budget.take("smokes")):
        return None, "out of budget"
    status, raw = post(lane, key, {"model": model, "max_tokens": 8,
                                   "messages": [{"role": "user", "content": "Say OK"}]}, timeout=40)
    if status == 401:
        return "auth", "key rejected"
    if status != 200:
        if _transient(status, raw):
            return None, f"HTTP {status}: {error_text(raw)[:70]}"
        return "not_served", f"HTTP {status}: {error_text(raw)[:90]}"
    if budget and not budget.take("ladders"):
        return None, "served, full test pending"

    single = {"model": model, "max_tokens": 500, "stream": True, "tools": TOOLS,
              "messages": [{"role": "user", "content": SINGLE_PROMPT}]}
    problems = None
    for _ in range(2):   # models are noisy: a flag has to repeat before it counts
        status, raw = post(lane, key, single)
        if status != 200:
            if _transient(status, raw):
                return None, f"stream HTTP {status}"
            return "broken", f"stream HTTP {status}: {error_text(raw)[:70]}"
        problems = classify_single(raw)
        if not problems:
            break
    if problems:
        return "broken", "; ".join(problems)[:110]

    history = {"model": model, "max_tokens": 1500, "stream": True, "tools": TOOLS, "messages": HISTORY,
               "thinking": {"type": "adaptive", "display": "updates"}}   # Claude Code's real shape
    # A blank or split tool block is the bug itself, so once is enough. No tool call can just be a
    # reasoning model running long, so that has to repeat.
    bad, silent, reasons = 0, 0, set()
    for _ in range(runs):
        status, raw = post(lane, key, history)
        if status != 200:
            if _transient(status, raw):
                return None, f"multi-turn HTTP {status}"
            bad += 1
            reasons.add(f"HTTP {status} on tool history: {error_text(raw)[:50]}")
            continue
        problems = classify_history(raw)
        if problems == ["no tool call after a tool turn"]:
            silent += 1
            reasons.update(problems)
        elif problems:
            bad += 1
            reasons.update(problems)
    if bad or silent >= 2:
        return "broken", f"{bad + silent}/{runs} " + "; ".join(sorted(reasons))[:100]
    verdict, note = real_prompt(lane, key, model)
    if verdict != "pass":
        return verdict, note
    return "pass", f"single + multi-turn {runs - silent}/{runs}, {note}"


# ---- state -----------------------------------------------------------------------------------------

@contextlib.contextmanager
def locked_state(lane):
    """Read-modify-write one lane's state under a lock; the write is atomic."""
    path = os.path.join(state_dir(), lane + ".json")
    with open(path + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(path) as f:
                st = json.load(f)
        except FileNotFoundError:
            st = {}
        except ValueError:
            st = None
        if not isinstance(st, dict):   # keep the evidence (and the accepted swaps) for a human
            os.replace(path, f"{path}.corrupt-{int(time.time())}")
            st = {}
        st.setdefault("models", {})
        st.setdefault("events", [])
        st.setdefault("map", {})
        yield st
        tmp = f"{path}.{os.getpid()}.tmp"
        with open(tmp, "w") as f:
            json.dump(st, f, indent=1, sort_keys=True)
        os.replace(tmp, path)


def seed(st, lane):
    for mid, (verdict, reason, day) in SEEDS.get(lane, {}).items():
        st["models"].setdefault(mid, {"first_seen": day, "verdict": verdict, "reason": reason,
                                      "tested_at": day, "listed": True, "source": "seed"})


def kosha_rows(provider):
    """{id: model row} for one provider from kosha's manifest. {} when it isn't readable."""
    path = os.environ.get("LANE_SYNC_KOSHA") or os.path.expanduser("~/.kosha/registry.json")
    if not provider:
        return {}
    try:
        with open(path) as f:
            models = json.load(f).get("models", [])
    except (OSError, ValueError):
        return {}
    return {m["modelId"]: m for m in models
            if m.get("providerId") == provider and isinstance(m.get("modelId"), str)}


def guess_candidates(cfg):
    """A plan with no list route: other catalogs' ids are guesses, and an 8-token call settles them."""
    out = set()
    for mid, m in kosha_rows(cfg.get("kosha", "")).items():
        if m.get("mode") == "chat":
            out.add(mid)
    prefix = cfg.get("or_prefix")
    if prefix:
        out |= {mid[len(prefix):] for mid in kosha_rows("openrouter") if mid.startswith(prefix)}
    return {i.split(":")[0] for i in out if SAFE_ID.match(i) and not NOT_CHAT.search(i) and not DATED.search(i)}


def refresh(st, lane, live):
    """Fold a fetched list (or guesses) into state, queueing what changed. Returns a status string.

    The fetch happens before the state lock is taken, so a slow provider can't block another launch."""
    cfg = lane_table()[lane]
    first = "baseline_at" not in st
    if first:
        seed(st, lane)
    now = today()
    if cfg.get("list"):
        if live is None:
            return "unreachable"
        for mid in live:
            m = st["models"].get(mid)
            if m is None:
                st["models"][mid] = {"first_seen": now, "verdict": None, "listed": True, "source": "live"}
                if first:
                    st["models"][mid]["baseline"] = True
                else:
                    st["events"].append({"kind": "new", "id": mid})
            elif not m.get("listed"):
                m["listed"] = True
                if not first:
                    st["events"].append({"kind": "back", "id": mid})
        # A list that suddenly halves is a partial page or a bad day, not a mass extinction.
        listed = sum(1 for m in st["models"].values() if m.get("listed"))
        if first or len(live) * 2 >= listed:
            for mid, m in st["models"].items():
                if m.get("listed") and mid not in live:
                    m["listed"] = False
                    if not first:
                        st["events"].append({"kind": "gone", "id": mid})
        st["live_count"] = len(live)
    elif time.time() - st.get("candidates_at", 0) > 86400:
        for mid in guess_candidates(cfg):
            st["models"].setdefault(mid, {"first_seen": now, "verdict": None, "listed": False, "source": "guess"})
        st["candidates_at"] = time.time()
    if first:
        st["baseline_at"] = now
        st["first_run"] = True
    return "ok"


def _age_days(day):
    try:
        return (datetime.date.today() - datetime.date.fromisoformat(day)).days
    except (TypeError, ValueError):
        return 10_000


def needs_test(m):
    verdict = m.get("verdict")
    if m.get("source") == "live" and not m.get("listed"):
        return False
    if verdict is None:
        return True
    limit = RETEST_PASS_DAYS if verdict == "pass" else RETEST_FAIL_DAYS
    return _age_days(m.get("tested_at")) >= limit


def pending(st, slots=()):
    """What to test, most useful first: the ids you launch on, unseen ids, then expired verdicts."""
    bare = {s.split("[")[0] for s in slots}
    rows = [(mid, m) for mid, m in st["models"].items() if needs_test(m)]

    def rank(row):
        mid, m = row
        verdict = m.get("verdict")
        return (0 if mid in bare else 1 if verdict == "pass" else
                2 if verdict is None and (m.get("source") == "live" or m.get("served_at")) else
                3 if verdict is None else 4, mid)
    return [mid for mid, _ in sorted(rows, key=rank)]


def record(st, mid, verdict, reason):
    """Store a result. Only a change of verdict becomes something to tell you about."""
    m = st["models"].setdefault(mid, {"first_seen": today(), "listed": True, "source": "guess"})
    was = m.get("verdict")
    reason = clean(reason)
    m |= {"verdict": verdict, "reason": reason, "tested_at": today()}
    guess_miss = m.get("source") == "guess" and verdict == "not_served"
    if verdict == "pass" and m.get("source") == "guess":
        m["listed"] = True
    if verdict != was and not guess_miss and not (was is None and m.get("baseline")):
        st["events"].append({"kind": verdict, "id": mid, "reason": reason, "was": was})


# ---- the test run ----------------------------------------------------------------------------------

def run_tests(lane, ladders=FULL_LADDERS, smokes=SMOKE_CALLS):
    missed = selftest()
    if missed:
        log(f"{lane}: checker self-test failed ({', '.join(missed)}); no verdicts written")
        with locked_state(lane) as st:
            st["events"].append({"kind": "harness", "id": "", "reason": "checker self-test failed"})
        return 1
    key = get_key(lane)
    if not key:
        log(f"{lane}: no key in keychain, skipped")
        return 0
    runlock = open(os.path.join(state_dir(), lane + ".run.lock"), "a")
    try:
        fcntl.flock(runlock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log(f"{lane}: another run is active")
        return 0
    live = fetch_ids(lane, key, timeout=20)
    with locked_state(lane) as st:
        st["last_run"] = time.time()
        refresh(st, lane, live)
        todo = pending(st, st.get("last_slots", ()))
        sources = {mid: st["models"][mid].get("source") for mid in todo}
    if not todo:
        return 0

    # The live control: if a model we trust fails, today's verdicts can't be trusted either.
    control = lane_table()[lane].get("control")
    if control:
        verdict, reason = ladder(lane, key, control)
        log(f"{lane}: control {control}: {verdict} ({reason})")
        with locked_state(lane) as st:
            st["models"].setdefault(control, {"first_seen": today(), "verdict": None, "listed": True,
                                              "source": "control", "baseline": True})
            if verdict == "pass":
                st.pop("blocked", None)
                record(st, control, verdict, reason)
            elif verdict in ("broken", "not_served"):
                record(st, control, verdict, reason)
                st["events"].append({"kind": "harness", "id": control, "reason": "control failed, run discarded"})
            else:   # dead key, empty wallet, outage: nothing learned, and the banner should say so
                st["blocked"] = clean(reason)
        if verdict != "pass":
            return 0
        todo = [m for m in todo if m != control]

    budget = Budget(ladders, smokes)
    stop = threading.Event()

    def one(mid):
        if stop.is_set():
            return
        try:
            verdict, reason = ladder(lane, key, mid, budget, guess=sources.get(mid) == "guess")
        except Exception as e:   # one odd response must not cost the rest of the run
            log(f"{lane}: {mid}: {type(e).__name__}")
            return
        if verdict == "auth":
            stop.set()
            with locked_state(lane) as st:
                st["blocked"] = reason
            return
        if reason != "out of budget":
            log(f"{lane}: {mid}: {verdict} ({clean(reason)})")
        if verdict:
            with locked_state(lane) as st:
                record(st, mid, verdict, reason)
        elif reason.startswith("served"):
            with locked_state(lane) as st:
                st["models"][mid]["served_at"] = today()

    with ThreadPoolExecutor(3) as pool:
        list(pool.map(one, todo))
    return 0


def child_env():
    """An allowlist, not a scrub: a detached process runs for minutes and fetches its own key."""
    keep = {"PATH", "HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "XDG_CACHE_HOME", "XDG_STATE_HOME", "SSL_CERT_FILE"}
    return {k: v for k, v in os.environ.items() if k in keep or k.startswith(("LC_", "LANE_SYNC_"))}


def spawn_background(lane):
    if os.environ.get("LANE_SYNC_NO_SPAWN"):
        return
    log_path = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "lcp", "lane-sync.log")
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, "a") as out:
        subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), "test", lane],
                         stdin=subprocess.DEVNULL, stdout=out, stderr=out, start_new_session=True, env=child_env())


# ---- what you see ----------------------------------------------------------------------------------

def _fmt_ctx(n):
    if not n:
        return "ctx ?"
    return f"{n / 1_000_000:g}M" if n >= 1_000_000 else f"{round(n / 1000)}k"


def describe(mid, rows):
    """'1M · $0.15/$0.50' from kosha; prices stay unknown rather than guessed."""
    m = rows.get(mid)
    if not m:
        return "ctx ?, price ?"
    p = m.get("pricing") or {}
    i, o = p.get("inputPerMillion"), p.get("outputPerMillion")
    price = f"${i:g}/${o:g}" if i and o else "price ?"
    return f"{_fmt_ctx(m.get('contextWindow'))} · {price}"


def _section(lines, title, rows):
    if not rows:
        return
    lines.append(f"  {title}")
    lines.extend(f"    {r}" for r in rows[:MAX_ROWS])
    if len(rows) > MAX_ROWS:
        lines.append(f"    … and {len(rows) - MAX_ROWS} more (lanes show)")


def apply_map(st, slots):
    """(slots after accepted swaps, notes). A swap whose target stopped passing is not applied."""
    out, notes = [], []
    for s in slots:
        target = st["map"].get(s)
        if not target:
            out.append(s)
        elif st["models"].get(target, {}).get("verdict") == "pass":
            suffix = s[s.index("["):] if "[" in s and "[" not in target else ""   # keep k3[1m]'s window
            out.append(target + suffix)
            if f"{s} → {target}{suffix}" not in notes:
                notes.append(f"{s} → {target}{suffix}")
        else:
            out.append(s)
            notes.append(f"⚠ kept {s}: accepted {target} no longer passes")
    return out, notes


def merged_picker(base_json, st, rows):
    """The lane's curated rows plus every verified id they don't cover. '' when there's nothing to add."""
    try:
        base = json.loads(base_json) if base_json.strip() else {"modelPicker": {"options": []}}
        options = base["modelPicker"]["options"]
        have = {o["model"].split("[")[0] for o in options}
    except (ValueError, KeyError, TypeError, AttributeError):
        return ""   # the launcher keeps its own picker; never hand it a multi-line fragment
    adds = [(m.get("tested_at", ""), mid) for mid, m in st["models"].items()
            if m.get("verdict") == "pass" and m.get("listed") and not m.get("baseline") and mid not in have]
    if not adds and not base_json.strip():
        return ""   # no --settings at all for a lane that never had a picker
    for day, mid in sorted(adds, reverse=True)[:MAX_PICKER_ADDS]:
        options.append({"model": mid, "label": mid.split("/")[-1],
                        "description": f"{describe(mid, rows)} — verified {day}"})
    return json.dumps(base, separators=(",", ":"), ensure_ascii=False)


def render(lane, st, status, slots, notes, testing, rows):
    """The lines to show. Quiet by design: a launch with no news gets one line."""
    events, st["events"] = st["events"], []
    by = {}
    for e in events:
        if SAFE_ID.match(e.get("id") or "x"):
            by.setdefault(e["kind"], []).append(e)
    gone_now = {e["id"] for e in by.get("gone", [])}
    lines = []
    count = st.get("live_count")
    where = f"{count} models live" if count is not None else "no list route, tested ids only"
    if status == "unreachable":
        where = "list unreachable, using last known"
    served = sum(1 for m in st["models"].values() if m.get("verdict") == "pass")
    lines.append(f"◆ {lane}: {where}, {served} verified for Claude Code")
    if st.pop("first_run", False):
        lines.append(f"  first run: recorded {len(st['models'])} ids as the baseline")
    _section(lines, "new:", [f"+ {e['id']}  {describe(e['id'], rows)}" + ("  testing…" if testing else "")
                             for e in by.get("new", [])])
    accept = "lanes accept %s %s"
    _section(lines, "passed, now in /model:",
             [f"✓ {e['id']}  {describe(e['id'], rows)}   ({accept % (lane, e['id'])} to make it default)"
              for e in by.get("pass", [])])
    _section(lines, "failed for Claude Code:", [f"✗ {e['id']}  {clean(e.get('reason', ''))}" for e in by.get("broken", [])])
    _section(lines, "gone or not served to this key:",
             [f"- {e['id']}" for e in by.get("gone", [])] + [f"- {e['id']}  {clean(e.get('reason', ''))}" for e in by.get("not_served", [])])
    _section(lines, "back:", [f"+ {e['id']}" for e in by.get("back", []) if e["id"] not in gone_now])
    for e in by.get("harness", []):
        lines.append(f"  ⚠ test run discarded: {e['id'] + ' ' if e['id'] else ''}{clean(e.get('reason', ''))}")
    if st.get("blocked"):
        lines.append(f"  ⚠ background tests paused: {clean(st['blocked'])}")
    if notes:
        _section(lines, "accepted:", notes)
    warned = set()
    for s in slots:
        bare = s.split("[")[0]
        m = st["models"].get(bare)
        if m and bare not in warned:
            warned.add(bare)
            if m.get("verdict") in ("broken", "not_served"):
                lines.append(f"  ⚠ this lane launches on {bare}: {clean(m.get('reason', m['verdict']))}")
            elif m.get("source") != "guess" and m.get("listed") is False:
                lines.append(f"  ⚠ this lane launches on {bare}, which the provider no longer lists")
    return lines


def cmd_banner(args):
    """Launch path. stdout is exactly: opus, sonnet, haiku, picker (one per line). Any failure → silence."""
    slots = [args.opus, args.sonnet, args.haiku]
    lane = ALIASES.get(args.lane, args.lane)
    if lane not in lane_table():
        return 0
    signal.signal(signal.SIGALRM, _deadline)
    signal.alarm(BANNER_DEADLINE)
    key = get_key(lane)
    live = fetch_ids(lane, key)
    with locked_state(lane) as st:
        st["last_slots"] = slots
        status = refresh(st, lane, live)
        todo = pending(st, slots)
        cooldown = BLOCKED_COOLDOWN if st.get("blocked") else RUN_COOLDOWN
        testing = bool(lane_table()[lane].get("auto_test", True) and key and todo
                       and time.time() - st.get("last_run", 0) > cooldown)
        needs_rows = testing or st["events"] or any(m.get("verdict") == "pass" for m in st["models"].values())
        rows = kosha_rows(lane_table()[lane].get("kosha", "")) if needs_rows else {}
        mapped, notes = apply_map(st, slots)
        lines = render(lane, st, status, slots, notes, testing, rows)
        picker = merged_picker(os.environ.get("LANE_PICKER", ""), st, rows)
        if testing:
            st["last_run"] = time.time()
    signal.alarm(0)
    print("\n".join(lines), file=sys.stderr)
    if testing:
        print(f"  testing {min(len(todo), FULL_LADDERS)} of {len(todo)} pending in the background; results next launch", file=sys.stderr)
        spawn_background(lane)
    print("\n".join(mapped + ([picker] if picker else [])))
    return 0


def _deadline(*_):
    raise LaneDeadline


def cmd_show(args):
    if not args.lane:
        for lane in lane_table():
            path = os.path.join(state_dir(), lane + ".json")
            if not os.path.exists(path):
                print(f"  {lane:12s} not synced yet")
                continue
            with open(path) as f:
                ms = json.load(f).get("models", {})
            vs = [m.get("verdict") for m in ms.values() if m.get("listed") or m.get("verdict") == "pass"]
            print(f"  {lane:12s} ✓ {vs.count('pass'):3d}  ✗ {vs.count('broken'):3d}  ? {vs.count(None):3d}")
        return 0
    lane = resolve_lane(args.lane)
    live = fetch_ids(lane, get_key(lane), timeout=10)
    with locked_state(lane) as st:
        status = refresh(st, lane, live)
        st.pop("first_run", None)
        rows = kosha_rows(lane_table()[lane].get("kosha", ""))
        models = dict(st["models"])
        mapped = dict(st["map"])
    pat = (args.grep or "").lower()
    order = {"pass": 0, None: 1, "broken": 2, "not_served": 3}
    shown = 0
    for mid, m in sorted(models.items(), key=lambda kv: (order.get(kv[1].get("verdict"), 4), kv[0])):
        if pat and pat not in mid.lower():
            continue
        if not m.get("listed") and m.get("verdict") != "pass":
            continue
        v = m.get("verdict")
        mark = {"pass": "✓", "broken": "✗", "not_served": "-"}.get(v, "?")
        note = {"pass": describe(mid, rows), None: "untested"}.get(v) or clean(m.get("reason", ""))
        day = f"  ({m['tested_at']})" if m.get("tested_at") else ""
        print(f"  {mark} {mid}  {note}{day}")
        shown += 1
    print(f"\n{shown} shown (✓ verified, ? untested, ✗ broken for Claude Code)" + ("; list unreachable" if status == "unreachable" else ""))
    for old, new in mapped.items():
        print(f"accepted: {old} → {new}")
    return 0


def cmd_accept(args):
    lane = resolve_lane(args.lane)
    with locked_state(lane) as st:
        m = st["models"].get(args.new)
        if not m or m.get("verdict") != "pass":
            state = m.get("verdict") if m else "unknown"
            print(f"✗ {args.new} isn't verified on {lane} ({state}). Run: lanes test {lane}", file=sys.stderr)
            return 1
        old = args.replace or (st.get("last_slots") or [None])[0]
        if not old:
            print("✗ no launch recorded yet; pass --replace <old-id>", file=sys.stderr)
            return 1
        st["map"][old] = args.new
    print(f"✓ {lane}: {old} → {args.new} (undo: lanes revert {lane} {old})")
    return 0


def cmd_revert(args):
    lane = resolve_lane(args.lane)
    with locked_state(lane) as st:
        if args.old:
            removed = [args.old] if st["map"].pop(args.old, None) else []
        else:
            removed, st["map"] = list(st["map"]), {}
    print(f"reverted {', '.join(removed)}" if removed else "nothing to revert")
    return 0


def cmd_test(args):
    return run_tests(resolve_lane(args.lane), args.limit)


def cmd_sweep(_):
    for lane, cfg in lane_table().items():
        try:
            if not cfg.get("auto_test", True):
                continue
            with locked_state(lane) as st:
                recent = time.time() - st.get("last_run", 0) < SWEEP_SKIP
            if not recent:
                run_tests(lane)
        except Exception as e:   # one lane's bad day must not cost the others theirs
            log(f"{lane}: sweep failed: {type(e).__name__}")
    return 0


def main():
    p = argparse.ArgumentParser(prog="lane-sync")
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("banner")
    for name in ("lane", "opus", "sonnet", "haiku"):
        b.add_argument(name)
    b.set_defaults(fn=cmd_banner)
    s = sub.add_parser("show")
    s.add_argument("lane", nargs="?")
    s.add_argument("grep", nargs="?")
    s.set_defaults(fn=cmd_show)
    t = sub.add_parser("test")
    t.add_argument("lane")
    t.add_argument("--limit", type=int, default=FULL_LADDERS)
    t.set_defaults(fn=cmd_test)
    a = sub.add_parser("accept")
    a.add_argument("lane")
    a.add_argument("new")
    a.add_argument("--replace")
    a.set_defaults(fn=cmd_accept)
    r = sub.add_parser("revert")
    r.add_argument("lane")
    r.add_argument("old", nargs="?")
    r.set_defaults(fn=cmd_revert)
    sub.add_parser("sweep").set_defaults(fn=cmd_sweep)
    st = sub.add_parser("selftest")
    st.set_defaults(fn=lambda _: (print("missed: " + ", ".join(m)) or 1) if (m := selftest()) else (print("ok") or 0))
    args = p.parse_args()
    try:
        return args.fn(args)
    except BaseException as e:   # the launch must go ahead whatever happens in here
        if args.cmd == "banner":
            return 0
        if isinstance(e, (SystemExit, KeyboardInterrupt)):
            raise
        print(f"lane-sync: {type(e).__name__}: {clean(e)}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
