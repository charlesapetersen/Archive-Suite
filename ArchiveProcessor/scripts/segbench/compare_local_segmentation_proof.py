#!/usr/bin/env python3
"""Compare a live local proof's window evidence against the independent Python bench, no model calls.

python3 -B scripts/segbench/compare_local_segmentation_proof.py /tmp/proof/result.json
The proof's folder is fixed to Herrnstein 19-39. No OCR/images/cues are read or emitted.
"""
import argparse
import json
from pathlib import Path

import data
import method_window as W
from score import boundaries_from_labels


def compare(result):
    assert result['folder'] == 'Herrnstein 19-39' and result['run'] == 'local:mac'
    whole = data.load('Herrnstein', with_exif=False)
    pages = [p for p in whole.pages if 19 <= p.n <= 39]
    folder = data.Collection('Herrnstein 19-39', whole.directory,
                             [data.Page(i + 1, p.label, None) for i, p in enumerate(pages)])
    windows = {(w['start'], w['end']): w for w in result['windows']}
    expected = set(W.windows(len(pages)))
    assert set(windows) == expected, 'a window is missing or extra'
    assert len(result['windows']) == len(windows) == result['answered_windows'] == result['expected_windows']
    def judge(col, a, b, allow_call=False):
        w = windows[a, b]
        assert w['voter'] == 'window-local-seg-2b'
        bounds = {v['page']: {**v, 'cue': ''} for v in w['boundaries']}
        assert set(bounds) == set(range(a + 1, b))
        return {'pages': {}, 'boundaries': bounds}
    pred = W.assemble(folder, W.combine(folder, judge), truth_photos=True)
    truth = [x == 'new' for x in boundaries_from_labels(folder.labels)]
    before = [x == 'new' for x in boundaries_from_labels(pred.labels)]
    level = next(a['level'] for a in json.loads((data.HERE.parents[1] / 'segbench-results/options.json').read_text())['approaches'] if a['id'] == 'local')
    flagged = {i for i, b in enumerate(pred.boundaries) if not b['fixed'] and b['confidence'] <= level}
    observed = {x['gap']: x for x in result['flagged_gaps']}
    assert set(observed) == flagged, 'flagged gap ids differ from bench'
    for i, gap in observed.items():
        assert abs(gap['confidence'] - pred.boundaries[i]['confidence']) < 1e-10
        assert gap['proposal'] == ('new' if before[i] else 'continue')
    after = [truth[i] if i in flagged else b for i, b in enumerate(before)]
    assert before == result['boundaries_before_review'], 'bench/app proposals differ'
    assert after == result['boundaries_after_review'], 'bench/app final classifications differ'
    assert truth == result['truth'], 'truth differs'
    def exact(boundaries):
        # Bench document spans exclude the label photo; add it for the proof's all-page denominator.
        from score import score_labels
        labels = [folder.labels[0]] + [('New' if new else 'Cont') for new in boundaries]
        return score_labels(folder.labels, labels).pages_exact + sum(p.label in data.PHOTO_LABELS for p in folder.pages)
    assert exact(before) == result['pages_exact_no_review']
    assert exact(after) == result['pages_exact_after_review']
    assert len(flagged) == result['flagged']
    assert sum(before[i] != truth[i] for i in flagged) == result['changed_by_review']
    assert sum(before[i] != truth[i] for i in range(len(before)) if i not in flagged) == result['unflagged_wrong']
    print(f'PASS: {len(windows)} windows, {len(before)} proposed/final boundaries, {len(flagged)} flagged ids/confidences, truth and all score totals match the Python bench')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('result', type=Path)
    args = parser.parse_args()
    rows = json.loads(args.result.read_text())
    assert len(rows) == 1
    compare(rows[0])
