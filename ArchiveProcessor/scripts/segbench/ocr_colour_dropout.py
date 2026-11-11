#!/usr/bin/env python3
"""W46.ocr-input-colour-dropout — a stamp in a second ink, dropped from the OCR input only: does it help the readers,
and where does it harm?

Owner, 2026-11-10 (point 6): "UIUC 156" tests how well the readers resolve a red stamp. Stage 02 allows a separate,
transient OCR input (R02.2) and applies nothing today (R02.1). This measures one such input.

  V=~/.local/share/visionocr-ocrlab/venv/bin/python          # numpy, scipy, PIL
  python3 ops/autonomous/heavy-run.py run -- $V ocr_colour_dropout.py survey
                       the colour cue (colour_dropout.cue) on every JPEG original of the 5,000-file Reader sample,
                       the sample's UIUC pages from their HEIC originals and UIUC 00156
  $V ocr_colour_dropout.py select      the stamped set (STAMPS pages, the cue's class 'stamp', 00156 forced in) and the
                       controls (CONTROLS pages, class 'control'), ranked by the cue, at most PER_COLL per collection
  python3 ops/autonomous/heavy-run.py run -- $V ocr_colour_dropout.py images
                       raw (2,400 px, JPEG 90, the panel's size), dropout and the mark layer for every selected page,
                       and the gate on the owner's 96 (dropout and mark layer where it fires, and ungated dropout on
                       all 96 for Vision)
  python3 ops/autonomous/heavy-run.py run -- $V ocr_colour_dropout.py vision     Apple Vision (segbench-dewarp lines)
  /usr/local/bin/python3 ocr_colour_dropout.py gemini [--probe]
                       Gemini 3.7 Flash through the Stanford gateway: the truth draft on the selected pages, then raw and
                       dropout on them and dropout on the 96's gated pages (raw on the 96 is W46.fix-ocr-scorers-paid's)
  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy \\
      python ocr_colour_dropout.py report      segbench-results/ocr-colour-dropout.md and .json
  $V ocr_colour_dropout.py sheet       the owner's boxed check sheet for the disputed lines

Selection is by colour, never by a reader: the cue reads pixels only. The truth draft is Gemini's, asked for the
page's text (the panel prompt, stamps included in place) and for each coloured mark's colour and text apart; it is
the same model family as one scored reader, which the measurement card says, and the owner checks the disputed
lines only. The 96 keep their owner truth.

Scored: NES and the bag-of-words missed and added words against the truth (ocr_panel_score.score); the body's missed
words with the marks' own words taken out of the truth (what the stamp cost the text under it); and, for Vision,
the lines that cross the mark (fewer, longer lines are whole lines; fragments are many short ones). The dropout
route's output is the dropout reading followed by the mark layer's reading, so the mark's text is kept, as a mark.

Writes CACHE only (images, readings, replies; rebuildable) and the committed results (page keys, sample-relative
paths, numbers). Reads the sample copy and the UIUC originals; never writes the corpus. The gateway is real money:
CAP bounds this item's whole spend and the ledger is CACHE/gateway/calls.jsonl.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]

RESULTS = HERE.parents[1] / 'segbench-results'
REH = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
CACHE = REH / 'colour-dropout'
SAMPLE = REH / 'reader-sample'
UIUC = Path.home() / 'Desktop/Google Drive/Archival Photos JPEGS/UIUC'
OWNER = 'uiuc-00156'
BIN = REH / 'segbench/bin/segbench-dewarp'
PANEL_IMAGES = REH / 'ocr-panel-local/images'          # ocr_panel.CACHE: the 96's frozen 2,400 px raw images
STAMPS, CONTROLS, PER_COLL, SEED = 40, 20, 5, 1110
SIDE = 2400
CAP = 2.00                                             # the item's whole gateway spend; filed at under $2
REPORT, BENCH = RESULTS / 'ocr-colour-dropout.md', RESULTS / 'ocr-colour-dropout.json'


def survey_path():
    return CACHE / 'survey.json'


# ---------------------------------------------------------------- survey and selection
def sample_images():
    """(key, image path, collection, rel) for the sample's JPEG originals and its UIUC pages, plus 00156."""
    import place_curved as PC
    out = [r for r in PC.sample_images() if r[1].suffix.lower() in ('.jpg', '.jpeg')]
    nums = set(PC.uiuc_numbers()) | {OWNER.split('-')[1]}
    for n in sorted(nums):
        src = UIUC / f'UIUC — {n}.HEIC'
        if src.exists():
            out.append((f'uiuc-{n}', src, 'UIUC', f'UIUC/UIUC — {n}.HEIC'))
    return out


def readable(path):
    """A JPEG for PIL: the file itself, or a HEIC original copied to JPEG in the cache (the corpus is only read)."""
    path = Path(path)
    if path.suffix.lower() != '.heic':
        return path
    dst = CACHE / 'src' / (hashlib.sha1(str(path).encode()).hexdigest()[:16] + '.jpg')
    if not dst.exists():
        dst.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '92', str(path), '--out', str(dst)],
                       check=True, stdout=subprocess.DEVNULL)
    return dst


def _cue_one(row):
    import colour_dropout as D
    key, path, coll, rel = row
    try:
        c = D.cue(D.load(readable(path)))
    except Exception as e:  # noqa: BLE001 — an unreadable file is reported, not fatal
        return {'key': key, 'coll': coll, 'rel': rel, 'error': repr(e)[:200]}
    return {'key': key, 'coll': coll, 'rel': rel, **c}


def survey():
    from concurrent.futures import ProcessPoolExecutor
    rows = sample_images()
    with ProcessPoolExecutor(4) as ex:
        out = list(ex.map(_cue_one, [(k, str(p), c, r) for k, p, c, r in rows], chunksize=16))
    CACHE.mkdir(parents=True, exist_ok=True)
    survey_path().write_text(json.dumps(out, indent=0))
    print(len(out), 'images;', Counter(r.get('class') for r in out))


def rank_key(r):
    """Stamps: the most text under the most mark first; controls: the clearest coloured text first. Ties broken by a
    seeded hash of the key, so the order does not follow the file system."""
    tie = hashlib.sha256(f'{SEED}:{r["key"]}'.encode()).hexdigest()
    if r['class'] == 'stamp':
        return (-r['over'] * min(r['mark_frac'], 0.03), tie)
    return (-r['colour_share'] * min(r['mark_frac'], 0.03), tie)


def draw(rows, cls, n, forced=()):
    pool = sorted((r for r in rows if r.get('class') == cls), key=rank_key)
    chosen, per = [r for r in pool if r['key'] in forced], Counter()
    for r in chosen:
        per[r['coll']] += 1
    for r in pool:
        if len(chosen) >= n:
            break
        if r in chosen or per[r['coll']] >= PER_COLL:
            continue
        chosen.append(r)
        per[r['coll']] += 1
    return chosen, len(pool)


def select():
    import colour_dropout as D
    rows = json.loads(survey_path().read_text())
    owner = next(r for r in rows if r['key'] == OWNER)
    if owner.get('class') != 'stamp':
        raise SystemExit(f'{OWNER} is not a stamp page under the cue: {owner}')
    stamps, n_s = draw(rows, 'stamp', STAMPS, forced={OWNER})
    controls, n_c = draw(rows, 'control', CONTROLS)
    sel = {'seed': SEED, 'thresholds': {k: getattr(D, k) for k in (
               'SURVEY', 'SAT', 'INK_CHROMA', 'INK_LUM', 'NEAR', 'BLOB', 'MIN_MARK', 'MAX_MARK', 'CONC',
               'STAMP_OVER', 'STAMP_SHARE', 'STAMP_INK', 'CONTROL_SHARE', 'CONTROL_PIECES')},
           'surveyed': len(rows), 'errors': sum('error' in r for r in rows),
           'pool': {'stamp': n_s, 'control': n_c},
           'stamp': stamps, 'control': controls}
    (CACHE / 'selection.json').write_text(json.dumps(sel, indent=1))
    print(f'{len(rows)} surveyed; stamp pool {n_s} -> {len(stamps)}, control pool {n_c} -> {len(controls)}')
    print('stamp collections', Counter(r['coll'] for r in stamps).most_common())
    print('control collections', Counter(r['coll'] for r in controls).most_common())


def selection():
    return json.loads((CACHE / 'selection.json').read_text())


def source(key):
    """The original image path of a selected key."""
    if key.startswith('uiuc-'):
        return UIUC / f'UIUC — {key.split("-")[1]}.HEIC'
    rel = next(r['rel'] for s in ('stamp', 'control') for r in selection()[s] if r['key'] == key)
    return SAMPLE / rel


# ---------------------------------------------------------------- images
ARMS = ('raw', 'dropout', 'mark')


def keys():
    s = selection()
    return [r['key'] for r in s['stamp']], [r['key'] for r in s['control']]


def panel_pages():
    import ocr_panel as P
    return [r['page'] for r in P.rows() if r['page'] not in P.AGREEMENT]


def image(arm, key):
    """The arm's image: the selected pages' under CACHE/img, the 96's raw image is the panel's frozen one."""
    if arm == 'raw' and key.startswith('p') and key[1:].isdigit():
        return PANEL_IMAGES / (key + '-original.jpg')
    return CACHE / 'img' / arm / (key + '.jpg')


def gate_path():
    return CACHE / 'gate96.json'


def _save(arr, dest):
    from PIL import Image
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix('.tmp')
    Image.fromarray(arr).save(tmp, 'JPEG', quality=90)
    tmp.replace(dest)


def _arms(key, raw_path, force):
    """Writes dropout (when `force` or the gate fires) and the mark layer beside a raw image; returns the cue and
    the channel chosen."""
    import colour_dropout as D
    from PIL import Image
    small = D.load(raw_path)
    c = D.cue(small)
    fire = c['class'] == 'stamp'
    ch = None
    if fire or force:
        ch, _ = D.channel(small)
    if ch is not None:
        full = __import__('numpy').asarray(Image.open(raw_path).convert('RGB'))
        _save(D.dropout(full, ch), image('dropout', key))
        lines_path('dropout', key).unlink(missing_ok=True)   # a reading of an earlier dropout image is stale
        _save(D.mark_layer(full, ch), image('mark', key))
        lines_path('mark', key).unlink(missing_ok=True)
    return {**c, 'fires': fire, 'channel': ch}


def images():
    from PIL import Image, ImageOps
    stamps, controls = keys()
    info = {}
    for k in stamps + controls:
        dst = image('raw', k)
        if not dst.exists():
            im = ImageOps.exif_transpose(Image.open(readable(source(k)))).convert('RGB')
            s = SIDE / max(im.size)
            if s < 1:
                im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
            dst.parent.mkdir(parents=True, exist_ok=True)
            im.save(dst, 'JPEG', quality=90)
        info[k] = _arms(k, dst, force=True)
    (CACHE / 'arms.json').write_text(json.dumps(info, indent=1))
    gate = {}
    for p in panel_pages():
        g = _arms(p, image('raw', p), force=True)   # ungated dropout for Vision; the gate is g['fires']
        gate[p] = g
    gate_path().write_text(json.dumps(gate, indent=1))
    print(len(info), 'selected pages;', sum(g['fires'] for g in gate.values()), 'of', len(gate),
          'of the 96 fire the gate;', sum(g['channel'] is not None for g in gate.values()), 'have a mark at all')
    print('channels on the selected pages', Counter(v['channel'] for v in info.values()))


# ---------------------------------------------------------------- Vision
def lines_path(arm, key):
    return CACHE / 'lines' / arm / (key + '.json')


def all_keys():
    stamps, controls = keys()
    return stamps + controls + panel_pages()


def vision():
    rows = [(image(a, k), lines_path(a, k)) for a in ARMS for k in all_keys()]
    rows = [r for r in rows if r[0].exists() and not r[1].exists()]
    if rows:
        jobs = CACHE / 'lines-jobs.tsv'
        jobs.write_text(''.join(f'{a}\t{b}\n' for a, b in rows))
        for _, b in rows:
            b.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(BIN), 'lines', str(jobs)], check=True)
    print(len(rows), 'images read')


def vision_lines(arm, key):
    f = lines_path(arm, key)
    return json.loads(f.read_text()) if f.exists() else None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('cmd', choices=['survey', 'select', 'images', 'vision'])
    a = ap.parse_args()
    {'survey': survey, 'select': select, 'images': images, 'vision': vision}[a.cmd]()


if __name__ == '__main__':
    main()
