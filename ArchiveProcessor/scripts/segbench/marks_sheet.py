#!/usr/bin/env python3
"""W46.fix-marks-set-draft: the owner's check sheet for the marks set's 40-page core, and the YOLO export.

  python3 marks_sheet.py build [--out DIR]                  # CACHE/sheet: index.html, key.json, pages/
  python3 marks_sheet.py export --answers FILE [--key K] [--out DIR]
                                                            # CACHE/export: core/ (owner truth), drafts/ (agreed drafts)

The two drafts (marks_set.gemini_draft, marks_set.local_draft) are merged into candidate boxes: marks of different
routes pair at IoU >= 0.5, greedily, and a pair's box is the mean of its members. A candidate's class is the routes'
class when they agree and None ("choose") when they do not; its texts are the distinct non-empty readings offered.
Unpaired marks are candidates too. Which route proposed a box goes into key.json only: the sheet shows no route
name, no stratum, no pre-flag and no source of a box, so a box never says which reading is the current truth
(owner check-sheet rule, 2026-10-21). Pages appear in a seeded shuffle. No Claude session reads the pages (owner,
2026-10-30): this script copies the images byte for byte and never opens them.

The owner's answers are the core's truth; the other 110 pages export only the marks both drafts found with the same
class, in a folder whose manifest says they are model drafts, not truth.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import random
import re
import shutil
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import marks_set as M  # noqa: E402

SHEET_SEED = 'W46.fix-marks-set-draft-sheet'
MINUTES_PER_PAGE = 10
IOU_PAIR = 0.5
# The owner's handwriting band: mixed_def's keys and answers, each mapped to marks_set.AMOUNTS (x: not a text page).
BANDS = {'0': 'none', '1': 'signature', '2': 'few', '3': 'passage', '4': 'long', '5': 'handpage', 'x': 'notext'}
BAND_TEXT = {'none': 'no handwriting', 'signature': 'a signature, initials or a date by hand only',
             'few': 'handwritten notes of under about 10 words', 'passage': 'a handwritten passage of about 10-29 words',
             'long': 'handwriting of 30 words or more on a typed or printed page', 'handpage': 'a handwritten page',
             'notext': 'not a text page (photograph, drawing, blank)'}
BAND_AMOUNT = dict(zip(['none', 'signature', 'few', 'passage', 'long', 'handpage'], M.AMOUNTS), notext='nontext')
NOT_TRANSCRIBED = ('signature_initials', 'redaction')


def default_routes():
    return {'gemini3.7-flash-gw': M.gemini_draft, M.LOCAL_KEY: M.local_draft}


def inner(d):
    """The draft proper: accepts a route's record ({'draft': ...}) or the draft itself; None when there is none."""
    if d and 'marks' not in d and 'draft' in d:
        d = d['draft']
    return d if d and isinstance(d.get('marks'), list) else None


# ---------- merging the drafts ----------

def candidates(drafts, thr=IOU_PAIR):
    """drafts: [(route, draft or None)]. One candidate per mark cluster: each route's marks pair greedily (highest IoU
    first, one to one) with the clusters built so far at IoU >= thr against the cluster's mean box. Class is the
    agreed class or None; texts are the distinct non-empty readings, sorted so the prefill never follows the route order; overlaps_print is any member's.
    Ordered top to bottom, then left."""
    groups = []
    for route, d in drafts:
        d = inner(d)
        if not d:
            continue
        marks = d['marks']
        pairs = sorted(((M.iou(g['box'], m['box']), gi, mi) for gi, g in enumerate(groups)
                        for mi, m in enumerate(marks) if route not in g['sources']), reverse=True)
        used_g, used_m = set(), set()
        for v, gi, mi in pairs:
            if v < thr:
                break
            if gi in used_g or mi in used_m:
                continue
            used_g.add(gi); used_m.add(mi)
            groups[gi]['members'].append(marks[mi]); groups[gi]['sources'].append(route)
        for gi in used_g:
            ms = groups[gi]['members']
            groups[gi]['box'] = [round(sum(m['box'][k] for m in ms) / len(ms), 4) for k in range(4)]
        for mi, m in enumerate(marks):
            if mi not in used_m:
                groups.append(dict(members=[m], sources=[route], box=[round(v, 4) for v in m['box']]))
    out = []
    for g in groups:
        classes = sorted({m['cls'] for m in g['members']})
        texts = []
        for m in g['members']:
            t = (m.get('text') or '').strip()
            if t and t not in texts:
                texts.append(t)
        texts.sort()
        out.append(dict(box=g['box'], cls=classes[0] if len(classes) == 1 else None, classes=classes, texts=texts,
                        overlaps_print=any(m.get('overlaps_print') for m in g['members']), sources=g['sources']))
    return sorted(out, key=lambda c: (c['box'][1], c['box'][0]))


def consensus(drafts):
    """(agreed, single): agreed candidates were found by two or more routes with the same class; all others single."""
    cs = candidates(drafts)
    agreed = [c for c in cs if len(c['sources']) >= 2 and c['cls'] is not None]
    return agreed, [c for c in cs if c not in agreed]


# ---------- the sheet ----------

def class_notes():
    """The class definitions and the not-a-mark rule, from marks_set.INSTRUCTION (one source for both)."""
    lines = re.findall(r'^- "(\w+)": (.*?);?$', M.INSTRUCTION.split('These are NOT marks')[0], re.M)
    nots = re.search(r'(These are NOT marks.*?table\.)', M.INSTRUCTION, re.S).group(1)
    return [(c, t.rstrip(';').rstrip('.')) for c, t in lines], ' '.join(nots.split())


def esc(s):
    return str(s).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def build(out_dir, routes=None, partial=False):
    """The core pages' sheet in out_dir. Refuses (SystemExit) when a core page has no usable draft, or when any route
    has not read it (both families must have tried every page, MRK-1). A route that read a page and failed (output cap,
    bad JSON) is a measured failure, not a missing draft: the page goes on with the other family's boxes and key.json
    lists the route under 'failed'. partial=True only refuses a page with no draft at all, for a trial build that is
    never offered. Also refuses a page with no image. Images are copied byte for byte (the scan artifact is read-only);
    nothing on the sheet names a route."""
    routes = routes or default_routes()
    out_dir = Path(out_dir)
    rows = [r for r in M.selection()['rows'] if r.get('core')]
    pages, missing, failed = {}, [], {}
    for r in rows:
        recs = [(name, f(r['id'])) for name, f in routes.items()]
        got = [(name, inner(rec)) for name, rec in recs]
        if not any(d for _, d in got) or (not partial and not all(rec for _, rec in recs)):
            missing.append(r['id'])
        bad = [name for name, rec in recs if rec and not inner(rec)]
        if bad:
            failed[r['id']] = bad
        pages[r['id']] = (r, got)
    if missing:
        raise SystemExit(f'{len(missing)} core pages lack a draft: {missing[:5]}')
    noimg = [pid for pid in pages if not Path(M.image_path(pid)).exists()]
    if noimg:
        raise SystemExit(f'no image for {noimg[:5]}')
    order = sorted(pages)
    random.Random(SHEET_SEED).shuffle(order)
    (out_dir / 'pages').mkdir(parents=True, exist_ok=True)
    data, key = [], dict(protocol='marks-core-sheet-v1', seed=SHEET_SEED, iou=IOU_PAIR, routes=list(routes),
                         order=order, pages={})
    for pid in order:
        r, got = pages[pid]
        shutil.copyfile(M.image_path(pid), out_dir / 'pages' / (pid + '.jpg'))
        cs = candidates(got)
        data.append(dict(page=pid, img=f'pages/{pid}.jpg',
                         cands=[dict(box=c['box'], cls=c['cls'], texts=c['texts'], overlaps=c['overlaps_print'])
                                for c in cs]))
        key['pages'][pid] = dict(stratum=r['stratum'], phase=r['phase'], preflag=r.get('amount'),
                                 drafted=[n for n, d in got if d], failed=failed.get(pid, []), candidates=cs)
    n_c = sum(len(d['cands']) for d in data)
    minutes = len(data) * MINUTES_PER_PAGE
    defs, nots = class_notes()
    blob = lambda o: json.dumps(o, ensure_ascii=False).replace('</', '<\\/')  # noqa: E731 - no </script> in data
    html = (SHEET_HTML.replace('__CLASSDEFS__', ''.join(f'<li><b>{esc(c)}</b>: {esc(t)}</li>' for c, t in defs))
            .replace('__NOTMARKS__', esc(nots)).replace('__N__', str(len(data))).replace('__NC__', str(n_c))
            .replace('__MINUTES__', str(minutes)).replace('__BANDS__', blob(BANDS))
            .replace('__BANDTEXT__', blob(BAND_TEXT)).replace('__CLASSES__', blob(list(M.CLASSES)))
            .replace('__NOTX__', blob(list(NOT_TRANSCRIBED))).replace('__DATA__', blob(data)))
    (out_dir / 'index.html').write_text(html)
    (out_dir / 'key.json').write_text(json.dumps(key, indent=1, ensure_ascii=False) + '\n')
    return dict(pages=len(data), candidates=n_c, minutes=minutes, failed=failed, out=str(out_dir))


SHEET_HTML = r"""<!doctype html><meta charset="utf-8"><title>W46 marks: the core</title>
<style>
body{font:14px -apple-system,sans-serif;margin:0;background:#fff;color:#111;color-scheme:light}
header{position:sticky;top:0;background:#fff;border-bottom:1px solid #ccc;padding:6px 12px;z-index:3}
header details{font-size:13px}header ul{margin:2px 0 4px;padding-left:20px}
.page{display:flex;gap:12px;border-bottom:3px solid #999;padding:10px;min-height:90vh;scroll-margin-top:var(--head,60px)}
.img{flex:1 1 62%;position:sticky;top:var(--head,60px);height:calc(100vh - var(--head,60px) - 20px);overflow:auto}
.frame{position:relative;width:100%;cursor:zoom-in;user-select:none}.frame.zoom{width:250%;cursor:zoom-out}
.frame img{width:100%;display:block;pointer-events:none}.adding .frame{cursor:crosshair}
.q{flex:1 1 38%;overflow:auto}.page.cur .q{outline:3px solid #06f;outline-offset:4px}.page.done .q{background:#e6f6e6}
.opt{display:block;margin:3px 0;padding:2px 4px;border-radius:3px;cursor:pointer}.opt.sel{font-weight:bold;color:#060;background:#d8f0d8}
.k{color:#888;font-size:12px;display:inline-block;width:1.4em}
.bx{position:absolute;border:2px solid #d00;box-sizing:border-box;pointer-events:none}
.bx span{position:absolute;top:-16px;left:-2px;background:#d00;color:#fff;font:bold 11px sans-serif;padding:0 3px}
.bx.no{border:2px dashed #999}.bx.no span{background:#999}.bx.add{border-color:#06c}.bx.add span{background:#06c}
.bx.hi{border-width:4px}.drag{position:absolute;border:2px dashed #06c;pointer-events:none}
.mk{border-top:1px solid #ccc;padding:5px 0}.mk.ok{background:#eef8ee}.mk label{margin-right:8px;white-space:nowrap}
.mk input[type=text]{width:95%}.alt{color:#06c;cursor:pointer;text-decoration:underline;margin-right:8px}
.hint{color:#777;font-size:12px}textarea{width:95%}#addbtn.on{background:#06c;color:#fff}
</style>
<header><b>Marks on the core pages</b>: __N__ pages, __NC__ draft boxes, about __MINUTES__ minutes.
The numbered boxes are <b>rough drafts</b>: for each say <b>keep</b> or <b>not a mark</b>, then its class, whether it
touches print, and its text. Signatures, initials and redactions are labelled, not transcribed. A missed mark:
<b>shift-drag</b> a rectangle on the image (or turn on <button id="addbtn" onclick="toggleAdd()">add box (a)</button>
and drag). Then the page's <b>handwriting band</b> (<b>0</b> none · <b>1</b> signature/initials/date only · <b>2</b>
under ~10 words · <b>3</b> ~10-29 · <b>4</b> 30+ on a typed or printed page · <b>5</b> a handwritten page · <b>x</b>
not a text page). <b>j/k</b> next/previous · <b>z</b> zoom (or click the image). Answers stay in this browser;
<button onclick="exportAnswers()">Export answers</button><span id="prog"></span>
<details><summary>The classes</summary><ul>__CLASSDEFS__</ul>__NOTMARKS__</details></header><div id="root"></div>
<script>
const DATA=__DATA__,BANDS=__BANDS__,BANDTEXT=__BANDTEXT__,CLASSES=__CLASSES__,NOTX=__NOTX__;const KEY='w46-marks-core';
let A=JSON.parse(localStorage.getItem(KEY)||'{}');const P=[];let cur=0,adding=false,drag=null,swallow=false;
function esc(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
function st(d){const a=A[d.page]=A[d.page]||{band:null,note:'',candidates:{},added:[]};a.candidates=a.candidates||{};a.added=a.added||[];
 d.cands.forEach((c,i)=>{const n=String(i+1);if(!a.candidates[n])a.candidates[n]={keep:null,cls:c.cls,overlaps:c.overlaps,text:c.texts[0]||''}});return a}
function okMark(m){return !!m&&(m.keep===false||(m.keep===true&&!!m.cls))}
function done(d){const a=A[d.page];return !!(a&&a.band&&d.cands.every((c,i)=>okMark(a.candidates[String(i+1)]))&&a.added.every(m=>!!m.cls))}
function save(){localStorage.setItem(KEY,JSON.stringify(A));prog()}
function prog(){document.getElementById('prog').textContent=` ${P.filter(p=>done(p.d)).length} / ${P.length} pages done`}
function radios(name,f,vals,cur,labels){return vals.map((v,i)=>`<label><input type="radio" name="${name}" data-f="${f}" value="${esc(v)}"${cur===v?' checked':''}>${esc(labels?labels[i]:v)}</label>`).join('')}
function form(pi,kind,n,m,c){const id=`${pi}-${kind}${n}`,yn=m.overlaps===true?'yes':m.overlaps===false?'no':null;
 let h=`<div class="mk" data-kind="${kind}" data-n="${n}"><b>${kind==='a'?'+':''}${n}</b> `;
 h+=kind==='c'?radios(id+'-k','keep',['keep','drop'],m.keep===true?'keep':m.keep===false?'drop':null,['keep','not a mark'])
  :`<button data-f="remove">remove</button>`;
 h+=`<div>${radios(id+'-c','cls',CLASSES,m.cls)}</div><div>touches print: ${radios(id+'-o','overlaps',['yes','no'],yn)}</div>`;
 h+=`<input type="text" data-f="text" value="${esc(m.text||'')}" placeholder="what it says">`;
 if(c&&c.texts.length>1)h+=`<div class="hint">other readings: ${c.texts.slice(1).map((t,j)=>`<span class="alt" data-alt="${j+1}">${esc(t)}</span>`).join('')}</div>`;
 h+=`<div class="hint">signatures, initials and redactions: label only, no text</div></div>`;return h}
function render(p){const d=p.d,a=st(d),pi=p.i;
 let o=`<img loading="lazy" src="${esc(d.img)}">`;
 d.cands.forEach((c,i)=>o+=`<div class="bx" data-kind="c" data-n="${i+1}" style="${pos(c.box)}"><span>${i+1}</span></div>`);
 a.added.forEach((m,i)=>o+=`<div class="bx add" data-kind="a" data-n="${i+1}" style="${pos(m.box)}"><span>+${i+1}</span></div>`);
 p.frame.innerHTML=o;
 let h=`<b>${pi+1}. ${esc(d.page)}</b><div>${d.cands.length?'':'<i>No draft box on this page.</i>'}</div>`;
 d.cands.forEach((c,i)=>h+=form(pi,'c',i+1,a.candidates[String(i+1)],c));
 a.added.forEach((m,i)=>h+=form(pi,'a',i+1,m,null));
 h+=`<div style="margin-top:10px"><b>Handwriting band</b>`;
 for(const [k,v] of Object.entries(BANDS))h+=`<span class="opt" data-band="${v}"><span class="k">${k}</span>${esc(BANDTEXT[v])}</span>`;
 h+=`</div><textarea rows="2" data-f="note" placeholder="note (optional)">${esc(a.note||'')}</textarea>`;
 p.q.innerHTML=h;paint(p)}
function pos(b){return `left:${b[0]*100}%;top:${b[1]*100}%;width:${(b[2]-b[0])*100}%;height:${(b[3]-b[1])*100}%`}
function markOf(p,kind,n){const a=st(p.d);return kind==='c'?a.candidates[n]:a.added[n-1]}
function paint(p){const a=st(p.d);p.el.classList.toggle('done',done(p.d));
 p.q.querySelectorAll('.opt').forEach(o=>o.classList.toggle('sel',a.band===o.dataset.band));
 p.q.querySelectorAll('.mk').forEach(e=>{const m=markOf(p,e.dataset.kind,+e.dataset.n);e.classList.toggle('ok',e.dataset.kind==='c'?okMark(m):!!m.cls)});
 p.frame.querySelectorAll('.bx').forEach(b=>{const m=markOf(p,b.dataset.kind,+b.dataset.n);b.classList.toggle('no',b.dataset.kind==='c'&&m.keep===false)})}
function edit(p,e){const t=e.target,mk=t.closest('.mk');if(!mk){if(t.dataset.f==='note'){st(p.d).note=t.value;save()}return}
 const m=markOf(p,mk.dataset.kind,+mk.dataset.n),f=t.dataset.f;
 if(f==='keep')m.keep=t.value==='keep';else if(f==='cls')m.cls=t.value;else if(f==='overlaps')m.overlaps=t.value==='yes';
 else if(f==='text')m.text=t.value;else return;save();paint(p)}
const root=document.getElementById('root');
DATA.forEach((d,i)=>{const el=document.createElement('div');el.className='page';
 el.innerHTML='<div class="img"><div class="frame"></div></div><div class="q"></div>';root.appendChild(el);
 const p={d,i,el,frame:el.querySelector('.frame'),q:el.querySelector('.q')};P.push(p);render(p);
 p.q.addEventListener('change',e=>edit(p,e));p.q.addEventListener('input',e=>{if(e.target.type==='text'||e.target.tagName==='TEXTAREA')edit(p,e)});
 p.q.addEventListener('click',e=>{if(cur!==i)go(i,false);const t=e.target;
  if(t.dataset.band!==undefined||t.closest('.opt')){st(d).band=t.closest('.opt').dataset.band;save();paint(p);return}
  if(t.dataset.alt){const mk=t.closest('.mk'),m=markOf(p,'c',+mk.dataset.n);m.text=d.cands[+mk.dataset.n-1].texts[+t.dataset.alt];
   mk.querySelector('input[type=text]').value=m.text;save();return}
  if(t.dataset.f==='remove'){st(d).added.splice(+t.closest('.mk').dataset.n-1,1);save();render(p)}});
 p.q.addEventListener('mouseover',e=>hi(p,e.target.closest('.mk')));p.q.addEventListener('mouseleave',()=>hi(p,null));
 p.frame.addEventListener('mousedown',e=>{if(e.button!==0||!(e.shiftKey||adding))return;e.preventDefault();go(i,false);
  const r=p.frame.getBoundingClientRect(),dv=document.createElement('div');dv.className='drag';p.frame.appendChild(dv);
  drag={p,r,dv,x0:fx(e,r),y0:fy(e,r),x1:fx(e,r),y1:fy(e,r)}});
 p.frame.addEventListener('click',()=>{if(swallow||adding)return;p.frame.classList.toggle('zoom')})});
function hi(p,mk){p.frame.querySelectorAll('.bx').forEach(b=>b.classList.toggle('hi',!!mk&&b.dataset.kind===mk.dataset.kind&&b.dataset.n===mk.dataset.n))}
function cl(v){return Math.min(1,Math.max(0,v))}function fx(e,r){return cl((e.clientX-r.left)/r.width)}function fy(e,r){return cl((e.clientY-r.top)/r.height)}
document.addEventListener('mousemove',e=>{if(!drag)return;drag.x1=fx(e,drag.r);drag.y1=fy(e,drag.r);
 drag.dv.setAttribute('style',pos([Math.min(drag.x0,drag.x1),Math.min(drag.y0,drag.y1),Math.max(drag.x0,drag.x1),Math.max(drag.y0,drag.y1)]))});
document.addEventListener('mouseup',()=>{if(!drag)return;const g=drag;drag=null;g.dv.remove();swallow=true;setTimeout(()=>swallow=false,0);
 const b=[Math.min(g.x0,g.x1),Math.min(g.y0,g.y1),Math.max(g.x0,g.x1),Math.max(g.y0,g.y1)].map(v=>Math.round(v*1e4)/1e4);
 if(b[2]-b[0]<0.005||b[3]-b[1]<0.005)return;st(g.p.d).added.push({box:b,cls:null,overlaps:null,text:''});save();render(g.p)});
function toggleAdd(){adding=!adding;document.body.classList.toggle('adding',adding);document.getElementById('addbtn').classList.toggle('on',adding)}
function go(i,scroll=true){if(i<0||i>=P.length)return;P[cur].el.classList.remove('cur');cur=i;P[cur].el.classList.add('cur');
 if(scroll)P[cur].el.scrollIntoView({block:'start'})}
function head(){document.documentElement.style.setProperty('--head',document.querySelector('header').offsetHeight+'px')}
addEventListener('resize',head);document.querySelector('details').addEventListener('toggle',head);head();
document.addEventListener('keydown',e=>{const p=P[cur];if(!p||e.metaKey||e.ctrlKey||e.altKey)return;
 if(['INPUT','TEXTAREA'].includes(e.target.tagName)&&e.target.type!=='radio')return;
 if(e.key==='j')go(cur+1);else if(e.key==='k')go(cur-1);else if(e.key==='z')p.frame.classList.toggle('zoom');
 else if(e.key==='a')toggleAdd();else if(BANDS[e.key]){st(p.d).band=BANDS[e.key];save();paint(p)}});
function exportAnswers(){const out={};P.forEach(p=>{const a=st(p.d);out[p.d.page]={band:a.band,note:a.note||'',candidates:a.candidates,added:a.added}});
 const b=new Blob([JSON.stringify(out,null,1)],{type:'application/json'});
 const l=document.createElement('a');l.href=URL.createObjectURL(b);l.download='marks-core-answers.json';l.click()}
save();go(0,false);
</script>"""


# ---------- the export ----------

def yolo_line(cls, box):
    """One YOLO row: the class index in marks_set.CLASSES, then centre x, centre y, width, height, all 0-1."""
    x0, y0, x1, y1 = box
    return f'{M.CLASSES.index(cls)} {(x0 + x1) / 2:.6f} {(y0 + y1) / 2:.6f} {x1 - x0:.6f} {y1 - y0:.6f}'


def page_done(a, n_cands):
    """The sheet's rule: a band, and every candidate kept with a class or dropped; every added box has a class."""
    cs = (a or {}).get('candidates') or {}
    ok = lambda m: bool(m) and (m.get('keep') is False or (m.get('keep') is True and m.get('cls') in M.CLASSES))  # noqa: E731
    return bool(a and a.get('band') in BAND_AMOUNT and all(ok(cs.get(str(n))) for n in range(1, n_cands + 1))
                and all(m.get('cls') in M.CLASSES for m in a.get('added') or []))


def write_classes(out_dir):
    (out_dir / 'classes.txt').write_text('\n'.join(M.CLASSES) + '\n')


def export_yolo(answers, key, out_dir):
    """YOLO files for the core pages the owner finished: kept candidates (the draft's box, the owner's class) and
    the boxes he added. An unfinished page writes no file and is listed, so a missing answer never reads as 'no
    marks'. marks.json keeps the owner's band (as a marks_set.AMOUNTS value or 'nontext'), texts and overlaps."""
    from marks_core import COMMENT
    for page in answers.values():
        entries = list((page.get('candidates') or {}).values()) + (page.get('added') or [])
        if page.get('note', '').strip() or any(COMMENT.search(m.get('text') or '') for m in entries):
            raise ValueError('Owner question feedback must be retained with marks_core.py freeze; '
                             'the plain YOLO export cannot treat it as transcription or detector truth')
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    write_classes(out_dir)
    truth, unfinished, boxes = {}, [], 0
    for pid in key.get('order') or sorted(key['pages']):
        cands, a = key['pages'][pid]['candidates'], answers.get(pid)
        if not page_done(a, len(cands)):
            unfinished.append(pid)
            continue
        marks = []
        for n, c in enumerate(cands, 1):
            m = a['candidates'][str(n)]
            if m['keep']:
                marks.append(dict(box=c['box'], cls=m['cls'], overlaps=m.get('overlaps'), text=m.get('text') or '',
                                  origin='draft'))
        for m in a.get('added') or []:
            marks.append(dict(box=[float(v) for v in m['box']], cls=m['cls'], overlaps=m.get('overlaps'),
                              text=m.get('text') or '', origin='owner'))
        (out_dir / (pid + '.txt')).write_text(''.join(yolo_line(m['cls'], m['box']) + '\n' for m in marks))
        truth[pid] = dict(band=BAND_AMOUNT[a['band']], note=a.get('note') or '', marks=marks)
        boxes += len(marks)
    (out_dir / 'marks.json').write_text(json.dumps(dict(
        protocol='marks-core-truth-v1', note="The owner's answers on the core sheet; boxes of kept drafts are the "
        "drafts' rough boxes.", classes=list(M.CLASSES), pages=truth, unfinished=unfinished), indent=1,
        ensure_ascii=False) + '\n')
    return dict(pages=len(truth), boxes=boxes, unfinished=len(unfinished))


def export_yolo_drafts(out_dir, routes=None):
    """Agreed-only YOLO files for the non-core pages. A page a route did not draft writes no file (agreement needs
    both), and single-route marks are left out, so these files are model drafts, not truth: an area with no row may
    still hold a mark."""
    routes = routes or default_routes()
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    write_classes(out_dir)
    pages, skipped = {}, []
    for r in M.selection()['rows']:
        if r.get('core'):
            continue
        got = [(name, inner(f(r['id']))) for name, f in routes.items()]
        if not all(d for _, d in got):
            skipped.append(r['id'])
            continue
        agreed, single = consensus(got)
        (out_dir / (r['id'] + '.txt')).write_text(''.join(yolo_line(c['cls'], c['box']) + '\n' for c in agreed))
        pages[r['id']] = dict(agreed=len(agreed), single=len(single))
    (out_dir / 'manifest.json').write_text(json.dumps(dict(
        protocol='marks-drafts-agreed-v1', truth=False,
        note='MODEL DRAFTS, NOT TRUTH: only the marks every route found (IoU >= %.1f) with the same class. Marks '
             'one route alone found are left out, so a page may hold marks with no row.' % IOU_PAIR,
        routes=list(routes), classes=list(M.CLASSES), pages=pages, skipped_no_draft=skipped), indent=1) + '\n')
    return dict(pages=len(pages), agreed=sum(p['agreed'] for p in pages.values()),
                single=sum(p['single'] for p in pages.values()), skipped=len(skipped))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    b = sub.add_parser('build')
    b.add_argument('--out', type=Path, default=M.CACHE / 'sheet')
    b.add_argument('--partial', action='store_true', help='a trial build with one route; never offered')
    e = sub.add_parser('export')
    e.add_argument('--answers', type=Path, required=True)
    e.add_argument('--key', type=Path, default=M.CACHE / 'sheet' / 'key.json')
    e.add_argument('--out', type=Path, default=M.CACHE / 'export')
    a = ap.parse_args()
    if a.cmd == 'build':
        print(json.dumps(build(a.out, partial=a.partial)))
    else:
        core = export_yolo(M.load(a.answers), M.load(a.key), a.out / 'core')
        print(json.dumps(dict(core=core, drafts=export_yolo_drafts(a.out / 'drafts'))))


if __name__ == '__main__':
    main()
