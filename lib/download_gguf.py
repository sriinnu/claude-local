#!/usr/bin/env python3
"""Download a GGUF file (or full shard set) from Hugging Face Hub.
Usage: python3 lib/download_gguf.py --repo REPO_ID --file FILENAME --dir LOCAL_DIR

If FILENAME matches a split-GGUF shard (e.g. name-00001-of-00006.gguf),
all sibling shards in the repo are downloaded too — llama.cpp expects the
full set on disk next to each other and loads them by pointing at shard 1.
"""
import argparse
import re
import sys

SHARD_RE = re.compile(r"^(.*)-(\d+)-of-(\d+)\.gguf$")


def main():
    parser = argparse.ArgumentParser(description="Download GGUF from Hugging Face")
    parser.add_argument("--repo", required=True, help="Hugging Face repo ID")
    parser.add_argument("--file", required=True, help="Filename to download")
    parser.add_argument("--dir", required=True, help="Local directory to save to")
    args = parser.parse_args()

    try:
        from huggingface_hub import HfApi, hf_hub_download
    except ImportError:
        print("Error: huggingface-hub is not installed. Run: pip install huggingface-hub",
              file=sys.stderr)
        sys.exit(1)

    files_to_get = [args.file]
    m = SHARD_RE.match(args.file)
    if m:
        prefix, _, total = m.groups()
        files_to_get = [f"{prefix}-{i:05d}-of-{total}.gguf" for i in range(1, int(total) + 1)]
        print(f"Split GGUF detected — fetching all {total} shards.")

    try:
        for i, filename in enumerate(files_to_get, 1):
            if len(files_to_get) > 1:
                print(f"[{i}/{len(files_to_get)}] {filename}")
            path = hf_hub_download(
                repo_id=args.repo,
                filename=filename,
                local_dir=args.dir,
                local_dir_use_symlinks=False,
            )
            print(f"Downloaded to: {path}")
    except Exception as e:
        print(f"Download failed: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
