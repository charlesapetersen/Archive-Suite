"""Tests for place_truth.py's drafting and place_score.py's scorers, on synthetic pages (no cache needed)."""
import copy
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import place_score as ps
import place_truth as pt


def page(lines=3, words=4, W=1000, H=1000):
    ws, ls = [], []
    for i in range(lines):
        y = 0.1 + 0.1 * i
        row = []
        for k in range(words):
            row.append({'text': f'w{i}{k}x', 'box': [0.1 + 0.2 * k, y, 0.15, 0.03], 'line': i, 'status': 'vision'})
        ws += row
        ls.append({'id': i, 'text': ' '.join(w['text'] for w in row), 'box': [0.1, y, 0.75, 0.03],
                   'baseline': [[0.1, y + 0.025], [0.85, y + 0.025]]})
    return {'page': 'pX', 'group': 'test', 'width': W, 'height': H, 'words': ws, 'lines': ls}


def shifted(p, dx=0.0, dy=0.0):
    q = copy.deepcopy(p)
    for w in q['words']:
        w['box'][0] += dx; w['box'][1] += dy
    for l in q['lines']:
        l['box'][0] += dx; l['box'][1] += dy
        l['baseline'] = [[x + dx, y + dy] for x, y in l['baseline']]
    return q


class Scorers(unittest.TestCase):
    def test_identity_is_perfect(self):
        t = page()
        r = ps.score_page(t, t)
        self.assertEqual(r['word']['f1@0.5'], 1.0)
        self.assertEqual(r['word']['f1@0.7'], 1.0)
        self.assertEqual(r['word']['mcer@0.5'], 0.0)
        self.assertAlmostEqual(r['baseline']['F'], 1.0)
        self.assertEqual(r['alignment']['accuracy'], 1.0)

    def test_small_shift_passes_0_5_not_0_7(self):
        t = page()
        h = shifted(t, dx=0.03)  # a fifth of a 0.15-wide word: IoU = 0.12/0.18 = 0.67
        r = ps.score_page(t, h)
        self.assertEqual(r['word']['f1@0.5'], 1.0)
        self.assertEqual(r['word']['f1@0.7'], 0.0)

    def test_baseline_offset_by_a_line_fails(self):
        t = page()
        near = ps.baseline_scores(t, shifted(t, dy=0.005))  # 5 px against a 100 px line pitch
        far = ps.baseline_scores(t, shifted(t, dy=0.05))   # half a line pitch
        self.assertGreater(near['F'], 0.95)
        self.assertLess(far['F'], 0.2)

    def test_missing_hypothesis_line_costs_recall_only(self):
        t = page()
        h = copy.deepcopy(t)
        h['lines'] = h['lines'][:2]
        r = ps.baseline_scores(t, h)
        self.assertAlmostEqual(r['P'], 1.0)
        self.assertAlmostEqual(r['R'], 2 / 3, places=2)

    def test_wrong_text_on_right_box_counts_in_mcer(self):
        t = page()
        h = copy.deepcopy(t)
        for w in h['words']:
            w['text'] = w['text'][:-1] + 'y'
        r = ps.word_scores(t, h)
        self.assertEqual(r['f1@0.5'], 1.0)
        self.assertAlmostEqual(r['mcer@0.5'], 0.25)

    def test_swapped_line_texts_fail_alignment(self):
        t = page()
        h = copy.deepcopy(t)
        h['lines'][0]['text'], h['lines'][1]['text'] = h['lines'][1]['text'], h['lines'][0]['text']
        self.assertAlmostEqual(ps.alignment_scores(t, h)['accuracy'], 1 / 3)

    def test_unscored_truth_words_are_counted_not_scored(self):
        t = page()
        t['words'][0]['status'] = 'missing'
        t['words'][0]['box'] = None
        r = ps.word_scores(t, t)
        self.assertEqual(r['truth_words'], 11)
        self.assertEqual(r['unscored_truth_words'], 1)


class Drafting(unittest.TestCase):
    VW = [['Dear', 0.1, 0.1, 0.1, 0.02], ['Sir,', 0.22, 0.1, 0.08, 0.02],
          ['I', 0.1, 0.15, 0.02, 0.02], ['am', 0.14, 0.15, 0.05, 0.02], ['gladto', 0.21, 0.15, 0.12, 0.02],
          ['hear', 0.1, 0.2, 0.08, 0.02]]

    def test_vision_lines_break_on_wrap(self):
        self.assertEqual(pt.vision_lines(self.VW), [0, 0, 1, 1, 1, 2])

    def test_draft_aligns_and_splits_and_breaks_lines(self):
        words, lines = pt.draft_owner('p', 'Dear Sir, I am glad to hear you', self.VW)
        st = [w['status'] for w in words]
        self.assertEqual(st, ['vision', 'vision', 'vision', 'vision', 'split', 'split', 'vision', 'missing'])
        glad, to = words[4]['box'], words[5]['box']
        self.assertAlmostEqual(glad[0], 0.21)
        self.assertAlmostEqual(glad[2] + to[2], 0.12, places=4)
        self.assertEqual([l['text'] for l in lines], ['Dear Sir,', 'I am glad to', 'hear you'])
        self.assertAlmostEqual(lines[0]['baseline'][0][1], 0.1 + pt.BASELINE_FRAC * 0.02, places=4)

    def test_a_much_longer_truth_stretch_stays_missing(self):
        vw = [['Dear', 0.1, 0.1, 0.1, 0.02], ['19', 0.3, 0.1, 0.03, 0.02], ['hear', 0.1, 0.2, 0.08, 0.02]]
        words, _ = pt.draft_owner('p', 'Dear 1909. Mr F. P. Keppel Secretary hear', vw)
        self.assertEqual([w['status'] for w in words][1:7], ['missing'] * 6)

    def test_illegible_is_never_boxed(self):
        words, _ = pt.draft_owner('p', '[illegible] Dear Sir,', self.VW[:2])
        self.assertEqual(words[0]['status'], 'illegible')
        self.assertIsNone(words[0]['box'])

    def test_a_line_given_only_word_boxes_takes_their_union(self):
        with tempfile.TemporaryDirectory() as d:
            store = Path(d)
            (store / 'xml').mkdir()
            page = {'page': 'p', 'group': 'owner-hand', 'image': '/nonexistent.jpg', 'width': 1000, 'height': 1000,
                    'words': [{'text': t, 'box': None, 'line': 0, 'status': 'missing'} for t in ('ab', 'cd')],
                    'lines': [], 'audit': {'verdict': 'fix'}}
            (store / 'p.json').write_text(json.dumps(page))
            spec = store / 'spec.json'
            spec.write_text(json.dumps({'lines': [{'text': 'ab cd', 'baseline': [[100, 200], [500, 200]],
                                                   'words': [[100, 150, 250, 210], [300, 140, 500, 205]]}]}))
            with mock.patch.object(pt, 'STORE', store), mock.patch.object(pt, 'Gray', lambda img: None):
                p = pt.apply_lines('p', spec, 'test')
        self.assertEqual([round(v, 5) for v in p['lines'][0]['box']], [0.1, 0.14, 0.4, 0.07])
        self.assertEqual([w['status'] for w in p['words']], ['drawn', 'drawn'])
        self.assertIsNone(p['audit'])


if __name__ == '__main__':
    unittest.main()
