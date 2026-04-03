# === CLAUDE CODE MULTI-PROVIDER SETUP ===
# Load API keys
[ -f ~/.env.claude ] && source ~/.env.claude

# GLM (Z.AI) - Cost-effective option
zai() {
  (
    export ANTHROPIC_BASE_URL="https://api.z.ai/api/anthropic"
    #export ANTHROPIC_BASE_URL="https://api.z.ai/api/coding/paas/v4"
    export ANTHROPIC_AUTH_TOKEN="$ZAI_API_KEY"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="glm-5"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="glm-5"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="glm-4.5-air"
    export API_TIMEOUT_MS="3000000"
    export CLAUDE_CODE_ATTRIBUTION_HEADER="0"
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    claude "$@"
  )
}

# MiniMax - Experimental
minimax() {
  (
    export ANTHROPIC_BASE_URL="https://api.minimax.io/anthropic"
    export ANTHROPIC_AUTH_TOKEN="$MINIMAX_API_KEY"
    export ANTHROPIC_MODEL="MiniMax-M2.7"
    export ANTHROPIC_SMALL_FAST_MODEL="MiniMax-M2.7"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="MiniMax-M2.7"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="MiniMax-M2.7"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="MiniMax-M2.7"
    export API_TIMEOUT_MS="3000000"
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    claude "$@"
  )
}

# OpenRouter - paid models (Claude, etc.)
openrouter() {
  (
    export ANTHROPIC_BASE_URL="https://openrouter.ai/api"
    export ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"
    export ANTHROPIC_API_KEY=""
    export ANTHROPIC_DEFAULT_OPUS_MODEL="anthropic/claude-opus-4"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="anthropic/claude-sonnet-4"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="anthropic/claude-haiku-3.5"
    export API_TIMEOUT_MS="3000000"
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    claude "$@"
  )
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
        ((i++))
      done
      echo ""
      echo -n "Pick a number (or install fzf for fuzzy search): "
      read -r choice
      [[ -z "$choice" ]] && return 1
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
  (
    export ANTHROPIC_BASE_URL="https://openrouter.ai/api"
    export ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"
    export ANTHROPIC_API_KEY=""
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$model"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$model"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$model"
    export API_TIMEOUT_MS="3000000"
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    claude "$@"
  )
}

# Refresh free models list from OpenRouter API
orf-update() {
  echo "Fetching free models from OpenRouter..."
  curl -s "https://openrouter.ai/api/v1/models" | python3 -c "
import json, sys
data = json.load(sys.stdin)
free = []
for m in data.get('data', []):
    p = m.get('pricing', {})
    if str(p.get('prompt','1')) == '0' and str(p.get('completion','1')) == '0':
        mid = m['id']
        name = m.get('name','')
        ctx = m.get('context_length', 0)
        if ctx >= 1000000: ctxs = f'{ctx//1000000}M'
        elif ctx >= 1000: ctxs = f'{ctx//1000}k'
        else: ctxs = str(ctx)
        free.append((mid, name, ctxs))
for mid, name, ctxs in sorted(free):
    print(f'  \"{mid:<50s} | {name:<25s} | ctx:{ctxs}\"')
print(f'\nTotal: {len(free)} free models')
print('Copy the output above to update _OR_FREE_MODELS in ~/.claude_config.zsh')
"
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

_LCP_DIR="$HOME/Sriinnu/Personal/llama-cpp-setup"  # Change this to wherever you cloned the repo
_LCP_MODELS_DIR="$_LCP_DIR/models"
_LCP_SERVER="$HOME/.local/bin/llama-server"
_LCP_PORT=8776
_LCP_PIDFILE="/tmp/llama-server.pid"

# Default server settings (tuned for M3 Pro 36GB + 22GB model)
_LCP_CTX_SIZE=32768        # 32k context — safe for 22GB model on 36GB RAM (use --ctx to override)
_LCP_GPU_LAYERS=99         # offload all layers to Metal GPU
_LCP_THREADS=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || echo 6)  # perf cores only (6 on M3 Pro)
_LCP_BATCH_SIZE=4096       # larger batch = faster prompt ingestion
_LCP_UBATCH_SIZE=1024      # bigger micro-batch for Metal (M3 handles this well)
_LCP_FLASH_ATTN=1          # flash attention (faster, less memory)

lcp() {
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
        ((count++))
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
      python3 -c "
from huggingface_hub import hf_hub_download
path = hf_hub_download(repo_id='$2', filename='$3', local_dir='$_LCP_MODELS_DIR', local_dir_use_symlinks=False)
print(f'Downloaded to: {path}')
"
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

  # Parse optional flags
  local ctx_override=""
  local model_hint=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ctx) ctx_override="$2"; shift 2 ;;
      -*) break ;;  # remaining flags go to claude
      *) model_hint="$1"; shift; break ;;
    esac
  done

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
        ((i++))
      done
      echo -n "Pick a number: "
      read -r choice
      [[ -z "$choice" ]] && return 1
      model_file="${gguf_files[$choice]}"
    fi
  fi

  local ctx="${ctx_override:-$_LCP_CTX_SIZE}"
  echo "Model:   $(basename "$model_file")"
  echo "Context: $ctx tokens"
  echo "GPU:     $_LCP_GPU_LAYERS layers | Flash attention: $([ $_LCP_FLASH_ATTN -eq 1 ] && echo ON || echo OFF)"
  echo ""

  # Stop existing server if running
  if [[ -f "$_LCP_PIDFILE" ]] && kill -0 "$(cat "$_LCP_PIDFILE")" 2>/dev/null; then
    echo "Stopping existing llama-server (PID: $(cat "$_LCP_PIDFILE"))..."
    kill "$(cat "$_LCP_PIDFILE")"
    sleep 1
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
    &>/tmp/llama-server.log &
  echo $! > "$_LCP_PIDFILE"

  # Wait for server to be ready
  echo -n "Waiting for server"
  local attempts=0
  while ! curl -sf "http://localhost:$_LCP_PORT/health" &>/dev/null; do
    echo -n "."
    sleep 1
    ((attempts++))
    if [[ $attempts -gt 120 ]]; then
      echo " TIMEOUT (check /tmp/llama-server.log)"
      return 1
    fi
  done
  echo " ready!"
  echo ""

  # Launch Claude Code connected to local server
  (
    export ANTHROPIC_BASE_URL="http://localhost:$_LCP_PORT"
    export ANTHROPIC_AUTH_TOKEN="local"
    export ANTHROPIC_API_KEY=""
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$(basename "$model_file" .gguf)"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$(basename "$model_file" .gguf)"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$(basename "$model_file" .gguf)"
    export API_TIMEOUT_MS="3000000"
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    claude "$@"
  )

  # Ask if user wants to keep server running
  echo ""
  echo -n "Keep llama-server running? [y/N]: "
  read -r keep
  if [[ "$keep" != [yY]* ]]; then
    lcp --stop
  fi
}
