#!/usr/bin/env python3
"""W46.fix-marks-set. What a "mixed" page is, fixed on the 2,000 bulk-pilot pages (10-gap-audit.md §4 fix 4 step one,
K-kinds.md test 2).

  mixed_def.py fetch                    # the bulk pilot's 2,000 JPEGs from FarmShare into CACHE/pages (owner's SSH master)
  mixed_def.py signals                  # kind-signals (Vision, no model) over the pages -> CACHE/signals.tsv
  run-guarded.sh --label atrium --need-gb 3 -- <kraken venv>/bin/python mixed_def.py atrium [--check]
  /usr/local/bin/python3 mixed_def.py labels    # four labels per page -> CACHE/labels.tsv, segbench-results/mixed-def.md/.json, the sheet
  /usr/local/bin/python3 mixed_def.py sheet     # the owner's sheet -> CACHE/sheet/index.html (+ key.json)
  /usr/local/bin/python3 mixed_def.py score --answers FILE   # after the owner: the definition and its corpus share

The four labels, each from what already exists or runs free:
  regression  the Processor's own page-kind classifier (PageKindClassifier.swift): kind-signals.swift's features and
              the bundled weights segbench-results/kind-classifier-model.json. Hand: handwritten, typewritten,
              printed. It has no mixed class (its 3 mixed training pages were folded into handwritten).
  sorter      the Vision OCR lab's page sorter (newspaper, photograph, handwriting, other), already run on these
              pages by W41.bench-vision-kind: segbench-results/farmshare/bulk/vision-kind.csv.
  atrium      ATRIUM's page classifier, ufal/vit-historical-page main (v4.3, RegNetY-16GF), zero-shot, eleven
              classes; TEXT is its mixed class. Measurement only (base weights CC BY-NC).
  qwen        Qwen3.6-27B's own label from the FarmShare bulk pilot (typewritten, printed, mixed, handwritten):
              segbench-results/farmshare/bulk/pages.csv. Not rerun: the label exists for all 2,000 pages.

Each label is read as the set of page kinds it allows, of C (typed or printed only), M (mixed: handwriting on a typed
or printed page) and H (a handwritten page). A label that cannot speak to the hand abstains (ATRIUM's photo and
drawing classes). The sorter's "other" and "photograph" allow C or M, because a typed letter with a postscript is
neither handwriting-dominated nor a newspaper; the regression's handwritten allows M or H for the same reason. A page
is a DISAGREEMENT when the sets that speak have nothing in common, and ALL-MIXED when M is the only kind they all allow
and both labels with a mixed class (ATRIUM, Qwen) say mixed.

The sheet is blind: it shows the page and asks how much handwriting it carries and whether the owner would call it
mixed, never what any label said. It holds 100 disagreements (stratified by the pattern of the disagreement), 50
all-mixed pages (topped up, when too few, from pages both mixed classes call mixed) and 20 control pages on which
every label agrees the page is typed or printed, which is what lets `score` estimate the corpus share without
assuming the agreed pages are clean. The key (stratum and labels) is a separate
file the sheet never loads.

Images and the per-page labels stay in the private cache; the repo is public, so segbench-results carries aggregates
and neutral page ids only (as farmshare/bulk/pages.csv already does). Reads the corpus never; no money.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import random
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
RESULTS = HERE.parents[1] / 'segbench-results'
REHEARSAL = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
CACHE = Path(os.environ.get('MIXED_DEF_CACHE', REHEARSAL / 'mixed-def'))
PAGES = CACHE / 'pages'
BULK = RESULTS / 'farmshare' / 'bulk'
QWEN_CSV = BULK / 'pages.csv'
SORTER_CSV = BULK / 'vision-kind.csv'
MODEL_JSON = RESULTS / 'kind-classifier-model.json'
KIND_LABELS = REHEARSAL / 'kind-classifier' / 'labels.tsv'     # the 144 owner-labelled pages, for ATRIUM's check
REPORT = RESULTS / 'mixed-def.md'
FARMSHARE = 'cp1@login.farmshare.stanford.edu'
REMOTE_PAGES = '/scratch/users/cp1/fs-ocr/bulk-pilot/in'
SSH_OPTS = ['-o', 'ControlPath=/Users/cp1/.ssh/cm-farmshare', '-o', 'ControlMaster=no', '-o', 'BatchMode=yes',
            '-o', 'ConnectTimeout=5', '-o', 'ProxyCommand=false']   # execution-plans/farmshare-access.md
N_PAGES = 2000
SEED = 4608
SHEET_DISAGREE = 100
SHEET_MIXED = 50
SHEET_CONTROL = 20
SECONDS_PER_PAGE = 20      # one look and at most two keys; 170 pages is about an hour

ATRIUM_REPO = 'ufal/vit-historical-page'
ATRIUM_REV = '543216d6b7e12552b164372e9124ceb168b06b98'   # main on 2026-10-22, v4.3 regnety_160.swag_ft_in1k
ATRIUM_CLASSES = ('DRAW', 'DRAW_L', 'LINE_HW', 'LINE_P', 'LINE_T', 'PHOTO', 'PHOTO_L', 'TEXT', 'TEXT_HW', 'TEXT_P',
                  'TEXT_T')      # the model card's category table, alphabetical: the order of LABEL_0..LABEL_10
# The card is ambiguous about preprocessing: config.json's timm cfg says 384 px with ImageNet mean and std and no
# crop, preprocessor_config.json says a ViT processor at 384 px with mean and std 0.5, and the card's model table
# gives v4.3 a 224 px resolution. `atrium --check` scores all four on the 144 labelled pages and the bulk run uses
# the one that agrees with the owner's labels most often.
IMAGENET = ((0.485, 0.456, 0.406), (0.229, 0.224, 0.225))
HALF = ((.5, .5, .5), (.5, .5, .5))
ATRIUM_PREP = {'imagenet-384': (*IMAGENET, 384), 'half-384': (*HALF, 384), 'imagenet-224': (*IMAGENET, 224),
               'half-224': (*HALF, 224)}

KINDS = ('C', 'M', 'H')
ANY = frozenset(KINDS)
LABELERS = ('regression', 'sorter', 'atrium', 'qwen')
KIND_SETS = ('disagree', 'mixed', 'clean', 'hand', 'open')

# The owner's answer per page: how much handwriting, then (where it is a question) mixed or not.
HAND_ANSWERS = {'0': 'none', '1': 'signature', '2': 'few', '3': 'passage', '4': 'long', '5': 'handpage', 'x': 'notext'}
HAND_TEXT = {'none': 'no handwriting', 'signature': 'a signature, initials or a date by hand only',
             'few': 'handwritten notes of under about 10 words', 'passage': 'a handwritten passage of about 10-29 words',
             'long': 'handwriting of 30 words or more on a typed or printed page', 'handpage': 'a handwritten page',
             'notext': 'not a text page (photograph, drawing, blank)'}
ASKS_MIXED = ('signature', 'few', 'passage', 'long')   # the others are not mixed by any definition


# ---- the labels ---------------------------------------------------------------------------------------------------

def read_csv(path, delimiter=','):
    with open(path, newline='') as f:
        return list(csv.DictReader((l for l in f if not l.startswith('#')), delimiter=delimiter))


def write_tsv(path, rows, cols):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w', newline='') as f:
        w = csv.DictWriter(f, cols, delimiter='\t', extrasaction='ignore', lineterminator='\n')
        w.writeheader()
        w.writerows(rows)


def allows(labeler, label):
    """The page kinds a label allows (a frozenset of C, M, H), or None when it does not speak to the hand."""
    if not label:
        return None
    if labeler == 'qwen':
        return {'typewritten': frozenset('C'), 'printed': frozenset('C'), 'mixed': frozenset('M'),
                'handwritten': frozenset('H')}.get(label)
    if labeler == 'atrium':
        if label in ('TEXT_T', 'TEXT_P', 'LINE_T', 'LINE_P'):
            return frozenset('C')
        if label == 'TEXT':
            return frozenset('M')
        if label in ('TEXT_HW', 'LINE_HW'):
            return frozenset('H')
        return None                                   # photographs and drawings say nothing about the hand
    if labeler == 'regression':
        return frozenset('MH') if label == 'handwritten' else frozenset('C') if label in ('typewritten', 'printed') else None
    if labeler == 'sorter':
        return {'handwriting': frozenset('MH'), 'newspaper': frozenset('C'), 'other': frozenset('CM'),
                'photograph': frozenset('CM')}.get(label)
    raise ValueError(labeler)


def classify(labels):
    """labels: {labeler: label}. Returns (kind, pattern): kind is 'disagree', 'mixed' (all-mixed), 'clean' (C is
    the only kind every label allows), 'hand' (H is), or 'open' (consistent but not settled, e.g. M or H). pattern
    names the disagreement: each speaking label and the kinds it allows."""
    sets = {k: allows(k, labels.get(k)) for k in LABELERS}
    speak = {k: s for k, s in sets.items() if s is not None}
    common = frozenset.intersection(*speak.values()) if speak else ANY
    pattern = ' '.join(f'{k}:{"".join(sorted(s))}' for k, s in speak.items())
    if not common:
        return 'disagree', pattern
    if common == frozenset('M') and labels.get('qwen') == 'mixed' and labels.get('atrium') == 'TEXT':
        return 'mixed', pattern
    if common == frozenset('C'):
        return 'clean', pattern
    if common == frozenset('H'):
        return 'hand', pattern
    return 'open', pattern


def regression_labels(signals, prints, model):
    """The app's PageKindClassifier in Python: the hand regression's softmax over kind-signals' features."""
    import numpy as np
    hand = model['hand']
    mean, sd, W, b = (np.array(hand[k], dtype=float) for k in ('mean', 'sd', 'W', 'b'))
    out = {}
    for pid, s in signals.items():
        fp = prints.get(pid)
        if fp is None:
            continue
        x = [float(s[c]) if s.get(c) not in (None, '', 'nan') else float('nan') for c in ('harmonic', 'periodic', 'conf', 'text_px', 'lines')]
        x = np.array([0.0 if v != v else v for v in x] + list(fp))
        if len(x) != len(mean):
            raise SystemExit(f'{pid}: {len(x)} features against {len(mean)} weights')
        z = (x - mean) / sd @ W + b
        p = np.exp(z - z.max()); p /= p.sum()
        k = int(p.argmax())
        out[pid] = {'label': hand['classes'][k], 'p': round(float(p[k]), 3),
                    'p_hand': round(float(p[hand['classes'].index('handwritten')]), 3)}
    return out


def load_labels():
    qwen = {r['page']: r for r in read_csv(QWEN_CSV)}
    sorter = {r['page']: r['vision_kind'] for r in read_csv(SORTER_CSV)}
    sig = {r['id']: r for r in read_csv(CACHE / 'signals.tsv', '\t')}
    prints = {}
    for line in open(CACHE / 'featureprints.tsv'):
        pid, _, v = line.rstrip('\n').partition('\t')
        prints[pid] = [float(x) for x in v.split(',')]
    reg = regression_labels(sig, prints, json.loads(MODEL_JSON.read_text()))
    atr = {r['id']: r for r in read_csv(CACHE / 'atrium.tsv', '\t')}
    pages = sorted(qwen)
    if len(pages) != N_PAGES:
        raise SystemExit(f'{QWEN_CSV}: {len(pages)} pages, expected {N_PAGES}')
    rows = []
    for p in pages:
        labels = {'regression': reg.get(p, {}).get('label', ''), 'sorter': sorter.get(p, ''),
                  'atrium': atr.get(p, {}).get('label', ''), 'qwen': qwen[p]['kind'] if qwen[p]['status'] == 'ok' else ''}
        kind, pattern = classify(labels)
        rows.append({'page': p, **labels, 'regression_p_hand': reg.get(p, {}).get('p_hand', ''),
                     'atrium_p': atr.get(p, {}).get('p', ''), 'atrium_p_text': atr.get(p, {}).get('p_TEXT', ''),
                     'qwen_status': qwen[p]['status'], 'kind': kind, 'pattern': pattern})
    return rows


# ---- the sheet ------------------------------------------------------------------------------------------------------

def stratified(rng, rows, n, key):
    """n rows spread over the values of key: every group gets at least one where n allows, the rest in proportion."""
    groups = {}
    for r in rows:
        groups.setdefault(key(r), []).append(r)
    if len(rows) <= n:
        return list(rows)
    order = sorted(groups, key=lambda g: (-len(groups[g]), g))
    take = {g: 0 for g in order}
    for g in order[:n]:
        take[g] = 1
    left = n - sum(take.values())
    while left > 0:   # largest remainder on the groups' sizes
        room = {g: len(groups[g]) - take[g] for g in order if len(groups[g]) > take[g]}
        g = max(room, key=lambda g: (len(groups[g]) / (take[g] + 1), -order.index(g)))
        take[g] += 1
        left -= 1
    out = []
    for g in order:
        out += rng.sample(sorted(groups[g], key=lambda r: r['page']), take[g])
    return out


def choose(rows, rng):
    by = {k: [r for r in rows if r['kind'] == k] for k in KIND_SETS}
    dis = stratified(rng, by['disagree'], SHEET_DISAGREE, lambda r: r['pattern'])
    mixed = rng.sample(by['mixed'], min(SHEET_MIXED, len(by['mixed'])))
    # Too few all-mixed pages: the rest from pages both mixed classes call mixed while another label dissents. They
    # inform the cut and the labels' check, not the corpus share (they would count the disagreements twice).
    taken = {r['page'] for r in dis}
    both = [r for r in by['disagree'] if r['qwen'] == 'mixed' and r['atrium'] == 'TEXT' and r['page'] not in taken]
    extra = rng.sample(both, min(SHEET_MIXED - len(mixed), len(both)))
    control = rng.sample(by['clean'], min(SHEET_CONTROL, len(by['clean'])))
    chosen = ([('disagree', r) for r in dis] + [('mixed', r) for r in mixed] + [('mixed-both', r) for r in extra]
              + [('control', r) for r in control])
    rng.shuffle(chosen)
    return chosen, by


def sheet(rows):
    rng = random.Random(SEED)
    chosen, by = choose(rows, rng)
    out = CACHE / 'sheet'
    out.mkdir(parents=True, exist_ok=True)
    data = [{'page': r['page'], 'img': f'../pages/{r["page"]}.jpg'} for _, r in chosen]
    missing = [d['page'] for d in data if not (PAGES / f'{d["page"]}.jpg').exists()]
    if missing:
        raise SystemExit(f'no image for {missing[:5]}… run fetch first')
    minutes = len(data) * SECONDS_PER_PAGE / 60
    (out / 'index.html').write_text(SHEET_HTML.replace('__DATA__', json.dumps(data)).replace('__N__', str(len(data)))
                                    .replace('__MINUTES__', f'{minutes:.0f}')
                                    .replace('__HANDS__', json.dumps(HAND_ANSWERS))
                                    .replace('__HANDTEXT__', json.dumps(HAND_TEXT))
                                    .replace('__ASKS__', json.dumps(ASKS_MIXED)))
    key = {'seed': SEED, 'strata': {k: len(v) for k, v in by.items()},
           'pattern_sizes': dict(Counter(r['pattern'] for r in by['disagree'])),
           'pages': {r['page']: {'stratum': s, **{k: r[k] for k in LABELERS}, 'pattern': r['pattern']} for s, r in chosen}}
    (out / 'key.json').write_text(json.dumps(key, indent=1))
    return {'pages': len(data), 'minutes': round(minutes), 'by_stratum': dict(Counter(s for s, _ in chosen)),
            'patterns_in_sheet': len({r['pattern'] for s, r in chosen if s == 'disagree'})}


SHEET_HTML = r"""<!doctype html><meta charset="utf-8"><title>W46 mixed-page definition</title>
<style>
body{font:14px -apple-system,sans-serif;margin:0;background:#fff;color:#111;color-scheme:light}
header{position:sticky;top:0;background:#fff;border-bottom:1px solid #ccc;padding:6px 12px;z-index:2}
.page{display:flex;gap:12px;border-bottom:3px solid #999;padding:10px;min-height:90vh;scroll-margin-top:var(--head,60px)}
.img{flex:1 1 65%;position:sticky;top:var(--head,60px);height:calc(100vh - var(--head,60px) - 20px);overflow:auto}
.frame{width:100%;cursor:zoom-in}.frame.zoom{width:250%;cursor:zoom-out}.frame img{width:100%;display:block}
.q{flex:1 1 35%}.page.cur .q{outline:3px solid #06f;outline-offset:4px}.page.done .q{background:#e6f6e6}
.opt{display:block;margin:3px 0;padding:2px 4px;border-radius:3px;cursor:pointer}.opt.sel{font-weight:bold;color:#060;background:#d8f0d8}
.k{color:#888;font-size:12px;display:inline-block;width:1.4em}.mixed{margin-top:10px}.mixed.off{display:none}
</style>
<header><b>What is a mixed page?</b> — __N__ pages drawn from the 2,000-page bulk pilot, about __MINUTES__ minutes.
No model's label is shown. For each page: <b>how much handwriting</b> does it carry
(<b>0</b> none · <b>1</b> signature/initials/date only · <b>2</b> under ~10 words · <b>3</b> ~10-29 words · <b>4</b> 30+ words on a
typed or printed page · <b>5</b> a handwritten page · <b>x</b> not a text page), then, where asked, <b>would you call it mixed</b>,
meaning its handwriting must be read and kept in the text (<b>y</b>/<b>n</b>).
<b>j/k</b> next/previous · <b>z</b> zoom (or click the image). Answers stay in this browser;
<button onclick="exportAnswers()">Export answers</button><span id="prog"></span></header><div id="root"></div>
<script>
const DATA=__DATA__,HANDS=__HANDS__,HANDTEXT=__HANDTEXT__,ASKS=__ASKS__;const KEY='w46-mixed-def';
let A=JSON.parse(localStorage.getItem(KEY)||'{}');const P=[];
function done(a){return a&&a.hand&&(!ASKS.includes(a.hand)||a.mixed)}
function save(){localStorage.setItem(KEY,JSON.stringify(A));prog()}
function prog(){document.getElementById('prog').textContent=` ${P.filter(p=>done(A[p.page])).length} / ${P.length} answered`}
function paint(p){const a=A[p.page]||{};p.el.classList.toggle('done',!!done(a));
 p.el.querySelectorAll('.opt').forEach(o=>o.classList.toggle('sel',(o.dataset.f==='hand'?a.hand:a.mixed)===o.dataset.v));
 p.el.querySelector('.mixed').classList.toggle('off',!ASKS.includes(a.hand))}
function set(p,f,v){const a=A[p.page]=A[p.page]||{};a[f]=v;if(f==='hand'&&!ASKS.includes(v))delete a.mixed;save();paint(p);
 if(done(a))go(cur+1)}
const root=document.getElementById('root');
DATA.forEach((d,i)=>{const el=document.createElement('div');el.className='page';
 let h=`<div class="img"><div class="frame"><img loading="lazy" src="${d.img}"></div></div><div class="q"><b>${i+1}. ${d.page}</b>`;
 for(const [k,v] of Object.entries(HANDS))h+=`<span class="opt" data-f="hand" data-v="${v}"><span class="k">${k}</span>${HANDTEXT[v]}</span>`;
 h+=`<div class="mixed"><b>Mixed?</b><span class="opt" data-f="mixed" data-v="yes"><span class="k">y</span>yes: read and keep its handwriting</span>`+
  `<span class="opt" data-f="mixed" data-v="no"><span class="k">n</span>no: the handwriting can be left out of the text</span></div></div>`;
 el.innerHTML=h;root.appendChild(el);const p={page:d.page,el};P.push(p);
 el.querySelector('.frame').onclick=e=>e.currentTarget.classList.toggle('zoom');
 el.querySelectorAll('.opt').forEach(o=>o.onclick=()=>{go(i);set(p,o.dataset.f,o.dataset.v)});
 el.querySelector('.q').addEventListener('click',e=>{if(!e.target.closest('.opt')&&cur!==i)go(i)});paint(p)});
let cur=0;function go(i){if(i<0||i>=P.length)return;P[cur].el.classList.remove('cur');cur=i;P[cur].el.classList.add('cur');
 P[cur].el.scrollIntoView({block:'start'})}
function head(){document.documentElement.style.setProperty('--head',document.querySelector('header').offsetHeight+'px')}
addEventListener('resize',head);head();
document.addEventListener('keydown',e=>{const p=P[cur];if(!p||e.metaKey||e.ctrlKey)return;
 if(e.key==='j')go(cur+1);else if(e.key==='k')go(cur-1);else if(e.key==='z')p.el.querySelector('.frame').classList.toggle('zoom');
 else if(HANDS[e.key])set(p,'hand',HANDS[e.key]);
 else if((e.key==='y'||e.key==='n')&&ASKS.includes((A[p.page]||{}).hand))set(p,'mixed',e.key==='y'?'yes':'no')});
function exportAnswers(){const b=new Blob([JSON.stringify(A,null,1)],{type:'application/json'});
 const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='mixed-def-answers.json';a.click()}
prog();go(0);
</script>"""


# ---- the owner's answers ---------------------------------------------------------------------------------------------

ORDER = ('signature', 'few', 'passage', 'long')    # handwriting on a typed or printed page, least to most
# the call nearest to "mixed" each label can make (the regression and the sorter have no mixed class)
MIXED_CALL = {'qwen': 'mixed', 'atrium': 'TEXT', 'regression': 'handwritten', 'sorter': 'handwriting'}


def score(answers, key, rows):
    """The definition the owner's answers support and its share of the 2,000. Each sampled stratum's rate is
    applied to the stratum's size in the 2,000; the disagreements, drawn with at least one page of every pattern,
    are weighted pattern by pattern (a pattern with no answer takes the pooled rate). 'mixed-both' pages (the
    all-mixed top-up) count for the cut and the labels' check only. Two strata are not sampled and are reported apart so the assumption
    is visible: 'open' (consistent with mixed but not settled) gets the disagreements' rate, the nearest checked
    stratum; 'hand' (every label allows only a handwritten page) counts as not mixed."""
    pages = key['pages']
    got = {p: a for p, a in answers.items() if p in pages and a.get('hand')}
    size = Counter(r['kind'] for r in rows)
    stratum_of = {'disagree': 'disagree', 'mixed': 'mixed', 'control': 'clean'}
    sizes = key.get('pattern_sizes', {})
    out = {'answered': len(got), 'sheet': len(pages), 'strata': dict(size), 'hand': {}, 'by_threshold': [], 'labelers': {}}
    out['hand'] = {s: dict(Counter(a['hand'] for p, a in got.items() if pages[p]['stratum'] == s))
                   for s in (*stratum_of, 'mixed-both')}
    yes = {p for p, a in got.items() if a.get('mixed') == 'yes'}
    out['owner_mixed'] = len(yes)
    # The owner's own cut: the least handwriting at which most of the pages carrying it were called mixed.
    called = {h: [a.get('mixed') == 'yes' for a in got.values() if a['hand'] == h] for h in ORDER}
    out['called_mixed_by_hand'] = {h: [sum(v), len(v)] for h, v in called.items()}
    cut = next((h for h in ORDER if called[h] and sum(called[h]) * 2 > len(called[h])), None)
    out['cut'] = cut
    for h in ORDER:   # "mixed" = handwriting at least this much on a typed or printed page
        at = set(ORDER[ORDER.index(h):])
        est, parts = 0.0, {}
        for s, k in stratum_of.items():
            a = [(pages[p]['pattern'], x['hand'] in at) for p, x in got.items() if pages[p]['stratum'] == s]
            rate = sum(v for _, v in a) / len(a) if a else 0.0
            if s == 'disagree' and a and sizes:
                per = {}
                for pat, v in a:
                    per.setdefault(pat, []).append(v)
                n_dis = sum(sizes.values())
                rate = sum(n * (sum(per[pat]) / len(per[pat]) if pat in per else rate) for pat, n in sizes.items()) / n_dis
            parts[k] = {'answered': len(a), 'rate': round(rate, 3)}
            est += rate * size.get(k, 0)
        open_rate = parts['disagree']['rate']   # 'hand' adds nothing: a handwritten page is not mixed
        est += open_rate * size.get('open', 0)
        n = sum(size.values())
        out['by_threshold'].append({'at_least': h, 'pages': round(est), 'share': round(est / n, 4) if n else 0,
                                    'open_assumed': round(open_rate * size.get('open', 0)), 'strata': parts})
    if cut:
        truth = {p: a['hand'] in ORDER[ORDER.index(cut):] for p, a in got.items() if a['hand'] != 'notext'}
        for lab in LABELERS:   # on the sheet's pages, which are not a random draw: a check, not an accuracy
            spoke = [p for p in truth if allows(lab, pages[p][lab]) is not None]
            calls = {p: pages[p][lab] == MIXED_CALL[lab] for p in spoke}
            out['labelers'][lab] = {'spoke': len(spoke), 'mixed_pages': sum(truth[p] for p in spoke),
                                    'found': sum(calls[p] and truth[p] for p in spoke),
                                    'false': sum(calls[p] and not truth[p] for p in spoke)}
    return out


# ---- commands -------------------------------------------------------------------------------------------------------

def fetch():
    PAGES.mkdir(parents=True, exist_ok=True)
    have = len(list(PAGES.glob('p*.jpg')))
    if have == N_PAGES:
        print(f'{have} pages already in {PAGES}', file=sys.stderr)
        return
    subprocess.run(['/opt/homebrew/bin/gtimeout', '3600', '/usr/bin/scp', '-q', *SSH_OPTS, '-r',
                    f'{FARMSHARE}:{REMOTE_PAGES}/.', str(PAGES)], check=True)
    print(f'{len(list(PAGES.glob("p*.jpg")))} pages in {PAGES}', file=sys.stderr)


def page_list():
    files = sorted(PAGES.glob('p*.jpg'))
    if len(files) != N_PAGES:
        raise SystemExit(f'{PAGES}: {len(files)} images, expected {N_PAGES}; run fetch')
    return files


def signals():
    tool = Path('/tmp/kind-signals')
    src = HERE / 'kind_signals/kind-signals.swift'
    if not tool.exists() or src.stat().st_mtime > tool.stat().st_mtime:
        subprocess.run(['swiftc', '-O', '-o', str(tool), '-target', 'arm64-apple-macos26.0', str(src)], check=True)
    lst = CACHE / 'signals-list.tsv'
    lst.write_text(''.join(f'{f.stem}\t{f}\n' for f in page_list()))
    t = time.time()
    with open(CACHE / 'signals.tsv', 'w') as out:
        subprocess.run([str(tool), str(lst), str(CACHE / 'featureprints.tsv')], stdout=out, check=True)
    print(f'signals for {N_PAGES} pages in {time.time() - t:.0f} s', file=sys.stderr)


def atrium_model():
    import timm
    import torch
    from huggingface_hub import hf_hub_download
    from safetensors.torch import load_file
    m = timm.create_model('regnety_160', num_classes=len(ATRIUM_CLASSES), pretrained=False)
    sd = load_file(hf_hub_download(ATRIUM_REPO, 'model.safetensors', revision=ATRIUM_REV))
    m.load_state_dict({k.removeprefix('timm_model.'): v for k, v in sd.items()}, strict=True)
    dev = 'mps' if torch.backends.mps.is_available() else 'cpu'
    return m.eval().to(dev), dev


def atrium_run(model, dev, files, prep, batch=16):
    import numpy as np
    import torch
    from PIL import Image
    *ms, side = ATRIUM_PREP[prep]
    mean, std = (np.array(v, dtype=np.float32).reshape(3, 1, 1) for v in ms)
    out = {}
    for i in range(0, len(files), batch):
        chunk = files[i:i + batch]
        x = []
        for _, f in chunk:   # the whole page squeezed to a square, bicubic, as the card's cfg (crop_pct 1.0)
            im = Image.open(f).convert('RGB').resize((side, side), Image.BICUBIC)
            x.append((np.asarray(im, dtype=np.float32).transpose(2, 0, 1) / 255 - mean) / std)
        with torch.no_grad():
            p = torch.softmax(model(torch.from_numpy(np.stack(x)).to(dev)), 1).cpu().numpy()
        for (pid, _), q in zip(chunk, p):
            k = int(q.argmax())
            out[pid] = {'id': pid, 'label': ATRIUM_CLASSES[k], 'p': f'{q[k]:.3f}',
                        **{f'p_{c}': f'{q[j]:.3f}' for j, c in enumerate(ATRIUM_CLASSES)}}
    return out


ATRIUM_HAND = {'typewritten': ('TEXT_T', 'LINE_T'), 'printed': ('TEXT_P', 'LINE_P'), 'handwritten': ('TEXT_HW', 'LINE_HW'),
               'mixed': ('TEXT',)}


def atrium(check):
    model, dev = atrium_model()
    if check:   # which preprocessing: agreement with the owner's hand labels on the 144 (ladder copies left out)
        lab = [r for r in read_csv(KIND_LABELS, '\t') if not r['set'].startswith('ladder')]
        files = [(r['id'], r['file']) for r in lab]
        res = {}
        for prep in ATRIUM_PREP:
            got = atrium_run(model, dev, files, prep)
            ok = sum(got[r['id']]['label'] in ATRIUM_HAND.get(r['hand'], ()) for r in lab)
            res[prep] = {'right': ok, 'n': len(lab), 'labels': dict(Counter(got[r['id']]['label'] for r in lab))}
            print(f'{prep}: hand right on {ok} of {len(lab)}; {res[prep]["labels"]}', file=sys.stderr)
        (CACHE / 'atrium-check.json').write_text(json.dumps(res, indent=1))
        return
    chk = json.loads((CACHE / 'atrium-check.json').read_text())
    prep = max(chk, key=lambda k: chk[k]['right'])
    t = time.time()
    got = atrium_run(model, dev, [(f.stem, f) for f in page_list()], prep)
    secs = time.time() - t
    write_tsv(CACHE / 'atrium.tsv', list(got.values()), ['id', 'label', 'p'] + [f'p_{c}' for c in ATRIUM_CLASSES])
    (CACHE / 'atrium-run.json').write_text(json.dumps({'prep': prep, 'device': dev, 'seconds': round(secs, 1),
                                                       'pages': len(got), 'revision': ATRIUM_REV}, indent=1))
    print(f'ATRIUM ({prep}) on {len(got)} pages in {secs:.0f} s on {dev}', file=sys.stderr)


def labels_cmd():
    rows = load_labels()
    write_tsv(CACHE / 'labels.tsv', rows, list(rows[0]))
    sh = sheet(rows)
    run = json.loads((CACHE / 'atrium-run.json').read_text())
    chk = json.loads((CACHE / 'atrium-check.json').read_text())
    J = {'pages': len(rows), 'counts': {k: dict(Counter(r[k] or '(none)' for r in rows)) for k in LABELERS},
         'kinds': dict(Counter(r['kind'] for r in rows)),
         'disagreement_patterns': dict(Counter(r['pattern'] for r in rows if r['kind'] == 'disagree').most_common()),
         'mixed_said': {'qwen': sum(r['qwen'] == 'mixed' for r in rows), 'atrium': sum(r['atrium'] == 'TEXT' for r in rows),
                        'both': sum(r['qwen'] == 'mixed' and r['atrium'] == 'TEXT' for r in rows),
                        'either': sum(r['qwen'] == 'mixed' or r['atrium'] == 'TEXT' for r in rows)},
         'atrium_run': run, 'atrium_check': {k: {'right': v['right'], 'n': v['n']} for k, v in chk.items()},
         'sheet': sh}
    J['cross_qwen_atrium'] = {q: dict(Counter(r['atrium'] for r in rows if r['qwen'] == q))
                              for q in sorted({r['qwen'] for r in rows})}
    (RESULTS / 'mixed-def.json').write_text(json.dumps(J, indent=1) + '\n')
    write_md(J)
    print(f'{len(rows)} pages: {J["kinds"]}; sheet {sh["pages"]} pages, ~{sh["minutes"]} min -> {CACHE / "sheet/index.html"}',
          file=sys.stderr)


def pct(a, n):
    return f'{100 * a / n:.1f}%' if n else '—'


def write_md(J):
    n = J['pages']
    c = J['counts']
    run, chk, sh, ms = J['atrium_run'], J['atrium_check'], J['sheet'], J['mixed_said']
    L = ['# What a mixed page is: four labels on the 2,000 bulk-pilot pages (W46.fix-marks-set)', '',
         f'Generated by `scripts/segbench/mixed_def.py` on {time.strftime("%Y-%m-%d")}. The {n} pages are the FarmShare '
         'bulk pilot\'s random draw from 91,152 corpus PDFs in 33 collections (`farmshare/bulk/`, neutral page names). '
         'No money: Apple Vision, open weights, and labels already saved. Per-page labels and the images stay in the '
         'private cache.', '',
         '## The labels', '',
         '| label | what it is | its calls on the 2,000 |', '|---|---|---|',
         '| regression | the Processor\'s page-kind classifier (`PageKindClassifier`, `kind-classifier-model.json`), no '
         'mixed class | ' + ', '.join(f'{k} {v}' for k, v in sorted(c['regression'].items(), key=lambda x: -x[1])) + ' |',
         '| sorter | the Vision OCR lab\'s page sorter (W41.bench-vision-kind), no mixed class | '
         + ', '.join(f'{k} {v}' for k, v in sorted(c['sorter'].items(), key=lambda x: -x[1])) + ' |',
         f'| atrium | `ufal/vit-historical-page` main (v4.3, RegNetY-16GF), zero-shot; `TEXT` is mixed | '
         + ', '.join(f'{k} {v}' for k, v in sorted(c['atrium'].items(), key=lambda x: -x[1])) + ' |',
         '| qwen | Qwen3.6-27B\'s own label in the bulk pilot (none where the reply failed) | '
         + ', '.join(f'{k} {v}' for k, v in sorted(c['qwen'].items(), key=lambda x: -x[1])) + ' |', '',
         f'ATRIUM ran on the Mac ({run["device"]}) in {run["seconds"]:.0f} s for {run["pages"]} pages. Its model card '
         'gives two preprocessings; on the 144 owner-labelled kind pages its hand agreed with the owner\'s on '
         + ' and '.join(f'{v["right"]} of {v["n"]} ({k})' for k, v in chk.items())
         + f', so the bulk run used `{run["prep"]}`. (W46.kind-atrium measures it properly.)', '',
         '## How often each says mixed', '',
         f'Qwen says mixed on {ms["qwen"]} pages ({pct(ms["qwen"], n)}), ATRIUM on {ms["atrium"]} ({pct(ms["atrium"], n)}); '
         f'both on {ms["both"]}, either on {ms["either"]}. Qwen\'s label against ATRIUM\'s:', '',
         '| qwen \\ atrium | ' + ' | '.join(ATRIUM_CLASSES) + ' |', '|---|' + '--:|' * len(ATRIUM_CLASSES)]
    for q, row in J['cross_qwen_atrium'].items():
        L.append(f'| {q or "(failed)"} | ' + ' | '.join(str(row.get(a, 0)) for a in ATRIUM_CLASSES) + ' |')
    k = J['kinds']
    L += ['', '## Agreement', '',
          'Each label is read as the kinds it allows: C typed or printed only, M mixed, H a handwritten page '
          '(header of `mixed_def.py`). A page is a disagreement when the labels that speak allow no kind in common.', '',
          f'| set | pages |', '|---|--:|',
          f'| disagree | {k.get("disagree", 0)} |',
          f'| all-mixed (M the only kind allowed, and ATRIUM and Qwen both say mixed) | {k.get("mixed", 0)} |',
          f'| typed or printed only by every label (C) | {k.get("clean", 0)} |',
          f'| a handwritten page by every label (H) | {k.get("hand", 0)} |',
          f'| consistent but unsettled (M or H, or M or C) | {k.get("open", 0)} |', '',
          'The commonest disagreements (each label and the kinds it allows):', '', '| pattern | pages |', '|---|--:|']
    for p, v in list(J['disagreement_patterns'].items())[:12]:
        L.append(f'| `{p}` | {v} |')
    L += ['', '## The owner\'s sheet', '',
          f'{sh["pages"]} pages, about {sh["minutes"]} minutes: '
          + ', '.join(f'{v} {s}' for s, v in sh['by_stratum'].items())
          + f' (the disagreements spread over {sh["patterns_in_sheet"]} patterns; mixed-both tops up the {k.get("mixed", 0)} '
          'all-mixed pages with pages ATRIUM and Qwen both call mixed while another label dissents, and counts for the '
          'cut but not the corpus share; the controls are pages every label '
          'calls typed or printed, so the score can check the agreed pages rather than assume them clean). Blind: '
          'each page asks how much handwriting it carries and whether the owner would call it mixed; no label is shown. '
          f'Seed {SEED}. The sheet and its key are private, under `mixed-def/sheet/`; gate W46.mixed-def-owner-ok, and '
          '`mixed_def.py score --answers FILE` turns the answers into the definition and its share of the corpus.', '']
    REPORT.write_text('\n'.join(L) + '\n')


def score_cmd(path):
    rows = read_csv(CACHE / 'labels.tsv', '\t')
    key = json.loads((CACHE / 'sheet' / 'key.json').read_text())
    out = score(json.loads(Path(path).read_text()), key, rows)
    (RESULTS / 'mixed-def-score.json').write_text(json.dumps(out, indent=1) + '\n')
    print(json.dumps(out, indent=1))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    for c in ('fetch', 'signals', 'labels', 'sheet'):
        sub.add_parser(c)
    sub.add_parser('atrium').add_argument('--check', action='store_true')
    sub.add_parser('score').add_argument('--answers', required=True)
    a = ap.parse_args()
    if a.cmd == 'atrium':
        atrium(a.check)
    elif a.cmd == 'score':
        score_cmd(a.answers)
    elif a.cmd == 'sheet':
        print(json.dumps(sheet(read_csv(CACHE / 'labels.tsv', '\t'))))
    else:
        {'fetch': fetch, 'signals': signals, 'labels': labels_cmd}[a.cmd]()


if __name__ == '__main__':
    main()
