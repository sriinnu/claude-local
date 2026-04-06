#!/usr/bin/env python3
"""Download a GGUF file from Hugging Face Hub.
Usage: python3 lib/download_gguf.py --repo REPO_ID --file FILENAME --dir LOCAL_DIR
"""
import argparse
import sys


def main():
    parser = argparse.ArgumentParser(description="Download GGUF from Hugging Face")
    parser.add_argument("--repo", required=True, help="Hugging Face repo ID")
    parser.add_argument("--file", required=True, help="Filename to download")
    parser.add_argument("--dir", required=True, help="Local directory to save to")
    args = parser.parse_args()

    try:
        from huggingface_hub import hf_hub_download
    except ImportError:
        print("Error: huggingface-hub is not installed. Run: pip install huggingface-hub",
              file=sys.stderr)
        sys.exit(1)

    try:
        path = hf_hub_download(
            repo_id=args.repo,
            filename=args.file,
            local_dir=args.dir,
            local_dir_use_symlinks=False,
        )
        print(f"Downloaded to: {path}")
    except Exception as e:
        print(f"Download failed: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
