#!/usr/bin/env python3
"""Bounded CPU-only preparation of pinned, ungated, single-GPU OCR candidates."""
from pathlib import Path
import fnmatch
import json
import os
import sys
import traceback

PATTERNS = ('*.json', '*.safetensors', '*.model', '*.txt', '*.tiktoken', '*.jinja', '*.py', '*.bpe', '*.vocab', '*.merges')


def save(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix('.part')
    tmp.write_text(json.dumps(obj, indent=2) + '\n')
    tmp.replace(path)


def main():
    from huggingface_hub import HfApi, hf_hub_download, snapshot_download
    from vllm import ModelRegistry
    root = Path(sys.argv[1])
    supported = set(ModelRegistry.get_supported_archs())
    api = HfApi()
    for candidate in json.loads((root / 'candidates.json').read_text()):
        dest = root / candidate['key'] / 'prepared.json'
        if dest.exists():
            raise RuntimeError('Preparation exists; inspect before any explicit recovery: ' + str(dest))
        record = {**candidate, 'state': 'preparing', 'job': os.environ.get('SLURM_JOB_ID')}
        save(dest, record)
        try:
            info = api.model_info(candidate['model'], revision=candidate.get('revision'), files_metadata=True)
            if info.gated or info.private:
                raise ValueError('Gated/private model excluded')
            record['revision'] = info.sha
            record['license'] = getattr(info.card_data, 'license', None)
            names = [f.rfilename for f in info.siblings if any(fnmatch.fnmatch(f.rfilename, p) for p in PATTERNS)]
            weights = [f for f in info.siblings if f.rfilename in names and f.rfilename.endswith('.safetensors')]
            if not weights or any(f.size is None for f in weights):
                raise ValueError('No safetensor weights with known size')
            record['weight_bytes'] = sum(f.size for f in weights)
            limit = candidate.get('weight_limit_bytes', 25_000_000_000)
            if not 0 < limit <= 175_000_000_000 or record['weight_bytes'] > limit:
                raise ValueError('Exceeds candidate weight limit (absolute ceiling175GB)')
            config = json.loads(Path(hf_hub_download(candidate['model'], 'config.json', revision=info.sha)).read_text())
            record['architectures'] = config.get('architectures', [])
            if not set(record['architectures']) & supported:
                raise ValueError('Architecture unsupported by installed vLLM; no environment upgrade')
            record['snapshot'] = snapshot_download(candidate['model'], revision=info.sha, allow_patterns=names, max_workers=4)
            record['state'] = 'ready'
        except Exception as exc:
            record['state'] = 'skipped'
            record['reason'] = str(exc)[:1000]
            traceback.print_exc()
        save(dest, record)
        print(json.dumps(record), flush=True)


if __name__ == '__main__':
    main()
