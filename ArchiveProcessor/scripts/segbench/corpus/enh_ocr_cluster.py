#!/usr/bin/env python3
"""W46.enh-ocr-input, the cluster half: the learned enhancement arms on a GPU, then the open readers on every arm.

  enh_ocr_cluster.py routes  --root ROOT                       # ROOT/routes.json (+ probe/, glm/) from the loop rerun's
  enh_ocr_cluster.py enhance --root ROOT --arms A[,A...]        # GPU: ROOT/images/<arm>/<page>.jpg, then the lists
  enh_ocr_cluster.py lists   --root ROOT                        # the three pages.jsonl from what images exist

ROOT (staged by enh_ocr_input.py stage) holds images/raw and images/shading (made on the Mac), pages.json (the 96
and the probe's 30), regions/pp-doclayoutv3.json (the regions run's detector output on the raw images), src/ (the
methods' code and weights), enh_ocr_arms.py, and dewarp_cluster.py and regions_cluster.py, whose readers run
unchanged on three roots this script lists:
  ROOT/pages.jsonl        every main arm of the 96, "<arm>/<page>": PP-OCRv6 and Qwen3-VL 8B whole page
                          (dewarp_cluster.py ppocr / read, out/<route>/<arm>/<page>.json);
  ROOT/glm/pages.jsonl    the same images with regions keyed "<arm>/<page>": GLM-OCR on PP-DocLayoutV3's regions
                          (regions_cluster.py read --arms pp-doclayoutv3, out/glm-ocr/pp-doclayoutv3/<arm>/<page>/);
  ROOT/probe/pages.jsonl  raw and the two-seed diffusion arms of the 30: Qwen3.6-27B whole page.
Every enhanced image keeps the raw image's size (checked), so the raw image's regions apply to it. An image already
written is not made again, so a rerun after a wall-limit kill makes only what is left. No network, no money.
"""
from __future__ import annotations

from pathlib import Path
import argparse
import hashlib
import json
import os
import sys
import time

HERE = Path(__file__).resolve().parent
ROUTES_FROM = '/scratch/users/cp1/fs-ocr/loop-rerun-20261021/routes.json'
# our name -> the loop rerun's entry: the truth96 run's prompts for the 96; Qwen3.6-27B as the regions run served it
ROUTES = {'qwen3-vl-8b': 't96-qwen3-vl-8b', 'glm-ocr': 't96-glm-ocr', 'qwen3.6-27b': 'qwen3.6-27b'}
MAIN = ('raw', 'shading', 'docres-appearance', 'docres-deshadow', 'gcdrnet', 'sbb')
PROBE = ('raw', 'resshift-s1', 'resshift-s2', 'nafdpm-s1', 'nafdpm-s2')


def atomic_jsonl(dest: Path, rows):
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix('.tmp')
    tmp.write_text(''.join(json.dumps(r) + '\n' for r in rows))
    tmp.replace(dest)


def cmd_routes(a):
    src = json.loads(Path(ROUTES_FROM).read_text())
    plan = {k: {f: src[v][f] for f in ('model', 'served', 'prompt', 'vllm_args')} for k, v in ROUTES.items()}
    for d in (a.root, a.root / 'glm', a.root / 'probe'):
        d.mkdir(parents=True, exist_ok=True)
        (d / 'routes.json').write_text(json.dumps(plan, indent=2) + '\n')
    print(json.dumps(plan, indent=1))


def image(root, arm, page):
    return root / 'images' / arm / f'{page}.jpg'


def cmd_enhance(a):
    import numpy as np
    from PIL import Image
    sys.path.insert(0, str(a.root))
    import enh_ocr_arms as A
    sets = json.loads((a.root / 'pages.json').read_text())
    for arm in a.arms.split(','):
        ids = sets['probe'] if arm.startswith(('resshift', 'nafdpm')) else sets['pages']
        t0, made = time.time(), 0
        for p in ids:
            dest = image(a.root, arm, p)
            if dest.exists():
                continue
            with Image.open(image(a.root, 'raw', p)) as im:
                img = np.asarray(im.convert('RGB'))
            out = A.enhance(arm, img, a.root / 'src')
            if out.shape != img.shape:
                raise SystemExit(f'{arm}/{p}: {out.shape} is not the raw image\'s {img.shape}')
            dest.parent.mkdir(parents=True, exist_ok=True)
            tmp = dest.with_suffix('.tmp')
            Image.fromarray(out).save(tmp, 'JPEG', quality=90)
            tmp.replace(dest)
            made += 1
        print(arm, made, 'made', round(time.time() - t0, 1), 's', flush=True)
    cmd_lists(a)


def rows_for(root, arms, ids, prefix=''):
    out = []
    for arm in arms:
        for p in ids:
            f = image(root, arm, p)
            if f.exists():
                out.append({'id': f'{arm}/{p}', 'image': str(f), 'sha256': hashlib.sha256(f.read_bytes()).hexdigest(),
                            'set': 'owner99'})
    return out


def cmd_lists(a):
    sets = json.loads((a.root / 'pages.json').read_text())
    main = rows_for(a.root, MAIN, sets['pages'])
    atomic_jsonl(a.root / 'pages.jsonl', main)
    atomic_jsonl(a.root / 'glm' / 'pages.jsonl', main)
    regions = json.loads((a.root / 'regions' / 'pp-doclayoutv3.json').read_text())
    keyed = {'detector': regions['detector'],
             'pages': {r['id']: regions['pages'][r['id'].split('/')[1]] for r in main}}
    (a.root / 'glm' / 'regions').mkdir(parents=True, exist_ok=True)
    (a.root / 'glm' / 'regions' / 'pp-doclayoutv3.json').write_text(json.dumps(keyed) + '\n')
    probe = rows_for(a.root, PROBE, sets['probe'])
    atomic_jsonl(a.root / 'probe' / 'pages.jsonl', probe)
    print(len(main), 'main images,', len(probe), 'probe images', flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = {k: sub.add_parser(k) for k in ('routes', 'enhance', 'lists')}
    for x in s.values():
        x.add_argument('--root', type=Path, required=True)
    s['enhance'].add_argument('--arms', required=True)
    a = ap.parse_args()
    {'routes': cmd_routes, 'enhance': cmd_enhance, 'lists': cmd_lists}[a.cmd](a)


if __name__ == '__main__':
    main()
