#!/usr/bin/env python3
"""W46.ocr-logprob: whether a local route's log-probabilities rank its errors, once calibrated (C test 7, H test 3).

  heavy-run.py run -- <lab venv>/bin/python ocr_logprob.py mac-collect --model lightonocr-3-4b-mlx8|qwen3.5-9b-mlx4
  python3 ocr_logprob.py seg            # the seg 2B's P(new), development boxes against test boxes (no calls)
  uv run --with rapidfuzz --with 'sacrebleu==2.5.1' python ocr_logprob.py report
  python3 ocr_logprob.py self-test

THE READINGS. Each route reads again with the log-probability of every generated token kept: on the Mac through
mlx-vlm (the 96, `mac-collect`, the settings of `ocr_mac_local.py`'s HW routes, so the text is the one W41.mac-local-hw
scored), and on FarmShare through vLLM's `logprobs` (the 895 and the 96, `corpus/logprob_cluster.py`, the open sweep's
request otherwise unchanged). Temperature 0 throughout, so a token's log-probability is that of the greedy choice.

THE SIGNALS, per page, over every generated token (the panel header included; it is a few near-certain tokens):
first-token log-probability, mean log-probability, minimum-k (the mean of the lowest 10% of token log-probabilities,
at least one token) and the low-probability share (tokens under p 0.5). Beside them, the signals already measured
without log-probabilities: output length in tokens, two-reader disagreement (one reader's NES against the other's
text) and escalate-on-failure (a cap or an error only).

THE TESTS. AUC of each signal against NES under 70 (the audit's line), NES under 90 (H test 3's) and failure.
Isotonic calibration fitted on the 440 (the open sweep's original strata), with Brier and ten-bin ECE on the 455 and
the 96. The cascade: a page whose calibrated error probability reaches t goes to the escalation route (Qwen3.6-27B,
its cached readings); t is the cheapest that brings the 96's cascade NES within half a point of escalating every
page; that t is then applied once to the 455. The invariance check (UCCI's assumption): on the escalated pages, the
mean calibrated probability against the observed error rate, and the escalation route's own NES there against its
mean.

THE SEG 2B. Its P(new) per gap is a verbal confidence averaged over windows (method_window.combine), not a token
probability. Isotonic calibration of P(new) on the development boxes is tested on the test boxes, and AUC of its
confidence against a wrong gap decision (expected: no ranking to calibrate; seg-students.md already reports that the
students' confidence does not flag errors).

No money: open weights on this Mac and on FarmShare.
"""
from __future__ import annotations
import argparse
import json
import math
import os
import statistics
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
RESULTS = HERE.parents[1] / 'segbench-results'
SEG_JSON = RESULTS / 'ocr-logprob-seg.json'
SEG_MD = RESULTS / 'ocr-logprob-seg.md'
LOW_P = math.log(0.5)
MIN_K = 0.10
MAC_KEYS = ('lightonocr-3-4b-mlx8', 'qwen3.5-9b-mlx4')


# --- statistics (pure; self-tested) ---------------------------------------------------------------------------

def auc(scores, labels):
    """P(score of a positive > score of a negative), ties counted half (Mann-Whitney). None without both classes."""
    pos = [s for s, y in zip(scores, labels) if y]
    neg = [s for s, y in zip(scores, labels) if not y]
    if not pos or not neg:
        return None
    ranked = sorted((s, y) for s, y in zip(scores, labels))
    rank_sum, i = 0.0, 0
    while i < len(ranked):
        j = i
        while j < len(ranked) and ranked[j][0] == ranked[i][0]:
            j += 1
        mid = (i + 1 + j) / 2  # mean 1-based rank of the tie block
        rank_sum += mid * sum(1 for _, y in ranked[i:j] if y)
        i = j
    return (rank_sum - len(pos) * (len(pos) + 1) / 2) / (len(pos) * len(neg))


def isotonic_fit(xs, ys):
    """Pool-adjacent-violators, non-decreasing in x: a list of (x_low, x_high, value) blocks over the sorted xs."""
    pts = sorted(zip(xs, ys))
    blocks = []  # [x_low, x_high, sum, count]
    for x, y in pts:
        if blocks and blocks[-1][1] == x:
            blocks[-1][2] += y; blocks[-1][3] += 1
        else:
            blocks.append([x, x, float(y), 1])
        while len(blocks) > 1 and blocks[-2][2] / blocks[-2][3] > blocks[-1][2] / blocks[-1][3]:
            b = blocks.pop()
            blocks[-1][1] = b[1]; blocks[-1][2] += b[2]; blocks[-1][3] += b[3]
    return [(lo, hi, s / n) for lo, hi, s, n in blocks]


def isotonic_predict(fit, x):
    """Step value of the block holding x; between blocks, linear between their values; outside, clamped."""
    if x <= fit[0][1]:
        return fit[0][2]
    if x >= fit[-1][0]:
        return fit[-1][2]
    for (lo1, hi1, v1), (lo2, hi2, v2) in zip(fit, fit[1:]):
        if lo1 <= x <= hi1:
            return v1
        if hi1 < x < lo2:
            return v1 + (v2 - v1) * (x - hi1) / (lo2 - hi1)
    return fit[-1][2]


def brier(ps, ys):
    return sum((p - y) ** 2 for p, y in zip(ps, ys)) / len(ps) if ps else None


def ece(ps, ys, bins=10):
    """Expected calibration error over equal-width probability bins."""
    if not ps:
        return None
    total = 0.0
    for b in range(bins):
        lo, hi = b / bins, (b + 1) / bins
        idx = [i for i, p in enumerate(ps) if lo <= p < hi or (b == bins - 1 and p == 1.0)]
        if idx:
            total += len(idx) / len(ps) * abs(sum(ps[i] for i in idx) / len(idx) - sum(ys[i] for i in idx) / len(idx))
    return total


def token_features(lps):
    """The four log-probability signals of one reading (higher = more confident). None for an empty reading."""
    if not lps:
        return None
    k = max(1, math.ceil(MIN_K * len(lps)))
    return {'first': lps[0], 'mean': sum(lps) / len(lps), 'min_k': sum(sorted(lps)[:k]) / k,
            'low_share': -sum(1 for x in lps if x < LOW_P) / len(lps), 'tokens': len(lps)}


def cascade_threshold(probs, first_nes, esc_nes, slack=0.005):
    """The cheapest escalation threshold on a tuning set: the largest t such that escalating every page with
    calibrated error probability >= t brings the mean NES within `slack` of escalating every page. Returns
    (t, escalated share, cascade NES, escalate-all NES)."""
    n = len(probs)
    target = sum(esc_nes) / n - slack
    for t in sorted(set(probs), reverse=True) + [-1.0]:
        nes = sum(e if p >= t else f for p, f, e in zip(probs, first_nes, esc_nes)) / n
        if nes >= target:
            share = sum(1 for p in probs if p >= t) / n
            return t, share, nes, target + slack
    return -1.0, 1.0, sum(esc_nes) / n, target + slack


def budget_nes(risk, first_nes, esc_nes, frac=0.2):
    """Cascade NES when the riskiest `frac` of pages are escalated (ties broken by order): a comparison at equal
    cost, which a threshold chosen per signal does not give."""
    n = len(risk); k = round(frac * n)
    top = set(sorted(range(n), key=lambda i: -risk[i])[:k])
    return sum(esc_nes[i] if i in top else first_nes[i] for i in range(n)) / n


def apply_threshold(t, probs, first_nes, esc_nes):
    n = len(probs)
    esc = [p >= t for p in probs]
    return {'share': sum(esc) / n, 'nes': sum(e if x else f for x, f, e in zip(esc, first_nes, esc_nes)) / n,
            'first_nes': sum(first_nes) / n, 'all_nes': sum(esc_nes) / n}


# --- the seg 2B's P(new) --------------------------------------------------------------------------------------

def seg_gaps(key='fs-seg-2b'):
    """Per document gap of every box: P(new), the truth, and whether the 2B's decision is wrong. Photo gaps (a
    truth Box/Folder page on either side) are left out, as score.risk_coverage leaves them out."""
    sys.path.insert(0, str(HERE))
    import data
    import method_openrouter as O
    import method_window as W
    from score import PHOTO, segment_ids
    out = {}
    for name in data.DEV + data.TEST:
        col = data.load(name, with_exif=False)
        comb = W.combine(col, O.judge(key))
        ids = segment_ids(col.labels)
        rows = []
        for i, g in enumerate(comb['gaps']):
            if col.labels[i] in PHOTO or col.labels[i + 1] in PHOTO:
                continue
            new = ids[i] != ids[i + 1]
            rows.append({'p_new': g['p_new'], 'new': new, 'wrong': (g['p_new'] >= 0.5) != new,
                         'confidence': g['confidence'], 'agree': g['agree']})
        out[name] = rows
    return out


def seg_analysis(boxes):
    import data
    dev = [r for n in data.DEV for r in boxes[n]]
    test = [r for n in data.TEST for r in boxes[n]]

    def side(rows, fit=None):
        p = [r['p_new'] for r in rows]; y = [1 if r['new'] else 0 for r in rows]
        conf = [r['confidence'] for r in rows]; wrong = [1 if r['wrong'] else 0 for r in rows]
        d = {'gaps': len(rows), 'new': sum(y), 'wrong': sum(wrong),
             'auc_p_new_vs_new': auc(p, y),
             'auc_low_confidence_vs_wrong': auc([-c for c in conf], wrong),
             'auc_disagree_vs_wrong': auc([0 if r['agree'] else 1 for r in rows], wrong),
             'raw_brier': brier(p, y), 'raw_ece': ece(p, y),
             'distinct_p_new': len(set(round(x, 6) for x in p)),
             'wrong_caught_reviewing': {f'{int(100 * f)}%': caught(conf, wrong, f) for f in (0.1, 0.2)}}
        if fit is not None:
            q = [isotonic_predict(fit, x) for x in p]
            d.update(cal_brier=brier(q, y), cal_ece=ece(q, y))
            dec = [x >= 0.5 for x in q]
            d['wrong_after_calibration'] = sum(1 for a, r in zip(dec, rows) if a != r['new'])
        return d
    fit = isotonic_fit([r['p_new'] for r in dev], [1 if r['new'] else 0 for r in dev])
    return {'development': side(dev), 'test': side(test, fit), 'test_by_box': {n: side(boxes[n], fit) for n in data.TEST},
            'development_by_box': {n: side(boxes[n]) for n in data.DEV},
            'isotonic_blocks': [[round(a, 4), round(b, 4), round(v, 4)] for a, b, v in fit]}


def caught(conf, wrong, frac):
    """Share of the wrong decisions among the least confident `frac` of gaps (ties broken by order)."""
    if not sum(wrong):
        return None
    k = round(frac * len(conf))
    order = sorted(range(len(conf)), key=lambda i: conf[i])[:k]
    return sum(wrong[i] for i in order) / sum(wrong)


def _f(x, pct=False):
    return '–' if x is None else (f'{100 * x:.1f}%' if pct else f'{x:.3f}')


def seg_report(res):
    d, t = res['development'], res['test']
    L = ['# W46.ocr-logprob — the seg 2B\'s P(new), calibrated on the development boxes, tested on the test boxes',
         '',
         'Generated by `scripts/segbench/ocr_logprob.py seg` from the cached FarmShare answers of `fs-seg-2b` (Qwen3.5 2B '
         'fine-tuned on the owner\'s corpus, the app\'s local segmenter; `seg-students.md`). No calls, no money. P(new) '
         'is the model\'s stated confidence in its JSON reply, averaged over the windows that judged the gap '
         '(`method_window.combine`), not a token probability. Photo gaps are left out, as in `score.risk_coverage`.',
         '',
         '| measure | development (Dean, Deaver, Herrnstein) | test (Stanton, RG165) |', '|---|---:|---:|',
         f"| document gaps | {d['gaps']} | {t['gaps']} |",
         f"| truth boundaries | {d['new']} | {t['new']} |",
         f"| wrong gap decisions | {d['wrong']} | {t['wrong']} |",
         f"| distinct P(new) values | {d['distinct_p_new']} | {t['distinct_p_new']} |",
         f"| AUC, P(new) against a truth boundary | {_f(d['auc_p_new_vs_new'])} | {_f(t['auc_p_new_vs_new'])} |",
         f"| AUC, low confidence against a wrong decision | {_f(d['auc_low_confidence_vs_wrong'])} | {_f(t['auc_low_confidence_vs_wrong'])} |",
         f"| AUC, windows disagreeing against a wrong decision | {_f(d['auc_disagree_vs_wrong'])} | {_f(t['auc_disagree_vs_wrong'])} |",
         f"| wrong decisions among the least confident 10% of gaps | {_f(d['wrong_caught_reviewing']['10%'], True)} | {_f(t['wrong_caught_reviewing']['10%'], True)} |",
         f"| wrong decisions among the least confident 20% of gaps | {_f(d['wrong_caught_reviewing']['20%'], True)} | {_f(t['wrong_caught_reviewing']['20%'], True)} |",
         f"| Brier, raw P(new) | {_f(d['raw_brier'])} | {_f(t['raw_brier'])} |",
         f"| ECE (10 bins), raw P(new) | {_f(d['raw_ece'])} | {_f(t['raw_ece'])} |",
         f"| Brier, after isotonic calibration on development | – | {_f(t.get('cal_brier'))} |",
         f"| ECE, after isotonic calibration on development | – | {_f(t.get('cal_ece'))} |",
         f"| wrong decisions at calibrated P >= 0.5 | – | {t.get('wrong_after_calibration')} |",
         '', '## By test box', '', '| box | gaps | wrong | AUC low confidence vs wrong | raw ECE | calibrated ECE |',
         '|---|---:|---:|---:|---:|---:|']
    for n, b in res['test_by_box'].items():
        L.append(f"| {n} | {b['gaps']} | {b['wrong']} | {_f(b['auc_low_confidence_vs_wrong'])} | {_f(b['raw_ece'])} | {_f(b.get('cal_ece'))} |")
    L += ['', f"Isotonic fit on the development gaps: {len(res['isotonic_blocks'])} blocks "
          f"(x low, x high, P(boundary)): {res['isotonic_blocks']}.", '']
    return '\n'.join(L)


def seg_main():
    sys.path.insert(0, str(HERE))
    res = seg_analysis(seg_gaps())
    res['item'] = 'W46.ocr-logprob'
    res['key'] = 'fs-seg-2b'
    SEG_JSON.write_text(json.dumps(res, indent=1) + '\n')
    SEG_MD.write_text(seg_report(res))
    print(SEG_MD.read_text())


# --- the Mac readings with log-probabilities ------------------------------------------------------------------

def mac_out(key):
    import ocr_panel as P
    return P.CACHE / 'local' / (key + '-logprob')


def mac_collect(key, limit=None):
    """ocr_mac_local.collect for an HW route, keeping each generated token's log-probability. Resumable."""
    import tempfile
    import mlx.core as mx
    import mlx_vlm
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    import ocr_mac_local as M
    import ocr_panel as P
    spec = M.HW[key]
    prompt = P.PROMPT if spec['prompt'] is None else spec['prompt']
    max_tokens = spec['max_tokens'] or P.MAX_TOKENS
    out = mac_out(key)
    todo = [j for j in M.jobs() if not (out / (j['id'] + '.json')).exists()][: limit or None]
    print(f'{key}: {len(todo)} pages to read', flush=True)
    if not todo:
        return
    os.environ['HF_HUB_OFFLINE'] = '1'
    if not Path(spec['repo'], 'config.json').exists():
        raise SystemExit('weights not in the lab cache: ' + str(spec['repo']))
    mx.set_cache_limit(256 * 2**20)
    t0 = time.time()
    model, processor = load(str(spec['repo']), trust_remote_code=True)
    load_s = time.time() - t0
    chat = apply_chat_template(processor, model.config, prompt, num_images=1, **spec['template'])
    tmp = tempfile.mkdtemp(prefix='mac-logprob-')
    for k, job in enumerate(todo, 1):
        image = P.CACHE / 'images' / (job['id'] + '.jpg')
        if P.digest(image.read_bytes()) != job['sha256']:
            raise SystemExit('image changed: ' + job['id'])
        if spec['max_side']:
            from PIL import Image
            im = Image.open(image); im.thumbnail((spec['max_side'], spec['max_side']), Image.LANCZOS)
            image = Path(tmp) / (job['id'] + '.png'); im.save(image)
        start = time.time(); text = []; lps = []; toks = []; last = None
        for r in stream_generate(model, processor, chat, image=[str(image)], max_tokens=max_tokens, temperature=0.0):
            text.append(r.text); last = r
            if r.token is not None and r.logprobs is not None:
                lp = r.logprobs
                lp = lp.reshape(-1) if hasattr(lp, 'reshape') else lp
                lps.append(round(float(lp[r.token].item() if hasattr(lp[r.token], 'item') else lp[r.token]), 5))
                toks.append(int(r.token))
        wall = time.time() - start
        if spec['max_side']:
            image.unlink()
        raw = ''.join(text)
        got = M.parse(spec, raw)
        finish = 'length' if last is not None and last.generation_tokens >= max_tokens else 'stop'
        meta = {'key': key, 'job': job['id'], 'page': job['page'], 'model': str(spec['repo']).replace(str(Path.home()), '~'),
                'runtime': 'mlx-vlm ' + mlx_vlm.__version__, 'status': 'ok' if got and finish == 'stop' else 'failed',
                'finish': finish, 'wall_s': round(wall, 2), 'completion_tokens': getattr(last, 'generation_tokens', 0),
                'logprob_tokens': len(lps), 't': time.time()}
        P.save(out / (job['id'] + '.raw.json'), {'text': raw, 'logprobs': lps, 'tokens': toks})
        P.save(out / (job['id'] + '.json'), {'meta': meta, 'parsed': got if meta['status'] == 'ok' else None})
        print(f"[{k}/{len(todo)}] {job['id']} {meta['status']} {meta['wall_s']}s {len(lps)} tok "
              f"mean lp {sum(lps) / max(1, len(lps)):.3f}", flush=True)


# --- the OCR report -------------------------------------------------------------------------------------------

CLUSTER = Path(os.environ.get('OCR_LOGPROB_CLUSTER',
                              Path.home() / 'Claude/Long term storage/FarmShare-logprob-20261022/out'))
# route -> (how its reply is read, its pair for the disagreement signal)
CLUSTER_ROUTES = {'lightonocr3-4b': ('native', 'qwen3.5-9b'), 'qwen3.5-9b': ('panel', 'lightonocr3-4b')}
MAC_ROUTES = {'lightonocr-3-4b-mlx8': 'qwen3.5-9b-mlx4', 'qwen3.5-9b-mlx4': 'lightonocr-3-4b-mlx8'}
ESCALATE = 'qwen3.6-27b'            # the escalation route: its cached open-sweep and truth96 readings
ESCALATE_96 = 'qwen3.6-27b-1849739'
OCR_JSON = RESULTS / 'ocr-logprob.json'
OCR_MD = RESULTS / 'ocr-logprob.md'
OCR_PAGES = RESULTS / 'ocr-logprob-pages.csv'
LP_SIGNALS = ('first', 'mean', 'min_k', 'low_share')
SIGNALS = LP_SIGNALS + ('length', 'disagreement', 'failure')
LABELS = {'nes<70': lambda r: not r['ok'] or r['nes'] < 0.70, 'nes<90': lambda r: not r['ok'] or r['nes'] < 0.90,
          'failure': lambda r: not r['ok']}


def risks(page):
    """Each signal as a risk (higher = more likely wrong). An empty reading takes the worst value."""
    f = page.get('features')
    out = {s: (-f[s] if f else 1e9) for s in LP_SIGNALS}
    out['length'] = f['tokens'] if f else 1e9
    out['disagreement'] = -page['agreement'] if page.get('agreement') is not None else 1.0
    out['failure'] = 0 if page['ok'] else 1
    return out


def _score(truth, text, stratum='S0'):
    sys.path.insert(0, str(HERE))
    import ocr_panel_score as S
    return S.score(truth, text, stratum)


def mac_pages(key):
    """The Mac route's 96 accuracy pages: NES as ocr_mac_local.hw_pairs scores them, plus the token features."""
    import ocr_mac_local as M
    import ocr_panel as P
    by_page, out = {r['page']: r for r in P.rows()}, mac_out(key)
    rows = []
    for job in M.jobs():
        if job['page'] in P.AGREEMENT:
            continue
        meta, parsed = M.load_reading(out / (job['id'] + '.json'))
        if not meta:
            return None  # not collected yet
        raw = json.loads((out / (job['id'] + '.raw.json')).read_text())
        text = parsed['text'] if parsed else ''
        truth = (P.TRUTH / 'truth' / (job['page'] + '.txt')).read_text()
        rows.append({'page': job['page'], 'set': '96', 'kind': by_page[job['page']]['kind'], 'ok': bool(parsed),
                     'nes': _score(truth, text)['nes'], 'text': text, 'features': token_features(raw['logprobs'])})
    return rows


def cluster_pages(route):
    """The FarmShare route's 895 (scored as the open sweep's expanded report scores them) and 96, with features."""
    sys.path.insert(0, str(HERE / 'corpus'))
    import farmshare_results as F
    import ocr_panel as P
    import routes as R
    mode = CLUSTER_ROUTES[route][0]
    base = CLUSTER / route
    if not (base / 'public895' / 'summary.json').exists() or not (base / 'truth99' / 'summary.json').exists():
        return None
    R.MANIFEST = RESULTS / 'bench-corpus' / 'manifest.jsonl'
    ref = {R.job_id(r) for r in R.C.read_jsonl(RESULTS / 'bench-corpus' / 'manifest-reference-440.jsonl')}
    rows = []
    recs = F.read_records(base / 'public895')
    for m in R.frozen():
        jid = R.job_id(m); rec = recs.get(jid)
        text = F.reading(rec, mode)
        rows.append({'page': jid, 'set': '440' if jid in ref else '455', 'kind': m['stratum'], 'ok': bool(text),
                     'nes': _score(Path(m['truth']).read_text(), text, m['stratum'])['nes'], 'text': text,
                     'features': token_features([x for x in (rec or {}).get('lp') or [] if x is not None])})
    recs = F.read_records(base / 'truth99')
    by_page = {r['page']: r for r in P.rows()}
    for page in sorted(by_page):
        if page in P.AGREEMENT:
            continue
        rec = recs.get(page); text = F.reading(rec, mode)
        rows.append({'page': page, 'set': '96', 'kind': by_page[page]['kind'], 'ok': bool(text),
                     'nes': _score((P.TRUTH / 'truth' / (page + '.txt')).read_text(), text)['nes'], 'text': text,
                     'features': token_features([x for x in (rec or {}).get('lp') or [] if x is not None])})
    return rows


def escalation_nes():
    """page -> NES of the escalation route: the open sweep's per-page CSV (895) and the truth96 run (96)."""
    import csv
    out = {}
    with open(RESULTS / 'bench-corpus' / 'open-sweep-20261019-pages.csv') as f:
        for r in csv.DictReader(f):
            if r['route'] == ESCALATE:
                out[r['page']] = float(r['nes']) if r['ok'] == 'True' else 0.0
    with open(RESULTS / 'farmshare' / 'truth' / ESCALATE_96 / 'pages.csv') as f:
        for r in csv.DictReader(f):
            out[r['page']] = float(r['nes']) if r['ok'] == 'True' else 0.0
    return out


def add_agreement(rows, pair_rows):
    """Two-reader disagreement: this reading's NES against the other route's text on the same page (0 if either
    failed)."""
    other = {(r['set'], r['page']): r for r in pair_rows or []}
    for r in rows:
        o = other.get((r['set'], r['page']))
        r['agreement'] = None if o is None else (_score(o['text'], r['text'])['nes'] if r['ok'] and o['ok'] else 0.0)


def analyse(rows, esc):
    """AUCs per set and label; isotonic per signal on the 440 (or, for a 96-only route, none); the cascade."""
    by_set = {}
    for r in rows:
        r['risk'] = risks(r)
        by_set.setdefault(r['set'], []).append(r)
    res = {'sets': {s: {'pages': len(rr), 'ok': sum(r['ok'] for r in rr),
                        'nes': sum(r['nes'] for r in rr) / len(rr),
                        **{f'errors {k}': sum(1 for r in rr if f(r)) for k, f in LABELS.items()}}
                    for s, rr in by_set.items()},
           'auc': {s: {k: {sig: auc([r['risk'][sig] for r in rr], [f(r) for r in rr]) for sig in SIGNALS}
                       for k, f in LABELS.items()} for s, rr in by_set.items()}}
    if '440' not in by_set or '96' not in by_set or '455' not in by_set:
        return res
    y = LABELS['nes<70']
    cal, casc = {}, {}
    for sig in SIGNALS:
        fit = isotonic_fit([r['risk'][sig] for r in by_set['440']], [1 if y(r) else 0 for r in by_set['440']])
        prob = {s: [isotonic_predict(fit, r['risk'][sig]) for r in rr] for s, rr in by_set.items()}
        cal[sig] = {s: {'brier': brier(prob[s], [1 if y(r) else 0 for r in by_set[s]]),
                        'ece': ece(prob[s], [1 if y(r) else 0 for r in by_set[s]])} for s in ('455', '96')}
        have = {s: [i for i, r in enumerate(by_set[s]) if r['page'] in esc] for s in ('96', '455')}
        p96 = [prob['96'][i] for i in have['96']]
        f96 = [by_set['96'][i]['nes'] for i in have['96']]; e96 = [esc[by_set['96'][i]['page']] for i in have['96']]
        t, share, nes, all_nes = cascade_threshold(p96, f96, e96)
        p455 = [prob['455'][i] for i in have['455']]
        f455 = [by_set['455'][i]['nes'] for i in have['455']]; e455 = [esc[by_set['455'][i]['page']] for i in have['455']]
        test = apply_threshold(t, p455, f455, e455)
        escd = [i for i, p in zip(have['455'], p455) if p >= t]
        inv = None
        if escd:
            inv = {'pages': len(escd), 'mean_calibrated_p': sum(prob['455'][i] for i in escd) / len(escd),
                   'observed_error_rate': sum(1 for i in escd if y(by_set['455'][i])) / len(escd),
                   'escalation_nes_on_escalated': sum(esc[by_set['455'][i]['page']] for i in escd) / len(escd),
                   'escalation_nes_overall': sum(e455) / len(e455),
                   'first_nes_on_escalated': sum(by_set['455'][i]['nes'] for i in escd) / len(escd)}
        r455 = [by_set['455'][i]['risk'][sig] for i in have['455']]
        test['nes_at_20pct'] = budget_nes(r455, f455, e455)
        test['oracle_at_20pct'] = budget_nes([e - f for f, e in zip(f455, e455)], f455, e455)
        casc[sig] = {'threshold': t, 'tune_96': {'share': share, 'nes': nes, 'all_nes': all_nes,
                                                 'first_nes': sum(f96) / len(f96), 'pages': len(p96)},
                     'test_455': {**test, 'pages': len(p455)}, 'invariance_455': inv}
    res.update(calibration=cal, cascade=casc)
    return res


def ocr_report():
    import csv
    sys.path.insert(0, str(HERE))
    out = {'item': 'W46.ocr-logprob', 'escalation_route': ESCALATE, 'routes': {}}
    esc = escalation_nes()
    page_rows = []
    for routes, loader, where in ((MAC_ROUTES, mac_pages, 'Mac mlx-vlm'), (CLUSTER_ROUTES, cluster_pages, 'FarmShare vLLM')):
        got = {k: loader(k) for k in routes}
        for k, rows in got.items():
            if rows is None:
                out['routes'][k] = {'where': where, 'status': 'not collected'}
                continue
            pair = routes[k][1] if isinstance(routes[k], tuple) else routes[k]
            add_agreement(rows, got.get(pair))
            out['routes'][k] = {'where': where, **analyse(rows, esc)}
            for r in rows:
                page_rows.append({'route': k, 'set': r['set'], 'page': r['page'], 'kind': r['kind'], 'ok': r['ok'],
                                  'nes': round(r['nes'], 6),
                                  **{s: (round(r['features'][s], 5) if r['features'] else '') for s in LP_SIGNALS},
                                  'tokens': r['features']['tokens'] if r['features'] else 0,
                                  'agreement': '' if r.get('agreement') is None else round(r['agreement'], 6)})
    OCR_JSON.write_text(json.dumps(out, indent=1) + '\n')
    with open(OCR_PAGES, 'w', newline='') as f:
        w = csv.DictWriter(f, ['route', 'set', 'page', 'kind', 'ok', 'nes', *LP_SIGNALS, 'tokens', 'agreement'])
        w.writeheader(); w.writerows(page_rows)
    OCR_MD.write_text(render(out))
    print(OCR_MD.read_text())


def render(out):
    L = ['# W46.ocr-logprob — whether a local route\'s log-probabilities rank its errors', '',
         'Generated by `scripts/segbench/ocr_logprob.py report` (the method is its docstring). Per-page figures, '
         'no text: `ocr-logprob-pages.csv`. No money. The seg 2B\'s P(new) is in `ocr-logprob-seg.md`.', '',
         'Signals are risks (higher = more likely wrong): first = first-token log-probability, mean = mean token '
         'log-probability, min_k = mean of the lowest 10%, low_share = share of tokens under p 0.5 (all negated); '
         'length = output tokens; disagreement = this reading\'s NES against the other route\'s reading; failure = '
         'a cap or an error only.', '']
    for k, r in out['routes'].items():
        L += [f'## {k} ({r["where"]})', '']
        if r.get('status'):
            L += ['Not collected yet.', '']
            continue
        L += ['| set | pages | answered | NES | errors NES<70 | errors NES<90 | failures |', '|---|---:|---:|---:|---:|---:|---:|']
        for s, d in sorted(r['sets'].items()):
            L.append(f"| {s} | {d['pages']} | {d['ok']} | {100 * d['nes']:.2f} | {d['errors nes<70']} | "
                     f"{d['errors nes<90']} | {d['errors failure']} |")
        L += ['', 'AUC of each signal against each kind of error (0.5 = no ranking):', '',
              '| set | error | ' + ' | '.join(SIGNALS) + ' |', '|---|---|' + '---:|' * len(SIGNALS)]
        for s, by in sorted(r['auc'].items()):
            for lab, a in by.items():
                L.append(f'| {s} | {lab} | ' + ' | '.join(_f(a[sig]) for sig in SIGNALS) + ' |')
        if 'cascade' in r:
            L += ['', f"Isotonic calibration of P(NES<70) on the 440; the escalation threshold chosen on the 96 "
                  f"(within half a point of escalating every page to {out['escalation_route']}), applied once to the 455:", '',
                  '| signal | ECE 455 | ECE 96 | 96: escalated | 96: cascade NES | 455: escalated | 455: cascade NES | '
                  '455: first alone | 455: escalate all | 455: NES, riskiest 20% escalated | oracle 20% |',
                  '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|']
            for sig in SIGNALS:
                c, k2 = r['cascade'][sig], r['calibration'][sig]
                L.append(f"| {sig} | {_f(k2['455']['ece'])} | {_f(k2['96']['ece'])} | {_f(c['tune_96']['share'], True)} | "
                         f"{100 * c['tune_96']['nes']:.2f} | {_f(c['test_455']['share'], True)} | {100 * c['test_455']['nes']:.2f} | "
                         f"{100 * c['test_455']['first_nes']:.2f} | {100 * c['test_455']['all_nes']:.2f} | "
                         f"{100 * c['test_455']['nes_at_20pct']:.2f} | {100 * c['test_455']['oracle_at_20pct']:.2f} |")
            L += ['', 'Invariance check on the 455\'s escalated pages (UCCI assumes the calibrated probability holds '
                  'there, and the escalation route reads them as well as it reads the rest):', '',
                  '| signal | escalated | mean calibrated P | observed error rate | first route NES there | '
                  'escalation NES there | escalation NES overall |', '|---|---:|---:|---:|---:|---:|---:|']
            for sig in SIGNALS:
                v = r['cascade'][sig]['invariance_455']
                if v:
                    L.append(f"| {sig} | {v['pages']} | {_f(v['mean_calibrated_p'])} | {_f(v['observed_error_rate'])} | "
                             f"{100 * v['first_nes_on_escalated']:.2f} | {100 * v['escalation_nes_on_escalated']:.2f} | "
                             f"{100 * v['escalation_nes_overall']:.2f} |")
        L.append('')
    return '\n'.join(L)


# --- self-test ------------------------------------------------------------------------------------------------

def self_test():
    assert auc([1, 2, 3, 4], [0, 0, 1, 1]) == 1.0
    assert auc([4, 3, 2, 1], [0, 0, 1, 1]) == 0.0
    assert auc([1, 1, 1, 1], [0, 1, 0, 1]) == 0.5
    assert abs(auc([1, 2, 2, 3], [0, 0, 1, 1]) - 0.875) < 1e-9
    assert auc([1, 2], [1, 1]) is None
    fit = isotonic_fit([1, 2, 3, 4], [0, 1, 0, 1])
    vals = [v for _, _, v in fit]
    assert vals == sorted(vals) and vals == [0.0, 0.5, 1.0], fit
    assert isotonic_predict(fit, 0) == 0.0 and isotonic_predict(fit, 9) == 1.0
    assert isotonic_predict(fit, 2.5) == 0.5
    f2 = isotonic_fit([0, 0, 1, 1], [0, 1, 1, 1])
    assert [v for _, _, v in f2] == [0.5, 1.0]
    assert isotonic_predict([(0, 0, 0.0), (2, 2, 1.0)], 1) == 0.5
    assert brier([0.0, 1.0], [0, 1]) == 0.0
    assert caught([0.9, 0.1, 0.8, 0.2], [0, 1, 0, 0], 0.25) == 1.0
    assert abs(ece([0.2, 0.2, 0.8, 0.8], [0, 1, 1, 1]) - 0.25) < 1e-9
    tf = token_features([-0.01] * 9 + [-2.0])
    assert tf['tokens'] == 10 and tf['min_k'] == -2.0 and tf['low_share'] == -0.1 and tf['first'] == -0.01
    # cascade: page 0 is bad for the first reader and fixed by escalation; the cheapest threshold escalates it alone
    t, share, nes, all_nes = cascade_threshold([0.9, 0.1, 0.2], [0.2, 0.95, 0.9], [0.9, 0.95, 0.9])
    assert share == 1 / 3 and abs(nes - all_nes) < 1e-9 and t == 0.9, (t, share, nes)
    assert budget_nes([3, 1, 2, 0, 0], [0.1, 0.9, 0.5, 0.9, 0.9], [0.9] * 5) == (0.9 + 0.9 + 0.5 + 0.9 + 0.9) / 5
    r = apply_threshold(0.5, [0.9, 0.1], [0.2, 0.9], [0.8, 0.9])
    assert r['share'] == 0.5 and abs(r['nes'] - 0.85) < 1e-9
    # analyse(): a signal that ranks perfectly gets AUC 1 and a cascade that escalates exactly the bad pages
    def pg(i, s, bad):
        lp = [-3.0] * 5 if bad else [-0.01] * 5
        return {'page': f'{s}{i}', 'set': s, 'kind': 'x', 'ok': True, 'nes': 0.5 if bad else 0.95, 'text': '',
                'features': token_features(lp), 'agreement': 0.4 if bad else 0.97}
    rows = [pg(i, s, i % 4 == 0) for s in ('440', '455', '96') for i in range(40)]
    esc = {r['page']: 0.9 for r in rows}
    res = analyse(rows, esc)
    assert res['auc']['455']['nes<70']['mean'] == 1.0 and res['auc']['455']['nes<70']['failure'] == 0.5
    c = res['cascade']['mean']
    assert c['tune_96']['share'] == 0.25 and c['test_455']['share'] == 0.25, c
    assert c['invariance_455']['observed_error_rate'] == 1.0
    # the cluster collector's request and its reading of a vLLM stream chunk
    sys.path.insert(0, str(HERE / 'corpus'))
    import logprob_cluster as LC
    b = LC.body('', b'x', 'm')
    assert b['logprobs'] is True and b['top_logprobs'] == 0 and b['temperature'] == 0 and b['max_tokens'] == 8192
    assert len(b['messages'][0]['content']) == 1  # an empty prompt sends the image alone
    chunk = {'delta': {'content': 'ab'}, 'logprobs': {'content': [{'token': 'a', 'logprob': -0.1, 'bytes': [97],
                                                                   'top_logprobs': []}, {'token': 'b', 'logprob': 0.0}]}}
    assert LC.chunk_logprobs(chunk) == [('a', -0.1), ('b', 0.0)] and LC.chunk_logprobs({'delta': {}}) == []
    print('self-test ok')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['mac-collect', 'seg', 'report', 'self-test'])
    ap.add_argument('--model', choices=MAC_KEYS)
    ap.add_argument('--limit', type=int)
    a = ap.parse_args()
    sys.path.insert(0, str(HERE))
    if a.command == 'self-test':
        self_test()
    elif a.command == 'seg':
        seg_main()
    elif a.command == 'report':
        ocr_report()
    else:
        if not a.model:
            ap.error('mac-collect needs --model')
        mac_collect(a.model, a.limit)


if __name__ == '__main__':
    main()
