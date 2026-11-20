#!/usr/bin/env python3
"""W49.proc-read-flag-newspaper: can the read-poorly flag cover a newspaper page read in regions?

  python3 ops/autonomous/heavy-run.py run -- python3 ArchiveProcessor/scripts/segbench/post_read_flag_newspaper.py vision
  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy --with python-Levenshtein \
      python ArchiveProcessor/scripts/segbench/post_read_flag_newspaper.py report
  python3 ArchiveProcessor/scripts/segbench/post_read_flag_newspaper.py self-test

THE QUESTION (owner, 2026-11-19, call 22). The flag (OCR/ReadQualityDisagreement.swift, post_read_flag.py) compares
a reader's page text with Apple Vision's reading of the same image, in reading order, and flags the page past the
reader's own cut. A newspaper page read in regions comes out region by region, so its text is in another order than
Vision's whole-page reading, and the check skips it. Which comparison would work there, and what cut?

THE SIGNALS (risk, higher = more likely poor; a failed reading is always flagged, as in the fit):
  strict     1 - NES of the reading against Vision's whole-page text (what the app's check computes today).
  orderfree  1 - NewsBench's bag-of-words F1 against Vision's whole-page text (no order at all).
  regrouped  1 - NES against Vision's own lines put into the reading's regions: each line goes to the region holding
             most of it (NewspaperPagePlan.owners, the app's rule), regions in their read order, lines no region
             touches last (where the partition reads its outside crops). The app already has these lines: the plan
             is cut from them (TextLayer.visionLines), so this costs no second Vision read.
THE LABEL. Poor under 70 strict NES against the truth, as the fit; a false alarm is a flag on a reading at 70 or above,
the ceiling 5% of those (post_read_flag.CEILING).

THE READINGS (cached, no reader is run, no money):
  * NewsBench, the Vision OCR lab's copy (~/.local/share/visionocr-ocrlab/newsbench, its own git repository): the 15
    scored L9 scans, read by every system in ocr-results/. The LLM and VLM systems are used, each marked region or
    whole page by its route; Tesseract pipelines and Vision itself are left out (the app offers neither as a reader
    the flag checks).
  * The bench's PaddleOCR-VL 1.6 4-bit on this Mac on the same 15 (W46.layout-partition-score/-fix): whole page, the
    raw regions and the app's fixed partition, from layout-partition-score/reads.
  * Gemini 3.7 Flash through the gateway on PP-DocLayoutV3 regions and the whole page (W46.ocr-regions-paid): 3 of
    the L9 scans, 9 other public pages and the owner's 96 (region order on pages that are not newspapers).
Vision: segbench-dewarp lines (the app's VisionClient settings) on the image each reader read: the frozen L9
originals, the gateway's images for its 12 public pages; the 96 use the fit's own readings (enh-dewarp/lines/raw).
Regions for `regrouped`: the reader's own crop boxes where they are saved (PaddleOCR-VL raw, Gemini); otherwise the
app's PP-DocLayoutV3 boxes in PaddleOCR-VL's raw order, or DocLayout-YOLO's (layout-photo/regions/yolo.json) for a
YOLO-routed system. A partition read uses its raw boxes: its own plan images went to the Trash.

THE FITS. Pooled over the region readings of the L9 scans (per system each has 15 pages, too few for a 5% ceiling):
in-sample, cross-validated by page (5-fold, 20 seeds, a page's readings in one fold), and leave one system out (the
cut fitted on the other systems, applied to the held-out one: a reader the cut was not fitted on). Every reader with
an app rule also has its own whole-page cut applied to its region readings under each signal.
Writes score-only files: segbench-results/post-read-flag-newspaper.{md,json}.
"""
from __future__ import annotations

import argparse
import json
import statistics as st
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import post_read_flag as F   # noqa: E402  (stdlib only at import)

CACHE = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
WORK = CACHE / 'read-flag-newspaper'
LAB = Path.home() / '.local/share/visionocr-ocrlab/newsbench'
FROZEN = Path.home() / 'Library/Application Support/ArchiveSuiteRehearsal/bench-corpus-frozen'
PARTITION = CACHE / 'layout-partition-score' / 'reads'
GATEWAY = CACHE / 'ocr-regions-gateway'
LAYOUT = CACHE / 'layout-photo' / 'regions'
BIN = CACHE / 'segbench/bin/segbench-dewarp'
RESULTS = HERE.parents[1] / 'segbench-results'
OUT_MD = RESULTS / 'post-read-flag-newspaper.md'
OUT_JSON = RESULTS / 'post-read-flag-newspaper.json'
SIGNALS = ('strict', 'orderfree', 'regrouped', 'crops')
FAILED = F.FAILED
BATCH = 400
# The cut recommended for the app: the fitted cut is the lowest that holds the ceiling in-sample (0.398), but held-out
# systems see 6% there; every cut from it to 0.45 catches the same content-poor readings, and 0.45 has a third of the
# false alarms. Chosen after looking at the cut grid, so its in-sample figures are not a held-out estimate.
RECOMMENDED = 0.45

# NewsBench systems: (route, regions the regrouping uses). Left out: Tesseract pipelines (tesseract-*, paddlex-
# tesseract, ll-*-tess, res-tess-*, progmag-ppdoc-tesseract) and Vision (apple-vision-wholepage, vision-yolo).
LAB_SYSTEMS = {
    'churro-3b-8bit-yolo': ('region', 'yolo'), 'claude-haiku-4.5-paddlex': ('region', 'pp'),
    'deepseek-v4.1-flash-paddlex': ('region', 'pp'), 'dots.mocr-4bit-yolo': ('region', 'yolo'),
    'gemini-3.5-flash-lite-paddlex': ('region', 'pp'), 'gemini-3.5-flash-lite-residual-paddlex': ('region', 'pp'),
    'gemma-3-27b-it-paddlex': ('region', 'pp'), 'glm-5.3-flash-paddlex': ('region', 'pp'),
    'glm-ocr-doclayout': ('region', 'pp'), 'glm-ocr-residual-paddlex': ('region', 'pp'),
    'gpt-5.6-luna-paddlex': ('region', 'pp'), 'lib-paddlex-glm': ('region', 'pp'), 'll-asyolo-glm': ('region', 'yolo'),
    'll-asyolo-pvl': ('region', 'yolo'), 'll-doclayout-glm': ('region', 'pp'), 'll-doclayout-pvl': ('region', 'pp'),
    'mistral-small-2603-paddlex': ('region', 'pp'), 'nara-qwen-3.5-2b-4bit-yolo': ('region', 'yolo'),
    'news_combo_fast': ('region', 'pp'), 'paddleocr-vl-1.6-4bit-yolo': ('region', 'yolo'),
    'paddlex-glm': ('region', 'pp'), 'progmag-ppdoc-glm-repair': ('region', 'pp'), 'qwen3.8-flash-paddlex': ('region', 'pp'),
    'res-glm-base': ('region', 'pp'),
    'churro-3b-8bit-whole': ('whole', None), 'claude-haiku-4.5-wholepage': ('whole', None),
    'gemini-3.5-flash-lite-wholepage': ('whole', None), 'gemma-3-27b-it-wholepage': ('whole', None),
    'glm-ocr-mlx': ('whole', None), 'gpt-5.6-luna-wholepage': ('whole', None),
    'mistral-small-2603-wholepage': ('whole', None), 'qwen3-vl-8b-4bit-whole': ('whole', None),
    'qwen3.5-4b-4bit-whole': ('whole', None), 'qwen3.8-flash-wholepage': ('whole', None),
}
# Systems whose model has an app rule (ReadQualityDisagreement.swift), with that rule's cut (fitted on whole pages).
APP_CUTS = {
    'gemini-3.5-flash-lite': ('Gemini 3.5 Flash Lite', 0.6967), 'qwen3.8-flash': ('Qwen3.8 Flash', 0.7243),
    'qwen3-vl-8b-4bit': ('Qwen3-VL 8B', 0.7013), 'gemini-3.7-gw': ('Gemini 3.7 Flash', 0.9764),
}


def model_of(system: str) -> str | None:
    return next((k for k in APP_CUTS if system.startswith(k)), None)


# --- geometry (pure; self-tested): NewspaperPagePlan.owners -------------------------------------------------------

def _inter(a, b):
    x0, y0, x1, y1 = max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])
    return (x0, y0, x1, y1) if x1 > x0 and y1 > y0 else None


def union_area(rects) -> float:
    rects = [r for r in rects if r]
    if not rects:
        return 0.
    xs = sorted({x for r in rects for x in (r[0], r[2])})
    total = 0.
    for x0, x1 in zip(xs, xs[1:]):
        spans = sorted((r[1], r[3]) for r in rects if r[0] <= x0 and r[2] >= x1)
        cover, cy0, cy1 = 0., None, None
        for y0, y1 in spans:
            if cy1 is None or y0 > cy1:
                if cy1 is not None:
                    cover += cy1 - cy0
                cy0, cy1 = y0, y1
            else:
                cy1 = max(cy1, y1)
        if cy1 is not None:
            cover += cy1 - cy0
        total += cover * (x1 - x0)
    return total


def kept(boxes):
    """The app's boxes: one wholly covered by earlier kept boxes adds no pixels and is dropped."""
    out = []
    for b in boxes:
        area = (b[2] - b[0]) * (b[3] - b[1])
        if union_area([_inter(b, o) for o in out]) < area - 1e-12:
            out.append(b)
    return out


def owners(lines, boxes):
    """For each line, the region with most of the line's area it owns (earlier regions own an overlap), the earlier on
    a tie; None for a line no region touches."""
    res = []
    for ln in lines:
        best = None
        for k, b in enumerate(boxes):
            hit = _inter(ln, b)
            if not hit:
                continue
            owned = (hit[2] - hit[0]) * (hit[3] - hit[1]) - union_area([_inter(hit, o) for o in boxes[:k]])
            if owned > 1e-12 and owned > (best[1] if best else 0):
                best = (k, owned)
        res.append(best[0] if best else None)
    return res


def regroup(lines, boxes):
    """Vision's line texts in region order, then the lines no region holds, in Vision's order."""
    own = owners([l['box'] for l in lines], boxes)
    out = [l['text'] for k in range(len(boxes)) for l, o in zip(lines, own) if o == k]
    return '\n'.join(out + [l['text'] for l, o in zip(lines, own) if o is None])


# --- Vision -------------------------------------------------------------------------------------------------------

def l9_pages():
    return sorted(p.stem for p in (FROZEN / 'L9').glob('*.jpg'))


def gateway_manifest():
    return json.loads((GATEWAY / 'manifest.json').read_text())


def vision_jobs():
    rows = [(FROZEN / 'L9' / f'{p}.jpg', WORK / 'lines' / 'l9' / f'{p}.json') for p in l9_pages()]
    rows += [(Path(p['image']), WORK / 'lines' / 'gateway' / f'{p["id"]}.json')
             for p in gateway_manifest()['pages'] if p['set'] != 'owner99']
    return rows


def crop_sets():
    """{(geometry, page): [(pixel box, image)]}: the region crops Vision reads for `crops`, in read order."""
    import regions_cluster as C
    from PIL import Image
    out = {}
    for p in l9_pages():
        img = FROZEN / 'L9' / f'{p}.jpg'
        recs = sorted((json.loads(f.read_text()) for f in (PARTITION / 'raw' / p).glob('*.json')), key=lambda r: r['index'])
        w, h = Image.open(img).size
        keep = set(kept(_norm_boxes([r['box'] for r in recs], w, h)))
        out['pp', p] = [(tuple(r['box']), img) for r in recs if tuple(_norm_boxes([r['box']], w, h)[0]) in keep]
        out['yolo', p] = [(C.pixel_box(b, w, h, C.PAD), img) for b in yolo_boxes(p)]
    for pg in gateway_manifest()['pages']:
        out['gateway', pg['id']] = [(tuple(c['px']), Path(pg['image'])) for c in pg['crops']['pp-doclayoutv3']]
    return out


def crop_path(geom, page, i):
    return WORK / 'crops' / geom / page / f'{i:03d}.png'


def crop_lines_path(geom, page, i):
    return WORK / 'lines' / 'crops' / geom / page / f'{i:03d}.json'


def vision():
    import vision_guard
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    crops = []
    for (geom, page), boxes in crop_sets().items():
        opened = None
        for i, (box, img) in enumerate(boxes):
            dest, lines = crop_path(geom, page, i), crop_lines_path(geom, page, i)
            if not dest.exists() and not lines.exists():
                opened = opened or Image.open(img).convert('RGB')
                dest.parent.mkdir(parents=True, exist_ok=True)
                opened.crop(box).save(dest)
            crops.append((dest, lines))
    rows = [r for r in vision_jobs() + crops if not r[1].exists()]
    print(f'{len(rows)} images for Vision', flush=True)
    if not rows:
        return
    for _, out in rows:
        out.parent.mkdir(parents=True, exist_ok=True)
    # In batches: Vision once hung on one crop (0% CPU, its ANE queue) during the guard's second read, and a refused
    # run quarantines every output it wrote, so a batch bounds what a hang costs.
    for k in range(0, len(rows), BATCH):
        jobs = WORK / 'lines-jobs.tsv'
        jobs.write_text(''.join(f'{a}\t{b}\n' for a, b in rows[k:k + BATCH]))
        vision_guard.run(BIN, jobs, 'lines')
        print(f'batch {k // BATCH + 1}: {min(k + BATCH, len(rows))} of {len(rows)}', flush=True)


def vision_lines(path: Path):
    """[{text, box (x0, y0, x1, y1), normalised}] from a segbench-dewarp lines file."""
    d = json.loads(path.read_text())
    out = []
    for l in d['lines']:
        xs, ys = [q[0] for q in l['quad']], [q[1] for q in l['quad']]
        out.append({'text': l['text'], 'box': (min(xs), min(ys), max(xs), max(ys))})
    return out


# --- the readings -------------------------------------------------------------------------------------------------

def _norm_boxes(px_boxes, w, h):
    return [(x0 / w, y0 / h, x1 / w, y1 / h) for x0, y0, x1, y1 in px_boxes]


def pp_raw_boxes(page):
    """PaddleOCR-VL's raw-arm crops (the app's PP-DocLayoutV3 detection, its kept regions in order), normalised."""
    from PIL import Image
    recs = sorted((json.loads(f.read_text()) for f in (PARTITION / 'raw' / page).glob('*.json')), key=lambda r: r['index'])
    w, h = Image.open(FROZEN / 'L9' / f'{page}.jpg').size
    return kept(_norm_boxes([r['box'] for r in recs], w, h))


def yolo_boxes(page):
    d = json.loads((LAYOUT / 'yolo.json').read_text())['pages'][page]
    return kept([tuple(r['box']) for r in sorted(d['regions'], key=lambda r: r['order'])])


_CROP_COUNTS = {}


def crop_vision(geom, page):
    """Vision's lines of each region crop, in read order (crop_sets)."""
    if not _CROP_COUNTS:
        _CROP_COUNTS.update({k: len(v) for k, v in crop_sets().items()})
    return [[l['text'] for l in vision_lines(crop_lines_path(geom, page, i))] for i in range(_CROP_COUNTS[geom, page])]


def stitch(texts):
    return '\n\n'.join(t.strip() for t in texts if t.strip())


def readings():
    """One dict per reading: system, model, route, set, page, text, ok, truth, stratum, vision lines, regions."""
    out = []
    l9 = l9_pages()
    lines = {p: vision_lines(WORK / 'lines' / 'l9' / f'{p}.json') for p in l9}
    truth = {p: (FROZEN / 'L9' / f'{p}.txt').read_text() for p in l9}
    boxes = {'pp': {p: pp_raw_boxes(p) for p in l9}, 'yolo': {p: yolo_boxes(p) for p in l9}}
    for system, (route, geom) in LAB_SYSTEMS.items():
        for p in l9:
            f = LAB / 'ocr-results' / system / (p.split('__', 1)[1] + '.txt')
            text = f.read_text() if f.exists() else ''
            out.append({'system': system, 'model': model_of(system), 'route': route, 'set': 'L9', 'page': p,
                        'text': text, 'ok': bool(text.strip()), 'truth': truth[p], 'stratum': 'L9', 'lines': lines[p],
                        'regions': boxes[geom][p] if geom else None, 'source': 'newsbench',
                        'crops': crop_vision(geom, p) if geom else None})
    for arm, route in (('whole', 'whole'), ('raw', 'region'), ('partition', 'region')):
        for p in l9:
            recs = sorted((json.loads(f.read_text()) for f in (PARTITION / arm / p).glob('*.json')), key=lambda r: r['index'])
            text = stitch(r['text'] for r in recs)
            out.append({'system': f'paddleocr-vl-1.6-mac-{arm}', 'model': None, 'route': route, 'set': 'L9', 'page': p,
                        'text': text, 'ok': bool(text.strip()), 'truth': truth[p], 'stratum': 'L9', 'lines': lines[p],
                        'regions': boxes['pp'][p] if route == 'region' else None, 'source': 'bench',
                        'crops': crop_vision('pp', p) if route == 'region' else None})
    out += gemini_readings()
    return out


def gemini_readings():
    """Gemini 3.7 Flash's whole and PP-DocLayoutV3 readings, re-validated from their receipts (regions_orderfree)."""
    import regions as D
    import regions_gateway as G
    m = G.manifest()
    G.verify()
    ledger = {r['request_sha256']: r for r in G.effective() if r['event'] == 'settle'}
    out = []
    for p in m['pages']:
        ref = Path(p['truth']).read_text()
        if p['set'] == 'owner99':
            lines, set_, stratum = vision_lines(CACHE / 'enh-dewarp/lines/raw' / f'{p["id"]}.json'), 'the 96', None
        else:
            lines = vision_lines(WORK / 'lines' / 'gateway' / f'{p["id"]}.json')
            set_, stratum = ('L9' if p['stratum'] == 'L9' else 'public'), p['stratum']
        for arm, route in (('whole', 'whole'), ('pp-doclayoutv3', 'region')):
            if not G.present(m, p, arm, ledger):
                raise ValueError(f'{p["id"]}/{arm}: receipts missing')
            got = [{'index': i, 'box': c['box'], **G.receipt(m, (p, arm, i, c), ledger)} for i, c in enumerate(p['crops'][arm])]
            good = [g for g in got if g['text']]
            text = D.stitch(arm, good) if good else ''
            regions = kept([tuple(c['box']) for c in p['crops'][arm]]) if route == 'region' else None
            out.append({'system': f'gemini-3.7-gw-{arm}', 'model': 'gemini-3.7-gw', 'route': route, 'set': set_,
                        'page': p['id'], 'text': text, 'ok': bool(text.strip()), 'truth': ref, 'stratum': stratum,
                        'lines': lines, 'regions': regions, 'source': 'gateway', 'kind': p.get('kind'),
                        'crops': crop_vision('gateway', p['id']) if route == 'region' else None})
    return out


# --- scoring ------------------------------------------------------------------------------------------------------

def score_all(reads):
    import ocr_panel_score as S
    import ocr_scorers as O
    import re
    ill = re.compile(r'\[illegible\]', re.I)
    rows = []
    for r in reads:
        sc = S.score(r['truth'], r['text'], r['stratum']) if r['stratum'] else S.score(r['truth'], r['text'])
        nes = sc['nes'] if r['ok'] else 0.
        bow_truth = O.newsbench(ill.sub(' ', r['truth']), ill.sub(' ', r['text']))['bowF1'] if r['ok'] else 0.
        vtext = '\n'.join(l['text'] for l in r['lines'])
        risk = {}
        if not r['ok']:
            risk = {s: FAILED for s in SIGNALS}
        elif not vtext.strip():
            risk = {s: 1. for s in SIGNALS}
        else:
            risk['strict'] = 1 - S.score(vtext, r['text'])['nes']
            risk['orderfree'] = 1 - O.newsbench(vtext, r['text'])['bowF1']
            grouped = regroup(r['lines'], r['regions']) if r['regions'] else vtext
            risk['regrouped'] = 1 - S.score(grouped, r['text'])['nes']
            crops = r.get('crops')
            if crops is None:
                risk['crops'] = risk['strict']
            else:
                ctext = '\n\n'.join('\n'.join(c) for c in crops if c)
                risk['crops'] = 1 - S.score(ctext, r['text'])['nes'] if ctext.strip() else 1.
        rows.append({k: r[k] for k in ('system', 'model', 'route', 'set', 'page', 'source')} |
                    {'kind': r.get('kind'), 'ok': r['ok'], 'nes': nes, 'bowf1': bow_truth, 'poor': nes < F.POOR,
                     'poor_orderfree': bow_truth < F.POOR, 'risk': risk})
    return rows


def evaluate(rows, sig, label='poor', cut=None):
    risk = [r['risk'][sig] for r in rows]
    poor = [r[label] for r in rows]
    nes = [r['nes'] for r in rows]
    fitted = F.fit_cut(risk, poor) if cut is None else cut
    out = {'n': len(rows), 'auc': F.auc(risk, poor), 'cut': fitted,
           'in_sample': F.rates(F.counts(risk, poor, nes, fitted))}
    if cut is None:
        out['crossval'] = F.rates(F.crossval(risk, poor, nes, groups=[r['page'] for r in rows]))
        out['leave_system_out'] = F.rates(leave_one_out(rows, sig, label))
    return out


def leave_one_out(rows, sig, label='poor'):
    tot = {}
    for s in sorted({r['system'] for r in rows}):
        tr = [r for r in rows if r['system'] != s]
        te = [r for r in rows if r['system'] == s]
        cut = F.fit_cut([r['risk'][sig] for r in tr], [r[label] for r in tr])
        tot = F.add(tot, F.counts([r['risk'][sig] for r in te], [r[label] for r in te], [r['nes'] for r in te], cut))
    return tot


def analyse(rows):
    l9 = [r for r in rows if r['set'] == 'L9']
    res = {'counts': {}, 'systems': {}, 'pooled': {}, 'app_cuts': {}, 'gemini': {}}
    for route in ('region', 'whole'):
        sub = [r for r in l9 if r['route'] == route]
        res['counts'][route] = {'readings': len(sub), 'systems': len({r['system'] for r in sub}),
                                'poor': sum(r['poor'] for r in sub), 'failed': sum(not r['ok'] for r in sub),
                                'mean_nes': st.mean(r['nes'] for r in sub)}
        res['pooled'][route] = {s: evaluate(sub, s) for s in SIGNALS}
        res['pooled'][route + ' order-free label'] = {s: evaluate(sub, s, 'poor_orderfree') for s in SIGNALS}
        # A single cut for every reader: the median of the app's whole-page cuts for its direct and OpenRouter routes.
    res['pooled']['region, app-style cut 0.70'] = {s: evaluate([r for r in l9 if r['route'] == 'region'], s, cut=0.70)
                                                  for s in SIGNALS}
    reg = [r for r in l9 if r['route'] == 'region']
    res['recommended'] = {'cut': RECOMMENDED, 'strict label': evaluate(reg, 'crops', cut=RECOMMENDED),
                          'order-free label': evaluate(reg, 'crops', 'poor_orderfree', cut=RECOMMENDED),
                          'by system': {s: F.counts([r['risk']['crops'] for r in reg if r['system'] == s],
                                                    [r['poor'] for r in reg if r['system'] == s],
                                                    [r['nes'] for r in reg if r['system'] == s], RECOMMENDED)
                                        for s in sorted({r['system'] for r in reg})}}
    res['pooled']['whole, app-style cut 0.70'] = {s: evaluate([r for r in l9 if r['route'] == 'whole'], s, cut=0.70)
                                                 for s in SIGNALS}
    for s in sorted({r['system'] for r in l9}):
        sub = [r for r in l9 if r['system'] == s]
        res['systems'][s] = {'route': sub[0]['route'], 'n': len(sub), 'poor': sum(r['poor'] for r in sub),
                             'failed': sum(not r['ok'] for r in sub), 'mean_nes': st.mean(r['nes'] for r in sub),
                             'auc': {g: F.auc([r['risk'][g] for r in sub], [r['poor'] for r in sub]) for g in SIGNALS},
                             'median_risk_good': {g: med([r['risk'][g] for r in sub if not r['poor'] and r['ok']])
                                                  for g in SIGNALS}}
    for model, (name, cut) in APP_CUTS.items():
        for route in ('region', 'whole'):
            sub = [r for r in rows if r['model'] == model and r['route'] == route]
            if sub:
                res['app_cuts'][f'{name}, {route}'] = {'cut': cut, 'sets': sorted({r['set'] for r in sub}),
                                                       **{s: evaluate(sub, s, cut=cut) for s in SIGNALS}}
    gem = [r for r in rows if r['source'] == 'gateway']
    for set_ in ('the 96', 'public', 'L9'):
        for route in ('whole', 'region'):
            sub = [r for r in gem if r['set'] == set_ and r['route'] == route]
            res['gemini'][f'{set_}, {route}'] = {'n': len(sub), 'poor': sum(r['poor'] for r in sub),
                                                'mean_nes': st.mean(r['nes'] for r in sub),
                                                **{s: {'auc': F.auc([r['risk'][s] for r in sub], [r['poor'] for r in sub]),
                                                       'median_risk_good': med([r['risk'][s] for r in sub
                                                                                if not r['poor'] and r['ok']]),
                                                       'fitted_cut': F.fit_cut([r['risk'][s] for r in sub],
                                                                               [r['poor'] for r in sub])}
                                                   for s in SIGNALS}}
    return res


def med(xs):
    xs = [x for x in xs if x != FAILED]
    return st.median(xs) if xs else None


def vision_quality():
    """Vision's own NES and bag-of-words F1 against the L9 truth: the whole page, regrouped, and its crops."""
    import ocr_panel_score as S
    import ocr_scorers as O
    out = {}
    for p in l9_pages():
        t = (FROZEN / 'L9' / f'{p}.txt').read_text()
        lines = vision_lines(WORK / 'lines' / 'l9' / f'{p}.json')
        texts = {'whole page': '\n'.join(l['text'] for l in lines), 'regrouped (PP)': regroup(lines, pp_raw_boxes(p))}
        for geom in ('pp', 'yolo'):
            texts[f'crops ({geom.upper()})'] = '\n\n'.join('\n'.join(c) for c in crop_vision(geom, p) if c)
        out[p] = {k: {'nes': S.score(t, v, 'L9')['nes'], 'bowf1': O.newsbench(t, v)['bowF1'],
                      'lines': len(lines) if k == 'whole page' else None} for k, v in texts.items()}
    return out


def report():
    rows = score_all(readings())
    res = analyse(rows)
    res['vision_quality'] = vision_quality()
    check_parity(rows)
    clean = json.loads(json.dumps(res, default=str).replace('Infinity', 'null'))
    OUT_JSON.write_text(json.dumps(clean, indent=1) + '\n')
    OUT_MD.write_text(render(clean))
    print(json.dumps(res['counts'], indent=1))
    return rows, res


def check_parity(rows):
    """Each PaddleOCR-VL arm's page NES reproduces the committed layout-partition-fix-pages.csv."""
    import csv
    with (RESULTS / 'layout-partition-fix-pages.csv').open() as f:
        want = {(r['arm'], r['page']): float(r['nes']) for r in csv.DictReader(f)}
    for r in rows:
        if r['system'].startswith('paddleocr-vl-1.6-mac-'):
            arm = r['system'].rsplit('-', 1)[1]
            w = want.get((arm, r['page']))
            if w is None or abs(w - r['nes']) > 1e-3:
                raise SystemExit(f'parity: {r["system"]} {r["page"]} {r["nes"]:.4f} against {w}')


def _p(x):
    return '-' if x is None else f'{100 * x:.0f}%'


def _ci(ci):
    return '' if not ci or ci[0] is None else f' ({100 * ci[0]:.0f}-{100 * ci[1]:.0f})'


def _cell(r, hits=True):
    if hits:
        return f"{r['hits']}/{r['poor']} {_p(r['hit_rate'])}{_ci(r['hit_ci'])}"
    return f"{r['false_alarms']}/{r['good']} {_p(r['fa_rate'])}{_ci(r['fa_ci'])}"


def _f(x, d=3):
    return '-' if x is None else f'{x:.{d}f}'


NAMES = {'strict': "against Vision's whole page, in order (today's check)",
         'orderfree': "against Vision's whole page, order-free (bag of words)",
         'regrouped': "against Vision's whole-page lines put into the reading's regions",
         'crops': 'against Vision reading the same region crops'}


def render(res):
    c = res['counts']
    L = [HEAD.strip(), '', FINDINGS.strip(), '',
         '## Vision itself on the 15 scans', '',
         'Its own reading scored against the truth (mean over the pages; the lowest page in brackets).', '',
         '| Vision reading | strict NES | bag-of-words F1 |', '|---|---:|---:|']
    vq = res['vision_quality']
    for k in next(iter(vq.values())):
        nes = [v[k]['nes'] for v in vq.values()]
        bow = [v[k]['bowf1'] for v in vq.values()]
        L.append(f'| {k} | {100 * st.mean(nes):.1f} ({100 * min(nes):.1f}) | {100 * st.mean(bow):.1f} ({100 * min(bow):.1f}) |')
    L += ['', '## The four comparisons, every reader pooled', '',
          f"Region readings: {c['region']['readings']} ({c['region']['systems']} systems x 15 pages, plus Gemini's 3), "
          f"{c['region']['poor']} poor, mean NES {100 * c['region']['mean_nes']:.1f}. Whole-page readings, for contrast: "
          f"{c['whole']['readings']} ({c['whole']['systems']} systems), {c['whole']['poor']} poor, {c['whole']['failed']} failed, "
          f"mean NES {100 * c['whole']['mean_nes']:.1f} (most whole-page reads of a newspaper loop or stop short). "
          'Cells: caught / poor, false alarms / good, Wilson 95% intervals.', '']
    for title, key in (('Region readings, poor = under 70 strict NES', 'region'),
                       ('Region readings, poor = under 70 bag-of-words F1 (content lost, not order)', 'region order-free label'),
                       ('Whole-page readings, poor = under 70 strict NES', 'whole')):
        L += [f'### {title}', '', '| comparison | AUC | cut | in-sample caught | in-sample false alarms | '
              'cross-validated by page | left-out system |', '|---|---:|---:|---|---|---|---|']
        for g in SIGNALS:
            e = res['pooled'][key][g]
            cv, lo = e['crossval'], e['leave_system_out']
            L.append(f"| {NAMES[g]} | {_f(e['auc'])} | {_f(e['cut'])} | {_cell(e['in_sample'])} | "
                     f"{_cell(e['in_sample'], False)} | {_p(cv['hit_rate'])} at {_p(cv['fa_rate'])} | "
                     f"{_p(lo['hit_rate'])} at {_p(lo['fa_rate'])} |")
        L.append('')
    r = res['recommended']
    L += [f"## The recommended cut, {r['cut']:.2f}, on the same-region comparison", '',
          '| label | caught | false alarms | flags under 90 NES |', '|---|---|---|---:|']
    for k in ('strict label', 'order-free label'):
        e = r[k]['in_sample']
        L.append(f"| {k} | {_cell(e)} | {_cell(e, False)} | {e['flags_under_90']}/{e['flagged']} |")
    L += ['', "### By system at that cut (strict label)", '', '| system | poor | caught | false alarms |', '|---|---:|---:|---:|']
    for s, e in r['by system'].items():
        L.append(f"| {s} | {e['poor']} | {e['hits']} | {e['false_alarms']} |")
    L += ['', "## The app's whole-page cuts applied to region readings", '',
          "Each reader with an app rule, its own cut (fitted on whole photographs) on its region and whole-page readings "
          'here. Sets: L9 for the NewsBench systems; Gemini 3.7 Flash adds 9 public pages and the 96.', '',
          '| reader, route | cut | today: caught | today: false alarms | same regions: caught | same regions: false alarms |',
          '|---|---:|---|---|---|---|']
    for k, e in res['app_cuts'].items():
        L.append(f"| {k} | {e['cut']:.3f} | {_cell(e['strict']['in_sample'])} | {_cell(e['strict']['in_sample'], False)} | "
                 f"{_cell(e['crops']['in_sample'])} | {_cell(e['crops']['in_sample'], False)} |")
    L += ['', '## Gemini 3.7 Flash on PP-DocLayoutV3 regions, by set', '',
          'Median disagreement of its good readings, and AUC, under each comparison (the 96 are not newspapers).', '',
          '| set, route | n | poor | mean NES | today: AUC, median | same regions: AUC, median |', '|---|---:|---:|---:|---|---|']
    for k, e in res['gemini'].items():
        L.append(f"| {k} | {e['n']} | {e['poor']} | {100 * e['mean_nes']:.1f} | {_f(e['strict']['auc'], 2)}, "
                 f"{_f(e['strict']['median_risk_good'], 2)} | {_f(e['crops']['auc'], 2)}, {_f(e['crops']['median_risk_good'], 2)} |")
    L += ['', '## Each system on the 15 scans', '',
          'AUC and the median disagreement of its good readings, today\'s check and the same-region one.', '',
          '| system | route | poor | mean NES | today: AUC, median | same regions: AUC, median |', '|---|---|---:|---:|---|---|']
    for s, e in res['systems'].items():
        L.append(f"| {s} | {e['route']} | {e['poor']} | {100 * e['mean_nes']:.1f} | {_f(e['auc']['strict'], 2)}, "
                 f"{_f(e['median_risk_good']['strict'], 2)} | {_f(e['auc']['crops'], 2)}, {_f(e['median_risk_good']['crops'], 2)} |")
    return '\n'.join(L) + '\n\n' + CARD.strip() + '\n'


HEAD = """
# W49.proc-read-flag-newspaper: the read-poorly flag on newspaper pages read in regions

Generated by `scripts/segbench/post_read_flag_newspaper.py report` (the method is its docstring); every figure is in
`post-read-flag-newspaper.json`. No money and no reader run: the readings are cached (the Vision OCR lab's NewsBench
copy at its commit 2372b6b, W46.layout-partition-score's Mac reads, W46.ocr-regions-paid's gateway reads); Apple
Vision read the 15 scans and their 3,124 region crops on this Mac (macOS 27.2, the guarded runner).

A reading is poor under 70 NES against the truth, as in `post-read-flag.md`; a false alarm is a flag on a reading at
70 or above, and the ceiling is 5% of those.
"""

FINDINGS = """
## What this says

- **Vision cannot read a whole newspaper scan, so today's check cannot work on one.** On the 15 L9 scans Vision's
  whole-page reading scores 21.8 strict NES and 44.5 bag-of-words F1 against the truth (16.6 on its worst page); it
  finds 84 to 544 lines on pages of 1,900 to 9,000 words. Every reader then disagrees with it: Gemini 3.7 Flash's
  whole-page readings score 97.8 and still sit 0.70 from Vision. Against the whole page the comparison barely
  separates poor region readings from good ones (AUC 0.52 in order, 0.42 order-free, 0.47 with Vision's lines put
  into the regions), and the app's own cuts (about 0.70) would flag 301 of 335 good region readings.
- **Vision reading the same region crops does.** Cropped, Vision reads the same scans at 84.8 strict NES and 90.8
  bag-of-words F1 (PP-DocLayoutV3 crops, worst page 82.6). Compared crop for crop, in the regions' order, the
  disagreement separates poor region readings (AUC 0.69) and almost perfectly separates the ones that lost content
  rather than order (AUC 0.98). The fitted cut, 0.398, holds the ceiling in-sample (16 of 335 good readings, 4.8%,
  catching 21 of 58 poor ones) and cross-validated by page (38% caught at 5.3%), and catches every one of the 12
  that lost content; with each system left out in turn the held-out system sees 6.0% false alarms.
- **A cut of 0.45 is the one to ship.** From 0.40 to 0.45 the false alarms fall from 16 to 5 of 335 (1.5%, 0.6-3.4%)
  while 20 of the 21 poor readings and all 12 content-poor ones are still caught; above 0.45 hits drop fast (13 of 58
  at 0.50). It was chosen from this grid, so its figures are in-sample. The poor readings it misses are poor in order
  only: the strict label counts a region
  reading whose words are right but whose columns are out of the truth's order as poor, and Vision's crops share the
  reading's order, so no comparison with them can see that.
- **The whole-page cuts do not transfer.** On the same-region comparison every app cut (0.70 to 0.98) flags no good
  region reading but also catches almost none; a newspaper page needs its own cut, one for every reader, since per
  system 15 pages are too few to fit one and the pooled cut holds for systems left out of the fit.
- **The shipped check misfires on a newspaper scan read whole.** The app reads a newspaper whole when the layout
  model is not downloaded, the detector fails or the kind is uncertain, and the whole-page check then runs against
  Vision's 22-NES reading: at the readers' cuts (about 0.70) it flags 46 of 53 good whole readings here (Gemini 3.5
  Flash Lite 12 of 13, Qwen3-VL 8B 10 of 11; Gemini 3.7 Flash, at 0.976, none). Most whole readings of these scans are
  poor (115 of 168), so most of those flags are right, but a good one is almost always flagged too
  (W49.proc-read-flag-newspaper-whole measures a fix).
- **What the app would do.** For a page read in regions, read each region image the plan hands the reader (and its
  outside crops) with Vision, join them in the same order, compare with the reading's text by the bench's NES, and
  flag at 0.45 or more. The plan's crops already exist; Vision on them took about 0.15 s a crop here (some 10 s for
  a page of 65 regions; time on the app's masked crops is not measured).
"""

CARD = """
## Measurement card

- **Truth.** The 15 scored L9 scans' Library of Congress By the People volunteer transcriptions (NewsBench; 4 pages
  with partial gold are left out, as the bench does). Not checked by the owner. No reader scored here drafted it.
- **Selection.** L9 is NewsBench's scored set as frozen in the bench corpus, chosen before any of these readers or
  this flag; the systems are every LLM or VLM folder in the lab's ocr-results (Tesseract pipelines and Vision itself
  left out), with no system dropped for its result.
- **Comparison.** Every comparison is computed on the same readings, the same Vision run and the same scorer. The
  region crops Vision read are the app's PP-DocLayoutV3 boxes in PaddleOCR-VL's raw order (DocLayout-YOLO's for the
  YOLO-routed systems; Gemini's own crops for Gemini), not each lab system's own detector, and unmasked: the app's
  partition whitens other regions' pixels and adds outside crops, which its plan images (now in the Trash) would show.
- **Noise.** 393 region readings, but only 15 pages, 14 from one collection (`mss34132`), four from one item; many
  lab systems share one detector and read alike (eleven PP systems have their one poor reading on the same page), so
  the pooled intervals are optimistic. Cross-validation keeps a page's readings in one fold; leave-one-system-out
  tests a reader outside the fit. Vision's readings are settled by the guard's two agreeing reads; the readers were
  not rerun.
- **Scope.** Scanned newspapers only: no photographed newspaper with truth exists (W46.newspaper-photo-truth), and
  the owner's newspapers are photographs. Not measured: Vision on the app's masked partition crops, the time it adds
  in the app, and a reader the flag does not yet check on whole pages.
"""


def self_test():
    assert union_area([(0, 0, 2, 2), (1, 1, 3, 3)]) == 7
    assert union_area([(0, 0, 1, 1), (0, 0, 1, 1)]) == 1
    assert kept([(0, 0, 2, 2), (0, 0, 1, 1), (1, 0, 3, 1)]) == [(0, 0, 2, 2), (1, 0, 3, 1)]
    boxes = [(0, 0, .5, 1), (.5, 0, 1, 1)]
    # a line mostly in the right region goes there; one in neither stays out; the earlier region wins a tie
    assert owners([(.4, .1, 1., .2), (.1, .3, .4, .4), (.25, .5, .75, .6)], boxes) == [1, 0, 0]
    assert owners([(2, 2, 3, 3)], boxes) == [None]
    lines = [{'text': 'right', 'box': (.6, .1, .9, .2)}, {'text': 'left', 'box': (.1, .2, .4, .3)},
             {'text': 'out', 'box': (2, 2, 3, 3)}]
    assert regroup(lines, boxes) == 'left\nright\nout'
    print('self-test ok')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=('vision', 'report', 'self-test'))
    a = ap.parse_args()
    {'vision': vision, 'report': report, 'self-test': self_test}[a.cmd]()


if __name__ == '__main__':
    main()
