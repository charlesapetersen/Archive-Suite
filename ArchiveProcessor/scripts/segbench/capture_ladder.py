#!/usr/bin/env python3
"""W46.capture-ladder, the 96 at every setting (L tests 2, 3): which capture defect costs which reader how much.

    python3 capture_ladder.py make --out DIR     # on the Mac: the defect images and pages.jsonl; no model call

The source is the panel's own original-scale image of each of the 99 owner pages (ocr-panel-local/images/
<page>-original.jpg, the file every scored route and the dewarp run read), so the dewarp run's raw readings are each
reader's no-defect baseline. Each image is degraded by one defect at one setting, deterministically (seed 46):

  Augraphy    ShadowCast, LightingGradient, ReflectedLight, LowLightNoise (one setting each, the library's defaults)
  OpenCV      motion blur 9 / 17 / 31 px, defocus (Gaussian) sigma 1.5 / 3 / 5, perspective tilt 5 / 12 / 20 degrees
  JPEG        quality 60 / 75 / 85

16 variants x 99 pages. The pack is read on the cluster by dewarp_cluster.py, unchanged, with the dewarp run's
routes (Qwen3.6-27B and LightOnOCR-3 4B, the open sweep's prompts and server arguments). Not in this pass: the 895
subset, GLM-OCR on regions, Apple Vision on the Mac, the quality verdicts, the capture-time signals and SmartDoc-QA.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
SEED = 46
CACHE = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
SRC = CACHE / 'ocr-panel-local/images'


def variants():
    v = [(f'aug-{n}', n) for n in ('ShadowCast', 'LightingGradient', 'ReflectedLight', 'LowLightNoise')]
    v += [(f'motion-{k}', k) for k in (9, 17, 31)] + [(f'defocus-{s}', s) for s in (1.5, 3, 5)]
    v += [(f'tilt-{d}', d) for d in (5, 12, 20)] + [(f'jpeg-{q}', q) for q in (60, 75, 85)]
    return v


def degrade(name, arg, rgb, rng):
    """`rgb`: an HxWx3 uint8 array; returns (array or None, jpeg quality)."""
    import cv2
    import numpy as np
    if name.startswith('aug-'):
        import augraphy
        np.random.seed(rng.randrange(2**31)); random.seed(rng.randrange(2**31))
        out = getattr(augraphy, arg)()(rgb)
        return np.ascontiguousarray(out[..., :3] if out.ndim == 3 else np.stack([out] * 3, -1)), 92
    if name.startswith('motion-'):
        k = np.zeros((arg, arg), np.float32); k[arg // 2, :] = 1.0 / arg
        return cv2.filter2D(rgb, -1, k, borderType=cv2.BORDER_REPLICATE), 92
    if name.startswith('defocus-'):
        return cv2.GaussianBlur(rgb, (0, 0), sigmaX=arg, sigmaY=arg, borderType=cv2.BORDER_REPLICATE), 92
    if name.startswith('tilt-'):
        h, w = rgb.shape[:2]; f = max(h, w); t = math.radians(arg)
        K = np.array([[f, 0, w / 2], [0, f, h / 2], [0, 0, 1]], np.float64)
        R = np.array([[1, 0, 0], [0, math.cos(t), -math.sin(t)], [0, math.sin(t), math.cos(t)]])
        H = K @ R @ np.linalg.inv(K)
        corners = np.array([[0, 0, 1], [w, 0, 1], [w, h, 1], [0, h, 1]], np.float64).T
        c = H @ corners; c = c[:2] / c[2]
        T = np.array([[1, 0, -c[0].min()], [0, 1, -c[1].min()], [0, 0, 1]])
        size = (int(math.ceil(c[0].max() - c[0].min())), int(math.ceil(c[1].max() - c[1].min())))
        return cv2.warpPerspective(rgb, T @ H, size, borderMode=cv2.BORDER_CONSTANT, borderValue=(255, 255, 255)), 92
    if name.startswith('jpeg-'):
        return rgb, int(arg)
    raise ValueError(name)


def cmd_make(a):
    import numpy as np
    from PIL import Image
    import ocr_panel as P
    pages = [r['page'] for r in P.rows()]
    out = a.out; rows = []
    for name, arg in variants():
        d = out / 'images' / name; d.mkdir(parents=True, exist_ok=True)
        for p in pages:
            dst = d / f'{p}.jpg'
            if not dst.exists():
                rng = random.Random(f'{SEED}/{name}/{p}')
                with Image.open(SRC / f'{p}-original.jpg') as im:
                    rgb = np.asarray(im.convert('RGB'))
                arr, q = degrade(name, arg, rgb, rng)
                im = Image.fromarray(arr)
                im.thumbnail((2400, 2400), Image.Resampling.LANCZOS)   # the panel's ceiling, after the warp
                im.save(dst, 'JPEG', quality=q)
            rows.append({'id': f'{name}/{p}', 'image': f'{a.remote}/images/{name}/{p}.jpg',
                         'sha256': hashlib.sha256(dst.read_bytes()).hexdigest()})
        print(name, len(pages), flush=True)
    (out / 'pages.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
    (out / 'pack.json').write_text(json.dumps({'variants': [n for n, _ in variants()], 'pages': len(pages),
                                               'images': len(rows), 'seed': SEED, 'source': str(SRC)}, indent=1) + '\n')
    print(len(rows), 'images ->', out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('make'); p.add_argument('--out', type=Path, required=True)
    p.add_argument('--remote', default='/scratch/users/cp1/fs-ocr/capture-ladder-20261022')
    a = ap.parse_args()
    {'make': cmd_make}[a.cmd](a)


if __name__ == '__main__':
    main()
