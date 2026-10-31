#!/usr/bin/env python3
"""W46.ocr-new-open-boxes: boxes_parse on hand-written replies in each reader's markup.   python3 test_boxes_parse.py"""
import unittest

import boxes_parse as B


class Unlimited(unittest.TestCase):
    def test_ref_det_blocks(self):
        raw = ('<|ref|>title<|/ref|><|det|>[[100, 50, 900, 90]]<|/det|>\nMEMORANDUM\n\n'
               '<|ref|>text<|/ref|><|det|>[[100, 120, 900, 400]]<|/det|>\nTo all area offices.\nPlease read.'
               '<｜end▁of▁sentence｜>')
        text, boxes = B.unlimited(raw)
        self.assertEqual(text, 'MEMORANDUM\n\nTo all area offices.\nPlease read.')
        self.assertEqual([b['cls'] for b in boxes], ['title', 'text'])
        self.assertEqual(boxes[1]['box'], [100, 120, 900, 400])
        self.assertEqual(boxes[1]['text'], 'To all area offices.\nPlease read.')
        self.assertEqual(boxes[0]['units'], 'unlimited-999')

    def test_det_only_form_and_untagged(self):
        text, boxes = B.unlimited('<|det|>text [1, 2, 3, 4]<|/det|>Hello')
        self.assertEqual((text, boxes[0]['box'], boxes[0]['cls']), ('Hello', [1, 2, 3, 4], 'text'))
        self.assertEqual(B.unlimited('plain words'), ('plain words', []))


class Nemotron(unittest.TestCase):
    RAW = ('<x_0.1><y_0.05>Dear Sir,<x_0.9><y_0.08><class_Text>'
           '<x_0.1><y_0.1>\\begin{tabular}{ll} a & b \\\\ \\end{tabular}<x_0.9><y_0.3><class_Table>'
           '<x_0.4><y_0.95>3<x_0.6><y_0.97><class_Page-footer>')

    def test_blocks_in_order(self):
        text, boxes = B.nemotron(self.RAW)
        self.assertEqual([b['cls'] for b in boxes], ['Text', 'Table', 'Page-footer'])
        self.assertEqual(boxes[0]['box'], [0.1, 0.05, 0.9, 0.08])
        self.assertTrue(text.startswith('Dear Sir,\n\n\\begin{tabular}'))
        self.assertTrue(text.endswith('\n\n3'))

    def test_postprocess_used_and_failure_kept(self):
        def pp(body, cls, text_format, table_format):
            if cls == 'Table':
                raise ValueError('bad table')
            return body.upper()
        text, _ = B.nemotron(self.RAW, postprocess_text=pp)
        self.assertIn('DEAR SIR,', text)
        self.assertIn('\\begin{tabular}', text)

    def test_no_boxes(self):
        self.assertEqual(B.nemotron('</s><s>just text<class_Text>'), ('just text', []))


class DocTags(unittest.TestCase):
    RAW = ('<doctag><title><loc_40><loc_20><loc_460><loc_40>MEMORANDUM</title>'
           '<text><loc_40><loc_60><loc_460><loc_200>To all area offices.</text>'
           '<page_footer><loc_240><loc_480><loc_260><loc_490>3</page_footer></doctag>')

    def test_fallback_text_and_boxes(self):
        text, boxes = B.doctags(self.RAW)
        self.assertEqual(text, 'MEMORANDUM\n\nTo all area offices.\n\n3')
        self.assertEqual([b['cls'] for b in boxes], ['title', 'text', 'page_footer'])
        self.assertEqual(boxes[1]['box'], [40, 60, 460, 200])
        self.assertEqual(boxes[1]['units'], 'doctags-500')

    def test_converter_wins_for_text(self):
        text, boxes = B.doctags(self.RAW, to_markdown=lambda raw: '# MEMORANDUM\n\n\n\nTo all')
        self.assertEqual(text, '# MEMORANDUM\n\nTo all')
        self.assertEqual(len(boxes), 3)

    def test_dispatch(self):
        self.assertEqual(B.parse('doctags', self.RAW)[0], B.doctags(self.RAW)[0])


if __name__ == '__main__':
    unittest.main()
