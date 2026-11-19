#!/usr/bin/env python3
"""W46.post-read-quality-flag: a "this photo read poorly" flag after processing, fitted for few false alarms.

  uv run --with rapidfuzz --with regex --with 'sacrebleu==2.5.1' python post_read_flag.py report
  python3 post_read_flag.py self-test

THE QUESTION. After a page is read, can the app tell the owner "this page probably read poorly" while rarely saying
it of a page that read well? Owner, 2026-11-17: a non-live warning is worth having, but false alarms must be rare;
use the reader's confidence and two-reader disagreement, not sharpness.

THE LABELS. A reading is poor when its NES against the 96's adjudicated truth is under 70 (the measurement audit's
line). A false alarm is a flag on a reading at 70 or above; the false-alarm rate is over those good readings. The
ceiling is CEILING (5% of good readings). Beside it, the share of flags on readings under 90.

THE SIGNALS, each a risk (higher = more likely poor). A reading that failed (a cap, an error or an empty reply) is
always flagged: the app already knows it failed, and it is poor by construction. Over answered readings:
  * conf: the reader's own mean token log-probability, negated (W46.ocr-logprob's per-page CSV: the two Mac mlx
    routes on the 96, the two Sherlock vLLM routes on the 440, 455 and 96). Apple Vision's own confidence is the
    character-weighted mean of its line confidences (it takes the values 1, 0.5 and 0.3), negated.
  * vs <partner>: 100 minus the reading's NES scored against the partner's reading of the same image (the bench
    scorer, the partner's text standing as truth). Pairs: the two Mac routes with each other (as in ocr-logprob),
    each reader with Apple Vision (the partner the app can run on any Mac for nothing), and Gemini 3.7 Flash with
    Qwen3.5-9B on the Mac.
  * vs Vision, typed: the same, with Vision's handwritten pages left unflagged (the app knows a page's kind, and
    Vision cannot read handwriting, so its disagreement there says nothing about the other reader).

THE SETS. The 96 (each reader on the plain photograph); the capture ladder's 48 Gemini pages (W46.capture-ladder:
the plain photograph and its ten defect images, read by Gemini 3.7 Flash through the gateway and by Apple Vision on
this Mac, 528 images), where the flag's job is to catch a damaged capture; the public 440 and 455 for the Sherlock
routes' log-probabilities (CSV only). No reading is made here: every text is cached, no money.

THE CUT. On a set, the lowest cut whose false alarms stay within the ceiling (flag when risk >= cut). In-sample it
is optimistic, so each set is also scored by repeated 5-fold cross-validation (the cut fitted on four fifths, applied
to the fifth, counts pooled over 20 seeded splits); and a cut fitted on one set is applied once to another where the
same reader pair exists on both (the 96 to the ladder and back, the 455 to the 96). Intervals: Wilson 95%.
"""
from __future__ import annotations
import argparse
import csv
import json
import math
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
RESULTS = HERE.parents[1] / 'segbench-results'
CACHE = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
OUT_MD = RESULTS / 'post-read-flag.md'
OUT_JSON = RESULTS / 'post-read-flag.json'
OUT_CSV = RESULTS / 'post-read-flag-pages.csv'
POOR = 0.70
GOOD_HI = 0.90
CEILING = 0.05
FOLDS, SEEDS = 5, 20
FAILED = float('inf')


# --- statistics (pure; self-tested) ---------------------------------------------------------------------------

def wilson(k, n, z=1.96):
    if not n:
        return (None, None)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0., c - h), min(1., c + h))


def auc(risk, poor):
    pos = [r for r, y in zip(risk, poor) if y]
    neg = [r for r, y in zip(risk, poor) if not y]
    if not pos or not neg:
        return None
    s = sum(1. if p > n else .5 if p == n else 0. for p in pos for n in neg)
    return s / (len(pos) * len(neg))


def fit_cut(risk, poor, ceiling=CEILING):
    """The lowest cut c (flag when risk >= c) whose false alarms among good readings stay within the ceiling.
    Failed readings (risk inf) are always flagged and never count against it. inf if no finite cut fits."""
    good = sorted((r for r, y in zip(risk, poor) if not y), reverse=True)
    allowed = math.floor(ceiling * len(good) + 1e-9)
    cands = sorted({r for r in risk if r != FAILED}, reverse=True)
    best = FAILED
    for c in cands:
        if sum(1 for g in good if g >= c) <= allowed:
            best = c
        else:
            break
    return best


def counts(risk, poor, nes, cut):
    flag = [r >= cut for r in risk]
    return {'n': len(risk), 'poor': sum(poor), 'good': len(risk) - sum(poor), 'flagged': sum(flag),
            'hits': sum(1 for f, y in zip(flag, poor) if f and y),
            'false_alarms': sum(1 for f, y in zip(flag, poor) if f and not y),
            'flags_under_90': sum(1 for f, e in zip(flag, nes) if f and e < GOOD_HI)}


def rates(c):
    out = dict(c)
    out['hit_rate'] = c['hits'] / c['poor'] if c['poor'] else None
    out['hit_ci'] = wilson(c['hits'], c['poor'])
    out['fa_rate'] = c['false_alarms'] / c['good'] if c['good'] else None
    out['fa_ci'] = wilson(c['false_alarms'], c['good'])
    out['precision'] = c['hits'] / c['flagged'] if c['flagged'] else None
    out['under_90_of_flags'] = c['flags_under_90'] / c['flagged'] if c['flagged'] else None
    return out


def add(a, b):
    return {k: a.get(k, 0) + b[k] for k in b}


def crossval(risk, poor, nes, groups=None, folds=FOLDS, seeds=SEEDS):
    """Repeated k-fold: the cut fitted on the other folds, applied to the held-out one; counts pooled over seeds.
    groups: one key per row; rows sharing a key (a page's images) stay in one fold."""
    keys = sorted(set(groups)) if groups else list(range(len(risk)))
    gidx = groups or list(range(len(risk)))
    tot = {}
    for s in range(seeds):
        order = keys[:]
        random.Random(1000 + s).shuffle(order)
        fold_of = {k: i % folds for i, k in enumerate(order)}
        for f in range(folds):
            tr = [i for i in range(len(risk)) if fold_of[gidx[i]] != f]
            te = [i for i in range(len(risk)) if fold_of[gidx[i]] == f]
            cut = fit_cut([risk[i] for i in tr], [poor[i] for i in tr])
            tot = add(tot, counts([risk[i] for i in te], [poor[i] for i in te], [nes[i] for i in te], cut))
    return tot


# --- the readings ------------------------------------------------------------------------------------------------

def _score(truth, text):
    sys.path.insert(0, str(HERE))
    import ocr_panel_score as S
    return S.score(truth, text)['nes']


def vision_text(path):
    d = json.loads(Path(path).read_text())
    lines = d['lines']
    text = '\n'.join(l['text'] for l in lines)
    chars = sum(len(l['text']) for l in lines)
    conf = sum(l['confidence'] * len(l['text']) for l in lines) / chars if chars else None
    return text, conf


def readings_96():
    """{reader: {page: (text, ok, conf)}} for the 96: the two Mac mlx routes, Gemini 3.7 Flash (the cloud panel's
    reading), Apple Vision (the dewarp run's plain-image reading, the ladder's Vision baseline)."""
    sys.path.insert(0, str(HERE))
    import ocr_logprob as L
    import ocr_mac_local as M
    import capture_ladder_gateway as GW
    import gateway_gemini as G
    pages = {r['page']: r for r in __import__('capture_ladder').scored_pages()}
    out = {}
    for key in L.MAC_KEYS:
        d = L.mac_out(key); out[key] = {}
        for job in M.jobs():
            if job['page'] not in pages:
                continue
            meta, parsed = M.load_reading(d / (job['id'] + '.json'))
            raw = json.loads((d / (job['id'] + '.raw.json')).read_text())
            text = parsed['text'] if parsed else ''
            out[key][job['page']] = (text, bool(parsed) and bool(text), L.token_features(raw['logprobs'])['mean'])
    out['gemini3.7-flash'] = {}
    for p in pages:
        parsed = G.parsed(GW.raw_reply(p))
        text = parsed['text'] if parsed else ''
        out['gemini3.7-flash'][p] = (text, bool(text), None)
    out['vision'] = {}
    for p in pages:
        text, conf = vision_text(CACHE / 'enh-dewarp/lines/raw' / f'{p}.json')
        out['vision'][p] = (text, bool(text), conf)
    return pages, out


def readings_ladder():
    """{reader: {(variant, page): (text, ok, conf)}} for the ladder's 48 Gemini pages, raw and its ten defects."""
    sys.path.insert(0, str(HERE))
    import capture_ladder as C
    import capture_ladder_gateway as GW
    gem = GW.readings()
    if gem is None:
        raise SystemExit('the ladder\'s Gemini readings are incomplete')
    out = {'gemini3.7-flash': {}, 'vision': {}}
    for (v, p), (text, status) in gem.items():
        out['gemini3.7-flash'][v, p] = (text, status == 'ok' and bool(text), None)
        text, conf = vision_text(C.lines_path(v, p))
        out['vision'][v, p] = (text, bool(text), conf)
    return out


LABEL = {'lightonocr-3-4b-mlx8': 'LightOnOCR-3 4B (Mac mlx 8-bit)', 'qwen3.5-9b-mlx4': 'Qwen3.5-9B (Mac mlx 4-bit)',
         'gemini3.7-flash': 'Gemini 3.7 Flash (gateway)', 'vision': 'Apple Vision',
         'lightonocr3-4b': 'LightOnOCR-3 4B (Sherlock vLLM)', 'qwen3.5-9b': 'Qwen3.5-9B (Sherlock vLLM)'}
PAIRS_96 = {'lightonocr-3-4b-mlx8': ['qwen3.5-9b-mlx4', 'vision'], 'qwen3.5-9b-mlx4': ['lightonocr-3-4b-mlx8', 'vision'],
            'gemini3.7-flash': ['vision', 'qwen3.5-9b-mlx4'], 'vision': ['gemini3.7-flash', 'qwen3.5-9b-mlx4']}
PAIRS_LADDER = {'gemini3.7-flash': ['vision'], 'vision': ['gemini3.7-flash']}


def rows_for(read, truth_of, kind_of, pairs):
    """One row per reader and image: nes, poor, and every signal's risk."""
    rows = []
    for reader, partners in pairs.items():
        for key, (text, ok, conf) in read[reader].items():
            nes = _score(truth_of(key), text) if ok else 0.
            sig = {}
            if conf is not None or reader in ('lightonocr-3-4b-mlx8', 'qwen3.5-9b-mlx4', 'vision'):
                sig['conf'] = (-conf if conf is not None else 0.) if ok else FAILED
            for q in partners:
                otext, ook, _ = read[q][key]
                d = 1 - _score(otext, text) if (ok and ook) else (1. if ok else FAILED)
                sig[f'vs {q}'] = d if ok else FAILED
                if q == 'vision':
                    typed = kind_of(key) != 'handwritten'
                    sig['vs vision, typed'] = (d if typed else 0.) if ok else FAILED
                    # weighted by Vision's own confidence: a disagreement Vision is unsure of is Vision's trouble
                    sig['vs vision x its conf, typed'] = ((d * (read[q][key][2] or 0.)) if typed else 0.) if ok \
                        else FAILED
            rows.append({'reader': reader, 'key': key, 'page': key if isinstance(key, str) else key[1],
                         'variant': 'raw' if isinstance(key, str) else key[0], 'kind': kind_of(key),
                         'nes': nes, 'poor': nes < POOR, 'risk': sig})
    return rows


def csv_rows():
    """The Sherlock routes' 440, 455 and 96 rows from W46.ocr-logprob's per-page CSV."""
    out = []
    with open(RESULTS / 'ocr-logprob-pages.csv') as f:
        for r in csv.DictReader(f):
            if r['route'] not in ('lightonocr3-4b', 'qwen3.5-9b'):
                continue
            ok = r['ok'] == 'True'
            nes = float(r['nes']) if ok else 0.
            risk = {'conf': -float(r['mean']) if ok and r['mean'] else FAILED,
                    'vs pair': (1 - float(r['agreement'])) if ok and r['agreement'] != '' else FAILED}
            out.append({'reader': r['route'], 'set': r['set'], 'page': r['page'], 'kind': r['kind'], 'nes': nes,
                        'poor': nes < POOR, 'risk': risk})
    return out


# --- the analysis ------------------------------------------------------------------------------------------------

def evaluate(rows, sig, groups=False):
    risk = [r['risk'][sig] for r in rows]
    poor = [r['poor'] for r in rows]
    nes = [r['nes'] for r in rows]
    cut = fit_cut(risk, poor)
    return {'auc': auc([min(x, 1e9) for x in risk], poor), 'cut': None if cut == FAILED else cut,
            'in_sample': rates(counts(risk, poor, nes, cut)),
            'crossval': rates(crossval(risk, poor, nes, [r['page'] for r in rows] if groups else None))}


def transfer(fit_rows, test_rows, sig):
    cut = fit_cut([r['risk'][sig] for r in fit_rows], [r['poor'] for r in fit_rows])
    return {'cut': None if cut == FAILED else cut,
            **rates(counts([r['risk'][sig] for r in test_rows], [r['poor'] for r in test_rows],
                           [r['nes'] for r in test_rows], cut))}


def analyse():
    pages, r96 = readings_96()
    kind = {p: r['kind'] for p, r in pages.items()}
    sys.path.insert(0, str(HERE))
    import ocr_panel as P
    truth = {p: (P.TRUTH / 'truth' / f'{p}.txt').read_text() for p in pages}
    rows96 = rows_for(r96, lambda k: truth[k], lambda k: kind[k], PAIRS_96)
    lad = readings_ladder()
    rowsl = rows_for(lad, lambda k: truth[k[1]], lambda k: kind[k[1]], PAIRS_LADDER)
    out = {'item': 'W46.post-read-quality-flag', 'poor_below': POOR, 'ceiling': CEILING, 'folds': FOLDS,
           'seeds': SEEDS, 'sets': {}}
    for name, rows, groups in (('96', rows96, False), ('ladder', rowsl, True)):
        res = {}
        for reader in sorted({r['reader'] for r in rows}):
            rr = [r for r in rows if r['reader'] == reader]
            res[reader] = {s: evaluate(rr, s, groups) for s in rr[0]['risk']}
        out['sets'][name] = res
    # the 96 and the ladder's plain images are the same photographs: the ladder's defect images are the test
    tr = {}
    for reader in PAIRS_LADDER:
        a = [r for r in rows96 if r['reader'] == reader and r['page'] in {x['page'] for x in rowsl}]
        b = [r for r in rowsl if r['reader'] == reader and r['variant'] != 'raw']
        a_all = [r for r in rows96 if r['reader'] == reader]
        for s in b[0]['risk']:
            tr[f'{reader}|{s}|96->ladder defects'] = transfer(a_all, b, s)
            tr[f'{reader}|{s}|ladder defects->96'] = transfer(b, a_all, s)
    cs = csv_rows()
    res = {}
    for reader in ('lightonocr3-4b', 'qwen3.5-9b'):
        for st in ('455', '96', '440'):
            rr = [r for r in cs if r['reader'] == reader and r['set'] == st]
            res[f'{reader}|{st}'] = {s: evaluate(rr, s) for s in ('conf', 'vs pair')}
        a = [r for r in cs if r['reader'] == reader and r['set'] == '455']
        b = [r for r in cs if r['reader'] == reader and r['set'] == '96']
        for s in ('conf', 'vs pair'):
            tr[f'{reader}|{s}|455->96'] = transfer(a, b, s)
    out['sets']['sherlock'] = res
    out['transfer'] = tr
    # the app's rule: Apple Vision's own confidence, the cut fitted on the 96, applied once to the ladder's defects
    v96 = [r for r in rows96 if r['reader'] == 'vision']
    cut = fit_cut([r['risk']['conf'] for r in v96], [r['poor'] for r in v96])
    above = min((-r['risk']['conf'] for r in v96 if r['risk']['conf'] != FAILED and -r['risk']['conf'] > -cut),
                default=1.)
    out['app_rule'] = {'reader': 'vision', 'signal': 'conf', 'flag_below': round((above - cut) / 2, 4),
                       'fitted_cut': cut, 'next_confidence_above': above,
                       '96': out['sets']['96']['vision']['conf']['in_sample'],
                       '96_crossval': out['sets']['96']['vision']['conf']['crossval'],
                       'ladder_defects': tr['vision|conf|96->ladder defects']}
    out['pages'] = [{'set': n, 'reader': r['reader'], 'page': r['page'], 'variant': r['variant'], 'kind': r['kind'],
                     'nes': round(r['nes'], 4), **{k: (None if v == FAILED else round(v, 5)) for k, v in r['risk'].items()}}
                    for n, rows in (('96', rows96), ('ladder', rowsl)) for r in rows]
    return out


# --- the report --------------------------------------------------------------------------------------------------

def _pct(x):
    return '–' if x is None else f'{100 * x:.0f}%'


def _ci(ci):
    return '' if ci[0] is None else f' ({100 * ci[0]:.0f}-{100 * ci[1]:.0f})'


def _cell(r):
    return (f"{r['hits']}/{r['poor']} {_pct(r['hit_rate'])}{_ci(r['hit_ci'])} | "
            f"{r['false_alarms']}/{r['good']} {_pct(r['fa_rate'])}{_ci(r['fa_ci'])} | {_pct(r['under_90_of_flags'])}")


def _cv(r):
    return f"{_pct(r['hit_rate'])}{_ci(r['hit_ci'])} | {_pct(r['fa_rate'])}{_ci(r['fa_ci'])}"


def _cutf(c):
    return '–' if c is None else f'{c:.3f}'


def render(out):
    L = [HEAD.strip(), '']
    hdr = ('| reader | signal | AUC | cut | in-sample hits | false alarms | flags under 90 | cross-validated hits | '
           'cross-validated false alarms |')
    sep = '|---|---|---:|---:|---|---|---:|---|---|'
    for name, title in (('96', 'The 96, each reader on the plain photograph'),
                        ('ladder', "The capture ladder's 48 Gemini pages: the plain photograph and ten defect images "
                                   "(528 images; cross-validation keeps a page's images in one fold)")):
        L += [f'## {title}', '', hdr, sep]
        for reader, sigs in out['sets'][name].items():
            for s, e in sigs.items():
                L.append(f"| {LABEL[reader]} | {s} | {e['auc']:.3f} | {_cutf(e['cut'])} | {_cell(e['in_sample'])} | "
                         f"{_cv(e['crossval'])} |")
        L.append('')
    L += ['## The Sherlock routes on the public sets and the 96 (W46.ocr-logprob\'s CSV; "vs pair" is the other '
          'Sherlock route)', '', hdr.replace('| reader |', '| reader, set |'), sep]
    for key, sigs in out['sets']['sherlock'].items():
        reader, st = key.split('|')
        for s, e in sigs.items():
            L.append(f"| {LABEL[reader]}, {st} | {s} | {e['auc']:.3f} | {_cutf(e['cut'])} | {_cell(e['in_sample'])} | "
                     f"{_cv(e['crossval'])} |")
    L += ['', '## A cut fitted on one set, applied once to another', '',
          '| reader | signal | fitted on, applied to | cut | hits | false alarms | flags under 90 |',
          '|---|---|---|---:|---|---|---:|']
    for key, r in out['transfer'].items():
        reader, s, how = key.split('|')
        L.append(f"| {LABEL[reader]} | {s} | {how} | {_cutf(r['cut'])} | {_cell(r)} |")
    a = out['app_rule']
    L += ['', '## The rule the app ships', '',
          f"Apple Vision's reading is flagged when its character-weighted mean line confidence is under "
          f"{a['flag_below']} (the cut fitted on the 96, between the confidences on either side of it), or when it "
          "returned no text. On the 96, and applied once to the ladder's 480 defect images:", '',
          '| set | hits | false alarms | flags under 90 |', '|---|---|---|---:|',
          f"| the 96, in-sample | {_cell(a['96'])} |",
          f"| the 96, cross-validated | {_cv(a['96_crossval'])} | – |",
          f"| ladder defect images, applied once | {_cell(a['ladder_defects'])} |"]
    L += ['', FINDINGS.strip(), '', CARD.strip(), '']
    return '\n'.join(L)


HEAD = """
# W46.post-read-quality-flag: a "this photo read poorly" flag, fitted for few false alarms

Generated by `scripts/segbench/post_read_flag.py report` (the method is its docstring). Per-image risks, no text:
`post-read-flag-pages.csv`; every figure: `post-read-flag.json`. No money: every reading is cached.

A reading is poor under 70 NES; a false alarm is a flag on a reading at 70 or above, counted over those good
readings; the ceiling is 5% of them. A failed reading (cap, error, empty) is always flagged. The cut is the lowest
whose in-sample false alarms stay within the ceiling (flag at risk >= cut; for "vs" signals the risk is 1 minus the
NES against the partner's text, for "conf" the negated mean log-probability, or for Apple Vision its negated
character-weighted line confidence). Cells: hits / poor readings, false alarms / good readings, with Wilson 95%
intervals; "flags under 90" is the share of flags on readings under 90 NES. Cross-validated: repeated 5-fold, 20 seeds,
counts pooled (so its intervals are narrower than the sample warrants; read them as a guide).
"""

FINDINGS = """
## Findings (2026-11-18)

- **Apple Vision's own confidence is the one flag near a 5% false-alarm rate on plain and damaged photographs
  alike.** Fitted on the 96 (flag under 0.9815), it catches 10 of Vision's 21 poor readings with 3 false alarms in 75
  in-sample (4%, the fit itself); cross-validated, the honest estimate for new pages (repeated 5-fold, pooled over the
  repeats), it catches 193 of 420 (46%) with 87 false alarms in 1,500 (5.8%, 4.7-7.1), a little over the ceiling it
  was fitted to. Applied once to the ladder's defect images it catches 179 of 231 with 7 false alarms in 249 (3%).
  The cut fitted on the ladder lands within 0.006 of it. Its misses on the 96 are confident failures (several poor pages at confidence 1.0, mostly printed pages Vision misreads), so it says "check this" on about half
  of Vision's poor plain-photo readings and on most damaged ones. This is the rule the app ships, for pages Vision
  reads (the no-key route).
- **Two-reader disagreement with Apple Vision ranks a reader's errors well on plain photographs** (AUC 0.89-0.98), and
  leaving handwritten pages out helps every reader but Qwen3.5-9B. For LightOnOCR-3 4B on the Mac it catches 82% of
  poor typed-page readings at 5% false alarms, cross-validated; for Qwen3.5-9B on the Mac 33-36%; Gemini 3.7 Flash
  reads only 3 of the 96 poorly, so it has little to catch there.
- **But that cut does not survive a damaged photograph.** Vision loses far more to blur than the other readers
  (capture-ladder.md), so on the ladder it disagrees with Gemini's good readings: the cut fitted on the 96 flags 21%
  of Gemini's good defect-image readings (16% with handwriting left out), four times the ceiling. The cut that holds
  the ceiling on the ladder (disagreement 0.95-0.97, near-total) catches 37-41% of Gemini's poor defect readings and
  none of its 3 poor plain readings, and one cut strict enough for every measured reader and set (0.968) catches
  0 or 1 poor reading per reader on the 96. Weighting the disagreement by Vision's confidence (AUC 0.52 on the
  ladder) or gating it on Vision having read half the words (0.42-0.47) does not rescue it.
- **Log-probabilities rank, but the app has none.** Qwen3.5-9B's mean log-probability catches 34% at 5% on the 96
  (cross-validated) and 67% on the public 455; LightOnOCR's catches 1% on the 96 at that ceiling. No Swift
  route requests log-probabilities today. Disagreement between the two Sherlock routes catches 75-96% of Qwen3.5-9B's
  poor public readings at 5%, but a cut fitted on the 455 flags 5 of 90 good readings on the 96 (6%): it travels
  roughly, not exactly.
- **For the app:** ship Vision's confidence flag, UI only (the run summary and the history), and no flag for the other
  readers yet: no rule measured here holds the ceiling for them across capture conditions. A reader-specific Vision
  disagreement cut for the Mac's open readers needs their ladder readings (not on this Mac), and real captures
  (W46.capture-warning) before it can be trusted; filed as W46.post-read-flag-readers.
"""

CARD = """
## Measurement card

- **Truth:** the 96's adjudicated truth (`ocr_truth`), the same for every image of a page. Gemini 3.8 Flash, a
  relative of the scored Gemini 3.7 Flash, drafted it with Claude Opus 5.5, so Gemini's own readings look closer to
  truth than they are; that can only make its poor readings rarer here, not change which signal ranks them. The
  owner's blind check found the typed-page truth fit for ranking (measurement audit, 2026-10-30). The public 440 and
  455 use their datasets' own truth.
- **Selection:** all 96 scored pages; the ladder's 48 are every other page of the 96 in a seeded order, chosen
  before any reading (W46.capture-ladder-paid). Every page where Apple Vision (26.6) read fewer than 20 words was
  replaced at the 96's draw, so the 96 hold no page Vision reads as empty: Vision's disagreement is measured on pages
  it could read, which flatters it as a partner on the owner's harder material. No ABBYY text is used.
- **Comparison:** every signal is scored on the same readings and labels; each reader's text is the one its own
  report scored (W46.ocr-logprob for the Mac routes, the cloud panel for Gemini's plain image, W46.enh-dewarp's
  macOS 27.2 Vision for Vision's). On the ladder both readers read the same defect image.
- **Noise:** 96 pages hold 4 to 27 poor readings per reader, so a hit rate moves by several points with one page
  and a 5% ceiling is 4 of about 85 good readings: a cut is fitted on a handful of pages. The cross-validated rows are
  the honest estimate; the in-sample rows are the fit. A rerun of a reader moves its NES by up to 0.24 points
  (W46.ocr-rerun-noise, Gemini), far below the 70 line.
- **Scope:** synthetic defects on the ladder, one at a time; no real phone captures (W46.capture-warning), the
  public sets only through the Sherlock routes' CSV, and the app's own routes only as far as the bench readers stand
  for them. The cuts are for a stated ceiling on these pages, not for any collection's mix of kinds.
"""


def report():
    out = analyse()
    pages = out.pop('pages')
    cols = ['set', 'reader', 'page', 'variant', 'kind', 'nes', *sorted({k for r in pages for k in r} - {
        'set', 'reader', 'page', 'variant', 'kind', 'nes'})]
    with open(OUT_CSV, 'w', newline='') as f:
        w = csv.DictWriter(f, cols); w.writeheader(); w.writerows(pages)
    OUT_JSON.write_text(json.dumps(out, indent=1, default=lambda x: None) + '\n')
    OUT_MD.write_text(render(out))
    print(OUT_MD.read_text())


def self_test():
    assert wilson(0, 0) == (None, None)
    lo, hi = wilson(5, 10); assert 0.23 < lo < 0.24 and 0.76 < hi < 0.77
    assert auc([3, 2, 1], [True, False, False]) == 1.0
    assert auc([1, 1], [True, False]) == 0.5
    # 20 good readings at risk 0..19, three poor at 30, 31 and 5, one failed: ceiling 5% of 20 = 1 false alarm
    risk = [float(i) for i in range(20)] + [30., 31., 5., FAILED]
    poor = [False] * 20 + [True, True, True, True]
    cut = fit_cut(risk, poor)
    assert cut == 19., cut
    c = counts(risk, poor, [0.95] * 20 + [0.5] * 4, cut)
    assert c == {'n': 24, 'poor': 4, 'good': 20, 'flagged': 4, 'hits': 3, 'false_alarms': 1, 'flags_under_90': 3}, c
    assert fit_cut([FAILED, 1.], [True, False]) == FAILED       # no finite cut fits: only failures flagged
    cv = crossval(risk, poor, [0.9] * 24)
    assert cv['n'] == 24 * SEEDS and cv['poor'] == 4 * SEEDS
    print('self-test ok')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('cmd', choices=['report', 'self-test'])
    a = ap.parse_args()
    report() if a.cmd == 'report' else self_test()


if __name__ == '__main__':
    main()
