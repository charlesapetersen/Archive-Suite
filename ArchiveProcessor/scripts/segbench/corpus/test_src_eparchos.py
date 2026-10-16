import unittest

import src_eparchos as s

# Shaped like an EPARCHOS file: line TextEquiv after Word children that are out of reading order.
XML = '''﻿<?xml version="1.0" encoding="utf-8"?>
<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2013-07-15"><Metadata><Creator>Transpro</Creator></Metadata>
<Page imageFilename="6791 (1).png" imageWidth="788" imageHeight="805"><TextRegion id="r0"><Coords points="0,0 1,1"/>
<TextLine id="r0l0"><Coords points="0,0 1,1"/>
<Word id="r0l0w2"><Coords points="0,0 1,1"/><TextEquiv><Unicode>λόγος</Unicode></TextEquiv></Word>
<Word id="r0l0w1"><Coords points="0,0 1,1"/><TextEquiv><Unicode>Ὁ</Unicode></TextEquiv></Word>
<TextEquiv><Unicode>Ὁ   λόγος ἐστί:-</Unicode></TextEquiv></TextLine>
<TextLine id="r0l1"><TextEquiv><Unicode>καὶ τὰ ἑξῆς  β´.</Unicode></TextEquiv></TextLine>
</TextRegion></Page></PcGts>'''.encode('utf-8')

NAMES = ['eparchos/image/6791 (10).png', 'eparchos/xml/6791 (10).xml', 'eparchos/image/6791 (2).png',
         'eparchos/xml/6791 (2).xml', 'eparchos/image/6791 (3).png', 'eparchos/xml/notes.txt', 'eparchos/']


class T(unittest.TestCase):
    def test_truth_uses_line_text_not_words(self):
        self.assertEqual(s.truth(XML), 'Ὁ   λόγος ἐστί:-\nκαὶ τὰ ἑξῆς  β´.')

    def test_listing_pairs_in_numeric_order(self):
        got = s.list_pages(NAMES)
        self.assertEqual([st for st, _, _ in got], ['6791 (2)', '6791 (10)'])
        self.assertEqual(got[1][1:], ('eparchos/image/6791 (10).png', 'eparchos/xml/6791 (10).xml'))


if __name__ == '__main__':
    unittest.main()
