#!/usr/bin/env python3
"""Replay W46.p18-mixed-switch-score from the saved mixed-def labels, features and owner checks.

Run with the bench Python (NumPy) under heavy-run.py. No images, models, network or new rulings.
Only aggregate results are written to segbench-results/mixed-switch-score.{md,json}.
"""
from collections import Counter
import json
import re

import numpy as np

import kind_atrium as KA
import kind_classifier as KC
import mixed_def as MD


def confidence_floor():
    source = KA.HERE.parents[1] / 'macOS/Sources/ArchiveProcessor/OCR/PageKindRouting.swift'
    return float(re.search(r'static let minimumConfidence = (\d+\.\d+)', source.read_text())[1])


def replay_kinds(labels):
    model = json.loads(MD.MODEL_JSON.read_text())
    signals = {r['id']: r for r in MD.read_csv(MD.CACHE / 'signals.tsv', '\t')}
    prints = KA.prints_of(MD.CACHE / 'featureprints.tsv')
    if not labels.keys() <= (signals.keys() & prints.keys()):
        raise ValueError('missing saved kind features')

    def regression(name):
        rule = model[name]
        scalars = [c for c in rule['features'] if not c.startswith('print')]
        features = np.array([[*(KC.num(signals[p][c]) for c in scalars), *prints[p]] for p in labels])
        # Missing table measurements and NaN hand scalars both enter the app as zero.
        features[np.isnan(features)] = 0
        scores = (features - rule['mean']) / rule['sd'] @ rule['W'] + rule['b']
        exp = np.exp(scores - scores.max(axis=1, keepdims=True))
        return exp / exp.sum(axis=1, keepdims=True)

    hand = regression('hand')
    forms = regression('form')
    hand_classes = model['hand']['classes']
    if model['form']['classes'] != ['no', 'yes']:
        raise ValueError('unexpected form classes')
    result = {}
    for p, h, f in zip(labels, hand, forms):
        i = int(h.argmax())
        if hand_classes[i] != labels[p]['regression']:
            raise ValueError('hand replay differs from saved labels')
        result[p] = ('forms', f[1]) if f[1] > f[0] else (hand_classes[i], h[i])
    return result


def score():
    rows = MD.read_csv(MD.CACHE / 'labels.tsv', '\t')
    labels = {r['page']: r for r in rows}
    if len(rows) != MD.N_PAGES or len(labels) != len(rows):
        raise ValueError('expected the frozen 2,000 distinct pages')
    key, _, truth = KA.mixed_owner_checks()
    floor = confidence_floor()
    kinds = replay_kinds(labels)

    # The ATRIUM rerun in kind-atrium.md §5 matched every saved top class.
    flagged = {p for p, r in labels.items() if r['atrium'] == 'TEXT'}
    typed = {'typewritten', 'printed'}
    eligible = {p for p, (kind, conf) in kinds.items() if kind in typed and conf >= floor}
    baseline = {p for p, (kind, conf) in kinds.items() if kind == 'handwritten' and conf >= floor}
    added = eligible & flagged
    low_print = {p for p, (kind, conf) in kinds.items() if kind == 'printed' and conf < floor}
    simple_hand = {p for p, r in labels.items() if r['regression'] == 'handwritten'}
    simple_added = flagged - simple_hand

    comparisons = {
        'Kind-only handwriting pick': (baseline, labels.keys()),
        'Switch additions, all-page recall': (added, labels.keys()),
        'Switch additions, eligible-page recall': (added, eligible),
        'Kind and switch together': (baseline | added, labels.keys()),
    }
    design, scores = KA.mixed_support(
        labels, key, truth,
        {name: {p: p in called for p in labels} for name, (called, _) in comparisons.items()},
        domains={name: domain for name, (_, domain) in comparisons.items()},
    )
    standalone, = KA.mixed_support(
        labels, key, truth, {'ATRIUM alone': {p: p in flagged for p in labels}}
    )[1]
    return {
        'design': design, 'confidence_floor': floor,
        'eligible_by_kind': dict(sorted(Counter(kinds[p][0] for p in eligible).items())),
        'added_by_kind': dict(sorted(Counter(kinds[p][0] for p in added).items())),
        'excluded_simple_flags': {
            'form': sum(kinds[p][0] == 'forms' for p in simple_added - added),
            'low_confidence': sum(kinds[p][0] in typed for p in simple_added - added),
        },
        'low_confidence_printed': len(low_print), 'low_confidence_printed_flagged': len(low_print & flagged),
        'simple': {'kind_only': len(simple_hand), 'added': len(simple_added),
                   'combined': len(simple_hand | simple_added)},
        'standalone': standalone, 'routing': scores,
    }


def report(result):
    design = result['design']
    eligible = sum(result['eligible_by_kind'].values())
    added = sum(result['added_by_kind'].values())
    def pct(x):
        return 'undefined' if x is None else f'{100*x:.2f}%'

    excluded, simple = result['excluded_simple_flags'], result['simple']
    length = design['population']
    names = ', '.join(f'{n:,} {k}' for k, n in result['added_by_kind'].items())
    lines = [
        '# What the handwriting switch adds with the pre-flag',
        '',
        'W46.p18-mixed-switch-score · Pass 18 P18-5 · See `kind-atrium.md` §5 for the standalone detector.',
        '',
        f'In the saved-page replay, {eligible:,}/{length:,} pages met the typed/printed and confidence rules. '
        f'The downloaded pre-flag would make **{added:,} of those pages candidates for the handwriting reader** '
        f'({names}), or {pct(added/eligible)} of eligible pages and {pct(added/length)} of the draw. '
        f'The handwriting kind alone chose {result["routing"][0]["full"]["calls"]} pages, and the union chose '
        f'{result["routing"][-1]["full"]["calls"]}. Each choice can replace the page’s usual reader.',
        '',
        f'The hand-only labels would yield {simple["kind_only"]} existing choices and {simple["added"]} additions '
        f'({simple["combined"]} total). Replaying the form override and confidence floor '
        f'({result["confidence_floor"]:.2f}) excludes {excluded["form"]} form and {excluded["low_confidence"]} '
        'low-confidence pages from the additions.',
        '',
        '## Estimates and their support',
        '',
        'Mixed means handwriting on typed or printed text, including a signature. Precision is the share of called '
        'pages that are mixed. In the kind-only and combined rows, a correctly routed wholly handwritten page still '
        'counts outside this mixed-page target. Recall is the share of mixed pages called, either in the whole '
        'draw or among eligible pages as named.',
        '',
        f'Covered estimates use the original population-to-check weights within each of the fixed disagreement '
        f'patterns and clean controls, plus weight 1 for the 39-page census. The 11 top-ups constrain exact bounds. '
        f'The weighted covered frame is {design["covered_pages"]:,} pages before eligibility, with '
        f'{design["observed_answers"]} owner checks in the full draw. Each mixed-page numerator and recall denominator '
        'uses those weights on its own domain. Precision uses the exact count of called pages in the covered '
        'domain because eligibility can vary within a pattern.',
        '',
        '| Rule | Full calls | Checked mixed hits / calls | Mixed / judged | Covered pages | Weighted mixed hits | Weighted mixed pages | Covered precision | Covered recall |',
        '|---|---:|---:|---:|---:|---:|---:|---:|---:|',
    ]
    all_rows = [result['standalone'], *result['routing']]
    for r in all_rows:
        s, c = r['sheet'], r['covered']
        lines.append(f'| {r["label"]} | {r["full"]["calls"]} | {s["found"]}/{s["found"] + s["false"]} | '
                     f'{s["mixed"]}/{s["n"]} | {c["pages"]:,} | {c["tp"]:.2f} | {c["tp"] + c["fn"]:.2f} | '
                     f'{pct(c["precision"])} | {pct(c["recall"])} |')
    for field, explanation in (
        ('point_completion', 'Hold the covered weighted counts fixed and vary missing truth in the omitted strata.'),
        ('finite_completion', 'Keep all owner checks fixed and vary the truth of every unchecked page.'),
    ):
        lines += [
            '',
            f'**{"Point-completion sensitivity" if field == "point_completion" else "Exact finite-population bounds"}.** '
            f'{explanation} “Hand not mixed” treats unchecked agreed-handwritten pages as wholly handwritten. '
            '“Unrestricted” leaves their truth open too. These ranges are completion bounds, with no confidence level.',
            '',
            '| Rule | Precision, hand not mixed | Recall, hand not mixed | Precision, unrestricted | Recall, unrestricted |',
            '|---|---:|---:|---:|---:|',
        ]
        for r in all_rows:
            ranges = r['full'][field]
            cells = ['–'.join(map(pct, ranges[a][m]))
                     for a in ('hand_not_mixed', 'unrestricted') for m in ('precision', 'recall')]
            lines.append(f'| {r["label"]} | ' + ' | '.join(cells) + ' |')

    baseline = result['routing'][0]
    c, checked = baseline['covered'], baseline['sheet']
    lines += [
        '',
        f'With the switch off, the weights estimate {c["tp"]:.2f} mixed hits across {c["calls"]} covered calls. '
        f'The owner checked {checked["false"]} of those calls as nonmixed, so the exact maximum is '
        f'{c["calls"] - checked["false"]}. This small overshoot in the survey estimate carries through to the '
        'upper weighted precision endpoints for that row. The finite bounds give the feasible endpoints.',
    ]

    lines += [
        '',
        '## Measurement card',
        '',
        '- **Truth.** The same 170 blind owner checks and any-handwriting cut as `mixed-def-score.md` and '
        '`kind-atrium.md` §5. The owner’s threshold answers supply the truth for every rule.',
        '- **Selection.** The same frozen 2,000-page bulk pilot and enriched owner sheet. The draw uses several '
        'classifiers’ disagreement patterns, including ATRIUM’s, plus clean controls and the census. The replay '
        'reused saved labels and features and cost $0.',
        '- **Comparison.** Same pages with and without the switch. Replayed the bundled hand and form regressions on '
        'the saved rounded Vision features. Forms win before the hand; the routing confidence floor applies to the '
        'chosen kind. The saved ATRIUM top class supplies the downloaded flag’s positive/negative result.',
        f'- **Noise.** {design["singleton_patterns"]} noncensus disagreement patterns have one checked page. The '
        'finite bounds include unchecked truths within sampled patterns. The point sensitivities hold the weighted '
        'covered estimates fixed and omit their sampling uncertainty.',
        '- **Scope.** This models direct per-image kind routing with the pre-flag downloaded and complete, a distinct '
        'runnable handwriting pick, no manual reader override, and both kind routing and the switch on. Saved features '
        'cannot observe live reader or key availability, identical reader choices, overrides, route settings, '
        'classifier/pre-flag failures, or the app’s newspaper and Finder-tag decisions. '
        f'Of the {result["low_confidence_printed"]} low-confidence printed pages, '
        f'{result["low_confidence_printed_flagged"]} have a positive flag and could become eligible if the app’s '
        'newspaper layout check promotes them. With a missing or failed flag the app falls back to allowing the '
        f'switch on all {eligible:,} replay-eligible pages. PDFs, paid batch, gateway, Local Agent, Apple Vision and '
        'pre-OCRed input fall outside this file-list route. The scores measure routing to the handwriting reader. '
        'The text it returns, actual traffic and performance on another corpus were unmeasured.',
    ]
    path = KA.RESULTS / 'mixed-switch-score'
    path.with_suffix('.md').write_text('\n'.join(lines) + '\n')
    path.with_suffix('.json').write_text(json.dumps(result, indent=1, default=float) + '\n')


if __name__ == '__main__':
    report(score())
