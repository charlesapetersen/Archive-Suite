"""W46.ocr-input-colour-dropout sheet offline tests: places against the draft, the blind order, the keep rule, the
turns and the fold. Synthetic data only. Run (from this directory): uv run --offline --with rapidfuzz
--with 'sacrebleu==2.5.1' --with regex --with numpy --with pillow python -m unittest test_colour_dropout_sheet"""
import hashlib
import unittest

import colour_dropout_sheet as S


def four(vr, vd, gr, gd):
    return {'vision-raw': vr, 'vision-dropout': vd, 'gemini-raw': gr, 'gemini-dropout': gd}


class Places(unittest.TestCase):
    def test_one_merged_place_with_the_draft_named(self):
        draft = 'the quick brown fox jumps over the lazy dog'
        got = S.page_places(draft, four('the quick brawn fox jumps over the lazy dog', draft,
                                        'the quack brown fox jumps over the lazy dog', draft))
        self.assertEqual(len(got), 1)
        x = got[0]
        self.assertEqual(x['readings']['draft'], 'quick brown')
        self.assertEqual(sorted(map(tuple, x['options'])),
                         [('draft', 'gemini-dropout', 'vision-dropout'), ('gemini-raw',), ('vision-raw',)])
        self.assertTrue(S.raw_dropout_disagree(x))

    def test_join_and_block_flagged(self):
        draft = 'a b c d e f g h i j k l m n o p'
        got = S.page_places(draft, four('a b c d e fg h i j k l m n o p', draft, draft,
                                        'a b c d e f g h i x1 x2 x3 x4 x5 x6 x7 x8'))
        self.assertTrue(any(x['join'] for x in got))
        self.assertTrue(any(x['block'] for x in got))

    def test_all_raw_agree_with_dropout_is_not_a_disagreement(self):
        draft = 'one two three four'
        got = S.page_places(draft, four('one too three four', 'one too three four', draft, draft))
        self.assertFalse(S.raw_dropout_disagree(got[0]))   # vision both 'too', gemini both the draft's

    def test_keep_rule(self):
        draft = 'one two three four'
        x = S.page_places(draft, four('one too three four', draft, draft, draft))[0]
        line = [[0.1, 0.4, 0.8, 0.05]]
        self.assertEqual(S.keep(x, [0.3, 0.41, 0.1, 0.03], line), 'under mark')
        self.assertIsNone(S.keep(x, [0.3, 0.7, 0.1, 0.03], line))
        self.assertEqual(S.keep(x, None, line), 'unlocated, raw and dropout disagree')
        y = S.page_places(draft, four('one too three four', 'one too three four', draft, draft))[0]
        self.assertIsNone(S.keep(y, None, line))

    def test_cap_is_seeded_and_ordered(self):
        a = S.cap(list(range(40)), S.random.Random('x'), 15)
        self.assertEqual(a, S.cap(list(range(40)), S.random.Random('x'), 15))
        self.assertEqual((len(a), a), (15, sorted(a)))


class Blind(unittest.TestCase):
    def test_order_does_not_depend_on_which_reading_is_the_draft(self):
        # the same three texts, the draft holding a different one each time: the shown order is the same
        texts = ['brown', 'brawn', 'browm']
        shown = set()
        for d in range(3):
            names = ['draft', 'r1', 'r2']
            names = names[d:] + names[:d]
            x = {'t0': 3, 't1': 4, 'readings': dict(zip(names, texts)), 'options': [[n] for n in names]}
            shown.add(tuple(t for t, _ in S.blind_options(x, S.place_rng('k', x))))
        self.assertEqual(len(shown), 1)

    def test_draft_first_in_hand_places_is_not_kept(self):
        # hand_places lists the draft's group first; across many places the draft lands in every position
        pos = set()
        for t0 in range(40):
            x = {'t0': t0, 't1': t0 + 1, 'readings': {'draft': 'aa', 'r1': 'bb', 'r2': 'cc'},
                 'options': [['draft'], ['r1'], ['r2']]}
            pos.add([s for _, s in S.blind_options(x, S.place_rng('k', x))].index(['draft']))
        self.assertEqual(pos, {0, 1, 2})


class Turns(unittest.TestCase):
    def test_clear_wins_only(self):
        self.assertEqual(S.clear_turn([10, 200, 5, 8]), (90, False))
        self.assertEqual(S.clear_turn([300, 10, 20, 5]), (0, False))
        self.assertEqual(S.clear_turn([40, 70, 5, 8]), (0, True))      # sideways, not by twice: left as it is
        self.assertEqual(S.clear_turn([12, 3, 2, 1]), (0, True))       # too little text to call


class Fold(unittest.TestCase):
    def test_apply_edits_keeps_lines(self):
        text = 'alpha beta\ngamma delta\nepsilon'
        self.assertEqual(S.apply_edits(text, [(1, 2, 'BETA'), (2, 4, 'g d')]), 'alpha BETA\ng d\nepsilon')
        self.assertEqual(S.apply_edits(text, [(2, 2, 'new')]), 'alpha beta\nnew gamma delta\nepsilon')
        self.assertEqual(S.apply_edits(text, [(5, 5, 'end')]), 'alpha beta\ngamma delta\nepsilon end')
        self.assertEqual(S.apply_edits('a b c', [(1, 2, '')]), 'a c')

    def test_fold(self):
        draft = 'the quick brown fox\njumps over'
        key = {'build': 'b1', 'pages': {
            'k1': {'draft_sha': hashlib.sha256(draft.encode()).hexdigest(), 'kind': 'typewritten',
                   'marks': [['red', 'X']], 'items': {
                       'd00': {'t0': 2, 't1': 3, 'options': [['vision-raw'], ['draft', 'gemini-raw']],
                               'texts': ['brawn', 'brown'], 'readings': {'draft': 'brown', 'vision-raw': 'brawn',
                                                                         'gemini-raw': 'brown'}},
                       'd01': {'t0': 4, 't1': 5, 'options': [['draft'], ['vision-raw']], 'texts': ['jumps', 'jumped'],
                               'readings': {'draft': 'jumps', 'vision-raw': 'jumped'}},
                       'd02': {'t0': 5, 't1': 6, 'options': [['draft'], ['vision-raw']], 'texts': ['over', 'ever'],
                               'readings': {'draft': 'over', 'vision-raw': 'ever'}},
                       'd03': {'t0': 0, 't1': 1, 'options': [['draft'], ['vision-raw']], 'texts': ['the', 'tho'],
                               'readings': {'draft': 'the', 'vision-raw': 'tho'}}}},
            'k2': {'not_ready': 'no draft'}}}
        answers = {'_build': 'b1', 'k1': {'d00': '1', 'd01': '=leaps', 'd02': 'either'},
                   '_notes': {'k1/d00': 'n1', 'k1': 'marks are blue', '_sheet': 's'}, '_turns': {'k1': 90}}
        r = S.fold(key, answers, {'k1': draft})
        self.assertEqual(r['texts']['k1'], 'the quick brawn fox\nleaps over')
        self.assertEqual(r['counts'], {'draft wrong': 2, 'either': 1, 'open': 1})
        p = r['pages']['k1']
        self.assertEqual((p['applied'], p['note'], p['turn_by_owner']), (2, 'marks are blue', 90))
        self.assertEqual(p['items']['d00']['note'], 'n1')
        self.assertEqual(r['sheet_note'], 's')
        # a typed text that is the draft's words leaves the draft
        r2 = S.fold(key, {'k1': {'d01': '=Jumps'}}, {'k1': draft})
        self.assertEqual(r2['texts']['k1'], draft)
        with self.assertRaises(SystemExit):
            S.fold(key, {'_build': 'other'}, {'k1': draft})
        with self.assertRaises(SystemExit):
            S.fold(key, {}, {'k1': draft + ' changed'})


if __name__ == '__main__':
    unittest.main()
