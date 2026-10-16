from pathlib import Path
import tempfile
import unittest

import src_read2017 as s

NS = 'http://schema.primaresearch.org/PAGE/gts/pagecontent/2013-07-15'

# Shaped like Train-A: one region per letter block, ReadingOrder, a bare '&' left unescaped by the source.
XML = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<PcGts xmlns="{NS}"><Metadata><Creator>htrsh_pagexml_create</Creator></Metadata>
<Page imageFilename="000001.jpg" imageWidth="1100" imageHeight="1440">
<ReadingOrder><OrderedGroup id="ro"><RegionRefIndexed index="0" regionRef="pg"/>
<RegionRefIndexed index="1" regionRef="r2"/></OrderedGroup></ReadingOrder>
<TextRegion id="r2"><TextLine id="l3"><TextEquiv><Unicode>Ihr ergebener</Unicode></TextEquiv></TextLine></TextRegion>
<TextRegion id="pg"><TextLine id="l1"><Baseline points="1,2 3,4"/><TextEquiv><Unicode>Brod & Wein, das ist gewiß</Unicode></TextEquiv></TextLine>
<TextLine id="l2"><TextEquiv><Unicode>u. so fort &amp; weiter</Unicode></TextEquiv></TextLine></TextRegion>
</Page></PcGts>'''.encode('utf-8')

# Shaped like Test-A: lines with geometry, no TextEquiv.
NO_TEXT = f'''<?xml version="1.0" encoding="UTF-8"?><PcGts xmlns="{NS}"><Page imageFilename="040001.jpg">
<TextRegion id="pg"><TextLine id="l1"><Baseline points="1,2 3,4"/></TextLine></TextRegion></Page></PcGts>'''.encode()


class T(unittest.TestCase):
    def test_truth_escapes_bare_ampersand_and_keeps_order(self):
        self.assertEqual(s.truth(XML), 'Brod & Wein, das ist gewiß\nu. so fort & weiter\n\nIhr ergebener')

    def test_listing_keeps_pages_with_text_and_image(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            for st, stem, data, img in [('Train-A', '000001', XML, True), ('Train-A', '000002', XML, False),
                                        ('Test-A', '040001', NO_TEXT, True)]:
                (root / st / 'page').mkdir(parents=True, exist_ok=True)
                (root / st / 'page' / f'{stem}.xml').write_bytes(data)
                if img:
                    (root / st / f'{stem}.jpg').write_bytes(b'\xff\xd8')
            (root / 'Train-A' / '000001.xml').write_bytes(XML)   # the duplicate copy outside page/
            got = s.list_pages(root)
            self.assertEqual([(st, stem) for st, stem, _, _ in got], [('Train-A', '000001')])
            self.assertEqual(got[0][2].name, '000001.jpg')


if __name__ == '__main__':
    unittest.main()
