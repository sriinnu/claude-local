# Alibaba Qwen Token Plan — how it's wired

Bought 2026-09-30: **Standard Plan, 1 year** (ends 2027-09-30), Model Studio, Singapore region.
Everything below lives in `claude_config.zsh` (symlinked as `~/.claude_config.zsh`) and `lib/qwen_media.py`.

## Commands

| Command | What it is |
|---|---|
| `qwen` | The **official Qwen Code** CLI (`/opt/homebrew/bin/qwen`, Bailian installer). Not our function. |
| `qwen-cc` | The plan **inside Claude Code**. opus=`qwen3.8-max`, sonnet=`qwen3.7-max`, haiku=`qwen3.8-flash` |
| `qwen-ds` | Claude Code on the plan: DeepSeek V4 Pro (opus/sonnet), V4.1 Flash (haiku) |
| `qwen-glm` | Claude Code on the plan: GLM 5.3 (opus/sonnet), GLM 5.2 (haiku) |
| `qwen-plus` | Claude Code on the plan: Qwen 3.7 Plus (opus/sonnet), 3.8 Flash (haiku) |
| `qwen-image "prompt"` | Image gen. Default `qwen-image-3.0-pro`; also `wan2.7-image`, `wan2.7-image-pro`. `--model`, `--size 1024x1024` |
| `qwen-video "prompt"` | Text-to-video. Default `happyhorse-1.1-t2v`. `--resolution 720P --ratio 16:9 --duration 5` |

`qwen-image` / `qwen-video` save to `~/qwen-media` (override: `QWEN_MEDIA_DIR`). `lcp-help` lists all launchers.

## /model picker

Inside `qwen-cc` (and the `qwen-*` launchers), `/model` lists the built-in Opus/Sonnet/Haiku **plus** 9 plan models
(Qwen 3.8 Max / 3.7 Max / 3.7 Plus / 3.8 Flash / 3.6 Flash, DeepSeek V4 Pro / V4.1 Flash, GLM 5.3 / 5.2).
Injected per launch with `claude --settings '<json>'` from `_QWEN_PICKER_JSON` — global `~/.claude/settings.json`
is untouched and other providers don't get it.

Schema (read from the claude 2.1.285 binary — a research agent got it wrong): `modelPicker.options` =
`[{model, label?, description?, behavesAs?}]`, plus `replaceBuiltInOptions`. Not `rows`/`name`.

## Endpoints and key

- Key: keychain service `QWEN_API_KEY` (a `sk-sp-…` plan key). Loaded by `claude_config.zsh`. Rotate:
  `security add-generic-password -U -a "$USER" -s QWEN_API_KEY -w`
- **Chat (Anthropic-compatible):** `https://token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic`
- **Chat (OpenAI-compatible):** `https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1`
- **Image / video:** same `token-plan` host, different paths (`/api/v1/services/aigc/image-generation/generation`,
  `/api/v1/services/aigc/video-generation/video-synthesis`). **Both are async-only** on the plan
  (`X-DashScope-Async: enable`, then poll `/api/v1/tasks/{id}` ~every 15s). Image ~1 min, video ~1.5 min.
- Plan keys only pair with the `token-plan` host. Don't use the `{WorkspaceId}…maas.aliyuncs.com` pay-as-you-go
  host from the docs.

## What each model type can do

Only **text models** work in the Claude harness. Image / video / audio / TTS models (Wan, HappyHorse, qwen-image,
qwen-audio) are generation APIs — reached via `qwen-image` / `qwen-video`, never the picker.
Plan also includes `auto` (looks like a router — untried) and Alibaba's built-in tools (web search, code interpreter,
web fetch, image search).

## Known gaps / gotchas

- **Context windows unknown.** Claude Code prints "isn't described by this version's model catalog" and assumes
  200k, so auto-compact fires early. Fix once a real window is known: `CLAUDE_CODE_MAX_CONTEXT_TOKENS` or `behavesAs`
  on a picker row. Not published on the plan page.
- Harmless warnings: "claude.ai connectors disabled" (launcher sets its own auth, by design), and the
  auto-mode classifier-billing notice (Alibaba's gateway, nothing to do).
- Image-to-video (`-i2v`) and reference-to-video (`-r2v`) are **not wired** — request bodies unverified.
- `qwen-ds` / `qwen-glm` / `qwen-plus` model IDs come from the plan's supported list but weren't each smoke-tested
  through the Anthropic endpoint. If one errors, that model isn't served there — swap the ID.
- Night discounts exist on some models (40% Qwen 3.8, 50% DeepSeek "nights") — worth knowing for long sessions.
- Plan page shows a usage %; monthly quota resets on the 1st (UTC+8). Console:
  https://modelstudio.console.alibabacloud.com/ap-southeast-1/subscription/token-plan/personal

## Not done yet

- **Takumi**: it talks to models via the Chitragupta daemon (`~/.config/takumi/model` = `chitragupta`), so the plan
  has to be registered as a provider in Chitragupta, not Takumi.
- Whether the official `qwen` CLI uses the plan key or a separate Bailian login (state in `~/.qwen`) — check by
  running it.
