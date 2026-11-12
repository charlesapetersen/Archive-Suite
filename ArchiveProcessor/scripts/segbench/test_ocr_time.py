"""W46.ocr-time-like-for-like: the page draw and the cloud concurrency count, on synthetic files; no model or network.
  python3 -m unittest test_ocr_time
"""
import csv
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import ocr_time as T


class Draw(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        (root / 'images').mkdir()
        rows, n = [], 0
        for kind, clip, count in [('typewritten', '', 9), ('printed', '', 4), ('printed', 'yes', 3), ('handwritten', '', 7),
                                  ('mixed', '', 2)]:
            for _ in range(count):
                n += 1
                rows.append({'page': f'p{n:03d}', 'kind': kind, 'clippings': clip, 'status': 'done'})
        rows.append({'page': 'p081', 'kind': 'typewritten', 'clippings': '', 'status': 'done'})   # set apart
        rows.append({'page': 'p090', 'kind': 'handwritten', 'clippings': '', 'status': 'open'})   # not done
        rows.append({'page': T.WARM, 'kind': 'typewritten', 'clippings': '', 'status': 'done'})   # the warm-up
        for r in rows:
            (root / 'images' / f'{r["page"]}-original.jpg').write_bytes(b'')
        tsv = root / 'pages.tsv'
        with tsv.open('w', newline='') as f:
            w = csv.DictWriter(f, fieldnames=['page', 'kind', 'clippings', 'status'], delimiter='\t')
            w.writeheader(); w.writerows(rows)
        for k, v in {'PAGES_TSV': tsv, 'IMAGES': root / 'images'}.items():
            p = patch.object(T, k, v); p.start(); self.addCleanup(p.stop)

    def test_counts_by_kind_and_exclusions(self):
        got = T.draw()
        self.assertEqual(len(got), sum(T.DRAW.values()))
        for kind, n in T.DRAW.items():
            self.assertEqual(sum(1 for g in got if g['kind'] == kind), n)
        ids = {g['page'] for g in got}
        self.assertFalse(ids & {'p081', 'p090', T.WARM})
        self.assertEqual(len(ids), len(got))

    def test_draw_is_fixed(self):
        self.assertEqual(T.draw(), T.draw())


class InFlight(unittest.TestCase):
    def test_overlap(self):
        # three calls: 0-10, 5-8 and 20-21; the second began while the first was open
        calls = [{'t': 10, 'wall_s': 10}, {'t': 8, 'wall_s': 3}, {'t': 21, 'wall_s': 1}]
        self.assertEqual(T.in_flight(calls), [1, 2, 1])


if __name__ == '__main__':
    unittest.main()
