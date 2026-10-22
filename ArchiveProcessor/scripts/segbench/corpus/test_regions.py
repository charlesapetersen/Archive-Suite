"""W46.ocr-regions: the crop geometry the cluster job sends (regions_cluster.py). No model, no cluster.

    python3 -m unittest test_regions
"""
import unittest

import regions_cluster as C


class Tiles(unittest.TestCase):
    def covered(self, boxes):
        return all(any(b[1] <= y <= b[3] for b in boxes) for y in [i / 200 for i in range(201)])

    def test_portrait_page_is_three_overlapping_bands(self):
        b = C.tile_boxes(1700, 2400)
        self.assertEqual(len(b), 3)
        self.assertTrue(all(x[0] == 0 and x[2] == 1 for x in b))
        self.assertEqual((b[0][1], b[-1][3]), (0, 1))
        for a, n in zip(b, b[1:]):
            self.assertGreaterEqual((a[3] - n[1]) / (a[3] - a[1]), C.TILE_OVERLAP - 1e-9)
        self.assertTrue(self.covered(b))

    def test_short_page_is_one_tile(self):
        self.assertEqual(C.tile_boxes(2000, 800), [[0.0, 0.0, 1.0, 1.0]])

    def test_wide_page_reads_down_each_column(self):
        b = C.tile_boxes(4000, 2400)
        self.assertEqual(len({x[0] for x in b}), 2)
        firsts = [x[0] for x in b]
        self.assertEqual(firsts, sorted(firsts))   # column 0's tiles all come before column 1's


class Regions(unittest.TestCase):
    def r(self, label, box):
        return {'label': label, 'box': box}

    def test_pictures_and_nested_boxes_are_dropped_order_kept(self):
        rs = [self.r('text', [0, 0.5, 1, 1]), self.r('image', [0, 0, 1, 0.4]), self.r('text', [0.1, 0.6, 0.5, 0.7]),
              self.r('doc_title', [0, 0, 1, 0.1])]
        got = C.keep_regions(rs)
        self.assertEqual([g['label'] for g in got], ['text', 'doc_title'])

    def test_degenerate_box_is_dropped(self):
        self.assertEqual(C.keep_regions([self.r('text', [0.5, 0.5, 0.5, 0.6])]), [])

    def test_pixel_box_pads_clamps_and_widens_tiny_boxes(self):
        self.assertEqual(C.pixel_box([0, 0, 1, 1], 1000, 2000, 0.01), (0, 0, 1000, 2000))
        x0, y0, x1, y1 = C.pixel_box([0.5, 0.5, 0.501, 0.501], 1000, 1000, 0)
        self.assertEqual((x1 - x0, y1 - y0), (C.MIN_SIDE, C.MIN_SIDE))
        x0, y0, x1, y1 = C.pixel_box([0.999, 0.999, 1, 1], 1000, 1000, 0)
        self.assertEqual((x1, y1, x1 - x0, y1 - y0), (1000, 1000, C.MIN_SIDE, C.MIN_SIDE))

    def test_crops_for_a_page_with_no_regions_record_is_an_error(self):
        with self.assertRaises(KeyError):
            C.crops_for('pp-doclayoutv3', {'id': 'x'}, {'pp-doclayoutv3': {}}, 100, 100)
        self.assertEqual(C.crops_for('pp-doclayoutv3', {'id': 'x'}, {'pp-doclayoutv3': {'x': []}}, 100, 100), [])


class Stitch(unittest.TestCase):
    def setUp(self):
        import regions
        self.R = regions

    def tile(self, i, x0, text):
        return {'index': i, 'box': [x0, 0, x0 + 0.5, 1], 'text': text}

    def test_overlap_lines_are_read_once(self):
        a = self.tile(0, 0, 'Dear Sir,\nI write to say\nthat the meeting is on')
        b = self.tile(1, 0, 'I write to say\nthat the meeting is on\nTuesday next.')
        self.assertEqual(self.R.stitch('tiles', [b, a]), 'Dear Sir,\nI write to say\nthat the meeting is on\nTuesday next.')

    def test_near_duplicate_counts_and_new_line_stops_the_drop(self):
        a = self.tile(0, 0, 'the Committee met at ten')
        b = self.tile(1, 0, 'the Comittee met at ten\nMinutes follow\nthe Committee met at ten')
        self.assertEqual(self.R.stitch('tiles', [a, b]), 'the Committee met at ten\nMinutes follow\nthe Committee met at ten')

    def test_a_new_column_is_not_deduplicated_against_the_last(self):
        a = self.tile(0, 0, 'same line'); b = self.tile(1, 0.5, 'same line')
        self.assertEqual(self.R.stitch('tiles', [a, b]), 'same line\nsame line')

    def test_regions_join_as_paragraphs_skipping_blanks(self):
        crops = [{'index': 1, 'box': [0, 0, 1, 1], 'text': 'body'}, {'index': 0, 'box': [0, 0, 1, 1], 'text': 'Title '},
                 {'index': 2, 'box': [0, 0, 1, 1], 'text': '  '}]
        self.assertEqual(self.R.stitch('pp-doclayoutv3', crops), 'Title\n\nbody')


class Report(unittest.TestCase):
    def setUp(self):
        import regions
        self.R = regions

    @staticmethod
    def reading(r, mode):
        return r['raw'].strip() if r.get('status') == 'ok' and r.get('finish') == 'stop' else ''

    def rec(self, i, raw, status='ok', finish='stop'):
        return {'index': i, 'box': [0, i / 4, 1, (i + 1) / 4], 'raw': raw, 'status': status, 'finish': finish,
                'usage': {'completion_tokens': 10}}

    def test_kind_groups(self):
        k = self.R.kinds_of
        self.assertEqual(k({'kind': 'printed', 'clippings': 'yes', 'tables': ''}), ['clippings'])
        self.assertEqual(k({'kind': 'printed', 'clippings': 'yes', 'tables': 'yes'}), ['clippings', 'tables'])
        self.assertEqual(k({'kind': 'handwritten', 'handwritten': ''}), ['handwritten'])
        self.assertEqual(k({'kind': 'typewritten', 'tables': 'yes'}), ['tables'])
        self.assertEqual(k({'kind': 'typewritten'}), ['typed, no table or clipping'])
        self.assertEqual(k({'kind': 'printed'}), [])

    def test_failed_crops_are_counted_and_left_out(self):
        recs = [self.rec(0, 'Title'), self.rec(1, 'loop loop', 'cap', 'length'), self.rec(2, 'body')]
        got = self.R.page_reading('doclayout_yolo', recs, 4, 'native', self.reading)
        self.assertEqual((got['text'], got['crops'], got['crops_failed'], got['completion_tokens']),
                         ('Title\n\nbody', 4, 2, 30))

    def test_no_regions_is_an_empty_reading(self):
        self.assertEqual(self.R.page_reading('pp-doclayoutv3', [], 0, 'native', self.reading)['text'], '')

    def test_a_retried_crop_uses_its_reading_not_its_error(self):
        import json, tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as t:
            d = Path(t) / 'out/glm-ocr/tiles/p001'; d.mkdir(parents=True)
            (d / '000.error.json').write_text(json.dumps(self.rec(0, '', 'error', None)))
            (d / '000.json').write_text(json.dumps(self.rec(0, 'read')))
            (d / '001.error.json').write_text(json.dumps(self.rec(1, '', 'error', None)))
            got = self.R.crop_records(Path(t), 'glm-ocr', 'tiles', 'p001')
        self.assertEqual([(r['index'], r['status']) for r in got], [(0, 'ok'), (1, 'error')])

    def test_table_shows_the_change_on_whole_page(self):
        row = lambda arm, nes: {'group': 'L4', 'route': 'glm-ocr', 'arm': arm, 'n': 80, 'ok': 80, 'nes': nes,
                                'order_edit': 0.1}
        md = self.R.tables([row('whole', 0.5), row('doclayout_yolo', 0.9), row('tiles', 0.45)], {'glm-ocr': 1.234})
        line = next(l for l in md.splitlines() if l.startswith('| glm-ocr'))
        self.assertIn('| 50.0 (80/80) | 90.0 (80/80) | – | 45.0 (80/80) | +40.0 | – | -5.0 |', line)
        self.assertIn('GPU-hours', md)


if __name__ == '__main__':
    unittest.main()
