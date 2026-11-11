#!/usr/bin/env python3
"""W46.place-curved-owner — does the print placement route select as well on the owner's curved and bound pages as on
flat ones?

Owner, 2026-11-10 (point 9): UIUC 00233 and 00149 "test warping with selection". Stage 01 calls strongly curled or
bound pages untested (`13-stage-rules/01-reading-copy.md`), and no dewarped copy is offered (owner, 2026-11-06), so
the layer sits on the raw or deskewed photograph. This scores that layer.

  python3 place_curved.py survey     Vision lines on every image of the 5,000-file Reader sample (JPEG originals)
                                     and the two UIUC pages; per-page geometry cues, no reader (run under heavy-run.py)
  python3 place_curved.py select     the curved set (the cue's top pages plus 00233 and 00149) and a flat set of
                                     the same collections; contact sheets for the eye check
  python3 place_curved.py truth      kraken blla's lines on the selected pages (run under heavy-run.py)
  python3 place_curved.py run        the route's layer and the PDFKit drags on every selected page
  python3 place_curved.py report     segbench-results/place-curved-owner.md and .json

The route (`05-placement.md`, print): Apple Vision's lines with the reader's words aligned onto them, one level run per
line (the Vision OCR lab's SearchableWriter), on the reading copy, which is deskewed when the median line angle is 1°
or more. The reader here is Vision itself, so the aligned route is Vision's own layer (`place-print.md`: the two tie,
+0.1, −0.4 to +0.7); no model is called and nothing is spent.

Truth, without anyone drawing it: kraken blla's lines (a baseline segmenter trained on documents, not a reader, and
blind to Vision). A blla line's words are the Vision words whose centre lies in its boundary, in order along its
baseline. The drag starts at the first word's left edge and ends at the last word's right edge, each at the middle of
the blla boundary at that x (the ink, where Vision's straight quads may not follow a bent line), and passes when
PDFKit's selection holds no line break and is exactly those words (place_functional.swift `drag`). A line is scored
when it has two or more Vision words and none of them lies in another blla line. A word Vision did not read is not
on the line at all, so an OCR miss is not a selection failure (as in place_geom.py). A second, Vision-only figure
drags each Vision line along its own words: that tests the writer and PDFKit on the page, not Vision's grouping.

Writes CACHE (images copied from the sample, layers, drags; rebuildable) and the committed results (counts, cues and
sample-relative paths). Reads the sample copy and two UIUC originals, never writes the corpus. No network, no money.
"""
from __future__ import annotations

import argparse
import json
import math
import random
import statistics
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from place_geom import (PT, angle_spread, deskew_map, identity_map, page_angle,  # noqa: E402
                        quad_bbox, run_tool)
from enh_dewarp import angle_residual  # noqa: E402

RESULTS = HERE.parents[1] / 'segbench-results'
REH = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
CACHE = REH / 'place-curved-owner'
SAMPLE = REH / 'reader-sample'
UIUC = Path.home() / 'Desktop/Google Drive/Archival Photos JPEGS/UIUC'
OWNER_PAGES = ('uiuc-00233', 'uiuc-00149')
VISION = Path('/tmp/pco-dewarp')            # swiftc -O dewarp.swift -o /tmp/pco-dewarp
WRITER = Path('/tmp/place_geom_writer')     # place_geom_writer.swift's header
FUNCTIONAL = Path('/tmp/place_functional')  # swiftc -O place_functional.swift -o /tmp/place_functional
KRAKEN = Path.home() / '.local/share/visionocr-ocrlab/venv-kraken/bin/kraken'
N_CURVED, SEED, DRAWS = 30, 4611, 2000
DESKEW_DEG = 1.0
PAGE_NS = {'p': 'http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15'}


# ---------------------------------------------------------------- the survey
def sample_images():
    """(key, image path, collection) for every image of the Reader sample: JPEGS-tree partners and main-tree images.
    The collection is the sampled PDF's first two path levels (the sample's own grouping)."""
    out = []
    for i, ln in enumerate((SAMPLE / 'selection.tsv').read_text().splitlines()[1:]):
        rel, kind, pdf = ln.split('\t')
        if kind == 'pdf':
            continue
        coll = '/'.join(pdf.split('/')[:2])
        out.append((f's{i:05d}', SAMPLE / rel, coll, rel))
    return out


def uiuc_numbers():
    """The UIUC PDFs the sample drew. Their originals are HEIC, which the sample's partner rule does not pair, so
    the survey reads them from the corpus (read only) to keep the owner's bound volume in it."""
    out = []
    for ln in (SAMPLE / 'selection.tsv').read_text().splitlines()[1:]:
        rel, kind, _ = ln.split('\t')
        if kind == 'pdf' and rel.startswith('Archival Photos/UIUC/'):
            out.append(rel.split('/')[-1].split(' ')[0])
    return out


def owner_images():
    """The two UIUC pages and the sample's UIUC pages, copied from their HEIC originals to JPEG in the cache (the
    corpus is only read)."""
    out = []
    keys = list(OWNER_PAGES) + [f'uiuc-{n}' for n in uiuc_numbers() if f'uiuc-{n}' not in OWNER_PAGES]
    for k in keys:
        n = k.split('-')[1]
        src = UIUC / f'UIUC — {n}.HEIC'
        if not src.exists():
            continue
        dst = CACHE / 'img' / f'{k}.jpg'
        if not dst.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '92', str(src), '--out', str(dst)],
                           check=True, stdout=subprocess.DEVNULL)
        out.append((k, dst, 'UIUC', f'UIUC/UIUC — {n}.HEIC'))
    return out


def lines_path(key):
    return CACHE / 'lines' / f'{key}.json'


def pitch_fill(lines, W, H, min_width=0.15):
    """A bend's signature in Vision's own boxes: Vision cuts every word from its line's straight quad, so a bowed line
    gets a quad tall enough to hold the bow and it reaches into the next line. For each wide line, its quad height
    over the distance to the nearest line below that shares half its width; returns the 90th percentile (None with
    fewer than 5 pairs). Ordinary text sits near 0.6-0.8; tilt alone does not raise it, since the quads turn with
    the lines."""
    rows = []
    for ln in lines:
        q = np.asarray(ln['quad'], float) * [W, H]
        top, bot = (q[0] + q[1]) / 2, (q[3] + q[2]) / 2
        h = float(np.hypot(*(bot - top)))
        x0, x1 = q[:, 0].min(), q[:, 0].max()
        if x1 - x0 < min_width * W or h <= 0:
            continue
        rows.append((x0, x1, float((top[1] + bot[1]) / 2), h))
    ratios = []
    for x0, x1, cy, h in rows:
        best = None
        for a0, a1, cy2, h2 in rows:
            if cy2 <= cy:
                continue
            ov = min(x1, a1) - max(x0, a0)
            if ov < 0.5 * min(x1 - x0, a1 - a0):
                continue
            d = cy2 - cy
            if best is None or d < best:
                best = d
        if best and best > 0:
            ratios.append(h / best)
    if len(ratios) < 5:
        return None
    return float(np.percentile(ratios, 90))


def turn_points(pts, k):
    """Normalised top-left points of an image turned k quarter turns clockwise (sips -r 90k)."""
    out = []
    for x, y in pts:
        for _ in range(k % 4):
            x, y = 1 - y, x
        out.append([x, y])
    return out


def quarter_turns(d):
    """How many clockwise quarter turns bring the page upright: the turn that makes the median direction of Vision's
    lines (bottom-left to bottom-right, in pixels) closest to left-to-right. Phone photographs are often stored
    sideways (UIUC 00233 is), and Vision reads them in any of the four turns."""
    W, H = d['width'], d['height']
    angs = [math.atan2((ln['quad'][2][1] - ln['quad'][3][1]) * H, (ln['quad'][2][0] - ln['quad'][3][0]) * W)
            for ln in d['lines']]
    if not angs:
        return 0
    c = math.atan2(sum(math.sin(a) for a in angs), sum(math.cos(a) for a in angs))
    # a clockwise quarter turn adds 90 degrees to every direction (image y down)
    return min(range(4), key=lambda k: abs(math.remainder(c + k * math.pi / 2, 2 * math.pi)))


def upright(d):
    """The Vision reading with every point turned upright, and the turn used."""
    k = quarter_turns(d)
    if k == 0:
        return d, 0
    W, H = (d['height'], d['width']) if k % 2 else (d['width'], d['height'])
    lines = []
    for ln in d['lines']:
        lines.append({**ln, 'quad': turn_points(ln['quad'], k),
                      'words': [{**w, 'quad': turn_points(w['quad'], k)} for w in ln.get('words') or []]})
    return {**d, 'width': W, 'height': H, 'lines': lines}, k


def cues(d):
    d, turn = upright(d)
    W, H, lines = d['width'], d['height'], d['lines']
    wide = [ln for ln in lines if (ln['quad'][2][0] - ln['quad'][3][0]) >= 0.25]
    angs = [math.degrees(math.atan2((ln['quad'][2][1] - ln['quad'][3][1]) * H, (ln['quad'][2][0] - ln['quad'][3][0]) * W))
            for ln in wide]
    return {'turn': turn, 'lines': len(lines), 'words': sum(len(ln.get('words') or []) for ln in lines), 'wide': len(wide),
            'angle': round(page_angle(lines, W, H), 3),
            'resid': (lambda v: None if v is None else round(v, 3))(angle_residual(lines, np.array([W, H], float))),
            'spread': (lambda v: None if v is None else round(v, 3))(angle_spread(lines, W, H)),
            'range': round(float(np.percentile(angs, 90) - np.percentile(angs, 10)), 3) if len(angs) >= 5 else None,
            'fill': (lambda v: None if v is None else round(v, 3))(pitch_fill(lines, W, H))}


def cmd_survey(a):
    imgs = owner_images() + sample_images()
    if a.limit:
        imgs = imgs[:a.limit]
    todo = [(p, lines_path(k)) for k, p, _, _ in imgs if not lines_path(k).exists()]
    (CACHE / 'lines').mkdir(parents=True, exist_ok=True)
    # a few Vision processes side by side, each over its own share; dewarp.swift skips what exists, so it resumes
    procs = []
    for w in range(a.workers):
        share = todo[w::a.workers]
        if not share:
            continue
        jf = CACHE / f'lines-jobs-{w}.tsv'
        jf.write_text(''.join(f'{p}\t{o}\n' for p, o in share))
        procs.append(subprocess.Popen([str(VISION), 'lines', str(jf)], stdout=subprocess.DEVNULL))
    bad = sum(p.wait() != 0 for p in procs)
    rows = []
    for k, p, coll, rel in imgs:
        f = lines_path(k)
        if not f.exists():
            rows.append({'key': k, 'rel': rel, 'collection': coll, 'failed': True})
            continue
        rows.append({'key': k, 'rel': rel, 'collection': coll, **cues(json.loads(f.read_text()))})
    (CACHE / 'survey.json').write_text(json.dumps(rows))
    print(f'surveyed {len(rows)} images, {sum(1 for r in rows if r.get("failed"))} failed ({bad} workers exited non-zero)')


# ---------------------------------------------------------------- the selection
CUE = 'fill'          # chosen after the survey: see the report's "The cue"
MIN_WIDE = 8          # a page needs this many wide lines for its cue to mean anything


def eligible(r):
    return not r.get('failed') and (r.get('wide') or 0) >= MIN_WIDE and r.get(CUE) is not None


def cmd_select(a):
    rows = json.loads((CACHE / 'survey.json').read_text())
    pool = [r for r in rows if eligible(r) and r['key'] not in OWNER_PAGES]
    pool.sort(key=lambda r: -r[CUE])
    curved = [r for r in rows if r['key'] in OWNER_PAGES] + pool[:N_CURVED]
    chosen = {r['key'] for r in curved}
    flat_cut = statistics.median(r[CUE] for r in pool)
    rng = random.Random(SEED)
    flat = []
    for c in curved:
        for level in (2, 1):
            g = '/'.join(c['collection'].split('/')[:level])
            cands = [r for r in pool if r['key'] not in chosen and r[CUE] <= flat_cut
                     and '/'.join(r['collection'].split('/')[:level]) == g]
            if cands:
                f = rng.choice(cands)
                flat.append({**f, 'pair': c['key'], 'match': 'collection' if level == 2 else 'archive'})
                chosen.add(f['key'])
                break
    sel = {'cue': CUE, 'min_wide': MIN_WIDE, 'flat_cut': flat_cut, 'curved': curved, 'flat': flat}
    (CACHE / 'selection.json').write_text(json.dumps(sel, indent=1))
    print(f'curved {len(curved)}, flat {len(flat)} (cut {flat_cut:.3f}); eligible {len(pool)} of {len(rows)}')
    for name, rs in (('curved', curved), ('flat', flat)):
        sheet(name, rs)


def image_of(key):
    rows = {r['key']: r for r in json.loads((CACHE / 'survey.json').read_text())}
    r = rows[key]
    return CACHE / 'img' / f'{key}.jpg' if key.startswith('uiuc-') else SAMPLE / r['rel']


def sheet(name, rs):
    """A contact sheet of the set (ImageMagick), for the eye check of what the cue picked."""
    out = CACHE / f'sheet-{name}.jpg'
    (CACHE / 'thumb').mkdir(parents=True, exist_ok=True)
    args = ['magick', 'montage']
    for r in rs:
        t = CACHE / 'thumb' / f'{r["key"]}.jpg'
        if not t.exists():
            subprocess.run(['sips', '-s', 'format', 'jpeg', '-Z', '400', '-r', str(90 * r['turn']),
                            str(image_of(r['key'])), '--out', str(t)], check=True, stdout=subprocess.DEVNULL)
        args += [str(t)]
    args += ['-tile', '8x', '-geometry', '300x300+4+4', '-label', '', str(out)]
    subprocess.run(args, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# ---------------------------------------------------------------- the truth lines (blla)
def selected():
    sel = json.loads((CACHE / 'selection.json').read_text())
    return [(r, 'curved') for r in sel['curved']] + [(r, 'flat') for r in sel['flat']]


def blla_path(key):
    return CACHE / 'blla' / f'{key}.json'


def up_image(key):
    return CACHE / 'up' / f'{key}.jpg'


def up_lines(key):
    return CACHE / 'lines-up' / f'{key}.json'


def cmd_truth(a):
    """Upright copies of the selected pages (the reading copy is upright; blla reads left to right), Vision lines
    read again on them, then blla's lines."""
    (CACHE / 'up').mkdir(parents=True, exist_ok=True)
    (CACHE / 'lines-up').mkdir(parents=True, exist_ok=True)
    jobs = []
    for r, _ in selected():
        k = r['key']
        if not up_image(k).exists():
            subprocess.run(['sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '92',
                            '-r', str(90 * r['turn']), str(image_of(k)), '--out', str(up_image(k))],
                           check=True, stdout=subprocess.DEVNULL)
        jobs.append(f'{up_image(k)}\t{up_lines(k)}\n')
    jf = CACHE / 'lines-up-jobs.tsv'
    jf.write_text(''.join(jobs))
    subprocess.run([str(VISION), 'lines', str(jf)], check=True, stdout=subprocess.DEVNULL)
    xml_dir = CACHE / 'blla-xml'
    xml_dir.mkdir(parents=True, exist_ok=True)
    (CACHE / 'blla').mkdir(parents=True, exist_ok=True)
    todo = [r for r, _ in selected() if not blla_path(r['key']).exists()]
    for r in todo:
        # one call a page: a page kraken cannot segment is recorded, not fatal to the rest
        xml = xml_dir / f'{r["key"]}.xml'
        p = subprocess.run([str(KRAKEN), '-i', str(up_image(r['key'])), str(xml), '-x', 'segment', '-bl'],
                           capture_output=True, text=True)
        if p.returncode != 0 or not xml.exists():
            blla_path(r['key']).write_text(json.dumps({'failed': p.stderr[-400:]}))
            continue
        root = ET.parse(xml).getroot()
        page = root.find('.//p:Page', PAGE_NS)
        W, H = float(page.get('imageWidth')), float(page.get('imageHeight'))
        lines = []
        for tl in root.iter(f"{{{PAGE_NS['p']}}}TextLine"):
            bl, co = tl.find('p:Baseline', PAGE_NS), tl.find('p:Coords', PAGE_NS)
            if bl is None or co is None:
                continue
            pts = lambda e: [[float(v) for v in xy.split(',')] for xy in e.get('points').split()]
            lines.append({'baseline': [[x / W, y / H] for x, y in pts(bl)],
                          'boundary': [[x / W, y / H] for x, y in pts(co)]})
        blla_path(r['key']).write_text(json.dumps({'width': W, 'height': H, 'lines': lines}))
        print(r['key'], len(lines), flush=True)


# ---------------------------------------------------------------- the layer and the drags
def inside(poly, c):
    x, y = c
    n, hit = len(poly), False
    for k in range(n):
        (x0, y0), (x1, y1) = poly[k], poly[(k + 1) % n]
        if (y0 > y) != (y1 > y) and x < x0 + (y - y0) * (x1 - x0) / (y1 - y0):
            hit = not hit
    return hit


def vertical_mid(poly, x):
    """The middle of a boundary polygon's vertical extent at x (None where the polygon does not reach x)."""
    ys = []
    n = len(poly)
    for k in range(n):
        (x0, y0), (x1, y1) = poly[k], poly[(k + 1) % n]
        if (x0 <= x <= x1) or (x1 <= x <= x0):
            ys.append(y0 if x1 == x0 else y0 + (x - x0) * (y1 - y0) / (x1 - x0))
    return (min(ys) + max(ys)) / 2 if ys else None


def along(baseline, c):
    """Position of point c along a polyline (its projection's arc length), for word order on a bent line."""
    best, acc, pos = None, 0.0, 0.0
    for (x0, y0), (x1, y1) in zip(baseline, baseline[1:]):
        dx, dy = x1 - x0, y1 - y0
        L2 = dx * dx + dy * dy
        t = 0.0 if L2 == 0 else max(0.0, min(1.0, ((c[0] - x0) * dx + (c[1] - y0) * dy) / L2))
        px, py = x0 + t * dx, y0 + t * dy
        d = (c[0] - px) ** 2 + (c[1] - py) ** 2
        if best is None or d < best:
            best, pos = d, acc + t * math.sqrt(L2)
        acc += math.sqrt(L2)
    return pos


def vision(key):
    d = json.loads(up_lines(key).read_text())
    d, k = upright(d)
    assert k == 0, (key, 'upright copy still turned', k)
    vlines, vwords = [], []
    for k, ln in enumerate(d['lines']):
        ids = []
        for w in ln.get('words') or [{'quad': ln['quad'], 'text': ln['text']}]:
            if not w['text'].strip():
                continue
            ids.append(len(vwords))
            vwords.append({'text': w['text'].strip(), 'quad': w['quad'], 'line': k, 'box': quad_bbox(w['quad'])})
        if ids:
            vlines.append({'quad': ln['quad'], 'words': ids})
    return d['width'], d['height'], vlines, vwords


def blla_expected(blines, vwords):
    """Scored blla lines: (index, Vision words in baseline order, boundary). Skips counted by reason."""
    home: dict[int, list] = {}
    for j, w in enumerate(vwords):
        c = (w['box'][0] + w['box'][2] / 2, w['box'][1] + w['box'][3] / 2)
        home[j] = [i for i, bl in enumerate(blines) if inside(bl['boundary'], c)]
    out, skipped = [], {'empty': 0, 'short': 0, 'shared': 0}
    for i, bl in enumerate(blines):
        ws = [j for j, h in home.items() if i in h]
        if not ws:
            skipped['empty'] += 1
            continue
        if len(ws) < 2:
            skipped['short'] += 1
            continue
        if any(len(home[j]) > 1 for j in ws):
            skipped['shared'] += 1
            continue
        ws.sort(key=lambda j: along(bl['baseline'], (vwords[j]['box'][0] + vwords[j]['box'][2] / 2,
                                                     vwords[j]['box'][1] + vwords[j]['box'][3] / 2)))
        out.append((i, ws, bl['boundary']))
    return out, skipped


def ink_drag(m, vwords, ws, boundary):
    """From the first word's left edge to the last's right, each at the middle of the blla boundary there."""
    b0, b1 = vwords[ws[0]]['box'], vwords[ws[-1]]['box']
    x0, x1 = b0[0], b1[0] + b1[2]
    y0 = vertical_mid(boundary, x0)
    y1 = vertical_mid(boundary, x1)
    y0 = b0[1] + b0[3] / 2 if y0 is None else y0
    y1 = b1[1] + b1[3] / 2 if y1 is None else y1
    return m([(x0, y0), (x1, y1)])


def own_drag(m, vwords, ws):
    """Vision-only: from the first word's left edge to the last's right, at each word's own mid-height."""
    b0, b1 = vwords[ws[0]]['box'], vwords[ws[-1]]['box']
    return m([(b0[0], b0[1] + b0[3] / 2), (b1[0] + b1[2], b1[1] + b1[3] / 2)])


def layer_lines(m, vlines, vwords):
    """Vision's lines carried onto the reading copy: one level box per line (the lab writer's input)."""
    out = []
    for ln in vlines:
        pts = np.concatenate([m(np.asarray(vwords[j]['quad'], float)) for j in ln['words']])
        pts = pts[np.all(np.isfinite(pts), 1)]
        if len(pts):
            out.append({'text': ' '.join(vwords[j]['text'] for j in ln['words']), 'box': quad_bbox(pts)})
    return out


def page_row(r, group):
    k = r['key']
    work = CACHE / 'pages' / k
    work.mkdir(parents=True, exist_ok=True)
    W, H, vlines, vwords = vision(k)
    bd = json.loads(blla_path(k).read_text())
    angle = page_angle(vlines, W, H)
    arms = {'raw': identity_map(W, H)}
    route = 'raw'
    if abs(angle) >= DESKEW_DEG:
        arms['deskew'] = deskew_map(W, H, angle)
        route = 'deskew'
    exp, skipped = ([], {}) if bd.get('failed') else blla_expected(bd['lines'], vwords)
    jobs, plans = [], {}
    for arm, m in arms.items():
        pdf = work / f'{arm}.pdf'
        jobs.append({'out': str(pdf), 'width': m.out_w * PT, 'height': m.out_h * PT,
                     'lines': layer_lines(m, vlines, vwords)})
        drags = []
        for i, ws, boundary in exp:
            s, e = ink_drag(m, vwords, ws, boundary)
            drags.append({'id': f'b{i}', 'expected': ' '.join(vwords[j]['text'] for j in ws),
                          'start': s.tolist(), 'end': e.tolist()})
        for n, ln in enumerate(vlines):
            if len(ln['words']) >= 2:
                s, e = own_drag(m, vwords, ln['words'])
                drags.append({'id': f'v{n}', 'expected': ' '.join(vwords[j]['text'] for j in ln['words']),
                              'start': s.tolist(), 'end': e.tolist()})
        plans[arm] = (pdf, drags)
    jf = work / 'jobs.json'
    jf.write_text(json.dumps(jobs))
    unplaced = json.loads(run_tool([WRITER, jf]))['unplaced']
    out = {'key': k, 'group': group, 'collection': r['collection'], 'rel': r['rel'], 'pair': r.get('pair'),
           'cue': r[CUE], 'angle': round(angle, 3), 'route': route, 'vision_lines': len(vlines),
           'vision_words': len(vwords), 'blla_lines': 0 if bd.get('failed') else len(bd['lines']),
           'blla_failed': bool(bd.get('failed')), 'skipped': skipped, 'arms': {}}
    for arm, (pdf, drags) in plans.items():
        dj, do = work / f'{arm}.drags.json', work / f'{arm}.drag-out.json'
        dj.write_text(json.dumps({'lines': drags}))
        run_tool([FUNCTIONAL, 'drag', dj, pdf, do])
        got = json.loads(do.read_text())['lines']
        b = [g for g in got if str(g['id']).startswith('b')]
        v = [g for g in got if str(g['id']).startswith('v')]
        out['arms'][arm] = {'blla_n': len(b), 'blla_pass': sum(g['pass'] for g in b),
                            'blla_broken': sum(g['broken'] for g in b),
                            'own_n': len(v), 'own_pass': sum(g['pass'] for g in v),
                            'unplaced': sum(1 for u in unplaced if u['out'] == str(pdf))}
    return out


def cmd_run(a):
    rows = [page_row(r, g) for r, g in selected()]
    (CACHE / 'rows.json').write_text(json.dumps(rows))
    for x in rows:
        ar = x['arms'][x['route']]
        print(f'{x["group"]:6} {x["key"]} cue {x["cue"]:.2f} angle {x["angle"]:+.1f} {x["route"]:6} '
              f'blla {ar["blla_pass"]}/{ar["blla_n"]} own {ar["own_pass"]}/{ar["own_n"]}')


# ---------------------------------------------------------------- the report
def pooled(rows, arm_of, n_key, p_key):
    n = sum(r['arms'][arm_of(r)][n_key] for r in rows)
    p = sum(r['arms'][arm_of(r)][p_key] for r in rows)
    return p, n, (100 * p / n if n else float('nan'))


def boot_diff(a_rows, b_rows, arm_of, n_key, p_key, draws=DRAWS, seed=SEED):
    """Pooled pass rate of a minus b, with a two-sample page bootstrap (pages resampled within each group)."""
    rng = random.Random(seed)
    A = [(r['arms'][arm_of(r)][p_key], r['arms'][arm_of(r)][n_key]) for r in a_rows]
    B = [(r['arms'][arm_of(r)][p_key], r['arms'][arm_of(r)][n_key]) for r in b_rows]

    def rate(xs):
        n = sum(x[1] for x in xs)
        return 100 * sum(x[0] for x in xs) / n if n else float('nan')
    d = rate(A) - rate(B)
    ds = sorted(rate([rng.choice(A) for _ in A]) - rate([rng.choice(B) for _ in B]) for _ in range(draws))
    return d, ds[int(0.025 * draws)], ds[int(0.975 * draws) - 1]


def cmd_report(a):
    rows = json.loads((CACHE / 'rows.json').read_text())
    survey = json.loads((CACHE / 'survey.json').read_text())
    sel = json.loads((CACHE / 'selection.json').read_text())
    pool = [r for r in survey if eligible(r) and r['key'] not in OWNER_PAGES]
    vals = sorted(r[CUE] for r in pool)
    owner_cue = {r['key']: r.get(CUE) for r in survey if r['key'] in OWNER_PAGES}
    thr = min(v for v in owner_cue.values() if v is not None)
    above = [r for r in pool if r[CUE] >= thr]
    curved = [r for r in rows if r['group'] == 'curved' and not r['blla_failed']]
    flat = [r for r in rows if r['group'] == 'flat' and not r['blla_failed']]
    route = lambda r: r['route']
    raw = lambda r: 'raw'
    res = {}
    for name, arm_of in (('route', route), ('raw', raw)):
        for truth, nk, pk in (('blla', 'blla_n', 'blla_pass'), ('own', 'own_n', 'own_pass')):
            res[f'{name}.{truth}'] = {
                'curved': pooled(curved, arm_of, nk, pk), 'flat': pooled(flat, arm_of, nk, pk),
                'diff': boot_diff(curved, flat, arm_of, nk, pk)}
    out = {'item': 'W46.place-curved-owner', 'cue': CUE, 'threshold': thr, 'owner_cue': owner_cue,
           'surveyed': len(survey), 'failed': sum(1 for r in survey if r.get('failed')), 'eligible': len(pool),
           'above_threshold': len(above), 'cue_quantiles': {q: float(np.percentile(vals, q)) for q in (50, 90, 95, 99)},
           'results': res, 'rows': rows,
           'selection': {'curved': [r['key'] for r in sel['curved']], 'flat': [r['key'] for r in sel['flat']],
                         'flat_cut': sel['flat_cut']}}
    (RESULTS / 'place-curved-owner.json').write_text(json.dumps(out, indent=1) + '\n')
    print(json.dumps({k: v for k, v in out.items() if k not in ('rows', 'selection')}, indent=1))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('survey')
    s.add_argument('--workers', type=int, default=3)
    s.add_argument('--limit', type=int, default=0)
    for c in ('select', 'truth', 'run', 'report'):
        sub.add_parser(c)
    a = ap.parse_args()
    {'survey': cmd_survey, 'select': cmd_select, 'truth': cmd_truth, 'run': cmd_run,
     'report': cmd_report}[a.cmd](a)


if __name__ == '__main__':
    main()
