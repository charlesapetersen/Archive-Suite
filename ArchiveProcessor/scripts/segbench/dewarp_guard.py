#!/usr/bin/env python3
"""W46.dewarp-guard — the revisit condition for a dewarped reading copy (owner, 2026-11-06, call 6: none is offered
now).

  python3 dewarp_guard.py classify       Gemini 3.7 Flash on the gateway classes the 64 pages of W46.place-curved-owner
                                         (bound or curled, perspective, display type, handwritten); about $0.15
  python3 dewarp_guard.py class-report   the curved-against-flat gap restated on the bound or curled pairs
                                         -> segbench-results/dewarp-guard-class.json

The classing is P12-5's first step (measurement review pass 12): the curved set of place-curved-owner is the line-angle
cue's top 1%, "pages whose lines fan most", with covers, display type and handwriting among the bound volumes, and
nobody classed it. The owner ruled on 2026-10-30 that a coding session's Claude subagents do not read corpus pages as
data, so the classes come from Gemini 3.7 Flash on the Stanford gateway (owner-authorised route, 2026-10-21 and
2026-10-25), one call a page at temperature 0, on the upright copy at 2048 px, q 0.85 (the review's encoder). No
session looked at a page to class it. The model sees one page at a time and is not told which set it is in.

Reads the Reader sample copy and the two UIUC HEIC originals (read only, converted into the cache); never writes the
corpus. The gateway is real money on a Stanford PTA: CAP bounds this item's spend, ledger CACHE/gateway/calls.jsonl.
"""
from __future__ import annotations

import argparse
import io
import json
import random
import re
import statistics
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import gateway_gemini as G  # noqa: E402

RESULTS = HERE.parents[1] / 'segbench-results'
REH = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
CACHE = REH / 'dewarp-guard'
PCO = REH / 'place-curved-owner'
SAMPLE = REH / 'reader-sample'
UIUC = Path.home() / 'Desktop/Google Drive/Archival Photos JPEGS/UIUC'
CAP = 0.60            # the classing's whole spend; the item's total stays far under the $7 rule
LONG_SIDE, QUALITY = 2048, 85
SEED, DRAWS = 4611, 2000

PAGE = ('bound', 'curled', 'flat')
PERSPECTIVE = ('strong', 'mild', 'none')
HAND = ('mostly', 'some', 'none')

PROMPT = """This is a photograph of one archival document page, taken by a researcher with a phone or camera.
Describe the physical page and the photograph, not the content. Answer with JSON only, exactly these keys:

{"page": "bound" | "curled" | "flat",
 "lines_bent": true | false,
 "perspective": "strong" | "mild" | "none",
 "display_type": true | false,
 "handwritten": "mostly" | "some" | "none",
 "note": "<at most 15 words>"}

page: "bound" if it is a page of a bound volume (book, bound magazine or journal, bound report or ledger) whose paper
rises or bends toward the spine or gutter; "curled" if it is a loose sheet that is visibly bent, curled, rolled or
folded so its surface is not flat; "flat" if the paper lies flat (a bound volume pressed flat counts as flat).
lines_bent: the printed or written lines visibly curve or bow, rather than running straight (slanted straight lines
are not bent).
perspective: how far the camera was off square: "strong" when the page's edges or text lines clearly converge like a
trapezoid, "mild" when slightly, "none" when the page was shot square on.
display_type: true when much of the visible text is display type (headlines, titles, cover or poster lettering,
large decorative or angled type) rather than ordinary body text.
handwritten: how much of the text is handwriting."""


# ---------------------------------------------------------------- the pages
def pages():
    """The 64 rows of the committed place-curved-owner result, with each row's survey record (path and turn)."""
    pco = json.loads((RESULTS / 'place-curved-owner.json').read_text())
    survey = {r['key']: r for r in json.loads((PCO / 'survey.json').read_text())}
    return [(r, survey[r['key']]) for r in pco['rows']]


def source(s):
    """The stored image: the sample copy, or for UIUC a JPEG converted from the HEIC original into the cache."""
    if not s['key'].startswith('uiuc-'):
        return SAMPLE / s['rel']
    dst = CACHE / 'heic' / f"{s['key']}.jpg"
    if not dst.exists():
        dst.parent.mkdir(parents=True, exist_ok=True)
        src = UIUC / f"UIUC — {s['key'].split('-')[1]}.HEIC"
        subprocess.run(['sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '92', str(src), '--out', str(dst)],
                       check=True, stdout=subprocess.DEVNULL)
    return dst


def upright_jpeg(src, turn) -> bytes:
    """The stored pixels turned `turn` clockwise quarter turns (place_curved's survey turn), long side LONG_SIDE."""
    from PIL import Image
    im = Image.open(src)
    im.load()
    im = im.convert('RGB')
    if turn % 4:
        im = im.rotate(-90 * turn, expand=True)
    s = LONG_SIDE / max(im.size)
    if s < 1:
        im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
    b = io.BytesIO()
    im.save(b, 'JPEG', quality=QUALITY)
    return b.getvalue()


# ---------------------------------------------------------------- the classing
def parse(raw):
    """The reply's JSON object with every field checked, or None."""
    if not raw:
        return None
    m = re.search(r'\{.*\}', raw, re.S)
    if not m:
        return None
    try:
        d = json.loads(m.group(0))
    except json.JSONDecodeError:
        return None
    ok = (d.get('page') in PAGE and d.get('perspective') in PERSPECTIVE and d.get('handwritten') in HAND
          and isinstance(d.get('lines_bent'), bool) and isinstance(d.get('display_type'), bool))
    return {k: d.get(k) for k in ('page', 'lines_bent', 'perspective', 'display_type', 'handwritten', 'note')} if ok else None


def cmd_classify(a):
    G.CACHE = CACHE / 'gateway'
    G.CAP = CAP
    todo = []
    for r, s in pages():
        dest = G.CACHE / 'class' / f"{r['key']}.json"
        todo.append((r['key'], b'' if dest.exists() else upright_jpeg(source(s), s['turn']), dest))
    G.run('dewarp-guard-class', todo, PROMPT)
    bad = [k for k, _, d in todo if not parse((json.loads(d.read_text()) if d.exists() else {}).get('raw'))]
    print(f'unparsed: {bad}; ${G.spent():.4f} spent')


# ---------------------------------------------------------------- the restated gap
def classes():
    out = {}
    for f in sorted((CACHE / 'gateway' / 'class').glob('*.json')):
        out[f.stem] = parse(json.loads(f.read_text()).get('raw'))
    return out


def bent(c):
    """Bound or curled: the case the revisit condition names."""
    return bool(c) and c['page'] in ('bound', 'curled')


def rate(r):
    a = r['arms'][r['route']]
    return a['blla_pass'], a['blla_n']


def gap(pairs, draws=DRAWS, seed=SEED):
    """Over (curved row, flat row) pairs: pooled pass rates, their difference with a two-sample page bootstrap, and
    the mean paired page-rate difference with its bootstrap (place_curved's two figures)."""
    if not pairs:
        return None
    C = [rate(c) for c, _ in pairs]
    F = [rate(f) for _, f in pairs]

    def pool(xs):
        n = sum(x[1] for x in xs)
        return 100 * sum(x[0] for x in xs) / n if n else float('nan')
    rng = random.Random(seed)
    ds = sorted(pool([rng.choice(C) for _ in C]) - pool([rng.choice(F) for _ in F]) for _ in range(draws))
    diffs = [100 * c[0] / c[1] - 100 * f[0] / f[1] for c, f in zip(C, F) if c[1] and f[1]]
    rng = random.Random(seed)
    ms = sorted(statistics.mean(rng.choice(diffs) for _ in diffs) for _ in range(draws))
    lo, hi = int(0.025 * draws), int(0.975 * draws) - 1
    return {'pairs': len(pairs),
            'curved': [sum(x[0] for x in C), sum(x[1] for x in C), round(pool(C), 1)],
            'flat': [sum(x[0] for x in F), sum(x[1] for x in F), round(pool(F), 1)],
            'diff': [round(pool(C) - pool(F), 1), round(ds[lo], 1), round(ds[hi], 1)],
            'paired': [round(statistics.mean(diffs), 1), round(ms[lo], 1), round(ms[hi], 1)],
            'worse': sum(d < 0 for d in diffs)}


def cmd_class_report(a):
    pco = json.loads((RESULTS / 'place-curved-owner.json').read_text())
    rows = {r['key']: r for r in pco['rows']}
    cls = classes()
    missing = [k for k in rows if not cls.get(k)]
    curved = [r for r in pco['rows'] if r['group'] == 'curved' and not r['blla_failed']]
    pair_of = {r['pair']: r for r in pco['rows'] if r['group'] == 'flat' and r['pair'] and not r['blla_failed']}
    pairs = [(c, pair_of[c['key']]) for c in curved if c['key'] in pair_of]
    k = lambda r: cls.get(r['key']) or {}
    subsets = {
        'all': pairs,
        'bound_or_curled': [p for p in pairs if bent(k(p[0]))],
        'bound_or_curled_flat_pair_flat': [p for p in pairs if bent(k(p[0])) and not bent(k(p[1]))],
        'not_bound_or_curled': [p for p in pairs if not bent(k(p[0]))],
        'bent_and_lines_bent_flat_pair_straight': [p for p in pairs if bent(k(p[0])) and k(p[0]).get('lines_bent')
                                                   and not k(p[1]).get('lines_bent')],
        'lines_bent': [p for p in pairs if k(p[0]).get('lines_bent')],
        'bound_or_curled_no_display_no_hand': [p for p in pairs if bent(k(p[0])) and not k(p[0]).get('display_type')
                                               and k(p[0]).get('handwritten') == 'none'
                                               and k(p[1]).get('handwritten') == 'none'],
        'strong_perspective_not_bent': [p for p in pairs if k(p[0]).get('perspective') == 'strong'
                                        and not bent(k(p[0]))],
        'display_type': [p for p in pairs if k(p[0]).get('display_type')],
    }
    tally = {}
    for g in ('curved', 'flat'):
        rs = [r for r in pco['rows'] if r['group'] == g]
        tally[g] = {f: {v: sum(1 for r in rs if (k(r).get(f) == v)) for v in vals}
                    for f, vals in (('page', PAGE), ('lines_bent', (True, False)), ('perspective', PERSPECTIVE),
                                    ('display_type', (True, False)), ('handwritten', HAND))}
        tally[g] = {f: {str(v).lower(): n for v, n in d.items()} for f, d in tally[g].items()}
    G.CACHE = CACHE / 'gateway'
    ledger = G.ledger()
    out = {'item': 'W46.dewarp-guard', 'step': 'P12-5 classing', 'model': G.MODEL, 'route': G.API,
           'prompt_sha': __import__('hashlib').sha256(PROMPT.encode()).hexdigest()[:16],
           'unparsed': missing, 'tally': tally,
           'gaps': {n: gap(p) for n, p in subsets.items()},
           'billed': G.billed(ledger),
           'pages': {key: {'group': rows[key]['group'], 'pair': rows[key]['pair'], 'cue': rows[key]['cue'],
                           **(cls.get(key) or {})} for key in rows}}
    (RESULTS / 'dewarp-guard-class.json').write_text(json.dumps(out, indent=1, ensure_ascii=False) + '\n')
    print(json.dumps({x: out[x] for x in ('unparsed', 'tally', 'gaps', 'billed')}, indent=1))


# ---------------------------------------------------------------- the 96: own-sheet losses and the guard
GUARD_ARMS = ('quad', 'uvdoc', 'docres')
READERS = {'apple-vision': ('enh-dewarp-pages.csv', None), 'gemini3.7-flash-gw': ('enh-dewarp-gateway.csv', None),
           'qwen3.6-27b': ('enh-dewarp-cluster.csv', 'qwen3.6-27b')}


def word_table(raw_lines):
    """Every word Vision read on the raw image: (line index, centre, its single token or None)."""
    import ocr_panel_score as S
    import numpy as np
    out = []
    for li, line in enumerate(raw_lines):
        for w in line['words']:
            t = S.tokens(w['text'])
            out.append((li, np.float64(w['quad']).mean(0), t[0] if len(t) == 1 else None))
    return out


def aligned(words, truth_tokens):
    """Indices of the words that align to the truth's word sequence (enh_dewarp.truth_words' rule, as indices)."""
    import difflib
    single = [i for i, w in enumerate(words) if w[2] is not None]
    sm = difflib.SequenceMatcher(None, [words[i][2] for i in single], truth_tokens, autojunk=False)
    return [single[b.a + k] for b in sm.get_matching_blocks() for k in range(b.size)]


def split_lost(words, shown, quad):
    """Each word the arm's image does not show, as own sheet or neighbour (place_geom.lost_words' rule): own when its
    centre lies inside Apple's quad or another word of its Vision line is shown (a line cut through)."""
    import numpy as np
    from enh_dewarp import inside
    lines_shown = {words[i][0] for i in range(len(words)) if shown[i]}
    poly = np.float64(quad)
    own = [i for i in range(len(words)) if not shown[i]
           and (inside(poly, words[i][1][None])[0] or words[i][0] in lines_shown)]
    neigh = [i for i in range(len(words)) if not shown[i] and i not in set(own)]
    return own, neigh


def nes_by_reader():
    """{reader: {(arm, page): nes}} from the committed enh-dewarp per-page files (no reading is redone)."""
    import csv
    out = {}
    for reader, (f, keep) in READERS.items():
        d = {}
        for r in csv.DictReader((RESULTS / f).open()):
            if keep and r.get('reader') != keep:
                continue
            if r.get('ok', 'True') != 'True' or r.get('nes') in (None, ''):
                continue
            d[(r['arm'], r['page'])] = float(r['nes'])
        out[reader] = d
    return out


def mean_ci(xs, draws=DRAWS, seed=SEED):
    if not xs:
        return None
    rng = random.Random(seed)
    ms = sorted(statistics.mean(rng.choice(xs) for _ in xs) for _ in range(draws))
    return [round(100 * statistics.mean(xs), 1), round(100 * ms[int(0.025 * draws)], 1),
            round(100 * ms[int(0.975 * draws) - 1], 1)]


def cmd_guard96(a):
    import numpy as np
    import ocr_panel as P
    import ocr_panel_score as S
    import enh_dewarp as E
    pages = []
    for r in P.rows():
        p = r['page']
        if p in P.AGREEMENT:
            continue
        raw, _ = E.load_lines('raw', p)
        words = word_table(raw['lines'])
        truth = (P.TRUTH / 'truth' / (p + '.txt')).read_text()
        tw = set(aligned(words, S.tokens(S.normal(truth))))
        quad = json.loads((E.CACHE / 'quad' / (p + '.json')).read_text())['corners']
        centres = np.array([w[1] for w in words]).reshape(-1, 2)
        row = {'page': p, 'source': 'original' if r['source'] == 'original' else 'pdf image', 'kind': r['kind'],
               'words': len(words), 'truth_words': len(tw),
               'in_quad': int(E.inside(np.float64(quad), centres).sum()) if len(words) else 0, 'arms': {}}
        for arm in GUARD_ARMS:
            g = np.load(E.CACHE / 'grids' / arm / (p + '.npz'))['grid']
            shown = E.covered(g, centres) if len(words) else np.zeros(0, bool)
            own, neigh = split_lost(words, shown, quad)
            row['arms'][arm] = {
                'lost': int((~shown).sum()), 'lost_own': len(own), 'lost_neighbour': len(neigh),
                'truth_lost': sum(1 for i in tw if not shown[i]),
                'truth_lost_own': sum(1 for i in own if i in tw), 'truth_lost_neighbour': sum(1 for i in neigh if i in tw),
                'guard_all': bool(shown.all()), 'guard_own': not own}
        pages.append(row)
    nes = nes_by_reader()
    summary = {}
    for scope, keep in (('originals', lambda r: r['source'] == 'original'), ('all96', lambda r: True)):
        rs = [r for r in pages if keep(r)]
        s = {'pages': len(rs)}
        for arm in GUARD_ARMS:
            A = [r['arms'][arm] for r in rs]
            t = {k: sum(x[k] for x in A) for k in ('lost', 'lost_own', 'lost_neighbour', 'truth_lost', 'truth_lost_own',
                                                     'truth_lost_neighbour')}
            t |= {f'pages_{k}': sum(1 for x in A if x[k]) for k in ('lost_own', 'lost_neighbour', 'truth_lost_own',
                                                                   'truth_lost_neighbour')}
            t |= {'guard_all_pass': sum(x['guard_all'] for x in A), 'guard_own_pass': sum(x['guard_own'] for x in A)}
            # NES gain over raw: every page, and only the pages the own-sheet guard lets through (the rest stay raw)
            for reader, d in nes.items():
                both = [r for r in rs if (arm, r['page']) in d and ('raw', r['page']) in d]
                gain = {r['page']: d[(arm, r['page'])] - d[('raw', r['page'])] for r in both}
                t[f'gain.{reader}'] = {'n': len(gain), 'every_page': mean_ci(list(gain.values())),
                                       'guarded': mean_ci([gain[r['page']] if r['arms'][arm]['guard_own'] else 0.0
                                                           for r in both]),
                                       'passing_only': mean_ci([gain[r['page']] for r in both
                                                                if r['arms'][arm]['guard_own']]),
                                       'passing_n': sum(1 for r in both if r['arms'][arm]['guard_own'])}
            s[arm] = t
        summary[scope] = s
    out = {'item': 'W46.dewarp-guard', 'step': 'ENH-4 split and the guard on the 96', 'summary': summary,
           'pages': pages}
    (RESULTS / 'dewarp-guard-96.json').write_text(json.dumps(out, indent=1) + '\n')
    print(json.dumps(summary, indent=1))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    for c in ('classify', 'class-report', 'guard96'):
        sub.add_parser(c)
    a = p.parse_args()
    {'classify': cmd_classify, 'class-report': cmd_class_report, 'guard96': cmd_guard96}[a.cmd](a)


if __name__ == '__main__':
    main()
