#!/usr/local/bin/python3
"""W46.enh-dewarp. Dewarp, crop or nothing, for the reading copy and for OCR, on the owner's truth pages.

  V=~/Library/Caches/ArchiveSuiteRehearsal/enh-dewarp/venv/bin/python
  $V enh_dewarp.py prepare      # Apple quads, then the arms' images and saved grids (quad, uvdoc, docres)
  $V enh_dewarp.py extras       # hand crops, the app's encoder at three settings, dewarp-then-quarter on the ladder
  $V enh_dewarp.py vision       # Apple Vision lines and word boxes on raw and on every arm
  $V enh_dewarp.py stage        # the FarmShare pack (corpus/dewarp-submit.sh runs it there)
  $V enh_dewarp.py fetch        # the FarmShare readings back, then report again
  $V enh_dewarp.py report       # segbench-results/enh-dewarp.md and enh-dewarp-pages.csv

Arms (dewarp_arms.py says how each is made): raw is the panel's frozen 2400 px / JPEG 90 image, the one every
saved route read; quad, uvdoc and docres are made from the full-resolution truth image and then frozen the same way
(2400 px ceiling, Pillow LANCZOS, JPEG 90), so only the geometry differs. Each arm keeps its backward map as a 45 x 31
lattice of source positions (grids/<arm>/<page>.npz); the edge-loss count and the line-box round trip are computed
from that lattice, because it is what a page would keep.

Measures, per arm against raw, on the 96 (the panel's 99 less its three agreement pages), originals and the PDF's
processed images apart:
  NES and the word rates of ocr_panel_score.score (the panel's scorer), Apple Vision as the reader;
  edge loss: truth words whose Vision box on the raw image has its centre in no cell of the arm's lattice carried
    into the source (a cell test, not the outer ring: a folding map's ring crosses itself);
  the round trip of up to 20 line boxes per page read on the arm's image and carried back through the lattice:
    corner error against the same line's box read on the raw image (lines matched by text, ratio >= 90) and the
    sagitta of the mapped baseline (the largest distance of the carried-back baseline from the straight chord
    between its ends: the error of a straight run drawn on the original), in pixels of the 2400 px image;
  the curvature trigger: two reference-free bend signals per page (angle_residual, lattice_bend) against each arm's
    NES gain.

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


def frame(grid):
    """The lattice's outer ring in source coordinates: the region of the source the arm's image shows."""
    return np.concatenate([grid[0, :], grid[1:, -1], grid[-1, -2::-1], grid[-2:0:-1, 0]])


def covered(grid, pts):
    """Points (n, 2) inside at least one lattice cell carried into the source. Unlike the outer ring this stays
    right where the map folds over itself."""
    pts = np.asarray(pts, float).reshape(-1, 2)
    a, b, c, d = grid[:-1, :-1], grid[:-1, 1:], grid[1:, 1:], grid[1:, :-1]
    cells = np.stack([a, b, c, d], -2).reshape(-1, 4, 2)
    hit = np.zeros(len(pts), bool)
    for k in range(0, len(cells), 256):
        q = cells[k:k + 256]
        lo, hi = q.min(1), q.max(1)
        near = ((pts[:, None] >= lo[None]) & (pts[:, None] <= hi[None])).all(-1)  # (n, cells): bounding boxes
        for i, j in zip(*np.nonzero(near & ~hit[:, None])):
            if not hit[i] and inside(q[j], pts[i:i + 1])[0]:
                hit[i] = True
    return hit


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


def angle_residual(lines, scale, min_width=0.25, min_lines=5):
    """Vision's reference-free bend signal. Vision's word boxes are cut from their line's quad (every word bottom
    lies on the line's bottom edge, measured), so no line shows a curve of its own; what a curl changes is the
    angle of whole lines across the page. Fit each wide line's baseline angle as a + b x + c y (a camera's tilt
    or perspective varies that smoothly) and return the RMS residual in degrees; None with too few wide lines."""
    pts = []
    for l in lines:
        q = np.float64(l['quad']) * scale
        d = q[2] - q[3]
        if np.hypot(*d) < min_width * scale[0]:
            continue
        c = q.mean(0) / scale
        pts.append((c[0], c[1], np.degrees(np.arctan2(d[1], d[0]))))
    if len(pts) < min_lines:
        return None
    a = np.array(pts)
    X = np.column_stack([np.ones(len(a)), a[:, 0], a[:, 1]])
    coef = np.linalg.lstsq(X, a[:, 2], rcond=None)[0]
    return float(np.sqrt(((a[:, 2] - X @ coef) ** 2).mean()))


def lattice_bend(grid, scale):
    """The dewarper's own bend estimate: the median, over the lattice's rows, of each row's sagitta in pixels at
    `scale`. A homography leaves rows straight, so this is the non-projective part of the map."""
    out = []
    for row in grid:
        pts = row * scale
        a, b = pts[0], pts[-1]
        d = b - a
        L = np.hypot(*d)
        if L:
            out.append(np.abs(d[0] * (pts[:, 1] - a[1]) - d[1] * (pts[:, 0] - a[0])).max() / L)
    return float(np.median(out)) if out else 0.


# ---------- runs ----------

def pages():
    return [r['page'] for r in P.rows()]


def source(page):
    return P.TRUTH / 'pages' / (page + '.jpg')


def raw_image(page):
    return P.CACHE / 'images' / (page + '-original.jpg')


def arm_image(arm, page):
    if arm == 'raw':
        return raw_image(page)
    if arm == 'quarter':
        return P.CACHE / 'images' / (page + '-quarter.jpg')
    return CACHE / 'images' / arm / (page + '.jpg')


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


# L test 4: the six typed originals with the lowest median NES over the 29 saved routes (ocr-pages.csv), cropped
# to the page by eye (Claude Opus 5.5 looking at each at 900 px with a 10% grid, 2026-10-22), as normalised
# x0, y0, x1, y1. p024 and p001 fill the frame edge to edge, so they have no crop: scope is not their loss.
HAND = {
    'p013': (0.0, 0.0, 1.0, 0.985),     # wood below the page's foot
    'p100': (0.045, 0.0, 1.0, 1.0),     # the binding strip at the left
    'p066': (0.0, 0.03, 0.955, 1.0),    # the tabbed pages and a neighbour's heading at the right
    'p069': (0.0, 0.03, 0.975, 0.955),  # a sticky note above, the archive's copyright slip below
    'p024': None, 'p001': None,
}
# L test 5: the app's encoder (ImageEncoding.loadImageAsJPEG, copied into segbench-dewarp) at the app's settings,
# at the bench's size and quality, and at the segmentation window's 1,600 px.
ENCODINGS = {'enc-2048-q85': (2048, 0.85), 'enc-2400-q90': (2400, 0.90), 'enc-1600-q90': (1600, 0.90)}
LADDER_ARMS = ('quad-quarter', 'uvdoc-quarter')  # D test 6: dewarp the full image, then make the quarter rung


def ladder_pages():
    return sorted(set(json.loads((P.TRUTH / 'ladder.json').read_text())) - P.AGREEMENT)


def extra_jobs():
    """(arm, page) for every image the extras add."""
    return ([('hand', p) for p, box in HAND.items() if box] + [(a, p) for a in ENCODINGS for p in pages()]
            + [(a, p) for a in LADDER_ARMS for p in ladder_pages()] + [('quarter', p) for p in ladder_pages()])


def quarter(img):
    """ocr_truth.py's quarter rung (LANCZOS to a quarter, JPEG 92), as an array the panel's freezing then takes."""
    import io
    from PIL import Image
    im = Image.fromarray(img)
    buf = io.BytesIO()
    im.resize((im.width // 4, im.height // 4), Image.LANCZOS).save(buf, 'JPEG', quality=92)
    return np.asarray(Image.open(buf).convert('RGB'))


def prepare_extras():
    import dewarp_arms as A
    from PIL import Image
    swift('encode', [(source(p), arm_image(a, p), cap, q) for a, (cap, q) in ENCODINGS.items() for p in pages()])
    for p, box in HAND.items():
        if box and not arm_image('hand', p).exists():
            with Image.open(source(p)) as im:
                w, h = im.size
                img = np.asarray(im.convert('RGB').crop((round(box[0] * w), round(box[1] * h),
                                                         round(box[2] * w), round(box[3] * h))))
            freeze(img, arm_image('hand', p))
    for p in ladder_pages():
        if all(arm_image(a, p).exists() for a in LADDER_ARMS):
            continue
        with Image.open(source(p)) as im:
            img = np.asarray(im.convert('RGB'))
        quad = json.loads((CACHE / 'quad' / (p + '.json')).read_text())
        freeze(quarter(A.quad_arm(img, quad)[0]), arm_image('quad-quarter', p))
        freeze(quarter(A.uvdoc_after_quad(img, quad, SRC)[0]), arm_image('uvdoc-quarter', p))


FS_ROOT = '/scratch/users/cp1/fs-ocr/dewarp-20261022'
CLUSTER_ARMS = ('raw', *ARMS, 'enc-2048-q85', 'enc-1600-q90')  # enc-2400-q90 is raw's size and quality


def cluster_jobs():
    """Every image the FarmShare readers get: the 96 in each arm, then the hand crops and the ladder's quarters."""
    ids = [p for p in pages() if p not in P.AGREEMENT]
    return [(a, p) for a in CLUSTER_ARMS for p in ids] + [j for j in extra_jobs() if j[0] in ('hand', 'quarter', *LADDER_ARMS)]


def stage():
    """CACHE/stage: the images under <arm>/<page>.jpg and pages.jsonl with their FarmShare paths, ready to copy to
    FS_ROOT with the two corpus scripts and routes.json (the regions run's, for the two vLLM readers)."""
    import hashlib
    import shutil
    out = CACHE / 'stage'
    rows = []
    for arm, p in cluster_jobs():
        src = arm_image(arm, p)
        dst = out / 'images' / arm / (p + '.jpg')
        dst.parent.mkdir(parents=True, exist_ok=True)
        if not dst.exists():
            shutil.copyfile(src, dst)
        rows.append({'id': f'{arm}/{p}', 'image': f'{FS_ROOT}/images/{arm}/{p}.jpg',
                     'sha256': hashlib.sha256(dst.read_bytes()).hexdigest()})
    (out / 'pages.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
    print(len(rows), 'images ->', out)


FETCHED = CACHE / 'farmshare-out'  # a copy of FS_ROOT/out
READERS = {'qwen3.6-27b': 'panel', 'lightonocr3-4b': 'native', 'ppocrv6': 'pipeline'}  # ocr_rescore.py's modes


def fetch():
    """Copy FS_ROOT/out to FETCHED over the owner's FarmShare socket (execution-plans/farmshare-access.md)."""
    sock = Path.home() / '.ssh/cm-farmshare'
    FETCHED.mkdir(parents=True, exist_ok=True)
    subprocess.run(['gtimeout', '--foreground', '1800', 'scp', '-q', '-r', '-o', f'ControlPath={sock}',
                    '-o', 'ControlMaster=no', '-o', 'BatchMode=yes', '-o', 'ProxyCommand=false',
                    f'cp1@login.farmshare.stanford.edu:{FS_ROOT}/out/.', str(FETCHED)], check=True)
    print(FETCHED)


def cluster_rows():
    """Per reader, {(arm, page): score row} from the fetched records; a missing or failed reading scores empty."""
    sys.path.insert(0, str(Path(__file__).resolve().parent / 'corpus'))
    import farmshare_expanded_report as X
    import ocr_panel_score as S
    out = {}
    for route, mode in READERS.items():
        if not (FETCHED / route).exists():
            continue
        by = {}
        for arm, p in cluster_jobs():
            f = FETCHED / route / arm / (p + '.json')
            rec = json.loads(f.read_text()) if f.exists() else None
            truth = (P.TRUTH / 'truth' / (p + '.txt')).read_text()
            by[arm, p] = {'page': p, 'arm': arm, 'reader': route, 'read': rec is not None,
                          **S.score(truth, X.reading(rec, mode))}
        out[route] = by
    return out


def vision():
    rows = [(arm_image(a, p), CACHE / 'lines' / a / (p + '.json')) for a in ('raw', *ARMS) for p in pages()]
    rows += [(arm_image(a, p), CACHE / 'lines' / a / (p + '.json')) for a, p in extra_jobs()]
    swift('lines', [r for r in rows if r[0].exists()])


def load_lines(arm, page):
    d = json.loads((CACHE / 'lines' / arm / (page + '.json')).read_text())
    return d, '\n'.join(l['text'] for l in d['lines'])


def truth_words(raw_lines, truth_tokens):
    """Centres of the raw reading's words that align to the truth's word sequence (difflib's matching blocks),
    so a neighbouring page's 'the' is not taken for one of the page's own."""
    import difflib
    import ocr_panel_score as S
    words = [(t[0], np.float64(w['quad']).mean(0)) for line in raw_lines for w in line['words']
             if len(t := S.tokens(w['text'])) == 1]
    sm = difflib.SequenceMatcher(None, [t for t, _ in words], truth_tokens, autojunk=False)
    return np.array([words[b.a + k][1] for b in sm.get_matching_blocks() for k in range(b.size)]).reshape(-1, 2)


def edge_loss(grid, centres):
    if not len(centres):
        return 0
    return int((~covered(grid, centres)).sum())


def round_trip(grid, arm_lines, raw_lines, scale_src):
    from rapidfuzz import fuzz
    lines = sorted((l for l in arm_lines if len(l['text']) >= 10), key=lambda l: -len(l['text']))[:MAX_LINES]
    out = []
    for l in lines:
        q = np.clip(np.float64(l['quad']), 0, 1)  # Vision's quads can overhang the image by a hair
        back = grid_eval(grid, q)
        row = {'sagitta': sagitta(grid, q[3], q[2], scale_src),
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
        raw, raw_text = load_lines('raw', p)
        cached = (P.CACHE / 'vision' / (p + '-original.txt')).read_text()
        if raw_text != cached:
            raise SystemExit(f'{p}: segbench-dewarp lines differs from the panel\'s saved Vision text')
        scale = (raw['width'], raw['height'])
        centres = truth_words(raw['lines'], S.tokens(S.normal(truth)))
        bend = angle_residual(raw['lines'], scale)
        base = {'page': p, 'source': 'original' if r['source'] == 'original' else 'pdf image', 'kind': r['kind'],
                'angle_residual': '' if bend is None else bend,
                'uvdoc_bend': lattice_bend(np.load(CACHE / 'grids/uvdoc' / (p + '.npz'))['grid'], scale),
                **{t: tags[p][t] for t in ('curl', 'perspective', 'edge_cut', 'neighbour')}}
        rows.append({**base, 'arm': 'raw', **S.score(truth, raw_text), 'edge_lost': 0, 'edge_words': len(centres)})
        for arm in ARMS:
            d, text = load_lines(arm, p)
            z = np.load(CACHE / 'grids' / arm / (p + '.npz'))
            g = z['grid']
            row = {**base, 'arm': arm, **S.score(truth, text), 'edge_lost': edge_loss(g, centres),
                   'edge_words': len(centres),
                   'found': bool(z['found']) if 'found' in z else '', 'mask': float(z['mask']) if 'mask' in z else '',
                   'foldovers': foldovers(g)}
            rt = round_trip(g, d['lines'], raw['lines'], scale)
            for t in rt:
                trips[arm].append({**t, 'source': base['source'], 'curl': base['curl']})
            row['sagitta_max'] = max((t['sagitta'] for t in rt), default='')
            rows.append(row)
    return rows, trips


FIELDS = ['page', 'arm', 'source', 'kind', 'nes', 'chrf', 'words', 'hyp_words', 'missed', 'added', 'edge_lost', 'edge_words',
          'found', 'mask', 'foldovers', 'sagitta_max', 'angle_residual', 'uvdoc_bend', 'curl', 'perspective',
          'edge_cut', 'neighbour']


def arm_table(by, groups, arms, base, edge=False):
    import ocr_panel_score as S

    def delta(key, arm, ps):
        t = S.paired([by[arm, p][key] for p in ps], [by[base, p][key] for p in ps])
        return f"{100 * t['delta']:+.1f} ({100 * t['lo']:+.1f} to {100 * t['hi']:+.1f}, p {t['p']:.3f})"
    L = [f'| pages | n | arm | NES % | Δ NES vs {base} | chrF2 % | Δ chrF2 | words added % | words missed % |'
         + (' edge-lost truth words (pages) |' if edge else ''),
         '|---|---:|---|---:|---|---:|---|---:|---:|' + ('---:|' if edge else '')]
    for name, ps in groups.items():
        if not ps:
            continue
        for arm in arms:
            rr = [by[arm, p] for p in ps]
            hyp = sum(r['hyp_words'] for r in rr) or 1
            words = sum(r['words'] for r in rr) or 1
            d_nes, d_chrf = ('—', '—') if arm == base else (delta('nes', arm, ps), delta('chrf', arm, ps))
            row = (f"| {name} | {len(ps)} | {arm} | {100 * statistics.mean(r['nes'] for r in rr):.1f} | {d_nes} | "
                   f"{100 * statistics.mean(r['chrf'] for r in rr):.1f} | {d_chrf} | "
                   f"{100 * sum(r['added'] for r in rr) / hyp:.1f} | {100 * sum(r['missed'] for r in rr) / words:.1f} |")
            if edge:
                row += f" {sum(r['edge_lost'] for r in rr)} ({sum(r['edge_lost'] > 0 for r in rr)}) |"
            L.append(row)
    return L


def arm_summary(by, groups, arms, base, reader):
    """arm_table's figures as rows for ArchiveOCRBench (enh-dewarp.json)."""
    import ocr_panel_score as S
    out = []
    for name, ps in groups.items():
        for arm in arms:
            rr = [by[arm, p] for p in ps]
            if not rr:
                continue
            row = {'reader': reader, 'pages': name, 'n': len(ps), 'arm': arm, 'base': base,
                   'nes': statistics.mean(r['nes'] for r in rr), 'chrf': statistics.mean(r['chrf'] for r in rr),
                   'added': sum(r['added'] for r in rr) / (sum(r['hyp_words'] for r in rr) or 1),
                   'missed': sum(r['missed'] for r in rr) / (sum(r['words'] for r in rr) or 1)}
            if 'edge_lost' in rr[0]:
                row['edge_lost'], row['edge_pages'] = sum(r['edge_lost'] for r in rr), sum(r['edge_lost'] > 0 for r in rr)
            if arm != base:
                t = S.paired([by[arm, p]['nes'] for p in ps], [by[base, p]['nes'] for p in ps])
                row.update(d_nes=t['delta'], lo=t['lo'], hi=t['hi'], p=t['p'])
            out.append({k: round(v, 5) if isinstance(v, float) else v for k, v in row.items()})
    return out


def extra_rows():
    """Scores for the extras' images (text only, no lattice)."""
    import ocr_panel_score as S
    out = []
    for arm, p in extra_jobs():
        f = CACHE / 'lines' / arm / (p + '.json')
        if not f.exists():
            continue
        truth = (P.TRUTH / 'truth' / (p + '.txt')).read_text()
        out.append({'page': p, 'arm': arm, **S.score(truth, load_lines(arm, p)[1])})
    return out


def report():
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
         'NES follows reading order, so a page whose lines Vision orders differently on a near-identical image can '
         'swing by tens of points (p008, a flat PDF image the quad leaves whole, is one); chrF and the word rates '
         'do not depend on order. Δ is paired by page: the mean, a 95% bootstrap interval and a permutation p.', '']
    L += arm_table(by, {**groups, **tag_groups}, ('raw', *ARMS), 'raw', edge=True)
    found = sum(by['quad', p]['found'] for p in ids)
    L += ['', f'Apple\'s quad was found on {found} of {len(ids)} pages; where it was not, the quad arm is the raw image '
          'and UVDoc reads the raw image.', '',
          '## Line boxes carried back through the saved lattice', '',
          'Up to 20 of the longest lines a page reads on the arm\'s image; pixels of the 2400 px image. Corner error is '
          'against the same line read on the raw image, so it includes Vision\'s own box differences between the two '
          "readings. DocRes's map folds faster than the lattice's spacing on about 14 pages (checked once against its "
          'dense map, recomputed: per-page p95 above 50 px there, median 0.4 px elsewhere), so on those pages its rows '
          'and its edge loss describe its lattice, not the image Vision read; its NES and word figures are unaffected.',
          '',
          '| arm | pages | lines | matched | corner error median / p95 | sagitta median / p95 / max | lines with sagitta > 2 px | > ¼ line height | fold-over cells (pages) |',
          '|---|---|---:|---:|---|---|---:|---:|---:|']
    for arm in ARMS:
        for name in ('originals', 'PDF images'):
            src = 'original' if name == 'originals' else 'pdf image'
            tt = [t for t in trips[arm] if t['source'] == src]
            if not tt:
                continue
            corner = [t['corner'] for t in tt if 'corner' in t]
            sag = [t['sagitta'] for t in tt]
            fold = [by[arm, p]['foldovers'] for p in groups[name]]
            L.append(f"| {arm} | {name} | {len(tt)} | {len(corner)} | {statistics.median(corner):.1f} / {pctl(corner, .95):.1f} | "
                     f"{statistics.median(sag):.2f} / {pctl(sag, .95):.2f} / {max(sag):.1f} | "
                     f"{100 * sum(s > 2 for s in sag) / len(sag):.0f}% | "
                     f"{100 * sum(t['sagitta'] > t['height'] / 4 for t in tt) / len(tt):.0f}% | "
                     f"{sum(fold)} ({sum(f > 0 for f in fold)}) |")
    L += ['', '## The curvature trigger', '',
          'Vision gives no curvature inside a line: its word boxes are cut from the line\'s quad (every word\'s bottom '
          'centre lies within 1 px of its line\'s bottom edge on the raw images). Two signals stand in, each against '
          'each arm\'s NES gain over raw on the originals: the RMS residual, in degrees, of wide lines\' baseline '
          'angles after a fit linear in the line\'s position (what perspective alone produces), and UVDoc\'s own '
          'bend, the median sagitta of its lattice\'s rows in pixels of the 2400 px image.', '',
          '| signal | arm | pages | Spearman ρ (p) | mean gain, signal above median | mean gain, at or below |',
          '|---|---|---:|---|---:|---:|']
    for sig, unit in (('angle_residual', '°'), ('uvdoc_bend', ' px')):
        cp = [p for p in groups['originals'] if by['raw', p][sig] != '']
        if len(cp) < 5:
            continue
        x = [by['raw', p][sig] for p in cp]
        med = statistics.median(x)
        for arm in ARMS:
            gain = [by[arm, p]['nes'] - by['raw', p]['nes'] for p in cp]
            rho, pv = spearmanr(x, gain)
            hi = [g for g, c in zip(gain, x) if c > med]
            lo = [g for g, c in zip(gain, x) if c <= med]
            L.append(f'| {sig} (median {med:.2f}{unit}) | {arm} | {len(cp)} | {rho:+.2f} ({pv:.3f}) | '
                     f'{100 * statistics.mean(hi):+.1f} | {100 * statistics.mean(lo):+.1f} |')
    ex = extra_rows()
    for r in ex:
        by[r['arm'], r['page']] = r
    with PAGES.open('a') as f:
        w = csv.DictWriter(f, FIELDS, extrasaction='ignore', lineterminator='\n')
        for r in ex:
            w.writerow({k: (round(v, 6) if isinstance(v, float) else v) for k, v in r.items()})
    hand = [p for p, box in HAND.items() if box and ('hand', p) in by]
    if hand:
        L += ['', '## Hand crops of the six worst typed originals', '',
              'The page cropped by eye (`HAND` in the script) against raw and the two automatic crops. '
              + ', '.join(p for p, box in HAND.items() if not box) + ' fill the frame and have no crop.', '']
        L += arm_table(by, {'hand-cropped': hand}, ('raw', 'quad', 'uvdoc', 'hand'), 'raw')
        L += ['', '| page | raw NES | quad | uvdoc | hand |', '|---|---:|---:|---:|---:|']
        L += [f"| {p} | " + ' | '.join(f"{100 * by[a, p]['nes']:.1f}" for a in ('raw', 'quad', 'uvdoc', 'hand')) + ' |'
              for p in hand]
    if all((a, p) in by for a in ENCODINGS for p in ids):
        L += ['', "## The app's encoding", '',
              "Each through the app's own encoder (ImageEncoding.loadImageAsJPEG, copied into segbench-dewarp): the "
              "app's 2048 px at quality 0.85, the bench's 2400 at 0.90 and the segmentation window's 1,600 at 0.90, "
              "against raw, the panel's Pillow 2400 px JPEG 90.", '']
        L += arm_table(by, groups, ('raw', *ENCODINGS), 'raw')
    lad = [p for p in ladder_pages() if all((a, p) in by for a in ('quarter', *LADDER_ARMS))]
    if lad:
        L += ['', '## Dewarp before downscaling, the ladder pages', '',
              'The quarter rung made from the quad crop or the UVDoc image of the full photograph, against the '
              "panel's quarter rung of the raw photograph (both LANCZOS to a quarter, JPEG 92, then the panel's "
              'freezing); the original size for reference.', '']
        L += arm_table(by, {'ladder': lad}, ('quarter', *LADDER_ARMS, 'raw'), 'quarter')
    readers = cluster_rows()
    if readers:
        L += ['', '## Open readers on FarmShare', '',
              "Qwen3.6-27B (the panel prompt), LightOnOCR-3 4B (its own prompt, plain text) and PP-OCRv6 (truth96's "
              'pinned native pipeline), each reading every image above as it is, raw included, in one run '
              f'(`corpus/dewarp_cluster.py`, {FS_ROOT}). An image with no reading, or a failed one, scores empty.', '']
        cluster = RESULTS / 'enh-dewarp-farmshare.csv'
        with cluster.open('w') as f:
            w = csv.DictWriter(f, ['reader', 'arm', 'page', 'read', 'nes', 'chrf', 'words', 'hyp_words', 'missed', 'added'],
                               extrasaction='ignore', lineterminator='\n')
            w.writeheader()
            for route, rb in readers.items():
                for r in rb.values():
                    w.writerow({k: (round(v, 6) if isinstance(v, float) else v) for k, v in r.items()})
        for route, rb in readers.items():
            missing = sum(not r['read'] for r in rb.values())
            L += ['', f'### {route}' + (f' ({missing} of {len(rb)} images not read yet)' if missing else ''), '']
            L += arm_table(rb, {**groups, **tag_groups}, ('raw', *ARMS), 'raw')
            L += [''] + arm_table(rb, groups, ('raw', 'enc-2048-q85', 'enc-1600-q90'), 'raw')
            if hand:
                L += [''] + arm_table(rb, {'hand-cropped': hand}, ('raw', 'quad', 'uvdoc', 'hand'), 'raw')
            if lad:
                L += [''] + arm_table(rb, {'ladder': lad}, ('quarter', *LADDER_ARMS, 'raw'), 'quarter')
    main3 = {k: groups[k] for k in ('originals', 'PDF images')}
    bench = arm_summary(by, main3, ('raw', *ARMS), 'raw', 'apple-vision')
    bench += arm_summary(by, main3, ('raw', *ENCODINGS), 'raw', 'apple-vision')
    if lad:
        bench += arm_summary(by, {'ladder': lad}, ('quarter', *LADDER_ARMS), 'quarter', 'apple-vision')
    for route, rb in readers.items():
        if all(r['read'] for r in rb.values()):
            bench += arm_summary(rb, main3, ('raw', *ARMS), 'raw', route)
            bench += arm_summary(rb, main3, ('raw', 'enc-2048-q85', 'enc-1600-q90'), 'raw', route)
            if lad:
                bench += arm_summary(rb, {'ladder': lad}, ('quarter', *LADDER_ARMS), 'quarter', route)
    found = RESULTS / 'enh-dewarp-uvdoc-bench.md'
    (RESULTS / 'enh-dewarp.json').write_text(json.dumps({
        'item': 'W46.enh-dewarp', 'report': REPORT.name, 'readers_pending': [r for r in READERS if r not in readers
                                                                             or not all(x['read'] for x in readers[r].values())],
        'uvdoc_benchmark': found.name if found.exists() else None, 'rows': bench}, indent=1) + '\n')
    REPORT.write_text('\n'.join(L) + '\n')
    print(REPORT)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('cmd', choices=['prepare', 'extras', 'vision', 'stage', 'fetch', 'report'])
    a = ap.parse_args()
    {'prepare': prepare, 'extras': prepare_extras, 'vision': vision, 'stage': stage, 'fetch': fetch, 'report': report}[a.cmd]()


if __name__ == '__main__':
    sys.exit(main())
