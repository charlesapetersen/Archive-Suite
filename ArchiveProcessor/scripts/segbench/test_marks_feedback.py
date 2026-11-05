"""Synthetic feedback/receipts: no document images or text read by a model."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import marks_feedback as F
import marks_core as C
import marks_pilot as P
from test_marks_core import inputs


def feedback_fixture():
    answers, feedback = {}, []
    all_ids = set(F.RELATIONS) | set(F.PENDING) | {'rejected-only'}
    for pid in sorted(all_ids):
        cs = {str(n): dict(keep=True, cls='annotation', overlaps=False, text='fixture') for n in range(1, 14)}
        answers[pid] = dict(band='few', candidates=cs, note='', added=[])
        ids = [n for n, _, _ in F.RELATIONS.get(pid, [])] + F.PENDING.get(pid, [])
        if pid in ('rejected-only', 'Dean-b31c4f7387db3844'):
            cs['3']['keep'] = False
            ids.append('3')
        feedback.append(dict(page=pid, entries=[dict(field='text', candidate=n, text='fixture') for n in ids]))
    return answers, feedback


class Reconcile(unittest.TestCase):
    def test_all_feedback_accounted_without_changing_answers(self):
        answers, feedback = feedback_fixture()
        before = copy.deepcopy(answers)
        out = F.reconcile(answers, feedback)
        self.assertEqual(answers, before)
        self.assertEqual(len(out['entries']), 18)
        counts = {s: sum(e['status'] == s for e in out['entries'])
                  for s in ('owner_recheck', 'relationship_recorded', 'retained_rejection')}
        self.assertEqual(counts, dict(owner_recheck=9, relationship_recorded=7, retained_rejection=2))
        e = next(e for e in out['entries'] if e['page'] == 'Herrnstein-04d25d2e123a33d0')
        self.assertEqual(e['relationships'], [dict(target='6', kind='duplicate_text')])
        self.assertEqual(out['detector_masks'], 'unchanged')
        self.assertEqual(len(out['pending']), 7)

    def test_unknown_and_changed_feedback_refused(self):
        a, f = feedback_fixture()
        f[0]['entries'][0]['text'] = 'different'
        with self.assertRaisesRegex(ValueError, 'differs'): F.reconcile(a, f)
        a, f = feedback_fixture()
        f[0]['entries'].append(dict(field='text', candidate='13', text='fixture'))
        with self.assertRaisesRegex(ValueError, 'unaccounted'): F.reconcile(a, f)

    def test_source_freeze_identity_and_tampering(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            a, k, s = inputs()
            for name, obj in [('answers', a), ('sheet-key', k), ('selection', s)]:
                (root / (name + '.json')).write_bytes(P.encoded(obj))
            receipts = dict(answers=C.sha(root/'answers.json'), sheet_key=C.sha(root/'sheet-key.json'),
                            selection=C.sha(root/'selection.json'))
            files = {p.name:C.sha(p) for p in root.iterdir()}
            (root/'freeze.json').write_bytes(P.encoded(dict(receipts=receipts, files=files)))
            with self.assertRaisesRegex(ValueError, 'only for export'): F.verify_freeze(root)
            with mock.patch.object(F, 'ANSWER_SHA', receipts['answers']):
                F.verify_freeze(root)
                (root/'answers.json').write_text('{}')
                with self.assertRaisesRegex(ValueError, 'frozen file changed'): F.verify_freeze(root)


class Prepare(unittest.TestCase):
    def test_targeted_sheet_preserves_baseline_and_refuses_overwrite(self):
        answers, feedback = feedback_fixture()
        key = dict(order=sorted(answers), pages={pid:dict(candidates=[dict(
            box=[.1,.1,.3,.2], cls='annotation', overlaps_print=False, texts=[]) for _ in range(13)])
            for pid in answers})
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            frozen = root/'frozen'; frozen.mkdir()
            for name, obj in [('answers', answers), ('question-feedback', feedback), ('sheet-key', key)]:
                (frozen/(name+'.json')).write_bytes(P.encoded(obj))
            (frozen/'freeze.json').write_text('{}')
            source = root/'original.jpg'; source.write_bytes(b'invented native JPEG fixture')
            before = {p.name:C.sha(p) for p in frozen.iterdir()}
            out = root/'review'
            with mock.patch.object(F, 'verify_freeze', return_value={}), \
                 mock.patch.object(F.SC, 'original_source', return_value=source):
                result = F.prepare(frozen, out)
                with self.assertRaises(FileExistsError): F.prepare(frozen, out)
            self.assertEqual(result['pages'], 7)
            self.assertEqual(result['pending_marks'], 9)
            self.assertEqual({p.name:C.sha(p) for p in frozen.iterdir()}, before)
            self.assertEqual((out/'baseline-answers.json').read_bytes(), (frozen/'answers.json').read_bytes())
            built_key = P.load(out/'key.json')
            self.assertEqual(set(built_key['pages']), set(F.PENDING))
            for pid in F.PENDING:
                self.assertEqual(built_key['pages'][pid], key['pages'][pid])
                self.assertEqual((out/'pages'/f'{pid}.jpg').read_bytes(), source.read_bytes())
            manifest = P.load(out/'manifest.json')
            for name, digest in manifest['files'].items(): self.assertEqual(C.sha(out/name), digest)
            html = (out/'index.html').read_text()
            initial = json.loads(html.split('const INITIAL=')[1].split(',RECHECK=')[0])
            for pid, page in initial.items():
                self.assertEqual(page['band'], answers[pid]['band'])
                for cid, mark in page['candidates'].items():
                    old = answers[pid]['candidates'][cid]
                    for field in ('keep','cls','overlaps'): self.assertEqual(mark[field], old[field])
                    if cid in F.PENDING[pid]:
                        self.assertEqual(mark['text'], '')
                        self.assertEqual(mark['feedback'], old['text'])
                        self.assertFalse(mark['reviewed'])
                    else: self.assertEqual(mark, old)


ANSWER_FOR = dict(unread=('', 'cannot read'), reading_in_note=('', 'a reading'), incomplete=('part', 'rest unread'),
                  uncertain=('x or y', ''), owner_reviewed=('a clean reading', ''))


def recheck_fixture():
    answers, feedback = feedback_fixture()
    export = dict(protocol='marks-feedback-answers-v1', answers_sha256=F.ANSWER_SHA, pages={})
    for pid, ids in F.PENDING.items():
        page = export['pages'][pid] = copy.deepcopy(answers[pid])
        for cid in ids:
            text, note = ANSWER_FOR[F.PLACES[(pid, cid)]]
            page['candidates'][cid].update(feedback=answers[pid]['candidates'][cid]['text'], text=text, note=note,
                                           reviewed=True)
    return answers, feedback, export


def truth_fixture(answers):
    """The freeze's shape: feedback pages masked, comment-bearing text null."""
    feedback_pages = set(F.RELATIONS) | set(F.PENDING) | {'rejected-only'}
    pages = {}
    for i, (pid, a) in enumerate(sorted(answers.items())):
        marks = [dict(candidate=cid, box=[.1, .1, .2, .2], cls='annotation', overlaps=False, text='fixture',
                      owner_entry='fixture', note='', origin='draft', transcription_evaluable=True,
                      transcription_status='owner_reviewed', localization='rough_draft_box')
                 for cid, m in a['candidates'].items() if m['keep']]
        pages[pid] = dict(band='few', core_support='A-core' if i % 2 else 'B-core', marks=marks,
                          rejected=[c for c, m in a['candidates'].items() if not m['keep']],
                          detector_evaluable=pid not in feedback_pages,
                          exclusion='unresolved_owner_question_feedback' if pid in feedback_pages else None)
    pages['clean-page'] = dict(band='none', core_support='A-core', marks=[], rejected=[], detector_evaluable=True,
                               exclusion=None)
    return dict(protocol='marks-core-reviewed-v1', truth=True, pages=pages, question_feedback=[])


class Recheck(unittest.TestCase):
    def test_valid_export_accepted(self):
        answers, _, export = recheck_fixture()
        F.check_recheck(export, answers)

    def test_changes_outside_the_nine_places_refused(self):
        cases = [
            (lambda e: e['pages']['Dean-7d1bce1dde28dfee']['candidates']['1'].update(text='edited'), 'locked answer'),
            (lambda e: e['pages']['Dean-7d1bce1dde28dfee'].update(band='none'), 'locked band'),
            (lambda e: e['pages']['Dean-7d1bce1dde28dfee']['candidates']['2'].update(reviewed=False), 'reviewed'),
            (lambda e: e['pages']['Dean-7d1bce1dde28dfee']['candidates']['2'].update(cls='stamp'), 'locked label'),
            (lambda e: e['pages']['Dean-7d1bce1dde28dfee']['added'].append({}), 'new boxes'),
            (lambda e: e['pages']['Dean-7d1bce1dde28dfee']['candidates']['2'].update(text='guess'), 'disposition'),
            (lambda e: e['pages']['RG165-15a0647456422fb9']['candidates']['1'].update(note='unsure'), 'disposition'),
            (lambda e: e['pages'].pop('RG165-15a0647456422fb9'), 'seven pending'),
            (lambda e: e.update(answers_sha256='0' * 64), 'not a recheck'),
        ]
        for change, message in cases:
            answers, _, export = recheck_fixture()
            change(export)
            with self.assertRaisesRegex(ValueError, message): F.check_recheck(export, answers)

    def test_fold_keeps_geometry_masks_unsettled_pages_and_scores_only_clean_readings(self):
        answers, _, export = recheck_fixture()
        truth = truth_fixture(answers)
        before = copy.deepcopy(truth)
        out = F.fold_recheck(truth, export)
        self.assertEqual(truth, before)
        for pid, page in out['pages'].items():
            old = before['pages'][pid]
            self.assertEqual([(m['candidate'], m['box'], m['cls']) for m in page['marks']],
                             [(m['candidate'], m['box'], m['cls']) for m in old['marks']])
            self.assertEqual(page['band'], old['band'])
            if pid in F.GEOMETRY:
                self.assertFalse(page['detector_evaluable'])
                self.assertEqual(page['exclusion'], F.GEOMETRY[pid])
            else:
                self.assertTrue(page['detector_evaluable'], pid)
        scored = {(pid, m['candidate']) for pid, p in out['pages'].items() for m in p['marks']
                  if m['transcription_evaluable'] and (pid, m['candidate']) in F.PLACES}
        self.assertEqual(scored, {k for k, v in F.PLACES.items() if v == 'owner_reviewed'})
        m = next(m for m in out['pages']['RG165-15a0647456422fb9']['marks'] if m['candidate'] == '3')
        self.assertIsNone(m['text'])
        self.assertEqual((m['note'], m['transcription_status']), ('a reading', 'reading_in_note'))
        self.assertEqual(out['pages']['rejected-only']['resolution'], 'rejection_retained')
        self.assertEqual(len(out['pages']['Dean-0a07517aa636ba99']['relationships']), 3)

    def test_label_only_class_never_scored(self):
        answers, _, export = recheck_fixture()
        truth = truth_fixture(answers)
        mark = next(m for m in truth['pages']['RG165-15a0647456422fb9']['marks'] if m['candidate'] == '1')
        mark['cls'] = 'signature_initials'
        out = F.fold_recheck(truth, export)
        mark = next(m for m in out['pages']['RG165-15a0647456422fb9']['marks'] if m['candidate'] == '1')
        self.assertEqual((mark['text'], mark['transcription_status']), (None, 'label_only'))


class Fold(unittest.TestCase):
    def build(self, root):
        """A synthetic freeze and review artifact, with the module bound to their hashes."""
        answers, feedback, export = recheck_fixture()
        truth = truth_fixture(answers)
        frozen = root / 'store' / 'frozen'; (frozen / 'core').mkdir(parents=True)
        for name, obj in [('answers', answers), ('question-feedback', feedback), ('owner-reviewed', truth)]:
            (frozen / (name + '.json')).write_bytes(P.encoded(obj))
        files = {}
        for pid, p in truth['pages'].items():
            if p['detector_evaluable']:
                f = frozen / 'core' / (pid + '.txt')
                f.write_text(''.join(F.S.yolo_line(m['cls'], m['box']) + '\n' for m in p['marks']))
                files['core/' + f.name] = C.sha(f)
        (frozen / 'freeze.json').write_bytes(P.encoded(dict(files=files, summary=dict(
            owner_pages=0, accepted_boxes=0, added_boxes=0, rejected_candidates=0, feedback_entries=0,
            feedback_pages=[], transcription_excluded_feedback=0, groups={}, scope='', frozen_root=str(frozen)))))
        review = root / 'review'; review.mkdir()
        (review / 'baseline-answers.json').write_bytes(P.encoded(answers))
        sha = C.sha(review / 'baseline-answers.json')
        mock.patch.object(F, 'ANSWER_SHA', sha).start()
        mock.patch.object(F, 'verify_freeze', side_effect=lambda r: P.load(r / 'freeze.json')).start()
        self.addCleanup(mock.patch.stopall)
        (review / 'reconciliation.json').write_bytes(P.encoded(F.reconcile(answers, feedback)))
        rfiles = {n: C.sha(review / n) for n in ('baseline-answers.json', 'reconciliation.json')}
        (review / 'manifest.json').write_bytes(P.encoded(dict(files=rfiles, summary=dict(answers_sha256=sha))))
        export['answers_sha256'] = sha
        (review / 'marks-feedback-answers.json').write_bytes(P.encoded(export))
        mock.patch.object(F, 'RECHECK_SHA', C.sha(review / 'marks-feedback-answers.json')).start()
        return frozen, review

    def test_derived_record_is_new_verified_on_repeat_and_freeze_untouched(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            frozen, review = self.build(root)
            before = {p: C.sha(p) for p in frozen.rglob('*') if p.is_file()}
            out, reports = root / 'store' / 'derived', root / 'reports'
            with self.assertRaisesRegex(ValueError, 'beside the freeze'):
                F.fold(frozen, review, root / 'elsewhere', reports)
            first = F.fold(frozen, review, out, reports)
            freeze_md = (reports / 'marks-set-freeze.md').read_text()
            derived_md = (reports / 'marks-set-reconciled.md').read_text()
            listing = {p: C.sha(p) for p in out.rglob('*') if p.is_file()}
            self.assertEqual(F.fold(frozen, review, out, reports), first)
            self.assertEqual({p: C.sha(p) for p in out.rglob('*') if p.is_file()}, listing)
            self.assertEqual((reports / 'marks-set-freeze.md').read_text(), freeze_md)
            self.assertEqual((reports / 'marks-set-reconciled.md').read_text(), derived_md)
            self.assertIn('Current status: reconciled in `marks-set-reconciled.md`', freeze_md)
            self.assertEqual({p: C.sha(p) for p in frozen.rglob('*') if p.is_file()}, before)
            self.assertEqual((out / 'recheck-answers.json').read_bytes(),
                             (review / 'marks-feedback-answers.json').read_bytes())
            labels = {p.stem for p in (out / 'core').glob('*.txt')} - {'classes'}
            self.assertEqual(labels, set(first['detector_pages']))
            self.assertTrue(labels.isdisjoint(F.GEOMETRY))
            self.assertIn('rejected-only', first['unmasked'])
            for p in (frozen / 'core').glob('*.txt'):
                self.assertEqual((out / 'core' / p.name).read_bytes(), p.read_bytes())
            (out / 'core' / 'clean-page.txt').write_text('tampered')
            with self.assertRaisesRegex(ValueError, 'derived file changed'): F.fold(frozen, review, out, reports)
            (review / 'reconciliation.json').write_text('{}')
            with self.assertRaisesRegex(ValueError, 'review artifact changed'): F.fold(frozen, review, out, reports)


class StatusPointer(unittest.TestCase):
    def test_freeze_report_says_unresolved_without_a_derived_record(self):
        self.assertIn('unresolved', C.status_line(Path(tempfile.gettempdir()) / 'no-such-reports-dir'))


if __name__ == '__main__':
    unittest.main()
