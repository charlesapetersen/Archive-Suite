#!/usr/bin/env python3
"""W46.fix-place-truth-lines — the placement truth's typed lines against two detectors that are not Apple Vision.

The measurement audit (11-measurement-audit.md, OCR-10): most of the placement truth's typed word boxes are Vision's,
the typed lines follow Vision's lines (`place_truth.py`, status `drafted`), and Vision is scored on them; since
2026-10-29 a line passes selection when a drag from its first truth word to its last returns exactly its words, so a
truth line that joins two columns, or splits one line, decides scores. Nobody but Claude auditors has looked at them.

  python3 place_truth_lines.py detect blla        kraken 7.1.1's baseline segmenter on the 40 typed pages, CPU (the
                                                  Vision OCR lab's venv-kraken, as place_hands.py runs it)
  python3 place_truth_lines.py detect ppocrv6     PP-OCRv6 medium det: the pinned FarmShare run's saved polygons on
                                                  the owner's 96 (place_hands.py's reader), not rerun
  python3 place_truth_lines.py compare            where each detector's grouping differs from the truth's
  python3 place_truth_lines.py build              the owner sheet (private) and the committed report
  python3 place_truth_lines.py fold ANSWERS.json  the owner's exported answers -> rulings.json beside the sheet

Grouping. Each scored truth word goes to the detector line whose polygon holds its box's centre (the nearest
baseline when several do), else to a baseline within GRAB of its height, else to none. PP-OCRv6 gives pieces, not
lines: pieces on one row are joined when the gap between them is at most JOIN_GAP of the row's height, so a wide gap
(a column gutter, a tab stop) stays a break, as the detector drew it. A detector line counts as a piece of a truth
line when it holds two or more of that line's words, or only that line's words; so a tall capital whose centre falls
in the next line's polygon is not a split. Two disagreements:

  split   one truth line whose words lie in two or more detector lines: the breaks are where consecutive truth
          words change detector line.
  join    one detector line that holds at least half the assigned words (and two, or all) of two or more truth lines.

A place is on the sheet when both detectors find it (a split at the same break, give or take a word; a join of the
same two truth lines). The sheet is blind: every place asks the same question, whether the text in the box is one
line or breaks at the dashed marks, and the truth's answer is "one line" for a split and "breaks" for a join.

Beside them, five of the owner's hand pages (seed SEED, among the 20 the audit passed) whose lines Claude subagents
drew: every line is boxed with its baseline, and the owner marks the wrong ones. No Claude subagent draws or redraws
anything here (owner, 2026-10-30), and no model runs: blla and PP-OCRv6 are the only readers of the pages.

Writes CACHE/ (detector lines; rebuildable), SHEET/ (index.html, key.json, private: the pages are the owner's),
segbench-results/place-truth-lines.md and .json (counts only). W46.place-print and W46.place-geom fold the answers.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import random
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import place_hands as PH  # noqa: E402
import place_score  # noqa: E402
import place_truth  # noqa: E402

CACHE = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/place-truth-lines'
SHEET = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/ocr-truth/place-lines'
RESULTS = HERE.parents[1] / 'segbench-results'
DETECTORS = ('blla', 'ppocrv6')
GROUP = 'owner-typed'
HAND_GROUP = 'owner-hand'
SEED = 20261030
HAND_PAGES = 5
JOIN_GAP = 0.5      # PP-OCRv6 pieces on one row join across a gap up to this share of the row's height
GRAB = 0.6          # a word outside every polygon goes to a baseline within this share of its height
SLACK = 1           # two detectors' breaks agree within this many words
GROUP_MAX = 6       # one question holds up to this many places of one kind on one page
SECONDS = {'page': 15, 'item': 10, 'place': 3, 'hand_page': 150}   # review-rate estimates for the sheet's minutes


def typed_pages(only=None):
    return [t for t in place_truth.load_all() if t['group'] == GROUP and (not only or t['page'] in only)]


def load_lines(det: str, t: dict):
    f = CACHE / 'lines' / det / f'{PH.key(t)}.json'
    return json.loads(f.read_text()) if f.exists() else None


# ---------------------------------------------------------------- detectors

def detect_blla(todo):
    PH.CACHE = CACHE          # place_hands' runner, writing under this item's cache
    PH.detect_blla(todo)


def join_gap(pieces):
    """place_hands.join_rows, but a row breaks where the horizontal gap passes JOIN_GAP of its height."""
    rows = PH.join_rows(pieces)
    out = []
    for r in rows:
        n = len(r['baseline']) // 2
        segs = []
        for i in range(n):
            b = r['baseline'][2 * i:2 * i + 2]
            segs.append({'baseline': b, 'top': r['boundary'][2 * i:2 * i + 2],
                         'bottom': r['boundary'][len(r['boundary']) - 2 * i - 2:len(r['boundary']) - 2 * i][::-1]})
        cur = [segs[0]]
        for s in segs[1:]:
            h = max(pt[1] for pt in cur[-1]['bottom'] + s['bottom']) - min(pt[1] for pt in cur[-1]['top'] + s['top'])
            gap = s['top'][0][0] - max(pt[0] for pt in cur[-1]['top'] + cur[-1]['bottom'])
            if gap > JOIN_GAP * h:
                out.append(cur)
                cur = []
            cur.append(s)
        out.append(cur)
    lines = []
    for ps in out:
        top = [pt for p in ps for pt in p['top']]
        bottom = [pt for p in ps for pt in p['bottom']]
        lines.append({'baseline': [pt for p in ps for pt in p['baseline']], 'boundary': top + bottom[::-1]})
    return lines


def detect_ppocrv6(todo):
    for t in todo:
        src = next((d / f"{t['page']}.json" for d in PH.PPOCR if (d / f"{t['page']}.json").exists()), None)
        if src is None:
            print('no saved PP-OCRv6 run for', t['page'])
            continue
        got = json.loads(src.read_text())
        copy = next((c for c in PH.PPOCR_IMAGES(t['page']) if c.exists() and PH.sha(c) == got['sha256']), None)
        if copy is None:
            print('no image with the hash PP-OCRv6 ran on for', t['page'], '- skipped')
            continue
        cw, ch = place_truth.image_size(copy)
        sx, sy = t['width'] / cw, t['height'] / ch
        if abs(sx - sy) > 0.01 * sx:
            print('the copy PP-OCRv6 read is not a uniform scale of', t['page'], '- skipped')
            continue
        pieces = [PH.quad_line([(x * sx, y * sy) for x, y in q]) for q in got['native']['res']['dt_polys']]
        PH.save(CACHE / 'lines/ppocrv6' / f'{PH.key(t)}.json',
                PH.normalise(join_gap(pieces), t['width'], t['height'], None, pieces=len(pieces), join_gap=JOIN_GAP,
                             device=f'saved FarmShare run on a {cw}x{ch} copy', source=str(src.relative_to(PH.LTS))))


DETECT = {'blla': detect_blla, 'ppocrv6': detect_ppocrv6}


# ---------------------------------------------------------------- grouping

def centre(b):
    return (b[0] + b[2] / 2, b[1] + b[3] / 2)


def baseline_dy(c, base, W, H):
    """Vertical pixels from c to the baseline at c's x, or None when c lies off its ends by more than a line."""
    pts = [(x * W, y * H) for x, y in base]
    x, y = c[0] * W, c[1] * H
    xs = [p[0] for p in pts]
    if not pts or x < min(xs) - 40 or x > max(xs) + 40:
        return None
    for a, b in zip(pts, pts[1:]):
        if min(a[0], b[0]) <= x <= max(a[0], b[0]) and a[0] != b[0]:
            return abs(y - (a[1] + (b[1] - a[1]) * (x - a[0]) / (b[0] - a[0])))
    return abs(y - min(pts, key=lambda p: abs(p[0] - x))[1])


def assign(t: dict, det: dict) -> dict[int, int | None]:
    """Each scored truth word's index in t['words'] -> the detector line it lies in (or None)."""
    W, H = t['width'], t['height']
    out = {}
    for i, w in enumerate(t['words']):
        if not w.get('box') or w['status'] in place_score.UNSCORED:
            continue
        c = centre(w['box'])
        holders = [(j, baseline_dy(c, ln['baseline'], W, H)) for j, ln in enumerate(det['lines'])
                   if ln.get('boundary') and len(ln['boundary']) >= 3 and PH.inside_poly(c, ln['boundary'])]
        if holders:
            out[i] = min(holders, key=lambda h: math.inf if h[1] is None else h[1])[0]
            continue
        near = [(j, d) for j, ln in enumerate(det['lines']) if (d := baseline_dy(c, ln['baseline'], W, H)) is not None]
        j, d = min(near, key=lambda h: h[1], default=(None, math.inf))
        out[i] = j if d <= GRAB * w['box'][3] * H else None
    return out


def truth_lines(t: dict) -> dict[int, list[int]]:
    """Truth line id -> its scored words' indices, in the truth's order."""
    out: dict[int, list[int]] = {}
    for i, w in enumerate(t['words']):
        if w.get('box') and w['status'] not in place_score.UNSCORED and w.get('line') is not None:
            out.setdefault(w['line'], []).append(i)
    return out


def disagreements(t: dict, a: dict[int, int | None]):
    """splits: truth line -> break positions (k: between its k-th and k+1-th scored word); joins: frozensets of
    truth lines one detector line holds."""
    tl = truth_lines(t)
    n: dict[tuple[int, int], int] = {}
    for L, ws in tl.items():
        for i in ws:
            if a.get(i) is not None:
                n[(L, a[i])] = n.get((L, a[i]), 0) + 1
    holders: dict[int, set[int]] = {}
    for (L, d) in n:
        holders.setdefault(d, set()).add(L)
    splits = {}
    for L, ws in tl.items():
        piece = {d for (L2, d), c in n.items() if L2 == L and (c >= 2 or holders[d] == {L})}
        if len(piece) < 2:
            continue
        seq = [(k, a[i]) for k, i in enumerate(ws) if a.get(i) in piece]
        breaks = [k0 for (k0, d0), (_, d1) in zip(seq, seq[1:]) if d0 != d1]
        if breaks:
            splits[L] = breaks
    joins = set()
    for d, Ls in holders.items():
        big = set()
        for L in Ls:
            got = sum(1 for i in tl[L] if a.get(i) is not None)
            c = n[(L, d)]
            if c >= min(2, got) and c >= 0.5 * got:
                big.add(L)
        if len(big) >= 2:
            joins.add(frozenset(big))
    return splits, joins


def compare():
    pages, rows = [], []
    for t in typed_pages():
        dets = {k: load_lines(k, t) for k in DETECTORS}
        if any(v is None for v in dets.values()):
            print('missing detector lines for', t['page'], [k for k, v in dets.items() if v is None])
            continue
        tl = truth_lines(t)
        status = {ln['id']: ln['status'] for ln in t['lines']}
        res = {k: disagreements(t, assign(t, v)) for k, v in dets.items()}
        unassigned = {k: sum(1 for v in assign(t, dets[k]).values() if v is None) for k in DETECTORS}
        (sb, jb), (sp, jp) = res['blla'], res['ppocrv6']
        both_split = {}
        for L in set(sb) & set(sp):
            agree = sorted(k for k in sb[L] if any(abs(k - k2) <= SLACK for k2 in sp[L]))
            if agree:
                both_split[L] = agree
        pairs = lambda js: {frozenset((x, y)) for j in js for x in j for y in j if x < y}
        both_join = sorted(sorted(p) for p in pairs(jb) & pairs(jp))
        page = {'page': t['page'], 'kind': t['kind'], 'lines': len(tl),
                'status': {s: sum(1 for L in tl if status.get(L) == s) for s in set(status.values())},
                'words': sum(len(v) for v in tl.values()), 'unassigned': unassigned,
                'split': {k: {str(L): v for L, v in res[k][0].items()} for k in DETECTORS},
                'join': {k: [sorted(j) for j in res[k][1]] for k in DETECTORS},
                'both_split': {str(L): v for L, v in both_split.items()}, 'both_join': both_join}
        pages.append(page)
        print(t['page'], t['kind'], len(tl), 'split b/p/both', len(sb), len(sp), len(both_split),
              'join b/p/both', len(jb), len(jp), len(both_join), 'unassigned', unassigned)
    PH.save(CACHE / 'compare.json', pages)
    return pages


# ---------------------------------------------------------------- the sheet

def union(boxes):
    x0, y0 = min(b[0] for b in boxes), min(b[1] for b in boxes)
    x1, y1 = max(b[0] + b[2] for b in boxes), max(b[1] + b[3] for b in boxes)
    return [round(x0, 5), round(y0, 5), round(x1 - x0, 5), round(y1 - y0, 5)]


def mark(a, b):
    """A dashed mark between two boxes: upright between them when they share a row, else level between them."""
    ov = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
    if ov >= 0.3 * min(a[3], b[3]):
        l, r = sorted((a, b), key=lambda q: q[0])
        x = (l[0] + l[2] + r[0]) / 2 if r[0] > l[0] + l[2] else (centre(l)[0] + centre(r)[0]) / 2
        y0, y1 = min(a[1], b[1]), max(a[1] + a[3], b[1] + b[3])
        return [round(x, 5), round(y0, 5), round(x, 5), round(y1, 5)]
    u, d = sorted((a, b), key=lambda q: q[1])
    y = (u[1] + u[3] + d[1]) / 2 if d[1] > u[1] + u[3] else (centre(u)[1] + centre(d)[1]) / 2
    x0, x1 = min(a[0], b[0]), max(a[0] + a[2], b[0] + b[2])
    return [round(x0, 5), round(y, 5), round(x1, 5), round(y, 5)]


def components(pairs):
    parent = {}
    find = lambda x: x if parent.setdefault(x, x) == x else find(parent[x])
    for a, b in pairs:
        parent[find(a)] = find(b)
    out = {}
    for x in list(parent):
        out.setdefault(find(x), set()).add(x)
    return [sorted(c) for c in out.values()]


def img_src(t):
    p = Path(t['image'])
    return f'../pages/{p.name}' if p.parent == SHEET.parent / 'pages' else p.as_uri()


def typed_places(t, page):
    """The places both detectors find on one page, in reading order."""
    tl = truth_lines(t)
    lines = {ln['id']: ln for ln in t['lines']}
    out = []
    for L, breaks in page['both_split'].items():
        L = int(L)
        ws = tl[L]
        marks = [mark(t['words'][ws[k]]['box'], t['words'][ws[k + 1]]['box']) for k in breaks]
        out.append({'kind': 'split', 'lines': [L], 'breaks': breaks, 'box': union([lines[L]['box']]), 'marks': marks,
                    'status': [lines[L]['status']]})
    for comp in components([tuple(p) for p in page['both_join']]):
        pairs = [p for p in page['both_join'] if p[0] in comp]
        out.append({'kind': 'join', 'lines': comp, 'box': union([lines[L]['box'] for L in comp]),
                    'marks': [mark(lines[a]['box'], lines[b]['box']) for a, b in pairs],
                    'status': sorted({lines[L]['status'] for L in comp})})
    return sorted(out, key=lambda x: (round(x['box'][1], 2), x['box'][0]))


def hand_pick():
    hands = [t for t in place_truth.load_all() if t['group'] == HAND_GROUP and t['audit']['verdict'] == 'ok'
             and all(ln['status'] in ('drawn', 'absent') for ln in t['lines'])]
    return sorted(random.Random(SEED).sample(hands, HAND_PAGES), key=lambda t: t['page'])


def build(out_dir: Path, results: Path):
    if (out_dir / 'answers.json').exists():
        raise SystemExit(f'{out_dir} is answered: its key is what the answers mean, so it is not rebuilt')
    cmp = {p['page']: p for p in json.loads((CACHE / 'compare.json').read_text())}
    typed = {t['page']: t for t in typed_pages()}
    data, key = [], {'seed': SEED, 'detectors': DETECTORS, 'join_gap': JOIN_GAP, 'grab': GRAB, 'slack': SLACK,
                     'pages': {}}
    n, places = 0, 0
    for p in sorted(cmp):
        items = []
        xs = typed_places(typed[p], cmp[p])
        for kind in ('split', 'join'):
            same = [x for x in xs if x['kind'] == kind]
            for g in range(0, len(same), GROUP_MAX):
                group = same[g:g + GROUP_MAX]
                iid = f't{n:03d}'
                n += 1
                places += len(group)
                items.append({'id': iid, 'boxes': [x['box'] for x in group], 'marks': [m for x in group for m in x['marks']]})
                # the truth's own answer: a split place is one truth line, a join place two or more
                key['pages'].setdefault(p, {})[iid] = {'kind': kind, 'truth': 'one' if kind == 'split' else 'breaks',
                                                       'places': group}
        items.sort(key=lambda it: (round(it['boxes'][0][1], 2), it['boxes'][0][0]))
        if items:
            data.append({'page': p, 'img': img_src(typed[p]), 'type': 'typed', 'items': items})
    hands = hand_pick()
    for t in hands:
        ls = [{'id': ln['id'], 'box': ln['box'], 'baseline': ln['baseline']} for ln in t['lines']
              if ln['status'] == 'drawn' and ln.get('box')]
        data.append({'page': t['page'], 'img': img_src(t), 'type': 'hand', 'lines': ls})
        key['pages'][t['page']] = {'hand': True, 'lines': [ln['id'] for ln in ls]}
    secs = (sum(1 for d in data if d['type'] == 'typed') * SECONDS['page'] + n * SECONDS['item']
            + places * SECONDS['place'] + len(hands) * SECONDS['hand_page'])
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / 'index.html').write_text(SHEET_HTML.replace('__DATA__', json.dumps(data, ensure_ascii=False))
                                        .replace('__MINUTES__', f'{secs / 60:.0f}').replace('__N__', str(places))
                                        .replace('__Q__', str(n))
                                        .replace('__H__', str(len(hands))))
    (out_dir / 'key.json').write_text(json.dumps(key, ensure_ascii=False, indent=1))
    stats = summarise(list(cmp.values()), key, hands, secs)
    results.mkdir(parents=True, exist_ok=True)
    (results / 'place-truth-lines.json').write_text(json.dumps(stats, indent=1) + '\n')
    write_md(results / 'place-truth-lines.md', stats)
    return stats


def provenance(pages) -> dict:
    """Typed truth lines and their scored words by line status: drafted (Vision's) or drawn (Claude subagents')."""
    out = {'lines': {}, 'words': {}, 'pages': len(pages)}
    for t in typed_pages():
        st = {ln['id']: ln['status'] for ln in t['lines']}
        for ln in t['lines']:
            out['lines'][ln['status']] = out['lines'].get(ln['status'], 0) + 1
        for L, ws in truth_lines(t).items():
            out['words'][st.get(L)] = out['words'].get(st.get(L), 0) + len(ws)
    return out


def summarise(pages, key, hands, secs) -> dict:
    typed = {t['page']: t for t in typed_pages()}
    per_det = {}
    for k in DETECTORS:
        by = {}
        for p in pages:
            st = {ln['id']: ln['status'] for ln in typed[p['page']]['lines']}
            for L in p['split'][k]:
                s = st[int(L)]
                by.setdefault(s, {'split': 0, 'join': 0})['split'] += 1
            for j in p['join'][k]:
                s = 'drafted' if all(st[L] == 'drafted' for L in j) else 'drawn' if all(st[L] == 'drawn' for L in j) else 'mixed'
                by.setdefault(s, {'split': 0, 'join': 0})['join'] += 1
        per_det[k] = {'split_lines': sum(len(p['split'][k]) for p in pages),
                      'joins': sum(len(p['join'][k]) for p in pages),
                      'unassigned_words': sum(p['unassigned'][k] for p in pages), 'by_status': by}
    places = [x for d in key['pages'].values() if not d.get('hand') for v in d.values() for x in v['places']]
    questions = sum(len(d) for d in key['pages'].values() if not d.get('hand'))
    def status_of(v):
        return v['status'][0] if len(v['status']) == 1 else 'mixed'
    both = {}
    for v in places:
        both.setdefault(status_of(v), {'split': 0, 'join': 0})[v['kind']] += 1
    lines_in = {}
    for v in places:
        lines_in[status_of(v)] = lines_in.get(status_of(v), 0) + len(v['lines'])
    page_rows = []
    for p in pages:
        d = key['pages'].get(p['page'], {})
        page_rows.append({'page': p['page'], 'kind': p['kind'], 'lines': p['lines'],
                          'main_status': max(p['status'], key=p['status'].get),
                          'blla_split': len(p['split']['blla']), 'blla_join': len(p['join']['blla']),
                          'ppocrv6_split': len(p['split']['ppocrv6']), 'ppocrv6_join': len(p['join']['ppocrv6']),
                          'places': sum(len(v['places']) for v in d.values()) if not d.get('hand') else 0})
    return {'provenance': provenance(pages), 'detectors': per_det, 'places': len(places), 'questions': questions, 'both': both,
            'lines_in_places': lines_in, 'typed_pages_with_places': sum(1 for r in page_rows if r['places']),
            'hand_pages': [t['page'] for t in hands], 'hand_lines': sum(len(key['pages'][t['page']]['lines']) for t in hands),
            'minutes': round(secs / 60, 1), 'pages': page_rows,
            'settings': {'join_gap': JOIN_GAP, 'grab': GRAB, 'slack': SLACK, 'seed': SEED}}


def write_md(path: Path, s: dict):
    pv, dt = s['provenance'], s['detectors']
    nl = pv['lines'].get('drafted', 0) + pv['lines'].get('drawn', 0)
    nw = pv['words'].get('drafted', 0) + pv['words'].get('drawn', 0)
    pct = lambda a, b: f'{100 * a / b:.0f}%' if b else '-'
    def rate(status):
        got = s['both'].get(status, {'split': 0, 'join': 0})
        return got['split'], got['join']
    L = ['# The placement truth\'s typed lines against blla and PP-OCRv6 (W46.fix-place-truth-lines)', '',
         'Generated by `scripts/segbench/place_truth_lines.py`. The measurement audit\'s OCR-10 '
         '(`execution-plans/processing-review/11-measurement-audit.md`): the typed truth\'s lines are largely Apple '
         'Vision\'s, Vision is scored on them, and since 2026-10-29 the line pass rate (a drag from a line\'s first '
         'truth word to its last returns exactly its words) decides the reading copy. No model read a page here and '
         'no money was spent: kraken 7.1.1\'s blla ran on the Mac\'s CPU, PP-OCRv6 medium det\'s polygons are the pinned '
         'FarmShare run\'s, and no Claude subagent drew or redrew anything (owner, 2026-10-30).', '',
         '## Where the typed lines come from', '',
         f'Of the {nl:,} typed truth lines on the {pv["pages"]} owner-typed pages, **{pv["lines"].get("drafted", 0):,} '
         f'({pct(pv["lines"].get("drafted", 0), nl)}) are Vision-derived** (status `drafted`: Vision\'s lines, its '
         f'word boxes trimmed to the ink) and **{pv["lines"].get("drawn", 0):,} ({pct(pv["lines"].get("drawn", 0), nl)}) '
         'were drawn** by Claude Opus 5.5 subagents on the 20 pages `place_truth.py` redrew'
         + (f'; {pv["lines"]["absent"]} more are text with no geometry' if pv['lines'].get('absent') else '') + '. '
         f'By scored words: {pv["words"].get("drafted", 0):,} ({pct(pv["words"].get("drafted", 0), nw)}) lie on '
         f'Vision-derived lines, {pv["words"].get("drawn", 0):,} on drawn ones. A drawn line can still hold Vision\'s '
         'word boxes (p044, p087, p088, p097, p099 kept many), so the word-box count the audit quotes (10,539 of '
         '14,124 Vision\'s) is not the line count.', '',
         '## Where the detectors group differently', '',
         'Each scored truth word goes to the detector line whose polygon holds its centre (the nearest baseline when '
         f'several do, else a baseline within {GRAB} of the word\'s height). PP-OCRv6\'s pieces on one row are joined '
         f'across gaps up to {JOIN_GAP} of the row\'s height, so a gutter or a tab stop stays a break. A **split** is '
         'one truth line spread over two or more detector lines (a detector line counts when it holds two of the '
         'line\'s words, or only that line\'s); a **join** is one detector line holding at least half of each of two '
         'or more truth lines.', '',
         '| | blla | PP-OCRv6 det |', '|---|---:|---:|',
         f'| truth lines split | {dt["blla"]["split_lines"]} | {dt["ppocrv6"]["split_lines"]} |',
         f'| joins (detector lines over 2+ truth lines) | {dt["blla"]["joins"]} | {dt["ppocrv6"]["joins"]} |',
         f'| scored words in no detector line | {dt["blla"]["unassigned_words"]} | {dt["ppocrv6"]["unassigned_words"]} |',
         '',
         'By the truth line\'s status (splits / joins; a join over lines of both statuses is "mixed"):', '',
         '| status | blla | PP-OCRv6 det | both (on the sheet) | lines |', '|---|---|---|---|---:|']
    for st in ('drafted', 'drawn', 'mixed'):
        f = lambda k: (lambda g: f'{g["split"]} / {g["join"]}')(dt[k]['by_status'].get(st, {'split': 0, 'join': 0}))
        sp, jo = rate(st)
        L.append(f'| {st} | {f("blla")} | {f("ppocrv6")} | {sp} / {jo} | {pv["lines"].get(st, "-")} |')
    d_sp, d_jo = rate('drafted')
    w_sp, w_jo = rate('drawn')
    L += ['', f'**{s["places"]} places where both detectors agree against the truth**, on {s["typed_pages_with_places"]} '
          f'of the {pv["pages"]} pages. On Vision-derived lines: {d_sp + d_jo} places ({d_sp} splits, {d_jo} joins) '
          f'touching {s["lines_in_places"].get("drafted", 0)} of the {pv["lines"].get("drafted", 0):,} lines '
          f'({pct(s["lines_in_places"].get("drafted", 0), pv["lines"].get("drafted", 0))}); on drawn lines: '
          f'{w_sp + w_jo} ({w_sp} splits, {w_jo} joins) touching {s["lines_in_places"].get("drawn", 0)} of '
          f'{pv["lines"].get("drawn", 0):,} ({pct(s["lines_in_places"].get("drawn", 0), pv["lines"].get("drawn", 0))}). '
          'The drawn pages are not a like sample: they were redrawn because Vision\'s lines failed there (tables, '
          'newspaper columns, broken type), so the gap says where the hard pages are as much as who drew the lines. '
          'A disagreement is not an error: two detectors can share a convention the truth does not (a table row in '
          'cells, a letterhead\'s two sides), and both detectors join narrow newspaper columns. The owner rules. '
          'blla left words outside every line on a few pages (most on p008, p088, p058 and p062), which only hides '
          'places there.', '',
          '| page | kind | lines | mostly | blla split / join | PP-OCRv6 split / join | on the sheet |',
          '|---|---|---:|---|---|---|---:|']
    for r in s['pages']:
        L.append(f'| {r["page"]} | {r["kind"]} | {r["lines"]} | {r["main_status"]} | {r["blla_split"]} / '
                 f'{r["blla_join"]} | {r["ppocrv6_split"]} / {r["ppocrv6_join"]} | {r["places"]} |')
    L += ['', '## The owner sheet', '',
          f'{s["places"]} typed places in {s["questions"]} questions (places of one kind on one page share a question, up '
          f'to {GROUP_MAX} at a time, so a table of like rows is answered once), then {len(s["hand_pages"])} hand pages ({", ".join(s["hand_pages"])}: seed '
          f'{SEED}, among the 20 the audit passed) with their {s["hand_lines"]} drawn lines; about {s["minutes"]:.0f} '
          'minutes at the script\'s review rates (an estimate). Blind: every typed place asks whether the boxed text is '
          'one line or breaks at the dashed marks, and the truth\'s answer is "one line" for a split place and '
          '"breaks" for a join place, so the question does not tell which the truth holds. On a hand page the owner '
          'marks each wrong line. The sheet and its key are private, under `ocr-truth/place-lines/`; '
          '`place_truth_lines.py fold ANSWERS.json` writes rulings.json beside them. W46.place-print and '
          'W46.place-geom fold the answers as their first step (gate W46.place-lines-owner-ok); until then their '
          'line pass rates are reported apart on Vision-derived and drawn lines.', '',
          '## Measurement card', '',
          '- **Truth.** The placement truth\'s typed lines as `place_truth.py` left them: Vision\'s lines on the '
          'drafted pages, Claude Opus 5.5 subagents\' on the drawn ones, audited by Claude Sonnet 5.5; the owner has '
          'not checked them. This item checks them; it scores no route.',
          '- **Selection.** All 40 owner-typed pages. Places are every line both detectors group differently, not a '
          'sample; the hand pages are a seeded draw. Neither detector is Vision or a relative of it, and no ABBYY '
          'text is read.',
          '- **Comparison.** Both detectors see the full truth images (PP-OCRv6 a 2400-pixel copy, scaled up). '
          'blla is a baseline segmenter trained on historical documents, PP-OCRv6 det a scene-and-document text '
          'detector; their agreement is the filter.',
          f'- **Noise.** No rerun floor applies (both are deterministic). The grouping rules\' thresholds ({JOIN_GAP} '
          f'join gap, {GRAB} grab, break slack {SLACK} word) move single places; requiring both detectors keeps one '
          'detector\'s fragmenting off the sheet.',
          '- **Scope.** A truth line that both detectors group the same wrong way is not found; the 5 hand pages '
          'sample the drawn hand lines, they do not clear the other 15. The sheet rules on grouping, not on where a '
          'box or baseline lies on a typed page.', '']
    path.write_text('\n'.join(L) + '\n')


SHEET_HTML = r"""<!doctype html><meta charset="utf-8"><title>W46 placement lines check</title>
<style>
body{font:14px -apple-system,sans-serif;margin:0;background:#fff;color:#111;color-scheme:light}
header{position:sticky;top:0;background:#fff;border-bottom:1px solid #ccc;padding:6px 12px;z-index:2}
.page{display:flex;gap:12px;border-bottom:3px solid #999;padding:10px;min-height:90vh}
.img{flex:1 1 62%;position:sticky;top:var(--head,44px);height:calc(100vh - var(--head,44px) - 20px);overflow:auto}
.frame{position:relative;width:100%;cursor:zoom-in}.frame.zoom{width:250%;cursor:zoom-out}.frame img{width:100%;display:block}
.frame svg{position:absolute;left:0;top:0;width:100%;height:100%}
.list{flex:1 1 38%}.it{scroll-margin:var(--head,44px) 0 10px;border:1px solid #ccc;border-radius:4px;padding:6px;margin:8px 0}
.it.cur{outline:3px solid #06f}.it.done{background:#e6f6e6;border-color:#4a4}
.opt{display:block;margin:2px 0}.opt.sel{font-weight:bold;color:#060}.k{color:#888;font-size:12px}.note{color:#a40}
.ln{display:inline-block;min-width:2.2em;margin:2px;padding:1px 4px;border:1px solid #aaa;border-radius:3px;cursor:pointer;text-align:center}
.ln.bad{background:#fdd;border-color:#c00;color:#c00;font-weight:bold}
</style>
<header><b>Placement lines check</b> — __N__ places on typed pages, then __H__ hand pages; about __MINUTES__ minutes.
<b>Typed questions</b> (__Q__): each pink box holds some text, the dashed marks are possible line breaks. Is the text in each
box <b>1</b> one line (ignore the marks) · <b>2</b> separate lines, breaking at every mark · <b>3</b> it differs: some marks
only, or not the same in every box (add a note with <b>t</b>) · <b>e</b> either will do / can't tell. <b>Hand pages:</b> every line is boxed and numbered, its baseline drawn; click
a line (or its number) that is wrong (box or baseline off its line, two lines in one, one line in two), then
<b>a</b> when the page is checked. <b>t</b> add a note · <b>n/p</b> next/previous · <b>z</b> zoom.
Answers stay in this browser; <button onclick="exportAnswers()">Export answers</button><span id="prog"></span></header>
<div id="root"></div>
<script>
const DATA=__DATA__;const KEY='w46-place-lines';
let A=JSON.parse(localStorage.getItem(KEY)||'{}');const items=[];
function esc(s){return s.replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
function save(){localStorage.setItem(KEY,JSON.stringify(A));prog()}
function prog(){const d=items.filter(it=>done(it)).length;document.getElementById('prog').textContent=` ${d} / ${items.length} answered`}
function rec(it){return (A[it.page]=A[it.page]||{})[it.key]=(A[it.page]||{})[it.key]||{}}
function get(it){return (A[it.page]||{})[it.key]||{}}
function done(it){const v=get(it);return it.hand?!!v.checked:!!v.pick}
const LABEL={'1':'one line','2':'breaks at every mark','3':'breaks at some marks only','e':"either will do / can't tell"};
function paint(it){const v=get(it);it.el.classList.toggle('done',done(it));
 it.el.querySelectorAll('.opt').forEach(o=>o.classList.toggle('sel',o.dataset.v===v.pick));
 if(it.hand){const bad=new Set(v.bad||[]);it.el.querySelectorAll('.ln').forEach(s=>s.classList.toggle('bad',bad.has(+s.dataset.id)));
  it.svg.querySelectorAll('[data-id]').forEach(r=>r.setAttribute('stroke',bad.has(+r.dataset.id)?'#d00':(r.dataset.c)))}
 it.el.querySelector('.note').textContent=v.note?'note: '+v.note:''}
function rect(b,c,w,extra){return `<rect x="${b[0]*1000}" y="${b[1]*1000}" width="${b[2]*1000}" height="${b[3]*1000}" fill="none" stroke="${c}" stroke-width="${w}" vector-effect="non-scaling-stroke" ${extra||''}/>`}
const root=document.getElementById('root');
for(const p of DATA){const div=document.createElement('div');div.className='page';
 let h=`<div class="img"><div class="frame"><img src="${p.img}"><svg viewBox="0 0 1000 1000" preserveAspectRatio="none"></svg></div></div><div class="list"><b>${p.page}</b>`;
 if(p.type==='typed'){for(const x of p.items){h+=`<div class="it" data-key="${x.id}"><span class="k">${x.id} · ${x.boxes.length} box${x.boxes.length>1?'es':''}</span>`;
   for(const v of ['1','2','3','e'])h+=`<span class="opt" data-v="${v}"><span class="k">${v}:</span> ${LABEL[v]}</span>`;
   h+=`<span class="note"></span></div>`}}
 else{h+=`<div class="it" data-key="lines"><span class="k">hand page: click each wrong line, then a</span><br>`;
  for(const l of p.lines)h+=`<span class="ln" data-id="${l.id}">${l.id}</span>`;
  h+=`<span class="opt" data-v="a"><span class="k">a:</span> page checked</span><span class="note"></span></div>`}
 div.innerHTML=h+'</div>';root.appendChild(div);
 const frame=div.querySelector('.frame'),svg=div.querySelector('svg');
 frame.onclick=()=>{frame.classList.toggle('zoom');if(items[cur])show(items[cur])};
 div.querySelectorAll('.it').forEach(el=>{
  const it={page:p.page,key:el.dataset.key,el,pane:div.querySelector('.img'),frame,svg,hand:p.type==='hand'};
  if(it.hand){const C=['#f0a','#08c'];it.lines=p.lines;
   svg.innerHTML=p.lines.map((l,i)=>rect(l.box,C[i%2],2,`data-id="${l.id}" data-c="${C[i%2]}"`)+
    `<polyline points="${l.baseline.map(q=>q[0]*1000+','+q[1]*1000).join(' ')}" fill="none" stroke="${C[i%2]}" stroke-width="1.5" vector-effect="non-scaling-stroke"/>`+
    `<text x="${l.box[0]*1000-2}" y="${(l.box[1]+l.box[3])*1000}" font-size="9" fill="${C[i%2]}" text-anchor="end">${l.id}</text>`).join('');
   el.querySelectorAll('.ln').forEach(s=>s.addEventListener('click',e=>{e.stopPropagation();toggle(it,+s.dataset.id)}));
   svg.style.pointerEvents='none'}
  else it.x=p.items.find(x=>x.id===el.dataset.key);
  items.push(it);paint(it);el.addEventListener('click',()=>go(items.indexOf(it)))})}
function toggle(it,id){const v=rec(it);const s=new Set(v.bad||[]);s.has(id)?s.delete(id):s.add(id);v.bad=[...s].sort((a,b)=>a-b);save();paint(it)}
let cur=0,first=true;function go(i){if(i<0||i>=items.length)return;const prev=first?null:items[cur];first=false;items[cur].el.classList.remove('cur');cur=i;
 const el=items[cur].el;el.classList.add('cur');
 if(!prev||prev.page!==items[cur].page)el.closest('.page').scrollIntoView({block:'start'});
 el.scrollIntoView({block:'nearest'});show(items[cur])}
function head(){const h=document.querySelector('header').offsetHeight;document.documentElement.style.setProperty('--head',h+'px');
 document.querySelectorAll('.page').forEach(d=>d.style.scrollMarginTop=h+'px')}
addEventListener('resize',head);head();
const PAD=.01;
function show(it){if(!it||it.hand)return;const bs=it.x.boxes;
 const x0=Math.min(...bs.map(q=>q[0])),y0=Math.min(...bs.map(q=>q[1])),b=[x0,y0,Math.max(...bs.map(q=>q[0]+q[2]))-x0,Math.max(...bs.map(q=>q[1]+q[3]))-y0];
 it.svg.innerHTML=bs.map(q=>rect([q[0]-PAD/2,q[1]-PAD/2,q[2]+PAD,q[3]+PAD],'#f0a',3)).join('')+it.x.marks.map(m=>
  `<line x1="${m[0]*1000}" y1="${m[1]*1000}" x2="${m[2]*1000}" y2="${m[3]*1000}" stroke="#06f" stroke-width="2.5" stroke-dasharray="6 4" vector-effect="non-scaling-stroke"/>`).join('');
 const f=it.frame,pane=it.pane,centre=()=>{pane.scrollTop=(b[1]+b[3]/2)*f.offsetHeight-pane.clientHeight/2;
  pane.scrollLeft=(b[0]+b[2]/2)*f.offsetWidth-pane.clientWidth/2};
 const img=f.querySelector('img');if(img.complete)centre();else img.addEventListener('load',centre,{once:true})}
document.addEventListener('keydown',e=>{const it=items[cur];if(!it)return;
 if(e.key==='n')go(cur+1);else if(e.key==='p')go(cur-1);else if(e.key==='z'){it.frame.classList.toggle('zoom');show(it)}
 else if(!it.hand&&['1','2','3','e'].includes(e.key)){rec(it).pick=e.key;save();paint(it);go(cur+1)}
 else if(it.hand&&e.key==='a'){rec(it).checked=true;save();paint(it);go(cur+1)}
 else if(e.key==='t'){const t=prompt('Note:',get(it).note||'');if(t!==null){rec(it).note=t;save();paint(it)}}});
function exportAnswers(){const b=new Blob([JSON.stringify(A,null,1)],{type:'application/json'});
 const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='place-lines-answers.json';a.click()}
prog();go(0);
</script>"""


# ---------------------------------------------------------------- fold

def fold(key: dict, answers: dict) -> dict:
    """Per typed question (its ruling holds for each of its places; counts are of places): whether the truth's grouping stands ('one' or 'breaks' against the owner's pick); per hand
    page, the lines the owner marked wrong. Unanswered stays open."""
    pick = {'1': 'one', '2': 'breaks', '3': 'some', 'e': 'either'}
    rulings, n = {}, {'typed': {}, 'hand_pages': {}, 'hand_lines_wrong': 0, 'hand_lines': 0}
    for p, d in key['pages'].items():
        got = answers.get(p) or {}
        if d.get('hand'):
            a = got.get('lines') or {}
            r = {'ruling': 'checked' if a.get('checked') else 'open', 'wrong': a.get('bad', []), 'note': a.get('note')}
            rulings[p] = {'hand': True, 'lines': d['lines'], **r}
            n['hand_pages'][r['ruling']] = n['hand_pages'].get(r['ruling'], 0) + 1
            if a.get('checked'):
                n['hand_lines'] += len(d['lines'])
                n['hand_lines_wrong'] += len(r['wrong'])
            continue
        for iid, v in d.items():
            a = got.get(iid) or {}
            owner = pick.get(a.get('pick'))
            if owner is None:
                k = 'open'
            elif owner == 'either':
                k = 'either'
            elif owner == 'some':   # breaks, but not at every mark: a join place's truth breaks at every mark
                k = 'truth wrong' if v['truth'] == 'one' else 'truth partly wrong'
            else:
                k = 'truth stands' if owner == v['truth'] else 'truth wrong'
            rulings.setdefault(p, {})[iid] = {**v, 'owner': owner, 'ruling': k, 'note': a.get('note')}
            n['typed'][k] = n['typed'].get(k, 0) + len(v['places'])
    return {'counts': n, 'rulings': rulings}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    d = sub.add_parser('detect')
    d.add_argument('detector', choices=DETECTORS)
    d.add_argument('--pages')
    sub.add_parser('compare')
    b = sub.add_parser('build')
    b.add_argument('--out', type=Path, default=SHEET)
    b.add_argument('--results', type=Path, default=RESULTS)
    f = sub.add_parser('fold')
    f.add_argument('answers', type=Path)
    f.add_argument('--out', type=Path, default=SHEET)
    a = ap.parse_args()
    only = set(a.pages.split(',')) if getattr(a, 'pages', None) else None
    if a.cmd == 'detect':
        venv = PH.VENV.get(a.detector)
        if venv and os.environ.get('PLACE_LINES_WORKER') != a.detector:
            cmd = [str(venv), __file__, 'detect', a.detector] + (['--pages', a.pages] if a.pages else [])
            subprocess.run(cmd, check=True, env=dict(os.environ, PLACE_LINES_WORKER=a.detector))
            return
        DETECT[a.detector](typed_pages(only))
    elif a.cmd == 'compare':
        compare()
    elif a.cmd == 'build':
        s = build(a.out, a.results)
        print(f'{s["places"]} typed places + {len(s["hand_pages"])} hand pages, ~{s["minutes"]:.0f} min -> '
              f'{a.out / "index.html"}')
    else:
        key = json.loads((a.out / 'key.json').read_text())
        r = fold(key, json.loads(a.answers.read_text()))
        (a.out / 'rulings.json').write_text(json.dumps(r, ensure_ascii=False, indent=1))
        print(json.dumps(r['counts']))


if __name__ == '__main__':
    main()
