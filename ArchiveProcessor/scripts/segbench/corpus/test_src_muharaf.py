"""Offline tests for src_muharaf: truth() on a synthetic PAGE-XML with nested reading-order records, the
collection rule, and the listing."""
import unittest
from unittest import mock

import common
import src_muharaf as s

PAGE = '''<?xml version="1.0" ?>
<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15"><Metadata>
<MetadataItem type="other" value="transcription_QA:Someone"/></Metadata>
<Page imageFilename="X_01.JPG" imageWidth="100" imageHeight="100"><ReadingOrder>
<OrderedGroup id="g">
  <OrderedGroupIndexed caption="record_1" id="r1" index="1">
    <RegionRefIndexed regionRef="region_2" index="0"/>
  </OrderedGroupIndexed>
  <OrderedGroupIndexed caption="record_0" id="r0" index="0">
    <RegionRefIndexed regionRef="region_0" index="1"/>
    <RegionRefIndexed regionRef="region_g" index="0"/>
  </OrderedGroupIndexed>
</OrderedGroup></ReadingOrder>
<TextRegion id="region_0" type="floating"><Coords points="0,0 1,1"/>
  <TextLine id="line_0" index="0"><Coords points="0,0"/><TextEquiv><Unicode>في ٦ تموز ١٩٠٨</Unicode></TextEquiv></TextLine>
</TextRegion>
<GraphicRegion id="region_g" type="other"><Coords points="0,0"/></GraphicRegion>
<TextRegion id="region_2" type="paragraph"><Coords points="0,0"/>
  <TextLine id="line_1"><TextEquiv><Unicode>اخي الامين </Unicode></TextEquiv></TextLine>
  <TextLine id="line_2"><TextEquiv><Unicode>الاهمال جريمةً\t\tعليَّ__هنا</Unicode></TextEquiv></TextLine>
  <TextLine id="line_3"><TextEquiv><Unicode></Unicode></TextEquiv></TextLine>
</TextRegion>
<TextRegion id="region_9" type="marginalia"><TextLine id="line_9"><TextEquiv><Unicode>هامش</Unicode></TextEquiv></TextLine></TextRegion>
</Page></PcGts>'''.encode()

NAMES = ['public/AR56_01_064.JPG', 'public/AR56_01_064.xml', 'public/AR56_01_064.json',
         'public/AR56_01_064_tagged.json', 'public/AR56_01_064_annotate_carlos.json',
         'public/KJoseph19040819_01.jpg', 'public/KJoseph19040819_01.xml',
         'public/Nasrallah-Al001-013f.jpg', 'public/Nasrallah-Al001-013f.xml',
         'public/EMPTY_1.jpg', 'public/EMPTY_1.xml',
         'public/NOIMG_1.xml']


class Truth(unittest.TestCase):
    def test_nested_reading_order(self):
        # record_0 (region_0) before record_1 (region_2); unlisted region_9 last; trailing space trimmed, tabs to one space, '__' kept,
        # harakat and Arabic-Indic digits kept.
        self.assertEqual(s.truth(PAGE),
                         'في ٦ تموز ١٩٠٨\n\nاخي الامين\nالاهمال جريمةً عليَّ__هنا\n\nهامش')

    def test_common_flat_sort_would_interleave(self):
        self.assertNotEqual(common.page_xml_text(PAGE).split('\n')[0], 'في ٦ تموز ١٩٠٨')

    def test_empty(self):
        self.assertEqual(s.truth(b'<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15">'
                                 b'<Page/></PcGts>'), '')


class Listing(unittest.TestCase):
    def test_collections(self):
        self.assertEqual([s.collection_of(x) for x in
                          ('AR56_01_064', 'KJoseph19040819_01', 'Nasrallah-Al001-013f', 'JoM_Kobayat_0092',
                           '2015 5-08b El-Khouri_Letter', 'kc0066_01_01_1873diary_022')],
                         ['AR56', 'KJoseph', 'Nasrallah', 'JoM', '2015 5', 'kc0066'])

    def test_pairs(self):
        got = s.list_pages(NAMES)
        self.assertEqual([p for p, _, _ in got],
                         ['AR56_01_064', 'EMPTY_1', 'KJoseph19040819_01', 'Nasrallah-Al001-013f'])
        self.assertTrue(got[0][2].endswith('.JPG'))

    def test_candidates_drop_empty(self):
        entries = {n: [8, 1, 1, 0] for n in NAMES}

        def fake_xml(page_id, member, entry):
            return b'<PcGts xmlns="x"><Page/></PcGts>' if 'EMPTY' in page_id else PAGE
        with mock.patch.object(s, '_directory', return_value=entries), mock.patch.object(s, '_xml', fake_xml):
            cs = s.candidates()
        self.assertEqual([c.collection for c in cs], ['AR56', 'KJoseph', 'Nasrallah'])
        c = cs[0]
        self.assertEqual((c.stratum, c.licence, c.script, c.contamination, c.era),
                         ('N1', 'CC-BY-NC-SA-2.0', 'Arab', 'low', '1800-2000'))
        self.assertIsInstance(c, common.Candidate)


if __name__ == '__main__':
    unittest.main()
