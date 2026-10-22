"""W46.fix-place-truth — the placement truth set (F-placement §6.2, 10-gap-audit §4 fix 5).

Four groups, one JSON per page in STORE (private: the owner's text and the public pages' text stay off the repo,
as the bench corpus does), plus a PAGE-XML copy of each and a text-free summary in segbench-results:

  owner-typed  40 typewritten or printed pages of the owner's 96, drawn by a fixed seed in the 96's kind mix.
  owner-hand   every handwritten or mixed truth page (21: the 96's 18 and the three outside it).
  L2-bentham   the bench corpus's 20 Bentham pages (L2), word and line polygons from tranScriptorium's PAGE GT.
  N6           the bench corpus's 40 Devanagari pages, line boxes and baselines from their ALTO/PAGE.

The owner pages' boxes are DRAFTED: each truth word is aligned with Apple Vision's word boxes
(`vision-words.json`, top-left normalised [x, y, w, h], `.accurate`), as `locate.py` aligned disputed spans. A
word's `status` says where its box came from: `vision` (same word), `vision-sub` (Vision read it differently,
one for one), `split` (its box is a share of Vision words read as a different count, within SHARE_RATIO of the
same length), `missing` (Vision has no word there, or read a stretch too different to share: draw it in the
tool), `vision-moved` (the same word, found by a second pass where Vision read the block in another order),
`tesseract` / `tesseract-sub` (a third pass over Tesseract 5's words where no Vision box lies: the tables and
columns Vision skipped). Lines follow Vision's (or Tesseract's) lines; a line's baseline is drafted at
BASELINE_FRAC of its words' height. The transcript is the truth text, broken where the drafted lines break.
A page redrawn from a line spec (`lines`, by a drawing subagent on the `grid` render) has `drawn` words: line
boxes and baselines as drawn, word boxes split at the line's ink gaps (`gap_split`), `corrected` set.

Usage: python3 place_truth.py build                  # writes STORE and the summary
       python3 place_truth.py summary                # prints the summary only
       python3 place_truth.py overlay [page ...]     # STORE/overlay/<page>.jpg: boxes and baselines on the image
       python3 place_truth.py grid PAGE ...          # STORE/grid/<page>.jpg: the image with a permille grid
       python3 place_truth.py zoom PAGE X0 Y0 X1 Y1   # /tmp: a region enlarged, grid every 10 permille
       python3 place_truth.py bands PAGE X0 X1 [Y0 Y1]   # inked row bands in a strip (permille): where lines sit
       python3 place_truth.py lines PAGE SPEC BY     # redraw a page from a line spec (apply_lines), then overlay it
       python3 place_truth.py audit PAGE VERDICT NOTE BY   # ok | fix | redraw, kept across rebuilds
"""
from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from statistics import median

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'corpus'))

TRUTH = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/ocr-truth'
BENCH = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/bench-corpus'
FROZEN = Path.home() / 'Library/Application Support/ArchiveSuiteRehearsal/bench-corpus-frozen'
STORE = Path.home() / 'Library/Application Support/ArchiveSuiteRehearsal/place-truth'
RESULTS = HERE.parent.parent / 'segbench-results'
MANIFEST = RESULTS / 'bench-corpus/manifest.jsonl'
SCORED = RESULTS / 'ocr-pages.csv'

SEED = 'W46.fix-place-truth'
N_TYPED = 40
SHARE_RATIO = 1.6  # a replace block is shared out only when its truth and Vision characters are this close
BASELINE_FRAC = 0.78
GAP_LAMBDA = 2.0  # a break one line-height from where the share puts it costs this much; a full gap scores 2
GRID_FONT = '/System/Library/Fonts/Supplemental/Arial.ttf'
DESC_FRAC = 0.7  # a drawn line's band reaches this share of its ascender height below the baseline (descenders)
BENTHAM_DROP = 0.2  # of a Bentham line polygon's height, below its middle: where the baseline of a hand sits  # of a Vision word box's height, top down: where the baseline sits in a box with descenders


def norm(t: str) -> str:
    return re.sub(r'[^0-9a-z]', '', t.lower())


def seeded(items, key=lambda x: x):
    return sorted(items, key=lambda x: hashlib.sha256(f'{SEED}:{key(x)}'.encode()).hexdigest())


def image_size(path: Path) -> tuple[int, int]:
    out = subprocess.run(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', str(path)],
                         capture_output=True, text=True, check=True).stdout
    w = int(re.search(r'pixelWidth: (\d+)', out).group(1))
    h = int(re.search(r'pixelHeight: (\d+)', out).group(1))
    return w, h


# ---------------------------------------------------------------- owner pages: draft from Vision's words

def vision_lines(vw) -> list[int]:
    """A line number for each Vision word, in Vision's reading order: a new line where the next word starts left
    of the previous one, leaves its height band, or jumps a column-sized gap."""
    out, line = [], 0
    for i, w in enumerate(vw):
        if i:
            p = vw[i - 1]
            pcy, cy = p[2] + p[4] / 2, w[2] + w[4] / 2
            h = max(p[4], w[4])
            gap = w[1] - (p[1] + p[3])
            if w[1] < p[1] or abs(cy - pcy) > 0.5 * h or gap > max(0.06, 4 * h):
                line += 1
        out.append(line)
    return out


def union(boxes):
    x0 = min(b[0] for b in boxes); y0 = min(b[1] for b in boxes)
    x1 = max(b[0] + b[2] for b in boxes); y1 = max(b[1] + b[3] for b in boxes)
    return [x0, y0, x1 - x0, y1 - y0]


def clamp(b):
    x0, y0 = max(0.0, b[0]), max(0.0, b[1])
    x1, y1 = min(1.0, b[0] + b[2]), min(1.0, b[1] + b[3])
    return [x0, y0, max(0.0, x1 - x0), max(0.0, y1 - y0)]


def share(truth_toks, vwords, vlines):
    """Boxes for `truth_toks` read by Vision as a different number of words: each truth word takes the stretch
    of Vision's characters its own length claims, sliced horizontally inside a Vision word; a stretch that
    crosses lines keeps its larger part."""
    chars = []  # (vision index, offset in that word, word length)
    for k, w in enumerate(vwords):
        n = max(1, len(w[0]))
        chars += [(k, j, n) for j in range(n)]
    total_t = sum(max(1, len(t)) for t in truth_toks)
    out, pos = [], 0
    for t in truth_toks:
        a = pos * len(chars) / total_t
        pos += max(1, len(t))
        b = pos * len(chars) / total_t
        span = chars[int(a):max(int(a) + 1, int(round(b)))]
        by_line = {}
        for k, j, n in span:
            by_line.setdefault(vlines[k], []).append((k, j, n))
        part = max(by_line.values(), key=len)
        pieces = []
        for k in sorted({k for k, _, _ in part}):
            js = [j for kk, j, _ in part if kk == k]
            n = max(1, len(vwords[k][0]))
            x, y, w, h = vwords[k][1:5]
            lo, hi = min(js) / n, (max(js) + 1) / n
            pieces.append([x + lo * w, y, (hi - lo) * w, h])
        out.append((union(pieces), vlines[part[0][0]]))
    return out


def overlap(a, b) -> float:
    """The share of the smaller box that the two boxes have in common."""
    iw = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])
    ih = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
    if iw <= 0 or ih <= 0:
        return 0.0
    return iw * ih / max(1e-9, min(a[2] * a[3], b[2] * b[3]))


def tesseract_words(page: str, img: Path) -> list:
    """Tesseract 5's words on a page as [text, x, y, w, h, line], normalised, top-left; cached in STORE/tesseract."""
    cache = STORE / 'tesseract' / f'{page}.tsv'
    if not cache.exists():
        cache.parent.mkdir(parents=True, exist_ok=True)
        out = subprocess.run(['tesseract', str(img), '-', 'tsv'], capture_output=True, text=True, check=True).stdout
        cache.write_text(out)
    W, H = image_size(img)
    rows, keys = [], {}
    for ln in cache.read_text().splitlines()[1:]:
        f = ln.split('\t')
        if len(f) < 12 or f[0] != '5' or not f[11].strip() or float(f[10]) < 0:
            continue
        key = keys.setdefault((f[2], f[3], f[4]), len(keys))
        x, y, w, h = (int(v) for v in f[6:10])
        rows.append([f[11], x / W, y / H, w / W, h / H, key])
    return rows


def bottom_fit(boxes):
    """A straight baseline through tight word boxes: the least-squares line through their bottoms, fitted again
    without the words that hang below it (descenders) by more than a sixth of the median word height."""
    pts = [(b[0] + b[2] / 2, b[1] + b[3]) for b in boxes]
    mh = median(b[3] for b in boxes)

    def fit(ps):
        n = len(ps); mx = sum(x for x, _ in ps) / n; my = sum(y for _, y in ps) / n
        sxx = sum((x - mx) ** 2 for x, _ in ps)
        k = sum((x - mx) * (y - my) for x, y in ps) / sxx if sxx > 1e-9 and n > 2 else 0.0
        return lambda x: my + k * (x - mx)
    f = fit(pts)
    keep = [(x, y) for x, y in pts if y - f(x) <= mh / 6] or pts
    return fit(keep)


def draft_owner(page: str, text: str, vw, tw=None, tight=None) -> tuple[list[dict], list[dict]]:
    toks = text.split()
    vlines = vision_lines(vw)
    tn = [norm(t) for t in toks]
    vn = [norm(w[0]) for w in vw]
    words = [{'text': t, 'box': None, 'line': None, 'status': 'missing'} for t in toks]
    for t, w in zip(toks, words):
        if t.startswith('[') and 'illegible' in t.lower():
            w['status'] = 'illegible'
    sm = difflib.SequenceMatcher(None, tn, vn, autojunk=False)
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == 'equal' or (op == 'replace' and i2 - i1 == j2 - j1):
            for k in range(i2 - i1):
                v = vw[j1 + k]
                if words[i1 + k]['status'] == 'illegible':
                    continue
                words[i1 + k].update(box=list(v[1:5]), line=vlines[j1 + k],
                                     status='vision' if op == 'equal' else 'vision-sub')
        elif op == 'replace':
            idx = [i for i in range(i1, i2) if words[i]['status'] != 'illegible']
            tc = sum(len(toks[i]) for i in idx)
            vc = sum(len(w[0]) for w in vw[j1:j2])
            if not idx or not (1 / SHARE_RATIO <= tc / max(1, vc) <= SHARE_RATIO):
                continue  # Vision read a different stretch, not this one differently: the words stay `missing`
            for i, (box, ln) in zip(idx, share([toks[i] for i in idx], vw[j1:j2], vlines[j1:j2])):
                words[i].update(box=box, line=ln, status='split')
    # Second pass: Vision reads some blocks in another order (a letterhead after the body, a second column first),
    # which the first pass sees as deletion plus insertion. Match the still-missing words against the Vision words
    # nobody took, keeping only runs of two or more, or single words of four or more letters.
    used = {tuple(w['box']) for w in words if w['box']}
    free = [k for k, v in enumerate(vw) if tuple(v[1:5]) not in used]
    miss = [i for i, w in enumerate(words) if w['status'] == 'missing' and tn[i]]
    sm2 = difflib.SequenceMatcher(None, [tn[i] for i in miss], [vn[k] for k in free], autojunk=False)
    for blk in sm2.get_matching_blocks():
        if blk.size < 2 and (blk.size == 0 or len(tn[miss[blk.a]]) < 4):
            continue
        for k in range(blk.size):
            v = vw[free[blk.b + k]]
            words[miss[blk.a + k]].update(box=list(v[1:5]), line=vlines[free[blk.b + k]], status='vision-moved')
    # Third pass: Tesseract's words (tables and columns Vision skipped), over the stretches no box yet covers.
    # Its lines get their own ids, offset past Vision's, so the renumbering below keeps them apart.
    if tw:
        def covered(b):
            return any(overlap(b, w['box']) > 0.3 for w in words if w['box'])
        free = [k for k, t in enumerate(tw) if not covered(t[1:5])]
        miss = [i for i, w in enumerate(words) if w['status'] == 'missing' and tn[i]]
        tnn = [norm(tw[k][0]) for k in free]
        base = max(vlines, default=-1) + 1
        sm3 = difflib.SequenceMatcher(None, [tn[i] for i in miss], tnn, autojunk=False)
        for op, i1, i2, j1, j2 in sm3.get_opcodes():
            if op not in ('equal', 'replace') or i2 - i1 != j2 - j1:
                continue
            if op == 'equal' and i2 - i1 < 2 and len(tn[miss[i1]]) < 3:
                continue
            for k in range(i2 - i1):
                a, b = tn[miss[i1 + k]], tnn[j1 + k]
                if op == 'replace' and difflib.SequenceMatcher(None, a, b).ratio() < 0.6:
                    continue
                t = tw[free[j1 + k]]
                words[miss[i1 + k]].update(box=list(t[1:5]), line=base + t[5],
                                           status='tesseract' if op == 'equal' else 'tesseract-sub')
    # Unplaced words take the line of the placed word before them (or after, at the top of the page).
    last = next((w['line'] for w in words if w['line'] is not None), 0)
    for w in words:
        if w['line'] is None:
            w['line'] = last
        last = w['line']
    # Renumber lines in order of first appearance, so line ids follow the transcript.
    order = {}
    for w in words:
        order.setdefault(w['line'], len(order))
    for w in words:
        w['line'] = order[w['line']]
        if w['box']:
            w['box'] = [round(v, 5) for v in clamp(tight(w['box']) if tight else w['box'])]
    lines = []
    for ln in range(len(order)):
        ws = [w for w in words if w['line'] == ln]
        boxed = [w['box'] for w in ws if w['box']]
        line = {'id': ln, 'text': ' '.join(w['text'] for w in ws), 'box': None, 'baseline': None, 'status': 'drafted'}
        if boxed:
            line['box'] = [round(v, 5) for v in union(boxed)]
            pts = []
            fit = bottom_fit(boxed) if tight else None
            for b in sorted(boxed):
                for x in (b[0], b[0] + b[2]):
                    y = fit(x) if fit else b[1] + BASELINE_FRAC * b[3]
                    pts.append([round(x, 5), round(y, 5)])
            line['baseline'] = pts
        lines.append(line)
    return words, lines


def owner_pages():
    """(typed, hand): page ids. Typed from the 96 in its typewritten:printed mix; hand = every handwritten or
    mixed page with a truth file."""
    import csv
    kinds = {r['page']: r['kind'] for r in csv.DictReader(open(SCORED))}
    rows = list(csv.DictReader(open(TRUTH / 'pages.tsv'), delimiter='\t'))
    have = {p.stem for p in (TRUTH / 'truth').glob('p*.txt')}
    tw = seeded([p for p, k in kinds.items() if k == 'typewritten'])
    pr = seeded([p for p, k in kinds.items() if k == 'printed'])
    n_tw = round(N_TYPED * len(tw) / (len(tw) + len(pr)))
    typed = sorted(tw[:n_tw] + pr[:N_TYPED - n_tw])
    hand = sorted(r['page'] for r in rows if r['kind'] in ('handwritten', 'mixed') and r['page'] in have)
    allk = {r['page']: r['kind'] for r in rows}
    return typed, hand, allk, kinds


def build_owner(group, pages, allk, scored):
    vw_all = json.loads((TRUTH / 'vision-words.json').read_text())
    out = []
    for p in pages:
        img = TRUTH / 'pages' / f'{p}.jpg'
        text = (TRUTH / 'truth' / f'{p}.txt').read_text()
        g = Gray(img)
        tight = lambda b: tighten(g, b)
        words, lines = draft_owner(p, text, vw_all.get(p, []), tesseract_words(p, img), tight)
        W, H = image_size(img)
        out.append({'page': p, 'group': group, 'kind': allk.get(p, ''), 'in_96': p in scored,
                    'image': str(img), 'width': W, 'height': H, 'coords': 'normalised, top-left origin',
                    'words': words, 'lines': lines, 'audit': None})
    return out


# ---------------------------------------------------------------- public pages: free geometry

def _local(tag):
    return tag.rsplit('}', 1)[-1]


def _bbox(pts, W, H):
    xs = [x for x, _ in pts]; ys = [y for _, y in pts]
    return [round(min(xs) / W, 5), round(min(ys) / H, 5), round((max(xs) - min(xs)) / W, 5),
            round((max(ys) - min(ys)) / H, 5)]


class Gray:
    """A page as 8-bit grey at GRAY_SIDE on its long side, read through ImageMagick's PGM (no numpy here)."""

    def __init__(self, img: Path, side: int = 2400):
        raw = subprocess.run(['magick', str(img), '-colorspace', 'gray', '-resize', f'{side}x{side}>', '-depth', '8',
                              'pgm:-'], capture_output=True, check=True).stdout
        parts = raw.split(maxsplit=4)
        self.w, self.h, self.px = int(parts[1]), int(parts[2]), parts[4]
        self.px = self.px[len(self.px) - self.w * self.h:]

    def ink(self, box):
        """(x0, y0, x1, y1) of the crop in pixels and its rows as 0/1 ink lists, Otsu-thresholded inside the crop."""
        x0 = max(0, int(box[0] * self.w)); x1 = min(self.w, max(x0 + 1, int(round((box[0] + box[2]) * self.w))))
        y0 = max(0, int(box[1] * self.h)); y1 = min(self.h, max(y0 + 1, int(round((box[1] + box[3]) * self.h))))
        rows = [self.px[y * self.w + x0:y * self.w + x1] for y in range(y0, y1)]
        hist = [0] * 256
        for r in rows:
            for v in r:
                hist[v] += 1
        n = sum(hist); tot = sum(i * c for i, c in enumerate(hist))
        best, thr, wb, sb = -1.0, 128, 0, 0
        for t in range(256):
            wb += hist[t]; sb += t * hist[t]
            if wb == 0 or wb == n:
                continue
            mb, mf = sb / wb, (tot - sb) / (n - wb)
            v = wb * (n - wb) * (mb - mf) ** 2
            if v > best:
                best, thr = v, t
        return (x0, y0, x1, y1), [[1 if v <= thr else 0 for v in r] for r in rows]


def tighten(g: Gray, box):
    """A drafted word box trimmed to its own ink, so every owner box follows one convention (the tight box round
    the word's ink, as `gap_split` draws them) rather than Vision's or Tesseract's padding. A box with almost no
    ink in it, or whose ink is only a sliver of it, is kept as it was: trimming it would only find a speck."""
    (x0, y0, x1, y1), rows = g.ink(box)
    if not rows or not rows[0]:
        return box
    W = x1 - x0
    cols = [sum(r[c] for r in rows) for c in range(W)]
    noise = max(1, len(rows) // 40)
    cs = [c for c in range(W) if cols[c] > noise]
    rs = [y for y, r in enumerate(rows) if sum(r) > max(1, W // 50)]
    if not cs or not rs or sum(cols) < 0.02 * W * len(rows):
        return box
    a, b, top, bot = cs[0], cs[-1] + 1, rs[0], rs[-1] + 1
    if (b - a) < 0.3 * W or (bot - top) < 0.25 * len(rows):
        return box
    return [round((x0 + a) / g.w, 5), round((y0 + top) / g.h, 5), round((b - a) / g.w, 5), round((bot - top) / g.h, 5)]


def band_box(baseline, asc):
    """The box round a line drawn as a baseline (normalised points) and its ascender height above it."""
    xs = [x for x, _ in baseline]; ys = [y for _, y in baseline]
    return [min(xs), min(ys) - asc, max(xs) - min(xs), max(ys) - min(ys) + asc * (1 + DESC_FRAC)]


def gap_split(g: Gray, box, toks, baseline=None, asc=None):
    """Word boxes for `toks` inside a line box from the ink: the column gaps of the line (runs of columns with
    no ink) are candidate word breaks, and a dynamic programme picks one per break, in order, trading a gap's
    width against its distance from where the characters' share puts the break; a break with no gap near falls
    back to the share. Each word is then trimmed to its own ink. A draft: the audit judges it."""
    (x0, y0, x1, y1), rows = g.ink(box)
    W = x1 - x0; Hh = max(1, y1 - y0)
    if baseline and asc:  # keep only the ink in the band that follows the baseline, so a slanting line's box
        pts = sorted(baseline)  # does not pull in its neighbours' ascenders and descenders
        Hh = max(1, round(asc * g.h * (1 + DESC_FRAC)))

        def yb(xn):
            if xn <= pts[0][0]:
                return pts[0][1]
            for (ax, ay), (bx, by) in zip(pts, pts[1:]):
                if xn <= bx:
                    return ay + (by - ay) * (xn - ax) / max(1e-9, bx - ax)
            return pts[-1][1]
        lo = [round((yb((x0 + c) / g.w) - asc) * g.h) - y0 for c in range(W)]
        for y, r in enumerate(rows):
            for c in range(W):
                if r[c] and not (lo[c] <= y < lo[c] + Hh):
                    r[c] = 0
    cols = [sum(r[c] for r in rows) for c in range(W)]
    noise = max(1, Hh // 40)
    runs, c = [], 0
    while c < W:
        if cols[c] <= noise:
            s = c
            while c < W and cols[c] <= noise:
                c += 1
            if s > 0 and c < W:
                runs.append(((s + c) / 2, c - s))
        else:
            c += 1
    units = sum(len(t) for t in toks) + len(toks) - 1
    exp, pos = [], 0
    for t in toks[:-1]:
        pos += len(t) + 0.5
        exp.append(W * pos / units)
        pos += 0.5
    nb = len(exp)
    lam = GAP_LAMBDA / max(1.0, Hh)
    # DP over breaks j and candidate runs r (strictly increasing), or a virtual break at exp[j].
    import math
    cand = [(p, w) for p, w in runs]
    best = [[-math.inf] * (len(cand) + 1) for _ in range(nb + 1)]
    back = [[None] * (len(cand) + 1) for _ in range(nb + 1)]
    # state index len(cand) = "last break virtual"; track its position separately via exp.
    best[0][len(cand)] = 0.0

    def last_pos(j, s):
        return -1.0 if j == 0 else (exp[j - 1] if s == len(cand) else cand[s][0])

    for j in range(nb):
        for s in range(len(cand) + 1):
            if best[j][s] == -math.inf:
                continue
            lp = last_pos(j, s)
            v = best[j][s] - 1.0
            if exp[j] > lp and v > best[j + 1][len(cand)]:
                best[j + 1][len(cand)], back[j + 1][len(cand)] = v, s
            for r, (p, w) in enumerate(cand):
                if p <= lp:
                    continue
                v = best[j][s] + min(w, Hh) / Hh * 2 - lam * abs(p - exp[j])
                if v > best[j + 1][r]:
                    best[j + 1][r], back[j + 1][r] = v, s
    s = max(range(len(cand) + 1), key=lambda k: best[nb][k])
    cuts = []
    for j in range(nb, 0, -1):
        cuts.append(exp[j - 1] if s == len(cand) else cand[s][0])
        s = back[j][s]
    cuts = [0.0] + sorted(cuts) + [float(W)]
    out = []
    for k in range(len(toks)):
        a, b = int(cuts[k]), max(int(cuts[k]) + 1, int(cuts[k + 1]))
        cs = [c for c in range(a, b) if cols[c] > noise]
        rs = [y for y, r in enumerate(rows) if sum(r[a:b]) > max(1, (b - a) // 50)]
        if cs and rs:
            a, b = cs[0], cs[-1] + 1
            top, bot = rs[0], rs[-1] + 1
        else:
            top, bot = 0, Hh
        out.append([round((x0 + a) / g.w, 5), round((y0 + top) / g.h, 5), round((b - a) / g.w, 5),
                    round((bot - top) / g.h, 5)])
    return out


def derived_baseline(pts, W, H):
    """A straight baseline for a line known only as a polygon round its ink: the least-squares line through the
    polygon's points (its middle), moved down by BENTHAM_DROP of the polygon's height about that line."""
    n = len(pts)
    mx = sum(x for x, _ in pts) / n; my = sum(y for _, y in pts) / n
    sxx = sum((x - mx) ** 2 for x, _ in pts)
    slope = sum((x - mx) * (y - my) for x, y in pts) / sxx if sxx else 0.0
    res = sorted(y - (my + slope * (x - mx)) for x, y in pts)
    h = res[int(0.9 * (n - 1))] - res[int(0.1 * (n - 1))]
    x0, x1 = min(x for x, _ in pts), max(x for x, _ in pts)
    f = lambda x: my + slope * (x - mx) + BENTHAM_DROP * h
    return [[round(x0 / W, 5), round(f(x0) / H, 5)], [round(x1 / W, 5), round(f(x1) / H, 5)]]


def bentham_page(xml: Path, img: Path) -> dict:
    """Lines and words from a Bentham PAGE 2010 file, in src_bentham's reading order. Word elements carry no text:
    a line's tokens are given to its Word boxes left to right when the counts agree (3 of the 20 pages have Word
    elements at all); otherwise the line's box is split at its ink gaps (`gap_split`, `line-gaps`, a draft). PAGE 2010 here has no Baseline: `derived_baseline` drafts a
    straight one per line, so READ-BAD on L2 measures against a draft until the audit passes it."""
    import src_bentham as sb
    root = ET.fromstring(xml.read_bytes())
    W, H = image_size(img)
    regions = []
    for reg in root.iter():
        if _local(reg.tag) != 'TextRegion':
            continue
        lines = []
        for ln in reg.iter():
            if _local(ln.tag) != 'TextLine':
                continue
            text = sb.clean(sb._unicode(ln))
            pts = sb._points(ln)
            if not text.strip() or not pts:
                continue
            wboxes = [sb._points(w) for w in ln if _local(w.tag) == 'Word']
            wboxes = sorted((b for b in wboxes if b), key=lambda b: min(x for x, _ in b))
            lines.append((sum(y for _, y in pts) / len(pts), min(x for x, _ in pts), text, pts, wboxes))
        if not lines:
            continue
        lines.sort(key=lambda r: (r[0], r[1]))
        rpts = sb._points(reg) or [(x, 0) for _, x, _, _, _ in lines]
        regions.append((lines[0][0], min(x for x, _ in rpts), lines))
    regions.sort(key=lambda r: (r[0], r[1]))
    words, out_lines, g = [], [], None
    for _, _, lines in regions:
        for _, _, text, pts, wboxes in lines:
            ln = len(out_lines)
            toks = text.split()
            ok = len(toks) == len(wboxes)
            if not ok:
                g = g or Gray(img)
            shares = None if ok else gap_split(g, _bbox(pts, W, H), toks)
            for k, t in enumerate(toks):
                words.append({'text': t, 'box': _bbox(wboxes[k], W, H) if ok else shares[k], 'line': ln,
                              'status': 'page-xml' if ok else 'line-gaps'})
            out_lines.append({'id': ln, 'text': text, 'box': _bbox(pts, W, H),
                              'baseline': derived_baseline(pts, W, H), 'status': 'page-xml, baseline derived'})
    return {'words': words, 'lines': out_lines, 'width': W, 'height': H}


def alto_page(xml: Path, img: Path) -> dict:
    """Lines (box, baseline, text) from an ALTO v4 file; its Strings are whole lines, so there are no word boxes."""
    root = ET.fromstring(xml.read_bytes())
    page = next(e for e in root.iter() if _local(e.tag) == 'Page')
    W, H = int(page.get('WIDTH')), int(page.get('HEIGHT'))
    lines, words = [], []
    for tl in root.iter():
        if _local(tl.tag) != 'TextLine':
            continue
        text = ' '.join(s.get('CONTENT', '') for s in tl if _local(s.tag) == 'String').strip()
        if not text:
            continue
        x, y, w, h = (float(tl.get(k)) for k in ('HPOS', 'VPOS', 'WIDTH', 'HEIGHT'))
        base = None
        if tl.get('BASELINE') and ',' in tl.get('BASELINE'):
            base = [[round(float(a) / W, 5), round(float(b) / H, 5)]
                    for a, b in (p.split(',') for p in tl.get('BASELINE').split())]
        ln = len(lines)
        lines.append({'id': ln, 'text': text, 'box': [round(x / W, 5), round(y / H, 5), round(w / W, 5),
                                                       round(h / H, 5)], 'baseline': base, 'status': 'alto'})
        words += [{'text': t, 'box': None, 'line': ln, 'status': 'line-only'} for t in text.split()]
    return {'words': words, 'lines': lines, 'width': W, 'height': H}


def page2013(xml: Path, img: Path) -> dict:
    """Lines (box, baseline, text) from a PAGE 2013+ file with `points` attributes, in document order."""
    root = ET.fromstring(xml.read_bytes())
    page = next(e for e in root.iter() if _local(e.tag) == 'Page')
    W, H = int(page.get('imageWidth')), int(page.get('imageHeight'))
    lines, words = [], []
    parse = lambda s: [tuple(int(float(v)) for v in p.split(',')) for p in s.split()]
    for tl in root.iter():
        if _local(tl.tag) != 'TextLine':
            continue
        coords = next((c for c in tl if _local(c.tag) == 'Coords'), None)
        base = next((c for c in tl if _local(c.tag) == 'Baseline'), None)
        eq = [u for c in tl if _local(c.tag) == 'TextEquiv' for u in c if _local(u.tag) == 'Unicode']
        text = (eq[0].text or '').strip() if eq else ''
        if not text or coords is None:
            continue
        ln = len(lines)
        lines.append({'id': ln, 'text': text, 'box': _bbox(parse(coords.get('points')), W, H),
                      'baseline': [[round(x / W, 5), round(y / H, 5)] for x, y in parse(base.get('points'))]
                      if base is not None else None, 'status': 'page-xml'})
        words += [{'text': t, 'box': None, 'line': ln, 'status': 'line-only'} for t in text.split()]
    return {'words': words, 'lines': lines, 'width': W, 'height': H}


def build_public():
    rows = [json.loads(l) for l in open(MANIFEST)]
    out = []
    for r in rows:
        if r['stratum'] == 'L2' and r['source'] == 'bentham':
            stem = r['page_id'].split('/')[-1]
            xml = BENCH / 'raw/bentham/BenthamDatasetR0-GT/PAGE' / f'{stem}.xml'
            img = FROZEN / 'L2' / f'bentham__{stem}.jpg'
            d = bentham_page(xml, img)
            group = 'L2-bentham'
        elif r['stratum'] == 'N6':
            book, name = r['page_id'].split('/')
            img = FROZEN / 'N6' / f'devanagari__{book}_{name}.jpg'
            if not img.exists():
                img = next(FROZEN.glob(f'N6/devanagari__{book}*{name}.jpg'))
            xml = BENCH / 'raw/devanagari/alto' / book / f'{name}.xml'
            d = alto_page(xml, img) if b'<alto' in xml.read_bytes()[:2000] else page2013(xml, img)
            group = 'N6'
        else:
            continue
        out.append({'page': r['page_id'], 'group': group, 'kind': r['kind'], 'in_96': False, 'image': str(img),
                    'coords': 'normalised, top-left origin', 'audit': None, **d})
    return out


# ---------------------------------------------------------------- PAGE-XML and the summary

def page_xml(p: dict) -> str:
    W, H = p['width'], p['height']

    def pts(b):
        x, y, w, h = b
        return ' '.join(f'{round(a * W)},{round(c * H)}' for a, c in ((x, y), (x + w, y), (x + w, y + h), (x, y + h)))

    ns = 'http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15'
    root = ET.Element('PcGts', xmlns=ns)
    meta = ET.SubElement(root, 'Metadata')
    ET.SubElement(meta, 'Creator').text = 'W46.fix-place-truth place_truth.py'
    pg = ET.SubElement(root, 'Page', imageFilename=Path(p['image']).name, imageWidth=str(W), imageHeight=str(H))
    reg = ET.SubElement(pg, 'TextRegion', id='r0')
    boxes = [l['box'] for l in p['lines'] if l['box']]
    ET.SubElement(reg, 'Coords', points=pts(union(boxes)) if boxes else '0,0 1,0 1,1 0,1')
    for l in p['lines']:
        tl = ET.SubElement(reg, 'TextLine', id=f"l{l['id']}", custom=f"status:{l['status']}")
        ET.SubElement(tl, 'Coords', points=pts(l['box']) if l['box'] else '0,0 1,0 1,1 0,1')
        if l['baseline']:
            ET.SubElement(tl, 'Baseline', points=' '.join(f'{round(x * W)},{round(y * H)}' for x, y in l['baseline']))
        for k, w in enumerate(x for x in p['words'] if x['line'] == l['id']):
            if not w['box']:
                continue
            we = ET.SubElement(tl, 'Word', id=f"l{l['id']}w{k}", custom=f"status:{w['status']}")
            ET.SubElement(we, 'Coords', points=pts(w['box']))
            ET.SubElement(ET.SubElement(we, 'TextEquiv'), 'Unicode').text = w['text']
        ET.SubElement(ET.SubElement(tl, 'TextEquiv'), 'Unicode').text = l['text']
    ET.indent(root)
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(root, encoding='unicode') + '\n'


def summarise(pages: list[dict]) -> dict:
    groups = {}
    for p in pages:
        g = groups.setdefault(p['group'], {'pages': 0, 'words': 0, 'lines': 0, 'baselines': 0, 'status': {},
                                           'lines_per_page': []})
        g['pages'] += 1
        g['words'] += len(p['words'])
        g['lines'] += len(p['lines'])
        g['baselines'] += sum(1 for l in p['lines'] if l['baseline'])
        g['lines_per_page'].append(len(p['lines']))
        for w in p['words']:
            g['status'][w['status']] = g['status'].get(w['status'], 0) + 1
    for g in groups.values():
        g['median_lines_per_page'] = median(g.pop('lines_per_page'))
    per_page = [{'page': p['page'], 'group': p['group'], 'kind': p['kind'], 'in_96': p['in_96'],
                 'words': len(p['words']), 'lines': len(p['lines']),
                 'missing': sum(1 for w in p['words'] if w['status'] == 'missing'),
                 'audit': (p.get('audit') or {}).get('verdict')} for p in pages]
    return {'groups': groups, 'pages': per_page}


def write(pages):
    STORE.mkdir(parents=True, exist_ok=True)
    (STORE / 'xml').mkdir(exist_ok=True)
    for p in pages:
        name = p['page'].replace('/', '__')
        old = STORE / f'{name}.json'
        if old.exists():  # never clobber a corrected or audited page with a fresh draft
            prev = json.loads(old.read_text())
            if prev.get('corrected') or prev.get('audit'):
                p = prev
        (STORE / f'{name}.json').write_text(json.dumps(p, ensure_ascii=False, indent=1))
        (STORE / 'xml' / f'{name}.xml').write_text(page_xml(p))


COLOURS = {'vision': 'lime', 'vision-sub': 'yellow', 'vision-moved': 'yellow', 'split': 'orange',
           'line-share': 'orange', 'line-gaps': 'orange', 'page-xml': 'dodgerblue', 'corrected': 'magenta',
           'tesseract': 'cyan', 'tesseract-sub': 'cyan', 'drawn': 'magenta'}


def overlay(p: dict, out: Path, long_side: int = 1800) -> Path:
    """The page image with its word boxes (by status colour) and baselines (red), for the audit; ImageMagick."""
    W, H = p['width'], p['height']
    k = long_side / max(W, H)
    cmd = ['magick', p['image'], '-resize', f'{round(W * k)}x{round(H * k)}!', '-fill', 'none', '-strokewidth', '2']
    for w in p['words']:
        if w['box']:
            x, y, bw, bh = (v * s for v, s in zip(w['box'], (W * k, H * k, W * k, H * k)))
            cmd += ['-stroke', COLOURS.get(w['status'], 'gray'), '-draw', f'rectangle {x:.0f},{y:.0f} {x + bw:.0f},{y + bh:.0f}']
    for l in p['lines']:
        if l['baseline'] and len(l['baseline']) >= 2:
            pts = ' '.join(f'{x * W * k:.0f},{y * H * k:.0f}' for x, y in l['baseline'])
            cmd += ['-stroke', 'red', '-draw', f'polyline {pts}']
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(cmd + ['-quality', '80', str(out)], check=True)
    return out


def grid(p: dict, out: Path, long_side: int = 1800, step: int = 50) -> Path:
    """The page image with a permille grid (a line every `step`, labelled every 100), for drawing a line spec."""
    W, H = p['width'], p['height']
    k = long_side / max(W, H)
    w, h = round(W * k), round(H * k)
    cmd = ['magick', p['image'], '-resize', f'{w}x{h}!', '-fill', 'none', '-strokewidth', '1']
    for v in range(step, 1000, step):
        col = 'blue' if v % 100 == 0 else 'lightblue'
        cmd += ['-stroke', col, '-draw', f'line {v * w / 1000:.0f},0 {v * w / 1000:.0f},{h}',
                '-draw', f'line 0,{v * h / 1000:.0f} {w},{v * h / 1000:.0f}']
    cmd += ['-stroke', 'none', '-fill', 'blue', '-font', GRID_FONT, '-pointsize', '14']
    for v in range(100, 1000, 100):
        cmd += ['-draw', f'text {v * w / 1000 + 2:.0f},14 "{v}"', '-draw', f'text 2,{v * h / 1000 - 2:.0f} "{v}"']
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(cmd + ['-quality', '80', str(out)], check=True)
    return out


def bands(p: dict, x0: float, x1: float, y0: float = 0, y1: float = 1000, min_rows: int = 2) -> list:
    """The bands of inked rows inside a strip of the page (permille), as (top, bottom) in permille: where the
    lines of text in that strip sit, for snapping a drawn line box to its ink."""
    g = Gray(Path(p['image']))
    _, rows = g.ink([x0 / 1000, y0 / 1000, (x1 - x0) / 1000, (y1 - y0) / 1000])
    thr = max(1, len(rows[0]) // 200) if rows else 1
    out, start = [], None
    for k, r in enumerate(rows + [[0]]):
        on = sum(r) > thr
        if on and start is None:
            start = k
        elif not on and start is not None:
            if k - start >= min_rows:
                out.append((round(y0 + start * 1000 / g.h, 1), round(y0 + k * 1000 / g.h, 1)))
            start = None
    return out


def zoom(p: dict, x0: float, y0: float, x1: float, y1: float, out: Path, width: int = 1600) -> Path:
    """A permille region of the page enlarged, with a grid line every 10 permille labelled every 50: reading
    coordinates off a close view without doing the crop's arithmetic."""
    W, H = p['width'], p['height']
    px0, py0 = round(x0 * W / 1000), round(y0 * H / 1000)
    pw, ph = max(1, round((x1 - x0) * W / 1000)), max(1, round((y1 - y0) * H / 1000))
    k = width / pw
    w, h = width, round(ph * k)
    sx, sy = w / (x1 - x0), h / (y1 - y0)
    cmd = ['magick', p['image'], '-crop', f'{pw}x{ph}+{px0}+{py0}', '+repage', '-resize', f'{w}x{h}!',
           '-fill', 'none', '-strokewidth', '1']
    labels = []
    for v in range(int(x0 // 10 + 1) * 10, int(x1), 10):
        cmd += ['-stroke', 'blue' if v % 50 == 0 else 'lightblue', '-draw', f'line {(v - x0) * sx:.0f},0 {(v - x0) * sx:.0f},{h}']
        if v % 50 == 0:
            labels.append(f'text {(v - x0) * sx + 2:.0f},14 "{v}"')
    for v in range(int(y0 // 10 + 1) * 10, int(y1), 10):
        cmd += ['-stroke', 'blue' if v % 50 == 0 else 'lightblue', '-draw', f'line 0,{(v - y0) * sy:.0f} {w},{(v - y0) * sy:.0f}']
        if v % 50 == 0:
            labels.append(f'text 2,{(v - y0) * sy - 2:.0f} "{v}"')
    cmd += ['-stroke', 'none', '-fill', 'blue', '-font', GRID_FONT, '-pointsize', '14']
    for t in labels:
        cmd += ['-draw', t]
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(cmd + ['-quality', '85', str(out)], check=True)
    return out


def apply_lines(page_id: str, spec_path: Path, by: str) -> dict:
    """Redraw a page from a line spec drawn on its `grid` render: JSON {"lines": [{"text", "baseline": [[x, y],
    ...], "height"}]}, permille of the page's width and height: the baseline under the line from its first letter
    to its last, and the height of its tall letters above the baseline. Lines go in transcript order, their texts
    together exactly the transcript's tokens. A "box": [x0, y0, x1, y1] may stand in for "height" on a level
    line. Word boxes come from `gap_split` in the band along the baseline (or inside the box) (`drawn`);
    an optional "words": [[x0, y0, x1, y1], ...] per line, one per token, overrides the split; a line with
    "absent": true holds transcript words the image does not show (left unboxed). Raises on a text
    mismatch, so a spec that drops or reorders words never lands."""
    f = STORE / f"{page_id.replace('/', '__')}.json"
    p = json.loads(f.read_text())
    spec = json.loads(Path(spec_path).read_text())
    toks = [w['text'] for w in p['words']]
    got = [t for ln in spec['lines'] for t in ln['text'].split()]
    if got != toks:
        sm = difflib.SequenceMatcher(None, got, toks, autojunk=False)
        diffs = [(op, got[i1:i2], toks[j1:j2]) for op, i1, i2, j1, j2 in sm.get_opcodes() if op != 'equal']
        raise SystemExit(f'{page_id}: the spec\'s words are not the transcript\'s (spec, transcript): {diffs[:8]}')
    g = Gray(Path(p['image']))
    pm = lambda b: [b[0] / 1000, b[1] / 1000, (b[2] - b[0]) / 1000, (b[3] - b[1]) / 1000]
    words, lines, i = [], [], 0
    for ln_id, ln in enumerate(spec['lines']):
        lt = ln['text'].split()
        if ln.get('absent'):  # words the transcript has and the image does not show: no box, unscored
            for t in lt:
                words.append({'text': t, 'box': None, 'line': ln_id, 'status': 'missing'})
                i += 1
            lines.append({'id': ln_id, 'text': ln['text'], 'box': None, 'baseline': None, 'status': 'absent'})
            continue
        bl = [[x / 1000, y / 1000] for x, y in ln['baseline']]
        asc = ln['height'] / 1000 if ln.get('height') else None
        box = pm(ln['box']) if ln.get('box') else band_box(bl, asc)
        wb = [pm(b) for b in ln['words']] if ln.get('words') else gap_split(g, box, lt, bl, asc)
        if len(wb) != len(lt):
            raise SystemExit(f'{page_id} line {ln_id}: {len(wb)} word boxes for {len(lt)} words')
        for t, b in zip(lt, wb):
            st = 'illegible' if p['words'][i]['status'] == 'illegible' else 'drawn'
            words.append({'text': t, 'box': [round(v, 5) for v in clamp(b)], 'line': ln_id, 'status': st})
            i += 1
        bl = [[round(x, 5), round(y, 5)] for x, y in bl]
        if not ln.get('box'):  # the line box is the words' union, not the band, which is generous by design
            box = union(wb)
        lines.append({'id': ln_id, 'text': ln['text'], 'box': [round(v, 5) for v in clamp(box)], 'baseline': bl,
                      'status': 'drawn'})
    p.update(words=words, lines=lines, corrected=True, drawn_by=by, audit=None)
    f.write_text(json.dumps(p, ensure_ascii=False, indent=1))
    (STORE / 'xml' / f'{f.stem}.xml').write_text(page_xml(p))
    return p


def record_audit(page_id: str, verdict: str, note: str, by: str) -> None:
    """Store an auditor's verdict (ok / fix / redraw) on a page; a page with an audit is never redrafted."""
    f = STORE / f"{page_id.replace('/', '__')}.json"
    p = json.loads(f.read_text())
    p['audit'] = {'verdict': verdict, 'note': note, 'by': by}
    f.write_text(json.dumps(p, ensure_ascii=False, indent=1))


def load_all() -> list[dict]:
    return [json.loads(f.read_text()) for f in sorted(STORE.glob('*.json'))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=['build', 'summary', 'overlay', 'grid', 'zoom', 'bands', 'lines', 'audit'])
    ap.add_argument('rest', nargs='*', help='overlay, grid: page ids (none = all); bands: page x0 x1 [y0 y1]; '
                                            'lines: page spec by; '
                                            'audit: page verdict note by')
    a = ap.parse_args()
    if a.cmd == 'grid':
        for p in load_all():
            if p['page'] in a.rest:
                print(grid(p, STORE / 'grid' / f"{p['page'].replace('/', '__')}.jpg"))
        return
    if a.cmd == 'zoom':
        p = next(q for q in load_all() if q['page'] == a.rest[0])
        x0, y0, x1, y1 = map(float, a.rest[1:5])
        print(zoom(p, x0, y0, x1, y1, Path('/tmp') / f"place-zoom-{p['page'].replace('/', '__')}-{x0:.0f}-{y0:.0f}.jpg"))
        return
    if a.cmd == 'bands':
        p = next(q for q in load_all() if q['page'] == a.rest[0])
        for top, bot in bands(p, *map(float, a.rest[1:])):
            print(f'{top:7.1f} {bot:7.1f}')
        return
    if a.cmd == 'lines':
        p = apply_lines(*a.rest)
        print(overlay(p, STORE / 'overlay' / f"{p['page'].replace('/', '__')}.jpg"))
        return
    if a.cmd == 'overlay':
        for p in load_all():
            if not a.rest or p['page'] in a.rest:
                print(overlay(p, STORE / 'overlay' / f"{p['page'].replace('/', '__')}.jpg"))
        return
    if a.cmd == 'audit':
        record_audit(*a.rest)
    if a.cmd == 'build':
        typed, hand, allk, scored = owner_pages()
        pages = build_owner('owner-typed', typed, allk, scored) + build_owner('owner-hand', hand, allk, scored)
        pages += build_public()
        write(pages)
    s = summarise(load_all())
    (RESULTS / 'place-truth.json').write_text(json.dumps(s, indent=1) + '\n')
    print(json.dumps(s['groups'], indent=1))


if __name__ == '__main__':
    main()
