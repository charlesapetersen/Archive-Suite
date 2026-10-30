#!/usr/bin/env python3
"""W46.fix-ocr-truth-bias. Is the owner's 96-page truth set biased toward the two models that drafted it?

  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy python ocr_truth_bias.py

Reads saved files only: no model, no network, no money. The 96's truth was drafted by Claude Opus 5.5 and Gemini
3.8 Flash (ocr_truth.py); where the two agreed, the words went into the truth unreviewed, and only the 416 spans
where they disagreed were adjudicated by the owner. So each truth word is either AGREED (both drafters, nobody
looked) or ADJUDICATED (the owner chose or typed it). The audit's test (10-gap-audit.md §4 item 1, §5 item 4):

  1. split  — every route's word accuracy, recomputed on the agreed words and on the adjudicated words separately.
     A drafter's lead that sits in the agreed words is the bias the test looks for: there, a reading that shares
     the drafters' mistakes scores as right and a reading that gets the page right scores as wrong.
  2. sheet  — a blind re-adjudication sheet: 20 random pages where Qwen3.6-27B (the best open, third-family
     reader) reads the agreed text differently. Each difference is shown as two unlabelled readings in a random
     order; the owner picks the one the image shows, types a correction, or says either will do. Which reading is
     the truth is kept in a key file the sheet never loads. Each place carries a rough box on the page image, from
     Apple Vision's word positions (locate); a place with no aligned Vision word in reach says instead how far
     through the page's text it is. W46.fix-ocr-truth-bias-score scores the answers.

Word accuracy here: the scorer's words (ocr_panel_score.tokens of normal(), [illegible] dropped), the truth and a
reading aligned in order (difflib), and a truth word counts as read when it sits in an aligned equal run. This is
order-aware so that each truth word can be credited to its label; the panel's bag-of-words miss rate is the
order-blind version of the same figure. Pages a route failed (empty reading) are left out of that route's figures.

Writes segbench-results/ocr-truth-bias.md/.json (aggregate figures only: the repo is public and the pages are the
owner's). The sheet (index.html), its key (key.json) and the per-page detail go under ocr_truth.CACHE/blind/.
"""
from __future__ import annotations

import argparse
import difflib
import html
import json
import random
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import ocr_panel as P                      # noqa: E402
import ocr_panel_score as S                # noqa: E402
import ocr_rescore as RS                   # noqa: E402

T = P.T
RESULTS = HERE.parents[1] / 'segbench-results'
BLIND = T.CACHE / 'blind'
ANSWERS = T.CACHE / 'answers-applied.json'   # what `ocr_truth.py apply` built truth/ from
VISION_WORDS = T.CACHE / 'vision-words.json' # Apple Vision's word boxes for the 100 truth pages (F-placement.md)
REFERENCE = 'qwen3.6-27b'                    # the third-family reader the sheet is drawn against
SEED = 46
SHEET_PAGES = 20
PER_PAGE_MAX = 15       # differences shown per page; more are sampled, and the key says how many there were
CONTEXT = 5             # truth words shown either side of a difference
BLOCK_WORDS = 6         # a longer difference is a passage left out, added or moved: reading order, not reading
ANCHOR = 2              # aligned truth/Vision words in a run before the run places a box (one aligns by chance)
REACH = 40              # truth words either side searched for an anchor
SPREAD = 3              # Vision words either side of an interpolated place
BOOT = 2000
ILLEGIBLE = re.compile(r'\[illegible\]', re.I)
DRAFTER_FAMILY = ('claude', 'gemini')        # the drafters' families: a shared blind spot would favour these


def keys(word: str) -> list[str]:
    """The scorer's words for one raw word (usually one, none for punctuation or [illegible])."""
    return S.tokens(ILLEGIBLE.sub('', S.normal(word)))


def resolved(span: dict, answer) -> str:
    if 'agreed' in span:
        return span['agreed']
    return T.merge([span], {'0': answer}) or ''


def labelled_truth(page: dict, answers: dict) -> list[tuple[str, str]]:
    """[(raw word, 'agreed' | 'adjudicated')] for the page's truth, in order."""
    out = []
    for i, sp in enumerate(page['spans']):
        label = 'agreed' if 'agreed' in sp else 'adjudicated'
        out += [(w, label) for w in resolved(sp, answers.get(str(i))).split()]
    return out


def corrected(page: str, truth: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """The labelled truth carried onto truth/<page>.txt, which also has the corrections made after the adjudication
    (ocr_truth.CORRECTIONS, W46.truth-edits): words in an aligned equal run keep their label, the rest were set by
    the owner and are 'adjudicated'."""
    raw = (T.CACHE / 'truth' / f'{page}.txt').read_text().split()
    old = [w for w, _ in truth]
    if old == raw:
        return truth
    out = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, old, raw, autojunk=False).get_opcodes():
        out += truth[i1:i2] if op == 'equal' else [(w, 'adjudicated') for w in raw[j1:j2]]
    return out


def keyed(raw: list[str]) -> list[tuple[int, str]]:
    """[(index of the raw word, scorer word)]: usually one per raw word, none for punctuation or [illegible]."""
    return [(i, k) for i, w in enumerate(raw) for k in keys(w)]


def split_page(truth: list[tuple[str, str]], reading: str) -> dict:
    """Read and total truth words per label, over the scorer words. `_read` is strict (as the panel scores);
    `_joined` also counts as read the words of a difference that is only where the words break (a line-end
    hyphen kept or joined, "uni- versity" against "university"), which the drafters' convention decides."""
    tk = [(k, truth[i][1]) for i, k in keyed([w for w, _ in truth])]
    hk = S.tokens(ILLEGIBLE.sub('', S.normal(reading)))
    read, joined = [False] * len(tk), [False] * len(tk)
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, [k for k, _ in tk], hk, autojunk=False).get_opcodes():
        if op == 'equal':
            read[i1:i2] = joined[i1:i2] = [True] * (i2 - i1)
        elif i1 < i2 and ''.join(k for k, _ in tk[i1:i2]) == ''.join(hk[j1:j2]):
            joined[i1:i2] = [True] * (i2 - i1)
    out = {f'{lab}_{f}': 0 for lab in ('agreed', 'adjudicated') for f in ('n', 'read', 'joined')}
    for (_, lab), r, j in zip(tk, read, joined):
        out[lab + '_n'] += 1
        out[lab + '_read'] += r
        out[lab + '_joined'] += j
    return out


def pooled(rows):
    rows = list(rows)
    tot = {f'{lab}_{f}': sum(r[f'{lab}_{f}'] for r in rows)
           for lab in ('agreed', 'adjudicated') for f in ('n', 'read', 'joined')}
    acc = lambda lab, f='read': tot[f'{lab}_{f}'] / tot[lab + '_n'] if tot[lab + '_n'] else 0.
    return {**tot, 'agreed_acc': acc('agreed'), 'adjudicated_acc': acc('adjudicated'),
            'agreed_acc_joined': acc('agreed', 'joined'), 'adjudicated_acc_joined': acc('adjudicated', 'joined')}


def lead(rows_r, rows_q, rng):
    """The route's accuracy minus the reference's, on agreed and on adjudicated words, over the pages both answered,
    with a 95% page-bootstrap interval for each."""
    pages = sorted(set(rows_r) & set(rows_q))
    def d(sample):
        r, q = pooled([rows_r[p] for p in sample]), pooled([rows_q[p] for p in sample])
        return (r['agreed_acc'] - q['agreed_acc'], r['adjudicated_acc'] - q['adjudicated_acc'],
                r['agreed_acc_joined'] - q['agreed_acc_joined'])
    point = d(pages)
    boots = [d([rng.choice(pages) for _ in pages]) for _ in range(BOOT)]
    ci = lambda i: (sorted(b[i] for b in boots)[int(.025 * BOOT)], sorted(b[i] for b in boots)[int(.975 * BOOT) - 1])
    return {'pages': len(pages), 'lead_agreed': point[0], 'lead_agreed_ci': ci(0),
            'lead_adjudicated': point[1], 'lead_adjudicated_ci': ci(1),
            'lead_agreed_joined': point[2], 'lead_agreed_joined_ci': ci(2)}


def family(route: str) -> str:
    if route.startswith('drafter '):
        return 'drafter'
    return 'drafter family' if route.startswith(DRAFTER_FAMILY) else 'third family'


# ---- the sheet --------------------------------------------------------------------------------------------------

def differences(truth: list[tuple[str, str]], reading: str) -> list[dict]:
    """Where the reading differs from the AGREED truth words (case, punctuation and typography ignored, as the
    scorer ignores them). A difference wholly inside adjudicated words is left out: the owner has read those."""
    raw_t, raw_h = [w for w, _ in truth], reading.split()
    tk, hk = keyed(raw_t), keyed(raw_h)
    sm = difflib.SequenceMatcher(None, [k for _, k in tk], [k for _, k in hk], autojunk=False)
    out = []
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == 'equal':
            continue
        if i1 < i2:
            r0, r1 = tk[i1][0], tk[i2 - 1][0] + 1
            labs = {truth[i][1] for i in range(r0, r1)}
        else:   # the reading has words the truth lacks: judged by the truth words either side
            r0 = r1 = tk[i1][0] if i1 < len(tk) else len(raw_t)
            labs = {truth[tk[i][0]][1] for i in (i1 - 1, i1) if 0 <= i < len(tk)}
        if 'agreed' not in labs:
            continue
        # only where the words break: a convention, not a question for the photograph, so not on the sheet
        join = i1 < i2 and ''.join(k for _, k in tk[i1:i2]) == ''.join(k for _, k in hk[j1:j2])
        reading_words = ' '.join(raw_h[hk[j1][0]:hk[j2 - 1][0] + 1]) if j1 < j2 else ''
        out.append({'truth': ' '.join(raw_t[r0:r1]), 'qwen': reading_words,
                    'before': ' '.join(raw_t[max(0, r0 - CONTEXT):r0]), 'after': ' '.join(raw_t[r1:r1 + CONTEXT]),
                    'mixed': labs != {'agreed'}, 'join': join, 'block': max(i2 - i1, j2 - j1) > BLOCK_WORDS, 'truth_words': i2 - i1, 'qwen_words': j2 - j1,
                    't0': r0, 't1': r1})
    return out


def locate(raw_t: list[str], vision: list[list], t0: int, t1: int):
    """A rough box [x, y, w, h] (0-1, top left) on the page for truth words t0..t1-1, from Apple Vision's word boxes
    (vision-words.json, in Vision's reading order). The truth and Vision's words are aligned as the scorer's words,
    and only runs of ANCHOR or more aligned words, or a lone aligned word whose text occurs once in each, are
    trusted. The box holds the Vision words aligned to the place's own truth words; failing that, the place lies
    between the nearest trusted truth word on each side (within REACH words), so the box holds the Vision words
    between those two anchors, or, when they are far apart in Vision's order, a few words at the place's
    proportional position between them; with an anchor on one side only, the words just past it. Then only the
    words on the focus word's line are kept. None when no anchor is in reach. The box comes from the truth's
    positions and Vision's, never from either reading, so it says where to look and not which reading is the
    truth."""
    tk, vk = keyed(raw_t), [(i, k) for i, v in enumerate(vision) for k in keys(v[0])]
    tw, vw = [k for _, k in tk], [k for _, k in vk]
    at = {}
    for blk in difflib.SequenceMatcher(None, tw, vw, autojunk=False).get_matching_blocks():
        lone = blk.size and len(tw[blk.a]) >= 3 and tw.count(tw[blk.a]) == vw.count(tw[blk.a]) == 1
        if blk.size >= ANCHOR or lone:
            for n in range(blk.size):
                at.setdefault(tk[blk.a + n][0], []).append(vk[blk.b + n][0])
    idx = [v for i in range(t0, t1) for v in at.get(i, [])]
    focus = idx[len(idx) // 2] if idx else None
    if not idx:
        before = max((i for i in at if t0 - REACH <= i < t0), default=None)
        after = min((i for i in at if t1 <= i < t1 + REACH), default=None)
        vb = max(at[before]) if before is not None else None
        va = min(at[after]) if after is not None else None
        if vb is not None and va is not None and va < vb:   # the two orders disagree here: trust the nearer side
            vb, va = (vb, None) if t0 - before <= after - t1 else (None, va)
        if vb is not None and va is not None:
            if va - vb <= 2 * SPREAD + 2:
                idx = list(range(vb, va + 1))
            else:
                c = round(vb + (t0 - before) / (after - before) * (va - vb))
                idx = list(range(c - SPREAD, c + SPREAD + 1))
            focus = idx[len(idx) // 2]
        elif vb is not None:
            idx, focus = list(range(vb, vb + SPREAD + 1)), vb
        elif va is not None:
            idx, focus = list(range(va - SPREAD, va + 1)), va
    if focus is None:
        return None
    # Vision's order can run on into another column or block: keep the words within a line and a half of the focus
    mid, fh = vision[focus][2] + vision[focus][4] / 2, vision[focus][4]
    bx = [vision[i][1:] for i in idx if 0 <= i < len(vision) and abs(vision[i][2] + vision[i][4] / 2 - mid) <= 1.5 * fh]
    x0, y0 = min(b[0] for b in bx), min(b[1] for b in bx)
    x1, y1 = max(b[0] + b[2] for b in bx), max(b[1] + b[3] for b in bx)
    return [round(v, 4) for v in (x0, y0, x1 - x0, y1 - y0)]


def build_sheet(pages96, truths, qwen, rng):
    vision = json.loads(VISION_WORDS.read_text())
    every = {p: differences(truths[p], qwen[p]) for p in pages96 if qwen.get(p)}
    diffs = {p: [x for x in d if not (x['join'] or x['block'])] for p, d in every.items()}
    eligible = sorted(p for p, d in diffs.items() if d)
    chosen = sorted(rng.sample(eligible, min(SHEET_PAGES, len(eligible))))
    data, key = [], {}
    for p in chosen:
        d = diffs[p]
        shown = sorted(rng.sample(range(len(d)), min(PER_PAGE_MAX, len(d))))
        items = []
        for n, i in enumerate(shown):
            x = d[i]
            truth_first = rng.random() < .5
            a, b = (x['truth'], x['qwen']) if truth_first else (x['qwen'], x['truth'])
            box = locate([w for w, _ in truths[p]], vision.get(p, []), x['t0'], x['t1'])
            items.append({'id': str(n), 'before': x['before'], 'after': x['after'], 'a': a, 'b': b, 'box': box,
                          'at': round(x['t0'] / max(1, len(truths[p])), 2)})
            key.setdefault(p, {'differences': len(d), 'shown': len(shown), 'items': {}})['items'][str(n)] = {
                'a': 'truth' if truth_first else 'qwen', **x}
        data.append({'page': p, 'img': f'../pages/{p}.jpg', 'items': items})
    n_items = sum(len(x['items']) for x in data)
    minutes = (len(data) * T.SECONDS_PER_PAGE + n_items * (T.SECONDS_PER_DISPUTE + T.TYPED_SHARE * T.SECONDS_PER_TYPED)) / 60
    BLIND.mkdir(parents=True, exist_ok=True)
    if (BLIND / 'answers.json').exists():
        # the owner has answered this sheet: its key and differences are what the score reads, so a rerun (on a
        # truth since corrected, ocr_truth.CORRECTIONS) must not replace them
        print(f'{BLIND} is answered: sheet, key and differences left as they are', file=sys.stderr)
    else:
        write_sheet(data, key, every, eligible, n_items, minutes)
    per_page = sorted(len(d) for d in diffs.values())
    return {'joins': sum(x['join'] for d in every.values() for x in d),
            'blocks': sum(x['block'] and not x['join'] for d in every.values() for x in d),
            'eligible_pages': len(eligible), 'answered_pages': len(diffs), 'chosen': len(chosen),
            'items': n_items, 'minutes': minutes, 'differences_total': sum(per_page),
            'differences_on_chosen': sum(len(diffs[p]) for p in chosen),
            'differences_median_page': per_page[len(per_page) // 2] if per_page else 0,
            'mixed_items': sum(v['mixed'] for k in key.values() for v in k['items'].values()),
            'boxed_items': sum(x['box'] is not None for d in data for x in d['items'])}


def write_sheet(data, key, every, eligible, n_items, minutes):
    (BLIND / 'index.html').write_text(SHEET_HTML.replace('__DATA__', json.dumps(data, ensure_ascii=False))
                                      .replace('__MINUTES__', f'{minutes:.0f}').replace('__N__', str(n_items))
                                      .replace('__PAGES__', str(len(data))))
    (BLIND / 'key.json').write_text(json.dumps({'reference': REFERENCE, 'seed': SEED, 'eligible': eligible,
                                                'pages': key}, indent=1))
    (BLIND / 'differences.json').write_text(json.dumps(every, ensure_ascii=False, indent=1))


SHEET_HTML = r"""<!doctype html><meta charset="utf-8"><title>W46 blind truth check</title>
<style>
body{font:14px -apple-system,sans-serif;margin:0;background:#fff;color:#111;color-scheme:light}
header{position:sticky;top:0;background:#fff;border-bottom:1px solid #ccc;padding:6px 12px;z-index:2}
.page{display:flex;gap:12px;border-bottom:3px solid #999;padding:10px;min-height:90vh}
.img{flex:1 1 55%;position:sticky;top:var(--head,44px);height:calc(100vh - var(--head,44px) - 20px);overflow:auto}
.frame{position:relative;width:100%;cursor:zoom-in}.frame.zoom{width:250%;cursor:zoom-out}.frame img{width:100%;display:block}
.box{position:absolute;border:3px solid #f0a;border-radius:4px;box-shadow:0 0 0 2000px rgba(0,0,0,.12);pointer-events:none;display:none}
.where{color:#a40;font-size:12px;display:block}
.list{flex:1 1 45%}.it{scroll-margin:var(--head,44px) 0 10px;border:1px solid #ccc;border-radius:4px;padding:6px;margin:8px 0;font-family:Georgia,serif}
.it.cur{outline:3px solid #06f}.it.done{background:#e6f6e6;border-color:#4a4}
.ctx{color:#777}.opt{display:block;margin:3px 0;font-family:-apple-system,sans-serif}.opt.sel{font-weight:bold;color:#060}
.k{color:#888;font-size:12px}.typed{color:#a40}
</style>
<header><b>Blind truth check</b> — __N__ places on __PAGES__ pages, about __MINUTES__ minutes. Two readings of the same
words; which reading is which is not shown. Pick the one the photograph shows.
Keys: <b>1</b> A · <b>2</b> B · <b>3</b> neither (type it) · <b>4</b> either will do / can't tell · <b>n/p</b> next/previous · <b>z</b> zoom.
The pink box marks roughly where each place is (from Apple Vision's word positions; it can be off by a line or so).
Click the image or press <b>z</b> to zoom. Answers stay in this browser; <button onclick="exportAnswers()">Export answers</button>
<span id="prog"></span></header><div id="root"></div>
<script>
const DATA=__DATA__;const KEY='w46-truth-bias-blind';
let A=JSON.parse(localStorage.getItem(KEY)||'{}');const items=[];
function esc(s){return s.replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
function save(){localStorage.setItem(KEY,JSON.stringify(A));prog()}
function prog(){const d=items.filter(it=>ans(it)!==undefined).length;document.getElementById('prog').textContent=` ${d} / ${items.length} answered`}
function ans(it){return (A[it.page]||{})[it.key]}
function set(it,v){(A[it.page]=A[it.page]||{})[it.key]=v;save();paint(it)}
function paint(it){const v=ans(it);it.el.classList.toggle('done',v!==undefined);
 it.el.querySelectorAll('.opt').forEach(o=>o.classList.toggle('sel',o.dataset.v===v));
 it.el.querySelector('.typed').textContent=v&&v.startsWith('=')?'typed: '+v.slice(1):(v==='either'?'either will do':'')}
const root=document.getElementById('root');
for(const p of DATA){const div=document.createElement('div');div.className='page';
 let h=`<div class="img"><div class="frame"><img src="${p.img}"><div class="box"></div></div></div><div class="list"><b>${p.page}</b>`;
 for(const x of p.items){h+=`<div class="it" data-key="${x.id}"><span class="ctx">… ${esc(x.before)}</span> <b>[ ]</b> <span class="ctx">${esc(x.after)} …</span>`+
  (x.box?'':`<span class="where">No box for this place: it is about ${Math.round(100*x.at)}% of the way through the page's text.</span>`)+
  `<span class="opt" data-v="a"><span class="k">1 A:</span> ${esc(x.a)||'<i>(nothing)</i>'}</span>`+
  `<span class="opt" data-v="b"><span class="k">2 B:</span> ${esc(x.b)||'<i>(nothing)</i>'}</span><span class="typed"></span></div>`}
 div.innerHTML=h+'</div>';root.appendChild(div);
 const frame=div.querySelector('.frame');frame.onclick=()=>{frame.classList.toggle('zoom');if(items[cur]&&items[cur].frame===frame)show(items[cur])};
 div.querySelectorAll('.it').forEach(el=>{const x=p.items.find(x=>x.id===el.dataset.key);
  const it={page:p.page,key:el.dataset.key,el,box:x.box,pane:div.querySelector('.img'),frame,mark:div.querySelector('.box')};items.push(it);paint(it);
  el.addEventListener('click',()=>go(items.indexOf(it)))})}
let cur=0,first=true;function go(i){if(i<0||i>=items.length)return;const prev=first?null:items[cur];first=false;items[cur].el.classList.remove('cur');cur=i;
 const el=items[cur].el;el.classList.add('cur');
 if(!prev||prev.page!==items[cur].page)el.closest('.page').scrollIntoView({block:'start'});
 el.scrollIntoView({block:'nearest'});show(items[cur])}
function head(){const h=document.querySelector('header').offsetHeight;document.documentElement.style.setProperty('--head',h+'px');
 document.querySelectorAll('.page').forEach(d=>d.style.scrollMarginTop=h+'px')}
addEventListener('resize',head);head();
const PAD=.012;
function show(it){if(!it)return;const m=it.mark,b=it.box;if(!b){m.style.display='none';return}
 const w=Math.max(b[2]+2*PAD,.08),h=Math.max(b[3]+2*PAD,.03),x=Math.max(0,b[0]+b[2]/2-w/2),y=Math.max(0,b[1]+b[3]/2-h/2);
 Object.assign(m.style,{display:'block',left:100*x+'%',top:100*y+'%',width:100*w+'%',height:100*h+'%'});
 const f=it.frame,pane=it.pane,centre=()=>{pane.scrollTop=(y+h/2)*f.offsetHeight-pane.clientHeight/2;
  pane.scrollLeft=(x+w/2)*f.offsetWidth-pane.clientWidth/2};
 const img=f.querySelector('img');if(img.complete)centre();else img.addEventListener("load",centre,{once:true})}
document.addEventListener('keydown',e=>{const it=items[cur];if(!it)return;
 if(e.key==='n')go(cur+1);else if(e.key==='z'){it.frame.classList.toggle('zoom');show(it)}else if(e.key==='p')go(cur-1);
 else if(e.key==='1'){set(it,'a');go(cur+1)}else if(e.key==='2'){set(it,'b');go(cur+1)}
 else if(e.key==='4'){set(it,'either');go(cur+1)}
 else if(e.key==='3'){const t=prompt('What the photograph shows here (empty = nothing):','');if(t!==null){set(it,'='+t);go(cur+1)}}});
function exportAnswers(){const b=new Blob([JSON.stringify(A,null,1)],{type:'application/json'});
 const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='truth-bias-blind-answers.json';a.click()}
prog();go(0);
</script>"""


# ---- report -----------------------------------------------------------------------------------------------------

def pc(x, d=2):
    return f'{100 * x:.{d}f}'


def write_md(path, out):
    s, sh = out['split'], out['sheet']
    tot = out['truth']
    L = ['# The 96\'s truth bias: agreed against adjudicated words (W46.fix-ocr-truth-bias)', '',
         'Generated by `scripts/segbench/ocr_truth_bias.py` from saved readings only: no call, no money. '
         f'The truth of the owner\'s 96 pages has {tot["words"]:,} scored words; {tot["agreed"]:,} '
         f'({pc(tot["agreed"] / tot["words"], 1)}%) are words both drafters (Claude Opus 5.5 and Gemini 3.8 Flash) '
         f'wrote the same and nobody reviewed, and {tot["adjudicated"]:,} ({pc(tot["adjudicated"] / tot["words"], 1)}%) '
         f'come from the {tot["spans"]} spans the owner adjudicated. The figures below count, per route, the share '
         'of each kind of truth word the reading has in the right order (pages the route failed are left out). '
         f'The lead columns are the route minus {REFERENCE} on the pages both answered, with a 95% page-bootstrap '
         'interval.', '',
         'How to read it: the drafters score 100% on the agreed words by construction. If the truth carries the '
         'drafters\' shared mistakes, a drafter-family route gains on the agreed words a lead it does not show on '
         'the adjudicated ones, and a third-family route loses points there for reading the page right. The split '
         'cannot say which reading is right where they differ; the blind sheet below asks the owner.', '',
         f'| route | family | pages | agreed % | agreed %, joins forgiven | adjudicated % | lead on agreed (pts) '
         '| lead on agreed, joins forgiven | lead on adjudicated (pts) |',
         '|---|---|--:|--:|--:|--:|--:|--:|--:|']
    for r in s:
        ld = r.get('lead')
        f = lambda k: (f'{100 * ld[k]:+.2f} [{100 * ld[k + "_ci"][0]:+.2f}, {100 * ld[k + "_ci"][1]:+.2f}]'
                       if ld else '—')
        L.append(f'| {r["route"]} | {r["family"]} | {r["pages"]} | {pc(r["agreed_acc"])} | {pc(r["agreed_acc_joined"])} '
                 f'| {pc(r["adjudicated_acc"])} | {f("lead_agreed")} | {f("lead_agreed_joined")} | {f("lead_adjudicated")} |')
    g = out['by_family']
    L += ['', '## By family', '',
          'Mean over routes answering at least 90 of the 96 pages (the drafters\' own drafts left out).', '',
          '| family | routes | agreed % | agreed %, joins forgiven | adjudicated % | lead on agreed, joins forgiven (pts) |',
          '|---|--:|--:|--:|--:|--:|']
    for fam, v in g.items():
        L.append(f'| {fam} | {v["routes"]} | {pc(v["agreed_acc"])} | {pc(v["agreed_acc_joined"])} | '
                 f'{pc(v["adjudicated_acc"])} | {100 * v["lead_agreed_joined"]:+.2f} |')
    q = next(r for r in s if r['route'] == REFERENCE)
    top = [r for r in s if r['family'] == 'drafter family' and r['pages'] >= 90]
    mean = lambda k: sum(r['lead'][k] for r in top) / len(top)
    L += ['', '## What it shows', '',
          f'The drafter-family routes lead {REFERENCE} on the agreed words by {100 * mean("lead_agreed"):+.2f} points '
          f'on average, and by {100 * mean("lead_agreed_joined"):+.2f} once a line-end hyphen kept or joined is '
          'forgiven: most of the strict lead is the drafters\' convention of keeping the hyphen, which the S0 score '
          'does not join. What remains is the most the bias could explain. '
          f'{REFERENCE} misses {pc(1 - q["agreed_acc_joined"])}% of the agreed words with joins forgiven; if every '
          'one of those were the truth\'s mistake rather than the reader\'s, its score on the agreed words would rise '
          'by that much, and if none were, there is no bias. The adjudicated words do not settle it: they are the '
          'hard places where the drafters disagreed, so every route scores far lower there, and with '
          f'{tot["adjudicated"]} words the intervals are wide. The blind pass below measures the share directly.']
    L += ['', '## The blind re-adjudication sheet', '',
          f'{REFERENCE} answered {sh["answered_pages"]} of the 96 pages and reads the agreed text differently on '
          f'{sh["eligible_pages"]} of them ({sh["differences_total"]} places; median {sh["differences_median_page"]} '
          f'per page), case, punctuation and typography ignored as the scorer ignores them, and leaving out '
          f'{sh["joins"]} places that differ only in where the words break (a line-end hyphen kept or joined) and '
          f'{sh["blocks"]} longer than {BLOCK_WORDS} words on either side (a passage left out, added or moved, which '
          'is reading order rather than reading). The sheet takes '
          f'{sh["chosen"]} of those pages at random (seed {SEED}) and at most {PER_PAGE_MAX} places on each, '
          f'{sh["items"]} places in all ({sh["differences_on_chosen"]} exist on those pages; {sh["mixed_items"]} touch '
          f'an adjudicated word as well). Each place shows the two readings as A and B in a random order. About '
          f'{sh["minutes"]:.0f} minutes at ocr_truth.py\'s review rates. {sh["boxed_items"]} of the places carry a rough box '
          'on the page image, taken from Apple Vision\'s word positions; the rest say how far through the page\'s text '
          'they are. The sheet and its key are private, under '
          '`ocr-truth/blind/`; W46.fix-ocr-truth-bias-score scores the owner\'s answers.', '']
    path.write_text('\n'.join(L) + '\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', type=Path, default=RESULTS)
    a = ap.parse_args()
    answers = json.loads(ANSWERS.read_text())
    compare = {p['page']: p for p in json.loads((T.CACHE / 'compare.json').read_text()) if 'spans' in p}
    pages96 = [r['page'] for r in P.rows() if r['page'] not in P.AGREEMENT]
    truths = {p: corrected(p, labelled_truth(compare[p], answers.get(p, {}))) for p in pages96}
    for p in pages96:   # the labelled words must be exactly the words the panel scores
        whole = S.tokens(ILLEGIBLE.sub('', S.normal((T.CACHE / 'truth' / f'{p}.txt').read_text())))
        if [k for _, k in keyed([w for w, _ in truths[p]])] != whole:
            raise SystemExit(f'{p}: labelled truth differs from truth/{p}.txt')
    src = {route: texts for (route, _), texts in RS.owner_sources().items()}
    src['drafter claude-opus5.5'] = {p: compare[p]['texts']['claude'] for p in pages96}
    src['drafter gemini3.8-flash'] = {p: compare[p]['texts']['gemini'] for p in pages96}
    per = {route: {p: split_page(truths[p], texts[p]) for p in pages96 if texts.get(p)} for route, texts in src.items()}
    rng = random.Random(SEED)
    split = []
    for route, rows in per.items():
        if not rows:
            continue
        r = {'route': route, 'family': family(route), 'pages': len(rows), **pooled(rows.values())}
        if route != REFERENCE:
            r['lead'] = lead(rows, per[REFERENCE], rng)
        split.append(r)
    split.sort(key=lambda r: -r['agreed_acc'])
    by_family = {}
    for fam in ('drafter family', 'third family'):
        rr = [r for r in split if r['family'] == fam and r['pages'] >= 90]
        if rr:
            by_family[fam] = {'routes': len(rr), **{k: sum(r[k] for r in rr) / len(rr) for k in (
                'agreed_acc', 'agreed_acc_joined', 'adjudicated_acc')},
                'lead_agreed_joined': sum(r['lead']['lead_agreed_joined'] for r in rr if 'lead' in r) / len(rr)}
    labs = [truths[p][i][1] for p in pages96 for i, _ in keyed([w for w, _ in truths[p]])]
    tot = {'words': len(labs), 'agreed': labs.count('agreed'),
           'spans': sum(1 for p in pages96 for s in compare[p]['spans'] if 'agreed' not in s)}
    tot['adjudicated'] = tot['words'] - tot['agreed']
    sheet = build_sheet(pages96, truths, src[REFERENCE], random.Random(SEED))
    out = {'truth': tot, 'reference': REFERENCE, 'split': split, 'by_family': by_family, 'sheet': sheet}
    a.out.mkdir(parents=True, exist_ok=True)
    (a.out / 'ocr-truth-bias.json').write_text(json.dumps(out, indent=1))
    write_md(a.out / 'ocr-truth-bias.md', out)
    print(f'{len(split)} routes; sheet {sheet["items"]} places on {sheet["chosen"]} pages, ~{sheet["minutes"]:.0f} min '
          f'-> {BLIND / "index.html"}')


if __name__ == '__main__':
    main()
