"""W46.ocr-audit-report-fix offline tests: the hand rescore's unresolved places (placed in the corrected truth, the
truths they allow, the exclusion and adverse-bound treatments) and the controls' per-passage interval. Synthetic
text only, no corpus. Run: uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy \
python -m unittest test_ocr_hands_rescore (from this directory)."""
import unittest

import ocr_hands_rescore as R
import ocr_panel_score as S


def hand(truth, others, t0, t1, ruling='either'):
    readings = {'truth': truth, **others}
    groups = {}
    for k, v in readings.items():
        groups.setdefault(v, []).append(k)
    return {'kind': 'hand', 'ruling': ruling, 'truth_stands': None, 'readings': readings,
            'options': list(groups.values()), 't0': t0, 't1': t1}


class Unresolved(unittest.TestCase):
    def test_only_either_hand_places_with_one_reading_per_option_truth_first(self):
        rulings = {'p1': {'h00': hand('cat', {'q': 'cot', 'l': 'cat'}, 1, 2),
                          'h01': {**hand('dog', {'q': 'dig'}, 3, 4, 'picked'), 'truth_stands': True},
                          'c00': {**hand('all agree', {}, 0, 2), 'kind': 'control'}}}
        u = R.unresolved(rulings)
        self.assertEqual(list(u), ['p1'])
        self.assertEqual([(x['id'], x['alts']) for x in u['p1']], [('h00', ['cat', 'cot'])])

    def test_relocate_follows_a_correction_elsewhere_and_refuses_a_touched_place(self):
        before = 'a b c d e'.split()
        self.assertEqual(R.relocate(before, 'x a b c d e'.split(), 2, 4), (3, 5))
        self.assertIsNone(R.relocate(before, 'a b C d e'.split(), 2, 4))
        self.assertEqual(R.relocate(before, 'a b c d e'.split(), 2, 2), (2, 2))      # insertion point
        self.assertIsNone(R.relocate(before, 'a b z c d e'.split(), 2, 2))           # something now sits there

    def test_variants_keep_line_breaks_and_cover_every_combination(self):
        text = 'one two-\nthree four\nfive'
        got = R.variants(text, [{'a0': 0, 'a1': 1, 'alts': ['one', 'won']},
                                {'a0': 3, 'a1': 3, 'alts': ['', 'and']}])
        self.assertEqual(got[0], text)                          # the fixed reference first
        self.assertEqual(sorted(got), sorted(['one two-\nthree four\nfive', 'one two-\nthree and four\nfive',
                                              'won two-\nthree four\nfive', 'won two-\nthree and four\nfive']))


class Treatments(unittest.TestCase):
    """Route A's lead over B rests wholly on one unresolved place; over C it does not."""
    PAGES = ['p1', 'p2', 'p3']
    TRUTH = {'p1': 'the cat sat on the mat today', 'p2': 'a quiet morning by the river',
             'p3': 'letters came in the afternoon post'}
    READ = {'A': {'p1': 'the cat sat on the mat today', 'p2': 'a quiet morning by the river',
                  'p3': 'letters came in the afternoon post'},
            'B': {'p1': 'the cot sat on the mat today', 'p2': 'a quiet morning by the river',
                  'p3': 'letters came in the afternoon post'},
            'C': {'p1': 'the cat sat on the mat today', 'p2': 'a quiet mourning by a rivet',
                  'p3': 'letter come on the afternoon past'}}

    def run_case(self):
        truths = {'p1': R.variants(self.TRUTH['p1'], [{'a0': 1, 'a1': 2, 'alts': ['cat', 'cot']}])}
        fixed = {r: {p: R.nes(self.TRUTH[p], t[p]) for p in self.PAGES} for r, t in self.READ.items()}
        b = R.bounds(truths, self.READ, R.nes)
        for r in b:
            for p in self.PAGES:
                b[r]['lo'].setdefault(p, fixed[r][p]); b[r]['hi'].setdefault(p, fixed[r][p])
        pair = lambda x, y: S.paired(x, y, rounds=2000)
        return fixed, b, R.treatments(fixed, b, 'A', self.PAGES, ['p1'], pair)

    def test_bounds_span_the_allowed_readings(self):
        fixed, b, _ = self.run_case()
        self.assertEqual(b['A']['hi']['p1'], 100.0)
        self.assertLess(b['A']['lo']['p1'], 100.0)              # 'cot' is allowed, A wrote 'cat'
        self.assertEqual(b['B']['hi']['p1'], 100.0)             # and B wrote 'cot'
        self.assertEqual(fixed['B']['p1'], b['B']['lo']['p1'])

    def test_a_lead_resting_on_the_unresolved_place_does_not_survive(self):
        _, _, tr = self.run_case()
        self.assertGreater(tr['B']['fixed']['delta'], 0)
        self.assertEqual(tr['B']['excluded']['delta'], 0)       # the clear pages are identical
        self.assertLessEqual(tr['B']['adverse']['delta'], 0)
        self.assertGreater(tr['C']['excluded']['delta'], 0)     # C's errors are off the unresolved page
        self.assertEqual(tr['C']['excluded']['n'], 2)


class Controls(unittest.TestCase):
    def test_the_passage_bound_also_bounds_words_and_the_iid_figure_is_kept_apart(self):
        rulings = {f'p{i}': {'c00': {'kind': 'control', 'truth_stands': True,
                                     'readings': {'truth': 'one two three four five six seven eight'}}}
                   for i in range(19)}
        c = R.controls(rulings)
        self.assertEqual((c['ruled'], c['wrong'], c['words']), (19, 0, 152))
        self.assertAlmostEqual(c['rate_hi'], 0.1765, places=3)
        self.assertEqual(c['per_word_hi'], c['rate_hi'])
        self.assertAlmostEqual(c['per_word_hi_if_iid'], 0.024, places=3)


class Report(unittest.TestCase):
    def test_the_report_carries_its_card_and_the_unresolved_section_on_every_generation(self):
        import re
        import tempfile
        from pathlib import Path
        d = {'n': 3, 'delta': 2.0, 'p': .1, 'lo': .5, 'hi': 3.5}
        t = {'n': 3, 'delta': .1, 'p': .9, 'lo': -1., 'hi': 1.}
        r = {'pages': ['p1', 'p2', 'p3'], 'changed_pages': ['p2'], 'lead': 'A',
             'routes': [{'route': 'A', 'after': 95., 'before': 95.5, 'move': -.5, 'failed': 0, 'lo': 94., 'hi': 95.,
                         'clear': 96.}, {'route': 'B', 'after': 93., 'before': 93., 'move': 0., 'failed': 0,
                                         'lo': 92., 'hi': 94., 'clear': 96.}],
             'paired': {'B': {'after': d, 'before': d}},
             'sheet': {'hand': {'truth stands': 1, 'either': 1, 'truth wrong': 1, 'open': 0}},
             'controls': {'passages': 2, 'ruled': 2, 'wrong': 0, 'rate_lo': 0., 'rate_hi': .84, 'per_word_hi': .84,
                          'per_word_hi_if_iid': .2},
             'unresolved': {'places': {'p1': ['h00']}, 'dropped': [], 'pages': ['p1'], 'truths': {'p1': 2},
                            'treatments': {'B': {'fixed': d, 'excluded': t, 'adverse': d}},
                            'summary': R.robustness({'B': {'fixed': d, 'excluded': t, 'adverse': d}})}}
        with tempfile.TemporaryDirectory() as tmp:
            out = []
            for _ in range(2):
                R.write_md(Path(tmp) / 'r.md', r)
                out.append((Path(tmp) / 'r.md').read_text())
        self.assertEqual(out[0], out[1])
        self.assertRegex(out[0], re.compile(r'(?mi)^#{1,4}\s+measurement card\b'))   # measure-review.py's CARD
        for field in ('Truth', 'Selection', 'Comparison', 'Noise', 'Scope'):
            self.assertIn(f'- **{field}.**', out[0])
        self.assertIn('## The unresolved places', out[0])
        self.assertIn('against 1 (B) it fails at least one', out[0])
        self.assertIn('either will do / can\'t tell', out[0])
        self.assertNotIn('either reading is right', out[0])


if __name__ == '__main__':
    unittest.main()
