# === CLAUDE CODE MULTI-PROVIDER SETUP ===
#
# NOTES LIVE IN THE PRIVATE NOTES REPO (llm-providers/), NOT HERE:
#   llm-providers/README.md              (current lane status, pricing, gotchas, Qwen plan doc beside it)
#   llm-providers/sweeps/YYYY-MM-DD.md   (one log per model sweep)
#   llm-providers/probe-lanes.zsh        (probes every lane, prints no keys)
# This file keeps one dated status line per lane; the long story goes in those notes.
# When updating model ids (last sweep 2026-10-21), follow the README's "How to run a sweep":
#   1. zsh probe-lanes.zsh      2. diff against the notes' state table      3. edit ids + the
#   lane's dated comment + help prices, `orf-update` for the free list      4. zsh -n, re-source,
#   launch one changed lane      5. write sweeps/<date>.md + refresh the README tables and
#   llama-cpp-setup/README.md      6. update Claude memory (project-provider-lanes-status).

# === API KEYS — macOS login keychain (single source of truth) ===
# Every provider key lives in the login keychain: service name = variable name,
# account = $USER. Nothing in plaintext on disk. Add or rotate a key:
#   security add-generic-password -U -a "$USER" -s KIMI_US_API_KEY -w   # prompts for value
#   security delete-generic-password -s KIMI_US_API_KEY                 # remove
# GUI: Keychain Access app -> login keychain -> search the var name.
# Keychain WINS over anything already exported (since 2026-10-21): keys are always rotated in the
# keychain, so a value inherited from an older shell is by definition stale. Vars the keychain
# doesn't have are left alone, so a one-off `FOO_API_KEY=... lane` override still works.
_LCP_KEYCHAIN_KEYS=(ZAI_API_KEY MINIMAX_API_KEY DEEPSEEK_API_KEY OPENROUTER_API_KEY \
  AI_GATEWAY_API_KEY KIMI_API_KEY KIMI_US_API_KEY GEMINI_API_KEY SILICONFLOW_API_KEY \
  BIGMODEL_API_KEY HUGGING_FACE_API_KEY OLLAMA_API_KEY QWEN_API_KEY JEV_API_KEY)
_lcp_load_keys() {
  local var val fails=0
  # 14 `security` lookups ≈ 0.1–0.2 s per shell on this Mac (measured 2026-10-21); not worth a cache,
  # and a cache is one more way for a stale value to survive.
  for var in "${_LCP_KEYCHAIN_KEYS[@]}"; do
    val=$(security find-generic-password -s "$var" -w 2>/dev/null) || { fails=$((fails+1)); continue; }
    [[ -n "$val" ]] && export "$var=$val"
  done
  if (( fails == ${#_LCP_KEYCHAIN_KEYS[@]} )); then
    echo "⚠ [lcp] keychain unreachable (locked? ssh?) — provider keys NOT refreshed; inherited values may be stale" >&2
  fi
}
_lcp_load_keys
unset -f _lcp_load_keys

# TypeSafe's SDK reads TYPESAFE_API_KEY, but the keychain entry is JEV_API_KEY
# (named for the model, not the product) — alias so there's still one secret,
# one keychain entry, not a duplicate.
[[ -n "${JEV_API_KEY:-}" ]] && export TYPESAFE_API_KEY="$JEV_API_KEY"   # follows the keychain, like the rest

# === PROVIDER ENDPOINTS ===
# Defaults live here; the `:=` only sets a value if you haven't already, so an
# endpoint exported earlier in your shell env wins, e.g.
#   export KIMI_US_BASE_URL="https://api.kimi.com/coding"       # flip kimi-us to the China-side host
# No need to edit the launcher functions to retarget an endpoint.
: ${ZAI_BASE_URL:=https://api.z.ai/api/anthropic}
: ${KIMI_BASE_URL:=https://api.moonshot.cn/anthropic}
: ${KIMI_US_BASE_URL:=https://api.kimi.ai/coding}
: ${MINIMAX_BASE_URL:=https://api.minimax.io/anthropic}
: ${DEEPSEEK_BASE_URL:=https://api.deepseek.com/anthropic}
: ${OPENROUTER_BASE_URL:=https://openrouter.ai/api}
: ${VAI_BASE_URL:=https://ai-gateway.vercel.sh}
: ${SILICONFLOW_BASE_URL:=https://api.siliconflow.com}   # .com key; .cn 401s on it. Bare host — Claude Code appends /v1/messages
: ${BIGMODEL_BASE_URL:=https://open.bigmodel.cn/api/paas/v4/}
: ${QWEN_BASE_URL:=https://token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic}

# Directory layout — set these at the top so all functions can reference them
# Allow callers to override _LCP_DIR, otherwise default to the directory containing
# this sourced config file so the setup is portable across machines.
_LCP_CONFIG_DIR="${${(%):-%N}:A:h}"
_LCP_DIR="${_LCP_DIR:-$_LCP_CONFIG_DIR}"
_LCP_LIB_DIR="${_LCP_LIB_DIR:-${_LCP_DIR}/lib}"

# Internal: source-time preflight checks
# Warns once at load if key dependencies or config are missing.
_lcp_preflight() {
  local ok=true
  if ! command -v claude &>/dev/null; then
    echo "⚠ [lcp] 'claude' not found in PATH — install Claude Code first" >&2
    ok=false
  fi
  if ! command -v python3 &>/dev/null; then
    echo "⚠ [lcp] 'python3' not found in PATH" >&2
    ok=false
  fi
  if ! command -v curl &>/dev/null; then
    echo "⚠ [lcp] 'curl' not found in PATH — OpenRouter/HF features will fail" >&2
    ok=false
  fi
  [[ -d "$_LCP_LIB_DIR" ]] || {
    # Create lib symlink if possible, warn otherwise
    if [[ -d "$_LCP_DIR/lib" ]]; then
      _LCP_LIB_DIR="$_LCP_DIR/lib"
    else
      echo "⚠ [lcp] lib/ directory not found at $_LCP_DIR/lib — Python helpers unavailable" >&2
    fi
  }
  $ok || echo "  → Some warnings above. Basic lcp/local may still work." >&2
}
_lcp_preflight
unset _lcp_preflight  # clean up — only needed at source time

# Internal: known provider API keys to scrub from subshell environments
# Prevents cross-provider credential leakage (e.g., ZAI key visible to OpenRouter)
# Derived from the load list so nothing the keychain exports can reach a third-party lane's subshell
# (2026-10-21 review: GEMINI/BIGMODEL/HF/OLLAMA/JEV were leaking into every claude process).
_LCP_PROVIDER_KEYS=("${_LCP_KEYCHAIN_KEYS[@]}" TYPESAFE_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY CLOUDFLARE_API_TOKEN)

# Internal: observability — session log location
_LCP_SESSION_LOG="${XDG_CACHE_HOME:-$HOME/.cache}/lcp/sessions.jsonl"

# Internal: record one session's metadata for observability/cost tracking
_lcp_log_session() {
  local provider="$1" model="$2" base_url="$3" exit_code="$4" duration="$5"
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  # Append one JSONL line using a real JSON encoder so user-provided values are escaped safely.
  # Keep numeric fields as JSON numbers when possible; otherwise emit null to preserve valid JSON.
  python3 - "$ts" "$provider" "$model" "$base_url" "$exit_code" "$duration" >> "$_LCP_SESSION_LOG" 2>/dev/null <<'PY'
import json
import sys

ts, provider, model, base_url, exit_code, duration = sys.argv[1:7]

def parse_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None

def parse_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None

print(json.dumps({
    "ts": ts,
    "provider": provider,
    "model": model,
    "base_url": base_url,
    "exit": parse_int(exit_code),
    "duration_s": parse_float(duration),
}, separators=(",", ":")))
PY
}

# Internal: pre-launch health check for a provider
# Prints warnings if the endpoint is unreachable or the model seems unavailable
_lcp_health_check() {
  local base_url="$1" model="$2" provider="$3"

  # Skip health check for localhost (local already does its own health polling)
  if [[ "$base_url" == http://localhost* || "$base_url" == http://127.0.0.1* ]]; then
    return 0
  fi

  # Only OpenRouter exposes a reliable OpenAI-style /v1/models route. zai/minimax/
  # deepseek/vercel are Anthropic-proxy endpoints that don't serve /v1/models — probing
  # it there 404s and throws a false "unreachable" warning on every launch, so skip them.
  if [[ "$base_url" != *"openrouter"* ]]; then
    return 0
  fi

  # Quick ping to the models endpoint
  if ! curl -sf -m 5 "$base_url/v1/models" &>/dev/null; then
    echo "⚠ $provider endpoint unreachable: $base_url"
    echo "  Check your API key and network connectivity."
    # Check specific model availability via the models list
    local check
    check=$(python3 "${_LCP_LIB_DIR:-${_LCP_DIR:-.}/lib}/provider_health.py" \
      --model "$model" --models-url "$OPENROUTER_BASE_URL/v1/models" 2>/dev/null)
    [[ -n "$check" ]] && echo "$check"
    return 1
  fi
  return 0
}

# Internal: unified launcher for any Claude Code provider
# Usage: _launch_claude <base_url> <auth_token> <opus_model> <sonnet_model> <haiku_model> [provider_id] [--arg ...]
# Passing the same model for all three roles is equivalent to single-model mode.
# Use provider_id for logging/health checks when multiple logical providers share the same base URL
# (for example: openrouter-free vs openrouter-paid).
_launch_claude() {
  local base_url="$1" auth_token="$2"
  local opus_model="$3" sonnet_model="$4" haiku_model="$5"
  shift 5

  # Allow callers to pass an explicit provider ID so session logging matches downstream provider IDs.
  local provider=""
  case "${1:-}" in
    zai|minimax|deepseek|vercel|openrouter-free|openrouter-paid|lcp-local|openrouter|siliconflow|kimi|kimi-cn|kimi-us|qwen|geminifree)
      provider="$1"
      shift
      ;;
  esac

  # Ensure run directory exists
  mkdir -p "$(dirname "$_LCP_SESSION_LOG")"

  # Fall back to deriving provider name from base_url for backward compatibility.
  # Prefer provider IDs that align with downstream session selection logic.
  if [[ -z "$provider" ]]; then
    provider="unknown"
    case "$base_url" in
      *z.ai*)              provider="zai" ;;
      *minimax*)           provider="minimax" ;;
      *deepseek*)          provider="deepseek" ;;
      *moonshot*)          provider="kimi-cn" ;;
      *api.kimi.*)         provider="kimi-us" ;;
      *aliyuncs.com*)      provider="qwen" ;;
      # Free only when the model itself is free; paid lanes (openrouter, fable, glmflash…)
      # were logging as openrouter-free and skewing its error rate in session_which.py.
      *openrouter*)
        if [[ "$opus_model" == *:free || "$opus_model" == openrouter/free ]]; then
          provider="openrouter-free"
        else
          provider="openrouter-paid"
        fi ;;
      *ai-gateway.vercel*) provider="vercel" ;;
      *localhost*)         provider="lcp-local" ;;
      *127.0.0.1*)         provider="lcp-local" ;;
    esac
  fi

  # Pre-launch health check (non-blocking — just warn)
  _lcp_health_check "$base_url" "$opus_model" "$provider" || true

  echo "→ $provider ($opus_model) @ ${base_url#https://}"
  echo ""

  local start_ts
  start_ts=$(date +%s)
  (
    # Scrub all provider keys from this subshell's environment
    local k
    for k in "${_LCP_PROVIDER_KEYS[@]}"; do
      unset "$k"
    done
    export ANTHROPIC_BASE_URL="$base_url"
    export ANTHROPIC_AUTH_TOKEN="$auth_token"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$opus_model"
    export ANTHROPIC_DEFAULT_FABLE_MODEL="$opus_model"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$sonnet_model"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$haiku_model"
    export ANTHROPIC_MODEL="$opus_model"
    # Claude Code's helper calls (titles, summaries, classifiers) read SMALL_FAST first and
    # only fall back to DEFAULT_HAIKU when it is unset — so this must be the haiku slot.
    # (Was "$sonnet_model" until 2026-10-15, which quietly sent every lane's helper traffic to sonnet.)
    export ANTHROPIC_SMALL_FAST_MODEL="$haiku_model"
    export API_TIMEOUT_MS="3000000"
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    # Optional per-launch /model picker rows (inline --settings JSON); empty for most providers.
    local -a picker_args=()
    [[ -n "${_LCP_PICKER_JSON:-}" ]] && picker_args=(--settings "$_LCP_PICKER_JSON")
    claude "${picker_args[@]}" "$@"
  )
  local exit_code=$?
  local end_ts
  end_ts=$(date +%s)
  local duration=$((end_ts - start_ts))

  # Format duration for display
  local dur_display
  if [[ $duration -ge 3600 ]];      then dur_display="$((duration/3600))h $((duration%3600/60))m"
  elif [[ $duration -ge 60 ]];      then dur_display="$((duration/60))m $((duration%60))s"
  else                                   dur_display="${duration}s"
  fi

  # Log the session
  _lcp_log_session "$provider" "$opus_model" "$base_url" "$exit_code" "$duration"

  if [[ $exit_code -eq 0 ]]; then
    echo "✔ Session complete — $provider | $dur_display"
  elif [[ $exit_code -eq 130 ]]; then
    echo "✔ Interrupted (Ctrl-C) — $provider | $dur_display"
  else
    echo "✗ Exit code $exit_code — $provider | $dur_display"
  fi
}

# GLM (Z.AI) - Cost-effective option. Verified against api.z.ai /v1/models 2026-09-16:
# glm-5.3 is the current flagship; glm-5.3-flash is the cheap/fast lane (replaces glm-5-turbo).
# Re-checked 2026-10-12: catalog adds glm-5.3-flashx (OpenRouter prices it $0.37/$1.25 vs flash's
# $0.02/$1.20 — a speed tier, not a saving; not adopted). ⚠ Every call 429s [1113] "Insufficient
# balance or no resource package" — the account needs a top-up; the ids themselves are fine.
# 2026-10-19: catalog unchanged, still 429 [1113]. OpenRouter lists a new glm-5.3-prime ($2.80/$8.80)
# but api.z.ai 400s it [1211 Unknown Model] — OR-only for now, not adopted.
zai() {
  _launch_claude \
    "$ZAI_BASE_URL" \
    "$ZAI_API_KEY" \
    "glm-5.3" \
    "glm-5.3" \
    "glm-5.3-flash" \
    "$@"
}

# MiniMax - Experimental. MiniMax-M3 is still their newest model (OpenRouter 2026-09-16).
# ⚠ 2026-09-16: MINIMAX_API_KEY 401s "invalid api key" on both api.minimax.io and the China
# host api.minimaxi.com — key expired/revoked, not the model id. Rotate it in the keychain.
# Still 401 on 2026-10-12 (same key). MiniMax-M3 is still their newest on OpenRouter ($0.30/$1.20).
# 2026-10-19: still 401. New on OpenRouter: minimax-m3.1-flash:free (1M ctx) — it's in the free
# list now (`orf`); can't check whether api.minimax.io serves an M3.1 id until the key is rotated.
# 2026-10-20: MiniMax shipped M3.1 Flash (10-19; 1M ctx, "~3x faster, 70% cheaper" per their blurb).
# platform.minimax.io's Anthropic-compat page now lists exactly two ids: MiniMax-M3 and
# MiniMax-M3.1-Flash. Key STILL 401 — ids below are from the docs, not smoke-tested.
# `minimaxflash` added for when the key is rotated; the free path today is `orf` -> minimax-m3.1-flash:free.
minimax() {
  _launch_claude \
    "$MINIMAX_BASE_URL" \
    "$MINIMAX_API_KEY" \
    "MiniMax-M3" \
    "MiniMax-M3.1-Flash" \
    "MiniMax-M3.1-Flash" \
    "$@"
}

# MiniMax M3.1 Flash on every lane — UNVERIFIED (key 401 as of 2026-10-20), id per official docs.
minimaxflash() {
  _launch_claude \
    "$MINIMAX_BASE_URL" \
    "$MINIMAX_API_KEY" \
    "MiniMax-M3.1-Flash" \
    "MiniMax-M3.1-Flash" \
    "MiniMax-M3.1-Flash" \
    "$@"
}

# DeepSeek — verified against api.deepseek.com/models + smoke-tested 2026-09-16.
# Re-verified 2026-10-12: /models still serves exactly deepseek-flash + deepseek-v4-pro, nothing new.
# 2026-10-19: same two ids, both smoke 200. OpenRouter added a deepseek-v4.1-flash-1017 snapshot
# ($0.15/$0.60, same as direct); the direct API 400s that slug — keep "deepseek-flash".
# 2026-10-20: /models still exactly two ids, deepseek-flash smoke 200. Per the 10-17 changelog
# "deepseek-flash" now serves DeepSeek-V4.1-Flash-1017 (minor update: DeepSWE 74.2 -> 77.0, shorter
# outputs, faster task completion), same id, same price — nothing to change here. No "V4.1" of
# Pro; deepseek-v4-pro is still V4-Pro-0813. Same release opened their Search/Fetch API and
# recommends DeepSeek Harness >= 0.2.1-rc.1 (their agent harness, not relevant to this lane).
# Live catalog is exactly two ids:
#   deepseek-v4-pro  -> DeepSeek-V4-Pro-0813        (1M ctx, 384K out, $0.66/$1.98 per M peak)
#   deepseek-flash   -> DeepSeek-V4.1-Flash-1017    (1M ctx, 384K out, $0.15/$0.60 per M peak, multimodal)
# V4.1 Flash went GA 2026-09-10; DeepSeek benches it ahead of V4-Pro at ~1/4 the price.
# There is NO "deepseek-v4.1-flash" slug (400s). "deepseek-v4-flash" still answers but is a
# temporary legacy alias routed to V4.1 Flash — don't rely on it. Off-peak (outside
# 01-04 & 06-10 UTC weekdays) is half price. Both models think by default.
# opus=pro for the main loop; sonnet+haiku=flash so subagents/background run cheap.
# Context: Claude Code doesn't know these models and would auto-compact at 200k, so we set
# CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 for the session. Do NOT use the "[1m]" model suffix
# here — it passes in -p mode but the interactive picker rejects "deepseek-flash[1m]" as a
# nonexistent model (hit 2026-09-16).
deepseek() {
  CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 _launch_claude \
    "$DEEPSEEK_BASE_URL" \
    "$DEEPSEEK_API_KEY" \
    "deepseek-v4-pro" \
    "deepseek-flash" \
    "deepseek-flash" \
    "$@"
}

# DeepSeek V4.1 Flash on every lane — cheapest DeepSeek, and per their evals it's the smarter one.
deepseekflash() {
  CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 _launch_claude \
    "$DEEPSEEK_BASE_URL" \
    "$DEEPSEEK_API_KEY" \
    "deepseek-flash" \
    "deepseek-flash" \
    "deepseek-flash" \
    deepseek \
    "$@"
}

# Kimi China (Moonshot Open Platform, moonshot.cn) — K3 + K2.7 Code, Anthropic-native endpoint.
# The bare `kimi` name is NOT defined here any more: it belongs to Moonshot's official
# Kimi Code CLI (installed 2026-10-15). This lane is `kimi-china` (`kimi-cn` is an alias).
# RE-CONFIRMED 2026-09-02: this key is a platform.moonshot.CN key — .cn returns 200,
# the .ai (international) host still 401s on it. Must be the /anthropic path (NOT /v1,
# which is the OpenAI-compatible route Claude Code can't speak).
# Live /v1/models 2026-10-15 serves exactly: kimi-k3, kimi-k2.7-code,
# kimi-k2.7-code-highspeed, kimi-k2.6 (unchanged since 09-02; same again 2026-10-19).
# Haiku lane runs kimi-k2.7-code-highspeed: same model, ~3.6x faster on a 200-token
# reply (2.2s vs 8.1s measured 2026-09-02), which is what the background lane wants.
#
# Status 2026-10-19 (unchanged since 10-15): every model 429s "account … is suspended due to insufficient balance"
# (type exceeded_current_quota_error). Pay-as-you-go wallet is EMPTY — top up at
# platform.moonshot.cn, or use `kimi-us` (Kimi Code plan, live again) which serves the same K3.
kimi-china() {
  _launch_claude \
    "$KIMI_BASE_URL" \
    "$KIMI_API_KEY" \
    "kimi-k3" \
    "kimi-k2.7-code" \
    "kimi-k2.7-code-highspeed" \
    kimi-cn \
    "$@"
}
kimi-cn() { kimi-china "$@"; }

# Kimi US (Kimi Code plan, kimi.com / kimi.ai) — Anthropic-compatible subscription endpoint.
# Separate account/key from the moonshot.cn one above: get it from the Kimi Code
# Console at kimi.com/code/console, store as KIMI_US_API_KEY in the login keychain.
# Docs: https://www.kimi.com/code/docs/en/  (Claude Code page: /third-party-tools/claude-code.html)
# Hosts (docs 2026-10-15): overseas https://api.kimi.ai/coding/ (default here, we're in Vienna),
# China-side https://api.kimi.com/coding/ — same key works on both, verified 200 on both.
# Claude Code appends /v1/messages itself; the OpenAI-compatible route is <host>/coding/v1.
# Models (live /v1/models 2026-10-15, all four smoke-tested 200 on this key):
#   k3                        K3, 1M ctx (1M needs Pro/Allegretto+), effort low/high/max (default high),
#                             ~2x the quota of k3-256k. Claude Code 1M form: "k3[1m]" — Claude Code
#                             strips the tag, sends beta context-1m-2025-08-07 (Kimi answers 200) and
#                             sizes the window at 1M; bare "k3" is treated as an unknown 200k model
#                             and auto-compacts at 200k while you still pay k3's quota.
#   k3-256k                   K3 at 256k ctx, cheapest-quota K3. Image in, no video.
#   kimi-for-coding           K2.8 Preview (upgraded in place 2026-09-11, same id), 1M ctx,
#                             effort low/high/max (default max). Andante/Plus+.
#   kimi-for-coding-highspeed K2.7 Code HighSpeed, 256k, ~6x output speed at 3x quota. Pro/Allegretto+.
# NOTE kimi.com ids are "k3"/"k3-256k", not moonshot's "kimi-k3". Use the id, never the display name.
# Plan tier: highspeed answers 200 for this key, so the plan is Pro/Allegretto+ (1M unlocked).
# Lanes: opus=k3[1m] (frontier), sonnet=kimi-for-coding[1m] (K2.8 Preview), haiku=k3-256k (cheapest
# stated quota cost; serves `model: haiku` subagents, /model haiku, and the helper calls via
# SMALL_FAST; highspeed would burn 3x). CLAUDE_CODE_MAX_CONTEXT_TOKENS=262144 is set lane-local so
# the 256k model is sized at 262144 instead of the unknown-model 200k default; [1m] models ignore it.
# Pick highspeed per-session from /model (picker rows below). A 401 "permission denied" on a model = tier gap.
# Effort: Claude Code already sends effort "high" by default (Kimi's recommended level);
# /effort medium -> Kimi "high", xhigh/max -> "max". No CLAUDE_CODE_EFFORT_LEVEL needed.
# Quota: one 5h rolling window + one monthly pool. This key is on a new-style plan (no weekly
# block in /usages; legacy Andante/Moderato/Allegretto plans still carry a weekly). Check remaining at
# kimi.com/code/console, or `GET https://api.kimi.ai/coding/v1/usages` with the key (Runic reads this).
#
# Status 2026-10-15: plan LIVE again (the 10-12 "does not have access to Kimi Code" 403 was a lapse;
# renewed since). 5h window 15% used, monthly 0.4% at check time.
# 2026-10-19: /v1/models still the same four ids, all four smoke 200. Nothing newer than K3 yet.
_KIMI_US_PICKER_JSON='{"modelPicker":{"options":[
{"model":"k3[1m]","label":"Kimi K3 (1M)","description":"1M ctx, effort high, ~2x quota of k3-256k"},
{"model":"k3-256k","label":"Kimi K3-256k","description":"256k ctx, cheapest K3 quota"},
{"model":"kimi-for-coding[1m]","label":"Kimi K2.8 Preview (1M)","description":"1M ctx, effort max"},
{"model":"kimi-for-coding-highspeed","label":"Kimi K2.7 HighSpeed","description":"256k ctx, ~6x speed, 3x quota"}]}}'
kimi-us() {
  if [[ -z "$KIMI_US_API_KEY" ]]; then
    echo "✗ KIMI_US_API_KEY not found — add it: security add-generic-password -U -a \"\$USER\" -s KIMI_US_API_KEY -w  (key from the Kimi Code Console at kimi.com/code/console)" >&2
    return 1
  fi
  CLAUDE_CODE_MAX_CONTEXT_TOKENS=262144 _LCP_PICKER_JSON="$_KIMI_US_PICKER_JSON" _launch_claude \
    "$KIMI_US_BASE_URL" \
    "$KIMI_US_API_KEY" \
    "k3[1m]" \
    "kimi-for-coding[1m]" \
    "k3-256k" \
    kimi-us \
    "$@"
}

# Qwen Coding Plan (Token Plan / Team Edition) — Alibaba's Anthropic-native endpoint.
# Get the key from the Qwen Cloud console (Token Plan -> API Keys), store as
# QWEN_API_KEY in the login keychain. Docs:
# https://docs.qwencloud.com/developer-guides/clients-and-developer-tools/claude-code
# Model IDs must match character-for-character (checked against the Token Plan
# supported-models table 2026-07-19): opus slot runs qwen3.8-max, which went GA and
# replaced qwen3.8-max-preview; haiku moved qwen3.6-flash -> qwen3.8-flash (2026-09-02,
# IDs cross-checked against the Vercel AI Gateway + OpenRouter catalogs). Plan is LIVE again
# as of 2026-10-12: all nine ids (qwen3.8-max, qwen3.7-max, qwen3.7-plus, qwen3.8-flash,
# qwen3.6-flash, deepseek-v4-pro, deepseek-v4.1-flash, glm-5.3, glm-5.2) smoke-tested 200 via
# /v1/messages. (The 09-16 "AccessDenied.Unpurchased" 403 was a lapsed subscription.) Note the
# plan serves no /v1/models route (404 "Not support") — smoke-test ids, don't list them. If a model 400s, drop
# opus to qwen3.7-max and haiku to qwen3.6-flash.
# 2026-10-19: all nine ids still 200. OpenRouter's new qwen3.8-max-prime / qwen3.8-omni-flash 400
# on the plan — not in the Token Plan table yet.
# /model picker rows for the plan (schema read from claude 2.1.285: modelPicker.options
# = [{model,label?,description?,behavesAs?}]). Added to the built-in lineup, not replacing it.
_QWEN_PICKER_JSON='{"modelPicker":{"options":[
{"model":"qwen3.8-max","label":"Qwen 3.8 Max"},
{"model":"qwen3.7-max","label":"Qwen 3.7 Max"},
{"model":"qwen3.7-plus","label":"Qwen 3.7 Plus"},
{"model":"qwen3.8-flash","label":"Qwen 3.8 Flash"},
{"model":"qwen3.6-flash","label":"Qwen 3.6 Flash"},
{"model":"deepseek-v4-pro","label":"DeepSeek V4 Pro"},
{"model":"deepseek-v4.1-flash","label":"DeepSeek V4.1 Flash"},
{"model":"glm-5.3","label":"GLM 5.3"},
{"model":"glm-5.2","label":"GLM 5.2"}]}}'
# Named qwen-cc (not qwen) so the official Qwen Code binary (/opt/homebrew/bin/qwen,
# installed 2026-09-30 from the Bailian installer) isn't shadowed by this function.
qwen-cc() {
  if [[ -z "$QWEN_API_KEY" ]]; then
    echo "✗ QWEN_API_KEY not found — add it: security add-generic-password -U -a \"\$USER\" -s QWEN_API_KEY -w  (key from the Qwen Cloud console, Token Plan -> API Keys)" >&2
    return 1
  fi
  _LCP_PICKER_JSON="$_QWEN_PICKER_JSON" _launch_claude \
    "$QWEN_BASE_URL" \
    "$QWEN_API_KEY" \
    "qwen3.8-max" \
    "qwen3.7-max" \
    "qwen3.8-flash" \
    qwen \
    "$@"
}

# Same Token Plan endpoint + key, other model families it serves (market list 2026-09-30:
# deepseek-v4-pro, deepseek-v4.1-flash, glm-5.3, glm-5.2, qwen3.7-plus). Each wrapper
# only swaps the three model slots. All five smoke-tested 200 on 2026-10-12; if one 400s/403s
# later, it dropped out of the plan's supported table — swap the ID.
_qwen_plan() {
  if [[ -z "$QWEN_API_KEY" ]]; then
    echo "✗ QWEN_API_KEY not found — see qwen() for how to add it" >&2
    return 1
  fi
  local opus="$1" sonnet="$2" haiku="$3"; shift 3
  _LCP_PICKER_JSON="$_QWEN_PICKER_JSON" _launch_claude "$QWEN_BASE_URL" "$QWEN_API_KEY" "$opus" "$sonnet" "$haiku" qwen "$@"
}
# Generation models (image/video) can't run in the Claude harness — separate endpoints.
# Files land in ~/qwen-media (override with QWEN_MEDIA_DIR). Usage: qwen-image "prompt" [--model ..]
qwen-image() { python3 "${_LCP_LIB_DIR}/qwen_media.py" image "$@"; }
qwen-video() { python3 "${_LCP_LIB_DIR}/qwen_media.py" video "$@"; }
qwen-ds()   { _qwen_plan "deepseek-v4-pro" "deepseek-v4-pro" "deepseek-v4.1-flash" "$@"; }
qwen-glm()  { _qwen_plan "glm-5.3" "glm-5.3" "glm-5.2" "$@"; }
qwen-plus() { _qwen_plan "qwen3.7-plus" "qwen3.7-plus" "qwen3.8-flash" "$@"; }

# OpenRouter - Claude via OpenRouter. Moved to the 5.5 family 2026-10-12 (all three on the OR
# catalog): opus-5.5 $4/$20 (was opus-5 at $5/$25 — newer AND cheaper), sonnet-5.5 $2/$10,
# haiku-5.5 $0.10/$0.50 (was haiku-4.5 at $1/$5, 10x cheaper for the background lane).
openrouter() {
  _launch_claude \
    "$OPENROUTER_BASE_URL" \
    "$OPENROUTER_API_KEY" \
    "anthropic/claude-opus-5.5" \
    "anthropic/claude-sonnet-5.5" \
    "anthropic/claude-haiku-5.5" \
    "$@"
}

# Fable 5.1 — Anthropic's creative powerhouse via OpenRouter. 1M ctx. Premium ($10/$50 per M).
# Opus+Sonnet roles run Fable; haiku lane drops to claude-haiku-5.5 ($0.10/$0.50, moved from
# haiku-4.5 on 2026-10-12) so background calls (titles, summaries) don't bill at $50/M output.
fable() {
  _launch_claude \
    "$OPENROUTER_BASE_URL" \
    "$OPENROUTER_API_KEY" \
    "anthropic/claude-fable-5.1" \
    "anthropic/claude-fable-5.1" \
    "anthropic/claude-haiku-5.5" \
    "$@"
}

# Vercel AI Gateway - Anthropic-native gateway to 280+ models across providers.
# Slugs are creator/model (anthropic/claude-opus-5.5, openai/gpt-6.1-sol, google/gemini-...).
# Browse live models + pricing with `vai-models`. Key: AI_GATEWAY_API_KEY in the login keychain.
# ⚠ 2026-10-12: AI_GATEWAY_API_KEY is NOT in the login keychain — this lane launches with an empty
# token until you add it (security add-generic-password -U -a "$USER" -s AI_GATEWAY_API_KEY -w).
# Slugs moved to the 5.5 family the same day; the gateway's public /v1/models lists all three.
vai() {
  _launch_claude \
    "$VAI_BASE_URL" \
    "$AI_GATEWAY_API_KEY" \
    "anthropic/claude-opus-5.5" \
    "anthropic/claude-sonnet-5.5" \
    "anthropic/claude-haiku-5.5" \
    "$@"
}

# === SiliconFlow (api.siliconflow.com, international) — Anthropic-native endpoint ===
# Rewritten 2026-10-21: SiliconFlow now serves /v1/messages directly (their own Claude Code
# guide: docs.siliconflow.com/en/usercases/use-siliconcloud-in-ClaudeCode), so the old LiteLLM
# bridge (which 404'd on /v1/responses) is gone. Plain _launch_claude, same as deepseek/kimi.
# Key is a .com key — api.siliconflow.cn 401s on it. No /anthropic suffix: base is the bare host.
# DATA: prompts, CLAUDE.md and repo contents go to SiliconFlow (third party). Same rule as geminifree:
# keep PHI / financial / legal / client code off this lane. Their retention terms are not recorded here.
# Free tier: NONE on .com (one-off $1 signup credit only; the free small models live on .cn).
# Rate limits are per-tier by monthly spend (L0 = 1000 RPM / 40k TPM) -> TPM is the real ceiling.
#
# STREAMING MATRIX 2026-10-21 (Claude Code always streams; non-stream curl tests lie here):
#   OK  text+tools: DeepSeek V4.1-Flash (undated), V4-Pro(-0813), V4-Flash; GLM 5.3/5.3-Flash/5.2/5V-Turbo;
#                   Kimi K3, K2.6; Qwen3.8-2.4T, 3.6-35B-A3B, 3.6-27B, 3.5-9B, Qwen3-Coder-30B-A3B;
#                   Hy3, Hy4-preview; Gemma 4 26B/31B; LongCat-2.0; Ling-flash-2.0
#   BROKEN (do not use in Claude Code):
#     deepseek-ai/DeepSeek-V4.1-Flash-1017  — every text_delta empty, tool JSON split into 17 blocks
#                                             with blank id/name -> Bash "command is missing" x15.
#                                             The undated slug is fine; use that.
#     moonshotai/Kimi-K2.7-Code, stepfun-ai/Step-3.5-Flash — stream zero text (tools OK)
#     MiniMaxAI/MiniMax-M3                  — raw <think> leaks into text deltas
#     Qwen/Qwen3.8-27B                      — tool JSON fragmented across 7 blocks
#     deepseek-ai/DeepSeek-V3.2, ByteDance-Seed/Seed-OSS-36B — never emit tool_use
#     openai/gpt-oss-20b/120b               — "Function call is not supported for this model"
#   Re-run the matrix after SiliconFlow changes anything: lib/ has no helper yet; the one-off was
#   /v1/messages stream=true, "Reply with exactly: pong" + a Bash tool call, concat the deltas.
#
# THINKING IS INVERTED HERE (measured 2026-10-21, Claude Code 2.1.306): Claude Code sends
#   thinking:{type:adaptive} + its beta header, and DeepSeek/GLM on SiliconFlow read that as
#   "reasoning OFF" (0 thinking chars, ~300 out tokens). The usual off-switches — Option+T,
#   MAX_THINKING_TOKENS=0, CLAUDE_CODE_DISABLE_THINKING=1 — just omit the field, and the model falls
#   back to ITS default = reasoning ON (2.5-3x output tokens, 1.4-2x latency). So: never use those
#   here. Default lane = non-reasoning (fast, cheap). `siliconflow --think` sends an explicit
#   thinking:{type:enabled,budget_tokens:16000} via CLAUDE_CODE_EXTRA_BODY (verified on a capture
#   server: it replaces Claude Code's object verbatim). Direct probe, same prompt: 62 output tokens
#   adaptive vs 308 enabled — but SiliconFlow streams ZERO thinking_delta for DeepSeek, so the
#   reasoning is paid for and used, never shown. GLM does stream its thinking.
#   /effort is a live cost dial either way (low cut reasoning ~60%, shortens answers when off).
# COST DISPLAY LIES: Claude Code prices unknown ids at an Opus-class rate and ignores cache reads, so
#   /usage, the statusline $ and --max-budget-usd are ~1000x too high on this lane. Real numbers:
#   input is nearly free (cache-read $0.003/M, hits 98%+ of the system prompt across sessions),
#   output is the whole bill. Truthful display needs modelPricing.overrides in managed settings
#   (/Library/Application Support/ClaudeCode/managed-settings.json; user/project settings ignore
#   it) — see llm-providers/sweeps/2026-10-21.md before writing one.
#   The haiku model (Qwen3-Coder) does not cache; irrelevant for helper calls, matters only for
#   long `model: haiku` subagents.
#
# Usage:
#   siliconflow                                   # default: DeepSeek V4.1-Flash (1M ctx), reasoning OFF
#   siliconflow --think                           # same model, reasoning ON (budget 16k) — hard problems
#   siliconflow zai-org/GLM-5.3                   # any chat slug from `sf-models`
#   siliconflow -p "hi"                           # flags pass through to claude
#   sf-models [grep]                              # live chat-model list; ✗ = broken for Claude Code
#   sf-models --use <slug> [claude args]          # pick + launch
# /model inside the session lists the curated rows in _SF_PICKER_JSON (all stream-verified).
# Prices are USD per M tokens (in/out) from SiliconFlow's model pages 2026-10-21 — approximate.
_SF_DEFAULT_MODEL="deepseek-ai/DeepSeek-V4.1-Flash"
# Haiku slot (helpers, /model haiku, `model: haiku` subagents): cheapest stream-clean tool-capable
# model, 1.5s on the tool smoke test. GLM-5.3-Flash is the smarter alternative ($0.15/$0.50, 5.7s).
_SF_HAIKU_MODEL="Qwen/Qwen3-Coder-30B-A3B-Instruct"
_SF_PICKER_JSON='{"modelPicker":{"options":[
{"model":"deepseek-ai/DeepSeek-V4.1-Flash","label":"DeepSeek V4.1 Flash","description":"1M ctx, ~$0.15/$0.60 — default (NOT the -1017 slug: broken stream)"},
{"model":"deepseek-ai/DeepSeek-V4-Pro-0813","label":"DeepSeek V4 Pro 0813","description":"1M ctx, ~$1.32/$3.96"},
{"model":"deepseek-ai/DeepSeek-V4-Flash","label":"DeepSeek V4 Flash","description":"1M ctx, vision, ~$0.13/$0.28 (slow: 26s on smoke test)"},
{"model":"zai-org/GLM-5.3","label":"GLM 5.3","description":"1M ctx, ~$1.40/$4.40"},
{"model":"zai-org/GLM-5.3-Flash","label":"GLM 5.3 Flash","description":"1M ctx, vision, ~$0.15/$0.50"},
{"model":"moonshotai/Kimi-K3","label":"Kimi K3","description":"1M ctx, vision, ~$2.70/$13.50"},
{"model":"moonshotai/Kimi-K2.6","label":"Kimi K2.6","description":"256k ctx ⚠ window sized 1M, short sessions only; vision, ~$0.77/$3.40"},
{"model":"Qwen/Qwen3.8-2.4T-A95B","label":"Qwen3.8 2.4T","description":"1M ctx, ~$2.00/$6.00"},
{"model":"Qwen/Qwen3.6-35B-A3B","label":"Qwen3.6 35B-A3B","description":"262k ctx ⚠ window sized 1M, short sessions only; ~$0.20/$1.60"},
{"model":"tencent/Hy4-preview","label":"Tencent Hy4 preview","description":"ctx + price not yet checked"},
{"model":"Qwen/Qwen3-Coder-30B-A3B-Instruct","label":"Qwen3 Coder 30B-A3B","description":"262k ctx ⚠ window sized 1M; ~$0.07/$0.28 — haiku lane"}]}}'

# Only one host is valid for this key. The lane moved from api.siliconflow.cn/v1 (LiteLLM days) to
# the bare .com host on 2026-10-21; `: ${VAR:=}` keeps whatever an older `source` exported, Claude
# Code then POSTs .cn/v1/v1/messages and reports the 404 as "model may not exist" — cost a morning.
_sf_fix_base_url() {
  if [[ "${SILICONFLOW_BASE_URL:-}" != "https://api.siliconflow.com" ]]; then
    echo "↻ SILICONFLOW_BASE_URL was '${SILICONFLOW_BASE_URL:-unset}' (stale from an older config) — using https://api.siliconflow.com" >&2
    export SILICONFLOW_BASE_URL="https://api.siliconflow.com"
  fi
}

siliconflow() {
  if [[ -z "${SILICONFLOW_API_KEY:-}" ]]; then
    echo "✗ SILICONFLOW_API_KEY not found — add it: security add-generic-password -U -a \"\$USER\" -s SILICONFLOW_API_KEY -w  (key from cloud.siliconflow.com)" >&2
    return 1
  fi
  _sf_fix_base_url
  # First arg is the model slug iff it looks like one (every SiliconFlow id has a "/"); a bare
  # prompt like `siliconflow "explain this"` falls through to claude instead of becoming the model.
  local model="$_SF_DEFAULT_MODEL"
  if [[ -n "${1:-}" && "$1" == */* ]]; then
    model="$1"; shift
  fi
  # --think (anywhere in the args): explicit reasoning on. See the header for why the normal
  # Claude Code switches do the opposite here.
  local -a rest=()
  local a think=0
  for a in "$@"; do
    [[ "$a" == "--think" ]] && { think=1; continue; }
    rest+=("$a")
  done
  set -- "${rest[@]}"
  # Stale-key guard: a shell that was open when the keychain entry was rotated still holds the old
  # value until it re-sources. Probe once (header via fd, so the key is not on the curl argv); on a
  # 401 that is really SiliconFlow's (body carries their "code" field, not a captive portal's),
  # reload from keychain.
  local body probe
  body=$(curl -s -m 4 -w $'\n%{http_code}' "$SILICONFLOW_BASE_URL/v1/models" \
    -H @<(print -r -- "Authorization: Bearer $SILICONFLOW_API_KEY"))
  probe=${body##*$'\n'}
  if [[ "$probe" == "401" && "$body" == *'"code"'* ]]; then
    local kc
    kc=$(security find-generic-password -s SILICONFLOW_API_KEY -w 2>/dev/null)
    if [[ -n "$kc" && "$kc" != "$SILICONFLOW_API_KEY" ]]; then
      export SILICONFLOW_API_KEY="$kc"
      echo "↻ SILICONFLOW_API_KEY in this shell was stale — reloaded from keychain" >&2
    else
      echo "✗ SiliconFlow rejects this key (401). Rotate it at cloud.siliconflow.com, then:" >&2
      echo "  security add-generic-password -U -a \"\$USER\" -s SILICONFLOW_API_KEY -w" >&2
      return 1
    fi
  fi
  if [[ "$model" == "deepseek-ai/DeepSeek-V4.1-Flash-1017" ]]; then
    echo "⚠ the -1017 slug streams broken on SiliconFlow (empty text, shredded tool calls) — using deepseek-ai/DeepSeek-V4.1-Flash" >&2
    model="deepseek-ai/DeepSeek-V4.1-Flash"
  fi
  # 1M-context models (DeepSeek V4.x, GLM 5.3, Kimi K3, Qwen3.8-2.4T) get the full window;
  # the unknown-model default would size them at 200k.
  # CLAUDE_CODE_EXTRA_BODY replaces Claude Code's own `thinking` object verbatim; exported only for
  # this launch. DISABLE_COST_WARNINGS: the $ it would warn about is the Opus-rate fiction above.
  (( think )) && export CLAUDE_CODE_EXTRA_BODY='{"thinking":{"type":"enabled","budget_tokens":16000}}'
  (( think )) && echo "🧠 reasoning ON (budget 16k) — billed as output tokens; SiliconFlow does not stream DeepSeek's thinking back" >&2
  DISABLE_COST_WARNINGS=1 CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 _LCP_PICKER_JSON="$_SF_PICKER_JSON" _launch_claude \
    "$SILICONFLOW_BASE_URL" \
    "$SILICONFLOW_API_KEY" \
    "$model" \
    "$model" \
    "$_SF_HAIKU_MODEL" \
    siliconflow \
    "$@"
  local rc=$?
  (( think )) && unset CLAUDE_CODE_EXTRA_BODY
  return $rc
}

# Live model list from SiliconFlow. Chat models only (image/video/audio/embedding/rerank filtered
# out). `sf-models [pattern]` greps; `sf-models --use <slug> [claude args]` launches.
# /v1/models carries no pricing — check cloud.siliconflow.com/models for the number before a long run.
sf-models() {
  if [[ -z "${SILICONFLOW_API_KEY:-}" ]]; then
    echo "✗ SILICONFLOW_API_KEY not found" >&2; return 1
  fi
  if [[ "${1:-}" == "--use" ]]; then
    shift
    [[ -z "${1:-}" ]] && { echo "usage: sf-models --use <slug> [claude args]" >&2; return 1; }
    siliconflow "$@"; return
  fi
  _sf_fix_base_url
  local pattern="${1:-}" body
  body=$(curl -sf -m 15 "$SILICONFLOW_BASE_URL/v1/models" \
    -H @<(print -r -- "Authorization: Bearer $SILICONFLOW_API_KEY")) \
    || { echo "✗ could not reach $SILICONFLOW_BASE_URL/v1/models (key? network?)" >&2; return 1; }
  print -r -- "$body" | python3 -I -c '
import json,sys,re
skip=re.compile(r"(FLUX|Wan-AI|Qwen-Image|Z-Image|fish-speech|CosyVoice|IndexTTS|Embedding|Reranker)",re.I)
# Verified broken for Claude Code over /v1/messages stream=true (2026-10-21) — see lane header.
broken={
 "deepseek-ai/DeepSeek-V4.1-Flash-1017":"empty text, shredded tool calls (use undated slug)",
 "moonshotai/Kimi-K2.7-Code":"streams no text","stepfun-ai/Step-3.5-Flash":"streams no text",
 "MiniMaxAI/MiniMax-M3":"<think> leaks into text","Qwen/Qwen3.8-27B":"tool JSON fragmented",
 "deepseek-ai/DeepSeek-V3.2":"never calls tools","ByteDance-Seed/Seed-OSS-36B-Instruct":"never calls tools",
 "openai/gpt-oss-20b":"no function calling","openai/gpt-oss-120b":"no function calling"}
ids=sorted((m["id"] for m in json.load(sys.stdin)["data"] if not skip.search(m["id"])),key=str.lower)
pat=sys.argv[1].lower()
shown=0
for i in ids:
    if pat and pat not in i.lower(): continue
    shown+=1
    print(f"  ✗ {i}  — {broken[i]}" if i in broken else f"    {i}")
print(f"\n{shown}/{len(ids)} chat models  (✗ = broken for Claude Code; untested slugs may still misbehave — try `siliconflow <slug> -p pong` first)")
' "$pattern"
}

# OpenRouter cheap-but-good launchers (paid, but pennies — won't queue like free tier).
# Verify live pricing anytime with `or-models --cheap`.

# GLM 5.3 Flash — ~$0.05/$0.16 per M, 1M ctx. Re-priced again by 2026-10-19: output fell back from
# $1.20 to $0.16 (input up from $0.02). Now within ~25% of qwenflash on output — usable for chatty work.
# (replaced glm-4.7-flash 2026-09-02: cheaper output, 6x the context.)
glmflash() {
  _launch_claude \
    "$OPENROUTER_BASE_URL" \
    "$OPENROUTER_API_KEY" \
    "z-ai/glm-5.3-flash" \
    "z-ai/glm-5.3-flash" \
    "z-ai/glm-5.3-flash" \
    "$@"
}

# Qwen3.7 Flash — ~$0.03/$0.13 per M, 1M ctx. Cheapest in and out, huge context.
# (re-checked 2026-09-16: qwen3.8-flash exists but is $0.15/$0.47 — 5x the price, so this stays.)
# (replaced qwen3.5-flash-02-23 2026-09-02: ~half the price, same 1M ctx.)
qwenflash() {
  _launch_claude \
    "$OPENROUTER_BASE_URL" \
    "$OPENROUTER_API_KEY" \
    "qwen/qwen3.7-flash" \
    "qwen/qwen3.7-flash" \
    "qwen/qwen3.7-flash" \
    "$@"
}

# Gemini 3.1 Flash Lite — ~$0.25/$1.50 per M, 1M ctx. Budget-frontier when you need more brain.
# (still the cheapest Gemini on OpenRouter, re-checked 2026-09-16. Newer: gemini-3.5-flash-lite
# ~$0.30/$2.50, gemini-3.8-flash ~$0.75/$3.75 — both pricier, only worth it if you need the brain.)
# (2026-10-19: still $0.25/$1.50 and still the cheapest. gemini-3.8-flash is now $0.83/$4.12; newest
# is gemini-4-argon at $2/$10 — frontier pricing, not a flash-lane candidate.)
geminiflash() {
  _launch_claude \
    "$OPENROUTER_BASE_URL" \
    "$OPENROUTER_API_KEY" \
    "google/gemini-3.1-flash-lite" \
    "google/gemini-3.1-flash-lite" \
    "google/gemini-3.1-flash-lite" \
    "$@"
}

# Gemini FREE tier — your own GEMINI_API_KEY (AI Studio), no OpenRouter, $0.
# Gemini speaks no Anthropic API, so a local LiteLLM proxy translates (native gemini/* adapter —
# unlike the old siliconflow openai/* route it does NOT hit /v1/responses, so it works). Verified
# 2026-09-16: plain replies + Claude Code tool calls round-trip fine.
# Free tier = Flash family only (3.8/3.7/3.6/3.5 Flash, 3.5 Flash-Lite); Pro models 429 with a
# free_tier quota of zero. Free-tier prompts MAY be used by Google to improve products — keep
# private/client code off this lane. Per-model RPM/RPD caps live only in AI Studio:
#   https://aistudio.google.com/rate-limit
# Usage: geminifree [model] [claude args...]   e.g. geminifree gemini-3.5-flash-lite -p "hi"
# Haiku/background lane runs 3.5 Flash-Lite so titles/summaries don't eat the main model's cap.
_GF_PORT=8778
_GF_RUNDIR="${XDG_CACHE_HOME:-$HOME/.cache}/lcp"
_GF_PIDFILE="$_GF_RUNDIR/gemini-litellm.pid"
_GF_CONFIG="$_GF_RUNDIR/gemini-litellm.yaml"
_GF_LOG="$_GF_RUNDIR/gemini-litellm.log"

geminifree() {
  if [[ -z "$GEMINI_API_KEY" ]]; then
    echo "✗ GEMINI_API_KEY not found — get one at https://aistudio.google.com/apikey, then: security add-generic-password -U -a \"\$USER\" -s GEMINI_API_KEY -w" >&2
    return 1
  fi
  if ! command -v litellm &>/dev/null; then
    echo "✗ litellm not found. Install: uv tool install 'litellm[proxy]' --python 3.12" >&2
    return 1
  fi

  local model="gemini-3.8-flash"
  if [[ -n "${1:-}" && "$1" != -* ]]; then
    model="$1"; shift
  fi

  mkdir -p "$_GF_RUNDIR"
  cat > "$_GF_CONFIG" <<YAML
model_list:
  - model_name: "*"
    litellm_params:
      model: "gemini/*"
      api_key: "os.environ/GEMINI_API_KEY"
litellm_settings:
  drop_params: true
YAML

  if [[ -f "$_GF_PIDFILE" ]] && kill -0 "$(cat "$_GF_PIDFILE")" 2>/dev/null; then
    kill "$(cat "$_GF_PIDFILE")" 2>/dev/null; sleep 1
  fi

  echo "→ starting LiteLLM proxy (Gemini free tier) on :$_GF_PORT — model: $model"
  litellm --config "$_GF_CONFIG" --host 127.0.0.1 --port "$_GF_PORT" &>"$_GF_LOG" &
  echo $! > "$_GF_PIDFILE"

  _gf_cleanup() { kill "$(cat "$_GF_PIDFILE" 2>/dev/null)" 2>/dev/null; rm -f "$_GF_PIDFILE" 2>/dev/null; }
  trap '_gf_cleanup' EXIT INT TERM

  echo -n "  waiting for proxy"
  local n=0
  while ! curl -sf "http://127.0.0.1:$_GF_PORT/health/liveliness" &>/dev/null; do
    echo -n "."; sleep 1; n=$((n+1))
    [[ $n -gt 60 ]] && { echo " TIMEOUT — check $_GF_LOG"; return 1; }
  done
  echo " ready!"; echo ""

  CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 _launch_claude \
    "http://127.0.0.1:$_GF_PORT" "gf-local" "$model" "$model" "gemini-3.5-flash-lite" geminifree "$@"
}

# Meta Muse Spark 1.3 — ~$1.25/$4.25 per M, 1M ctx, multimodal (text+image+video+audio+file).
# NOT free: it briefly was ($0/$0) around 2026-09-02 and got caught by orf-update into
# _OR_FREE_MODELS with no ":free" suffix; Meta repriced it before 2026-09-12 and the stale
# entry would've silently billed anyone who picked it via `orf`. Pulled from the free list
# and given its own paid lane here instead, same pattern as glmflash/qwenflash/geminiflash.
# Cheaper contributor tier exists too (meta/muse-spark-1.3-contributor, ~$0.10/$0.20/M) if
# the flagship's brain isn't needed.
musespark() {
  _launch_claude \
    "$OPENROUTER_BASE_URL" \
    "$OPENROUTER_API_KEY" \
    "meta/muse-spark-1.3" \
    "meta/muse-spark-1.3" \
    "meta/muse-spark-1.3" \
    "$@"
}

# === OpenRouter FREE models ===
# Dynamic picker: run `orf` to pick interactively, or `orf <model-id>` to use directly
# Examples:
#   orf                                    # interactive fzf picker
#   orf openrouter/free                   # use directly (OpenRouter's free-pool router)
#   orf openrouter/free -p "hi"           # pass extra claude args

# Free model registry (updated 2026-10-21)
_OR_FREE_MODELS=(
  "cohere/north-mini-code:free                        | Cohere: North Mini Code (free) | ctx:256k"
  "dots-studio/dots-3-note-preview:free               | Dots Studio: Dots3-Note Preview (free) | ctx:512k"
  "google/gemma-4-26b-a4b-it:free                     | Google: Gemma 4 26B A4B  (free) | ctx:262k"
  "google/gemma-4-31b-it:free                         | Google: Gemma 4 31B (free) | ctx:262k"
  "google/lyria-3-clip-preview                        | Google: Lyria 3 Clip Preview | ctx:1M"
  "google/lyria-3-pro-preview                         | Google: Lyria 3 Pro Preview | ctx:1M"
  "liquid/lfm-2.5-2.6b:free                           | LiquidAI: LFM2.5-2.6B (free) | ctx:65k"
  "minimax/minimax-m3.1-flash:free                    | MiniMax: MiniMax M3.1 Flash (free) | ctx:1M"
  "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free | NVIDIA: Nemotron 3 Nano Omni (free) | ctx:256k"
  "nvidia/nemotron-3-super-120b-a12b:free             | NVIDIA: Nemotron 3 Super (free) | ctx:262k"
  "nvidia/nemotron-3-ultra-550b-a55b:free             | NVIDIA: Nemotron 3 Ultra (free) | ctx:1M"
  "nvidia/nemotron-3.5-content-safety:free            | NVIDIA: Nemotron 3.5 Content Safety (free) | ctx:128k"
  "nvidia/nemotron-3.5-lightning:free                 | NVIDIA: Nemotron 3.5 Lightning (free) | ctx:1M"
  "nvidia/nemotron-3.5-super-vl:free                  | NVIDIA: Nemotron 3.5 Super VL (free) | ctx:1M"
  "openrouter/free                                    | Free Models Router        | ctx:200k"
  "poolside/laguna-s-2.1:free                         | Poolside: Laguna S 2.1 (free) | ctx:262k"
  "poolside/laguna-xs-2.1:free                        | Poolside: Laguna XS 2.1 (free) | ctx:262k"
  "thinkingmachines/inkling-small:free                | Thinking Machines: Inkling Small (free) | ctx:1M"
  "thinkingmachines/inkling:free                      | Thinking Machines: Inkling (free) | ctx:1M"
  "xingchen-agi/xing4.0-29b-a4b:free                  | XingChen: Xing4.0 29B A4B (free) | ctx:262k"
)

# Probe a free model with a 1-token completion to check if OpenRouter's
# shared upstream pool is currently 429-ing it. Free models share a global
# pool per-provider (not a per-key limit), so this flips minute to minute.
_orf_ratelimited() {
  local model="$1" code
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 8 \
    "$OPENROUTER_BASE_URL/v1/chat/completions" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}")
  [[ "$code" == "429" ]]
}

# Cache the OpenRouter catalog fetch for a few minutes — _orf_still_free hits this
# on every `orf` call just to check one model's price, and refetching the whole
# catalog that often (on top of _orf_ratelimited's own network round-trip) is wasted
# latency for data that doesn't change minute to minute. Keyed by API base so a
# different OPENROUTER_BASE_URL doesn't serve stale cross-account data.
_orf_models_json() {
  local cache="${TMPDIR:-/tmp}/orf_models_$(echo -n "$OPENROUTER_BASE_URL" | shasum | cut -d' ' -f1).json"
  if [[ -f "$cache" ]]; then
    local age=$(( $(date +%s) - $(stat -f %m "$cache" 2>/dev/null || echo 0) ))
    if (( age < 600 )); then
      cat "$cache"
      return 0
    fi
  fi
  local resp
  resp=$(curl -sf -m 8 "$OPENROUTER_BASE_URL/v1/models" -H "Authorization: Bearer $OPENROUTER_API_KEY") || return 1
  print -r -- "$resp" > "$cache"
  print -r -- "$resp"
}

# _OR_FREE_MODELS is a cache — a model that was $0 when orf-update last ran can get
# repriced by the provider any day after (this is exactly how meta/muse-spark-1.3 slipped
# in: free on 2026-09-02, paid by 2026-09-12, nothing ever re-checked it). Re-verify live
# pricing right before we'd actually spend money on it, via or_price_check.py (model id
# passed as argv, never spliced into source — an earlier inline `python3 -c` version with
# the id interpolated into a string literal was a code-injection bug, caught in review).
#
# Three distinct outcomes, not two: confirmed-free/not-found (silent, common path),
# confirmed-paid (warn + confirm before launching — this is the one case that actually
# costs money if missed), and couldn't-verify (say so; don't stay silent as if checked).
_orf_still_free() {
  local model="$1" script="${_LCP_LIB_DIR:-${_LCP_DIR:-.}/lib}/or_price_check.py"
  local response pricing rc

  response=$(_orf_models_json) || {
    echo "⚠ couldn't verify $model's pricing (OpenRouter fetch failed) — proceeding unverified." >&2
    return 0
  }

  pricing=$(print -r -- "$response" | python3 "$script" "$model")
  rc=$?
  case $rc in
    0) return 0 ;;
    1)
      echo "⚠ $model is no longer free — OpenRouter now prices it at \$${pricing%,*}/\$${pricing#*,} per token." >&2
      echo "  The cached free-list is stale (run orf-update to refresh it)." >&2
      if [[ -t 0 ]]; then
        local reply
        read -q "reply?  Launch anyway? [y/N] "
        echo >&2
        [[ "$reply" == [yY] ]] || return 1
      else
        echo "  Non-interactive shell — proceeding since you asked for it by name." >&2
      fi
      ;;
    *)
      echo "⚠ couldn't verify $model's pricing (unexpected API response) — proceeding unverified." >&2
      ;;
  esac
  return 0
}

orf() {
  local model="$1"

  # If no model given, pick interactively
  if [[ -z "$model" ]]; then
    if ! command -v fzf &>/dev/null; then
      echo "Available free models:"
      echo ""
      local i=1
      for entry in "${_OR_FREE_MODELS[@]}"; do
        printf "  %2d) %s\n" "$i" "$entry"
        i=$((i + 1))
      done
      echo ""
      echo -n "Pick a number (or install fzf for fuzzy search): "
      read -r choice
      [[ -z "$choice" ]] && return 1
      [[ "$choice" =~ ^[0-9]+$ ]] || { echo "Invalid choice: $choice"; return 1; }
      [[ $choice -ge 1 && $choice -le ${#_OR_FREE_MODELS[@]} ]] || { echo "Out of range (1-${#_OR_FREE_MODELS[@]})"; return 1; }
      model="${_OR_FREE_MODELS[$choice]%%|*}"
      model="${model// /}"
    else
      local picked
      picked=$(printf '%s\n' "${_OR_FREE_MODELS[@]}" | fzf --prompt="Pick a free model> " --height=30)
      [[ -z "$picked" ]] && return 1
      model="${picked%%|*}"
      model="${model// /}"
    fi
  else
    shift  # consume model arg, rest goes to claude
  fi

  echo "Using model: $model"
  _orf_still_free "$model" || return 1

  if _orf_ratelimited "$model"; then
    echo "⚠ $model is rate-limited upstream right now — probing other free models..."
    local candidate found="" tried=0
    for candidate in "${_OR_FREE_MODELS[@]}"; do
      (( tried >= 5 )) && break
      candidate="${candidate%%|*}"; candidate="${candidate// /}"
      [[ "$candidate" == "$model" ]] && continue
      tried=$((tried + 1))
      echo -n "  $candidate... "
      if _orf_ratelimited "$candidate"; then
        echo "limited."
      else
        echo "OK."
        found="$candidate"
        break
      fi
    done
    if [[ -n "$found" ]]; then
      model="$found"
      echo "Using model: $model"
    else
      echo "  free pool looks fully congested — falling back to qwenflash (paid, ~\$0.03/\$0.13 per M, pennies per session)."
      qwenflash "$@"
      return
    fi
  fi

  _launch_claude "$OPENROUTER_BASE_URL" "$OPENROUTER_API_KEY" "$model" "$model" "$model" "$@"
}

# Refresh free models list from OpenRouter API (edits claude_config.zsh in place)
# Pass --dry-run to just print the block without touching the file.
orf-update() {
  local script="${_LCP_LIB_DIR:-${_LCP_DIR:-.}/lib}/or_free_update.py"
  local config="${_LCP_DIR}/claude_config.zsh"
  echo "Fetching free models from OpenRouter..."

  # Dry run: just print the block, touch nothing.
  if [[ "$1" == "--dry-run" ]]; then
    curl -sf "$OPENROUTER_BASE_URL/v1/models" | python3 "$script"
    return
  fi

  if [[ ! -f "$config" ]]; then
    echo "✗ Config not found at $config — set _LCP_DIR to your repo path." >&2
    return 1
  fi

  curl -sf "$OPENROUTER_BASE_URL/v1/models" | python3 "$script" --config "$config"
  # zsh $pipestatus: exit code of each pipe stage. Stage 1 = curl, stage 2 = python.
  if (( pipestatus[1] != 0 )); then
    echo "✗ Couldn't reach OpenRouter (curl failed) — check your network/API and retry. Config untouched." >&2
    return 1
  fi
  if (( pipestatus[2] != 0 )); then
    echo "✗ Update failed — config left untouched." >&2
    return 1
  fi

  # The gotcha: editing the file doesn't update THIS shell's in-memory model
  # list. Re-source so `orf` shows the new models immediately — no manual step.
  source "$config" && echo "↻ Reloaded — run 'orf' and the new models are there."
}

# === OpenRouter model browser with live pricing ===
# Browse, search, and filter ALL OpenRouter models
# Usage:
#   or-models                     # list all models (piped to less)
#   or-models gemma-4             # search for gemma-4
#   or-models --free              # free models only
#   or-models --cheap             # sort by cheapest first
#   or-models --max-tokens        # sort by provider max token limit
#   or-models --free gemma        # combine: free gemma models
#   or-models gemma-4 --use       # search + pick one to launch with Claude Code

or-models() {
  local search="" filter="all" sort_by="name" use_model=false claude_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --free)   filter="free"; shift ;;
      --paid)   filter="paid"; shift ;;
      --cheap)  sort_by="cheap"; shift ;;
      --max-tokens) sort_by="max_tokens"; shift ;;
      --use)    use_model=true; shift ;;
      --help)
        echo "or-models — Browse all OpenRouter models with live pricing"
        echo ""
        echo "Usage:"
        echo "  or-models                     List all models"
        echo "  or-models <query>             Search by name/id"
        echo "  or-models --free              Free models only"
        echo "  or-models --paid              Paid models only"
        echo "  or-models --cheap             Sort by cheapest prompt cost"
        echo "  or-models --max-tokens        Sort by provider max token limit"
        echo "  or-models --use               Pick a model and launch Claude Code"
        echo "  or-models --free gemma        Combine filters with search"
        echo ""
        echo "Examples:"
        echo "  or-models gemma-4             Find Gemma 4 variants"
        echo "  or-models --cheap --paid      Cheapest paid models"
        echo "  or-models qwen --use          Search qwen, pick one, launch"
        return 0
        ;;
      # First unrecognized flag = start of Claude args. Grab the rest verbatim so
      # value-taking flags survive (e.g. `--use -p "hi"` keeps "hi" with -p instead
      # of stealing it as the search term).
      -*)     claude_args+=("$@"); break ;;
      *)      search="$1"; shift ;;
    esac
  done

  local output
  output=$(curl -sf "$OPENROUTER_BASE_URL/v1/models" | python3 "${_LCP_LIB_DIR:-${_LCP_DIR:-.}/lib}/or_models.py" \
    --search "$search" $([[ "$filter" == "free" ]] && echo --free) $([[ "$filter" == "paid" ]] && echo --paid) \
    --sort "$sort_by" 2>&1)
  if [[ ${#output} -eq 0 ]]; then
    echo "Failed to fetch models from OpenRouter."
    return 1
  fi

  if $use_model; then
    echo "$output"
    echo ""
    echo -n "  Enter model ID to use (or empty to cancel): "
    read -r picked
    [[ -z "$picked" ]] && return 1
    echo ""
    echo "Launching Claude Code with $picked..."
    _launch_claude "$OPENROUTER_BASE_URL" "$OPENROUTER_API_KEY" "$picked" "$picked" "$picked" "${claude_args[@]}"
  elif command -v less &>/dev/null && [[ -t 1 ]]; then
    echo "$output" | less -R
  else
    echo "$output"
  fi
}

# === Vercel AI Gateway model browser with live pricing ===
# Browse, search, and filter all Vercel AI Gateway models (no API key needed to list).
# Usage:
#   vai-models                    # list all models (piped to less)
#   vai-models claude-opus        # search
#   vai-models --free             # free models only
#   vai-models --cheap            # sort by cheapest first
#   vai-models --max-tokens       # sort by provider max output tokens
#   vai-models claude --use       # search + pick one to launch with Claude Code
vai-models() {
  local search="" filter="all" sort_by="name" use_model=false all_types=false claude_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --free)   filter="free"; shift ;;
      --paid)   filter="paid"; shift ;;
      --cheap)  sort_by="cheap"; shift ;;
      --max-tokens) sort_by="max_tokens"; shift ;;
      --all-types) all_types=true; shift ;;
      --use)    use_model=true; shift ;;
      --help)
        echo "vai-models — Browse all Vercel AI Gateway models with live pricing"
        echo ""
        echo "Usage:"
        echo "  vai-models                    List language models (default)"
        echo "  vai-models <query>            Search by name/id"
        echo "  vai-models --free             Free models only"
        echo "  vai-models --paid             Paid models only"
        echo "  vai-models --cheap            Sort by cheapest input cost"
        echo "  vai-models --max-tokens       Sort by provider max output tokens"
        echo "  vai-models --all-types        Include image/video/reranking models"
        echo "  vai-models --use              Pick a model and launch Claude Code"
        echo "  vai-models claude --use       Combine search with launch"
        return 0
        ;;
      # First unrecognized flag = start of Claude args. Grab the rest verbatim so
      # value-taking flags survive (e.g. `--use -p "hi"` keeps "hi" with -p instead
      # of stealing it as the search term).
      -*)     claude_args+=("$@"); break ;;
      *)      search="$1"; shift ;;
    esac
  done

  local output
  output=$(curl -sf "$VAI_BASE_URL/v1/models" | python3 "${_LCP_LIB_DIR:-${_LCP_DIR:-.}/lib}/vai_models.py" \
    --search "$search" $([[ "$filter" == "free" ]] && echo --free) $([[ "$filter" == "paid" ]] && echo --paid) \
    $([[ "$all_types" == true ]] && echo --all-types) --sort "$sort_by" 2>&1)
  if [[ ${#output} -eq 0 ]]; then
    echo "Failed to fetch models from Vercel AI Gateway."
    return 1
  fi

  if $use_model; then
    echo "$output"
    echo ""
    echo -n "  Enter model ID to use (or empty to cancel): "
    read -r picked
    [[ -z "$picked" ]] && return 1
    echo ""
    echo "Launching Claude Code with $picked..."
    _launch_claude "$VAI_BASE_URL" "$AI_GATEWAY_API_KEY" "$picked" "$picked" "$picked" "${claude_args[@]}"
  elif command -v less &>/dev/null && [[ -t 1 ]]; then
    echo "$output" | less -R
  else
    echo "$output"
  fi
}

# === llama.cpp LOCAL inference ===
# Full-featured local inference with Metal GPU acceleration
# Usage:
#   lcp                          # interactive model picker from models dir
#   lcp qwen3-30b-a3b            # fuzzy match model name
#   lcp --list                   # list downloaded models
#   lcp --stop                   # stop running server
#   lcp --status                 # check if server is running
#   lcp --pull <hf-repo> <file>  # download a GGUF from HuggingFace

_LCP_MODELS_DIR="${LCP_MODELS_DIR:-$HOME/Models/gguf}"
_LCP_SERVER="$HOME/.local/bin/llama-server"
_LCP_PORT=8776
_LCP_RUNDIR="${XDG_CACHE_HOME:-$HOME/.cache}/lcp"
_LCP_PIDFILE="$_LCP_RUNDIR/llama-server.pid"
_lcp_ensure_rundir() { mkdir -p "$_LCP_RUNDIR"; }

# Default server settings (tuned for M3 Pro 36GB + 22GB model)
_LCP_CTX_SIZE=32768        # 32k context — safe for 22GB model on 36GB RAM (use --ctx to override)
_LCP_GPU_LAYERS=99         # offload all layers to Metal GPU
_LCP_THREADS=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || echo 6)  # perf cores only (6 on M3 Pro)
_LCP_BATCH_SIZE=4096       # larger batch = faster prompt ingestion
_LCP_UBATCH_SIZE=1024      # bigger micro-batch for Metal (M3 handles this well)
_LCP_FLASH_ATTN=1          # flash attention (faster, less memory)

lcp() {
  # Cleanup helper — stops the server THIS invocation starts and clears its pidfile.
  # NOTE: in zsh an EXIT trap set inside a function fires on function *return*, not on
  # shell exit. So we must NOT arm it here — doing so would kill a running server when
  # the user merely runs `lcp --status`/`--list`/`--help`/`--pull`. We arm it further
  # down, only after we've actually launched a server (and clear it on "keep running").
  _lcp_cleanup() { kill "$(cat "$_LCP_PIDFILE" 2>/dev/null)" 2>/dev/null; rm -f "$_LCP_PIDFILE" 2>/dev/null; }

  case "${1:-}" in
    --stop)
      if [[ -f "$_LCP_PIDFILE" ]] && kill -0 "$(cat "$_LCP_PIDFILE")" 2>/dev/null; then
        kill "$(cat "$_LCP_PIDFILE")"
        rm -f "$_LCP_PIDFILE"
        echo "llama-server stopped."
      else
        echo "No llama-server running."
      fi
      return 0
      ;;
    --status)
      if [[ -f "$_LCP_PIDFILE" ]] && kill -0 "$(cat "$_LCP_PIDFILE")" 2>/dev/null; then
        local pid=$(cat "$_LCP_PIDFILE")
        echo "llama-server running (PID: $pid, port: $_LCP_PORT)"
        curl -s "http://localhost:$_LCP_PORT/health" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "(health check failed)"
      else
        echo "No llama-server running."
      fi
      return 0
      ;;
    --list)
      echo "Downloaded models in $_LCP_MODELS_DIR:"
      echo ""
      local count=0
      for f in "$_LCP_MODELS_DIR"/*.gguf; do
        [[ -f "$f" ]] || continue
        local size=$(du -h "$f" | cut -f1)
        printf "  %-50s %s\n" "$(basename "$f")" "$size"
        count=$((count + 1))
      done
      [[ $count -eq 0 ]] && echo "  (none — use 'lcp --pull <repo> <file>' to download)"
      echo ""
      echo "Total: $count models"
      return 0
      ;;
    --pull)
      if [[ -z "${2:-}" || -z "${3:-}" ]]; then
        echo "Usage: lcp --pull <hf-repo-id> <filename>"
        echo "Example: lcp --pull unsloth/Qwen3-30B-A3B-GGUF Qwen3-30B-A3B-Q8_0.gguf"
        return 1
      fi
      echo "Downloading $3 from $2..."
      python3 "$_LCP_LIB_DIR/download_gguf.py" --repo "$2" --file "$3" --dir "$_LCP_MODELS_DIR"
      return $?
      ;;
    --help)
      echo "lcp - llama.cpp local inference for Claude Code"
      echo ""
      echo "Usage:"
      echo "  lcp                              Launch with interactive model picker"
      echo "  lcp <partial-name>               Fuzzy match a model and launch"
      echo "  lcp --list                       List downloaded GGUF models"
      echo "  lcp --pull <repo> <file>         Download a GGUF from HuggingFace"
      echo "  lcp --stop                       Stop the running server"
      echo "  lcp --status                     Check server status"
      echo "  lcp --ctx <size>                 Override context size (default: $_LCP_CTX_SIZE)"
      echo "  lcp --help                       This help"
      echo ""
      echo "Settings (edit in ~/.claude_config.zsh):"
      echo "  Context:    $_LCP_CTX_SIZE tokens"
      echo "  GPU layers: $_LCP_GPU_LAYERS"
      echo "  Threads:    $_LCP_THREADS (perf cores)"
      echo "  Batch:      $_LCP_BATCH_SIZE"
      echo "  Flash attn: $([ $_LCP_FLASH_ATTN -eq 1 ] && echo ON || echo OFF)"
      return 0
      ;;
  esac

  # Validate binary exists before attempting launch
  if [[ ! -x "$_LCP_SERVER" ]]; then
    echo "llama-server not found at $_LCP_SERVER"
    echo "Build it: see README.md → Build from source"
    return 1
  fi

  # Parse optional flags — collect unknown flags for passthrough to claude
  local ctx_override=""
  local model_hint=""
  local passthru=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ctx) ctx_override="$2"; shift 2 ;;
      -*)    passthru+=("$1"); shift ;;   # forward unknown flags to claude
      *)     model_hint="$1"; shift; break ;;
    esac
  done

  # Ensure run directory exists
  _lcp_ensure_rundir

  # Find the model file
  local model_file=""
  local gguf_files=("$_LCP_MODELS_DIR"/*.gguf(N))

  if [[ ${#gguf_files[@]} -eq 0 ]]; then
    echo "No GGUF models found in $_LCP_MODELS_DIR"
    echo "Download one with: lcp --pull <hf-repo> <filename>"
    echo "Example: lcp --pull unsloth/Qwen3-30B-A3B-GGUF Qwen3-30B-A3B-Q8_0.gguf"
    return 1
  fi

  if [[ -n "$model_hint" ]]; then
    # Fuzzy match
    for f in "${gguf_files[@]}"; do
      if [[ "$(basename "$f")" == *"$model_hint"* ]]; then
        model_file="$f"
        break
      fi
    done
    if [[ -z "$model_file" ]]; then
      # Case-insensitive retry
      local hint_lower="${model_hint:l}"
      for f in "${gguf_files[@]}"; do
        if [[ "${$(basename "$f"):l}" == *"$hint_lower"* ]]; then
          model_file="$f"
          break
        fi
      done
    fi
    if [[ -z "$model_file" ]]; then
      echo "No model matching '$model_hint' found. Available:"
      for f in "${gguf_files[@]}"; do echo "  $(basename "$f")"; done
      return 1
    fi
  elif [[ ${#gguf_files[@]} -eq 1 ]]; then
    model_file="${gguf_files[1]}"
  else
    # Interactive picker
    if command -v fzf &>/dev/null; then
      model_file=$(printf '%s\n' "${gguf_files[@]}" | xargs -I{} basename {} | fzf --prompt="Pick a model> " --height=20)
      [[ -z "$model_file" ]] && return 1
      model_file="$_LCP_MODELS_DIR/$model_file"
    else
      echo "Available models:"
      local i=1
      for f in "${gguf_files[@]}"; do
        local size=$(du -h "$f" | cut -f1)
        printf "  %2d) %-45s %s\n" "$i" "$(basename "$f")" "$size"
        i=$((i + 1))
      done
      echo -n "Pick a number: "
      read -r choice
      [[ -z "$choice" ]] && return 1
      [[ "$choice" =~ ^[0-9]+$ ]] || { echo "Invalid choice: $choice"; return 1; }
      [[ $choice -ge 1 && $choice -le ${#gguf_files[@]} ]] || { echo "Out of range (1-${#gguf_files[@]})"; return 1; }
      model_file="${gguf_files[$choice]}"
    fi
  fi

  local ctx="${ctx_override:-$_LCP_CTX_SIZE}"
  echo "Model:   $(basename "$model_file")"
  echo "Context: $ctx tokens"
  echo "GPU:     $_LCP_GPU_LAYERS layers | Flash attention: $([ $_LCP_FLASH_ATTN -eq 1 ] && echo ON || echo OFF)"
  echo ""

  # Stop existing server if running, wait for port release
  if [[ -f "$_LCP_PIDFILE" ]] && kill -0 "$(cat "$_LCP_PIDFILE")" 2>/dev/null; then
    echo "Stopping existing llama-server (PID: $(cat "$_LCP_PIDFILE"))..."
    kill "$(cat "$_LCP_PIDFILE")"
    # Wait for process to exit and port to release (max 10s)
    local waited=0
    while kill -0 "$(cat "$_LCP_PIDFILE")" 2>/dev/null || curl -sf "http://localhost:$_LCP_PORT/health" &>/dev/null; do
      sleep 0.5
      waited=$((waited + 1))
      [[ $waited -gt 20 ]] && { echo "Port $_LCP_PORT still in use. Kill manually and retry."; return 1; }
    done
  fi

  # Launch llama-server in background
  echo "Starting llama-server on port $_LCP_PORT..."
  "$_LCP_SERVER" \
    --model "$model_file" \
    --port "$_LCP_PORT" \
    --ctx-size "$ctx" \
    --n-gpu-layers "$_LCP_GPU_LAYERS" \
    --threads "$_LCP_THREADS" \
    --batch-size "$_LCP_BATCH_SIZE" \
    --ubatch-size "$_LCP_UBATCH_SIZE" \
    $([ $_LCP_FLASH_ATTN -eq 1 ] && echo "--flash-attn on") \
    --cont-batching \
    --mlock \
    --cache-type-k q8_0 \
    --cache-type-v q8_0 \
    --log-disable \
    &>"$_LCP_RUNDIR/llama-server.log" &
  echo $! > "$_LCP_PIDFILE"

  # Now that we own a live server, arm cleanup. zsh fires this EXIT trap when lcp
  # returns; the "keep running?" prompt below clears it if the user opts to keep.
  trap '_lcp_cleanup' EXIT INT TERM

  # Wait for server to be ready
  echo -n "Waiting for server"
  local attempts=0
  while ! curl -sf "http://localhost:$_LCP_PORT/health" &>/dev/null; do
    echo -n "."
    sleep 1
    attempts=$((attempts + 1))
    if [[ $attempts -gt 120 ]]; then
      echo " TIMEOUT (check $_LCP_RUNDIR/llama-server.log)"
      return 1
    fi
  done
  echo " ready!"
  echo ""

  # Clear INT/TERM traps — we want Ctrl-C and kill to reach Claude, not kill the server
  trap '' INT TERM

  # Launch Claude Code connected to local server
  local model_name
  model_name=$(basename "$model_file" .gguf)
  _launch_claude "http://localhost:$_LCP_PORT" "local" "$model_name" "$model_name" "$model_name" "$@" "${passthru[@]}"

  # Ask if user wants to keep server running
  if [[ -t 0 ]]; then
    echo ""
    echo -n "Keep llama-server running? [y/N]: "
    read -r keep
    if [[ "$keep" != [yY]* ]]; then
      lcp --stop
    else
      trap - EXIT  # remove cleanup trap — server stays alive
      echo "llama-server stays running (PID: $(cat "$_LCP_PIDFILE" 2>/dev/null))"
    fi
  fi
}

# === HUGGING FACE — load any LLM ===
# Search, download, and run any model from HF Hub in one command
# Usage:
#   hf                                  # interactive search + pick + download + launch
#   hf qwen3 coder                      # search keyword, pick, download, launch
#   hf --pull <repo> <file>             # download specific file then launch
#   hf --list                           # list downloaded models
#   hf --stop                           # stop running server
#   hf --status                         # check server status

# Hugging Face inference server config
_HF_MODEL_DIR="$_LCP_MODELS_DIR"  # reuse the same models directory

# Internal: HF Hub search and download
hf() {
  case "${1:-}" in
    --pull)
      if [[ -z "${2:-}" || -z "${3:-}" ]]; then
        echo "Usage: hf --pull <hf-repo-id> <filename>"
        echo "Example: hf --pull unsloth/Qwen3-30B-A3B-GGUF Qwen3-30B-A3B-Q4_K_M.gguf"
        return 1
      fi
      echo "Downloading $3 from $2..."
      python3 "$_LCP_LIB_DIR/download_gguf.py" --repo "$2" --file "$3" --dir "$_HF_MODEL_DIR"
      return $?
      ;;
    --list)
      lcp --list
      return $?
      ;;
    --stop)
      lcp --stop
      return $?
      ;;
    --status)
      lcp --status
      return $?
      ;;
    --help)
      echo "hf — Search, download, and run any Hugging Face model"
      echo ""
      echo "Usage:"
      echo "  hf                              Interactive search + download + launch"
      echo "  hf <keywords>                   Search, pick, download, launch"
      echo "  hf --pull <repo> <file>         Download a specific GGUF file"
      echo "  hf --list                       List downloaded models"
      echo "  hf --stop                       Stop the running server"
      echo "  hf --status                     Check server status"
      echo "  hf --help                       This help"
      return 0
      ;;
  esac

  # Parse lcp tuning flags and pass them through to the final launch
  local lcp_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ctx) lcp_args+=("$1" "$2"); shift 2 ;;
      -*)    lcp_args+=("$1"); shift ;;
      *)     break ;;
    esac
  done

  # Search Hugging Face Hub for GGUF models. Empty query = browse top-liked
  # models overall, filtered down to ones that actually ship .gguf files —
  # HF's search API does literal substring matching on repo names, so a
  # fallback like "llm.gguf" would just never match anything and always 404.
  local query="$*"

  echo "Searching Hugging Face Hub for: ${query:-(top GGUF models)}..."

  local results search_exit
  results=$(python3 "$_LCP_LIB_DIR/hf_search.py" --query "$query" 2>&1)
  search_exit=$?
  if (( search_exit != 0 )); then
    echo "HF search failed:"
    echo "$results" | tail -5
    return 1
  fi

  if [[ -z "$results" ]]; then
    echo "No models found matching: $query"
    return 1
  fi

  echo ""
  echo "Top Hugging Face GGUF models:"
  echo ""
  echo "$results" | head -20  # Show top 20

  echo ""
  if command -v fzf &>/dev/null; then
    local picked
    picked=$(echo "$results" | fzf --prompt="Pick a model> " --height=30 --layout=reverse)
    [[ -z "$picked" ]] && return 1
    local repo="${picked%%|*}"
    repo="${repo// /}"
  else
    echo "Enter the full repo ID to download:"
    echo -n "> "
    read -r repo
    [[ -z "$repo" ]] && return 1
  fi

  echo ""
  echo "Searching for available GGUF files in: $repo..."

  # List available GGUF files
  local files
  files=$(python3 "$_LCP_LIB_DIR/hf_files.py" "$repo" 2>&1)

  if [[ "$files" == *"No GGUF files found"* ]]; then
    echo "No GGUF files found. This model may not have GGUF weights uploaded."
    return 1
  fi

  echo ""
  echo "Available GGUF files:"
  echo "$files"

  echo ""
  local picked_file=""
  if command -v fzf &>/dev/null; then
    picked_file=$(echo "$files" | fzf --prompt="Pick a GGUF file> " --height=20)
    [[ -z "$picked_file" ]] && return 1
  else
    echo "Enter filename to download:"
    echo -n "> "
    read -r picked_file
    [[ -z "$picked_file" ]] && return 1
  fi

  # Ensure models directory exists
  mkdir -p "$_HF_MODEL_DIR"

  # Download via lcp --pull
  echo ""
  echo "Downloading $picked_file from $repo..."
  lcp --pull "$repo" "$picked_file" || return $?

  # Now launch with lcp, passing through any tuning flags
  echo ""
  echo "Model downloaded. Launching..."
  # lcp parses flags first then breaks on the first positional (the model), so the
  # tuning flags (e.g. --ctx) must come BEFORE the filename or they'd never be consumed.
  lcp "${lcp_args[@]}" "$picked_file"
}

# ==============================================================================
# === OBSERVABILITY & ROUTING ==================================================
# ==============================================================================

# llp-stats — session dashboard
# Tracks sessions, error rates, avg duration, and per-provider breakdown.
# Usage: llp-stats
# Probe every lane and write the status cache LLM Bar reads. Script lives in scripts/ (no secrets).
lane-status() { zsh "${_LCP_DIR}/scripts/lane-status.zsh" --print "$@"; }

llp-stats() {
  [ -f "$_LCP_SESSION_LOG" ] || { echo "No session data yet — run a session first."; return 1; }
  python3 "$_LCP_LIB_DIR/session_stats.py" "$_LCP_SESSION_LOG"
}

# llp-history — raw session log viewer
# Usage: llp-history          # last 10
#        llp-history 30       # last 30
#        llp-history all      # everything
llp-history() {
  [ -f "$_LCP_SESSION_LOG" ] || { echo "No session log found."; return 1; }
  local n="${1:-10}"
  # sessions.jsonl is one JSON object per line — json.tool chokes on multi-line input,
  # so decode line by line and pretty-print each entry separately.
  local _pretty_jsonl='import json, sys
first = True
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    if not first:
        print()
    print(json.dumps(json.loads(line), indent=2, ensure_ascii=False))
    first = False'
  if [[ "$n" == "all" ]]; then
    cat "$_LCP_SESSION_LOG" | python3 -c "$_pretty_jsonl"
  else
    tail -n "$n" "$_LCP_SESSION_LOG" | python3 -c "$_pretty_jsonl"
  fi
}

# llp-which — intelligent provider recommendation
# Analyzes provider health, recent error rates, and task type to recommend a model.
# Usage: llp-which                    # general recommendation
#        llp-which code               # coding task
#        llp-which reasoning          # reasoning/math
#        llp-which fast               # quick query
#        llp-which creative           # creative writing
llp-which() {
  local task="${1:-general}"
  python3 "$_LCP_LIB_DIR/session_which.py" --task "$task" --log "$_LCP_SESSION_LOG"
}

# llp-quick — one-liner: launch the best free model right now
# Uses openrouter/free — OpenRouter's own router over the free pool — and launches with no
# prompts. Switched 2026-10-12: qwen/qwen3-coder:free is gone from the catalog, and every
# individual :free id probed that day 404'd "no endpoints" while the router answered 200.
llp-quick() {
  echo "→ Launching best free model (openrouter/free)..."
  orf openrouter/free "$@"
}

# llp-reset — clear the session log
# Usage: llp-reset
llp-reset() {
  if [[ -f "$_LCP_SESSION_LOG" ]]; then
    local count
    count=$(wc -l < "$_LCP_SESSION_LOG")
    rm -f "$_LCP_SESSION_LOG"
    echo "Cleared $count session entries from log."
  else
    echo "No session log found."
  fi
}

# lcp-help — splash screen listing every launcher/utility in this file
# Usage: lcp-help
lcp-help() {
  cat <<'EOF'
━━━ Claude Code multi-provider launchers ━━━

  CLOUD (paid, full price)
    zai            GLM via Z.AI — cost-effective
    minimax        MiniMax (opus=M3, sonnet/haiku=M3.1 Flash) — key 401 since 09-16, rotate first
    minimaxflash   MiniMax M3.1 Flash on all lanes — unverified until the key is rotated
    deepseek       DeepSeek (opus=V4-Pro, sonnet/haiku=V4.1 Flash-1017)
    deepseekflash  DeepSeek V4.1 Flash-1017 on all lanes — ~$0.15 / $0.60 per M
    kimi           Official Kimi Code CLI (Moonshot binary, not a function here)
    kimi-us        Kimi Code plan inside Claude Code via api.kimi.ai (opus=k3[1m], sonnet=K2.8 Preview[1m], haiku=k3-256k)
    kimi-china     Kimi K3 / K2.7 Code via moonshot.cn pay-as-you-go (alias kimi-cn)
    qwen           Official Qwen Code CLI (Homebrew binary, not a function here)
    qwen-cc        Qwen Token Plan inside Claude Code (opus=3.8-max, sonnet=3.7-max, haiku=3.8-flash)
    qwen-image     Image gen via the plan (qwen-image-3.0-pro default; wan2.7-image[-pro])
    qwen-video     Video gen via the plan (happyhorse-1.1-t2v default) -> ~/qwen-media
    qwen-ds        Same plan: DeepSeek V4-Pro (opus/sonnet), V4.1 Flash (haiku)
    qwen-glm       Same plan: GLM 5.3 (opus/sonnet), GLM 5.2 (haiku)
    qwen-plus      Same plan: Qwen3.7 Plus (opus/sonnet), 3.8-flash (haiku)
    openrouter     Claude Opus/Sonnet/Haiku 5.5 via OpenRouter
    fable          Claude Fable 5 — premium, 1M ctx, creative work
    vai            Vercel AI Gateway — 280+ models, any creator/model slug
    siliconflow    SiliconFlow (.com) — DeepSeek V4.1 Flash default, 11 rows in /model, sf-models to browse; third party — no private data
    geminifree     Gemini free tier on your own GEMINI_API_KEY, via local LiteLLM ($0, Flash only)

  CLOUD — cheap-but-good (OpenRouter, pennies per session)
    glmflash       GLM 5.3 Flash          ~$0.05 / $0.16 per M
    qwenflash      Qwen3.7 Flash          ~$0.03 / $0.13 per M
    geminiflash    Gemini 3.1 Flash Lite  ~$0.25 / $1.50 per M
    musespark      Meta Muse Spark 1.3    ~$1.25 / $4.25 per M

  CLOUD — free tier (OpenRouter, shared pool — can 429)
    orf [model]    Free model picker (fzf if installed). Auto-falls back to
                    another free model, then to qwenflash, if one 429s.
    orf-update     Refresh the free-model list from OpenRouter's live API
    llp-quick      Skip the picker — launch the most reliable free model now

  BROWSE / PICK MODELS (live pricing)
    or-models      Browse OpenRouter models (--free / --cheap / --use)
    vai-models     Browse Vercel Gateway models (--cheap / --use)
    hf             Search/download models from Hugging Face

  LOCAL (offline, your GPU, zero cost)
    lcp            Launch a local llama.cpp server + Claude Code against it
                    (--status / --list / --pull / --help for sub-options)

  OBSERVABILITY
    lane-status    Probe every lane (8 tokens each) -> ~/.cache/lcp/lane-status.json; feeds LLM Bar's menu
                    (zsh scripts/lane-status.zsh --print; launchd runs it daily at 07:30)
    llp-stats      Session dashboard — error rates, avg duration, per-provider
    llp-history    Recent sessions (llp-history 30 / llp-history all)
    llp-which      Suggest a provider for a task (reasoning / fast / creative)
    llp-reset      Clear the session log

  Keys live in the macOS login keychain (service = var name, e.g.
  security add-generic-password -U -a "$USER" -s KIMI_US_API_KEY -w).
  Endpoints/defaults in this file
  (~/.claude_config.zsh -> llama-cpp-setup/claude_config.zsh).
  Run any command with no args to see its own usage where it has one.
EOF
}
