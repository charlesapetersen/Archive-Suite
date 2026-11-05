#!/usr/bin/env python3
"""Prepare the bounded recheck of frozen marks export da388b05c388, then fold the owner's answers.

  python3 marks_feedback.py prepare --frozen FREEZE --out REVIEW
  python3 marks_feedback.py fold --frozen FREEZE --review REVIEW --out DERIVED

The fold writes a new derived 40-page record beside the freeze (and its own
report); re-running it verifies that record instead of rewriting it.

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


# ---------- the fold of the owner's recheck ----------

# The one export these dispositions were written for. A different export needs
# its own review of every place, not a silent reuse of this table.
RECHECK_SHA = 'dac79c80c2f6fceee7ebb319b8e0beac7d3a283b63f76c889c9f89cb8c8a210e'
# Each rechecked place, as the owner left it. Only 'owner_reviewed' is scored
# text; the rest keep the owner's entry and note verbatim but stay unscored.
PLACES = {
    ('Dean-7d1bce1dde28dfee', '2'): 'unread',
    ('Dean-d3a52a7e272b066a', '3'): 'unread',
    ('Dean-e6ecf7a0b3ed6e6b', '1'): 'unread',
    ('Dean-e6ecf7a0b3ed6e6b', '2'): 'incomplete',
    ('Herrnstein-39bea9fb30cda479', '2'): 'unread',
    ('Herrnstein-3f753f88969588ac', '1'): 'uncertain',  # alternative letters, not one reading
    ('Herrnstein-5d66cd10e6af25f0', '1'): 'unread',
    ('RG165-15a0647456422fb9', '1'): 'owner_reviewed',
    ('RG165-15a0647456422fb9', '3'): 'reading_in_note',  # not moved into the text field for him
}
# Pages whose geometry the recheck did not settle. Two boxes on one mark, or one
# box over several, would mis-score a detector, and choosing or merging boxes
# is not ours to do, so these stay out of detector truth with the reason named.
GEOMETRY = {
    'Dean-d3a52a7e272b066a': 'grouped_subannotations_not_drawn',
    'Herrnstein-5d66cd10e6af25f0': 'incomplete_box_on_sideways_page',
    'RG165-15a0647456422fb9': 'one_box_contains_others_duplicate_text',
}
GEOMETRY.update({pid: 'relationship_boxes_unmerged' for pid in RELATIONS})
PLACE_FIELDS = {'keep', 'cls', 'overlaps', 'text', 'feedback', 'note', 'reviewed'}


def verify_review(review):
    """The prepared artifact is unchanged, and its baseline is the frozen answer set."""
    manifest = P.load(review / 'manifest.json')
    for name, digest in manifest['files'].items():
        if C.sha(P.relative(review, name)) != digest:
            raise ValueError('review artifact changed: ' + name)
    if C.sha(review / 'baseline-answers.json') != ANSWER_SHA or manifest['summary']['answers_sha256'] != ANSWER_SHA:
        raise ValueError('review baseline is not export da388b05c388')
    return manifest


def check_recheck(export, baseline):
    """Only the nine places may change, and only their text, note and reviewed flag."""
    if export.get('protocol') != 'marks-feedback-answers-v1' or export.get('answers_sha256') != ANSWER_SHA:
        raise ValueError('not a recheck of export da388b05c388')
    if set(export.get('pages') or {}) != set(PENDING):
        raise ValueError('recheck must cover exactly the seven pending pages')
    if set(PLACES) != {(p, n) for p, ns in PENDING.items() for n in ns}:
        raise ValueError('dispositions do not match the pending places')
    for pid, page in export['pages'].items():
        base = baseline[pid]
        if page.get('band') != base['band'] or page.get('note', '') != base.get('note', ''):
            raise ValueError(f'{pid}: locked band or page note changed')
        if page.get('added') != base['added']:
            raise ValueError(f'{pid}: new boxes need their own fold rule; none were expected')
        if set(page.get('candidates') or {}) != set(base['candidates']):
            raise ValueError(f'{pid}: candidate IDs changed')
        for cid, m in page['candidates'].items():
            old = base['candidates'][cid]
            if (pid, cid) not in PLACES:
                if m != old:
                    raise ValueError(f'{pid}/{cid}: a locked answer changed')
                continue
            if set(m) != PLACE_FIELDS or m['reviewed'] is not True:
                raise ValueError(f'{pid}/{cid}: place not marked reviewed or has unexpected fields')
            if any(m[f] != old[f] for f in ('keep', 'cls', 'overlaps')) or m['feedback'] != old['text']:
                raise ValueError(f'{pid}/{cid}: locked label or original feedback changed')
            if not isinstance(m['text'], str) or not isinstance(m['note'], str):
                raise ValueError(f'{pid}/{cid}: text and note must be strings')
            text, note, status = m['text'].strip(), m['note'].strip(), PLACES[(pid, cid)]
            ok = dict(unread=not text, reading_in_note=not text and bool(note),
                      incomplete=bool(text) and bool(note), uncertain=bool(text),
                      owner_reviewed=bool(text) and not note and not C.COMMENT.search(m['text']))[status]
            if not ok:
                raise ValueError(f'{pid}/{cid}: answer does not match its disposition {status}')


def fold_recheck(truth, export):
    """A new 40-page record: the frozen marks with the recheck's statuses, relationships and masks."""
    out = copy.deepcopy(truth)
    out['protocol'] = 'marks-core-reconciled-v1'
    for pid, page in out['pages'].items():
        page['relationships'] = [dict(candidate=s, target=t, kind=k) for s, t, k in RELATIONS.get(pid, [])]
        if page['detector_evaluable']:
            page['resolution'] = None
            continue
        for m in page['marks']:
            place = PLACES.get((pid, m['candidate']))
            if place is None:
                continue
            a = export['pages'][pid]['candidates'][m['candidate']]
            label_only = m['cls'] in S.NOT_TRANSCRIBED
            text = a['text'] if place == 'owner_reviewed' and not label_only else None
            m.update(text=text, owner_entry=a['text'], note=a['note'], original_feedback=a['feedback'],
                     transcription_evaluable=bool(text),
                     transcription_status='label_only' if label_only else place)
        reason = GEOMETRY.get(pid)
        page.update(detector_evaluable=reason is None, exclusion=reason,
                    resolution='owner_recheck' if pid in PENDING else
                               'relationships_recorded' if pid in RELATIONS else 'rejection_retained')
    return out


def fold_summary(derived, receipts, root):
    pages = derived['pages']
    groups = {}
    for group in ('A-core', 'B-core'):
        rows = [p for p in pages.values() if p['core_support'] == group]
        groups[group] = dict(pages=len(rows), detector_evaluable=sum(p['detector_evaluable'] for p in rows),
                             accepted_boxes=sum(len(p['marks']) for p in rows),
                             scored_texts=sum(m['transcription_evaluable'] for p in rows for m in p['marks']))
    places = {}
    for pid, cid in sorted(PLACES):
        m = next(m for m in pages[pid]['marks'] if m['candidate'] == cid)
        places.setdefault(m['transcription_status'], []).append(f'{pid}/{cid}')
    return dict(protocol='marks-set-reconciled-v1', reconciled_root=str(root), receipts=receipts,
                owner_pages=len(pages), groups=groups,
                detector_pages=sorted(p for p, v in pages.items() if v['detector_evaluable']),
                excluded=dict(sorted((p, v['exclusion']) for p, v in pages.items() if not v['detector_evaluable'])),
                unmasked=sorted(p for p, v in pages.items() if v['resolution'] and v['detector_evaluable']),
                relationships=sum(len(v['relationships']) for v in pages.values()),
                places=places)


def report_fold(out, reports):
    """The derived record's own report; the freeze report stays a description of the freeze."""
    reports.mkdir(parents=True, exist_ok=True)
    (reports / 'marks-set-reconciled.json').write_bytes(P.encoded(out))
    lines = ['# Marks set: the owner core after the question-feedback recheck', '',
             f"{out['owner_pages']} pages; {len(out['detector_pages'])} are detector truth, "
             f"{len(out['excluded'])} stay excluded. The recheck returned {len(out['unmasked'])} pages to "
             'detector truth: ' + ', '.join(out['unmasked']) + '.', '',
             '| Core group | Pages | Detector-eligible pages | Accepted rough boxes | Scored texts |',
             '|---|---:|---:|---:|---:|']
    for group, g in sorted(out['groups'].items()):
        lines.append(f"| {group} | {g['pages']} | {g['detector_evaluable']} | {g['accepted_boxes']} "
                     f"| {g['scored_texts']} |")
    lines += ['', '## Still excluded from detector truth', '',
              'These pages have no label file in the derived `core/`; that is never a no-mark negative.', '']
    lines += [f"- {pid}: {reason.replace('_', ' ')}" for pid, reason in sorted(out['excluded'].items())]
    lines += ['', '## The nine rechecked places', '',
              "Only an owner reading with no hedge is scored. The owner's entries and notes are kept verbatim "
              'in the derived record outside Git.', '']
    lines += [f"- {status.replace('_', ' ')} ({len(ids)}): " + ', '.join(ids) for status, ids in sorted(out['places'].items())]
    lines += ['', f"{out['relationships']} explicit duplicate/connected/part relationships are metadata on their "
              'pages; no box is merged or dropped and no reading is concatenated.', '',
              '## Measurement card', '',
              "- **Truth.** The da388b05c388 freeze (owner keep/reject, class, touches-print and bands on 40 pages; "
              'rough draft boxes plus one owner box), with the owner\'s 2026-11-04 recheck of nine places on '
              'original JPEG bytes. No label, band or box changed; no reading was inferred from a comment.',
              "- **Selection.** Unchanged: the frozen two-phase selection's 40-page owner core, 16 A-core and "
              '24 B-core, reported apart. No population weights.',
              "- **Comparison.** A truth record, not a model ranking. Detector and transcription scoring read this "
              "record's `core/` labels and statuses, not the freeze's.",
              '- **Noise.** No accuracy estimate. Rough draft boxes are not tight geometry.',
              '- **Scope.** The excluded pages need box work (drawn sub-boxes, a re-run of the sideways page, '
              'a choice between duplicate or containing boxes) before they can be detector truth.', '',
              '## Provenance', '', f"Derived record: `{out['reconciled_root']}`.",
              'Its receipts bind the freeze, the review artifact and the raw recheck export, kept byte for byte. '
              'The freeze is never rewritten.', '']
    (reports / 'marks-set-reconciled.md').write_text('\n'.join(lines))


def fold(frozen_root, review, out, reports):
    frozen_root, review, out = (Path(p).resolve() for p in (frozen_root, review, out))
    if out.parent != frozen_root.parent or out == frozen_root:
        raise ValueError('the derived record goes in its own folder beside the freeze')
    frozen = verify_freeze(frozen_root)
    manifest = verify_review(review)
    raw = review / 'marks-feedback-answers.json'
    receipts = dict(freeze=C.sha(frozen_root / 'freeze.json'), answers=ANSWER_SHA,
                    review_manifest=C.sha(review / 'manifest.json'), recheck=C.sha(raw))
    if receipts['recheck'] != RECHECK_SHA:
        raise ValueError('this fold is written for recheck export ' + RECHECK_SHA[:12])
    baseline = P.load(frozen_root / 'answers.json')
    if P.load(review / 'reconciliation.json') != P.loads(P.encoded(
            reconcile(baseline, P.load(frozen_root / 'question-feedback.json'))).decode()):
        raise ValueError('reconciliation no longer matches the freeze')
    export = P.load(raw)
    check_recheck(export, baseline)
    if out.exists():
        # Repeated generation: verify what is there, never rewrite it.
        existing = P.load(out / 'manifest.json')
        if existing['summary']['receipts'] != receipts:
            raise ValueError('refusing to change a derived record built from different inputs')
        for name, digest in existing['files'].items():
            if C.sha(P.relative(out, name)) != digest:
                raise ValueError('derived file changed: ' + name)
        result = existing['summary']
    else:
        derived = fold_recheck(P.load(frozen_root / 'owner-reviewed.json'), export)
        stage = Path(tempfile.mkdtemp(prefix=out.name + '.partial-', dir=out.parent))
        shutil.copyfile(raw, stage / 'recheck-answers.json')
        (stage / 'reconciled.json').write_bytes(P.encoded(derived))
        core = stage / 'core'
        core.mkdir()
        S.write_classes(core)
        for pid, p in derived['pages'].items():
            if p['detector_evaluable']:
                (core / (pid + '.txt')).write_text(''.join(S.yolo_line(m['cls'], m['box']) + '\n' for m in p['marks']))
        for name, digest in frozen['files'].items():
            # Pages the freeze already labelled keep identical label bytes.
            if name.startswith('core/') and name.endswith('.txt') and C.sha(core / name[5:]) != digest:
                raise ValueError('a frozen label changed: ' + name)
        result = fold_summary(derived, receipts, out)
        (core / 'manifest.json').write_bytes(P.encoded(dict(
            truth=True, pages=result['detector_pages'], excluded=result['excluded'],
            note='Excluded pages have no label file; never treat missing labels as no marks.')))
        files = {str(p.relative_to(stage)): C.sha(p) for p in sorted(stage.rglob('*')) if p.is_file()}
        (stage / 'manifest.json').write_bytes(P.encoded(dict(summary=result, files=files)))
        if verify_freeze(frozen_root) != frozen or C.sha(raw) != RECHECK_SHA or verify_review(review) != manifest:
            raise ValueError('inputs changed while folding; partial directory preserved')
        stage.rename(out)
    report_fold(result, Path(reports))
    C.report(frozen['summary'], Path(reports))
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='command', required=True)
    a = sub.add_parser('prepare')
    a.add_argument('--frozen', type=Path, required=True)
    a.add_argument('--out', type=Path, required=True)
    b = sub.add_parser('fold')
    b.add_argument('--frozen', type=Path, required=True)
    b.add_argument('--review', type=Path, required=True)
    b.add_argument('--out', type=Path, required=True)
    b.add_argument('--reports', type=Path, default=C.M.RESULTS)
    a = p.parse_args()
    if a.command == 'prepare':
        print(json.dumps(prepare(a.frozen, a.out), indent=1))
    else:
        print(json.dumps(fold(a.frozen, a.review, a.out, a.reports), indent=1))


if __name__ == '__main__':
    main()
