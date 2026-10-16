import io
import unittest
import zipfile

import src_sbb as s

NS = 'http://schema.primaresearch.org/PAGE/gts/pagecontent/2010-03-19'


def page(body: str, order: str) -> bytes:
    return (f'<?xml version="1.0" encoding="UTF-8"?><PcGts xmlns="{NS}"><Metadata><Creator>FineReader</Creator>'
            f'</Metadata><Page imageFilename="x.tif"><ReadingOrder>{order}</ReadingOrder>{body}</Page></PcGts>'
            ).encode('utf-8')


def region(rid: str, text: str, kind: str = 'paragraph') -> str:
    return (f'<TextRegion id="{rid}" type="{kind}"><Coords><Point x="1" y="1"/></Coords>'
            f'<TextEquiv><PlainText/><Unicode>{text}</Unicode></TextEquiv></TextRegion>')


# Shaped like the SBB files: an UnorderedGroup holding a plain-RegionRef group (masthead) and an OrderedGroup
# (articles, listed out of index order), one region no group names (the page number), region text with '\n'.
ORDER = ('<UnorderedGroup id="ro"><UnorderedGroup id="g1"><RegionRef regionRef="m1"/><RegionRef regionRef="m2"/>'
         '</UnorderedGroup><OrderedGroup id="g2"><RegionRefIndexed index="1" regionRef="a2"/>'
         '<RegionRefIndexed index="0" regionRef="a1"/></OrderedGroup></UnorderedGroup>')
BODY = (region('a2', 'Zweiter Artikel.') + region('pn', '- 3 -', 'page-number')
        + region('a1', 'Berlin, 3. April 1867. Die Verand-\nlung iſt geſloſſen, 1867.')
        + region('m1', 'Der Anzeiger.', 'heading') + region('m2', 'Nr. 15, 1866.', 'heading')
        + '<SeparatorRegion id="s1"><Coords><Point x="1" y="1"/></Coords></SeparatorRegion>')
XML = page(BODY, ORDER)


class T(unittest.TestCase):
    def test_truth_follows_reading_order_and_keeps_characters(self):
        self.assertEqual(s.truth(XML), 'Der Anzeiger.\n\nNr. 15, 1866.\n\n'
                         'Berlin, 3. April 1867. Die Verand-\nlung iſt geſloſſen, 1867.\n\n'
                         'Zweiter Artikel.\n\n- 3 -')

    def test_year_is_the_most_named(self):
        self.assertEqual(s.year_of(s.truth(XML)), '1867')
        self.assertEqual(s.year_of('keine Jahreszahl, 12345'), '')

    def test_listing_drops_tables_illegible_and_imageless(self):
        table = page(region('a1', 'Nachweisung 1914') + '<TableRegion id="t1"/>', '')
        illegible = page(region('a1', 'Der Krieg 1915 ' + '�' * 5), '')
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, 'w') as z:
            for name, data in [('pc-00000001.xml', XML), ('pc-00000002.xml', table),
                               ('pc-00000003.xml', illegible), ('pc-00000004.xml', XML)]:
                z.writestr(name, data)
        with zipfile.ZipFile(buf) as z:
            got = s.list_pages(z, ['00000001.tif', '00000002.tif', '00000003.tif'])
        self.assertEqual(got, [('00000001', 'pc-00000001.xml', '00000001.tif', '1867')])


if __name__ == '__main__':
    unittest.main()
