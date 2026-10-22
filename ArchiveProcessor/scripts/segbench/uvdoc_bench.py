#!/usr/local/bin/python3
"""W46.enh-dewarp: the UVDoc benchmark (50 real photographs with flat truth) through our UVDoc and DocRes installs.

  V=~/Library/Caches/ArchiveSuiteRehearsal/enh-dewarp/venv/bin/python
  $V uvdoc_bench.py predict     # our UVDoc and DocRes outputs, in the layout uvdocBenchmark_pred.py writes
  $V uvdoc_bench.py score       # segbench-results/enh-dewarp-uvdoc-bench.md

Data (BENCH, not in git): UVDoc_benchmark.zip and the authors' UVDocBenchmark_results.zip, from
igl.ethz.ch/projects/uvdoc. The point is to confirm the installs before trusting them on our pages (D-enhancement §8),
so the first check is the grid itself: our UVDoc's 45 x 31 backward map against the one the authors published for the
same photograph. Then, for the published outputs, ours, DocRes's and the photograph left as it is:
  MS-SSIM by a Python port of the repo's evalUnwarp.m (rgb2gray, imresize bicubic, SSIM with MATLAB's defaults at
    five impyramid levels, the published weights), so the published row checks the port against 0.785;
  the repo's own line metric (uvdocBenchmark_metric.py, from the grids) and Tesseract CER (eval/ocr_eval, --oem 1;
    the Tesseract version differs from the paper's, so CER checks ours against the published outputs, not the paper).
AD and LD are not computed: both need SIFT flow under MATLAB, which neither this Mac nor FarmShare has. No money.
"""
from __future__ import annotations
import argparse
import json
import os
import statistics
import sys
from pathlib import Path

import cv2
import numpy as np

import enh_dewarp as E

BENCH = E.CACHE / 'uvdoc-bench'
DATA = BENCH / 'data' / 'UVDoc_benchmark'
PUBLISHED = BENCH / 'results' / 'UVDocBenchmark_results'
OURS = {'uvdoc': BENCH / 'ours-uvdoc', 'docres': BENCH / 'ours-docres', 'input': BENCH / 'input'}
OUT = E.RESULTS / 'enh-dewarp-uvdoc-bench.md'
UV = E.SRC / 'UVDoc'


def samples():
    return sorted(x.rsplit('.', 1)[0] for x in os.listdir(DATA / 'img'))


def unwarp(img, grid):
    """uvdocBenchmark_pred.py's bilinear_unwarping with a [-1, 1] grid (GH, GW, 2), on an RGB uint8 image."""
    import torch
    import torch.nn.functional as F
    h, w = img.shape[:2]
    g = torch.from_numpy(grid.transpose(2, 0, 1)).unsqueeze(0).float()
    up = F.interpolate(g, size=(h, w), mode='bilinear', align_corners=True)
    x = torch.from_numpy(img.transpose(2, 0, 1) / 255.).unsqueeze(0).float()
    out = F.grid_sample(x, up.permute(0, 2, 3, 1), align_corners=True)
    return (out[0].numpy().transpose(1, 2, 0) * 255).astype(np.uint8)


def predict():
    import hdf5storage as h5
    import torch
    import dewarp_arms as A
    A.uvdoc_arm(np.zeros((8, 8, 3), np.uint8), E.SRC)  # loads the model
    net = A._models['uvdoc']
    for s in samples():
        img = cv2.cvtColor(cv2.imread(str(DATA / 'img' / f'{s}.png')), cv2.COLOR_BGR2RGB)
        tex = cv2.cvtColor(cv2.imread(str(DATA / 'warped_textures' / f'{s}.png')), cv2.COLOR_BGR2RGB)
        grids = {}
        x = torch.from_numpy(cv2.resize(img.astype(np.float32) / 255, A.UVDOC_IN).transpose(2, 0, 1)).unsqueeze(0)
        with torch.no_grad():
            grids['uvdoc'] = net(x)[0][0].numpy().transpose(1, 2, 0)  # (45, 31, 2), x then y, in [-1, 1]
        # DocRes's map, normalised to the source, at 128 x 128 (the MBD grid's size), as a [-1, 1] grid
        _, g, _ = A.docres_arm(np.ascontiguousarray(img[..., ::-1]), E.SRC)
        h, w = img.shape[:2]
        u, v = np.meshgrid(np.linspace(0, 1, 128), np.linspace(0, 1, 128))
        dense = E.grid_eval(g, np.stack([u, v], -1))  # the 45 x 31 lattice at 128 x 128, corners aligned
        grids['docres'] = (dense * (w / (w - 1), h / (h - 1))) * 2 - 1
        grids['input'] = np.stack(np.meshgrid(np.linspace(-1, 1, 31), np.linspace(-1, 1, 45)), -1)
        for arm, grid in grids.items():
            d = OURS[arm]
            for sub in ('uwp_img', 'uwp_texture', 'bm'):
                (d / sub).mkdir(parents=True, exist_ok=True)
            cv2.imwrite(str(d / 'uwp_img' / f'{s}.png'), cv2.cvtColor(unwarp(img, grid), cv2.COLOR_RGB2BGR))
            cv2.imwrite(str(d / 'uwp_texture' / f'{s}.png'), cv2.cvtColor(unwarp(tex, grid), cv2.COLOR_RGB2BGR))
            h5.savemat(str(d / 'bm' / f'{s}.mat'), {'bm': grid.astype(np.float32)})
        print(s, flush=True)


def _ssim(x, y):
    """MATLAB ssim with its defaults: Gaussian window sigma 1.5 (radius 5), K = 0.01 / 0.03, range 255, and the mean
    over the whole map (skimage crops the border before its mean; MATLAB does not)."""
    from skimage.metrics import structural_similarity
    _, S = structural_similarity(x, y, data_range=255, gaussian_weights=True, sigma=1.5, use_sample_covariance=False,
                                 truncate=3.5, full=True)
    return float(S.mean())


def _reduce(im):
    """impyramid(im, 'reduce') on uint8: the 5-tap kernel with a = 0.375, replicate borders, every other sample,
    rounded back to uint8 as MATLAB keeps the class."""
    k = np.array([0.0625, 0.25, 0.375, 0.25, 0.0625])
    out = cv2.sepFilter2D(im.astype(np.float64), -1, k, k, borderType=cv2.BORDER_REPLICATE)
    return np.clip(np.round(out[::2, ::2]), 0, 255).astype(np.uint8)


def _gray(bgr):
    """rgb2gray: 0.2989 R + 0.5870 G + 0.1140 B, rounded to uint8."""
    b, g, r = (bgr[..., i].astype(np.float64) for i in range(3))
    return np.clip(np.round(0.2989 * r + 0.5870 * g + 0.1140 * b), 0, 255).astype(np.uint8)


def _imresize(im, w, h):
    """imresize(..., 'bicubic'): Pillow's bicubic is the same a = -0.5 kernel, widened when shrinking (antialiasing)."""
    from PIL import Image
    return np.asarray(Image.fromarray(im).resize((w, h), Image.Resampling.BICUBIC))


def ms_ssim(pred, ref):
    """evalScriptUVDoc.m + evalUnwarp.m: grey, the reference resized to 598,400 px, the prediction to the reference,
    then SSIM at five impyramid levels with the published weights."""
    r, x = _gray(ref), _gray(pred)
    f = np.sqrt(598400 / (r.shape[0] * r.shape[1]))
    r = _imresize(r, int(np.ceil(r.shape[1] * f)), int(np.ceil(r.shape[0] * f)))
    x = _imresize(x, r.shape[1], r.shape[0])
    total = 0.
    for w in [0.0448, 0.2856, 0.3001, 0.2363, 0.1333]:
        total += w * _ssim(x.astype(np.float64), r.astype(np.float64))
        x, r = _reduce(x), _reduce(r)
    return total


def score():
    import hdf5storage as h5
    sys.path.insert(0, str(UV))
    os.chdir(UV)  # the repo's modules import each other by bare name
    from uvdocBenchmark_metric import compute_line_metric
    from eval.ocr_eval.ocr_eval import OCR_eval_UVDoc
    ss = samples()
    diffs = []
    for s in ss:
        a = np.asarray(h5.loadmat(str(PUBLISHED / 'bm' / f'{s}.mat'))['bm'])
        b = np.asarray(h5.loadmat(str(OURS['uvdoc'] / 'bm' / f'{s}.mat'))['bm'])
        diffs.append(float(np.abs(a - b).max()))
    rows = {}
    for name, d in [('published UVDoc', PUBLISHED), ('our UVDoc', OURS['uvdoc']), ('our DocRes', OURS['docres']),
                    ('photograph as is', OURS['input'])]:
        ms = [ms_ssim(cv2.imread(str(d / 'uwp_texture' / f'{s}.png')), cv2.imread(str(DATA / 'texture_sample' / f'{s}.png')))
              for s in ss]
        compute_line_metric(str(DATA), str(d / 'bm'), 25)  # writes bm/line_metric_mean.json
        line = json.loads((d / 'bm' / 'line_metric_mean.json').read_text())
        hor, ver = line['hor'], line['ver']
        cer, ed, _ = OCR_eval_UVDoc(str(DATA / 'texture_sample'), str(d / 'uwp_texture'))
        rows[name] = (statistics.mean(ms), hor, ver, cer, ed)
        print(name, rows[name], flush=True)
    L = ['# W46.enh-dewarp: the UVDoc benchmark through our installs', '',
         'Generated by `scripts/segbench/uvdoc_bench.py score`; method in its docstring. 50 photographs.', '',
         f'Our UVDoc grid against the published one, largest absolute difference per photograph in [-1, 1] units: '
         f'median {statistics.median(diffs):.2e}, max {max(diffs):.2e} (one pixel of a 712 px side is 2.8e-03).', '',
         '| outputs | MS-SSIM (Python port) | line metric, horizontal | vertical | CER (Tesseract --oem 1) | ED |',
         '|---|---:|---:|---:|---:|---:|']
    for name, (ms, hor, ver, cer, ed) in rows.items():
        L.append(f'| {name} | {ms:.3f} | {hor:.3f} | {ver:.3f} | {cer:.3f} | {ed:.0f} |')
    L += ['', 'Published, full benchmark (README erratum): UVDoc MS-SSIM 0.785, AD 0.119. AD and LD are not computed '
          'here (SIFT flow under MATLAB).']
    OUT.write_text('\n'.join(L) + '\n')
    print(OUT)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('cmd', choices=['predict', 'score'])
    {'predict': predict, 'score': score}[ap.parse_args().cmd]()


if __name__ == '__main__':
    main()
