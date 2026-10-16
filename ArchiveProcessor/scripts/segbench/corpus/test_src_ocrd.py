#!/usr/bin/env python3
"""Tests for src_ocrd.py on a synthetic fixture (no network). python3 test_src_ocrd.py"""
import unittest

import src_ocrd as S

PAGE = '''<?xml version="1.0" encoding="UTF-8"?>
<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15"><Page imageFilename="GT-PAGE/x_0001.tif">
 <ReadingOrder><OrderedGroup id="g"><RegionRefIndexed regionRef="b" index="0"/><RegionRefIndexed regionRef="a" index="1"/></OrderedGroup></ReadingOrder>
 <TextRegion id="a" primaryLanguage="Latin">
  <TextLine id="l1"><Word id="w"><TextEquiv><Unicode>word</Unicode></TextEquiv></Word>
   <TextEquiv><Unicode>Ein ſchoͤner Tag</Unicode></TextEquiv></TextLine>
  <TextEquiv><Unicode>Ein ſchoͤner Tag</Unicode></TextEquiv></TextRegion>
 <TextRegion id="b" primaryLanguage="German">
  <TextLine id="l2"><TextEquiv><Unicode>Titel</Unicode></TextEquiv></TextLine></TextRegion>
 <TextRegion id="c" language="German"><TextEquiv><Unicode>region only</Unicode></TextEquiv></TextRegion>
</Page></PcGts>'''.encode()

REGION_ONLY = b'''<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15"><Page>
 <TextRegion id="c"><TextEquiv><Unicode>region only</Unicode></TextEquiv></TextRegion></Page></PcGts>'''


class T(unittest.TestCase):
    def test_truth_reading_order_lines_keep_long_s(self):
        self.assertEqual(S.truth(PAGE), 'Titel\n\nEin ſchoͤner Tag\n\nregion only')   # a line-less region keeps its own text)

    def test_region_only_page_dropped(self):
        self.assertEqual(S.truth(REGION_ONLY), '')

    def test_language_majority(self):
        self.assertEqual(S.language(PAGE), 'German')   # German x2 (one via `language`), Latin x1

    def test_language_falls_back_to_any_element(self):
        x = b'<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15"><Page primaryLanguage="Latin"><TextRegion id="r"/></Page></PcGts>'
        self.assertEqual(S.language(x), 'Latin')

    def test_era(self):
        self.assertEqual(S.era_of('aepinus_bekentnis_1548'), '1548')
        self.assertEqual(S.era_of('hohberg_georgica01_1682_teil1'), '1682')
        self.assertEqual(S.era_of('nodate'), '')

    def test_pairs_skip_binarised(self):
        items = [{'name': n, 'contentType': 'file'} for n in
                 ['d_0006.tif', 'd_0006.xml', 'd_0006_B.tif', 'd_0007.tif']]
        self.assertEqual(S.pairs(items), [('d_0006.tif', 'd_0006.xml')])


if __name__ == '__main__':
    unittest.main()
