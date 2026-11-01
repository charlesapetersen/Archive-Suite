#!/usr/bin/env python3
"""W46.ocr-ppocrv6-hands — kraken PP-OCRv6 as the laptop handwriting route (10-gap-audit §5 item 19).

Whether the laptop handwriting route and the kit can be a line recogniser: Kiessling's kraken port of PP-OCRv6
medium (Zenodo 10.5281/zenodo.21788410, Apache-2.0, kraken 7.1.1 and torch 2.14 in the rehearsal kraken venv),
first as it comes and then fine-tuned on a few hundred lines of one hand.

  python3 ocr_ppocrv6_hands.py vision-xml   Apple Vision's lines (layout_order.swift `lines`, the app's settings)
                                            as PAGE XML: each box a rectangle, its baseline at BASELINE_FRAC
  python3 ocr_ppocrv6_hands.py zero         kraken PP-OCRv6 on the Vision lines (the blla arm is loop_kraken.py's
                                            `public` and `truth96`, run into RUN/zero/blla-*)
  python3 ocr_ppocrv6_hands.py hand-fetch   one public hand: pages of one Elizabeth Blackwell diary volume
                                            (By the People, CC0), none of them in the 895
  python3 ocr_ppocrv6_hands.py hand-seg     blla and the base model's line readings on every hand page
  python3 ocr_ppocrv6_hands.py pairs        each truth line matched to a blla line (below)
  python3 ocr_ppocrv6_hands.py train [--device cpu|mps] [--only NAME]   the fine-tune curve, resumable
  python3 ocr_ppocrv6_hands.py eval         every trained model on its hand's held-out pages
  uv run --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex python ocr_ppocrv6_hands.py report

Sets. Zero-shot: the 895's L1-L3 (240 pages; By the People and Bentham, none in the model's listed training data)
and the owner's 21 hand and mixed pages of the 96 (the panel's 2400 px JPEGs, as loop_kraken.py reads them).
Comparators on the same pages: LightOnOCR-3 4B and Qwen3.5-9B 4-bit on this Mac for the owner's pages
(ocr_mac_local.py's saved readings), LightOnOCR-3 4B bf16 on FarmShare for L1-L3 (no Mac reading of the public
pages exists). The owner's truth was drafted by Claude Opus and Gemini 3.8 Flash, so on the owner's pages every
figure is agreement with the drafters until W46.ocr-hands-rescore (measurement audit, OCR-1); hands are ranked on
L1-L3.

Fine-tune hands. The owner's: the four handwritten pages of the Shils papers folder (p050, p051, p055, p056; the
folder is the only writer record, so one hand is assumed, not checked), leave one page out. The public: one
Blackwell diary volume (VOLUME), seeded pages, TRAIN_PAGES to draw lines from and the rest held out, plus the
26 L1 pages of the 895 from her other volumes. Training lines are the truth's own lines, never drawn by anyone: the base
model reads each blla line, and a monotone alignment (`match`) pairs truth lines with blla lines by character
error; a pair is kept when its error is at most MAX_CER and its lengths are within LEN_RATIO. VAL_LINES of the pool
are the validation lines (early stopping picks the epoch); the curve's N lines are the first N of the rest in a
seeded order, so each set contains the smaller ones. Scored on the held-out pages' whole text (blla lines, read by
the tuned model), as the zero-shot pages are.

MPS against CPU: the same training (the public hand, N = MPS_N) on each device, minutes and the held-out score.

Writes RUN/ (rebuildable: Vision lines, PAGE XML, readings, models) and segbench-results/ocr-ppocrv6-hands.md and
.json (aggregates only; the owner's text never enters the repo). No network but hand-fetch's public download; no
money.
"""
from __future__ import annotations

import argparse
import collections
import concurrent.futures
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from xml.sax.saxutils import quoteattr, escape

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / 'corpus'))

import common as C            # noqa: E402
import loop_kraken as LK      # noqa: E402
import routes as R            # noqa: E402
import specialists as SP      # noqa: E402

RUN = Path(os.environ.get('PPOCRV6_HANDS_RUN', Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/ppocrv6-hands'))
RESULTS = HERE.parents[1] / 'segbench-results'
KETOS = SP.KRAKEN.with_name('ketos')
LAYOUT = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/layout-order/bin/layout-order'
BASELINE_FRAC = 0.78          # place_truth.py's: the baseline's height in a Vision box, from the top
STRATA = ('L1', 'L2', 'L3')
OWNER_HAND = ('p050', 'p051', 'p055', 'p056')   # Shils papers, the folder with the most hand pages
BLACKWELL_ZIP = 'https://tile.loc.gov/storage-services/master/gdc/gdcdatasets/2023527889_v2/2023527889_v2.zip'
VOLUME = 'https://www.loc.gov/item/mss1288000967/'   # a Blackwell diary volume (254 L1 pages), none of them in the 895
HAND_PAGES, TRAIN_PAGES, SEED = 36, 24, 46
MIN_LINES = 8                 # a diary page with fewer truth lines is skipped (a blank or a cover)
MAX_CER, LEN_RATIO, SKIP = 0.6, 2.0, 0.7
VAL_LINES = 10
CURVE = {'blackwell': (20, 40, 80, 160, 240), 'owner': (20, 40, 80)}
MPS_N = 80


# ---- PAGE XML ----------------------------------------------------------------------------------------------------

def _pts(xy):
    return ' '.join(f'{round(x)},{round(y)}' for x, y in xy)


def page_xml(image, width, height, lines):
    """lines: [{'id', 'boundary': [(x, y)...], 'baseline': [(x, y)...], 'text'?}] -> a PAGE XML string kraken reads."""
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15">',
           f'<Page imageFilename={quoteattr(str(image))} imageWidth="{width}" imageHeight="{height}">',
           f'<TextRegion id="r0" custom="type {{type:text;}}"><Coords points="0,0 {width},0 {width},{height} 0,{height}"/>']
    for ln in lines:
        out.append(f'<TextLine id={quoteattr(ln["id"])} custom="type {{type:default;}}">'
                   f'<Coords points="{_pts(ln["boundary"])}"/><Baseline points="{_pts(ln["baseline"])}"/>')
        if ln.get('text') is not None:
            out.append(f'<TextEquiv><Unicode>{escape(ln["text"])}</Unicode></TextEquiv>')
        out.append('</TextLine>')
    out += ['</TextRegion>', '</Page>', '</PcGts>', '']
    return '\n'.join(out)


def _local(tag):
    return tag.rsplit('}', 1)[-1]


def read_page(path):
    """A PAGE XML file -> (image, width, height, lines in document order with their Unicode text or '')."""
    root = ET.parse(path).getroot()
    page = next(e for e in root.iter() if _local(e.tag) == 'Page')
    parse = lambda s: [tuple(float(v) for v in p.split(',')) for p in s.split()]   # noqa: E731
    lines = []
    for tl in (e for e in page.iter() if _local(e.tag) == 'TextLine'):
        coords = next((e for e in tl if _local(e.tag) == 'Coords'), None)
        base = next((e for e in tl if _local(e.tag) == 'Baseline'), None)
        uni = [u.text or '' for te in tl if _local(te.tag) == 'TextEquiv' for u in te if _local(u.tag) == 'Unicode']
        lines.append({'id': tl.get('id'), 'boundary': parse(coords.get('points')) if coords is not None else [],
                      'baseline': parse(base.get('points')) if base is not None else [],
                      'text': uni[0] if uni else ''})
    return page.get('imageFilename'), int(page.get('imageWidth')), int(page.get('imageHeight')), lines


def vision_lines(vision, image_size):
    """layout_order.swift's `lines` JSON (0-1 boxes, top-left origin) -> PAGE lines in pixels."""
    w, h = image_size
    out = []
    for i, ln in enumerate(vision['lines']):
        x0, y0, x1, y1 = ln['box']
        x0, x1 = max(0., x0 * w), min(w - 1., x1 * w)
        y0, y1 = max(0., y0 * h), min(h - 1., y1 * h)
        if x1 - x0 < 2 or y1 - y0 < 2:
            continue
        yb = y0 + BASELINE_FRAC * (y1 - y0)
        out.append({'id': f'v{i}', 'boundary': [(x0, y0), (x1, y0), (x1, y1), (x0, y1)],
                    'baseline': [(x0, yb), (x1, yb)]})
    return out


# ---- alignment ----------------------------------------------------------------------------------------------------

def lev(a, b):
    if len(a) < len(b):
        a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def cer(hyp, ref):
    ref, hyp = ' '.join(ref.split()), ' '.join(hyp.split())
    return lev(hyp, ref) / max(1, len(ref))


def truth_lines(text):
    return [' '.join(t.split()) for t in text.splitlines() if t.strip()]


def match(truth, read, skip=SKIP):
    """Monotone one-to-one alignment of truth lines to detected lines by the base model's reading of each.

    Cost of a pair is its character error (capped at 1), of leaving a line out `skip`; the cheapest path is
    returned as (truth index, detected index, cer) for the pairs it uses, in order."""
    m, n = len(truth), len(read)
    INF = float('inf')
    d = [[INF] * (n + 1) for _ in range(m + 1)]
    back = [[None] * (n + 1) for _ in range(m + 1)]
    d[0][0] = 0.
    for i in range(m + 1):
        for j in range(n + 1):
            if d[i][j] == INF:
                continue
            if i < m and d[i][j] + skip < d[i + 1][j]:
                d[i + 1][j], back[i + 1][j] = d[i][j] + skip, (i, j, None)
            if j < n and d[i][j] + skip < d[i][j + 1]:
                d[i][j + 1], back[i][j + 1] = d[i][j] + skip, (i, j, None)
            if i < m and j < n:
                c = min(1., cer(read[j], truth[i]))
                if d[i][j] + c < d[i + 1][j + 1]:
                    d[i + 1][j + 1], back[i + 1][j + 1] = d[i][j] + c, (i, j, c)
    pairs, i, j = [], m, n
    while (i, j) != (0, 0):
        pi, pj, c = back[i][j]
        if c is not None:
            pairs.append((pi, pj, c))
        i, j = pi, pj
    return pairs[::-1]


def keep(t, r, c):
    lt, lr = len(t), len(' '.join(r.split()))
    return c <= MAX_CER and lt >= 3 and lr > 0 and max(lt, lr) <= LEN_RATIO * min(lt, lr)


def curve_split(pool, curve, val=VAL_LINES, seed=SEED):
    """pool: line keys. -> (validation keys, {N: training keys}); nested sets, N capped at what the pool holds."""
    order = sorted(pool)
    random.Random(seed).shuffle(order)
    vals, rest = order[:val], order[val:]
    sets = {}
    for n in curve:
        if n <= len(rest):
            sets[n] = rest[:n]
    if rest and len(rest) not in sets and len(rest) < max(curve) and (not sets or len(rest) > max(sets)):
        sets[len(rest)] = rest           # the whole pool, when it is short of the curve's top
    return vals, sets


# ---- the sets -----------------------------------------------------------------------------------------------------

def public_rows():
    R.MANIFEST = LK.MANIFEST
    return [r for r in R.frozen() if r['stratum'] in STRATA]


def owner_pages():
    import ocr_panel as P
    return sorted(r['page'] for r in P.rows() if r['kind'] in ('handwritten', 'mixed'))


def owner_kinds():
    import ocr_panel as P
    return {r['page']: r['kind'] for r in P.rows()}


def owner_truth(p):
    import ocr_panel as P
    return (P.TRUTH / 'truth' / f'{p}.txt').read_text()


def owner_image(p):
    return LK.PANEL_IMAGES / f'{p}-original.jpg'


def image_size(path):
    from PIL import Image
    with Image.open(path) as im:
        return im.size


def cmd_vision_xml(_):
    jobs = [(p, owner_image(p)) for p in owner_pages()] + [(R.job_id(r), Path(r['image'])) for r in public_rows()]
    missing = [i for i, img in jobs if not (RUN / 'vision' / f'{i}.json').exists()]
    if missing:
        args = [a for i, img in jobs if i in missing for a in (str(img), str(RUN / 'vision' / f'{i}.json'))]
        (RUN / 'vision').mkdir(parents=True, exist_ok=True)
        subprocess.run([str(LAYOUT), 'lines', *args], check=True)
    out = RUN / 'vision-xml'
    out.mkdir(parents=True, exist_ok=True)
    for i, img in jobs:
        v = json.loads((RUN / 'vision' / f'{i}.json').read_text())
        size = image_size(img)
        (out / f'{i}.xml').write_text(page_xml(img, *size, vision_lines(v, size)))
    print(f'{len(jobs)} pages, {len(missing)} read by Vision now')


PAGE_CAP_GB = float(os.environ.get('PPOCRV6_PAGE_CAP_GB', '5'))


def _group_rss_gb(pgid):
    out = subprocess.run(['ps', '-A', '-o', 'pgid=,rss='], capture_output=True, text=True).stdout
    return sum(int(r) for g, r in (ln.split() for ln in out.splitlines() if ln.strip()) if int(g) == pgid) / 2**20


def guarded(args, log, page, step):
    """One kraken call for one page, on its own process group, killed past PAGE_CAP_GB (two runs of this item
    took the Mac down on 2026-10-31 with kraken trees of 50 GB). Peak memory and seconds go to `log`."""
    t, peak = time.monotonic(), 0.
    p = subprocess.Popen(args, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    killed = False
    while p.poll() is None:
        peak = max(peak, _group_rss_gb(p.pid))
        if peak > PAGE_CAP_GB:
            os.killpg(p.pid, 9)
            killed = True
            break
        time.sleep(0.5)
    err = p.communicate()[1]
    row = {'page': page, 'step': step, 'rc': p.returncode, 'peak_gb': round(peak, 2),
           'seconds': round(time.monotonic() - t, 1), 'killed': killed}
    log.write(json.dumps(row) + '\n')
    log.flush()
    print(json.dumps(row), flush=True)
    if p.returncode and not killed:
        print(err[-2000:], file=sys.stderr)
    return row


def cmd_public(_):
    """The blla arm on L1-L3, one page per kraken call on the CPU, each guarded (loop_kraken.py's batches of ten
    under four workers are what ran away). Segmentations go where loop_kraken.py's would (SP.seg_path), readings
    to SP.text_path(LK.KEY) and RUN/zero/blla-public; a killed page is recorded and skipped."""
    rows, m = public_rows(), LK.model()
    out = RUN / 'zero' / 'blla-public'
    out.mkdir(parents=True, exist_ok=True)
    with (RUN / 'zero' / 'blla-public-guard.jsonl').open('a') as log:
        for r in rows:
            i, seg, txt = R.job_id(r), SP.seg_path(r), SP.text_path(LK.KEY, r)
            seg.parent.mkdir(parents=True, exist_ok=True)
            txt.parent.mkdir(parents=True, exist_ok=True)
            if not seg.exists():
                guarded([str(SP.KRAKEN), '-d', 'cpu', '-x', '-i', str(r['image']), str(seg), 'segment', '-bl',
                         '--text-direction', 'horizontal-lr'], log, i, 'blla')
            if seg.exists() and not txt.exists():
                guarded([str(SP.KRAKEN), '-d', 'cpu', '-f', 'page', '-i', str(seg), str(txt), 'ocr', '-m', str(m)],
                        log, i, 'ocr')
            if txt.exists():
                shutil.copyfile(txt, out / f'{i}.txt')


def timed_kraken(log, step, pairs, *cmd, device='cpu'):
    t = time.monotonic()
    SP.kraken(['-d', device, '-f', 'page'], pairs, *cmd)
    log.append({'step': step, 'pages': len(pairs), 'seconds': round(time.monotonic() - t, 1)})


def cmd_zero(_):
    m = LK.model()
    jobs = [(i, RUN / 'vision-xml' / f'{i}.xml', RUN / 'zero' / ('vision-hands' if i.startswith('p') and '__' not in i
                                                               else 'vision-public') / f'{i}.txt')
            for i in [*owner_pages(), *(R.job_id(r) for r in public_rows())]]
    todo = [j for j in jobs if not j[2].exists()]
    for j in todo:
        j[2].parent.mkdir(parents=True, exist_ok=True)
    log = []
    with concurrent.futures.ThreadPoolExecutor(SP.WORKERS) as ex:
        for f in [ex.submit(timed_kraken, log, 'ocr', [(j[1], j[2]) for j in b], 'ocr', '-m', str(m))
                  for b in SP.batches(todo)]:
            f.result()
    t = RUN / 'zero' / 'vision-timing.json'
    prev = json.loads(t.read_text())['calls'] if t.exists() else []
    t.write_text(json.dumps({'workers': SP.WORKERS, 'batch': SP.BATCH, 'calls': prev + log}, indent=1))
    print(f'{len(todo)} pages read on Vision lines')


# ---- the hands ----------------------------------------------------------------------------------------------------

def hand_dir(hand):
    return RUN / 'hand' / hand


def fetch(url, dest):
    """corpus/fetch.sh (the allowed hosts only) into RUN: --stdout caps a body at 20 MB, the diaries' zip is 30."""
    subprocess.run([str(C.FETCH), url, str(dest.relative_to(RUN))], check=True,
                   env={**os.environ, 'BENCH_CORPUS_CACHE': str(RUN)})


def cmd_hand_fetch(_):
    import src_btp
    d = hand_dir('blackwell')
    z = RUN / 'raw' / '2023527889_v2.zip'
    if not z.exists():
        fetch(BLACKWELL_ZIP, z)
    rows = {r['Asset']: r for r in src_btp.rows_of(z.read_bytes())}
    cands = [json.loads(l) for l in (C.CACHE / 'candidates.jsonl').open()]
    bench = {r['page_id'] for r in C.read_jsonl(RESULTS / 'bench-corpus' / 'manifest.jsonl')}
    vol = sorted(c['page_id'] for c in cands if c['item_url'] == VOLUME and c['page_id'] not in bench
                 and c['page_id'] in rows and len(truth_lines(src_btp.truth(rows[c['page_id']]['Transcription'])))
                 >= MIN_LINES)
    random.Random(SEED).shuffle(vol)
    chosen = vol[:HAND_PAGES]
    by = {c['page_id']: c for c in cands}
    (d / 'img').mkdir(parents=True, exist_ok=True)
    pages = []
    for k, pid in enumerate(chosen):
        img = d / 'img' / f'{pid}.jpg'
        if not img.exists():
            fetch(by[pid]['fetch']['image'], img)
        (d / 'img' / f'{pid}.txt').write_text(src_btp.truth(rows[pid]['Transcription']))
        pages.append({'page': pid, 'role': 'train' if k < TRAIN_PAGES else 'test', 'image': str(img),
                      'truth': str(d / 'img' / f'{pid}.txt'), 'stratum': 'L1'})
    # Her other volumes' pages in the 895 are a second held-out group (`other`), read from the frozen copies.
    for r in public_rows():
        if r['collection'] == '2023527889/Elizabeth Blackwell: Diaries':
            pages.append({'page': R.job_id(r), 'role': 'other', 'image': r['image'], 'truth': r['truth'],
                          'stratum': r['stratum']})
    (d / 'pages.json').write_text(json.dumps({'volume': VOLUME, 'candidates': len(vol), 'pages': pages}, indent=1))
    print(f'{len(chosen)} of {len(vol)} pages of {VOLUME}; {sum(p["role"] == "other" for p in pages)} others')


def hand_pages(hand):
    if hand == 'blackwell':
        return json.loads((hand_dir(hand) / 'pages.json').read_text())['pages']
    return [{'page': p, 'role': 'fold', 'image': str(owner_image(p)), 'truth': None, 'stratum': 'S0'}
            for p in OWNER_HAND]


def page_truth(p):
    return Path(p['truth']).read_text() if p['truth'] else owner_truth(p['page'])


def seg_xml(hand, p):
    return hand_dir(hand) / 'seg' / f'{p["page"]}.xml'


def cmd_hand_seg(_):
    m = LK.model()
    for hand in ('owner', 'blackwell'):
        pp = hand_pages(hand)
        (hand_dir(hand) / 'seg').mkdir(parents=True, exist_ok=True)
        (hand_dir(hand) / 'base').mkdir(parents=True, exist_ok=True)
        todo = [p for p in pp if not seg_xml(hand, p).exists()]
        with concurrent.futures.ThreadPoolExecutor(SP.WORKERS) as ex:
            for f in [ex.submit(SP.kraken, ['-x'], [(p['image'], seg_xml(hand, p)) for p in b], 'segment', '-bl',
                                '--text-direction', 'horizontal-lr') for b in SP.batches(todo)]:
                f.result()
        read = [p for p in pp if not (hand_dir(hand) / 'base' / f'{p["page"]}.xml').exists()]
        with concurrent.futures.ThreadPoolExecutor(SP.WORKERS) as ex:
            for f in [ex.submit(SP.kraken, ['-f', 'page', '-x'],
                                [(seg_xml(hand, p), hand_dir(hand) / 'base' / f'{p["page"]}.xml') for p in b],
                                'ocr', '-m', str(m)) for b in SP.batches(read)]:
                f.result()
        print(f'{hand}: {len(todo)} segmented, {len(read)} read')


def cmd_pairs(_):
    for hand in ('owner', 'blackwell'):
        stats = []
        for p in hand_pages(hand):
            image, w, h, lines = read_page(hand_dir(hand) / 'base' / f'{p["page"]}.xml')
            truth = truth_lines(page_truth(p))
            kept = [(i, j, c) for i, j, c in match(truth, [ln['text'] for ln in lines])
                    if keep(truth[i], lines[j]['text'], c)]
            rows = [{**lines[j], 'id': f'{p["page"]}#{j}', 'text': truth[i], 'cer': round(c, 4)} for i, j, c in kept]
            (hand_dir(hand) / 'pairs').mkdir(parents=True, exist_ok=True)
            (hand_dir(hand) / 'pairs' / f'{p["page"]}.json').write_text(json.dumps(
                {'image': image, 'width': w, 'height': h, 'lines': rows}, ensure_ascii=False))
            stats.append({'page': p['page'], 'role': p['role'], 'truth_lines': len(truth), 'detected': len(lines),
                          'kept': len(rows), 'mean_cer': round(sum(r['cer'] for r in rows) / len(rows), 4)
                          if rows else None})
        (hand_dir(hand) / 'pairs.json').write_text(json.dumps(stats, indent=1))
        tl, kl = sum(s['truth_lines'] for s in stats), sum(s['kept'] for s in stats)
        print(f'{hand}: {kl} of {tl} truth lines paired over {len(stats)} pages')


def pair_lines(hand, page):
    return json.loads((hand_dir(hand) / 'pairs' / f'{page}.json').read_text())


def plans():
    """Every training: name -> {hand, n, train pages, test pages, device}. Owner: leave one page out."""
    out = {}
    bw = hand_pages('blackwell')
    tr = [p['page'] for p in bw if p['role'] == 'train']
    te = [p['page'] for p in bw if p['role'] in ('test', 'other')]
    pool = [f'{pg}|{k}' for pg in tr for k in range(len(pair_lines('blackwell', pg)['lines']))]
    vals, sets = curve_split(pool, CURVE['blackwell'])
    for n, keys in sets.items():
        out[f'blackwell-n{n}-cpu'] = {'hand': 'blackwell', 'n': n, 'keys': keys, 'val': vals, 'test': te,
                                      'device': 'cpu'}
    if MPS_N in sets:
        out[f'blackwell-n{MPS_N}-mps'] = {**out[f'blackwell-n{MPS_N}-cpu'], 'device': 'mps'}
    for held in OWNER_HAND:
        pool = [f'{pg}|{k}' for pg in OWNER_HAND if pg != held
                for k in range(len(pair_lines('owner', pg)['lines']))]
        vals, sets = curve_split(pool, CURVE['owner'])
        for n, keys in sets.items():
            out[f'owner-{held}-n{n}-cpu'] = {'hand': 'owner', 'n': n, 'keys': keys, 'val': vals, 'test': [held],
                                             'device': 'cpu'}
    return out


def write_lines(hand, keys, d):
    """The chosen pair lines, grouped by page, as PAGE XML files with the truth line as their text."""
    by = collections.defaultdict(list)
    for k in keys:
        pg, i = k.split('|')
        by[pg].append(int(i))
    d.mkdir(parents=True, exist_ok=True)
    files = []
    for pg, idx in sorted(by.items()):
        pl = pair_lines(hand, pg)
        f = d / f'{pg}.xml'
        f.write_text(page_xml(pl['image'], pl['width'], pl['height'], [pl['lines'][i] for i in sorted(idx)]))
        files.append(f)
    return files


def cmd_train(a):
    todo = {k: v for k, v in plans().items() if (not a.only or re.fullmatch(a.only, k))
            and (not a.device or v['device'] == a.device)}
    base = LK.model()
    for name, pl in todo.items():
        d = RUN / 'train' / name
        if (d / 'done.json').exists():
            continue
        if d.exists():
            shutil.rmtree(d)        # an interrupted training restarts whole; only this run's own directory
        tr = write_lines(pl['hand'], pl['keys'], d / 'train')
        va = write_lines(pl['hand'], pl['val'], d / 'val')
        (d / 'train.txt').write_text(''.join(f'{f}\n' for f in tr))
        (d / 'val.txt').write_text(''.join(f'{f}\n' for f in va))
        t = time.monotonic()
        p = subprocess.run([str(KETOS), '-d', pl['device'], '-s', str(SEED), 'train', '-f', 'page', '-i', str(base), '--resize', 'union',
                            '-t', str(d / 'train.txt'), '-e', str(d / 'val.txt'), '-q', 'early', '--min-epochs',
                            str(MIN_EPOCHS), '--lag', str(LAG), '-N', str(MAX_EPOCHS), '-o', str(d / 'model')],
                           capture_output=True, text=True)
        secs = time.monotonic() - t
        (d / 'ketos.log').write_text(p.stdout + p.stderr)
        if p.returncode:
            raise SystemExit(f'{name}: ketos exited {p.returncode}; see {d / "ketos.log"}')
        best = best_model(d)
        (d / 'done.json').write_text(json.dumps({'seconds': round(secs, 1), 'best': str(best), 'lines': len(pl['keys']),
                                                 'device': pl['device']}, indent=1))
        print(f'{name}: {secs / 60:.1f} min, best {best.name}')


MIN_EPOCHS, LAG, MAX_EPOCHS = 10, 5, 60


def best_model(d):
    """ketos writes the best checkpoint's weights as best_<val_metric>.safetensors into its -o directory."""
    found = sorted((d / 'model').glob('best_*.safetensors'))
    if len(found) != 1:
        raise SystemExit(f'{d}: want one best_*.safetensors, found {len(found)}')
    return found[0]


def cmd_eval(_):
    for name, pl in plans().items():
        d = RUN / 'train' / name
        if not (d / 'done.json').exists():
            continue
        m = json.loads((d / 'done.json').read_text())['best']
        pages = {p['page']: p for p in hand_pages(pl['hand'])}
        todo = [pg for pg in pl['test'] if not (d / 'read' / f'{pg}.txt').exists()]
        (d / 'read').mkdir(parents=True, exist_ok=True)
        if todo:
            SP.kraken(['-d', 'cpu', '-f', 'page'], [(seg_xml(pl['hand'], pages[pg]), d / 'read' / f'{pg}.txt')
                                                    for pg in todo], 'ocr', '-m', m)
        print(f'{name}: {len(todo)} read')


# ---- report -------------------------------------------------------------------------------------------------------

def cmd_report(_):
    import ocr_panel_score as S
    raise SystemExit('report: not written yet')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['vision-xml', 'public', 'zero','hand-fetch', 'hand-seg', 'pairs', 'train', 'eval',
                                        'report'])
    ap.add_argument('--device', choices=['cpu', 'mps'])
    ap.add_argument('--only', help='train: a regular expression over the training names')
    a = ap.parse_args()
    globals()['cmd_' + a.command.replace('-', '_')](a)


if __name__ == '__main__':
    main()
