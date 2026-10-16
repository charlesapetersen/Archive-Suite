#!/usr/bin/env python3
"""Tests for src_tapus.py on a synthetic fixture (no network). python3 test_src_tapus.py"""
import unittest

import src_tapus as S

PAGE = '''<?xml version="1.0" encoding="UTF-8"?>
<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15"><Page>
 <TextRegion id="r1">
  <TextLine id="a"><TextEquiv><Unicode>_Le _petit chat ~~~ ~~~ dort</Unicode></TextEquiv></TextLine>
  <TextLine id="b"><TextEquiv><Unicode>le 1^er mars   ^mm</Unicode></TextEquiv></TextLine>
  <TextLine id="c"><TextEquiv><Unicode>~~~ ~~~</Unicode></TextEquiv></TextLine>
 </TextRegion>
 <TextRegion id="r2"><TextLine id="d"><TextEquiv><Unicode>snake_case stays</Unicode></TextEquiv></TextLine></TextRegion>
</Page></PcGts>'''.encode()


class T(unittest.TestCase):
    def test_truth(self):
        self.assertEqual(S.truth(PAGE), 'Le petit chat dort\nle 1er mars mm\n\nsnake_case stays')

    def test_truth_alto(self):
        alto = b'<alto xmlns="http://www.loc.gov/standards/alto/ns-v4#"><Layout><Page><PrintSpace><TextBlock>' \
               b'<TextLine><String CONTENT="_Rue"/><String CONTENT="~~~"/></TextLine>' \
               b'<TextLine><String CONTENT="~~~"/></TextLine></TextBlock></PrintSpace></Page></Layout></alto>'
        self.assertEqual(S.truth(alto), 'Rue')

    def test_nontyped_count(self):
        self.assertEqual(S.nontyped('a ~~~ ~~~ b ~~~'), 3)

    def test_pairs(self):
        items = [{'name': n, 'contentType': 'file'} for n in
                 ['b.jpeg', 'b.xml', 'a.jpg', 'a.xml', 'c.jpg', 'd.png', 'd.xml', 'link_to_manifest.txt']]
        self.assertEqual(S.pairs(items), [('a.jpg', 'a.xml'), ('b.jpeg', 'b.xml'), ('d.png', 'd.xml')])


if __name__ == '__main__':
    unittest.main()
