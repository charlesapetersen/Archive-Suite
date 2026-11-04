#!/usr/bin/env python3
"""W46.place-print — placement on print, measured (F-placement tests 2, 3, 5, 6 and 7; gap audit §5 item 21).

  $U place_print.py vision     test 2: Apple Vision's own word and line boxes, both APIs, against the truth
  $U place_print.py arms       test 3: Vision's own layers and the saved readings placed by the lab's alignedReading,
                               dragged line by line in PDFKit, with Find and the word scores
  $U place_print.py writers    test 5: three PDF writings of the same words, read by PDFKit, poppler, mupdf, pdf.js
  $U place_print.py verapdf    test 6: veraPDF PDF/A-2b and 2u over the writers' PDFs, and with a ToUnicode map
  $U place_print.py boxes      test 7: the box-emitting readers' and detectors' geometry beside Vision's
  $U place_print.py report     segbench-results/place-print.md and .json from the rows

  ($U is `uv run -q --with numpy --with rapidfuzz --with regex --with sacrebleu --with jiwer --with pikepdf
  --with ocrmypdf --with fonttools --with reportlab python`; run every step under ops/autonomous/heavy-run.py, as
  they work through a page set.)

Inputs, all saved before this item: the placement truth (place_truth.py STORE) with the owner's line rulings
folded (place_geom.fold_lines, W46.place-lines-owner-ok); Vision's words and lines read by place_print_vision.swift
(CACHE/vision/{accurate,documents}); the readings of the 96 as ocr_rescore.owner_sources() saves them; the box
readers' records from W46.ocr-new-open-boxes and the detector lines from W46.fix-place-truth-lines.

The line pass (F-placement §6.2, "Selection is a line", owner 2026-10-29) is place-geom's and place-hands-lines':
a PDFKit drag from a truth line's first ink to its last, at mid-height, passes when the selection holds no line
break and is exactly the words the layer holds for that line, in order. What a line expects is
place_hands_lines.expected's rule: the layer's words, in the layer's order, aligned to the truth's words by a
word edit distance, each taking the line of the truth word it pairs with. So a reading's misread word does not fail
a line, and a word the layer lacks does not either; a line the layer holds no word for fails. Every arm is scored on
every truth line of two or more scored words read less than 45° off level (the same set for every arm, so the
comparison is paired). Vision's rows are reported apart on the truth's drawn and Vision-derived lines (OCR-10).

Writes CACHE (layers, drags, extractions; rebuildable) and the committed results (counts and page ids only). No
network, no model, no money.
"""
from __future__ import annotations

import argparse
import collections
import json
import math
import os
import random
import re
import statistics
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import place_geom as G  # noqa: E402
import place_hands_lines as HL  # noqa: E402
import place_score as S  # noqa: E402
import place_truth  # noqa: E402

RESULTS = HERE.parents[1] / 'segbench-results'
REH = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
CACHE = REH / 'place-print'
VISION = CACHE / 'vision'
SHEET = REH / 'ocr-truth/place-lines'
FUNCTIONAL = Path(os.environ.get('PLACE_FUNCTIONAL', '/tmp/place_functional'))
WRITER = Path(os.environ.get('PLACE_GEOM_WRITER', '/tmp/place_geom_writer'))
ALIGN = Path(os.environ.get('PLACE_PRINT_ALIGN', '/tmp/place_print_align'))
PT = 72 / 300
UNSCORED = S.UNSCORED
APIS = ('accurate', 'bywords', 'documents')
# The readings placed through alignedReading (F test 3). Gemini 3.8 Flash drafted the 96's truth text; Qwen3.6-27B
# and LightOnOCR-3 neither drafted nor checked it. Falcon-OCR has no saved reading of the 96 (its align figures are
# the lab's 56 print pages), so it is not an arm here.
READINGS = ('gemini3.8-flash', 'qwen3.6-27b', 'lightonocr3-4b')
SEED, DRAWS = 46, 2000


def rulings():
    return json.loads((SHEET / 'rulings.json').read_text())['rulings']


def key(t):
    return t['page'].replace('/', '__')


def run_tool(args, check=True):
    r = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f'{args[0]} failed: {r.stderr[-800:]}')
    return r.stdout


def typed_pages():
    return [t for t in G.load_truth() if t['group'] == 'owner-typed']


def hyp(api, t):
    return json.loads((VISION / api / f'{key(t)}.json').read_text())


# ---------------------------------------------------------------- the truth's lines (owner's rulings folded)
def line_status(t):
    return {ln['id']: ln.get('status') for ln in t['lines']}


def truth_lines(t, folded):
    """[{id, tokens, start, end, scored, source}] in reading order. `source` is 'drawn' when any of the folded
    line's truth lines was drawn by a subagent, else 'vision' (its boxes drafted from Vision's, OCR-10)."""
    st = line_status(t)
    ident = G.identity_map(t['width'], t['height'])
    out = []
    for L, ws in folded.items():
        sc = [i for i in ws if t['words'][i]['status'] not in UNSCORED]
        ids = [int(x) for x in re.split(r'[+.]', L)[:1]] if '.' in L else [int(x) for x in L.split('+')]
        src = 'drawn' if any(st.get(i) == 'drawn' for i in ids) else 'vision'
        scored = len(sc) >= 2 and not G.sideways(t, sc)
        s = e = None
        if sc:
            s, e = G.drag_points(t, ident, sc)
            s, e = [float(v) for v in s], [float(v) for v in e]
        out.append({'id': L, 'tokens': [t['words'][i]['text'] for i in sc], 'start': s, 'end': e,
                    'scored': scored, 'source': src})
    return out


def expected_for(layer_lines, tl):
    """Truth line id -> the layer's words expected in its selection (place_hands_lines.expected's rule, on the
    layer's own text in the layer's order)."""
    rw, rline = [], []
    for k, text in enumerate(layer_lines):
        for w in text.split():
            rw.append(w)
            rline.append(k)
    tw, tid = [], []
    for L in tl:
        for w in L['tokens']:
            tw.append(w)
            tid.append(L['id'])
    pair = HL.align_words(rw, tw) if rw and tw else [None] * len(rw)
    lab = [tid[p] if p is not None else None for p in pair]
    for i in range(len(rw)):
        if lab[i] is not None:
            continue
        prev = next((k for k in range(i - 1, -1, -1) if pair[k] is not None), None)
        nxt = next((k for k in range(i + 1, len(rw)) if pair[k] is not None), None)
        lp = tid[pair[prev]] if prev is not None else None
        ln_ = tid[pair[nxt]] if nxt is not None else None
        if lp == ln_ or ln_ is None:
            lab[i] = lp
        elif lp is None:
            lab[i] = ln_
        else:
            lab[i] = lp if rline[prev] == rline[i] else ln_
    out = {L['id']: [] for L in tl}
    for w, L in zip(rw, lab):
        if L is not None:
            out[L].append(w)
    return {L: ' '.join(ws) for L, ws in out.items()}


# ---------------------------------------------------------------- test 2: Vision's own geometry
def word_strata(t, hw):
    """Per truth word stratum (its line's source), the truth words matched at centre and the words with no Vision
    box at all (no hypothesis word holds the truth word's centre: the cap on placement)."""
    tw = S.scoreable(t)
    st = line_status(t)
    pairs = S.match(tw, hw, 'centre')
    matched = {i for i, _, _ in pairs}
    out = collections.defaultdict(lambda: {'words': 0, 'matched': 0, 'no_box': 0})
    for i, w in enumerate(tw):
        src = 'drawn' if st.get(w.get('line')) == 'drawn' else 'vision'
        c = (w['box'][0] + w['box'][2] / 2, w['box'][1] + w['box'][3] / 2)
        o = out[src]
        o['words'] += 1
        o['matched'] += i in matched
        o['no_box'] += not any(S.inside(c, h['box']) for h in hw)
    return dict(out)


def cmd_vision(a):
    rows = []
    for t in place_truth.load_all():
        if (t.get('audit') or {}).get('verdict') != 'ok':
            continue
        for api in APIS:
            f = VISION / api / f'{key(t)}.json'
            if not f.exists():
                continue
            h = json.loads(f.read_text())
            r = S.score_page(t, h)
            ill = [w['box'] for w in t['words'] if w.get('box') and w['status'] == 'illegible']
            hw = [w for w in h['words'] if w.get('box') and not any(S.centres_meet(b, w['box']) for b in ill)]
            r.update(api=api, kind=t.get('kind'), strata=word_strata(t, hw), hyp_lines=len(h['lines']))
            rows.append(r)
    out = CACHE / 'vision-rows.json'
    out.write_text(json.dumps(rows) + '\n')
    print(f'{len(rows)} rows -> {out}')


# ---------------------------------------------------------------- test 3: the arms, dragged
def layer_lines_vision(h):
    return [{'text': ' '.join(l['text'].split()), 'box': l['box']} for l in h['lines']
            if l['text'].strip() and l['box'][2] > 0 and l['box'][3] > 0]


def documents_lines(h):
    """RecognizeDocumentsRequest's lines, as the layer would carry them."""
    return layer_lines_vision(h)


def readings_for(t):
    import ocr_rescore as O
    global _OWNER
    if '_OWNER' not in globals():
        _OWNER = {k: v for (k, _), v in O.owner_sources().items() if k in READINGS}
    return {r: _OWNER.get(r, {}).get(t['page']) for r in READINGS}


def anchor_share(vision_words, model_words):
    """The share of Vision's words the model's reading pairs with an equal word (case and punctuation aside), by
    place_hands_lines' word alignment: an approximation of alignedReading's anchors, which the lab does not report
    (its wordLikeness is not an exact-equality test)."""
    if not vision_words or not model_words:
        return 0.0
    pair = HL.align_words(vision_words, model_words)
    eq = sum(1 for i, j in enumerate(pair) if j is not None and HL.norm(vision_words[i]) and
             HL.norm(vision_words[i]) == HL.norm(model_words[j]))
    return eq / len(vision_words)


def multiset_share(a, b):
    """Share of the words of `a` found in `b`, counted with multiplicity (normalised)."""
    ca = collections.Counter(HL.norm(w) for w in a if HL.norm(w))
    cb = collections.Counter(HL.norm(w) for w in b if HL.norm(w))
    n = sum(ca.values())
    return sum(min(v, cb[k]) for k, v in ca.items()) / n if n else 0.0


def loose_pass(expected, got, broken):
    """The line pass with case and punctuation aside (place_hands_lines.norm per word): a selection that drops a
    line's closing comma, or its full stop, still holds the line's words in order. Reported beside the strict pass,
    never instead of it."""
    e = [HL.norm(w) for w in expected.split()]
    g = [HL.norm(w) for w in got.split()]
    return bool(expected) and not broken and [w for w in e if w] == [w for w in g if w]


def score_layer(t, tl, lines, work, name):
    """Write `lines` with the lab writer (no image, the page's size), drag every scored truth line, run Find and
    read the layer's word boxes back for the word scores."""
    pdf, dj, do = work / f'{name}.pdf', work / f'{name}.drags.json', work / f'{name}.out.json'
    jf, tj, hj = work / f'{name}.jobs.json', work / f'{name}.truth.json', work / f'{name}.hyp.json'
    jf.write_text(json.dumps([{'out': str(pdf), 'width': t['width'] * PT, 'height': t['height'] * PT,
                               'lines': lines}]))
    unplaced = len(json.loads(run_tool([WRITER, jf]))['unplaced'])
    exp = expected_for([l['text'] for l in lines], tl)
    scored = [L for L in tl if L['scored']]
    drags = [{'id': L['id'], 'expected': exp[L['id']], 'start': L['start'], 'end': L['end']}
             for L in scored if exp[L['id']]]
    dj.write_text(json.dumps({'lines': drags}))
    run_tool([FUNCTIONAL, 'drag', dj, pdf, do])
    got = {r['id']: r for r in json.loads(do.read_text())['lines']}
    tj.write_text(json.dumps({'page': t['page'], 'words': t['words']}))
    find = json.loads(run_tool([FUNCTIONAL, 'score', tj, pdf]))
    run_tool([FUNCTIONAL, 'words', tj, pdf, hj])
    ws = S.word_scores(t, json.loads(hj.read_text()))
    per = []
    for L in scored:
        g = got.get(L['id'])
        row = {'id': L['id'], 'source': L['source'], 'pass': bool(g and g['pass']),
               'loose': bool(g) and loose_pass(exp[L['id']], g['got'], g['broken']),
               'unread': not exp[L['id']], 'broken': bool(g and g['broken'])}
        if not row['pass']:
            row.update(expected=exp[L['id']], got=g['got'] if g else '')
        per.append(row)
    for f in (pdf, dj, do, jf, tj, hj):
        f.unlink(missing_ok=True)
    return {'lines': per, 'find_words': find['words'], 'found': find['found'], 'placed': find['placed'],
            'f1@centre': ws['f1@centre'], 'matched@centre': ws['matched@centre'], 'hyp_words': ws['hyp_words'],
            'truth_words': ws['truth_words'], 'mcer@0.5': ws['mcer@0.5'], 'unplaced': unplaced}


def page_arms(t, R):
    work = CACHE / 'arms' / key(t)
    work.mkdir(parents=True, exist_ok=True)
    folded, fold_n = G.fold_lines(t, R)
    tl = truth_lines(t, folded)
    acc = hyp('accurate', t)
    vis = layer_lines_vision(acc)
    vwords = [w for l in vis for w in l['text'].split()]
    arms = {'vision-accurate': (vis, {}), 'vision-documents': (documents_lines(hyp('documents', t)), {})}
    # The truth's own text aligned onto Vision's lines: the aligner's ceiling (a reading with no errors).
    texts = {'truth': '\n'.join(' '.join(t['words'][i]['text'] for i in ws
                                         if t['words'][i]['status'] not in UNSCORED)
                                for ws in folded.values())}
    texts.update({r: v for r, v in readings_for(t).items() if v})
    jobs = [{'id': r, 'aspect': t['height'] / t['width'], 'reading': v, 'lines': vis} for r, v in texts.items()]
    jf, of = work / 'align-jobs.json', work / 'align-out.json'
    jf.write_text(json.dumps(jobs))
    run_tool([ALIGN, jf, of])
    for o in json.loads(of.read_text()):
        lines = [{'text': ' '.join(l['text'].split()), 'box': l['box']} for l in o['lines'] if l['text'].strip()]
        lw = [w for l in lines for w in l['text'].split()]
        rewritten = sum(1 for a_, b_ in zip(lines, vis) if a_['text'] != b_['text'])
        arms[f'aligned:{o["id"]}'] = (lines, {
            'model_words': len(o['words']), 'anchor_share': anchor_share(vwords, o['words']),
            'model_placed': multiset_share(o['words'], lw), 'kept_vision': multiset_share(lw, vwords),
            'rewritten_lines': rewritten, 'vision_lines': len(vis)})
    jf.unlink()
    of.unlink()
    rows = []
    for name, (lines, extra) in arms.items():
        r = score_layer(t, tl, lines, work, name.replace(':', '_'))
        rows.append({'page': t['page'], 'kind': t.get('kind'), 'arm': name, **extra, **r})
    return rows, {'page': t['page'], 'kind': t.get('kind'), 'fold': fold_n,
                  'scored_lines': sum(L['scored'] for L in tl), 'truth_lines': len(tl)}


def cmd_arms(a):
    R = rulings()
    out = CACHE / 'arms-rows.jsonl'
    done = {}
    if a.fresh and out.exists():
        out.write_text('')
    if out.exists():
        for x in out.read_text().splitlines():
            r = json.loads(x)
            done[r['meta']['page']] = r
    pages = typed_pages()
    if a.pages:
        pages = [t for t in pages if t['page'] in a.pages.split(',')]
    for n, t in enumerate(pages, 1):
        if t['page'] in done:
            continue
        rows, meta = page_arms(t, R)
        with out.open('a') as f:
            f.write(json.dumps({'meta': meta, 'rows': rows}) + '\n')
        summ = ' '.join(f'{r["arm"].split(":")[-1]}={sum(x["pass"] for x in r["lines"])}' for r in rows)
        print(f'{n}/{len(pages)} {t["page"]} lines {meta["scored_lines"]} {summ}', flush=True)


# ---------------------------------------------------------------- test 5: three writings, four viewers
CLIPPINGS = ('p072', 'p078', 'p080', 'p081', 'p098')   # the typed truth's newspaper clippings (pages.tsv `clippings`)
DESIGNS = ('lab', 'ocrmypdf', 'words')
VIEWERS = ('pdfkit', 'poppler', 'mupdf', 'pdfjs')
PDFJS = CACHE / 'pdfjs'          # npm install pdfjs-dist there (place_print_pdfjs.mjs is copied in to run)


def writer_pages():
    """Ten typed pages and the five clippings. The ten: every second non-clipping typewritten page in page order
    (a fixed rule; no route chose them)."""
    ts = {t['page']: t for t in typed_pages()}
    plain = sorted(p for p, t in ts.items() if t['kind'] == 'typewritten' and p not in CLIPPINGS)
    return [ts[p] for p in plain[::2][:10] + list(CLIPPINGS)]


def hocr(t, h):
    """Vision's lines and words as hOCR in pixels (OCRmyPDF's input), the baseline as Tesseract writes it: slope and
    the offset of its left end below the line box's bottom."""
    W, H = t['width'], t['height']
    words = iter(h['words'])
    out = [f'<div class="ocr_page" title="bbox 0 0 {W} {H}; scan_res 300 300"><div class="ocr_carea" title="bbox 0 0 '
           f'{W} {H}"><p class="ocr_par" title="bbox 0 0 {W} {H}">']
    from html import escape
    for k, ln in enumerate(h['lines']):
        toks = ln['text'].split()
        ws = [next(words) for _ in toks]
        if not ws:
            continue
        x, y, w, hh = ln['box']
        x0, y0, x1, y1 = round(x * W), round(y * H), round((x + w) * W), round((y + hh) * H)
        (bx0, by0), (bx1, by1) = ln['baseline']
        slope = ((by1 - by0) * H) / max(1.0, (bx1 - bx0) * W)
        off = round((by0 * H + slope * (x0 - bx0 * W)) - y1)
        out.append(f'<span class="ocr_line" title="bbox {x0} {y0} {x1} {y1}; baseline {slope:.4f} {off}; '
                   f'x_size {y1 - y0}">')
        for j, wd in enumerate(ws):
            a, b, c, d = wd['box']
            out.append(f'<span class="ocrx_word" id="w{k}_{j}" title="bbox {round(a * W)} {round(b * H)} '
                       f'{round((a + c) * W)} {round((b + d) * H)}; x_wconf 95">{escape(wd["text"])}</span> ')
        out.append('</span>')
    out.append('</p></div></div>')
    return ('<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head>'
            '<meta name="ocr-system" content="vision"/><meta name="ocr-capabilities" content="ocr_page ocr_carea '
            'ocr_par ocr_line ocrx_word"/></head><body>' + ''.join(out) + '</body></html>')


def write_words_design(t, h, pdf):
    """Design (c): every word its own text object, its own text matrix, the word and a real trailing space, the
    font sized to the box's height and stretched (Tz) so the word without its space spans the box; no reserve."""
    from reportlab.pdfbase.pdfmetrics import stringWidth
    from reportlab.pdfgen import canvas
    Wp, Hp = t['width'] * PT, t['height'] * PT
    c = canvas.Canvas(str(pdf), pagesize=(Wp, Hp))
    c.drawImage(t['image'], 0, 0, Wp, Hp)
    for w in h['words']:
        x, y, bw, bh = w['box']
        size = max(1.0, bh * Hp * 0.8)
        nat = stringWidth(w['text'], 'Helvetica', size)
        to = c.beginText()
        to.setTextRenderMode(3)
        to.setFont('Helvetica', size)
        to.setHorizScale(100 * (bw * Wp) / nat if nat > 0 else 100)
        to.setTextOrigin(x * Wp, Hp - (y + bh) * Hp + 0.2 * bh * Hp)
        to.textOut(w['text'] + ' ')
        c.drawText(to)
    c.showPage()
    c.save()


def underlay(pdf, image):
    """Put the page image under a text-only PDF (the lab writer's, drawImages false), stretched over the page."""
    import pikepdf
    with pikepdf.open(pdf, allow_overwriting_input=True) as doc:
        pg = doc.pages[0]
        W, H = float(pg.mediabox[2]), float(pg.mediabox[3])
        raw = Path(image).read_bytes()
        from PIL import Image
        with Image.open(image) as im:
            iw, ih = im.size
            mode = im.mode
        xo = pikepdf.Stream(doc, raw, Type=pikepdf.Name.XObject, Subtype=pikepdf.Name.Image, Width=iw, Height=ih,
                            ColorSpace=pikepdf.Name.DeviceGray if mode == 'L' else pikepdf.Name.DeviceRGB,
                            BitsPerComponent=8, Filter=pikepdf.Name.DCTDecode)
        name = pg.add_resource(xo, pikepdf.Name.XObject, prefix='Im')
        pg.contents_add(pikepdf.Stream(doc, f'q {W} 0 0 {H} 0 0 cm {name} Do Q\n'.encode()), prepend=True)
        doc.save(pdf)


def write_design(t, h, design, pdf, work):
    if design == 'lab':
        jf = work / f'{pdf.stem}.jobs.json'
        jf.write_text(json.dumps([{'out': str(pdf), 'width': t['width'] * PT, 'height': t['height'] * PT,
                                   'lines': layer_lines_vision(h)}]))
        run_tool([WRITER, jf])
        jf.unlink()
        underlay(pdf, t['image'])
    elif design == 'ocrmypdf':
        hf = work / f'{pdf.stem}.hocr'
        hf.write_text(hocr(t, h))
        run_tool([sys.executable, '-m', 'ocrmypdf.hocrtransform', '-i', t['image'], hf, pdf])
        hf.unlink()
    else:
        write_words_design(t, h, pdf)


def extract(viewer, pdf, work):
    """The PDF's text as each viewer extracts it, as lines."""
    if viewer == 'pdfkit':
        hj = work / f'{pdf.stem}.pk.json'
        run_tool([FUNCTIONAL, 'words', work / 'empty-truth.json', pdf, hj])
        text = '\n'.join(l['text'] for l in json.loads(hj.read_text())['lines'])
        hj.unlink()
    elif viewer == 'poppler':
        text = run_tool(['/opt/homebrew/bin/pdftotext', '-enc', 'UTF-8', pdf, '-'])
    elif viewer == 'mupdf':
        text = run_tool(['/opt/homebrew/bin/mutool', 'draw', '-q', '-F', 'txt', '-o', '-', pdf])
    else:
        script = PDFJS / 'place_print_pdfjs.mjs'
        script.write_bytes((HERE / 'place_print_pdfjs.mjs').read_bytes())
        text = run_tool(['/opt/homebrew/bin/node', script, pdf])
    return [ln for ln in text.splitlines() if ln.strip()]


def extraction_scores(ext_lines, layer_words, exp, scored_ids):
    """`line`: a scored truth line whose expected words appear, in order and adjacent, inside one extracted line.
    `words`: the layer's words found as whole tokens (multiset). `welded`: extracted tokens that are two or more
    adjacent layer words run together. `split`: layer words that come out in pieces (two adjacent extracted tokens
    that join to a layer word the extraction lacks)."""
    toks = [[HL.norm(w) for w in ln.split()] for ln in ext_lines]
    toks = [[w for w in ln if w] for ln in toks]
    flat = [w for ln in toks for w in ln]
    lw = [HL.norm(w) for w in layer_words if HL.norm(w)]
    have = collections.Counter(flat)
    words = sum(min(v, have[k]) for k, v in collections.Counter(lw).items())
    pairs = {lw[i] + lw[i + 1] for i in range(len(lw) - 1)} | {lw[i] + lw[i + 1] + lw[i + 2] for i in range(len(lw) - 2)}
    lwset = set(lw)
    welded = sum(1 for w in flat if w in pairs and w not in lwset)
    split = sum(1 for ln in toks for a_, b_ in zip(ln, ln[1:]) if a_ + b_ in lwset and a_ + b_ not in have)
    ok = 0
    for L in scored_ids:
        e = [HL.norm(w) for w in exp.get(L, '').split()]
        e = [w for w in e if w]
        if not e:
            continue
        n = len(e)
        ok += any(ln[i:i + n] == e for ln in toks for i in range(len(ln) - n + 1))
    return {'line': ok, 'words': words, 'layer_words': len(lw), 'welded': welded, 'split': split}


def cmd_writers(a):
    R = rulings()
    work = CACHE / 'writers'
    work.mkdir(parents=True, exist_ok=True)
    (work / 'empty-truth.json').write_text('{"words": []}')
    rows = []
    for t in writer_pages():
        folded, _ = G.fold_lines(t, R)
        tl = truth_lines(t, folded)
        scored = [L for L in tl if L['scored']]
        h = hyp('accurate', t)
        layer_words = [w for l in layer_lines_vision(h) for w in l['text'].split()]
        exp = expected_for([l['text'] for l in layer_lines_vision(h)], tl)
        drags = [{'id': L['id'], 'expected': exp[L['id']], 'start': L['start'], 'end': L['end']}
                 for L in scored if exp[L['id']]]
        dj = work / f'{key(t)}.drags.json'
        dj.write_text(json.dumps({'lines': drags}))
        tj = work / f'{key(t)}.truth.json'
        tj.write_text(json.dumps({'page': t['page'], 'words': t['words']}))
        for design in DESIGNS:
            pdf = work / f'{key(t)}-{design}.pdf'
            write_design(t, h, design, pdf, work)
            do = work / f'{key(t)}-{design}.drag-out.json'
            run_tool([FUNCTIONAL, 'drag', dj, pdf, do])
            got = json.loads(do.read_text())
            find = json.loads(run_tool([FUNCTIONAL, 'score', tj, pdf]))
            ex = {d['id']: d['expected'] for d in drags}
            loose = sum(loose_pass(ex[r['id']], r['got'], r['broken']) for r in got['lines'])
            row = {'page': t['page'], 'kind': t['kind'], 'clipping': t['page'] in CLIPPINGS, 'design': design,
                   'lines': len(scored), 'dragged': got['n'], 'passed': got['passed'], 'loose': loose,
                   'find_words': find['words'], 'found': find['found'], 'placed': find['placed'],
                   'bytes': pdf.stat().st_size, 'viewers': {}}
            for v in VIEWERS:
                row['viewers'][v] = extraction_scores(extract(v, pdf, work), layer_words, exp,
                                                      [L['id'] for L in scored])
            rows.append(row)
            print(t['page'], design, f'drag {got["passed"]}/{len(scored)}',
                  ' '.join(f'{v}={row["viewers"][v]["line"]}' for v in VIEWERS), flush=True)
    (CACHE / 'writers-rows.json').write_text(json.dumps(rows) + '\n')


# ---------------------------------------------------------------- test 6: PDF/A
SRGB = Path('/System/Library/ColorSync/Profiles/sRGB Profile.icc')
VERAPDF = '/opt/homebrew/bin/verapdf'


def as_pdfa(src, dst, conformance):
    """A copy of `src` declared PDF/A-2 (XMP pdfaid part 2 and `conformance`) with an sRGB output intent: the
    declarations every PDF/A file carries, so what veraPDF still finds is the file's own content (its fonts and
    text layer), not the absence of a claim."""
    import pikepdf
    with pikepdf.open(src) as doc:
        with doc.open_metadata(set_pikepdf_as_editor=False) as m:
            m['pdfaid:part'] = '2'
            m['pdfaid:conformance'] = conformance
        icc = pikepdf.Stream(doc, SRGB.read_bytes(), N=3)
        doc.Root.OutputIntents = pikepdf.Array([pikepdf.Dictionary(
            Type=pikepdf.Name.OutputIntent, S=pikepdf.Name.GTS_PDFA1, OutputConditionIdentifier='sRGB',
            DestOutputProfile=icc)])
        doc.save(dst, fix_metadata_version=False)


def to_unicode_cmap(pairs, width=1):
    """A ToUnicode CMap for `pairs` {code: text}, codes `width` bytes wide (1 for simple fonts, 2 for Identity-H)."""
    h = 2 * width
    lines = ['/CIDInit /ProcSet findresource begin', '12 dict begin', 'begincmap',
             '/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def',
             '/CMapName /Adobe-Identity-UCS def', '/CMapType 2 def', '1 begincodespacerange',
             f'<{0:0{h}X}> <{256 ** width - 1:0{h}X}>', 'endcodespacerange']
    pairs = sorted(pairs.items())
    for i in range(0, len(pairs), 100):
        chunk = pairs[i:i + 100]
        lines.append(f'{len(chunk)} beginbfchar')
        lines += [f'<{c:0{h}X}> <{s.encode("utf-16-be").hex().upper()}>' for c, s in chunk]
        lines.append('endbfchar')
    lines += ['endcmap', 'CMapName currentdict /CMap defineresource pop', 'end', 'end']
    return '\n'.join(lines).encode()


def system_glyph_unicode(base):
    """{glyph name: text} for the installed font whose PostScript name is `base` (a subset prefix stripped), from its
    cmap, the lowest code point winning; {} when no installed font has that name."""
    import glob
    from fontTools.ttLib import TTCollection, TTFont
    base = base.split('+', 1)[-1]
    if base in _GLYPH_UNICODE:
        return _GLYPH_UNICODE[base]
    out = {}
    for path in glob.glob('/System/Library/Fonts/*.tt[cf]') + glob.glob('/Library/Fonts/*.tt[cf]'):
        try:
            fonts = TTCollection(path).fonts if path.endswith('.ttc') else [TTFont(path)]
        except Exception:
            continue
        ft = next((x for x in fonts if 'name' in x and x['name'].getDebugName(6) == base), None)
        if ft is not None:
            for u, g in sorted(ft.getBestCmap().items(), reverse=True):
                out[g] = chr(u)
            break
    _GLYPH_UNICODE[base] = out
    return out


_GLYPH_UNICODE = {}


def truetype_to_unicode(doc, f):
    """A complete ToUnicode stream for a simple TrueType font with no /Encoding (Core Text's subsets): its embedded
    (1,0) cmap names each code's glyph, and the installed full font, else the Adobe Glyph List, gives the glyph's
    text. Core Text writes a ToUnicode for these that can miss a glyph (₴ "Hryvnia" on p024). None when a used code
    cannot be named."""
    import io
    import pikepdf
    from fontTools.agl import toUnicode
    from fontTools.ttLib import TTFont
    ff = f.get('/FontDescriptor', {}).get('/FontFile2')
    if ff is None or '/Encoding' in f:
        return None
    ft = TTFont(io.BytesIO(ff.read_bytes()))
    sub = next((t for t in ft['cmap'].tables if (t.platformID, t.platEncID) in ((1, 0), (3, 0))), None)
    if sub is None:
        return None
    names = system_glyph_unicode(str(f.BaseFont)[1:])
    pairs = {}
    for code, g in sub.cmap.items():
        text = names.get(g) or toUnicode(g)
        if not text:
            return None
        pairs[code & 0xFF] = text
    return pikepdf.Stream(doc, to_unicode_cmap(pairs))


def type0_to_unicode(doc, f):
    """A ToUnicode stream for an Identity-H Type0 font over an embedded CID-keyed CFF (what Core Text embeds when it
    falls back to a CJK font for a symbol Helvetica lacks): the subset's charset names each glyph's CID, and the
    installed full font maps CIDs to Unicode. None when that cannot be rebuilt."""
    import io
    import pikepdf
    from fontTools.cffLib import CFFFontSet
    if str(f.get('/Encoding', '')) != '/Identity-H':
        return None
    desc = f.DescendantFonts[0]
    ff = desc.get('/FontDescriptor', {}).get('/FontFile3')
    if ff is None:
        return None
    cff = CFFFontSet()
    cff.decompile(io.BytesIO(ff.read_bytes()), None)
    top = cff[cff.fontNames[0]]
    uni = system_glyph_unicode(str(f.BaseFont)[1:])
    pairs = {}
    for name in top.charset:
        if name.startswith('cid') and name[3:].isdigit() and name in uni:
            pairs[int(name[3:])] = uni[name]   # Identity-H with no CIDToGIDMap: the code is the CID
    return pikepdf.Stream(doc, to_unicode_cmap(pairs, 2)) if pairs else None


def add_to_unicode(src, dst):
    """Give every font without a ToUnicode map one: a simple font's from its encoding (the base encoding named, or
    WinAnsi, with its Differences applied by glyph name), an Identity-H CID font's from type0_to_unicode; and replace
    an unencoded TrueType subset's (Core Text's) with truetype_to_unicode's. Returns how many fonts were given one."""
    import pikepdf
    from fontTools.agl import toUnicode
    n = 0
    with pikepdf.open(src) as doc:
        for pg in doc.pages:
            fonts = pg.obj.get('/Resources', {}).get('/Font', {})
            for _, f in fonts.items():
                if f.get('/Subtype') == '/TrueType' and '/Encoding' not in f:
                    tu = truetype_to_unicode(doc, f)       # replaces Core Text's own map, which can miss a glyph
                    if tu is not None:
                        f.ToUnicode = tu
                        n += 1
                    continue
                if '/ToUnicode' in f:
                    continue
                if f.get('/Subtype') == '/Type0':
                    tu = type0_to_unicode(doc, f)
                    if tu is not None:
                        f.ToUnicode = tu
                        n += 1
                    continue
                enc = f.get('/Encoding')
                base, diffs = 'cp1252', {}
                if str(f.get('/BaseFont', '')) in ('/ZapfDingbats', '/Symbol'):   # their built-in encodings
                    import reportlab.pdfbase.rl_codecs as rlc
                    rlc.RL_Codecs.register()
                    base = str(f.BaseFont)[1:].lower()
                if isinstance(enc, pikepdf.Name) and str(enc) == '/MacRomanEncoding':
                    base = 'mac_roman'
                if isinstance(enc, pikepdf.Dictionary):
                    if str(enc.get('/BaseEncoding', '')) == '/MacRomanEncoding':
                        base = 'mac_roman'
                    code = 0
                    for d in enc.get('/Differences', []):
                        if isinstance(d, int):
                            code = int(d)
                        else:
                            diffs[code] = toUnicode(str(d)[1:])
                            code += 1
                pairs = {}
                for c in range(32, 256):
                    s = diffs.get(c)
                    if s is None:
                        try:
                            s = bytes([c]).decode(base)
                        except UnicodeDecodeError:
                            continue
                    if s:
                        pairs[c] = s
                f.ToUnicode = pikepdf.Stream(doc, to_unicode_cmap(pairs))
                n += 1
        doc.save(dst, fix_metadata_version=False)
    return n


def verapdf(pdf, flavour):
    out = run_tool([VERAPDF, '--flavour', flavour, '--format', 'json', pdf], check=False)
    d = json.loads(out)
    job = d['report']['jobs'][0]
    vr = job['validationResult']
    vr = vr[0] if isinstance(vr, list) else vr
    fails = []
    for r in vr.get('details', {}).get('ruleSummaries', []):
        if r.get('ruleStatus') == 'FAILED':
            fails.append({'rule': f'{r["clause"]}-{r["testNumber"]}', 'checks': r.get('failedChecks'),
                          'description': r.get('description', '')[:200]})
    return {'compliant': bool(vr.get('compliant')), 'fails': fails}


def cmd_verapdf(a):
    """veraPDF 2b and 2u over the lab writer's PDFs of the fifteen writer pages and five more typewritten pages
    (twenty of ours), and over the other two designs' fifteen; then 2u again with ToUnicode maps added."""
    work = CACHE / 'writers'
    va = CACHE / 'verapdf'
    va.mkdir(parents=True, exist_ok=True)
    ts = {t['page']: t for t in typed_pages()}
    plain = sorted(p for p, t in ts.items() if t['kind'] == 'typewritten' and p not in CLIPPINGS)
    extra = [p for p in plain[1::2]][:5]
    for p in extra:
        pdf = work / f'{p}-lab.pdf'
        if not pdf.exists():
            write_design(ts[p], hyp('accurate', ts[p]), 'lab', pdf, work)
    rows = []
    for pdf in sorted(work.glob('*.pdf')):
        page, design = pdf.stem.rsplit('-', 1)
        row = {'page': page, 'design': design}
        for flav, conf in (('2b', 'B'), ('2u', 'U')):
            cand = va / f'{pdf.stem}-{flav}.pdf'
            as_pdfa(pdf, cand, conf)
            row[flav] = verapdf(cand, flav)
            if flav == '2u' and not row[flav]['compliant']:
                fixed = va / f'{pdf.stem}-2u-tounicode.pdf'
                row['tounicode_added'] = add_to_unicode(cand, fixed)
                row['2u+tounicode'] = verapdf(fixed, '2u')
                fixed.unlink()
            cand.unlink()
        rows.append(row)
        print(page, design, {k: (v['compliant'], [f['rule'] for f in v['fails']]) for k, v in row.items()
                             if isinstance(v, dict)}, flush=True)
    (CACHE / 'verapdf-rows.json').write_text(json.dumps(rows) + '\n')


# ---------------------------------------------------------------- test 7: box-emitting readers and detectors
BOXREAD = REH / 'sherlock-results/new-open-96'
DETECT = REH / 'place-truth-lines/lines'
NEMO_W, NEMO_H = 1664, 2048


def nemotron_to_image(b, iw, ih):
    """Nemotron-Parse 2.0's box (0-1 of its 1664x2048 canvas) -> 0-1 of the image. Rebuilt from the card's
    statement of the canvas (the image fitted inside it, aspect kept, padded to it) with the padding centred: the
    publisher's postprocessing.py could not be read in this session, and centred padding is the one that puts its
    blocks on Unlimited-OCR's (checked in `boxes`, `nemotron_check`)."""
    s = min(NEMO_W / iw, NEMO_H / ih, 1.0)
    rw, rh = iw * s, ih * s
    px, py = (NEMO_W - rw) / 2, (NEMO_H - rh) / 2
    x0, y0, x1, y1 = b
    return [(x0 * NEMO_W - px) / rw, (y0 * NEMO_H - py) / rh, (x1 * NEMO_W - px) / rw, (y1 * NEMO_H - py) / rh]


def reader_blocks(reader, page):
    f = BOXREAD / reader / 'results/ocr' / reader / f'{page}.json'
    if not f.exists():
        return None
    d = json.loads(f.read_text())
    if d.get('status') != 'ok':
        return None
    iw, ih = d['image_size']
    out = []
    for b in d.get('boxes') or []:
        x0, y0, x1, y1 = b['box']
        if b['units'] == 'unlimited-999':
            q = [x0 / 999, y0 / 999, x1 / 999, y1 / 999]
        else:
            q = nemotron_to_image(b['box'], iw, ih)
        if q[2] > q[0] and q[3] > q[1]:    # an invalid box (reversed, zero area) is not repaired; it holds nothing
            out.append({'cls': b['cls'], 'box': [q[0], q[1], q[2] - q[0], q[3] - q[1]], 'text': b.get('text', '')})
    return out


def detector_lines(det, page):
    f = DETECT / det / f'{page}.json'
    if not f.exists():
        return None
    return [{'box': l['box'], 'baseline': l['baseline'], 'poly': l.get('boundary')} for l in json.loads(f.read_text())['lines']]


def holds(region, c):
    if region.get('poly'):
        return G.inside(region['poly'], c)
    return S.inside(c, region['box'])


def grouping(t, tl_words, regions):
    """Per scored truth line: `whole` when one region holds the centres of all its scored words, `alone` when that
    region also holds no scored word of another truth line; and the truth words in no region at all."""
    centre = {}
    for L, ws in tl_words.items():
        for i in ws:
            b = t['words'][i]['box']
            centre[i] = (b[0] + b[2] / 2, b[1] + b[3] / 2)
    home = {i: [k for k, r in enumerate(regions) if holds(r, c)] for i, c in centre.items()}
    owners = collections.defaultdict(set)
    for L, ws in tl_words.items():
        for i in ws:
            for k in home[i]:
                owners[k].add(L)
    whole = alone = 0
    for L, ws in tl_words.items():
        common = set(home[ws[0]]).intersection(*(set(home[i]) for i in ws[1:]))
        whole += bool(common)
        alone += any(owners[k] == {L} for k in common)
    return {'lines': len(tl_words), 'whole': whole, 'alone': alone,
            'words': len(centre), 'outside': sum(1 for i in home if not home[i])}


def block_text(t, blocks):
    """For `replace` (a block's text placed in its block): the share of the truth words inside some block that the
    block's own text holds (multiset, case and punctuation aside)."""
    hit = n = 0
    for blk in blocks:
        inside = [w['text'] for w in S.scoreable(t)
                  if S.inside((w['box'][0] + w['box'][2] / 2, w['box'][1] + w['box'][3] / 2), blk['box'])]
        if inside:
            n += len(inside)
            hit += round(multiset_share(inside, blk['text'].split()) * len(inside))
    return {'block_words': n, 'in_block_text': hit}


def nemotron_check(page):
    """Median offset, in page widths and heights, between each Nemotron block's left-top corner and that of the
    Unlimited-OCR block whose text is most alike (when the two texts share at least half their words)."""
    a, b = reader_blocks('nemotron-parse-2', page), reader_blocks('unlimited-ocr', page)
    if not a or not b:
        return []
    out = []
    for x in a:
        best = max(b, key=lambda y: multiset_share(x['text'].split(), y['text'].split()), default=None)
        if best and len(x['text'].split()) >= 5 and multiset_share(x['text'].split(), best['text'].split()) >= 0.5:
            out.append((x['box'][0] - best['box'][0], x['box'][1] - best['box'][1]))
    return out


def cmd_boxes(a):
    R = rulings()
    rows, offs = [], []
    for t in typed_pages():
        folded, _ = G.fold_lines(t, R)
        tlw = {}
        for L in truth_lines(t, folded):
            if L['scored']:
                tlw[L['id']] = [i for i in folded[L['id']] if t['words'][i]['status'] not in UNSCORED]
        offs += nemotron_check(t['page'])
        sources = {f'vision-{api}': [{'box': l['box'], 'baseline': l['baseline']} for l in hyp(api, t)['lines']]
                   for api in ('accurate', 'documents')}
        for det in ('blla', 'ppocrv6'):
            sources[det] = detector_lines(det, t['page'])
        for rd in ('unlimited-ocr', 'nemotron-parse-2'):
            sources[rd] = reader_blocks(rd, t['page'])
        for name, regs in sources.items():
            if regs is None:
                continue
            row = {'page': t['page'], 'kind': t['kind'], 'source': name, 'regions': len(regs),
                   **grouping(t, tlw, regs)}
            if name.startswith(('vision', 'blla', 'ppocr')):
                row['baseline'] = S.baseline_scores(t, {'lines': [r for r in regs if r.get('baseline')]})
            else:
                row.update(block_text(t, regs))
            rows.append(row)
    med = ([statistics.median(o[0] for o in offs), statistics.median(o[1] for o in offs)] if offs else None)
    (CACHE / 'boxes-rows.json').write_text(json.dumps({'rows': rows, 'nemotron_check': {
        'pairs': len(offs), 'median_dx_dy': med,
        'within_0.02': sum(1 for o in offs if abs(o[0]) <= 0.02 and abs(o[1]) <= 0.02)}}) + '\n')
    print(len(rows), 'rows; nemotron vs unlimited', len(offs), med)


# ---------------------------------------------------------------- the owner's Acrobat check (test 5, by hand)
ACROBAT_PAGES = ('p002', 'p024', 'p087', 'p078', 'p081')   # three typewritten writer pages, two clippings


def cmd_acrobat(a):
    """The owner's sheet: five writer pages, each in all three designs under blind names (A, B, C, shuffled per
    page; the key is CACHE/acrobat-key.json, outside the folder he opens), ten words to Find and two lines to
    drag-select on each, about 20 minutes in Acrobat Reader. Writes CACHE/acrobat/ (PDF copies, index.html) and CACHE/acrobat-key.json."""
    import html
    import shutil
    R = rulings()
    src, out = CACHE / 'writers', CACHE / 'acrobat'
    out.mkdir(parents=True, exist_ok=True)
    rnd = random.Random(SEED)
    ts = {t['page']: t for t in typed_pages()}
    key_, items = {}, []
    for p in ACROBAT_PAGES:
        t = ts[p]
        folded, _ = G.fold_lines(t, R)
        tl = [L for L in truth_lines(t, folded) if L['scored'] and len(L['tokens']) >= 4]
        words = [w['text'].strip('.,;:()"\'') for w in S.scoreable(t)]
        words = [w for w in words if sum(ch.isalpha() for ch in w) >= 5]
        step = max(1, len(words) // 10)
        finds = words[::step][:10]
        lines = [tl[len(tl) // 4], tl[(3 * len(tl)) // 4]] if len(tl) >= 2 else tl
        names = ['A', 'B', 'C']
        rnd.shuffle(names)
        for name, d in zip(names, DESIGNS):
            shutil.copyfile(src / f'{key(t)}-{d}.pdf', out / f'{p}-{name}.pdf')
            key_[f'{p}-{name}'] = d
        items.append((p, sorted(names), finds, [' '.join(L['tokens']) for L in lines]))
    (CACHE / 'acrobat-key.json').write_text(json.dumps(key_, indent=1) + '\n')
    rows = []
    for p, names, finds, lines in items:
        for n in names:
            f = f'{p}-{n}'
            rows.append(f'<h2>{f}.pdf</h2><p>Find (Ctrl/Cmd-F): for each word, tick if Acrobat finds it <i>and</i> '
                        'the highlight sits on the word in the image.</p><table>' +
                        ''.join(f'<tr><td>{html.escape(w)}</td><td><label><input type=checkbox name="{f}|find|{k}">'
                                f' found, on the word</label></td></tr>' for k, w in enumerate(finds)) +
                        '</table><p>Drag-select each line from its first word to its last and copy (Cmd-C). Tick if '
                        'the copy is that line\'s words, in order, on one line, nothing extra.</p><table>' +
                        ''.join(f'<tr><td>{html.escape(l)}</td><td><label><input type=checkbox name="{f}|line|{k}">'
                                f' whole line, in order</label></td></tr>' for k, l in enumerate(lines)) +
                        f'</table><p><textarea name="{f}|note" rows=2 cols=80 placeholder="anything odd"></textarea></p>')
    page = ('<!doctype html><meta charset=utf-8><title>W46.place-print — Acrobat check</title><style>body{font:15px '
            'system-ui;max-width:52em;margin:2em auto}td{padding:2px 10px}h2{margin-top:2em}</style>'
            '<h1>Acrobat Reader check: three text layers (about 20 minutes)</h1><p>Fifteen PDFs in this folder: five '
            'pages, each written three ways, named A, B and C in a different order on each page. Open each in '
            'Adobe Acrobat Reader (not Preview). Untick means it failed. When done, press Export and save the file '
            'next to this page as <code>answers.json</code>.</p>' + ''.join(rows) +
            '<p><textarea id=overall rows=3 cols=80 placeholder="overall notes"></textarea></p>'
            '<button onclick="const o={};document.querySelectorAll(\'input,textarea\').forEach(e=>o[e.name||e.id]='
            'e.type===\'checkbox\'?e.checked:e.value);const a=document.createElement(\'a\');a.href=URL.createObject'
            'URL(new Blob([JSON.stringify(o,null,1)]));a.download=\'answers.json\';a.click()">Export</button>')
    (out / 'index.html').write_text(page)
    print('sheet', out / 'index.html', len(key_), 'PDFs')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('vision')
    r = sub.add_parser('arms')
    r.add_argument('--pages')
    r.add_argument('--fresh', action='store_true')
    for c in ('writers', 'verapdf', 'boxes', 'acrobat', 'report'):
        sub.add_parser(c)
    a = ap.parse_args()
    if a.cmd == 'report':
        import place_print_report
        place_print_report.write(CACHE, RESULTS)
        return
    {'vision': cmd_vision, 'arms': cmd_arms, 'writers': cmd_writers, 'verapdf': cmd_verapdf,
     'boxes': cmd_boxes, 'acrobat': cmd_acrobat}[a.cmd](a)


if __name__ == '__main__':
    main()
