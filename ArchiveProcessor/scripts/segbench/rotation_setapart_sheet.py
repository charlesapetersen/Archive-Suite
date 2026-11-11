#!/usr/bin/env python3
"""W46.rotation-setapart-sheet. Which way up are the five held-out box pages every route agrees the box stores turned?

W46.rotation-heldout scored its 119 held-out owner pages as stored (each taken as upright and turned by a known angle),
and five box pages came back with the same non-zero correction from every route, Gemini included
(`segbench-results/rotation-routes.md` §"Held out"). They are reported apart, never dropped, and nobody had looked at
them. This sheet asks the owner, about a minute: each page is shown AS STORED (the one sheet where that is the point),
and he turns it until it reads upright. Five held-out box pages the routes agree are upright are mixed in as controls,
so that turning is never the expected answer.

  python3 rotation_setapart_sheet.py sheet               # REHEARSAL/rotation-setapart/sheet/index.html
  python3 rotation_setapart_sheet.py score ANSWERS.json  # the owner's turns against the routes'; the rules' figures

No model runs and no network: the sheet reads the held-out answers W46.rotation-heldout already wrote. The page
images are the locked segmentation boxes' JPEGs (read only); the sheet holds downscaled copies of them.
"""
import argparse
import hashlib
import json
import random
import sys
from pathlib import Path

import rotation_report as REP
import rotation_routes as RR

OUT = RR.REHEARSAL / 'rotation-setapart'
SALT = 'W46.rotation-setapart-sheet'
N_CONTROLS = 5
SEED = 20261111                 # the sheet's order
SHEET_PX = 1600                 # the copies' long side
SECONDS_PER_PAGE = 6
RULES = {'vision=paddle>flag': 'free rule (Vision checked by PP-LCNet, else flag)',
         'vision=paddle>llm1': 'gateway rule (Vision checked by PP-LCNet, else Gemini)',
         'vision': 'Local Vision alone', 'paddle': 'PP-LCNet alone'}


def heldout():
    """The held-out pages, the routes' answers and the set-apart pages (rotation_report.heldout_data's own reading)."""
    pages, a, _ = REP.load_heldout()
    llm = a.pop('_llm')
    turned = REP.stored_turned(pages, a, llm)
    return pages, a, turned


def controls(pages, a, turned, n=N_CONTROLS):
    """Box pages that every local route reads upright as stored at all four turns, drawn by a salted hash."""
    pool = [p for p in pages if pages[p]['set'] == 'boxes' and p not in turned
            and all(REP.outcome(a[r].get((p, t), {}).get('found'), t) == 'exact' for r in REP.LOCAL if r in a
                    for t in RR.TURNS)]
    pool.sort(key=lambda p: hashlib.sha256((SALT + p).encode()).hexdigest())
    return pool[:n]


def copy(src: Path, dst: Path):
    """The stored pixels, downscaled; no EXIF orientation is read or written, so the browser shows them as stored."""
    from PIL import Image
    im = Image.open(src).convert('RGB')
    im.thumbnail((SHEET_PX, SHEET_PX), Image.Resampling.LANCZOS)
    im.save(dst, 'JPEG', quality=85)


def cmd_sheet(_):
    pages, a, turned = heldout()
    if len(turned) != 5:
        print(f'note: {len(turned)} set-apart pages, not the five the report names', file=sys.stderr)
    ids = sorted(turned) + controls(pages, a, turned)
    random.Random(SEED).shuffle(ids)
    sheet = OUT / 'sheet'
    (sheet / 'img').mkdir(parents=True, exist_ok=True)
    items = []
    for i, pid in enumerate(ids, 1):
        name = f'p{i:02d}.jpg'                       # no box name or number on the image, nothing to hint at the set
        copy(Path(pages[pid]['path']), sheet / 'img' / name)
        items.append({'id': pid, 'img': 'img/' + name, 'box': pages[pid]['stratum']})
    (OUT / 'draw.json').write_text(json.dumps({'salt': SALT, 'seed': SEED, 'set_apart': sorted(turned),
                                               'controls': sorted(set(ids) - set(turned)),
                                               'routes': turned}, indent=1))
    minutes = max(1, round(len(items) * SECONDS_PER_PAGE / 60))
    page = SHEET_HTML.replace('__ITEMS__', json.dumps(items)).replace('__N__', str(len(items))) \
                     .replace('__MIN__', str(minutes))
    (sheet / 'index.html').write_text(page)
    print(sheet / 'index.html', len(items), 'pages, about', minutes, 'min')


SHEET_HTML = r"""<!doctype html><meta charset="utf-8"><title>Which way is up?</title>
<style>body{font:15px -apple-system,sans-serif;margin:0;display:flex;height:100vh}
#side{width:340px;padding:14px;overflow:auto;border-right:1px solid #ccc;box-sizing:border-box}
#main{flex:1;display:flex;align-items:center;justify-content:center;overflow:hidden;background:#333}
#main img{max-width:96%;max-height:96%;transition:transform .1s;background:#fff}
.k{display:inline-block;border:1px solid #888;border-radius:4px;padding:1px 6px;margin:2px;cursor:pointer}
.k.on{background:#2a6;color:#fff;border-color:#2a6}textarea{width:100%;height:70px}
#bar{height:6px;background:#2a6}small{color:#555}</style>
<div id="side"><h3>Which way is up?</h3>
<p><small>__N__ pages, about __MIN__ minute(s). Each page is shown <b>as it is stored in the box</b>, not turned
upright: that is the question. Press <b>r</b> to turn it a quarter clockwise until it reads upright, then
<b>Enter</b> (or <b>u</b>) to say it is upright now; it moves on by itself. <b>x</b> if you cannot tell. Some pages
are already upright; Enter at once is the answer for those. ← → move. Nothing else is asked: the box listed below each
page goes in as listed, and a note can correct it or say a page should be dropped. Answers save in this browser as you
go; press <b>Export</b> at the end and keep the file.</small></p>
<div id="bar"></div><p id="pos"></p>
<p><span class="k" id="rot">r turn ↻</span><span class="k" data-a="up">Enter upright now</span><span class="k" data-a="x">x cannot tell</span></p>
<p><small>Box (listed, not asked): <span id="box"></span> · turned so far: <span id="deg"></span>°</small></p>
<p>Note on this page (optional)<br><textarea id="note"></textarea></p>
<p><span class="k" id="exp">Export</span> <span class="k" id="next">next unanswered</span></p></div>
<div id="main"><img id="im"></div>
<script>
const items=__ITEMS__;const KEY='w46-rotation-setapart-sheet';
let A=JSON.parse(localStorage.getItem(KEY)||'{}');A._notes=A._notes||{};A._turns=A._turns||{};
const save=()=>localStorage.setItem(KEY,JSON.stringify(A));
let cur=0;const im=document.getElementById('im'),note=document.getElementById('note');
function turn(it){return A._turns[it.id]??0}
function go(i){if(i<0||i>=items.length)return;cur=i;const it=items[i];im.src=it.img;
 im.style.transform='rotate('+turn(it)+'deg)';document.getElementById('box').textContent=it.box;
 document.getElementById('deg').textContent=turn(it);note.value=A._notes[it.id]||'';
 document.querySelectorAll('[data-a]').forEach(k=>k.classList.toggle('on',A[it.id]===k.dataset.a));
 const n=items.filter(x=>A[x.id]).length;document.getElementById('pos').textContent='page '+(i+1)+' of '+items.length+' · '+n+' answered';
 document.getElementById('bar').style.width=(100*n/items.length)+'%'}
function answer(a){A[items[cur].id]=a;save();go(cur);setTimeout(()=>go(Math.min(cur+1,items.length-1)),120)}
function rot(){const it=items[cur];A._turns[it.id]=(turn(it)+90)%360;if(A[it.id]==='up')delete A[it.id];save();go(cur)}
note.addEventListener('input',()=>{const id=items[cur].id;if(note.value)A._notes[id]=note.value;else delete A._notes[id];save()});
note.addEventListener('keydown',e=>e.stopPropagation());
document.querySelectorAll('[data-a]').forEach(k=>k.onclick=()=>answer(k.dataset.a));
document.getElementById('rot').onclick=rot;
document.getElementById('next').onclick=()=>{const j=items.findIndex(x=>!A[x.id]);if(j>=0)go(j)};
document.getElementById('exp').onclick=()=>{const b=new Blob([JSON.stringify(A,null,1)],{type:'application/json'});
 const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='rotation-setapart-answers.json';a.click()};
document.addEventListener('keydown',e=>{if(e.metaKey||e.ctrlKey)return;
 if(e.key=='Enter'||e.key=='u')answer('up');else if(e.key=='x')answer('x');else if(e.key=='r')rot();
 else if(e.key=='ArrowRight')go(cur+1);else if(e.key=='ArrowLeft')go(cur-1)});
go(Math.max(0,items.findIndex(x=>!A[x.id])));
</script>"""


# ---------------------------------------------------------------- the score

def owner_offsets(answers, ids):
    """The owner's clockwise correction per page (the routes' offset convention), None where he could not tell or
    did not answer."""
    turns = answers.get('_turns', {})
    return {p: (turns.get(p, 0) % 360 if answers.get(p) == 'up' else None) for p in ids}


def page_outcome(ans, pid, off):
    """A page under a corrected truth, counted as page_figures counts it: every turn's right answer is
    RR.want(t) + off; 'wrong' when any turn gets a confident wrong answer (an escalated turn included: its answer is
    the rule's), 'flagged' when any turn abstains or is escalated, 'right' when all are exact. A page can be wrong and
    flagged at once. None when a turn is unanswered (page_figures leaves the page out)."""
    got = [ans.get((pid, t)) for t in RR.TURNS]
    if any(v is None for v in got):
        return None
    return {'right': all(v['found'] == (RR.want(t) + off) % 360 for v, t in zip(got, RR.TURNS)),
            'wrong': any(v['found'] is not None and v['found'] != (RR.want(t) + off) % 360
                         for v, t in zip(got, RR.TURNS)),
            'flagged': any(v['found'] is None or v.get('escalated') for v in got)}


def word(o):
    return 'wrong' if o['wrong'] else 'flagged' if o['flagged'] else 'right'


def tally(pages, a, turned, answers):
    ids = sorted(turned) + [p for p in answers if not p.startswith('_') and p not in turned]
    owner = owner_offsets(answers, ids)
    agree = {p: owner[p] == turned[p]['offset'] for p in turned if owner.get(p) is not None}
    controls_turned = sorted(p for p in ids if p not in turned and owner.get(p))
    rules = {}
    for r, name in RULES.items():
        if r not in a:
            continue
        stored = {p: page_outcome(a[r], p, 0) for p in pages}
        truth = dict(stored)
        for p, off in owner.items():
            if off is not None and p in truth:
                truth[p] = page_outcome(a[r], p, off)
        rules[r] = {'name': name, 'pages': sum(v is not None for v in stored.values()),
                    'wrong_as_stored': sum(bool(v and v['wrong']) for v in stored.values()),
                    'wrong_owner_truth': sum(bool(v and v['wrong']) for v in truth.values()),
                    'flagged_owner_truth': sum(bool(v and v['flagged']) for v in truth.values()),
                    'set_apart_owner_truth': {p: word(truth[p]) for p in turned if truth[p]}}
    return {'owner': owner, 'agree': agree, 'controls_turned': controls_turned,
            'unanswered': sorted(p for p in ids if p not in answers), 'notes': answers.get('_notes', {}),
            'rules': rules}


def cmd_score(args):
    answers = json.loads(Path(args.answers).read_text())
    pages, a, turned = heldout()
    t = tally(pages, a, turned, answers)
    print(json.dumps(t, indent=1))
    moved = [r for r, v in t['rules'].items() if v['wrong_owner_truth'] != v['wrong_as_stored']]
    print('\nOwner agrees with the routes on', sum(t['agree'].values()), 'of', len(t['agree']), 'set-apart pages;',
          len(t['controls_turned']), 'control pages turned.', 'Figures that move:', moved or 'none')


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('sheet').set_defaults(f=cmd_sheet)
    s = sub.add_parser('score')
    s.add_argument('answers')
    s.set_defaults(f=cmd_score)
    args = ap.parse_args(argv)
    args.f(args)


if __name__ == '__main__':
    main()
