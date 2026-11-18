"""W46.newspaper-photo-truth offline tests: the hashed order and its caps, the screen's parse, the set's choice, the
owner-time estimate, and that owner_set_grow runs on this item's cache. Synthetic data only; no corpus, no network.
Run (from this directory): /usr/local/bin/python3 -m unittest test_newspaper_photo_truth"""
import unittest

import newspaper_photo_truth as N
import owner_set_grow as G


class Draw(unittest.TestCase):
    def test_order_is_the_salted_hash_and_stable(self):
        paths = [f'C{i % 3}/f{i % 5}/{i:03d}.pdf' for i in range(40)]
        self.assertEqual(N.hashed_order(paths), N.hashed_order(list(reversed(paths))))
        self.assertEqual(N.hashed_order(paths)[0], min(paths, key=lambda p: N.sh256(N.SALT + p)))

    def test_caps_count_only_pages_that_were_taken(self):
        order = ['A/x/1.pdf', 'A/x/2.pdf', 'A/x/3.pdf', 'A/y/1.pdf', 'B/z/1.pdf', 'A/y/2.pdf']
        gen = N.capped(order, folder_max=1, collection_max=2)
        got, ok = [], None
        try:
            while True:
                p = gen.send(ok) if ok is not None else next(gen)
                ok = p != 'A/x/1.pdf'            # the first one is unreadable: it does not use up A/x's place
                if ok:
                    got.append(p)
        except StopIteration:
            pass
        self.assertEqual(got, ['A/x/2.pdf', 'A/y/1.pdf', 'B/z/1.pdf'])   # A/x/3: folder full; A/y/2: collection full

    def test_collection_is_the_top_level_folder(self):
        self.assertEqual(N.collection('Hoover Institute/Zschau/IMG 1.pdf'), 'Hoover Institute')


class Screen(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(N.parse_screen('SOURCE: NEWSPAPER\nCOLUMNS: 6'), {'source': 'NEWSPAPER', 'columns': 6})
        self.assertEqual(N.parse_screen('**SOURCE:** magazine\nCOLUMNS: **3**'), {'source': 'MAGAZINE', 'columns': 3})
        self.assertEqual(N.parse_screen('SOURCE: OTHER'), {'source': 'OTHER', 'columns': None})
        self.assertIsNone(N.parse_screen('It is a newspaper.'))
        self.assertIsNone(N.parse_screen(None))

    def test_choose_takes_newspapers_in_draw_order_up_to_target(self):
        rows = [{'id': f'n{i}', 'order': o} for i, o in enumerate([5, 1, 3, 2, 4])]
        screens = {'n0': {'source': 'NEWSPAPER'}, 'n1': {'source': 'MAGAZINE'}, 'n2': {'source': 'NEWSPAPER'},
                   'n3': {'source': 'NEWSPAPER'}, 'n4': None}
        self.assertEqual([r['id'] for r in N.choose(rows, screens, target=2)], ['n3', 'n2'])


class Size(unittest.TestCase):
    def test_rate_and_estimate(self):
        rows = [{'kind': {'a': 'printed', 'b': 'printed'}, 'n_disputes': 10, 'words': {'a': 900, 'b': 1100}},
                {'kind': {'a': 'typewritten', 'b': 'printed'}, 'n_disputes': 30, 'words': {'a': 1000, 'b': 1000}}]
        self.assertAlmostEqual(N.dispute_rate(rows, 'printed'), 10.0)
        self.assertAlmostEqual(N.dispute_rate(rows), 20.0)
        e = N.estimate([2000, 2000], 10.0, controls=0)
        self.assertEqual((e['pages'], e['words'], e['disputes']), (2, 4000, 40))
        self.assertEqual(e['minutes'], round(G.owner_minutes(2, 40, 0, 0)))


class Wiring(unittest.TestCase):
    def test_owner_set_grow_runs_on_this_cache_and_cap(self):
        self.assertEqual(G.OUT, N.OUT)
        self.assertEqual(G.CAP, N.CAP)
        self.assertLessEqual(N.CAP, 7.0)
        self.assertEqual(G.image({'key': 'k'}), N.OUT / 'prep' / 'k.jpg')


class Report(unittest.TestCase):
    def test_counts_only_and_pending_steps(self):
        import json, tempfile
        from pathlib import Path
        old = N.OUT
        with tempfile.TemporaryDirectory() as t:
            N.OUT = G.OUT = Path(t)
            try:
                rows = [{'id': f'n{i:03d}', 'set': 'news', 'key': f'k{i}', 'folder': 'Secret Coll/Folder X',
                         'name': f'Private Name {i}.pdf', 'source': 'original (exact name)', 'vision_words': w,
                         'order': i} for i, w in enumerate([300, 500, 900], 1)]
                text = ''.join(json.dumps(r) + '\n' for r in rows)
                (N.OUT / 'candidates.jsonl').write_text(text)
                (N.OUT / 'pages.jsonl').write_text(text)
                (N.OUT / 'draw.json').write_text(json.dumps({'pool': 6285, 'candidates': 3, 'failed': [],
                    'folder_max': 3, 'collection_max': 8, 'collections': {'Secret Coll': 3}}))
                (N.OUT / 'sorter.tsv').write_text('id\tvision_kind\nn001\tnewspaper\nn002\tphotograph\n')
                out = '\n'.join(N.report_lines())
                self.assertIn('6,285', out)
                self.assertIn('median 500, range 300-900', out)
                self.assertIn('1 newspaper', out)
                self.assertIn('not made yet', out)
                self.assertIn('## Measurement card', out)
                self.assertNotIn('## The screen', out)
                for leak in ('Secret', 'Folder X', 'Private Name'):
                    self.assertNotIn(leak, out)
                (N.OUT / 'screen').mkdir()
                for r, a in zip(rows, ('SOURCE: NEWSPAPER\nCOLUMNS: 5', 'SOURCE: OTHER', 'SOURCE: NEWSPAPER')):
                    N.screen_path(r).write_text(json.dumps({'raw': a}))
                chosen = N.choose(rows, {r['id']: N.screened(r) for r in rows})
                (N.OUT / 'pages.jsonl').write_text(''.join(json.dumps({**r, 'screen': N.screened(r)}) + '\n'
                                                           for r in chosen))
                out = '\n'.join(N.report_lines())
                self.assertIn('2 newspaper, 1 other', out)
                self.assertIn('the first 2 screened newspaper', out)
                self.assertIn("sorter calls 1 of them newspaper", out)
            finally:
                N.OUT = G.OUT = old


if __name__ == '__main__':
    unittest.main()
