"""W46.owner-set-grow offline tests: the prompt and its parse, the selection of the base and top-up, the spans, the
sheet's blind order and its key, and the fold. Synthetic data only; no corpus, no network. Run (from this
directory): /usr/local/bin/python3 -m unittest test_owner_set_grow"""
import hashlib
import random
import unittest

import owner_set_grow as S


class Prompt(unittest.TestCase):
    def test_language_line_after_table(self):
        p = S.prompt()
        self.assertLess(p.index('TABLE:'), p.index('LANGUAGE:'))
        self.assertLess(p.index('LANGUAGE:'), p.index('TEXT:'))

    def test_parse_with_and_without_language(self):
        got = S.parse('KIND: typewritten\nTABLE: no\nLANGUAGE: English\nTEXT:\nDear Sir,\nyours')
        self.assertEqual((got['kind'], got['table'], got['language'], got['text']),
                         ('typewritten', False, 'English', 'Dear Sir,\nyours'))
        self.assertEqual(S.parse('KIND: printed\nTABLE: yes\nTEXT:\na | b')['language'], None)
        self.assertIsNone(S.parse('no form at all'))
        self.assertIsNone(S.parse(None))


class Select(unittest.TestCase):
    def test_base_is_answer_3_and_topup_follows_the_last_base_document(self):
        S.uh = lambda s: s            # order by the id itself in the test
        docs = [(f'f#{i:02d}', 'f', [(f'{i:02d}a.pdf', []), (f'{i:02d}b.pdf', [])]) for i in range(10)]
        drawn = [{'id': f'drawn:{i}', 'folder': 'f', 'name': f'{i:02d}a.pdf'} for i in (0, 1, 3)]
        answers = {'drawn:0': '3', 'drawn:1': '2', 'drawn:3': '3'}
        base, cand, last, gaps = S.select(drawn, answers, docs, 2)
        self.assertEqual([r['id'] for r in base], ['drawn:0', 'drawn:3'])
        self.assertEqual(last, 3)
        self.assertEqual(gaps, 1)                       # doc 2 was passed over by the first draw
        self.assertEqual(cand[0][2], '04a.pdf')

    def test_refuses_when_the_order_lost_a_page(self):
        S.uh = lambda s: s
        docs = [('f#00', 'f', [('00a.pdf', [])])]
        with self.assertRaises(SystemExit):
            S.select([{'id': 'drawn:x', 'folder': 'f', 'name': 'zz.pdf'}], {}, docs, 1)


class Spans(unittest.TestCase):
    def test_disputes_keep_a_token_range(self):
        sp = S.spans('the quick brown fox', 'the quack brown fox')
        self.assertEqual(sp[0], {'agreed': 'the', 't0': 0, 't1': 1})
        self.assertEqual(sp[1], {'a': 'quick', 'b': 'quack', 't0': 1, 't1': 2})

    def test_typography_is_not_a_dispute(self):
        sp = S.spans('it’s “here” – now', "it's \"here\" - now")
        self.assertTrue(all('agreed' in s for s in sp))

    def test_insertion_has_an_empty_side(self):
        sp = S.spans('a b c', 'a x b c')
        d = [s for s in sp if 'agreed' not in s][0]
        self.assertEqual((d['a'], d['b'], d['t0'], d['t1']), ('', 'x', 1, 1))

    def test_controls_are_inside_agreed_spans(self):
        sp = S.spans('one two three four five six seven eight', 'one two three four five six seven eight')
        c = S.control_spans(sp, random.Random(1))[0]
        self.assertEqual(len(c['text'].split()), 6)
        self.assertIn(c['text'], sp[0]['agreed'])


def compare_fixture():
    a, b = 'Dear Mr Smith thank you for the letter of May 4 one two three four', \
           'Dear Mr Smyth thank you for the letter of May 9 one two three four'
    sp = S.spans(a, b)
    ctrl = S.control_spans(sp, random.Random(3))[:1]
    return {'a': 'A', 'b': 'B', 'missing': [], 'pages': [
        {'id': 's001', 'spans': sp, 'controls': ctrl, 'kind': ['typewritten', 'typewritten'], 'table': [False, False],
         'language': ['English', 'English'], 'a_text': a, 'b_text': b}]}


class Sheet(unittest.TestCase):
    def setUp(self):
        self.cmp = compare_fixture()
        self.rows = [{'id': 's001', 'key': 'k1', 'set': 'base', 'tags': ['1950', 'Unread'], 'source': 'original'}]

    def test_build_is_blind_and_the_key_holds_the_sides(self):
        items, key = S.build(self.cmp, self.rows, {}, {})
        it = items[0]
        disputes = [x for x in it['places'] if x['kind'] == 'dispute']
        self.assertEqual(len(disputes), 2)
        for x in disputes:
            self.assertNotIn('a', x)          # no side names on the sheet
            opts = key['pages']['s001']['places'][x['id']]['options']
            self.assertEqual(sorted(opts), ['a', 'b'])
        self.assertTrue(any(x['kind'] == 'control' for x in it['places']))
        self.assertFalse(it['ask_text'])
        self.assertIn(('has text', 'a page of text (your answer of 11 Nov)'), it['fields'])
        self.assertEqual(it['places'][0]['at'], round(100 * 2 / 15))   # no Vision words: how far through the text

    def test_context_never_shows_a_side_of_a_dispute(self):
        items, key = S.build(self.cmp, self.rows, {}, {})
        for x in items[0]['places']:
            self.assertNotIn('Smith', x['left'] + x['right'])
            self.assertNotIn('Smyth', x['left'] + x['right'])

    def test_fold_picks_types_and_controls(self):
        items, key = S.build(self.cmp, self.rows, {}, {})
        places = key['pages']['s001']['places']
        ans = {'_build': key['build'], 's001': {}}
        sp = self.cmp['pages'][0]['spans']
        for pid, v in places.items():
            if v.get('control'):
                ans['s001'][pid] = 'y'
            elif sp[v['span']]['a'] == 'Smith':
                ans['s001'][pid] = str(v['options'].index('b') + 1)       # the owner picks B's "Smyth"
            else:
                ans['s001'][pid] = '=6'                                    # neither: he types it
        got = S.fold(self.cmp, key, ans)['s001']
        self.assertEqual(got['status'], 'settled')
        self.assertIn('Mr Smyth thank', got['text'])
        self.assertIn('of May 6 one', got['text'])
        self.assertEqual(got['counts']['control right'], 1)

    def test_fold_control_wrong_replaces_words_and_open_stays_open(self):
        items, key = S.build(self.cmp, self.rows, {}, {})
        places = key['pages']['s001']['places']
        ctrl = [p for p, v in places.items() if v.get('control')][0]
        c = places[ctrl]
        ans = {'_build': key['build'], 's001': {ctrl: '=X Y'}}
        got = S.fold(self.cmp, key, ans)['s001']
        self.assertEqual(got['status'], 'open')
        self.assertEqual(got['text'], None)
        for p, v in places.items():
            if not v.get('control'):
                ans['s001'][p] = '1'
        got = S.fold(self.cmp, key, ans)['s001']
        span = self.cmp['pages'][0]['spans'][c['span']]['agreed'].split()
        expect = span[:c['w0']] + ['X', 'Y'] + span[c['w1']:]
        self.assertIn(' '.join(expect), got['text'])
        self.assertEqual(got['counts']['control wrong'], 1)

    def test_fold_drops_topup_without_text_and_refuses_another_build(self):
        rows = [{**self.rows[0], 'set': 'topup'}]
        items, key = S.build(self.cmp, rows, {}, {})
        self.assertTrue(items[0]['ask_text'])
        ans = {'_build': key['build'], 's001': {'_text': '2'}}
        self.assertEqual(S.fold(self.cmp, key, ans)['s001']['drop'], 'top-up page not a page of text')
        with self.assertRaises(SystemExit):
            S.fold(self.cmp, key, {'_build': 'other'})

    def test_fold_drops_a_page_both_call_not_english(self):
        self.cmp['pages'][0]['language'] = ['French', 'French']
        items, key = S.build(self.cmp, self.rows, {}, {})
        self.assertTrue(items[0]['flag_language'])
        self.assertEqual(S.fold(self.cmp, key, {'_build': key['build']})['s001']['drop'], 'both drafters: not English')

    def test_fold_refuses_a_changed_draft(self):
        items, key = S.build(self.cmp, self.rows, {}, {})
        self.cmp['pages'][0]['a_text'] += ' more'
        with self.assertRaises(SystemExit):
            S.fold(self.cmp, key, {'_build': key['build']})


class Turns(unittest.TestCase):
    def test_clear_wins_only(self):
        self.assertEqual(S.clear_turn([10, 200, 5, 3]), (90, False))
        self.assertEqual(S.clear_turn([100, 80, 5, 3]), (0, True))


class Minutes(unittest.TestCase):
    def test_estimate(self):
        self.assertAlmostEqual(S.owner_minutes(6, 10, 15, 20), (60 + 10 * 10.5 + 60 + 60) / 60)


if __name__ == '__main__':
    unittest.main()
