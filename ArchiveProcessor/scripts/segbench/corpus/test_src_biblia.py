"""Offline tests for src_biblia: truth() on a synthetic ALTO 4.2 page, the catalogue parse, and the listing."""
import unittest
from unittest import mock

import common
import src_biblia as s

ALTO = '''<?xml version="1.0" encoding="UTF-8"?>
<alto xmlns="http://www.loc.gov/standards/alto/ns-v4#"><Description><sourceImageInformation>
<fileName>btv1bX.jpg</fileName></sourceImageInformation></Description><Tags>
<OtherTag ID="BT2" LABEL="Main"/><OtherTag ID="BT3" LABEL="Commentary"/></Tags><Layout><Page><PrintSpace>
<TextBlock ID="b1" TAGREFS="BT2"><TextLine ID="l1"><String CONTENT="בְּרֵאשִׁית ברא אלהים"/></TextLine>
<TextLine ID="l2"><String CONTENT="את השמים ואת"/></TextLine></TextBlock>
<TextBlock ID="b2" TAGREFS="BT3"><TextLine ID="l3"><String CONTENT="ל׳ זעירא"/></TextLine>
<TextLine ID="l4"><String CONTENT=""/></TextLine></TextBlock>
<TextBlock ID="b3" TAGREFS="BT2"/></PrintSpace></Page></Layout></alto>'''.encode()

CATALOGUE = ('filename\tscript_type\tlibrary\tShelfmark\tDate\tBiblical_or_Rabbinic\tcolor_or_grayscale\t'
             'iiif_manifest\tlink2img\ttest/train\t\n'
             'Vat.ebr.9_0011.xml\tItalian\tBAV\tVat.ebr.9\t1287\tBiblical\tcolor\thttps://x/m\thttps://x/i\ttrain\t\n'
             'btv1bA.xml\tSephardi\tBnF\tBnF héb. 11\t\tBiblical\tcolor\t\t\ttrain\t\n'
             'btv1bB.xml\tAshkenazy\tBnF\tBnF héb. 2\t1286\tRabbinic\tgrayscale\t\t\ttest\t\n')

R = 'BiblIA_dataset/'
NAMES = [R + 'catalogue.txt', R + 'README.txt',
         R + 'Sephardi/btv1bA.xml', R + 'Sephardi/btv1bA.jpg',
         R + 'Ashkenazy/btv1bB.xml', R + 'Ashkenazy/btv1bB.jpg',
         R + 'Ashkenazy/btv1bE.xml', R + 'Ashkenazy/btv1bE.jpg',     # empty transcription
         R + 'Italian/Vat.ebr.9_0011.xml']                          # BAV: IIIF only


class Truth(unittest.TestCase):
    def test_blocks_lines_points_kept(self):
        self.assertEqual(s.truth(ALTO), 'בְּרֵאשִׁית ברא אלהים\nאת השמים ואת\n\nל׳ זעירא')

    def test_clean_line(self):
        self.assertEqual(s.clean_line("ואת הקרב ואת [הכר']"), 'ואת הקרב ואת')     # line-end filler
        self.assertEqual(s.clean_line('ויחבר את חמש היר[י]עת'), 'ויחבר את חמש היריעת')   # added letter
        self.assertEqual(s.clean_line('חז(ה)אל למלך על'), 'חזאל למלך על')           # cancelled letter
        self.assertEqual(s.clean_line('אח[ר](ל)י אדני לפני [הנ/]'), 'אחרי אדני לפני')
        self.assertEqual(s.clean_line('[מפנק] מנער עבדו'), 'מפנק מנער עבדו')         # added word, line start
        self.assertEqual(s.clean_line('[/]'), '')
        self.assertEqual(s.clean_line('ואת [א/] הכרעים'), 'ואת הכרעים')             # mid-line filler
        self.assertEqual(s.clean_line("קד' ייי ˙˙ :"), "קד' ייי ˙˙ :")

    def test_filler_line_dropped_in_truth(self):
        page = ALTO.replace('את השמים ואת'.encode(), 'את השמים ואת [ה/]'.encode())
        self.assertEqual(s.truth(page).split('\n')[1], 'את השמים ואת')

    def test_empty(self):
        self.assertEqual(s.truth(b'<alto xmlns="http://www.loc.gov/standards/alto/ns-v4#"/>'), '')


class Listing(unittest.TestCase):
    def test_catalogue(self):
        cat = s.parse_catalogue(CATALOGUE)
        self.assertEqual(set(cat), {'Vat.ebr.9_0011.xml', 'btv1bA.xml', 'btv1bB.xml'})
        self.assertEqual((cat['btv1bB.xml']['Shelfmark'], cat['btv1bB.xml']['Date']), ('BnF héb. 2', '1286'))

    def test_only_pages_with_jpg(self):
        self.assertEqual([p for p, _, _ in s.list_pages(NAMES)],
                         ['Ashkenazy/btv1bB', 'Ashkenazy/btv1bE', 'Sephardi/btv1bA'])

    def test_candidates(self):
        entries = {n: [8, 1, 1, 0] for n in NAMES}

        def fake_raw(member, entry):
            if member.endswith('catalogue.txt'):
                return CATALOGUE.encode()
            return b'<alto xmlns="http://www.loc.gov/standards/alto/ns-v4#"/>' if 'btv1bE' in member else ALTO
        with mock.patch.object(s, '_directory', return_value=entries), mock.patch.object(s, '_raw', fake_raw):
            cs = s.candidates()
        self.assertEqual([c.page_id for c in cs], ['Ashkenazy/btv1bB', 'Sephardi/btv1bA'])
        b, a = cs
        self.assertEqual((b.collection, b.era), ('BnF héb. 2', '1286'))
        self.assertEqual((a.collection, a.era), ('BnF héb. 11', 'medieval'))
        self.assertIn('Ashkenazy', b.convention)
        self.assertEqual((a.stratum, a.licence, a.script, a.contamination), ('N4', 'CC-BY-NC-SA-4.0', 'Hebr', 'low'))
        self.assertTrue(a.fetch['image_member'].endswith('btv1bA.jpg'))
        self.assertIsInstance(a, common.Candidate)


if __name__ == '__main__':
    unittest.main()
