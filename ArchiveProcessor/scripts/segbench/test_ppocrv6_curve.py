"""Offline curve-report contracts; synthetic text only, no models or corpus access."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import ocr_ppocrv6_hands as H


class CurveReportTests(unittest.TestCase):
    def test_unread_page_cannot_shrink_the_evaluation_sample(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / 'read').mkdir()
            (d / 'read' / 'a.txt').write_text('alpha')
            with self.assertRaisesRegex(ValueError, '1 held-out readings missing'):
                H.tune_scores({'test': ['a', 'b'], 'hand': 'blackwell'}, d, {})

    def test_empty_reading_scores_zero_instead_of_disappearing(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / 'read').mkdir()
            (d / 'read' / 'a.txt').write_text('alpha')
            (d / 'read' / 'b.txt').write_text('')
            with patch.object(H, 'page_truth', return_value='alpha'), \
                    patch.object(H, 'page_text', return_value='alpha'):
                tuned, base = H.tune_scores({'test': ['a', 'b'], 'hand': 'blackwell'}, d, {'a': {}, 'b': {}})
            self.assertEqual(tuned, {'a': 100., 'b': 0.})
            self.assertEqual(base, {'a': 100., 'b': 100.})

    def test_contrasts_pair_by_page_identity_and_keep_all_conditions(self):
        tunes, per = [], {}
        for n, level in ((80, 0), (160, 20), (240, 30)):
            for device, offset in (('cpu', 0), ('mps', 1)):
                name = f'blackwell-n{n}-{device}'
                tunes.append({'name': name, 'hand': 'blackwell', 'n': n, 'device': device})
                scores = {'a': 10 + level + offset, 'b': 40 + level + offset}
                per[name] = dict(reversed(list(scores.items()))) if n == 160 else scores
        pairs = H.tune_pairs(tunes, per)
        self.assertEqual(len(pairs), 9)  # three size increments/device and three device contrasts
        at = {(p['a'], p['b']): p for p in pairs}
        for n, ref, delta in ((160, 80, 20), (240, 80, 30), (240, 160, 10)):
            for device in ('cpu', 'mps'):
                p = at[f'blackwell-n{n}-{device}', f'blackwell-n{ref}-{device}']
                self.assertEqual((p['n'], p['delta'], p['lo'], p['hi']), (2, delta, delta, delta))
        for n in (80, 160, 240):
            self.assertEqual(at[f'blackwell-n{n}-mps', f'blackwell-n{n}-cpu']['delta'], 1)

    def test_contrasts_reject_different_pages_even_at_equal_sample_size(self):
        tunes = [{'name': f'blackwell-n{n}-cpu', 'hand': 'blackwell', 'n': n, 'device': 'cpu'}
                 for n in (80, 160)]
        with self.assertRaisesRegex(ValueError, 'different held-out pages'):
            H.tune_pairs(tunes, {'blackwell-n80-cpu': {'a': 10}, 'blackwell-n160-cpu': {'b': 20}})


if __name__ == '__main__':
    unittest.main()
