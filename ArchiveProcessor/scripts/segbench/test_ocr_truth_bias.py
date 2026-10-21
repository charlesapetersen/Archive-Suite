"""W46.fix-ocr-truth-bias: ocr_truth_bias.py's word labels, split and sheet differences on synthetic input. Run:
uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy \
    python -m unittest test_ocr_truth_bias"""
import unittest

import ocr_truth_bias as B

PAGE = {'spans': [{'agreed': 'The uni- versity has'}, {'a': 'ap- pointed', 'b': 'appointed'},
                  {'agreed': 'an ombudsman to deal with the multitude of complaints at once.'}]}


class Labels(unittest.TestCase):
    def test_spans_and_answers(self):
        t = B.labelled_truth(PAGE, {'1': 'b'})
        self.assertEqual(t[:5], [('The', 'agreed'), ('uni-', 'agreed'), ('versity', 'agreed'), ('has', 'agreed'),
                                 ('appointed', 'adjudicated')])
        typed = B.labelled_truth(PAGE, {'1': '=named'})
        self.assertEqual(typed[4], ('named', 'adjudicated'))
        self.assertEqual(B.labelled_truth(PAGE, {'1': '='})[4], ('an', 'agreed'))   # typed as nothing


class Split(unittest.TestCase):
    def test_strict_and_joined(self):
        t = B.labelled_truth(PAGE, {'1': 'b'})
        r = B.split_page(t, 'The university has appointed an ombudsman to deal with the multitude of complaints.')
        self.assertEqual((r['agreed_n'], r['adjudicated_n']), (15, 1))
        self.assertEqual(r['agreed_read'], 11)       # "uni" and "versity" are not the word "university"
        self.assertEqual(r['agreed_joined'], 13)     # ... unless joins are forgiven; "at once" stays missing
        self.assertEqual(r['adjudicated_read'], 1)

    def test_join_forgiven(self):
        t = B.labelled_truth(PAGE, {'1': 'b'})
        r = B.split_page(t, 'The university has appointed an ombudsman to deal with the multitude of complaints at once.')
        self.assertEqual((r['agreed_read'], r['agreed_joined']), (13, 15))


class Differences(unittest.TestCase):
    def test_kinds(self):
        t = B.labelled_truth(PAGE, {'1': 'b'})
        d = B.differences(t, 'The university has apointed an ombudsman to deal with the multitude of complaint at once.')
        self.assertEqual([(x['truth'], x['qwen'], x['join']) for x in d],
                         [('uni- versity', 'university', True), ('complaints', 'complaint', False)])
        self.assertNotIn('apointed', [x['qwen'] for x in d])      # wholly inside the adjudicated span
        self.assertEqual(d[1]['before'], 'deal with the multitude of')
        self.assertEqual(d[1]['after'], 'at once.')

    def test_block(self):
        t = B.labelled_truth(PAGE, {'1': 'b'})
        d = B.differences(t, 'The uni- versity has appointed complaints at once.')
        self.assertEqual(len(d), 1)
        self.assertTrue(d[0]['block'])               # a passage of nine words left out

    def test_insertion(self):
        t = B.labelled_truth(PAGE, {'1': 'b'})
        d = B.differences(t, 'Dear Sir The uni- versity has appointed an ombudsman to deal with the multitude of '
                             'complaints at once.')
        self.assertEqual([(x['truth'], x['qwen'], x['block']) for x in d], [('', 'Dear Sir', False)])


if __name__ == '__main__':
    unittest.main()
