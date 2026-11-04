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
  --with ocrmypdf python`; run every step under ops/autonomous/heavy-run.py, as they work through a page set.)

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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('vision')
    r = sub.add_parser('arms')
    r.add_argument('--pages')
    r.add_argument('--fresh', action='store_true')
    sub.add_parser('writers')
    a = ap.parse_args()
    {'vision': cmd_vision, 'arms': cmd_arms, 'writers': cmd_writers}[a.cmd](a)


if __name__ == '__main__':
    main()
