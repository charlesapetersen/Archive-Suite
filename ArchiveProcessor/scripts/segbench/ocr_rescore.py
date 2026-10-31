#!/usr/bin/env python3
"""W46.fix-ocr-scorers. Every cached OCR reading re-scored with the review's scorer additions (ocr_scorers.py).

  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy python ocr_rescore.py

Reads saved files only: no model, no network, no money. The owner's truth pages (ocr_panel.TRUTH; the 96 are the 99
without the three agreement letters) and the 895 frozen public pages (corpus/routes.frozen()). Sources:

  the 96   cloud panel (ocr-panel-cloud/responses/*, sub/claude-sonnet5.5, mistral), local panel
           (ocr-panel-local/responses/*), the Mac-local routes (ocr-panel-local/local/*), Apple Vision, the eight
           FarmShare truth96 routes and the 2026-10-18 owner99 runs (CHURRO, Qwen3.5-27B), from FARMSHARE.
  the 895  the two reference routes and Apple Vision (bench-corpus/routes), the kraken specialists, the open
           sweep's eleven routes and the 2026-10-18 CHURRO, Qari and Fanar runs, from FARMSHARE.
  both     Gemini 3.7 Flash through the Stanford gateway (gateway-gemini/panel, gemini37-public/responses), and
           W46.ocr-new-open's three Sherlock routes (Xiaomi-OCR-0, PaddleOCR-VL 1.6, Qwen3.8 27B), from
           CACHE/sherlock-results/new-open-{895,96}.

A reading is what that source's own report scored (the same reading() functions and modes); a failure is an
empty reading. The invention figures (added, rewritten, suspect) are pooled over answered pages, since an empty
reading invents nothing; NES and the NewsBench figures count failures, as their own benches do. The suspect check uses Apple Vision as the second reader
(the free one on the Mac, D-enhancement 6.4), or Gemini 3.8 Flash for Vision's own rows, and is scored against
the truth: how many suspect words the truth lacks (precision) and how many of the reading's non-truth words are
suspect (recall). Restoration-only words are computed for the local panel's half and quarter scale readings
against the original-scale reading: a downscale, not an enhancement, so this shows the scorer on real readings;
the enhancement arms are W46.enh-ocr-input. The mark-region check and reseeding instability need enhanced
images and mark boxes, which no cached run has (W46.enh-ocr-input, W46.fix-marks-set-draft).

Writes, under segbench-results/: ocr-scorers.md, ocr-scorers.json (per route and set, and per stratum) and
ocr-scorers-pages.csv (scores only; no text). Restoration-only word lists stay in CACHE (raw text is private).
"""
from __future__ import annotations

import argparse
import collections
import csv
import json
import os
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import ocr_panel as P                      # noqa: E402
import ocr_panel_score as S                # noqa: E402
import ocr_scorers as Z                    # noqa: E402
import routes as R                         # noqa: E402
import farmshare_results as F              # noqa: E402
import farmshare_expanded_report as X      # noqa: E402
import specialists as SP                   # noqa: E402

RESULTS = HERE.parents[1] / 'segbench-results'
CACHE = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
FARMSHARE = Path(os.environ.get('FARMSHARE_STORE', Path.home() / 'Claude/Long term storage'))
OUT_CACHE = CACHE / 'ocr-scorers'
PRESERVE = ('L2', 'L5', 'L6', 'L7', 'L8')   # strata whose strict score keeps long s and the ligatures
SECOND_READER = 'apple-vision'
SECOND_FOR_VISION = 'gemini3.8-flash'
GATEWAY_ROUTE = 'gemini3.7-flash-gw'   # Gemini 3.7 Flash through the Stanford gateway, on both sets

T96 = FARMSHARE / 'FarmShare-truth96-20261020/outputs'
TRUTH96_ROUTES = [  # label, folder under T96, mode (farmshare_truth96.py's)
    ('glm-ocr', 'glm-ocr/results/ocr/glm-ocr', 'native'),
    ('lightonocr3-4b', 'lightonocr3-4b/results/ocr/lightonocr3-4b', 'native'),
    ('lightonocr3-0.8b', 'lightonocr3-08b/results/ocr/lightonocr3-08b', 'native'),
    ('paddleocr-vl1.5', 'paddleocr-vl15/results/ocr/paddleocr-vl15', 'native'),
    ('qwen3-vl-8b', 'qwen3-vl-8b/results/ocr/qwen3-vl-8b', 'panel'),
    ('qwen3.5-4b', 'qwen35-4b/results/ocr/qwen35-4b', 'panel'),
    ('ling3-flash-vl-fp8', 'ling3-flash-vl-fp8/results/ocr/ling3-flash-vl-fp8', 'panel'),
    ('ppocrv6-medium', 'ppocrv6-medium-native/raw', 'pipeline'),
]
SH = CACHE / 'sherlock-results'
SHERLOCK_ROUTES = [  # W46.ocr-new-open, new-open-sherlock-20261024.md: label, model folder, mode; 895 and 96 alike
    ('xiaomi-ocr-0', 'xiaomi-ocr-0', 'native'),
    ('paddleocr-vl1.6', 'paddleocr-vl16', 'native'),
    ('qwen3.8-27b', 'qwen38-27b-fp8', 'panel'),
]
OS, GS, PS, Q18, Q19 = (FARMSHARE / 'FarmShare-open-sweep-20261019/outputs',
                        FARMSHARE / 'FarmShare-general-sweep-20261019/outputs',
                        FARMSHARE / 'FarmShare-ppocrv6-20261019/outputs',
                        FARMSHARE / 'FarmShare-20261018/results/ocr', FARMSHARE / 'FarmShare-20261019/results/ocr')
SWEEP_ROUTES = [  # open-sweep-20261019.md's command, plus the 2026-10-18 page specialists
    ('glm-ocr', OS / 'glm-ocr/results/ocr/glm-ocr', 'native'),
    ('lightonocr3-4b', OS / 'lightonocr3-4b/results/ocr/lightonocr3-4b', 'native'),
    ('lightonocr3-0.8b', OS / 'lightonocr3-08b/results/ocr/lightonocr3-08b', 'native'),
    ('paddleocr-vl1.5', OS / 'paddleocr-vl15/results/ocr/paddleocr-vl15', 'native'),
    ('qwen3-vl-8b', OS / 'qwen3-vl-8b/results/ocr/qwen3-vl-8b', 'panel'),
    ('qwen3.5-4b', OS / 'qwen35-4b/results/ocr/qwen35-4b', 'panel'),
    ('ling3-flash-vl-fp8', GS / 'ling3-flash-vl-fp8/results/ocr/ling3-flash-vl-fp8', 'panel'),
    ('ppocrv6-medium', PS / 'ppocrv6-medium-native/raw', 'pipeline'),
    ('qwen3.6-27b', Q19 / 'qwen3.6-27b', 'panel'),
    ('qwen3.5-27b', Q19 / 'qwen3.5-27b', 'panel'),
    ('qwen3.6-35b-a3b', Q19 / 'qwen3.6-35b-a3b', 'panel'),
    ('fs-churro', Q18 / 'churro', 'churro'),
    ('fs-qari', Q18 / 'qari', 'native'),
    ('fs-fanar', Q18 / 'fanar', 'native'),
]


# ---- the 96 -----------------------------------------------------------------------------------------------------

def _parsed(f: Path) -> str:
    got = json.loads(f.read_text()) if f.exists() else {}
    return ((got.get('parsed') or {}).get('text') or '').strip()


def _gateway(f: Path) -> str:
    """A gateway_gemini.call reply: the raw draft, parsed as the panel parses it; '' for a failure."""
    got = json.loads(f.read_text()) if f.exists() else {}
    parsed = P.T.parse_draft(got['raw']) if got.get('raw') else None
    return parsed['text'].strip() if parsed else ''


def owner_sources():
    """{(route, family): {page: text}} over the 99 owner pages, original scale."""
    pages = [r['page'] for r in P.rows()]
    out = {}
    cloud, local = CACHE / 'ocr-panel-cloud', CACHE / 'ocr-panel-local'
    for d in sorted((cloud / 'responses').iterdir()):
        out[(d.name, 'cloud panel')] = {p: _parsed(d / f'{p}-original.json') for p in pages}
    out[('claude-sonnet5.5', 'plan route')] = {p: _parsed(cloud / 'sub/claude-sonnet5.5' / f'{p}-original.json')
                                               for p in pages}
    mis = {}
    for p in pages:
        f = cloud / 'mistral' / f'{p}-original.json'
        mis[p] = (json.loads(f.read_text()).get('text') or '').strip() if f.exists() else ''
    out[('mistral-ocr', 'cloud native')] = mis
    for d in sorted((local / 'responses').iterdir()):
        out[(d.name, 'local panel')] = {p: _parsed(d / f'{p}-original.json') for p in pages}
    for d in sorted((local / 'local').iterdir()):
        out[(d.name, 'Mac local')] = {p: _parsed(d / f'{p}-original.json') for p in pages}
    vis = {}
    for p in pages:
        f = local / 'vision' / f'{p}-original.txt'
        vis[p] = f.read_text().strip() if f.exists() else ''
    out[(SECOND_READER, 'Mac')] = vis
    for label, folder, mode in TRUTH96_ROUTES:
        if (T96 / folder).is_dir():
            recs = F.read_records(T96 / folder)
            out[(label, f'FarmShare {mode}')] = {p: X.reading(recs.get(p), mode) for p in pages}
    for label, key, mode in SHERLOCK_ROUTES:
        d = SH / 'new-open-96' / key / 'results/ocr' / key
        if d.is_dir():
            recs = F.read_records(d)
            out[(label, f'Sherlock {mode}')] = {p: X.reading(recs.get(p), mode) for p in pages}
    churro = FARMSHARE / 'FarmShare-20261018/results/ocr/churro-owner99'
    if churro.is_dir():
        recs = F.read_records(churro)
        out[('fs-churro', 'FarmShare churro')] = {p: F.reading(recs.get(p), 'churro') for p in pages}
    q = FARMSHARE / 'FarmShare-20261018/results/owner99/qwen3.5-27b/replies'
    if q.is_dir():
        texts = {}
        for p in pages:
            f = q / f'{p}.json'
            got = json.loads(f.read_text()) if f.exists() else {}
            reply = got.get('reply') or {}
            ok = (got.get('meta') or reply.get('meta') or {}).get('finish') == 'stop'
            parsed = P.T.parse_draft(reply.get('raw', '')) if ok else None
            texts[p] = parsed['text'].strip() if parsed else ''
        out[('qwen3.5-27b', 'FarmShare panel')] = texts
    gw = CACHE / 'gateway-gemini/panel'   # W46.fix-ocr-scorers-paid's reading of the 96 (gateway_gemini.py panel)
    if gw.is_dir():
        out[(GATEWAY_ROUTE, 'gateway')] = {p: _gateway(gw / f'{p}-original.json') for p in pages}
    return out


def owner_scales():
    """{route: {(page, scale): text}} for the local panel's half and quarter readings."""
    local = CACHE / 'ocr-panel-local/responses'
    jobs = json.loads((CACHE / 'ocr-panel-local/manifest.json').read_text())['jobs']
    return {d.name: {(j['page'], j['scale']): _parsed(d / f"{j['id']}.json") for j in jobs}
            for d in sorted(local.iterdir())}


# ---- the 895 ----------------------------------------------------------------------------------------------------

def public_sources(truth):
    """{(route, family): {job_id: text}}; a page missing from a source's run is absent, not empty."""
    want = {R.job_id(r) for r in truth}
    run = CACHE / 'bench-corpus/routes'
    out = {}
    for k in ('gemini3.8-flash', 'qwen3-vl-235b'):
        d = run / 'responses' / k
        out[(k, 'reference')] = {j: _parsed(d / f'{j}.json') for j in want if (d / f'{j}.json').exists()}
    out[(SECOND_READER, 'Mac')] = {j: (run / 'vision' / f'{j}.txt').read_text().strip() for j in want
                                   if (run / 'vision' / f'{j}.txt').exists()}
    by = {R.job_id(r): r for r in truth}
    for k, spec in SP.MODELS.items():
        if spec.get('runner') == 'farmshare':
            continue
        texts = {}
        for r in SP.pages(spec['strata']):
            f = SP.text_path(k, r)
            if f.exists():
                t = f.read_text()
                texts[R.job_id(r)] = (SP.logical(t) if spec.get('visual_rtl') else t).strip()
        if texts:
            out[(k, 'kraken specialist')] = texts
    for label, folder, mode in SWEEP_ROUTES:
        if not folder.is_dir():
            continue
        recs = F.read_records(folder)
        recs = {j: r for j, r in recs.items() if j in by}
        if label.startswith('fs-'):   # specialists: scored only on the strata they were run for
            out[(label, f'FarmShare {mode}')] = {j: X.reading(r, mode) for j, r in recs.items()}
        else:
            out[(label, f'FarmShare {mode}')] = {j: X.reading(recs.get(j), mode) for j in want}
    for label, key, mode in SHERLOCK_ROUTES:
        d = SH / 'new-open-895' / key / 'results/ocr' / key
        if d.is_dir():
            recs = F.read_records(d)
            out[(label, f'Sherlock {mode}')] = {j: X.reading(recs.get(j), mode) for j in want}
    gw = CACHE / 'gemini37-public/responses'   # W46.ocr-gemini37-895-paid (ocr_gemini37_public.py run)
    if gw.is_dir():
        out[(GATEWAY_ROUTE, 'gateway')] = {j: _gateway(gw / f'{j}.json') for j in want}
    return out


# ---- per-page scoring -------------------------------------------------------------------------------------------

def words(text: str, stratum: str) -> list[str]:
    opt = S.STRATA[stratum]
    t = S.normal(text, opt.get('keep', frozenset()), opt.get('hyphens', False))
    return S.tokens(S.re.sub(r'\[illegible\]', '', t, flags=S.re.I))


def page_row(truth: str, text: str, stratum: str, second: str | None, latin: bool = True) -> dict:
    base = S.score(truth, text, stratum)
    tw, hw = words(truth, stratum), words(text, stratum)
    ar = Z.added_rewritten(tw, hw)
    # the [illegible] marker is not text to read (NES and the word counts drop it too)
    t_clean, h_clean = (S.re.sub(r'\[illegible\]', ' ', x, flags=S.re.I) for x in (truth, text))
    row = {'ok': bool(text), 'nes': base['nes'], 'truth_words': ar['truth_words'], 'reading_words': ar['reading_words'],
           'inserted': ar['inserted'], 'rewritten': ar['rewritten'], 'cmer': Z.cmer(t_clean, h_clean)}
    if latin:  # NewsBench keeps only a-z and 0-9: its figures mean nothing on other scripts
        nb = Z.newsbench(t_clean, h_clean)
        row.update(nb_overall=nb['overall'], nb_chrf=nb['chrF'], nb_bowf1=nb['bowF1'], nb_gap=nb['gap'],
                   nb_edits=nb['edits'], nb_chars=nb['chars'])
    order = Z.reading_order_edit(truth, text) if text else None
    if order:
        row.update(order_blocks=order['blocks'], order_matched=order['matched'], order_edit=order['edit'])
    if stratum in PRESERVE:
        pv = Z.preservation(truth, text)
        row.update(hist_truth=pv['truth'], hist_kept=pv['kept'], hist_inserted=pv['inserted'])
    if text and Z.has_markup(text):
        row['markup'] = True
        row['nes_stripped'] = S.score(truth, Z.strip_markup(text), stratum)['nes']
    if text and second:
        sw = Z.suspect_words(hw, [words(second, stratum)])['words']
        tv = {w.casefold() for w in tw}
        row.update(suspect=len(sw), suspect_not_truth=sum(1 for w in sw if w.casefold() not in tv),
                   not_truth=sum(1 for w in hw if w.casefold() not in tv))
    return row


def score_set(name, sources, truth_of, stratum_of, pages_of, latin_of=lambda p: True):
    rows = []
    second = sources.get(next((k for k in sources if k[0] == SECOND_READER), None), {})
    alt = sources.get(next((k for k in sources if k[0] == SECOND_FOR_VISION), None), {})
    for (route, family), texts in sorted(sources.items()):
        for page in pages_of(texts):
            other = alt.get(page) if route == SECOND_READER else second.get(page)
            r = page_row(truth_of(page), texts.get(page, ''), stratum_of(page), other or None, latin_of(page))
            rows.append({'set': name, 'route': route, 'family': family, 'page': page, 'stratum': stratum_of(page), **r})
    return rows


# ---- aggregation ------------------------------------------------------------------------------------------------

def _sum(rr, k):
    return sum(r.get(k) or 0 for r in rr)


def _spearman(xs, ys):
    if len(xs) < 5 or len(set(xs)) < 2 or len(set(ys)) < 2:
        return None
    def ranks(v):  # average ranks for ties
        order = sorted(range(len(v)), key=lambda i: v[i])
        out = [0.0] * len(v)
        i = 0
        while i < len(v):
            j = i
            while j + 1 < len(v) and v[order[j + 1]] == v[order[i]]:
                j += 1
            for k in range(i, j + 1):
                out[order[k]] = (i + j) / 2
            i = j + 1
        return out
    a, b = ranks(xs), ranks(ys)
    try:
        return statistics.correlation(a, b)
    except statistics.StatisticsError:
        return None


def aggregate(rr):
    ok = [r for r in rr if r['ok']]
    tw = _sum(ok, 'truth_words')
    out = {'n': len(rr), 'ok': len(ok), 'nes': statistics.fmean(r['nes'] for r in rr) if rr else None,
           'nes_answered': statistics.fmean(r['nes'] for r in ok) if ok else None,
           'added_rate': _sum(ok, 'inserted') / tw if tw else None,
           'rewritten_rate': _sum(ok, 'rewritten') / tw if tw else None,
           'cmer': statistics.fmean(r['cmer'] for r in ok) if ok else None}
    # NewsBench scores a failed page as an empty reading, so its figures are over every page, like NES
    nb = Z.newsbench_pool([{'overall': r['nb_overall'], 'chrF': r['nb_chrf'], 'bowF1': r['nb_bowf1']}
                           for r in rr if 'nb_overall' in r])
    out.update({f'nb_{k}': nb.get(k) for k in ('overall', 'chrF', 'bowF1', 'gap')})
    orders = [r['order_edit'] for r in ok if r.get('order_edit') is not None]
    out['order_pages'], out['order_edit'] = len(orders), (statistics.fmean(orders) if orders else None)
    ht = _sum(ok, 'hist_truth')
    if any('hist_truth' in r for r in ok):
        pages_with = [r for r in ok if (r.get('hist_truth') or 0) > 0]
        no_hist = [r for r in ok if 'hist_truth' in r and not r.get('hist_truth')]
        out.update(hist_truth=ht, hist_kept=(_sum(ok, 'hist_kept') / ht if ht else None),
                   hist_pages=len(pages_with),
                   archaic_insert_pages=(sum(1 for r in no_hist if r.get('hist_inserted')) / len(no_hist)
                                         if no_hist else None))
    mk = [r for r in ok if r.get('markup')]
    out['markup_pages'] = len(mk)
    if mk:
        out['markup_nes'] = statistics.fmean(r['nes'] for r in mk)
        out['markup_nes_stripped'] = statistics.fmean(r['nes_stripped'] for r in mk)
        lift = sum(r['nes_stripped'] - r['nes'] for r in mk) / len(rr)
        out['markup_mean_lift'] = lift
    su = [r for r in ok if 'suspect' in r]
    if su:
        flagged, invented = _sum(su, 'suspect'), _sum(su, 'not_truth')
        out.update(suspect_pages=len(su), suspect_rate=flagged / _sum(su, 'reading_words') if _sum(su, 'reading_words') else None,
                   suspect_precision=_sum(su, 'suspect_not_truth') / flagged if flagged else None,
                   suspect_recall=_sum(su, 'suspect_not_truth') / invented if invented else None,
                   suspect_vs_added=_spearman([r['suspect'] / max(r['reading_words'], 1) for r in su],
                                              [r['inserted'] / max(r['truth_words'], 1) for r in su]))
    return out


def summarise(rows):
    by = collections.defaultdict(list)
    for r in rows:
        by[(r['set'], r['route'], r['family'], 'all')].append(r)
        if r['set'] == 'public895':
            by[(r['set'], r['route'], r['family'], r['stratum'])].append(r)
    return [{'set': s, 'route': k, 'family': f, 'stratum': st, **aggregate(rr)}
            for (s, k, f, st), rr in sorted(by.items())]


def restoration(scales, truth_text):
    out, lists = [], {}
    for route, texts in sorted(scales.items()):
        for scale in ('half', 'quarter'):
            pages = sorted(p for (p, s) in texts if s == scale)
            found, n_words, n_ok = [], 0, 0
            for p in pages:
                enh, raw = texts[(p, scale)], texts.get((p, 'original'), '')
                if not enh or not raw:
                    continue
                n_ok += 1
                r = Z.restoration_only(words(enh, 'S0'), words(truth_text(p), 'S0'), words(raw, 'S0'))
                found += r['words']
                n_words += len(words(enh, 'S0'))
                lists[f'{route}/{p}-{scale}'] = r['words']
            out.append({'route': route, 'scale': scale, 'pages': n_ok, 'words': n_words, 'restoration_only': len(found),
                        'per_1000': 1000 * len(found) / n_words if n_words else None})
    return out, lists


# ---- report -----------------------------------------------------------------------------------------------------

def pct(x, d=1):
    return '–' if x is None else f'{100 * x:.{d}f}'


def num(x, d=3):
    return '–' if x is None else f'{x:.{d}f}'


def write_md(path, summary, rest, counts):
    own = [r for r in summary if r['set'] == 'owner96' and r['stratum'] == 'all']
    pub = [r for r in summary if r['set'] == 'public895' and r['stratum'] == 'all']
    L = ['# OCR scorer additions on every cached reading (W46.fix-ocr-scorers)', '',
         'Generated by `ArchiveProcessor/scripts/segbench/ocr_rescore.py` from saved readings only: no model, no '
         'network, $0. Scorers: `ocr_scorers.py`; definitions in `execution-plans/processing-review/10-gap-audit.md` '
         '§4 item 9 and D-enhancement §6.4. ' + counts, '',
         'Columns. **NES**: the bench\'s own score, failures as 0 (answered pages only in brackets). **added** and '
         '**rewritten**: insertions, and substitutions more than one edit from their truth word, over truth words, '
         'pooled over answered pages, on the scorer\'s lower-cased word tokens. **cMER**: HIPE-OCRepair\'s '
         '(S+D+I)/(H+S+D+I), case and punctuation folded, page mean. **NB overall / bowF1 / gap**: NewsBench\'s '
         'scorer (1 - the mean page CER, page-mean bag-of-words F1, and their difference, the order penalty) over '
         'every page, a failure as an empty reading as NewsBench scores it, on Latin-script pages only, since it '
         'keeps only a-z and 0-9; the `[illegible]` marker is dropped before cMER and NewsBench, as NES drops it. '
         '**suspect**: '
         'share of the reading\'s words that the second reader (Apple Vision; Gemini 3.8 Flash for Vision\'s own row) '
         'does not contain; **prec** is the share of those the truth lacks, **rec** the share of the reading\'s '
         'non-truth words that are suspect, **ρ** the page-level Spearman correlation of suspect rate with added '
         'rate.', '']
    hdr = ('| route | family | pages | NES (answered) | added | rewritten | cMER | NB overall | bowF1 | gap | '
           'suspect | prec | rec | ρ |')
    sep = '|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|'
    def line(r):
        return (f"| {r['route']} | {r['family']} | {r['ok']}/{r['n']} | {pct(r['nes'])} ({pct(r['nes_answered'])}) | "
                f"{pct(r['added_rate'])} | {pct(r['rewritten_rate'])} | {pct(r['cmer'])} | {pct(r['nb_overall'])} | "
                f"{pct(r['nb_bowF1'])} | {pct(r['nb_gap'])} | {pct(r.get('suspect_rate'))} | "
                f"{pct(r.get('suspect_precision'), 0)} | {pct(r.get('suspect_recall'), 0)} | "
                f"{num(r.get('suspect_vs_added'), 2)} |")
    L += ['## The owner\'s 96 truth pages', '',
          'The 96\'s truth is one line of words per page, so it has no blocks and OmniDocBench\'s reading-order edit '
          'cannot be scored on it; NewsBench\'s gap still separates order from recognition.', '', hdr, sep]
    L += [line(r) for r in sorted(own, key=lambda r: -(r['nes'] or 0))]
    L += ['', '## The 895 public pages', '',
          'Every route over the pages its run covered (the reference routes and Vision were run on the original 440 '
          'or the Latin-script pages; the kraken and FarmShare specialists on their strata only). **order**: '
          'OmniDocBench\'s reading-order edit, the normalised edit distance between the truth\'s block order and the '
          'order of the matched blocks in the reading, over pages with at least two matched blocks of three or more '
          'words (lower is better).', '',
          hdr + ' order (pages) |', sep + '---:|']
    L += [line(r) + f" {num(r['order_edit'])} ({r['order_pages']}) |" for r in sorted(pub, key=lambda r: -(r['nes'] or 0))]
    L += ['', '### Order by stratum (OmniDocBench reading-order edit; pages scored)', '']
    strata = sorted({r['stratum'] for r in summary if r['set'] == 'public895' and r['stratum'] != 'all'})
    routes = [r['route'] for r in sorted(pub, key=lambda r: -(r['nes'] or 0)) if r['order_pages']]
    cell = {(r['route'], r['stratum']): r for r in summary if r['set'] == 'public895'}
    L += ['| route | ' + ' | '.join(strata) + ' |', '|---|' + '---:|' * len(strata)]
    for k in routes:
        cs = [cell.get((k, s)) for s in strata]
        L.append(f'| {k} | ' + ' | '.join('' if not c or not c['order_pages'] else
                                          f"{num(c['order_edit'], 2)} ({c['order_pages']})" for c in cs) + ' |')
    L += ['', '### Long s and Fraktur ligatures (2510.06743\'s preservation checks)', '',
          'On the strata whose strict score keeps them (L2, L5-L8). **kept**: of the truth\'s long s and ligature '
          'characters, the share the reading has. **archaic insertion**: of the answered pages whose truth has none, '
          'the share where the reading puts one in.', '',
          '| route | stratum | truth characters (pages) | kept | archaic insertion |', '|---|---|---:|---:|---:|']
    for r in summary:
        if (r['set'] == 'public895' and r['stratum'] in PRESERVE and r.get('hist_truth') is not None
                and (r['hist_truth'] or r['archaic_insert_pages'])):
            L.append(f"| {r['route']} | {r['stratum']} | {r['hist_truth']} ({r['hist_pages']}) | {pct(r['hist_kept'])} | "
                     f"{pct(r['archaic_insert_pages'])} |")
    L += ['', '### Markup-aware diagnostic', '',
          'Pages whose reading carries Markdown or HTML (headings, bold, tables, tags, image placeholders, LaTeX '
          'delimiters), NES as scored and after `strip_markup`; **lift** is the change on the whole set\'s mean, in '
          'points. A diagnostic only: the bench\'s convention (score native Markdown as written) is unchanged.', '',
          '| set | route | family | pages with markup | NES | NES stripped | lift on the mean |',
          '|---|---|---|---:|---:|---:|---:|']
    for r in summary:
        if r['stratum'] == 'all' and r['markup_pages']:
            L.append(f"| {r['set']} | {r['route']} | {r['family']} | {r['markup_pages']} | {pct(r['markup_nes'])} | "
                     f"{pct(r['markup_nes_stripped'])} | {100 * r['markup_mean_lift']:+.2f} |")
    L += ['', '### Restoration-only words (scale variants of the local panel)', '',
          'Words in the half- or quarter-scale reading that neither the truth nor the same route\'s original-scale '
          'reading contains, per 1,000 reading words, on the 20 ladder pages. A downscale, not an enhancement: this '
          'runs the scorer on real readings; W46.enh-ocr-input applies it to the enhancement methods. The word '
          'lists are kept privately in the cache.', '',
          '| route | scale | pages | reading words | restoration-only | per 1,000 |', '|---|---|---:|---:|---:|---:|']
    for r in rest:
        if r['pages']:
            L.append(f"| {r['route']} | {r['scale']} | {r['pages']} | {r['words']} | {r['restoration_only']} | "
                     f"{num(r['per_1000'], 1)} |")
    L += ['', 'Not computed here, for want of inputs: the mark-region ink check (needs enhanced images and the marks '
          'set\'s boxes: W46.enh-ocr-input-marks, W46.fix-marks-set-draft) and reseeding instability (needs two seeds '
          'of a diffusion restorer: W46.enh-ocr-input). Both functions are in `ocr_scorers.py` with unit tests.', '']
    path.write_text('\n'.join(L))


PAGE_FIELDS = ['set', 'route', 'family', 'page', 'stratum', 'ok', 'nes', 'truth_words', 'reading_words', 'inserted',
               'rewritten', 'cmer', 'nb_overall', 'nb_chrf', 'nb_bowf1', 'nb_gap', 'order_blocks', 'order_matched',
               'order_edit', 'hist_truth', 'hist_kept', 'hist_inserted', 'markup', 'nes_stripped', 'suspect',
               'suspect_not_truth', 'not_truth']


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', type=Path, default=RESULTS)
    ap.add_argument('--only', choices=['owner', 'public'])
    a = ap.parse_args()
    rows, counts = [], []
    truth_owner = lambda p: (P.TRUTH / 'truth' / f'{p}.txt').read_text()
    if a.only != 'public':
        src = owner_sources()
        keep = [r['page'] for r in P.rows() if r['page'] not in P.AGREEMENT]
        rows += score_set('owner96', src, truth_owner, lambda p: 'S0', lambda t: keep)
        counts.append(f'The 96: {len(src)} routes.')
    if a.only != 'owner':
        R.MANIFEST = RESULTS / 'bench-corpus/manifest.jsonl'
        truth = R.frozen()
        by = {R.job_id(r): r for r in truth}
        src = public_sources(truth)
        rows += score_set('public895', src, lambda j: Path(by[j]['truth']).read_text(),
                          lambda j: by[j]['stratum'], lambda t: sorted(t), lambda j: by[j]['script'] == 'Latn')
        counts.append(f'The 895: {len(src)} routes.')
    summary = summarise(rows)
    rest, lists = restoration(owner_scales(), truth_owner) if a.only != 'public' else ([], {})
    OUT_CACHE.mkdir(parents=True, exist_ok=True)
    (OUT_CACHE / 'restoration-only.json').write_text(json.dumps(lists, ensure_ascii=False, indent=1))
    a.out.mkdir(parents=True, exist_ok=True)
    (a.out / 'ocr-scorers.json').write_text(json.dumps({'summary': summary, 'restoration_only': rest}, indent=1))
    with (a.out / 'ocr-scorers-pages.csv').open('w', newline='') as f:
        w = csv.DictWriter(f, PAGE_FIELDS, extrasaction='ignore')
        w.writeheader()
        for r in rows:
            w.writerow({k: (f'{v:.6f}' if isinstance(v, float) else v) for k, v in r.items()})
    write_md(a.out / 'ocr-scorers.md', summary, rest, ' '.join(counts))
    print(f'{len(rows)} page scores, {len(summary)} summary rows -> {a.out}')


if __name__ == '__main__':
    main()
