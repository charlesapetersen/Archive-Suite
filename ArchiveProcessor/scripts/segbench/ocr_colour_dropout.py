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


# ---------------------------------------------------------------- the gateway
GW = CACHE / 'gateway'
DRAFT_NOTE = ('You are given two photographs of the same page. The first is the photograph as taken. The second is '
              'one colour channel of it, in which a stamp or mark in coloured ink is faded so that the text under it '
              'is easier to read. Transcribe the page as it is in the first photograph, stamps included; use the '
              'second only to read text that a coloured mark covers.\n\n')
MARKS_FORM = ('MARKS:\n<one line for each stamp, seal, highlighting or annotation in coloured ink (red, blue, green, '
              'purple, orange, yellow and so on; not black, grey or a dark blue-black), as "<colour>: <its text, or '
              '- if it has none>"; or the single word none>\nTEXT:\n<the transcription>')


def _gateway():
    import gateway_gemini as G
    G.CACHE, G.CAP = GW, CAP
    return G


def panel_prompt():
    return _gateway().panel_manifest()[0]['prompt']


def draft_prompt():
    p = panel_prompt()
    if 'TEXT:\n<the transcription>' not in p:
        raise SystemExit('the panel prompt changed shape')
    return DRAFT_NOTE + p.replace('TEXT:\n<the transcription>', MARKS_FORM)


def parse_draft(raw):
    """{'kind', 'table', 'text', 'marks': [(colour, text)]} or None."""
    import re
    import ocr_truth as T
    if not raw:
        return None
    m = re.search(r'\n\s*MARKS:[ \t]*\n?(.*?)\n\s*TEXT:', raw, re.S | re.I)
    if not m:
        return None
    marks = []
    for ln in m.group(1).strip().splitlines():
        ln = ln.strip().lstrip('-*• ').strip()
        if not ln or ln.lower() == 'none':
            continue
        colour, _, text = ln.partition(':')
        text = text.strip().strip('"')
        marks.append((colour.strip().lower(), '' if text == '-' else text))
    d = T.parse_draft(raw[:m.start()] + '\nTEXT:' + raw[m.end():])
    return {**d, 'marks': marks} if d else None


def reply_path(kind, key):
    return GW / kind / (key + '.json')


def gemini_jobs():
    """(kind, key, images) for every call: the draft (raw and dropout together), raw, dropout and the mark layer on
    the 60, and dropout and the mark layer on the 96's pages where the gate fires (their raw reading is
    W46.fix-ocr-scorers-paid's)."""
    stamps, controls = keys()
    jobs = [('draft', k, (image('raw', k), image('dropout', k))) for k in stamps + controls]
    for kind in ('raw', 'dropout', 'mark'):
        jobs += [(kind, k, (image(kind, k),)) for k in stamps + controls]
    gate = json.loads(gate_path().read_text())
    for kind in ('dropout', 'mark'):
        jobs += [(kind, p, (image(kind, p),)) for p, g in gate.items() if g['fires']]
    return jobs


def gemini(probe=False):
    import base64
    G = _gateway()
    plain_body = G.body

    def body(images, prompt):
        if isinstance(images, bytes):
            return plain_body(images, prompt)
        b = plain_body(images[0], prompt)
        b['messages'][0]['content'][1:1] = [
            {'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,' + base64.b64encode(i).decode()}}
            for i in images[1:]]
        b['reasoning_effort'] = 'medium'   # the truth draft reads more carefully than a scored reading
        return b

    G.body = body
    todo = [j for j in gemini_jobs() if not reply_path(j[0], j[1]).exists()]
    if probe:
        todo = [j for j in todo if j[1] == OWNER][:2]
    for kind in ('draft', 'raw', 'dropout', 'mark'):
        part = [j for j in todo if j[0] == kind]
        if not part:
            continue
        prompt = draft_prompt() if kind == 'draft' else panel_prompt()
        G.run(f'colour-dropout-{kind}',
              [(f'{kind}/{k}', tuple(p.read_bytes() for p in ims) if kind == 'draft' else ims[0].read_bytes(),
                reply_path(kind, k)) for kind, k, ims in part], prompt)
        if kind == 'draft':
            bad = [k for _, k, _ in part if not parse_draft((json.loads(reply_path('draft', k).read_text())
                                                            if reply_path('draft', k).exists() else {}).get('raw'))]
            print('drafts without a MARKS block or text:', bad)
    print(f'${G.spent():.4f} of ${CAP} spent on this item ({G.billed_note(G.ledger())})')


def gemini_text(kind, key):
    """A Gemini reading: the 96's raw is W46.fix-ocr-scorers-paid's; '' for a failed or unparsed reply."""
    G = _gateway()
    if kind == 'raw' and key.startswith('p') and key[1:].isdigit():
        m, panel = G.panel_manifest()
        j = next(j for j in panel if j['page'] == key)
        f = G.REHEARSAL / 'gateway-gemini' / 'panel' / (j['id'] + '.json')
    else:
        f = reply_path(kind, key)
    if not f.exists():
        return None
    p = G.parsed(json.loads(f.read_text()))
    return p['text'] if p else ''


# ---------------------------------------------------------------- report
READERS = {'apple-vision': 'Apple Vision (accurate, macOS 27.2)', 'gemini3.7-flash-gw': 'Gemini 3.7 Flash (gateway)'}
HELP = 0.02          # a page helped or harmed: NES moved by more than this
UNDER = 0.02         # a Vision line is under the mark when the mark covers this share of its box


def draft(key):
    f = reply_path('draft', key)
    return parse_draft(json.loads(f.read_text()).get('raw')) if f.exists() else None


def truth(key):
    """(text, marks' words) for a page: the 96's owner truth with no marks recorded, else the gateway draft."""
    import ocr_panel as P
    if key.startswith('p') and key[1:].isdigit():
        return (P.TRUTH / 'truth' / (key + '.txt')).read_text(), []
    d = draft(key)
    return (d['text'], [t for _, t in d['marks'] if t]) if d else (None, [])


def reading(reader, kind, key):
    if reader == 'apple-vision':
        v = vision_lines(kind, key)
        return '\n'.join(ln['text'] for ln in v['lines']) if v else None
    return gemini_text(kind, key)


def bag(text):
    import ocr_panel_score as S
    return Counter(S.tokens(S.normal(re_illegible(text))))


def re_illegible(text):
    import re
    return re.sub(r'\[illegible\]', '', text, flags=re.I)


def under_mark(key, arm):
    """Vision's lines on `arm` that cross the mark (the mark layer's dark pixels) and the words on them."""
    import numpy as np
    from PIL import Image
    v = vision_lines(arm, key)
    m = image('mark', key)
    if not v or not m.exists():
        return None
    mask = np.asarray(Image.open(m).convert('L')) < 128
    H, W = mask.shape
    ii = np.pad(mask.cumsum(0).cumsum(1), ((1, 0), (1, 0)))
    n = w = 0
    for ln in v['lines']:
        q = np.asarray(ln['quad'], float) * [W, H]
        x0, x1 = int(max(0, q[:, 0].min())), int(min(W, q[:, 0].max()))
        y0, y1 = int(max(0, q[:, 1].min())), int(min(H, q[:, 1].max()))
        area = (x1 - x0) * (y1 - y0)
        if area <= 0:
            continue
        inside = ii[y1, x1] - ii[y0, x1] - ii[y1, x0] + ii[y0, x0]
        if inside >= UNDER * area:
            n += 1
            w += len(ln['text'].split())
    return n, w


def page_rows():
    """One row per (reader, set, page): raw, dropout alone, and the route (dropout, then the mark layer's reading),
    each scored against the page's truth; the body's missed words with the marks' words taken out."""
    import ocr_panel_score as S
    stamps, controls = keys()
    gate = json.loads(gate_path().read_text())
    sets = [('stamp', k) for k in stamps] + [('control', k) for k in controls] + [('96', p) for p in panel_pages()]
    rows = []
    for reader in READERS:
        for st, k in sets:
            t, marks = truth(k)
            raw = reading(reader, 'raw', k)
            if t is None or raw is None:
                continue
            fires = gate[k]['fires'] if st == '96' else None
            drop = reading(reader, 'dropout', k) if (st != '96' or fires or reader == 'apple-vision') else None
            if drop is None:
                if st == '96' and reader != 'apple-vision' and not fires:
                    drop = raw        # the gate does not fire: the input is raw, the reading raw's
                else:
                    continue          # not read yet
            mark = reading(reader, 'mark', k) if (st != '96' or fires) else ''
            route = drop + ('\n' + mark if mark else '')
            body = bag(t) - bag('\n'.join(marks))
            r = {'reader': reader, 'set': st, 'page': k, 'fires': fires, 'marks': len(marks),
                 'marked': bool(draft(k)['marks']) if st != '96' else None,
                 'body_words': sum(body.values())}
            for arm, text in (('raw', raw), ('dropout', drop), ('route', route)):
                s = S.score(t, text)
                r[arm] = round(s['nes'], 5)
                r[arm + '_missed'], r[arm + '_added'] = s['missed'], s['added']
                r[arm + '_body_missed'] = sum((body - bag(text)).values())
            r['words'] = S.score(t, raw)['words']
            if reader == 'apple-vision' and st != '96':
                for arm in ('raw', 'dropout'):
                    u = under_mark(k, arm)
                    r[arm + '_lines_under'], r[arm + '_words_under'] = u if u else (None, None)
            rows.append(r)
    return rows


def summary(rr, a='route', b='raw'):
    import ocr_panel_score as S
    if not rr:
        return None
    pd = S.paired([r[a] for r in rr], [r[b] for r in rr])
    bw = sum(r['body_words'] for r in rr) or 1
    return {'n': len(rr), 'raw': round(100 * sum(r[b] for r in rr) / len(rr), 2),
            a: round(100 * sum(r[a] for r in rr) / len(rr), 2),
            'delta': round(100 * pd['delta'], 2), 'lo': round(100 * pd['lo'], 2), 'hi': round(100 * pd['hi'], 2),
            'p': round(pd['p'], 4),
            'helped': sum(r[a] - r[b] > HELP for r in rr), 'harmed': sum(r[b] - r[a] > HELP for r in rr),
            'body_missed_raw': round(100 * sum(r[b + '_body_missed'] for r in rr) / bw, 2),
            'body_missed_' + a: round(100 * sum(r[a + '_body_missed'] for r in rr) / bw, 2)}


def chart_rows(rows):
    """The 96's rows for the bench page's OCR charts, like enh_ocr_input's: Vision with dropout on every page that has
    a mark at all (ungated) and with the gate; Gemini with the gate."""
    import ocr_panel as P
    kind = {r['page']: r['kind'] for r in P.rows()}
    out = []
    for reader in READERS:
        rr = {r['page']: r for r in rows if r['reader'] == reader and r['set'] == '96'}
        if len(rr) != len(panel_pages()):
            continue
        arms = [('gated', lambda r: r['route'] if r['fires'] else r['raw'])]
        if reader == 'apple-vision':
            arms.insert(0, ('ungated', lambda r: r['dropout']))
        groups = {'the 96': list(rr), **{f'kind:{k}': [p for p in rr if kind[p] == k] for k in sorted(set(kind[p] for p in rr))}}
        for arm, f in arms:
            for g, ps in groups.items():
                row = {'route': reader, 'arm': arm, 'group': g, 'n': len(ps), 'ok': len(ps),
                       'nes': round(sum(f(rr[p]) for p in ps) / len(ps), 5)}
                if reader != 'apple-vision':
                    row['cost'] = round(sum(reply_cost('raw', p) + (reply_cost('dropout', p) + reply_cost('mark', p)
                                                                    if rr[p]['fires'] else 0) for p in ps), 6)
                out.append(row)
    return out


def reply_cost(kind, key):
    """A Gemini reply's estimated cost (its ledger figure, the larger of the estimate and the gateway's own)."""
    G = _gateway()
    if kind == 'raw' and key.startswith('p') and key[1:].isdigit():
        j = next(j for j in G.panel_manifest()[1] if j['page'] == key)
        f = G.REHEARSAL / 'gateway-gemini' / 'panel' / (j['id'] + '.json')
    else:
        f = reply_path(kind, key)
    m = json.loads(f.read_text())['meta']
    return max(m.get('cost') or 0, m.get('gateway_cost') or 0)


def report():
    import statistics
    sel = selection()
    gate = json.loads(gate_path().read_text())
    rows = page_rows()
    G = _gateway()
    led = G.ledger()
    spent = G.spent()
    summ = {}
    for reader in READERS:
        for st in ('stamp', 'stamp-marked', 'stamp-unmarked', 'control', '96'):
            base = st.split('-')[0]
            rr = [r for r in rows if r['reader'] == reader and r['set'] == base
                  and (st == base or r['marked'] == (st == 'stamp-marked'))]
            summ[f'{reader}|{st}|route'] = summary(rr, 'route')
            summ[f'{reader}|{st}|dropout'] = summary(rr, 'dropout')
            if st == '96':
                fired = [r for r in rr if r['fires']]
                summ[f'{reader}|96-gated|route'] = summary(
                    [{**r, 'route': r['route'] if r['fires'] else r['raw'],
                      'route_body_missed': r['route_body_missed'] if r['fires'] else r['raw_body_missed']} for r in rr], 'route')
                summ[f'{reader}|96-fired|route'] = summary(fired, 'route')
    stamp_v = [r for r in rows if r['reader'] == 'apple-vision' and r['set'] == 'stamp' and r.get('raw_lines_under') is not None]
    lines = {arm: (sum(r[arm + '_lines_under'] for r in stamp_v), sum(r[arm + '_words_under'] for r in stamp_v))
             for arm in ('raw', 'dropout')}
    with_marks = {st: sum(1 for r in rows if r['reader'] == 'apple-vision' and r['set'] == st and r['marked'])
                  for st in ('stamp', 'control')}
    owner = {r['reader']: {a: r[a] for a in ('raw', 'dropout', 'route', 'raw_body_missed', 'dropout_body_missed',
                                              'body_words', 'raw_lines_under', 'dropout_lines_under',
                                              'raw_words_under', 'dropout_words_under') if a in r}
             for r in rows if r['page'] == OWNER}
    out = {'item': 'W46.ocr-input-colour-dropout', 'report': REPORT.name, 'surveyed': sel['surveyed'],
           'pool': sel['pool'], 'thresholds': sel['thresholds'],
           'selected': {'stamp': [{k: r[k] for k in ('key', 'coll', 'rel', 'hue', 'over', 'mark_frac', 'colour_share')}
                                  for r in sel['stamp']],
                        'control': [{k: r[k] for k in ('key', 'coll', 'rel', 'hue', 'over', 'mark_frac', 'colour_share')}
                                    for r in sel['control']]},
           'gate96': {'fires': sorted(p for p, g in gate.items() if g['fires']),
                      'any_mark': sum(g['channel'] is not None for g in gate.values())},
           'drafts_with_marks': with_marks, 'summary': summ, 'lines_under_mark': lines, 'owner_page': owner,
           'gateway': {'model': G.MODEL, 'route': G.LABEL, 'calls': len(led), 'cost_estimate': round(spent, 4),
                       'billed': G.billed_note(led), 'cap': CAP},
           'chart_rows': chart_rows(rows), 'pages': rows}
    BENCH.write_text(json.dumps(out, indent=1) + '\n')
    print(json.dumps({k: v for k, v in summ.items() if v}, indent=0)[:4000])
    print('lines under the mark', lines, 'drafts with marks', with_marks, 'owner', owner)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('cmd', choices=['survey', 'select', 'images', 'vision', 'gemini', 'report'])
    ap.add_argument('--probe', action='store_true')
    a = ap.parse_args()
    if a.cmd == 'gemini':
        return gemini(a.probe)
    {'survey': survey, 'select': select, 'images': images, 'vision': vision, 'report': report}[a.cmd]()


if __name__ == '__main__':
    main()
