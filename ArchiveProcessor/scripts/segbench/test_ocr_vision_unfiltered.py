"""Synthetic pages and answers; no corpus page, Vision run or network call."""
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import ocr_vision_unfiltered as V


def row(i, words, s='drawn', tags=()):
    return {'id': f'{s}:{i:016x}', 'set': s, 'key': f'{i:016x}', 'tags': list(tags), 'words': words}


class Tally(unittest.TestCase):
    def setUp(self):
        self.rows = [row(1, 0), row(2, 5), row(3, 300), row(4, 12, tags=['Handwritten']), row(5, 40),
                     row(6, 0, 'replaced'), row(7, 15, 'replaced')]
        self.ans = {'drawn:0000000000000001': '1', 'drawn:0000000000000002': '2', 'drawn:0000000000000003': '3',
                    'drawn:0000000000000004': '3', 'drawn:0000000000000005': '3',
                    'replaced:0000000000000006': '3', 'replaced:0000000000000007': '2', '_notes': {}}

    def test_counts_before_answers(self):
        t = V.tally(self.rows)
        self.assertEqual(t['drawn']['pages'], 5)
        self.assertEqual(t['drawn']['vision_empty']['k'], 1)
        self.assertEqual(t['drawn']['vision_under_min']['k'], 3)
        self.assertEqual(t['replaced']['vision_under_min']['k'], 2)
        self.assertNotIn('fail_on_text_page', t['drawn'])

    def test_failure_rate_is_on_pages_of_text_and_kept_apart_by_set(self):
        t = V.tally(self.rows, self.ans)
        d = t['drawn']
        self.assertEqual((d['fail_on_text_page']['k'], d['fail_on_text_page']['n']), (1, 3))   # the 12-word hand page
        self.assertEqual((d['empty_on_has_text']['k'], d['empty_on_has_text']['n']), (0, 4))
        self.assertEqual((d['under_min_no_text']['k'], d['under_min_no_text']['n']), (1, 1))
        self.assertEqual(d['fail_on_handwritten_text_page']['k'], 1)
        self.assertEqual(t['replaced']['fail_on_text_page']['k'], 1)
        self.assertEqual(d['answers'], {'no text': 1, 'a few words': 1, 'a page of text': 3})

    def test_unanswered_is_counted_not_scored(self):
        ans = dict(self.ans)
        del ans['drawn:0000000000000004']
        d = V.tally(self.rows, ans)['drawn']
        self.assertEqual(d['answers']['unanswered'], 1)
        self.assertEqual(d['fail_on_text_page']['n'], 2)


class Turns(unittest.TestCase):
    def test_clear_wins_and_eye_overrides(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(V, 'OUT', Path(tmp)):
            (Path(tmp) / 'orient.tsv').write_text(
                '/x/aaaa.jpg\t10\t500\t20\t30\n'      # clear: turn 90
                '/x/bbbb.jpg\t0\t17\t0\t12\n'         # not clear: left as stored
                '/x/cccc.jpg\t900\t10\t600\t5\n'      # upright
                '/x/dddd.jpg\t5\t5\t300\t5\n')        # clear 180, overridden to upright by eye
            (Path(tmp) / 'orient-eye.tsv').write_text('# a comment line\nbbbb\t90\ndddd\t0\n')
            self.assertEqual(V.turns(), {'aaaa': 90, 'bbbb': 90})


if __name__ == '__main__':
    unittest.main()
