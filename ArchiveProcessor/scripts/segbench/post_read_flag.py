#!/usr/bin/env python3
"""W46.post-read-quality-flag: a "this photo read poorly" flag after processing, fitted for few false alarms.

  uv run --with rapidfuzz --with regex --with 'sacrebleu==2.5.1' python post_read_flag.py report
  python3 post_read_flag.py report --from-scores
  python3 post_read_flag.py self-test

THE QUESTION. After a page is read, can the app tell the owner "this page probably read poorly" while rarely saying
it of a page that read well? Owner, 2026-11-17: a non-live warning is worth having, but false alarms must be rare;
use the reader's confidence and two-reader disagreement, not sharpness.

THE LABELS. A reading is poor when its NES against the 96's adjudicated truth is under 70 (the measurement audit's
line). A false alarm is a flag on a reading at 70 or above; the false-alarm rate is over those good readings. The
ceiling is CEILING (5% of good readings). Beside it, the share of flags on readings under 90.

THE SIGNALS, each a risk (higher = more likely poor). Count caps, errors and empty replies as failed readings.
Fit and score the flag on answered readings. The app handles failures through its refusal and retry paths.
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
    Return inf if no finite cut fits."""
    good = [r for r, y in zip(risk, poor) if not y]
    allowed = math.floor(ceiling * len(good) + 1e-9)
    cands = sorted({r for r in risk if r != FAILED}, reverse=True)
    best = FAILED
    for c in cands:
        if sum(1 for g in good if g != FAILED and g >= c) <= allowed:
            best = c
        else:
            break
    return best


def counts(risk, poor, nes, cut, *, answered=None):
    # Newspaper analyses call this with their own row selection and failure policy.
    extra = {}
    if answered is not None:
        extra['failed'] = len(answered) - sum(answered)
        risk, poor, nes = ([value for value, ok in zip(values, answered) if ok] for values in (risk, poor, nes))
        flag = [r != FAILED and r >= cut for r in risk]
    else:
        flag = [r >= cut for r in risk]
    return {'n': len(risk), **extra, 'poor': sum(poor), 'good': len(risk) - sum(poor), 'flagged': sum(flag),
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


def fit_cut_each(risk, poor, sets, ceiling=CEILING):
    """The lowest cut whose false alarms stay within the ceiling on every set at once (sets: one label per row).
    False alarms only fall as the cut rises, so it is the highest of the sets' own cuts."""
    return max(fit_cut([r for r, s in zip(risk, sets) if s == x], [y for y, s in zip(poor, sets) if s == x], ceiling)
               for x in set(sets)) if sets else FAILED


def crossval(risk, poor, nes, groups=None, folds=FOLDS, seeds=SEEDS, sets=None, *, answered=None):
    """Repeated k-fold: the cut fitted on the other folds, applied to the held-out one; counts pooled over seeds.
    groups: one key per row; rows sharing a key (a page's images) stay in one fold. sets: fit with fit_cut_each.
    With an answered mask, keep the original fold assignments and tally failed readings separately."""
    keys = sorted(set(groups)) if groups else list(range(len(risk)))
    gidx = groups or list(range(len(risk)))
    tot = {}
    for s in range(seeds):
        order = keys[:]
        random.Random(1000 + s).shuffle(order)
        fold_of = {k: i % folds for i, k in enumerate(order)}
        for f in range(folds):
            tr = [i for i in range(len(risk)) if fold_of[gidx[i]] != f and (answered is None or answered[i])]
            te = [i for i in range(len(risk)) if fold_of[gidx[i]] == f]
            cut = fit_cut_each([risk[i] for i in tr], [poor[i] for i in tr], [sets[i] for i in tr]) if sets \
                else fit_cut([risk[i] for i in tr], [poor[i] for i in tr])
            te_answered = [answered[i] for i in te] if answered is not None else None
            tot = add(tot, counts([risk[i] for i in te], [poor[i] for i in te], [nes[i] for i in te], cut,
                                  answered=te_answered))
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


# W47.wh-read-flag-readers: every other reader the app offers whose 96 readings are cached, with the app route it
# stands for (provider, the app's model id) and where its reading of a page is. 'A' the cloud panel's responses,
# 'B' the local panel's (OpenRouter), 'claude' the plan route's, 'mistral' Mistral OCR's own, 'mlx' the Mac mlx
# panel's plain (not log-probability) readings.
APP_ROUTES = {
    'gemini3.8-flash': ('Gemini 3.8 Flash', 'gemini', 'gemini-3.8-flash', 'A'),
    'gemini3.5-flash': ('Gemini 3.5 Flash', 'gemini', 'gemini-3.5-flash', 'A'),
    'gemini3.1-pro': ('Gemini 3.1 Pro', 'gemini', 'gemini-3.1-pro', 'A'),
    'gemini3.5-flash-lite': ('Gemini 3.5 Flash Lite', 'gemini', 'gemini-3.5-flash-lite', 'A'),
    'gemini3.1-flash-lite': ('Gemini 3.1 Flash Lite', 'gemini', 'gemini-3.1-flash-lite', 'B'),
    'gpt5.4-mini': ('GPT-5.4 mini', 'openai', 'gpt-5.4-mini', 'A'),
    'claude-sonnet5.5': ('Claude Sonnet 5.5', 'anthropic', 'claude-sonnet-5-5', 'claude'),
    'mistral-ocr-4-1': ('Mistral OCR', 'mistral', 'mistral-ocr-latest', 'mistral'),
    'qwen3-vl-235b': ('Qwen3-VL 235B', 'openrouter', 'qwen/qwen3-vl-235b-a22b-instruct', 'A'),
    'qwen3.8-flash': ('Qwen3.8 Flash', 'openrouter', 'qwen/qwen3.8-flash', 'A'),
    'qwen3.6-27b': ('Qwen3.6 27B', 'openrouter', 'qwen/qwen3.6-27b', 'B'),
    'qwen3.5-9b': ('Qwen3.5 9B', 'openrouter', 'qwen/qwen3.5-9b', 'B'),
    'qwen3-vl-8b-mlx4': ('Qwen3-VL 8B', 'local', 'qwen3-vl-8b', 'mlx'),
}
# The two Mac routes post_read_flag already reads (log-probability runs), and Gemini 3.7 Flash through the gateway.
APP_ROUTES_KNOWN = {'lightonocr-3-4b-mlx8': ('LightOnOCR-3', 'local', 'lightonocr'),
                    'qwen3.5-9b-mlx4': ('Qwen3.5 9B', 'local', 'qwen3.5-9b'),
                    'gemini3.7-flash': ('Gemini 3.7 Flash', 'gateway', 'gemini-3.7-flash')}


def route_text(key, page):
    """(text, ok) for one app route's reading of one of the 96, from the caches APP_ROUTES names."""
    src = APP_ROUTES[key][3]
    jid = page + '-original.json'
    path = {'A': CACHE / 'ocr-panel-cloud/responses' / key / jid, 'B': CACHE / 'ocr-panel-local/responses' / key / jid,
            'claude': CACHE / 'ocr-panel-cloud/sub' / key / jid, 'mistral': CACHE / 'ocr-panel-cloud/mistral' / jid,
            'mlx': CACHE / 'ocr-panel-local/local' / key / jid}[src]
    if not path.exists():
        raise SystemExit(f'missing reading {path}')
    d = json.loads(path.read_text())
    text = d.get('text') or '' if src == 'mistral' else ((d.get('parsed') or {}).get('text') or '')
    return text, bool(text)


LABEL = {'lightonocr-3-4b-mlx8': 'LightOnOCR-3 4B (Mac mlx 8-bit)', 'qwen3.5-9b-mlx4': 'Qwen3.5-9B (Mac mlx 4-bit)',
         'gemini3.7-flash': 'Gemini 3.7 Flash (gateway)', 'vision': 'Apple Vision',
         'lightonocr3-4b': 'LightOnOCR-3 4B (Sherlock vLLM)', 'qwen3.5-9b': 'Qwen3.5-9B (Sherlock vLLM)',
         **{k: v[0] + (' (Mac mlx 4-bit)' if v[1] == 'local' else '') for k, v in APP_ROUTES.items()
            if k != 'qwen3.5-9b'}}

PAIRS_96 = {
    'lightonocr-3-4b-mlx8': ['qwen3.5-9b-mlx4', 'vision'],
    'qwen3.5-9b-mlx4': ['lightonocr-3-4b-mlx8', 'vision'],
    'gemini3.7-flash': ['vision', 'qwen3.5-9b-mlx4'],
    'vision': ['gemini3.7-flash', 'qwen3.5-9b-mlx4'],
}
PAIRS_LADDER = {'gemini3.7-flash': ['vision'], 'vision': ['gemini3.7-flash']}


def rows_for(read, truth_of, kind_of, pairs):
    """One row per reader and image: nes, poor, and every signal's risk."""
    from ocr_panel_score import normal

    rows = []
    for reader, partners in pairs.items():
        for key, (text, ok, conf) in read[reader].items():
            ok = ok and bool(normal(text))
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
                         'nes': nes, 'poor': nes < POOR, 'answered': ok, 'risk': sig})
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
                        'poor': nes < POOR, 'answered': ok, 'risk': risk})
    return out


# --- the analysis ------------------------------------------------------------------------------------------------

def row_counts(rows, sig, cut):
    return counts([r['risk'][sig] for r in rows], [r['poor'] for r in rows], [r['nes'] for r in rows], cut,
                  answered=[r['answered'] for r in rows])


def evaluate(rows, sig, groups=False, sets=None):
    risk = [r['risk'][sig] for r in rows]
    poor = [r['poor'] for r in rows]
    nes = [r['nes'] for r in rows]
    answered = [r['answered'] for r in rows]
    answered_risk = [r for r, ok in zip(risk, answered) if ok]
    answered_poor = [y for y, ok in zip(poor, answered) if ok]
    cut = (fit_cut_each(answered_risk, answered_poor, [s for s, ok in zip(sets, answered) if ok]) if sets is not None
           else fit_cut(answered_risk, answered_poor))
    # An unavailable signal on an otherwise answered reading cannot flag it.
    scored_risk = [-math.inf if r == FAILED else r for r in answered_risk]
    return {'auc': auc(scored_risk, answered_poor), 'cut': None if cut == FAILED else cut,
            'in_sample': rates(counts(risk, poor, nes, cut, answered=answered)),
            'crossval': rates(crossval(risk, poor, nes, [r['page'] for r in rows] if groups else None,
                                      sets=sets, answered=answered))}


def transfer(fit_rows, test_rows, sig):
    answered = [r for r in fit_rows if r['answered']]
    cut = fit_cut([r['risk'][sig] for r in answered], [r['poor'] for r in answered])
    return {'cut': None if cut == FAILED else cut, **rates(row_counts(test_rows, sig, cut))}


def scored_rows():
    pages, r96 = readings_96()
    kind = {p: r['kind'] for p, r in pages.items()}
    sys.path.insert(0, str(HERE))
    import ocr_panel as P
    truth = {p: (P.TRUTH / 'truth' / f'{p}.txt').read_text() for p in pages}
    rows96 = rows_for(r96, lambda k: truth[k], lambda k: kind[k], PAIRS_96)
    lad = readings_ladder()
    rowsl = rows_for(lad, lambda k: truth[k[1]], lambda k: kind[k[1]], PAIRS_LADDER)
    read = {'vision': r96['vision']}
    for key in APP_ROUTES:
        read[key] = {p: (*route_text(key, p), None) for p in pages}
    rows_routes = rows_for(read, lambda k: truth[k], lambda k: kind[k], {k: ['vision'] for k in APP_ROUTES})
    return rows96 + rows_routes, rowsl


def published_scores():
    """Replay the committed per-page scores after the original Vision text cache has been retired."""
    rows_by_set = {'96': [], 'ladder': []}
    with OUT_CSV.open(newline='') as f:
        records = list(csv.DictReader(f))
    signals = {}
    for r in records:
        key = (r['set'], r['reader'])
        signals.setdefault(key, set()).update(s for s, value in r.items() if value and (s == 'conf' or s.startswith('vs ')))
    for r in records:
        risk = {s: float(r[s]) if r[s] else FAILED for s in sorted(signals[r['set'], r['reader']])}
        # Legacy score exports left the primary signal blank for failed replies.
        primary = 'conf' if r['reader'] == 'vision' else 'vs vision'
        answered = r['answered'] == 'True' if 'answered' in r else risk[primary] != FAILED
        nes = float(r['nes'])
        rows_by_set[r['set']].append({**r, 'risk': risk, 'answered': answered, 'nes': nes, 'poor': nes < POOR})
    return rows_by_set['96'], rows_by_set['ladder']


def analyse(rows96, rowsl):
    out = {'item': 'W46.post-read-quality-flag', 'poor_below': POOR, 'ceiling': CEILING, 'folds': FOLDS,
           'seeds': SEEDS, 'sets': {}}
    for name, rows, groups in (('96', rows96, False), ('ladder', rowsl, True)):
        res = {}
        readers = PAIRS_96 if name == '96' else PAIRS_LADDER
        for reader in sorted(readers):
            rr = [r for r in rows if r['reader'] == reader]
            res[reader] = {s: evaluate(rr, s, groups) for s in rr[0]['risk']}
        out['sets'][name] = res
    # the 96 and the ladder's plain images are the same photographs: the ladder's defect images are the test
    tr = {}
    for reader in PAIRS_LADDER:
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
    v96 = [r for r in rows96 if r['reader'] == 'vision' and r['answered']]
    cut = fit_cut([r['risk']['conf'] for r in v96], [r['poor'] for r in v96])
    above = min((-r['risk']['conf'] for r in v96 if r['risk']['conf'] != FAILED and -r['risk']['conf'] > -cut),
                default=1.)
    out['app_rule'] = {'reader': 'vision', 'signal': 'conf', 'flag_below': round((above - cut) / 2, 4),
                       'fitted_cut': cut, 'next_confidence_above': above,
                       '96': out['sets']['96']['vision']['conf']['in_sample'],
                       '96_crossval': out['sets']['96']['vision']['conf']['crossval'],
                       'ladder_defects': tr['vision|conf|96->ladder defects']}
    out['app_readers'] = app_readers(rows96, rowsl)
    return out


def flag_at(rows, sig, cut):
    """The app's threshold for a fitted cut: midway between it and the next lower finite risk, so every row flags
    exactly as in the fit (flag at risk >= the threshold)."""
    below = [r['risk'][sig] for r in rows if r['risk'][sig] != FAILED and r['risk'][sig] < cut]
    return round((cut + max(below)) / 2, 4) if below else cut


def app_readers(rows96, rowsl):
    """W47.wh-read-flag-readers: each reader's own 'vs vision' cut for the app, under the same ceiling. The 96 for
    every reader; Gemini 3.7 Flash, the one reader with ladder readings, gets the lowest cut that holds the ceiling on
    the 96 and on the ladder's 480 defect images each (fit_cut_each; cross-validation keeps a page's images in one
    fold). Recommend a cut when it holds and catches a poor answered reading in cross-validation.
    Track the evidence separately from the rules currently deployed in the app."""
    sig = 'vs vision'
    out = {}
    fits = {k: ([r for r in rows96 if r['reader'] == k], '96 plain photographs, read on this Mac')
            for k in ('lightonocr-3-4b-mlx8', 'qwen3.5-9b-mlx4')}
    gem96 = [r for r in rows96 if r['reader'] == 'gemini3.7-flash']
    gemlad = [r for r in rowsl if r['reader'] == 'gemini3.7-flash' and r['variant'] != 'raw']
    fits['gemini3.7-flash'] = (gem96 + gemlad, '96 plain photographs and 480 damaged copies of 48 of them')
    for k in APP_ROUTES:
        fits[k] = ([r for r in rows96 if r['reader'] == k],
                   '96 plain photographs' + (', read on this Mac' if APP_ROUTES[k][1] == 'local' else ''))
    for k, (rows, measured_on) in fits.items():
        if k == 'gemini3.7-flash':
            sets = ['96'] * len(gem96) + ['ladder'] * len(gemlad)
            ev = evaluate(rows, sig, groups=True, sets=sets)
        else:
            ev = evaluate(rows, sig)
        cut = ev['cut']
        e = {'label': (APP_ROUTES.get(k) or APP_ROUTES_KNOWN[k])[0],
             'route': list((APP_ROUTES.get(k) or APP_ROUTES_KNOWN[k])[1:3]), 'measured_on': measured_on,
             'signal': sig, 'auc': ev['auc'], 'cut': cut, 'flag_at': None if cut is None else flag_at(rows, sig, cut),
             'in_sample': ev['in_sample'], 'crossval': ev['crossval']}
        fitted_sets = [e['in_sample']]
        if k == 'gemini3.7-flash' and cut is not None:
            e['on_96'] = rates(row_counts(gem96, sig, cut))
            e['on_ladder_defects'] = rates(row_counts(gemlad, sig, cut))
            fitted_sets = [e['on_96'], e['on_ladder_defects']]
        e['ships'] = cut is not None and ev['crossval']['hits'] > 0 and all(
            r['fa_rate'] is not None and r['fa_rate'] <= CEILING for r in fitted_sets)
        e['in_app'] = e['ships']
        out[k] = e
    return out


# --- the report --------------------------------------------------------------------------------------------------

def _pct(x):
    return '–' if x is None else f'{100 * x:.0f}%'


def _ci(ci):
    return '' if ci[0] is None else f' ({100 * ci[0]:.0f}-{100 * ci[1]:.0f})'


def _cell(r):
    return f"{_cv(r)} | {_pct(r['under_90_of_flags'])} | {r['failed']}"


def _cv(r):
    return (f"{r['hits']}/{r['poor']} {_pct(r['hit_rate'])}{_ci(r['hit_ci'])} | "
            f"{r['false_alarms']}/{r['good']} {_pct(r['fa_rate'])}{_ci(r['fa_ci'])}")


def _cutf(c):
    return '–' if c is None else f'{c:.3f}'


def render(out):
    L = [HEAD.strip(), '']
    if out['score_source'] == 'published per-page scores':
        L += ['Replayed from the published scores (NES to four decimals, risks to five). The original Vision text',
              'cache is no longer present. Very close risks can tie after rounding.', '']
    hdr = ('| reader | signal | AUC | cut | in-sample hits | false alarms | flags under 90 | failed | '
           'cross-validated hits | cross-validated false alarms | held-out failures |')
    sep = '|---|---|---:|---:|---|---|---:|---:|---|---|---:|'
    for name, title in (('96', 'The 96, each reader on the plain photograph'),
                        ('ladder', "The capture ladder's 48 Gemini pages: the plain photograph and ten defect images "
                                   "(528 images; cross-validation keeps a page's images in one fold)")):
        L += [f'## {title}', '', hdr, sep]
        for reader, sigs in out['sets'][name].items():
            for s, e in sigs.items():
                L.append(f"| {LABEL[reader]} | {s} | {_cutf(e['auc'])} | {_cutf(e['cut'])} | {_cell(e['in_sample'])} | "
                         f"{_cv(e['crossval'])} | {e['crossval']['failed']} |")
        L.append('')
    L += ['## The Sherlock routes on the public sets and the 96 (W46.ocr-logprob\'s CSV; "vs pair" is the other '
          'Sherlock route)', '', hdr.replace('| reader |', '| reader, set |'), sep]
    for key, sigs in out['sets']['sherlock'].items():
        reader, st = key.split('|')
        for s, e in sigs.items():
            L.append(f"| {LABEL[reader]}, {st} | {s} | {_cutf(e['auc'])} | {_cutf(e['cut'])} | {_cell(e['in_sample'])} | "
                     f"{_cv(e['crossval'])} | {e['crossval']['failed']} |")
    L += ['', '## A cut fitted on one set, applied once to another', '',
          '| reader | signal | fitted on, applied to | cut | hits | false alarms | flags under 90 | failed |',
          '|---|---|---|---:|---|---|---:|---:|']
    for key, r in out['transfer'].items():
        reader, s, how = key.split('|')
        L.append(f"| {LABEL[reader]} | {s} | {how} | {_cutf(r['cut'])} | {_cell(r)} |")
    a = out['app_rule']
    L += ['', '## The rule the app ships', '',
          f"Apple Vision's reading is flagged when its character-weighted mean line confidence is under "
          f"{a['flag_below']} (the cut fitted on the 96, between the confidences on either side of it). "
          "On the 96, and applied once to the ladder's 480 defect images:", '',
          '| set | hits | false alarms | flags under 90 | failed |', '|---|---|---|---:|---:|',
          f"| the 96, in-sample | {_cell(a['96'])} |",
          f"| the 96, cross-validated | {_cell(a['96_crossval'])} |",
          f"| ladder defect images, applied once | {_cell(a['ladder_defects'])} |"]
    L += ['', '## Each reader\'s own cut, for the app (W47.wh-read-flag-readers, 2026-11-19)', '',
          "Owner, 2026-11-19 (call 15): every reader the bench has read gets the disagreement-with-Vision flag at its "
          "own cut under the same 5% ceiling. Signal: vs vision, every page (the app does not know a page is "
          "handwritten before it is read). Gemini 3.7 Flash's cut is the lowest that holds the ceiling on the 96 and "
          "on the ladder's 480 defect images each. \"flag at\" is the app's threshold, midway between the cut and the "
          "next lower disagreement seen. A cut qualifies when it holds the ceiling in the fit and catches at least "
          "one poor answer in cross-validation.",
          '', '| reader | app route | measured on | AUC | cut | flag at | in-sample hits | false alarms | flags under 90 '
          '| failed | cross-validated hits | cross-validated false alarms | held-out failures | qualifies | in app |',
          '|---|---|---|---:|---:|---:|---|---|---:|---:|---|---|---:|---|---|']
    for e in out['app_readers'].values():
        L.append(f"| {e['label']} | {' '.join(e['route'])} | {e['measured_on']} | {_cutf(e['auc'])} | {_cutf(e['cut'])} | "
                 f"{'–' if e['flag_at'] is None else format(e['flag_at'], '.4f')} | {_cell(e['in_sample'])} | "
                 f"{_cv(e['crossval'])} | {e['crossval']['failed']} | "
                 f"{'yes' if e['ships'] else 'no'} | {'yes' if e['in_app'] else 'no'} |")
    g = out['app_readers'].get('gemini3.7-flash', {})
    if 'on_96' in g:
        L += ['', f"Gemini 3.7 Flash at its cut: on the 96 {_cell(g['on_96'])}; on the ladder's defect images "
                  f"{_cell(g['on_ladder_defects'])} (hits | false alarms | flags under 90 | failed)."]
    L += ['', FINDINGS.strip(), '', FINDINGS_READERS.strip(), '', CARD.strip(), '']
    return '\n'.join(L)


def check_swift(out):
    """The Swift rules carry the shipped readers' thresholds and no others (ReadQualityDisagreement.swift)."""
    import re
    src = (HERE.parents[1] / 'macOS/Sources/ArchiveProcessor/OCR/ReadQualityDisagreement.swift').read_text()
    have = {m.group(2): float(m.group(1)) for m in re.finditer(
        r'flagAtOrAbove: ([0-9.]+),\s*measuredOn: "[^"]*",\s*benchReaderID: "([^"]+)"', src)}
    have.update({m.group(2): float(m.group(1)) for m in re.finditer(r'plain\("[^"]+", ([0-9.]+), "([^"]+)", caught: \d+, poor: \d+\)', src)})
    want = {k: e['flag_at'] for k, e in out['app_readers'].items() if e['in_app']}
    bad = sorted(set(have) ^ set(want)) + sorted(k for k in set(have) & set(want) if have[k] != want[k])
    if bad:
        raise SystemExit(f'ReadQualityDisagreement.swift does not match app_readers: {bad} (have {have}, want {want})')
    return want


HEAD = """
# W46.post-read-quality-flag: a "this photo read poorly" flag, fitted for few false alarms

Generated by `scripts/segbench/post_read_flag.py report` (add `--from-scores` to replay). Per-image risks, no text:
`post-read-flag-pages.csv`; every figure: `post-read-flag.json`. No money: every reading is cached.

A reading is poor under 70 NES; a false alarm is a flag on a reading at 70 or above, counted over those good
readings; the ceiling is 5% of them. Hits, false alarms and AUC use answered readings. Failed readings (cap,
refusal, error or empty reply) appear in their own counts. The cut is the lowest
whose in-sample false alarms stay within the ceiling (flag at risk >= cut; for "vs" signals the risk is 1 minus the
NES against the partner's text, for "conf" the negated mean log-probability, or for Apple Vision its negated
character-weighted line confidence). Cells: hits / poor readings, false alarms / good readings, with Wilson 95%
intervals; "flags under 90" is the share of flags on readings under 90 NES. Cross-validation uses the original
folds and pools counts over 20 five-fold splits, so each failed reading appears 20 times under "held-out failures".
The pooled intervals are narrower than the sample warrants; read them as a guide.
"""

FINDINGS = """
## Findings from the original photo sets

- **Apple Vision's confidence cut transfers from plain photographs to damaged ones.** Fitted on the 96 (flag under 0.9815), it catches 10 of Vision's 21 poor readings with 3 false alarms in 75
  in-sample (4%, the fit itself); cross-validated, the honest estimate for new pages (repeated 5-fold, pooled over the
  repeats), it catches 193 of 420 (46%) with 87 false alarms in 1,500 (5.8%, 4.7-7.1), a little over the ceiling it
  was fitted to. Applied once to the ladder's defect images it catches 155 of 207 poor answers with 7 false alarms in 249 (3%).
  Another 24 images produced no answer. The cut fitted on the ladder lands within 0.006 of it. The misses on the 96
  include poor answers at confidence 1.0, mostly printed pages Vision misreads.
- **Two-reader disagreement with Apple Vision ranks poor answers on plain photographs.** On the original
  three readers, AUC is 0.89–0.96, and leaving handwritten pages unflagged improves it for two of the three.
  At around 5% false alarms, cross-validation catches 82% of LightOnOCR-3's poor answers with handwriting
  unflagged and 25–28% of the Mac Qwen3.5-9B's across the Vision signals. Gemini 3.7 Flash gives three poor answers.
- **Gemini's plain-photo disagreement cut flags too many good answers on damaged images.** Vision loses far
  more to blur than Gemini (capture-ladder.md). The cut fitted on the 96 flags 21% of Gemini's good defect-image
  answers, or 16% with handwriting unflagged. The cuts fitted on the damaged images catch 38–42% of Gemini's
  poor damaged answers there. Weighting disagreement by Vision's confidence gives an AUC of 0.52 on the ladder.
- **Log-probabilities rank errors.** Qwen3.5-9B's mean log-probability catches about 25% of poor answers at
  5% false alarms on the 96 and 38% on the public 455 for the Sherlock build. LightOnOCR's catches around 1% or
  less on the 96. No Swift route requests log-probabilities today. Disagreement between the Sherlock routes
  catches 53% and 89% of Qwen3.5-9B's poor answers on the public sets. The cut fitted on the 455 flags 5 of 90
  good answers on the 96 (6%).
- **Real phone captures:** the reader-specific cuts below were measured on these benchmark images. Their
  performance on real phone captures remains unmeasured (W46.capture-warning).
"""

CARD = """
## Measurement card

- **Truth:** the 96's adjudicated truth (`ocr_truth`), the same for every image of a page. Gemini 3.8 Flash is
  both a drafter and a scored reader. Its co-drafter Claude Opus 5.5 is in the same family as the scored Claude
  Sonnet 5.5. This can favour their readings and affect which pages score below 70. The owner's blind check
  found the typed-page truth fit for ranking (measurement audit, 2026-10-30). The public 440 and 455 use their
  datasets' own truth.
- **Selection:** all 96 scored pages; the ladder's 48 are every other page of the 96 in a seeded order, chosen
  before any reading (W46.capture-ladder-paid). Every page where Apple Vision (26.6) read fewer than 20 words was
  replaced at the 96's draw, so the 96 hold no page Vision reads as empty: Vision's disagreement is measured on pages
  it could read, which flatters it as a partner on the owner's harder material. No ABBYY text is used.
- **Comparison:** every signal is scored on the same readings and labels; each reader's text is the one its own
  report scored (W46.ocr-logprob for the Mac routes, the cloud panel for Gemini's plain image, W46.enh-dewarp's
  macOS 27.2 Vision for Vision's). On the ladder both readers read the same defect image.
- **Noise:** Most app readers give fewer than 10 poor answers on the 96, so one page can move a hit rate by
  10 points or more. A 5% ceiling allows about four false alarms per reader. The cross-validated rows are
  the honest estimate; the in-sample rows are the fit. A rerun of a reader moves its NES by up to 0.24 points
  (W46.ocr-rerun-noise, Gemini), far below the 70 line.
- **Scope:** synthetic defects on the ladder, one at a time; no real phone captures (W46.capture-warning), the
  public sets only through the Sherlock routes' CSV, and the app's own routes only as far as the bench readers stand
  for them. The cuts are for a stated ceiling on these pages, not for any collection's mix of kinds.
"""


FINDINGS_READERS = """
## Findings for the other readers (W46.p17-flag-answered-hits)

- Nine of sixteen cuts qualify on answered readings. Five former app cuts catch zero poor answers at their fitted
  thresholds or in cross-validation: Gemini 3.8 Flash (0/3), Gemini 3.1 Pro (0/2), Gemini 3.5 Flash Lite (0/3),
  Qwen3.8 Flash (0/3), and Qwen3.6 27B (0/3). Each flags four good plain-photo answers in the fit. Their earlier
  reported hits came from failed requests. Gemini 3.8 Flash's AUC falls from 0.897 to about 0.83. The app removed
  those five cuts in W46.p17-flag-unflag-five, following the owner's call 24. Claude Sonnet 5.5 and
  Mistral OCR also catch zero poor answers (0/2 and 0/7) and have no app rule (call 17).
- Four readers catch one poor answer each at their fitted cuts: Gemini 3.1 Flash Lite (1/5), GPT-5.4 mini (1/4),
  Qwen3.5 9B through OpenRouter (1/5), and Qwen3-VL 8B on the Mac (1/3).
- Gemini 3.7 Flash is the only reader with a disagreement cut fitted on both plain and damaged photographs.
  Its cut is near-total disagreement. The table above gives its plain and damaged results separately.
- The check compares the reader's text with Apple Vision's. A completed Vision pass with no text is total
  disagreement. Region-ordered newspaper text, failed reader replies and failed Vision passes are outside
  the check. The run summary names the images each flagged reader's threshold was measured on and what it caught there.
"""


def report(from_scores=False):
    rows96, rowsl = published_scores() if from_scores else scored_rows()
    out = analyse(rows96, rowsl)
    out['score_source'] = 'published per-page scores' if from_scores else 'cached reader replies'
    matched = check_swift(out)
    base = ['set', 'reader', 'page', 'variant', 'kind', 'answered', 'nes']
    pages = [{'set': name, **{key: r[key] for key in base[1:-1]}, 'nes': round(r['nes'], 4),
              **{k: (None if v == FAILED else round(v, 5)) for k, v in r['risk'].items()}}
             for name, rows in (('96', rows96), ('ladder', rowsl)) for r in rows]
    cols = base + sorted({k for r in pages for k in r} - set(base))
    with OUT_CSV.open('w', newline='') as f:
        w = csv.DictWriter(f, cols, lineterminator='\n')
        w.writeheader()
        w.writerows(pages)
    OUT_JSON.write_text(json.dumps(out, indent=1, allow_nan=False) + '\n')
    OUT_MD.write_text(render(out))
    print(OUT_MD.read_text())
    print('Swift rules match:', matched)


def self_test():
    assert wilson(0, 0) == (None, None)
    lo, hi = wilson(5, 10); assert 0.23 < lo < 0.24 and 0.76 < hi < 0.77
    assert auc([3, 2, 1], [True, False, False]) == 1.0
    assert auc([1, 1], [True, False]) == 0.5
    # 20 good readings at risk 0..19, three poor at 30, 31 and 5, one failed: ceiling 5% of 20 = 1 false alarm.
    risk = [float(i) for i in range(20)] + [30., 31., 5., FAILED]
    poor = [False] * 20 + [True, True, True, True]
    cut = fit_cut(risk, poor)
    assert cut == 19., cut
    c = counts(risk, poor, [0.95] * 20 + [0.5] * 4, cut)
    assert c == {'n': 24, 'poor': 4, 'good': 20, 'flagged': 4, 'hits': 3, 'false_alarms': 1, 'flags_under_90': 3}, c
    assert fit_cut([FAILED, 1.], [True, False]) == FAILED       # no finite cut fits: only failures flagged
    cv = crossval(risk, poor, [0.9] * 24)
    assert cv['n'] == 24 * SEEDS and cv['poor'] == 4 * SEEDS
    answered = [True] * 23 + [False]
    nes = [0.95] * 20 + [0.5] * 4
    c = counts(risk, poor, nes, cut, answered=answered)
    assert c == {'n': 23, 'failed': 1, 'poor': 3, 'good': 20, 'flagged': 3, 'hits': 2,
                 'false_alarms': 1, 'flags_under_90': 2}, c
    cv = crossval(risk, poor, nes, answered=answered)
    assert cv['n'] == 23 * SEEDS and cv['poor'] == 3 * SEEDS and cv['failed'] == SEEDS
    # With no poor answer caught, the failed reading raises neither AUC nor the held-out hit count.
    rows = [{'risk': {'s': r}, 'poor': y, 'nes': e, 'answered': ok}
            for r, y, e, ok in zip([1., 0., FAILED], [False, True, True], [.95, .5, 0.], [True, True, False])]
    ev = evaluate(rows, 's')
    assert ev['auc'] == 0 and ev['in_sample']['hits'] == ev['crossval']['hits'] == 0
    assert ev['in_sample']['failed'] == 1 and ev['crossval']['failed'] == SEEDS
    assert counts([FAILED], [True], [0.], FAILED, answered=[False])['flagged'] == 0
    # two sets: the second's good readings sit higher, so the cut that holds on both is the second's
    sets = ['a'] * 24 + ['b'] * 21
    both = fit_cut_each(risk + [float(i) + 10 for i in range(20)] + [40.], poor + [False] * 20 + [True], sets)
    assert both == 29., both
    assert fit_cut_each(risk, poor, ['a'] * 24) == cut
    rows = [{'risk': {'s': x}} for x in (1., 2., 4., FAILED)]
    assert flag_at(rows, 's', 4.) == 3. and flag_at(rows, 's', 1.) == 1.
    print('self-test ok')


def parity(path):
    """Every app route's 96 readings with Vision's and the bench's NES of one against the other, as JSON at path (a
    temporary file: it holds page text), for the Swift contract's parity check (READQUALITY_PARITY)."""
    pages, r96 = readings_96()
    rows = []
    for key in [*APP_ROUTES, 'lightonocr-3-4b-mlx8', 'qwen3.5-9b-mlx4', 'gemini3.7-flash']:
        for p in pages:
            text, ok = route_text(key, p) if key in APP_ROUTES else r96[key][p][:2]
            vision = r96['vision'][p][0]
            if ok:
                rows.append({'vision': vision, 'reader': text, 'nes': _score(vision, text)})
    Path(path).write_text(json.dumps(rows, ensure_ascii=False))
    print(f'{len(rows)} pairs to {path}')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('cmd', choices=['report', 'self-test', 'parity'])
    ap.add_argument('path', nargs='?')
    ap.add_argument('--from-scores', action='store_true', help='replay the published per-page scores')
    a = ap.parse_args()
    report(a.from_scores) if a.cmd == 'report' else parity(a.path) if a.cmd == 'parity' else self_test()


if __name__ == '__main__':
    main()
