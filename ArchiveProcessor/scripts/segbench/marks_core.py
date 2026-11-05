#!/usr/bin/env python3
"""Freeze the answered marks sheet without treating review comments as transcription.

  python3 marks_core.py freeze --answers FILE --out DIR

The raw answers, sheet key, selected pages, draft records and image bytes are
retained in DIR. Results committed to the repo contain counts and page IDs only.
Pages carrying question feedback are excluded from detector training/evaluation
until that feedback is resolved. Their explicit labels and bands remain intact.
No model, network, corpus write or population estimate.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import tempfile

import marks_set as M
import marks_sheet as S

COMMENT = re.compile(r'\bNB\b|\bduplicat\w*|bounding box|can[’\x27]t|cannot|'
                     r're.run|too difficult|emphasis marks|cross out mark|'
                     r'same annotation|sub.annotations|connected to number|part of number', re.I)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def box_ok(box):
    return (isinstance(box, list) and len(box) == 4
            and all(type(x) in (int, float) and math.isfinite(x) and 0 <= x <= 1 for x in box)
            and box[0] < box[2] and box[1] < box[3])


def fold(answers, key, selection):
    rows = {r['id']: r for r in selection['rows']}
    core = {pid for pid, r in rows.items() if r.get('core')}
    if set(answers) != core or set(key['pages']) != core:
        raise ValueError('answer IDs, sheet key and selected owner core must match exactly')
    pages, notes = {}, []
    for pid in sorted(core):
        a, k, r = answers[pid], key['pages'][pid], rows[pid]
        if not isinstance(a, dict) or not S.page_done(a, len(k['candidates'])):
            raise ValueError(f'{pid}: incomplete owner answers')
        if set(a['candidates']) != {str(i) for i in range(1, len(k['candidates']) + 1)}:
            raise ValueError(f'{pid}: unexpected/missing candidate IDs')
        if not isinstance(a.get('note', ''), str) or not isinstance(a.get('added'), list):
            raise ValueError(f'{pid}: invalid note or added marks')
        feedback = []
        if a.get('note', '').strip():
            feedback.append(dict(field='note', text=a['note']))
        marks, rejected = [], []
        entries = [(str(i), a['candidates'][str(i)], c['box'], 'draft')
                   for i, c in enumerate(k['candidates'], 1)]
        entries += [(f'+{i}', m, m['box'], 'owner') for i, m in enumerate(a['added'], 1)]
        for cid, m, box, origin in entries:
            if not box_ok(box) or not isinstance(m.get('text', ''), str) or not isinstance(m.get('note', ''), str):
                raise ValueError(f'{pid}/{cid}: invalid box or text')
            if origin == 'draft' and type(m.get('keep')) is not bool:
                raise ValueError(f'{pid}/{cid}: keep must be boolean')
            if m.get('note', '').strip():
                feedback.append(dict(field='mark_note', candidate=cid, text=m['note']))
            inline_comment = bool(COMMENT.search(m.get('text', '')))
            comment = inline_comment or bool(m.get('note', '').strip())
            if inline_comment:
                feedback.append(dict(field='text', candidate=cid, text=m['text']))
            if origin == 'draft' and not m['keep']:
                rejected.append(cid)
                continue
            if m.get('cls') not in M.CLASSES or type(m.get('overlaps')) is not bool:
                raise ValueError(f'{pid}/{cid}: kept mark needs a class and explicit touches-print answer')
            label_only = m['cls'] in S.NOT_TRANSCRIBED
            # Preserve the entry verbatim, but never feed question feedback or a
            # label-only class to a transcription scorer as if it were text.
            text = None if comment or label_only else m.get('text', '')
            marks.append(dict(candidate=cid, box=box, cls=m['cls'], overlaps=m['overlaps'],
                              text=text, owner_entry=m.get('text', ''), note=m.get('note', ''), origin=origin,
                              transcription_evaluable=bool(text),
                              transcription_status=('question_feedback' if comment else
                                  'label_only' if label_only else 'owner_reviewed' if text else 'unread'),
                              localization='rough_draft_box' if origin == 'draft' else 'owner_drawn_box'))
        if feedback:
            notes.append(dict(page=pid, entries=feedback))
        pages[pid] = dict(band=S.BAND_AMOUNT[a['band']], phase=r['phase'],
                          core_support=r['core_support'], stratum=r['stratum'],
                          drafted=k['drafted'], failed=k.get('failed', []),
                          detector_evaluable=not feedback,
                          exclusion='unresolved_owner_question_feedback' if feedback else None,
                          note=a.get('note', ''), marks=marks, rejected=rejected)
    return dict(protocol='marks-core-reviewed-v1', truth=True, pages=pages,
                question_feedback=notes, weighting=M.weighting(selection['rows']))


def summary(truth, receipts, root):
    pages = truth['pages']
    groups = {}
    for group in ('A-core', 'B-core'):
        rows = [p for p in pages.values() if p['core_support'] == group]
        groups[group] = dict(pages=len(rows), detector_evaluable=sum(p['detector_evaluable'] for p in rows),
                            bands=dict(Counter(p['band'] for p in rows)),
                            accepted_boxes=sum(len(p['marks']) for p in rows))
    return dict(protocol='marks-set-freeze-v1', frozen_root=str(root), receipts=receipts,
                owner_pages=len(pages), groups=groups,
                accepted_boxes=sum(len(p['marks']) for p in pages.values()),
                rejected_candidates=sum(len(p['rejected']) for p in pages.values()),
                added_boxes=sum(m['origin'] == 'owner' for p in pages.values() for m in p['marks']),
                feedback_pages=[pid for pid, p in pages.items() if not p['detector_evaluable']],
                feedback_entries=sum(len(n['entries']) for n in truth['question_feedback']),
                transcription_excluded_feedback=sum(m['transcription_status'] == 'question_feedback'
                                                     for p in pages.values() for m in p['marks']),
                weighting=truth['weighting'],
                scope='Descriptive enriched core, A-core/B-core apart. No population weights or prevalence. '
                      'Feedback pages are not detector training/evaluation truth; rough draft boxes are not '
                      'independently measured geometry. Non-core agreement remains model drafts, never truth.')


def status_line(reports):
    """This freeze never changes; the current feedback status lives in the derived record's report."""
    derived = reports / 'marks-set-reconciled.json'
    if not derived.exists():
        return 'Current status: the feedback is unresolved; no reconciled record exists yet.'
    d = json.loads(derived.read_text())
    return (f"Current status: reconciled in `marks-set-reconciled.md` (recheck {d['receipts']['recheck'][:12]}): "
            f"{len(d['detector_pages'])} detector-eligible pages, {len(d['excluded'])} still excluded. "
            'Use that record, not this freeze, for detector or transcription truth.')


def report(out, reports):
    reports.mkdir(parents=True, exist_ok=True)
    (reports / 'marks-set-freeze.json').write_text(json.dumps(out, indent=1) + '\n')
    lines = ['# Marks set: the answered owner core', '',
             f"{out['owner_pages']} pages answered; {out['accepted_boxes']} accepted boxes "
             f"({out['added_boxes']} added), {out['rejected_candidates']} draft candidates rejected.", '',
             f"Question feedback: {out['feedback_entries']} entries on {len(out['feedback_pages'])} pages. "
             'These pages remain in the reviewed record but are excluded from detector labels until resolved. '
             f"{out['transcription_excluded_feedback']} kept entries containing feedback have no scored text. "
             'Raw owner entries are retained verbatim in the frozen record.', '',
             status_line(reports), '',
             '| Core group | Answered pages | Detector-eligible pages | Accepted rough boxes |',
             '|---|---:|---:|---:|']
    for group, g in out['groups'].items():
        lines.append(f"| {group} | {g['pages']} | {g['detector_evaluable']} | {g['accepted_boxes']} |")
    lines += ['', 'Feedback pages: ' + ', '.join(out['feedback_pages']) + '.', '',
              '## Measurement card', '',
              '- **Truth.** Owner keep/reject, class, touches-print and handwriting bands on all 40 pages. '
              'Two model families proposed the rough boxes; the owner added missed boxes. Question comments '
              'in transcription fields are preserved separately and never scored as document text. Explicit '
              'duplicate/grouping and legibility concerns remain unresolved, rather than being merged or guessed.',
              '- **Selection.** Frozen 150-page two-phase selection; 16 A-core and 24 B-core pages. '
              'The core is enriched and has no validated population inclusion weights. All results stay '
              'descriptive by core group; independent mixed prevalence is unchanged.',
              '- **Comparison.** This is a truth freeze, not a model ranking or OCR experiment. Non-core '
              'agreed drafts stay separate and are not evaluation truth. Existing owner bands are not re-labelled.',
              '- **Noise.** No accuracy estimate or confidence interval. Excluded pages are not zero-mark negatives. '
              'Keep uncertainty at field/page level; do not infer tight localization from rough boxes.',
              '- **Scope.** ' + out['scope'], '',
              '## Provenance', '', f"Frozen record: `{out['frozen_root']}`.",
              'Input SHA-256 receipts are in the adjacent JSON. Images and all owner text stay outside Git.', '']
    (reports / 'marks-set-freeze.md').write_text('\n'.join(lines))


def freeze(answers, key, selection, out, reports):
    answers, key, selection, out = map(Path, (answers, key, selection, out))
    receipts = {name: sha(p) for name, p in [('answers', answers), ('sheet_key', key), ('selection', selection)]}
    truth = fold(M.load(answers), M.load(key), M.load(selection))
    if out.exists():
        existing = M.load(out / 'freeze.json')
        if existing['receipts'] != receipts:
            raise ValueError('refusing to change an existing freeze with different inputs')
        for name, digest in existing['files'].items():
            if sha(out / name) != digest:
                raise ValueError('frozen file changed: ' + name)
        result = existing['summary']
    else:
        out.parent.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix=out.name + '.partial-', dir=out.parent))
        for src, name in [(answers, 'answers.json'), (key, 'sheet-key.json'), (selection, 'selection.json')]:
            shutil.copyfile(src, stage / name)
        for folder in ('images', 'core', 'draft-records'):
            (stage / folder).mkdir()
        provenance = stage / 'scan-provenance'
        provenance.mkdir()
        for name in ('inventory.json', 'scan.json', 'freeze.json'):
            shutil.copyfile(M.SCAN / name, provenance / name)
        for r in M.load(selection)['rows']:
            pid = r['id']
            image = M.image_path(pid)
            digest = sha(image)
            target = stage / 'images' / (pid + '.jpg')
            shutil.copyfile(image, target)
            if sha(image) != digest or sha(target) != digest:
                raise ValueError('image changed while copying: ' + pid)
            # Preserve both drafter records, including measured failures, for all
            # selected pages. This does not read or reinterpret their text.
            records = {name: reader(pid) for name, reader in S.default_routes().items()}
            (stage / 'draft-records' / (pid + '.json')).write_text(json.dumps(records, ensure_ascii=False) + '\n')
        (stage / 'owner-reviewed.json').write_text(json.dumps(truth, indent=1, ensure_ascii=False) + '\n')
        (stage / 'question-feedback.json').write_text(json.dumps(truth['question_feedback'], indent=1, ensure_ascii=False) + '\n')
        S.write_classes(stage / 'core')
        for pid, p in truth['pages'].items():
            if p['detector_evaluable']:
                (stage / 'core' / (pid + '.txt')).write_text(''.join(S.yolo_line(m['cls'], m['box']) + '\n' for m in p['marks']))
        (stage / 'core/manifest.json').write_text(json.dumps(dict(
            truth=True, pages=[pid for pid, p in truth['pages'].items() if p['detector_evaluable']],
            excluded=[pid for pid, p in truth['pages'].items() if not p['detector_evaluable']],
            note='Excluded pages have no label file; never treat missing labels as no marks.'), indent=1) + '\n')
        draft_counts = S.export_yolo_drafts(stage / 'drafts')
        result = summary(truth, receipts, out)
        result['image_provenance'] = ('Sheet images are EXIF-upright copies downscaled to at most 2400 pixels '
            'and saved at JPEG quality 95, not original JPEG bytes. Source inventory and original hashes '
            'are retained in scan-provenance; feedback about legibility is unresolved.')
        result['model_drafts'] = draft_counts
        files = {str(p.relative_to(stage)): sha(p) for p in sorted(stage.rglob('*')) if p.is_file()}
        (stage / 'freeze.json').write_text(json.dumps(dict(receipts=receipts, files=files, summary=result), indent=1) + '\n')
        if {name: sha(p) for name, p in [('answers', answers), ('sheet_key', key), ('selection', selection)]} != receipts:
            raise ValueError('input changed while freezing; partial directory preserved')
        stage.rename(out)
    report(result, Path(reports))
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=['freeze'])
    p.add_argument('--answers', type=Path, required=True)
    p.add_argument('--key', type=Path, default=M.CACHE / 'sheet/key.json')
    p.add_argument('--selection', type=Path, default=M.CACHE / 'selection.json')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--reports', type=Path, default=M.RESULTS)
    a = p.parse_args()
    print(json.dumps(freeze(a.answers, a.key, a.selection, a.out, a.reports), indent=1))


if __name__ == '__main__':
    main()
