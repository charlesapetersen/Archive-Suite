#!/usr/bin/env python3
"""Prepare the bounded recheck of frozen marks export da388b05c388.

No document reading, model or corpus write. Relationships cite the owner's
explicit candidate references; they do not choose a class, merge geometry or
invent a reading. Unresolved places keep their detector/transcription masks.
The original freeze is verified and never rewritten.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import shutil
import tempfile

import marks_core as C
import marks_pilot as P
import marks_scan as SC
import marks_sheet as S

ANSWER_SHA = 'da388b05c3885d6fc1f20986ddea02ba7cbed7274de5c33a4d3b1b5b98554b38'
RELATIONS = {
    'Dean-0a07517aa636ba99': [('2', '1', 'duplicate'), ('7', '6', 'connected'), ('12', '13', 'part_of')],
    'Dean-23edf5f15485b7ff': [('2', '1', 'same_annotation')],
    'Dean-b31c4f7387db3844': [('6', '8', 'duplicate'), ('8', '6', 'duplicate')],
    # The comment establishes duplicated text, not identical geometry: candidate
    # 6's reading is longer. Keep both boxes and classes rather than suppressing one.
    'Herrnstein-04d25d2e123a33d0': [('5', '6', 'duplicate_text')],
}
PENDING = {
    'Dean-7d1bce1dde28dfee': ['2'],
    'Dean-d3a52a7e272b066a': ['3'],
    'Dean-e6ecf7a0b3ed6e6b': ['1', '2'],
    'Herrnstein-39bea9fb30cda479': ['2'],
    'Herrnstein-3f753f88969588ac': ['1'],
    'Herrnstein-5d66cd10e6af25f0': ['1'],
    'RG165-15a0647456422fb9': ['1', '3'],
}


def verify_freeze(root):
    frozen = P.load(root / 'freeze.json')
    if frozen['receipts']['answers'] != ANSWER_SHA:
        raise ValueError('this reconciliation is only for export da388b05c388')
    for name, digest in frozen['files'].items():
        if C.sha(P.relative(root, name)) != digest:
            raise ValueError('frozen file changed: ' + name)
    for name, file in [('answers', 'answers.json'), ('sheet_key', 'sheet-key.json'),
                       ('selection', 'selection.json')]:
        if C.sha(root / file) != frozen['receipts'][name]:
            raise ValueError('frozen input receipt differs: ' + name)
    return frozen


def reconcile(answers, feedback):
    """Every comment is accounted for, with exact owner evidence retained outside Git."""
    entries, seen = [], set()
    for page in feedback:
        pid = page['page']
        for e in page['entries']:
            cid = e['candidate']
            if e['field'] != 'text' or (pid, cid) in seen:
                raise ValueError('unexpected feedback field or repeated entry')
            seen.add((pid, cid))
            m = answers[pid]['candidates'][cid]
            if m['text'] != e['text']:
                raise ValueError('feedback differs from raw answer')
            links = [(target, kind) for source, target, kind in RELATIONS.get(pid, []) if source == cid]
            status = 'retained_rejection' if not m['keep'] else 'relationship_recorded' if links else 'owner_recheck'
            if (status == 'owner_recheck') != (cid in PENDING.get(pid, [])):
                raise ValueError('unaccounted feedback')
            for target, _ in links:
                if not answers[pid]['candidates'][target]['keep'] or not m['keep']:
                    raise ValueError('relationship must reference kept candidates')
            entries.append(dict(page=pid, candidate=cid, status=status, evidence=e['text'],
                                relationships=[dict(target=t, kind=k) for t, k in links]))
    expected = {(p, n) for p, ns in PENDING.items() for n in ns}
    expected |= {(p, n) for p, links in RELATIONS.items() for n, _, _ in links}
    if not expected.issubset(seen) or len(entries) != 18 or len(feedback) != 12:
        raise ValueError('feedback scope changed')
    return dict(protocol='marks-feedback-reconciliation-v1', answers_sha256=ANSWER_SHA, entries=entries,
                pending=PENDING, labels_bands_and_boxes='unchanged', detector_masks='unchanged',
                note='Explicit relationships are metadata, not merged boxes or concatenated text. '
                     'All 12 feedback pages remain excluded; missing labels are never no-mark negatives. '
                     'Unresolved text stays null in the frozen truth; no reading is inferred from a comment.')


def prepare(frozen_root, out):
    frozen_root, out = Path(frozen_root).resolve(), P.safe_output(Path(out))
    if out == frozen_root or out.is_relative_to(frozen_root) or frozen_root.is_relative_to(out):
        raise ValueError('review output overlaps freeze')
    if out.exists():
        raise FileExistsError('never overwrite a review or its answers: ' + str(out))
    frozen = verify_freeze(frozen_root)
    answers = P.load(frozen_root / 'answers.json')
    feedback = P.load(frozen_root / 'question-feedback.json')
    overlay = reconcile(answers, feedback)
    key = P.load(frozen_root / 'sheet-key.json')
    out.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=out.name + '.partial-', dir=out.parent))
    (stage / 'pages').mkdir()
    order = [pid for pid in key['order'] if pid in PENDING]
    data, initial, images = [], {}, {}
    for pid in order:
        src = SC.original_source(frozen_root / 'scan-provenance', pid)
        digest = C.sha(src)
        dest = stage / 'pages' / (pid + '.jpg')
        shutil.copyfile(src, dest)
        if C.sha(dest) != digest or C.sha(src) != digest:
            raise ValueError('source changed during copying: ' + pid)
        images[pid] = dict(sha256=digest, bytes=dest.stat().st_size,
                           view='original JPEG bytes; EXIF-upright display; no resampling')
        a = initial[pid] = copy.deepcopy(answers[pid])
        # No partial reading is silently promoted out of a question comment.
        # Show the verbatim entry as evidence beside a blank transcription field.
        for cid in PENDING[pid]:
            m = a['candidates'][cid]
            m.update(feedback=m['text'], text='', note='', reviewed=False)
        data.append(dict(page=pid, img=f'pages/{pid}.jpg', pending=PENDING[pid],
                         cands=[dict(box=c['box'], cls=c['cls'], texts=[], overlaps=c['overlaps_print'])
                                for c in key['pages'][pid]['candidates']]))
    review_key = dict(protocol='marks-feedback-sheet-v1', answers_sha256=ANSWER_SHA,
                      order=order, pages={pid: key['pages'][pid] for pid in order}, pending=PENDING,
                      frozen_root=str(frozen_root), images=images)
    S.write_sheet(stage, data, review_key, initial, storage_key='w46-marks-feedback-' + ANSWER_SHA[:12], recheck=True)
    (stage / 'reconciliation.json').write_bytes(P.encoded(overlay))
    # Retain the complete frozen owner answer set beside the bounded sheet. It
    # is the merge baseline; never use the seven-page export as a new core.
    shutil.copyfile(frozen_root / 'answers.json', stage / 'baseline-answers.json')
    result = dict(protocol='marks-feedback-prepared-v1', answers_sha256=ANSWER_SHA,
                  source_freeze_sha256=C.sha(frozen_root / 'freeze.json'), pages=len(order),
                  pending_marks=sum(map(len, PENDING.values())), relationship_entries=7,
                  relationship_groups=6, retained_rejections=2, excluded_pages=12,
                  minutes='30-45; may be split into sittings', out=str(out),
                  original_bytes=sum(v['bytes'] for v in images.values()),
                  next='Owner rechecks nine places on seven pages, then validate and fold the export '
                       'against this baseline. Preserve labels/bands and masks until explicitly settled.')
    files = {str(p.relative_to(stage)): C.sha(p) for p in sorted(stage.rglob('*')) if p.is_file()}
    (stage / 'manifest.json').write_bytes(P.encoded(dict(summary=result, files=files)))
    # Check inputs again before publishing; do not write anywhere under frozen_root.
    if verify_freeze(frozen_root) != frozen:
        raise ValueError('freeze changed during preparation')
    stage.rename(out)
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--frozen', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    print(json.dumps(prepare(a.frozen, a.out), indent=1))


if __name__ == '__main__':
    main()
