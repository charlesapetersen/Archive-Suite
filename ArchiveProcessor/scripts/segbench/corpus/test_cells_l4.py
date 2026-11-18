#!/usr/bin/env python3
"""W46.ocr-cells-l4-more: the drafter's pick/agreement, the sheet and the fold, on a synthetic page. No network."""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cells_l4_draft as D  # noqa: E402
import cells_l4_sheet as S  # noqa: E402
import regions_cells as R  # noqa: E402

PROPOSAL = {'rotation': 0, 'table': True, 'note': 'ledger',
            'table_box': {'left': 100, 'top': 100, 'right': 900, 'bottom': 900},
            'columns': [100, 300, 500, 700, 900], 'heading': {'top': 100, 'bottom': 180},
            'rows': [180, 300, 420, 540, 660, 780, 900]}


def reply(obj):
    return {'meta': {}, 'raw': json.dumps(obj)}


class CellsL4(unittest.TestCase):
    def setUp(self):
        from PIL import Image
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Path(self.tmp.name)
        self.patches = [mock.patch.object(D, 'STORE', self.store), mock.patch.object(S, 'SHEET', self.store / 'sheet')]
        for p in self.patches:
            p.start()
        (self.store / 'images').mkdir()
        for pid in ('pA', 'pB'):
            Image.new('RGB', (600, 400), 'white').save(self.store / 'images' / f'{pid}.jpg')
        D.dump(self.store / 'draw.json', {'pages': [{'id': 'pA', 'sha256': 'a'}, {'id': 'pB', 'sha256': 'b'}]})
        D.dump(self.store / 'propose' / 'pA.json', reply(PROPOSAL))
        D.dump(self.store / 'propose' / 'pB.json', reply({'rotation': 0, 'table': False, 'note': 'prose'}))

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.tmp.cleanup()

    def read_all(self, disagree=()):
        for c in D.load(self.store / 'picked.json')['pages'][0]['cells']:
            for route in D.MODELS:
                text = f'v{c["id"]}' + ('x' if route == 'gpt' and c['id'] in disagree else '')
                D.dump(self.store / 'read' / route / 'pA' / f'{c["id"]}.json',
                       reply({'text': text, 'box': 'fits', 'medium': 'hand', 'type': 'free_text'}))

    def test_pick_is_seeded_and_inside_the_table(self):
        D.pick()
        first = D.load(self.store / 'picked.json')
        D.pick()
        self.assertEqual(first, D.load(self.store / 'picked.json'))
        self.assertEqual([p['id'] for p in first['pages']], ['pA'])
        self.assertIn('pB', first['left_out'])
        page = first['pages'][0]
        self.assertEqual([c['role'] for c in page['cells']].count('heading'), 3)
        self.assertEqual([c['role'] for c in page['cells']].count('entry'), 6)
        for c in page['cells']:
            self.assertTrue(R.box_ok(c['box']) and R.contains(page['table_box'], c['box']), c)

    def test_agreement_is_normalised_and_a_cut_box_is_disputed(self):
        D.pick()
        self.read_all()
        self.assertEqual(D.cell_state('pA', 'c01')[0], 'agreed')
        D.dump(self.store / 'read' / 'gpt' / 'pA' / 'c02.json',
               reply({'text': ' VC02 ', 'box': 'fits', 'medium': 'hand', 'type': 'free_text'}))
        self.assertEqual(D.cell_state('pA', 'c02')[0], 'agreed')
        D.dump(self.store / 'read' / 'gpt' / 'pA' / 'c03.json',
               reply({'text': 'vc03', 'box': 'cut', 'medium': 'hand', 'type': 'free_text'}))
        self.assertEqual(D.cell_state('pA', 'c03')[0], 'disputed')
        (self.store / 'read' / 'gpt' / 'pA' / 'c04.json').unlink()
        self.assertEqual(D.cell_state('pA', 'c04')[0], 'missing')

    def test_sheet_and_fold_make_a_draft_the_bank_accepts_after_freeze_checks(self):
        D.pick()
        self.read_all(disagree={'c02', 'c05'})
        S.build(no_orient=True)
        page = (self.store / 'sheet' / 'index.html').read_text()
        self.assertIn('_notes', page)
        self.assertNotIn('__', page.replace('__proto__', ''))
        key = D.load(self.store / 'sheet' / 'key.json')
        self.assertEqual(len(key['disputed']), 2)
        ctrl = key['controls'][0]['id']
        answers = {'pA/c02': '=typed', 'pA/c05': 'drop', ctrl: '1', '_notes': {'pA/c02': 'faint'}}
        f = self.store / 'answers.json'
        f.write_text(json.dumps(answers))
        with self.assertRaises(ValueError):            # every asked item needs an answer
            S.fold(f)
        for x in key['controls']:
            answers.setdefault(x['id'], 'blank')
        f.write_text(json.dumps(answers))
        draft = S.fold(f)
        cells = {c['id']: c for c in draft['pages'][0]['tables'][0]['cells']}
        self.assertEqual(cells['c02']['value'], 'typed')
        self.assertNotIn('c05', cells)
        self.assertEqual(draft['audit']['notes'], {'pA/c02': 'faint'})
        self.assertEqual(len(cells), 8)
        # The bank's validator, less the image hash (synthetic) and the capability pilot rule this bank relaxes.
        for c in cells.values():
            self.assertIn(c['role'], ('heading', 'entry'))
            self.assertIn(c['medium'], ('print', 'hand', 'unknown'))
            self.assertTrue(c['reviewed'])
            self.assertTrue(R.contains(draft['pages'][0]['tables'][0]['box'], c['box']))

    def test_cap_refuses_before_sending(self):
        D.dump(self.store / 'calls.jsonl', {})
        (self.store / 'calls.jsonl').write_text(json.dumps({'cost': D.CAP}) + '\n')
        with mock.patch.object(D.G, 'request') as req, self.assertRaises(SystemExit):
            D.call('gemini', 'k', b'x', 'p', self.store / 'out.json')
        req.assert_not_called()


if __name__ == '__main__':
    unittest.main()
