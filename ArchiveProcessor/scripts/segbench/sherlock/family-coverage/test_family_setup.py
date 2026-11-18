#!/usr/bin/env python3
"""W46.ocr-family-coverage: family_setup's prompt reading and subset, offline (--from).   python3 test_family_setup.py"""
from pathlib import Path
import json
import sys
import tempfile
import unittest
import zipfile

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import family_setup as FS  # noqa: E402

OLMO = '''import re
def build_no_anchoring_v4_yaml_prompt() -> str:
    return "Attached is one page." + "\\nReturn markdown."
'''
CHANDRA = '''ALLOWED_TAGS = ["p", "table"]
PROMPT_ENDING = f"Only use these tags {ALLOWED_TAGS}."
OCR_PROMPT = f"""OCR this image to HTML.

{PROMPT_ENDING}"""
'''
DOTS = 'dict_promptmode_to_prompt = {"prompt_layout_all_en": "Please output the layout.", "prompt_ocr": "x"}\n'


class Prompts(unittest.TestCase):
    def test_sources_win_and_are_recorded(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            with zipfile.ZipFile(d / 'olmocr-0.4.9-py3-none-any.whl', 'w') as z:
                z.writestr('olmocr/prompts/prompts.py', OLMO)
            with zipfile.ZipFile(d / 'chandra_ocr-0.3.0-py3-none-any.whl', 'w') as z:
                z.writestr('chandra/prompts.py', CHANDRA)
            (d / 'prompts.py').write_text(DOTS)
            cands = [
                {'key': 'olmo', 'prompt': 'Attached is one page.\nReturn markdown.',
                 'prompt_from': {'pypi': 'olmocr', 'file': 'olmocr/prompts/prompts.py',
                                 'expr': 'build_no_anchoring_v4_yaml_prompt()'}},
                {'key': 'chandra', 'prompt': None,
                 'prompt_from': {'pypi': 'chandra-ocr', 'file': 'chandra/prompts.py', 'expr': 'OCR_PROMPT'}},
                {'key': 'dots', 'prompt': 'Please output the layout ',
                 'prompt_from': {'url': 'https://example.org/x/prompts.py',
                                 'expr': "dict_promptmode_to_prompt['prompt_layout_all_en']"}},
                {'key': 'missing', 'prompt': 'kept', 'prompt_from': {'pypi': 'nothere', 'file': 'a.py', 'expr': 'X'}},
                {'key': 'plain', 'prompt': 'Free OCR.'}]
            p = d / 'c.json'
            p.write_text(json.dumps(cands))
            FS.prompts(p, d)
            out = {c['key']: c for c in json.loads(p.read_text())}
        self.assertEqual(out['olmo']['prompt_check']['same_as_transcription'], True)
        self.assertEqual(out['chandra']['prompt'], "OCR this image to HTML.\n\nOnly use these tags ['p', 'table'].")
        self.assertEqual(out['chandra']['prompt_check']['source'], 'chandra_ocr-0.3.0-py3-none-any.whl')
        self.assertEqual(out['dots']['prompt'], 'Please output the layout.')
        self.assertEqual(out['dots']['prompt_check']['transcription'], 'Please output the layout ')
        self.assertEqual((out['missing']['prompt'], out['missing']['prompt_check']['used']), ('kept', 'the transcription'))
        self.assertNotIn('prompt_check', out['plain'])


class Subset(unittest.TestCase):
    def test_subset_written_and_recorded(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / 'public895.jsonl').write_text(''.join(json.dumps({'id': f'p{i}', 'sha256': 'x'}) + '\n'
                                                       for i in range(5)))
            (d / 'k').mkdir()
            (d / 'k' / 'prepared.json').write_text(json.dumps({'key': 'k', 'state': 'downloaded'}))
            (d / 'ids.txt').write_text('p1\np3\n')
            FS.subset(d, 'k', d / 'ids.txt')
            self.assertEqual([json.loads(x)['id'] for x in (d / 'public895-k.jsonl').read_text().splitlines()],
                             ['p1', 'p3'])
            self.assertEqual(json.loads((d / 'k' / 'prepared.json').read_text())['manifest_895'], 'public895-k.jsonl')
            (d / 'ids.txt').write_text('p1\nzz\n')
            with self.assertRaises(SystemExit):
                FS.subset(d, 'k', d / 'ids.txt')

    def test_the_455_are_the_strata_churro_skipped(self):
        ids = (HERE / 'churro-added455.txt').read_text().split()
        self.assertEqual((len(ids), len(set(ids))), (455, 455))
        manifest = HERE.parents[3] / 'segbench-results/bench-corpus/manifest.jsonl'
        strata = {(r['source'] + ':' + r['page_id']).replace(':', '__').replace('/', '_'): r['stratum']  # routes.job_id
                  for r in map(json.loads, manifest.read_text().splitlines())}
        self.assertEqual({strata[i] for i in ids}, {'L1', 'L2', 'L3', 'L4', 'L9', 'N2', 'N5', 'N6'})


if __name__ == '__main__':
    unittest.main()
