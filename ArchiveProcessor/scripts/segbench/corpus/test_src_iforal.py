#!/usr/bin/env python3
"""Tests for src_iforal.py on a synthetic fixture (no network). python3 test_src_iforal.py"""
import unittest

import src_iforal as S

PAGE = '''<?xml version='1.0' encoding='utf-8'?>
<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15"><Page imageFilename="1.jpg">
 <TextRegion id="r1"><Coords points="1,1 2,2"/>
  <TextLine id="a"><Baseline points="1,1 2,2"/><TextEquiv><Unicode>in nomine ⁊ filii</Unicode></TextEquiv></TextLine>
  <TextLine id="b"><TextEquiv><Unicode>q&#772; dixit</Unicode></TextEquiv></TextLine>
  <TextLine id="c"><TextEquiv><Unicode></Unicode></TextEquiv></TextLine></TextRegion>
 <TextRegion id="r2"><TextLine id="d"><TextEquiv><Unicode>alia</Unicode></TextEquiv></TextLine></TextRegion>
</Page></PcGts>'''.encode()


class T(unittest.TestCase):
    def test_truth(self):
        self.assertEqual(S.truth(PAGE), 'in nomine ⁊ filii\nq̄ dixit\n\nalia')

    def test_empty_page(self):
        self.assertEqual(S.truth(b'<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15"><Page/></PcGts>'), '')

    def test_era(self):
        self.assertEqual(S.era_of('foral_de_castreicao_1222'), '1222')

    def test_pairs_numeric_order(self):
        items = [{'name': n, 'contentType': 'file'} for n in ['10.jpg', '10.xml', '2.jpg', '2.xml', '3.jpg']]
        self.assertEqual(S.pairs(items), [('2.jpg', '2.xml'), ('10.jpg', '10.xml')])


if __name__ == '__main__':
    unittest.main()
