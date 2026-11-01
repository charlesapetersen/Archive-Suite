"""Synthetic selection, drafts and images; no corpus page, model or network call."""
import json
from pathlib import Path
import re
import tempfile
import unittest
from unittest import mock

import marks_set as M
import marks_sheet as S


def mk(cls, box, text='', overlaps=False):
    return dict(cls=cls, box=box, overlaps_print=overlaps, legible=bool(text), text=text, words=0)


def draft(*marks):
    return dict(draft=dict(page_kind='typed_printed', amount='none', uncertain=False, marks=list(marks)), problems=[])


class Candidates(unittest.TestCase):
    def test_pairing_and_mean_box(self):
        a = [mk('stamp', [0.1, 0.1, 0.3, 0.2], 'RECEIVED')]
        b = [mk('stamp', [0.12, 0.1, 0.32, 0.2], 'RECEIVED', overlaps=True)]
        cs = S.candidates([('ga', draft(*a)), ('qb', draft(*b))])
        self.assertEqual(len(cs), 1)
        self.assertEqual(cs[0]['box'], [0.11, 0.1, 0.31, 0.2])
        self.assertEqual(cs[0]['cls'], 'stamp')
        self.assertEqual(cs[0]['texts'], ['RECEIVED'])
        self.assertTrue(cs[0]['overlaps_print'])
        self.assertEqual(cs[0]['sources'], ['ga', 'qb'])

    def test_class_disagreement_is_none_and_texts_union(self):
        cs = S.candidates([('ga', draft(mk('annotation', [0.5, 0.5, 0.7, 0.6], 'ok'))),
                           ('qb', draft(mk('marginal_note', [0.5, 0.5, 0.7, 0.61], 'OK!')))])
        self.assertEqual(len(cs), 1)
        self.assertIsNone(cs[0]['cls'])
        self.assertEqual(cs[0]['classes'], ['annotation', 'marginal_note'])
        self.assertEqual(cs[0]['texts'], ['OK!', 'ok'])  # sorted, not in route order

    def test_unpaired_kept_and_ordered(self):
        cs = S.candidates([('ga', draft(mk('other', [0.6, 0.8, 0.7, 0.9]), mk('stamp', [0.1, 0.1, 0.2, 0.2]))),
                           ('qb', draft(mk('redaction', [0.5, 0.3, 0.9, 0.4]), mk('stamp', [0.6, 0.81, 0.71, 0.9]))),
                           ('none', None), ('empty', {'draft': None})])
        # the second route's stamp overlaps the first's 'other' at IoU >= .5: one candidate, class to choose
        self.assertEqual([c['box'][1] for c in cs], sorted(c['box'][1] for c in cs))
        self.assertEqual([(c['sources'], c['cls']) for c in cs],
                         [(['ga'], 'stamp'), (['qb'], 'redaction'), (['ga', 'qb'], None)])

    def test_low_iou_not_paired(self):
        cs = S.candidates([('ga', draft(mk('stamp', [0.0, 0.0, 0.2, 0.2]))),
                           ('qb', draft(mk('stamp', [0.15, 0.15, 0.35, 0.35])))])
        self.assertEqual(len(cs), 2)

    def test_consensus(self):
        got = [('ga', draft(mk('stamp', [0.1, 0.1, 0.3, 0.2]), mk('annotation', [0.4, 0.4, 0.6, 0.5]),
                            mk('other', [0.8, 0.8, 0.9, 0.9]))),
               ('qb', draft(mk('stamp', [0.1, 0.1, 0.3, 0.21]), mk('marginal_note', [0.4, 0.4, 0.6, 0.5])))]
        agreed, single = S.consensus(got)
        self.assertEqual([c['cls'] for c in agreed], ['stamp'])
        self.assertEqual(len(single), 2)


class Yolo(unittest.TestCase):
    def test_line(self):
        self.assertEqual(S.yolo_line('stamp', [0.1, 0.2, 0.3, 0.6]), '2 0.200000 0.400000 0.200000 0.400000')
        self.assertEqual(S.yolo_line('other', [0, 0, 1, 1]).split()[0], str(M.CLASSES.index('other')))

    def test_export(self):
        key = {'order': ['p1', 'p2'], 'pages': {
            'p1': {'candidates': [{'box': [0.1, 0.1, 0.3, 0.2]}, {'box': [0.5, 0.5, 0.6, 0.6]}]},
            'p2': {'candidates': [{'box': [0.1, 0.1, 0.3, 0.2]}]}}}
        answers = {'p1': {'band': 'few', 'note': '', 'candidates': {
            '1': {'keep': True, 'cls': 'annotation', 'overlaps': True, 'text': 'yes'},
            '2': {'keep': False, 'cls': None, 'overlaps': False, 'text': ''}},
            'added': [{'box': [0.0, 0.9, 0.5, 1.0], 'cls': 'signature_initials', 'overlaps': False, 'text': ''}]},
            'p2': {'band': None, 'candidates': {'1': {'keep': True, 'cls': 'stamp'}}, 'added': []}}
        with tempfile.TemporaryDirectory() as t:
            out = Path(t)
            got = S.export_yolo(answers, key, out)
            self.assertEqual(got, dict(pages=1, boxes=2, unfinished=1))
            self.assertEqual((out / 'p1.txt').read_text().splitlines(),
                             ['0 0.200000 0.150000 0.200000 0.100000', '3 0.250000 0.950000 0.500000 0.100000'])
            self.assertFalse((out / 'p2.txt').exists())
            self.assertEqual((out / 'classes.txt').read_text().split(), list(M.CLASSES))
            truth = json.loads((out / 'marks.json').read_text())
            self.assertEqual(truth['pages']['p1']['band'], 'under_10_words')
            self.assertEqual(truth['unfinished'], ['p2'])

    def test_kept_without_class_is_unfinished(self):
        key = {'pages': {'p': {'candidates': [{'box': [0, 0, 1, 1]}]}}}
        a = {'p': {'band': 'none', 'candidates': {'1': {'keep': True, 'cls': None}}, 'added': []}}
        with tempfile.TemporaryDirectory() as t:
            self.assertEqual(S.export_yolo(a, key, Path(t))['unfinished'], 1)


class Build(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        (root / 'img').mkdir()
        rows = []
        for i in range(6):
            pid = f'Dean-{i:04d}'
            (root / 'img' / (pid + '.jpg')).write_bytes(b'\xff\xd8synthetic' + bytes([i]))
            rows.append(dict(id=pid, collection='Dean', phase='AB'[i % 2], stratum=f'B:30_plus_words:Dean' if i % 2
                             else 'A:Dean', amount='30_plus_words' if i % 2 else 'signature_initials_date',
                             core=i < 4))
        self.rows, self.root = rows, root
        self.drafts = {'gemini3.7-flash-gw': {r['id']: draft(mk('stamp', [0.1, 0.1, 0.3, 0.2], 'RECEIVED'))
                                              for r in rows},
                       'qwen3-vl-8b-mlx4': {r['id']: draft(mk('annotation', [0.11, 0.1, 0.3, 0.2], '</script>x'),
                                                           mk('other', [0.7, 0.7, 0.8, 0.8])) for r in rows}}
        self.patches = [mock.patch.object(M, 'selection', lambda: {'rows': self.rows}),
                        mock.patch.object(M, 'image_path', lambda pid: root / 'img' / (pid + '.jpg')),
                        mock.patch.object(M, 'gemini_draft', lambda pid: self.drafts['gemini3.7-flash-gw'].get(pid)),
                        mock.patch.object(M, 'local_draft', lambda pid: self.drafts['qwen3-vl-8b-mlx4'].get(pid))]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.tmp.cleanup()

    def test_build(self):
        out = self.root / 'sheet'
        got = S.build(out)
        self.assertEqual(got['pages'], 4)
        self.assertEqual(got['candidates'], 8)
        self.assertEqual(got['minutes'], 40)
        html = (out / 'index.html').read_text()
        key = json.loads((out / 'key.json').read_text())
        for word in ('gemini', 'qwen', 'mlx', 'flash'):
            self.assertNotIn(word, html.lower())
        self.assertIsNone(re.search(r'\blocal\b', html, re.I))    # localStorage is the only 'local'
        for s in ('A:Dean', 'B:30_plus_words', '30_plus_words', 'signature_initials_date', 'stratum', 'preflag',
                  'sources', '"phase"'):
            self.assertNotIn(s, html)
        self.assertNotIn('</script>x', html)                      # model text cannot close the script
        self.assertIn('w46-marks-core', html)
        self.assertIn('marks-core-answers.json', html)
        # the order is the seeded shuffle, the same on a rebuild, and the key holds what the sheet hides
        S.build(self.root / 'again')
        self.assertEqual(key['order'], json.loads((self.root / 'again' / 'key.json').read_text())['order'])
        self.assertEqual(sorted(key['order']), [f'Dean-{i:04d}' for i in range(4)])
        p = key['pages']['Dean-0001']
        self.assertEqual((p['stratum'], p['preflag'], p['phase']), ('B:30_plus_words:Dean', '30_plus_words', 'B'))
        self.assertEqual(p['drafted'], ['gemini3.7-flash-gw', 'qwen3-vl-8b-mlx4'])
        self.assertEqual([c['sources'] for c in p['candidates']], [['gemini3.7-flash-gw', 'qwen3-vl-8b-mlx4'],
                                                                   ['qwen3-vl-8b-mlx4']])
        self.assertEqual((out / 'pages' / 'Dean-0002.jpg').read_bytes(), b'\xff\xd8synthetic\x02')

    def test_refuses_undrafted_core_page(self):
        self.drafts['gemini3.7-flash-gw']['Dean-0002'] = None
        self.drafts['qwen3-vl-8b-mlx4']['Dean-0002'] = {'draft': None, 'problems': ['bad json']}
        with self.assertRaises(SystemExit):
            S.build(self.root / 'sheet')
        self.assertFalse((self.root / 'sheet' / 'index.html').exists())

    def test_both_routes_required_unless_partial(self):
        self.drafts['qwen3-vl-8b-mlx4']['Dean-0002'] = None
        with self.assertRaises(SystemExit):
            S.build(self.root / 'sheet')
        self.assertEqual(S.build(self.root / 'sheet', partial=True)['pages'], 4)

    def test_read_but_failed_route_goes_on_recorded(self):
        # the route read the page and hit its cap: a measured failure, built with the other family's boxes
        self.drafts['qwen3-vl-8b-mlx4']['Dean-0002'] = {'draft': None, 'problems': ['bad json'], 'finish': 'length'}
        got = S.build(self.root / 'sheet')
        self.assertEqual((got['pages'], got['failed']), (4, {'Dean-0002': ['qwen3-vl-8b-mlx4']}))
        p = json.loads((self.root / 'sheet' / 'key.json').read_text())['pages']['Dean-0002']
        self.assertEqual((p['drafted'], p['failed']), (['gemini3.7-flash-gw'], ['qwen3-vl-8b-mlx4']))
        self.assertEqual(json.loads((self.root / 'sheet' / 'key.json').read_text())['pages']['Dean-0001']['failed'], [])

    def test_drafts_export(self):
        self.drafts['qwen3-vl-8b-mlx4']['Dean-0005'] = None
        out = self.root / 'drafts'
        got = S.export_yolo_drafts(out)
        self.assertEqual(got['pages'], 1)                         # Dean-0004; Dean-0005 lacks a draft
        self.assertEqual(got['skipped'], 1)
        man = json.loads((out / 'manifest.json').read_text())
        self.assertFalse(man['truth'])
        self.assertIn('NOT TRUTH', man['note'])
        self.assertEqual((out / 'Dean-0004.txt').read_text(), '')  # stamp vs annotation: no agreed mark


if __name__ == '__main__':
    unittest.main()
