#!/usr/bin/env python3
"""Synthetic checks for kind_atrium.py (W46.kind-atrium): no corpus, no model, no cache.

  /usr/local/bin/python3 test_kind_atrium.py      (numpy needed)
"""
import os
import itertools
import tempfile
import unittest

os.environ['KIND_ATRIUM_CACHE'] = tempfile.mkdtemp(prefix='kind-atrium-test-')
import numpy as np        # noqa: E402
import kind_atrium as K   # noqa: E402


def probs(**kw):
    p = np.full(len(K.CLASSES), 0.001)
    for c, v in kw.items():
        p[K.CLASSES.index(c)] = v
    return p / p.sum()


class Mapping(unittest.TestCase):
    def test_classes_read_as_ours(self):
        self.assertEqual(K.hand_argmax('TEXT_T'), 'typewritten')
        self.assertEqual(K.hand_argmax('LINE_P'), 'printed')
        self.assertEqual(K.hand_argmax('TEXT_HW'), 'handwritten')
        self.assertEqual(K.hand_argmax('TEXT'), 'mixed')
        self.assertEqual(K.hand_argmax('PHOTO'), 'none')
        self.assertEqual(K.hand_argmax('DRAW_L'), 'none')

    def test_hand_only_skips_mixed_and_pictures(self):
        self.assertEqual(K.hand_only(probs(TEXT=.6, PHOTO=.2, TEXT_P=.15, TEXT_T=.05)), ('printed', False))

    def test_hand_only_reports_a_form(self):
        self.assertEqual(K.hand_only(probs(LINE_HW=.5, TEXT_HW=.4)), ('handwritten', True))

    def test_hand6_is_the_six_text_classes(self):
        self.assertEqual(sorted(K.CLASSES[j] for j in K.HAND6),
                         ['LINE_HW', 'LINE_P', 'LINE_T', 'TEXT_HW', 'TEXT_P', 'TEXT_T'])

    def test_public_kinds_all_mapped(self):
        self.assertEqual(set(K.PUBLIC_HAND), {'typed', 'print', 'newspaper', 'handwritten', 'ledger'})
        self.assertTrue(set(K.PUBLIC_HAND.values()) <= set(K.KINDS3))


class Stats(unittest.TestCase):
    def test_wilson_contains_the_rate(self):
        lo, hi = K.wilson(90, 100)
        self.assertTrue(lo < .9 < hi)
        self.assertAlmostEqual(lo, .825, places=2)

    def test_wilson_at_the_edge(self):
        lo, hi = K.wilson(10, 10)
        self.assertLess(lo, 1)
        self.assertAlmostEqual(hi, 1)

    def test_mcnemar_counts_only_discordant_pages(self):
        a = [True, True, False, True, False]
        b = [True, False, False, False, True]
        x, y, p = K.mcnemar(a, b)
        self.assertEqual((x, y), (2, 1))
        self.assertAlmostEqual(p, 1.0)

    def test_mcnemar_one_sided_split(self):
        x, y, p = K.mcnemar([True] * 10, [False] * 10)
        self.assertEqual((x, y), (10, 0))
        self.assertAlmostEqual(p, 2 / 2 ** 10)

    def test_mcnemar_no_discordance(self):
        self.assertEqual(K.mcnemar([True, False], [True, False]), (0, 0, 1.0))

    def test_auc(self):
        self.assertEqual(K.auc([.9, .8, .1], [True, True, False]), 1.0)
        self.assertEqual(K.auc([.1, .9], [True, False]), 0.0)
        self.assertEqual(K.auc([.5, .5], [True, False]), 0.5)
        self.assertTrue(K.auc([.5], [True]) != K.auc([.5], [True]))   # nan when one side is empty

    def test_head_fits_separable_data(self):
        rng = np.random.default_rng(0)
        X = np.vstack([rng.normal(0, 1, (20, 5)), rng.normal(4, 1, (20, 5))])
        y = np.array([0] * 20 + [1] * 20)
        groups = [f'g{i % 5}' for i in range(40)]
        self.assertGreaterEqual((K.lofo(X, y, 2, groups) == y).mean(), .95)
        self.assertGreaterEqual((K.fit_all(X, y, 2)(X) == y).mean(), .95)


class MixedSupport(unittest.TestCase):
    def fixture(self):
        # Fixed quotas: singleton pattern A (1/3), pattern B (2/2), clean (1/4), mixed census (39/39).
        labels, pages, truth, call = {}, {}, {}, {}
        for kind, pattern, n, answers, called in (
                ('disagree', 'A', 3, [True], True), ('disagree', 'B', 2, [False, True], False),
                ('clean', '', 4, [False], False), ('mixed', '', 39, [True] * 38 + [False], True),
                ('hand', '', 2, [], True), ('open', '', 1, [], True)):
            for i in range(n):
                p = f'{kind}-{pattern}-{i}'
                labels[p] = {'kind': kind, 'pattern': pattern}
                call[p] = called
                if i < len(answers):
                    pages[p] = {'stratum': 'control' if kind == 'clean' else kind, 'pattern': pattern}
                    truth[p] = answers[i]
        return labels, {'pages': pages, 'pattern_sizes': {'A': 3, 'B': 2}}, truth, {'test': call}

    def test_weights_denominators_singletons_and_census(self):
        d, (r,) = K.mixed_support(*self.fixture())
        self.assertEqual((d['population'], d['covered_pages'], d['singleton_patterns']), (51, 48, 1))
        self.assertEqual(r['covered']['tp'], 41)  # A: 3, census: 38
        self.assertEqual(r['covered']['fp'], 1)
        self.assertEqual(r['covered']['fn'], 1)
        self.assertEqual(r['covered']['calls'], 42)
        self.assertEqual(r['full']['calls'], 45)
        self.assertEqual(r['full']['unsampled_calls'], {'hand': 2, 'open': 1})
        self.assertEqual(r['full']['point_completion']['hand_not_mixed']['precision'], [41/45, 42/45])
        self.assertEqual(r['full']['point_completion']['unrestricted']['precision'], [41/45, 44/45])
        census = next(g for g in d['groups'] if g['stratum'] == 'mixed')
        self.assertEqual((census['population'], census['checked'], census['census']), (39, 39, True))
        # Unseen pages within singleton A stay uncertain even though its point estimate is all-positive.
        lo, hi = r['full']['finite_completion']['unrestricted']['precision']
        self.assertLess(lo, hi)

    def test_top_up_constrains_finite_bounds_without_design_weight(self):
        args = self.fixture()
        _, (before,) = K.mixed_support(*args)
        labels, key, truth, calls = args
        key['pages']['disagree-A-1'] = {'stratum': 'mixed-both', 'pattern': 'A'}
        truth['disagree-A-1'] = False
        d, (after,) = K.mixed_support(labels, key, truth, calls)
        self.assertEqual(d['top_up_answers'], 1)
        self.assertEqual(before['covered'], after['covered'])
        self.assertLess(after['full']['finite_completion']['unrestricted']['precision'][1],
                        before['full']['finite_completion']['unrestricted']['precision'][1])

    def test_missing_answer_pattern_census_and_calls_fail(self):
        for p in ('disagree-A-0', 'mixed--0', 'clean--0'):
            args = self.fixture()
            del args[2][p]
            with self.assertRaises(ValueError):
                K.mixed_support(*args)
        args = self.fixture()
        del args[1]['pages']['mixed--0']
        with self.assertRaisesRegex(ValueError, 'census'):
            K.mixed_support(*args)
        args = self.fixture()
        del args[3]['test']['open--0']
        with self.assertRaisesRegex(ValueError, 'every frame ID'):
            K.mixed_support(*args)
        args = self.fixture()
        args[1]['pattern_sizes']['A'] = 4
        with self.assertRaisesRegex(ValueError, 'pattern sizes'):
            K.mixed_support(*args)

    def test_hand_assumption_never_overwrites_an_owner_answer(self):
        labels, key, truth, calls = self.fixture()
        truth['hand--0'] = True
        _, (r,) = K.mixed_support(labels, key, truth, calls)
        self.assertEqual(r['sheet']['found'], 40)
        self.assertEqual(r['full']['finite_completion']['hand_not_mixed']['precision'][0], 40/45)
        self.assertEqual(r['full']['point_completion']['hand_not_mixed']['precision'][0], 42/45)

    def test_review_examples_keep_all_calls(self):
        q = K.completion_bounds(150, 650, 165, 14, 0)
        reg = K.completion_bounds(81, 650, 221, 14, 0)
        self.assertEqual(q['precision'], [150/165, 164/165])
        self.assertEqual(reg['precision'], [81/221, 95/221])

    def test_report_retains_support_and_uncertainty_on_repeat_generation(self):
        design, rows = K.mixed_support(*self.fixture())
        md = '\n'.join(K.mixed_support_md(design, rows))
        self.assertIn('4 clean-stratum pages represented by 1 checked controls', md)
        self.assertIn('5 disagreements represented by 3 checks across 2 fixed patterns', md)
        self.assertIn('1 of those are noncensus', md)
        self.assertIn('not confidence intervals', md)
        self.assertIn('Finite-population completion bounds', md)
        self.assertEqual(md, '\n'.join(K.mixed_support_md(*K.mixed_support(*self.fixture()))))

    def test_bounds_equal_exhaustive_completions_and_collapse_at_census(self):
        # Brute force an independent oracle, including zero mixed / zero calls edges.
        for known in itertools.product((False, True), repeat=2):
            for calls in itertools.product((False, True), repeat=5):
                tp = sum(c and t for c, t in zip(calls, known))
                b = K.completion_bounds(tp, sum(known), sum(calls), sum(calls[2:]), 3-sum(calls[2:]))
                precision, recall = [], []
                for rest in itertools.product((False, True), repeat=3):
                    truths = known + rest
                    full_tp = sum(c and t for c, t in zip(calls, truths))
                    if sum(calls):
                        precision.append(full_tp/sum(calls))
                    if sum(truths):
                        recall.append(full_tp/sum(truths))
                self.assertEqual(b['precision'], [min(precision), max(precision)] if precision else [None, None])
                self.assertEqual(b['recall'], [min(recall), max(recall)] if recall else [None, None])
        self.assertEqual(K.completion_bounds(38, 38, 39, 0, 0)['precision'], [38/39, 38/39])
        self.assertEqual(K.completion_bounds(38, 38, 39, 0, 0)['recall'], [1, 1])
        self.assertEqual(K.completion_bounds(0, 0, 0, 0, 0)['recall'], [None, None])


if __name__ == '__main__':
    unittest.main()
