#!/usr/bin/env python3
"""W46.kind-atrium. ATRIUM's page classifier against the Processor's page-kind classifier (10-gap-audit.md §5 item
26, K test 1; measurement audit KND-1 and KND-2).

  PYTHONPATH=<cache>/atrium-pylib heavy-run.py run -- <torch-env python> kind_atrium.py run
                                             # ATRIUM zero-shot on the 144, the 895 and the 2,000: probabilities,
                                             # pooled embeddings, seconds and memory -> CACHE
  heavy-run.py run -- /usr/local/bin/python3 kind_atrium.py signals
                                             # kind-signals (Vision) over the 895, for the regression's labels
  /usr/local/bin/python3 kind_atrium.py report   # -> segbench-results/kind-atrium.md / .json

ATRIUM is ufal/vit-historical-page main (v4.3, RegNetY-16GF, eleven classes; base weights CC BY-NC, measurement
only), with mixed_def.py's loader and its preprocessing (whole page squeezed to 384 px, ImageNet mean and std, the
reading W46.fix-marks-set's check chose). Its classes are read as ours:
  hand   TEXT_T / LINE_T typewritten, TEXT_P / LINE_P printed, TEXT_HW / LINE_HW handwritten, TEXT mixed (its "text
         of more than one kind"), DRAW / DRAW_L / PHOTO / PHOTO_L no hand. "hand-only" is the argmax over the six
         TEXT_* / LINE_* classes, the forced three-way reading a router would use.
  forms  LINE_* (its "text in a table or form").
The pages:
  the 144    kind_classifier.py's labelled originals (the ladder's copies left out). Per KND-1, partly labelled by a
             session looking at contact sheets, not blind; and the 3 mixed pages use the old definition, so the hand
             is scored on the 141 typed, printed and handwritten pages only.
  the 96     the truth set's originals with NES for every guide pick (a subset of the 144): hand and what routing
             by each classifier costs in NES.
  the 895    the frozen public set; kind truth is the stratum's (bench-corpus/sample/draw.jsonl `kind`): typed ->
             typewritten, print and newspaper -> printed, handwritten -> handwritten, ledger (L4) -> handwritten
             and a form. Public datasets, so no reader of ours drew the truth.
  the 2,000  the bulk-pilot pages (mixed_def.py); mixed is scored against the owner's 170 sheet answers under his
             cut (any handwriting on a typed or printed page, a signature included; mixed-def-score.md), not
             against any model.
A small head: a logistic regression on ATRIUM's 3,024-dimension pooled embedding, fitted leave-one-folder-out on
the 141 (hand) and the 144 (forms), beside the shipped classifier's own features fitted the same way.

Images and per-page labels stay in the private cache; segbench-results carries aggregates only. Read-only
throughout: the 144's images are read where kind_classifier's labels point (15 of them in the JPEG originals folder);
nothing outside CACHE and segbench-results is written. No money.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import random
import resource
import subprocess
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import mixed_def as MD          # noqa: E402  ATRIUM's loader, the 2,000's labels and the owner's sheet
import kind_classifier as KC    # noqa: E402  the 144's labels, signals and the LOFO regression

RESULTS = HERE.parents[1] / 'segbench-results'
REHEARSAL = MD.REHEARSAL
CACHE = Path(os.environ.get('KIND_ATRIUM_CACHE', REHEARSAL / 'kind-atrium'))
PUBLIC = REHEARSAL / 'bench-corpus/sample/draw.jsonl'
REPORT = RESULTS / 'kind-atrium.md'
PREP = 'imagenet-384'
SETS = ('k144', 'public', 'bulk')
CLASSES = MD.ATRIUM_CLASSES
HAND_OF = {'TEXT_T': 'typewritten', 'LINE_T': 'typewritten', 'TEXT_P': 'printed', 'LINE_P': 'printed',
           'TEXT_HW': 'handwritten', 'LINE_HW': 'handwritten', 'TEXT': 'mixed'}
HAND6 = [CLASSES.index(c) for c in ('LINE_HW', 'LINE_P', 'LINE_T', 'TEXT_HW', 'TEXT_P', 'TEXT_T')]
KINDS3 = KC.KINDS3
PUBLIC_HAND = {'typed': 'typewritten', 'print': 'printed', 'newspaper': 'printed', 'handwritten': 'handwritten',
               'ledger': 'handwritten'}
AGREEMENT_ONLY = ('p086', 'p094', 'p096')   # ocr_panel_score: shown apart, not among the 96
SEED = 26


def hand_argmax(label):
    return HAND_OF.get(label, 'none')


def hand_only(p):
    """The forced three-way reading: the most likely of the six TEXT_* / LINE_* classes."""
    k = max(HAND6, key=lambda j: p[j])
    return HAND_OF[CLASSES[k]], CLASSES[k].startswith('LINE')


# ---- the pages ------------------------------------------------------------------------------------------------------

def k144_rows():
    return [r for r in KC.read_tsv(KC.CACHE / 'labels.tsv') if not r['set'].startswith('ladder')]


def public_rows():
    return [json.loads(l) for l in open(PUBLIC)]


def page_files(name):
    if name == 'k144':
        return [(r['id'], Path(r['file'])) for r in k144_rows()]
    if name == 'public':
        return [(r['page_id'], Path(r['image'])) for r in public_rows()]
    return [(f.stem, f) for f in MD.page_list()]


# ---- run: ATRIUM over the pages -------------------------------------------------------------------------------------

def run(sets):
    import numpy as np
    import torch
    from PIL import Image
    CACHE.mkdir(parents=True, exist_ok=True)
    t = time.time()
    model, dev = MD.atrium_model()
    load_s = time.time() - t
    *ms, side = MD.ATRIUM_PREP[PREP]
    mean, std = (np.array(v, dtype=np.float32).reshape(3, 1, 1) for v in ms)
    info = json.loads((CACHE / 'run.json').read_text()) if (CACHE / 'run.json').exists() else {}
    info.update({'device': dev, 'prep': PREP, 'revision': MD.ATRIUM_REV, 'load_s': round(load_s, 1),
                 'torch': torch.__version__})
    for name in sets:
        files = page_files(name)
        ids, probs, embs, batch_s, decode_s = [], [], [], [], 0.0
        t0 = time.time()
        for i in range(0, len(files), 16):
            chunk = files[i:i + 16]
            td = time.time()
            x = []
            for _, f in chunk:   # as mixed_def.atrium_run: the whole page squeezed to a square, bicubic
                im = Image.open(f).convert('RGB').resize((side, side), Image.BICUBIC)
                x.append((np.asarray(im, dtype=np.float32).transpose(2, 0, 1) / 255 - mean) / std)
            decode_s += time.time() - td
            tb = time.time()
            with torch.no_grad():
                feat = model.forward_head(model.forward_features(torch.from_numpy(np.stack(x)).to(dev)), pre_logits=True)
                p = torch.softmax(model.get_classifier()(feat), 1).cpu().numpy()
                e = feat.cpu().numpy()
            batch_s.append((time.time() - tb) / len(chunk))
            ids += [pid for pid, _ in chunk]
            probs.append(p); embs.append(e)
        secs = time.time() - t0
        np.savez_compressed(CACHE / f'{name}.npz', ids=np.array(ids), probs=np.concatenate(probs),
                            emb=np.concatenate(embs).astype(np.float32))
        info[name] = {'pages': len(ids), 'seconds': round(secs, 1), 's_page': round(secs / len(ids), 4),
                      'model_s_page_median': round(float(np.median(batch_s)), 4),
                      'decode_s_page': round(decode_s / len(ids), 4)}
        print(f'{name}: {len(ids)} pages in {secs:.0f} s on {dev}', file=sys.stderr)
    info['peak_rss_gb'] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**30, 2)
    if dev == 'mps':
        info['mps_driver_gb'] = round(torch.mps.driver_allocated_memory() / 2**30, 2)
    (CACHE / 'run.json').write_text(json.dumps(info, indent=1))


def signals():
    """kind-signals over the 895, so the shipped regression can label them (the 144 and the 2,000 have theirs)."""
    tool = Path('/tmp/kind-signals')
    src = HERE / 'kind_signals/kind-signals.swift'
    if not tool.exists() or src.stat().st_mtime > tool.stat().st_mtime:
        subprocess.run(['swiftc', '-O', '-o', str(tool), '-target', 'arm64-apple-macos26.0', str(src)], check=True)
    CACHE.mkdir(parents=True, exist_ok=True)
    lst = CACHE / 'public-signals-list.tsv'
    lst.write_text(''.join(f'{pid}\t{f}\n' for pid, f in page_files('public')))
    t = time.time()
    with open(CACHE / 'public-signals.tsv', 'w') as out:
        subprocess.run([str(tool), str(lst), str(CACHE / 'public-featureprints.tsv')], stdout=out, check=True)
    info = json.loads((CACHE / 'run.json').read_text()) if (CACHE / 'run.json').exists() else {}
    info['public_signals_s'] = round(time.time() - t, 1)
    (CACHE / 'run.json').write_text(json.dumps(info, indent=1))


# ---- report helpers -------------------------------------------------------------------------------------------------

def load(name):
    import numpy as np
    z = np.load(CACHE / f'{name}.npz')
    ids = [str(x) for x in z['ids']]
    return ids, z['probs'], z['emb']


def prints_of(path):
    out = {}
    for line in open(path):
        pid, _, v = line.rstrip('\n').partition('\t')
        out[pid] = [float(x) for x in v.split(',')]
    return out


def wilson(k, n, z=1.96):
    if not n:
        return (float('nan'), float('nan'))
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (c - h, c + h)


def frac(k, n):
    lo, hi = wilson(k, n)
    return f'{k}/{n} ({100 * lo:.0f}–{100 * hi:.0f}%)'


def mcnemar(a, b):
    """Exact two-sided McNemar p on paired right/wrong lists."""
    x = sum(1 for i, j in zip(a, b) if i and not j)
    y = sum(1 for i, j in zip(a, b) if j and not i)
    n = x + y
    if not n:
        return x, y, 1.0
    k = min(x, y)
    p = sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n * 2
    return x, y, min(1.0, p)


def auc(scores, truth):
    pos = [s for s, t in zip(scores, truth) if t]
    neg = [s for s, t in zip(scores, truth) if not t]
    if not pos or not neg:
        return float('nan')
    return sum((p > q) + 0.5 * (p == q) for p in pos for q in neg) / (len(pos) * len(neg))


def lofo(X, y, k, groups, lam=0.05):
    return KC.loo_lr(X, y, k, groups, lam)


def fit_all(X, y, k, lam=0.05):
    import numpy as np
    mu, sd = X.mean(0), X.std(0) + 1e-6
    W, b = KC.lr_fit((X - mu) / sd, y, k, lam)
    return lambda Z: np.argmax(((Z - mu) / sd) @ W + b, axis=1)


# ---- report ---------------------------------------------------------------------------------------------------------

def report():
    import numpy as np
    run_info = json.loads((CACHE / 'run.json').read_text())
    J = {'run': run_info}
    L = []

    # ---- the 144: zero-shot hand and forms, and the heads -------------------------------------------------------
    lab = k144_rows()
    ids, P, E = load('k144')
    ix = {p: i for i, p in enumerate(ids)}
    assert [r['id'] for r in lab] == ids, 'the 144 changed since run'
    sig = {r['id']: r for r in KC.read_tsv(KC.CACHE / 'signals.tsv')}
    fp = prints_of(KC.CACHE / 'featureprints.tsv')
    scal = ['harmonic', 'periodic', 'conf', 'text_px', 'lines']

    def ours(pid):
        x = [KC.num(sig[pid][c]) for c in scal]
        return np.array([0.0 if v != v else v for v in x] + fp[pid])
    three = [i for i, r in enumerate(lab) if r['hand'] in KINDS3]     # the 141
    truth = [lab[i]['hand'] for i in three]
    folders = [lab[i]['group'] for i in three]
    y3 = np.array([KINDS3.index(h) for h in truth])
    atr_arg = [hand_argmax(CLASSES[int(P[i].argmax())]) for i in three]
    atr_h6 = [hand_only(P[i])[0] for i in three]
    X_our = np.array([ours(lab[i]['id']) for i in three])
    X_atr = E[three]
    heads = {'ours': [KINDS3[k] for k in lofo(X_our, y3, 3, folders)],
             'atrium-head': [KINDS3[k] for k in lofo(X_atr, y3, 3, folders)],
             'both': [KINDS3[k] for k in lofo(np.hstack([X_our, X_atr]), y3, 3, folders)]}
    rows = {'ATRIUM zero-shot, its top class': atr_arg,
            'ATRIUM zero-shot, hand-only (top of its six text classes)': atr_h6,
            'Shipped classifier: Vision signals + feature print, LR (leave-one-folder-out)': heads['ours'],
            'ATRIUM embedding + LR head (leave-one-folder-out)': heads['atrium-head'],
            'Both feature sets + LR head (leave-one-folder-out)': heads['both']}
    J['k144_hand'] = []
    L.append('# ATRIUM\'s page classifier against our kind classifier (W46.kind-atrium)\n')
    L.append(f'Measured {time.strftime("%Y-%m-%d")} with `scripts/segbench/kind_atrium.py` (header: how to rerun). '
             'ATRIUM is `ufal/vit-historical-page` main (v4.3, RegNetY-16GF, eleven classes, revision '
             f'`{MD.ATRIUM_REV[:12]}`), zero-shot, the whole page squeezed to 384 px with ImageNet normalisation '
             '(the reading W46.fix-marks-set chose on the 144). "Ours" is the Processor\'s page-kind classifier '
             '(`kind-classifier.md`): Vision signals and the Vision feature print with a logistic regression. '
             'Page images and per-page labels stay in the private cache. No money.\n')
    L.append('## 1. The hand on the 144 owner-set pages\n')
    L.append(f'The 141 typed, printed and handwritten pages of the 144 (the 3 mixed pages are left out: they use the '
             'old mixed definition, KND-2). These labels were partly made by a session looking at contact sheets, '
             'not blind (KND-1), and the shipped weights were fitted on them; the learned rows are scored leave-one-'
             'folder-out. Interval: Wilson 95%.\n')
    L.append('| method | right | handwritten | typewritten | printed | said mixed | said no hand |\n'
             '|---|---:|---:|---:|---:|---:|---:|')
    right = {}
    for name, pred in rows.items():
        ok = [p == t for p, t in zip(pred, truth)]
        right[name] = ok
        per = {h: f'{sum(o for o, t in zip(ok, truth) if t == h)}/{truth.count(h)}' for h in KINDS3}
        L.append(f'| {name} | {frac(sum(ok), len(ok))} | {per["handwritten"]} | {per["typewritten"]} | '
                 f'{per["printed"]} | {pred.count("mixed")} | {pred.count("none")} |')
        J['k144_hand'].append({'method': name, 'right': sum(ok), 'n': len(ok), 'mixed': pred.count('mixed'),
                               'none': pred.count('none'), **{h: per[h] for h in KINDS3}})
    a, b, p = mcnemar(right['ATRIUM zero-shot, hand-only (top of its six text classes)'],
                      right['Shipped classifier: Vision signals + feature print, LR (leave-one-folder-out)'])
    a2, b2, p2 = mcnemar(right['ATRIUM embedding + LR head (leave-one-folder-out)'],
                         right['Shipped classifier: Vision signals + feature print, LR (leave-one-folder-out)'])
    J['k144_paired'] = {'hand_only_vs_ours': [a, b, round(p, 4)], 'head_vs_ours': [a2, b2, round(p2, 4)]}
    L.append(f'\nPaired against ours (exact McNemar): hand-only ATRIUM right where ours is wrong on {a} pages, the '
             f'reverse on {b} (p {p:.3g}); the ATRIUM head {a2} against {b2} (p {p2:.3g}).\n')
    L.append('Hand-only ATRIUM\'s confusions:\n')
    L.append(KC.confusion(truth, atr_h6, list(KINDS3)) + '\n')
    zs = Counter(CLASSES[int(P[i].argmax())] for i in three)
    L.append('ATRIUM\'s top class on the 141: ' + ', '.join(f'{c} {n}' for c, n in zs.most_common()) + '.\n')

    # forms
    form_t = [r['form'] == 'yes' for r in lab]
    yF = np.array([int(f) for f in form_t])
    allf = [r['group'] for r in lab]
    f_arg = [CLASSES[int(P[i].argmax())].startswith('LINE') for i in range(len(lab))]
    f_h6 = [hand_only(P[i])[1] for i in range(len(lab))]
    X_our_all = np.array([ours(r['id']) for r in lab])
    f_rows = {'ATRIUM zero-shot, top class LINE_*': f_arg,
              'ATRIUM zero-shot, hand-only top class LINE_*': f_h6,
              'Shipped classifier, LR (leave-one-folder-out)': [bool(k) for k in lofo(X_our_all, yF, 2, allf)],
              'ATRIUM embedding + LR head (leave-one-folder-out)': [bool(k) for k in lofo(E, yF, 2, allf)]}
    L.append('## 2. Forms and tables on the 144\n')
    L.append(f'{sum(form_t)} of the 144 are mainly a table or a form. ATRIUM\'s LINE_* classes are its "text in a '
             'table or form".\n')
    L.append('| method | right | forms found | false calls |\n|---|---:|---:|---:|')
    J['k144_forms'] = []
    for name, pred in f_rows.items():
        ok = sum(p == t for p, t in zip(pred, form_t))
        found = sum(p and t for p, t in zip(pred, form_t))
        false = sum(p and not t for p, t in zip(pred, form_t))
        L.append(f'| {name} | {ok}/{len(lab)} | {found}/{sum(form_t)} | {false} |')
        J['k144_forms'].append({'method': name, 'right': ok, 'found': found, 'forms': sum(form_t), 'false': false})

    # ---- the 96: routing cost -----------------------------------------------------------------------------------
    guide = {k['id']: k['picks'][0]['source']['route'] for k in json.load(open(KC.GUIDE))['kinds']}
    nes = {}
    for r in csv.DictReader(open(KC.PAGES)):
        nes[(r['route'], r['page'])] = KC.num(r['nes']) if r['ok'] == 'True' else 0.0

    def route(hand, form):
        if form:
            return guide['forms']
        return guide.get(hand, guide['handwritten']) if hand in KINDS3 else guide['handwritten']
    acc = [i for i, r in enumerate(lab) if r['set'] == 'truth' and r['id'] not in AGREEMENT_ONLY
           and all((rt, r['id']) in nes for rt in set(guide.values()))]
    of3 = {i: j for j, i in enumerate(three)}
    lofo_hand = {k: {three[j]: v for j, v in enumerate(heads[k])} for k in heads}
    f_lofo = {'ours': f_rows['Shipped classifier, LR (leave-one-folder-out)'],
              'atrium-head': f_rows['ATRIUM embedding + LR head (leave-one-folder-out)']}
    hl = {i: lab[i]['hand'] for i in acc}
    combos = {'Labels for hand and form': (lambda i: hl[i], lambda i: form_t[i]),
              'Shipped classifier (hand and form LR, leave-one-folder-out)':
                  (lambda i: lofo_hand['ours'].get(i, 'handwritten'), lambda i: f_lofo['ours'][i]),
              'ATRIUM zero-shot hand-only, LINE_* for form': (lambda i: hand_only(P[i])[0], lambda i: f_h6[i]),
              'ATRIUM zero-shot top class (mixed or no hand to the handwritten pick)':
                  (lambda i: hand_argmax(CLASSES[int(P[i].argmax())]), lambda i: f_arg[i]),
              'ATRIUM embedding heads (leave-one-folder-out)':
                  (lambda i: lofo_hand['atrium-head'].get(i, 'handwritten'), lambda i: f_lofo['atrium-head'][i])}
    oracle = [nes[(route(hl[i], form_t[i]), lab[i]['id'])] for i in acc]
    L.append(f'## 3. The 96: the hand, and what routing by each costs\n')
    L.append(f'The guide\'s first pick per kind ({", ".join(f"{k} → {v}" for k, v in guide.items() if k != "low-resolution")}; '
             f'no low-resolution flag, as the shipped classifier), on the {len(acc)} truth pages. "Lost" is mean NES '
             'below routing by the labels; the interval is a paired bootstrap over pages (2,000 draws). A mixed '
             'page in the labels (2) goes to the handwritten pick, as the shipped classifier sends it.\n')
    L.append('| classifier | hand right | routed as labelled | mean NES | lost | 95% interval |\n'
             '|---|---:|---:|---:|---:|---:|')
    rng = random.Random(SEED)
    J['routing_96'] = []
    for name, (hf, ff) in combos.items():
        got = [nes[(route(hf(i), ff(i)), lab[i]['id'])] for i in acc]
        same = sum(route(hf(i), ff(i)) == route(hl[i], form_t[i]) for i in acc)
        hand_ok = sum(hf(i) == hl[i] for i in acc)
        loss = [o - g for o, g in zip(oracle, got)]
        boots = sorted(sum(loss[rng.randrange(len(loss))] for _ in loss) / len(loss) for _ in range(2000))
        lo, hi = boots[49] * 100, boots[1949] * 100
        L.append(f'| {name} | {hand_ok}/{len(acc)} | {same}/{len(acc)} | {100 * np.mean(got):.2f} | '
                 f'{100 * np.mean(loss):+.2f} | {lo:+.2f} to {hi:+.2f} |')
        J['routing_96'].append({'classifier': name, 'hand_right': hand_ok, 'as_labelled': same, 'n': len(acc),
                                'mean_nes': round(100 * float(np.mean(got)), 2), 'lost': round(100 * float(np.mean(loss)), 2),
                                'lost_ci': [round(lo, 2), round(hi, 2)]})

    # ---- the 895 ------------------------------------------------------------------------------------------------
    pub = public_rows()
    pids, PP, PE = load('public')
    assert pids == [r['page_id'] for r in pub], 'the 895 changed since run'
    pt = [PUBLIC_HAND[r['kind']] for r in pub]
    pform = [r['kind'] == 'ledger' for r in pub]
    p_arg = [hand_argmax(CLASSES[int(q.argmax())]) for q in PP]
    p_h6 = [hand_only(q)[0] for q in PP]
    p_line = [hand_only(q)[1] for q in PP]
    predict_head = fit_all(X_atr, y3, 3)
    p_head = [KINDS3[k] for k in predict_head(PE)]
    pub_rows = {'ATRIUM zero-shot, its top class': p_arg, 'ATRIUM zero-shot, hand-only': p_h6,
                'ATRIUM embedding + LR head fitted on the 141': p_head}
    sig_p = CACHE / 'public-signals.tsv'
    if sig_p.exists():
        psig = {r['id']: r for r in MD.read_csv(sig_p, '\t')}
        reg = MD.regression_labels(psig, prints_of(CACHE / 'public-featureprints.tsv'),
                                   json.loads(MD.MODEL_JSON.read_text()))
        pub_rows['Shipped classifier (bundled weights)'] = [reg.get(p, {}).get('label', 'none') for p in pids]
    L.append('## 4. The 895 public pages\n')
    L.append('Kind truth is the stratum\'s: each public set is one kind (typed L3; printed L8, L9 newspapers, N5, N6; '
             'handwritten the rest, the L4 ledgers counted as handwritten forms). Nothing here was fitted on these '
             'pages: the head and the shipped weights were fitted on the owner\'s 144. Non-Latin scripts (N1–N6) are '
             'outside what either was fitted on.\n')
    L.append('| method | right | handwritten (' + str(pt.count('handwritten')) + ') | typewritten (' +
             str(pt.count('typewritten')) + ') | printed (' + str(pt.count('printed')) + ') | said mixed | said no hand |\n'
             '|---|---:|---:|---:|---:|---:|---:|')
    J['public_hand'] = []
    pub_ok = {}
    for name, pred in pub_rows.items():
        ok = [p == t for p, t in zip(pred, pt)]
        pub_ok[name] = ok
        per = {h: sum(o for o, t in zip(ok, pt) if t == h) for h in KINDS3}
        L.append(f'| {name} | {frac(sum(ok), len(ok))} | {per["handwritten"]} | {per["typewritten"]} | '
                 f'{per["printed"]} | {pred.count("mixed")} | {pred.count("none")} |')
        J['public_hand'].append({'method': name, 'right': sum(ok), 'n': len(ok), **per,
                                 'mixed': pred.count('mixed'), 'none': pred.count('none')})
    strata = sorted({r['stratum'] for r in pub})
    L.append('\nBy stratum, right of pages:\n')
    L.append('| stratum | kind | pages | ' + ' | '.join(pub_rows) + ' |\n|---|---|---:|' + '---:|' * len(pub_rows))
    J['public_strata'] = {}
    for s in strata:
        idx = [i for i, r in enumerate(pub) if r['stratum'] == s]
        cells = [str(sum(pub_ok[n][i] for i in idx)) for n in pub_rows]
        J['public_strata'][s] = {n: sum(pub_ok[n][i] for i in idx) for n in pub_rows} | {'n': len(idx)}
        L.append(f'| {s} | {pub[idx[0]]["kind"]} | {len(idx)} | ' + ' | '.join(cells) + ' |')
    lf = sum(p and t for p, t in zip(p_line, pform))
    lfalse = sum(p and not t for p, t in zip(p_line, pform))
    J['public_forms'] = {'found': lf, 'ledgers': sum(pform), 'false': lfalse}
    L.append(f'\nForms: hand-only ATRIUM calls LINE_* on {lf} of the {sum(pform)} L4 ledger pages and on {lfalse} '
             'other pages (some of which may really hold a table: the strata carry no form label).\n')

    # ---- the 2,000: mixed against the owner's answers ------------------------------------------------------------
    bids, BP, _ = load('bulk')
    blab = {r['page']: r for r in MD.read_csv(MD.CACHE / 'labels.tsv', '\t')}
    same_label = sum(CLASSES[int(BP[i].argmax())] == blab[p]['atrium'] for i, p in enumerate(bids))
    J['bulk_rerun_same_label'] = [same_label, len(bids)]
    answers = json.loads((MD.CACHE / 'sheet/answers.json').read_text())
    key = json.loads((MD.CACHE / 'sheet/key.json').read_text())
    kp = key['pages']
    bix = {p: i for i, p in enumerate(bids)}
    got = {p: a for p, a in answers.items() if p in kp and a.get('hand') and a['hand'] != 'notext'}
    truth_m = {p: a['hand'] in MD.ORDER for p, a in got.items()}
    calls = {'ATRIUM TEXT (its top class)': lambda p: CLASSES[int(BP[bix[p]].argmax())] == 'TEXT',
             'Qwen3.6-27B mixed (saved bulk label)': lambda p: blab[p]['qwen'] == 'mixed',
             'Shipped classifier handwritten': lambda p: blab[p]['regression'] == 'handwritten'}
    # population weights: each sampled stratum's pages stand for its size in the 2,000; the disagreements by pattern
    size = Counter(r['kind'] for r in blab.values())
    psize = key['pattern_sizes']
    w = {}
    for s, k in (('disagree', 'disagree'), ('mixed', 'mixed'), ('control', 'clean')):
        ps = [p for p in got if kp[p]['stratum'] == s]
        if s == 'disagree':
            per = Counter(kp[p]['pattern'] for p in ps)
            raw = {p: psize.get(kp[p]['pattern'], 0) / per[kp[p]['pattern']] for p in ps}
            tot = sum(raw.values())
            w.update({p: v * size[k] / tot for p, v in raw.items()})
        else:
            w.update({p: size[k] / len(ps) for p in ps})
    strat = defaultdict(list)
    for p in w:
        strat[kp[p]['stratum']].append(p)

    def est(fn, pages):
        tp = sum(w[p] for p in pages if fn(p) and truth_m[p])
        fp_ = sum(w[p] for p in pages if fn(p) and not truth_m[p])
        fn_ = sum(w[p] for p in pages if not fn(p) and truth_m[p])
        return tp / (tp + fn_) if tp + fn_ else float('nan'), tp / (tp + fp_) if tp + fp_ else float('nan')
    L.append('## 5. Mixed pages on the 2,000, against the owner\'s 170 answers\n')
    L.append(f'The owner\'s cut (mixed-def-score.md): any handwriting on a typed or printed page, a signature '
             f'included. Of the sheet\'s 170 pages, {len(got)} carry text and have an answer ({sum(truth_m.values())} '
             'mixed under the cut). "On the sheet" counts those pages as drawn, which is not a random draw. '
             '"Estimated in the 2,000" weights each answered page by the stratum it stands for (the disagreements '
             'by pattern; the top-up of pages both mixed classes call mixed is left out, as in the share estimate; '
             f'the {size["open"]} unsettled and {size["hand"]} agreed-handwritten pages are not sampled and add '
             'nothing), with a stratified bootstrap interval (2,000 draws). Recall is of the owner\'s mixed pages, '
             'precision of the label\'s mixed calls.\n')
    L.append('| label | on the sheet: found | false | AUC of p(TEXT) | est. recall | est. precision |\n'
             '|---|---:|---:|---:|---:|---:|')
    J['bulk_mixed'] = []
    rng = random.Random(SEED)
    for name, fn in calls.items():
        found = sum(fn(p) and truth_m[p] for p in got)
        false = sum(fn(p) and not truth_m[p] for p in got)
        rec, prec = est(fn, list(w))
        bs = []
        for _ in range(2000):
            sample = [q for s, ps in strat.items() for q in (ps[rng.randrange(len(ps))] for _ in ps)]
            bs.append(est(fn, sample))
        def ci(j):
            v = sorted(x[j] for x in bs if x[j] == x[j])
            return v[int(.025 * len(v))], v[int(.975 * len(v)) - 1]
        (rl, rh), (pl, ph) = ci(0), ci(1)
        a = auc([float(BP[bix[p]][CLASSES.index('TEXT')]) for p in got], [truth_m[p] for p in got]) \
            if name.startswith('ATRIUM') else float('nan')
        L.append(f'| {name} | {found}/{sum(truth_m.values())} | {false}/{len(got) - sum(truth_m.values())} | '
                 f'{"–" if a != a else f"{a:.2f}"} | {100 * rec:.0f}% ({100 * rl:.0f}–{100 * rh:.0f}) | '
                 f'{100 * prec:.0f}% ({100 * pl:.0f}–{100 * ph:.0f}) |')
        J['bulk_mixed'].append({'label': name, 'found': found, 'false': false, 'mixed': sum(truth_m.values()),
                                'n': len(got), 'auc': None if a != a else round(a, 3), 'recall': round(rec, 3),
                                'recall_ci': [round(rl, 3), round(rh, 3)], 'precision': round(prec, 3),
                                'precision_ci': [round(pl, 3), round(ph, 3)]})
    hand_of_owner = Counter((a['hand'], CLASSES[int(BP[bix[p]].argmax())] == 'TEXT') for p, a in got.items())
    L.append('\nATRIUM\'s TEXT calls by how much handwriting the owner saw (called / pages): ' + ', '.join(
        f'{h} {hand_of_owner[(h, True)]}/{hand_of_owner[(h, True)] + hand_of_owner[(h, False)]}'
        for h in ('none', *MD.ORDER, 'handpage')) + '.\n')
    J['bulk_text_by_hand'] = {h: [hand_of_owner[(h, True)], hand_of_owner[(h, True)] + hand_of_owner[(h, False)]]
                              for h in ('none', *MD.ORDER, 'handpage')}
    share = sum(CLASSES[int(q.argmax())] == 'TEXT' for q in BP)
    L.append(f'ATRIUM says TEXT on {share} of the 2,000 ({100 * share / len(BP):.1f}%); the owner\'s cut puts the '
             f'share near 33% (about 27–46%, KND-3). This rerun gives the same top class as W46.fix-marks-set\'s on '
             f'{same_label} of {len(bids)} pages.\n')
    agree = Counter((hand_argmax(CLASSES[int(BP[i].argmax())]), blab[p]['regression']) for i, p in enumerate(bids))
    L.append('ATRIUM\'s hand against the shipped classifier\'s on the 2,000 (no truth; rows ATRIUM, columns ours):\n')
    L.append('| ATRIUM \\ ours | typewritten | printed | handwritten |\n|---|---:|---:|---:|')
    for h in ('typewritten', 'printed', 'handwritten', 'mixed', 'none'):
        L.append(f'| {h} | ' + ' | '.join(str(agree[(h, o)]) for o in ('typewritten', 'printed', 'handwritten')) + ' |')
    J['bulk_agreement'] = {f'{a}|{b}': n for (a, b), n in agree.items()}

    # ---- confidence ---------------------------------------------------------------------------------------------
    L.append('\n## 6. ATRIUM\'s confidence and whether it is right\n')
    L.append('Hand-only reading, its probability renormalised over the six text classes; the 141 and the 895 '
             'together.\n')
    L.append('| confidence | pages | right |\n|---|---:|---:|')
    conf = []
    for q, t in [(P[i], lab[i]['hand']) for i in three] + list(zip(PP, pt)):
        s = q[HAND6] / q[HAND6].sum()
        conf.append((float(s.max()), hand_only(q)[0] == t))
    J['confidence'] = []
    for lo, hi in ((0, .5), (.5, .8), (.8, .95), (.95, 1.01)):
        c = [ok for v, ok in conf if lo <= v < hi]
        L.append(f'| {lo:.2f}–{min(hi, 1):.2f} | {len(c)} | {frac(sum(c), len(c)) if c else "–"} |')
        J['confidence'].append({'from': lo, 'to': min(hi, 1), 'n': len(c), 'right': sum(c)})

    # ---- speed and memory ---------------------------------------------------------------------------------------
    L.append('\n## 7. Seconds and memory on the M3 Pro (18 GB)\n')
    L.append(f'One process on {run_info["device"]}, batches of 16, torch {run_info.get("torch")}; model load '
             f'{run_info["load_s"]} s. Peak resident memory of the process {run_info["peak_rss_gb"]} GB'
             + (f', MPS driver {run_info["mps_driver_gb"]} GB at the end' if 'mps_driver_gb' in run_info else '') +
             '. Run under the heavy lock, nothing else running.\n')
    L.append('| pages | count | s a page, all in | model s a page (median batch) | JPEG decode and resize s a page |\n'
             '|---|---:|---:|---:|---:|')
    for n, label in (('k144', 'the 144'), ('public', 'the 895'), ('bulk', 'the 2,000')):
        r = run_info[n]
        L.append(f'| {label} | {r["pages"]} | {r["s_page"]:.3f} | {r["model_s_page_median"]:.3f} | {r["decode_s_page"]:.3f} |')
    L.append('\nThe shipped classifier, for comparison: about 0.6 s a page (Vision text lines, document request and '
             'feature print; `kind-classifier.md` §5), with no download. ATRIUM\'s weights are a 323 MB download '
             f'(CC BY-NC). Vision signals for the shipped classifier on the 895 took {run_info.get("public_signals_s", float("nan")):.0f} s '
             f'({run_info.get("public_signals_s", float("nan")) / 895:.2f} s a page). The 2,895-page pass took minutes on the Mac, so it needs no cluster.\n')
    # ---- the verdict, put after the title -------------------------------------------------------------------
    h = {r['method']: r for r in J['k144_hand']}
    ph = {r['method']: r for r in J['public_hand']}
    ours_pub = ph.get('Shipped classifier (bundled weights)')
    rt = {r['classifier']: r for r in J['routing_96']}
    bm = {r['label']: r for r in J['bulk_mixed']}
    at, qw = bm['ATRIUM TEXT (its top class)'], bm['Qwen3.6-27B mixed (saved bulk label)']
    V = ['## Verdict\n',
         '**Keep the shipped classifier for the hand and for forms; do not replace it with ATRIUM or combine the two. '
         'ATRIUM\'s TEXT has the highest mixed-page recall of the three labels on the 2,000 and is worth keeping as a '
         'candidate signal for the mixed flag (W46.mixed-route), not as the kind router.**\n',
         f'- On the 141 typed, printed and handwritten owner pages, ours is right on {h[next(k for k in h if k.startswith("Shipped"))]["right"]}, '
         f'ATRIUM forced to its six text classes on {h["ATRIUM zero-shot, hand-only (top of its six text classes)"]["right"]} '
         f'(paired p {J["k144_paired"]["hand_only_vs_ours"][2]:.3g}): it finds every handwritten page but calls '
         'typewriting printed. A head on its embedding does better '
         f'({h["ATRIUM embedding + LR head (leave-one-folder-out)"]["right"]}) but still below ours '
         f'(p {J["k144_paired"]["head_vs_ours"][2]:.3g}), and adding it to our features does not help '
         f'({h["Both feature sets + LR head (leave-one-folder-out)"]["right"]}).',
         f'- Routed by the guide on the 96, ATRIUM costs {rt["ATRIUM zero-shot hand-only, LINE_* for form"]["lost"]:.2f} NES '
         f'against ours {rt["Shipped classifier (hand and form LR, leave-one-folder-out)"]["lost"]:.2f}: '
         'their intervals overlap, because ATRIUM\'s errors are mostly typewritten called printed, which costs '
         'little on these pages.',
         f'- On the 895 public pages, which neither was fitted on, ATRIUM hand-only is right on '
         f'{ph["ATRIUM zero-shot, hand-only"]["right"]}' + (f' and ours on {ours_pub["right"]}' if ours_pub else '') +
         '. By stratum (§4) both fail L5 and N4; ATRIUM also misses most of L7\'s handwriting and L8\'s and N6\'s print, '
         'where ours holds better.',
         f'- Mixed, under the owner\'s cut: ATRIUM\'s TEXT finds an estimated {100 * at["recall"]:.0f}% of mixed pages '
         f'at {100 * at["precision"]:.0f}% precision; Qwen3.6-27B\'s mixed {100 * qw["recall"]:.0f}% at '
         f'{100 * qw["precision"]:.0f}%. ATRIUM over-calls mixed on pages with no handwriting '
         f'({J["bulk_text_by_hand"]["none"][0]} of {J["bulk_text_by_hand"]["none"][1]} on the sheet) and the two '
         'Qwen\'s few calls are nearly all right but find under a quarter, so neither alone is a mixed filter.',
         f'- Speed is not the obstacle: {run_info["bulk"]["s_page"]:.2f} s a page on MPS, against about 0.6 s for ours. The '
         'obstacles are accuracy on the distinction the guide routes by, a 323 MB download and a non-commercial '
         'licence on the base weights.\n']
    L[1:1] = V
    L.append('## Measurement card\n')
    L.append('- **Truth:** the 144: `kind-classifier.md`\'s labels, the 99 truth pages\' kinds as the drafting models '
             'and the owner left them and the drawn pages labelled by a session looking at contact sheets, not blind '
             '(KND-1); the shipped weights were fitted on them, so its rows are leave-one-folder-out. The 895: the '
             'public set\'s stratum kind, made by its datasets, not by any scored route; not checked page by page, '
             'and a stratum can hold a page of another kind. The 2,000: the owner\'s own 170 blind sheet answers '
             '(2026-10-22), read under his cut; no model\'s label is truth.\n'
             '- **Selection:** the 144 and the 96 as `kind-classifier.md` drew them; the 895 frozen at W43.corpus-'
             'build by source and script; the 170 drawn by `mixed_def.py` from the four labels\' disagreements, '
             'ATRIUM\'s among them, which is why the sheet figures are a check and the estimate re-weights them by '
             'stratum. No page was chosen by ATRIUM\'s output alone or by ABBYY text.\n'
             '- **Comparison:** every method on the same images; ATRIUM at one preprocessing (chosen on the 144 by '
             'W46.fix-marks-set, which flatters it there slightly); the heads with the same regression, penalty and '
             'folders as the shipped classifier\'s.\n'
             f'- **Noise:** Wilson 95% intervals on rates, exact McNemar on paired right/wrong, paired bootstrap on '
             f'NES lost, stratified bootstrap on the 2,000\'s estimates. ATRIUM is deterministic here: the rerun gives '
             f'the same top class as W46.fix-marks-set\'s on {same_label} of {len(bids)} pages.\n'
             '- **Scope:** page kind for routing only. It does not settle where on a page the handwriting is '
             '(W46.marks-detect), how mixed pages should be read (W46.mixed-route), or ATRIUM on other corpora; the '
             '144 has few forms (14) and the 895\'s form truth is the ledger stratum alone.\n')
    REPORT.write_text('\n'.join(L) + '\n')
    REPORT.with_suffix('.json').write_text(json.dumps(J, indent=1, default=float) + '\n')
    print(f'wrote {REPORT}', file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('run').add_argument('--sets', nargs='+', choices=SETS, default=list(SETS))
    sub.add_parser('signals')
    sub.add_parser('report')
    a = ap.parse_args()
    if a.cmd == 'run':
        run(a.sets)
    else:
        {'signals': signals, 'report': report}[a.cmd]()


if __name__ == '__main__':
    main()
