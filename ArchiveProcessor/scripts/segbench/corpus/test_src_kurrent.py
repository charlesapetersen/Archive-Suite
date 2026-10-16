import unittest

import src_kurrent as s

XML = '''<?xml version="1.0" encoding="UTF-8"?>
<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2013-07-15"><Page imageFilename="x.png">
<ReadingOrder><OrderedGroup id="g"><RegionRefIndexed index="0" regionRef="r1"/><RegionRefIndexed index="1" regionRef="r2"/></OrderedGroup></ReadingOrder>
<TextRegion id="r2"><TextLine id="l3"><TextEquiv><Unicode>Schluss</Unicode></TextEquiv></TextLine></TextRegion>
<TextRegion id="r1"><TextLine id="l1"><TextEquiv><Unicode>ein ſtarker Wind</Unicode></TextEquiv></TextLine>
<TextLine id="l2"><TextEquiv><Unicode>u. kalt</Unicode></TextEquiv></TextLine></TextRegion>
</Page></PcGts>'''.encode('utf-8')

NAMES = [
    'data/README.md',
    'data/pages/HufelandOtto/pngAndXml/p11.png', 'data/pages/HufelandOtto/pngAndXml/p11.xml',
    'data/pages/HufelandOtto/annotatedJpeg/p11.jpeg',
    'data/pages/Senatsprotokolle/pageAndXml/UAT_1.png', 'data/pages/Senatsprotokolle/pageAndXml/UAT_1.xml',
    'data/pages/Senatsprotokolle/pageAndXml/UAT_2.png',
    'data/lines/TestSet/a_tl_1.png', 'data/lines/TestSet/a_tl_1.xml',
    '__MACOSX/data/pages/HufelandOtto/pngAndXml/._p11.png',
    'data/pages/HufelandOtto/pngAndXml/.DS_Store',
]


class T(unittest.TestCase):
    def test_truth_keeps_source_characters_and_order(self):
        self.assertEqual(s.truth(XML), 'ein ſtarker Wind\nu. kalt\n\nSchluss')

    def test_listing_pairs_only(self):
        got = s.list_pages(NAMES)
        self.assertEqual([(c, st) for c, st, _, _ in got], [('HufelandOtto', 'p11'), ('Senatsprotokolle', 'UAT_1')])
        self.assertTrue(got[0][2].endswith('p11.png') and got[0][3].endswith('p11.xml'))


if __name__ == '__main__':
    unittest.main()
