"""Synthetic owner answers only: uncertainty, identity and freeze integrity."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import marks_core as C
import marks_set as M
import marks_sheet as S


def inputs():
    selection = dict(rows=[dict(id='a', core=True, phase='A', core_support='A-core', stratum='A:one'),
                           dict(id='b', core=True, phase='B', core_support='B-core', stratum='B:few'),
                           dict(id='c', core=False, phase='A', stratum='A:one')])
    key = dict(pages={p: dict(drafted=['one', 'two'], candidates=[dict(box=[.1, .2, .6, .5])]) for p in ('a', 'b')})
    answers = {p: dict(band='few', note='', added=[], candidates={'1': dict(
        keep=True, cls='annotation', overlaps=False, text='invented fixture')}) for p in ('a', 'b')}
    return answers, key, selection


class Fold(unittest.TestCase):
    def setUp(self):
        self.a, self.k, self.s = inputs()

    def test_complete_kept_rejected_and_owner_added_boxes(self):
        self.a['a']['candidates']['1']['keep'] = False
        self.a['a']['added'] = [dict(box=[0, 0, .2, .3], cls='stamp', overlaps=True, text='synthetic')]
        out = C.fold(self.a, self.k, self.s)
        self.assertEqual(out['pages']['a']['rejected'], ['1'])
        self.assertEqual(out['pages']['a']['marks'][0]['origin'], 'owner')
        self.assertTrue(out['pages']['a']['detector_evaluable'])
        self.assertEqual(out['weighting']['use'], 'descriptive')
        self.assertFalse(out['weighting']['validated'])

    def test_comments_not_transcription_and_no_negative_label(self):
        raw = 'some words [NB: duplicate of number 2; cannot read the rest]'
        self.a['a']['candidates']['1']['text'] = raw
        before = copy.deepcopy(self.a)
        out = C.fold(self.a, self.k, self.s)
        page = out['pages']['a']
        self.assertFalse(page['detector_evaluable'])
        self.assertIsNone(page['marks'][0]['text'])
        self.assertEqual(page['marks'][0]['owner_entry'], raw)
        self.assertEqual(out['question_feedback'][0]['entries'][0]['text'], raw)
        self.assertEqual(self.a, before)

    def test_page_notes_and_comments_on_rejected_candidates_are_kept(self):
        self.a['a']['note'] = 'the fixture question is ambiguous'
        self.a['b']['candidates']['1'].update(keep=False, text='NB: cross out mark')
        out = C.fold(self.a, self.k, self.s)
        self.assertEqual(len(out['question_feedback']), 2)
        self.assertEqual(out['pages']['b']['marks'], [])
        self.assertFalse(out['pages']['b']['detector_evaluable'])

    def test_signatures_never_become_transcription(self):
        self.a['a']['candidates']['1']['cls'] = 'signature_initials'
        m = C.fold(self.a, self.k, self.s)['pages']['a']['marks'][0]
        self.assertIsNone(m['text'])
        self.assertFalse(m['transcription_evaluable'])

    def test_incomplete_and_extra_answers_refused(self):
        for change in ('missing', 'extra', 'candidate', 'band', 'keep', 'overlaps', 'class'):
            with self.subTest(change=change):
                a = copy.deepcopy(self.a)
                if change == 'missing': del a['b']
                elif change == 'extra': a['z'] = a['a']
                elif change == 'candidate': a['a']['candidates']['2'] = a['a']['candidates']['1']
                elif change == 'band': a['a']['band'] = None
                elif change == 'keep': a['a']['candidates']['1']['keep'] = 1
                elif change == 'overlaps': a['a']['candidates']['1']['overlaps'] = None
                else: a['a']['candidates']['1']['cls'] = 'unknown'
                with self.assertRaises(ValueError): C.fold(a, self.k, self.s)

    def test_nonfinite_inverted_and_out_of_bounds_boxes_refused(self):
        for box in ([0, 0, float('nan'), 1], [0, 0, 2, 1], [.8, 0, .2, 1], [True, 0, 1, 1]):
            self.k['pages']['a']['candidates'][0]['box'] = box
            with self.assertRaises(ValueError): C.fold(self.a, self.k, self.s)

    def test_plain_export_cannot_bypass_feedback_masks(self):
        self.a['a']['candidates']['1']['text'] = 'NB: not legible'
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ValueError): S.export_yolo(self.a, self.k, Path(d) / 'labels')
            self.assertFalse((Path(d) / 'labels').exists())


class Freeze(unittest.TestCase):
    def test_roundtrip_masks_idempotence_and_tamper_refusal(self):
        a, k, s = inputs()
        a['a']['candidates']['1']['text'] = 'NB: this question needs repair'
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            for name, obj in [('answers', a), ('key', k), ('selection', s)]:
                (root / (name + '.json')).write_text(json.dumps(obj))
            scan = root / 'scan'; scan.mkdir()
            for name in ('inventory.json', 'scan.json', 'freeze.json'):
                (scan / name).write_text('{}')
            for p in ('a', 'b', 'c'): (root / (p + '.jpg')).write_bytes(b'synthetic image bytes ' + p.encode())
            out, reports = root / 'freeze', root / 'reports'
            with mock.patch.object(M, 'image_path', side_effect=lambda p: root / (p + '.jpg')), \
                 mock.patch.object(M, 'SCAN', scan), \
                 mock.patch.object(S, 'default_routes', return_value={'one': lambda p: {}, 'two': lambda p: {}}), \
                 mock.patch.object(S, 'export_yolo_drafts', return_value={'pages': 1}):
                args = (root/'answers.json', root/'key.json', root/'selection.json', out, reports)
                result = C.freeze(*args)
                self.assertEqual(result['owner_pages'], 2)
                self.assertFalse((out/'core/a.txt').exists())
                self.assertTrue((out/'core/b.txt').exists())
                self.assertEqual((out/'answers.json').read_bytes(), (root/'answers.json').read_bytes())
                self.assertEqual(C.freeze(*args), result)
                (out/'images/b.jpg').write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError, 'frozen file changed'): C.freeze(*args)


if __name__ == '__main__':
    unittest.main()
