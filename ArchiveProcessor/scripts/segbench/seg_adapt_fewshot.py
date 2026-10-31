"""W46.seg-adapt-curve-paid: few-shot examples of a user's checked gaps in the Gemini window prompt.

  SEGBENCH_CACHE=ROOT/cache <lab python> seg_adapt_fewshot.py inventory|collect ROOT --box Lincoln --k 25
  SEGBENCH_CACHE=ROOT/cache <lab python> seg_adapt_fewshot.py score ROOT     # no calls -> segbench-results/

The question (10-gap-audit.md §5 item 13, its few-shot arm): does showing the window model the gaps a user has
already checked in the same box lower its errors on the gaps nobody checked? W46.seg-adapt-curve answered it for
the local models' threshold refit (a few labels buy little beyond themselves); this is the cloud prompt's version.

THE BASELINE is W46.seg-lincoln-cloud-paid's zero-shot gateway arm, read from its cache unchanged: Gemini 3.7 Flash,
low reasoning, temperature 0, JSON mode, g1 windows (7 pages, stride 3, 1600px images plus cached Vision text).
THE FEW-SHOT ARM sends the identical request with one block added before the schema line: the k checked gaps of the
same box, each as the end of the earlier page's OCR text, the start of the later page's, and the archivist's
decision. Text only (no example images, which would multiply the cost); the same block in every window of the box.
THE CHECKED GAPS are W46.seg-adapt-curve's first random draw at that k (random.Random(11), its loop order), so the
local models' curve and this arm share a labelled set. Scored as that item scores: errors per 100 held-out gaps,
and pages in an exact document over the whole box with the k checked gaps set to the truth, against the baseline
with the same k gaps corrected.

MONEY: real money on the Stanford PTA through the gateway. One ledger (STORE/calls.jsonl), the item cap CAP, and the
seg_lincoln_gateway machinery unchanged: an fsynced pre-send reservation, settle at Gemini's list rate (.75/3.75 per
M tokens, an estimate; seg_lincoln_gateway records the gateway's own figure beside it), stop on any invalid reply, no
automatic retry. Scoring makes no calls. Lincoln and CREST are public boxes: no owner material is sent.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import random
import sys
from contextlib import contextmanager
from pathlib import Path

import data
import seg_lincoln_gateway as SL
import method_window as W

STORE = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/seg-adapt-gateway'
RESULTS = data.HERE.parents[1] / 'segbench-results'
CAP = 3.00                 # the item's own limit (SUITE_TODO), under the $7 rule
EXCERPT = 300              # characters of OCR text either side of an example gap
SEED, CURVE_KS, DRAWS, MIN_HELD = 11, (0, 25, 50, 100, 200), 30, 20    # seg_adapt_curve.curve's, verbatim
# In run order. Estimated from the zero-shot arm's tokens plus the block's: about $1.10, $0.60 and $0.80; Lincoln
# k=50 (about $1.40) would not fit under CAP after the first two.
SETTINGS = (('Lincoln', 25), ('CREST', 25), ('CREST', 50))
MARKER = '\nReturn only one JSON object matching this schema:\n'
_BASE_REQUEST = SL.request
BLOCKS: dict[str, str] = {}


def gaps_truth(col):
    """Document gaps and their truth, as seg_adapt_curve.Box defines them (True = new document)."""
    from score import PHOTO, segment_ids
    lab = col.labels
    gaps = [i for i in range(len(lab) - 1) if lab[i] not in PHOTO and lab[i + 1] not in PHOTO]
    ids = segment_ids(lab)
    return gaps, {i: ids[i] != ids[i + 1] for i in gaps}


def draw(gaps, k):
    """The first random draw of k gaps in seg_adapt_curve.curve, reproduced by replaying its loop."""
    rng = random.Random(SEED)
    for kk in CURVE_KS:
        if len(gaps) - kk < MIN_HELD:
            continue
        for _ in range(DRAWS if kk else 1):
            s = rng.sample(gaps, kk)
            if kk == k:
                return sorted(s)
    raise ValueError(f'k={k} is not drawn for {len(gaps)} gaps')


def squash(t):
    return ' '.join((t or '').split()) or '(no text found)'


def block(col, k):
    gaps, truth = gaps_truth(col)
    lab = draw(gaps, k)
    lines = ['', 'GAPS THE ARCHIVIST HAS ALREADY CHECKED IN THIS BOX',
             f'The archivist has checked {len(lab)} gaps elsewhere in this same box. They show how this '
             'material is divided into documents. Only the OCR text either side of each gap is shown, not '
             'the image. Use them as worked examples of the rules above on this material. Still answer '
             'every gap of the window from its own images; where a window gap is listed here, give the '
             "archivist's decision.", '']
    for i in lab:
        a, b = col.pages[i].n, col.pages[i + 1].n
        end, start = squash(col.text(i))[-EXCERPT:], squash(col.text(i + 1))[:EXCERPT]
        lines += [f'Pages {a} and {b}: {"NEW DOCUMENT at page " + str(b) if truth[i] else "SAME DOCUMENT (continue)"}',
                  f'  end of page {a}: "{end}"', f'  start of page {b}: "{start}"']
    return '\n'.join(lines) + '\n', lab


def request(route, col, a, b, whole=False):
    """SL.request's exact body with this box's example block inserted before the schema line."""
    if route != 'gemini' or whole:
        raise ValueError('the few-shot arm is Gemini windows only')
    body, _, nums = _BASE_REQUEST(route, col, a, b, whole)
    parts = body['messages'][0]['content']
    head, sep, tail = parts[-1]['text'].rpartition(MARKER)
    if not sep or col.name not in BLOCKS:
        raise ValueError('prompt shape changed or no example block set; no call sent')
    parts[-1] = {'type': 'text', 'text': head + BLOCKS[col.name] + sep + tail}
    key = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()
    return body, key, nums


@contextmanager
def fewshot(col, k):
    """Route SL's call/cache machinery to this item's store, cap and request for one setting."""
    BLOCKS[col.name], lab = block(col, k)
    saved = SL.STORE, SL.CAP, SL.request
    SL.STORE, SL.CAP, SL.request = STORE, CAP, request
    try:
        yield lab
    finally:
        SL.STORE, SL.CAP, SL.request = saved
        BLOCKS.pop(col.name, None)


@contextmanager
def patch_store():
    saved = SL.STORE
    SL.STORE = STORE
    try:
        yield
    finally:
        SL.STORE = saved


def p_new(col, judge):
    comb = W.combine(col, judge)
    return {i: float(g['p_new']) for i, g in enumerate(comb['gaps'])}


def pending(col, k):
    with fewshot(col, k):
        out = []
        for a, b in W.windows(len(col.pages)):
            body, key, _ = request('gemini', col, a, b)
            hit = SL.cache_hit(body, key)
            if hit is None or not hit.get('valid'):
                out.append((a, b))
        return out


def collect(col, k, limit=None):
    import requests  # noqa: F401 -- fail before a reservation, not after (the first pilot reserved without sending)
    todo = pending(col, k)
    with fewshot(col, k):
        print(f'{col.name} k={k}: {len(todo)} windows uncached, item spent ${SL.spent():.4f}', flush=True)
        STORE.mkdir(parents=True, exist_ok=True)
        with (STORE / 'collect.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for a, b in todo[:limit]:
                SL.call('gemini', col, a, b)


def score_box(col, k):
    from score import PHOTO, derived, score_labels
    gaps, truth = gaps_truth(col)
    base = p_new(col, SL.judge('gemini'))
    with fewshot(col, k) as lab:
        few = p_new(col, SL.judge('gemini'))
    held = [i for i in gaps if i not in lab]

    def row(p):
        new = {i: p[i] >= 0.5 for i in p}
        for i in lab:
            new[i] = truth[i]
        pred = []
        for i, t in enumerate(col.labels):
            pred.append(t if t in PHOTO else 'New' if i == 0 or col.labels[i - 1] in PHOTO or new[i - 1] else 'Cont')
        c = score_labels(col.labels, pred, col.name)
        m = derived(c)
        wrong = [i for i in held if (p[i] >= 0.5) != truth[i]]
        return {'held_errors': len(wrong), 'err_per_100_held': 100 * len(wrong) / len(held),
                'false_splits_held': sum(not truth[i] for i in wrong), 'false_merges_held': sum(truth[i] for i in wrong),
                'wrong_gaps': [[col.pages[i].n, col.pages[i + 1].n] for i in wrong],
                'exact': m['pages_in_exact_doc'], 'pq': m['pq'], 'false_splits': c.false_splits,
                'false_merges': c.false_merges}
    flipped = [[col.pages[i].n, col.pages[i + 1].n] for i in held if (base[i] >= 0.5) != (few[i] >= 0.5)]
    listed_against = [[col.pages[i].n, col.pages[i + 1].n] for i in lab if (few[i] >= 0.5) != truth[i]]
    return {'box': col.name, 'k': k, 'gaps': len(gaps), 'held': len(held), 'labelled_new': sum(truth[i] for i in lab),
            'zero_shot': row(base), 'few_shot': row(few), 'held_decisions_changed': flipped,
            'listed_gaps_answered_against_the_archivist': listed_against}


def score(root):
    import rescore
    rescore.no_network()
    cols = {c.name: c for c in SL.public_columns(root)}
    SL.use_cache(root / 'cache')
    done, skipped = [], []
    for box, k in SETTINGS:
        col = cols[box]
        if pending(col, k):
            skipped.append([box, k])
            continue
        done.append(score_box(col, k))
    with patch_store():
        calls = SL.effective_records()
        total = SL.spent()
    by = {}
    for r in calls:
        s = by.setdefault(r['box'], {'calls': 0, 'valid': 0, 'in': 0, 'out': 0, 'cost': 0.0})
        s['calls'] += 1
        s['valid'] += bool(r.get('valid'))
        s['in'] += (r.get('usage') or {}).get('prompt_tokens', 0)
        s['out'] += (r.get('usage') or {}).get('completion_tokens', 0)
        s['cost'] += r['charge']
    out = {'model': SL.MODELS['gemini'], 'item_cost_estimate': total, 'cap': CAP, 'settings': done,
           'not_collected': skipped, 'calls_by_box': by}
    (RESULTS / 'seg-adapt-fewshot.json').write_text(json.dumps(out, indent=1) + '\n')
    (RESULTS / 'seg-adapt-fewshot.md').write_text(render(out))
    print(render(out))


FINDINGS = """## Findings (2026-10-29)

1. **The examples change almost nothing, because zero-shot Gemini already makes very few errors here.** Gemini 3.7
   Flash windows get 2-5 of the held-out gaps wrong on these boxes (about 2 per 100). With the examples:
   - Lincoln, k=25: 5 errors become 4. The examples fixed two over-splits and made one new false merge (pages 76/77).
   - CREST, k=25: no held-out decision changed.
   - CREST, k=50: one over-split went (pages 87/88). That single gap rejoins a long document, so pages exact rises
     from 85.9% to 96.9%.
   Each difference is one or two gaps on one draw, which is within what a different draw would move. This run is
   no evidence that few-shot examples help, and none that they hurt.
2. **The examples did not override the archivist.** Where a listed gap fell inside a window, the model gave the
   archivist's decision every time, as asked. So the examples need no separate guard.
3. **What follows for the kit.** A user's corrections set the gaps they correct; feeding them back into the cloud
   prompt buys no measurable accuracy here, and it costs input tokens on every window: 1.43x the zero-shot arm's
   input on Lincoln at k=25 ($1.18 for the box), 1.51x on CREST at k=25 ($0.68) and 2.01x at k=50 ($0.88). The review screen's disagreement rule
   (W46.seg-adapt-curve) remains the way corrections pay off. Where few-shot might still matter is a box on which
   the cloud model errs often, as the local models do on Lincoln. No such box is in hand for Gemini.
4. **Limits.** One random draw per setting; two public boxes; text-only examples (300 characters of OCR either
   side), with no example images; Gemini 3.7, not 3.8. Lincoln k=50 (about $1.40) was not run, to keep the item
   under its $3 cap.
"""


def render(out):
    pct = lambda x: f'{100 * x:.1f}%'
    L = ['# Few-shot examples in the Gemini window prompt (W46.seg-adapt-curve-paid)', '',
         'Generated by `scripts/segbench/seg_adapt_fewshot.py` (method in its docstring). Gemini 3.7 Flash through the '
         'Stanford gateway, low reasoning, temperature 0, g1 windows (7 pages, stride 3). The zero-shot column is '
         "W46.seg-lincoln-cloud-paid's cached arm; the few-shot column is the same requests with the box's k checked "
         'gaps added as text examples (OCR either side of the gap and the archivist\'s decision). The k gaps are '
         "W46.seg-adapt-curve's first random draw, and both columns count them as corrected.", '',
         FINDINGS,
         '| box | k checked | held-out gaps | arm | held-out errors | per 100 held-out | false splits | false merges | pages exact | PQ |',
         '|---|---:|---:|---|---:|---:|---:|---:|---:|---:|']
    for s in out['settings']:
        for arm, name in (('zero_shot', 'zero-shot'), ('few_shot', 'few-shot')):
            r = s[arm]
            L.append(f"| {s['box']} | {s['k']} | {s['held']} | {name} | {r['held_errors']} | {r['err_per_100_held']:.1f} | "
                     f"{r['false_splits_held']} | {r['false_merges_held']} | {pct(r['exact'])} | {r['pq']:.3f} |")
    L += ['', 'False splits and merges here are the held-out gaps answered wrong. Pages exact and PQ are the whole box '
          'with the checked gaps set to the truth.', '']
    for s in out['settings']:
        L.append(f"- {s['box']} k={s['k']} ({s['labelled_new']} of the checked gaps are new documents): zero-shot wrong at "
                 f"{s['zero_shot']['wrong_gaps']}, few-shot wrong at {s['few_shot']['wrong_gaps']}; held-out decisions the "
                 f"examples changed: {s['held_decisions_changed'] or 'none'}; listed gaps answered against the archivist: "
                 f"{s['listed_gaps_answered_against_the_archivist'] or 'none'}.")
    if out['not_collected']:
        L += ['', f"Not collected: {out['not_collected']}."]
    L += ['', '| box | calls | valid | input tokens | output tokens | cost estimate |', '|---|---:|---:|---:|---:|---:|']
    for box, s in out['calls_by_box'].items():
        L.append(f"| {box} | {s['calls']} | {s['valid']} | {s['in']:,} | {s['out']:,} | ${s['cost']:.4f} |")
    L += ['', 'Calls count every reservation, so a box\'s calls can exceed its valid replies: Lincoln\'s first pilot reserved '
          'and then failed before sending (no requests module in that Python); its allowance stays charged. A box\'s cost '
          'covers all its settings.']
    L += ['', f"Item cost estimate ${out['item_cost_estimate']:.4f} of the ${out['cap']:.2f} cap, at Gemini's list rate "
          '($0.75 / $3.75 per million input / output tokens, reasoning included); the gateway returns no cost.', '']
    return '\n'.join(L)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=('inventory', 'collect', 'score', 'show-block', 'retry-unsettled'))
    ap.add_argument('root', type=Path)
    ap.add_argument('--box', choices=('Lincoln', 'CREST'))
    ap.add_argument('--k', type=int)
    ap.add_argument('--limit', type=int)
    args = ap.parse_args()
    if args.command == 'score':
        return score(args.root)
    if args.command == 'retry-unsettled':
        # SL's one explicit retry of a reservation whose send never returned usage; the allowance stays charged.
        with (STORE / 'collect.lock').open('a') as lock, patch_store():
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            SL.retry_unsettled_once()
        return
    if not args.box or not args.k or (args.box, args.k) not in SETTINGS:
        ap.error(f'--box and --k must name one of {SETTINGS}')
    cols = {c.name: c for c in SL.public_columns(args.root)}
    SL.use_cache(args.root / 'cache')
    col = cols[args.box]
    if args.command == 'show-block':
        print(block(col, args.k)[0])
    elif args.command == 'inventory':
        print(len(pending(col, args.k)), 'windows uncached')
    else:
        collect(col, args.k, args.limit)


if __name__ == '__main__':
    sys.exit(main())
