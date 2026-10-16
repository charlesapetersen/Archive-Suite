"""Offline tests for src_castilian: truth() on a synthetic graphematic ALTO, and the page listing."""
import unittest
from unittest import mock

import common
import src_castilian as s

ALTO = '''<alto xmlns="http://www.loc.gov/standards/alto/ns-v4#"><Description><sourceImageInformation>
<fileName>X-1r.jpg</fileName></sourceImageInformation></Description><Layout><Page><PrintSpace>
<TextBlock ID="b1"><TextLine ID="l1"><String CONTENT="poꝛ q̃ era pobre e sus"/></TextLine>
<TextLine ID="l2"><String CONTENT="parien"/><HYP CONTENT="-"/></TextLine></TextBlock>
<TextBlock ID="b2"><TextLine ID="l3"><String CONTENT="tes ꝺe aquel"/></TextLine>
<TextLine ID="l4"><String CONTENT=""/></TextLine></TextBlock>
<TextBlock ID="b3"/></PrintSpace></Page></Layout></alto>'''.encode()


class Truth(unittest.TestCase):
    def test_blocks_lines_and_marks_kept(self):
        self.assertEqual(s.truth(ALTO), 'poꝛ q̃ era pobre e sus\nparien-\n\ntes ꝺe aquel')

    def test_empty(self):
        self.assertEqual(s.truth(b'<alto xmlns="http://www.loc.gov/standards/alto/ns-v4#"/>'), '')


R = 'data_v2/corpus/'
NAMES = [R + 'in_domain/Mad_A/Hand_A/IB-1r.xml', R + 'in_domain/Mad_A/Hand_A/IB-1r.normalized.xml',
         R + 'in_domain/Mad_A/Hand_A/IB-1r.jpg',
         R + 'in_domain/Esc_M/pg_12.xml', R + 'in_domain/Esc_M/pg_12.normalized.xml',          # no image
         R + 'in_domain/Sev_Z/3_pg.pdf.png-1_1L.normalized.xml', R + 'in_domain/Sev_Z/3_pg.pdf.png-1_1L.tif',
         R + 'out_of_domain/calila_2.normalized.xml', R + 'out_of_domain/calila_2.jpg',
         R + 'out_of_domain/regum.pdf_page_1.normalized.xml', R + 'out_of_domain/regum.pdf_page_1.png',
         R + 'out_of_domain/sem_tob_78r.normalized.xml', R + 'out_of_domain/sem_tob_78r.jpg',
         R + 'out_of_domain/Ms_2086.pdf_page_1.normalized.xml', R + 'out_of_domain/Ms_2086.pdf_page_1.png',
         R + 'out_of_domain/empty.normalized.xml', R + 'out_of_domain/empty.jpg',
         'data_v2/models/x.mlmodel']


class Listing(unittest.TestCase):
    def test_pairs_graphematic_with_image(self):
        got = s.list_pages(NAMES)
        self.assertEqual([p for p, _, _ in got],
                         ['in_domain/Mad_A/Hand_A/IB-1r', 'in_domain/Sev_Z/3_pg.pdf.png-1_1L',
                          'out_of_domain/Ms_2086.pdf_page_1', 'out_of_domain/calila_2', 'out_of_domain/empty', 'out_of_domain/regum.pdf_page_1',
                          'out_of_domain/sem_tob_78r'])
        self.assertTrue(all(x.endswith('.normalized.xml') for _, x, _ in got))
        self.assertTrue(got[1][2].endswith('.tif'))

    def test_collections(self):
        self.assertEqual([s.collection_of(x) for _, x, _ in s.list_pages(NAMES)],
                         ['Mad_A', 'Sev_Z', 'ood_Ms_2086', 'ood_calila', 'ood_empty', 'ood_regum', 'ood_sem_tob'])

    def test_candidates_drop_empty_truth(self):
        entries = {n: [8, 1, 1, 0] for n in NAMES}
        def fake_xml(page_id, member, entry):
            return b'<alto xmlns="http://www.loc.gov/standards/alto/ns-v4#"/>' if 'empty' in page_id else ALTO
        with mock.patch.object(s, '_directory', return_value=entries), mock.patch.object(s, '_xml', fake_xml):
            cs = s.candidates()
        self.assertEqual(len(cs), 6)
        self.assertNotIn('out_of_domain/empty', [c.page_id for c in cs])
        c = cs[0]
        self.assertEqual((c.stratum, c.licence, c.publish_image, c.contamination), ('L5', 'CC-BY-NC-SA-4.0', False, 'low'))
        self.assertIsInstance(c, common.Candidate)


if __name__ == '__main__':
    unittest.main()
