#!/usr/bin/env python3
"""Synthetic checks for mixed_def.py (W46.fix-marks-set): no corpus, no model, no cache.

  /usr/local/bin/python3 test_mixed_def.py      (numpy needed for the regression check)
"""
import json
import os
import random
import tempfile
import unittest
from collections import Counter
from pathlib import Path

os.environ['MIXED_DEF_CACHE'] = tempfile.mkdtemp(prefix='mixed-def-test-')
import mixed_def as M   # noqa: E402


def lab(regression='typewritten', sorter='other', atrium='TEXT_T', qwen='typewritten'):
    return {'regression': regression, 'sorter': sorter, 'atrium': atrium, 'qwen': qwen}


class Classify(unittest.TestCase):
    def test_agreed_typed_page_is_clean(self):
        self.assertEqual(M.classify(lab())[0], 'clean')

    def test_qwen_mixed_against_atrium_typed_is_a_disagreement(self):
        kind, pattern = M.classify(lab(qwen='mixed'))
        self.assertEqual(kind, 'disagree')
        self.assertIn('qwen:M', pattern)
        self.assertIn('atrium:C', pattern)

    def test_all_mixed_needs_both_mixed_classes(self):
        self.assertEqual(M.classify(lab(regression='handwritten', sorter='other', atrium='TEXT', qwen='mixed'))[0], 'mixed')
        # Qwen mixed, ATRIUM a photograph (abstains): consistent, but not all-mixed
        self.assertEqual(M.classify(lab(regression='handwritten', atrium='PHOTO', qwen='mixed'))[0], 'open')

    def test_photograph_and_drawing_abstain(self):
        self.assertIsNone(M.allows('atrium', 'PHOTO'))
        self.assertIsNone(M.allows('atrium', 'DRAW_L'))
        self.assertNotIn('atrium', M.classify(lab(atrium='DRAW'))[1])

    def test_a_handwritten_page(self):
        self.assertEqual(M.classify(lab(regression='handwritten', sorter='handwriting', atrium='TEXT_HW',
                                        qwen='handwritten'))[0], 'hand')

    def test_failed_qwen_reply_abstains(self):
        self.assertEqual(M.classify(lab(qwen=''))[0], 'clean')

    def test_regression_handwritten_is_compatible_with_mixed(self):
        # a typed letter with a postscript: the regression's handwritten and Qwen's mixed agree
        self.assertNotEqual(M.classify(lab(regression='handwritten', atrium='TEXT', qwen='mixed'))[0], 'disagree')
        self.assertEqual(M.classify(lab(regression='handwritten'))[0], 'disagree')

    def test_every_kind_is_one_of_the_sets(self):
        vals = {'regression': ('typewritten', 'printed', 'handwritten', ''), 'sorter': ('other', 'photograph', 'handwriting', 'newspaper'),
                'atrium': M.ATRIUM_CLASSES + ('',), 'qwen': ('typewritten', 'printed', 'mixed', 'handwritten', '')}
        rng = random.Random(1)
        for _ in range(500):
            k, _ = M.classify({x: rng.choice(v) for x, v in vals.items()})
            self.assertIn(k, M.KIND_SETS)


class Stratified(unittest.TestCase):
    def rows(self):
        return [{'page': f'p{i:05d}', 'pattern': g} for i, g in enumerate(['a'] * 60 + ['b'] * 30 + ['c'] * 3 + ['d'])]

    def test_exact_size_every_group_and_deterministic(self):
        a = M.stratified(random.Random(7), self.rows(), 20, lambda r: r['pattern'])
        b = M.stratified(random.Random(7), self.rows(), 20, lambda r: r['pattern'])
        self.assertEqual(len(a), 20)
        self.assertEqual(len({r['page'] for r in a}), 20)
        self.assertEqual({r['pattern'] for r in a}, {'a', 'b', 'c', 'd'})
        self.assertEqual([r['page'] for r in a], [r['page'] for r in b])
        n = Counter(r['pattern'] for r in a)
        self.assertGreater(n['a'], n['b'])

    def test_fewer_rows_than_asked_takes_them_all(self):
        self.assertEqual(len(M.stratified(random.Random(1), self.rows()[:5], 20, lambda r: r['pattern'])), 5)

    def test_never_more_than_a_group_holds(self):
        rows = [{'page': f'p{i}', 'pattern': 'a' if i < 2 else 'b'} for i in range(12)]
        got = Counter(r['pattern'] for r in M.stratified(random.Random(3), rows, 11, lambda r: r['pattern']))
        self.assertEqual(sum(got.values()), 11)
        self.assertLessEqual(got['a'], 2)
        self.assertLessEqual(got['b'], 10)
        self.assertGreaterEqual(got['a'], 1)


class Regression(unittest.TestCase):
    def test_softmax_over_the_bundled_feature_order(self):
        import numpy as np
        feats = ['harmonic', 'periodic', 'conf', 'text_px', 'lines', 'print0']
        model = {'hand': {'classes': ['handwritten', 'typewritten', 'printed'], 'features': feats,
                          'mean': [0] * 6, 'sd': [1] * 6, 'W': [[0, 0, 0]] * 5 + [[3, 0, 0]], 'b': [0, 1, 0]}}
        sig = {'p1': {'harmonic': '0', 'periodic': '0', 'conf': '0', 'text_px': 'nan', 'lines': '0'}}
        hand = M.regression_labels(sig, {'p1': [2.0]}, model)['p1']
        self.assertEqual(hand['label'], 'handwritten')
        z = np.array([6, 1, 0.0]); p = np.exp(z) / np.exp(z).sum()
        self.assertAlmostEqual(hand['p_hand'], round(float(p[0]), 3))
        typed = M.regression_labels(sig, {'p1': [0.0]}, model)['p1']
        self.assertEqual(typed['label'], 'typewritten')

    def test_wrong_feature_count_stops(self):
        model = {'hand': {'classes': ['handwritten', 'typewritten', 'printed'], 'features': ['a'] * 7,
                          'mean': [0] * 7, 'sd': [1] * 7, 'W': [[0, 0, 0]] * 7, 'b': [0, 0, 0]}}
        sig = {'p1': {c: '0' for c in ('harmonic', 'periodic', 'conf', 'text_px', 'lines')}}
        with self.assertRaises(SystemExit):
            M.regression_labels(sig, {'p1': [0.0]}, model)


class Score(unittest.TestCase):
    def setUp(self):
        # 2,000 pages: 100 disagree, 50 mixed, 1,700 clean, 50 hand, 100 open
        self.rows = ([{'kind': 'disagree'}] * 100 + [{'kind': 'mixed'}] * 50 + [{'kind': 'clean'}] * 1700
                     + [{'kind': 'hand'}] * 50 + [{'kind': 'open'}] * 100)
        pages, answers = {}, {}
        def add(i, stratum, hand, mixed=None, pattern='x'):
            p = f'p{i:05d}'
            pages[p] = {'stratum': stratum, 'pattern': pattern, **lab(qwen='mixed' if stratum == 'mixed' else 'typewritten',
                                                  atrium='TEXT' if stratum != 'control' else 'TEXT_T')}
            answers[p] = {'hand': hand, **({'mixed': mixed} if mixed else {})}
        i = 0
        for j in range(10):        # disagreements: half have a passage (called mixed), half none
            add(i, 'disagree', 'passage' if j < 5 else 'none', 'yes' if j < 5 else None); i += 1
        for j in range(10):        # all-mixed: 8 long (mixed), 2 signature only (not mixed)
            add(i, 'mixed', 'long' if j < 8 else 'signature', 'yes' if j < 8 else 'no'); i += 1
        for j in range(10):        # controls: one few-words page, called not mixed
            add(i, 'control', 'few' if j == 0 else 'none', 'no' if j == 0 else None); i += 1
        self.key = {'pages': pages}
        self.answers = answers

    def test_cut_is_the_least_handwriting_mostly_called_mixed(self):
        out = M.score(self.answers, self.key, self.rows)
        self.assertEqual(out['cut'], 'passage')
        self.assertEqual(out['called_mixed_by_hand']['signature'], [0, 2])
        self.assertEqual(out['called_mixed_by_hand']['few'], [0, 1])
        self.assertEqual(out['answered'], 30)

    def test_estimate_weights_each_stratum_by_its_size(self):
        out = M.score(self.answers, self.key, self.rows)
        at = {r['at_least']: r for r in out['by_threshold']}
        # passage or more: disagree 0.5 * 100 + mixed 0.8 * 50 + clean 0 * 1700 + open (disagree rate) 0.5 * 100
        self.assertEqual(at['passage']['pages'], 140)
        self.assertEqual(at['passage']['open_assumed'], 50)
        # few or more adds the control page: 1/10 of 1,700 clean pages
        self.assertEqual(at['few']['pages'], 140 + 170)
        self.assertAlmostEqual(at['passage']['share'], 140 / 2000)

    def test_labelers_checked_against_the_owner_at_the_cut(self):
        out = M.score(self.answers, self.key, self.rows)
        q = out['labelers']['qwen']
        self.assertEqual(q['found'], 8)      # the all-mixed pages with a long passage
        self.assertEqual(q['false'], 2)      # the all-mixed pages with a signature only

    def test_disagreements_are_weighted_by_pattern(self):
        # pattern a (90 pages in the 2,000) answered once with no handwriting, pattern b (10 pages) nine times with a
        # passage: unweighted 0.9 of 100, weighted 0.1 of 100
        for p, v in self.key['pages'].items():
            if v['stratum'] == 'disagree':
                v['pattern'] = 'b'
                self.answers[p] = {'hand': 'passage', 'mixed': 'yes'}
        first = next(p for p, v in self.key['pages'].items() if v['stratum'] == 'disagree')
        self.key['pages'][first]['pattern'] = 'a'
        self.answers[first] = {'hand': 'none'}
        self.key['pattern_sizes'] = {'a': 90, 'b': 10}
        at = {r['at_least']: r for r in M.score(self.answers, self.key, self.rows)['by_threshold']}
        self.assertAlmostEqual(at['passage']['strata']['disagree']['rate'], 0.1)
        # a pattern with no answer takes the pooled rate (0.9)
        self.key['pattern_sizes'] = {'a': 50, 'b': 10, 'c': 40}
        at = {r['at_least']: r for r in M.score(self.answers, self.key, self.rows)['by_threshold']}
        self.assertAlmostEqual(at['passage']['strata']['disagree']['rate'], (0 + 10 + 36) / 100, places=3)

    def test_top_up_pages_set_the_cut_but_not_the_share(self):
        before = M.score(self.answers, self.key, self.rows)
        for j in range(5):
            p = f'p9{j:04d}'
            self.key['pages'][p] = {'stratum': 'mixed-both', 'pattern': 'x', **lab(qwen='mixed', atrium='TEXT')}
            self.answers[p] = {'hand': 'few', 'mixed': 'yes'}
        out = M.score(self.answers, self.key, self.rows)
        self.assertEqual(out['cut'], 'few')
        self.assertEqual(out['hand']['mixed-both'], {'few': 5})
        b = {r['at_least']: r['pages'] for r in before['by_threshold']}
        self.assertEqual({r['at_least']: r['pages'] for r in out['by_threshold']}, b)

    def test_unanswered_and_unknown_pages_are_ignored(self):
        self.answers['p99999'] = {'hand': 'long', 'mixed': 'yes'}
        self.answers['p00000'] = {}
        out = M.score(self.answers, self.key, self.rows)
        self.assertEqual(out['answered'], 29)


class Sheet(unittest.TestCase):
    def test_sheet_is_blind_and_complete(self):
        M.PAGES.mkdir(parents=True, exist_ok=True)
        rows = []
        rng = random.Random(5)
        for i in range(400):
            p = f'p{i:05d}'
            (M.PAGES / f'{p}.jpg').write_bytes(b'')
            l = lab(regression=rng.choice(['typewritten', 'handwritten']), atrium=rng.choice(['TEXT_T', 'TEXT', 'PHOTO']),
                    qwen=rng.choice(['typewritten', 'mixed', 'mixed']))
            kind, pattern = M.classify(l)
            rows.append({'page': p, **l, 'kind': kind, 'pattern': pattern})
        sh = M.sheet(rows)
        html = (M.CACHE / 'sheet' / 'index.html').read_text()
        self.assertNotIn('__', html.replace('__proto__', ''))
        key = json.loads((M.CACHE / 'sheet' / 'key.json').read_text())
        self.assertEqual(len(key['pages']), sh['pages'])
        self.assertEqual(sh['by_stratum'].get('disagree'), min(100, sum(r['kind'] == 'disagree' for r in rows)))
        n_mixed = sh['by_stratum'].get('mixed', 0) + sh['by_stratum'].get('mixed-both', 0)
        self.assertEqual(n_mixed, 50)
        self.assertEqual(sum(key['pattern_sizes'].values()), sum(r['kind'] == 'disagree' for r in rows))
        for p, v in key['pages'].items():
            if v['stratum'] == 'mixed-both':
                self.assertEqual((v['qwen'], v['atrium']), ('mixed', 'TEXT'))
        for word in ('TEXT_T', 'typewritten', 'disagree', 'stratum'):   # no label or stratum leaks into the sheet
            self.assertNotIn(word, html.split('const DATA=')[1].split(';')[0])


if __name__ == '__main__':
    unittest.main()
