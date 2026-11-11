#!/usr/bin/env python3
"""W46.ocr-vision-unfiltered: Apple Vision's failure rate on owner pages drawn without the 20-word filter.

The 96 were drawn through a Vision filter: every candidate where Apple Vision (macOS 26.6) read fewer than
ocr_truth.MIN_WORDS words was replaced (P8-3, ocr_card.DRAW_96), so no owner page Vision reads as empty is in them
and the free default's card has no failure rate on owner material. This draws pages without that filter, reads
them with Vision as the bench's panel did (`segbench-ocr`, ocr.swift: .accurate, language correction on) on the
current OS, and asks the owner one thing per page, with no transcription: does it have text?

  heavy-run.py run -- /usr/local/bin/python3 ocr_vision_unfiltered.py draw    # pages, Vision words, the orientation scores
  python3 ocr_vision_unfiltered.py sheet                        # the owner's sheet (private, in the bench cache)
  python3 ocr_vision_unfiltered.py report                       # the draw's counts, before the owner's answers
  python3 ocr_vision_unfiltered.py score ANSWERS.json           # the failure rate -> segbench-results

THE DRAW RULE, written before the draw ran (salt ``SALT``):
  * The 19 pages the 96's draw replaced (ocr-truth/draw.json "replaced"), from their prepared images
    (ocr-truth/prep, by key), read again by Vision on the current OS. They are reported apart: they were chosen
    BY Vision's reading, so they say what the filter took out, not how often Vision fails.
  * DRAWN pages from the 96's pool (ocr_truth.documents over its index: the collection folders, label photos
    left out, documents implied by the tags): the documents ordered by sha256(SALT + document id), a document
    holding one of the 96's chosen or replaced pages left out, and from each the page with the lowest
    sha256(SALT + file name). No caps, strata, attribute balancing or word filter: one page per document,
    uniform over documents, which is what the failure rate is a rate of. A page that cannot be read from disk is
    passed over and counted. Images are prepared as the 96's were (ocr_truth.prepare: the original photograph
    when exactly one exists, else the PDF's image, EXIF orientation applied, turned like the PDF page).
  * Vision reads the prepared image as stored, as the 96's draw did; the count is ocr_truth.vision_words.

THE OWNER'S QUESTION, one key per page: 1 no text (a blank, a photograph, a drawing with no writing),
2 a few words only (a label, a cover title, a caption: under about 20 words), 3 a page of text. Collapsed to
yes or no, "has text" is 2 or 3. Vision FAILS on a page when it reads fewer than MIN_WORDS words of a page of
text (answer 3), and is EMPTY on a page with text when it reads none (2 or 3). The page's folder tags are listed,
not asked; Vision's count is not shown, so nothing on the sheet says what Vision read.

Reads the corpus read only (through ocr_truth.prepare), writes the bench cache (OUT); the committed result,
segbench-results/ocr-vision-unfiltered.{md,json}, is counts only, because the repo is public.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import platform
import random
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import ocr_truth as T                      # noqa: E402

TRUTH = T.CACHE                             # the 96's draw (read only here)
OUT = T.CACHE.parent / 'ocr-vision-unfiltered'
RESULTS = HERE.parents[1] / 'segbench-results' / 'ocr-vision-unfiltered'
SALT = 'W46.ocr-vision-unfiltered'
N_DRAWN = 200
SEED = 20261111                             # the sheet's order
ORIENT_BIN = T.OCR_BIN.parent / 'segbench-ocr-orient'
TURN_RATIO, TURN_MIN = 2.0, 20.0            # item_fields_retruth.display_turns' clear-win rule
SECONDS_PER_PAGE = 5
ANSWERS = {'1': 'no text', '2': 'a few words', '3': 'a page of text'}


def h(s: str) -> str:
    return hashlib.sha256((SALT + s).encode()).hexdigest()


def os_version() -> str:
    return platform.mac_ver()[0]


# ---------------------------------------------------------------- the draw (under the heavy lock)

def replaced_rows(draw):
    rows = []
    for r in draw['replaced']:
        key = hashlib.sha256(f"{r['folder']}/{r['name']}".encode()).hexdigest()[:16]
        src = TRUTH / 'prep' / f'{key}.jpg'
        if not src.exists():
            raise SystemExit('a replaced page has no prepared image: ' + key)
        meta = json.loads((TRUTH / 'prep' / f'{key}.json').read_text()) if (TRUTH / 'prep' / f'{key}.json').exists() else {}
        img = OUT / 'img' / f'{key}.jpg'
        if not img.exists():
            shutil.copyfile(src, img)          # a copy, so Vision's fresh reading lands beside it, not on the 26.6 one
        rows.append({'id': 'replaced:' + key, 'set': 'replaced', 'key': key, 'folder': r['folder'], 'name': r['name'],
                     'tags': meta.get('tags', []), 'source': meta.get('source'), 'words_26_6': r['words'],
                     'words': T.vision_words(img)})
    return rows


def drawn_rows(draw, idx):
    in96 = {(c['folder'], c['name']) for c in draw['chosen']} | {(r['folder'], r['name']) for r in draw['replaced']}
    docs = []
    for f in idx['folders']:
        for d in T.documents(f['folder'], f['photos']):
            if not any((f['folder'], n) in in96 for n, _ in d):
                docs.append((f"{f['folder']}#{d[0][0]}", f['folder'], d))
    docs.sort(key=lambda x: h(x[0]))
    T.CACHE = OUT                              # ocr_truth.prepare writes its copy and its Vision text under OUT/prep
    rows, failed = [], []
    for doc_id, folder, d in docs:
        if len(rows) == N_DRAWN:
            break
        name, tags = min(d, key=lambda p: h(p[0]))
        rec = T.prepare(folder, name, tags, idx['originals'])
        if 'error' in rec:
            failed.append({'doc': doc_id, 'error': rec['error'][:200]})
            continue
        rows.append({'id': 'drawn:' + rec['key'], 'set': 'drawn', 'key': rec['key'], 'folder': folder, 'name': name,
                     'tags': tags, 'source': rec['source'], 'doc_pages': len(d), 'words': rec['words']})
        print(len(rows), rec['words'], flush=True)
    T.CACHE = TRUTH
    return rows, failed, len(docs)


def image_path(r) -> Path:
    return OUT / ('img' if r['set'] == 'replaced' else 'prep') / f"{r['key']}.jpg"


def orient(rows):
    src = HERE / 'ocr_orient.swift'
    if not ORIENT_BIN.exists() or ORIENT_BIN.stat().st_mtime < src.stat().st_mtime:
        r = subprocess.run(['/usr/bin/swiftc', '-O', str(src), '-o', str(ORIENT_BIN)], capture_output=True, text=True)
        if r.returncode:
            raise SystemExit('ocr_orient.swift did not compile:\n' + r.stderr)
    lst = OUT / 'orient-list.txt'
    lst.write_text(''.join(f'{image_path(r)}\n' for r in rows))
    out = subprocess.run([str(ORIENT_BIN), str(lst)], capture_output=True, text=True).stdout
    (OUT / 'orient.tsv').write_text(out)


def cmd_draw(_):
    (OUT / 'img').mkdir(parents=True, exist_ok=True)
    draw = json.loads((TRUTH / 'draw.json').read_text())
    rows = replaced_rows(draw)
    drawn, failed, pool = drawn_rows(draw, T.load_index())
    rows += drawn
    orient(rows)
    (OUT / 'pages.jsonl').write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in rows))
    (OUT / 'draw.json').write_text(json.dumps({'salt': SALT, 'os': os_version(), 'pool_docs': pool,
                                               'n_drawn': len(drawn), 'failed': failed}, indent=1))
    print(len(rows), 'pages,', len(failed), 'not readable from disk')


def load_pages():
    return [json.loads(x) for x in (OUT / 'pages.jsonl').read_text().splitlines()]


def turns() -> dict[str, int]:
    """{key: degrees clockwise that show the page upright}: clear wins only (item_fields_retruth.display_turns'
    rule), and any turn an eye check put in orient-eye.tsv ("<key> <degrees>")."""
    out = {}
    f = OUT / 'orient.tsv'
    for line in (f.read_text().splitlines() if f.exists() else []):
        p = line.split('\t')
        if len(p) != 5:
            continue
        sc = [float(x) for x in p[1:]]
        best = max(range(4), key=lambda i: sc[i])
        rest = [sc[i] for i in range(4) if i != best]
        if best and all(sc[best] >= TURN_RATIO * x for x in rest) and sc[best] - max(rest) >= TURN_MIN:
            out[Path(p[0]).stem] = 90 * best
    eye = OUT / 'orient-eye.tsv'
    for line in (eye.read_text().splitlines() if eye.exists() else []):
        p = line.split()
        if len(p) >= 2 and p[1] in ('0', '90', '180', '270'):
            out[p[0]] = int(p[1])
    return {k: v for k, v in out.items() if v}


# ---------------------------------------------------------------- the sheet

def listed_tags(tags):
    return ', '.join(t for t in tags if t not in T.ID_IGNORED) or 'none'


def cmd_sheet(_):
    rows = load_pages()
    tn = turns()
    order = rows[:]
    random.Random(SEED).shuffle(order)          # the replaced pages mixed in, so none stands out by place
    sheet = OUT / 'sheet'
    sheet.mkdir(exist_ok=True)
    items = [{'id': r['id'], 'img': os.path.relpath(image_path(r), sheet), 'turn': tn.get(r['key'], 0),
              'tags': listed_tags(r['tags'])} for r in order]
    minutes = round(len(items) * SECONDS_PER_PAGE / 60)
    page = SHEET_HTML.replace('__ITEMS__', json.dumps(items)).replace('__N__', str(len(items))) \
                     .replace('__MIN__', str(minutes)).replace('__TURNED__', str(sum(1 for i in items if i['turn'])))
    (sheet / 'index.html').write_text(page)
    print(sheet / 'index.html', len(items), 'pages,', sum(1 for i in items if i['turn']), 'turned, about', minutes, 'min')


SHEET_HTML = r"""<!doctype html><meta charset="utf-8"><title>Does this page have text?</title>
<style>body{font:15px -apple-system,sans-serif;margin:0;display:flex;height:100vh}
#side{width:340px;padding:14px;overflow:auto;border-right:1px solid #ccc;box-sizing:border-box}
#main{flex:1;display:flex;align-items:center;justify-content:center;overflow:hidden;background:#333}
#main img{max-width:96%;max-height:96%;transition:transform .1s;background:#fff}
.k{display:inline-block;border:1px solid #888;border-radius:4px;padding:1px 6px;margin:2px;cursor:pointer}
.k.on{background:#2a6;color:#fff;border-color:#2a6}textarea{width:100%;height:70px}
#bar{height:6px;background:#2a6}small{color:#555}</style>
<div id="side"><h3>Does this page have text?</h3>
<p><small>__N__ pages, about __MIN__ minutes. One key per page; it moves on by itself. <b>1</b> no text (blank,
photograph, a drawing with no writing) · <b>2</b> a few words only (a label, a cover title, a caption: under about 20
words) · <b>3</b> a page of text (any letter, form, table, clipping or note with more than that, typed, printed or
handwritten, readable or not). ← → move, <b>r</b> turns the page. __TURNED__ pages were turned upright before the sheet
was built (a clear text score, or an eye check where the score was unsure); turn any that is still not upright. Nothing else is asked: the folder tags listed
below each page go in as listed, and a note can correct them or say a page should be dropped.
Answers save in this browser as you go; press <b>Export</b> at the end and keep the file.</small></p>
<div id="bar"></div><p id="pos"></p>
<p><span class="k" data-a="1">1 no text</span><span class="k" data-a="2">2 a few words</span><span class="k" data-a="3">3 a page of text</span></p>
<p><small>Folder tags (listed, not asked): <span id="tags"></span></small></p>
<p><span class="k" id="rot">r turn</span></p>
<p>Note on this page (optional)<br><textarea id="note"></textarea></p>
<p><span class="k" id="exp">Export</span> <span class="k" id="next">next unanswered</span></p></div>
<div id="main"><img id="im"></div>
<script>
const items=__ITEMS__;const KEY='w46-ocr-vision-unfiltered';
let A=JSON.parse(localStorage.getItem(KEY)||'{}');A._notes=A._notes||{};A._turns=A._turns||{};
const save=()=>localStorage.setItem(KEY,JSON.stringify(A));
let cur=0;const im=document.getElementById('im'),note=document.getElementById('note');
function turn(it){return ((A._turns[it.id]??0)+it.turn)%360}
function go(i){if(i<0||i>=items.length)return;cur=i;const it=items[i];im.src=it.img;
 im.style.transform='rotate('+turn(it)+'deg)';document.getElementById('tags').textContent=it.tags;
 note.value=A._notes[it.id]||'';document.querySelectorAll('[data-a]').forEach(k=>k.classList.toggle('on',A[it.id]===k.dataset.a));
 const n=items.filter(x=>A[x.id]).length;document.getElementById('pos').textContent='page '+(i+1)+' of '+items.length+' · '+n+' answered';
 document.getElementById('bar').style.width=(100*n/items.length)+'%'}
function answer(a){A[items[cur].id]=a;save();go(cur);setTimeout(()=>go(Math.min(cur+1,items.length-1)),120)}
function rot(){const it=items[cur];A._turns[it.id]=((A._turns[it.id]??0)+90)%360;save();go(cur)}
note.addEventListener('input',()=>{const id=items[cur].id;if(note.value)A._notes[id]=note.value;else delete A._notes[id];save()});
note.addEventListener('keydown',e=>e.stopPropagation());
document.querySelectorAll('[data-a]').forEach(k=>k.onclick=()=>answer(k.dataset.a));
document.getElementById('rot').onclick=rot;
document.getElementById('next').onclick=()=>{const j=items.findIndex(x=>!A[x.id]);if(j>=0)go(j)};
document.getElementById('exp').onclick=()=>{const b=new Blob([JSON.stringify(A,null,1)],{type:'application/json'});
 const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='ocr-vision-unfiltered-answers.json';a.click()};
document.addEventListener('keydown',e=>{if(e.metaKey||e.ctrlKey)return;
 if('123'.includes(e.key)&&e.key.length==1)answer(e.key);else if(e.key=='ArrowRight')go(cur+1);
 else if(e.key=='ArrowLeft')go(cur-1);else if(e.key=='r')rot()});
go(Math.max(0,items.findIndex(x=>!A[x.id])));
</script>"""


# ---------------------------------------------------------------- the result

def rate(k, n):
    lo, hi = T.CS.wilson(k, n)
    return {'k': k, 'n': n, 'pct': round(100 * k / n, 1) if n else None,
            'ci95': [round(100 * lo, 1), round(100 * hi, 1)] if n else None}


def fmt(r):
    return f"{r['k']} of {r['n']}" + (f" ({r['pct']}%, 95% {r['ci95'][0]}-{r['ci95'][1]}%)" if r['n'] else '')


def tally(rows, answers=None):
    out = {}
    for s in ('drawn', 'replaced'):
        rs = [r for r in rows if r['set'] == s]
        w = [r['words'] for r in rs]
        o = {'pages': len(rs), 'vision_empty': rate(sum(x == 0 for x in w), len(rs)),
             'vision_under_min': rate(sum(x < T.MIN_WORDS for x in w), len(rs))}
        hand = [r for r in rs if 'Handwritten' in r['tags']]
        o['handwritten_tagged'] = {'pages': len(hand), 'vision_under_min': rate(sum(r['words'] < T.MIN_WORDS for r in hand), len(hand))}
        if answers is not None:
            a = {r['id']: answers.get(r['id']) for r in rs}
            o['answers'] = dict(collections.Counter(ANSWERS.get(v, 'unanswered') for v in a.values()))
            text = [r for r in rs if a[r['id']] == '3']
            has = [r for r in rs if a[r['id']] in ('2', '3')]
            o['fail_on_text_page'] = rate(sum(r['words'] < T.MIN_WORDS for r in text), len(text))
            o['empty_on_has_text'] = rate(sum(r['words'] == 0 for r in has), len(has))
            o['under_min_no_text'] = rate(sum(r['words'] < T.MIN_WORDS for r in rs if a[r['id']] == '1'),
                                          sum(1 for r in rs if a[r['id']] == '1'))
            ht = [r for r in text if 'Handwritten' in r['tags']]
            o['fail_on_handwritten_text_page'] = rate(sum(r['words'] < T.MIN_WORDS for r in ht), len(ht))
        out[s] = o
    return out


def write_result(meta, t, answers=None):
    d, rp = t['drawn'], t['replaced']
    RESULTS.with_suffix('.json').write_text(json.dumps({'meta': meta, 'tally': t}, indent=1) + '\n')
    L = ['# W46.ocr-vision-unfiltered — Apple Vision on owner pages drawn without the 20-word filter', '',
         f"Written by `ArchiveProcessor/scripts/segbench/ocr_vision_unfiltered.py`. Vision is `segbench-ocr` "
         f"(ocr.swift: .accurate, language correction on), the panel's tool, read on macOS {meta['os']}. Counts only: "
         f"the pages and the sheet are in the bench cache (`ocr-vision-unfiltered/`), outside git.", '']
    if answers is None:
        L += ['**Status: the sheet waits for the owner.** The figures below are Vision\'s word counts alone; without '
              'the owner\'s answers they do not say how many of the short readings are pages with no text (a '
              'blank, a photograph) and how many are pages Vision failed on.', '']
    else:
        L += ['## Verdict', '',
              f"On {d['answers'].get('a page of text', 0)} drawn pages the owner marked as a page of text, Vision read "
              f"fewer than {T.MIN_WORDS} words on {fmt(d['fail_on_text_page'])}: that is the free first reader's "
              f"failure rate on owner material, one page per document. It read nothing on "
              f"{fmt(d['empty_on_has_text'])} of the drawn pages with any text. On handwritten-tagged pages of text: "
              f"{fmt(d['fail_on_handwritten_text_page'])}.", '']
    L += ['## The draw', '',
          f"{d['pages']} pages, one per document, ordered by a salted hash over the {meta['pool_docs']:,} documents of "
          f"the 96's pool that hold none of the 96's pages (no caps, strata or word filter); "
          f"{len(meta['failed'])} passed over as unreadable from disk. Apart from them, the {rp['pages']} pages the "
          f"96's draw replaced, read again: they were chosen by Vision's reading, so they show what the filter took "
          f"out, not a rate.", '',
          '| | drawn | replaced at the 96\'s draw |', '|---|---|---|',
          f"| pages | {d['pages']} | {rp['pages']} |",
          f"| Vision reads nothing | {fmt(d['vision_empty'])} | {fmt(rp['vision_empty'])} |",
          f"| Vision reads under {T.MIN_WORDS} words | {fmt(d['vision_under_min'])} | {fmt(rp['vision_under_min'])} |",
          f"| tagged Handwritten: under {T.MIN_WORDS} words | {fmt(d['handwritten_tagged']['vision_under_min'])} | "
          f"{fmt(rp['handwritten_tagged']['vision_under_min'])} |"]
    if answers is not None:
        L += [f"| owner: no text / a few words / a page of text | " +
              ' / '.join(str(d['answers'].get(v, 0)) for v in ANSWERS.values()) + ' | ' +
              ' / '.join(str(rp['answers'].get(v, 0)) for v in ANSWERS.values()) + ' |',
              f"| Vision under {T.MIN_WORDS} words on a page of text | {fmt(d['fail_on_text_page'])} | {fmt(rp['fail_on_text_page'])} |",
              f"| Vision reads nothing on a page with text | {fmt(d['empty_on_has_text'])} | {fmt(rp['empty_on_has_text'])} |"]
    L += ['', '## Measurement card', '',
          '- **Truth:** ' + ('the owner\'s answer per page (1 no text, 2 a few words, 3 a page of text), on a sheet '
                             'that shows neither Vision\'s count nor which pages were replaced; no model drafted it.'
                             if answers is not None else
                             'none yet: the owner\'s yes or no per page, on the sheet this item built (about '
                             f"{meta['minutes']} minutes); Vision's counts here are not truth."),
          '- **Selection:** a salted hash over documents, fixed before the draw ran; never by a route\'s answer or the '
          'ABBYY text. The replaced pages were selected by Vision (26.6) and are kept apart for that reason.',
          f"- **Comparison:** one route, Vision as the panel reads it, on the prepared image as stored (turned like the "
          f"PDF page, as the 96's were); the app's rotation step is not applied first, so a page stored sideways counts "
          f"against Vision here ({meta['turned']} pages are stored turned, by a clear text score or an eye check).",
          '- **Noise:** Vision is deterministic on one OS build (vision-27-reread.md); the intervals are Wilson 95% on '
          'pages, one page per document.',
          '- **Scope:** owner material in the collection folders only; a rate of pages, not of words read wrongly on '
          'pages Vision does read (the 96 measure that); the free default\'s card cites the drawn figure, never the '
          'replaced pages\'.', '']
    RESULTS.with_suffix('.md').write_text('\n'.join(L))


def meta_of(rows):
    m = json.loads((OUT / 'draw.json').read_text())
    m['turned'] = len(turns())
    m['minutes'] = round(len(rows) * SECONDS_PER_PAGE / 60)
    return m


def cmd_report(_):
    rows = load_pages()
    write_result(meta_of(rows), tally(rows))
    print(RESULTS.with_suffix('.md'))


def cmd_score(a):
    rows = load_pages()
    answers = json.loads(Path(a.answers).read_text())
    missing = [r['id'] for r in rows if r['id'] not in answers]
    if missing and not a.partial:
        raise SystemExit(f'{len(missing)} pages unanswered (--partial to score anyway)')
    write_result(meta_of(rows), tally(rows, answers), answers)
    notes = answers.get('_notes', {})
    print(RESULTS.with_suffix('.md'), f'{len(notes)} notes: read them before using the figure')
    for k, v in notes.items():
        print(' ', k, v)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)
    sub.add_parser('draw')
    sub.add_parser('sheet')
    sub.add_parser('report')
    s = sub.add_parser('score')
    s.add_argument('answers')
    s.add_argument('--partial', action='store_true')
    a = p.parse_args(argv)
    {'draw': cmd_draw, 'sheet': cmd_sheet, 'report': cmd_report, 'score': cmd_score}[a.cmd](a)


if __name__ == '__main__':
    main()
