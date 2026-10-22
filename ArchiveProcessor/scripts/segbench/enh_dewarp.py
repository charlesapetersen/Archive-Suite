#!/usr/local/bin/python3
"""W46.enh-dewarp. Dewarp, crop or nothing, for the reading copy and for OCR, on the owner's truth pages.

  V=~/Library/Caches/ArchiveSuiteRehearsal/enh-dewarp/venv/bin/python
  $V enh_dewarp.py prepare      # Apple quads, then the arms' images and saved grids (quad, uvdoc, docres)
  $V enh_dewarp.py vision       # Apple Vision lines and word boxes on raw and on every arm
  $V enh_dewarp.py report       # segbench-results/enh-dewarp.md and enh-dewarp-pages.csv

Arms (dewarp_arms.py says how each is made): raw is the panel's frozen 2400 px / JPEG 90 image, the one every
saved route read; quad, uvdoc and docres are made from the full-resolution truth image and then frozen the same way
(2400 px ceiling, Pillow LANCZOS, JPEG 90), so only the geometry differs. Each arm keeps its backward map as a 45 x 31
lattice of source positions (grids/<arm>/<page>.npz); the edge-loss count and the line-box round trip are computed
from that lattice, because it is what a page would keep.

Measures, per arm against raw, on the 96 (the panel's 99 less its three agreement pages), originals and the PDF's
processed images apart:
  NES and the word rates of ocr_panel_score.score (the panel's scorer), Apple Vision as the reader;
  edge loss: truth words whose Vision box on the raw image has its centre outside the arm's frame (the lattice's
    outer ring carried into the source);
  the round trip of up to 20 line boxes per page read on the arm's image and carried back through the lattice:
    corner error against the same line's box read on the raw image (lines matched by text, ratio >= 90), the
    inversion error (back, then forward again by inverting the lattice), and the sagitta of the mapped baseline
    (the largest distance of the carried-back baseline from the straight chord between its ends: the error of a
    straight run drawn on the original), all in pixels of the 2400 px image;
  the line-curvature trigger: per page, the median over raw Vision lines of four or more words of the RMS distance
    of the words' bottom centres from their best straight line, in word heights, against each arm's NES gain.

Raw text and page images stay in CACHE; the committed results hold page ids and numbers only. No network, no money.
"""
from __future__ import annotations
import argparse
import collections
import csv
import json
import os
import statistics
import subprocess
import sys
from pathlib import Path

import numpy as np

import ocr_panel as P

CACHE = Path(os.environ.get('ENH_DEWARP_CACHE', Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/enh-dewarp'))
SRC = CACHE / 'src'  # UVDoc 4c9b82b5 and DocRes d3e3a18c clones, with weights (see the report's method)
BIN = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/segbench/bin/segbench-dewarp'
RESULTS = P.RESULTS
REPORT, PAGES = RESULTS / 'enh-dewarp.md', RESULTS / 'enh-dewarp-pages.csv'
ARMS = ('quad', 'uvdoc', 'docres')
SIDE = P.SIDE
MAX_LINES = 20


# ---------- geometry on a saved lattice (pure numpy, tested in test_enh_dewarp.py) ----------

def grid_eval(grid, uv):
    """Bilinear value of a (GH, GW, 2) lattice at output-normalised points uv (..., 2) in [0, 1]."""
    gh, gw = grid.shape[:2]
    uv = np.asarray(uv, float)
    x = np.clip(uv[..., 0], 0, 1) * (gw - 1)
    y = np.clip(uv[..., 1], 0, 1) * (gh - 1)
    x0 = np.clip(np.floor(x).astype(int), 0, gw - 2)
    y0 = np.clip(np.floor(y).astype(int), 0, gh - 2)
    fx, fy = (x - x0)[..., None], (y - y0)[..., None]
    a, b = grid[y0, x0], grid[y0, x0 + 1]
    c, d = grid[y0 + 1, x0], grid[y0 + 1, x0 + 1]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def invert(grid, xy, iters=30):
    """Output-normalised points whose lattice value is each source point xy (n, 2); Newton from the nearest point
    of a fine evaluation. Returns (uv, residual in source-normalised units)."""
    xy = np.asarray(xy, float).reshape(-1, 2)
    fu, fv = np.meshgrid(np.linspace(0, 1, 121), np.linspace(0, 1, 181))
    fine = np.stack([fu, fv], -1).reshape(-1, 2)
    vals = grid_eval(grid, fine)
    uv = fine[np.argmin(((vals[None] - xy[:, None]) ** 2).sum(-1), 1)].copy()
    e = 1e-4
    for _ in range(iters):
        f = grid_eval(grid, uv) - xy
        ju = (grid_eval(grid, uv + (e, 0)) - grid_eval(grid, uv - (e, 0))) / (2 * e)
        jv = (grid_eval(grid, uv + (0, e)) - grid_eval(grid, uv - (0, e))) / (2 * e)
        J = np.stack([ju, jv], -1)  # (n, 2 outputs, 2 inputs)
        det = J[:, 0, 0] * J[:, 1, 1] - J[:, 0, 1] * J[:, 1, 0]
        det = np.where(np.abs(det) < 1e-12, 1e-12, det)
        du = (J[:, 1, 1] * f[:, 0] - J[:, 0, 1] * f[:, 1]) / det
        dv = (-J[:, 1, 0] * f[:, 0] + J[:, 0, 0] * f[:, 1]) / det
        uv = np.clip(uv - np.stack([du, dv], -1), 0, 1)
    return uv, np.linalg.norm(grid_eval(grid, uv) - xy, axis=1)


def frame(grid):
    """The lattice's outer ring in source coordinates: the region of the source the arm's image shows."""
    return np.concatenate([grid[0, :], grid[1:, -1], grid[-1, -2::-1], grid[-2:0:-1, 0]])


def inside(poly, pts):
    """Even-odd ray test of points (n, 2) against a closed polygon (m, 2)."""
    pts = np.asarray(pts, float).reshape(-1, 2)
    x, y = pts[:, 0:1], pts[:, 1:2]
    a, b = poly, np.roll(poly, -1, 0)
    cross = (a[:, 1] > y) != (b[:, 1] > y)
    with np.errstate(divide='ignore', invalid='ignore'):
        xi = a[:, 0] + (y - a[:, 1]) * (b[:, 0] - a[:, 0]) / (b[:, 1] - a[:, 1])
    return ((cross & (x < xi)).sum(1) % 2) == 1


def foldovers(grid):
    """Lattice cells whose orientation flips (the map is not one-to-one there)."""
    du = grid[:-1, 1:] - grid[:-1, :-1]
    dv = grid[1:, :-1] - grid[:-1, :-1]
    return int(((du[..., 0] * dv[..., 1] - du[..., 1] * dv[..., 0]) <= 0).sum())


def sagitta(grid, p0, p1, scale, n=50):
    """Largest distance, in pixels at `scale` (w, h), of the carried-back segment p0-p1 from its chord."""
    t = np.linspace(0, 1, n)[:, None]
    pts = grid_eval(grid, np.asarray(p0) * (1 - t) + np.asarray(p1) * t) * scale
    a, b = pts[0], pts[-1]
    d = b - a
    L = np.hypot(*d)
    if L == 0:
        return 0.
    return float(np.abs(d[0] * (pts[:, 1] - a[1]) - d[1] * (pts[:, 0] - a[0])).max() / L)


def line_curvature(words, scale):
    """RMS distance of a line's word bottom centres from their total-least-squares line, in median word heights.
    None below four words."""
    if len(words) < 4:
        return None
    q = np.float64([w['quad'] for w in words]) * scale  # (n, 4 corners TL TR BR BL, 2)
    bottom = (q[:, 2] + q[:, 3]) / 2
    height = np.median(np.linalg.norm((q[:, 3] + q[:, 2]) / 2 - (q[:, 0] + q[:, 1]) / 2, axis=1))
    if height <= 0:
        return None
    c = bottom - bottom.mean(0)
    normal = np.linalg.svd(c, full_matrices=False)[2][-1]
    return float(np.sqrt(((c @ normal) ** 2).mean()) / height)


# ---------- runs ----------

def pages():
    return [r['page'] for r in P.rows()]


def source(page):
    return P.TRUTH / 'pages' / (page + '.jpg')


def raw_image(page):
    return P.CACHE / 'images' / (page + '-original.jpg')


def arm_image(arm, page):
    return raw_image(page) if arm == 'raw' else CACHE / 'images' / arm / (page + '.jpg')


def swift(mode, rows):
    jobs = CACHE / f'{mode}-jobs.tsv'
    jobs.write_text(''.join('\t'.join(map(str, r)) + '\n' for r in rows))
    subprocess.run([str(BIN), mode, str(jobs)], check=True)


def freeze(img, dest):
    """The panel's freezing (ocr_panel._prepare): RGB, 2400 px ceiling, LANCZOS, JPEG 90."""
    from PIL import Image
    im = Image.fromarray(img)
    im.thumbnail((SIDE, SIDE), Image.Resampling.LANCZOS)
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix('.tmp')
    im.save(tmp, 'JPEG', quality=90)
    tmp.replace(dest)


def prepare():
    import dewarp_arms as A
    from PIL import Image
    swift('quad', [(source(p), CACHE / 'quad' / (p + '.json')) for p in pages()])
    for p in pages():
        todo = [a for a in ARMS if not (CACHE / 'grids' / a / (p + '.npz')).exists()]
        if not todo:
            continue
        with Image.open(source(p)) as im:
            img = np.asarray(im.convert('RGB'))
        quad = json.loads((CACHE / 'quad' / (p + '.json')).read_text())
        for arm in todo:
            extra = {}
            if arm == 'quad':
                out, g, found = A.quad_arm(img, quad); extra['found'] = found
            elif arm == 'uvdoc':
                out, g, found = A.uvdoc_after_quad(img, quad, SRC); extra['found'] = found
            else:
                out, g, mask = A.docres_arm(np.ascontiguousarray(img[..., ::-1]), SRC)
                out = np.ascontiguousarray(out[..., ::-1]); extra['mask'] = mask
            freeze(out, arm_image(arm, p))
            dest = CACHE / 'grids' / arm / (p + '.npz')
            dest.parent.mkdir(parents=True, exist_ok=True)
            np.savez(dest, grid=g, out_w=out.shape[1], out_h=out.shape[0], src_w=img.shape[1], src_h=img.shape[0],
                     **extra)
        print(p, 'done', flush=True)


def vision():
    rows = [(arm_image(a, p), CACHE / 'lines' / a / (p + '.json')) for a in ('raw', *ARMS) for p in pages()]
    swift('lines', rows)


def load_lines(arm, page):
    d = json.loads((CACHE / 'lines' / arm / (page + '.json')).read_text())
    return d, '\n'.join(l['text'] for l in d['lines'])


def edge_loss(grid, raw_lines, truth_counts):
    import ocr_panel_score as S
    left = collections.Counter(truth_counts)
    poly = frame(grid)
    centres = []
    for line in raw_lines:
        for w in line['words']:
            t = S.tokens(w['text'])
            if len(t) == 1 and left[t[0]] > 0:
                left[t[0]] -= 1
                centres.append(np.float64(w['quad']).mean(0))
    if not centres:
        return 0, 0
    return int((~inside(poly, np.array(centres))).sum()), len(centres)


def round_trip(grid, arm_lines, raw_lines, scale_src, scale_out):
    from rapidfuzz import fuzz
    lines = sorted((l for l in arm_lines if len(l['text']) >= 10), key=lambda l: -len(l['text']))[:MAX_LINES]
    out = []
    for l in lines:
        q = np.float64(l['quad'])
        back = grid_eval(grid, q)
        uv, _ = invert(grid, back)
        row = {'inversion': float(np.linalg.norm((uv - q) * scale_out, axis=1).max()),
               'sagitta': sagitta(grid, q[3], q[2], scale_src),
               'height': float(np.linalg.norm(((back[3] + back[2]) - (back[0] + back[1])) / 2 * scale_src))}
        best = max(raw_lines, key=lambda r: fuzz.ratio(r['text'], l['text']), default=None)
        if best is not None and fuzz.ratio(best['text'], l['text']) >= 90:
            row['corner'] = float(np.linalg.norm((back - np.float64(best['quad'])) * scale_src, axis=1).mean())
        out.append(row)
    return out


def pctl(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))] if xs else float('nan')


def measure():
    import ocr_panel_score as S
    tags = {r['page']: r for r in json.loads((RESULTS / 'capture-tags.json').read_text())['pages']}
    rows, trips = [], collections.defaultdict(list)
    for r in P.rows():
        p = r['page']
        if p in P.AGREEMENT:
            continue
        truth = (P.TRUTH / 'truth' / (p + '.txt')).read_text()
        truth_counts = collections.Counter(S.tokens(S.normal(truth)))
        raw, raw_text = load_lines('raw', p)
        cached = (P.CACHE / 'vision' / (p + '-original.txt')).read_text()
        if raw_text != cached:
            raise SystemExit(f'{p}: segbench-dewarp lines differs from the panel\'s saved Vision text')
        scale = (raw['width'], raw['height'])
        curv = [c for l in raw['lines'] if (c := line_curvature(l['words'], scale)) is not None]
        base = {'page': p, 'source': 'original' if r['source'] == 'original' else 'pdf image', 'kind': r['kind'],
                'curvature': statistics.median(curv) if curv else '', 'curved_lines': len(curv),
                **{t: tags[p][t] for t in ('curl', 'perspective', 'edge_cut', 'neighbour')}}
        rows.append({**base, 'arm': 'raw', **S.score(truth, raw_text), 'edge_lost': 0, 'edge_words': ''})
        for arm in ARMS:
            d, text = load_lines(arm, p)
            z = np.load(CACHE / 'grids' / arm / (p + '.npz'))
            g = z['grid']
            lost, seen = edge_loss(g, raw['lines'], truth_counts)
            row = {**base, 'arm': arm, **S.score(truth, text), 'edge_lost': lost, 'edge_words': seen,
                   'found': bool(z['found']) if 'found' in z else '', 'mask': float(z['mask']) if 'mask' in z else '',
                   'foldovers': foldovers(g)}
            rt = round_trip(g, d['lines'], raw['lines'], scale, (d['width'], d['height']))
            for t in rt:
                trips[arm].append({**t, 'source': base['source'], 'curl': base['curl']})
            row['sagitta_max'] = max((t['sagitta'] for t in rt), default='')
            rows.append(row)
    return rows, trips


FIELDS = ['page', 'arm', 'source', 'kind', 'nes', 'words', 'hyp_words', 'missed', 'added', 'edge_lost', 'edge_words',
          'found', 'mask', 'foldovers', 'sagitta_max', 'curvature', 'curved_lines', 'curl', 'perspective', 'edge_cut',
          'neighbour']


def report():
    import ocr_panel_score as S
    from scipy.stats import spearmanr
    rows, trips = measure()
    with PAGES.open('w') as f:
        w = csv.DictWriter(f, FIELDS, extrasaction='ignore', lineterminator='\n')
        w.writeheader()
        for r in rows:
            w.writerow({k: (round(v, 6) if isinstance(v, float) else v) for k, v in r.items()})
    by = {(r['arm'], r['page']): r for r in rows}
    ids = sorted({r['page'] for r in rows})
    groups = {'96': ids, 'originals': [p for p in ids if by['raw', p]['source'] == 'original'],
              'PDF images': [p for p in ids if by['raw', p]['source'] != 'original']}
    tag_groups = {f'originals tagged {t}': [p for p in groups['originals'] if by['raw', p][t]]
                  for t in ('curl', 'perspective', 'edge_cut', 'neighbour')}
    L = ['# W46.enh-dewarp: dewarp, crop or nothing, on the truth pages', '',
         'Generated by `scripts/segbench/enh_dewarp.py report`; the method is in its docstring and in '
         '`dewarp_arms.py`. Reader: Apple Vision with the app\'s settings. Page-level numbers: `enh-dewarp-pages.csv`.', '',
         '## NES and words, each arm against raw', '',
         '| pages | n | arm | NES % | Δ NES vs raw (95% CI, p) | words added % | words missed % | edge-lost truth words (pages) |',
         '|---|---:|---|---:|---|---:|---:|---:|']
    for name, ps in {**groups, **tag_groups}.items():
        if not ps:
            continue
        for arm in ('raw', *ARMS):
            rr = [by[arm, p] for p in ps]
            nes = 100 * statistics.mean(r['nes'] for r in rr)
            hyp = sum(r['hyp_words'] for r in rr) or 1
            words = sum(r['words'] for r in rr) or 1
            if arm == 'raw':
                delta = '—'
            else:
                t = S.paired([by[arm, p]['nes'] for p in ps], [by['raw', p]['nes'] for p in ps])
                delta = f"{100 * t['delta']:+.1f} ({100 * t['lo']:+.1f} to {100 * t['hi']:+.1f}, p {t['p']:.3f})"
            lost = sum(r['edge_lost'] for r in rr)
            L.append(f"| {name} | {len(ps)} | {arm} | {nes:.1f} | {delta} | {100 * sum(r['added'] for r in rr) / hyp:.1f} | "
                     f"{100 * sum(r['missed'] for r in rr) / words:.1f} | {lost} ({sum(r['edge_lost'] > 0 for r in rr)}) |")
    found = sum(by['quad', p]['found'] for p in ids)
    L += ['', f'Apple\'s quad was found on {found} of {len(ids)} pages; where it was not, the quad arm is the raw image '
          'and UVDoc reads the raw image.', '',
          '## Line boxes carried back through the saved lattice', '',
          'Up to 20 of the longest lines a page reads on the arm\'s image; pixels of the 2400 px image. Corner error is '
          'against the same line read on the raw image, so it includes Vision\'s own box differences between the two '
          'readings; inversion is the round trip back and forward again.', '',
          '| arm | pages | lines | matched | corner error median / p95 | inversion p95 / max | sagitta median / p95 / max | lines with sagitta > 2 px | > ¼ line height | fold-over cells (pages) |',
          '|---|---|---:|---:|---|---|---|---:|---:|---:|']
    for arm in ARMS:
        for name in ('originals', 'PDF images'):
            src = 'original' if name == 'originals' else 'pdf image'
            tt = [t for t in trips[arm] if t['source'] == src]
            if not tt:
                continue
            corner = [t['corner'] for t in tt if 'corner' in t]
            sag = [t['sagitta'] for t in tt]
            inv = [t['inversion'] for t in tt]
            fold = [by[arm, p]['foldovers'] for p in groups[name]]
            L.append(f"| {arm} | {name} | {len(tt)} | {len(corner)} | {statistics.median(corner):.1f} / {pctl(corner, .95):.1f} | "
                     f"{pctl(inv, .95):.2f} / {max(inv):.2f} | {statistics.median(sag):.2f} / {pctl(sag, .95):.2f} / {max(sag):.1f} | "
                     f"{100 * sum(s > 2 for s in sag) / len(sag):.0f}% | "
                     f"{100 * sum(t['sagitta'] > t['height'] / 4 for t in tt) / len(tt):.0f}% | "
                     f"{sum(fold)} ({sum(f > 0 for f in fold)}) |")
    L += ['', '## The curvature trigger', '',
          'Per page, the raw image\'s line curvature (median RMS distance of word bottoms from a straight line, in '
          'word heights) against each arm\'s NES gain over raw, on the originals with at least three measurable lines.', '',
          '| arm | pages | Spearman ρ (p) | mean gain, curvature above median | mean gain, at or below |',
          '|---|---:|---|---:|---:|']
    cp = [p for p in groups['originals'] if by['raw', p]['curved_lines'] >= 3]
    if cp:
        med = statistics.median(by['raw', p]['curvature'] for p in cp)
        for arm in ARMS:
            gain = [by[arm, p]['nes'] - by['raw', p]['nes'] for p in cp]
            curv = [by['raw', p]['curvature'] for p in cp]
            rho, pv = spearmanr(curv, gain)
            hi = [g for g, c in zip(gain, curv) if c > med]
            lo = [g for g, c in zip(gain, curv) if c <= med]
            L.append(f'| {arm} | {len(cp)} | {rho:+.2f} ({pv:.3f}) | {100 * statistics.mean(hi):+.1f} | {100 * statistics.mean(lo):+.1f} |')
        L.append(f'\nMedian curvature {med:.3f} word heights.')
    REPORT.write_text('\n'.join(L) + '\n')
    print(REPORT)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('cmd', choices=['prepare', 'vision', 'report'])
    a = ap.parse_args()
    {'prepare': prepare, 'vision': vision, 'report': report}[a.cmd]()


if __name__ == '__main__':
    sys.exit(main())
