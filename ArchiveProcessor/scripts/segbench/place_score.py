"""W46.fix-place-truth — the placement scorers over the truth set of `place_truth.py` (F-placement §6.2).

Three scores, plus the line-level alignment accuracy the line-broken truth makes possible:

  functional   Find-in-place on a rendered PDF: `place_functional.swift` (PDFKit), not here.
  word         F1 at IoU 0.5 and 0.7 over word boxes, one-to-one, greedy by IoU (GutenOCR's matching), and mCER
               over the pairs matched at 0.5.
  baseline     READ-BAD-style coverage R, P, F over baselines: polylines resampled every 2 px; each truth line
               gets a tolerance from its distance to the nearest other truth line (TOL_FRAC of it, at least
               TOL_MIN px); a point within the tolerance counts fully, falling linearly to nothing at twice it.
               R = mean over truth lines of their points' coverage by any hypothesis line; P = the same with the
               roles swapped, each hypothesis point judged by the tolerance of the truth line nearest it.
               Simplified from Grüning et al. (2019): no skew-dependent tolerance and no split/merge alignment
               term, so it is not interchangeable with the Transkribus Java tool's figures.
  alignment    Bullinger's line-level alignment accuracy: a truth line counts when the hypothesis line that
               overlaps it most carries text no closer to any of the NEIGHBOURS truth lines either side of it.

A hypothesis page is JSON: {"words": [{"text", "box"}], "lines": [{"text", "box", "baseline"}]}, boxes and
points normalised with a top-left origin, as the truth is. Truth words whose box is still `missing` (Vision found
nothing there and nobody has drawn it) or `illegible`, and N6's line-only words, are not scored at word level;
the counts say how many.

Usage: python3 place_score.py <hyp-dir> [--group owner-typed] [--json out.json]
       (hyp-dir holds <page>.json, the page id with '/' as '__')
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import place_truth

TOL_FRAC = 0.25
NEIGHBOURS = 5
TOL_MIN = 5.0
UNSCORED = {'missing', 'illegible', 'line-only'}


def iou(a, b) -> float:
    ax1, ay1, bx1, by1 = a[0] + a[2], a[1] + a[3], b[0] + b[2], b[1] + b[3]
    iw = max(0.0, min(ax1, bx1) - max(a[0], b[0]))
    ih = max(0.0, min(ay1, by1) - max(a[1], b[1]))
    inter = iw * ih
    uni = a[2] * a[3] + b[2] * b[3] - inter
    return inter / uni if uni > 0 else 0.0


def levenshtein(a: str, b: str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def cer(hyp: str, ref: str) -> float:
    return levenshtein(hyp, ref) / max(1, len(ref))


def scoreable(truth: dict) -> list[dict]:
    return [w for w in truth['words'] if w.get('box') and w['status'] not in UNSCORED]


def match(truth_words, hyp_words, thr):
    """One-to-one pairs with IoU >= thr, greedy from the highest IoU down."""
    cands = []
    for i, t in enumerate(truth_words):
        for j, h in enumerate(hyp_words):
            v = iou(t['box'], h['box'])
            if v >= thr:
                cands.append((v, i, j))
    cands.sort(reverse=True)
    used_t, used_h, pairs = set(), set(), []
    for v, i, j in cands:
        if i in used_t or j in used_h:
            continue
        used_t.add(i); used_h.add(j); pairs.append((i, j, v))
    return pairs


def word_scores(truth: dict, hyp: dict) -> dict:
    tw = scoreable(truth)
    hw = [w for w in hyp.get('words', []) if w.get('box')]
    out = {'truth_words': len(tw), 'hyp_words': len(hw),
           'unscored_truth_words': len(truth['words']) - len(tw)}
    for thr in (0.5, 0.7):
        pairs = match(tw, hw, thr)
        p = len(pairs) / len(hw) if hw else 0.0
        r = len(pairs) / len(tw) if tw else 0.0
        out[f'f1@{thr}'] = 2 * p * r / (p + r) if p + r else 0.0
        out[f'p@{thr}'], out[f'r@{thr}'], out[f'matched@{thr}'] = p, r, len(pairs)
        if thr == 0.5:
            out['mcer@0.5'] = (sum(cer(hw[j]['text'], tw[i]['text']) for i, j, _ in pairs) / len(pairs)
                               if pairs else None)
    return out


# ---------------------------------------------------------------- baselines

STEP = 2.0  # px between resampled points


def resample(poly, W, H):
    """Pixel points every STEP pixels along a normalised polyline."""
    pts = [(x * W, y * H) for x, y in poly]
    out = [pts[0]]
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        n = max(1, int(math.hypot(x1 - x0, y1 - y0) / STEP))
        out += [(x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * k / n) for k in range(1, n + 1)]
    return out


class Grid:
    """Points bucketed in CELL-pixel cells, for nearest-point queries bounded by a radius."""
    CELL = 16.0

    def __init__(self, items):  # items: (x, y, tag)
        self.cells = {}
        for x, y, tag in items:
            self.cells.setdefault((int(x // self.CELL), int(y // self.CELL)), []).append((x, y, tag))

    def nearest(self, x, y, radius, skip=None):
        """(distance, tag) of the nearest point within `radius` whose tag is not `skip`, else (inf, None).
        Rings of cells outward from the query's cell, stopping once no farther ring can hold a closer point."""
        cx, cy, rmax = int(x // self.CELL), int(y // self.CELL), int(radius // self.CELL) + 1
        best = (math.inf, None)
        for r in range(rmax + 1):
            if best[0] <= (r - 1) * self.CELL:
                break
            ring = ((i, j) for i in range(cx - r, cx + r + 1) for j in range(cy - r, cy + r + 1)
                    if max(abs(i - cx), abs(j - cy)) == r)
            for cell in ring:
                for qx, qy, tag in self.cells.get(cell, ()):
                    if tag == skip:
                        continue
                    d = math.hypot(x - qx, y - qy)
                    if d < best[0]:
                        best = (d, tag)
        return best if best[0] <= radius else (math.inf, None)


def _thin(pts, step):
    return pts[::step] or pts


TOL_CAP = 400.0  # px: a truth line with no neighbour this close gets the tolerance of a neighbour at this distance


def tolerances(truth_pts, grid):
    """Per truth line: TOL_FRAC of the median distance from its points to the nearest other truth line."""
    tols = []
    for i, pts in enumerate(truth_pts):
        ds = sorted(min(grid.nearest(x, y, TOL_CAP, skip=i)[0], TOL_CAP) for x, y in _thin(pts, 10))
        tols.append(max(TOL_MIN, TOL_FRAC * ds[len(ds) // 2]))
    return tols


def coverage(d, t):
    if d <= t:
        return 1.0
    return max(0.0, 1.0 - (d - t) / t)


def baseline_scores(truth: dict, hyp: dict) -> dict:
    W, H = truth['width'], truth['height']
    tl = [resample(l['baseline'], W, H) for l in truth['lines'] if l.get('baseline') and len(l['baseline']) >= 1]
    hl = [resample(l['baseline'], W, H) for l in hyp.get('lines', []) if l.get('baseline')]
    out = {'truth_baselines': len(tl), 'hyp_baselines': len(hl)}
    if not tl or not hl:
        out.update(R=0.0, P=0.0, F=0.0)
        return out
    tgrid = Grid((x, y, i) for i, pts in enumerate(tl) for x, y in pts)
    hgrid = Grid((x, y, 0) for pts in hl for x, y in pts)
    tols = tolerances(tl, tgrid)
    rs = []
    for i, pts in enumerate(tl):
        sample = _thin(pts, 3)
        rs.append(sum(coverage(hgrid.nearest(x, y, 2 * tols[i])[0], tols[i]) for x, y in sample) / len(sample))
    tmax = 2 * max(tols)
    ps = []
    for pts in hl:
        sample = _thin(pts, 3)
        tot = 0.0
        for x, y in sample:
            d, i = tgrid.nearest(x, y, tmax)
            tot += coverage(d, tols[i]) if i is not None else 0.0
        ps.append(tot / len(sample))
    R, P = sum(rs) / len(rs), sum(ps) / len(ps)
    out.update(R=R, P=P, F=2 * R * P / (R + P) if R + P else 0.0)
    return out


# ---------------------------------------------------------------- line alignment

def alignment_scores(truth: dict, hyp: dict) -> dict:
    tl = [l for l in truth['lines'] if l.get('box')]
    hl = [l for l in hyp.get('lines', []) if l.get('box')]
    ok = 0
    for i, t in enumerate(tl):
        best = max(hl, key=lambda h: iou(t['box'], h['box']), default=None)
        if best is None or iou(t['box'], best['box']) == 0:
            continue
        # The rival lines are the page's nearest NEIGHBOURS lines either side: an aligner's error is to put a line's
        # text one or two lines off, and comparing against every line on a 100-line page costs minutes. A tie
        # (a repeated line) counts as aligned.
        text = best.get('text', '')
        own = cer(text, t['text'])
        rivals = range(max(0, i - NEIGHBOURS), min(len(tl), i + NEIGHBOURS + 1))
        ok += all(cer(text, tl[k]['text']) >= own for k in rivals if k != i)
    return {'truth_lines': len(tl), 'aligned': ok, 'accuracy': ok / len(tl) if tl else 0.0}


def score_page(truth: dict, hyp: dict) -> dict:
    return {'page': truth['page'], 'group': truth['group'], 'word': word_scores(truth, hyp),
            'baseline': baseline_scores(truth, hyp), 'alignment': alignment_scores(truth, hyp)}


def pooled(rows: list[dict]) -> dict:
    """Micro-averaged word figures and macro-averaged (per page) baseline and alignment figures."""
    out = {'pages': len(rows)}
    tw = sum(r['word']['truth_words'] for r in rows)
    hw = sum(r['word']['hyp_words'] for r in rows)
    out['truth_words'] = tw
    for thr in (0.5, 0.7):
        if not tw:  # N6: line geometry only
            out[f'f1@{thr}'] = None
            continue
        m = sum(r['word'][f'matched@{thr}'] for r in rows)
        p, rr = (m / hw if hw else 0.0), (m / tw if tw else 0.0)
        out[f'f1@{thr}'] = 2 * p * rr / (p + rr) if p + rr else 0.0
    c = [r['word']['mcer@0.5'] for r in rows if r['word']['mcer@0.5'] is not None]
    out['mcer@0.5'] = sum(c) / len(c) if c else None
    for k in ('R', 'P', 'F'):
        out[f'baseline_{k}'] = sum(r['baseline'][k] for r in rows) / len(rows) if rows else 0.0
    out['alignment'] = sum(r['alignment']['accuracy'] for r in rows) / len(rows) if rows else 0.0
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('hyp_dir', type=Path)
    ap.add_argument('--group')
    ap.add_argument('--json', type=Path)
    a = ap.parse_args()
    rows = []
    for t in place_truth.load_all():
        if a.group and t['group'] != a.group:
            continue
        f = a.hyp_dir / (t['page'].replace('/', '__') + '.json')
        if f.exists():
            rows.append(score_page(t, json.loads(f.read_text())))
    groups = sorted({r['group'] for r in rows})
    res = {'by_group': {g: pooled([r for r in rows if r['group'] == g]) for g in groups}, 'pages': rows}
    if a.json:
        a.json.write_text(json.dumps(res, indent=1) + '\n')
    print(json.dumps(res['by_group'], indent=1))


if __name__ == '__main__':
    main()
