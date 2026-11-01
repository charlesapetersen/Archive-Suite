"""W46.place-hands-lines — the shipped hand placer and its 0.67 gate, rescored on the line pass rate (OCR-11).

W46.place-hands-fu chose the hand route (blla lines, McCATMuS forced alignment, the per-page `conf` matcher pick,
a 0.67 CTC-confidence gate) on per-word Find, which the owner ruled is no evidence of selection (c096de18,
F-placement §6.2 "Selection is a line"). Here every placement hypothesis `place_hands.py align` wrote (every
detector, placer, matcher and reading) is written as the same PDF text layer place_hands scores (`oracle --words
--fit`, here `--no-image`: the text and page size are the same, the selection does not read the image) and each
truth line is dragged in PDFKit (`place_functional drag`, W46.place-geom's scorer).

What a line expects. A reading is not the truth, so a line's expected selection is the reading's own words for
that line: the reading's words are aligned to the truth's words in order (a word-level edit distance, substitution
cost the two words' normalised character distance), each reading word takes the line of the truth word it is
aligned to, and an inserted word the line of its neighbours (at a line break, of the neighbour on its own reading
line). A truth line the reading has no word for fails (`unread`); so do lines the placer leaves out. The pass is
place-geom's: a drag from the line's first ink to its last, at mid-height, returns exactly those words, in order,
with no line break. A line of fewer than two truth words is not scored; neither is one read more than 45° off level.

The drag. The owner pages' truth has word boxes; Bentham's has line geometry only (PAGE-XML baselines), so for
both the drag runs along the truth line itself: from its baseline's left end to its right end, lifted to the
middle of its band (place_truth draws the baseline at BASELINE_FRAC of the band). The owner's line rulings for the
hand pages (place_geom HAND_MERGE, HAND_OPEN) are folded in.

Readings: truth, Gemini 3.8 Flash (a drafter of the owner-hand truth; owner pages only), LightOnOCR-3 and
Qwen3.6-27B (the non-drafter reading: neither drafted nor checked the hand truth; both groups).

Usage (the drags take no model; run under the heavy lock all the same, as they work through a page set):
  uv run --with rapidfuzz --with numpy python place_hands_lines.py run      # CACHE/lines-rows.jsonl
  uv run --with rapidfuzz --with numpy python place_hands_lines.py report   # segbench-results/place-hands-lines.{json,md}
"""
from __future__ import annotations

import argparse
import json
import math
import os
import random
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from rapidfuzz.distance import Levenshtein

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import place_hands as P  # noqa: E402
import place_truth  # noqa: E402
from place_geom import HAND_MERGE, HAND_OPEN  # noqa: E402

CACHE = P.CACHE
ROWS = CACHE / 'lines-rows.jsonl'
RESULTS = P.RESULTS
FUNCTIONAL = Path(os.environ.get('PLACE_FUNCTIONAL', '/tmp/phl_functional'))
WRITER = Path(os.environ.get('PLACE_GEOM_WRITER', '/tmp/phl_writer'))   # place_geom_writer.swift, built as its header says
WRITERS = ('word', 'lab')
PT = 72 / 300
FRAC = place_truth.BASELINE_FRAC
GAP = 0.6           # the alignment's cost of a reading or truth word left unpaired
DEFAULT = 'blla.ctc-mccatmus-conf'   # the shipped hand placer (W46.place-hands-fu)
GATE = 0.67         # its CTC-confidence gate: a page below goes to the text page
READINGS = P.READINGS
NONDRAFTER = 'qwen3.6-27b'
SEED, DRAWS = 46, 2000


def norm(w: str) -> str:
    return re.sub(r'[^\w]', '', w.lower())


# ---------------------------------------------------------------- the truth's lines

def truth_lines(t):
    """[(id, [truth tokens], drag start, drag end)] in reading order, the owner's hand rulings folded."""
    ls = [ln for ln in t['lines'] if ln.get('text', '').strip() and ln.get('baseline')]
    drop = HAND_OPEN.get(t['page'], set())
    parent = {ln['id']: ln['id'] for ln in ls}
    for a, b in HAND_MERGE.get(t['page'], []):
        if a in parent and b in parent:
            parent[b] = parent[a]
    groups: dict = {}
    for ln in ls:
        if ln['id'] not in drop:
            groups.setdefault(parent[ln['id']], []).append(ln)
    out = []
    W, H = t['width'], t['height']
    for root, g in groups.items():
        toks = [w for ln in g for w in ln['text'].split()]
        ends = []
        for ln in g:
            bl = sorted(ln['baseline'])
            (x0, y0), (x1, y1) = bl[0], bl[-1]
            band = max(ln['box'][3] - abs(y1 - y0), 0.25 * ln['box'][3])
            lift = (FRAC - 0.5) * band
            ends.append(((x0, y0 - lift), (x1, y1 - lift)))
        s = min((e[0] for e in ends), key=lambda p: p[0])
        e = max((e[1] for e in ends), key=lambda p: p[0])
        sideways = abs(math.degrees(math.atan2((e[1] - s[1]) * H, (e[0] - s[0]) * W))) > 45
        out.append({'id': '+'.join(str(ln['id']) for ln in g), 'tokens': toks, 'start': list(s), 'end': list(e),
                    'scored': len(toks) >= 2 and not sideways})
    return out


def align_words(rw: list[str], tw: list[str]) -> list[int | None]:
    """For each reading word, the index of the truth word it is paired with (None: inserted)."""
    n, m = len(rw), len(tw)
    a, b = [norm(x) for x in rw], [norm(x) for x in tw]
    D = [[0.0] * (m + 1) for _ in range(n + 1)]
    for i in range(1, n + 1):
        D[i][0] = i * GAP
    for j in range(1, m + 1):
        D[0][j] = j * GAP
    for i in range(1, n + 1):
        ai, Di, Dp = a[i - 1], D[i], D[i - 1]
        for j in range(1, m + 1):
            sub = Dp[j - 1] + (Levenshtein.normalized_distance(ai, b[j - 1]) if ai or b[j - 1] else 0.0)
            Di[j] = min(sub, Dp[j] + GAP, Di[j - 1] + GAP)
    out: list[int | None] = [None] * n
    i, j = n, m
    while i > 0 and j > 0:
        sub = D[i - 1][j - 1] + (Levenshtein.normalized_distance(a[i - 1], b[j - 1]) if a[i - 1] or b[j - 1] else 0.0)
        if abs(D[i][j] - sub) < 1e-9:
            out[i - 1] = j - 1
            i, j = i - 1, j - 1
        elif abs(D[i][j] - (D[i - 1][j] + GAP)) < 1e-9:
            i -= 1
        else:
            j -= 1
    return out


def expected(t, route, tl):
    """Truth line id -> the reading's words expected in its selection, in reading order."""
    rl = P.reading(t, route)
    if rl is None:
        return None
    rw, rline = [], []
    for k, ln in enumerate(rl):
        for w in ln.split():
            rw.append(w)
            rline.append(k)
    tw, tid = [], []
    for L in tl:
        for w in L['tokens']:
            tw.append(w)
            tid.append(L['id'])
    pair = align_words(rw, tw)
    lab = [tid[p] if p is not None else None for p in pair]
    for i in range(len(rw)):
        if lab[i] is not None or pair[i] is not None:
            continue
        prev = next((k for k in range(i - 1, -1, -1) if pair[k] is not None), None)
        nxt = next((k for k in range(i + 1, len(rw)) if pair[k] is not None), None)
        lp = tid[pair[prev]] if prev is not None else None
        ln_ = tid[pair[nxt]] if nxt is not None else None
        if lp == ln_ or ln_ is None:
            lab[i] = lp
        elif lp is None:
            lab[i] = ln_
        else:
            lab[i] = lp if rline[prev] == rline[i] else ln_
    out = {L['id']: [] for L in tl}
    for w, L in zip(rw, lab):
        if L is not None:
            out[L].append(w)
    return {L: ' '.join(ws) for L, ws in out.items()}


# ---------------------------------------------------------------- the drags

def score_one(t, hyp_dir: Path, tl, exp, work: Path):
    """One page of one hypothesis, written both ways: `word`, place_hands's own per-word layer (every placed word
    its own run, sized to its box), and `lab`, the app's writer (one run per placed line over the line's box,
    the Vision OCR lab's SearchableWriter.compose, as W46.place-geom drives it)."""
    k = P.key(t)
    hyp = hyp_dir / f'{k}.json'
    h = json.loads(hyp.read_text())
    stem = work / f'{hyp_dir.name}.{k}'
    truth = place_truth.STORE / f'{k}.json'
    scored = [L for L in tl if L['scored']]
    drags = [{'id': L['id'], 'expected': exp[L['id']], 'start': L['start'], 'end': L['end']}
             for L in scored if exp[L['id']]]
    dj = Path(f'{stem}.drags.json')
    dj.write_text(json.dumps({'lines': drags}))
    det, method, route = hyp_dir.name.split('.', 2)
    meta = h.get('meta', {})
    rows = []
    for writer in WRITERS:
        pdf, do = Path(f'{stem}.{writer}.pdf'), Path(f'{stem}.{writer}.out.json')
        unplaced = 0
        if writer == 'word':
            subprocess.run([str(FUNCTIONAL), 'oracle', str(truth), str(pdf), '--words', str(hyp), '--fit',
                            '--no-image'], check=True, stdout=subprocess.DEVNULL)
        else:
            jf = Path(f'{stem}.jobs.json')
            lines = [{'text': ln['text'], 'box': ln['box']} for ln in h.get('lines', []) if ln.get('text', '').strip() and ln.get('box') and len(ln['box']) == 4]
            jf.write_text(json.dumps([{'out': str(pdf), 'width': t['width'] * PT, 'height': t['height'] * PT,
                                       'lines': lines}]))
            out = subprocess.run([str(WRITER), str(jf)], check=True, capture_output=True, text=True).stdout
            unplaced = len(json.loads(out)['unplaced'])
            jf.unlink()
        subprocess.run([str(FUNCTIONAL), 'drag', str(dj), str(pdf), str(do)], check=True, stdout=subprocess.DEVNULL)
        got = json.loads(do.read_text())
        pdf.unlink()
        do.unlink()
        rows.append({'page': t['page'], 'group': t['group'], 'detector': det, 'method': method, 'reading': route,
                     'writer': writer, 'lines': len(scored), 'unread': len(scored) - len(drags),
                     'passed': got['passed'], 'broken': sum(r['broken'] for r in got['lines']),
                     'empty': sum(not r['got'] for r in got['lines']), 'unplaced': unplaced,
                     'ctc_conf': meta.get('ctc_conf'), 'span': meta.get('span'),
                     'passes': [r['id'] for r in got['lines'] if r['pass']]})
    dj.unlink()
    return rows


def cmd_run(a):
    if not FUNCTIONAL.exists():
        subprocess.run(['swiftc', '-O', str(HERE / 'place_functional.swift'), '-o', str(FUNCTIONAL)], check=True)
    ps = [t for t in P.pages() if P.keep(t)]
    tls = {t['page']: truth_lines(t) for t in ps}
    exps = {(t['page'], r): expected(t, r, tls[t['page']]) for t in ps for r in READINGS}
    jobs = []
    for d in sorted((CACHE / 'hyp').iterdir()):
        route = d.name.split('.', 2)[2]
        for t in ps:
            if (d / f'{P.key(t)}.json').exists() and exps.get((t['page'], route)) is not None:
                jobs.append((t, d))
    work = Path(tempfile.mkdtemp(prefix='phl-', dir=CACHE))
    with ThreadPoolExecutor(int(os.environ.get('PHL_WORKERS', '6'))) as ex:
        rows = sum(ex.map(lambda td: score_one(td[0], td[1], tls[td[0]['page']], exps[(td[0]['page'], td[1].name.split('.', 2)[2])], work), jobs), [])
    work.rmdir()
    with ROWS.open('w') as f:
        for r in rows:
            f.write(json.dumps(r) + '\n')
    # the reading's own coverage of the scored lines, independent of any placer
    cov = {}
    for (p, r), e in exps.items():
        if e is None:
            continue
        sc = [L for L in tls[p] if L['scored']]
        cov.setdefault(r, [0, 0])
        cov[r][0] += sum(1 for L in sc if e[L['id']])
        cov[r][1] += len(sc)
    (CACHE / 'lines-coverage.json').write_text(json.dumps(cov))
    print(len(rows), 'page rows')


# ---------------------------------------------------------------- the report

def load_rows():
    return [json.loads(l) for l in ROWS.read_text().splitlines()]


def route_of(r):
    return f"{r['detector']}.{r['method']}"


def boot(pairs, gated=None):
    """Paired over pages: pooled pass rate of b minus a, as points; pairs = [(pass_a, pass_b, lines)]."""
    if not pairs:
        return None
    rng = random.Random(SEED)
    tot = sum(n for _, _, n in pairs)
    d0 = 100 * (sum(b for _, b, _ in pairs) - sum(a for a, _, _ in pairs)) / max(1, tot)
    ds = []
    for _ in range(DRAWS):
        s = [pairs[rng.randrange(len(pairs))] for _ in pairs]
        n = sum(x[2] for x in s)
        ds.append(100 * (sum(x[1] for x in s) - sum(x[0] for x in s)) / max(1, n))
    ds.sort()
    return d0, ds[int(0.025 * DRAWS)], ds[int(0.975 * DRAWS) - 1]


def table(rows, group, reading):
    by = {}
    for r in rows:
        if r['group'] == group and r['reading'] == reading:
            by.setdefault(route_of(r), {})[r['page']] = r
    if DEFAULT not in by:
        return None
    base = by[DEFAULT]
    out = []
    for route, pg in by.items():
        common = [p for p in pg if p in base]
        pairs = [(base[p]['passed'], pg[p]['passed'], pg[p]['lines']) for p in common]
        n = sum(pg[p]['lines'] for p in pg)
        out.append({'route': route, 'pages': len(pg), 'lines': n, 'passed': sum(pg[p]['passed'] for p in pg),
                    'unread': sum(pg[p]['unread'] for p in pg), 'broken': sum(pg[p]['broken'] for p in pg),
                    'delta': None if route == DEFAULT else boot(pairs)})
    out.sort(key=lambda x: -x['passed'] / max(1, x['lines']))
    return out


def gate_sweep(rows, group, reading, route=DEFAULT):
    pg = [r for r in rows if r['group'] == group and r['reading'] == reading and route_of(r) == route]
    if not pg:
        return None
    ths = sorted({0.0, GATE, *[round(r['ctc_conf'], 3) for r in pg if r['ctc_conf'] is not None]})
    out = []
    for th in ths:
        kept = [r for r in pg if (r['ctc_conf'] or 0) >= th]
        kl = sum(r['lines'] for r in kept)
        out.append({'threshold': th, 'pages_kept': len(kept), 'pages': len(pg), 'lines': sum(r['lines'] for r in pg),
                    'kept_lines': kl, 'passed': sum(r['passed'] for r in kept),
                    'kept_failing': kl - sum(r['passed'] for r in kept)})
    return out


def cmd_report(a):
    allrows = load_rows()
    cov = json.loads((CACHE / 'lines-coverage.json').read_text())
    res = {'default': DEFAULT, 'gate': GATE, 'coverage': cov, 'tables': {}, 'gate_sweeps': {}, 'gate_paired': {}}
    for w in WRITERS:
        rows = [r for r in allrows if r['writer'] == w]
        for g in P.GROUPS:
            for rd in READINGS:
                k = f'{w}|{g}|{rd}'
                tb = table(rows, g, rd)
                if tb:
                    res['tables'][k] = tb
                gs = gate_sweep(rows, g, rd)
                if gs:
                    res['gate_sweeps'][k] = gs
                # the gate against no gate, paired over pages: the passing lines it gives up (on pages sent to the
                # text page) and the failing ones it spares the user
                pg = [r for r in rows if r['group'] == g and r['reading'] == rd and route_of(r) == DEFAULT]
                if pg:
                    off = [r for r in pg if (r['ctc_conf'] or 0) < GATE]
                    res['gate_paired'][k] = {
                        'pages': len(pg), 'sent_to_text': [r['page'] for r in off],
                        'passing_lines_lost': sum(r['passed'] for r in off),
                        'failing_lines_avoided': sum(r['lines'] - r['passed'] for r in off),
                        'delta': boot([(r['passed'], r['passed'] if (r['ctc_conf'] or 0) >= GATE else 0, r['lines'])
                                       for r in pg])}
    # the writers against each other, the shipped placer, paired over pages
    res['writer_paired'] = {}
    for g in P.GROUPS:
        for rd in READINGS:
            pg = {(r['page'], r['writer']): r for r in allrows
                  if r['group'] == g and r['reading'] == rd and route_of(r) == DEFAULT}
            pages = sorted({p for p, _ in pg})
            if pages:
                res['writer_paired'][f'{g}|{rd}'] = boot([(pg[(p, 'word')]['passed'], pg[(p, 'lab')]['passed'],
                                                           pg[(p, 'lab')]['lines']) for p in pages])
    (RESULTS / 'place-hands-lines.json').write_text(json.dumps(res, indent=1) + '\n')
    md = RESULTS / 'place-hands-lines.md'
    head = md.read_text().split(MARK)[0] if md.exists() else '# W46.place-hands-lines\n\n'
    md.write_text(head + MARK + '\n' + tables_md(res) + MARK + '\n' + (md.read_text().split(MARK)[2] if md.exists() and md.read_text().count(MARK) >= 2 else ''))
    return res


MARK = '<!-- tables -->'
SHOW = 8   # routes per table; the json has every one
NAMES = {'truth': 'truth text', 'gemini3.8-flash': 'Gemini 3.8 Flash (a drafter)',
         'lightonocr3-4b': 'LightOnOCR-3', 'qwen3.6-27b': 'Qwen3.6-27B (non-drafter)'}


def pct(a, n):
    return f'{100 * a / n:.1f} ({a}/{n})' if n else '—'


def ci(d):
    return '—' if d is None else f'{d[0]:+.1f} ({d[1]:+.1f} to {d[2]:+.1f})'


def tables_md(res):
    out = []
    for w, wname in (('lab', "the app's line writer (lab)"), ('word', "place_hands's per-word layer")):
        out.append(f'## Line pass rate, {wname}\n')
        out.append('Δ is against the shipped placer (`' + DEFAULT + '`) on the same pages, paired over pages '
                   f'(bootstrap, {DRAWS} draws). Unread: scored lines the reading has no word for (they fail on every '
                   f'placer). The best {SHOW} routes and the shipped one; every route is in the json.\n')
        for g in P.GROUPS:
            for rd in READINGS:
                tb = res['tables'].get(f'{w}|{g}|{rd}')
                if not tb:
                    continue
                n = next(x for x in tb if x['route'] == DEFAULT)
                out.append(f"### {g}, {NAMES[rd]} ({n['pages']} pages, {n['lines']} lines, {n['unread']} unread)\n")
                out.append('| rank | detector.placer | line pass % | Δ vs shipped (95% CI) | broken drags |')
                out.append('|---:|---|---:|---|---:|')
                for i, x in enumerate(tb):
                    if i < SHOW or x['route'] == DEFAULT:
                        nm = f"**{x['route']}** (shipped)" if x['route'] == DEFAULT else x['route']
                        out.append(f"| {i + 1} | {nm} | {pct(x['passed'], x['lines'])} | {ci(x['delta'])} | {x['broken']} |")
                out.append(f'\n{len(tb)} routes.\n')
    out.append('## The 0.67 gate on the line pass rate\n')
    out.append('The shipped placer with and without its gate: a page whose CTC confidence is under 0.67 goes to the '
               'text page, so its lines are not selectable on the image (counted as not passing) and its failing '
               'drags are spared the user. Δ is gated minus ungated line pass, paired over pages.\n')
    out.append('| writer | group | reading | pages to the text page | passing lines given up | failing lines spared | Δ line pass (95% CI) |')
    out.append('|---|---|---|---:|---:|---:|---|')
    for k, v in res['gate_paired'].items():
        w, g, rd = k.split('|')
        out.append(f"| {w} | {g} | {NAMES[rd]} | {len(v['sent_to_text'])} of {v['pages']} | {v['passing_lines_lost']} | "
                   f"{v['failing_lines_avoided']} | {ci(v['delta'])} |")
    out.append('\n### The gate swept, lab writer\n')
    out.append('Per threshold: pages kept, lines passing on them (of all scored lines), and the pass rate on the kept '
               'pages. Thresholds are the pages\' own confidences.\n')
    for k, sw in res['gate_sweeps'].items():
        w, g, rd = k.split('|')
        if w != 'lab':
            continue
        out.append(f'#### {g}, {NAMES[rd]}\n')
        out.append('| threshold | pages kept | lines passing (of all) | pass % on kept pages |')
        out.append('|---:|---:|---:|---:|')
        for x in sw:
            mark = ' (shipped)' if abs(x['threshold'] - GATE) < 1e-9 else (' (no gate)' if x['threshold'] == 0 else '')
            out.append(f"| {x['threshold']:.3f}{mark} | {x['pages_kept']}/{x['pages']} | {pct(x['passed'], x['lines'])} | "
                       f"{pct(x['passed'], x['kept_lines'])} |")
        out.append('')
    out.append('## Writers, the shipped placer\n')
    out.append('| group | reading | lab minus per-word, line pass points (95% CI) |')
    out.append('|---|---|---|')
    for k, d in res['writer_paired'].items():
        g, rd = k.split('|')
        out.append(f'| {g} | {NAMES[rd]} | {ci(d)} |')
    cov = res['coverage']
    out.append('\nReading coverage (scored lines with at least one reading word, every placer alike): ' +
               '; '.join(f'{NAMES[r]} {pct(*v)}' for r, v in cov.items()) + '.\n')
    return '\n'.join(out) + '\n'


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('run')
    sub.add_parser('report')
    a = ap.parse_args()
    {'run': cmd_run, 'report': cmd_report}[a.cmd](a)


if __name__ == '__main__':
    main()
