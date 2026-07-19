# === CLAUDE CODE MULTI-PROVIDER SETUP ===

# === API KEYS — macOS login keychain (single source of truth) ===
# Every provider key lives in the login keychain: service name = variable name,
# account = $USER. Nothing in plaintext on disk. Add or rotate a key:
#   security add-generic-password -U -a "$USER" -s KIMI_US_API_KEY -w   # prompts for value
#   security delete-generic-password -s KIMI_US_API_KEY                 # remove
# GUI: Keychain Access app -> login keychain -> search the var name.
# A var already exported in the environment wins — keychain only fills what's unset.
_LCP_KEYCHAIN_KEYS=(ZAI_API_KEY MINIMAX_API_KEY DEEPSEEK_API_KEY OPENROUTER_API_KEY \
  AI_GATEWAY_API_KEY KIMI_API_KEY KIMI_US_API_KEY GEMINI_API_KEY SILICONFLOW_API_KEY \
  BIGMODEL_API_KEY HUGGING_FACE_API_KEY OLLAMA_API_KEY QWEN_API_KEY)
_lcp_load_keys() {
  local var val
  for var in "${_LCP_KEYCHAIN_KEYS[@]}"; do
    [[ -n "${(P)var}" ]] && continue
    val=$(security find-generic-password -s "$var" -w 2>/dev/null) || continue
    [[ -n "$val" ]] && export "$var=$val"
  done
}
_lcp_load_keys
unset -f _lcp_load_keys

# === PROVIDER ENDPOINTS ===
# Defaults live here; the `:=` only sets a value if you haven't already, so an
# endpoint exported earlier in your shell env wins, e.g.
#   export KIMI_BASE_URL="https://api.moonshot.ai/anthropic"   # flip Kimi to the intl host
# No need to edit the launcher functions to retarget an endpoint.
: ${ZAI_BASE_URL:=https://api.z.ai/api/anthropic}
: ${KIMI_BASE_URL:=https://api.moonshot.cn/anthropic}
: ${KIMI_US_BASE_URL:=https://api.kimi.com/coding}
: ${MINIMAX_BASE_URL:=https://api.minimax.io/anthropic}
: ${DEEPSEEK_BASE_URL:=https://api.deepseek.com/anthropic}
: ${OPENROUTER_BASE_URL:=https://openrouter.ai/api}
: ${VAI_BASE_URL:=https://ai-gateway.vercel.sh}
: ${SILICONFLOW_BASE_URL:=https://api.siliconflow.cn/v1}
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
_LCP_PROVIDER_KEYS=(ZAI_API_KEY MINIMAX_API_KEY DEEPSEEK_API_KEY OPENROUTER_API_KEY AI_GATEWAY_API_KEY KIMI_API_KEY KIMI_US_API_KEY SILICONFLOW_API_KEY QWEN_API_KEY ANTHROPIC_API_KEY)

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
    zai|minimax|deepseek|vercel|openrouter-free|openrouter-paid|lcp-local|openrouter|siliconflow|kimi|kimi-us|qwen)
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
      *moonshot*)          provider="kimi" ;;
      *api.kimi.com*)      provider="kimi-us" ;;
      *aliyuncs.com*)      provider="qwen" ;;
      *openrouter*)        provider="openrouter-free" ;;
      *ai-gateway.vercel*) provider="vercel" ;;
      *localhost*)         provider="lcp-local" ;;
      *127.0.0.1*)         provider="lcp-local" ;;
    esac
  fi

  # Pre-launch health check (non-blocking — just warn)
  _lcp_health_check "$base_url" "$opus_model" "$provider" || true

  echo "→ $provider ($opus_model)"
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
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$sonnet_model"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$haiku_model"
    export ANTHROPIC_MODEL="$opus_model"
    export ANTHROPIC_SMALL_FAST_MODEL="$sonnet_model"
    export API_TIMEOUT_MS="3000000"
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    claude "$@"
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

# GLM (Z.AI) - Cost-effective option
zai() {
  _launch_claude \
    "$ZAI_BASE_URL" \
    "$ZAI_API_KEY" \
    "glm-5.2" \
    "glm-5.2" \
    "glm-5-turbo" \
    "$@"
}

# MiniMax - Experimental
minimax() {
  _launch_claude \
    "$MINIMAX_BASE_URL" \
    "$MINIMAX_API_KEY" \
    "MiniMax-M3" \
    "MiniMax-M3" \
    "MiniMax-M3" \
    "$@"
}

# DeepSeek - V4 era. opus/sonnet=pro (big), haiku=flash (fast).
# Note: deepseek-chat alias was retired; API now serves only v4-pro and v4-flash.
deepseek() {
  _launch_claude \
    "$DEEPSEEK_BASE_URL" \
    "$DEEPSEEK_API_KEY" \
    "deepseek-v4-pro" \
    "deepseek-v4-pro" \
    "deepseek-v4-flash" \
    "$@"
}

# Kimi (Moonshot AI) — K2.7 Code, Anthropic-native endpoint.
# CONFIRMED 2026-06-26: this key is a platform.moonshot.CN key — .cn returns 200,
# the .ai (international) host 401s on it. Must be the /anthropic path (NOT /v1, which
# is the OpenAI-compatible route Claude Code can't speak).
# NOTE: kimi-k2.7-code REQUIRES extended thinking. A request without it returns
# HTTP 400 "invalid thinking: only type=enabled is allowed for this model" — if you
# ever see that, turn thinking on in Claude Code; it's not an endpoint/key problem.
kimi() {
  _launch_claude \
    "$KIMI_BASE_URL" \
    "$KIMI_API_KEY" \
    "kimi-k3" \
    "kimi-k2.7-code" \
    "kimi-k2.7-code" \
    "$@"
}

# Kimi US (kimi.com) — Kimi Code subscription endpoint, Anthropic-compatible.
# Separate account/key from the moonshot.cn one above: get it from the Kimi Code
# Console at kimi.com, store as KIMI_US_API_KEY in the login keychain.
# Docs: https://www.kimi.com/code/docs/en/
# Models by plan tier: kimi-for-coding (standard, works on any plan),
# kimi-for-coding-highspeed (Allegretto+), k3 (Moderato+).
# Opus slot runs k3 (NOTE: the kimi.com id is "k3", not moonshot's "kimi-k3");
# sonnet/haiku stay on kimi-for-coding. If k3 400s, the plan doesn't cover it —
# drop the opus slot back to kimi-for-coding.
kimi-us() {
  if [[ -z "$KIMI_US_API_KEY" ]]; then
    echo "✗ KIMI_US_API_KEY not found — add it: security add-generic-password -U -a \"\$USER\" -s KIMI_US_API_KEY -w  (key from the Kimi Code Console at kimi.com)" >&2
    return 1
  fi
  _launch_claude \
    "$KIMI_US_BASE_URL" \
    "$KIMI_US_API_KEY" \
    "k3" \
    "kimi-for-coding" \
    "kimi-for-coding" \
    kimi-us \
    "$@"
}

# Qwen Coding Plan (Token Plan / Team Edition) — Alibaba's Anthropic-native endpoint.
# Get the key from the Qwen Cloud console (Token Plan -> API Keys), store as
# QWEN_API_KEY in the login keychain. Docs:
# https://docs.qwencloud.com/developer-guides/clients-and-developer-tools/claude-code
# Model IDs must match character-for-character (checked against the Token Plan
# supported-models table 2026-07-19): opus slot runs the qwen3.8-max-preview
# preview model; sonnet/haiku stay on GA models since preview capacity/limits
# can be rockier. If the preview 400s or gets pulled, drop opus to qwen3.7-max.
qwen() {
  if [[ -z "$QWEN_API_KEY" ]]; then
    echo "✗ QWEN_API_KEY not found — add it: security add-generic-password -U -a \"\$USER\" -s QWEN_API_KEY -w  (key from the Qwen Cloud console, Token Plan -> API Keys)" >&2
    return 1
  fi
  _launch_claude \
    "$QWEN_BASE_URL" \
    "$QWEN_API_KEY" \
    "qwen3.8-max-preview" \
    "qwen3.7-max" \
    "qwen3.6-flash" \
    qwen \
    "$@"
}

# OpenRouter - paid models (Claude, etc.)
openrouter() {
  _launch_claude \
    "$OPENROUTER_BASE_URL" \
    "$OPENROUTER_API_KEY" \
    "anthropic/claude-opus-4.8" \
    "anthropic/claude-sonnet-4.6" \
    "anthropic/claude-haiku-4.5" \
    "$@"
}

# Fable 5 — Anthropic's creative powerhouse via OpenRouter. 1M ctx. Premium ($10/$50 per M).
# Opus+Sonnet roles run Fable; haiku lane drops to claude-haiku-4.5 so background
# calls (titles, summaries) don't bill at $50/M output.
fable() {
  _launch_claude \
    "$OPENROUTER_BASE_URL" \
    "$OPENROUTER_API_KEY" \
    "anthropic/claude-fable-5" \
    "anthropic/claude-fable-5" \
    "anthropic/claude-haiku-4.5" \
    "$@"
}

# Vercel AI Gateway - Anthropic-native gateway to 280+ models across providers.
# Slugs are creator/model (anthropic/claude-opus-4.8, openai/gpt-5, google/gemini-...).
# Browse live models + pricing with `vai-models`. Key: AI_GATEWAY_API_KEY in the login keychain.
vai() {
  _launch_claude \
    "$VAI_BASE_URL" \
    "$AI_GATEWAY_API_KEY" \
    "anthropic/claude-opus-4.8" \
    "anthropic/claude-sonnet-4.6" \
    "anthropic/claude-haiku-4.5" \
    "$@"
}

# === SiliconFlow — OpenAI-only, bridged to Claude Code via a local LiteLLM proxy ===
# ⚠ WIP / NOT WORKING YET: litellm's /v1/messages bridge calls SiliconFlow's /v1/responses
#   (OpenAI Responses API), which SiliconFlow doesn't serve -> 404. Needs the bridge forced
#   to /chat/completions (likely via claude-code-router instead of litellm). Don't rely on
#   this until fixed. Scaffolding + endpoint var are kept so it's a quick finish later.
# SiliconFlow speaks ONLY the OpenAI API (no /anthropic endpoint), so Claude Code can't
# hit it directly. This boots a local LiteLLM proxy that translates Anthropic /v1/messages
# -> SiliconFlow's OpenAI /chat/completions, points Claude Code at localhost, and tears the
# proxy down on exit. Same local-server lifecycle as lcp.
#
# Usage:
#   siliconflow                                      # default model (_SF_DEFAULT_MODEL)
#   siliconflow deepseek-ai/DeepSeek-V3              # any SiliconFlow slug
#   siliconflow Qwen/Qwen3-Coder-... -p "hi"         # extra args pass through to claude
# Exact slugs (the model arg must match SiliconFlow exactly):
#   curl -s https://api.siliconflow.cn/v1/models -H "Authorization: Bearer $SILICONFLOW_API_KEY"
# Deps: uv tool install 'litellm[proxy]' --python 3.12  (3.14 fails — PyO3 cap)
_SF_PORT=8777
_SF_DEFAULT_MODEL="deepseek-ai/DeepSeek-V3"   # change here, or pass a slug as the first arg
_SF_RUNDIR="${XDG_CACHE_HOME:-$HOME/.cache}/lcp"
_SF_PIDFILE="$_SF_RUNDIR/siliconflow-litellm.pid"
_SF_CONFIG="$_SF_RUNDIR/siliconflow-litellm.yaml"
_SF_LOG="$_SF_RUNDIR/siliconflow-litellm.log"

siliconflow() {
  if [[ -z "$SILICONFLOW_API_KEY" ]]; then
    echo "✗ SILICONFLOW_API_KEY not found — add it: security add-generic-password -U -a \"\$USER\" -s SILICONFLOW_API_KEY -w" >&2
    return 1
  fi
  if ! command -v litellm &>/dev/null; then
    echo "✗ litellm not found. Install: uv tool install 'litellm[proxy]' --python 3.12" >&2
    return 1
  fi

  # First non-flag arg is the model slug; everything after passes through to claude.
  local model="$_SF_DEFAULT_MODEL"
  if [[ -n "${1:-}" && "$1" != -* ]]; then
    model="$1"; shift
  fi

  mkdir -p "$_SF_RUNDIR"

  # Wildcard route: Claude Code asks for "<slug>", LiteLLM forwards to openai/<slug> at
  # SiliconFlow — so any slug works with no per-model config. drop_params tolerates
  # Anthropic-only params the OpenAI backend doesn't accept.
  cat > "$_SF_CONFIG" <<YAML
model_list:
  - model_name: "*"
    litellm_params:
      model: "openai/*"
      api_base: "$SILICONFLOW_BASE_URL"
      api_key: "os.environ/SILICONFLOW_API_KEY"
litellm_settings:
  drop_params: true
YAML

  # Stop any stale proxy we left running
  if [[ -f "$_SF_PIDFILE" ]] && kill -0 "$(cat "$_SF_PIDFILE")" 2>/dev/null; then
    kill "$(cat "$_SF_PIDFILE")" 2>/dev/null; sleep 1
  fi

  echo "→ starting LiteLLM proxy (SiliconFlow) on :$_SF_PORT — model: $model"
  litellm --config "$_SF_CONFIG" --host 127.0.0.1 --port "$_SF_PORT" &>"$_SF_LOG" &
  echo $! > "$_SF_PIDFILE"

  # Tear the proxy down when this function returns or is interrupted
  _sf_cleanup() { kill "$(cat "$_SF_PIDFILE" 2>/dev/null)" 2>/dev/null; rm -f "$_SF_PIDFILE" 2>/dev/null; }
  trap '_sf_cleanup' EXIT INT TERM

  echo -n "  waiting for proxy"
  local n=0
  while ! curl -sf "http://127.0.0.1:$_SF_PORT/health/liveliness" &>/dev/null; do
    echo -n "."; sleep 1; n=$((n+1))
    [[ $n -gt 60 ]] && { echo " TIMEOUT — check $_SF_LOG"; return 1; }
  done
  echo " ready!"; echo ""

  # Claude Code talks Anthropic to the local proxy. Auth token is a dummy — the proxy is
  # open on localhost (no master key). Model name handed to claude = the SiliconFlow slug.
  _launch_claude "http://127.0.0.1:$_SF_PORT" "sf-local" "$model" "$model" "$model" siliconflow "$@"
}

# OpenRouter cheap-but-good launchers (paid, but pennies — won't queue like free tier).
# Verify live pricing anytime with `or-models --cheap`.

# GLM 4.7 Flash — ~$0.06/$0.40 per M, 203k ctx. Daily-driver value pick.
glmflash() {
  _launch_claude \
    "$OPENROUTER_BASE_URL" \
    "$OPENROUTER_API_KEY" \
    "z-ai/glm-4.7-flash" \
    "z-ai/glm-4.7-flash" \
    "z-ai/glm-4.7-flash" \
    "$@"
}

# Qwen3.5 Flash — ~$0.065/$0.26 per M, 1M ctx. Cheapest output, huge context.
qwenflash() {
  _launch_claude \
    "$OPENROUTER_BASE_URL" \
    "$OPENROUTER_API_KEY" \
    "qwen/qwen3.5-flash-02-23" \
    "qwen/qwen3.5-flash-02-23" \
    "qwen/qwen3.5-flash-02-23" \
    "$@"
}

# Gemini 3.1 Flash Lite — ~$0.25/$1.50 per M, 1M ctx. Budget-frontier when you need more brain.
# (preview graduated to GA; same pricing. Newer non-lite google/gemini-3.5-flash exists at ~6x cost.)
geminiflash() {
  _launch_claude \
    "$OPENROUTER_BASE_URL" \
    "$OPENROUTER_API_KEY" \
    "google/gemini-3.1-flash-lite" \
    "google/gemini-3.1-flash-lite" \
    "google/gemini-3.1-flash-lite" \
    "$@"
}

# === OpenRouter FREE models ===
# Dynamic picker: run `orf` to pick interactively, or `orf <model-id>` to use directly
# Examples:
#   orf                                    # interactive fzf picker
#   orf qwen/qwen3-coder:free             # use directly
#   orf qwen/qwen3-coder:free -p "hi"     # pass extra claude args

# Free model registry (updated 2026-07-08)
_OR_FREE_MODELS=(
  "cognitivecomputations/dolphin-mistral-24b-venice-edition:free | Venice: Uncensored (free) | ctx:32k"
  "cohere/north-mini-code:free                        | Cohere: North Mini Code (free) | ctx:256k"
  "google/gemma-4-26b-a4b-it:free                     | Google: Gemma 4 26B A4B  (free) | ctx:262k"
  "google/gemma-4-31b-it:free                         | Google: Gemma 4 31B (free) | ctx:262k"
  "google/lyria-3-clip-preview                        | Google: Lyria 3 Clip Preview | ctx:1M"
  "google/lyria-3-pro-preview                         | Google: Lyria 3 Pro Preview | ctx:1M"
  "liquid/lfm-2.5-1.2b-instruct:free                  | LiquidAI: LFM2.5-1.2B-Instruct (free) | ctx:32k"
  "liquid/lfm-2.5-1.2b-thinking:free                  | LiquidAI: LFM2.5-1.2B-Thinking (free) | ctx:32k"
  "meta-llama/llama-3.2-3b-instruct:free              | Meta: Llama 3.2 3B Instruct (free) | ctx:131k"
  "meta-llama/llama-3.3-70b-instruct:free             | Meta: Llama 3.3 70B Instruct (free) | ctx:131k"
  "nousresearch/hermes-3-llama-3.1-405b:free          | Nous: Hermes 3 405B Instruct (free) | ctx:131k"
  "nvidia/nemotron-3-nano-30b-a3b:free                | NVIDIA: Nemotron 3 Nano 30B A3B (free) | ctx:256k"
  "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free | NVIDIA: Nemotron 3 Nano Omni (free) | ctx:256k"
  "nvidia/nemotron-3-super-120b-a12b:free             | NVIDIA: Nemotron 3 Super (free) | ctx:1M"
  "nvidia/nemotron-3-ultra-550b-a55b:free             | NVIDIA: Nemotron 3 Ultra (free) | ctx:1M"
  "nvidia/nemotron-3.5-content-safety:free            | NVIDIA: Nemotron 3.5 Content Safety (free) | ctx:128k"
  "nvidia/nemotron-nano-12b-v2-vl:free                | NVIDIA: Nemotron Nano 12B 2 VL (free) | ctx:128k"
  "nvidia/nemotron-nano-9b-v2:free                    | NVIDIA: Nemotron Nano 9B V2 (free) | ctx:128k"
  "openai/gpt-oss-120b:free                           | OpenAI: gpt-oss-120b (free) | ctx:131k"
  "openai/gpt-oss-20b:free                            | OpenAI: gpt-oss-20b (free) | ctx:131k"
  "openrouter/free                                    | Free Models Router        | ctx:200k"
  "poolside/laguna-m.1:free                           | Poolside: Laguna M.1 (free) | ctx:262k"
  "poolside/laguna-xs-2.1:free                        | Poolside: Laguna XS 2.1 (free) | ctx:262k"
  "poolside/laguna-xs.2:free                          | Poolside: Laguna XS.2 (free) | ctx:262k"
  "qwen/qwen3-coder:free                              | Qwen: Qwen3 Coder 480B A35B (free) | ctx:1M"
  "qwen/qwen3-next-80b-a3b-instruct:free              | Qwen: Qwen3 Next 80B A3B Instruct (free) | ctx:262k"
  "tencent/hy3:free                                   | Tencent: Hy3 (free)       | ctx:262k"
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
      echo "  free pool looks fully congested — falling back to glmflash (paid, ~\$0.06/M in, pennies per session)."
      glmflash "$@"
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

_LCP_MODELS_DIR="$_LCP_DIR/models"
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
# Picks the most reliable free OpenRouter model and launches immediately
# with no prompts. For when you just want to code now.
llp-quick() {
  echo "→ Launching best free model (qwen/qwen3-coder:free)..."
  orf qwen/qwen3-coder:free "$@"
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
    minimax        MiniMax — experimental
    deepseek       DeepSeek V4 (opus/sonnet=pro, haiku=flash)
    kimi           Kimi K2.7 Code via moonshot.cn (needs extended thinking on)
    kimi-us        Kimi Code via kimi.com US endpoint (opus=k3, rest=kimi-for-coding)
    qwen           Qwen Coding Plan (opus=3.8-max-preview, rest=3.7-max/3.6-flash)
    openrouter     Claude Opus/Sonnet/Haiku via OpenRouter
    fable          Claude Fable 5 — premium, 1M ctx, creative work
    vai            Vercel AI Gateway — 280+ models, any creator/model slug
    siliconflow    OpenAI-only, bridged via local LiteLLM proxy (WIP)

  CLOUD — cheap-but-good (OpenRouter, pennies per session)
    glmflash       GLM 4.7 Flash          ~$0.06 / $0.40 per M
    qwenflash      Qwen3.5 Flash          ~$0.065 / $0.26 per M
    geminiflash    Gemini 3.1 Flash Lite  ~$0.25 / $1.50 per M

  CLOUD — free tier (OpenRouter, shared pool — can 429)
    orf [model]    Free model picker (fzf if installed). Auto-falls back to
                    another free model, then to glmflash, if one 429s.
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
