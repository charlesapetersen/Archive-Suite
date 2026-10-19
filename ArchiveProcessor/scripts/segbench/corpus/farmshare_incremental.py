#!/usr/bin/env python3
"""Append-only FarmShare OCR: unchanged pages survive benchmark expansion.

pack verifies the committed source checksums and adds JPEGs for new pages only.
run binds the existing collector/cache to one inference protocol, verifies cached
page identities, and proves those saved readings were not rewritten. Truth edits
need rescoring only; changed images/settings require a distinct cache/experiment.
No hosted call, source download or original-result deletion.
"""
from pathlib import Path
import argparse
import hashlib
import io
import json
import os
import subprocess
import sys

LEGACY_SHA = 'fe5679d9913fdc92008ad6d409c05c7b400239dd1913eeb4639dde2f3e29576b'
PROMPT_SHA = '2ab7ab039a6e42db6734ad7c7e5a168a60856d3bfb27e02f6c2bef08137aee8d'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.part')
    tmp.write_text(json.dumps(obj, indent=2) + '\n')
    tmp.replace(path)


def bind(path, config):
    if path.exists() and json.loads(path.read_text()) != config:
        raise ValueError('OCR settings changed; use a distinct experiment/cache, never silently reuse')
    if not path.exists():
        save(path, config)


def cached(rows, out, model):
    """A larger manifest leaves valid old readings alone; capped replies remain terminal."""
    found = {}
    for row in rows:
        p = out / (row['id'] + '.json')
        if not p.exists():
            continue
        old = json.loads(p.read_text())
        if any(old.get(k) != v for k, v in {
            'id': row['id'], 'sha256': row['sha256'], 'model': model, 'mode': 'panel',
        }.items()) or old.get('status') not in ('ok', 'cap'):
            raise ValueError('Cached OCR input/model differs: ' + row['id'])
        found[row['id']] = digest(p.read_bytes())
    return found


def pack(a):
    import routes as R
    from PIL import Image
    R.MANIFEST = a.manifest
    full = R.frozen()  # original image + truth hashes checked; never fetches
    base = {R.job_id(x): x for x in R.C.read_jsonl(a.base)}
    old = {x['id']: x for x in R.C.read_jsonl(a.legacy_inputs)}
    current = {R.job_id(x): x for x in full}
    if len(current) != len(full) or set(base) != set(old) or not set(base) <= set(current):
        raise ValueError('Duplicate/colliding page IDs or removed reference pages')
    for jid, row in base.items():
        for key in ('source', 'page_id', 'image_sha256'):
            if current[jid][key] != row[key]:
                raise ValueError('Reference source changed: ' + jid)
    if digest(R.P.PROMPT.encode()) != PROMPT_SHA or R.P.SIDE != 2400 or R.P.MAX_TOKENS != 8192:
        raise ValueError('Panel protocol differs from the measured original run')
    a.out.mkdir(parents=True, exist_ok=True)
    jobs = []
    Image.MAX_IMAGE_PIXELS = None  # every source was checksum-verified above
    for jid, row in sorted(current.items()):
        if jid in old:
            jobs.append(old[jid])
            continue
        with Image.open(row['image']) as source:
            image = source.convert('RGB')
            image.thumbnail((2400, 2400), Image.Resampling.LANCZOS)
            data = io.BytesIO()
            image.save(data, 'JPEG', quality=90)
        dest = a.out / 'images' / (jid + '.jpg')
        b = data.getvalue()
        if dest.exists() and dest.read_bytes() != b:
            raise ValueError('Prepared image changed: ' + jid)
        dest.parent.mkdir(parents=True, exist_ok=True)
        if not dest.exists():
            dest.write_bytes(b)
        jobs.append({'id': jid, 'image': str(a.remote / 'images' / dest.name),
                     'sha256': digest(b), 'stratum': row['stratum'], 'source': row['source']})
    payload = ''.join(json.dumps(j) + '\n' for j in jobs)
    path = a.out / 'public-expanded.jsonl'
    if path.exists() and path.read_text() != payload:
        raise ValueError('Pack exists with other inputs; preserve it and choose a new output directory')
    path.write_text(payload)
    save(a.out / 'pack.json', {'pages': len(jobs), 'old_pages': len(old), 'new_pages': len(jobs)-len(old),
         'manifest_sha256': digest(a.manifest.read_bytes()), 'base_sha256': digest(a.base.read_bytes()),
         'legacy_inputs_sha256': digest(a.legacy_inputs.read_bytes()), 'prompt_sha256': PROMPT_SHA,
         'legacy_collector_sha256': LEGACY_SHA, 'side': 2400, 'max_tokens': 8192})
    print(f'{len(jobs)} total; reuse {len(old)}, new {len(jobs)-len(old)}; no original JPEG re-encoding')


def run(a):
    from huggingface_hub import snapshot_download
    import importlib.metadata
    root = Path(os.environ['SESSION_ROOT'])
    legacy, prompt = root / 'ocr/ocr_run.py', root / 'ocr/panel-prompt.txt'
    if digest(legacy.read_bytes()) != LEGACY_SHA or digest(prompt.read_bytes()) != PROMPT_SHA:
        raise ValueError('Original collector/prompt changed; do not adopt its cache')
    model = os.environ['FS_MODEL']
    revision = Path(snapshot_download(model, local_files_only=True)).name
    if revision != a.revision:
        raise ValueError('Cached model revision changed')
    rows = [json.loads(x) for x in a.manifest.open()]
    if len({r['id'] for r in rows}) != len(rows):
        raise ValueError('Duplicate page ID')
    for row in rows:
        if Path(row['id']).name != row['id']:
            raise ValueError('Page ID escapes cache')
    out = root / 'results/ocr' / a.label
    out.mkdir(parents=True, exist_ok=True)
    before = cached(rows, out, model)
    config = {'model': model, 'revision': revision, 'prompt_sha256': PROMPT_SHA,
              'collector_sha256': LEGACY_SHA, 'mode': 'panel', 'max_tokens': 8192,
              'temperature': 0, 'thinking': False, 'side': 2400,
              'vllm': importlib.metadata.version('vllm'), 'server_args': os.environ['FS_VLLM_ARGS']}
    # Manifest size is deliberately absent: adding pages does not invalidate readings.
    bind(root / 'ocr-cache-contracts' / (a.label + '.json'), config)
    if (out / 'summary.json').exists():
        b = (out / 'summary.json').read_bytes()
        backup = out / 'runs' / ('summary-' + digest(b) + '.json')
        backup.parent.mkdir(exist_ok=True)
        if not backup.exists():
            backup.write_bytes(b)
    # Prior transport errors are history, not duplicate page answers in report globs.
    for row in rows:
        p = out / (row['id'] + '.error.json')
        if p.exists():
            backup = out / 'errors' / (row['id'] + '-' + digest(p.read_bytes()) + '.json')
            backup.parent.mkdir(exist_ok=True)
            p.rename(backup)
    result = subprocess.run([sys.executable, str(legacy), '--manifest', str(a.manifest),
                             '--label', a.label, '--mode', 'panel'])
    after = cached(rows, out, model)
    if any(after.get(jid) != h for jid, h in before.items()):
        raise ValueError('An existing page reading was rewritten')
    receipt = {'label': a.label, 'job': os.environ.get('SLURM_JOB_ID'), 'expected': len(rows),
               'cached_before': len(before), 'terminal_after': len(after),
               'new_terminal': len(after)-len(before), 'old_readings_unchanged': True,
               'collector_exit': result.returncode, 'settings': config}
    save(a.receipts / (a.label + '.json'), receipt)
    print(json.dumps(receipt), flush=True)
    if result.returncode or len(after) != len(rows):
        raise SystemExit(result.returncode or 1)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('pack')
    for name in ('manifest', 'base', 'legacy-inputs', 'out', 'remote'):
        p.add_argument('--'+name, type=Path, required=True)
    p = sub.add_parser('run')
    p.add_argument('--manifest', type=Path, required=True)
    p.add_argument('--label', required=True)
    p.add_argument('--revision', required=True)
    p.add_argument('--receipts', type=Path, required=True)
    a = ap.parse_args()
    {'pack': pack, 'run': run}[a.cmd](a)


if __name__ == '__main__':
    main()
