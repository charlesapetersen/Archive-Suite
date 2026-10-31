#!/usr/bin/env python3
"""W46.ocr-new-open-boxes, the CPU setup job's Python (setup-job.sh runs it; Sherlock keeps downloads off login nodes).

  boxes_setup.py download CANDIDATES ROOT895 ROOT96    in the vLLM image: each model's snapshot at its resolved ref
  boxes_setup.py check KEY ROOT895 ROOT96              in that model's overlay venv: import its code, no weights

download resolves each candidate's ref (`main`, granite's `untied`) to a commit, records it beside the sha the Mac read
on 2026-10-31 (`expected_sha`; a mismatch is recorded, not fatal, since the snapshot is pinned from here on), fetches
the small files, then only the weight files the index names (Unlimited-OCR's repo carries the same weights twice),
refusing a model over `weight_limit_bytes`. It writes prepared.json (state `downloaded`) into ROOT/<key> for both
sets. check imports the model's remote code (transformers' dynamic modules; granite: vLLM and docling-core) without
loading a weight and sets state `ready`, or `skipped` with the reason, in both. A key already `ready` is left alone.
"""
from pathlib import Path
import fnmatch
import json
import os
import sys
import traceback


def save(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix('.part')
    tmp.write_text(json.dumps(obj, indent=1, ensure_ascii=False) + '\n')
    tmp.replace(path)


def write_both(roots, key, rec):
    for root in roots:
        save(root / key / 'prepared.json', rec)


def download(cands, roots):
    from huggingface_hub import HfApi, snapshot_download
    api = HfApi()
    for c in json.loads(Path(cands).read_text()):
        key = c['key']
        done = roots[0] / key / 'prepared.json'
        if done.exists() and json.loads(done.read_text())['state'] == 'ready':
            print(key, 'ready already')
            continue
        rec = {**c, 'state': 'skipped'}
        try:
            info = api.model_info(c['model'], revision=c['ref'], files_metadata=True)
            if getattr(info, 'gated', False) or getattr(info, 'private', False):
                raise RuntimeError('gated or private')
            rec['revision'] = info.sha
            rec['sha_check'] = ('matches' if info.sha == c.get('expected_sha') else
                                f"resolved {c['ref']} to {info.sha}; the Mac read {c.get('expected_sha')} on 2026-10-31")
            names = [s.rfilename for s in info.siblings]
            keep = [n for n in names if not any(fnmatch.fnmatch(n, g) for g in c.get('ignore', []))]
            heavy = ('.safetensors', '.bin', '.pt', '.pth', '.onnx', '.gguf', '.msgpack', '.h5', '.whl')
            small = [n for n in keep if not n.endswith(heavy)]
            snap = snapshot_download(c['model'], revision=info.sha, allow_patterns=small)
            index = Path(snap) / 'model.safetensors.index.json'
            weights = (sorted(set(json.loads(index.read_text())['weight_map'].values())) if index.exists()
                       else [n for n in keep if n.endswith('.safetensors') and '/' not in n])
            size = sum(s.size or 0 for s in info.siblings if s.rfilename in weights)
            if size > c['weight_limit_bytes']:
                raise RuntimeError(f'{size} weight bytes over the {c["weight_limit_bytes"]} limit')
            snap = snapshot_download(c['model'], revision=info.sha, allow_patterns=small + weights)
            rec.update(state='downloaded', snapshot=snap, weights=weights, weight_bytes=size)
        except Exception as exc:
            rec['reason'] = f'{type(exc).__name__}: {exc}'[:500]
        write_both(roots, key, rec)
        print(key, rec['state'], rec.get('revision', ''), rec.get('sha_check', ''), rec.get('reason', ''))


def check(key, roots):
    rec = json.loads((roots[0] / key / 'prepared.json').read_text())
    if rec['state'] != 'downloaded':
        print(key, rec['state'], 'not checked')
        return
    try:
        import torch
        import transformers
        versions = {'torch': torch.__version__, 'transformers': transformers.__version__, 'python': sys.version.split()[0]}
        if not torch.__version__.endswith('+cu129'):
            raise RuntimeError('the overlay replaced the image torch: ' + torch.__version__)
        snap = rec['snapshot']
        if rec['adapter'] == 'granite':
            import docling_core  # noqa: F401
            import vllm
            from docling_core.types.doc.document import DocTagsDocument  # noqa: F401
            versions.update(vllm=vllm.__version__)
            from transformers import AutoProcessor
            AutoProcessor.from_pretrained(snap, local_files_only=True)
        else:
            from transformers import AutoConfig
            from transformers.dynamic_module_utils import get_class_from_dynamic_module
            cfg = AutoConfig.from_pretrained(snap, trust_remote_code=True, local_files_only=True)
            ref = cfg.auto_map.get('AutoModel') or cfg.auto_map.get('AutoModelForCausalLM')
            get_class_from_dynamic_module(ref, snap, local_files_only=True)
            if rec['adapter'] == 'nemotron':
                sys.path.insert(0, snap)
                from postprocessing import postprocess_text  # noqa: F401
                from transformers import AutoProcessor
                AutoProcessor.from_pretrained(snap, trust_remote_code=True, local_files_only=True)
            else:
                from transformers import AutoTokenizer
                AutoTokenizer.from_pretrained(snap, trust_remote_code=True, local_files_only=True)
        used = Path(sys.prefix, 'constraints-used')
        if rec['adapter'] == 'granite':
            drift = vllm_drift()
            if drift:
                raise RuntimeError('the overlay moved packages vLLM needs: ' + ', '.join(drift))
        rec.update(state='ready', python=sys.executable, check_versions=versions,
                   constraints_used=used.read_text().strip() if used.exists() else None)
    except Exception:
        rec.update(state='skipped', reason='import check failed: ' + traceback.format_exc()[-1500:])
    write_both(roots, key, rec)
    print(key, rec['state'], rec.get('check_versions', ''), rec.get('reason', '')[-400:])


def vllm_drift():
    """vLLM's own requirements whose installed version in this venv differs from the image's (the venv shadows the
    image), as `name image->venv`. Empty when docling-core went in under the whole image's constraints."""
    import importlib.metadata as md
    import re
    image = {}
    freeze = Path(os.environ.get('BOXES_IMAGE_FREEZE', ''))
    if freeze.is_file():
        for line in freeze.read_text().splitlines():
            if '==' in line:
                k, v = line.split('==', 1)
                image[re.sub(r'[-_.]+', '-', k).lower()] = v.strip()
    out = []
    for req in md.requires('vllm') or []:
        if 'extra ==' in req:
            continue
        name = re.sub(r'[-_.]+', '-', re.match(r'[A-Za-z0-9_.-]+', req).group(0)).lower()
        try:
            have = md.version(name)
        except md.PackageNotFoundError:
            continue
        if name in image and image[name] != have:
            out.append(f'{name} {image[name]}->{have}')
    return out


def main():
    cmd = sys.argv[1]
    roots = [Path(p) for p in sys.argv[3:5]]
    if cmd == 'download':
        download(sys.argv[2], roots)
    elif cmd == 'check':
        check(sys.argv[2], roots)
    else:
        raise SystemExit('download | check')


if __name__ == '__main__':
    os.environ.setdefault('TOKENIZERS_PARALLELISM', 'false')
    main()
