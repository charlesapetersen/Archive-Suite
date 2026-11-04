"""W46.place-print's report: segbench-results/place-print.md (the tables between the markers) and place-print.json,
from place_print.py's rows (counts, rates and page ids only).

Intervals are paired over pages: 2,000 bootstrap draws of the pages both arms scored, the arm's rate (summed over
the drawn pages) less the base's on the same draw; 95% percentile interval. A difference whose interval holds 0 is
a tie.
"""
from __future__ import annotations

import collections
import json
import random
from pathlib import Path

DRAWS, SEED = 2000, 20261103
ARMS = ['vision-accurate', 'vision-documents', 'aligned:truth', 'aligned:gemini3.8-flash', 'aligned:qwen3.6-27b',
        'aligned:lightonocr3-4b']
LABEL = {'vision-accurate': "Vision's own lines (VNRecognizeTextRequest, today's layer)",
         'vision-documents': "Vision's RecognizeDocumentsRequest lines",
         'aligned:truth': 'truth text aligned onto Vision (the aligner\'s ceiling)',
         'aligned:gemini3.8-flash': 'Gemini 3.8 Flash aligned (drafted the truth text)',
         'aligned:qwen3.6-27b': 'Qwen3.6-27B aligned (non-drafter)',
         'aligned:lightonocr3-4b': 'LightOnOCR-3 4B aligned (non-drafter)'}
BASE = 'vision-accurate'


def pct(a, n):
    return f'{100 * a / n:.1f}' if n else '—'


def boot(pages, num, den):
    """Paired page bootstrap of sum(num)/sum(den) differences: pages = [(arm_num, arm_den, base_num, base_den)]."""
    rnd = random.Random(SEED)
    out = []
    for _ in range(DRAWS):
        s = [pages[rnd.randrange(len(pages))] for _ in pages]
        a = sum(x[0] for x in s) / max(1, sum(x[1] for x in s))
        b = sum(x[2] for x in s) / max(1, sum(x[3] for x in s))
        out.append(100 * (a - b))
    out.sort()
    return out[int(0.025 * DRAWS)], out[int(0.975 * DRAWS) - 1]


def fmt_ci(d, lo, hi):
    return f'{d:+.1f} ({lo:+.1f} to {hi:+.1f})'


# ---------------------------------------------------------------- test 2
def vision_tables(rows):
    md, js = [], {}
    md.append('## Vision\'s own word and line boxes against the truth (test 2)\n')
    md.append('Every audited-ok truth page (owner-typed 40, owner-hand 20, Bentham 14, N6 28). `bywords` is the '
              'lab\'s request (revision 3, `.accurate`, language correction, language detected) with a word per '
              '`.byWords` substring, the segmentation the typed truth was drafted from; `accurate` the same request '
              'with whitespace words, the words the lab writer lays; `documents` is macOS 26 '
              '`RecognizeDocumentsRequest`. F1 is one-to-one over word boxes; the truth boxes are ink-tight and '
              'Vision\'s padded, so @centre (each box holds the other\'s centre) is the figure that does not charge '
              'padding. Recall and no-box by the truth line\'s source: `drawn` lines were drawn by subagents, '
              '`Vision` lines drafted from Vision\'s own (OCR-10); the drawn ones are the hard pages, so the two '
              'are not a like comparison. Bentham and N6 have line geometry only.\n')
    md.append('| group | kind | API | pages | truth words | F1@0.5 | F1@0.7 | F1@centre | recall@centre, Vision lines | '
              'recall@centre, drawn lines | no Vision box, Vision lines | no Vision box, drawn lines | baseline F |')
    md.append('|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
    g = collections.defaultdict(list)
    for r in rows:
        g[(r['group'], r['kind'], r['api'])].append(r)
    order = ['owner-typed', 'owner-hand', 'L2-bentham', 'N6']
    for (grp, kind, api), rs in sorted(g.items(), key=lambda kv: (order.index(kv[0][0]), kv[0][1],
                                                                 ['bywords', 'accurate', 'documents'].index(kv[0][2]))):
        tw = sum(r['word']['truth_words'] for r in rs)
        hw = sum(r['word']['hyp_words'] for r in rs)
        f1 = {}
        for thr in ('0.5', '0.7', 'centre'):
            m = sum(r['word'][f'matched@{thr}'] for r in rs)
            p, q = (m / hw if hw else 0), (m / tw if tw else 0)
            f1[thr] = 2 * p * q / (p + q) if p + q else None
        st = collections.defaultdict(lambda: [0, 0, 0])
        for r in rs:
            for s, v in r['strata'].items():
                st[s][0] += v['words']
                st[s][1] += v['matched']
                st[s][2] += v['no_box']
        bf = sum(r['baseline']['F'] for r in rs) / len(rs)
        js[f'{grp}/{kind}/{api}'] = {'pages': len(rs), 'truth_words': tw, 'hyp_words': hw, 'f1': f1,
                                     'strata': {k: dict(zip(('words', 'matched', 'no_box'), v)) for k, v in st.items()},
                                     'baseline_F': bf}
        cell = lambda v: f'{v:.3f}' if v is not None and tw else '—'  # noqa: E731
        sv, sd = st.get('vision', [0, 0, 0]), st.get('drawn', [0, 0, 0])
        md.append(f'| {grp} | {kind} | {api} | {len(rs)} | {tw} | {cell(f1["0.5"])} | {cell(f1["0.7"])} | '
                  f'{cell(f1["centre"])} | {pct(sv[1], sv[0])} | {pct(sd[1], sd[0])} | {pct(sv[2], sv[0])} | '
                  f'{pct(sd[2], sd[0])} | {bf:.3f} |')
    return md, js


# ---------------------------------------------------------------- test 3
def arm_pages(pages):
    """page -> arm -> the page's counts."""
    out = {}
    for d in pages:
        p = d['meta']['page']
        out[p] = {}
        for r in d['rows']:
            c = collections.Counter()
            for l in r['lines']:
                c['n'] += 1
                c['pass'] += l['pass']
                c['loose'] += l['loose']
                c['unread'] += l['unread']
                c['broken'] += l['broken']
                c[f'n_{l["source"]}'] += 1
                c[f'pass_{l["source"]}'] += l['pass']
            c.update(fw=r['find_words'], found=r['found'], placed=r['placed'], m=r['matched@centre'],
                     hw=r['hyp_words'], tw=r['truth_words'])
            out[p][r['arm']] = {'c': c, 'kind': r['kind'], 'row': r}
    return out


def arms_tables(pages):
    ap = arm_pages(pages)
    md, js = [], {}
    md.append('## The line pass, Find and the aligner (test 3)\n')
    md.append('The 40 owner-typed truth pages, every folded truth line of two or more scored words (owner rulings '
              'folded, W46.place-lines-owner-ok). Each arm\'s layer is the lab writer\'s (SearchableWriter.compose, '
              'one level run per line) over Vision\'s line boxes; an aligned arm\'s text is the lab\'s own '
              '`alignedReading` of the saved reading onto Vision\'s `accurate` lines. `strict` is PDFKit\'s drag '
              'returning exactly the layer\'s words for the line; `loose` the same selection with case and '
              'punctuation aside (a dropped closing comma passes). A line the layer holds no word for fails. '
              'Δ is against Vision\'s own layer on the pages both have, paired over pages. Gemini 3.8 Flash and '
              'Qwen3.6-27B have no usable reading of 2 and 1 pages; their rows are on the pages they read.\n')
    for kind in ('all', 'typewritten', 'printed'):
        md.append(f'### {kind} pages\n')
        md.append('| arm | pages | lines | strict pass % | Δ strict vs Vision (95% CI) | loose pass % | '
                  'strict, Vision lines | strict, drawn lines | Find % | Find placed % | Δ placed vs Vision (95% CI) | '
                  'word F1@centre |')
        md.append('|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---|---:|')
        for arm in ARMS:
            ps = [p for p, v in ap.items() if arm in v and BASE in v and (kind == 'all' or v[arm]['kind'] == kind)]
            if not ps:
                continue
            c = sum((ap[p][arm]['c'] for p in ps), collections.Counter())
            b = sum((ap[p][BASE]['c'] for p in ps), collections.Counter())
            d_pass = 100 * (c['pass'] / c['n'] - b['pass'] / b['n'])
            ci_pass = boot([(ap[p][arm]['c']['pass'], ap[p][arm]['c']['n'], ap[p][BASE]['c']['pass'],
                             ap[p][BASE]['c']['n']) for p in ps], 'pass', 'n')
            d_pl = 100 * (c['placed'] / c['fw'] - b['placed'] / b['fw'])
            ci_pl = boot([(ap[p][arm]['c']['placed'], ap[p][arm]['c']['fw'], ap[p][BASE]['c']['placed'],
                           ap[p][BASE]['c']['fw']) for p in ps], 'placed', 'fw')
            pr, rc = c['m'] / max(1, c['hw']), c['m'] / max(1, c['tw'])
            f1 = 2 * pr * rc / (pr + rc) if pr + rc else 0
            js[f'{kind}/{arm}'] = {'pages': len(ps), 'lines': c['n'], 'pass': c['pass'], 'loose': c['loose'],
                                   'unread': c['unread'], 'broken': c['broken'],
                                   'pass_vision_lines': [c['pass_vision'], c['n_vision']],
                                   'pass_drawn_lines': [c['pass_drawn'], c['n_drawn']],
                                   'find': [c['found'], c['fw']], 'placed': [c['placed'], c['fw']],
                                   'f1_centre': f1, 'delta_pass': [d_pass, *ci_pass], 'delta_placed': [d_pl, *ci_pl]}
            base = arm == BASE
            md.append(f'| {LABEL[arm]} | {len(ps)} | {c["n"]} | {pct(c["pass"], c["n"])} | '
                      f'{"—" if base else fmt_ci(d_pass, *ci_pass)} | {pct(c["loose"], c["n"])} | '
                      f'{pct(c["pass_vision"], c["n_vision"])} | {pct(c["pass_drawn"], c["n_drawn"])} | '
                      f'{pct(c["found"], c["fw"])} | {pct(c["placed"], c["fw"])} | '
                      f'{"—" if base else fmt_ci(d_pl, *ci_pl)} | {f1:.3f} |')
        md.append('')
    # the anchor share against what aligning gains, page by page (the text-page rule)
    md.append('### When does aligning stop paying? Aligned against Vision\'s own layer, by anchor share\n')
    md.append('Per page and reading (the three saved readings): the share of Vision\'s words the reading pairs with '
              'an equal word (an approximation of the lab\'s anchors, which it does not report), and the change in '
              'Find-placed words and in strictly passing lines against Vision\'s own layer. The lab keeps Vision\'s '
              'words when under half of them are its anchors; its anchors match loosely (wordLikeness), so this '
              'exact-equality share is lower than the lab\'s and pages under 0.50 here were still rewritten. A text page leaves Vision\'s layer as it is and '
              'adds the reading on a page of its own: it never costs placement, and it adds Find for the reading\'s '
              'words that the layer lacks.\n')
    md.append('| anchor share | page readings | lines rewritten | Δ placed words (sum) | pages placed worse | '
              'Δ passing lines (sum) | pages losing lines |')
    md.append('|---|---:|---:|---:|---:|---:|---:|')
    bins = [(0, 0.5), (0.5, 0.7), (0.7, 0.85), (0.85, 0.95), (0.95, 1.01)]
    rows_b = []
    for lo, hi in bins:
        n = rw = dpl = worse = dps = lose = 0
        for p, v in ap.items():
            for arm in ARMS[3:]:
                if arm not in v:
                    continue
                r = v[arm]['row']
                if not (lo <= r['anchor_share'] < hi):
                    continue
                n += 1
                rw += r['rewritten_lines']
                x = v[arm]['c']['placed'] - v[BASE]['c']['placed']
                y = v[arm]['c']['pass'] - v[BASE]['c']['pass']
                dpl += x
                worse += x < 0
                dps += y
                lose += y < 0
        rows_b.append({'bin': [lo, min(hi, 1.0)], 'n': n, 'rewritten': rw, 'd_placed': dpl, 'worse': worse,
                       'd_pass': dps, 'losing': lose})
        md.append(f'| {lo:.2f}–{min(hi, 1.0):.2f} | {n} | {rw} | {dpl:+d} | {worse} | {dps:+d} | {lose} |')
    js['anchor_bins'] = rows_b
    md.append('')
    return md, js


# ---------------------------------------------------------------- test 5, 6
def writer_tables(rows, vrows):
    md, js = [], {}
    md.append('## Three writings of the same words, four viewers (test 5)\n')
    md.append('Ten typewritten pages (every second non-clipping one in page order) and the five clippings '
              '(p072, p078, p080, p081, p098), Vision\'s `accurate` words and lines written three ways, each over '
              'the page image: `lab`, the Vision OCR lab\'s SearchableWriter (one run per line, the font sized to '
              'fit, a 0.25 em reserve); `ocrmypdf`, OCRmyPDF 17.13\'s own `hocrtransform` over the same words as '
              'hOCR (one BT block a line, per-word Tz, a trailing space, its glyphless Occulta font, the line\'s '
              'baseline slope); `words`, every word its own text object with a real trailing space and no reserve '
              '(Helvetica, Tz to the box). PDFKit is the drag and Find; for every viewer, its text extraction: '
              '`line` a truth line whose expected words come out adjacent and in order inside one extracted line, '
              '`welded` extracted tokens that are two or three layer words run together, `split` layer words that '
              'come out in two pieces. Extractions: PDFKit `page.string`, poppler 26 `pdftotext`, mupdf 1.28 '
              '`mutool draw -F txt`, pdf.js 6.5 `getTextContent` (a line ends at an item marked hasEOL).\n')
    for clip in (False, True):
        sel = [r for r in rows if r['clipping'] == clip]
        md.append(f'### {"the five clippings" if clip else "ten typewritten pages"}\n')
        md.append('| design | lines | PDFKit drag strict % | loose % | Find placed % | ' +
                  ' | '.join(f'{v} line %' for v in ('PDFKit', 'poppler', 'mupdf', 'pdf.js')) +
                  ' | welded per 1,000 words (PDFKit/poppler/mupdf/pdf.js) | split per 1,000 | MB a page |')
        md.append('|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---:|')
        for d in ('lab', 'ocrmypdf', 'words'):
            rs = [r for r in sel if r['design'] == d]
            n = sum(r['lines'] for r in rs)
            ps = sum(r['passed'] for r in rs)
            lo = sum(r['loose'] for r in rs)
            pl, fw = sum(r['placed'] for r in rs), sum(r['find_words'] for r in rs)
            v = {k: collections.Counter() for k in ('pdfkit', 'poppler', 'mupdf', 'pdfjs')}
            for r in rs:
                for k in v:
                    v[k].update(r['viewers'][k])
            lw = v['pdfkit']['layer_words']
            js[f'{"clip" if clip else "typed"}/{d}'] = {'lines': n, 'passed': ps, 'loose': lo, 'placed': [pl, fw],
                                                      'viewers': {k: dict(c) for k, c in v.items()},
                                                      'mb': sum(r['bytes'] for r in rs) / len(rs) / 1e6}
            md.append(f'| {d} | {n} | {pct(ps, n)} | {pct(lo, n)} | {pct(pl, fw)} | ' +
                      ' | '.join(pct(v[k]['line'], n) for k in v) + ' | ' +
                      ' / '.join(f'{1000 * v[k]["welded"] / max(1, lw):.1f}' for k in v) + ' | ' +
                      ' / '.join(f'{1000 * v[k]["split"] / max(1, lw):.1f}' for k in v) +
                      f' | {sum(r["bytes"] for r in rs) / len(rs) / 1e6:.2f} |')
        md.append('')
    md.append('## PDF/A (test 6)\n')
    md.append('veraPDF 1.30 over each PDF made a PDF/A-2 candidate (XMP `pdfaid` part 2, conformance B or U, and an '
              'sRGB output intent; nothing else changed), so what it finds is the file\'s own content: its fonts, '
              'their embedding and their Unicode mapping. Twenty `lab` PDFs (the fifteen writer pages and five more '
              'typewritten ones) and the fifteen of each other design. The same files without the declarations fail '
              '(6.6.2.1 metadata, 6.2.4.3 DeviceRGB without an output intent), so the validator is reading them. Where 2u '
              'fails, every font is given a full ToUnicode map (`add_to_unicode`): a simple font\'s from its encoding '
              '(ZapfDingbats and Symbol by their built-in ones), a Core Text TrueType subset\'s rebuilt from its '
              'embedded cmap\'s glyph names through the installed font (Core Text\'s own map can miss a glyph), and '
              'an Identity-H CID fallback font\'s from its CFF charset through the installed font; the extracted text '
              'is unchanged by it.\n')
    md.append('| design | PDFs | PDF/A-2b compliant | PDF/A-2u compliant | 2u after adding ToUnicode maps | rules failed |')
    md.append('|---|---:|---:|---:|---:|---|')
    for d in ('lab', 'ocrmypdf', 'words'):
        rs = [r for r in vrows if r['design'] == d]
        b = sum(r['2b']['compliant'] for r in rs)
        u = sum(r['2u']['compliant'] for r in rs)
        fixed = [r for r in rs if '2u+tounicode' in r]
        fu = sum(r['2u+tounicode']['compliant'] for r in fixed)
        rules = sorted({f['rule'] for r in rs for k in ('2b', '2u', '2u+tounicode') if k in r for f in r[k]['fails']})
        js[f'pdfa/{d}'] = {'pdfs': len(rs), '2b': b, '2u': u, 'tounicode_tried': len(fixed), 'tounicode_ok': fu,
                           'rules': rules}
        md.append(f'| {d} | {len(rs)} | {b} | {u} | {f"{fu} of {len(fixed)}" if fixed else "not needed"} | '
                  f'{", ".join(rules) or "none"} |')
    md.append('')
    return md, js


def acrobat_tables(cache: Path):
    """The owner's Acrobat Reader check (place_print.py acrobat): his answers.json against the blind key."""
    md, js = ['## Acrobat Reader, the owner\'s check (test 5, fifth viewer)\n'], {}
    ans, key = cache / 'acrobat' / 'answers.json', cache / 'acrobat-key.json'
    if not ans.exists():
        md.append('Not answered yet: the sheet is `acrobat/index.html` in the bench cache, gate '
                  '`W46.place-print-acrobat-owner-ok`.\n')
        return md, js
    a, k = json.loads(ans.read_text()), json.loads(key.read_text())
    md.append('Five writer pages (p002, p024, p087 typewritten; p078, p081 clippings), each design under a blind name; '
              'ten Find words and two whole-line drags a PDF, ticked by the owner in Adobe Acrobat Reader.\n')
    md.append('| design | Find, on the word | lines whole, in order | notes |')
    md.append('|---|---:|---:|---|')
    for d in ('lab', 'ocrmypdf', 'words'):
        files = [f for f, v in k.items() if v == d]
        c = {x: [0, 0] for x in ('find', 'line')}
        notes = []
        for f in files:
            for name, v in a.items():
                parts = name.split('|')
                if parts[0] != f:
                    continue
                if parts[1] in c:
                    c[parts[1]][0] += bool(v)
                    c[parts[1]][1] += 1
                elif parts[1] == 'note' and v.strip():
                    notes.append(f'{f[:4]}: {v.strip()}')
        js[d] = {x: c[x] for x in c} | {'notes': notes}
        md.append(f'| {d} | {c["find"][0]} of {c["find"][1]} | {c["line"][0]} of {c["line"][1]} | '
                  f'{"; ".join(notes).replace("|", "/") or "—"} |')
    if str(a.get('overall', '')).strip():
        md.append(f'\nOverall (owner): {a["overall"].strip()}')
    md.append('')
    return md, js


# ---------------------------------------------------------------- test 7
def box_tables(d):
    rows = d['rows']
    md, js = [], {}
    md.append('## The box-emitting readers and the open detectors beside Vision (test 7)\n')
    md.append('The 40 owner-typed pages, the same folded truth lines. A truth line is `whole` when one region holds '
              'the centres of all its scored words, `whole and alone` when that region holds no other truth line\'s '
              'word as well (what a line run needs); `outside` truth words lie in no region. blla (kraken 7.1.1) and '
              'PP-OCRv6 det lines are W46.fix-place-truth-lines\' (polygons where saved); Unlimited-OCR and '
              'Nemotron-Parse 2.0 blocks are W46.ocr-new-open-boxes\' Sherlock records, reversed or zero-area boxes '
              'left out, not repaired. For the blocks, `in block text` is the share of the truth words inside a '
              'block that the block\'s own text holds (what a block-level `replace` would put there). Nemotron\'s '
              f'canvas transform is rebuilt (centred padding), checked against Unlimited\'s blocks of like text: '
              f'{d["nemotron_check"]["pairs"]} pairs, median offset ({", ".join(f"{v:+.4f}" for v in d["nemotron_check"]["median_dx_dy"])}) of the page, '
              f'{d["nemotron_check"]["within_0.02"]} within 0.02 of the page on both axes.\n')
    md.append('| source | pages | regions | truth lines | whole % | whole and alone % | truth words outside % | '
              'baseline F | in block text % |')
    md.append('|---|---:|---:|---:|---:|---:|---:|---:|---:|')
    for src in ('vision-accurate', 'vision-documents', 'blla', 'ppocrv6', 'unlimited-ocr', 'nemotron-parse-2'):
        rs = [r for r in rows if r['source'] == src]
        if not rs:
            continue
        c = collections.Counter()
        for r in rs:
            c.update({k: r[k] for k in ('regions', 'lines', 'whole', 'alone', 'words', 'outside')})
            c.update({k: r.get(k, 0) for k in ('block_words', 'in_block_text')})
        bf = [r['baseline']['F'] for r in rs if 'baseline' in r]
        js[src] = {'pages': len(rs), **c, 'baseline_F': sum(bf) / len(bf) if bf else None}
        md.append(f'| {src} | {len(rs)} | {c["regions"]} | {c["lines"]} | {pct(c["whole"], c["lines"])} | '
                  f'{pct(c["alone"], c["lines"])} | {pct(c["outside"], c["words"])} | '
                  f'{f"{sum(bf) / len(bf):.3f}" if bf else "—"} | '
                  f'{pct(c["in_block_text"], c["block_words"]) if c["block_words"] else "—"} |')
    md.append('')
    # P6-1 (W46.place-print-fold-split): the owner's line rulings were asked only where blla and PP-OCRv6 det both
    # grouped differently from the truth, so folding them can only move the truth toward those two.
    fold = d.get('fold') or {}
    fs = collections.Counter()
    for v in fold.values():
        fs.update(v)
    md.append('### The same grouping on the unfolded truth, and on the lines the fold left alone\n')
    md.append('The owner\'s line rulings (W46.place-lines-owner-ok) were asked only where blla and PP-OCRv6 det both '
              'grouped a place differently from the truth, so folding them can only move the truth toward those two '
              f'detectors: {fs["merged"]} merges and {fs["left_out"]} truth lines left out, {fs["split"]} splits, on '
              f'{sum(1 for v in fold.values() if any(v.values()))} pages. `folded` is the table above; `unfolded` the '
              'truth lines as typed, before any ruling; `untouched` the unfolded lines no ruling merged, split or left '
              'out, on which the two truths agree. Δ is against Vision\'s `accurate` lines on the same truth, paired '
              'over the 40 pages.\n')
    md.append('| source | folded: lines | whole and alone % | Δ vs Vision (95% CI) | unfolded: lines | '
              'whole and alone % | Δ vs Vision (95% CI) | untouched: lines | whole and alone % | Δ vs Vision (95% CI) |')
    md.append('|---|---:|---:|---|---:|---:|---|---:|---:|---|')
    base = {r['page']: r for r in rows if r['source'] == 'vision-accurate'}
    for src in ('vision-accurate', 'vision-documents', 'blla', 'ppocrv6', 'unlimited-ocr', 'nemotron-parse-2'):
        rs = [r for r in rows if r['source'] == src and r['page'] in base and 'unfolded' in r]
        if not rs:
            continue
        cells, jv = [], {}
        for truth in ('folded', 'unfolded', 'untouched'):
            g = (lambda r: r) if truth == 'folded' else (lambda r, k=truth: r[k])
            n = sum(g(r)['lines'] for r in rs)
            a = sum(g(r)['alone'] for r in rs)
            bn = sum(g(base[r['page']])['lines'] for r in rs)
            ba = sum(g(base[r['page']])['alone'] for r in rs)
            jv[truth] = {'lines': n, 'alone': a}
            if src == 'vision-accurate':
                cells.append(f'{n} | {pct(a, n)} | —')
                continue
            dd = 100 * (a / n - ba / bn)
            ci = boot([(g(r)['alone'], g(r)['lines'], g(base[r['page']])['alone'], g(base[r['page']])['lines'])
                       for r in rs], 'alone', 'lines')
            jv[truth]['delta_vs_vision'] = [dd, *ci]
            cells.append(f'{n} | {pct(a, n)} | {fmt_ci(dd, *ci)}')
        js[f'truths/{src}'] = jv
        md.append(f'| {src} | ' + ' | '.join(cells) + ' |')
    js['fold_counts'] = dict(fs)
    md.append('')
    return md, js


def write(cache: Path, results: Path):
    vrows = json.loads((cache / 'vision-rows.json').read_text())
    pages = [json.loads(x) for x in (cache / 'arms-rows.jsonl').read_text().splitlines() if x.strip()]
    wrows = json.loads((cache / 'writers-rows.json').read_text())
    prow = json.loads((cache / 'verapdf-rows.json').read_text())
    brows = json.loads((cache / 'boxes-rows.json').read_text())
    brows['fold'] = {p['meta']['page']: p['meta']['fold'] for p in pages}
    out, js = [], {}
    for fn, args in ((vision_tables, (vrows,)), (arms_tables, (pages,)), (writer_tables, (wrows, prow)),
                     (acrobat_tables, (cache,)), (box_tables, (brows,))):
        md, j = fn(*args)
        out += md
        js[fn.__name__.replace('_tables', '')] = j
    js['fold'] = {p['meta']['page']: p['meta']['fold'] for p in pages}
    md_path = results / 'place-print.md'
    text = md_path.read_text() if md_path.exists() else '# W46.place-print\n\n<!-- tables -->\n<!-- /tables -->\n'
    head, rest = text.split('<!-- tables -->', 1)
    tail = rest.split('<!-- /tables -->', 1)[1]
    md_path.write_text(head + '<!-- tables -->\n' + '\n'.join(out) + '\n<!-- /tables -->' + tail)
    (results / 'place-print.json').write_text(json.dumps(js, indent=1, sort_keys=True) + '\n')
    print('wrote', md_path)
