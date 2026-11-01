#!/usr/bin/env python3
"""W46.fix-marks-set-draft: draw the 150-page marks set from the 1,014-page pre-flag scan, and draft it.

  python3 marks_set.py select                 # the draw and the owner core -> CACHE/selection.json + segbench-results
  /usr/local/bin/python3 marks_set.py gemini [--limit N]   # Gemini 3.7 Flash through the Stanford gateway (real money)
  python3 ops/autonomous/heavy-run.py run -- ~/.local/share/visionocr-ocrlab/venv/bin/python marks_set.py local
                                              # Qwen3-VL 8B, 4-bit MLX, on this Mac ($0)
  python3 marks_set.py report                 # segbench-results/marks-set-draft.{md,json}

The draw answers the measurement audit (execution-plans/processing-review/11-measurement-audit.md MRK-1): the scan's
pre-flagger is Qwen3.6-27B, which W46.marks-detect will rank, so the set must not be chosen only from its flags.
Phase A draws 50 pages of the 1,014 uniformly within each collection, whatever the flag said. Phase B draws 100
more from the rest, enriched by the pre-flag's handwriting band so the owner's four bands can each be scored
(W46.mixed-route-bands). Every page carries its stratum and the probability it was drawn; for phase B that is
conditional on phase A's draw (the stratum's remaining count), and the unconditional figure is given as
pA + (1 - pA) * pB, which is exact for phase A and close for phase B. The owner core of 40 is drawn from both
phases in fixed numbers, its probabilities recorded the same way.

Drafting uses two families, neither the pre-flagger (MRK-1): Gemini 3.7 Flash through the gateway, and Qwen3-VL 8B
locally. Both get the same instruction, each in its own native box form, normalised here to [x0, y0, x1, y1]
fractions of the image. The drafts are not truth: the owner checks the core; the other 110 pages are two drafts and
their agreement. No Claude session or subagent reads the pages (owner, 2026-10-30); the report reads only the drafts'
JSON. Images, replies and drafts stay in CACHE (the owner's material); committed results hold page ids and numbers.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]

SCAN = Path.home() / '.local/state/archive-autonomous/artifacts/marks-scan-20261029'
REHEARSAL = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
CACHE = REHEARSAL / 'marks-set'
RESULTS = HERE.parents[1] / 'segbench-results'
SEED = 'W46.fix-marks-set-draft-set-20261031'
COLLECTIONS = ('Dean', 'Deaver', 'Herrnstein', 'Stanton', 'RG165')
CLASSES = ('annotation', 'marginal_note', 'stamp', 'signature_initials', 'redaction', 'other')
HAND = ('annotation', 'marginal_note', 'signature_initials')
AMOUNTS = ('none', 'signature_initials_date', 'under_10_words', '10_29_words', '30_plus_words', 'handwritten_page')
SET_SIZE = 150
PHASE_A = {'Dean': 11, 'Deaver': 11, 'Herrnstein': 11, 'Stanton': 11, 'RG165': 6}   # ~ 50 x N_c / 1,014
# Phase B by pre-flag band: None = every remaining page; an int = that many in seed order; a dict = per collection.
PHASE_B = {'30_plus_words': None, '10_29_words': None, 'handwritten_page': 4,
           'signature_initials_date': {c: 4 for c in COLLECTIONS}, 'under_10_words': {c: 4 for c in COLLECTIONS}}
CORE_A = 16
CORE_B = {'30_plus_words': 6, '10_29_words': 6, 'signature_initials_date': 4, 'under_10_words': 4,
          'handwritten_page': 1, 'none': 3}

INSTRUCTION = '''This is a photograph of one archival page. Find every mark on it: anything added to a typed or
printed page by hand or by a stamp. Classes:
- "annotation": handwriting within the body of the page (words between or over the lines, corrections, notes);
- "marginal_note": handwriting in a margin or above or below the text block;
- "stamp": a rubber, date, received, file or classification stamp;
- "signature_initials": a handwritten signature or initials (a handwritten date written with them belongs to them);
- "redaction": an area inked or blacked out by hand;
- "other": any other hand mark: ticks, lines, brackets, arrows, circled items, numbers without words.
These are NOT marks: text or ink showing through from the reverse; a printed or reproduced signature; typewriter
underlining, overstrikes or typed corrections; anything on a neighbouring page, an archive slip, a ruler or the
table. If the whole page is handwritten, page_kind is "handwritten" and its body is not a mark.
Return ONLY one JSON object, no Markdown:
{"page_kind": "typed_printed" | "handwritten" | "nontext",
 "marks": [{"class": one of the six classes, BOXSPEC,
            "overlaps_print": true if the mark touches or crosses printed or typed text,
            "legible": true if you can read it,
            "text": what a legible annotation, marginal note, stamp or other mark says ("" for signatures,
                    initials, redactions and anything illegible),
            "words": the number of handwritten words in the mark (0 for a stamp)}],
 "handwriting_amount": "none" | "signature_initials_date" | "under_10_words" | "10_29_words" | "30_plus_words" |
                       "handwritten_page",
 "uncertain": true if any part of your judgement is doubtful}
Give one box per mark; a note of several lines is one mark. An empty list when there are no marks.'''
BOX = {'gemini': '"box_2d": [ymin, xmin, ymax, xmax] on a 0-1000 scale of the image',
       'local': '"bbox_2d": [x1, y1, x2, y2] on a 0-1000 scale of the image'}


def prompt(route):
    return INSTRUCTION.replace('BOXSPEC', BOX[route])


def rank(pid):
    return hashlib.sha256((SEED + ':' + pid).encode()).hexdigest()


def load(path):
    return json.loads(Path(path).read_text())


def scan_rows(root=SCAN):
    """Every scanned page with its pre-flag (None for a reply that did not parse)."""
    scan = load(root / 'scan.json')
    rows = []
    for p in scan['pages']:
        rec = load(root / 'out' / (p['id'] + '.json'))
        pred = rec.get('prediction') if rec.get('status') == 'ok' else None
        rows.append(dict(id=p['id'], collection=p['collection'], image=p['image'], status=rec.get('status'),
                         amount=pred['handwriting_amount'] if pred else None,
                         flagged=bool(pred and any(pred['marks'].values())),
                         consistent=rec.get('consistent'), uncertain=bool(pred and pred['uncertain'])))
    return rows


def take(group, n):
    """n pages of group in seed order (all of them when n is None)."""
    group = sorted(group, key=lambda r: rank(r['id']))
    return group if n is None else group[:n]


def select(rows):
    by_c = defaultdict(list)
    for r in rows:
        by_c[r['collection']].append(r)
    chosen = {}
    for c in COLLECTIONS:
        n = PHASE_A[c]
        for r in take(by_c[c], n):
            chosen[r['id']] = dict(r, phase='A', stratum='A:' + c, p_phase=n / len(by_c[c]), p_a=n / len(by_c[c]))
    left = [r for r in rows if r['id'] not in chosen]

    def add(group, n, stratum, p_a):
        if not group:
            return
        got = take(group, n)
        for r in got:
            pb = len(got) / len(group)
            chosen[r['id']] = dict(r, phase='B', stratum=stratum, p_phase=pb, p_a=p_a(r))
    p_a_of = {c: PHASE_A[c] / len(by_c[c]) for c in COLLECTIONS}
    pa = lambda r: p_a_of[r['collection']]  # noqa: E731
    for band, q in PHASE_B.items():
        group = [r for r in left if r['amount'] == band]
        if isinstance(q, dict):
            for c in COLLECTIONS:
                add([r for r in group if r['collection'] == c], q[c], f'B:{band}:{c}', pa)
        else:
            add(group, q, 'B:' + band, pa)
    rest = SET_SIZE - len(chosen)
    none = [r for r in left if r['amount'] == 'none' and r['id'] not in chosen]
    per = {c: rest // len(COLLECTIONS) + (i < rest % len(COLLECTIONS)) for i, c in enumerate(COLLECTIONS)}
    for c in COLLECTIONS:
        add([r for r in none if r['collection'] == c], per[c], 'B:none:' + c, pa)
    if len(chosen) != SET_SIZE:
        raise SystemExit(f'drew {len(chosen)} pages, not {SET_SIZE}')
    for r in chosen.values():
        r['p_overall'] = r['p_a'] if r['phase'] == 'A' else r['p_a'] + (1 - r['p_a']) * r['p_phase']
        r['core'] = False
    # The owner core: CORE_A of phase A in seed order, and CORE_B by band from phase B.
    a = [r for r in chosen.values() if r['phase'] == 'A']
    for r in take(a, CORE_A):
        r['core'], r['p_core'] = True, CORE_A / len(a)
    b = [r for r in chosen.values() if r['phase'] == 'B']
    for band, n in CORE_B.items():
        group = [r for r in b if r['amount'] == band]
        got = take(group, n)
        for r in got:
            r['core'], r['p_core'] = True, len(got) / len(group)
    return sorted(chosen.values(), key=lambda r: (r['phase'], r['stratum'], rank(r['id'])))


def cmd_select(_):
    rows = scan_rows()
    pages = select(rows)
    core = [p for p in pages if p['core']]
    out = dict(protocol='marks-set-draw-v1', seed=SEED, scan=str(SCAN.name),
               scan_freeze_sha256=hashlib.sha256((SCAN / 'freeze.json').read_bytes()).hexdigest(),
               phase_a=PHASE_A, phase_b={k: v for k, v in PHASE_B.items()}, core_a=CORE_A, core_b=CORE_B,
               pages=len(pages), core=len(core),
               frame=dict(Counter(r['collection'] for r in rows)),
               frame_bands=dict(Counter(r['amount'] or 'unparsed' for r in rows)),
               note='Phase B and core probabilities are conditional on the earlier draw; p_overall approximates '
                    'the unconditional inclusion probability (exact for phase A).',
               rows=[{k: p[k] for k in ('id', 'collection', 'phase', 'stratum', 'amount', 'flagged', 'p_phase',
                                        'p_overall', 'core') if k in p} | ({'p_core': round(p['p_core'], 6)}
                                                                          if p['core'] else {})
                     for p in pages])
    for r in out['rows']:
        r['p_phase'], r['p_overall'] = round(r['p_phase'], 6), round(r['p_overall'], 6)
    CACHE.mkdir(parents=True, exist_ok=True)
    text = json.dumps(out, indent=1) + '\n'
    (CACHE / 'selection.json').write_text(text)
    (RESULTS / 'marks-set-selection.json').write_text(text)
    print(json.dumps({k: out[k] for k in ('pages', 'core', 'frame_bands')}),
          dict(Counter(p['stratum'].split(':')[1] if p['phase'] == 'B' else 'A' for p in pages)),
          'core by band', dict(Counter(p['amount'] for p in core)))


def selection():
    return load(CACHE / 'selection.json')


def image_path(pid):
    return SCAN / 'images' / (pid + '.jpg')


# ---------- parsing a draft ----------

def strip_fence(raw):
    m = re.search(r'```(?:json)?\s*\n(.*?)\n\s*```', raw, re.S)
    return m.group(1) if m else raw


def parse(raw, route):
    """(draft, problems). draft is None when the reply holds no usable object. Boxes become [x0, y0, x1, y1]
    fractions; a mark with a bad class or box is dropped and counted, never repaired by guess."""
    if not raw:
        return None, ['empty']
    text = re.sub(r'<think>.*?</think>', '', raw, flags=re.S)
    text = strip_fence(text)
    m = re.search(r'\{.*\}', text, re.S)
    if not m:
        return None, ['no object']
    try:
        obj = json.loads(m.group(0))
    except ValueError:
        return None, ['bad json']
    if not isinstance(obj, dict) or not isinstance(obj.get('marks'), list):
        return None, ['no marks list']
    problems, marks = [], []
    for mk in obj['marks']:
        if not isinstance(mk, dict) or mk.get('class') not in CLASSES:
            problems.append('bad class'); continue
        b = mk.get('box_2d' if route == 'gemini' else 'bbox_2d') or mk.get('box_2d') or mk.get('bbox_2d')
        if not (isinstance(b, list) and len(b) == 4 and all(isinstance(v, (int, float)) for v in b)):
            problems.append('bad box'); continue
        if route == 'gemini':
            y0, x0, y1, x1 = b
        else:
            x0, y0, x1, y1 = b
        box = [min(x0, x1) / 1000, min(y0, y1) / 1000, max(x0, x1) / 1000, max(y0, y1) / 1000]
        box = [round(min(max(v, 0.0), 1.0), 4) for v in box]
        if box[2] - box[0] <= 0 or box[3] - box[1] <= 0:
            problems.append('empty box'); continue
        words = mk.get('words')
        marks.append(dict(cls=mk['class'], box=box, overlaps_print=bool(mk.get('overlaps_print')),
                          legible=bool(mk.get('legible')), text=str(mk.get('text') or ''),
                          words=int(words) if isinstance(words, (int, float)) and words >= 0 else None))
    amount = obj.get('handwriting_amount')
    kind = obj.get('page_kind')
    return dict(page_kind=kind if kind in ('typed_printed', 'handwritten', 'nontext') else None,
                amount=amount if amount in AMOUNTS else None, uncertain=bool(obj.get('uncertain')),
                marks=marks), problems


# ---------- Gemini through the gateway ----------

GEMINI_CAP = 2.50   # this item's gateway spend; with Azure (~$0.08) far under the $7 rule
GEMINI_DIR = CACHE / 'gemini'


def preflight_key(G, timeout=20):
    """Read the gateway key once, with a deadline. Unattended, /usr/bin/security waits on a Keychain prompt for
    the Gateway item (fix-keychain-access.sh leaves it out; 2026-10-31), and gateway_gemini's threads would each
    start their own; this fails instead of hanging, and hands the one key to every thread."""
    try:
        r = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', 'com.archiveprocessor.app',
                            '-a', 'Gateway', '-w'], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise SystemExit('the gateway key read waited on a Keychain prompt; the Gateway item needs CLI access '
                         '(ops/autonomous/README.md, "Keychain")')
    if r.returncode != 0 or not r.stdout.strip():
        raise SystemExit('no gateway key in the Keychain (com.archiveprocessor.app / Gateway)')
    G._key = r.stdout.strip()


def cmd_gemini(a):
    import gateway_gemini as G
    G.CACHE, G.CAP = GEMINI_DIR, GEMINI_CAP     # this item's own ledger and cap
    preflight_key(G)
    todo = []
    for r in selection()['rows'][: a.limit or None]:
        dest = GEMINI_DIR / 'replies' / (r['id'] + '.json')
        if not dest.exists():
            todo.append((r['id'], image_path(r['id']).read_bytes(), dest))
    print(f'{len(todo)} pages to draft; spent so far ${G.spent():.4f} of ${GEMINI_CAP}', flush=True)
    if todo:
        G.run('marks-set', todo, prompt('gemini'), concurrency=4)
    print(f'spent ${G.spent():.4f}; {G.billed_note(G.ledger())}')


def gemini_draft(pid):
    f = GEMINI_DIR / 'replies' / (pid + '.json')
    if not f.exists():
        return None
    rec = load(f)
    d, problems = parse(rec.get('raw'), 'gemini')
    return dict(draft=d, problems=problems, finish=rec['meta'].get('finish'), wall_s=rec['meta'].get('wall_s'),
                usage=rec['meta'].get('usage'), cost=rec['meta'].get('cost'))


# ---------- Qwen3-VL 8B locally ----------

LOCAL_REPO = 'mlx-community/Qwen3-VL-8B-Instruct-4bit'
LOCAL_KEY = 'qwen3-vl-8b-mlx4'
LOCAL_SIDE = 1400
LOCAL_TOKENS = 1500
LOCAL_DIR = CACHE / LOCAL_KEY


def local_image(pid):
    """A downscaled copy for the 8B (long side LOCAL_SIDE), written once into the cache with sips."""
    out = CACHE / 'local-images' / (pid + '.jpg')
    if not out.exists():
        out.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['/usr/bin/sips', '-Z', str(LOCAL_SIDE), str(image_path(pid)), '--out', str(out)],
                       capture_output=True, check=True)
    return out


def cmd_local(a):
    import model_store
    model_store.use()   # before mlx_vlm imports huggingface_hub
    import mlx.core as mx
    from mlx_vlm import load as vload, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    LOCAL_DIR.mkdir(parents=True, exist_ok=True)
    todo = [r['id'] for r in selection()['rows'] if not (LOCAL_DIR / (r['id'] + '.json')).exists()]
    todo = todo[: a.limit or None]
    print(f'{LOCAL_KEY}: {len(todo)} pages to draft', flush=True)
    if not todo:
        return
    mx.set_cache_limit(256 * 2**20)
    model, processor = vload(LOCAL_REPO)
    chat = apply_chat_template(processor, model.config, prompt('local'), num_images=1)
    for k, pid in enumerate(todo, 1):
        img = local_image(pid)
        start, text, last = time.time(), [], None
        for r in stream_generate(model, processor, chat, image=[str(img)], max_tokens=LOCAL_TOKENS, temperature=0.0):
            text.append(r.text)
            last = r
        rec = dict(id=pid, model=LOCAL_REPO, side=LOCAL_SIDE, raw=''.join(text), wall_s=round(time.time() - start, 2),
                   tokens=[getattr(last, 'prompt_tokens', 0), getattr(last, 'generation_tokens', 0)],
                   peak_gb=round(mx.get_peak_memory() / 2**30, 2) if hasattr(mx, 'get_peak_memory') else None)
        tmp = LOCAL_DIR / ('.' + pid + '.tmp')
        tmp.write_text(json.dumps(rec, ensure_ascii=False))
        tmp.rename(LOCAL_DIR / (pid + '.json'))
        print(f'[{k}/{len(todo)}] {pid} {rec["wall_s"]}s {rec["tokens"]}', flush=True)


def local_draft(pid):
    f = LOCAL_DIR / (pid + '.json')
    if not f.exists():
        return None
    rec = load(f)
    d, problems = parse(rec.get('raw'), 'local')
    capped = rec['tokens'][1] >= LOCAL_TOKENS
    return dict(draft=d, problems=problems, finish='length' if capped else 'stop', wall_s=rec['wall_s'],
                peak_gb=rec.get('peak_gb'))


# ---------- comparing the two drafts ----------

def iou(a, b):
    w = min(a[2], b[2]) - max(a[0], b[0])
    h = min(a[3], b[3]) - max(a[1], b[1])
    if w <= 0 or h <= 0:
        return 0.0
    inter = w * h
    return inter / ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter)


def match(ma, mb, thr=0.5, same_class=False):
    """Greedy one-to-one matching by IoU; the number of matched pairs."""
    pairs = sorted(((iou(x['box'], y['box']), i, j) for i, x in enumerate(ma) for j, y in enumerate(mb)
                    if not same_class or x['cls'] == y['cls']), reverse=True)
    used_a, used_b, n = set(), set(), 0
    for v, i, j in pairs:
        if v < thr:
            break
        if i in used_a or j in used_b:
            continue
        used_a.add(i); used_b.add(j); n += 1
    return n


def has_hand(d):
    return any(m['cls'] in HAND for m in d['marks'])


def wilson(k, n, z=1.96):
    if not n:
        return None
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    s = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return [round((c - s) / d, 4), round((c + s) / d, 4)]


def cmd_report(_):
    sel = selection()
    rows = sel['rows']
    routes = {'gemini3.7-flash-gw': gemini_draft, LOCAL_KEY: local_draft}
    per = {name: {r['id']: f(r['id']) for r in rows} for name, f in routes.items()}
    out = dict(protocol='marks-set-draft-v1', pages=len(rows), core=sum(r['core'] for r in rows), routes={})
    for name, got in per.items():
        have = [g for g in got.values() if g]
        ok = [g for g in have if g['draft']]
        marks = [m for g in ok for m in g['draft']['marks']]
        info = dict(read=len(have), parsed=len(ok), capped=sum(g['finish'] == 'length' for g in have),
                    dropped_marks=dict(Counter(p for g in have for p in g['problems'])),
                    marks=len(marks), by_class=dict(Counter(m['cls'] for m in marks)),
                    pages_with_marks=sum(bool(g['draft']['marks']) for g in ok),
                    pages_with_hand=sum(has_hand(g['draft']) for g in ok),
                    bands=dict(Counter(g['draft']['amount'] for g in ok)),
                    median_s=sorted(g['wall_s'] for g in have)[len(have) // 2] if have else None)
        if name.startswith('gemini'):
            costs = [g['cost'] or 0 for g in have]
            info['cost_estimate'] = round(sum(costs), 4)
            try:
                import gateway_gemini as G
                G.CACHE = GEMINI_DIR
                info['billed'] = G.billed(G.ledger())
            except Exception as e:  # noqa: BLE001 - the report still writes without the ledger
                info['billed'] = str(e)
        else:
            info['peak_gb'] = max((g.get('peak_gb') or 0) for g in have) if have else None
        out['routes'][name] = info
    # agreement on pages both parsed
    g, q = per['gemini3.7-flash-gw'], per[LOCAL_KEY]
    both = [r for r in rows if g[r['id']] and g[r['id']]['draft'] and q[r['id']] and q[r['id']]['draft']]
    hand_agree = sum(has_hand(g[r['id']]['draft']) == has_hand(q[r['id']]['draft']) for r in both)
    band_agree = sum(g[r['id']]['draft']['amount'] == q[r['id']]['draft']['amount'] for r in both)
    na = sum(len(g[r['id']]['draft']['marks']) for r in both)
    nb = sum(len(q[r['id']]['draft']['marks']) for r in both)
    m_any = sum(match(g[r['id']]['draft']['marks'], q[r['id']]['draft']['marks']) for r in both)
    m_cls = sum(match(g[r['id']]['draft']['marks'], q[r['id']]['draft']['marks'], same_class=True) for r in both)
    m_any3 = sum(match(g[r['id']]['draft']['marks'], q[r['id']]['draft']['marks'], thr=0.3) for r in both)
    out['agreement'] = dict(pages=len(both), hand_page=[hand_agree, wilson(hand_agree, len(both))],
                            band=[band_agree, wilson(band_agree, len(both))],
                            gemini_marks=na, local_marks=nb, matched_iou50=m_any, matched_iou50_same_class=m_cls,
                            matched_iou30=m_any3)
    # the pre-flag against Gemini, by phase (phase A is flag-independent, so it alone estimates the flag's misses)
    pre = {}
    for phase in ('A', 'B'):
        rs = [r for r in rows if r['phase'] == phase and g[r['id']] and g[r['id']]['draft']]
        gh = [r for r in rs if has_hand(g[r['id']]['draft'])]
        pre[phase] = dict(pages=len(rs), gemini_hand=len(gh),
                          gemini_hand_preflag_none=sum(r['amount'] == 'none' for r in gh),
                          preflag_hand_gemini_none=sum(r['amount'] not in (None, 'none') and not
                                                       has_hand(g[r['id']]['draft']) for r in rs))
    out['preflag_vs_gemini'] = pre
    # band cross-table: pre-flag x Gemini
    out['band_table'] = {b: dict(Counter((g[r['id']]['draft']['amount'] if g[r['id']] and g[r['id']]['draft']
                                          else 'unread') for r in rows if (r['amount'] or 'unparsed') == b))
                         for b in [*AMOUNTS, 'unparsed']}
    # disagreement pages: where the owner core and a later check should look first
    dis = []
    for r in both:
        a_, b_ = g[r['id']]['draft'], q[r['id']]['draft']
        if has_hand(a_) != has_hand(b_) or a_['amount'] != b_['amount'] or \
                match(a_['marks'], b_['marks']) < max(len(a_['marks']), len(b_['marks'])):
            dis.append(r['id'])
    out['disagreement_pages'] = len(dis)
    out['disagreement_core'] = sum(1 for r in rows if r['id'] in set(dis) and r['core'])
    RESULTS.mkdir(exist_ok=True)
    (RESULTS / 'marks-set-draft.json').write_text(json.dumps(out, indent=1) + '\n')
    (CACHE / 'disagreements.json').write_text(json.dumps(dis, indent=1) + '\n')
    (RESULTS / 'marks-set-draft.md').write_text(markdown(out))
    print(json.dumps(out, indent=1))


def markdown(o):
    """The committed report: counts and agreement only, never page text."""
    names = list(o['routes'])
    L = ['# Marks set: the two drafts of the 150 pages', '',
         f"W46.fix-marks-set-draft. `marks_set.py report` over the {o['pages']} pages of `marks-set-selection.json` "
         f"({o['core']} in the owner core). Draft figures, not truth; the JSON beside this file has every count.", '',
         '| | ' + ' | '.join(names) + ' |', '|---|' + '---|' * len(names)]
    rows = [('Pages read', 'read'), ('Parsed', 'parsed'), ('Hit the output cap', 'capped'), ('Marks', 'marks'),
            ('Pages with a mark', 'pages_with_marks'), ('Pages with handwriting', 'pages_with_hand'),
            ('Median seconds a page', 'median_s')]
    for label, k in rows:
        L.append(f'| {label} | ' + ' | '.join(str(o['routes'][n].get(k)) for n in names) + ' |')
    for c in CLASSES:
        L.append(f'| {c} | ' + ' | '.join(str(o['routes'][n]['by_class'].get(c, 0)) for n in names) + ' |')
    L.append('| Marks dropped (bad class or box) | ' + ' | '.join(
        str(sum(o['routes'][n]['dropped_marks'].values())) for n in names) + ' |')
    a = o['agreement']
    L += ['', '## Agreement between the drafts', '']
    if a['pages']:
        L += [f"On the {a['pages']} pages both parsed: handwriting present or not agreed on {a['hand_page'][0]} "
              f"(95% {a['hand_page'][1]}); the band on {a['band'][0]} ({a['band'][1]}). Of "
              f"{a['gemini_marks']} and {a['local_marks']} marks, {a['matched_iou50']} pair at IoU 0.5 "
              f"({a['matched_iou50_same_class']} with the same class) and {a['matched_iou30']} at IoU 0.3. "
              f"{o['disagreement_pages']} pages disagree somewhere, {o['disagreement_core']} of them in the core."]
    else:
        L += ['No page has both drafts yet.']
    L += ['', '## Measurement card', '',
          '- **Truth.** None. Both columns are drafts; the owner core (W46.marks-core-owner-ok) is the first truth.',
          '- **Selection.** `marks-set-selection.json`: phase A independent of every route, phase B by the '
          "Qwen3.6-27B pre-flag's band (neither drafter).",
          '- **Comparison.** One instruction, each route in its own box form; Gemini at 2,400 px, the 8B at 1,400 px.',
          '- **Noise.** One pass each at temperature 0; no rerun floor.',
          '- **Scope.** Agreement is not accuracy: two drafts can agree and both be wrong. Neither drafter may be '
          'ranked on these pages (MRK-1).', '']
    return '\n'.join(L)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    for c in ('select', 'gemini', 'local', 'report'):
        p = sub.add_parser(c)
        if c in ('gemini', 'local'):
            p.add_argument('--limit', type=int)
    a = ap.parse_args()
    dict(select=cmd_select, gemini=cmd_gemini, local=cmd_local, report=cmd_report)[a.cmd](a)


if __name__ == '__main__':
    main()
