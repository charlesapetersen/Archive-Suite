#!/usr/bin/env python3
"""W46.ocr-hands-rescore. Every route on the 96's 16 hand pages, on the truth before and after the owner's blind
handwriting sheet (ocr_hands_sheet.py, answered 2026-10-31), the typed controls' error rate, and the API hand route.

  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy python ocr_hands_rescore.py

Reads saved files only: no model, no network, no money. The corrections themselves are ocr_truth.CORRECTIONS, put
into the cache's truth/ by `ocr_truth.py apply` (the pre-sheet copy is ocr-truth/truth-before-hands/). Readings are
ocr_rescore.owner_sources() (every cached route on the 96); a failure is an empty reading and scores as such, as on
the panels. Scores are ocr_panel_score.score's NES, in points; intervals are ocr_panel_score.paired (per-page
differences, 95% bootstrap, 10,000 rounds).

Writes segbench-results/ocr-hands-rescore.md and .json (scores and counts only; no text).
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


def scores(pages: list[str], truth_dir: Path) -> dict[str, dict[str, float]]:
    src = RS.owner_sources()
    keys = [r for r, _ in src]
    out = {}
    for (route, family), texts in src.items():
        if not any((texts.get(p) or '').strip() for p in pages):
            continue   # a route with no reading of any hand page
        truth = {p: (truth_dir / f'{p}.txt').read_text() for p in pages}
        out[route_name(route, family, keys)] = {p: 100 * S.score(truth[p], texts.get(p) or '')['nes'] for p in pages}
    return out


def controls(rulings: dict) -> dict:
    items = [(p, i, v) for p, d in rulings.items() for i, v in d.items() if v['kind'] == 'control']
    ruled = [v for _, _, v in items if v['truth_stands'] is not None]
    wrong = [f'{p} {i}' for p, i, v in items if v['truth_stands'] is False]
    n, k = len(ruled), len(wrong)
    lo, hi = clopper(k, n)
    words = sum(1 for _, _, v in items for _ in v['readings']['truth'].split())
    return {'passages': len(items), 'ruled': n, 'wrong': k, 'wrong_items': wrong, 'words': words,
            'rate_lo': lo, 'rate_hi': hi, 'per_word_hi': clopper(0, n * 8)[1] if k == 0 else None}


def build(out: Path) -> dict:
    key = json.loads((HANDS / 'key.json').read_text())
    rulings = json.loads((HANDS / 'rulings.json').read_text())
    pages = key['hand_pages']
    after, before = scores(pages, T.CACHE / 'truth'), scores(pages, BEFORE)
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
    counts = rulings['counts']
    res = {'pages': pages, 'changed_pages': changed, 'routes': rows, 'lead': LEAD, 'paired': pairs,
           'sheet': counts, 'controls': controls(rulings['rulings'])}
    out.mkdir(parents=True, exist_ok=True)
    (out / 'ocr-hands-rescore.json').write_text(json.dumps(res, indent=1) + '\n')
    write_md(out / 'ocr-hands-rescore.md', res)
    return res


def tie(d: dict) -> bool:
    return abs(d['delta']) < TIE or d['lo'] <= 0 <= d['hi']


def f2(x):
    return f'{x:+.2f}'


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
         '## The sheet\'s rulings', '',
         f'On the 114 hand places, the truth stands at {h["truth stands"]}, either reading is right at {h["either"]}, '
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
         'today.', '',
         '| route | after | before | move | failed pages |', '|---|---:|---:|---:|---:|']
    for x in r['routes']:
        L.append(f'| {x["route"]} | {x["after"]:.2f} | {x["before"]:.2f} | {f2(x["move"])} | {x["failed"]} |')
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
          f'{max(d["after"]["delta"] - d["before"]["delta"] for d in r["paired"].values()):+.2f} points: it '
          'stays the API hand route.']
    L += ['', '## The typed controls', '',
          f'{c["passages"]} passages of 8 agreed words on typed and printed pages, which both drafters and both '
          f'third-family readers read alike. The owner ruled {c["ruled"]}: {c["ruled"] - c["wrong"]} confirm the '
          f'truth and {c["wrong"]} {"is" if c["wrong"] == 1 else "are"} wrong. The 20th (p077 c15) is a struck-text '
          'note: its 8 words are right, and the struck "believe" just past them belongs before "think" (corrected). '
          f'The measured error of the agreed part on typed pages: {c["wrong"]} of {c["ruled"]} passages, 95% '
          f'interval {100 * c["rate_lo"]:.1f}% to {100 * c["rate_hi"]:.1f}%'
          + (f'; per word, 0 of {8 * c["ruled"]}, under {100 * c["per_word_hi"]:.1f}%' if c['per_word_hi'] else '')
          + f'. {c["ruled"]} passages bound it loosely; they do not show it is zero.', '',
          '## Measurement card', '',
          '- **Truth.** The 96\'s truth, drafted by Claude Opus 5.5 and Gemini 3.8 Flash, adjudicated by the owner, '
          'and on the 16 hand pages now checked by him blind wherever Qwen3.6-27B or LightOnOCR-3 4B differed. '
          'Gemini 3.8 is still a drafter: where both third-family readers agree with a wrong truth, nothing has '
          'looked, so its score here is still partly agreement with itself.',
          '- **Selection.** The 16 hand pages are the 96\'s handwritten pages less the three agreement letters; the '
          'sheet\'s places are every third-family difference, the controls a seeded draw. No ABBYY text is read.',
          '- **Comparison.** Every cached route\'s saved original-scale reading of the same 16 page images, scored '
          'by one scorer on both truths.',
          f'- **Noise.** n = 16 pages, paired bootstrap intervals above. The rerun floor is `ocr-rerun-noise.md`\'s '
          f'on the whole 96 (a gap under {TIE} points, or an interval across 0, is a tie); no hand-only rerun '
          'floor exists, and Gemini\'s reruns moved single pages by up to 18 points, so on 16 pages read the '
          'intervals, not the order of close rows.',
          '- **Scope.** Hands only on the owner\'s 16 pages. The controls measure the agreed part on typed pages; on '
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
