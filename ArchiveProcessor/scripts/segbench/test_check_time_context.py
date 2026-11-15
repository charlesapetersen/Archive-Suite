"""W46.seg-check-context: timing packs contain actual neighbours, never cross a box, and rotate every page."""
import contextlib
import io
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import check_time as C


class ContextPackTest(unittest.TestCase):
    def test_edges_interior_and_box_identity(self):
        with TemporaryDirectory() as scratch:
            root = Path(scratch)
            results = root / 'results'
            results.mkdir()
            (results / 'seg-magazine-rule-app.json').write_text('{"level": 0.965}')
            out = root / 'out'
            pages = {}
            for box in ('A', 'B'):
                source = root / box
                source.mkdir()
                pages[box] = []
                for i in range(9):
                    path = source / f'{i + 1}.jpg'
                    path.write_bytes(f'{box}-{i + 1}'.encode())
                    pages[box].append(SimpleNamespace(n=i + 1, path=path))

            def flagged(box, _):
                return SimpleNamespace(pages=pages[box]), [
                    (i, 'new', .5, 'hidden cue', 'new', False) for i in (0, 4, 7)]

            def orient(paths):
                # Stand-in for Vision: clear clockwise rotation on every page, no ambiguous calls.
                (out / 'orient-scores.json').write_text(json.dumps({p: [0, 30, 0, 0] for p in paths}))
                return {p: 90 for p in paths}

            with patch.multiple(C, OUT=out, PAGES=out / 'pages', PACK=out / 'pack.json',
                                TRUTH=out / 'truth.json', RESULTS=results, BOXES=('A', 'B')), \
                    patch.object(C, 'flagged', flagged), patch.object(C, 'orient', orient), \
                    contextlib.redirect_stdout(io.StringIO()):
                C.cmd_pack(None)
            pack = json.loads((out / 'pack.json').read_text())
            self.assertEqual(pack['context_pages_each_side'], 3)
            self.assertEqual(len(pack['items']), 6)
            for box, items in zip(('A', 'B'), (pack['items'][:3], pack['items'][3:])):
                for item, indices in zip(items, ([0, 1, 2, 3], [2, 3, 4, 5, 6, 7], [5, 6, 7, 8])):
                    self.assertEqual([p['index'] for p in item['context_pages']], indices)
                    by_index = {p['index']: p for p in item['context_pages']}
                    self.assertEqual(by_index[item['gap_index']]['path'], item['left'])
                    self.assertEqual(by_index[item['gap_index'] + 1]['path'], item['right'])
                    for p in item['context_pages']:
                        self.assertEqual(Path(p['path']).read_bytes(), f"{box}-{p['index'] + 1}".encode())
                        self.assertEqual(p['rotation'], 90)


if __name__ == '__main__':
    unittest.main()
