#!/usr/bin/env python3
"""Tests for src_newsbench.py on a synthetic fixture (no network). python3 test_src_newsbench.py"""
import unittest

import src_newsbench as S

CSV = '''image_name,collection,words,tier,exclude,newspaper_note
mss3413201417-17.jpg,nawsa,5464,broadsheet,,"The Liberator (1864), inner page"
mss3413201856-40.jpg,nawsa,5253,broadsheet,partial_gold,"Boston Daily Advertiser, gold is partial"
mss425490669-55.jpg,mary-church-terrell,1892,page,,"Indianapolis paper, full front page"
'''


class T(unittest.TestCase):
    def test_rows_drop_partial_gold(self):
        self.assertEqual([r['image_name'] for r in S.rows(CSV)], ['mss3413201417-17.jpg', 'mss425490669-55.jpg'])

    def test_era(self):
        self.assertEqual(S.era_of('The Liberator (1864), inner page'), '1864')
        self.assertEqual(S.era_of('Hartford Daily Courant, p.11'), '')

    def test_loc_url_only_for_nawsa(self):
        self.assertEqual(S.loc_url('mss3413201417-17.jpg'), 'https://www.loc.gov/resource/mss34132.01417/?sp=17')
        self.assertIsNone(S.loc_url('mss425490669-55.jpg'))

    def test_truth_as_is(self):
        self.assertEqual(S.truth('  line one\n\nline  two ſ\n'.encode()), 'line one\n\nline  two ſ')


if __name__ == '__main__':
    unittest.main()
