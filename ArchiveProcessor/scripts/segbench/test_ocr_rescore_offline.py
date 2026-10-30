"""W46.ocr-rescore-offline: the failure classes in ocr-pages.csv and the order-free region summary.

  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy python -m unittest test_ocr_rescore_offline
"""
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import ocr_pages_export as E      # noqa: E402
import regions_orderfree as RO    # noqa: E402


class FailureClasses(unittest.TestCase):
    def test_answered_page_has_no_failure(self):
        self.assertEqual(E.failure(True, 'length', 8192), '')

    def test_model_failures(self):
        self.assertEqual(E.failure(False, 'length', 8192), 'cap')
        self.assertEqual(E.failure(False, 'content_filter', 0), 'refusal')
        self.assertEqual(E.failure(False, 'error', 0), 'refusal')     # Gemini's 0-token refusal of reprinted text
        self.assertEqual(E.failure(False, 'error', '0'), 'refusal')   # a zero read from a CSV is still zero
        self.assertEqual(E.failure(False, 'stop', 552), 'empty')

    def test_transport_failures(self):
        self.assertEqual(E.failure(False, 'error', 408), 'transport')  # the stream broke after tokens began
        self.assertEqual(E.failure(False, 'provider-error', None), 'transport')
        self.assertEqual(E.failure(False, 'interrupted', None), 'transport')
        self.assertEqual(E.failure(False, None, None, {'error_code': 502}), 'transport')
        self.assertEqual(E.failure(False, '', 1), 'transport')

    def test_unknown_finish_is_refused(self):
        with self.assertRaises(SystemExit):
            E.failure(False, 'something-new', 5)

    def test_cluster_runs(self):
        self.assertEqual(E.farmshare_failure({'ok': 'False', 'outcome': 'cap', 'status': 'cap'}, {}), 'cap')
        self.assertEqual(E.farmshare_failure({'ok': 'False', 'outcome': 'unparsable', 'status': 'ok'}, {}), 'empty')
        self.assertEqual(E.farmshare_failure({'ok': 'False', 'status': 'unparsed'}, {}), 'empty')
        note = {'env': {'note': 'official XML prompt, 8192 token cap; caps count as failures'}}
        self.assertEqual(E.farmshare_failure({'ok': 'False'}, note), 'cap')
        with self.assertRaises(SystemExit):
            E.farmshare_failure({'ok': 'False'}, {})


class OrderFree(unittest.TestCase):
    def test_reordered_text_loses_nes_but_not_bowf1(self):
        ref = 'the first paragraph of the letter\n\nand the second one after it'
        hyp = 'and the second one after it\n\nthe first paragraph of the letter'
        s = RO.page_scores(ref, hyp, None, True)
        self.assertLess(s['nes'], 0.9)
        self.assertEqual(s['bowf1'], 1.0)
        self.assertEqual((s['missed'], s['added']), (0, 0))

    def test_summary_pairs_each_arm_with_its_own_whole_page(self):
        def row(arm, page, nes, bow, ok=True):
            return {'source': 's', 'route': 'r', 'arm': arm, 'set': 'owner99', 'page': page, 'groups': ['the 96'],
                    'ok': ok, 'nes': nes, 'nb_overall': nes, 'bowf1': bow, 'gap': bow - nes, 'words': 10,
                    'missed': 0 if ok else 10, 'added': 0}
        rows = [row('whole', 'p1', .9, .95), row('whole', 'p2', .8, .9),
                row('tiles', 'p1', .7, .95), row('tiles', 'p2', 0, 0, ok=False)]
        out = {(r['arm'], r['group']): r for r in RO.summarise(rows)}
        t = out[('tiles', 'the 96')]
        self.assertEqual((t['n'], t['ok']), (2, 1))
        self.assertAlmostEqual(t['d_nes']['delta'], -0.5)       # (-0.2 - 0.8) / 2: the failure scores 0
        self.assertAlmostEqual(t['d_bowf1']['delta'], -0.45)    # (0 - 0.9) / 2: order cost p1 nothing order-free
        self.assertEqual(t['d_bowf1_answered']['n'], 1)
        self.assertAlmostEqual(t['d_missed_rate'], 0.5)


if __name__ == '__main__':
    unittest.main()
