#!/usr/bin/env python3
"""W46.fix-ocr-truth-bias-score: score the owner's blind re-adjudication of the 96's truth against Qwen3.6-27B.

ocr_truth_bias.py built the blind sheet (ocr_truth.CACHE/blind/): 59 places on 20 pages where qwen3.6-27b reads the
agreed (never reviewed) truth words differently, each shown as A and B in a random order. The owner's answers are
blind/answers.json ('a', 'b', 'either', or '=' and typed text). This script unblinds them with key.json and classes
each place:

  truth      the owner chose the truth's reading (or typed one that agrees with it on the word in question)
  reader     the owner chose qwen's reading: the truth is wrong there
  neither    the owner typed a reading that is neither
  either     the owner says either reading will do
  frame      the owner says the text is not on the page (a folder label or another sheet in the photograph)
  placement  the owner says it is the same text in a different place: reading order, not reading
  unanswered / excluded

Typed answers are notes as often as readings, so each is classed by hand in TYPED below, with the reason. p081 is
excluded by the owner, and the owner's note on p093 ("typographical dividers, either reading is fine") answers every
divider place on that page.

What the bias costs a route: the panel's word accuracy is the share of truth words read in order, so a place costs
qwen only the truth words it holds (a truth word missing from the truth costs nobody). The estimate is the share of
qwen's charged truth words, on the judged places, that sit where the truth is wrong (reader or neither), with a
page-bootstrap interval, scaled to all 194 eligible places on the 50 pages and set against qwen's agreed-word miss.

Saved answers only: no call, no money. The per-place result with every note verbatim stays private
(blind/scored.json); the committed result keeps each note with quoted page text elided.
"""
import argparse
import json
import random
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
RESULTS = HERE.parents[1] / 'segbench-results'
CACHE = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/ocr-truth'
BLIND = CACHE / 'blind'
SEED = 46
BOOT = 4000
MATERIAL = 0.25   # points: a truth fault worth this much of the reference's agreed-word score would be material

EXCLUDED = {'p081': 'owner: a badly scanned microfilm of an early-20th-century newspaper, far outside the corpus; '
                    'not answered beyond the note'}
DIVIDERS = {'p093'}   # the owner's note on the page's first place answers every divider place on it
DIVIDER = re.compile(r'^(?:[o0]\s*)+$', re.I)

# Typed ('=') answers, read by hand. Key 'page#place' -> (class, why).
TYPED = {
    'p007#0': ('frame', 'the date is typed on a separate sheet above the page; the page has only an illegible mark'),
    'p009#0': ('neither', 'owner reads the number as "16" or "10", probably "10"; the truth marks it illegible, '
                          'qwen reads "16"'),
    'p009#3': ('frame', 'qwen read the folder label in the background; not part of the page'),
    'p025#0': ('truth', 'owner typed the truth\'s reading but for the last character (1 for l); the initials '
                        'qwen misread are the truth\'s'),
    'p041#0': ('frame', 'qwen read a number on the page behind this one'),
    'p046#1': ('placement', 'same text, different placement; the pair of p046#0, where the owner chose the truth\'s '
                            'place'),
    'p054#12': ('truth', 'owner typed "form", the truth\'s word; qwen read "from" (the truth\'s neighbouring '
                         '"interests" is not in question)'),
    'p072#0': ('frame', 'qwen read the folder title in the background, not the document'),
    'p081#0': ('excluded', EXCLUDED['p081']),
    'p093#0': ('either', 'typographical dividers; either reading is fine'),
}
TRUTH_FAULT = ('reader', 'neither')
JUDGED = ('truth', 'reader', 'neither', 'either', 'frame', 'placement')
QUOTED = re.compile(r'"[^"]*"')


def classify(page: str, place: str, item: dict, answer: str | None) -> tuple[str, str]:
    key = f'{page}#{place}'
    if key in TYPED:
        return TYPED[key]
    if page in EXCLUDED:
        return 'excluded', EXCLUDED[page]
    if page in DIVIDERS and DIVIDER.match(item['truth']) and DIVIDER.match(item['qwen']):
        return 'either', 'divider; the owner\'s note on the page answers it'
    if not answer:
        return 'unanswered', ''
    if answer.startswith('='):
        raise SystemExit(f'{key}: typed answer not classed by hand in TYPED: {answer!r}')
    if answer == 'either':
        return 'either', ''
    chose = item['a'] if answer == 'a' else ('qwen' if item['a'] == 'truth' else 'truth')
    return ('truth', '') if chose == 'truth' else ('reader', '')


def scored(key: dict, answers: dict) -> list[dict]:
    rows = []
    for page, pg in key['pages'].items():
        for place, item in pg['items'].items():
            ans = answers.get(page, {}).get(place)
            cls, why = classify(page, place, item, ans)
            rows.append({'page': page, 'place': int(place), 'class': cls, 'answer': ans, 'why': why,
                         'truth': item['truth'], 'qwen': item['qwen'], 'mixed': item['mixed'],
                         'charged': item['truth_words']})
    return rows


def share(rows: list[dict]) -> tuple[float, int, int]:
    judged = [r for r in rows if r['class'] in JUDGED]
    bad = sum(r['charged'] for r in judged if r['class'] in TRUTH_FAULT)
    tot = sum(r['charged'] for r in judged)
    return (bad / tot if tot else 0.0), bad, tot


def bootstrap(rows: list[dict], rng: random.Random) -> tuple[float, float]:
    pages = sorted({r['page'] for r in rows if r['class'] in JUDGED})
    by = {p: [r for r in rows if r['page'] == p] for p in pages}
    xs = sorted(share([r for p in rng.choices(pages, k=len(pages)) for r in by[p]])[0] for _ in range(BOOT))
    return xs[int(0.025 * BOOT)], xs[int(0.975 * BOOT) - 1]


def elide(note: str | None) -> str | None:
    return QUOTED.sub('"…"', note) if note else note


def public(r: dict) -> dict:
    """The committed row: no page text (readings dropped, quoted words in notes elided)."""
    ans = r['answer']
    return {'page': r['page'], 'place': r['place'], 'class': r['class'], 'mixed': r['mixed'], 'charged': r['charged'],
            'answer': elide(ans) if ans and ans.startswith('=') else ans, 'why': elide(r['why'])}


def summarise(rows: list[dict], diffs: dict, bias: dict) -> dict:
    classes = {}
    for r in rows:
        c = classes.setdefault(r['class'], {'places': 0, 'charged': 0})
        c['places'] += 1
        c['charged'] += r['charged']
    s, bad, tot = share(rows)
    lo, hi = bootstrap(rows, random.Random(SEED))
    eligible = [x for l in diffs.values() for x in l if not x['join'] and not x['block']]
    blocks = [x for l in diffs.values() for x in l if x['block']]
    # a passage moved: the truth's words are missing here and a passage of the reader's is added elsewhere on the page
    moved = [x for l in diffs.values() for x in l if x['block'] and x['truth_words'] and not x['qwen_words']
             and any(y['block'] and not y['truth_words'] for y in l)]
    ref = next(r for r in bias['split'] if r['route'] == bias['reference'])
    n = ref['agreed_n']
    pop = sum(x['truth_words'] for x in eligible)
    pts = lambda f: 100 * f * pop / n
    drafters = bias['by_family'].get('drafter family', {})
    return {
        'reference': bias['reference'], 'places': len(rows), 'pages': len({r['page'] for r in rows}),
        'classes': classes,
        'judged': sum(1 for r in rows if r['class'] in JUDGED),
        'truth_fault_places': sum(1 for r in rows if r['class'] in TRUTH_FAULT),
        'charged_judged': tot, 'charged_truth_fault': bad,
        'truth_fault_share': s, 'truth_fault_share_ci': [lo, hi],
        'population': {'places': len(eligible), 'charged': pop,
                       'block_places': len(blocks), 'block_charged': sum(x['truth_words'] for x in blocks),
                       'moved_charged': sum(x['truth_words'] for x in moved)},
        'reader_omitted_by_truth': sum(1 for r in rows if r['class'] == 'reader' and not r['charged']),
        'reference_agreed_n': n,
        'reference_agreed_missed_joined': n - ref['agreed_joined'],
        'reference_miss_joined_pts': 100 * (1 - ref['agreed_acc_joined']),
        'bias_pts': pts(s), 'bias_pts_ci': [pts(lo), pts(hi)],
        'drafter_lead_joined_pts': 100 * drafters['lead_agreed_joined'] if drafters else None,
        'material_pts': MATERIAL, 'material': pts(hi) >= MATERIAL,
        'excluded': EXCLUDED,
    }


def write_md(path: Path, out: dict):
    s, c = out['summary'], out['summary']['classes']
    g = lambda k, f='places': c.get(k, {}).get(f, 0)
    lo, hi = s['truth_fault_share_ci']
    blo, bhi = s['bias_pts_ci']
    pop = s['population']
    L = ['# The owner\'s blind truth check, scored (W46.fix-ocr-truth-bias-score)', '',
         f'Generated by `scripts/segbench/ocr_truth_bias_score.py` from the owner\'s saved answers to the blind sheet '
         f'`ocr_truth_bias.py` built (answered 2026-10-21): no call, no money. The sheet showed {s["places"]} places on '
         f'{s["pages"]} of the 96 pages where {s["reference"]} reads the agreed, never-reviewed truth words '
         f'differently, each as A and B without saying which was the truth.', '',
         '## What the owner found', '',
         '| class | places | truth words at stake |', '|---|--:|--:|']
    names = {'truth': 'the truth is right, the reader wrong', 'reader': 'the reader is right, the truth wrong',
             'neither': 'neither reading is right', 'either': 'either reading will do',
             'frame': 'not on the page (background label or another sheet)', 'placement': 'same text, another place',
             'unanswered': 'unanswered', 'excluded': 'excluded by the owner'}
    for k in ('truth', 'reader', 'neither', 'either', 'frame', 'placement', 'unanswered', 'excluded'):
        if k in c:
            L.append(f'| {names[k]} | {g(k)} | {g(k, "charged")} |')
    L += ['', f'"Truth words at stake" counts the truth words the place costs {s["reference"]} under the panel\'s '
          f'word accuracy (the share of truth words read in order). A word the truth leaves out costs nobody, so the '
          f'{g("reader")} places where the reader is right and the truth wrong cost {g("reader", "charged")} '
          f'truth word(s): in {s["reader_omitted_by_truth"]} of them the truth omits a word the page has, and in '
          f'the rest it has the wrong word.', '',
          '## Is the bias material?', '',
          f'Of the {s["charged_judged"]} truth words at stake on the {s["judged"]} judged places, '
          f'the truth is wrong at {s["charged_truth_fault"]}: {100 * s["truth_fault_share"]:.1f}% '
          f'[95% page bootstrap {100 * lo:.1f}, {100 * hi:.1f}]. Scaled to all {pop["places"]} such places on the '
          f'96 ({pop["charged"]} truth words at stake), the truth\'s own mistakes cost {s["reference"]} about '
          f'{s["bias_pts"]:.2f} points of its agreed-word score [{blo:.2f}, {bhi:.2f}], against the '
          f'{s["reference_miss_joined_pts"]:.2f} points it misses with joins forgiven and the drafter family\'s '
          f'+{s["drafter_lead_joined_pts"]:.2f}-point lead over it.', '',
          ('**Material: yes.**' if s['material'] else '**Material: no.**') +
          f' The threshold is {s["material_pts"]:.2f} points at the top of the interval, under a third of the lead. '
          + ('A fresh 50-page set is drafted (W46.fix-ocr-truth-bias-score, size M).' if s['material'] else
             'No fresh 50-page set is drafted: the 96\'s truth stands, and the drafter family\'s lead on it is '
             'not the truth\'s mistakes.'), '',
          'Where the lead comes from instead. The places the sheet left out are not readings: '
          f'{pop["block_places"]} passages of more than six words left out, added or moved cost '
          f'{s["reference"]} {pop["block_charged"]} truth words ({100 * pop["block_charged"] / s["reference_agreed_n"]:.2f} '
          f'points), {pop["moved_charged"]} of them in passages {s["reference"]} read but placed elsewhere on the '
          f'page (a sidebar, an author note, a letterhead): reading order, which the order scores of '
          f'W46.fix-ocr-scorers measure apart. Line-end joins are already forgiven. The judged places add '
          f'conventions that are nobody\'s misreading: {g("either")} where either reading will do (dividers written '
          f'"o o o" or "0 0 0", which cost {g("either", "charged")} words) and {g("frame")} where {s["reference"]} '
          f'read text that is not on the page, a folder label or a sheet behind it (the truth is right to leave it '
          f'out; the metric charges nothing for it). Which order is the page\'s is the one part of the lead the blind '
          f'sheet did not test; for a moved sidebar it is a convention more than a fact, and no item is filed for it.', '',
          '## Every place', '',
          'Readings are left out (owner material); the owner\'s notes are kept with each place, quoted page text '
          'elided. The private copy with the readings and notes verbatim is `ocr-truth/blind/scored.json`.', '',
          '| page | place | class | owner\'s answer | how it was read |', '|---|--:|---|---|---|']
    for r in out['places']:
        L.append(f'| {r["page"]} | {r["place"]} | {r["class"]} | {r["answer"] or ""} | {r["why"] or ""} |')
    path.write_text('\n'.join(L) + '\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', type=Path, default=RESULTS)
    a = ap.parse_args()
    key = json.loads((BLIND / 'key.json').read_text())
    answers = json.loads((BLIND / 'answers.json').read_text())
    diffs = json.loads((BLIND / 'differences.json').read_text())
    bias = json.loads((a.out / 'ocr-truth-bias.json').read_text())
    rows = scored(key, answers)
    (BLIND / 'scored.json').write_text(json.dumps(rows, ensure_ascii=False, indent=1))
    out = {'summary': summarise(rows, diffs, bias), 'places': [public(r) for r in rows]}
    (a.out / 'ocr-truth-bias-score.json').write_text(json.dumps(out, ensure_ascii=False, indent=1))
    write_md(a.out / 'ocr-truth-bias-score.md', out)
    s = out['summary']
    print(f'{s["judged"]} judged of {s["places"]}; truth wrong at {s["truth_fault_places"]} places, '
          f'{s["charged_truth_fault"]}/{s["charged_judged"]} words; bias {s["bias_pts"]:.2f} pts '
          f'[{s["bias_pts_ci"][0]:.2f}, {s["bias_pts_ci"][1]:.2f}]; material={s["material"]}')


if __name__ == '__main__':
    main()
