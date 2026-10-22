"""W46.fix-ocr-truth-bias-score: unblinding, classing and the truth-fault share on synthetic answers. Run:
python3 -m unittest test_ocr_truth_bias_score"""
import random
import unittest

import ocr_truth_bias_score as S


def item(a, truth, qwen, tw):
    return {'a': a, 'truth': truth, 'qwen': qwen, 'mixed': False, 'truth_words': tw}


KEY = {'pages': {
    'p001': {'items': {'0': item('qwen', 'Shafer', 'Shaver', 1), '1': item('truth', '', 'your', 0),
                       '2': item('truth', 'feel of', 'feeling', 2)}},
    'p093': {'items': {'0': item('truth', 'o o o', '0 0 0', 3), '1': item('qwen', 'o o o', '0 0 0', 3),
                       '2': item('truth', '3S', 'SS', 1)}},
    'p081': {'items': {'0': item('truth', 'barred', 'turned', 1), '1': item('qwen', '', 'begin', 0)}},
    'p002': {'items': {'0': item('qwen', 'cat', 'cot', 1)}},
}}
ANSWERS = {'p001': {'0': 'b', '1': 'b', '2': 'a'}, 'p093': {'0': '=These are dividers.'}, 'p081': {'0': '=skip'},
           'p002': {'0': 'a'}}


class Classes(unittest.TestCase):
    def setUp(self):
        S.TYPED = {'p093#0': ('either', 'dividers'), 'p081#0': ('excluded', 'out')}
        self.rows = {(r['page'], r['place']): r for r in S.scored(KEY, ANSWERS)}

    def test_unblinding(self):
        self.assertEqual(self.rows[('p001', 0)]['class'], 'truth')    # A was qwen, the owner chose B
        self.assertEqual(self.rows[('p001', 1)]['class'], 'reader')   # A was the truth, the owner chose B
        self.assertEqual(self.rows[('p001', 2)]['class'], 'truth')
        self.assertEqual(self.rows[('p002', 0)]['class'], 'reader')

    def test_page_rules(self):
        self.assertEqual(self.rows[('p093', 1)]['class'], 'either')     # the page note answers every divider
        self.assertEqual(self.rows[('p093', 2)]['class'], 'unanswered')  # ... but not a non-divider
        self.assertEqual(self.rows[('p081', 1)]['class'], 'excluded')

    def test_untyped_note_refused(self):
        S.TYPED = {}
        with self.assertRaises(SystemExit):
            S.scored(KEY, {**ANSWERS, 'p002': {'0': '=a note nobody read'}})

    def test_share_counts_charged_truth_words(self):
        rows = list(self.rows.values())
        share, bad, tot = S.share(rows)
        self.assertEqual((bad, tot), (1, 10))   # p002's wrong truth word; omissions charge nothing
        lo, hi = S.bootstrap(rows, random.Random(1))
        self.assertTrue(0 <= lo <= share <= hi <= 1)

    def test_public_rows_hold_no_page_text(self):
        r = S.public({'page': 'p1', 'place': 0, 'class': 'frame', 'mixed': False, 'charged': 0,
                      'answer': '="Museum" is on the label', 'why': 'reads "Museum"', 'truth': 'x', 'qwen': 'y'})
        self.assertNotIn('truth', r)
        self.assertEqual(r['answer'], '="…" is on the label')
        self.assertEqual(r['why'], 'reads "…"')


if __name__ == '__main__':
    unittest.main()
