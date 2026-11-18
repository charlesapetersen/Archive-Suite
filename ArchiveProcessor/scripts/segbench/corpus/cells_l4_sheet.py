#!/usr/bin/env python3
"""W46.ocr-cells-l4-more: the owner's sheet for the second L4 cell bank, and the fold of his answers into truth.

  python3 cells_l4_sheet.py orient            # Apple Vision at four turns on the drawn pages (heavy lock)
  python3 cells_l4_sheet.py build             # STORE/sheet/index.html + key.json; prints his time estimate
  python3 cells_l4_sheet.py fold ANSWERS.json # -> STORE/truth-draft.json in regions_cells.py's draft format

Reads what cells_l4_draft.py saved: no model, no network, no money, and no Claude reader looks at a page.

Asked: every cell the two drafting readers (Gemini 3.7 Flash, GLM 5.3 Flash) read differently or either called
badly boxed, with the distinct readings unlabelled in a seeded random order; and CONTROLS agreed cells drawn at
random (seed), each showing its one reading to confirm or correct, so the agreed part has a measured error rate.
Each item can also be dropped (the box does not hold one field) or marked unreadable (unknown truth, excluded from
scoring as the bank's null). Unasked, listed on every item and in each page's header (owner, 2026-11-05): the
cell's role (from the grid), its writing medium and field type (the readers' labels; where they differ, Gemini's,
and the item says so), and every agreed cell of the page with its value. They go in as listed; a note corrects
them. Notes per item save under `_notes/<id>` and are folded before the answer. Pages are shown upright: clear
wins of ocr_orient.swift's scores only (TURN_RATIO, TURN_MIN as item_fields_retruth), and a turn button rotates
the image and its box together. The box is the grid cell's own; it never tells which reading is which.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import io
import json
import random
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE)]
import cells_l4_draft as D  # noqa: E402

SHEET = D.STORE / 'sheet'
ORIENT = D.STORE / 'orient.json'
ORIENT_BIN = D.G.REHEARSAL / 'segbench/bin/segbench-ocr-orient'
HEAVY = HERE.parents[3] / 'ops/autonomous/heavy-run.py'
TURN_RATIO, TURN_MIN = 2.0, 20.0
CONTROLS = 12
SECONDS = {'disputed': 20, 'control': 8, 'page': 15}   # his time, for the estimate the sheet and the hand-over quote


def orient():
    if not ORIENT_BIN.exists():
        raise SystemExit(f'{ORIENT_BIN} is missing: swiftc -O {HERE.parent / "ocr_orient.swift"} -o {ORIENT_BIN}')
    paths = {str(D.STORE / 'images' / (p['id'] + '.jpg')): p['id'] for p in D.drawn()}
    lst = D.STORE / 'orient-list.txt'
    lst.write_text(''.join(p + '\n' for p in paths))
    r = subprocess.run(['python3', str(HEAVY), 'run', '--', str(ORIENT_BIN), str(lst)], capture_output=True, text=True)
    scores = {}
    for line in r.stdout.splitlines():
        f = line.split('\t')
        if len(f) == 5 and f[0] in paths:
            scores[paths[f[0]]] = [float(x) for x in f[1:]]
    if r.returncode or len(scores) != len(paths):
        raise SystemExit(f'orient: rc {r.returncode}, {len(scores)} of {len(paths)} scored\n{r.stderr[-2000:]}')
    D.dump(ORIENT, {'bin': str(ORIENT_BIN), 'scores': scores})
    print(len(scores), 'pages scored at four turns;', sum(bool(clear_turn(s)) for s in scores.values()), 'turned')


def clear_turn(sc):
    """Degrees clockwise that show the page upright; 0 unless one turn clearly wins."""
    best = max(range(4), key=lambda k: sc[k])
    rest = [sc[k] for k in range(4) if k != best]
    if best and all(sc[best] >= TURN_RATIO * x for x in rest) and sc[best] - max(rest) >= TURN_MIN:
        return 90 * best
    return 0


def labels(r):
    """medium and type for the item: agreed, or Gemini's with a flag."""
    out, differ = {}, []
    for k in ('medium', 'type'):
        vals = {route: (r[route] or {}).get(k) for route in D.MODELS}
        out[k] = vals['gemini'] if vals['gemini'] is not None else vals['glm']
        if len(set(vals.values())) > 1:
            differ.append(k)
    return out, differ


def items():
    """(pages, disputed, controls, agreed) from the saved readings; a missing reading stops the build."""
    picked = D.load(D.STORE / 'picked.json')
    pages, disputed, agreed = [], [], []
    for p in picked['pages']:
        for c in p['cells']:
            state, r = D.cell_state(p['id'], c['id'])
            if state == 'missing':
                raise SystemExit(f'{p["id"]}/{c["id"]}: a reading is missing; run cells_l4_draft.py read first')
            lab, differ = labels(r)
            row = {'page': p['id'], 'cell': c['id'], 'id': f'{p["id"]}/{c["id"]}', 'role': c['role'],
                   'box': c['box'], **lab, 'labels_differ': differ,
                   'boxes': {route: r[route].get('box') for route in D.MODELS}}
            if state == 'agreed':
                agreed.append({**row, 'value': r['gemini']['text']})
            else:
                opts = sorted({r[route]['text'] for route in D.MODELS})
                random.Random(D.sha(f'{D.SEED}|order|{row["id"]}'.encode())).shuffle(opts)
                disputed.append({**row, 'opts': opts})
        pages.append(p['id'])
    rng = random.Random(D.sha(f'{D.SEED}|controls'.encode()))
    controls = sorted(rng.sample(agreed, min(CONTROLS, len(agreed))), key=lambda x: x['id'])
    return pages, disputed, controls, agreed


def minutes(n_disputed, n_controls, n_pages):
    s = n_disputed * SECONDS['disputed'] + n_controls * SECONDS['control'] + n_pages * SECONDS['page']
    return max(1, round(s / 60))


def build(no_orient=False):
    from PIL import Image
    pages, disputed, controls, agreed = items()
    unsure = []
    if no_orient:
        turns = {p: 0 for p in pages}
    else:
        if not ORIENT.exists():
            raise SystemExit(f'{ORIENT} is missing: run `cells_l4_sheet.py orient` first (pages upright, owner '
                             '2026-11-05), or --no-orient to test the build only')
        sc = D.load(ORIENT)['scores']
        # Vision reads little of a handwritten ledger (its scores here are mostly under 30), so a page is turned
        # only where its clear win and the grid proposer's own rotation agree; any disagreement is named.
        turns, unsure = {}, []
        for p in pages:
            v, g = clear_turn(sc[p]), D.rotation(p)
            turns[p] = v if v == g else 0
            if v != g:
                unsure.append(f'{p} (Vision {v}°, Gemini {g}°)')
    if SHEET.exists():
        shutil.rmtree(SHEET)
    (SHEET / 'img').mkdir(parents=True)
    data = []
    control_ids = {x['id'] for x in controls}
    for pid in pages:
        src = D.STORE / 'images' / (pid + '.jpg')
        with Image.open(src) as im:
            im = im.convert('RGB')
            im.thumbnail((1600, 1600))
            im.save(SHEET / 'img' / (pid + '.jpg'), 'JPEG', quality=88)
        asked = [{**x, 'kind': 'disputed'} for x in disputed if x['page'] == pid]
        asked += [{**x, 'kind': 'control', 'opts': [x['value']]} for x in controls if x['page'] == pid]
        listed = [{k: x[k] for k in ('cell', 'value', 'role', 'medium', 'type')}
                  for x in agreed if x['page'] == pid and x['id'] not in control_ids]
        data.append({'page': pid, 'img': f'img/{pid}.jpg', 'turn': turns[pid], 'listed': listed,
                     'items': [{k: x[k] for k in ('id', 'cell', 'kind', 'opts', 'box', 'role', 'medium', 'type',
                                                  'labels_differ')} for x in sorted(asked, key=lambda x: x['cell'])]})
    n_min = minutes(len(disputed), len(controls), len(pages))
    turned = [p for p in pages if turns[p]]
    page = (TEMPLATE.replace('__DATA__', json.dumps(data, ensure_ascii=False))
            .replace('__N__', str(len(disputed) + len(controls))).replace('__PAGES__', str(len(pages)))
            .replace('__MINUTES__', str(n_min))
            .replace('__TURNED__', html.escape(', '.join(f'{p} ({turns[p]}°)' for p in turned) or 'none'))
            .replace('__UNSURE__', html.escape('; '.join(unsure) or 'none')))
    (SHEET / 'index.html').write_text(page)
    D.dump(SHEET / 'key.json', {'disputed': disputed, 'controls': controls, 'agreed': agreed, 'turns': turns,
                                'orientation_unsure': unsure, 'oriented': not no_orient})
    print(f'{len(disputed)} disputed + {len(controls)} controls on {len(pages)} pages, about {n_min} minutes; '
          f'{len(agreed)} agreed ({len(agreed) - len(controls)} listed, unasked); turned: {turned or "none"}')
    print(SHEET / 'index.html')


TEMPLATE = r"""<!doctype html><meta charset="utf-8"><title>L4 cells — owner check</title>
<style>
body{font:14px -apple-system,sans-serif;margin:0}header{position:sticky;top:0;background:#fff;border-bottom:1px solid #ccc;padding:8px 12px;z-index:5}
.page{display:flex;gap:12px;padding:12px;border-bottom:3px solid #999}.pane{flex:0 0 58%;max-height:80vh;overflow:auto;border:1px solid #ccc}
.frame{position:relative;transform-origin:center center;display:inline-block}.frame img{display:block;width:100%}.frame.zoom img{width:250%}
.box{position:absolute;border:3px solid #e0007a;box-shadow:0 0 0 2px #fff;display:none;pointer-events:none}
.list{flex:1;overflow:auto;max-height:80vh}.it{border:1px solid #ddd;margin:6px 0;padding:6px}.it.cur{border-color:#e0007a;background:#fff6fb}.it.done{opacity:.75}
.opt{display:block;margin:3px 0;padding:3px 6px;border:1px solid #bbb;border-radius:4px;cursor:pointer;font:15px Georgia,serif}.opt.sel{background:#cfe;border-color:#080}
.k{color:#888;font:12px -apple-system,sans-serif}.meta{color:#555;font-size:12px}.listed{font-size:12px;color:#444;margin-bottom:8px}
textarea{width:95%;height:2.4em;font:12px -apple-system,sans-serif}.chosen{color:#080;font-size:12px}
</style>
<header><b>Forms-L4 cell check</b> — __N__ fields on __PAGES__ ledger pages, about __MINUTES__ minutes. Each pink box is one table field.
Pick the reading the photograph shows (the readings are in no particular order), or type it. The <i>control</i> fields
show one reading two readers agreed on: confirm it or correct it.<br>
Keys (not while typing a note): <b>1</b>–<b>2</b> pick · <b>t</b> type what it says · <b>b</b> the field is blank ·
<b>u</b> can't read it · <b>d</b> drop: the box does not hold one field · <b>n/p</b> next/previous · <b>z</b> zoom · <b>r</b> turn the page 90°.<br>
Not asked, and going in as listed: each field's role, writing medium and type, and the agreed fields in each page's list.
Correct any of them in a note. Pages turned upright by the sheet: __TURNED__. Left as scanned because the two checks differ (press r if one is not upright): __UNSURE__.
Answers stay in this browser; <button onclick="exportAnswers()">Export answers</button><span id="prog"></span></header><div id="root"></div>
<script>
const DATA=__DATA__;const KEY='w46-cells-l4-more';
let A=JSON.parse(localStorage.getItem(KEY)||'{}');A._notes=A._notes||{};A._turns=A._turns||{};const items=[];
function esc(s){return String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function save(){localStorage.setItem(KEY,JSON.stringify(A));prog()}
function prog(){const d=items.filter(it=>A[it.id]!==undefined).length;document.getElementById('prog').textContent=` ${d} / ${items.length} answered`}
function set(it,v){A[it.id]=v;save();paint(it)}
const WORDS={blank:'blank',unread:"can't read it",drop:'dropped: the box does not hold one field'};
function paint(it){const v=A[it.id];it.el.classList.toggle('done',v!==undefined);
 it.el.querySelectorAll('.opt').forEach(o=>o.classList.toggle('sel',o.dataset.v===v));
 it.el.querySelector('.chosen').textContent=v===undefined?'':v.startsWith('=')?'typed: '+v.slice(1):(WORDS[v]||'')}
function turnOf(p){return (A._turns[p.page]!==undefined?A._turns[p.page]:p.turn)%360}
function applyTurn(p){p.frame.style.transform=`rotate(${turnOf(p)}deg)`}
const root=document.getElementById('root');
for(const p of DATA){const div=document.createElement('div');div.className='page';
 let h=`<div class="pane"><div class="frame"><img src="${p.img}"><div class="box"></div></div></div><div class="list"><b>${p.page}</b>
 <div class="listed">Agreed by both readers, not asked: ${p.listed.length?p.listed.map(x=>`${x.cell} “${esc(x.value)||'(blank)'}” (${x.role}, ${x.medium}, ${x.type})`).join(' · '):'none'}</div>
 <div class="k">Page note</div><textarea data-note="page:${p.page}"></textarea>`;
 for(const x of p.items){h+=`<div class="it" data-id="${esc(x.id)}"><b>${x.cell}</b> <span class="k">${x.kind==='control'?'control: both readers agree':'readers differ'}</span>
  <div class="meta">Unasked: role ${x.role}, medium ${x.medium}, type ${x.type}${x.labels_differ.length?' (readers differed on '+x.labels_differ.join(' and ')+'; this is Gemini\'s)':''}</div>`;
  x.opts.forEach((o,i)=>{h+=`<span class="opt" data-v="${i+1}"><span class="k">${i+1}:</span> ${esc(o)||'<i>(blank)</i>'}</span>`});
  h+=`<span class="chosen"></span><div class="k">Note</div><textarea data-note="${esc(x.id)}"></textarea></div>`}
 div.innerHTML=h+'</div>';root.appendChild(div);
 p.frame=div.querySelector('.frame');p.mark=div.querySelector('.box');p.pane=div.querySelector('.pane');applyTurn(p);
 div.querySelectorAll('textarea').forEach(t=>{t.value=A._notes[t.dataset.note]||'';t.addEventListener('input',()=>{A._notes[t.dataset.note]=t.value;save()})});
 div.querySelectorAll('.it').forEach(el=>{const x=p.items.find(x=>x.id===el.dataset.id);
  const it={id:x.id,el,box:x.box,n:x.opts.length,p};items.push(it);paint(it);
  el.querySelectorAll('.opt').forEach(o=>o.addEventListener('click',()=>set(it,o.dataset.v)));
  el.addEventListener('click',()=>go(items.indexOf(it)))})}
let cur=0;function go(i){if(i<0||i>=items.length)return;items[cur].el.classList.remove('cur');cur=i;
 const it=items[cur];it.el.classList.add('cur');it.el.scrollIntoView({block:'nearest'});show(it)}
function show(it){const b=it.box,m=it.p.mark;
 Object.assign(m.style,{display:'block',left:100*b[0]+'%',top:100*b[1]+'%',width:100*(b[2]-b[0])+'%',height:100*(b[3]-b[1])+'%'});
 const f=it.p.frame,pane=it.p.pane,centre=()=>{pane.scrollTop=(b[1]+b[3])/2*f.offsetHeight-pane.clientHeight/2;
  pane.scrollLeft=(b[0]+b[2])/2*f.offsetWidth-pane.clientWidth/2};
 const img=f.querySelector('img');if(img.complete)centre();else img.addEventListener('load',centre,{once:true})}
document.addEventListener('keydown',e=>{if(e.target.tagName==='TEXTAREA'||e.metaKey||e.ctrlKey)return;const it=items[cur];if(!it)return;
 if(e.key==='n')go(cur+1);else if(e.key==='p')go(cur-1);else if(e.key==='z'){it.p.frame.classList.toggle('zoom');show(it)}
 else if(e.key==='r'){A._turns[it.p.page]=(turnOf(it.p)+90)%360;save();applyTurn(it.p)}
 else if(/^[1-9]$/.test(e.key)&&+e.key<=it.n){set(it,e.key);go(cur+1)}
 else if(e.key==='b'){set(it,'blank');go(cur+1)}else if(e.key==='u'){set(it,'unread');go(cur+1)}else if(e.key==='d'){set(it,'drop');go(cur+1)}
 else if(e.key==='t'){const t=prompt('What the photograph shows in the box:','');if(t!==null){set(it,'='+t);go(cur+1)}}});
function exportAnswers(){const b=new Blob([JSON.stringify(A,null,1)],{type:'application/json'});
 const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='cells-l4-answers.json';a.click()}
prog();if(items.length)go(0);
</script>"""


# ---- fold -----------------------------------------------------------------------------------------------------------

def ruling(item, answer):
    """(value, unknown_reason) for one asked item, or None when it is dropped; raises on an unanswered item."""
    if answer is None:
        raise ValueError(f'{item["id"]}: not answered')
    if answer == 'drop':
        return None
    if answer == 'blank':
        return '', None
    if answer == 'unread':
        return None, 'owner could not read it'
    if answer.startswith('='):
        return answer[1:].strip(), None
    k = int(answer)
    if not 1 <= k <= len(item['opts']):
        raise ValueError(f'{item["id"]}: answer {answer} is not one of its readings')
    return item['opts'][k - 1], None


def cell_row(x, value, reason, how):
    medium = x['medium'] if x['medium'] in ('print', 'hand') else 'unknown'
    kind = x['type'] if x['type'] in ('free_text', 'formatted', 'discrete') else 'free_text'
    if value == '[illegible]':
        value, reason = None, reason or 'both readers marked it illegible'
    row = {'id': x['cell'], 'box': [round(v, 6) for v in x['box']], 'role': x['role'], 'medium': medium,
           'type': kind, 'value': value, 'reviewed': how}
    if value is None:
        row['unknown_reason'] = reason
    return row


def fold(answers_path: Path):
    from PIL import Image
    key = D.load(SHEET / 'key.json')
    answers = D.load(answers_path)
    notes = {k: v for k, v in (answers.get('_notes') or {}).items() if v.strip()}
    picked = {p['id']: p for p in D.load(D.STORE / 'picked.json')['pages']}
    rows, dropped, counts = {}, [], {'agreed': 0, 'control_confirmed': 0, 'control_corrected': 0, 'owner': 0}
    controls = {x['id'] for x in key['controls']}
    for x in key['agreed']:
        if x['id'] in controls:
            r = ruling({**x, 'opts': [x['value']]}, answers.get(x['id']))
            if r is None:
                dropped.append(x['id']); continue
            same = r[0] is not None and D.norm(r[0]) == D.norm(x['value'])
            counts['control_confirmed' if same else 'control_corrected'] += 1
            rows[x['id']] = cell_row(x, r[0], r[1], 'owner (control)')
        else:
            counts['agreed'] += 1
            rows[x['id']] = cell_row(x, x['value'], None, 'two readers agreed; listed on the owner sheet')
    for x in key['disputed']:
        r = ruling(x, answers.get(x['id']))
        if r is None:
            dropped.append(x['id']); continue
        counts['owner'] += 1
        rows[x['id']] = cell_row(x, r[0], r[1], 'owner')
    pages = []
    for pid, p in picked.items():
        cells = [rows[f'{pid}/{c["id"]}'] for c in p['cells'] if f'{pid}/{c["id"]}' in rows]
        if not cells:
            continue
        with Image.open(D.STORE / 'images' / (pid + '.jpg')) as im:
            size = list(im.size)
        pages.append({'id': pid, 'set': 'L4', 'capability': False, 'sha256': p['sha256'], 'size': size,
                      'tables': [{'id': 't1', 'box': [round(v, 6) for v in p['table_box']], 'cells': cells}]})
    draft = {'protocol': 'oracle-cells-v1', 'pages': pages,
             'audit': {'item': 'W46.ocr-cells-l4-more', 'drafters': list(D.MODELS.values()),
                       'selection': 'pages by seeded hash of id from the 895 L4 less the first bank; cells at random '
                                    'from the proposed grid (3 headings, 6 entries a table page)',
                       'counts': counts, 'dropped': dropped, 'turns_by_owner': answers.get('_turns') or {},
                       'notes': notes, 'answers_sha256': D.sha(answers_path.read_bytes())}}
    D.dump(D.STORE / 'truth-draft.json', draft)
    print(f'{sum(len(p["tables"][0]["cells"]) for p in pages)} cells on {len(pages)} pages; {counts}; '
          f'{len(dropped)} dropped; {len(notes)} notes to read before freezing -> {D.STORE / "truth-draft.json"}')
    return draft


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('cmd', choices=('orient', 'build', 'fold'))
    ap.add_argument('answers', nargs='?', type=Path)
    ap.add_argument('--no-orient', action='store_true')
    a = ap.parse_args()
    if a.cmd == 'orient':
        orient()
    elif a.cmd == 'build':
        build(a.no_orient)
    else:
        if not a.answers:
            raise SystemExit('fold needs the exported answers file')
        fold(a.answers)


if __name__ == '__main__':
    main()
