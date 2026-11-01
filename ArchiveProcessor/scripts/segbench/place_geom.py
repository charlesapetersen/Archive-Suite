#!/usr/bin/env python3
"""W46.place-geom — whether a straightened reading copy, made after OCR, makes the text layer easier to select.

OCR stays on the raw photograph (W46.enh-dewarp). The question is the reading copy: which image the layer sits on,
scored by whole lines (F-placement §6.2, "Selection is a line", owner 2026-10-29). Apple Vision's lines read on the
raw image (W46.enh-dewarp's saved readings) are carried onto each arm's image through that arm's map and written as
a layer there; the placement truth's lines are carried the same way and dragged in PDFKit.

  $V place_geom.py run          every arm on every placement-truth page with a saved W46.enh-dewarp lattice
  $V place_geom.py selftest     the drag scorer on the truth's own oracle layer, level and shifted
  $V place_geom.py report       segbench-results/place-geom.md and .json from the run's rows

  ($V is W46.enh-dewarp's venv, which has numpy, scipy and OpenCV; run both under ops/autonomous/heavy-run.py.)

Arms (the image the layer is written on; all read the same Vision words, read once on the raw image):
  raw      the raw photograph, today's layer
  deskew   the raw photograph turned level by the page's median line angle on an enlarged canvas (removes nothing)
  quad     Apple's document quad with its perspective correction (W46.enh-dewarp's homography lattice)
  uvdoc    UVDoc after the quad (W46.enh-dewarp's lattice)
Writers:
  lab      the Vision OCR lab's SearchableWriter.compose (place_geom_writer.swift), one level run per Vision line
           over the line's box on the arm's image; the lab has no sloped run
  slope    place_functional.swift `layer`: one straight run per line along its baseline, sloped as the line is on
           the arm's image (OCRmyPDF's design); `level` is the same writer drawn level over the box, the control
           that separates the slope from the writer

The line pass (place_functional `drag`): a drag from just left of a truth line's first word to just right of its
last, on that arm's layer, passes when the selection holds no line break and is exactly the Vision words that sit
on the line's truth words, in their order. A line is scored when Vision read every one of its scored words (each
truth word's centre in a Vision word's box) and none of those Vision words also sits on another line; so every arm
is held to the same words, and an OCR miss is not counted as a selection failure. A line with a word the arm's
image cut off fails on that arm (the reading-copy rule forbids removing content).

The truth's lines are folded with the owner's rulings first (W46.place-lines-owner-ok, rulings.json): a join the
owner read as one line is merged, a split he read as breaking is split at the marks; the table rows he said break
at more places than the sheet marked are left out, and p096's two merged and one short hand line are applied or
left out as his note says.

Writes CACHE (layers, drags; rebuildable) and the committed results (counts and page ids only). No network, no
model, no money.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import random
import statistics
import subprocess
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
RESULTS = HERE.parents[1] / 'segbench-results'
REH = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
CACHE = REH / 'place-geom'
DEWARP = REH / 'enh-dewarp'
STORE = Path.home() / 'Library/Application Support/ArchiveSuiteRehearsal/place-truth'
SHEET = REH / 'ocr-truth/place-lines'
WRITER = Path(os.environ.get('PLACE_GEOM_WRITER', '/tmp/place_geom_writer'))
FUNCTIONAL = Path(os.environ.get('PLACE_FUNCTIONAL', '/tmp/place_functional'))
PT = 72 / 300                      # points per source pixel: the page as a 300 dpi scan
UNSCORED = {'missing', 'illegible', 'line-only'}
GROUPS = ('owner-typed', 'owner-hand')
ARMS = ('raw', 'deskew', 'quad', 'uvdoc')
VARIANTS = [('raw', 'lab'), ('deskew', 'lab'), ('quad', 'lab'), ('uvdoc', 'lab'),
            ('raw', 'level'), ('raw', 'slope'), ('deskew', 'slope'), ('quad', 'slope'), ('uvdoc', 'slope')]
BASE = ('raw', 'lab')
MARGIN = float(os.environ.get('PLACE_GEOM_MARGIN', '0'))  # the drag starts and ends this share of the word's height outside its ink;
# 0 is the ink's own edges, which the scorer self-test passes best (0.98 of oracle lines, against 0.93 at 0.35)
# Owner, 2026-10-31 (owner-notes-20261031.json): these table rows break at more places than the sheet marked, so
# their true lines are not known; they are left out rather than guessed.
TABLE_OPEN = {'p024': {'t002', 't003'}, 'p057': {'t007'}, 'p066': {'t010', 't011'}}
HAND_MERGE = {'p096': [(6, 8), (9, 11)]}
HAND_OPEN = {'p096': {20}}          # missing two words at its start


# ---------------------------------------------------------------- geometry (pure; test_place_geom.py)
def quad_bbox(pts):
    a = np.asarray(pts, float)
    x0, y0 = a.min(0)
    x1, y1 = a.max(0)
    return [float(x0), float(y0), float(x1 - x0), float(y1 - y0)]


def box_corners(b):
    x, y, w, h = b
    return [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]


def page_angle(lines, W, H, min_width=0.25):
    """The median angle in degrees (positive: the line falls to the right, image y down) of the bottom edges of
    Vision's lines at least min_width of the page wide; 0 when there are none."""
    a = []
    for ln in lines:
        q = ln['quad']
        (x0, y0), (x1, y1) = q[3], q[2]
        if x1 - x0 >= min_width:
            a.append(math.degrees(math.atan2((y1 - y0) * H, (x1 - x0) * W)))
    return statistics.median(a) if a else 0.0


def angle_spread(lines, W, H, min_width=0.25, min_lines=5):
    """Perspective's signature: how far a fit of line angle linear in the line's centre moves across the page, in
    degrees (the fit's range over the lines). None with fewer than min_lines wide lines."""
    rows = []
    for ln in lines:
        q = ln['quad']
        (x0, y0), (x1, y1) = q[3], q[2]
        if x1 - x0 >= min_width:
            cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
            rows.append((cx, cy, math.degrees(math.atan2((y1 - y0) * H, (x1 - x0) * W))))
    if len(rows) < min_lines:
        return None
    A = np.array([[1, r[0], r[1]] for r in rows])
    y = np.array([r[2] for r in rows])
    coef, *_ = np.linalg.lstsq(A, y, rcond=None)
    pred = A @ coef
    return float(pred.max() - pred.min())


class Map:
    """Source-normalised points -> an arm's output-normalised points (NaN where the arm's image does not show
    them), plus the output's size in source pixels."""

    def __init__(self, fn, out_w, out_h):
        self.fn, self.out_w, self.out_h = fn, out_w, out_h

    def __call__(self, pts):
        a = np.atleast_2d(np.asarray(pts, float))
        out = self.fn(a)
        bad = ~np.all(np.isfinite(out), 1) | np.any(out < -1e-6, 1) | np.any(out > 1 + 1e-6, 1)
        out = np.clip(out, 0, 1)
        out[bad] = np.nan
        return out


def identity_map(W, H):
    return Map(lambda a: a.copy(), W, H)


def deskew_map(W, H, deg):
    """Turn the page by -deg about its centre onto a canvas that holds all of it."""
    t = math.radians(-deg)
    c, s = math.cos(t), math.sin(t)
    corners = np.array([[0, 0], [W, 0], [W, H], [0, H]], float) - [W / 2, H / 2]
    R = np.array([[c, -s], [s, c]])
    rc = corners @ R.T
    lo, hi = rc.min(0), rc.max(0)
    ow, oh = hi - lo

    def fn(a):
        p = a * [W, H] - [W / 2, H / 2]
        return ((p @ R.T) - lo) / [ow, oh]
    return Map(fn, float(ow), float(oh))


def lattice_inverse(grid, out_w, out_h, W, H, kind, dense=4):
    """Invert a W46.enh-dewarp lattice (output-normalised node -> source-normalised point). A homography for the
    quad arm (exact: its lattice is one); for UVDoc a piecewise-linear inverse over the lattice refined `dense`
    times by bilinear interpolation, NaN outside it."""
    gh, gw = grid.shape[:2]
    u, v = np.meshgrid(np.linspace(0, 1, gw), np.linspace(0, 1, gh))
    out_px = np.stack([u * out_w, v * out_h], -1).reshape(-1, 2)
    src_px = (grid * [W, H]).reshape(-1, 2)
    if kind == 'quad':
        import cv2
        Hm, _ = cv2.findHomography(src_px.astype(np.float64), out_px.astype(np.float64), 0)

        def fn(a):
            p = np.c_[a * [W, H], np.ones(len(a))] @ Hm.T
            return (p[:, :2] / p[:, 2:3]) / [out_w, out_h]
        return Map(fn, float(out_w), float(out_h))
    from scipy.interpolate import LinearNDInterpolator
    sys.path.insert(0, str(HERE))
    from enh_dewarp import grid_eval
    n_u, n_v = (gw - 1) * dense + 1, (gh - 1) * dense + 1
    uu, vv = np.meshgrid(np.linspace(0, 1, n_u), np.linspace(0, 1, n_v))
    uv = np.stack([uu, vv], -1)
    src = grid_eval(grid, uv.reshape(-1, 2)).reshape(-1, 2) * [W, H]
    interp = LinearNDInterpolator(src, uv.reshape(-1, 2))

    def fn(a):
        return interp(a * [W, H])
    return Map(fn, float(out_w), float(out_h))


# ---------------------------------------------------------------- truth, folded with the owner's rulings
def load_truth():
    pages = []
    for f in sorted(STORE.glob('*.json')):
        t = json.loads(f.read_text())
        if t.get('group') in GROUPS and t.get('in_96'):
            pages.append(t)
    return pages


def fold_lines(t: dict, rulings: dict) -> tuple[dict, dict]:
    """The truth's lines after the owner's rulings: id -> word indices in reading order (every word with a box
    that the line holds, scored or not), and a count of what was folded. Line ids become strings ('12', '12.1',
    '3+5')."""
    page = t['page']
    lines: dict[int, list[int]] = {}
    for i, w in enumerate(t['words']):
        if w.get('box') and w.get('line') is not None:
            lines.setdefault(w['line'], []).append(i)
    scored = {L: [i for i in ws if t['words'][i]['status'] not in UNSCORED] for L, ws in lines.items()}
    r = rulings.get(page) or {}
    n = {'merged': 0, 'split': 0, 'left_out': 0}
    drop: set[int] = set()
    splits: dict[int, list[int]] = {}
    parent = {L: L for L in lines}

    def find(L):
        while parent[L] != L:
            L = parent[L]
        return L
    if r.get('hand'):
        for a, b in HAND_MERGE.get(page, []) if r.get('ruling') == 'checked' else []:
            if a in parent and b in parent:
                parent[find(b)] = find(a)
                n['merged'] += 1
        for L in HAND_OPEN.get(page, set()):
            drop.add(L)
    else:
        for iid, v in r.items():
            if iid in TABLE_OPEN.get(page, set()):
                for p in v['places']:
                    drop.update(p['lines'])
                continue
            if v.get('ruling') != 'truth wrong':
                continue
            for p in v['places']:
                if p['kind'] == 'join':
                    Ls = [L for L in p['lines'] if L in parent]
                    for L in Ls[1:]:
                        if find(L) != find(Ls[0]):
                            parent[find(L)] = find(Ls[0])
                            n['merged'] += 1
                else:
                    splits.setdefault(p['lines'][0], []).extend(p['breaks'])
    groups: dict[int, list[int]] = {}
    for L in lines:
        groups.setdefault(find(L), []).append(L)
    out = {}
    for root, Ls in groups.items():
        if any(L in drop for L in Ls):
            n['left_out'] += len(Ls)
            continue
        if len(Ls) > 1:
            if any(L in splits for L in Ls):    # both merged and split: not known, left out
                n['left_out'] += len(Ls)
                continue
            ws = sorted((i for L in Ls for i in lines[L]), key=lambda i: t['words'][i]['box'][0])
            out['+'.join(map(str, sorted(Ls)))] = ws
            continue
        L = Ls[0]
        if L in splits:
            cuts = sorted(set(splits[L]))
            sc = scored[L]
            # a break k falls between the k-th and k+1-th scored word; an unscored word goes with the part before it
            bounds = [sc[k + 1] for k in cuts if k + 1 < len(sc)]
            part, parts = [], []
            for i in lines[L]:
                if bounds and i == bounds[0]:
                    parts.append(part)
                    part = []
                    bounds.pop(0)
                part.append(i)
            parts.append(part)
            for k, ws in enumerate(parts):
                out[f'{L}.{k}'] = ws
            n['split'] += 1
            continue
        out[str(L)] = lines[L]
    return out, n


# ---------------------------------------------------------------- Vision's reading, and what each line expects
def vision_words(page):
    d = json.loads((DEWARP / 'lines/raw' / f'{page}.json').read_text())
    lines, words = [], []
    for k, ln in enumerate(d['lines']):
        ws = ln.get('words') or [{'quad': ln['quad'], 'text': ln['text']}]
        ids = []
        for w in ws:
            if not w['text'].strip():
                continue
            ids.append(len(words))
            words.append({'text': w['text'].strip(), 'quad': w['quad'], 'line': k, 'box': quad_bbox(w['quad'])})
        if ids:
            lines.append({'quad': ln['quad'], 'words': ids})
    return lines, words


def contains(b, c, pad):
    x, y, w, h = b
    return x - pad * h <= c[0] <= x + w + pad * h and y - pad * h <= c[1] <= y + h + pad * h


def assign(t, vwords):
    """Truth word index -> the Vision word whose box holds its centre (the smallest such box)."""
    out = {}
    for i, w in enumerate(t['words']):
        if not w.get('box'):
            continue
        b = w['box']
        c = (b[0] + b[2] / 2, b[1] + b[3] / 2)
        hits = [j for j, v in enumerate(vwords) if contains(v['box'], c, 0.1)]
        if hits:
            out[i] = min(hits, key=lambda j: vwords[j]['box'][2] * vwords[j]['box'][3])
    return out


def expected_lines(t, folded, vwords, a):
    """The scored lines: id -> (truth word indices, the Vision words expected in order). Left out when Vision
    missed one of its scored words, a Vision word sits on two lines, or the line has fewer than two scored words."""
    owner: dict[int, set] = {}
    for L, ws in folded.items():
        for i in ws:
            if i in a:
                owner.setdefault(a[i], set()).add(L)
    out, skipped = {}, {'unread': 0, 'shared': 0, 'short': 0, 'sideways': 0}
    for L, ws in folded.items():
        sc = [i for i in ws if t['words'][i]['status'] not in UNSCORED]
        if len(sc) < 2:
            skipped['short'] += 1
            continue
        if sideways(t, sc):
            skipped['sideways'] += 1
            continue
        if any(i not in a for i in sc):
            skipped['unread'] += 1
            continue
        seq = []
        for i in ws:
            j = a.get(i)
            if j is not None and (not seq or seq[-1] != j):
                seq.append(j)
        if any(len(owner[j]) > 1 for j in seq) or len(set(seq)) != len(seq):
            skipped['shared'] += 1
            continue
        out[L] = (sc, seq)
    return out, skipped


# ---------------------------------------------------------------- one page, every arm
def arm_maps(t, vlines):
    W, H, p = t['width'], t['height'], t['page']
    maps = {'raw': identity_map(W, H), 'deskew': deskew_map(W, H, page_angle(vlines, W, H))}
    for arm in ('quad', 'uvdoc'):
        g = np.load(DEWARP / 'grids' / arm / f'{p}.npz')
        assert int(g['src_w']) == W and int(g['src_h']) == H, (p, arm)
        maps[arm] = lattice_inverse(g['grid'], float(g['out_w']), float(g['out_h']), W, H, arm)
    return maps


def edge_points(quad, k=5):
    """The quad's outline sampled k points an edge, so a bent map's box holds the whole carried line."""
    q = np.asarray(quad, float)
    pts = []
    for a, b in zip(q, np.roll(q, -1, 0)):
        for s in np.linspace(0, 1, k, endpoint=False):
            pts.append(a * (1 - s) + b * s)
    return np.array(pts)


def carried_layer(m: Map, vlines, vwords, writer):
    """Vision's lines on the arm's image: words whose quad the arm keeps whole, each line's box (lab, level) or
    sloped baseline (slope). Returns (lines for the writer, kept word ids)."""
    kept_words, out = set(), []
    for ln in vlines:
        keep = []
        for j in ln['words']:
            # kept when its centre is shown, the rule the truth's words are held to (lost_words); its box is
            # what of its outline the arm shows
            q = np.asarray(vwords[j]['quad'], float)
            if not np.all(np.isfinite(m([q.mean(0)]))):
                continue
            pts = m(edge_points(q, 3))
            keep.append((j, pts[np.all(np.isfinite(pts), 1)]))
        if not keep:
            continue
        kept_words.update(j for j, _ in keep)
        text = ' '.join(vwords[j]['text'] for j, _ in keep)
        allpts = np.concatenate([p for _, p in keep])
        box = quad_bbox(allpts)
        if writer in ('lab', 'level'):
            x, y, w, h = box
            out.append({'text': text, 'box': box,
                        'baseline': [[x, y + h], [x + w, y + h]], 'height': h})
            continue
        # slope: the line's own bottom edge from its first kept word's bottom-left to its last's bottom-right
        q0, q1 = vwords[keep[0][0]]['quad'], vwords[keep[-1][0]]['quad']
        bl, br, tl = m([q0[3], q1[2], q0[0]])
        if not (np.all(np.isfinite(bl)) and np.all(np.isfinite(br)) and np.all(np.isfinite(tl))):
            x, y, w, h = box      # a corner off the image: drawn level over what is shown
            out.append({'text': text, 'box': box, 'baseline': [[x, y + h], [x + w, y + h]], 'height': h})
            continue
        Wo, Ho = m.out_w, m.out_h
        hpx = math.hypot((tl[0] - bl[0]) * Wo, (tl[1] - bl[1]) * Ho)
        out.append({'text': text, 'box': box, 'baseline': [bl.tolist(), br.tolist()], 'height': hpx / Ho})
    return out, kept_words


def sideways(t, ws, limit=45.0):
    """A line that reads more than `limit` degrees off level, first word's centre to last's (a margin note turned
    a quarter): the lab writer turns such lines in a frame of their own (C36), which the arms here do not carry."""
    W, H = t['width'], t['height']
    b0, b1 = t['words'][ws[0]]['box'], t['words'][ws[-1]]['box']
    dx = ((b1[0] + b1[2] / 2) - (b0[0] + b0[2] / 2)) * W
    dy = ((b1[1] + b1[3] / 2) - (b0[1] + b0[3] / 2)) * H
    return abs(math.degrees(math.atan2(dy, dx))) > limit


def drag_points(t, m: Map, sc):
    """Start just left of the first truth word's ink and end just right of the last's, at mid-height, carried."""
    W, H = t['width'], t['height']
    b0, b1 = t['words'][sc[0]]['box'], t['words'][sc[-1]]['box']
    s = (max(0.0, b0[0] - MARGIN * b0[3] * H / W), b0[1] + b0[3] / 2)
    e = (min(1.0, b1[0] + b1[2] + MARGIN * b1[3] * H / W), b1[1] + b1[3] / 2)
    s2, e2 = m([s, e])
    # a margin the arm's image does not show: start or end on the word's own edge instead
    if not np.all(np.isfinite(s2)):
        s2 = m([(b0[0], s[1])])[0]
    if not np.all(np.isfinite(e2)):
        e2 = m([(b1[0] + b1[2], e[1])])[0]
    return s2, e2


def lost_words(t, m: Map, quad_poly, vwords, a, kept):
    """Truth words (scored) the arm's image cuts off: their centre is not shown. Own sheet when the word lies inside
    Apple's quad or its Vision line keeps other words on the arm (a line cut through); else neighbour text. Third,
    the words whose centre is shown but whose ink box is cut (part of the word removed)."""
    own = neigh = part = 0
    for i, w in enumerate(t['words']):
        if not w.get('box') or w['status'] in UNSCORED:
            continue
        b = w['box']
        c = (b[0] + b[2] / 2, b[1] + b[3] / 2)
        if np.all(np.isfinite(m([c]))):
            part += not np.all(np.isfinite(m(box_corners(b))))
            continue
        j = a.get(i)
        cut_line = j is not None and any(k in kept for k in range(len(vwords))
                                         if vwords[k]['line'] == vwords[j]['line'])
        if inside(quad_poly, c) or cut_line:
            own += 1
        else:
            neigh += 1
    return own, neigh, part


def inside(poly, c):
    x, y = c
    n, hit = len(poly), False
    for k in range(n):
        (x0, y0), (x1, y1) = poly[k], poly[(k + 1) % n]
        if (y0 > y) != (y1 > y) and x < x0 + (y - y0) * (x1 - x0) / (y1 - y0):
            hit = not hit
    return hit


def run_tool(args, check=True):
    r = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f'{args[0]} failed: {r.stderr[-800:]}')
    return r.stdout


def page_rows(t, rulings):
    p = t['page']
    work = CACHE / 'pages' / p
    work.mkdir(parents=True, exist_ok=True)
    vlines, vwords = vision_words(p)
    folded, fold_n = fold_lines(t, rulings)
    a = assign(t, vwords)
    exp, skipped = expected_lines(t, folded, vwords, a)
    W, H = t['width'], t['height']
    maps = arm_maps(t, vlines)
    quad_poly = json.loads((DEWARP / 'quad' / f'{p}.json').read_text())['corners']
    geo = {'angle': page_angle(vlines, W, H), 'spread': angle_spread(vlines, W, H)}
    rows, lab_jobs = [], []
    plans = {}
    for arm, writer in VARIANTS:
        m = maps[arm]
        layer, kept = carried_layer(m, vlines, vwords, writer)
        pdf = work / f'{arm}-{writer}.pdf'
        Wp, Hp = m.out_w * PT, m.out_h * PT
        if writer == 'lab':
            lab_jobs.append({'out': str(pdf), 'width': Wp, 'height': Hp,
                             'lines': [{'text': l['text'], 'box': l['box']} for l in layer]})
        else:
            spec = work / f'{arm}-{writer}.lines.json'
            spec.write_text(json.dumps({'width': Wp, 'height': Hp, 'lines': layer}))
            run_tool([FUNCTIONAL, 'layer', spec, pdf])
        drags, lost_lines = [], 0
        for L, (sc, seq) in exp.items():
            if any(j not in kept for j in seq):
                lost_lines += 1
                continue
            s, e = drag_points(t, m, sc)
            if not (np.all(np.isfinite(s)) and np.all(np.isfinite(e))):
                lost_lines += 1
                continue
            drags.append({'id': L, 'expected': ' '.join(vwords[j]['text'] for j in seq),
                          'start': s.tolist(), 'end': e.tolist()})
        # the truth's words carried onto the arm, for Find
        tw = []
        for w in t['words']:
            if not w.get('box'):
                continue
            pts = m(box_corners(w['box']))
            if np.all(np.isfinite(pts)):
                tw.append({**w, 'box': quad_bbox(pts)})
        own, neigh, part = lost_words(t, m, quad_poly, vwords, a, kept)
        plans[(arm, writer)] = (pdf, drags, tw, lost_lines, own, neigh, part)
    if lab_jobs:
        jf = work / 'lab-jobs.json'
        jf.write_text(json.dumps(lab_jobs))
        unplaced = json.loads(run_tool([WRITER, jf]))['unplaced']
    else:
        unplaced = []
    for (arm, writer), (pdf, drags, tw, lost_lines, own, neigh, part) in plans.items():
        dj, do = work / f'{arm}-{writer}.drags.json', work / f'{arm}-{writer}.drag-out.json'
        dj.write_text(json.dumps({'lines': drags}))
        run_tool([FUNCTIONAL, 'drag', dj, pdf, do])
        got = json.loads(do.read_text())
        tj = work / f'{arm}-{writer}.truth.json'
        tj.write_text(json.dumps({'page': p, 'words': tw}))
        find = json.loads(run_tool([FUNCTIONAL, 'score', tj, pdf]))
        rows.append({'page': p, 'group': t['group'], 'kind': t.get('kind'), 'arm': arm, 'writer': writer,
                     'lines': len(exp), 'dragged': got['n'], 'passed': got['passed'], 'lost_lines': lost_lines,
                     'broken': sum(1 for r in got['lines'] if r['broken']),
                     'find_words': find['words'], 'found': find['found'], 'placed': find['placed'],
                     'lost_own': own, 'lost_neighbour': neigh, 'cut_words': part,
                     'unplaced': sum(1 for u in unplaced if u['out'] == str(pdf)),
                     'passes': [r['id'] for r in got['lines'] if r['pass']]})
    meta = {'page': p, 'group': t['group'], 'kind': t.get('kind'), 'fold': fold_n, 'skipped': skipped,
            'scored_lines': len(exp), 'truth_lines': len(folded), **geo}
    return rows, meta


def cmd_run(a):
    rulings = json.loads((SHEET / 'rulings.json').read_text())['rulings']
    pages = [t for t in load_truth() if (DEWARP / 'grids/uvdoc' / f'{t["page"]}.npz').exists()
             and (DEWARP / 'lines/raw' / f'{t["page"]}.json').exists()]
    if a.pages:
        pages = [t for t in pages if t['page'] in a.pages.split(',')]
    out = CACHE / 'rows.jsonl'
    done = {}
    if a.fresh and out.exists():
        out.write_text('')
    if out.exists():
        for x in out.read_text().splitlines():
            r = json.loads(x)
            done[r['meta']['page']] = r
    for n, t in enumerate(pages, 1):
        if t['page'] in done:
            continue
        rows, meta = page_rows(t, rulings)
        done[t['page']] = {'meta': meta, 'rows': rows}
        with out.open('a') as f:
            f.write(json.dumps(done[t['page']]) + '\n')
        base = next(r for r in rows if (r['arm'], r['writer']) == BASE)
        print(f'{n}/{len(pages)} {t["page"]} lines {meta["scored_lines"]} raw-lab passed {base["passed"]}', flush=True)


def cmd_selftest(a):
    """The drag scorer on a per-line oracle: every folded typed truth line of two or more boxed words written as
    one level run (place_functional `layer`) from its first word's left edge to its last's right, on its words'
    median bottom edge, at their median height, its text the truth's own words, dragged along the run's own middle.
    This tests the scorer, not a layer: the arms drag along the truth's ink, which is the user's drag. Close to every line should pass; with the whole layer moved
    down by `dy` of the page (about a line), close to none. (The per-word oracle is no test of a line scorer:
    PDFKit orders one run a word by the stream, not the line.)"""
    rulings = json.loads((SHEET / 'rulings.json').read_text())['rulings']
    work = CACHE / 'selftest'
    work.mkdir(parents=True, exist_ok=True)
    res = {}
    for t in load_truth():
        if t['group'] != 'owner-typed':
            continue
        p, W, H = t['page'], t['width'], t['height']
        folded, _ = fold_lines(t, rulings)
        drags, lines = [], []
        for L, ws in folded.items():
            ws = [i for i in ws if t['words'][i]['box'][2] > 0]
            if len(ws) < 2 or sideways(t, ws):
                continue
            b0, b1 = t['words'][ws[0]]['box'], t['words'][ws[-1]]['box']
            h = statistics.median(t['words'][i]['box'][3] for i in ws)
            text = ' '.join(t['words'][i]['text'] for i in ws)
            y = statistics.median(t['words'][i]['box'][1] + t['words'][i]['box'][3] for i in ws)
            ya, yb = (y, y) if a.slope == 'level' else (b0[1] + b0[3], b1[1] + b1[3])
            lines.append({'text': text, 'baseline': [[b0[0], ya], [b1[0] + b1[2], yb]], 'height': h,
                          'angle': abs(math.degrees(math.atan2((b1[1] + b1[3] - b0[1] - b0[3]) * H,
                                                               (b1[0] + b1[2] - b0[0]) * W)))})
            # along the run's own middle (lifted a fifth, glyphs to about 0.6 of the height above that), from a
            # margin before its first glyph to a margin past its last: the scorer, not the layer, under test
            mx = MARGIN * h * H / W
            drags.append({'id': L, 'expected': ' '.join(text.split()),
                          'start': [max(0.0, b0[0] - mx), ya - 0.5 * h], 'end': [min(1.0, b1[0] + b1[2] + mx), yb - 0.5 * h]})
        dj = work / f'{p}.drags.json'
        dj.write_text(json.dumps({'lines': drags}))
        for dy in (0.0, 0.02):
            spec, pdf, do = work / f'{p}-{dy}.lines.json', work / f'{p}-{dy}.pdf', work / f'{p}-{dy}.out.json'
            moved = [{**ln, 'baseline': [[x, y + dy] for x, y in ln['baseline']]} for ln in lines]
            spec.write_text(json.dumps({'width': W * PT, 'height': H * PT, 'lines': moved}))
            run_tool([FUNCTIONAL, 'layer', spec, pdf])
            run_tool([FUNCTIONAL, 'drag', dj, pdf, do])
            got = json.loads(do.read_text())
            for ln, r in zip(lines, got['lines']):
                for key in (f'{dy} all', f'{dy} slope<0.5' if ln['angle'] < 0.5 else f'{dy} slope>=0.5'):
                    k = res.setdefault(key, [0, 0])
                    k[0] += r['pass']
                    k[1] += 1
    out = {dy: {'passed': v[0], 'n': v[1], 'rate': v[0] / v[1] if v[1] else None} for dy, v in res.items()}
    (CACHE / f'selftest-{a.slope}.json').write_text(json.dumps(out, indent=1))
    print(json.dumps(out))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('run')
    r.add_argument('--pages')
    r.add_argument('--fresh', action='store_true')
    st = sub.add_parser('selftest')
    st.add_argument('--slope', choices=('level', 'sloped'), default='level',
                    help='sloped: each oracle run follows its truth line, first word to last (PDFKit on sloped runs)')
    sub.add_parser('report')
    a = ap.parse_args()
    if a.cmd == 'run':
        cmd_run(a)
    elif a.cmd == 'selftest':
        cmd_selftest(a)
    else:
        import place_geom_report
        place_geom_report.write(CACHE / 'rows.jsonl', RESULTS)


if __name__ == '__main__':
    main()
