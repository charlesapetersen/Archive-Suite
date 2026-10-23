#!/usr/bin/env python3
"""W46.ocr-postcorrect: image-grounded post-correction in the NES 70-90 band only (C test 6).

    python3 postcorrect.py pack --out DIR --public-manifest public895.jsonl   # on the Mac; no model call

The pack is chosen from segbench-results/ocr-scorers-pages.csv, the rescorer's own per-page NES, and the readings come
from ocr_rescore.py's loaders, so the input is exactly the text those scores were computed on:

  band     pages a cheap reading scored NES 0.70-0.90: on the 96 the app's cheap readers (Apple Vision, LightOnOCR-3 4B
           on the Mac, Qwen3-VL 8B, Gemini 3.5 Flash-Lite), all of them; on the 895 the better open routes (GLM-OCR,
           LightOnOCR-3 4B, Qwen3-VL 8B) in L1, L2, L4 and L6, at most CAP_PUBLIC a route, spread over the strata.
  easy     the abstention check: on the 96, up to CAP_EASY pages a cheap reader scored 0.97 or more, which a corrector
           must leave as they are.

Each item goes to the corrector twice: with the page image (the field's safe design) and as text only (the control,
the design the literature finds fails). Corrector: Qwen3.6-27B FP8, thinking off, temperature 0, on Sherlock.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import random
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
RESULTS = HERE.parent.parent / 'segbench-results'

OWNER_ROUTES = ('apple-vision', 'lightonocr-3-4b-mlx8', 'qwen3-vl-8b', 'gemini3.5-flash-lite')
PUBLIC_ROUTES = ('glm-ocr', 'lightonocr3-4b', 'qwen3-vl-8b')
PUBLIC_STRATA = ('L1', 'L2', 'L4', 'L6')
LOW, HIGH, EASY = 0.70, 0.90, 0.97
CAP_PUBLIC, CAP_EASY, SEED = 40, 10, 46
# Where each set's page images sit on Sherlock: the 895 as the open sweep staged them; the 96 go up with the pack.
PUBLIC_IMAGES = '/scratch/users/cp1/fs-ocr/interactive-20261019/ocr/images'

PROMPT_IMAGE = (
    "Below is an OCR reading of the page in the image. Correct the reading against the image: fix characters and "
    "words that were misread, restore words that were dropped, and remove text that is not on the page. Do not "
    "translate, modernise, normalise spelling, rephrase or add anything that is not visible on the page. Keep the "
    "reading's line breaks and order wherever they are right. If the reading is already correct, return it unchanged. "
    "Reply with the corrected transcription only.\n\nOCR reading:\n")
PROMPT_TEXT = (
    "Below is an OCR reading of a historical document page. Correct OCR errors only: fix characters and words that "
    "were misread. Do not translate, modernise, normalise spelling, rephrase or add anything. Keep the line breaks and "
    "order. If the reading has no OCR error, return it unchanged. Reply with the corrected transcription only.\n\n"
    "OCR reading:\n")


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cmd_pack(a):
    import ocr_rescore as X
    rows = list(csv.DictReader((RESULTS / 'ocr-scorers-pages.csv').open()))
    nes = lambda r: float(r['nes']) if r['ok'] == 'True' and r['nes'] else None
    rng = random.Random(SEED)
    owner_src = {route: texts for (route, _fam), texts in X.owner_sources().items()}
    X.R.MANIFEST = RESULTS / 'bench-corpus/manifest.jsonl'
    truth = X.R.frozen()
    public_src = {route: texts for (route, _fam), texts in X.public_sources(truth).items()}
    by_job = {X.R.job_id(r): r for r in truth}

    items = []
    def add(set_, route, page, kind, score, text):
        if text and text.strip():
            items.append({'set': set_, 'route': route, 'page': page, 'kind': kind, 'nes': score, 'reading': text})

    for route in OWNER_ROUTES:
        mine = [r for r in rows if r['set'] == 'owner96' and r['route'] == route and nes(r) is not None]
        for r in mine:
            if LOW <= nes(r) <= HIGH:
                add('owner96', route, r['page'], 'band', nes(r), owner_src.get(route, {}).get(r['page']))
        easy = [r for r in mine if nes(r) >= EASY]
        for r in rng.sample(easy, min(CAP_EASY, len(easy))):
            add('owner96', route, r['page'], 'easy', nes(r), owner_src.get(route, {}).get(r['page']))
    for route in PUBLIC_ROUTES:
        band = [r for r in rows if r['set'] == 'public895' and r['route'] == route and r['stratum'] in PUBLIC_STRATA
                and nes(r) is not None and LOW <= nes(r) <= HIGH]
        # Spread the cap over the strata: shuffle, then take round-robin by stratum.
        by_s = {s: rng.sample([r for r in band if r['stratum'] == s], len([r for r in band if r['stratum'] == s]))
                for s in PUBLIC_STRATA}
        pick = []
        while len(pick) < CAP_PUBLIC and any(by_s.values()):
            for s in PUBLIC_STRATA:
                if by_s[s] and len(pick) < CAP_PUBLIC:
                    pick.append(by_s[s].pop())
        for r in pick:
            add('public895', route, r['page'], 'band', nes(r), public_src.get(route, {}).get(r['page']))

    out = a.out; (out / 'images').mkdir(parents=True, exist_ok=True)
    # The open sweep's manifest of the 895 as staged on the cluster (id, image, sha256); the job checks each image.
    public_sha = {r['id']: r['sha256'] for r in map(json.loads, a.public_manifest.read_text().splitlines())}
    requests = []
    for it in items:
        if it['set'] == 'owner96':
            # The original-scale image the panel and truth96 read (its hash is truth99.jsonl's), not ocr-truth/pages.
            src = X.CACHE / 'ocr-panel-local/images' / f"{it['page']}-original.jpg"
            dst = out / 'images' / src.name
            if not dst.exists():
                shutil.copy2(src, dst)
            image, digest = f"{a.remote}/images/{src.name}", sha(src)
        else:
            image, digest = f"{PUBLIC_IMAGES}/{it['page']}.jpg", public_sha.get(it['page'])
        for arm, prompt in (('image', PROMPT_IMAGE), ('text', PROMPT_TEXT)):
            rid = f"{it['set']}__{it['route']}__{it['page']}__{arm}"
            requests.append({'id': rid, **{k: it[k] for k in ('set', 'route', 'page', 'kind', 'nes')}, 'arm': arm,
                             'image': image if arm == 'image' else None, 'image_sha256': digest,
                             'prompt': prompt + it['reading']})
    with (out / 'requests.jsonl').open('w') as f:
        for r in requests:
            f.write(json.dumps(r, ensure_ascii=False) + '\n')
    counts = {}
    for it in items:
        k = f"{it['set']}/{it['kind']}"; counts[k] = counts.get(k, 0) + 1
    (out / 'pack.json').write_text(json.dumps({'items': len(items), 'requests': len(requests), 'counts': counts,
        'owner_routes': OWNER_ROUTES, 'public_routes': PUBLIC_ROUTES, 'public_strata': PUBLIC_STRATA,
        'band': [LOW, HIGH], 'easy': EASY, 'cap_public': CAP_PUBLIC, 'cap_easy': CAP_EASY, 'seed': SEED,
        'prompt_image_sha256': hashlib.sha256(PROMPT_IMAGE.encode()).hexdigest(),
        'prompt_text_sha256': hashlib.sha256(PROMPT_TEXT.encode()).hexdigest()}, indent=1) + '\n')
    print(json.dumps(counts), len(items), 'items,', len(requests), 'requests')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('pack'); p.add_argument('--out', type=Path, required=True)
    p.add_argument('--remote', default='/scratch/users/cp1/fs-ocr/postcorrect-20261022')
    p.add_argument('--public-manifest', type=Path, required=True, help="open-sweep-20261019/public895.jsonl")
    a = ap.parse_args()
    {'pack': cmd_pack}[a.cmd](a)


if __name__ == '__main__':
    main()
