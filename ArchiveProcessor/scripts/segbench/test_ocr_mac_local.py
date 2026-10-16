"""W41.mac-local-measure and W41.mac-local-hw reports on synthetic scratch readings; no corpus, model or network.
Needs the scorer's packages: uv run --with rapidfuzz --with 'sacrebleu==2.5.1' python -m unittest test_ocr_mac_local
"""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import ocr_panel as P
import ocr_mac_local as M


class MacLocal(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        (root / 'truth/truth').mkdir(parents=True)
        pages = ['p001', 'p002', 'p086']  # p086 is agreement-only: never in the penalty
        for p in pages:
            (root / 'truth/truth' / (p + '.txt')).write_text('the quick brown fox')
        jobs = [{'id': p + '-original', 'page': p, 'scale': 'original'} for p in pages]
        rows = [{'page': p, 'kind': 'typewritten'} for p in pages]
        self.patches = [patch.object(P, 'CACHE', root / 'cache'), patch.object(P, 'TRUTH', root / 'truth'),
                        patch.object(P, 'RESULTS', root / 'out'), patch.object(M, 'OUT', root / 'cache/local/k'),
                        patch.object(M, 'REPORT', root / 'out/r.md'), patch.object(M, 'HW_REPORT', root / 'out/hw.md'), patch.object(M, 'GROUPS', root / 'out/ocr-mac-local-groups.csv'), patch.object(P, 'rows', return_value=rows),
                        patch.object(P, 'manifest', return_value={'jobs': jobs}),
                        patch.dict('os.environ', {'OCRLAB': str(root / 'lab')})]
        for p in self.patches:
            p.start(); self.addCleanup(p.stop)
        (root / 'out').mkdir()
        self.root = root

    def reading(self, side, page, text, **meta):
        d = (M.OUT if side == 'local' else P.CACHE / 'responses' / M.HOSTED)
        base = {'wall_s': 10, 'first_token_s': 2, 'prompt_tokens': 100, 'completion_tokens': 20, 'gen_tps': 20,
                'mlx_peak_gb': 7, 'load_s': 5, 'status': 'ok', 'finish': 'stop'}
        P.save(d / (page + '-original.json'), {'meta': {**base, **meta},
               'parsed': None if text is None else {'kind': 'typewritten', 'table': False, 'text': text}})

    def test_penalty_is_paired_and_excludes_agreement_pages(self):
        for p in ('p001', 'p002', 'p086'):
            self.reading('hosted', p, 'the quick brown fox')
        self.reading('local', 'p001', 'the quick brown fox')
        self.reading('local', 'p002', None, status='failed', finish='length')  # a failure scores as empty
        self.reading('local', 'p086', 'zzz')
        M.report()
        out = (self.root / 'out/r.md').read_text()
        self.assertIn('4-bit penalty (local − hosted NES): -50.00 points** over 2 pages', out)
        self.assertIn('1 failed (1 hit max_tokens)', out)
        self.assertIn('p002 (typewritten): hosted 100.0 → local 0.0 (local reading failed: length)', out)
        self.assertNotIn('quick brown', out)  # no page text in the public report
        groups = (self.root / 'out/ocr-mac-local-groups.csv').read_text().splitlines()
        self.assertIn('qwen3-vl-8b-mlx4,kind,typewritten,2,1,0.5,', '\n'.join(groups))
        self.assertNotIn('quick brown', '\n'.join(groups))

    def test_format_slip_has_a_lenient_figure(self):
        for p in ('p001', 'p002'):
            self.reading('hosted', p, 'the quick brown fox')
        self.reading('local', 'p001', 'the quick brown fox')
        self.reading('local', 'p002', None, status='failed', finish='stop')
        P.save(M.OUT / 'p002-original.raw.json', {'text': 'KIND: typewritten with notes\nTABLE: no\nTEXT:\nthe quick brown fox'})
        M.report()
        out = (self.root / 'out/r.md').read_text()
        self.assertIn('-50.00 points** over 2 pages', out)  # strict: the panel's parser scores it empty
        self.assertIn('1 local reading(s) ended normally but broke the reply format', out)
        self.assertIn('the penalty is **+0.00 points**', out)

    def test_incomplete_run_says_so(self):
        for p in ('p001', 'p002'):
            self.reading('hosted', p, 'the quick brown fox')
        self.reading('local', 'p001', 'the quick brown fox')
        M.report()
        out = (self.root / 'out/r.md').read_text()
        self.assertIn('Incomplete: 1 of 2 accuracy pages', out)
        self.assertIn('+0.00 points** over 1 pages', out)

    def test_handwriting_models_join_the_groups_csv(self):
        for p in ('p001', 'p002', 'p086'):
            self.reading('hosted', p, 'the quick brown fox')
        self.reading('local', 'p001', 'the quick brown fox')
        lighton = M.out_dir('lightonocr-3-4b-mlx8')
        P.save(lighton / 'p001-original.json', {'meta': {'wall_s': 18, 'first_token_s': 3, 'prompt_tokens': 3086,
               'completion_tokens': 300, 'gen_tps': 30, 'mlx_peak_gb': 6.4, 'load_s': 2, 'status': 'ok', 'finish': 'stop'},
               'parsed': M.parse(M.HW['lightonocr-3-4b-mlx8'], 'the quick brown fox\n')})
        qwen = M.out_dir('qwen3.5-9b-mlx4')
        P.save(qwen / 'p002-original.json', {'meta': {'wall_s': 30, 'first_token_s': 5, 'prompt_tokens': 4000,
               'completion_tokens': 400, 'gen_tps': 20, 'mlx_peak_gb': 8.7, 'load_s': 3, 'status': 'ok', 'finish': 'stop'},
               'parsed': {'kind': 'typewritten', 'table': False, 'text': 'the quick brown'}})
        P.save(P.CACHE / 'responses' / 'qwen3.5-9b' / 'p002-original.json',
               {'meta': {}, 'parsed': {'kind': 'typewritten', 'table': False, 'text': 'the quick brown fox'}})
        M.report()
        out = (self.root / 'out/hw.md').read_text()
        self.assertIn('**Incomplete: 1 of 2 accuracy pages read.**', out)
        self.assertIn('| Mac MLX (lightonocr-3-4b-mlx8) | 1/1 | 100.00 |', out)
        self.assertIn('| hosted bf16 (qwen3.5-9b) | 1/1 | 100.00 |', out)
        self.assertIn('**Mac 4-bit − hosted bf16 NES: -21.05 points** over 1 pages', out)
        self.assertNotIn('quick brown', out)
        groups = (self.root / 'out/ocr-mac-local-groups.csv').read_text()
        self.assertIn('lightonocr-3-4b-mlx8,all,accuracy-96,1,1,1.0,', groups)
        self.assertIn('qwen3.5-9b-mlx4,kind,typewritten,1,1,', groups)
        self.assertIn('qwen3-vl-8b-mlx4,all,accuracy-96,1,1,1.0,', groups)

    def test_plain_reply_is_scored_whole(self):
        spec = M.HW['lightonocr-3-4b-mlx8']
        self.assertEqual(M.parse(spec, '  KIND: x\nsome text\n')['text'], 'KIND: x\nsome text')
        self.assertIsNone(M.parse(spec, '   '))
        self.assertIsNone(M.parse(M.HW['qwen3.5-9b-mlx4'], 'no header at all'))


if __name__ == '__main__':
    unittest.main()
