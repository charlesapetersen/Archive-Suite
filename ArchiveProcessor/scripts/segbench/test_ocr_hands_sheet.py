"""W46.ocr-hands-sheet offline tests: merging two readers' differences into places, the control draw, the fold.
No corpus. Run: uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy \
python -m unittest test_ocr_hands_sheet (from this directory)."""
import random
import unittest

import ocr_hands_sheet as H


def lab(text, adjudicated=()):
    return [(w, 'adjudicated' if i in adjudicated else 'agreed') for i, w in enumerate(text.split())]


class Places(unittest.TestCase):
    def test_overlapping_differences_merge_into_one_three_way_place(self):
        truth = lab('the quick brown fox jumps over the lazy dog')
        got = H.hand_places(truth, {'q': 'the quick brawn fox jumps over the lazy dog',
                                    'l': 'the quack brown fax jumps over the lazy dog'})
        self.assertEqual(len(got), 1)
        x = got[0]
        self.assertEqual(x['readings']['truth'], 'quick brown fox')
        self.assertEqual(x['readings']['q'], 'quick brawn fox')
        self.assertEqual(x['readings']['l'], 'quack brown fax')
        self.assertEqual(len(x['options']), 3)
        self.assertEqual((x['before'], x['after']), ('the', 'jumps over the lazy dog'))

    def test_a_reader_agreeing_with_the_truth_shares_its_option(self):
        truth = lab('one two three four five six')
        got = H.hand_places(truth, {'q': 'one two tree four five six', 'l': 'one two three four five six'})
        self.assertEqual(sorted(map(sorted, got[0]['options'])), [['l', 'truth'], ['q']])

    def test_insertion_and_join_and_labels(self):
        truth = lab('a b c d e f g h', adjudicated={6})
        got = H.hand_places(truth, {'q': 'a b extra c d e fg h', 'l': 'a b c d e f g h'})
        ins = next(x for x in got if x['readings']['truth'] == '')
        self.assertEqual(ins['readings']['q'], 'extra')
        self.assertEqual(ins['labels'], ['agreed'])
        join = next(x for x in got if x['readings']['truth'] == 'f g')
        self.assertTrue(join['join'])                       # "fg" is the same words, only broken differently
        self.assertEqual(join['labels'], ['adjudicated', 'agreed'])

    def test_long_difference_is_a_block(self):
        truth = lab('x ' + ' '.join(f'w{i}' for i in range(10)) + ' y')
        got = H.hand_places(truth, {'q': 'x y', 'l': ' '.join(w for w, _ in truth)})
        self.assertTrue(got[0]['block'])


class Controls(unittest.TestCase):
    def test_starts_need_agreed_words_both_readers_read(self):
        words = ' '.join(f'w{i}' for i in range(20))
        truth = lab(words, adjudicated={12})
        q = words.replace('w3 ', 'v3 ')
        starts = H.control_starts(truth, {'q': q, 'l': words})
        # runs: w4..w11 (8 words) only; w0..w2 too short, w13..w19 is 7
        self.assertEqual(starts, [4])

    def test_draw_is_seeded_and_never_overlaps(self):
        starts = {'p1': list(range(1000)), 'p2': list(range(500))}
        a = H.draw_controls(starts, random.Random(1))
        self.assertEqual(a, H.draw_controls(starts, random.Random(1)))
        self.assertEqual(len(a), H.CONTROLS)
        for i, (p, s) in enumerate(a):
            for q, t in a[i + 1:]:
                self.assertTrue(p != q or abs(s - t) >= H.CONTROL_WORDS)


class Fold(unittest.TestCase):
    def test_rulings(self):
        key = {'pages': {'p1': {'items': {
            'h00': {'kind': 'hand', 'options': [['q'], ['truth', 'l']], 'readings': {'truth': 'cat', 'q': 'cot', 'l': 'cat'}},
            'h01': {'kind': 'hand', 'options': [['truth'], ['q']], 'readings': {'truth': 'dog', 'q': 'dig'}},
            'h02': {'kind': 'hand', 'options': [['truth'], ['q']], 'readings': {'truth': 'x', 'q': 'y'}},
            'c00': {'kind': 'control', 'options': [['truth', 'q', 'l']], 'readings': {'truth': 'all agree'}}}}}}
        r = H.fold(key, {'p1': {'h00': '1', 'h01': '=Dig', 'c00': '1'}})
        rr = r['rulings']['p1']
        self.assertFalse(rr['h00']['truth_stands'])
        self.assertEqual(rr['h01']['matches'], ['q'])
        self.assertEqual(rr['h02']['ruling'], 'open')
        self.assertTrue(rr['c00']['truth_stands'])
        self.assertEqual(r['counts'], {'hand': {'truth wrong': 2, 'open': 1}, 'control': {'truth stands': 1}})


if __name__ == '__main__':
    unittest.main()
