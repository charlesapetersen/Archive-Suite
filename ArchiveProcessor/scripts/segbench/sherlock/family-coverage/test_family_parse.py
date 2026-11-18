#!/usr/bin/env python3
"""W46.ocr-family-coverage: family_parse on hand-written replies in each card's format.   python3 test_family_parse.py"""
from pathlib import Path
import json
import sys
import unittest

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parents[1] / 'corpus'), str(HERE.parents[1])]
import family_parse as P  # noqa: E402


class Html(unittest.TestCase):
    def test_blocks_cells_entities_and_images(self):
        raw = ('<h1>LEDGER</h1><p>Paid to J. Smith &amp; Co.<br>for coal</p>'
               '<table><tr><th>Date</th><th>Sum</th></tr><tr><td>Jan 3</td><td>$4</td></tr></table>'
               '<img src="x.png" alt="a seal"/><p>Page 2</p>')
        self.assertEqual(P.chandra(raw)[0], 'LEDGER\n\nPaid to J. Smith & Co.\nfor coal\n\nDate Sum\n\nJan 3 $4\n\nPage 2')

    def test_math_text_kept(self):
        self.assertEqual(P.html_text('<p>Area <math>\\pi r^2</math></p>'), 'Area \\pi r^2')


class Olmocr(unittest.TestCase):
    def test_front_matter_figure_and_table(self):
        raw = ('---\nprimary_language: en\nis_rotation_valid: true\nrotation_correction: 0\nis_table: false\n'
               'is_diagram: false\n---\nDear Sir,\n\n![a stamp](page_1_2_3_4.png)\n\n'
               '<table><tr><td>a</td><td>b</td></tr></table>\nYours, A.')
        self.assertEqual(P.olmocr(raw)[0], 'Dear Sir,\n\na b\n\nYours, A.')

    def test_no_front_matter_and_markdown_kept(self):
        self.assertEqual(P.olmocr('# Title\n\n*Dear* Sir')[0], '# Title\n\n*Dear* Sir')


class Review(unittest.TestCase):
    def test_olmocr_reduces_only_its_tables(self):
        raw = '---\nprimary_language: en\n---\nIf a<b then x</p>y\n\n<table><tr><td>1</td></tr></table>\nEnd'
        self.assertEqual(P.olmocr(raw)[0], 'If a<b then x</p>y\n\n1\n\nEnd')

    def test_dots_unexpected_wrapper_falls_back_to_texts(self):
        raw = json.dumps({'layout_dets': [{'bbox': [1, 2, 3, 4], 'category': 'Text', 'text': 'Kept words'}]})
        self.assertEqual(P.dots(raw)[0], 'Kept words')


class Dots(unittest.TestCase):
    def test_layout_json_in_order(self):
        raw = json.dumps([
            {'bbox': [1, 2, 3, 4], 'category': 'Page-header', 'text': 'THE TIMES'},
            {'bbox': [1, 5, 3, 9], 'category': 'Picture'},
            {'bbox': [1, 10, 3, 20], 'category': 'Text', 'text': 'First **line**'},
            {'bbox': [1, 21, 3, 30], 'category': 'Table', 'text': '<table><tr><td>1</td><td>2</td></tr></table>'}])
        text, boxes = P.dots('```json\n' + raw + '\n```')
        self.assertEqual(text, 'THE TIMES\n\nFirst **line**\n\n1 2')
        self.assertEqual([b['cls'] for b in boxes], ['Page-header', 'Picture', 'Text', 'Table'])
        self.assertEqual(boxes[0]['units'], 'dots-px')

    def test_capped_reply_keeps_complete_texts(self):
        raw = '[{"bbox": [1,2,3,4], "category": "Text", "text": "One \\"quoted\\" line"}, {"bbox": [5,6,7,8], "categ'
        self.assertEqual(P.dots(raw), ('One "quoted" line', []))


class DeepseekChurroMineru(unittest.TestCase):
    def test_deepseek_tags_removed(self):
        text, boxes = P.deepseek('<|ref|>text<|/ref|><|det|>[[10, 20, 30, 40]]<|/det|>\nHello there')
        self.assertEqual(text, 'Hello there')
        self.assertEqual(boxes[0]['units'], 'deepseek-999')
        self.assertEqual(P.deepseek('Plain text only.')[0], 'Plain text only.')

    def test_churro_matches_farmshare_results(self):
        try:
            import farmshare_results
        except ImportError as exc:  # its scoring stack (regex, rapidfuzz) is not in every Mac python
            self.skipTest(str(exc))
        for raw in ('<HistoricalDocument><Page><Header>H</Header><Body><Line>A</Line><Description>x</Description>'
                    '<Line>B</Line></Body><Footer>F</Footer></Page></HistoricalDocument>',
                    '<HistoricalDocument><Page>broken', 'not xml at all '):
            self.assertEqual(P.churro(raw)[0], farmshare_results.churro_text(raw))

    def test_mineru_blocks(self):
        blocks = [{'type': 'title', 'bbox': [0.1, 0.1, 0.9, 0.2], 'content': 'REPORT'},
                  {'type': 'image', 'bbox': [0.1, 0.3, 0.5, 0.5], 'content': None},
                  {'type': 'table', 'bbox': [0.1, 0.6, 0.9, 0.8], 'content': '<table><tr><td>x</td></tr></table>'},
                  {'type': 'text', 'bbox': [0.1, 0.8, 0.9, 0.9], 'content': 'The end.'}]
        text, boxes = P.mineru(blocks)
        self.assertEqual(text, 'REPORT\n\nx\n\nThe end.')
        self.assertEqual(len(boxes), 4)


if __name__ == '__main__':
    unittest.main()
