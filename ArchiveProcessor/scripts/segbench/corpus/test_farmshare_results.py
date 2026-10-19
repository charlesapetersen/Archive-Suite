import unittest

from farmshare_results import churro_text, join_lines, reading


class Extraction(unittest.TestCase):
    def test_xml_excludes_metadata_and_deleted_or_described_content(self):
        raw = ('<HistoricalDocument xmlns="urn:test"><Metadata><Language>German</Language></Metadata>'
               '<Page><Header>H</Header><Body><Line>A<Deletion>wrong</Deletion></Line>'
               '<Description>not text</Description><Line>B</Line></Body><Footer>F</Footer></Page>'
               '</HistoricalDocument>')
        self.assertEqual(churro_text(raw), 'H\nA\nB\nF')

    def test_malformed_xml_and_capped_text_are_failures(self):
        self.assertEqual(churro_text('<HistoricalDocument><Page>broken'), '')
        self.assertEqual(reading({'status': 'cap', 'finish': 'length', 'raw': 'partial'}, 'qari'), '')

    def test_line_order_is_numeric_and_one_missing_line_fails_page(self):
        records = {str(i): {'page': 'p', 'line': i, 'raw': str(i), 'status': 'ok', 'finish': 'stop'}
                   for i in [3, 1, 2]}
        self.assertEqual(join_lines(records, {'p': 3}), {'p': '1\n2\n3'})
        del records['2']
        self.assertEqual(join_lines(records, {'p': 3}), {'p': ''})

    def test_one_capped_line_fails_page_and_duplicate_ordinals_are_refused(self):
        r = {'page': 'p', 'line': 1, 'raw': 'partial', 'status': 'cap', 'finish': 'length'}
        self.assertEqual(join_lines({'a': r}, {'p': 1}), {'p': ''})
        with self.assertRaises(ValueError):
            join_lines({'a': r, 'b': r}, {'p': 1})


if __name__ == '__main__':
    unittest.main()
