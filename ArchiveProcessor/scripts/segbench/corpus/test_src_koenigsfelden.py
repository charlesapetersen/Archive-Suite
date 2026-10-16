"""Offline tests for src_koenigsfelden: truth() and the PAGE -> JPEG listing, on a synthetic fixture."""
import io
import unittest
import zipfile

import src_koenigsfelden as s

NS = 'http://schema.primaresearch.org/PAGE/gts/pagecontent/2013-07-15'


def page(image: str, regions: list[list[str]]) -> bytes:
    body = []
    for i, lines in enumerate(regions):
        ls = ''.join(f'<TextLine id="l{i}{j}" custom="abbrev {{offset:0; length:2;expansion:Omnibus;}}">'
                     f'<Coords points="0,0"/><TextEquiv><Unicode>{t}</Unicode></TextEquiv></TextLine>'
                     for j, t in enumerate(lines))
        body.append(f'<TextRegion id="r{i}"><Coords points="0,0"/>{ls}</TextRegion>')
    order = ''.join(f'<RegionRefIndexed index="{i}" regionRef="r{i}"/>' for i in reversed(range(len(regions))))
    return (f'<?xml version="1.0" encoding="UTF-8"?><PcGts xmlns="{NS}"><Page imageFilename="{image}" '
            f'imageWidth="10" imageHeight="10"><ReadingOrder><OrderedGroup id="g">{order}</OrderedGroup>'
            f'</ReadingOrder>{"".join(body)}</Page></PcGts>').encode()


class Truth(unittest.TestCase):
    def test_keeps_marks_and_orders_regions(self):
        xml = page('U-17_0001_r.jpg', [['Om̄ib; ✳ p̄sentes lr̄as ¬', 'inspecturis ✳'], ['Nͦ ✳ 12']])
        self.assertEqual(s.truth(xml), 'Om̄ib; ✳ p̄sentes lr̄as ¬\ninspecturis ✳\n\nNͦ ✳ 12')

    def test_expansions_in_custom_are_not_read(self):
        self.assertNotIn('Omnibus', s.truth(page('x.jpg', [['Om̄ib;']])))

    def test_empty_page(self):
        self.assertEqual(s.truth(page('x.jpg', [])), '')


class Listing(unittest.TestCase):
    def setUp(self):
        names = ['Digitalisate_JPG/U-17_0001_r.jpg', 'Digitalisate_JPG/U-17_0001_v.jpg',
                 'Digitalisate_JPG/U-17_0552_r.jpg', 'Digitalisate_JPG/U-17_0977_r.jpg',
                 'Digitalisate_JPG/.DS_Store']
        self.index = s.image_index(names)
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, 'w') as z:
            root = 'exports/job/1/'
            z.writestr(root + 'u-17_0001/page/U-17_0001_r.xml', page('U-17_0001_r.jpg', [['a']]))
            z.writestr(root + 'u-17_0001/page/U-17_0001_v.xml', page('U-17_0001_v.TIF', [['b']]))
            z.writestr(root + 'u-17_0001/page/U-17_0001_s01.xml', page('U-17_0001_s01.jpg', [['no image']]))
            z.writestr(root + 'u-17_0552/page/0552_r.xml', page('0552_r.jpg', [['c']]))
            z.writestr(root + 'u-17_0002/page/U-17_0002_r.xml', page('U-17_0002_r.jpg', []))
            z.writestr(root + 'u-17_0977/page/U-17_0977_r.xml', page('U-17_0977_r.jpg', [['late']]))
            z.writestr(root + 'u-17_0001/metadata.xml', '<x/>')
        self.zip = zipfile.ZipFile(io.BytesIO(buf.getvalue()))

    def test_tif_and_bare_stems_match(self):
        self.assertEqual(s.match_image('U-17_0001_v.TIF', 'u-17_0001', self.index),
                         'Digitalisate_JPG/U-17_0001_v.jpg')
        self.assertEqual(s.match_image('0552_r.jpg', 'u-17_0552', self.index),
                         'Digitalisate_JPG/U-17_0552_r.jpg')
        self.assertIsNone(s.match_image('saa-0428_001r.jpg', 'AA_0428', self.index))

    def test_list_drops_unmatched_empty_and_late(self):
        rows = list(s.list_pages(self.zip, self.index, {'u-17_0001': '1312', 'u-17_0977': '1628'}))
        self.assertEqual([(d, img.rsplit('/', 1)[-1], era) for d, _, img, era in rows],
                         [('u-17_0001', 'U-17_0001_r.jpg', '1312'), ('u-17_0001', 'U-17_0001_v.jpg', '1312'),
                          ('u-17_0552', 'U-17_0552_r.jpg', '1308-1662')])

    def test_tei_dates(self):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, 'w') as z:
            z.writestr('all_teis/U-17_0001.xml', '<TEI><origDate calendar="Julian" when="1312-01-27"/></TEI>')
            z.writestr('__MACOSX/all_teis/._U-17_0001.xml', 'junk')
            z.writestr('all_teis/U-17_0003.xml', '<TEI/>')
        self.assertEqual(s.tei_dates(zipfile.ZipFile(io.BytesIO(buf.getvalue()))), {'u-17_0001': '1312'})


if __name__ == '__main__':
    unittest.main()
