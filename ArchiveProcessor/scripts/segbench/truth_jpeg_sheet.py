#!/usr/bin/env python3
"""W46.truth-jpeg-upgrade: an owner sheet for the truth pages that came from a corpus PDF with no matching JPEG.

    python3 truth_jpeg_sheet.py --out DIR     # writes DIR/index.html (+ candidate thumbnails); reads both trees only

For each such page the sheet shows the truth image, its corpus PDF path, and up to three candidate JPEGs from
"Archival Photos JPEGS": the JPEGs whose file stem shares a 3+ digit number with the PDF's and at least one name word
with its folder or file name (at most MAX_TRY of them), ranked by the truth builder's own test (ocr_truth.
orient_like_pdf, grey thumbnails correlated at the best of four turns; true pairs measure about 0.69-0.98). The owner
either picks a candidate, types the right JPEG's path, or says no JPEG exists. The answers are exported as
truth-jpeg-answers.json. Nothing in either tree is written.
"""
from __future__ import annotations

import argparse
import csv
import html
import json
import os
import re
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
TRUTH = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/ocr-truth'
MIN_CORR, MAX_TRY, SHOW = 0.65, 40, 3
WORD = re.compile(r'[a-z]{2,}')
NUM = re.compile(r'\d{3,}')


def words(s):
    return {w for w in WORD.findall(s.lower()) if w not in ('img', 'pdf', 'jpg', 'jpeg', 'the', 'and', 'of')}


def main():
    ap = argparse.ArgumentParser(description=__doc__); ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    from PIL import Image
    import corpus_pairs as CP
    import ocr_truth as OT
    recs = [r for r in json.load(open(TRUTH / 'compare.json')) if isinstance(r, dict) and 'source' in r]
    page_of = {(r['folder'], r['name']): r['page'] for r in csv.DictReader(open(TRUTH / 'pages.tsv'), delimiter='\t')}
    pairs = {}
    for line in open(os.path.join(CP.CACHE, 'pairs.tsv'), encoding='utf-8').read().splitlines()[1:]:
        p, j, m = line.split('\t')[:3]
        if j and m != 'none':
            pairs[p] = j
    tmp = Path(tempfile.mkdtemp(dir=os.path.join(CP.CACHE, 'tmp')))
    jroot = Path(CP.JPEGS)
    alljpg = [str(Path(d, f).relative_to(jroot)) for d, _, fs in os.walk(jroot) for f in fs
              if f.lower().endswith(('.jpg', '.jpeg'))]
    by_num = {}
    for j in alljpg:
        for n in set(NUM.findall(Path(j).stem)):
            by_num.setdefault(n, []).append(j)

    def corr(jpg, pdf):
        with Image.open(jroot / jpg) as im:
            im.draft('RGB', (800, 800))
            return OT.orient_like_pdf(im, pdf, tmp)

    cards = []
    (a.out / 'candidates').mkdir(parents=True, exist_ok=True)
    for r in recs:
        if r['source'] == 'original':
            continue
        rel = os.path.join(r['folder'], r['name']); pdf = Path(CP.CS.CORPUS) / rel
        if rel in pairs and corr(pairs[rel], pdf)[1] >= MIN_CORR:
            continue                                        # one of the eight already confirmed
        page = page_of[(r['folder'], r['name'])]
        want = words(rel)
        pool = {j for n in set(NUM.findall(Path(r['name']).stem)) for j in by_num.get(n, [])}
        pool = sorted(pool, key=lambda j: -len(want & words(j)))
        pool = [j for j in pool if want & words(j)][:MAX_TRY]
        scored = []
        for j in pool:
            try:
                deg, c = corr(j, pdf)
            except Exception:
                continue
            scored.append((c, deg, j))
        scored.sort(reverse=True)
        cands = []
        for i, (c, deg, j) in enumerate(scored[:SHOW]):
            thumb = f'candidates/{page}-{i + 1}.jpg'
            with Image.open(jroot / j) as im:
                im.draft('RGB', (900, 900)); im = im.convert('RGB').rotate(deg, expand=True); im.thumbnail((900, 900))
                im.save(a.out / thumb, 'JPEG', quality=85)
            cands.append({'jpeg': j, 'corr': round(c, 2), 'thumb': thumb})
        img = next(a.out.glob(f'{page} — truth page*'), None)
        cards.append({'page': page, 'pdf': rel, 'img': img.name if img else '', 'tried': len(pool), 'cands': cands})
        print(page, len(pool), [c['corr'] for c in cands], flush=True)
    (a.out / 'index.html').write_text(PAGE.replace('__DATA__', json.dumps(cards, ensure_ascii=False)))
    print(len(cards), 'pages ->', a.out / 'index.html')


PAGE = r'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Truth page JPEGs</title>
<style>
:root{--bg:#fff;--fg:#1d1d1f;--mute:#6e6e73;--line:#d2d2d7;--pick:#0a66c2;--good:#1b7f3b;--card:#f5f5f7}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 -apple-system,system-ui,sans-serif}
header{position:sticky;top:0;background:var(--bg);border-bottom:1px solid var(--line);padding:10px 16px;z-index:2;
display:flex;gap:12px;align-items:center;flex-wrap:wrap}
header b{font-size:17px}#prog{color:var(--mute)}button{font:inherit;padding:6px 12px;border-radius:8px;
border:1px solid var(--line);background:var(--card);cursor:pointer}button.primary{background:var(--pick);color:#fff;border-color:var(--pick)}
main{max-width:1200px;margin:0 auto;padding:16px}.card{border:1px solid var(--line);border-radius:12px;padding:14px;margin:0 0 18px}
.card.done{border-color:var(--good)}.head{display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap}
.pdf{font-size:17px;font-weight:600;word-break:break-all;user-select:all;margin:4px 0 2px}.row{display:flex;gap:12px;overflow-x:auto;margin:10px 0}
figure{margin:0;flex:0 0 auto;width:260px}figure img{width:260px;height:340px;object-fit:contain;background:var(--card);
border:2px solid transparent;border-radius:8px;cursor:zoom-in}figure.sel img{border-color:var(--pick)}
figcaption{font-size:12px;color:var(--mute);word-break:break-all}.opts{display:flex;gap:14px;flex-wrap:wrap;align-items:center}
input[type=text]{flex:1;min-width:260px;font:inherit;padding:6px 8px;border:1px solid var(--line);border-radius:8px}
dialog img{max-width:92vw;max-height:88vh}dialog{border:none;padding:0;background:transparent}
</style></head><body>
<header><b>Truth pages without a JPEG original</b><span id="prog"></span>
<button class="primary" onclick="exportAnswers()">Export answers</button>
<span style="color:var(--mute);font-size:13px">For each page: type the matching JPEG's path (relative to "Archival
Photos JPEGS"), or tick "No JPEG exists". The candidates below each page are a guess by image similarity (about 0.69 or
more is a likely match); most here are not. Saved in this browser as you go.</span></header>
<main id="root"></main><dialog id="zoom" onclick="this.close()"><img id="zimg"></dialog>
<script>
const DATA=__DATA__, KEY='truth-jpeg-answers-v1';
let A={};try{A=JSON.parse(localStorage.getItem(KEY)||'{}')}catch(e){}
const save=()=>{try{localStorage.setItem(KEY,JSON.stringify(A))}catch(e){};render()};
const esc=s=>String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
function zoom(src){document.getElementById('zimg').src=src;document.getElementById('zoom').showModal()}
function pick(p,j){A[p]={jpeg:j,none:false};save()}
function none(p,v){A[p]=v?{jpeg:'',none:true}:{};save()}
function typed(p,v){A[p]={jpeg:v.trim(),none:false};try{localStorage.setItem(KEY,JSON.stringify(A))}catch(e){};
 document.getElementById('prog').textContent=count()}
const count=()=>`${DATA.filter(d=>A[d.page]&&(A[d.page].none||A[d.page].jpeg)).length} of ${DATA.length} answered`;
function render(){
 document.getElementById('prog').textContent=count();
 document.getElementById('root').innerHTML=DATA.map(d=>{const a=A[d.page]||{};const ok=a.none||a.jpeg;
  return `<section class="card ${ok?'done':''}"><div class="head"><b>${esc(d.page)}</b></div>
  <div class="pdf">${esc(d.pdf)}</div><div style="color:var(--mute);font-size:13px">the corpus PDF this truth page came from</div><div class="row">
  <figure><img src="${encodeURI(d.img)}" onclick="zoom(this.src)"><figcaption>The truth page (from the PDF)</figcaption></figure>
  ${d.cands.map(c=>`<figure class="${a.jpeg===c.jpeg?'sel':''}"><img src="${c.thumb}" onclick="zoom(this.src)">
   <figcaption>Candidate: ${esc(c.jpeg)}<br>similarity ${c.corr}<br><button onclick="pick('${d.page}','${c.jpeg.replace(/'/g,"\\'")}')">This is the match</button></figcaption></figure>`).join('')
   ||`<figcaption style="align-self:center">No candidate found (${d.tried} JPEGs share a number and a name word).</figcaption>`}
  </div><div class="opts"><label><input type="checkbox" ${a.none?'checked':''} onchange="none('${d.page}',this.checked)"> No JPEG exists</label>
  <input type="text" placeholder="or the matching JPEG's path" value="${esc(a.none?'':(a.jpeg||''))}" oninput="typed('${d.page}',this.value)"></div></section>`}).join('')}
function exportAnswers(){const b=new Blob([JSON.stringify(A,null,1)],{type:'application/json'});
 const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='truth-jpeg-answers.json';a.click()}
render();
</script></body></html>'''

if __name__ == '__main__':
    main()
