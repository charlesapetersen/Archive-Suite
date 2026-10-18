import unittest

import common
import src_devanagari as D


class Pages(unittest.TestCase):
    def test_only_full_page_pairs(self):
        self.assertEqual(D.pairs(['book/alto/01.xml', 'book/01.jpg', 'book/alto/02.xml',
                                  'book/mets.xml', 'book/metadata.xml', 'book/metadata.jpg',
                                  'other/page/03.xml', 'other/03.jpg']),
                         [('book/alto/01.xml', 'book/01.jpg'), ('other/page/03.xml', 'other/03.jpg')])

    def test_original_script_and_block_order(self):
        xml = '<alto><TextBlock><TextLine><String CONTENT="श्री"/><String CONTENT="राम"/></TextLine></TextBlock><TextBlock><TextLine><String CONTENT="२"/></TextLine></TextBlock></alto>'
        self.assertEqual(common.alto_text(xml.encode()), 'श्री राम\n\n२')

    def test_page_variant(self):
        xml = '<PcGts><Page><TextRegion><TextLine><TextEquiv><Unicode>श्री राम</Unicode></TextEquiv></TextLine></TextRegion></Page></PcGts>'
        self.assertEqual(D.truth(xml.encode()), 'श्री राम')


if __name__ == '__main__':
    unittest.main()
