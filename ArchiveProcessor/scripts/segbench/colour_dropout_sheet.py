#!/usr/bin/env python3
"""W46.ocr-input-colour-dropout — the owner's boxed check sheet for the disputed lines of the 40 stamped pages' truth.

  python3 colour_dropout_sheet.py orient      (not under heavy-run.py: it runs the binary through heavy-run.py itself)
                       Apple Vision at four turns (ocr_orient.swift's segbench-ocr-orient) on every stamped page's raw
                       image -> CACHE/sheet/orient.json; a turn an eye check found goes in CACHE/sheet/orient-eye.tsv
                       ("<key> <degrees clockwise>")
  V=~/.local/share/visionocr-ocrlab/venv/bin/python
  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy --with pillow \\
      python colour_dropout_sheet.py build [--allow-missing] [--no-orient]
                       CACHE/sheet/index.html + key.json (private) and segbench-results/ocr-colour-dropout-sheet.md
                       (counts only). Refuses while a page's draft or a reading is missing (the gateway run still
                       going) unless --allow-missing, which leaves such pages off and lists them; refuses without
                       orient.json unless --no-orient (every page then "not checked", for testing the build only)
  ... python colour_dropout_sheet.py fold ANSWERS.json
                       CACHE/sheet/rulings.json and the corrected truths CACHE/truth/<key>.txt (+ .json: what was
                       applied, the notes, the unasked fields as listed), which the report prefers over the draft

The truth of the stamped pages is Gemini 3.7 Flash's draft (ocr_colour_dropout.draft), the same family as one scored
reader, so the owner checks it where it matters for this item: places where any of the four plain readings (Vision
raw and dropout, Gemini raw and dropout; not the mark layer) reads the draft's text differently, aligned on the
scorer's words (ocr_hands_sheet.hand_places, overlapping differences merged into one place). Kept: places on a Vision
raw line under the mark (the line's box at least ocr_colour_dropout.UNDER covered by the mark layer's dark pixels, as
under_mark() tests it), and places that cannot be located only where a reader's dropout reading and its raw reading disagree.
Left out and counted: differences only in where the words break, passages longer than BLOCK_WORDS words (reading
order, not reading), places off the mark. At most PER_PAGE_MAX a page, a seeded sample; the key keeps every count.

Blind: a place shows every distinct reading, the draft's among them, unlabelled, in an order seeded by the page and
place and sorted by text first, so it does not depend on which reading is the draft; plus "none of these — type it".
The box comes from the draft words' positions through Vision raw's words (ocr_truth_bias.locate) and is shared by
every reading of the place; with no box, the sheet says how far through the page's text the place is.

Owner-sheet rules (2026-11-05): an optional note per place, per page and for the sheet (answers' `_notes`, keyed
`<page>/<id>`, `<page>` and `_sheet`; typing in a note never triggers a shortcut); the unasked fields (the draft's
kind and its coloured marks, colour and text) listed on each page, going in as listed unless a note corrects them;
pages upright: clear wins of ocr_orient.swift's scores only (TURN_RATIO, TURN_MIN, as item_fields_retruth), close
calls flagged in the key, and a turn button that turns the page and its boxes together (answers' `_turns`).

Reads the cache only: no model, no network, no money; no Claude reader looks at a page.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import ocr_colour_dropout as C             # noqa: E402
import ocr_hands_sheet as H                # noqa: E402

B = H.B
T = B.T
RESULTS = HERE.parents[1] / 'segbench-results'
OUT = C.CACHE / 'sheet'
TRUTH = C.CACHE / 'truth'
MD = RESULTS / 'ocr-colour-dropout-sheet.md'
HEAVY = HERE.parents[2] / 'ops/autonomous/heavy-run.py'
ORIENT_BIN = C.REH / 'segbench/bin/segbench-ocr-orient'
SEED = 20261111
PER_PAGE_MAX = 15
CONTEXT, BLOCK_WORDS = B.CONTEXT, B.BLOCK_WORDS
TURN_RATIO, TURN_MIN = 2.0, 20.0           # item_fields_retruth.display_turns: a clear win only
ON_LINE = 0.5                              # a place's box on a line: half its area inside the line's box
GEMINI = 'gemini3.7-flash-gw'
NAMES = {'vision-raw': ('apple-vision', 'raw'), 'vision-dropout': ('apple-vision', 'dropout'),
         'gemini-raw': (GEMINI, 'raw'), 'gemini-dropout': (GEMINI, 'dropout')}
DROPOUT, RAW = ('vision-dropout', 'gemini-dropout'), ('vision-raw', 'gemini-raw')


# ---- places (pure) ----------------------------------------------------------------------------------------------

def page_places(draft_text: str, texts: dict[str, str]) -> list[dict]:
    """ocr_hands_sheet.hand_places against the draft, its 'truth' named 'draft'."""
    out = []
    for x in H.hand_places([(w, 'draft') for w in draft_text.split()], texts):
        rd = {('draft' if n == 'truth' else n): t for n, t in x['readings'].items()}
        opts = [sorted('draft' if n == 'truth' else n for n in g) for g in x['options']]
        out.append({**x, 'readings': rd, 'options': opts})
    return out


def blind_options(x: dict, rng: random.Random) -> list[tuple[str, list[str]]]:
    """(text shown, its sources) per distinct reading: groups sorted by text, then shuffled, so the order depends on
    the texts and the seed and never on which source is the draft. A group's text is its smallest raw text."""
    groups = sorted(((min(x['readings'][n] for n in g), sorted(g)) for g in x['options']), key=lambda o: o[0])
    rng.shuffle(groups)
    return groups


def place_rng(key: str, x: dict) -> random.Random:
    return random.Random(f'{SEED}:{key}:{x["t0"]}:{x["t1"]}')


def raw_dropout_disagree(x: dict) -> bool:
    """Whether a reader's dropout reading differs from its own raw reading here: what the input changed. Two
    readers differing on the same input is not the dropout's doing."""
    grp = {n: i for i, g in enumerate(x['options']) for n in g}
    return any(d in grp and r in grp and grp[d] != grp[r] for d, r in zip(DROPOUT, RAW))


def on_lines(box, lines) -> bool:
    """Whether a place's box [x, y, w, h] is on any of the line boxes: its centre inside one, or at least ON_LINE
    of its area."""
    if not box:
        return False
    x, y, w, h = box
    cx, cy = x + w / 2, y + h / 2
    for lx, ly, lw, lh in lines:
        if lx <= cx <= lx + lw and ly <= cy <= ly + lh:
            return True
        ix = max(0., min(x + w, lx + lw) - max(x, lx))
        iy = max(0., min(y + h, ly + lh) - max(y, ly))
        if w * h > 0 and ix * iy >= ON_LINE * w * h:
            return True
    return False


def keep(x: dict, box, mark_lines) -> str | None:
    """Why a place is on the sheet ('under mark', 'unlocated, raw and dropout disagree'), or None."""
    if box is not None:
        return 'under mark' if on_lines(box, mark_lines) else None
    return 'unlocated, raw and dropout disagree' if raw_dropout_disagree(x) else None


def cap(items: list, rng: random.Random, n: int = PER_PAGE_MAX) -> list:
    return items if len(items) <= n else [items[i] for i in sorted(rng.sample(range(len(items)), n))]


# ---- turns (pure) -----------------------------------------------------------------------------------------------

def clear_turn(sc: list[float]) -> tuple[int, bool]:
    """(degrees clockwise that show the page upright, close call) from the scores at up, right, down, left. A turn
    wins only by TURN_RATIO over every other turn and TURN_MIN weighted characters; anything else stays as it is,
    and is a close call when no turn, upright included, wins that clearly."""
    best = max(range(4), key=lambda i: sc[i])
    rest = [sc[i] for i in range(4) if i != best]
    clear = all(sc[best] >= TURN_RATIO * r for r in rest) and sc[best] - max(rest) >= TURN_MIN
    return (90 * best if clear else 0), not clear


# ---- fold (pure) ------------------------------------------------------------------------------------------------

def apply_edits(text: str, edits: list[tuple[int, int, str]]) -> str:
    """The text with raw words t0..t1-1 (its whitespace-split words) replaced by each edit's text, the rest of its
    layout (line breaks) kept. An empty range inserts before word t0 (or at the end)."""
    spans = [m.span() for m in re.finditer(r'\S+', text)]
    for t0, t1, new in sorted(edits, key=lambda e: (e[0], e[1]), reverse=True):
        if t0 < t1:
            a, b = spans[t0][0], spans[t1 - 1][1]
            if not new:   # take the following space too, so no double space is left
                while b < len(text) and text[b] == ' ':
                    b += 1
        else:
            a = b = spans[t0][0] if t0 < len(spans) else len(text)
            if not new:
                continue
            new = new + ' ' if t0 < len(spans) else (' ' if text and not text[-1].isspace() else '') + new
        text = text[:a] + new + text[b:]
    return text


def same(a: str, b: str) -> bool:
    return B.keys(a.replace(' ', '')) == B.keys(b.replace(' ', ''))


def fold(key: dict, answers: dict, drafts: dict[str, str]) -> dict:
    """Rulings per place and the corrected text per page. A pick or a typed text that matches the draft leaves the
    draft; another replaces the place's draft words; 'either' (can't tell) and an unanswered place leave the draft
    and are counted. Notes and the owner's turns are carried onto each page."""
    if answers.get('_build') not in (None, key['build']):
        raise SystemExit('these answers are from another build of the sheet')
    notes, turns = answers.get('_notes') or {}, answers.get('_turns') or {}
    counts, rulings, texts = {}, {}, {}
    for p, d in key['pages'].items():
        if 'items' not in d:
            continue
        if hashlib.sha256(drafts[p].encode()).hexdigest() != d['draft_sha']:
            raise SystemExit(f'{p}: the draft changed since the sheet was built')
        edits, rp = [], {}
        for iid, v in d['items'].items():
            a = (answers.get(p) or {}).get(iid)
            if a is None:
                r = {'ruling': 'open'}
            elif a == 'either':
                r = {'ruling': 'either', 'unresolved': True}
            elif a.startswith('='):
                r = {'ruling': 'typed', 'text': a[1:], 'matches': [s for s in v['readings'] if same(a[1:], v['readings'][s])]}
            else:
                i = int(a) - 1
                r = {'ruling': 'picked', 'text': v['texts'][i], 'matches': v['options'][i]}
            stands = 'draft' in r.get('matches', [])
            r['draft_stands'] = stands if r['ruling'] in ('picked', 'typed') else None
            if r['draft_stands'] is False:
                edits.append((v['t0'], v['t1'], r['text']))
            k = r['ruling'] if r['draft_stands'] is None else ('draft stands' if stands else 'draft wrong')
            counts[k] = counts.get(k, 0) + 1
            rp[iid] = {**v, **r, 'note': notes.get(f'{p}/{iid}')}
        texts[p] = apply_edits(drafts[p], edits)
        rulings[p] = {'items': rp, 'applied': len(edits), 'note': notes.get(p),
                      'turn_by_owner': turns.get(p, 0), 'kind': d['kind'], 'marks': d['marks']}
    return {'build': key['build'], 'counts': counts, 'sheet_note': notes.get('_sheet'), 'pages': rulings,
            'texts': texts}


# ---- the cache --------------------------------------------------------------------------------------------------

def vision_words(v: dict) -> list[list]:
    """Vision's words in its reading order as ocr_truth_bias.locate takes them: [text, x, y, w, h] (0-1, top left),
    and each word's line index."""
    words, line_of = [], []
    for li, ln in enumerate(v['lines']):
        for w in ln.get('words') or [{'text': ln['text'], 'quad': ln['quad']}]:
            xs, ys = [q[0] for q in w['quad']], [q[1] for q in w['quad']]
            words.append([w['text'], min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)])
            line_of.append(li)
    return words, line_of


def mark_lines(key: str) -> list[list[float]] | None:
    """Vision raw's line boxes under the mark ([x, y, w, h], 0-1), by ocr_colour_dropout.under_mark's test."""
    import numpy as np
    from PIL import Image
    v, m = C.vision_lines('raw', key), C.image('mark', key)
    if not v or not m.exists():
        return None
    mask = np.asarray(Image.open(m).convert('L')) < 128
    H_, W = mask.shape
    ii = np.pad(mask.cumsum(0).cumsum(1), ((1, 0), (1, 0)))
    out = []
    for ln in v['lines']:
        q = np.asarray(ln['quad'], float) * [W, H_]
        x0, x1 = int(max(0, q[:, 0].min())), int(min(W, q[:, 0].max()))
        y0, y1 = int(max(0, q[:, 1].min())), int(min(H_, q[:, 1].max()))
        area = (x1 - x0) * (y1 - y0)
        if area > 0 and ii[y1, x1] - ii[y0, x1] - ii[y1, x0] + ii[y0, x0] >= C.UNDER * area:
            out.append([x0 / W, y0 / H_, (x1 - x0) / W, (y1 - y0) / H_])
    return out


def page_inputs(key: str):
    """(draft, {name: reading}, failed names, why not ready). A Gemini reading of '' is a failed reply (left out of
    the page); None anywhere is not read yet."""
    d = C.draft(key)
    if d is None:
        return None, {}, [], 'no draft'
    texts, failed, missing = {}, [], []
    for n, (reader, kind) in NAMES.items():
        t = C.reading(reader, kind, key)
        if t is None:
            missing.append(n)
        elif reader == GEMINI and not t.strip():
            failed.append(n)
        else:
            texts[n] = t
    if missing:
        return d, texts, failed, 'not read: ' + ', '.join(missing)
    if C.vision_lines('raw', key) is None or not C.image('mark', key).exists():
        return d, texts, failed, 'no Vision raw lines or mark layer'
    return d, texts, failed, None


def orient_path():
    return OUT / 'orient.json'


def orient():
    """ocr_orient.swift's scores on every stamped page's raw image, through heavy-run.py (a model run)."""
    stamps, _ = C.keys()
    if not ORIENT_BIN.exists():
        raise SystemExit(f'{ORIENT_BIN} is missing: swiftc -O {HERE / "ocr_orient.swift"} -o {ORIENT_BIN}')
    OUT.mkdir(parents=True, exist_ok=True)
    paths = {str(C.image('raw', k)): k for k in stamps if C.image('raw', k).exists()}
    lst = OUT / 'orient-list.txt'
    lst.write_text(''.join(p + '\n' for p in paths))
    r = subprocess.run(['python3', str(HEAVY), 'run', '--', str(ORIENT_BIN), str(lst)], capture_output=True, text=True)
    scores = {}
    for line in r.stdout.splitlines():   # heavy-run.py's own lines are not five tab fields on a listed path
        f = line.split('\t')
        if len(f) == 5 and f[0] in paths:
            scores[paths[f[0]]] = [float(x) for x in f[1:]]
    if r.returncode or len(scores) != len(paths):
        raise SystemExit(f'orient: rc {r.returncode}, {len(scores)} of {len(paths)} scored\n{r.stderr[-2000:]}')
    orient_path().write_text(json.dumps({'bin': str(ORIENT_BIN), 'scores': scores}, indent=1))
    print(len(scores), 'pages scored at four turns')


def page_turns(no_orient: bool) -> dict[str, dict]:
    """{key: {'turn', 'close', 'how'}}; 'how' is 'scores', 'eye' or 'not checked'."""
    stamps, _ = C.keys()
    if no_orient:
        return {k: {'turn': 0, 'close': None, 'how': 'not checked'} for k in stamps}
    if not orient_path().exists():
        raise SystemExit(f'{orient_path()} is missing: run `colour_dropout_sheet.py orient` first (pages upright, '
                         'owner 2026-11-05), or --no-orient to test the build only')
    sc = json.loads(orient_path().read_text())['scores']
    out = {}
    for k in stamps:
        if k in sc:
            t, close = clear_turn(sc[k])
            out[k] = {'turn': t, 'close': close, 'how': 'scores'}
        else:
            out[k] = {'turn': 0, 'close': None, 'how': 'not checked'}
    eye = OUT / 'orient-eye.tsv'
    for line in (eye.read_text().splitlines() if eye.exists() else []):
        f = line.split()
        if len(f) >= 2 and f[0] in out and f[1] in ('0', '90', '180', '270'):
            out[f[0]] = {**out[f[0]], 'turn': int(f[1]), 'how': 'eye'}
    return out


# ---- build ------------------------------------------------------------------------------------------------------

def build(out_dir: Path, md: Path, allow_missing=False, no_orient=False) -> dict:
    if (out_dir / 'answers.json').exists():
        raise SystemExit(f'{out_dir} is answered: its key is what the answers mean, so it is not rebuilt')
    stamps, _ = C.keys()
    turns = page_turns(no_orient)
    data, key = [], {'seed': SEED, 'per_page_max': PER_PAGE_MAX, 'block_words': BLOCK_WORDS, 'readings': list(NAMES),
                     'orient': 'not checked' if no_orient else 'scores', 'pages': {}}
    st = {'pages': len(stamps), 'not_ready': {}, 'failed_readings': {}, 'places': 0, 'joins': 0, 'blocks': 0,
          'off_mark': 0, 'unlocated_dropped': 0, 'kept': 0, 'shown': 0, 'kept_why': {}, 'box_from': {'vision': 0, None: 0},
          'pages_capped': 0}
    for k in stamps:
        d, texts, failed, why = page_inputs(k)
        if why:
            st['not_ready'][k] = why
            key['pages'][k] = {'not_ready': why}
            continue
        if failed:
            st['failed_readings'][k] = failed
        raw_t = d['text'].split()
        v = C.vision_lines('raw', k)
        vw, _ = vision_words(v)
        ml = mark_lines(k) or []
        every = page_places(d['text'], texts)
        kept = []
        for x in every:
            if x['join']:
                st['joins'] += 1
                continue
            if x['block']:
                st['blocks'] += 1
                continue
            b = B.locate(raw_t, vw, x['t0'], x['t1']) if vw else None
            w = keep(x, b, ml)
            if w is None:
                st['off_mark' if b else 'unlocated_dropped'] += 1
                continue
            st['kept_why'][w] = st['kept_why'].get(w, 0) + 1
            kept.append((x, b, w))
        st['places'] += len(every)
        st['kept'] += len(kept)
        shown = cap(kept, random.Random(f'{SEED}:{k}:cap'))
        st['pages_capped'] += len(shown) < len(kept)
        items, kp = [], {}
        for n, (x, b, w) in enumerate(shown):
            opts = blind_options(x, place_rng(k, x))
            iid = f'd{n:02d}'
            items.append({'id': iid, 'before': x['before'], 'after': x['after'], 'opts': [t for t, _ in opts],
                          'box': b, 'at': round(x['t0'] / max(1, len(raw_t)), 2)})
            kp[iid] = {'options': [s for _, s in opts], 'texts': [t for t, _ in opts], 'readings': x['readings'],
                       't0': x['t0'], 't1': x['t1'], 'kept': w, 'box_from': 'vision' if b else None}
            st['box_from']['vision' if b else None] += 1
        st['shown'] += len(items)
        key['pages'][k] = {'places': len(every), 'kept': len(kept), 'shown': len(items), 'failed_readings': failed,
                           'mark_lines': len(ml), 'draft_sha': hashlib.sha256(d['text'].encode()).hexdigest(),
                           'kind': d['kind'], 'marks': [list(m) for m in d['marks']], **turns[k], 'items': kp}
        if items:
            data.append({'page': k, 'img': f'../img/raw/{k}.jpg', 'turn': turns[k]['turn'], 'kind': d['kind'] or '',
                         'marks': [list(m) for m in d['marks']], 'items': items})
    random.Random(SEED).shuffle(data)
    build_id = hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()[:12]
    key['build'] = build_id
    turned = sorted(p['page'] for p in data if p['turn'])
    st.update({'pages_on_sheet': len(data), 'turned': turned, 'orient': key['orient'],
               'close_calls': sum(1 for p in data if turns[p['page']]['close']),
               'minutes': (len(data) * T.SECONDS_PER_PAGE
                           + st['shown'] * (T.SECONDS_PER_DISPUTE + T.TYPED_SHARE * T.SECONDS_PER_TYPED)) / 60})
    key['stats'] = {k: v for k, v in st.items() if k != 'box_from'} | {'box_from': {str(a): b for a, b in st['box_from'].items()}}
    if st['not_ready'] and not allow_missing:
        raise SystemExit(f'{len(st["not_ready"])} of {len(stamps)} pages are not ready (a draft or reading missing; '
                         'the gateway run may still be going): rerun later, or --allow-missing to leave them off')
    out_dir.mkdir(parents=True, exist_ok=True)
    turned_note = (f'{len(turned)} pages were turned upright before the sheet was built (a clear Apple Vision text '
                   f'score at four turns, or an eye check): {", ".join(turned)}.' if turned else
                   'No page was turned before the sheet was built.') if not no_orient else \
        'The pages were NOT checked for orientation (a test build).'
    (out_dir / 'index.html').write_text(
        SHEET_HTML.replace('__DATA__', json.dumps(data, ensure_ascii=False)).replace('__BUILD__', build_id)
        .replace('__MINUTES__', f'{st["minutes"]:.0f}').replace('__N__', str(st['shown']))
        .replace('__PAGES__', str(len(data))).replace('__TURNED__', turned_note))
    (out_dir / 'key.json').write_text(json.dumps(key, ensure_ascii=False, indent=1))
    md.parent.mkdir(parents=True, exist_ok=True)
    write_md(md, st)
    return st


SHEET_HTML = r"""<!doctype html><meta charset="utf-8"><title>W46 colour dropout: disputed lines</title>
<style>
body{font:14px -apple-system,sans-serif;margin:0;background:#fff;color:#111;color-scheme:light}
header{position:sticky;top:0;background:#fff;border-bottom:1px solid #ccc;padding:6px 12px;z-index:2}
header textarea{width:60%;height:2.2em;vertical-align:middle}
.page{display:flex;gap:12px;border-bottom:3px solid #999;padding:10px;min-height:90vh}
.img{flex:1 1 55%;position:sticky;top:var(--head,44px);height:calc(100vh - var(--head,44px) - 20px);overflow:auto}
.wrap{position:relative;cursor:zoom-in}.wrap.zoom{cursor:zoom-out}
.frame{position:absolute;left:0;top:0;transform-origin:0 0}.frame img{width:100%;height:100%;display:block}
.box{position:absolute;border:3px solid #f0a;border-radius:4px;box-shadow:0 0 0 2000px rgba(0,0,0,.12);pointer-events:none;display:none}
.where{color:#a40;font-size:12px;display:block}.unasked{background:#f4f4f4;padding:4px 6px;margin:4px 0;font-size:13px}
.list{flex:1 1 45%}.it{scroll-margin:var(--head,44px) 0 10px;border:1px solid #ccc;border-radius:4px;padding:6px;margin:8px 0;font-family:Georgia,serif}
.it.cur{outline:3px solid #06f}.it.done{background:#e6f6e6;border-color:#4a4}
.ctx{color:#777}.opt{display:block;margin:3px 0;font-family:-apple-system,sans-serif;cursor:pointer}.opt.sel{font-weight:bold;color:#060}
.k{color:#888;font-size:12px}.typed{color:#a40;display:block}textarea{width:100%;height:2.6em;font:13px -apple-system,sans-serif}
</style>
<header><b>Colour dropout: the disputed lines</b> — __N__ places on __PAGES__ pages, about __MINUTES__ minutes. Each
place shows the readings of the same words, which reading is which not shown. Pick the one the photograph shows.
Keys: <b>1</b>–<b>9</b> pick that reading · <b>t</b> none of these (type it) · <b>e</b> either will do / can't tell ·
<b>n/p</b> next/previous · <b>z</b> zoom · <b>r</b> turn the page (its boxes turn with it). The pink box marks roughly
where each place is (it can be off by a line or so). __TURNED__ Not asked: each page's kind and its coloured marks
(colour and text) are listed in grey and go in as listed; correct them in the page's note. Notes never trigger keys.
Answers stay in this browser; <button onclick="exportAnswers()">Export answers</button> <span id="prog"></span><br>
Note on the whole sheet (optional): <textarea data-note="_sheet"></textarea></header><div id="root"></div>
<script>
const DATA=__DATA__;const BUILD='__BUILD__';const KEY='w46-colour-dropout-'+BUILD;
let A=JSON.parse(localStorage.getItem(KEY)||'{}');A._build=BUILD;A._notes=A._notes||{};A._turns=A._turns||{};
const items=[],pages=[];
function esc(s){return String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function save(){localStorage.setItem(KEY,JSON.stringify(A));prog()}
function prog(){const d=items.filter(it=>ans(it)!==undefined).length;document.getElementById('prog').textContent=` ${d} / ${items.length} answered`}
function ans(it){return (A[it.page]||{})[it.key]}
function set(it,v){(A[it.page]=A[it.page]||{})[it.key]=v;save();paint(it)}
function paint(it){const v=ans(it);it.el.classList.toggle('done',v!==undefined);
 it.el.querySelectorAll('.opt').forEach(o=>o.classList.toggle('sel',o.dataset.v===v));
 it.el.querySelector('.typed').textContent=v&&v.startsWith('=')?'typed: '+v.slice(1):(v==='either'?'either will do / can\'t tell':'')}
function typeIt(it){const t=prompt('What the photograph shows here (empty = nothing):','');if(t!==null){set(it,'='+t);go(cur+1)}}
function note(el,id){el.value=A._notes[id]||'';el.addEventListener('input',()=>{if(el.value)A._notes[id]=el.value;else delete A._notes[id];save()});
 el.addEventListener('keydown',e=>e.stopPropagation())}
const root=document.getElementById('root');
for(const p of DATA){const div=document.createElement('div');div.className='page';
 const marks=p.marks.length?p.marks.map(m=>esc(m[0])+': '+(m[1]?esc(m[1]):'<i>(no text)</i>')).join(' · '):'none';
 let h=`<div class="img"><div class="wrap"><div class="frame"><img src="${p.img}"><div class="box"></div></div></div></div>`+
  `<div class="list"><b>${p.page}</b> <button class="turn">turn ⟳ (r)</button> <span class="k turned"></span>`+
  `<div class="unasked">Not asked, goes in as listed. Kind: ${esc(p.kind)||'<i>(none)</i>'} · Coloured marks: ${marks}</div>`;
 for(const x of p.items){h+=`<div class="it" data-key="${x.id}"><span class="ctx">… ${esc(x.before)}</span> <b>[ ]</b> <span class="ctx">${esc(x.after)} …</span>`+
  (x.box?'':`<span class="where">No box for this place: it is about ${Math.round(100*x.at)}% of the way through the page's text.</span>`);
  x.opts.forEach((o,i)=>{h+=`<span class="opt" data-v="${i+1}"><span class="k">${i+1}:</span> ${esc(o)||'<i>(nothing)</i>'}</span>`});
  h+=`<span class="opt" data-v="t"><span class="k">t:</span> none of these — type it</span>`+
   `<span class="typed"></span><span class="k">Note (optional)</span><textarea data-note="${p.page}/${x.id}"></textarea></div>`}
 h+=`<span class="k">Note on this page (optional; correct the kind or marks here)</span><textarea data-note="${p.page}"></textarea>`;
 div.innerHTML=h+'</div>';root.appendChild(div);
 const pg={page:p.page,turn:p.turn,div,pane:div.querySelector('.img'),wrap:div.querySelector('.wrap'),frame:div.querySelector('.frame'),
  img:div.querySelector('img'),mark:div.querySelector('.box'),zoom:false};pages.push(pg);
 pg.img.addEventListener('load',()=>lay(pg));
 pg.wrap.onclick=()=>{pg.zoom=!pg.zoom;lay(pg)};
 div.querySelector('.turn').onclick=()=>rot(pg);
 div.querySelectorAll('.it').forEach(el=>{const x=p.items.find(x=>x.id===el.dataset.key);
  const it={page:p.page,key:el.dataset.key,el,box:x.box,n:x.opts.length,pg};items.push(it);paint(it);
  el.querySelectorAll('.opt').forEach(o=>o.addEventListener('click',e=>{e.stopPropagation();go(items.indexOf(it));
   if(o.dataset.v==='t')typeIt(it);else{set(it,o.dataset.v);go(cur+1)}}));
  el.addEventListener('click',()=>go(items.indexOf(it)))})}
document.querySelectorAll('textarea[data-note]').forEach(el=>note(el,el.dataset.note));
function turnOf(pg){return (pg.turn+(A._turns[pg.page]||0))%360}
function rot(pg){A._turns[pg.page]=((A._turns[pg.page]||0)+90)%360;save();lay(pg)}
// the frame holds the image and its box, turned together; the wrap is the turned footprint, the pane's width
function lay(pg){const im=pg.img;if(!im.naturalWidth)return;const t=turnOf(pg),ar=im.naturalHeight/im.naturalWidth;
 const base=(pg.pane.clientWidth-4)*(pg.zoom?2.5:1),up=t%180===0,fw=up?base:base/ar,fh=fw*ar;
 Object.assign(pg.frame.style,{width:fw+'px',height:fh+'px',transform:
  t===90?`translate(${fh}px,0) rotate(90deg)`:t===180?`translate(${fw}px,${fh}px) rotate(180deg)`:t===270?`translate(0,${fw}px) rotate(270deg)`:'none'});
 Object.assign(pg.wrap.style,{width:base+'px',height:(up?fh:fw)+'px'});pg.wrap.classList.toggle('zoom',pg.zoom);
 pg.div.querySelector('.turned').textContent=t?`shown turned ${t}° clockwise`:'';
 if(items[cur]&&items[cur].pg===pg)show(items[cur])}
let cur=0,first=true;function go(i){if(i<0||i>=items.length)return;const prev=first?null:items[cur];first=false;items[cur].el.classList.remove('cur');cur=i;
 const el=items[cur].el;el.classList.add('cur');
 if(!prev||prev.page!==items[cur].page)el.closest('.page').scrollIntoView({block:'start'});
 el.scrollIntoView({block:'nearest'});show(items[cur])}
function head(){const h=document.querySelector('header').offsetHeight;document.documentElement.style.setProperty('--head',h+'px');
 document.querySelectorAll('.page').forEach(d=>d.style.scrollMarginTop=h+'px');pages.forEach(lay)}
addEventListener('resize',head);
const PAD=.012;
function show(it){if(!it)return;const pg=it.pg,m=pg.mark,b=it.box;if(!b){m.style.display='none';return}
 const w=Math.max(b[2]+2*PAD,.08),h=Math.max(b[3]+2*PAD,.03),x=Math.max(0,b[0]+b[2]/2-w/2),y=Math.max(0,b[1]+b[3]/2-h/2);
 Object.assign(m.style,{display:'block',left:100*x+'%',top:100*y+'%',width:100*w+'%',height:100*h+'%'});
 const fw=pg.frame.offsetWidth,fh=pg.frame.offsetHeight,cx=(x+w/2)*fw,cy=(y+h/2)*fh,t=turnOf(pg);
 const [rx,ry]=t===90?[fh-cy,cx]:t===180?[fw-cx,fh-cy]:t===270?[cy,fw-cx]:[cx,cy];
 pg.pane.scrollTop=ry-pg.pane.clientHeight/2;pg.pane.scrollLeft=rx-pg.pane.clientWidth/2}
document.addEventListener('keydown',e=>{if(e.metaKey||e.ctrlKey||e.altKey||e.target.closest('textarea,input'))return;
 const it=items[cur];if(!it)return;
 if(e.key==='n')go(cur+1);else if(e.key==='p')go(cur-1);else if(e.key==='z'){it.pg.zoom=!it.pg.zoom;lay(it.pg)}
 else if(e.key==='r')rot(it.pg);
 else if(/^[1-9]$/.test(e.key)&&+e.key<=it.n){set(it,e.key);go(cur+1)}
 else if(e.key==='e'){set(it,'either');go(cur+1)}
 else if(e.key==='t')typeIt(it)});
function exportAnswers(){const b=new Blob([JSON.stringify(A,null,1)],{type:'application/json'});
 const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='colour-dropout-answers.json';a.click()}
head();prog();go(0);
</script>"""


def write_md(path: Path, s: dict):
    nr, fr = s['not_ready'], s['failed_readings']
    kw = s['kept_why']
    L = ['# The colour-dropout check sheet (W46.ocr-input-colour-dropout)', '',
         'Generated by `scripts/segbench/colour_dropout_sheet.py` from saved readings only: no call, no money, and no '
         'Claude reader looked at the pages. The stamped pages\' truth is Gemini 3.7 Flash\'s draft, the same family '
         'as one scored reader; this sheet is the owner\'s check of it on the lines that decide the item.', '',
         '## What is on it', '',
         f'- **Pages.** {s["pages"]} stamped pages; {s["pages"] - len(nr)} ready'
         + (f', {len(nr)} not ready and left off ({", ".join(sorted(set(nr.values())))})' if nr else '') + '. '
         + (f'Failed Gemini readings, left out of their page: {sum(len(v) for v in fr.values())} on {len(fr)} pages.'
            if fr else 'No failed reading.'),
         f'- **Places.** {s["places"]} places where Vision raw, Vision dropout, Gemini raw or Gemini dropout reads the '
         f'draft differently (scorer\'s words, overlapping differences merged). Left out: {s["joins"]} that differ only '
         f'in where the words break, {s["blocks"]} longer than {BLOCK_WORDS} words on a side (reading order), '
         f'{s["off_mark"]} located off the mark, and {s["unlocated_dropped"]} that could not be located where no '
         f'reader\'s dropout and raw readings disagree. Kept: {s["kept"]} ({kw.get("under mark", 0)} on a Vision raw '
         f'line under the mark, {kw.get("unlocated, raw and dropout disagree", 0)} unlocated where a reader\'s '
         f'dropout and raw readings disagree). At most {PER_PAGE_MAX} a page (a seeded sample on {s["pages_capped"]} pages): **{s["shown"]} '
         f'places on {s["pages_on_sheet"]} pages are on the sheet**, about {s["minutes"]:.0f} minutes at '
         '`ocr_truth.py`\'s review rates (an estimate).',
         f'- **Boxes.** {s["box_from"]["vision"]} from Apple Vision raw\'s word positions (`ocr_truth_bias.locate`), '
         f'{s["box_from"][None]} with none, which say how far through the page\'s text they are.',
         '- **Upright.** ' + ('Not checked (a test build).' if s['orient'] == 'not checked' else
                              f'Apple Vision at four turns (`ocr_orient.swift`); {len(s["turned"])} pages turned '
                              f'({", ".join(s["turned"]) or "none"}), {s["close_calls"]} close calls on the sheet '
                              '(listed in the key); the owner can turn any page.'),
         '- **Unasked.** Each page lists the draft\'s kind and its coloured marks (colour and text); they go in as '
         'listed unless a note corrects them.', '',
         'Blind: the readings of a place are unlabelled in a seeded order that does not depend on which is the draft, '
         'and the box is shared by all of them. The sheet and its key are private, under the item\'s cache '
         '(`colour-dropout/sheet/`); `colour_dropout_sheet.py fold` writes the rulings and the corrected truths.', '',
         '## Measurement card', '',
         '- **Truth.** Gemini 3.7 Flash\'s draft; nothing is scored here. The owner\'s rulings correct it on the '
         'places shown.',
         '- **Selection.** Places are every difference of the four plain readings that falls under the mark (or is '
         'unlocated where a reader\'s dropout and raw readings disagree), capped by a seeded sample; no ABBYY text is read.',
         '- **Comparison.** None yet: the report rescores raw against dropout on the corrected truth.',
         f'- **Noise.** {s["shown"]} places; the report gives the paired intervals.',
         '- **Scope.** Draft errors that all four readings share, and those off the mark, are not on the sheet.', '']
    path.write_text('\n'.join(L) + '\n')


def cmd_fold(answers_path: Path, out_dir: Path):
    key = json.loads((out_dir / 'key.json').read_text())
    answers = json.loads(answers_path.read_text())
    drafts = {p: C.draft(p)['text'] for p, d in key['pages'].items() if 'items' in d}
    r = fold(key, answers, drafts)
    texts = r.pop('texts')
    (out_dir / 'rulings.json').write_text(json.dumps(r, ensure_ascii=False, indent=1))
    TRUTH.mkdir(parents=True, exist_ok=True)
    for p, t in texts.items():
        (TRUTH / f'{p}.txt').write_text(t)
        pr = r['pages'][p]
        (TRUTH / f'{p}.json').write_text(json.dumps(
            {'from': 'gemini draft + owner rulings (colour_dropout_sheet.py fold)', 'build': key['build'],
             'applied': pr['applied'], 'kind': pr['kind'], 'marks': pr['marks'], 'page_note': pr['note'],
             'item_notes': {i: v['note'] for i, v in pr['items'].items() if v['note']},
             'sheet_note': r['sheet_note']}, ensure_ascii=False, indent=1))
    print(json.dumps(r['counts']), len(texts), 'truths written')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('orient')
    b = sub.add_parser('build')
    b.add_argument('--out', type=Path, default=OUT)
    b.add_argument('--md', type=Path, default=MD)
    b.add_argument('--allow-missing', action='store_true')
    b.add_argument('--no-orient', action='store_true')
    f = sub.add_parser('fold')
    f.add_argument('answers', type=Path)
    f.add_argument('--out', type=Path, default=OUT)
    a = ap.parse_args()
    if a.cmd == 'orient':
        return orient()
    if a.cmd == 'build':
        s = build(a.out, a.md, a.allow_missing, a.no_orient)
        print(f'{s["shown"]} places on {s["pages_on_sheet"]} pages ({len(s["not_ready"])} pages not ready), '
              f'~{s["minutes"]:.0f} min -> {a.out / "index.html"}')
        return
    cmd_fold(a.answers, a.out)


if __name__ == '__main__':
    main()
