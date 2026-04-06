# === CLAUDE CODE MULTI-PROVIDER SETUP ===
# Load API keys
[ -f ~/.env.claude ] && source ~/.env.claude

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
_LCP_PROVIDER_KEYS=(ZAI_API_KEY MINIMAX_API_KEY OPENROUTER_API_KEY ANTHROPIC_API_KEY)

# Internal: observability — session log location
_LCP_SESSION_LOG="${XDG_CACHE_HOME:-$HOME/.cache}/lcp/sessions.jsonl"

# Internal: record one session's metadata for observability/cost tracking
_lcp_log_session() {
  local provider="$1" model="$2" base_url="$3" exit_code="$4" duration="$5"
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  # Append one JSONL line — safe to run concurrently (O_APPEND writes are atomic < PIPE_BUF)
  printf '{"ts":"%s","provider":"%s","model":"%s","base_url":"%s","exit":%s,"duration_s":%s}\n' \
    "$ts" "$provider" "$model" "$base_url" "$exit_code" "$duration" >> "$_LCP_SESSION_LOG" 2>/dev/null
}

# Internal: pre-launch health check for a provider
# Prints warnings if the endpoint is unreachable or the model seems unavailable
_lcp_health_check() {
  local base_url="$1" model="$2" provider="$3"

  # Skip health check for localhost (local already does its own health polling)
  if [[ "$base_url" == http://localhost* || "$base_url" == http://127.0.0.1* ]]; then
    return 0
  fi

  # Quick ping to the base URL
  if ! curl -sf -m 5 "$base_url/v1/models" &>/dev/null; then
    echo "⚠ $provider endpoint unreachable: $base_url"
    echo "  Check your API key and network connectivity."
    # For OpenRouter, check specific model availability via the models list
    if [[ "$base_url" == *"openrouter"* ]]; then
      local check
      check=$(python3 "${_LCP_LIB_DIR:-${_LCP_DIR:-.}/lib}/provider_health.py" \
        --model "$model" --models-url "https://openrouter.ai/api/v1/models" 2>/dev/null)
      [[ -n "$check" ]] && echo "$check"
    fi
    return 1
  fi
  return 0
}

# Internal: unified launcher for any Claude Code provider
# Usage: _launch_claude <base_url> <auth_token> <opus_model> <sonnet_model> <haiku_model> [--arg ...]
# Passing the same model for all three roles is equivalent to single-model mode.
_launch_claude() {
  local base_url="$1" auth_token="$2"
  local opus_model="$3" sonnet_model="$4" haiku_model="$5"
  shift 5

  # Ensure run directory exists
  mkdir -p "$(dirname "$_LCP_SESSION_LOG")"

  # Derive provider name from base_url for logging/display
  local provider="unknown"
  case "$base_url" in
    *z.ai*)          provider="zai" ;;
    *minimax*)       provider="minimax" ;;
    *openrouter*)    provider="openrouter" ;;
    *localhost*)     provider="lcp-local" ;;
    *127.0.0.1*)     provider="lcp-local" ;;
  esac

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
    "https://api.z.ai/api/anthropic" \
    "$ZAI_API_KEY" \
    "glm-5" \
    "glm-5" \
    "glm-4.5-air" \
    "$@"
}

# MiniMax - Experimental
minimax() {
  _launch_claude \
    "https://api.minimax.io/anthropic" \
    "$MINIMAX_API_KEY" \
    "MiniMax-M2.7" \
    "MiniMax-M2.7" \
    "MiniMax-M2.7" \
    "$@"
}

# OpenRouter - paid models (Claude, etc.)
openrouter() {
  _launch_claude \
    "https://openrouter.ai/api" \
    "$OPENROUTER_API_KEY" \
    "anthropic/claude-opus-4" \
    "anthropic/claude-sonnet-4" \
    "anthropic/claude-haiku-3.5" \
    "$@"
}

# === OpenRouter FREE models ===
# Dynamic picker: run `orf` to pick interactively, or `orf <model-id>` to use directly
# Examples:
#   orf                                    # interactive fzf picker
#   orf qwen/qwen3-coder:free             # use directly
#   orf qwen/qwen3-coder:free -p "hi"     # pass extra claude args

# Free model registry (updated 2026-04-03)
_OR_FREE_MODELS=(
  "arcee-ai/trinity-large-preview:free        | Arcee Trinity Large     | ctx:131k"
  "arcee-ai/trinity-mini:free                 | Arcee Trinity Mini      | ctx:131k"
  "cognitivecomputations/dolphin-mistral-24b-venice-edition:free | Venice Uncensored | ctx:32k"
  "google/gemma-3-12b-it:free                 | Gemma 3 12B             | ctx:32k"
  "google/gemma-3-27b-it:free                 | Gemma 3 27B             | ctx:131k"
  "google/gemma-3-4b-it:free                  | Gemma 3 4B              | ctx:32k"
  "google/gemma-3n-e2b-it:free                | Gemma 3n 2B             | ctx:8k"
  "google/gemma-3n-e4b-it:free                | Gemma 3n 4B             | ctx:8k"
  "liquid/lfm-2.5-1.2b-instruct:free          | LiquidAI 1.2B Instruct  | ctx:32k"
  "liquid/lfm-2.5-1.2b-thinking:free          | LiquidAI 1.2B Thinking  | ctx:32k"
  "meta-llama/llama-3.2-3b-instruct:free      | Llama 3.2 3B            | ctx:131k"
  "meta-llama/llama-3.3-70b-instruct:free     | Llama 3.3 70B           | ctx:65k"
  "minimax/minimax-m2.5:free                  | MiniMax M2.5            | ctx:196k"
  "nousresearch/hermes-3-llama-3.1-405b:free  | Hermes 3 405B           | ctx:131k"
  "nvidia/nemotron-3-nano-30b-a3b:free        | Nemotron 3 Nano 30B     | ctx:256k"
  "nvidia/nemotron-3-super-120b-a12b:free     | Nemotron 3 Super 120B   | ctx:262k"
  "nvidia/nemotron-nano-12b-v2-vl:free        | Nemotron Nano 12B VL    | ctx:128k"
  "nvidia/nemotron-nano-9b-v2:free            | Nemotron Nano 9B V2     | ctx:128k"
  "openai/gpt-oss-120b:free                   | GPT-OSS 120B            | ctx:131k"
  "openai/gpt-oss-20b:free                    | GPT-OSS 20B             | ctx:131k"
  "openrouter/free                            | Free Models Router      | ctx:200k"
  "qwen/qwen3-coder:free                      | Qwen3 Coder 480B        | ctx:262k"
  "qwen/qwen3-next-80b-a3b-instruct:free      | Qwen3 Next 80B          | ctx:262k"
  "qwen/qwen3.6-plus:free                     | Qwen3.6 Plus            | ctx:1M"
  "stepfun/step-3.5-flash:free                | Step 3.5 Flash          | ctx:256k"
  "z-ai/glm-4.5-air:free                      | GLM 4.5 Air             | ctx:131k"
)

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
  _launch_claude "https://openrouter.ai/api" "$OPENROUTER_API_KEY" "$model" "$model" "$model" "$@"
}

# Refresh free models list from OpenRouter API
orf-update() {
  echo "Fetching free models from OpenRouter..."
  curl -sf "https://openrouter.ai/api/v1/models" | python3 "${_LCP_LIB_DIR:-${_LCP_DIR:-.}/lib}/or_free_update.py"
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
      -*)     claude_args+=("$1"); shift ;;
      *)      search="$1"; shift ;;
    esac
  done

  local output
  output=$(curl -sf "https://openrouter.ai/api/v1/models" | python3 "${_LCP_LIB_DIR:-${_LCP_DIR:-.}/lib}/or_models.py" \
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
    _launch_claude "https://openrouter.ai/api" "$OPENROUTER_API_KEY" "$picked" "$picked" "$picked" "${claude_args[@]}"
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
  # Install cleanup trap — if the shell dies, crashes, or user disconnects,
  # the background llama-server gets stopped automatically instead of orphaning.
  # Cleared later if the user says "keep server running."
  _lcp_cleanup() { kill "$(cat "$_LCP_PIDFILE" 2>/dev/null)" 2>/dev/null; rm -f "$_LCP_PIDFILE" 2>/dev/null; }
  trap '_lcp_cleanup' EXIT INT TERM

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

  # Search Hugging Face Hub for GGUF models
  local query="$*"
  [[ -z "$query" ]] && query="llm.gguf"

  echo "Searching Hugging Face Hub for: $query..."

  local results
  results=$(python3 "$_LCP_LIB_DIR/hf_search.py" --query "$query" 2>&1) || { echo "HF search failed. Do you have huggingface-hub installed?"; echo "Install: pip install huggingface-hub"; return 1; }

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
  lcp "$picked_file" "${lcp_args[@]}"
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
  if [[ "$n" == "all" ]]; then
    cat "$_LCP_SESSION_LOG" | python3 -m json.tool --no-ensure-ascii 2>/dev/null
  else
    tail -n "$n" "$_LCP_SESSION_LOG" | python3 -m json.tool --no-ensure-ascii 2>/dev/null
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
