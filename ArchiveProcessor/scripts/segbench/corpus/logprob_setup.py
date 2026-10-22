#!/usr/bin/env python3
"""W46.ocr-logprob: pin and download the routes' weights that FarmShare's cache lacks (Qwen3.5-9B), on a CPU node.

  logprob_setup.py ROOT        (writes ROOT/setup.json: each model's pinned revision and snapshot path)

Run by logprob-submit.sh's setup job with HF_HOME set and HF_HUB_OFFLINE unset, as open_sweep_setup.py is.
"""
import json
import sys
from pathlib import Path

MODELS = ['Qwen/Qwen3.5-9B']
PATTERNS = ['*.json', '*.safetensors', '*.txt', '*.jinja', '*.model', '*.tiktoken']


def main():
    from huggingface_hub import HfApi, snapshot_download
    root = Path(sys.argv[1]); api = HfApi(); out = {}
    for m in MODELS:
        sha = api.model_info(m).sha
        out[m] = {'revision': sha, 'snapshot': snapshot_download(m, revision=sha, allow_patterns=PATTERNS, max_workers=4)}
        print(m, sha, flush=True)
    (root / 'setup.json').write_text(json.dumps(out, indent=2) + '\n')


if __name__ == '__main__':
    main()
