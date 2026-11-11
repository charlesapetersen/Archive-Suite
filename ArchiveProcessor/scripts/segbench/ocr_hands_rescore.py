#!/usr/bin/env python3
"""W46.ocr-hands-rescore. Every route on the 96's 16 hand pages, on the truth before and after the owner's blind
handwriting sheet (ocr_hands_sheet.py, answered 2026-10-31), the typed controls' error rate, and the API hand route.

  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy python ocr_hands_rescore.py

Reads saved files only: no model, no network, no money. The corrections themselves are ocr_truth.CORRECTIONS, put
into the cache's truth/ by `ocr_truth.py apply` (the pre-sheet copy is ocr-truth/truth-before-hands/). Readings are
ocr_rescore.owner_sources() (every cached route on the 96); a failure is an empty reading and scores as such, as on
the panels. Scores are ocr_panel_score.score's NES, in points; intervals are ocr_panel_score.paired (per-page
differences, 95% bootstrap, 10,000 rounds).

Writes segbench-results/ocr-hands-rescore.md and .json (scores and counts only; no text), and ocr-hands-pages.csv
(each route's per-page NES on the corrected truth, for ocr_pair_matrix.py's hands16 group).
"""
from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import ocr_panel as P                      # noqa: E402
import ocr_panel_score as S                # noqa: E402
import ocr_rescore as RS                   # noqa: E402

T = P.T
RESULTS = HERE.parents[1] / 'segbench-results'
HANDS = T.CACHE / 'hands'
BEFORE = T.CACHE / 'truth-before-hands'
LEAD = 'gemini3.8-flash'          # C-ocr §6's API hand route
TIE = 0.49   # ocr-rerun-noise.md's rule: twice the larger rerun range (Gemini 3.7 Flash, 0.24), or an interval across 0


def clopper(k: int, n: int) -> tuple[float, float]:
    """Exact 95% binomial interval, by bisection on the beta tails (no scipy here)."""
    def tail(p, upper):
        s = sum(math.comb(n, i) * p ** i * (1 - p) ** (n - i) for i in range(0, k + 1 if upper else k))
        return s if upper else 1 - s
    def solve(f, target):
        lo, hi = 0., 1.
        for _ in range(60):
            mid = (lo + hi) / 2
            lo, hi = (mid, hi) if f(mid) > target else (lo, mid)
        return (lo + hi) / 2
    lo = 0. if k == 0 else solve(lambda p: -tail(p, False), -.025)
    hi = 1. if k == n else solve(lambda p: tail(p, True), .025)
    return lo, hi


def route_name(route: str, family: str, names: list[str]) -> str:
    return route if names.count(route) == 1 else f'{route} ({family})'


def readings(pages: list[str]) -> dict[str, dict[str, str]]:
    """Every cached route that read any hand page, by its report name."""
    src = RS.owner_sources()
    keys = [r for r, _ in src]
    return {route_name(route, family, keys): texts for (route, family), texts in src.items()
            if any((texts.get(p) or '').strip() for p in pages)}


def nes(truth: str, reading: str) -> float:
    return 100 * S.score(truth, reading)['nes']


def scores(pages: list[str], truth_dir: Path, src: dict | None = None) -> dict[str, dict[str, float]]:
    src = src if src is not None else readings(pages)
    truth = {p: (truth_dir / f'{p}.txt').read_text() for p in pages}
    return {r: {p: nes(truth[p], texts.get(p) or '') for p in pages} for r, texts in src.items()}


def controls(rulings: dict) -> dict:
    """The typed controls' error, per sampled passage (the unit the draw sampled). W46.ocr-audit-report-fix (pass 3,
    P3-2): the per-word figure once divided by 8n words as if each word were its own draw; words of one passage are
    not independent, so the bound that respects the sample is the passage one, which also caps the per-word rate (a
    passage's share of wrong words is at most 1 when it has any). The iid figure stays only as labelled."""
    items = [(p, i, v) for p, d in rulings.items() for i, v in d.items() if v['kind'] == 'control']
    ruled = [v for _, _, v in items if v['truth_stands'] is not None]
    wrong = [f'{p} {i}' for p, i, v in items if v['truth_stands'] is False]
    n, k = len(ruled), len(wrong)
    lo, hi = clopper(k, n)
    words = sum(1 for _, _, v in items for _ in v['readings']['truth'].split())
    return {'passages': len(items), 'ruled': n, 'wrong': k, 'wrong_items': wrong, 'words': words,
            'rate_lo': lo, 'rate_hi': hi, 'per_word_hi': hi,
            'per_word_hi_if_iid': clopper(0, n * 8)[1] if k == 0 else None}


# ---- unresolved hand places (W46.ocr-audit-report-fix, measurement review 2026-10-31 pass 3, P3-2) ---------------
# The sheet's fourth answer was "either will do / can't tell", one key for two meanings, so a place answered with it
# is UNRESOLVED: neither "both readings are right" nor "the truth stands" can be read from it. The fixed-reference
# scores keep the truth's reading there; the treatments below show how far the ranking rests on those places,
# without crediting every alternative as right.

def unresolved(rulings: dict) -> dict[str, list[dict]]:
    """page -> its unresolved hand places: the truth's word range (in the pre-sheet truth the key was built on) and
    one reading per scorer-distinct option, the truth's first."""
    out = {}
    for p, d in rulings.items():
        for iid, v in d.items():
            if v['kind'] != 'hand' or v['ruling'] != 'either':
                continue
            alts = [v['readings']['truth']]
            alts += [v['readings'][g[0]] for g in v['options'] if 'truth' not in g]
            out.setdefault(p, []).append({'id': iid, 't0': v['t0'], 't1': v['t1'], 'alts': alts})
    return out


def relocate(before: list[str], after: list[str], t0: int, t1: int) -> tuple[int, int] | None:
    """The range t0..t1 of `before`'s words in `after`, when the words there and their neighbours are unchanged by
    the sheet's corrections; None when a correction touched the place (it is then not unresolved any more)."""
    import difflib
    m = {}
    for a, b, n in difflib.SequenceMatcher(None, before, after, autojunk=False).get_matching_blocks():
        m.update({a + i: b + i for i in range(n)})
    if t1 > t0:
        idx = [m.get(i) for i in range(t0, t1)]
        if None in idx or idx != list(range(idx[0], idx[0] + len(idx))):
            return None
        return idx[0], idx[-1] + 1
    if t0 - 1 in m and (t0 >= len(before) or m.get(t0) == m[t0 - 1] + 1):
        return m[t0 - 1] + 1, m[t0 - 1] + 1      # an insertion point: both neighbours still adjacent
    if t0 == 0 and m.get(0) == 0:
        return 0, 0
    return None


def variants(text: str, places: list[dict]) -> list[str]:
    """Every truth the unresolved places allow: one alternative per place, all combinations, the first being the
    fixed reference (`text` itself). `places` carry `a0`/`a1`, their range in `text.split()`, and must not overlap.
    The text around each place keeps its own spacing and line breaks, which the scorer reads (line-end hyphens)."""
    import itertools
    import re
    spans = [m.span() for m in re.finditer(r'\S+', text)]
    def chars(x):
        if x['a1'] > x['a0']:
            return spans[x['a0']][0], spans[x['a1'] - 1][1]
        at = spans[x['a0'] - 1][1] if x['a0'] else 0     # an insertion: just after the word before
        return at, at
    ps = sorted(places, key=lambda x: x['a0'], reverse=True)
    out = []
    for pick in itertools.product(*[x['alts'] for x in ps]):
        t = text
        for x, alt in zip(ps, pick):
            c0, c1 = chars(x)
            if c0 == c1 and alt:
                alt = (' ' if c0 else '') + alt + ('' if c0 else ' ')
            t = t[:c0] + alt + t[c1:]
        out.append(t)
    return out


def bounds(truths: dict[str, list[str]], readings: dict[str, dict[str, str]], score) -> dict[str, dict]:
    """Per route, per page, the lowest and highest score over the page's allowed truths. A bound, not a score:
    each route's best (or worst) case may take a different reading at a place, so no one truth gives them all."""
    out = {}
    for route, texts in readings.items():
        lo, hi = {}, {}
        for p, ts in truths.items():
            s = [score(t, texts.get(p) or '') for t in ts]
            lo[p], hi[p] = min(s), max(s)
        out[route] = {'lo': lo, 'hi': hi}
    return out


def treatments(after: dict, b: dict, lead: str, pages: list[str], held: list[str], pair) -> dict:
    """The lead route against each other route under three treatments of the unresolved places: `fixed` (the
    truth's reading, the report's main figures), `excluded` (the pages that carry none) and `adverse` (the lead at
    its lowest, the other route at its highest, page by page)."""
    clear = [p for p in pages if p not in held]
    out = {}
    for ref in sorted(after):
        if ref == lead:
            continue
        out[ref] = {'fixed': pair([after[lead][p] for p in pages], [after[ref][p] for p in pages]),
                    'excluded': pair([after[lead][p] for p in clear], [after[ref][p] for p in clear]),
                    'adverse': pair([b[lead]['lo'][p] for p in pages], [b[ref]['hi'][p] for p in pages])}
    return out


def sensitivity(pages: list[str], rulings: dict, after_dir: Path) -> dict:
    """The unresolved places on the hand pages, placed in the corrected truth, and each page's allowed truths."""
    places, truths, dropped = unresolved(rulings), {}, []
    for p in pages:
        text = (after_dir / f'{p}.txt').read_text()
        words = text.split()
        here = []
        for x in places.get(p, []):
            at = relocate((BEFORE / f'{p}.txt').read_text().split(), words, x['t0'], x['t1'])
            if at is None:
                dropped.append(f'{p} {x["id"]}')
            else:
                here.append({**x, 'a0': at[0], 'a1': at[1]})
        if here:
            assert all(' '.join(words[x['a0']:x['a1']]) == x['alts'][0] for x in here), p
            here.sort(key=lambda x: x['a0'])
            assert all(x['a1'] <= y['a0'] for x, y in zip(here, here[1:])), f'{p}: unresolved places overlap'
            truths[p] = variants(text, here)
    return {'places': {p: [x['id'] for x in v] for p, v in places.items()}, 'dropped': dropped, 'truths': truths}


def build(out: Path) -> dict:
    key = json.loads((HANDS / 'key.json').read_text())
    rulings = json.loads((HANDS / 'rulings.json').read_text())
    pages = key['hand_pages']
    src = readings(pages)
    after, before = scores(pages, T.CACHE / 'truth', src), scores(pages, BEFORE, src)
    sens = sensitivity(pages, rulings['rulings'], T.CACHE / 'truth')
    held = sorted(sens['truths'])
    bd = bounds(sens['truths'], src, nes)
    for r in bd:   # a page with no unresolved place has one truth
        for p in pages:
            bd[r]['lo'].setdefault(p, after[r][p])
            bd[r]['hi'].setdefault(p, after[r][p])
    changed = [p for p in pages if (BEFORE / f'{p}.txt').read_text() != (T.CACHE / 'truth' / f'{p}.txt').read_text()]
    rows = []
    for r in sorted(after, key=lambda r: -statistics.fmean(after[r].values())):
        a, b = statistics.fmean(after[r].values()), statistics.fmean(before[r].values())
        rows.append({'route': r, 'after': a, 'before': b, 'move': a - b,
                     'failed': sum(1 for p in pages if after[r][p] == 0)})
    pairs = {}
    for ref in sorted(after):
        if ref == LEAD:
            continue
        pairs[ref] = {t: S.paired([d[LEAD][p] for p in pages], [d[ref][p] for p in pages])
                      for t, d in (('after', after), ('before', before))}
    for x in rows:
        x['lo'] = statistics.fmean(bd[x['route']]['lo'].values())
        x['hi'] = statistics.fmean(bd[x['route']]['hi'].values())
        x['clear'] = statistics.fmean(after[x['route']][p] for p in pages if p not in held)
    tr = treatments(after, bd, LEAD, pages, held, S.paired)
    counts = rulings['counts']
    res = {'pages': pages, 'changed_pages': changed, 'routes': rows, 'lead': LEAD, 'paired': pairs,
           'sheet': counts, 'controls': controls(rulings['rulings']),
           'unresolved': {'places': sens['places'], 'dropped': sens['dropped'], 'pages': held,
                          'truths': {p: len(v) for p, v in sens['truths'].items()}, 'treatments': tr,
                          'summary': robustness(tr)}}
    out.mkdir(parents=True, exist_ok=True)
    (out / 'ocr-hands-rescore.json').write_text(json.dumps(res, indent=1) + '\n')
    # W46.pair-matrix-cover: each route's per-page scores on the corrected truth, for ocr_pair_matrix.py's hands16 group
    (out / 'ocr-hands-pages.csv').write_text('route,page,nes\n' + ''.join(
        f'"{r}",{p},{after[r][p]:.6f}\n' for r in sorted(after) for p in pages))
    write_md(out / 'ocr-hands-rescore.md', res)
    return res


def tie(d: dict) -> bool:
    return abs(d['delta']) < TIE or d['lo'] <= 0 <= d['hi']


def f2(x):
    return f'{x:+.2f}'


def pages_clear(r: dict) -> list[str]:
    return [p for p in r['pages'] if p not in r['unresolved']['pages']]


def verdict(d: dict) -> str:
    return 'tie' if tie(d) else ('leads' if d['delta'] > 0 else 'trails')


def robustness(tr: dict) -> dict:
    """Which fixed-reference leads also lead with the unresolved pages excluded and on the adverse bound."""
    fixed = sorted(k for k, d in tr.items() if verdict(d['fixed']) == 'leads')
    robust = [k for k in fixed if verdict(tr[k]['excluded']) == 'leads' and verdict(tr[k]['adverse']) == 'leads']
    return {'fixed_leads': fixed, 'robust': robust, 'conditional': sorted(set(fixed) - set(robust))}


def unresolved_md(r: dict) -> list[str]:
    u, lead = r['unresolved'], r['lead']
    n = sum(len(v) for v in u['places'].values())
    clear = pages_clear(r)
    tr = u['treatments']
    L = ['', '## The unresolved places', '',
         f'{n} hand places were answered "either will do / can\'t tell" on {len(u["places"])} pages ('
         + ', '.join(f'{p} {len(v)}' for p, v in sorted(u['places'].items())) + '). Every one has readings that '
         'the scorer counts as different, so the choice moves scores; but the answer does not say whether both are '
         'right or the owner could not tell, so no alternative is credited as right here. Two treatments, beside '
         'the fixed reference:', '',
         f'- **Excluded.** The {len(clear)} hand pages with no unresolved place ({", ".join(clear)}).',
         f'- **Adverse bound.** Each page scored on every combination of the readings its unresolved places allow '
         f'({", ".join(f"{p} {k}" for p, k in sorted(u["truths"].items()))} combinations); {lead} takes its lowest '
         'and the other route its highest, page by page. Not a score: the two sides may take different readings '
         'at one place. A lead that survives it does not rest on the unresolved places.']
    if u['dropped']:
        L.append(f'- Left out: {", ".join(u["dropped"])}, whose words a correction changed.')
    L += ['', f'{lead} minus each route, 95% paired bootstrap; "tie" by the rerun-noise rule:', '',
          '| against | fixed | excluded | interval | adverse | interval |', '|---|---|---|---|---|---|']
    for ref, d in sorted(tr.items(), key=lambda kv: kv[1]['fixed']['delta']):
        e, a = d['excluded'], d['adverse']
        L.append(f'| {ref} | {f2(d["fixed"]["delta"])} {verdict(d["fixed"])} | {f2(e["delta"])} {verdict(e)} | '
                 f'{e["lo"]:+.2f} to {e["hi"]:+.2f} | {f2(a["delta"])} {verdict(a)} | {a["lo"]:+.2f} to {a["hi"]:+.2f} |')
    sm = u['summary']
    fixed, robust, lost = sm['fixed_leads'], sm['robust'], sm['conditional']
    L += ['', f'Of the {len(fixed)} routes {lead} leads on the fixed reference, it still leads {len(robust)} both '
          'without the unresolved pages and on the adverse bound'
          + (f'; against {len(lost)} ({", ".join(lost)}) it fails at least one of the two, so the API hand-route '
             'preference over them stays conditional on the truth\'s readings at those places.' if lost else '.')]
    return L


def write_md(path: Path, r: dict):
    c, h = r['controls'], r['sheet']['hand']
    lead = next(x for x in r['routes'] if x['route'] == r['lead'])
    rank = [x['route'] for x in r['routes']].index(r['lead']) + 1
    L = ['# The hand pages rescored on the owner\'s handwriting sheet (W46.ocr-hands-rescore)', '',
         'Generated by `scripts/segbench/ocr_hands_rescore.py` from saved readings only: no call, no money. The '
         'measurement audit\'s OCR-1 (`execution-plans/processing-review/11-measurement-audit.md`): Gemini 3.8 Flash '
         'drafted the 96\'s truth with Claude Opus 5.5 and leads on its 16 hand pages, so until the owner checked '
         'them the hand chart was agreement with the drafters. The owner answered the blind sheet '
         '(`ocr-hands-sheet.md`) on 2026-10-31.', '',
         '**Regenerations.** 2026-11-04 (W46.hands-kit-epochs): Granite-Docling 258M now reads its completed Mac run '
         '(W46.ocr-new-open-boxes, 17.26 with 5 of 16 failed; 11.32 with 10 failed before), and Unlimited-OCR and '
         'Nemotron-Parse 2.0, already shipped, were added; no other row moved. 2026-11-04 (W46.vision-27-swap): the '
         'apple-vision row is now the macOS 27.2 re-read (`vision-27-reread.md`; 58.06 on the 26.6 reading); no other '
         'row moved.', '',
         '## The sheet\'s rulings', '',
         f'On the 114 hand places, the truth stands at {h["truth stands"]}, the answer is "either will do / can\'t tell" at {h["either"]} '
         '(unresolved: the sheet\'s one key covers both meanings, so these are not ten readings known to be right), '
         f'the truth is wrong at {h["truth wrong"]} and {h["open"]} are notes rather than readings. Of the '
         f'{h["truth wrong"]}, 5 are the owner\'s own typed readings, 3 favour LightOnOCR-3 4B, 2 Qwen3.6-27B and 2 '
         'both. One of them (p052 h00) is a placement answer: the date is in the truth once, so it is not edited, '
         'and neither are the two placement notes (p048 h01, p052 h01). The rest are applied as '
         '`ocr_truth.CORRECTIONS`, changing ' + f'{len(r["changed_pages"])} of the 16 hand pages ('
         + ', '.join(r['changed_pages']) + ') and one typed page (p077, control c15). p052\'s "directed" is the '
         'owner\'s tentative reading (he would need the next page).', '',
         '**Struck text (owner: mark and score).** Four places are crossed-out words. The scored truth keeps struck '
         'words as plain text, because no reader is yet asked to mark them: a reader that transcribes them is '
         'right, one that drops them misses them. `ocr_truth.py apply` writes the marks to '
         '`ocr-truth/truth-struck.json` (p050\'s "was", "becoming" and "aged"; p077\'s "believe", which the owner '
         'puts before "think"), so a scorer that asks for marks can use them. One struck passage on p050 the owner '
         'cannot read; it is scored as `[illegible]`, and the drafters\' unverified reading stays only in the mark '
         'record.', '',
         '## Every route on the 16 hand pages', '',
         'Mean NES in points; a failed page scores 0, as on the panels. "Before" is the truth the panels used until '
         f'today. "Unresolved range" is the mean over the 16 with each page at its lowest and its highest score over '
         f'the readings its unresolved places allow; "{len(pages_clear(r))} clear" is the mean on the pages with none '
         '(below).', '',
         f'| route | after | before | move | failed pages | unresolved range | {len(pages_clear(r))} clear |',
         '|---|---:|---:|---:|---:|---|---:|']
    for x in r['routes']:
        L.append(f'| {x["route"]} | {x["after"]:.2f} | {x["before"]:.2f} | {f2(x["move"])} | {x["failed"]} | '
                 f'{x["lo"]:.2f} to {x["hi"]:.2f} | {x["clear"]:.2f} |')
    L += ['', f'## The API hand route: {r["lead"]}', '',
          f'On the corrected truth {r["lead"]} reads the 16 at {lead["after"]:.2f} ({f2(lead["move"])} from '
          f'{lead["before"]:.2f}), rank {rank} of {len(r["routes"])}. Paired differences, {r["lead"]} minus each '
          'route, 95% bootstrap interval over the 16 pages:', '',
          '| against | after | interval | tie | before | interval |', '|---|---:|---|---|---:|---|']
    for ref, d in sorted(r['paired'].items(), key=lambda kv: kv[1]['after']['delta']):
        a, b = d['after'], d['before']
        L.append(f'| {ref} | {f2(a["delta"])} | {a["lo"]:+.2f} to {a["hi"]:+.2f} | {"tie" if tie(a) else ""} | '
                 f'{f2(b["delta"])} | '
                 f'{b["lo"]:+.2f} to {b["hi"]:+.2f} |')
    ties = [ref for ref, d in r['paired'].items() if tie(d['after'])]
    L += ['', f'On the corrected truth, by the rerun-noise rule ({TIE} points, or an interval across 0), '
          f'{r["lead"]} ties {len(ties)} route{"" if len(ties) == 1 else "s"} ({", ".join(sorted(ties))}) and '
          f'leads the other {len(r["paired"]) - len(ties)}. The correction moves its lead over each route by '
          f'{min(d["after"]["delta"] - d["before"]["delta"] for d in r["paired"].values()):+.2f} to '
          f'{max(d["after"]["delta"] - d["before"]["delta"] for d in r["paired"].values()):+.2f} points. These are '
          'fixed-reference figures: each unresolved place is scored on the truth\'s reading, so they are conditional '
          'on it (next section).']
    L += unresolved_md(r)
    L += ['', '## The typed controls', '',
          f'{c["passages"]} passages of 8 agreed words on typed and printed pages, which both drafters and both '
          f'third-family readers read alike. The owner ruled {c["ruled"]}: {c["ruled"] - c["wrong"]} confirm the '
          f'truth and {c["wrong"]} {"is" if c["wrong"] == 1 else "are"} wrong. The 20th (p077 c15) is a struck-text '
          'note: its 8 words are right, and the struck "believe" just past them belongs before "think" (corrected). '
          f'The measured error of the agreed part on typed pages: {c["wrong"]} of {c["ruled"]} passages, 95% '
          f'interval {100 * c["rate_lo"]:.1f}% to {100 * c["rate_hi"]:.1f}%'
          + '. The draw sampled 8-word passages, not words, so the passage is the unit: a passage\'s share of wrong '
          f'words is at most 1, so the per-word rate is under the same {100 * c["per_word_hi"]:.1f}%'
          + (f' (the {100 * c["per_word_hi_if_iid"]:.1f}% once given here treats the {8 * c["ruled"]} words as '
             'independent draws, which words of one passage are not)' if c.get('per_word_hi_if_iid') else '')
          + f'. {c["ruled"]} passages bound it loosely; they do not show it is zero. These are typed and printed '
          'words: neither figure measures how often the agreed part of a hand page is agreed and wrong.', '',
          '## Measurement card', '',
          '- **Truth.** The 96\'s truth, drafted by Claude Opus 5.5 and Gemini 3.8 Flash, adjudicated by the owner, '
          'and on the 16 hand pages now checked by him blind wherever Qwen3.6-27B or LightOnOCR-3 4B differed. '
          'Gemini 3.8 is still a drafter: where both third-family readers agree with a wrong truth, nothing has '
          'looked, so its score here is still partly agreement with itself. '
          f'{sum(len(v) for v in r["unresolved"]["places"].values())} hand places were answered "either will do / '
          'can\'t tell" and stay unresolved; the fixed-reference scores keep the truth\'s reading there, and the '
          'unresolved section shows exclusion and bounds rather than crediting every alternative.',
          '- **Selection.** The 16 hand pages are the 96\'s handwritten pages less the three agreement letters; the '
          'sheet\'s places are every third-family difference, the controls a seeded draw. No ABBYY text is read.',
          '- **Comparison.** Every cached route\'s saved original-scale reading of the same 16 page images, scored '
          'by one scorer on both truths.',
          f'- **Noise.** n = 16 pages, paired bootstrap intervals above. The rerun floor is `ocr-rerun-noise.md`\'s '
          f'on the whole 96 (a gap under {TIE} points, or an interval across 0, is a tie); no hand-only rerun '
          'floor exists, and Gemini\'s reruns moved single pages by up to 18 points, so on 16 pages read the '
          'intervals, not the order of close rows.',
          '- **Scope.** Hands only on the owner\'s 16 pages. A lead that is not robust in the unresolved section is '
          'a fixed-reference lead only, so the API hand-route preference stays conditional. The controls measure the agreed part on typed pages; on '
          'hand pages the agreed-and-wrong rate stays unmeasured. Struck-text marking is not scored. Public L1-L2 '
          'and the HHTR gold rank hands on independent truth.', '']
    path.write_text('\n'.join(L) + '\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', type=Path, default=RESULTS)
    r = build(ap.parse_args().out)
    lead = next(x for x in r['routes'] if x['route'] == r['lead'])
    print(f'{len(r["routes"])} routes on {len(r["pages"])} hand pages; {r["lead"]} {lead["after"]:.2f} '
          f'({lead["move"]:+.2f}); controls {r["controls"]["wrong"]}/{r["controls"]["ruled"]} wrong')


if __name__ == '__main__':
    main()
