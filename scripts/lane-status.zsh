#!/bin/zsh
# lane-status.zsh — probe every Claude Code provider lane with one 8-token request and write a
# machine-readable status cache for LLM Bar (menu-bar app) and for humans (`--print`).
#
#   zsh scripts/lane-status.zsh            # write ~/.cache/lcp/lane-status.json, notify on change
#   zsh scripts/lane-status.zsh --print    # also print a table
#   zsh scripts/lane-status.zsh --quiet    # no notification even if something changed
#
# Never prints a key. Keys come from the login keychain (service = var name), same as
# claude_config.zsh. One probe per endpoint+key; lanes that share both share the result.
# Status vocabulary (what the dot in the menu bar means):
#   ok        200 — launch away
#   auth      401/403 — key dead or wrong host
#   balance   402, or 429/400 whose body mentions balance/quota/insufficient
#   ratelimit 429 without a balance message
#   down      5xx, timeout, DNS
#   nokey     no keychain entry for the lane's key
set -u
zmodload zsh/datetime   # $EPOCHREALTIME — macOS date has no %N
OUT="${LCP_LANE_STATUS:-$HOME/.cache/lcp/lane-status.json}"
PRINT=0; QUIET=0
for a in "$@"; do case "$a" in --print) PRINT=1;; --quiet) QUIET=1;; esac; done
mkdir -p "${OUT:h}"

typeset -A KEY
for var in ZAI_API_KEY MINIMAX_API_KEY DEEPSEEK_API_KEY OPENROUTER_API_KEY AI_GATEWAY_API_KEY \
           KIMI_API_KEY KIMI_US_API_KEY QWEN_API_KEY SILICONFLOW_API_KEY GEMINI_API_KEY; do
  KEY[$var]=$(security find-generic-password -s "$var" -w 2>/dev/null || true)
done

# probe <id> <base> <keyvar> <model>   -> writes one JSON line to $TMP/<id>.json
TMP=$(mktemp -d -t lane-status)
probe() {
  local id=$1 base=$2 keyvar=$3 model=$4 key=${KEY[$3]:-}
  local ms code body
  if [[ -z "$key" ]]; then
    print -r -- "{\"id\":\"$id\",\"status\":\"nokey\",\"http\":0,\"ms\":0,\"model\":\"$model\",\"detail\":\"no $keyvar in keychain\"}" > "$TMP/$id.json"; return
  fi
  local t0=$EPOCHREALTIME
  body=$(curl -s -m 25 -w $'\n%{http_code}' "$base/v1/messages" \
    -H @<(print -r -- "x-api-key: $key") -H @<(print -r -- "Authorization: Bearer $key") \
    -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
    -d "{\"model\":\"$model\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}]}")
  ms=$(printf "%.0f" $(( (EPOCHREALTIME - t0) * 1000 ))); code=${body##*$'\n'}; body=${body%$'\n'*}
  LS_BODY="$body" python3 -I -c '
import sys,json,re,os
id_,code,ms,model=sys.argv[1],int(sys.argv[2] or 0),int(sys.argv[3]),sys.argv[4]
raw=os.environ.get("LS_BODY","")
try: d=json.loads(raw)
except Exception: d={}
msg=""
if isinstance(d,dict):
    e=d.get("error")
    if isinstance(e,dict): msg=str(e.get("message") or e.get("msg") or "")
    elif isinstance(e,str): msg=e
    msg=msg or str(d.get("message") or d.get("base_resp",{}).get("status_msg","") if isinstance(d.get("base_resp"),dict) else d.get("message") or "")
if not msg and code!=200: msg=raw[:160]
low=msg.lower()
if code==200: status="ok"
elif code in (401,403): status="auth"
elif code==402 or (code in (429,400) and re.search(r"balance|quota|insufficient|recharge|unpurchased|credit|suspended",low)): status="balance"
elif code==429: status="ratelimit"
elif code==0 or code>=500: status="down"
else: status="error"
print(json.dumps({"id":id_,"status":status,"http":code,"ms":ms,"model":model,"detail":re.sub(r"\b(sk|ak|ek|key)-[A-Za-z0-9_-]{4,}[^ ]*","[key]",msg)[:160]}))
' "$id" "$code" "$ms" "$model" > "$TMP/$id.json"
}
# Gemini speaks no Anthropic API; the free-tier lane goes through LiteLLM. Probe the key directly.
probe_gemini() {
  local key=${KEY[GEMINI_API_KEY]:-}
  if [[ -z "$key" ]]; then print -r -- '{"id":"geminifree","status":"nokey","http":0,"ms":0,"model":"gemini-3.5-flash-lite","detail":"no GEMINI_API_KEY in keychain"}' > "$TMP/geminifree.json"; return; fi
  local code; code=$(curl -s -m 15 -o /dev/null -w '%{http_code}' -H @<(print -r -- "x-goog-api-key: $key") "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1")
  local st=down; [[ $code == 200 ]] && st=ok; [[ $code == 401 || $code == 403 || $code == 400 ]] && st=auth; [[ $code == 429 ]] && st=ratelimit
  print -r -- "{\"id\":\"geminifree\",\"status\":\"$st\",\"http\":$code,\"ms\":0,\"model\":\"gemini-3.5-flash-lite\",\"detail\":\"models list\"}" > "$TMP/geminifree.json"
}

# One probe per distinct (endpoint,key); lanes listed in SHARES inherit it.
probe zai         https://api.z.ai/api/anthropic                                   ZAI_API_KEY         glm-5.3-flash &
probe minimax     https://api.minimax.io/anthropic                                 MINIMAX_API_KEY     MiniMax-M3.1-Flash &
probe deepseek    https://api.deepseek.com/anthropic                               DEEPSEEK_API_KEY    deepseek-flash &
probe kimi-china  https://api.moonshot.cn/anthropic                                KIMI_API_KEY        kimi-k2.7-code-highspeed &
probe kimi-us     https://api.kimi.ai/coding                                       KIMI_US_API_KEY     k3-256k &
probe qwen-cc     https://token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic QWEN_API_KEY      qwen3.8-flash &
probe openrouter  https://openrouter.ai/api                                        OPENROUTER_API_KEY  anthropic/claude-haiku-5.5 &
probe vai         https://ai-gateway.vercel.sh                                     AI_GATEWAY_API_KEY  anthropic/claude-haiku-5.5 &
probe siliconflow https://api.siliconflow.com                                      SILICONFLOW_API_KEY deepseek-ai/DeepSeek-V4.1-Flash &
probe_gemini &
wait

typeset -A SHARES=(
  minimaxflash minimax   deepseekflash deepseek   kimi-cn kimi-china
  qwen-ds qwen-cc   qwen-glm qwen-cc   qwen-plus qwen-cc
  fable openrouter  glmflash openrouter  qwenflash openrouter  geminiflash openrouter  musespark openrouter
  orf openrouter    llp-quick openrouter
)
python3 -I - "$TMP" "$OUT" "$PRINT" "$QUIET" "${(kv)SHARES[@]}" <<'PY'
import sys,json,glob,os,datetime,subprocess
tmp,out,do_print,quiet=sys.argv[1],sys.argv[2],sys.argv[3]=="1",sys.argv[4]=="1"
kv=sys.argv[5:]; shares=dict(zip(kv[0::2],kv[1::2]))
lanes={}
for f in glob.glob(os.path.join(tmp,"*.json")):
    try: d=json.load(open(f)); lanes[d["id"]]=d
    except Exception: pass
for lane,src in shares.items():
    if src in lanes: lanes[lane]={**lanes[src],"id":lane,"shared_with":src}
prev={}
try: prev=json.load(open(out)).get("lanes",{})
except Exception: pass
now=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
doc={"probed_at":now,"lanes":dict(sorted(lanes.items()))}
json.dump(doc,open(out,"w"),indent=1)
changed=[l for l in lanes if prev.get(l,{}).get("status")!=lanes[l]["status"] and (prev or False)]
if do_print:
    for l,d in doc["lanes"].items():
        print(f'  {d["status"]:9s} {l:14s} HTTP {d["http"]:<3d} {d["ms"]:>5d}ms  {d["model"]:38s} {d.get("detail","")[:60]}')
    print(f"\n{len(lanes)} lanes -> {out}" + (f"  changed: {', '.join(changed)}" if changed else ""))
if changed and not quiet:
    txt="; ".join(f'{l}: {prev.get(l,{}).get("status","?")} → {lanes[l]["status"]}' for l in changed)[:200]
    subprocess.run(["osascript","-e",f'display notification "{txt}" with title "LLM Bar: lane status changed"'],check=False)
PY
rm -rf "$TMP"
