#!/usr/bin/env python3
"""W46.ocr-hands-sheet. The blind handwriting sheet for the 96's 16 hand pages, with typed controls.

  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy python ocr_hands_sheet.py build
  ... python ocr_hands_sheet.py fold ANSWERS.json      # the owner's exported answers -> rulings.json

Reads saved files only: no model, no network, no money, and no Claude reader looks at a page. The measurement audit
(11-measurement-audit.md, OCR-1 and OCR-4): Gemini 3.8 Flash drafted the 96's truth with Claude Opus 5.5 and leads
on its 16 hand pages, so the hand ranking is partly the drafter scoring itself, and the earlier blind check
(ocr_truth_bias.py) drew about 3 hand pages and only looked where Qwen3.6-27B differed. This sheet asks two things:

  hands     every place on the 16 hand pages (kind handwritten, the 19 less the three agreement pages) where a
            third-family reader, Qwen3.6-27B or LightOnOCR-3 4B, reads the truth differently: agreed words and
            adjudicated words both, since a third reading neither drafter offered is what the owner's first pass
            never saw. One reader's differences that overlap the other's are merged into one place over the
            union of the truth words, so a place shows every distinct reading of it (two or three), unlabelled, in
            a random order. Differences only in where the words break (a line-end hyphen kept or joined) are left
            out, as in the earlier sheet; so are those longer than BLOCK_WORDS words on a side (a passage left
            out, added or moved: reading order, not reading). The key records both counts.
  controls  20 passages of CONTROL_WORDS words drawn at random (seed) from the typed pages' agreed words where both
            readers read the truth word for word, the part no check has looked at. Each shows its one reading,
            which every reader and both drafters share, so nothing on it tells it apart from any other reading;
            the owner confirms it or types what the photograph shows.

Boxes: on the hand pages and on the typed pages in the placement truth (place_truth.py STORE), each truth word's own
box, aligned to the truth by the scorer's words, and the place's box is the union of its words' boxes on the focus
line (a reading with words the truth lacks takes the neighbours'). Elsewhere, ocr_truth_bias.locate (Apple Vision's
word positions); failing both, the sheet says how far through the page's text the place is. A box is drawn from the
truth's word positions, never from a reading's text, and every reading of a place shares it, so it does not tell
which reading is the truth.

Writes ocr_truth.CACHE/hands/ (index.html, key.json; private: the pages are the owner's) and
segbench-results/ocr-hands-sheet.md (counts only). W46.ocr-hands-rescore folds the answers.
"""
from __future__ import annotations

import argparse
import difflib
import json
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import ocr_panel as P                      # noqa: E402
import ocr_rescore as RS                   # noqa: E402
import ocr_truth_bias as B                 # noqa: E402

T = P.T
RESULTS = HERE.parents[1] / 'segbench-results'
OUT = T.CACHE / 'hands'
PLACE = Path.home() / 'Library/Application Support/ArchiveSuiteRehearsal/place-truth'
READERS = ('qwen3.6-27b', 'lightonocr3-4b')   # the third-family readers the audit names
SEED = 20261030
CONTROLS = 20
CONTROL_WORDS = 8
CONTEXT = B.CONTEXT
BLOCK_WORDS = B.BLOCK_WORDS
EXCLUDED = {'p081'}                          # owner: cannot correct it (ocr_truth_bias_score.EXCLUDED)


def page_kinds() -> dict[str, str]:
    return {r['page']: r['kind'] for r in P.rows()}


# ---- places -----------------------------------------------------------------------------------------------------

def ops(tw: list[str], hw: list[str]):
    return difflib.SequenceMatcher(None, tw, hw, autojunk=False).get_opcodes()


def places(tw: list[str], readings: dict[str, list[str]]) -> list[dict]:
    """Merged places over the truth's scorer words `tw`. Each reader's non-equal opcodes are intervals [i1, i2] on
    the truth (an insertion is the point i1); intervals that overlap or touch, from either reader, are joined. A
    place is (a, b) on the truth and, per reader, its span (j0, j1) on that reader's words."""
    spans = []
    al = {}
    for name, hw in readings.items():
        al[name] = ops(tw, hw)
        spans += [(i1, i2) for op, i1, i2, _, _ in al[name] if op != 'equal']
    spans.sort()
    merged = []
    for a, b in spans:
        if merged and a <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    out = []
    for a, b in merged:
        per = {}
        for name, oc in al.items():
            per[name] = (lo(oc, a), hi(oc, b))
        out.append({'a': a, 'b': b, 'spans': per})
    return out


def lo(oc, t: int) -> int:
    """The first reader word at truth boundary t (an insertion at t falls inside)."""
    for op, i1, i2, j1, j2 in oc:
        if op == 'equal' and i1 <= t <= i2:
            return j1 + t - i1
        if op != 'equal' and i1 <= t <= i2:
            return j1
    return oc[-1][4] if oc else 0


def hi(oc, t: int) -> int:
    """The reader word just past truth boundary t (an insertion at t falls inside)."""
    for op, i1, i2, j1, j2 in reversed(oc):
        if op == 'equal' and i1 <= t <= i2:
            return j1 + t - i1
        if op != 'equal' and i1 <= t <= i2:
            return j2
    return 0


def raw_range(keyed: list[tuple[int, str]], a: int, b: int, n_raw: int) -> tuple[int, int]:
    """Raw word range for scorer words a..b-1; an empty range sits before raw word of scorer word a."""
    if a < b:
        return keyed[a][0], keyed[b - 1][0] + 1
    r = keyed[a][0] if a < len(keyed) else n_raw
    return r, r


def hand_places(truth: list[tuple[str, str]], texts: dict[str, str]) -> list[dict]:
    raw_t = [w for w, _ in truth]
    tk = B.keyed(raw_t)
    tw = [k for _, k in tk]
    raw_h = {n: t.split() for n, t in texts.items()}
    hk = {n: B.keyed(w) for n, w in raw_h.items()}
    out = []
    for pl in places(tw, {n: [k for _, k in v] for n, v in hk.items()}):
        a, b = pl['a'], pl['b']
        r0, r1 = raw_range(tk, a, b, len(raw_t))
        readings = {'truth': ' '.join(raw_t[r0:r1])}
        norm = {'truth': ''.join(tw[a:b])}
        width = b - a
        for n, (j0, j1) in pl['spans'].items():
            s0, s1 = raw_range(hk[n], j0, j1, len(raw_h[n]))
            readings[n] = ' '.join(raw_h[n][s0:s1])
            norm[n] = ''.join(k for _, k in hk[n][j0:j1])
            width = max(width, j1 - j0)
        labs = {truth[i][1] for i in range(r0, r1)} or {truth[i][1] for i in (r0 - 1, r0) if 0 <= i < len(truth)}
        # options: distinct readings by the scorer's words, spaces ignored (a join is the same reading)
        opts = {}
        for n in readings:
            opts.setdefault(norm[n], []).append(n)
        out.append({'t0': r0, 't1': r1, 'readings': readings, 'options': list(opts.values()),
                    'before': ' '.join(raw_t[max(0, r0 - CONTEXT):r0]), 'after': ' '.join(raw_t[r1:r1 + CONTEXT]),
                    'labels': sorted(labs), 'join': len(opts) == 1, 'block': width > BLOCK_WORDS})
    return out


# ---- controls ---------------------------------------------------------------------------------------------------

def control_starts(truth: list[tuple[str, str]], texts: dict[str, str]) -> list[int]:
    """Scorer-word positions s where words s..s+CONTROL_WORDS-1 are all agreed and every reader reads them in an
    equal run."""
    tk = B.keyed([w for w, _ in truth])
    tw = [k for _, k in tk]
    ok = [truth[i][1] == 'agreed' for i, _ in tk]
    for t in texts.values():
        eq = [False] * len(tw)
        for op, i1, i2, _, _ in ops(tw, [k for _, k in B.keyed(t.split())]):
            if op == 'equal':
                eq[i1:i2] = [True] * (i2 - i1)
        ok = [x and y for x, y in zip(ok, eq)]
    run, out = 0, []
    for i, x in enumerate(ok):
        run = run + 1 if x else 0
        if run >= CONTROL_WORDS:
            out.append(i - CONTROL_WORDS + 1)
    return out


def draw_controls(starts: dict[str, list[int]], rng) -> list[tuple[str, int]]:
    """CONTROLS passages, uniform over every eligible start on every page, none overlapping another."""
    pool = sorted((p, s) for p, ss in starts.items() for s in ss)
    rng.shuffle(pool)
    out = []
    for p, s in pool:
        if all(q != p or abs(s - t) >= CONTROL_WORDS for q, t in out):
            out.append((p, s))
        if len(out) == CONTROLS:
            break
    return sorted(out)


# ---- boxes ------------------------------------------------------------------------------------------------------

def place_words(page: str):
    f = PLACE / f'{page}.json'
    return json.loads(f.read_text())['words'] if f.exists() else None


def box_from_place(raw_t: list[str], pw: list[dict], t0: int, t1: int):
    """Union of the placement truth's boxes for truth words t0..t1-1 (for an empty range, the words either side),
    kept to the focus word's line. None when no word in the place has a box."""
    tk = B.keyed(raw_t)
    pk = [(i, k) for i, w in enumerate(pw) for k in B.keys(w['text'])]
    at = {}
    for blk in difflib.SequenceMatcher(None, [k for _, k in tk], [k for _, k in pk], autojunk=False).get_matching_blocks():
        for n in range(blk.size):
            at.setdefault(tk[blk.a + n][0], pk[blk.b + n][0])
    want = range(t0, t1) if t1 > t0 else (t0 - 1, t0)
    idx = [at[i] for i in want if i in at and pw[at[i]].get('box')]
    if not idx:
        return None
    line = pw[idx[len(idx) // 2]].get('line')
    bx = [pw[i]['box'] for i in idx if pw[i].get('line') == line]
    x0, y0 = min(b[0] for b in bx), min(b[1] for b in bx)
    x1, y1 = max(b[0] + b[2] for b in bx), max(b[1] + b[3] for b in bx)
    return [round(v, 4) for v in (x0, y0, x1 - x0, y1 - y0)]


def box(page, raw_t, t0, t1, vision):
    pw = place_words(page)
    if pw:
        b = box_from_place(raw_t, pw, t0, t1)
        if b:
            return b, 'placement truth'
    b = B.locate(raw_t, vision.get(page, []), t0, t1)
    return (b, 'vision') if b else (None, None)


# ---- the sheet --------------------------------------------------------------------------------------------------

def build(out_dir: Path, results: Path):
    if (out_dir / 'answers.json').exists():
        raise SystemExit(f'{out_dir} is answered: its key is what the answers mean, so it is not rebuilt')
    kinds = page_kinds()
    answers = json.loads(B.ANSWERS.read_text())
    compare = {p['page']: p for p in json.loads((T.CACHE / 'compare.json').read_text()) if 'spans' in p}
    pages96 = [p for p in kinds if p not in P.AGREEMENT]
    hands = sorted(p for p in pages96 if kinds[p] == 'handwritten')
    typed = sorted(p for p in pages96 if kinds[p] in ('typewritten', 'printed') and p not in EXCLUDED)
    truths = {p: B.corrected(p, B.labelled_truth(compare[p], answers.get(p, {}))) for p in hands + typed}
    for p in truths:   # the labelled words must be exactly the words the panel scores
        whole = B.S.tokens(B.ILLEGIBLE.sub('', B.S.normal((T.CACHE / 'truth' / f'{p}.txt').read_text())))
        if [k for _, k in B.keyed([w for w, _ in truths[p]])] != whole:
            raise SystemExit(f'{p}: labelled truth differs from truth/{p}.txt')
    src = {route: texts for (route, _), texts in RS.owner_sources().items() if route in READERS}
    if set(src) != set(READERS):
        raise SystemExit(f'missing readings: {set(READERS) - set(src)}')
    vision = json.loads(B.VISION_WORDS.read_text())
    rng = random.Random(SEED)

    data, key, stats = [], {'seed': SEED, 'readers': READERS, 'hand_pages': hands, 'pages': {}}, {}
    every, failed = {}, {}
    for p in hands:
        texts = {n: src[n].get(p) or '' for n in READERS}
        failed[p] = [n for n, t in texts.items() if not t.strip()]
        every[p] = hand_places(truths[p], {n: t for n, t in texts.items() if t.strip()})
    for p in hands:
        shown = [x for x in every[p] if not (x['join'] or x['block'])]
        if not shown:
            continue
        raw_t = [w for w, _ in truths[p]]
        items, kp = [], {}
        for n, x in enumerate(shown):
            order = rng.sample(range(len(x['options'])), len(x['options']))
            opts = []
            for o in order:
                srcs = x['options'][o]
                opts.append({'text': x['readings'][rng.choice(srcs)], 'sources': srcs})
            b, how = box(p, raw_t, x['t0'], x['t1'], vision)
            iid = f'h{n:02d}'
            items.append({'id': iid, 'before': x['before'], 'after': x['after'], 'opts': [o['text'] for o in opts],
                          'box': b, 'at': round(x['t0'] / max(1, len(raw_t)), 2)})
            kp[iid] = {'kind': 'hand', 'options': [o['sources'] for o in opts], 'readings': x['readings'],
                       'labels': x['labels'], 't0': x['t0'], 't1': x['t1'], 'box_from': how}
        data.append({'page': p, 'img': f'../pages/{p}.jpg', 'items': items})
        key['pages'][p] = {'places': len(every[p]), 'shown': len(shown), 'failed_readers': failed[p], 'items': kp}

    starts = {p: control_starts(truths[p], {n: src[n].get(p) or '' for n in READERS})
              for p in typed if all((src[n].get(p) or '').strip() for n in READERS)}
    chosen = draw_controls(starts, rng)
    cdata = {}
    for n, (p, s) in enumerate(chosen):
        raw_t = [w for w, _ in truths[p]]
        tk = B.keyed(raw_t)
        r0, r1 = raw_range(tk, s, s + CONTROL_WORDS, len(raw_t))
        b, how = box(p, raw_t, r0, r1, vision)
        iid = f'c{n:02d}'
        cdata.setdefault(p, []).append({'id': iid, 'before': ' '.join(raw_t[max(0, r0 - CONTEXT):r0]),
                                        'after': ' '.join(raw_t[r1:r1 + CONTEXT]),
                                        'opts': [' '.join(raw_t[r0:r1])], 'box': b,
                                        'at': round(r0 / max(1, len(raw_t)), 2)})
        key['pages'].setdefault(p, {'items': {}})['items'][iid] = {
            'kind': 'control', 'options': [['truth'] + list(READERS)], 'readings': {'truth': ' '.join(raw_t[r0:r1])},
            'labels': ['agreed'], 't0': r0, 't1': r1, 'box_from': how}
    for p in sorted(cdata):
        data.append({'page': p, 'img': f'../pages/{p}.jpg', 'items': cdata[p]})
    rng.shuffle(data)   # the controls' pages are mixed among the hand pages

    all_items = [x for d in data for x in d['items']]
    n_hand = sum(1 for x in all_items if x['id'][0] == 'h')
    secs = (len(data) * T.SECONDS_PER_PAGE + n_hand * (T.SECONDS_PER_DISPUTE + T.TYPED_SHARE * T.SECONDS_PER_TYPED)
            + len(chosen) * T.SECONDS_PER_DISPUTE)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / 'index.html').write_text(SHEET_HTML.replace('__DATA__', json.dumps(data, ensure_ascii=False))
                                        .replace('__MINUTES__', f'{secs / 60:.0f}').replace('__N__', str(len(all_items)))
                                        .replace('__PAGES__', str(len(data))))
    (out_dir / 'key.json').write_text(json.dumps(key, ensure_ascii=False, indent=1))
    allp = [x for p in hands for x in every[p]]
    hk = [v for p in hands for v in key['pages'].get(p, {}).get('items', {}).values()]
    stats = {'hand_pages': len(hands), 'hand_pages_with_places': sum(1 for p in hands if p in key['pages']),
             'failed_readings': {p: f for p, f in failed.items() if f},
             'places_total': len(allp), 'joins': sum(x['join'] for x in allp),
             'blocks': sum(x['block'] and not x['join'] for x in allp), 'hand_items': n_hand,
             'three_way': sum(len(v['options']) == 3 for v in hk),
             'agreed_only': sum(v['labels'] == ['agreed'] for v in hk),
             'touch_adjudicated': sum('adjudicated' in v['labels'] for v in hk),
             'per_reader': {n: sum(any(n in o and 'truth' not in o for o in v['options']) for v in hk) for n in READERS},
             'controls': len(chosen), 'control_pages': len(cdata), 'typed_pages': len(typed),
             'control_starts': sum(len(s) for s in starts.values()),
             'box_from': {w: sum(1 for d in key['pages'].values() for v in d['items'].values() if v['box_from'] == w)
                          for w in ('placement truth', 'vision', None)},
             'pages_on_sheet': len(data), 'minutes': secs / 60}
    results.mkdir(parents=True, exist_ok=True)
    write_md(results / 'ocr-hands-sheet.md', stats)
    return stats


SHEET_HTML = r"""<!doctype html><meta charset="utf-8"><title>W46 blind handwriting check</title>
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
<header><b>Blind handwriting check</b> — __N__ places on __PAGES__ pages, about __MINUTES__ minutes. Each place shows
the readings of the same words; which reading is which is not shown. Pick the one the photograph shows; a place with
one reading asks whether it is right.
Keys: <b>1</b>–<b>3</b> pick that reading · <b>t</b> none is right (type it) · <b>e</b> either will do / can't tell ·
<b>n/p</b> next/previous · <b>z</b> zoom. The pink box marks roughly where each place is (it can be off by a line or so).
Answers stay in this browser; <button onclick="exportAnswers()">Export answers</button>
<span id="prog"></span></header><div id="root"></div>
<script>
const DATA=__DATA__;const KEY='w46-hands-blind';
let A=JSON.parse(localStorage.getItem(KEY)||'{}');const items=[];
function esc(s){return s.replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
function save(){localStorage.setItem(KEY,JSON.stringify(A));prog()}
function prog(){const d=items.filter(it=>ans(it)!==undefined).length;document.getElementById('prog').textContent=` ${d} / ${items.length} answered`}
function ans(it){return (A[it.page]||{})[it.key]}
function set(it,v){(A[it.page]=A[it.page]||{})[it.key]=v;save();paint(it)}
function paint(it){const v=ans(it);it.el.classList.toggle('done',v!==undefined);
 it.el.querySelectorAll('.opt').forEach(o=>o.classList.toggle('sel',o.dataset.v===v));
 it.el.querySelector('.typed').textContent=v&&v.startsWith('=')?'typed: '+v.slice(1):(v==='either'?'either will do / can\'t tell':'')}
const root=document.getElementById('root');
for(const p of DATA){const div=document.createElement('div');div.className='page';
 let h=`<div class="img"><div class="frame"><img src="${p.img}"><div class="box"></div></div></div><div class="list"><b>${p.page}</b>`;
 for(const x of p.items){h+=`<div class="it" data-key="${x.id}"><span class="ctx">… ${esc(x.before)}</span> <b>[ ]</b> <span class="ctx">${esc(x.after)} …</span>`+
  (x.box?'':`<span class="where">No box for this place: it is about ${Math.round(100*x.at)}% of the way through the page's text.</span>`);
  x.opts.forEach((o,i)=>{h+=`<span class="opt" data-v="${i+1}"><span class="k">${i+1}:</span> ${esc(o)||'<i>(nothing)</i>'}</span>`});
  if(x.opts.length===1)h+=`<span class="k">1 = right as shown · t = type what the photograph shows</span>`;
  h+=`<span class="typed"></span></div>`}
 div.innerHTML=h+'</div>';root.appendChild(div);
 const frame=div.querySelector('.frame');frame.onclick=()=>{frame.classList.toggle('zoom');if(items[cur]&&items[cur].frame===frame)show(items[cur])};
 div.querySelectorAll('.it').forEach(el=>{const x=p.items.find(x=>x.id===el.dataset.key);
  const it={page:p.page,key:el.dataset.key,el,box:x.box,n:x.opts.length,pane:div.querySelector('.img'),frame,mark:div.querySelector('.box')};items.push(it);paint(it);
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
 else if(/^[1-9]$/.test(e.key)&&+e.key<=it.n){set(it,e.key);go(cur+1)}
 else if(e.key==='e'){set(it,'either');go(cur+1)}
 else if(e.key==='t'){const t=prompt('What the photograph shows here (empty = nothing):','');if(t!==null){set(it,'='+t);go(cur+1)}}});
function exportAnswers(){const b=new Blob([JSON.stringify(A,null,1)],{type:'application/json'});
 const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='hands-blind-answers.json';a.click()}
prog();go(0);
</script>"""


# ---- fold -------------------------------------------------------------------------------------------------------

def fold(key: dict, answers: dict) -> dict:
    """Per item: which sources the owner's pick matches ('truth' among them when the truth stands), or the typed
    text, or 'either'. Plus the counts W46.ocr-hands-rescore starts from."""
    rulings, n = {}, {'hand': {}, 'control': {}}
    for p, d in key['pages'].items():
        for iid, v in d['items'].items():
            a = (answers.get(p) or {}).get(iid)
            if a is None:
                r = {'ruling': 'open'}
            elif a == 'either':
                r = {'ruling': 'either'}
            elif a.startswith('='):
                text = a[1:]
                same = [s for s in v['readings'] if B.keys(text.replace(' ', '')) == B.keys(v['readings'][s].replace(' ', ''))]
                r = {'ruling': 'typed', 'text': text, 'matches': same}
            else:
                r = {'ruling': 'picked', 'matches': v['options'][int(a) - 1]}
            truth_stands = 'truth' in r.get('matches', [])
            r['truth_stands'] = truth_stands if r['ruling'] in ('picked', 'typed') else None
            rulings.setdefault(p, {})[iid] = {**v, **r}
            c = n[v['kind']]
            k = r['ruling'] if r['truth_stands'] is None else ('truth stands' if truth_stands else 'truth wrong')
            c[k] = c.get(k, 0) + 1
    return {'counts': n, 'rulings': rulings}


# ---- report -----------------------------------------------------------------------------------------------------

def write_md(path: Path, s: dict):
    fr = s['failed_readings']
    L = ['# The blind handwriting sheet (W46.ocr-hands-sheet)', '',
         'Generated by `scripts/segbench/ocr_hands_sheet.py` from saved readings only: no call, no money, and no '
         'Claude reader looked at the pages. It answers the measurement audit\'s OCR-1 and OCR-4 '
         '(`execution-plans/processing-review/11-measurement-audit.md`): the 96\'s truth was drafted by Claude Opus '
         '5.5 and Gemini 3.8 Flash, Gemini 3.8 leads on the hand pages, and the earlier blind check '
         '(`ocr-truth-bias.md`) drew about 3 hand pages and looked only where Qwen3.6-27B differed.', '',
         '## What is on it', '',
         f'- **Hand places.** The {s["hand_pages"]} hand pages of the 96 (kind handwritten, less the three '
         'agreement pages). Every place where Qwen3.6-27B or LightOnOCR-3 4B reads the truth differently, agreed '
         f'and adjudicated words alike: {s["places_total"]} places, the two readers\' overlapping differences '
         f'merged. Left out: {s["joins"]} that differ only in where the words break, and {s["blocks"]} longer than '
         f'{BLOCK_WORDS} words on a side (a passage left out, added or moved: reading order, not reading). '
         f'**{s["hand_items"]} places on {s["hand_pages_with_places"]} pages are on the sheet**; {s["three_way"]} '
         f'show three readings (the truth and both readers all differ), {s["agreed_only"]} lie wholly in agreed '
         f'words and {s["touch_adjudicated"]} touch a word the owner adjudicated. Places where each reader differs: '
         + ', '.join(f'{n} {c}' for n, c in s['per_reader'].items()) + '.'
         + (f' Failed readings (left out of that page): {fr}.' if fr else ''),
         f'- **Typed controls.** {s["controls"]} passages of {CONTROL_WORDS} words drawn at random (seed {SEED}) '
         f'from the {s["control_starts"]:,} eligible starts on {s["typed_pages"]} typed and printed pages (p081 '
         'left out: the owner cannot correct it): agreed words that both readers also read word for word, the '
         f'part no check has looked at. They fall on {s["control_pages"]} pages, mixed among the hand pages. Each '
         'shows its one reading, shared by every reader and both drafters, and asks whether it is right.', '',
         'Blind: a place shows its readings unlabelled in a random order, and nothing on the sheet says which is '
         'the truth; that is kept in a key the sheet never loads. Each place carries a rough box: '
         f'{s["box_from"]["placement truth"]} from the placement truth\'s word boxes (`place_truth.py`), '
         f'{s["box_from"]["vision"]} from Apple Vision\'s word positions, and {s["box_from"][None]} with none, which '
         'say how far through the page\'s text they are. A box comes from the truth\'s word positions, shared by '
         'every reading of the place, so it does not tell them apart.', '',
         f'{s["pages_on_sheet"]} pages, about {s["minutes"]:.0f} minutes at `ocr_truth.py`\'s review rates (an '
         'estimate). The sheet and its key are private, under `ocr-truth/hands/`. W46.ocr-hands-rescore folds the '
         'answers (`ocr_hands_sheet.py fold`), corrects the hand truth, rescores the hand charts and C-ocr\'s hand '
         'route, and reports the controls\' error rate.', '',
         '## Measurement card', '',
         '- **Truth.** The 96\'s truth as it stands: drafted by Claude Opus 5.5 and Gemini 3.8 Flash, the drafters\' '
         'disagreements adjudicated by the owner. This sheet is the check of it on the hand pages; nothing is scored '
         'yet.',
         '- **Selection.** Places are every difference of two third-family readers, not a sample; the controls are '
         'a seeded random draw. Neither is chosen by a drafter, and no ABBYY text is read.',
         '- **Comparison.** None yet: the rescore compares routes on the corrected truth.',
         f'- **Noise.** {s["hand_items"]} hand places and {s["controls"]} controls; the rescore gives intervals.',
         '- **Scope.** Places where both third-family readers agree with a wrong truth are not on the sheet; the '
         'controls estimate how often that happens on typed pages only, and on hand pages it stays unmeasured. '
         'Passages longer than the block limit (reading order) are not judged.', '']
    path.write_text('\n'.join(L) + '\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    b = sub.add_parser('build')
    b.add_argument('--out', type=Path, default=OUT)
    b.add_argument('--results', type=Path, default=RESULTS)
    f = sub.add_parser('fold')
    f.add_argument('answers', type=Path)
    f.add_argument('--out', type=Path, default=OUT)
    a = ap.parse_args()
    if a.cmd == 'build':
        s = build(a.out, a.results)
        print(f'{s["hand_items"]} hand places + {s["controls"]} controls on {s["pages_on_sheet"]} pages, '
              f'~{s["minutes"]:.0f} min -> {a.out / "index.html"}')
    else:
        key = json.loads((a.out / 'key.json').read_text())
        r = fold(key, json.loads(a.answers.read_text()))
        (a.out / 'rulings.json').write_text(json.dumps(r, ensure_ascii=False, indent=1))
        print(json.dumps(r['counts']))


if __name__ == '__main__':
    main()
