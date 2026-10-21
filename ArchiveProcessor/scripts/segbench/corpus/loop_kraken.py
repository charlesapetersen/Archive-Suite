#!/usr/bin/env python3
"""W46.ocr-loops — kraken PP-OCRv6 (medium) on blla lines, for the Latin-script pages an open route capped.

  heavy-run.py run -- python3 loop_kraken.py public --ids DIR/latin-caps.json --out DIR/kraken
  heavy-run.py run -- python3 loop_kraken.py truth96 --pages p013,p018,... --out DIR/kraken96

A CTC line recogniser cannot loop, so this is the recovery arm loop_rerun.py's report scores. specialists.py's
lane, reused: blla once per page into RUN/seg (pages segmented there already are not redone), then `kraken ocr`
into RUN/text/kraken-ppocrv6/, each page also copied to --out. The public pages are the 895-page manifest's
(loop_rerun.MANIFEST); the owner's 96 are read from the panel's 2400 px JPEGs (ocr_panel.py CACHE/images, the
same images ocr_mac_local.py reads), segmented into RUN/seg96 and read into RUN/text96. Their text never enters
the repo. Kiessling's model (Zenodo 10.5281/zenodo.21788410, Apache-2.0) needs kraken >= 7.1.0; it writes NFD.
Its card lists koenigsfelden, kurrent (german_kurrent_handwritten_text_lines), iforal, OCR-D gt_structure_text,
EPARCHOS and Muharaf among its training data, and a VOC/notarial-deeds record (Zenodo 11209325) beside ours
(6414086). No money. Timings (wall seconds a call, pages a call, workers) go to --out/timing.json.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import shutil
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import routes as R          # noqa: E402
import specialists as SP    # noqa: E402

KEY = 'kraken-ppocrv6'
DOI = '10.5281/zenodo.21788410'
LTS = Path(os.environ.get('LTS', Path.home() / 'Claude/Long term storage'))
MANIFEST = LTS / 'FarmShare-20261019/recovery/manifest-895.jsonl'   # = loop_rerun.MANIFEST
PANEL_IMAGES = Path(os.environ.get('OCR_PANEL_CACHE', Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/ocr-panel-local')) / 'images'


def model():
    found = sorted(SP.MODELS_DIR.glob('*/medium.safetensors'))
    if len(found) != 1:
        raise SystemExit(f'{KEY}: want one medium.safetensors under {SP.MODELS_DIR}; run: {SP.KRAKEN} get {DOI}')
    return found[0]


def timed(log, kind, n, *a):
    t = time.monotonic()
    SP.kraken(*a)
    log.append({'step': kind, 'pages': n, 'seconds': round(time.monotonic() - t, 1)})


def run(jobs, out):
    """jobs: (id, image, seg xml, text file, text direction). Segment what has no xml, read what has no text."""
    log, m = [], model()
    seg = [j for j in jobs if not j[2].exists()]
    for j in jobs:
        j[2].parent.mkdir(parents=True, exist_ok=True)
        j[3].parent.mkdir(parents=True, exist_ok=True)
    # One kraken per worker, BATCH pages a call, as specialists.segment does; `-x` before the inputs.
    with concurrent.futures.ThreadPoolExecutor(SP.WORKERS) as ex:
        for f in [ex.submit(timed, log, 'blla', len(b), ['-x'], [(j[1], j[2]) for j in b], 'segment', '-bl',
                            '--text-direction', d)
                  for d in sorted({j[4] for j in seg}) for b in SP.batches([j for j in seg if j[4] == d])]:
            f.result()
        read = [j for j in jobs if not j[3].exists()]
        for f in [ex.submit(timed, log, 'ocr', len(b), ['-f', 'page'], [(j[2], j[3]) for j in b], 'ocr', '-m', str(m))
                  for b in SP.batches(read)]:
            f.result()
    out.mkdir(parents=True, exist_ok=True)
    for j in jobs:
        shutil.copyfile(j[3], out / (j[0] + '.txt'))
    empty = [j[0] for j in jobs if not j[3].read_text().strip()]
    t = out / 'timing.json'
    prev = json.loads(t.read_text())['calls'] if t.exists() else []
    t.write_text(json.dumps({'workers': SP.WORKERS, 'batch': SP.BATCH, 'model': str(m), 'calls': prev + log,
                             'segmented': len(seg), 'read': len(read), 'pages': len(jobs), 'empty': empty}, indent=1))
    print(f'{len(seg)} segmented, {len(read)} read, {len(jobs)} copied to {out}, {len(empty)} empty')


def public(ids, out):
    R.MANIFEST = MANIFEST
    rows = {R.job_id(r): r for r in R.frozen()}
    want = json.loads(Path(ids).read_text())
    bad = [i for i in want if i not in rows or rows[i]['script'] != 'Latn']
    if bad:
        raise SystemExit(f'not Latin pages of the 895: {bad[:5]}')
    run([(i, rows[i]['image'], SP.seg_path(rows[i]), SP.text_path(KEY, rows[i]), 'horizontal-lr') for i in want], out)


def truth96(pages, out):
    run([(p, PANEL_IMAGES / f'{p}-original.jpg', SP.RUN / 'seg96' / f'{p}.xml', SP.RUN / 'text96' / KEY / f'{p}.txt',
          'horizontal-lr') for p in pages], out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['public', 'truth96'])
    ap.add_argument('--ids', help='public: JSON list of job ids')
    ap.add_argument('--pages', help='truth96: comma-separated panel ids')
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    if a.command == 'public':
        return public(a.ids, a.out)
    truth96(a.pages.split(','), a.out)


if __name__ == '__main__':
    main()
