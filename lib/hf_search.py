#!/usr/bin/env python3
"""Search Hugging Face Hub for GGUF models.
Usage: python3 lib/hf_search.py [--query QUERY] [--limit N]
"""
import argparse
import sys


def main():
    parser = argparse.ArgumentParser(description="Search HF Hub for GGUF models")
    parser.add_argument("--query", default="", help="Search keywords (space-separated)")
    parser.add_argument("--limit", type=int, default=200, help="Max results from API")
    args = parser.parse_args()

    try:
        from huggingface_hub import HfApi
    except ImportError:
        print("Error: huggingface-hub is not installed. Run: pip install huggingface-hub",
              file=sys.stderr)
        sys.exit(1)

    api = HfApi()
    keywords = [k.lower() for k in args.query.split() if k]

    models = api.list_models(
        search=keywords[0] if keywords else "",
        limit=args.limit,
        sort="likes",
    )

    ggufs = []
    for m in models:
        mid = m.id
        if keywords and not any(k in mid.lower() for k in keywords):
            continue

        try:
            siblings = list(api.list_repo_files(repo_id=mid, repo_type="model"))
        except Exception:
            continue

        gguf_files = [f for f in siblings if f.endswith(".gguf")]
        if not gguf_files:
            continue

        likes = getattr(m, "likes", 0) or 0
        gguf_files.sort(key=len)
        ggufs.append({
            "id": mid,
            "likes": likes,
            "gguf_count": len(gguf_files),
            "files": gguf_files,
        })

    ggufs.sort(key=lambda x: (-x["likes"], x["id"]))

    for g in ggufs[:50]:
        gguf_list = " | ".join(g["files"][:5])
        if len(g["files"]) > 5:
            gguf_list += f' + {len(g["files"]) - 5} more'
        print(f'{g["id"]:<40s} | {g["likes"]:>5d} likes | {g["gguf_count"]} GGUF(s) | {gguf_list}')

    if not ggufs:
        print("No GGUF models found.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
