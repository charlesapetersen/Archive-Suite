"""W46.place-hands — whether handwritten pages can leave the text page (F-placement §7 test 4, 10-gap-audit §5 item 23).

Step one, the line detectors on the placement truth's hand pages (`place_truth.py`: the owner's 21 handwritten or
mixed pages and the 20 Bentham pages, the only L1/L2 pages with published geometry; By the People, L1, ships text
only, so the plan's "160 L1/L2 pages" are the 20 that can be scored):

  blla      kraken 7.1.1's default baseline segmenter, CPU (the Vision OCR lab's venv-kraken).
  orli      Orli base (zenodo 20558179, Apache-2.0), on the Mac's GPU (MPS) in bf16, else CPU.
  surya     Surya 0.22 text-line detection (measurement only: OpenRAIL-M), MPS.
  ppocrv6   PP-OCRv6 medium det, the pinned FarmShare run's saved polygons (FarmShare-ppocrv6-20261019 for the 895,
            FarmShare-truth96-20261020 for the owner's 99), read on 2400-px copies and scaled up. Not rerun on the
            Mac: at the pinned settings (max side 4000) one Bentham page peaked at 32 GB on CPU, past this 18 GB
            Mac, and paddlex 3.7.2 has no MPS device.

Box detectors (surya, ppocrv6) give quads, often a line in pieces: pieces that share a row are joined into one line,
its baseline drawn at place_truth's BASELINE_FRAC of each piece's height. Scores: place_score's READ-BAD-style
baseline R, P, F against the hand baselines, and the share of truth word boxes whose centre lies inside some line.

Step two, readings placed on the lines (every detector, so the pick is visible, not assumed):

  prop      our proportional aligner: the reading's lines matched in order to runs of consecutive detected lines
            (one to 8 of them, the `-s8` methods beside the one-to-one `-s1`, since a reader may reflow a paragraph into one line, as LightOnOCR-3 does) by a
            monotone dynamic programme on length (characters against the lines' length, page-relative); a run's
            words shared out by the lines' lengths, then placed along each baseline in proportion to their
            characters. What every production writer does within a line.
  flow      the reading's words poured across the detected lines in order, by the lines' lengths; ignores the
            reading's line breaks.
  ctc-<m>   forced alignment through a kraken CTC recogniser <m>: each detected line is recognised, the reading's
            lines are matched to runs of them by the same programme on character error instead of length, and each
            reading line is force-aligned over its run's frames joined end to end, which also decides where a
            reflowed line breaks (ctc_char_spans); a run it cannot align falls back to proportional. Models: `revcity` (zenodo 19238205, an
            English 18th-century archival hand) and `mccatmus` (McCATMuS, zenodo 13788177, 16th-21st c.). The
            alignment runs on the recogniser's logits (see ctc_char_spans: kraken 7.1.1's own cut positions are
            wrong); word boxes take the line's height as `prop` does, so the two differ only in where along the
            line each word falls.

Matchers (W46.place-hands-fu): `prop` and `ctc-<m>` each write `-s1` (one reading line to one detected line) and
`-s8` (to a run of up to 8); `ctc-<m>` also writes three per-page picks between them, `-lines` (the reading's line
count against the detected lines), `-conf` (mean CTC confidence) and `-cer` (the matched runs' character error).
Every ctc hypothesis carries the gate's features in its `meta`: `page_cer` (the recogniser against the whole
reading), `ctc_conf` and `match_cer`; `score` sweeps each as the per-page gate that sends a page to the text page.

Readings: `truth` (the line-broken truth text itself: what the geometry and the aligner lose with a perfect
reader), `lightonocr3-4b` (FarmShare's saved readings, both groups) and `gemini3.8-flash` (the cloud panel's,
owner pages only: no Gemini reading of the Bentham pages exists and this item has no paid arm). Scores: place_score's
word F1 (at centre, ranked; 0.5 and 0.7 beside), line-level alignment accuracy, and place_functional's Find and
placed-hit on a PDF written with the hypothesis's words.

Usage (system python3 unless noted; each detector runs itself under its own venv):
  python3 place_hands.py detect blla|orli|surya|ppocrv6 [--pages p007,...]
  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy python place_hands.py readings
  python3 place_hands.py align DET METHOD [READING ...]      # METHOD prop | flow | ctc-revcity | ctc-mccatmus
  python3 place_hands.py score                               # segbench-results/place-hands.json and .md
Cache (private: page text and geometry): ~/Library/Caches/ArchiveSuiteRehearsal/place-hands/.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import place_truth  # noqa: E402
import place_score  # noqa: E402

CACHE = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/place-hands'
RESULTS = HERE.parent.parent / 'segbench-results'
LTS = Path(os.environ.get('FARMSHARE_STORE', Path.home() / 'Claude/Long term storage'))
HTRMOPO = Path.home() / 'Library/Application Support/htrmopo'
GROUPS = ('owner-hand', 'L2-bentham')
VENV = {
    'blla': Path.home() / '.local/share/visionocr-ocrlab/venv-kraken/bin/python',
    'orli': CACHE / 'venv-orli/bin/python',
    'surya': CACHE / 'venv-surya/bin/python',
    'ctc': Path.home() / '.local/share/visionocr-ocrlab/venv-kraken/bin/python',
}
MODELS = {
    'orli': HTRMOPO / 'c690cc12-0cf5-59dd-af71-69cdef2392b2/orli_base.safetensors',
    'revcity': HTRMOPO / 'd71b1ba1-6d9b-57f7-b85a-ea6a19a4820f/revcity_july_2025.mlmodel',
    'mccatmus': HTRMOPO / '78d7d26e-50b3-55f8-b839-c7a882ea2053/McCATMuS_nfd_nofix_V1.mlmodel',
}
PPOCR = [LTS / 'FarmShare-ppocrv6-20261019/outputs/ppocrv6-medium-native/raw',
         LTS / 'FarmShare-truth96-20261020/outputs/ppocrv6-medium-native/raw']
PPOCR_IMAGES = lambda name: [Path.home() / f'Library/Caches/ArchiveSuiteRehearsal/ocr-panel-local/images/{name}-original.jpg',
                              LTS / f'FarmShare-20261019/ocr/images/{name}.jpg']
READINGS = ('truth', 'lightonocr3-4b', 'gemini3.8-flash')
FRAC = place_truth.BASELINE_FRAC
ROW_OVERLAP = 0.5   # two pieces are one line when their vertical overlap is this share of the shorter's height
SKIP = {'length': 1.5, 'text': 0.6}   # DP cost of leaving a reading line or a detected line unmatched


def pages(only=None):
    out = [t for t in place_truth.load_all() if t['group'] in GROUPS]
    return [t for t in out if not only or t['page'] in only]


def key(t):
    return t['page'].replace('/', '__')


def save(path: Path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix('.part')
    tmp.write_text(json.dumps(obj, ensure_ascii=False) + '\n')
    tmp.replace(path)


def sha(path) -> str:
    with open(path, 'rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


# ---------------------------------------------------------------- geometry (pixels inside, normalised outside)

def bbox(pts):
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    return [min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)]


def polylen(pts):
    return sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(pts, pts[1:]))


def area(poly):
    return abs(sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(poly, poly[1:] + poly[:1]))) / 2


def at(pts, s):
    """The point at arc length s along a polyline (clamped)."""
    if len(pts) == 1:
        return pts[0]
    for a, b in zip(pts, pts[1:]):
        d = math.hypot(b[0] - a[0], b[1] - a[1])
        if s <= d or b is pts[-1]:
            f = 0.0 if d == 0 else max(0.0, min(1.0, s / d))
            return (a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f)
        s -= d
    return pts[-1]


def inside_poly(p, poly):
    x, y, hit = p[0], p[1], False
    for (x0, y0), (x1, y1) in zip(poly, poly[1:] + poly[:1]):
        if (y0 > y) != (y1 > y) and x < x0 + (y - y0) * (x1 - x0) / (y1 - y0):
            hit = not hit
    return hit


def quad_line(q):
    """A quad (any corner order) as a line piece: its top and bottom edges, baseline at FRAC of its height."""
    q = sorted(q, key=lambda p: p[0])
    left, right = sorted(q[:2], key=lambda p: p[1]), sorted(q[2:], key=lambda p: p[1])
    (tl, bl), (tr, br) = left, right
    base = [(tl[0] + (bl[0] - tl[0]) * FRAC, tl[1] + (bl[1] - tl[1]) * FRAC),
            (tr[0] + (br[0] - tr[0]) * FRAC, tr[1] + (br[1] - tr[1]) * FRAC)]
    return {'top': [tl, tr], 'bottom': [bl, br], 'baseline': base}


def join_rows(pieces):
    """Pieces that share a row become one line, ordered top to bottom and left to right within it."""
    def span(p):
        ys = [pt[1] for pt in p['top'] + p['bottom']]
        return min(ys), max(ys)
    rows = []
    for p in sorted(pieces, key=lambda p: sum(span(p)) / 2):
        y0, y1 = span(p)
        for r in rows:
            r0, r1 = r['span']
            ov = min(y1, r1) - max(y0, r0)
            if ov >= ROW_OVERLAP * min(y1 - y0, r1 - r0) and not any(
                    min(p['top'][1][0], q['top'][1][0]) > max(p['top'][0][0], q['top'][0][0]) for q in r['pieces']):
                r['pieces'].append(p)
                r['span'] = (min(r0, y0), max(r1, y1))
                break
        else:
            rows.append({'pieces': [p], 'span': (y0, y1)})
    lines = []
    for r in rows:
        ps = sorted(r['pieces'], key=lambda p: p['top'][0][0])
        top = [pt for p in ps for pt in p['top']]
        bottom = [pt for p in ps for pt in p['bottom']]
        lines.append({'baseline': [pt for p in ps for pt in p['baseline']], 'boundary': top + bottom[::-1]})
    return lines


def normalise(lines, W, H, seconds=None, **extra):
    out = []
    for ln in lines:
        b = ln['boundary'] if ln.get('boundary') else ln['baseline']
        x, y, w, h = bbox(b)
        out.append({'baseline': [[px / W, py / H] for px, py in ln['baseline']],
                    'boundary': [[px / W, py / H] for px, py in ln['boundary']] if ln.get('boundary') else None,
                    'box': [x / W, y / H, w / W, h / H]})
    return {'width': W, 'height': H, 'seconds': seconds, 'lines': out, **extra}


# ---------------------------------------------------------------- step one: detectors

def detect_blla(todo):
    """kraken's CLI in one call over the pages; PAGE-XML parsed here. Seconds are the call's, shared out."""
    xml_dir = CACHE / 'blla-xml'
    xml_dir.mkdir(parents=True, exist_ok=True)
    args = [str(VENV['blla'].parent / 'kraken')]
    for t in todo:
        args += ['-i', t['image'], str(xml_dir / f'{key(t)}.xml')]
    t0 = time.time()
    subprocess.run(args + ['-x', 'segment', '-bl'], check=True, stdout=subprocess.DEVNULL)
    per = (time.time() - t0) / max(1, len(todo))
    ns = {'p': 'http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15'}
    for t in todo:
        root = ET.parse(xml_dir / f'{key(t)}.xml').getroot()
        lines = []
        for tl in root.iter(f"{{{ns['p']}}}TextLine"):
            bl, co = tl.find('p:Baseline', ns), tl.find('p:Coords', ns)
            pts = lambda e: [tuple(map(float, xy.split(','))) for xy in e.get('points').split()]
            if bl is not None:
                lines.append({'baseline': pts(bl), 'boundary': pts(co) if co is not None else None})
        save(CACHE / 'lines/blla' / f'{key(t)}.json',
             normalise(lines, t['width'], t['height'], per, device='cpu (one core per call)'))


def detect_orli(todo):
    import torch
    from PIL import Image
    from kraken.models import load_models
    from kraken.tasks.segmentation import SegmentationTaskModel
    from orli.configs import OrliSegmentationInferenceConfig
    dev, prec = ('mps', 'bf16-true') if torch.backends.mps.is_available() else ('cpu', '32-true')
    # orli.pred.segment, with the model loaded once rather than per page
    task = SegmentationTaskModel(load_models(MODELS['orli'], tasks=['segmentation']))
    for t in todo:
        im = Image.open(t['image'])
        t0 = time.time()
        seg = task.predict(im, OrliSegmentationInferenceConfig(accelerator=dev, device='auto', precision=prec,
                                                               polygonize=True))
        sec = time.time() - t0
        pts = lambda a: [(float(x), float(y)) for x, y in a] if a is not None and len(a) else None
        lines = [{'baseline': pts(ln.baseline), 'boundary': pts(ln.boundary)} for ln in seg.lines if pts(ln.baseline)]
        save(CACHE / 'lines/orli' / f'{key(t)}.json',
             normalise(lines, im.width, im.height, sec, device=f'{dev} {prec}'))


def detect_surya(todo):
    from PIL import Image
    from surya.detection import DetectionPredictor
    det = DetectionPredictor()
    for t in todo:
        im = Image.open(t['image']).convert('RGB')
        t0 = time.time()
        pred = det([im])[0]
        sec = time.time() - t0
        pieces = [quad_line(b.polygon) for b in pred.bboxes]
        save(CACHE / 'lines/surya' / f'{key(t)}.json',
             normalise(join_rows(pieces), im.width, im.height, sec, device='mps', pieces=len(pieces)))


def detect_ppocrv6(todo):
    """The pinned run read 2400-px copies (the owner's from ocr-panel-local, the 895's from FarmShare-20261019's
    pack): each copy is found by the hash the run recorded and its polygons are scaled up to the truth image."""
    for t in todo:
        name = ('bentham__' if t['group'] == 'L2-bentham' else '') + t['page']
        src = next((d / f'{name}.json' for d in PPOCR if (d / f'{name}.json').exists()), None)
        if src is None:
            print('no saved PP-OCRv6 run for', t['page'])
            continue
        got = json.loads(src.read_text())
        copy = next((c for c in PPOCR_IMAGES(name) if c.exists() and sha(c) == got['sha256']), None)
        if copy is None:
            print('no image with the hash PP-OCRv6 ran on for', t['page'], '- skipped')
            continue
        cw, ch = place_truth.image_size(copy)
        sx, sy = t['width'] / cw, t['height'] / ch
        if abs(sx - sy) > 0.01 * sx:
            print('the copy PP-OCRv6 read is not a uniform scale of', t['page'], '- skipped')
            continue
        quads = [[(x * sx, y * sy) for x, y in q] for q in got['native']['res']['dt_polys']]
        pieces = [quad_line(q) for q in quads]
        save(CACHE / 'lines/ppocrv6' / f'{key(t)}.json',
             normalise(join_rows(pieces), t['width'], t['height'], None, pieces=len(pieces),
                       device=f'saved FarmShare run on a {cw}x{ch} copy', source=str(src.relative_to(LTS))))


DETECTORS = {'blla': detect_blla, 'orli': detect_orli, 'surya': detect_surya, 'ppocrv6': detect_ppocrv6}


# ---------------------------------------------------------------- readings

def clean(text: str) -> list[str]:
    """A reading as its lines: markdown and markup off, empty and rule lines dropped."""
    out = []
    for ln in text.splitlines():
        ln = re.sub(r'<[^>]+>', ' ', ln)
        ln = re.sub(r'\[illegible\]', ' ', ln, flags=re.I)
        ln = re.sub(r'^\s*(#+|>|[-*+]\s)\s*', '', ln)
        ln = ln.replace('**', '').replace('__', '').replace('|', ' ')
        ln = ' '.join(ln.split())
        if ln and not re.fullmatch(r'[-=:_ ]+', ln):
            out.append(ln)
    return out


def export_readings():
    import ocr_rescore as O
    import routes as R
    R.MANIFEST = O.RESULTS / 'bench-corpus/manifest.jsonl'
    ps = pages()
    owner = O.owner_sources()
    bentham = [r for r in R.frozen() if r['source'] == 'bentham']
    public = O.public_sources(bentham)
    for route in READINGS[1:]:
        o = next((v for (k, _), v in owner.items() if k == route), {})
        p = next((v for (k, _), v in public.items() if k == route), {})
        n = 0
        for t in ps:
            text = o.get(t['page']) if t['group'] == 'owner-hand' else p.get('bentham__' + t['page'])
            if text:
                n += 1
                f = CACHE / 'readings' / route / f'{key(t)}.txt'
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text(text)
        print(route, n, 'pages')


def reading(t, route):
    if route == 'truth':
        return [' '.join(ln['text'].split()) for ln in t['lines'] if ln.get('text', '').strip()]
    f = CACHE / 'readings' / route / f'{key(t)}.txt'
    return clean(f.read_text()) if f.exists() else None


# ---------------------------------------------------------------- step two: placement

def px_lines(det, W, H):
    out = []
    for ln in det['lines']:
        bl = [(x * W, y * H) for x, y in ln['baseline']]
        bd = [(x * W, y * H) for x, y in ln['boundary']] if ln.get('boundary') else None
        L = polylen(bl)
        h = (area(bd) / L) if bd and L > 0 else ln['box'][3] * H
        out.append({'baseline': bl, 'boundary': bd, 'len': max(L, 1.0), 'h': max(h, 4.0), 'box': ln['box']})
    return out


SPANS = (1, 8)  # the two matchers: one-to-one, and a reading line over up to 8 consecutive detected lines (a reader
#   that reflows a paragraph, as LightOnOCR-3 does). W46.place-hands: the span matcher lifts a reflowing reader and
#   costs a line-faithful one, so every placer writes both (method suffix -s1, -s8) and the CTC placer a per-page pick.
SPAN_COST = 0.05  # per extra line covered, so a one-to-one reading is preferred when the costs tie
REFLOW = 0.7  # the line-count pick: a reading with fewer lines than this share of the detected ones has reflowed


def dp_match(n_read, n_det, cost, skip, span):
    """Monotone matching of reading lines to runs of consecutive detected lines: reading line i covers detected
    lines j..j+k-1 (k = 1..span) at cost(i, j, k); a reading line or a detected line left unmatched costs `skip`.
    Returns {reading index: (first detected index, count)}."""
    INF = float('inf')
    D = [[INF] * (n_det + 1) for _ in range(n_read + 1)]
    B = [[None] * (n_det + 1) for _ in range(n_read + 1)]
    D[0][0] = 0.0
    for i in range(n_read + 1):
        for j in range(n_det + 1):
            d = D[i][j]
            if d == INF:
                continue
            if i < n_read:
                for k in range(1, min(span, n_det - j) + 1):
                    c = d + cost(i, j, k) + SPAN_COST * (k - 1)
                    if c < D[i + 1][j + k]:
                        D[i + 1][j + k], B[i + 1][j + k] = c, (i, j, k)
                if d + skip < D[i + 1][j]:
                    D[i + 1][j], B[i + 1][j] = d + skip, (i, j, 0)
            if j < n_det and d + skip < D[i][j + 1]:
                D[i][j + 1], B[i][j + 1] = d + skip, (i, j, -1)
    out, i, j = {}, n_read, n_det
    while B[i][j]:
        pi, pj, k = B[i][j]
        if k > 0:
            out[pi] = (pj, k)
        i, j = pi, pj
    return out


def length_cost(rl, dl):
    rho = sum(len(r) for r in rl) / sum(d['len'] for d in dl)
    return lambda i, j, k: abs(math.log((len(rl[i]) + 1) / (sum(d['len'] for d in dl[j:j + k]) * rho + 1)))


def split_by_length(text, lens):
    """A reading line's words shared out over consecutive lines by their lengths: each word goes to the line in
    which its first character falls."""
    toks = text.split()
    total = sum(len(w) + 1 for w in toks)
    bounds, acc = [], 0.0
    for L in lens:
        acc += L / sum(lens)
        bounds.append(acc)
    out, pos = [[] for _ in lens], 0
    for w in toks:
        f = pos / total
        out[next((k for k, b_ in enumerate(bounds) if f < b_), len(lens) - 1)].append(w)
        pos += len(w) + 1
    return [' '.join(x) for x in out]


def prop_words(text, ln, W, H):
    """Words of `text` along a line's baseline in proportion to their characters (a space counts as one)."""
    toks = text.split()
    total = sum(len(w) for w in toks) + max(0, len(toks) - 1)
    out, pos = [], 0
    for w in toks:
        s, e = pos / total * ln['len'], (pos + len(w)) / total * ln['len']
        pos += len(w) + 1
        a, b = at(ln['baseline'], s), at(ln['baseline'], e)
        top = min(a[1], b[1]) - FRAC * ln['h']
        bot = max(a[1], b[1]) + (1 - FRAC) * ln['h']
        x0, x1 = min(a[0], b[0]), max(a[0], b[0])
        out.append({'text': w, 'box': [x0 / W, top / H, max(x1 - x0, 1) / W, (bot - top) / H]})
    return out


def hyp_page(assigned, dl, W, H, words_of):
    """assigned: {detected index: text}. Lines carry the detected geometry and the text placed on them."""
    words, lines = [], []
    for j, d in enumerate(dl):
        text = assigned.get(j, '')
        if text:
            words += words_of(j, text)
        lines.append({'text': text, 'box': d['box'],
                      'baseline': [[x / W, y / H] for x, y in d['baseline']]})
    return {'words': words, 'lines': lines}


def place_prop(t, det, rl, span):
    W, H = t['width'], t['height']
    dl = px_lines(det, W, H)
    if not dl:
        return {'words': [], 'lines': []}
    assigned = {}
    for i, (j, k) in dp_match(len(rl), len(dl), length_cost(rl, dl), SKIP['length'], span).items():
        for n, chunk in enumerate(split_by_length(rl[i], [d['len'] for d in dl[j:j + k]])):
            if chunk:
                assigned[j + n] = chunk
    return hyp_page(assigned, dl, W, H, lambda j, s: prop_words(s, dl[j], W, H))


def place_flow(t, det, rl, span=None):
    W, H = t['width'], t['height']
    dl = px_lines(det, W, H)
    toks = ' '.join(rl).split()
    if not dl or not toks:
        return {'words': [], 'lines': []}
    total_len = sum(d['len'] for d in dl)
    total_chr = sum(len(w) + 1 for w in toks)
    assigned, k, acc = {}, 0, 0.0
    for j, d in enumerate(dl):
        acc += d['len'] / total_len * total_chr
        take = []
        while k < len(toks) and (sum(len(w) + 1 for w in toks[:k + 1]) <= acc + 0.5 or j == len(dl) - 1):
            take.append(toks[k])
            k += 1
        if take:
            assigned[j] = ' '.join(take)
    return hyp_page(assigned, dl, W, H, lambda j, s: prop_words(s, dl[j], W, H))


def ctc_char_spans(net, logits_list, text, pad):
    """Each character of `text` as (line, start, end): which of the consecutive lines it falls on and where, as a
    fraction of that line, by CTC forced alignment over the recogniser's own output with the lines' frames joined
    end to end (so a reading line that runs over several written lines is split where the ink says).
    kraken.tasks.align's trellis and backtrack, with the frames scaled to each line as kraken's recogniser scales
    its own cuts. ForcedAlignmentTaskModel.predict in kraken 7.1.1 packs the text at the line's start (p049's first
    line ends at 264 px where its recognition ends at 1307): it takes log_softmax of record.logits, which are
    already probabilities, so every frame is near uniform. A character the model's codec lacks takes its place
    after its predecessor. Also returns the aligned characters' confidences (kraken's Segment.score: the mean
    probability of the frames each character holds). None when the lines are too short for the text (kraken's own
    guard: fewer than two frames a label)."""
    import torch
    from kraken.tasks.align import get_trellis, backtrack, merge_repeats
    keep = [k for k, c in enumerate(text) if c in net.codec.c2l]
    if not keep:
        return None
    sub = ''.join(text[k] for k in keep)
    labels = net.codec.encode(sub).long()
    parts = [lg.detach().float().cpu().squeeze() for lg in logits_list]
    lens = [x.shape[-1] for x in parts]
    if len(labels) != len(sub) or sum(lens) < 2 * len(labels):
        return None
    # kraken's `logits` are the softmax output (each frame sums to 1): their log, not log_softmax
    emission = torch.cat(parts, dim=-1).clamp_min(1e-12).log().T
    segs = merge_repeats(backtrack(get_trellis(emission, labels), emission, labels), sub)
    if len(segs) != len(sub):
        return None
    starts = [sum(lens[:n]) for n in range(len(lens))]

    def where(f):
        n = max(k for k, s0 in enumerate(starts) if s0 <= f)
        T = lens[n]
        local = f - starts[n]
        return n, max(0.0, min(1.0, (local * net.net_scale - pad) / max(1.0, T * net.net_scale - 2 * pad)))
    spans = [None] * len(text)
    for k, sg in zip(keep, segs):
        n, s0 = where(sg.start)
        n1, s1 = where(max(sg.start, sg.end - 1))
        spans[k] = (n, s0, s1 if n1 == n else 1.0)
    for k in range(len(text)):
        if spans[k] is None:
            prev = next((spans[i] for i in range(k - 1, -1, -1) if spans[i]), (0, 0.0, 0.0))
            spans[k] = (prev[0], prev[2], prev[2])
    return spans, [sg.score for sg in segs]


def place_ctc(model_name, todo, det_name, routes):
    """Runs under the kraken venv: recognise each detected line once (text, logits and line image), match the
    reading's lines to the recognised ones by character error, and force-align each matched line's text on its
    logits; every reading of the page shares the one recognition pass."""
    from PIL import Image
    from kraken.containers import Segmentation, BaselineLine
    from kraken.configs import RecognitionInferenceConfig
    from kraken.tasks import ForcedAlignmentTaskModel
    net = ForcedAlignmentTaskModel.load_model(MODELS[model_name]).net
    cfg = RecognitionInferenceConfig()
    cfg.return_logits = True
    cfg.return_line_image = True
    net.prepare_for_inference(cfg)
    for t in todo:
        det = json.loads((CACHE / 'lines' / det_name / f'{key(t)}.json').read_text())
        W, H = t['width'], t['height']
        dl = px_lines(det, W, H)
        im = Image.open(t['image'])

        def kline(d):
            bd = d['boundary'] or [(x, y - FRAC * d['h']) for x, y in d['baseline']] + \
                [(x, y + (1 - FRAC) * d['h']) for x, y in d['baseline'][::-1]]
            return BaselineLine(id=None, baseline=[tuple(map(int, p)) for p in d['baseline']],
                                boundary=[tuple(map(int, p)) for p in bd])
        usable = [j for j, d in enumerate(dl) if len(d['baseline']) >= 2]
        t0 = time.time()
        seg = Segmentation(type='baselines', imagename=t['image'], text_direction='horizontal-lr',
                           script_detection=False, lines=[kline(dl[j]) for j in usable])
        recs = dict(zip(usable, net.predict(im=im, segmentation=seg)))
        recog = {j: r.prediction for j, r in recs.items()}
        rsec = time.time() - t0
        page_recog = ' '.join(recog.get(j, '') for j in range(len(dl)))

        def place(rl, span):
            cost = lambda i, j, k: min(1.0, place_score.cer(' '.join(recog.get(j + n, '') for n in range(k)), rl[i]))
            m = dp_match(len(rl), len(dl), cost, SKIP['text'], span)
            assigned, placed, fallback, conf = {}, {}, 0, []
            for i, (j, k) in m.items():
                text, run = rl[i], range(j, j + k)
                got = None
                if all(recs.get(n) is not None and recs[n].logits is not None for n in run):
                    got = ctc_char_spans(net, [recs[n].logits for n in run], text, cfg.padding)
                if got is None:
                    fallback += 1
                    for n, chunk in zip(run, split_by_length(text, [dl[n]['len'] for n in run])):
                        if chunk:
                            assigned[n], placed[n] = chunk, prop_words(chunk, dl[n], W, H)
                    continue
                spans, scores = got
                conf += scores
                for mt in re.finditer(r'\S+', text):
                    n0, s0, _ = spans[mt.start()]
                    n1, _, e1 = spans[mt.end() - 1]
                    e1 = e1 if n1 == n0 else 1.0
                    d = dl[j + n0]
                    a_, b_ = at(d['baseline'], s0 * d['len']), at(d['baseline'], max(e1 * d['len'], s0 * d['len'] + 1))
                    top = min(a_[1], b_[1]) - FRAC * d['h']
                    bot = max(a_[1], b_[1]) + (1 - FRAC) * d['h']
                    x0, x1 = min(a_[0], b_[0]), max(a_[0], b_[0])
                    assigned[j + n0] = (assigned.get(j + n0, '') + ' ' + mt.group()).strip()
                    placed.setdefault(j + n0, []).append(
                        {'text': mt.group(), 'box': [x0 / W, top / H, max(x1 - x0, 1) / W, (bot - top) / H]})
            hyp = hyp_page(assigned, dl, W, H, lambda j, s_: placed[j])
            n_chars = sum(len(r.replace(' ', '')) for r in rl)
            # the match's own character error: each reading line against its run's recognition, weighted by length,
            # a reading line left unmatched counting as all wrong
            err = sum(len(rl[i]) * (min(1.0, cost(i, *m[i])) if i in m else 1.0) for i in range(len(rl)))
            # the gate's features: the recogniser's character error against the whole reading (independent of the
            # matcher), and the alignment's confidence over the reading's characters, an unaligned one counting 0
            hyp['meta'] = {'matched_lines': len(assigned), 'fallback_lines': fallback, 'model': model_name,
                           'span': span, 'reading_lines': len(rl), 'detected_lines': len(dl),
                           'page_cer': place_score.cer(page_recog, ' '.join(rl)),
                           'ctc_conf': sum(conf) / max(1, n_chars), 'aligned_chars': len(conf),
                           'match_cer': err / max(1, sum(len(r) for r in rl))}
            return hyp

        for route in routes:
            rl = reading(t, route)
            if rl is None:
                continue
            t1 = time.time()
            by_span = {sp: place(rl, sp) for sp in SPANS}
            for sp, hyp in by_span.items():
                hyp['meta'].update(recognise_s=rsec, align_s=(time.time() - t1) / len(SPANS))
                save(CACHE / 'hyp' / f'{det_name}.ctc-{model_name}-s{sp}.{route}' / f'{key(t)}.json', hyp)
            one, many = by_span[1], by_span[max(SPANS)]
            # the line-count pick: span when the reading has far fewer lines than the page shows
            lines_pick = many if len(rl) < REFLOW * max(1, len(dl)) else one
            # the confidence pick: whichever matcher aligns more of the reading more surely; ties go one-to-one
            conf_pick = many if many['meta']['ctc_conf'] > one['meta']['ctc_conf'] + 1e-9 else one
            # the error pick: whichever matcher's runs read closer to the reading; ties go one-to-one
            cer_pick = many if many['meta']['match_cer'] < one['meta']['match_cer'] - 1e-9 else one
            for name, hyp in (('lines', lines_pick), ('conf', conf_pick), ('cer', cer_pick)):
                save(CACHE / 'hyp' / f'{det_name}.ctc-{model_name}-{name}.{route}' / f'{key(t)}.json', hyp)
        print(t['page'], f'{time.time() - t0:.0f}s', flush=True)


PLACERS = {'prop': place_prop, 'flow': place_flow}


def align(det_name, method, routes, only=None):
    todo = [t for t in pages(only) if (CACHE / 'lines' / det_name / f'{key(t)}.json').exists()]
    if method.startswith('ctc-'):
        if os.environ.get('PLACE_HANDS_WORKER') != 'ctc':
            env = dict(os.environ, PLACE_HANDS_WORKER='ctc')
            cmd = [str(VENV['ctc']), __file__, 'align', det_name, method, *routes]
            if only:
                cmd += ['--pages', ','.join(only)]
            subprocess.run(cmd, check=True, env=env)
            return
        place_ctc(method[4:], todo, det_name, routes)
        return
    for t in todo:
        det = json.loads((CACHE / 'lines' / det_name / f'{key(t)}.json').read_text())
        for route in routes:
            rl = reading(t, route)
            if rl is None:
                continue
            if method == 'flow':
                save(CACHE / 'hyp' / f'{det_name}.flow.{route}' / f'{key(t)}.json', place_flow(t, det, rl))
                continue
            for sp in SPANS:
                save(CACHE / 'hyp' / f'{det_name}.{method}-s{sp}.{route}' / f'{key(t)}.json', PLACERS[method](t, det, rl, sp))


# ---------------------------------------------------------------- scoring

FUNCTIONAL_BIN = CACHE / 'place_functional'


def functional_bin():
    if not FUNCTIONAL_BIN.exists() or FUNCTIONAL_BIN.stat().st_mtime < (HERE / 'place_functional.swift').stat().st_mtime:
        subprocess.run(['swiftc', '-O', str(HERE / 'place_functional.swift'), '-o', str(FUNCTIONAL_BIN)], check=True)


def functional(t, hyp_file: Path) -> dict:
    truth = place_truth.STORE / f"{key(t)}.json"
    pdf = CACHE / 'pdf' / hyp_file.parent.name / f'{key(t)}.pdf'
    pdf.parent.mkdir(parents=True, exist_ok=True)
    if not pdf.exists() or pdf.stat().st_mtime < max(hyp_file.stat().st_mtime, FUNCTIONAL_BIN.stat().st_mtime):
        subprocess.run([str(FUNCTIONAL_BIN), 'oracle', str(truth), str(pdf), '--words', str(hyp_file), '--fit'],
                       check=True, stdout=subprocess.DEVNULL)
    out = subprocess.run([str(FUNCTIONAL_BIN), 'score', str(truth), str(pdf)], check=True, capture_output=True,
                         text=True).stdout
    return json.loads(out)


def word_inside(t, det):
    """Share of the truth's boxed words whose centre lies inside some detected line (boundary, else box)."""
    tw = place_score.scoreable(t)
    shapes = [ln['boundary'] or [[ln['box'][0], ln['box'][1]], [ln['box'][0] + ln['box'][2], ln['box'][1]],
                                 [ln['box'][0] + ln['box'][2], ln['box'][1] + ln['box'][3]],
                                 [ln['box'][0], ln['box'][1] + ln['box'][3]]] for ln in det['lines']]
    W, H = t['width'], t['height']
    shapes = [[(x * W, y * H) for x, y in s] for s in shapes]
    boxes = [bbox(s) for s in shapes]
    hit = 0
    for w in tw:
        b = w['box']
        c = ((b[0] + b[2] / 2) * W, (b[1] + b[3] / 2) * H)
        hit += any(bx[0] <= c[0] <= bx[0] + bx[2] and bx[1] <= c[1] <= bx[1] + bx[3] and inside_poly(c, s)
                   for s, bx in zip(shapes, boxes))
    return hit, len(tw)


def keep(t):
    return (t.get('audit') or {}).get('verdict') == 'ok'


def score():
    ps = [t for t in pages() if keep(t)]
    res = {'pages': {g: sum(t['group'] == g for t in ps) for g in GROUPS}, 'detectors': {}, 'placement': {},
           'per_page': {}}
    for det_dir in sorted((CACHE / 'lines').iterdir()):
        name, rows = det_dir.name, {g: [] for g in GROUPS}
        for t in ps:
            f = det_dir / f'{key(t)}.json'
            if not f.exists():
                continue
            det = json.loads(f.read_text())
            b = place_score.baseline_scores(t, det)
            hit, n = word_inside(t, det)
            rows[t['group']].append({'R': b['R'], 'P': b['P'], 'F': b['F'], 'hit': hit, 'n': n,
                                     'lines': len(det['lines']), 'truth_lines': b['truth_baselines'],
                                     'seconds': det.get('seconds'), 'device': det.get('device')})
        res['detectors'][name] = {g: summarise_det(r) for g, r in rows.items() if r}
    functional_bin()
    jobs = [(d, t) for d in sorted((CACHE / 'hyp').iterdir()) for t in ps if (d / f'{key(t)}.json').exists()]
    with ThreadPoolExecutor(8) as ex:
        fun_of = dict(zip(((d.name, t['page']) for d, t in jobs), ex.map(lambda dt: functional(dt[1], dt[0] / f'{key(dt[1])}.json'), jobs)))
    for hyp_dir in sorted((CACHE / 'hyp').iterdir()):
        det_name, method, route = hyp_dir.name.split('.', 2)
        rows, fun = [], {g: {'n': 0, 'find': 0, 'placed': 0, 'pages_placed_80': 0} for g in GROUPS}
        for t in ps:
            f = hyp_dir / f'{key(t)}.json'
            if not f.exists():
                continue
            rows.append(place_score.score_page(t, json.loads(f.read_text())))
            fr = fun_of[(hyp_dir.name, t['page'])]
            g = fun[t['group']]
            g['n'] += fr.get('words', 0)
            g['find'] += fr.get('found', 0)
            g['placed'] += fr.get('placed', 0)
            # a page whose highlight lands on the word for at least 80% of the words Find finds
            g['pages_placed_80'] += fr.get('found', 0) > 0 and fr['placed'] >= 0.8 * fr['found']
        by = {}
        for g in GROUPS:
            gr = [r for r in rows if r['group'] == g]
            if gr:
                pl = place_score.pooled(gr)
                by[g] = {k: pl[k] for k in ('pages', 'truth_words', 'f1@centre', 'f1@0.5', 'f1@0.7', 'alignment')}
                by[g]['functional'] = fun[g]
        res['placement'][hyp_dir.name] = {'detector': det_name, 'method': method, 'reading': route, 'by_group': by}
        if method.startswith('ctc-'):
            # per page, for the gate: its features from the placer and what Find and the highlight did with it
            res['per_page'][hyp_dir.name] = [
                {'page': t['page'], **{k: json.loads((hyp_dir / f'{key(t)}.json').read_text())['meta'].get(k)
                                       for k in ('span', 'page_cer', 'ctc_conf', 'match_cer', 'reading_lines',
                                                 'detected_lines')},
                 'words': fun_of[(hyp_dir.name, t['page'])].get('words', 0),
                 'found': fun_of[(hyp_dir.name, t['page'])].get('found', 0),
                 'placed': fun_of[(hyp_dir.name, t['page'])].get('placed', 0)}
                for t in ps if t['group'] == 'owner-hand' and (hyp_dir / f'{key(t)}.json').exists()]
    res['gate'] = {pick: {feat: gate_sweep(res, feat, pick) for feat in GATE_FEATURES} for pick in GATE_PICKS}
    # only the gate's own route keeps its per-page rows in the results file
    res['per_page'] = {k: v for k, v in res['per_page'].items()
                       if any(k.startswith(GATE_ROUTE.format(pick=p) + '.') for p in GATE_PICKS)}
    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / 'place-hands.json').write_text(json.dumps(res, indent=1) + '\n')
    (RESULTS / 'place-hands.md').write_text(write_md(res))
    print(json.dumps(res['detectors'], indent=1))
    return res


GATE_ROUTE = 'blla.ctc-mccatmus-{pick}'  # the hand route the gate is set for (the best detector and recogniser)
GATE_PICKS = ('cer', 'conf')  # the matcher picks the gate is tried on; each sweep pools every reading
GATE_PICK = 'conf'  # the one whose sweeps the page shows in full
GATE_FEATURES = {'page_cer': -1, 'ctc_conf': 1, 'match_cer': -1}  # +1: higher is better, -1: lower is better


GATE_OFF = 0.10  # the gate's bar: on the pages it keeps, at most this share of Find's hits highlight off the word


def gate_rows(res, pick=None):
    pick = pick or GATE_PICK
    return [dict(r, reading=name.split('.', 2)[2]) for name, rs in res['per_page'].items()
            if '.'.join(name.split('.', 2)[:2]) == GATE_ROUTE.format(pick=pick) for r in rs]


def gate_choose(rows, feat):
    """The loosest threshold at which the kept page readings' pooled off-word share is within GATE_OFF."""
    sign, best = GATE_FEATURES[feat], None
    for th in sorted({r[feat] for r in rows}, key=lambda v: sign * v, reverse=True):
        kept = [r for r in rows if sign * r[feat] >= sign * th]
        found = sum(r['found'] for r in kept)
        if found and (found - sum(r['placed'] for r in kept)) <= GATE_OFF * found:
            best = th
    return best


def gate_sweep(res, feat, pick=None):
    """Every threshold on one feature, over the gate route's owner-hand page readings pooled across readings: a page
    passing it keeps its placed layer, the rest go to the text page (Find still works there; no highlight). Also the
    chosen threshold, and the same choice made leaving each page out (all its readings) and applied to it."""
    rows = [r for r in gate_rows(res, pick) if r[feat] is not None]
    sign = GATE_FEATURES[feat]
    out = []
    for th in sorted({r[feat] for r in rows}, key=lambda v: sign * v, reverse=True):
        kept = [r for r in rows if sign * r[feat] >= sign * th]
        out.append({'threshold': th, 'kept': len(kept), 'of': len(rows),
                    'found': sum(r['found'] for r in kept), 'placed': sum(r['placed'] for r in kept),
                    'words': sum(r['words'] for r in rows),
                    'kept_under_80': sum(r['placed'] < 0.8 * r['found'] for r in kept),
                    'sent_at_80': sum(r['placed'] >= 0.8 * r['found'] for r in rows if r not in kept),
                    'by_reading': {rd: sum(r['reading'] == rd for r in kept) for rd in READINGS}})
    chosen = gate_choose(rows, feat)
    loo = []
    for pg in sorted({r['page'] for r in rows}):
        th = gate_choose([r for r in rows if r['page'] != pg], feat)
        loo += [dict(r, kept=th is not None and sign * r[feat] >= sign * th) for r in rows if r['page'] == pg]

    def tally(rs):
        k = [r for r in rs if r['kept']]
        return {'kept': len(k), 'of': len(rs), 'found': sum(r['found'] for r in k),
                'placed': sum(r['placed'] for r in k), 'words': sum(r['words'] for r in rs)}
    return {'sweep': out, 'chosen': chosen,
            'in_sample': {rd: tally([dict(r, kept=chosen is not None and sign * r[feat] >= sign * chosen)
                                     for r in rows if r['reading'] == rd]) for rd in READINGS},
            'leave_one_page_out': {rd: tally([r for r in loo if r['reading'] == rd]) for rd in READINGS}}


FINDINGS = (HERE / 'place_hands_findings.md')


def write_md(res) -> str:
    f = lambda x, d=3: '—' if x is None else f'{x:.{d}f}'
    pc = lambda a, b: f'{a} / {b} ({100 * a / b:.0f}%)' if b else '—'
    out = ['# W46.place-hands — whether handwritten pages can leave the text page', '',
           'Generated by `ArchiveProcessor/scripts/segbench/place_hands.py score` (F-placement §7 test 4, 10-gap-audit §5 '
           'item 23). Pages: the placement truth\'s hand pages the audit passed (`--verdict ok`): '
           f"{res['pages']['owner-hand']} of the owner's 21 handwritten or mixed pages and {res['pages']['L2-bentham']} "
           'of the 20 Bentham pages (L2; L1 has no geometry, so these are the plan\'s "160 L1/L2" that can be scored). '
           'Bentham\'s audited pages carry line geometry only, so its word and functional figures are empty. '
           'Everything ran on the Mac (M3 Pro, 18 GB) or from saved runs; no money, no cluster.', '']
    if FINDINGS.exists():
        out += [FINDINGS.read_text().strip(), '']
    out += ['## Step one: line detectors', '',
            '| detector | group | baseline R | P | F | truth words inside a line | lines found / truth | s a page | where |',
            '|---|---|---:|---:|---:|---:|---:|---:|---|']
    for name, by in res['detectors'].items():
        for g, d in by.items():
            out.append(f"| {name} | {g} | {f(d['R'])} | {f(d['P'])} | {f(d['F'])} | {f(d['words_inside'])} | "
                       f"{d['lines']} / {d['truth_lines']} | {f(d['seconds_per_page'], 1)} | {d['device']} |")
    out += ['', 'Reference, same truth and scorer (segbench-results/place-truth.md): Apple Vision\'s own lines on the '
            'owner-hand pages, baseline F 0.733.', '']
    out += matcher_table(res, pc) + gate_tables(res, f, pc)
    for route in READINGS:
        rows = {k: v for k, v in res['placement'].items() if v['reading'] == route and
                (v['method'] == 'flow' or v['method'].endswith(('-s1', '-' + GATE_PICK)))}
        if not rows:
            continue
        out += [f'## Step two: `{route}` placed on the lines (one-to-one, the `{GATE_PICK}` pick, flow; every arm in the json)', '',
                '| detector | method | owner-hand F1@centre | F1@0.5 | line alignment | Find | placed on the word | '
                'pages placed ≥80% of found | Bentham line alignment |',
                '|---|---|---:|---:|---:|---:|---:|---:|---:|']
        for k, v in sorted(rows.items(), key=lambda kv: -(kv[1]['by_group'].get('owner-hand', {}).get('f1@centre') or 0)):
            o, b = v['by_group'].get('owner-hand'), v['by_group'].get('L2-bentham')
            if o:
                fu = o['functional']
                cells = [f(o['f1@centre']), f(o['f1@0.5']), f(o['alignment']), pc(fu['find'], fu['n']),
                         pc(fu['placed'], fu['n']), f"{fu['pages_placed_80']} / {o['pages']}"]
            else:
                cells = ['—'] * 6
            out.append(f"| {v['detector']} | {v['method']} | " + ' | '.join(cells) + f" | {f(b['alignment']) if b else '—'} |")
        out.append('')
    out += ['Reference: Vision\'s own words on the owner-hand pages (it reads as well as places): F1@centre 0.761, '
            'line alignment 0.698 (place-truth.md, the 20 audited ok). Find counts truth words of four or more letters; '
            '"placed" is a Find hit whose highlight meets the word\'s truth box (`place_functional.swift`, writer `--fit`).',
            '']
    return '\n'.join(out) + '\n'


MATCHERS = ('s1', 's8', 'lines', 'conf', 'cer')


def matcher_table(res, pc):
    """Both matchers and the three per-page picks side by side, every reading in one row."""
    P = res['placement']
    out = ['## The matcher, per reading', '',
           'Placed on the word, owner-hand (of 1,584 truth words; pages placed ≥80% of found in brackets), and line '
           'alignment on Bentham. `s1` one-to-one, `s8` a reading line over up to 8 detected lines; the picks choose '
           f'between them per page: `lines` takes `s8` when the reading has fewer than {REFLOW:.0%} of the detected '
           'lines, `conf` the one with the higher mean CTC confidence over the reading\'s characters, `cer` the one whose '
           'matched runs\' recognition reads closer to the reading (an unmatched line counting as all wrong).', '',
           '| detector | placer | matcher | ' + ' | '.join(f'`{r}`' for r in READINGS) +
           ' | Bentham `truth` | Bentham `lightonocr3-4b` |',
           '|---|---|---|' + '---:|' * (len(READINGS) + 2)]
    dets = sorted({v['detector'] for v in P.values()})
    for d in dets:
        for placer in ('ctc-mccatmus', 'ctc-revcity', 'prop'):
            for m in MATCHERS:
                cells, any_ = [], False
                for r in READINGS:
                    o = P.get(f'{d}.{placer}-{m}.{r}', {}).get('by_group', {}).get('owner-hand')
                    if o:
                        any_ = True
                        fu = o['functional']
                        cells.append(f"{pc(fu['placed'], fu['n'])} ({fu['pages_placed_80']})")
                    else:
                        cells.append('—')
                for r in ('truth', 'lightonocr3-4b'):
                    b = P.get(f'{d}.{placer}-{m}.{r}', {}).get('by_group', {}).get('L2-bentham')
                    cells.append(f"{b['alignment']:.3f}" if b else '—')
                if any_:
                    out.append(f'| {d} | {placer} | {m} | ' + ' | '.join(cells) + ' |')
    return out + ['']


GATE_SHOW = 12  # rows of each sweep shown; the json has every threshold


def gate_tables(res, f, pc):
    out = ['## The gate, every pick and feature', '',
           f"Each feature's threshold is the loosest with at most {GATE_OFF:.0%} of the kept pages' Find hits highlighting "
           'off the word, fitted on every reading\'s page readings together (one gate for any reader). Figures are '
           'leave one page out: the threshold fitted without a page (all its readings), then applied to it. Kept pages, '
           'words placed on the word (of 1,584), and Find hits off the word on the kept pages.', '',
           '| pick | feature | threshold | ' + ' | '.join(f'`{r}`' for r in READINGS) + ' |',
           '|---|---|---:|' + '---|' * len(READINGS)]
    for pick, gates in res.get('gate', {}).items():
        for feat, gate in gates.items():
            cells = []
            for r in READINGS:
                b = gate['leave_one_page_out'][r]
                cells.append(f"{b['kept']} / {b['of']}, {pc(b['placed'], b['words'])}, {b['found'] - b['placed']} off"
                             if b['of'] else '—')
            out.append(f"| {pick} | {feat} | {f(gate['chosen'])} | " + ' | '.join(cells) + ' |')
    out.append('')
    for feat, gate in res.get('gate', {}).get(GATE_PICK, {}).items():
        sweep = gate['sweep']
        if not sweep:
            continue
        step = max(1, len(sweep) // GATE_SHOW)
        rows = sweep[::step] + ([sweep[-1]] if (len(sweep) - 1) % step else [])
        out += [f'## The gate on `{feat}` ({GATE_ROUTE.format(pick=GATE_PICK)}, every reading pooled)', '',
                'A page reading at or past the threshold keeps its placed layer; the rest go to the text page. '
                '"Placed" and "found" count on the kept pages only.', '',
                '| threshold | pages kept | placed on the word | found but highlight off the word | kept pages under 80% | '
                'sent pages that were ≥80% | kept: ' + ' / '.join(READINGS) + ' |',
                '|---:|---:|---:|---:|---:|---:|---|']
        for g in rows:
            out.append(f"| {f(g['threshold'])} | {g['kept']} / {g['of']} | {pc(g['placed'], g['words'])} | "
                       f"{g['found'] - g['placed']} | {g['kept_under_80']} | {g['sent_at_80']} | "
                       + ' / '.join(str(g['by_reading'][r]) for r in READINGS) + ' |')
        out += ['', f"Chosen (the loosest threshold with at most {GATE_OFF:.0%} of the kept pages' Find hits off the "
                f"word): **{f(gate['chosen'])}**. Per reading, pages kept and words placed on the word, with the "
                'threshold fitted on all pages, and fitted without each page then applied to it:', '',
                '| reading | in sample: kept | placed | off the word | leave one page out: kept | placed | off the word |',
                '|---|---:|---:|---:|---:|---:|---:|']
        for r in READINGS:
            a, b = gate['in_sample'][r], gate['leave_one_page_out'][r]
            if a['of']:
                out.append(f"| `{r}` | {a['kept']} / {a['of']} | {pc(a['placed'], a['words'])} | {a['found'] - a['placed']} "
                           f"| {b['kept']} / {b['of']} | {pc(b['placed'], b['words'])} | {b['found'] - b['placed']} |")
        out.append('')
    return out


def summarise_det(rows):
    n = len(rows)
    secs = [r['seconds'] for r in rows if r['seconds'] is not None]
    return {'pages': n, 'R': sum(r['R'] for r in rows) / n, 'P': sum(r['P'] for r in rows) / n,
            'F': sum(r['F'] for r in rows) / n,
            'words_inside': (sum(r['hit'] for r in rows) / sum(r['n'] for r in rows)) if sum(r['n'] for r in rows) else None,
            'lines': sum(r['lines'] for r in rows), 'truth_lines': sum(r['truth_lines'] for r in rows),
            'seconds_per_page': sum(secs) / len(secs) if secs else None, 'device': rows[0]['device']}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    d = sub.add_parser('detect')
    d.add_argument('detector', choices=sorted(DETECTORS))
    d.add_argument('--pages')
    sub.add_parser('readings')
    a_ = sub.add_parser('align')
    a_.add_argument('detector')
    a_.add_argument('method')
    a_.add_argument('routes', nargs='*', default=list(READINGS))
    a_.add_argument('--pages')
    sub.add_parser('score')
    a = ap.parse_args()
    only = set(a.pages.split(',')) if getattr(a, 'pages', None) else None
    if a.cmd == 'detect':
        venv = VENV.get(a.detector)
        if venv and os.environ.get('PLACE_HANDS_WORKER') != a.detector:
            cmd = [str(venv), __file__, 'detect', a.detector] + (['--pages', a.pages] if a.pages else [])
            subprocess.run(cmd, check=True, env=dict(os.environ, PLACE_HANDS_WORKER=a.detector))
            return
        DETECTORS[a.detector](pages(only))
    elif a.cmd == 'readings':
        export_readings()
    elif a.cmd == 'align':
        align(a.detector, a.method, a.routes, only)
    else:
        score()


if __name__ == '__main__':
    main()
