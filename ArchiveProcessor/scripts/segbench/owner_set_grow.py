#!/usr/bin/env python3
"""W46.owner-set-grow: about 200 more random English owner pages with a word-level truth, beside the frozen 96.

Owner review of the pipeline doc, 2026-11-17: the 96 resolve about 3 NES on a typical route pair, and 730-2,303
pages are needed for 1 point (execution-plans/benchmark-corpus/00-plan.md §4). This builds a second owner set, S1;
the 96 (S0) stay frozen, so every earlier result stays comparable.

  heavy-run.py run -- /usr/local/bin/python3 owner_set_grow.py draw     # the pages, prepared from the JPEG originals
  heavy-run.py run -- /usr/local/bin/python3 owner_set_grow.py vision   # Apple Vision's word boxes (the sheet's boxes)
                                                                       # and ocr_orient.swift's four-turn scores
  python3 owner_set_grow.py models                  # the gateway's models now, each marked scored on the 96 or not
  python3 owner_set_grow.py draft --drafter NAME    # one blind truth draft per page through the gateway (paid, CAP)
  python3 owner_set_grow.py compare                 # agreed and disputed spans, the controls, the owner's minutes
  python3 owner_set_grow.py sheet                   # the owner's sheet (private, in the bench cache)
  python3 owner_set_grow.py fold ANSWERS.json       # the owner's rulings -> truth/<id>.txt, pages.tsv, the report

THE DRAW RULE, written before the draw ran:
  * Base: W46.ocr-vision-unfiltered's 200 drawn pages (ocr-vision-unfiltered/pages.jsonl, set "drawn": the 96's pool,
    documents ordered by sha256(U.SALT + document id), a document holding one of the 96's chosen or replaced pages
    left out, from each the page with the lowest sha256(U.SALT + file name); no caps, strata or word filter). Kept:
    the pages the owner answered "3, a page of text" on 11 Nov (answers-2026-11-11.json). That answer, not Vision's
    word count, is the text filter, so no tested route chose a page.
  * Top-up, TOPUP documents: the next documents in the same hashed order after the last of the 200, one page each
    by the same rule. The owner answers the same has-text question for them on this item's sheet; pages he does not
    call "a page of text" are dropped and counted.
  * English: each drafter names the page's main language; a page either drafter calls something other than English
    is listed on the sheet with that answer, and goes out of the set if the owner's note says so or both drafters
    agree it is not English. Counted either way.
  * Images: ocr_truth.prepare, the 96's preparation with the JPEG-originals rule (owner 2026-10-22, extended
    2026-11-11): the original by exact name, else its pairs.tsv JPEG checked against the PDF at MIN_CORR, else the
    PDF's image, EXIF applied, turned like the PDF page. Each row records which.

THE TRUTH: two gateway drafters of different families draft blind with ocr_truth.PROMPT plus a LANGUAGE line;
their words are aligned (difflib over ocr_truth.words of each raw token); every disputed span goes to the owner,
blind (the two readings in a seeded order, or type it), with a box from Apple Vision's word positions
(ocr_truth_bias.locate), plus CONTROLS agreed spans drawn at random, so a wrong agreed reading is measured too. The
drafters are chosen when the run is made, from `models`: the strongest two families not scored on the 96 where the
gateway serves them; a drafter that is scored is named on the result's measurement card, and scored on S1 only on
owner-ruled spans.

Reads the corpus read only (through ocr_truth.prepare); writes the bench cache (OUT). The committed result,
segbench-results/owner-set-grow.md, is counts only, because the repo is public and the pages are the owner's.
"""
from __future__ import annotations

import argparse
import base64
import collections
import difflib
import hashlib
import html
import io
import json
import os
import random
import re
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import ocr_truth as T                      # noqa: E402

REH = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
OUT = Path(os.environ.get('OWNER_SET_GROW_CACHE', REH / 'owner-set-grow'))
UNF = REH / 'ocr-vision-unfiltered'
UNF_ANSWERS = UNF / 'answers-2026-11-11.json'
RESULTS = HERE.parents[1] / 'segbench-results' / 'owner-set-grow.md'
DEWARP_BIN = REH / 'segbench/bin/segbench-dewarp'
ORIENT_BIN = REH / 'segbench/bin/segbench-ocr-orient'
TOPUP = 30
CONTROLS = 24
SEED = 20261118
CAP = 13.00                # the item's gateway total; the owner approved $13 for a third reader (2026-11-18 gate)
DRAFT_SIDE = T.DRAFT_SIDE
TURN_RATIO, TURN_MIN = 2.0, 20.0           # item_fields_retruth.display_turns: a clear win only
SECONDS_PER_PAGE, SECONDS_PER_DISPUTE, SECONDS_PER_TYPED, TYPED_SHARE = 10, 6, 30, 0.15   # ocr_truth's, measured on
SECONDS_PER_CONTROL = 4                                                                    # the 96's sheet
SECONDS_PER_LISTED = 1     # a place settled 2 to 1 is listed, not asked: a glance (an estimate, not measured)

# Drafter candidates through the gateway: id -> (label, family, $ per million input, output tokens, ceilings).
# A price is a labelled estimate from the provider's list price; the gateway's own figure is kept beside it and the
# cap counts the larger (gateway_gemini.charge). `draft` refuses a model that is not listed here.
DRAFTERS = {
    'gemini-3.7-flash': ('gemini3.7-flash-gw', 'gemini', 0.75, 3.75),
    'gpt-5.6-luna': ('gpt5.6-luna-gw', 'gpt', 0.20, 1.20),
    # Not scored on the 96 (the reader-not-under-test rule); priced at their providers' list prices.
    'gpt-5.4': ('gpt5.4-gw', 'gpt', 2.50, 15.00),
    'claude-sonnet-5': ('claude-sonnet5-gw', 'claude', 3.00, 15.00),
    'gemini-2.5-pro': ('gemini2.5-pro-gw', 'gemini', 1.25, 10.00),
    'gemini-2.5-flash': ('gemini2.5-flash-gw', 'gemini', 0.30, 2.50),
}
LANG_LINE = 'LANGUAGE: <the main language of the page\'s text, in English: English, French, German, ...>'
ANSWER_KEYS = {'1': 'no text', '2': 'a few words', '3': 'a page of text'}


def prompt() -> str:
    """ocr_truth.PROMPT with a LANGUAGE line after TABLE (the drafts are truth, not a scored reading)."""
    p = T.PROMPT
    i = p.index('TABLE:')
    j = p.index('\n', i)
    return p[:j + 1] + LANG_LINE + p[j:]


def parse(raw: str | None):
    """{kind, table, language, text} or None."""
    if not raw:
        return None
    m = re.search(r'^\s*LANGUAGE:\s*([^\n]*)\n', raw, re.M | re.I)
    lang = m.group(1).strip().strip('<>').strip() if m else None
    got = T.parse_draft(raw[:m.start()] + '\n' + raw[m.end():] if m else raw)
    return {**got, 'language': lang} if got else None


# ---------------------------------------------------------------- the draw (under the heavy lock)

def uh(s: str) -> str:
    import ocr_vision_unfiltered as U
    return U.h(s)


def load_jsonl(p: Path) -> list[dict]:
    return [json.loads(x) for x in p.read_text().splitlines() if x.strip()] if p.exists() else []


def hashed_docs(idx, truth_draw):
    """The unfiltered draw's documents in its hashed order: [(doc id, folder, [(name, tags), ...])]."""
    in96 = {(c['folder'], c['name']) for c in truth_draw['chosen']} | {(r['folder'], r['name']) for r in truth_draw['replaced']}
    docs = []
    for f in idx['folders']:
        for d in T.documents(f['folder'], f['photos']):
            if not any((f['folder'], n) in in96 for n, _ in d):
                docs.append((f"{f['folder']}#{d[0][0]}", f['folder'], d))
    docs.sort(key=lambda x: uh(x[0]))
    return docs


def select(drawn: list[dict], answers: dict, docs, topup: int):
    """(base rows, top-up candidates [(doc id, folder, name, tags, doc pages)], position of the last base document).
    Base: drawn pages the owner answered 3. Refuses when the rebuilt order does not hold the unfiltered draw's 200
    documents as its first ones (the index changed since), so the top-up is the next documents of that very order."""
    base = [r for r in drawn if answers.get(r['id']) == '3']
    want = {(r['folder'], r['name']) for r in drawn}
    first = {}
    for i, (doc_id, folder, d) in enumerate(docs):
        name, _ = min(d, key=lambda p: uh(p[0]))
        if (folder, name) in want:
            first[(folder, name)] = i
    if len(first) != len(want):
        raise SystemExit(f'{len(want) - len(first)} of the unfiltered draw\'s pages are not in the rebuilt order')
    last = max(first.values())
    gaps = last + 1 - len(first)
    cand = []
    for doc_id, folder, d in docs[last + 1:]:
        name, tags = min(d, key=lambda p: uh(p[0]))
        cand.append((doc_id, folder, name, tags, len(d)))
    return base, cand, last, gaps


def cmd_draw(_):
    import ocr_vision_unfiltered as U
    if (OUT / 'pages.jsonl').exists():
        raise SystemExit(f'{OUT / "pages.jsonl"} exists: the draw is made once')
    drawn = [r for r in load_jsonl(UNF / 'pages.jsonl') if r['set'] == 'drawn']
    answers = json.loads(UNF_ANSWERS.read_text())
    truth_draw = json.loads((T.CACHE / 'draw.json').read_text())
    idx = T.load_index()
    docs = hashed_docs(idx, truth_draw)
    base, cand, last, gaps = select(drawn, answers, docs, TOPUP)
    OUT.mkdir(parents=True, exist_ok=True)
    truth_cache, T.CACHE = T.CACHE, OUT                             # ocr_truth.prepare writes its copy and Vision's text under OUT/prep
    originals = idx['originals']
    rows, failed = [], []

    def add(set_name, folder, name, tags, doc_pages, extra):
        rec = T.prepare(folder, name, tags, originals)
        if 'error' in rec:
            failed.append({'set': set_name, 'folder': folder, 'name': name, 'error': rec['error'][:200]})
            return False
        rows.append({'set': set_name, 'key': rec['key'], 'folder': folder, 'name': name, 'tags': tags,
                     'source': rec['source'], 'source_method': rec.get('source_method'),
                     'pair_rejected': rec.get('pair_rejected'), 'doc_pages': doc_pages, 'vision_words': rec['words'],
                     **extra})
        print(len(rows), set_name, rec['source'], flush=True)
        return True

    for r in base:
        add('base', r['folder'], r['name'], r['tags'], r.get('doc_pages'), {'unfiltered_id': r['id'],
            'unfiltered_note': (answers.get('_notes') or {}).get(r['id'])})
    n_top = 0
    for doc_id, folder, name, tags, n in cand:
        if n_top == TOPUP:
            break
        n_top += add('topup', folder, name, tags, n, {'doc': doc_id})
    order = rows[:]
    random.Random(SEED).shuffle(order)          # the top-up mixed in, so none stands out by place
    for i, r in enumerate(order, 1):
        r['id'] = f's{i:03d}'
    T.CACHE = truth_cache
    (OUT / 'pages.jsonl').write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in order))
    (OUT / 'draw.json').write_text(json.dumps({
        'salt': U.SALT, 'seed': SEED, 'pool_docs': len(docs), 'unfiltered_drawn': len(drawn),
        'base_kept': len(base), 'base_answers': collections.Counter(answers.get(r['id']) for r in drawn),
        'last_base_position': last, 'unreadable_before_last': gaps, 'topup': n_top, 'failed': failed,
        'sources': collections.Counter(r['source'].split(' (')[0] for r in order)}, indent=1))
    print(len(order), 'pages,', len(failed), 'not readable from disk')


def load_pages() -> list[dict]:
    return load_jsonl(OUT / 'pages.jsonl')


def image(r) -> Path:
    return OUT / 'prep' / f"{r['key']}.jpg"


def lines_path(r) -> Path:
    return OUT / 'lines' / f"{r['key']}.json"


def cmd_vision(_):
    """Vision's lines with word quads (segbench-dewarp lines, guarded) and ocr_orient.swift's four-turn scores."""
    import subprocess
    import vision_guard
    rows = load_pages()
    todo = [r for r in rows if not lines_path(r).exists()]
    if todo:
        (OUT / 'lines').mkdir(parents=True, exist_ok=True)
        jobs = OUT / 'lines-jobs.tsv'
        jobs.write_text(''.join(f'{image(r)}\t{lines_path(r)}\n' for r in todo))
        vision_guard.run(DEWARP_BIN, jobs, 'lines')
    if not ORIENT_BIN.exists():
        raise SystemExit(f'{ORIENT_BIN} is missing: swiftc -O {HERE / "ocr_orient.swift"} -o {ORIENT_BIN}')
    lst = OUT / 'orient-list.txt'
    lst.write_text(''.join(f'{image(r)}\n' for r in rows))
    out = subprocess.run([str(ORIENT_BIN), str(lst)], capture_output=True, text=True)
    scores = {}
    for line in out.stdout.splitlines():
        f = line.split('\t')
        if len(f) == 5:
            scores[Path(f[0]).stem] = [float(x) for x in f[1:]]
    if out.returncode or len(scores) != len(rows):
        raise SystemExit(f'orient: rc {out.returncode}, {len(scores)} of {len(rows)} scored\n{out.stderr[-1500:]}')
    (OUT / 'orient.json').write_text(json.dumps({'bin': str(ORIENT_BIN), 'scores': scores}, indent=1))
    print(len(todo), 'pages read for boxes;', len(scores), 'scored at four turns')


def clear_turn(sc: list[float]) -> tuple[int, bool]:
    """(degrees clockwise that show the page upright, close call): colour_dropout_sheet.clear_turn's rule."""
    best = max(range(4), key=lambda i: sc[i])
    rest = [sc[i] for i in range(4) if i != best]
    clear = all(sc[best] >= TURN_RATIO * r for r in rest) and sc[best] - max(rest) >= TURN_MIN
    return (90 * best if clear else 0), not clear


def page_turns() -> dict[str, dict]:
    f = OUT / 'orient.json'
    if not f.exists():
        raise SystemExit(f'{f} is missing: run `owner_set_grow.py vision` first (pages upright, owner 2026-11-05)')
    sc = json.loads(f.read_text())['scores']
    out = {k: dict(zip(('turn', 'close'), clear_turn(v)), how='scores') for k, v in sc.items()}
    eye = OUT / 'orient-eye.tsv'
    for line in (eye.read_text().splitlines() if eye.exists() else []):
        p = line.split()
        if len(p) >= 2 and p[0] in out and p[1] in ('0', '90', '180', '270'):
            out[p[0]] = {**out[p[0]], 'turn': int(p[1]), 'how': 'eye'}
    return out


# ---------------------------------------------------------------- the gateway

def key_ready(G):
    """Read the gateway key into gateway_gemini's memory with a 20 s bound (hand_icl_gateway's rule): a locked login
    Keychain waits for a password nobody is there to type, so it stops here, before any request."""
    import subprocess
    if G._key is None:
        try:
            r = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', 'com.archiveprocessor.app',
                                '-a', 'Gateway', '-w'], capture_output=True, text=True, timeout=20)
        except subprocess.TimeoutExpired:
            raise SystemExit('the login Keychain did not answer in 20 s (locked?); nothing was sent') from None
        if r.returncode or not r.stdout.strip():
            raise SystemExit('no gateway key in the Keychain (com.archiveprocessor.app / Gateway); nothing was sent')
        G._key = r.stdout.strip()
    return G


def gateway(model: str):
    import gateway_gemini as G
    key_ready(G)
    if model not in DRAFTERS:
        raise SystemExit(f'{model} has no price in DRAFTERS; add it (list price, labelled an estimate) first')
    G.CACHE, G.CAP, G.MODEL = OUT / 'gateway', CAP, model
    G.PRICE = DRAFTERS[model][2:]
    return G


def cmd_models(_):
    import gateway_gemini as G
    key_ready(G)
    r = G.request('/models', timeout=60)
    r.raise_for_status()
    ids = sorted(m['id'] for m in r.json().get('data', []))
    scored = {x.split(',')[0] for x in (HERE.parents[1] / 'segbench-results/ocr-pages.csv').read_text().splitlines()[1:]}
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'models.json').write_text(json.dumps({'ids': ids}, indent=1))
    for i in ids:
        lab = DRAFTERS.get(i, (None,))[0]
        print(i, '\t', 'priced' if i in DRAFTERS else '-', '\t',
              'SCORED on the 96' if lab and lab.replace('-gw', '') in {s.replace('-gw', '') for s in scored} else '')
    print(len(ids), 'models; scored routes on the 96:', len(scored))


def draft_path(label, r) -> Path:
    return OUT / 'drafts' / label / f"{r['id']}.json"


_TURNS = None


def draft_image_bytes(r) -> bytes:
    """The page upright (the sheet's turn: clear wins and the eye check), at DRAFT_SIDE; the boxes come from the stored
    image's Vision words, matched by text, so the drafts' turn does not move them."""
    from PIL import Image
    global _TURNS
    if _TURNS is None:
        _TURNS = page_turns()
    with Image.open(image(r)) as im:
        im = im.convert('RGB').rotate(-_TURNS.get(r['key'], {}).get('turn', 0), expand=True)
        im.thumbnail((DRAFT_SIDE, DRAFT_SIDE), Image.LANCZOS)
        b = io.BytesIO()
        im.save(b, 'JPEG', quality=90)
    return b.getvalue()


def cmd_draft(a):
    G = gateway(a.drafter)
    label = DRAFTERS[a.drafter][0]
    rows = load_pages()[:a.limit] if a.limit else load_pages()
    jobs = [(r['id'], draft_image_bytes(r), draft_path(label, r)) for r in rows]
    p = prompt()
    G.run(label, jobs, p, concurrency=a.concurrency)
    for r in rows:   # an unparsed reply is read once more (a cut-off reply is a failed attempt, as ocr_truth's were)
        d = draft_path(label, r)
        if d.exists() and not parse(json.loads(d.read_text()).get('raw')):
            d.rename(d.with_suffix('.unparsed.json'))
            G.call(label, r['id'] + ':retry', draft_image_bytes(r), p, d)
    print(f'{label}: {sum(1 for r in rows if draft(label, r))}/{len(rows)} parsed; ${G.spent():.4f} spent in all')


def draft(label, r):
    d = draft_path(label, r)
    return parse(json.loads(d.read_text()).get('raw')) if d.exists() else None


# ---------------------------------------------------------------- compare (pure parts first)

def norm_tokens(text: str) -> tuple[list[str], list[str]]:
    """(raw whitespace tokens, their comparison keys: ocr_truth.words of each token joined)."""
    raw = text.split()
    return raw, [' '.join(T.words(t)) for t in raw]


def spans(a_text: str, b_text: str) -> list[dict]:
    """Agreed and disputed spans over A's and B's raw tokens; each keeps A's token range (t0, t1) for the box."""
    ra, ka = norm_tokens(a_text)
    rb, kb = norm_tokens(b_text)
    out = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, ka, kb, autojunk=False).get_opcodes():
        if op == 'equal':
            out.append({'agreed': ' '.join(ra[i1:i2]), 't0': i1, 't1': i2})
        else:
            out.append({'a': ' '.join(ra[i1:i2]), 'b': ' '.join(rb[j1:j2]), 't0': i1, 't1': i2})
    return out


def control_spans(sp: list[dict], rng: random.Random, n_words=6) -> list[dict]:
    """A random window of up to n_words agreed tokens per agreed span long enough (candidates for controls)."""
    out = []
    for i, s in enumerate(sp):
        if 'agreed' in s and s['t1'] - s['t0'] >= n_words:
            k = rng.randrange(s['t0'], s['t1'] - n_words + 1)
            toks = s['agreed'].split()
            out.append({'span': i, 'w0': k - s['t0'], 'w1': k - s['t0'] + n_words,
                        'text': ' '.join(toks[k - s['t0']:k - s['t0'] + n_words]), 't0': k, 't1': k + n_words})
    return out


def owner_minutes(n_pages: int, n_disputes: int, n_controls: int, n_topup: int, n_listed: int = 0) -> float:
    return (n_pages * SECONDS_PER_PAGE + n_disputes * (SECONDS_PER_DISPUTE + TYPED_SHARE * SECONDS_PER_TYPED)
            + n_controls * SECONDS_PER_CONTROL + n_topup * 3 + n_listed * SECONDS_PER_LISTED) / 60


def labels() -> tuple[str, str, str | None]:
    """(A, B, the tie-breaking third reader or None): drafters.json's "a", "b" and optional "c"."""
    f = OUT / 'drafters.json'
    if not f.exists():
        raise SystemExit(f'{f} is missing: write {{"a": "<label>", "b": "<label>"}} naming the two drafters')
    d = json.loads(f.read_text())
    return d['a'], d['b'], d.get('c')


def a_to_c(ops, i: int, start: bool, n_a: int, n_c: int) -> int | None:
    """Where A's token boundary i falls in C's tokens, or None unless the word beside it agrees: a span's start needs
    A's word before it matched in C, its end the word after it (the text's own ends count as matched)."""
    if start and i == 0:
        return 0
    if not start and i == n_a:
        return n_c
    for op, i1, i2, j1, _ in ops:
        if op == 'equal' and (i1 < i <= i2 if start else i1 <= i < i2):
            return j1 + (i - i1)
    return None


def tie_breaks(a_text: str, c_text: str, sp: list[dict]) -> None:
    """Adds to each disputed span C's reading of it ('c', None when C's words around it do not line up with A's) and
    'major': the side C matches exactly by the comparison keys, so the place settles 2 to 1 (owner, 2026-11-18)."""
    _, ka = norm_tokens(a_text)
    rc, kc = norm_tokens(c_text)
    ops = difflib.SequenceMatcher(None, ka, kc, autojunk=False).get_opcodes()
    for s in sp:
        if 'agreed' in s:
            continue
        j0 = a_to_c(ops, s['t0'], True, len(ka), len(kc))
        j1 = a_to_c(ops, s['t1'], False, len(ka), len(kc))
        s['c'] = ' '.join(rc[j0:j1]) if j0 is not None and j1 is not None and j0 <= j1 else None
        s['major'] = None
        if s['c'] is not None:
            got = kc[j0:j1]
            s['major'] = 'a' if got == norm_tokens(s['a'])[1] else 'b' if got == norm_tokens(s['b'])[1] else None


LOOP_N, LOOP_MIN = 8, 20


def trim_loop(text: str) -> str | None:
    """A draft that repeats one 8-word run 20 times or more; compare applies it only to a draft cut off at MAX_TOKENS,
    the decoding loop (Gemini 2.5 Flash on s044, twice), since a form that really repeats is not cut off. Keeps the
    text up to the run's second start, so the rest of the page is one dispute against the other reader, not
    thousands of repeated words. None when there is no loop."""
    w = text.split()
    seen, count = {}, collections.Counter()
    for i in range(len(w) - LOOP_N + 1):
        g = tuple(w[i:i + LOOP_N])
        count[g] += 1
        seen.setdefault(g, []).append(i)
    if not count:
        return None
    g, n = count.most_common(1)[0]
    return ' '.join(w[:seen[g][1]]) if n >= LOOP_MIN else None


def cmd_compare(_):
    la, lb, lc = labels()
    rows = load_pages()
    rng = random.Random(SEED)
    pages, missing, trimmed, no_c = [], [], [], []
    for r in rows:
        da, db = draft(la, r), draft(lb, r)
        dc = draft(lc, r) if lc else None
        if not (da and db):
            missing.append(r['id'])
            continue
        for side, lab, d in (('a', la, da), ('b', lb, db), ('c', lc, dc)):
            if not d:
                continue
            cut = json.loads(draft_path(lab, r).read_text())['meta'].get('finish') == 'length'
            if cut and (t := trim_loop(d['text'])) is not None:
                trimmed.append(f"{r['id']}:{side}")
                d['text'] = t
        sp = spans(da['text'], db['text'])
        if dc:
            tie_breaks(da['text'], dc['text'], sp)
        elif lc:
            no_c.append(r['id'])                 # every dispute on the page goes to the owner
        pages.append({'id': r['id'], 'spans': sp, 'controls': control_spans(sp, rng),
                      'kind': [da['kind'], db['kind']], 'table': [da['table'], db['table']],
                      'language': [da['language'], db['language']], 'a_text': da['text'], 'b_text': db['text'],
                      'c_text': dc['text'] if dc else None})
    pool = [(p['id'], c) for p in pages for c in p['controls']]
    chosen = set()
    for pid, c in rng.sample(pool, min(CONTROLS, len(pool))):
        chosen.add((pid, c['span'], c['t0']))
    for p in pages:
        p['controls'] = [c for c in p['controls'] if (p['id'], c['span'], c['t0']) in chosen]
    (OUT / 'compare.json').write_text(json.dumps({'a': la, 'b': lb, 'c': lc, 'missing': missing, 'no_c': no_c,
                                                  'trimmed': trimmed, 'pages': pages}, ensure_ascii=False, indent=1))
    s = summary(rows, pages, missing)
    print(json.dumps({**s, 'loops_trimmed': trimmed, 'pages_without_c': no_c}, indent=1))


def not_english(langs) -> bool:
    return any(l and not l.lower().startswith('english') for l in langs)


def summary(rows, pages, missing) -> dict:
    disp = [s for p in pages for s in p['spans'] if 'agreed' not in s]
    major = collections.Counter(s['major'] for s in disp if s.get('major'))
    n_ctrl = sum(len(p['controls']) for p in pages)
    by_id = {r['id']: r for r in rows}
    n_top = sum(1 for p in pages if by_id[p['id']]['set'] == 'topup')
    words = sum(len(p['a_text'].split()) for p in pages)
    disp_words = sum(max(len(s['a'].split()), len(s['b'].split())) for s in disp)
    n_asked = len(disp) - sum(major.values())
    return {'pages': len(pages), 'missing': len(missing), 'topup': n_top, 'disputes': len(disp),
            'settled_2_to_1': dict(major), 'c_unaligned': sum(1 for s in disp if 'c' in s and s['c'] is None),
            'disputes_asked': n_asked, 'controls': n_ctrl, 'words': words, 'disputed_words': disp_words,
            'pages_without_dispute': sum(1 for p in pages if all('agreed' in s for s in p['spans'])),
            'pages_without_question': sum(1 for p in pages if all('agreed' in s or s.get('major') for s in p['spans'])),
            'not_english_by_a_drafter': sum(1 for p in pages if not_english(p['language'])),
            'kinds': collections.Counter(p['kind'][0] if p['kind'][0] == p['kind'][1] else 'readers differ' for p in pages),
            'owner_minutes': round(owner_minutes(len(pages), n_asked, n_ctrl, n_top, sum(major.values())))}


# ---------------------------------------------------------------- the sheet

def vision_words(v: dict) -> list[list]:
    """Vision's words in its reading order as ocr_truth_bias.locate takes them: [text, x, y, w, h] (0-1, top left)."""
    words = []
    for ln in v['lines']:
        for w in ln.get('words') or [{'text': ln['text'], 'quad': ln['quad']}]:
            xs, ys = [q[0] for q in w['quad']], [q[1] for q in w['quad']]
            words.append([w['text'], min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)])
    return words


def listed_tags(tags):
    return ', '.join(t for t in tags if t not in T.ID_IGNORED) or 'none'


def both(vals) -> str:
    """An unasked field as the drafters gave it, unattributed: one value, or both when they differ."""
    v = ['yes' if x is True else 'no' if x is False else (x or '?') for x in vals]
    return v[0] if v[0] == v[1] else f'{" / ".join(sorted(set(v)))} (the readers differ)'


def context_tokens(sp: list[dict], n: int) -> list[str]:
    """A's tokens as the sheet may show them around a place: agreed words as they are, a disputed word as '…', so
    the context never shows one reader's side of a neighbouring dispute."""
    out = ['…'] * n
    for s in sp:
        if 'agreed' in s:
            out[s['t0']:s['t1']] = s['agreed'].split()
    return out


def build(cmp: dict, rows: list[dict], turns: dict, vision: dict) -> tuple[list, dict]:
    """(the sheet's items, the private key). Each place is a dispute (both readings, seeded order) or a control
    (the agreed reading); the box comes from A's token positions through Vision's words, so it says where to look,
    never which reading is which."""
    import ocr_truth_bias as B
    by_id = {r['id']: r for r in rows}
    items, key = [], {'build': None, 'a': cmp['a'], 'b': cmp['b'], 'c': cmp.get('c'), 'pages': {}}
    for p in cmp['pages']:
        r = by_id[p['id']]
        rng = random.Random(f"{SEED}:{p['id']}")
        raw_a = p['a_text'].split()
        shown = context_tokens(p['spans'], len(raw_a))
        vw = vision.get(r['key'])
        n_a = max(1, len(raw_a))
        places, kp = [], {}

        def box(t0, t1):
            b = B.locate(raw_a, vw, t0, max(t1, t0 + 1)) if vw else None
            return b, (None if b else round(100 * t0 / n_a))

        for i, s in enumerate(p['spans']):
            if 'agreed' in s:
                continue
            opts = [('a', s['a']), ('b', s['b'])]
            rng.shuffle(opts)
            bx, at = box(s['t0'], s['t1'])
            pid = f'd{i}'
            if s.get('major'):                   # settled 2 to 1: listed with the reading it takes, not asked
                places.append({'id': pid, 'kind': 'listed', 'texts': [s[s['major']]], 'box': bx, 'at': at,
                               'left': ' '.join(shown[max(0, s['t0'] - 6):s['t0']]),
                               'right': ' '.join(shown[s['t1']:s['t1'] + 6])})
                kp[pid] = {'span': i, 'majority': s['major']}
                continue
            places.append({'id': pid, 'kind': 'dispute', 'texts': [o[1] for o in opts], 'box': bx, 'at': at,
                           'left': ' '.join(shown[max(0, s['t0'] - 6):s['t0']]), 'right': ' '.join(shown[s['t1']:s['t1'] + 6])})
            kp[pid] = {'span': i, 'options': [o[0] for o in opts]}
        for c in p['controls']:
            bx, at = box(c['t0'], c['t1'])
            pid = f"c{c['span']}_{c['w0']}"
            places.append({'id': pid, 'kind': 'control', 'texts': [c['text']], 'box': bx, 'at': at,
                           'left': ' '.join(shown[max(0, c['t0'] - 6):c['t0']]), 'right': ' '.join(shown[c['t1']:c['t1'] + 6])})
            kp[pid] = {'span': c['span'], 'w0': c['w0'], 'w1': c['w1'], 'control': True}
        places.sort(key=lambda x: (int(re.match(r'[dc](\d+)', x['id']).group(1)), x['id']))
        places = [x for x in places if x['kind'] != 'listed'] + [x for x in places if x['kind'] == 'listed']
        tn = turns.get(r['key'], {'turn': 0, 'close': None, 'how': 'not checked'})
        fields = [('folder tags', listed_tags(r['tags'])), ('kind of writing', both(p['kind'])),
                  ('mostly a table or form', both(p['table'])), ('language', both(p['language'])),
                  ('image', 'JPEG original' if r['source'] == 'original' else 'the PDF\'s image (no original found)')]
        if r['set'] == 'base':
            fields.append(('has text', 'a page of text (your answer of 11 Nov)'))
        items.append({'page': p['id'], 'img': os.path.relpath(image(r), OUT / 'sheet'), 'turn': tn['turn'],
                      'ask_text': r['set'] == 'topup', 'fields': fields, 'places': places,
                      'flag_language': not_english(p['language'])})
        key['pages'][p['id']] = {'places': kp, 'a_sha': hashlib.sha256(p['a_text'].encode()).hexdigest(),
                                 'turn': tn, 'set': r['set']}
    key['build'] = hashlib.sha256(json.dumps(items, sort_keys=True).encode()).hexdigest()[:12]
    return items, key


def cmd_sheet(_):
    sheet = OUT / 'sheet'
    if (sheet / 'answers.json').exists():
        raise SystemExit(f'{sheet / "answers.json"} exists: the sheet is answered; it is not rebuilt')
    cmp = json.loads((OUT / 'compare.json').read_text())
    rows = load_pages()
    vision = {}
    for r in rows:
        f = lines_path(r)
        if f.exists():
            vision[r['key']] = vision_words(json.loads(f.read_text()))
    items, key = build(cmp, rows, page_turns(), vision)
    sheet.mkdir(parents=True, exist_ok=True)
    s = summary(rows, cmp['pages'], cmp['missing'])
    n_boxed = sum(1 for it in items for x in it['places'] if x['box'])
    n_places = sum(len(it['places']) for it in items)
    page = (SHEET_HTML.replace('__ITEMS__', json.dumps(items, ensure_ascii=False)).replace('__BUILD__', key['build'])
            .replace('__N__', str(len(items))).replace('__MIN__', str(s['owner_minutes']))
            .replace('__TURNED__', str(sum(1 for i in items if i['turn'])))
            .replace('__TOPUP__', str(sum(1 for i in items if i['ask_text']))))
    (sheet / 'index.html').write_text(page)
    (sheet / 'key.json').write_text(json.dumps(key, indent=1))
    print(sheet / 'index.html', len(items), 'pages,', n_places, 'places,', n_boxed, 'boxed;',
          sum(1 for i in items if i['turn']), 'turned; about', s['owner_minutes'], 'min')


SHEET_HTML = r"""<!doctype html><meta charset="utf-8"><title>W46 owner set: disputed words</title>
<style>body{font:15px -apple-system,sans-serif;margin:0;display:flex;height:100vh}
#side{width:440px;padding:12px;overflow:auto;border-right:1px solid #ccc;box-sizing:border-box}
#main{flex:1;position:relative;overflow:auto;background:#333;display:flex;align-items:center;justify-content:center}
#wrap{position:relative;transition:transform .1s}#wrap img{display:block;max-height:92vh;max-width:none;background:#fff}
.bx{position:absolute;border:3px solid #f0a;background:rgba(255,0,170,.08)}.bx.cur{border-color:#0af}
.bx.ls{border:2px dashed #999;background:none}.bx.ls.cur{border-color:#0af}.pl.ls{border-style:dashed;color:#444}
.k{display:inline-block;border:1px solid #888;border-radius:4px;padding:1px 6px;margin:2px;cursor:pointer}
.k.on{background:#2a6;color:#fff;border-color:#2a6}textarea,input[type=text]{width:100%;box-sizing:border-box}
.pl{border:1px solid #ddd;border-radius:5px;padding:6px;margin:6px 0}.pl.cur{border-color:#0af;background:#f4fbff}
.ctx{color:#777}.opt{font-family:Menlo,monospace;font-size:14px}small{color:#555}.warn{color:#b40}
#bar{height:6px;background:#2a6}</style>
<div id="side"><h3>Disputed words, __N__ pages</h3>
<p><small>About __MIN__ minutes in all; answers save in this browser as you go, so it can be done in several sittings.
Each page lists the places where the two readers differ (pick the reading that matches the page, or type it) and a
few places where they agree (say whether the words match the page). The readings are in no particular order and
nothing says which reader gave which. Below them, grey and dashed, are places where a third reader matched one
of the two exactly: those are settled 2 to 1 and only listed, with the reading they take; nothing to do unless one
is wrong, and then a note on it says so. The box on the image marks roughly where each place is; with no box, the
place says how far through the page's text it falls. Keys: <b>1</b>/<b>2</b> pick, <b>t</b> type, <b>e</b> can't tell,
<b>y</b>/<b>n</b> on an agreed place, <b>↓</b>/<b>↑</b> next/previous place, <b>←</b>/<b>→</b> page, <b>r</b> turn the page.
Keys do nothing while you type in a box. __TURNED__ pages were turned upright before the sheet was built (a clear
text score only); turn any page that is still not upright, and its boxes turn with it. __TOPUP__ pages are new to
you and ask one more thing first: does the page have text? Every other field listed under a page goes in as listed;
a note can correct it, or say the page should be dropped (not English, not one page, anything).</small></p>
<div id="bar"></div><p id="pos"></p><div id="ask"></div>
<div id="fields"></div><div id="places"></div>
<p>Note on this page (optional)<br><textarea id="note" rows="3"></textarea></p>
<p><span class="k" id="prev">← page</span><span class="k" id="next">page →</span><span class="k" id="rot">r turn</span>
<span class="k" id="todo">next unanswered</span><span class="k" id="exp">Export</span></p>
<p>Note on the whole sheet (optional)<br><textarea id="snote" rows="2"></textarea></p></div>
<div id="main"><div id="wrap"><img id="im"></div></div>
<script>
const items=__ITEMS__;const BUILD='__BUILD__';const KEY='w46-owner-set-grow-'+BUILD;
let A=JSON.parse(localStorage.getItem(KEY)||'{}');A._build=BUILD;A._notes=A._notes||{};A._turns=A._turns||{};
const save=()=>localStorage.setItem(KEY,JSON.stringify(A));
let pi=0,cur=0;const $=id=>document.getElementById(id);
const esc=s=>(s||'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
function ans(p,id){return (A[p]||{})[id]}
function setAns(p,id,v){A[p]=A[p]||{};A[p][id]=v;save();}
function done(it){return (!it.ask_text||ans(it.page,'_text'))&&it.places.every(x=>x.kind=='listed'||ans(it.page,x.id)!=null)}
function turn(it){return ((it.turn||0)+(A._turns[it.page]||0))%360}
function show(){const it=items[pi];$('im').src=it.img;$('wrap').style.transform='rotate('+turn(it)+'deg)';
 $('pos').textContent='page '+(pi+1)+' of '+items.length+' ('+it.page+')'+(done(it)?' ✓':'');
 $('bar').style.width=(100*items.filter(done).length/items.length)+'%';
 $('ask').innerHTML=it.ask_text?'<p><b>Does this page have text?</b> '+['1 no text','2 a few words','3 a page of text']
  .map((t,i)=>'<span class="k'+(ans(it.page,'_text')==String(i+1)?' on':'')+'" data-t="'+(i+1)+'">'+t+'</span>').join('')+'</p>':'';
 $('fields').innerHTML='<p><small>Listed, not asked: '+it.fields.map(f=>'<b>'+esc(f[0])+'</b>: '+esc(f[1])).join(' · ')+'</small></p>'
  +(it.flag_language?'<p class="warn">A reader thinks this page is not in English: say so in the note if it should be dropped.</p>':'');
 $('places').innerHTML=it.places.length?'':'<p><small>The readers agree on every word of this page.</small></p>';
 it.places.forEach((x,i)=>{const a=ans(it.page,x.id);const d=document.createElement('div');d.className='pl'+(x.kind=='listed'?' ls':'')+(i==cur?' cur':'');
  let h='<small>'+(x.kind=='dispute'?'The readers differ':x.kind=='listed'?'Settled 2 to 1, listed, not asked':'The readers agree')+(x.box?'':' · no box: about '+x.at+'% through the text')+'</small><br>'
   +'<span class="ctx">…'+esc(x.left)+'</span> <b>[ ]</b> <span class="ctx">'+esc(x.right)+'…</span><br>';
  if(x.kind=='dispute'){x.texts.forEach((t,j)=>{h+='<span class="k opt'+(a==String(j+1)?' on':'')+'" data-p="'+i+'" data-v="'+(j+1)+'">'+(j+1)+' '+(esc(t)||'<i>(nothing here)</i>')+'</span><br>'});
   h+='<span class="k'+(a=='either'?' on':'')+'" data-p="'+i+'" data-v="either">e can\'t tell</span>';}
  else if(x.kind=='listed')h+='<span class="opt">'+(esc(x.texts[0])||'<i>(nothing here)</i>')+'</span>';
  else{h+='<span class="opt">'+esc(x.texts[0])+'</span><br><span class="k'+(a=='y'?' on':'')+'" data-p="'+i+'" data-v="y">y matches the page</span>'
   +'<span class="k'+(a&&a.startsWith('=')?' on':'')+'" data-p="'+i+'" data-v="t">n wrong: type it</span>';}
  if(x.kind=='dispute')h+='<span class="k'+(a&&a.startsWith('=')?' on':'')+'" data-p="'+i+'" data-v="t">t type it</span>';
  if(a&&a.startsWith('='))h+='<br><small>typed: </small><span class="opt">'+esc(a.slice(1))+'</span>';
  h+='<br><input type="text" placeholder="note on this place (optional)" data-n="'+i+'" value="'+esc(A._notes[it.page+'/'+x.id]||'')+'">';
  d.innerHTML=h;$('places').appendChild(d);});
 $('note').value=A._notes[it.page]||'';$('snote').value=A._notes._sheet||'';drawBoxes();}
function drawBoxes(){const it=items[pi];document.querySelectorAll('.bx').forEach(b=>b.remove());
 it.places.forEach((x,i)=>{if(!x.box)return;const b=document.createElement('div');b.className='bx'+(x.kind=='listed'?' ls':'')+(i==cur?' cur':'');
  b.style.left=(100*x.box[0])+'%';b.style.top=(100*x.box[1])+'%';b.style.width=(100*x.box[2])+'%';b.style.height=(100*x.box[3])+'%';
  $('wrap').appendChild(b);});}
function pick(i,v){const it=items[pi],x=it.places[i];if(v=='t'){const t=prompt('Type the words as they are on the page (leave empty for "no words here"):',
  x.kind=='control'?x.texts[0]:'');if(t===null)return;v='='+t;}setAns(it.page,x.id,v);cur=Math.min(i+1,it.places.length-1);show();}
document.addEventListener('click',e=>{const t=e.target.closest('.k');if(!t)return;
 if(t.dataset.t){setAns(items[pi].page,'_text',t.dataset.t);show();}
 else if(t.dataset.p!=null)pick(+t.dataset.p,t.dataset.v);});
document.addEventListener('input',e=>{const it=items[pi];
 if(e.target.id=='note')A._notes[it.page]=e.target.value;else if(e.target.id=='snote')A._notes._sheet=e.target.value;
 else if(e.target.dataset.n!=null)A._notes[it.page+'/'+it.places[+e.target.dataset.n].id]=e.target.value;save();});
function go(d){pi=Math.max(0,Math.min(items.length-1,pi+d));cur=0;show();}
$('prev').onclick=()=>go(-1);$('next').onclick=()=>go(1);
$('rot').onclick=()=>{const p=items[pi].page;A._turns[p]=((A._turns[p]||0)+90)%360;save();show();};
$('todo').onclick=()=>{const j=items.findIndex(it=>!done(it));if(j>=0){pi=j;cur=0;show();}};
$('exp').onclick=()=>{const b=new Blob([JSON.stringify(A,null,1)],{type:'application/json'});const u=document.createElement('a');
 u.href=URL.createObjectURL(b);u.download='owner-set-grow-answers.json';u.click();};
document.addEventListener('keydown',e=>{if(['TEXTAREA','INPUT'].includes(e.target.tagName))return;const it=items[pi];
 const x=it.places[cur];if(e.key=='ArrowRight')go(1);else if(e.key=='ArrowLeft')go(-1);
 else if(e.key=='ArrowDown'){cur=Math.min(cur+1,it.places.length-1);show();}else if(e.key=='ArrowUp'){cur=Math.max(cur-1,0);show();}
 else if(e.key=='r')$('rot').click();else if(!x||x.kind=='listed')return;
 else if(x.kind=='dispute'&&['1','2'].includes(e.key))pick(cur,e.key);else if(x.kind=='dispute'&&e.key=='e')pick(cur,'either');
 else if(e.key=='t'||(x.kind=='control'&&e.key=='n'))pick(cur,'t');else if(x.kind=='control'&&e.key=='y')pick(cur,'y');
 else return;e.preventDefault();});
show();
</script>"""


# ---------------------------------------------------------------- fold

def fold(cmp: dict, key: dict, answers: dict) -> dict:
    """{page id: {'text', 'status', 'counts', 'note', 'drop', 'two_to_one_words'}}: the truth from the spans and the
    owner's rulings. A place settled 2 to 1 takes the majority's reading; its [first, past-last) word positions in the
    text are kept, so a route can be scored with and without those places (owner, 2026-11-18). A dispute takes his pick or his typed text; 'can't tell' takes neither reader's words as settled: the page is
    kept with the place as [illegible] and counted. A control he marks wrong replaces those agreed words. A top-up
    page he does not call a page of text is dropped, and so is a page both drafters call non-English."""
    if answers.get('_build') != key['build']:
        raise SystemExit('these answers are from another build of the sheet')
    notes = answers.get('_notes') or {}
    out = {}
    for p in cmp['pages']:
        pid, kp = p['id'], key['pages'][p['id']]
        if hashlib.sha256(p['a_text'].encode()).hexdigest() != kp['a_sha']:
            raise SystemExit(f'{pid}: the draft changed since the sheet was built')
        got = answers.get(pid) or {}
        c = collections.Counter()
        drop = None
        if kp['set'] == 'topup' and got.get('_text') != '3':
            drop = 'top-up page not a page of text' if got.get('_text') else 'top-up page unanswered'
        langs = p['language']
        if all(l and not l.lower().startswith('english') for l in langs):
            drop = drop or 'both drafters: not English'
        ctrl = {}
        for pl, v in kp['places'].items():
            if v.get('control'):
                ctrl.setdefault(v['span'], []).append((pl, v))
        parts, open_, maj = [], False, []
        for i, s in enumerate(p['spans']):
            if 'agreed' in s:
                toks = s['agreed'].split()
                for pl, v in sorted(ctrl.get(i, []), key=lambda e: -e[1]['w0']):
                    a = got.get(pl)
                    if a is None:
                        c['control open'] += 1
                    elif a == 'y':
                        c['control right'] += 1
                    else:
                        c['control wrong'] += 1
                        toks[v['w0']:v['w1']] = a[1:].split()
                parts.append(' '.join(toks))
                continue
            pl = f'd{i}'
            if side := kp['places'][pl].get('majority'):
                c[f'dispute 2 to 1 {side}'] += 1        # listed, not asked; a place note is read before scoring
                w0 = sum(len(x.split()) for x in parts)
                maj.append([w0, w0 + len(s[side].split())])
                parts.append(s[side])
                continue
            a = got.get(pl)
            opts = kp['places'][pl]['options']
            if a is None:
                c['dispute open'] += 1
                open_ = True
            elif a == 'either':
                c["dispute can't tell"] += 1
                parts.append('[illegible]')
            elif a.startswith('='):
                c['dispute typed'] += 1
                parts.append(a[1:].strip())
            else:
                side = opts[int(a) - 1]
                c[f'dispute picked {side}'] += 1
                parts.append(s[side])
        out[pid] = {'text': None if open_ else ' '.join(x for x in parts if x), 'status': 'open' if open_ else 'settled',
                    'counts': dict(c), 'note': notes.get(pid), 'drop': drop, 'two_to_one_words': maj,
                    'place_notes': {k.split('/', 1)[1]: v for k, v in notes.items() if k.startswith(pid + '/') and v}}
    return out


def cmd_fold(a):
    cmp = json.loads((OUT / 'compare.json').read_text())
    key = json.loads((OUT / 'sheet' / 'key.json').read_text())
    answers = json.loads(Path(a.answers).read_text())
    res = fold(cmp, key, answers)
    (OUT / 'truth').mkdir(exist_ok=True)
    for pid, r in res.items():
        if r['text'] is not None and not r['drop']:
            (OUT / 'truth' / f'{pid}.txt').write_text(r['text'] + '\n')
    (OUT / 'rulings.json').write_text(json.dumps({'build': key['build'], 'sheet_note': (answers.get('_notes') or {}).get('_sheet'),
                                                  'turns': answers.get('_turns') or {}, 'pages': res}, ensure_ascii=False, indent=1))
    tot = collections.Counter()
    for r in res.values():
        tot.update(r['counts'])
    print(json.dumps({'pages': len(res), 'settled': sum(1 for r in res.values() if r['status'] == 'settled' and not r['drop']),
                      'dropped': collections.Counter(r['drop'] for r in res.values() if r['drop']),
                      'notes to read': sum(1 for r in res.values() if r['note'] or r['place_notes']),
                      'counts': tot}, indent=1))
    print('Read every note before scoring: a note can correct a listed field or drop a page.')


def spent_usd() -> float:
    import gateway_gemini as G
    G.CACHE = OUT / 'gateway'
    return G.spent() if (G.CACHE / 'calls.jsonl').exists() else 0.0


def cmd_report(_):
    """segbench-results/owner-set-grow.md from what the cache holds now: counts only (the repo is public)."""
    d = json.loads((OUT / 'draw.json').read_text())
    rows = load_pages()
    cmp = json.loads((OUT / 'compare.json').read_text()) if (OUT / 'compare.json').exists() else None
    rul = json.loads((OUT / 'rulings.json').read_text()) if (OUT / 'rulings.json').exists() else None
    turns = page_turns() if (OUT / 'orient.json').exists() else {}
    src = collections.Counter(r['source'] for r in rows)
    L = ['# W46.owner-set-grow: S1, about 200 more random owner pages beside the 96', '',
         'Owner review of the pipeline doc, 2026-11-17: the 96 resolve about 3 NES on a typical pair of routes, and 730-2,303 '
         'pages are needed for 1 point (`execution-plans/benchmark-corpus/00-plan.md` §4). S1 adds about 200 pages; the 96 '
         '(S0) stay frozen. Built by `scripts/segbench/owner_set_grow.py`; images, drafts and the sheet stay in the bench '
         'cache, since the pages are the owner\'s.', '', '## The draw', '',
         f"- Base: W46.ocr-vision-unfiltered's {d['unfiltered_drawn']} hashed-draw pages (one page per document, uniform "
         f"over the {d['pool_docs']:,} documents of the 96's pool that hold none of the 96's pages), of which the owner "
         f"answered \"a page of text\" for {d['base_kept']} on 11 Nov ({d['base_answers'].get('2', 0)} \"a few words\", "
         f"{d['base_answers'].get('1', 0)} \"no text\").",
         f"- Top-up: the next {d['topup']} documents of the same hashed order (the rebuilt order holds the first draw's "
         f"{d['unfiltered_drawn']} as its first {d['last_base_position'] + 1}); {len(d['failed'])} document passed over "
         'as unreadable from disk. The owner answers the has-text question for these on the sheet.',
         f"- {len(rows)} pages in all. Images: " + ', '.join(f'{n} {k}' for k, n in src.most_common()) + '.']
    if turns:
        sc = json.loads((OUT / 'orient.json').read_text())['scores']
        doubt = sum(1 for k, v in sc.items() if max(range(4), key=lambda i: v[i]) and not clear_turn(v)[0])
        L.append(f"- Upright: {sum(1 for t in turns.values() if t['turn'])} pages turned for the sheet. ocr_orient.swift's "
                 f"scores gave {sum(1 for v in sc.values() if clear_turn(v)[0])} clear wins and {doubt} pages where "
                 f"another turn scored highest without one. All {doubt + sum(1 for v in sc.values() if clear_turn(v)[0])} were "
                 f"judged by eye on four-turn thumbnails, {sum(1 for t in turns.values() if t['how'] == 'eye')} recorded in "
                 "orient-eye.tsv (two clear wins were wrong: upright handwriting that Vision "
                 "read better upside down). Up and upside down score alike on most pages, so the rest stay as stored, "
                 "and the sheet has a turn button.")
    if cmp:
        s = summary(rows, cmp['pages'], cmp['missing'])
        L += ['', '## The drafts and the sheet', '',
              f"Drafters, blind: {cmp['a']} and {cmp['b']}, through the gateway. {s['pages']} pages drafted by both "
              f"({s['missing']} missing). {s['words']:,} words; {s['disputes']:,} disputed spans covering "
              f"{s['disputed_words']:,} words; {s['pages_without_dispute']} pages with none; {s['controls']} agreed "
              f"controls. A drafter calls {s['not_english_by_a_drafter']} pages not English. Estimated owner time: "
              f"about {s['owner_minutes']} minutes (ocr_truth's per-page and per-dispute rates: an estimate, not a timing)."
              + (f" A draft cut off in a decoding loop is kept to its first pass ({', '.join(cmp.get('trimmed', []))}), so "
                 "the rest of that page is one dispute." if cmp.get('trimmed') else '')]
        if cmp.get('c'):
            m = s['settled_2_to_1']
            L += ['', f"Third reader, blind, to break ties (owner, 2026-11-18): {cmp['c']}, through the gateway, on "
                  f"{s['pages'] - len(cmp.get('no_c', []))} of the {s['pages']} pages. Where its words at a disputed place "
                  f"match one draft exactly, the place settles 2 to 1 and is listed on the sheet, not asked: "
                  f"{m.get('a', 0) + m.get('b', 0):,} of the {s['disputes']:,} ({m.get('a', 0):,} for {cmp['a']}, "
                  f"{m.get('b', 0):,} for {cmp['b']}); at {s['c_unaligned']:,} more its neighbouring words do not line "
                  f"up with A's, so it is not read there. {s['disputes_asked']:,} places are asked."]
        if spent_usd():
            L += ['', f"Gateway spend for the item: ${spent_usd():.2f} (the larger of the gateway's figure and the "
                  "list-price estimate, per call), pilots of four candidate drafters on 5 pages included."]
    if rul:
        tot = collections.Counter()
        for r in rul['pages'].values():
            tot.update(r['counts'])
        kept = [r for r in rul['pages'].values() if r['status'] == 'settled' and not r['drop']]
        L += ['', '## The owner\'s rulings', '', f"{len(kept)} pages settled and kept; dropped: " +
              (', '.join(f'{n} {k}' for k, n in collections.Counter(r['drop'] for r in rul['pages'].values() if r['drop']).items()) or 'none')
              + '. ' + ', '.join(f'{k} {n}' for k, n in sorted(tot.items())) + '.']
    L += ['', '## Measurement card', '',
          '- **Truth:** ' + ('two gateway drafters blind, every disputed span and the controls ruled by the owner on a '
                              'blind sheet with boxes.' if rul else 'not made yet: the drafts and the owner\'s sheet are pending.'),
          '- **Selection:** a hashed draw, one page per document, uniform over documents; the text filter is the owner\'s '
          'own answer, not a route\'s reading; English by the drafters\' language line, the owner able to overrule.',
          '- **Comparison:** S1 is scored with the same scorer and settings as the 96 (`ocr_panel_score`), and reported '
          'beside it, never pooled into the 96\'s figures.',
          '- **Noise:** with about 200 pages a typical pair resolves about 2 NES (n = (2.8 σd / Δ)², σd 9.7); pooled with '
          'the 96, about 1.6. Not yet 1 point.',
          '- **Scope:** the owner\'s English collections only. No drafter is scored on the 96, but each has kin '
          'that are (GPT-5.4 Mini and GPT-5.6 Luna; the Gemini 3.x routes; Claude Sonnet 5.5 for the tie-breaker, '
          'Sonnet 5), so a kin route may gain on agreed words and on places settled 2 to 1; the controls measure how '
          'often the owner overrules an agreed word, they do not remove the gain. Sonnet 5.5\'s S1 score is to be '
          'reported with and without the 2-to-1 places (owner, 2026-11-18; the fold keeps their word positions).', '']
    RESULTS.write_text('\n'.join(L))
    print(RESULTS)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('draw').set_defaults(fn=cmd_draw)
    sub.add_parser('vision').set_defaults(fn=cmd_vision)
    sub.add_parser('models').set_defaults(fn=cmd_models)
    d = sub.add_parser('draft')
    d.add_argument('--drafter', required=True, choices=sorted(DRAFTERS))
    d.add_argument('--limit', type=int, default=0, help='the first N pages only (a pilot)')
    d.add_argument('--concurrency', type=int, default=4)
    d.set_defaults(fn=cmd_draft)
    sub.add_parser('compare').set_defaults(fn=cmd_compare)
    sub.add_parser('report').set_defaults(fn=cmd_report)
    sub.add_parser('sheet').set_defaults(fn=cmd_sheet)
    f = sub.add_parser('fold')
    f.add_argument('answers')
    f.set_defaults(fn=cmd_fold)
    a = ap.parse_args()
    a.fn(a)


if __name__ == '__main__':
    main()
