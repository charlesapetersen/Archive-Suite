"""Synthetic scan rows and replies; no corpus, model or paid call."""
from collections import Counter
import json
import unittest

import marks_set as M


def frame():
    """A 1,014-row frame shaped like the scan: 225 a collection, RG165 114, with bands spread across them."""
    sizes = {'Dean': 225, 'Deaver': 225, 'Herrnstein': 225, 'Stanton': 225, 'RG165': 114}
    # about the scan's proportions: upper bands near 1-3% each
    cycle = ['none'] * 35 + ['under_10_words'] * 15 + ['signature_initials_date'] * 9 + \
            ['10_29_words', '30_plus_words', 'handwritten_page']
    rows = []
    for c, n in sizes.items():
        for i in range(n):
            amount = cycle[i % len(cycle)]
            rows.append(dict(id=f'{c}-{i:04d}', collection=c, image='', status='ok', amount=amount,
                             flagged=amount != 'none', consistent=True, uncertain=False))
    rows[0]['amount'], rows[0]['status'], rows[0]['flagged'] = None, 'parse', False
    return rows


class Select(unittest.TestCase):
    def setUp(self):
        self.rows = frame()
        self.pages = M.select(self.rows)

    def test_size_and_uniqueness(self):
        self.assertEqual(len(self.pages), M.SET_SIZE)
        self.assertEqual(len({p['id'] for p in self.pages}), M.SET_SIZE)
        self.assertEqual(sum(p['core'] for p in self.pages), M.CORE_A + sum(M.CORE_B.values()))

    def test_phase_a_ignores_the_flag(self):
        a = [p for p in self.pages if p['phase'] == 'A']
        self.assertEqual(Counter(p['collection'] for p in a), Counter(M.PHASE_A))
        # the same phase-A draw whatever the flags say: rotate every page's band and draw again
        bands = [r['amount'] for r in self.rows]
        rotated = [dict(r, amount=bands[(i + 7) % len(bands)]) for i, r in enumerate(self.rows)]
        for r in rotated:
            r['flagged'] = r['amount'] not in (None, 'none')
        ids = {p['id'] for p in a}
        self.assertEqual(ids, {p['id'] for p in M.select(rotated) if p['phase'] == 'A'})
        for p in a:
            self.assertAlmostEqual(p['phase_membership_approx'], M.PHASE_A[p['collection']] /
                                   sum(r['collection'] == p['collection'] for r in self.rows))

    def test_fractions(self):
        for p in self.pages:
            self.assertTrue(0 < p['phase_fraction'] <= 1 and 0 < p['phase_membership_approx'] <= 1, p)
            if p['core']:
                self.assertTrue(0 < p['core_fraction_conditional'] <= 1)
        # an all-taken stratum has fraction one in its phase
        b30 = [p for p in self.pages if p['stratum'] == 'B:30_plus_words']
        self.assertTrue(b30 and all(p['phase_fraction'] == 1 for p in b30))

    def test_no_field_reads_as_a_weight(self):
        # P3-3: nothing named like an inclusion probability or weight on any page
        for p in self.pages:
            self.assertFalse({'p_core', 'p_overall', 'p_phase', 'weight'} & set(p), p)

    def test_core_groups_and_weighting(self):
        g = M.core_groups(self.pages)
        self.assertEqual({k: len(v) for k, v in g.items()}, {'A-core': M.CORE_A, 'B-core': sum(M.CORE_B.values())})
        self.assertTrue(all(p['phase'] == 'A' for p in g['A-core']) and all(p['phase'] == 'B' for p in g['B-core']))
        w = M.weighting(self.pages)
        self.assertIsNone(w['final_core_inclusion_probability'])
        self.assertFalse(w['validated'])
        self.assertEqual(w['use'], 'descriptive')
        self.assertEqual((w['phase_a_pages'], w['phase_a_owner_truth']), (50, M.CORE_A))
        self.assertEqual(w['support'], {'A-core': M.CORE_A, 'B-core': sum(M.CORE_B.values())})

    def test_report_card_carries_the_restriction(self):
        o = dict(pages=150, core=40, routes={}, agreement=dict(pages=0), weighting=M.weighting(self.pages))
        self.assertIn(M.CORE_RESTRICTION, M.markdown(o))

    def test_the_parse_failure_can_only_enter_by_phase_a(self):
        for p in self.pages:
            if p['amount'] is None:
                self.assertEqual(p['phase'], 'A')


class Parse(unittest.TestCase):
    def test_gemini_box_order(self):
        raw = '```json\n' + json.dumps(dict(page_kind='typed_printed', handwriting_amount='under_10_words',
                                            uncertain=False, marks=[
            dict(**{'class': 'marginal_note', 'box_2d': [100, 50, 200, 300], 'overlaps_print': False,
                    'legible': True, 'text': 'ok', 'words': 1})])) + '\n```'
        d, problems = M.parse(raw, 'gemini')
        self.assertEqual(problems, [])
        self.assertEqual(d['marks'][0]['box'], [0.05, 0.1, 0.3, 0.2])

    def test_local_box_order_and_bad_marks(self):
        raw = json.dumps(dict(page_kind='typed_printed', handwriting_amount='none', uncertain=False, marks=[
            {'class': 'stamp', 'bbox_2d': [50, 100, 300, 200], 'words': 0},
            {'class': 'doodle', 'bbox_2d': [0, 0, 10, 10]},
            {'class': 'stamp', 'bbox_2d': [5, 5, 5, 9]},
            {'class': 'other', 'bbox_2d': 'here'}]))
        d, problems = M.parse('<think>x</think>' + raw, 'local')
        self.assertEqual([m['box'] for m in d['marks']], [[0.05, 0.1, 0.3, 0.2]])
        self.assertEqual(sorted(problems), ['bad box', 'bad class', 'empty box'])

    def test_unusable(self):
        self.assertIsNone(M.parse('', 'gemini')[0])
        self.assertIsNone(M.parse('no json here', 'gemini')[0])
        self.assertIsNone(M.parse('{"marks": 3}', 'gemini')[0])


class Match(unittest.TestCase):
    def test_iou_and_greedy(self):
        a = dict(cls='stamp', box=[0, 0, 0.5, 0.5])
        b = dict(cls='other', box=[0, 0, 0.5, 0.4])
        c = dict(cls='stamp', box=[0.6, 0.6, 0.9, 0.9])
        self.assertAlmostEqual(M.iou(a['box'], b['box']), 0.8)
        self.assertEqual(M.match([a, c], [b]), 1)
        self.assertEqual(M.match([a, c], [b], same_class=True), 0)
        self.assertEqual(M.match([a], [a, a]), 1)  # one to one


if __name__ == '__main__':
    unittest.main()
