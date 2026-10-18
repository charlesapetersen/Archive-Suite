#!/usr/bin/env python3
"""NewsBench read layout-first by a GENERAL model on an institutional GPU node (job.sbatch mode news-layout).

The kit's own layout-first route is news_layout.py (the glm-ocr preset: DocLayout-YOLO + GLM-OCR, NewsBench's
reference configuration, through cluster_ocr.py --layout). This runner is the comparison beside it: any model vLLM serves
reading the library's regions through its OpenAI-compatible recognizer, as NewsBench's *-paddlex rows were made.

  cluster_news_layout.py --newsbench DIR --out DIR --label L --base-url URL --model M --reader openai|glm \
      --detectors doclayout_yolo paddlex [--workers N] [--limit N]

newspaper-ocr (github.com/nealcaren/newspaper-ocr) finds the page's regions with a layout detector, and each region
crop goes to the model this job serves with vLLM: through the library's OpenAI-compatible recognizer for a general
model (`openai`, its default region prompt), or its GLM-OCR recognizer in API mode (`glm`). This is how NewsBench's
own reference rows were made: `ll-doclayout-*` and `glm-ocr-doclayout` are the `doclayout_yolo` detector with the
library's layout processing, the `*-paddlex` rows PP-DocLayout. Library defaults throughout, so a row here differs
from its reference only in the reader and the hardware.

Runs in the newspaper-ocr venv (setup-layout.sh), not the vLLM one. Per detector it writes
  <newsbench>/ocr-results/<label>-<detector>/<id>.txt   what NewsBench's score.py reads
  <out>/<label>-<detector>/timing.json                   seconds a page, characters, failures; no transcript text
Pages run in parallel, one pipeline per worker thread (the detectors are not shared across threads), so vLLM
batches region requests from several pages at once.
"""
from __future__ import annotations

import argparse
import json
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def build_pipeline(detector: str, reader: str, base_url: str, model: str):
    from newspaper_ocr import Pipeline
    if reader == 'glm':
        from newspaper_ocr.recognizers.glm_ocr import GlmOcrRecognizer
        # API mode posts its mlx_model_id as the request's model name, so that must be the served name.
        rec = GlmOcrRecognizer(mode='api', api_url=f'{base_url}/chat/completions', model_id=model,
                               mlx_model_id=model, timeout=600)
    else:
        from newspaper_ocr.recognizers.openai_compat import OpenAiCompatRecognizer
        # Qwen3.5/3.6 think by default and vLLM returns the thinking in the reply, so every region's text came back
        # wrapped in working notes (NewsBench 0.187, 2026-10-15). cluster_ocr.py turns it off the same way.
        rec = OpenAiCompatRecognizer(model=model, base_url=base_url, api_key='local', timeout=600,
                                     extra_body={'chat_template_kwargs': {'enable_thinking': False}})
    return Pipeline(detector=detector, recognizer=rec)


def run_detector(a, detector: str, images: list[Path]) -> dict:
    name = f'{a.label}-{detector}'
    txt_dir = Path(a.newsbench) / 'ocr-results' / name
    txt_dir.mkdir(parents=True, exist_ok=True)
    local = threading.local()

    def read(img: Path) -> dict:
        if not hasattr(local, 'pipe'):
            local.pipe = build_pipeline(detector, a.reader, a.base_url, a.model)
        t = time.time()
        try:
            text = local.pipe.ocr(str(img))
            # newspaper-ocr catches a region's failed request and leaves it blank, so a page whose every request
            # failed still returns: call that empty, not ok (2026-10-15, one page against no server came back "ok").
            status = 'ok' if text.strip() else 'empty'
        except Exception as e:  # one page's failure is that page's empty reading, as NewsBench scores it
            text, status = '', f'error: {type(e).__name__}: {e}'[:300]
        (txt_dir / f'{img.stem}.txt').write_text(text, encoding='utf-8')
        page = {'page': img.stem, 'seconds': round(time.time() - t, 1), 'chars': len(text), 'status': status}
        print(json.dumps({'detector': detector, **page}), flush=True)
        return page

    t0 = time.time()
    with ThreadPoolExecutor(max_workers=a.workers) as pool:
        pages = list(pool.map(read, images))
    wall = time.time() - t0
    summary = {'label': name, 'detector': detector, 'reader': a.reader, 'model': a.model, 'workers': a.workers,
               'pages': len(pages), 'ok': sum(p['status'] == 'ok' for p in pages),
               'empty': sum(p['status'] == 'empty' for p in pages), 'wall_s': round(wall, 1),
               'pages_per_hour_per_gpu': round(len(pages) / wall * 3600, 1) if wall else None, 'per_page': pages}
    out = Path(a.out) / name
    out.mkdir(parents=True, exist_ok=True)
    (out / 'timing.json').write_text(json.dumps(summary, indent=1) + '\n')
    return summary


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--newsbench', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--label', required=True)
    ap.add_argument('--base-url', required=True, help='the served model, e.g. http://127.0.0.1:8123/v1')
    ap.add_argument('--model', required=True, help='the served model name')
    ap.add_argument('--reader', choices=['openai', 'glm'], required=True)
    ap.add_argument('--detectors', nargs='+', default=['doclayout_yolo', 'paddlex'])
    ap.add_argument('--workers', type=int, default=4)
    ap.add_argument('--limit', type=int, default=0, help='only the first N pages (a warm-up or a check)')
    a = ap.parse_args()
    images = sorted((Path(a.newsbench) / 'images').glob('*.jpg'))
    if a.limit:
        images = images[:a.limit]
    if not images:
        raise SystemExit(f'no page images under {a.newsbench}/images')
    for detector in a.detectors:
        s = run_detector(a, detector, images)
        print(f"{s['label']}: {s['ok']}/{s['pages']} pages in {s['wall_s']} s ({s['pages_per_hour_per_gpu']} an hour)",
              flush=True)
    print(f"Score: cd {a.newsbench} && python score.py", flush=True)


if __name__ == '__main__':
    main()
