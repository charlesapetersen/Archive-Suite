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
    r = apply_threshold(0.5, [0.9, 0.1], [0.2, 0.9], [0.8, 0.9])
    assert r['share'] == 0.5 and abs(r['nes'] - 0.85) < 1e-9
    print('self-test ok')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['mac-collect', 'seg', 'self-test'])
    ap.add_argument('--model', choices=MAC_KEYS)
    ap.add_argument('--limit', type=int)
    a = ap.parse_args()
    sys.path.insert(0, str(HERE))
    if a.command == 'self-test':
        self_test()
    elif a.command == 'seg':
        seg_main()
    else:
        if not a.model:
            ap.error('mac-collect needs --model')
        mac_collect(a.model, a.limit)


if __name__ == '__main__':
    main()
