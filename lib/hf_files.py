#!/usr/bin/env python3
"""List GGUF files in a Hugging Face repo.
Usage: python3 lib/hf_files.py <repo_id>
"""
import sys


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 hf_files.py <repo_id>", file=sys.stderr)
        sys.exit(1)

    repo_id = sys.argv[1]

    try:
        from huggingface_hub import HfApi
    except ImportError:
        print("Error: huggingface-hub is not installed. Run: pip install huggingface-hub",
              file=sys.stderr)
        sys.exit(1)

    api = HfApi()
    try:
        siblings = list(api.list_repo_files(repo_id=repo_id, repo_type="model"))
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    gguf_files = sorted(f for f in siblings if f.endswith(".gguf"))
    if not gguf_files:
        print("No GGUF files found in this repo.")
        sys.exit(1)

    for f in gguf_files:
        print(f)


if __name__ == "__main__":
    main()
