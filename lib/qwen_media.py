#!/usr/bin/env python3
"""Image/video generation through the Alibaba Model Studio Token Plan (Singapore).

Chat models go through the Anthropic endpoint; generation models use separate
endpoints on the same token-plan host. Key comes from $QWEN_API_KEY (loaded from
the login keychain by claude_config.zsh) and is never printed.

  qwen_media.py image "a red cat" [--model wan2.7-image-pro] [--size 1024*1024]
  qwen_media.py video "a cardboard city" [--resolution 720P --ratio 16:9 --duration 5]

Only text-to-image and text-to-video are wired. i2v / r2v bodies are unverified.
"""
import argparse, json, os, re, sys, time, urllib.error, urllib.request

BASE = os.environ.get("QWEN_MEDIA_BASE", "https://token-plan.ap-southeast-1.maas.aliyuncs.com")
IMAGE_PATHS = ["/api/v1/services/aigc/image-generation/generation",
               "/api/v1/services/aigc/multimodal-generation/generation"]
VIDEO_PATH = "/api/v1/services/aigc/video-generation/video-synthesis"
OUT_DIR = os.path.expanduser(os.environ.get("QWEN_MEDIA_DIR", "~/qwen-media"))


def die(msg):
    print(f"✗ {msg}", file=sys.stderr)
    sys.exit(1)


def call(method, path, key, body=None, extra=None):
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    headers.update(extra or {})
    req = urllib.request.Request(BASE + path, method=method, headers=headers,
                                 data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"raw": raw[:300]}


def find_urls(obj, keys=("image", "url", "video_url", "image_url")):
    """Collect http(s) URLs found under any of `keys`, anywhere in the response."""
    out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in keys and isinstance(v, str) and v.startswith("http"):
                out.append(v)
            else:
                out += find_urls(v, keys)
    elif isinstance(obj, list):
        for v in obj:
            out += find_urls(v, keys)
    return out


def slug(prompt):
    return re.sub(r"[^a-z0-9]+", "-", prompt.lower()).strip("-")[:40] or "out"


def download(url, prompt, default_ext):
    os.makedirs(OUT_DIR, exist_ok=True)
    m = re.search(r"\.(png|jpe?g|webp|mp4)(?:\?|$)", url, re.I)
    ext = m.group(1).lower() if m else default_ext
    path = os.path.join(OUT_DIR, f"{time.strftime('%Y%m%d-%H%M%S')}-{slug(prompt)}.{ext}")
    urllib.request.urlretrieve(url, path)  # signed URL, no auth header needed
    return path


def poll(key, task_id, every=15, limit=900):
    t0 = time.time()
    while time.time() - t0 < limit:
        code, d = call("GET", f"/api/v1/tasks/{task_id}", key)
        out = d.get("output", {})
        status = out.get("task_status", "?")
        print(f"  … {status} ({int(time.time() - t0)}s)", file=sys.stderr)
        if status == "SUCCEEDED":
            return d
        if status in ("FAILED", "CANCELED", "UNKNOWN") or code >= 400:
            die(f"task {status}: {out.get('code') or d.get('code')} {out.get('message') or d.get('message') or d}")
        time.sleep(every)
    die("timed out waiting for the task")


def image(key, a):
    body = {"model": a.model,
            "input": {"messages": [{"role": "user", "content": [{"text": a.prompt}]}]},
            "parameters": {"size": a.size.lower().replace("x", "*"), "n": 1, "watermark": False}}
    for p in IMAGE_PATHS:
        # token-plan image-generation rejects sync calls (403 "does not support synchronous calls")
        code, d = call("POST", p, key, body,
                       {"X-DashScope-Async": "enable"} if "image-generation" in p else None)
        if code == 404:
            continue
        if code >= 400:
            die(f"image request failed ({code}) on {p}: {d.get('code', '')} {d.get('message') or d}")
        tid = d.get("output", {}).get("task_id")
        if tid and not find_urls(d):
            d = poll(key, tid)
        urls = find_urls(d)
        if not urls:
            die(f"no image URL in response: {json.dumps(d)[:300]}")
        return [download(u, a.prompt, "png") for u in urls]
    die("both image endpoints returned 404")


def video(key, a):
    body = {"model": a.model, "input": {"prompt": a.prompt},
            "parameters": {"resolution": a.resolution, "ratio": a.ratio, "duration": a.duration}}
    code, d = call("POST", VIDEO_PATH, key, body, {"X-DashScope-Async": "enable"})
    if code >= 400:
        die(f"video request failed ({code}): {d.get('code', '')} {d.get('message') or d}")
    tid = d.get("output", {}).get("task_id")
    if not tid:
        die(f"no task_id in response: {json.dumps(d)[:300]}")
    print(f"→ task {tid} submitted; polling every 15s (1-5 min typical)", file=sys.stderr)
    d = poll(key, tid)
    urls = find_urls(d)
    if not urls:
        die(f"no video URL in response: {json.dumps(d)[:300]}")
    return [download(u, a.prompt, "mp4") for u in urls]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="kind", required=True)
    i = sub.add_parser("image")
    i.add_argument("prompt")
    i.add_argument("--model", default="qwen-image-3.0-pro")
    i.add_argument("--size", default="1024*1024")
    v = sub.add_parser("video")
    v.add_argument("prompt")
    v.add_argument("--model", default="happyhorse-1.1-t2v")
    v.add_argument("--resolution", default="720P")
    v.add_argument("--ratio", default="16:9")
    v.add_argument("--duration", type=int, default=5)
    a = ap.parse_args()
    key = os.environ.get("QWEN_API_KEY")
    if not key:
        die("QWEN_API_KEY not set — source ~/.claude_config.zsh (loads it from the keychain)")
    for path in (image if a.kind == "image" else video)(key, a):
        print(path)


if __name__ == "__main__":
    main()
