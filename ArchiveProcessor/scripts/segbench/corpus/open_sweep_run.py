#!/usr/bin/env python3
"""Three-page compatibility gate, then append-only frozen-page OCR; no retries."""
from pathlib import Path
import hashlib
import importlib.metadata
import json
import os
import subprocess
import sys

LEGACY_SHA = 'fe5679d9913fdc92008ad6d409c05c7b400239dd1913eeb4639dde2f3e29576b'


def save(path, obj):
    tmp = path.with_suffix('.part')
    tmp.write_text(json.dumps(obj, indent=2) + '\n')
    tmp.replace(path)


def main():
    root = Path(os.environ['SESSION_ROOT'])
    parent = root.parent
    config = json.loads((root / 'prepared.json').read_text())
    label = config['key']
    concurrency = config.get('concurrency', 8)
    os.environ['FS_MODEL'] = config['model']
    collector = root / 'ocr/ocr_run.py'
    if hashlib.sha256(collector.read_bytes()).hexdigest() != LEGACY_SHA:
        raise ValueError('Frozen collector changed')
    contract = {'model': config['model'], 'revision': config['revision'], 'route': config['route'],
                'prompt_sha256': hashlib.sha256((root / 'ocr/panel-prompt.txt').read_bytes()).hexdigest(),
                'collector_sha256': LEGACY_SHA,
                'vllm': importlib.metadata.version('vllm') if config.get('runtime', 'vllm') == 'vllm' else None,
                'server_args': os.environ['FS_VLLM_ARGS'], 'max_tokens': 8192,
                'temperature': 0, 'thinking': False, 'concurrency': concurrency}
    if config.get('runtime') != 'vllm' and config.get('runtime') is not None:
        contract.update(runtime=config['runtime'], runtime_revision=config['runtime_revision'],
                        binary_sha256=config['binary_sha256'])
    binding = root / 'cache-contract.json'
    if binding.exists() and json.loads(binding.read_text()) != contract:
        raise ValueError('Different OCR settings; use a separate experiment')
    save(binding, contract)
    status = {'state': 'pilot', 'job': os.environ.get('SLURM_JOB_ID'), 'settings': contract}
    save(root / 'status.json', status)
    out = root / 'results/ocr' / label
    def collect(manifest):
        subprocess.run([sys.executable, str(collector), '--manifest', str(manifest),
                        '--label', label, '--mode', 'panel', '--concurrency', str(concurrency)], check=True)
    try:
        collect(parent / 'pilot3.jsonl')
        rows = [json.loads(x) for x in (parent / 'pilot3.jsonl').read_text().splitlines()]
        for row in rows:
            answer = json.loads((out / (row['id'] + '.json')).read_text())
            if answer['status'] != 'ok' or not answer['raw'].strip():
                raise ValueError('Pilot failed (capped/empty answer); no full run')
        save(root / 'pilot-summary.json', json.loads((out / 'summary.json').read_text()))
        status.update(state='full', pilot_passed=3)
        save(root / 'status.json', status)
        collect(parent / 'public895.jsonl')  # collector reuses the three pilot readings
        rows = [json.loads(x) for x in (parent / 'public895.jsonl').read_text().splitlines()]
        counts = {'ok': 0, 'cap': 0}
        for row in rows:
            answer = json.loads((out / (row['id'] + '.json')).read_text())
            if any(answer.get(k) != v for k, v in {'id': row['id'], 'sha256': row['sha256'],
                                                  'model': config['model'], 'mode': 'panel'}.items()):
                raise ValueError('Cached page/model identity differs')
            counts[answer['status']] += 1
        status.update(state='completed_raw', terminal=len(rows), counts=counts)
    except Exception as exc:
        status.update(state='needs_inspection', error=str(exc))
        save(root / 'status.json', status)
        raise
    save(root / 'status.json', status)


if __name__ == '__main__':
    main()
