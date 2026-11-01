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


SKIP_WORD, SPAN_SLACK = 0.35, 3


def span_match(words, read, skip=SKIP, skip_word=SKIP_WORD, slack=SPAN_SLACK):
    """Truth with no line breaks (the owner's pages are one paragraph): each detected line takes a contiguous run of
    truth words, monotone, chosen by the base model's reading of it. A line may take nothing (cost `skip`), a
    truth word may go unused (`skip_word`, a line blla missed); a run is the reading's word count +- `slack`.
    -> (start, end, detected index, cer) for the runs used, in order."""
    try:
        from rapidfuzz.distance import Levenshtein
        dist = Levenshtein.distance
    except ImportError:
        dist = lev
    m, n = len(read), len(words)
    INF = float('inf')
    d = [[INF] * (n + 1) for _ in range(m + 1)]
    back = [[None] * (n + 1) for _ in range(m + 1)]
    d[0][0] = 0.
    for j in range(m + 1):
        r = ' '.join(read[j].split()) if j < m else ''
        rw = len(r.split())
        for i in range(n + 1):
            here = d[j][i]
            if here == INF:
                continue
            if i < n and here + skip_word < d[j][i + 1]:
                d[j][i + 1], back[j][i + 1] = here + skip_word, (j, i, None)
            if j < m:
                if here + skip < d[j + 1][i]:
                    d[j + 1][i], back[j + 1][i] = here + skip, (j, i, None)
                for k in range(max(1, rw - slack), rw + slack + 1):
                    if i + k > n:
                        break
                    t = ' '.join(words[i:i + k])
                    c = min(1., dist(r, t) / max(1, len(t)))
                    if here + c < d[j + 1][i + k]:
                        d[j + 1][i + k], back[j + 1][i + k] = here + c, (j, i, c)
    out, j, i = [], m, n
    while (j, i) != (0, 0):
        pj, pi, c = back[j][i]
        if c is not None:
            out.append((pi, i, pj, c))
        j, i = pj, pi
    return out[::-1]


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


# A kraken call's process tree is stopped past this. Ordinary pages peak at 2.4-5.7 GB on CPU (landscape and
# large scans highest); 9 GB stays under the Agent Manager's 10.8 GB guard, and one call runs at a time.
PAGE_CAP_GB = float(os.environ.get('PPOCRV6_PAGE_CAP_GB', '9'))


_LIBPROC = []


def _footprint(pid):
    """phys_footprint in bytes (proc_pid_rusage, RUSAGE_INFO_V0), the figure the Agent Manager's memory guard and
    Activity Monitor use; ps's RSS leaves out compressed and swapped pages, so under pressure it read 0.8 GB for a
    ketos training the session guard stopped at 14.3 GB (2026-11-01)."""
    import ctypes
    import struct
    if not _LIBPROC:
        _LIBPROC.append(ctypes.CDLL('/usr/lib/libproc.dylib'))
    buf = ctypes.create_string_buffer(256)
    if _LIBPROC[0].proc_pid_rusage(int(pid), 0, buf) != 0:
        return 0
    return struct.unpack_from('<Q', buf.raw, 16 + 7 * 8)[0]


def _group_rss_gb(pgid):
    """The process group's summed phys_footprint in GB (the name is historical)."""
    out = subprocess.run(['ps', '-A', '-o', 'pid=,pgid='], capture_output=True, text=True).stdout
    pids = [int(p) for p, g in (ln.split() for ln in out.splitlines() if ln.strip()) if int(g) == pgid]
    return sum(_footprint(p) for p in pids) / 2**30


def guarded(args, log, page, step, cap=None, out=None):
    """One kraken call for one page, on its own process group, killed past PAGE_CAP_GB (two runs of this item
    took the Mac down on 2026-10-31 with kraken trees of 50 GB). Peak memory and seconds go to `log`."""
    t, peak, cap = time.monotonic(), 0., cap or PAGE_CAP_GB
    sink = out.open('w') if out else None
    p = subprocess.Popen(args, start_new_session=True, stdout=sink or subprocess.DEVNULL,
                         stderr=sink or subprocess.PIPE, text=True)
    killed = False
    while p.poll() is None:
        peak = max(peak, _group_rss_gb(p.pid))
        if peak > cap:
            os.killpg(p.pid, 9)
            killed = True
            break
        time.sleep(0.5)
    err = p.communicate()[1] or (out.read_text() if out else '')
    if sink:
        sink.close()
    row = {'page': page, 'step': step, 'rc': p.returncode, 'peak_gb': round(peak, 2),
           'seconds': round(time.monotonic() - t, 1), 'killed': killed}
    log.write(json.dumps(row) + '\n')
    log.flush()
    print(json.dumps(row), flush=True)
    if p.returncode and not killed:
        print(err[-2000:], file=sys.stderr)
    return row


OCR_BATCH = 10   # reading peaks under 2 GB a call (blla is what ran away), so it is batched to load the model once


def ocr_batches(pairs, m, log, opts):
    """kraken ocr over (input, output) pairs, OCR_BATCH a guarded call; the log row names the batch's first page and
    its size, so seconds a page are seconds / pages."""
    for k in range(0, len(pairs), OCR_BATCH):
        b = pairs[k:k + OCR_BATCH]
        args = [str(SP.KRAKEN), '-d', 'cpu', *opts]
        for a, o in b:
            args += ['-i', str(a), str(o)]
        row = guarded(args + ['ocr', '-m', str(m)], log, Path(b[0][0]).stem, f'ocr-batch{len(b)}')
        if row['rc'] and len(b) > 1:
            # One bad or heavy page fails or stops the call: read the batch's pages one at a time so the rest are
            # not lost, and a page that is stopped alone is the one named in the log.
            for a, o in b:
                if not Path(o).exists():
                    guarded([str(SP.KRAKEN), '-d', 'cpu', *opts, '-i', str(a), str(o), 'ocr', '-m', str(m)], log,
                            Path(a).stem, 'ocr')


def cmd_public(_):
    """The blla arm on L1-L3, blla one page per kraken call on the CPU (reading batched), each guarded (loop_kraken.py's batches of ten
    under four workers are what ran away). Segmentations go where loop_kraken.py's would (SP.seg_path), readings
    to SP.text_path(LK.KEY) and RUN/zero/blla-public; a killed page is recorded and skipped."""
    rows, m = public_rows(), LK.model()
    out = RUN / 'zero' / 'blla-public'
    out.mkdir(parents=True, exist_ok=True)
    with (RUN / 'zero' / 'blla-public-guard.jsonl').open('a') as log:
        for r in rows:
            seg = SP.seg_path(r)
            seg.parent.mkdir(parents=True, exist_ok=True)
            SP.text_path(LK.KEY, r).parent.mkdir(parents=True, exist_ok=True)
            if not seg.exists():
                guarded([str(SP.KRAKEN), '-d', 'cpu', '-x', '-i', str(r['image']), str(seg), 'segment', '-bl',
                         '--text-direction', 'horizontal-lr'], log, R.job_id(r), 'blla')
        ocr_batches([(SP.seg_path(r), SP.text_path(LK.KEY, r)) for r in rows
                     if SP.seg_path(r).exists() and not SP.text_path(LK.KEY, r).exists()], m, log, ['-f', 'page'])
    for r in rows:
        if SP.text_path(LK.KEY, r).exists():
            shutil.copyfile(SP.text_path(LK.KEY, r), out / f'{R.job_id(r)}.txt')


def cmd_zero(_):
    """PP-OCRv6 on the Vision lines, OCR_BATCH pages a guarded call."""
    m = LK.model()
    jobs = [(i, RUN / 'vision-xml' / f'{i}.xml', RUN / 'zero' / ('vision-hands' if i.startswith('p') and '__' not in i
                                                               else 'vision-public') / f'{i}.txt')
            for i in [*owner_pages(), *(R.job_id(r) for r in public_rows())]]
    todo = [(xml, txt) for _, xml, txt in jobs if not txt.exists()]
    for _, txt in todo:
        txt.parent.mkdir(parents=True, exist_ok=True)
    with (RUN / 'zero' / 'vision-guard.jsonl').open('a') as log:
        ocr_batches(todo, m, log, ['-f', 'page'])


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
        with (hand_dir(hand) / 'guard.jsonl').open('a') as log:
            for p in pp:
                if not seg_xml(hand, p).exists():
                    guarded([str(SP.KRAKEN), '-d', 'cpu', '-x', '-i', p['image'], str(seg_xml(hand, p)), 'segment',
                             '-bl', '--text-direction', 'horizontal-lr'], log, p['page'], 'blla')
            ocr_batches([(seg_xml(hand, p), hand_dir(hand) / 'base' / f'{p["page"]}.xml') for p in pp
                         if seg_xml(hand, p).exists() and not (hand_dir(hand) / 'base' / f'{p["page"]}.xml').exists()],
                        m, log, ['-f', 'page', '-x'])
        print(f'{hand}: {sum(seg_xml(hand, p).exists() for p in pp)} of {len(pp)} segmented')


def cmd_pairs(_):
    for hand in ('owner', 'blackwell'):
        stats = []
        for p in hand_pages(hand):
            if not (hand_dir(hand) / 'base' / f'{p["page"]}.xml').exists():
                print(f'{hand}: {p["page"]} has no base reading (stopped by the guard); left out', file=sys.stderr)
                continue
            image, w, h, lines = read_page(hand_dir(hand) / 'base' / f'{p["page"]}.xml')
            truth = truth_lines(page_truth(p))
            reads = [ln['text'] for ln in lines]
            if len(truth) * 2 < len(lines):
                # One paragraph a page (the owner's truth): pair runs of its words with the lines instead.
                words = ' '.join(truth).split()
                runs = span_match(words, reads)
                truth = [' '.join(words[a:b]) for a, b, _, _ in runs]
                spans = [(k, j, c) for k, (_, _, j, c) in enumerate(runs)]
                used = sum(b - a for a, b, _, _ in runs)
            else:
                spans, words, used = match(truth, reads), None, None
            kept = [(i, j, c) for i, j, c in spans if keep(truth[i], lines[j]['text'], c)]
            rows = [{**lines[j], 'id': f'{p["page"]}#{j}', 'text': truth[i], 'cer': round(c, 4)} for i, j, c in kept]
            (hand_dir(hand) / 'pairs').mkdir(parents=True, exist_ok=True)
            (hand_dir(hand) / 'pairs' / f'{p["page"]}.json').write_text(json.dumps(
                {'image': image, 'width': w, 'height': h, 'lines': rows}, ensure_ascii=False))
            stats.append({'page': p['page'], 'role': p['role'], 'truth_lines': len(truth), 'detected': len(lines),
                          'truth_words': len(words) if words else None, 'words_in_runs': used,
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
    paired = lambda hand, p: (hand_dir(hand) / 'pairs' / f'{p["page"]}.json').exists()   # noqa: E731
    bw = [p for p in hand_pages('blackwell') if paired('blackwell', p)]   # a page the guard stopped is left out
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
        with (RUN / 'train' / 'guard.jsonl').open('a') as log:
            row = guarded([str(KETOS), '-d', pl['device'], '--workers', '0', '-s', str(SEED), 'train', '-f', 'page', '-i', str(base),
                           '--resize', 'union', '--schedule', 'constant', '--warmup', '0', '-r', str(LRATE),
                           '-B', str(BATCH_LINES), '-t', str(d / 'train.txt'), '-e', str(d / 'val.txt'), '-q', 'early',
                           '--min-epochs', str(MIN_EPOCHS), '--lag', str(LAG), '-N', str(MAX_EPOCHS),
                           '-o', str(d / 'model')], log, name, 'train', cap=TRAIN_CAP_GB, out=d / 'ketos.log')
        secs = row['seconds']
        if row['rc']:
            raise SystemExit(f'{name}: ketos exited {row["rc"]} (killed: {row["killed"]}); see {d / "ketos.log"}')
        best = best_model(d)
        (d / 'done.json').write_text(json.dumps({'seconds': round(secs, 1), 'best': str(best), 'lines': len(pl['keys']),
                                                 'device': pl['device'], 'peak_gb': row['peak_gb']}, indent=1))
        print(f'{name}: {secs / 60:.1f} min, best {best.name}')


MIN_EPOCHS, LAG, MAX_EPOCHS = 10, 5, 60
# Fine-tuning a few dozen lines: the PP-OCRv6 config's defaults (cosine over 100 epochs, 1,000 warmup steps,
# batch 64) are for training from scratch, and its cosine schedule cannot run under early stopping.
LRATE, BATCH_LINES = 1e-4, 8
# --workers 0: ketos's DataLoader worker is a fork of the trainer, and the memory guard charges its shared pages again.
TRAIN_CAP_GB = 8.


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
        with (d / 'eval-guard.jsonl').open('a') as log:
            ocr_batches([(seg_xml(pl['hand'], pages[pg]), d / 'read' / f'{pg}.txt') for pg in todo], m, log,
                        ['-f', 'page'])
        print(f'{name}: {len(todo)} read')


# ---- report -------------------------------------------------------------------------------------------------------

def _texts(d, ids):
    return {i: (d / f'{i}.txt').read_text().strip() for i in ids if (d / f'{i}.txt').exists()}


def vision_text(i):
    """Apple Vision's own reading of the lines PP-OCRv6 read in the vision arm (layout_order.swift `lines`)."""
    return '\n'.join(ln.get('text', '') for ln in json.loads((RUN / 'vision' / f'{i}.json').read_text())['lines'])


def page_text(xml):
    """A kraken PAGE XML reading -> its lines' text, one a line."""
    return '\n'.join(ln['text'] for ln in read_page(xml)[3] if ln['text'].strip())


def table(sources, ids, truth, stratum, ours, lead_n=6):
    """Per route: mean NES (points) over `ids` (a missing or empty reading scores 0) by stratum; a route enters only
    when it read every page. -> (rows sorted by NES, per-page scores by route)."""
    import ocr_panel_score as S
    per = {}
    for name, texts in sources.items():
        if not all(i in texts for i in ids) and name not in ours:
            continue
        per[name] = {i: 100 * S.score(truth(i), texts.get(i) or '', stratum(i))['nes'] for i in ids}
    rows = []
    for name, sc in per.items():
        by = collections.defaultdict(list)
        for i, v in sc.items():
            by[stratum(i)].append(v)
        rows.append({'route': name, 'n': len(sc), 'nes': sum(sc.values()) / len(sc),
                     'strata': {k: sum(v) / len(v) for k, v in sorted(by.items())},
                     'empty': sum(not (sources[name].get(i) or '').strip() for i in ids)})
    return sorted(rows, key=lambda r: -r['nes']), per


def pairs_against(per, ours, ids):
    import ocr_panel_score as S
    out = {}
    for o in ours:
        for other in per:
            if other != o:
                d = S.paired([per[o][i] for i in ids], [per[other][i] for i in ids])
                out[f'{o} vs {other}'] = {k: round(v, 2) if isinstance(v, float) else v for k, v in d.items()}
    return out


def guard_stats(path):
    rows = [json.loads(ln) for ln in path.open()] if path.exists() else []
    out = {}
    size = lambda r: int(r['step'][9:]) if r['step'].startswith('ocr-batch') else 1   # noqa: E731
    kind = lambda r: 'ocr' if r['step'].startswith('ocr') else r['step']               # noqa: E731
    for step in sorted({kind(r) for r in rows}):
        rr = [r for r in rows if kind(r) == step and not r['killed'] and r['rc'] == 0]
        if rr:
            secs = sorted(r['seconds'] / size(r) for r in rr)
            out[step] = {'calls': len(rr), 'pages': sum(size(r) for r in rr), 'median_s': round(secs[len(secs) // 2], 1),
                         'peak_gb': max(r['peak_gb'] for r in rr)}
    out['killed'] = [r['page'] for r in rows if r['killed']]
    out['failed'] = sorted({r['page'] for r in rows if r['rc'] and not r['killed']})
    return out


def named(sources):
    """{(route, family): texts} -> {name: texts}, the family added only where a route name repeats."""
    names = [r for r, _ in sources]
    return {(r if names.count(r) == 1 else f'{r} ({fam})'): t for (r, fam), t in sources.items()}


def cmd_report(_):
    import ocr_panel as P
    import ocr_rescore as RS
    ours = ('ppocrv6-kraken-blla', 'ppocrv6-kraken-vision')
    # The public L1-L3, ranked (OCR-1: hands are ranked here, where the truth is the source's own).
    R.MANIFEST = RESULTS / 'bench-corpus' / 'manifest.jsonl'
    rows = [r for r in R.frozen() if r['stratum'] in STRATA]
    by = {R.job_id(r): r for r in rows}
    ids = sorted(by)
    src = {k: {i: t for i, t in v.items() if i in by} for k, v in named(RS.public_sources(R.frozen())).items()}
    src[ours[0]] = _texts(RUN / 'zero' / 'blla-public', ids)
    src[ours[1]] = _texts(RUN / 'zero' / 'vision-public', ids)
    src['apple-vision (lines)'] = {i: vision_text(i) for i in ids if (RUN / 'vision' / f'{i}.json').exists()}
    pub, pub_per = table(src, ids, lambda i: Path(by[i]['truth']).read_text(), lambda i: by[i]['stratum'], ours)
    pub_pairs = pairs_against({k: v for k, v in pub_per.items() if k in ours or k in [r['route'] for r in pub[:4]]
                               or k in ('ppocrv6-medium', 'apple-vision (lines)', 'lightonocr3-4b')}, ours, ids)
    # The owner's 21 hand and mixed pages (truth after W46.ocr-hands-rescore's corrections).
    kinds = owner_kinds()
    own_ids = owner_pages()
    osrc = named(RS.owner_sources())
    osrc[ours[0]] = _texts(RUN / 'zero' / 'blla-hands', own_ids)
    osrc[ours[1]] = _texts(RUN / 'zero' / 'vision-hands', own_ids)
    own, own_per = table(osrc, own_ids, owner_truth, lambda p: 'S0', ours)
    hand_ids = [p for p in own_ids if kinds[p] == 'handwritten']
    own_hand = {r: sum(v[p] for p in hand_ids) / len(hand_ids) for r, v in own_per.items()}
    own_mixed = {r: sum(v[p] for p in own_ids if p not in hand_ids) / max(1, len(own_ids) - len(hand_ids))
                 for r, v in own_per.items()}
    own_pairs = pairs_against({k: v for k, v in own_per.items() if k in ours or k in [r['route'] for r in own[:4]]
                               or k in ('ppocrv6-medium', 'apple-vision', 'lightonocr-3-4b-mlx8', 'qwen3.5-9b-mlx4')},
                              ours, own_ids)
    # The fine-tunes: held-out pages, tuned against base (both on blla lines).
    import ocr_panel_score as S
    tunes = []
    try:
        trained = plans()
    except FileNotFoundError:      # no pairs yet: the zero-shot tables alone
        trained = {}
    for name, pl in trained.items():
        d = RUN / 'train' / name
        if not (d / 'done.json').exists():
            continue
        done = json.loads((d / 'done.json').read_text())
        pages = {p['page']: p for p in hand_pages(pl['hand'])}
        tuned, base = [], []
        for pg in pl['test']:
            f = d / 'read' / f'{pg}.txt'
            if not f.exists():
                continue
            t = page_truth(pages[pg])
            tuned.append(100 * S.score(t, f.read_text())['nes'])
            base.append(100 * S.score(t, page_text(hand_dir(pl['hand']) / 'base' / f'{pg}.xml'))['nes'])
        if tuned:
            pd = S.paired(tuned, base)
            tunes.append({'name': name, 'hand': pl['hand'], 'n': pl['n'], 'device': pl['device'],
                          'minutes': round(done['seconds'] / 60, 1), 'peak_gb': done.get('peak_gb'),
                          'pages': len(tuned), 'tuned': sum(tuned) / len(tuned), 'base': sum(base) / len(base),
                          'delta': pd['delta'], 'lo': pd['lo'], 'hi': pd['hi']})
    timing = {'blla-public': guard_stats(RUN / 'zero' / 'blla-public-guard.jsonl'),
              'vision': guard_stats(RUN / 'zero' / 'vision-guard.jsonl'),
              'train': guard_stats(RUN / 'train' / 'guard.jsonl')}
    pairs_stats = {h: json.loads((hand_dir(h) / 'pairs.json').read_text()) for h in ('owner', 'blackwell')
                   if (hand_dir(h) / 'pairs.json').exists()}
    out = {'public': pub, 'public_pairs': pub_pairs, 'owner': own, 'owner_hand': own_hand, 'owner_mixed': own_mixed,
           'owner_pairs': own_pairs, 'tunes': tunes, 'timing': timing,
           'pairs': {h: {'pages': len(v), 'truth_lines': sum(s['truth_lines'] for s in v),
                         'kept': sum(s['kept'] for s in v)} for h, v in pairs_stats.items()},
           'sets': {'public': len(ids), 'owner': len(own_ids), 'owner_hand': len(hand_ids)}}
    (RESULTS / 'ocr-ppocrv6-hands.json').write_text(json.dumps(out, indent=1))
    write_md(out)
    print(f'{RESULTS / "ocr-ppocrv6-hands.md"}: {len(pub)} public routes, {len(own)} owner routes, {len(tunes)} tunes')


def f1(x):
    return '' if x is None else f'{x:.1f}'


def write_md(o):
    L = ['# kraken PP-OCRv6 as the laptop handwriting route (W46.ocr-ppocrv6-hands)', '',
         'Generated by `scripts/segbench/ocr_ppocrv6_hands.py report` from saved readings. Kiessling\'s kraken port of '
         'PP-OCRv6 medium (Zenodo 10.5281/zenodo.21788410, kraken 7.1.1, CPU) read on two line sources: kraken blla '
         'baselines (`ppocrv6-kraken-blla`) and Apple Vision\'s line boxes as rectangles (`ppocrv6-kraken-vision`); '
         '`apple-vision (lines)` is Vision\'s own text of those lines (the cached Vision page readings do not cover '
         'L1-L3); '
         'then fine-tuned on corrected lines of one hand. `ppocrv6-medium` is the native PaddleOCR pipeline (its own '
         'detector) from FarmShare. Mean NES in points; a missing or empty reading scores 0. No money; no text in the '
         'repo.', '']
    L += [f'## The public L1-L3 ({o["sets"]["public"]} pages), where hands are ranked', '',
          '| route | NES | L1 | L2 | L3 | empty |', '|---|---:|---:|---:|---:|---:|']
    for r in o['public']:
        st = r['strata']
        L.append(f'| {r["route"]} | {f1(r["nes"])} | {f1(st.get("L1"))} | {f1(st.get("L2"))} | {f1(st.get("L3"))} '
                 f'| {r["empty"]} |')
    L += ['', 'Paired differences (ours minus the other route, 95% bootstrap interval over the pages):', '',
          '| pair | delta | interval | p |', '|---|---:|---|---:|']
    L += [f'| {k} | {v["delta"]:+.2f} | {v["lo"]:+.2f} to {v["hi"]:+.2f} | {v["p"]:.4f} |'
          for k, v in o['public_pairs'].items()]
    L += ['', f'## The owner\'s {o["sets"]["owner"]} hand and mixed pages of the 96', '',
          'Truth after W46.ocr-hands-rescore\'s corrections (the owner\'s blind sheet of 2026-10-31 on the hand '
          'places; ten places stay unresolved, scored on the truth\'s reading). Not a ranking of hands (OCR-1); '
          f'the {o["sets"]["owner_hand"]} handwritten pages and the mixed pages apart.', '',
          '| route | all | handwritten | mixed | empty |', '|---|---:|---:|---:|---:|']
    for r in o['owner']:
        L.append(f'| {r["route"]} | {f1(r["nes"])} | {f1(o["owner_hand"][r["route"]])} | '
                 f'{f1(o["owner_mixed"][r["route"]])} | {r["empty"]} |')
    L += ['', '| pair | delta | interval | p |', '|---|---:|---|---:|']
    L += [f'| {k} | {v["delta"]:+.2f} | {v["lo"]:+.2f} to {v["hi"]:+.2f} | {v["p"]:.4f} |'
          for k, v in o['owner_pairs'].items()]
    L += ['', '## Fine-tuned on one hand', '',
          'Training lines are the hand\'s own truth lines, paired to blla lines by a monotone alignment on the base '
          f'model\'s reading (character error at most {MAX_CER}, lengths within {LEN_RATIO}x); {VAL_LINES} pool lines '
          'pick the epoch (early stopping); scored on held-out pages read on blla lines, tuned against the base model '
          'on the same lines. '
          + '; '.join(f'{h}: {v["kept"]} of {v["truth_lines"]} truth lines paired over {v["pages"]} pages'
                      for h, v in o['pairs'].items()) + '.', '',
          '| training | lines | device | minutes | peak GB | held-out pages | base | tuned | delta | interval |',
          '|---|---:|---|---:|---:|---:|---:|---:|---:|---|']
    for t in o['tunes']:
        L.append(f'| {t["name"]} | {t["n"]} | {t["device"]} | {t["minutes"]} | {t["peak_gb"]} | {t["pages"]} | '
                 f'{f1(t["base"])} | {f1(t["tuned"])} | {t["delta"]:+.2f} | {t["lo"]:+.2f} to {t["hi"]:+.2f} |')
    tm = o['timing']
    L += ['', '## Seconds and memory (M3 Pro, 18 GB, CPU, one page a kraken call)', '',
          '| step | calls | pages | median seconds a page | peak GB a call |', '|---|---:|---:|---:|---:|']
    for k, v in tm.items():
        for step, s in v.items():
            if isinstance(s, dict):
                L.append(f'| {k} {step} | {s["calls"]} | {s["pages"]} | {s["median_s"]} | {s["peak_gb"]} |')
    killed = sorted({p for v in tm.values() for p in v.get('killed', [])})
    L += ['', f'Pages stopped by the {PAGE_CAP_GB:g} GB per-call guard: {", ".join(killed) or "none"}. A call includes '
          'loading the model, so one-page calls overstate seconds a page; blla is one page a call because two batched '
          'four-worker runs took the Mac down on 2026-10-31; reading is batched ten pages a call.']
    L += ['', '## Measurement card', '',
          '- **Truth.** Public L1-L3: the sources\' own transcriptions (By the People crowd text, Bentham '
          'Transcribe), not drafted by any scored route. Owner pages: drafted by Claude Opus 5.5 and Gemini 3.8 '
          'Flash, the hand places checked blind by the owner (W46.ocr-hands-rescore); typed and mixed lines not '
          're-checked, so Gemini 3.8 Flash\'s rows there are agreement with its own draft. Blackwell fine-tune truth: '
          'By the People\'s transcriptions of the volume. No line was drawn or corrected by a Claude subagent.',
          '- **Selection.** The 895\'s frozen L1-L3 strata; the owner\'s pages by the panel\'s kind label; the '
          'Blackwell volume pages by a seeded shuffle of the volume\'s pages with at least '
          f'{MIN_LINES} truth lines, none in the 895; the owner\'s fine-tune hand is the folder with most hand pages. '
          'None chosen by a tested route.',
          '- **Comparison.** Every row reads the same pages; comparator readings are the cached ones '
          '(`ocr_rescore.py` sources), scored by `ocr_panel_score.score` with the stratum\'s settings. A route that '
          'did not read every page is left out of a table rather than scored on fewer.',
          '- **Noise.** kraken on CPU is deterministic, so the rerun floor of our rows is 0; the comparators\' rerun '
          'floor is ocr-rerun-noise.md\'s 0.49 points. A paired interval across 0 is a tie. Fine-tune rows rest on '
          'few held-out pages (one per fold for the owner\'s hand), so their intervals are wide.',
          '- **Scope.** Line recognition only: placement of these lines is W46.place-hands. The Qwen few-line '
          'prompting arm (cluster) and the Gemini arm (W46.ocr-ppocrv6-hands-paid) are not here.', '']
    (RESULTS / 'ocr-ppocrv6-hands.md').write_text('\n'.join(L))


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
