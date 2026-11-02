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


if __name__ == '__main__':
    unittest.main()
