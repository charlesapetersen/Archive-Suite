import unittest

import src_bentham as s

# PAGE 2010, shaped like the set: one region with <Point> children, one with a points attribute, lines stored out
# of reading order, inline <gap/> and <del>, trailing spaces. Synthetic text.
XML = '''<?xml version='1.0'?>
<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2010-03-19"><Page imageFilename="071_001_001.jpg">
<TextRegion type="paragraph" id="r2"><Coords points="100,900 2000,900 2000,1500 100,1500"/>
<TextLine id="r200"><Coords points="120,1200 1900,1200 1900,1260 120,1260"/>
<TextEquiv><PlainText/><Unicode>second body line &amp; more </Unicode></TextEquiv></TextLine>
<TextLine id="r201"><Coords points="120,1000 1900,1000 1900,1060 120,1060"/>
<TextEquiv><PlainText/><Unicode>first body line re=</Unicode></TextEquiv></TextLine>
<TextLine id="r202"><Coords points="900,1100 1200,1100 1200,1130 900,1130"/>
<TextEquiv><PlainText/><Unicode>  </Unicode></TextEquiv></TextLine>
</TextRegion>
<TextRegion type="paragraph" id="r1"><Coords><Point x="1500" y="100"/><Point x="2000" y="100"/><Point x="2000" y="300"/></Coords>
<TextLine id="r100"><Coords><Point x="1500" y="150"/><Point x="2000" y="150"/><Point x="2000" y="200"/></Coords>
<TextEquiv><PlainText/><Unicode>[Head] the &lt;gap/&gt; of &lt;del&gt;it&lt;/del&gt; Law</Unicode></TextEquiv></TextLine>
</TextRegion>
</Page></PcGts>'''.encode('utf-8')


class T(unittest.TestCase):
    def test_truth_reorders_geometrically_and_cleans_markup(self):
        self.assertEqual(s.truth(XML),
                         '[Head] the [illegible] of it Law\n\nfirst body line re=\nsecond body line & more')

    def test_pick_is_seeded_sorted_and_caps_a_box(self):
        stems = [f'071_{i:03d}_001' for i in range(100)] + [f'115_{i:03d}_001' for i in range(10)] + ['README']
        a, b = s.pick(stems, n=8), s.pick(list(reversed(stems)), n=8)
        self.assertEqual(a, b)
        self.assertEqual(a, sorted(a))
        self.assertLessEqual(sum(x.startswith('071') for x in a), 2)
        self.assertNotIn('README', a)

    def test_listing_needs_an_extracted_image(self):
        got = s.list_pages(['071_001_001', '071_002_001', 'junk'], ['071_001_001.jpg', '.DS_Store', '9.txt'])
        self.assertEqual(got, [('071_001_001', '071_001_001.jpg')])
        self.assertEqual(s.box('071_001_001'), 'box071')


if __name__ == '__main__':
    unittest.main()
