import unittest

import src_si as S


class Pages(unittest.TestCase):
    def test_asset_continuations_not_pdf_pages(self):
        raw = ('cover\fGenerated on date\nNMAAHC-0001\nImage:\nAsset 1: NMAAHC-0001\n'
               'Transcription:\nfirst [[note]]margin[[/note]]\ntranscription.si.edu | transcribe@si.edu Page 2\f'
               'Generated on date\ncontinued\ntranscription.si.edu | transcribe@si.edu Page 3\f'
               'Generated on date\nNMAAHC-0002\nTranscription:\nnext\n'
               'transcription.si.edu | transcribe@si.edu Page 4')
        self.assertEqual(S.pages(raw), {'NMAAHC-0001': 'first margin\ncontinued', 'NMAAHC-0002': 'next'})

    def test_markers_and_table_rules_are_not_truth(self):
        text = '| A | B |\n|---|---|\n| 1 | [[strikethrough]]2[[/strikethrough]] |\n[[illegible]]\n'
        self.assertEqual(S.clean(text), 'A B\n1 2\n[illegible]')
        self.assertEqual(S.clean('[[strikethrough]]x[[/\nstrikethrough]]y'), 'xy')

    def test_duplicate_asset_refused(self):
        with self.assertRaises(ValueError):
            S.pages('NMAAHC-01\nTranscription:\ntext\fNMAAHC-01\nTranscription:\nother')

    def test_real_register_editorial_and_malformed_tags(self):
        self.assertEqual(S.clean('[[left margin]]89 West[[/left margin]]'), '89 West')
        self.assertEqual(S.clean('[[[ /\nstrikethrough]]kept'), 'kept')
        self.assertEqual(S.clean('[[occupied by Capt Allen 13 Army Corp [[/note]]]]'),
                         'occupied by Capt Allen 13 Army Corp')
        self.assertEqual(S.clean('[[four columned table]]A [[Fister?]] [[/table]]'), 'A Fister?')
        self.assertEqual(S.clean('[[image of a map depicting a River and buildings]]'), '')


if __name__ == '__main__':
    unittest.main()
