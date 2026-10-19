#!/usr/bin/env python3
"""Pinned native PP-OCRv6: prepare on CPU; gated, append-only frozen-page run."""
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import re
import sys
import time
import traceback

MODELS = {
    'det': ('PaddlePaddle/PP-OCRv6_medium_det_safetensors', '4236c2b61741a259c091fd879dcc4edc339e916c'),
    'rec': ('PaddlePaddle/PP-OCRv6_medium_rec_safetensors', '024cad6a831de75c2c3c26e711ba8c4a82ccd24b'),
}
KEY = 'ppocrv6-medium-native'


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix('.part')
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    tmp.replace(path)


def pipeline(prepared, device):
    from paddleocr import PaddleOCR
    return PaddleOCR(
        text_detection_model_name='PP-OCRv6_medium_det',
        text_detection_model_dir=prepared['models']['det']['snapshot'],
        text_recognition_model_name='PP-OCRv6_medium_rec',
        text_recognition_model_dir=prepared['models']['rec']['snapshot'],
        engine='transformers', device=device,
        use_doc_orientation_classify=False, use_doc_unwarping=False,
        use_textline_orientation=False,
        # Explicit native OCR pipeline defaults, independent of future library defaults.
        text_det_limit_side_len=64, text_det_limit_type='min',
        text_det_thresh=0.3, text_det_box_thresh=0.6, text_det_unclip_ratio=1.5,
        text_recognition_batch_size=6, text_rec_score_thresh=0.0,
    )


def native_result(ocr, image):
    results = list(ocr.predict(image))
    if len(results) != 1:
        raise ValueError('Expected one page result')
    native = results[0].json
    res = native['res']
    texts = res['rec_texts']
    if not isinstance(texts, list) or not all(isinstance(x, str) for x in texts):
        raise ValueError('Invalid recognition text schema')
    if not len(texts) == len(res['rec_scores']) == len(res['rec_polys']):
        raise ValueError('Text/score/polygon counts differ')
    return native, '\n'.join(texts)


def prepare(root):
    from huggingface_hub import HfApi, snapshot_download
    import numpy as np
    dest = root / KEY / 'prepared.json'
    if dest.exists():
        raise RuntimeError('Preparation already recorded; inspect rather than resubmit')
    prepared = {'state': 'preparing', 'models': {}, 'job': os.environ.get('SLURM_JOB_ID')}
    save(dest, prepared)
    try:
        for key, (model, revision) in MODELS.items():
            info = HfApi().model_info(model, revision=revision, files_metadata=True)
            weights = [x for x in info.siblings if x.rfilename.endswith('.safetensors')]
            if info.gated or info.private or not weights or any(x.size is None for x in weights):
                raise ValueError('Expected public safetensors with known sizes')
            if sum(x.size for x in weights) > 2_000_000_000:
                raise ValueError('Unexpected model size')
            snapshot = Path(snapshot_download(model, revision=revision,
                allow_patterns=['*.json', '*.yml', '*.safetensors'], max_workers=4))
            prepared['models'][key] = {
                'model': model, 'revision': revision, 'snapshot': str(snapshot),
                'files': {p.name: sha(p) for p in sorted(snapshot.iterdir()) if p.is_file()},
            }
        prepared['versions'] = {p: importlib.metadata.version(p) for p in
            ['paddleocr', 'paddlex', 'transformers', 'torch', 'torchvision', 'numpy']}
        # API/load smoke only; benchmark pages are read once later on the GPU.
        ocr = pipeline(prepared, 'cpu')
        ocr.export_paddlex_config_to_yaml(str(root / KEY / 'pipeline.yaml'))
        native, _ = native_result(ocr, np.full((128, 128, 3), 255, dtype=np.uint8))
        save(root / KEY / 'synthetic-smoke.json', native)
        prepared['state'] = 'ready'
    except Exception as exc:
        prepared.update(state='failed', error=str(exc))
        save(dest, prepared)
        raise
    save(dest, prepared)
    print(json.dumps(prepared), flush=True)


def read_rows(path):
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if len({r['id'] for r in rows}) != len(rows):
        raise ValueError('Duplicate page IDs')
    for row in rows:
        if not re.fullmatch(r'[A-Za-z0-9_.-]+', row['id']):
            raise ValueError('Unsafe page ID')
        if sha(row['image']) != row['sha256']:
            raise ValueError('Input image changed: ' + row['id'])
    return rows


def run(root):
    out = root / KEY
    prepared = json.loads((out / 'prepared.json').read_text())
    if prepared['state'] != 'ready':
        raise RuntimeError('CPU preparation did not pass')
    for model in prepared['models'].values():
        for name, digest in model['files'].items():
            if sha(Path(model['snapshot']) / name) != digest:
                raise ValueError('Model bytes changed')
    rows = read_rows(root / 'public895.jsonl')
    pilots = read_rows(root / 'pilot3.jsonl')
    by_id = {r['id']: r for r in rows}
    if len(rows) != 895 or len(pilots) != 3 or any(by_id.get(r['id']) != r for r in pilots):
        raise ValueError('Expected frozen895 with matching three-page pilot')
    # Manifest size is intentionally absent: added pages can reuse unchanged readings.
    contract = {'prepared': prepared, 'runner_sha256': sha(__file__),
                'pipeline_sha256': sha(out / 'pipeline.yaml'), 'mode': KEY}
    dest = out / 'contract.json'
    if dest.exists() and json.loads(dest.read_text()) != contract:
        raise ValueError('Run contract changed; preserve prior readings')
    if not dest.exists():
        save(dest, contract)
    contract_sha = sha(dest)
    save(out / 'input-receipt.json', {'pages': len(rows), 'manifest_sha256': sha(root / 'public895.jsonl'),
                                    'pilot_sha256': sha(root / 'pilot3.jsonl')})
    ocr = pipeline(prepared, 'gpu:0')
    rawdir = out / 'raw'
    rawdir.mkdir(exist_ok=True)

    def page(row):
        target = rawdir / (row['id'] + '.json')
        if target.exists():
            previous = json.loads(target.read_text())
            if previous['sha256'] != row['sha256'] or previous['contract_sha256'] != contract_sha:
                raise ValueError('Cached page identity/configuration mismatch')
            return previous  # Includes failures; no automatic retry.
        start = time.monotonic()
        record = {**row, 'label': 'PP-OCRv6 medium native detector+recognizer',
                  'model': KEY, 'mode': KEY, 'contract_sha256': contract_sha,
                  'finish': None, 'usage': None, 'job': os.environ.get('SLURM_JOB_ID')}
        try:
            native, text = native_result(ocr, row['image'])
            record.update(native=native, raw=text, status='ok' if text.strip() else 'blank', error=None)
        except Exception as exc:
            traceback.print_exc()
            record.update(raw='', status='error', error=str(exc))
        record['wall_s'] = time.monotonic() - start
        # Only this job owns this output directory; existing terminal records never overwritten.
        save(target, record)
        print(row['id'], record['status'], round(record['wall_s'], 2), flush=True)
        return record

    pilot_records = [page(r) for r in pilots]
    passed = all(r['status'] == 'ok' for r in pilot_records)
    save(out / 'pilot-summary.json', {'passed': passed, 'pages':
         [{'id': r['id'], 'status': r['status'], 'wall_s': r['wall_s']} for r in pilot_records]})
    if not passed:
        raise RuntimeError('Three-page pilot failed; full benchmark was not started')
    counts = {}
    for row in rows:
        status = page(row)['status']
        counts[status] = counts.get(status, 0) + 1
        save(out / 'progress.json', {'terminal': sum(counts.values()), 'expected': len(rows), 'counts': counts})
    save(out / 'summary.json', {'phase': 'raw_complete_review_pending', 'pages': len(rows), 'counts': counts})


if __name__ == '__main__':
    phase, directory = sys.argv[1:]
    {'prepare': prepare, 'run': run}[phase](Path(directory))
