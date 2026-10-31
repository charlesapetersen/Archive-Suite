#!/usr/bin/env python3
"""prompt_source.py on fake wheels and an sdist: the package's prompt wins, a match is recorded, a bad archive leaves
the transcription. Run: python3 test_prompt_source.py"""
import json
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE / 'prompt_source.py'
CANDS = json.loads((HERE / 'candidates-infinity-20261031.json').read_text())


class PromptSource(unittest.TestCase):
    def setUp(self):
        self.d = pathlib.Path(tempfile.mkdtemp())
        self.prompt = CANDS[0]['prompt']
        self.src = 'X = 1\nPROMPT_DOC2JSON = "json"\nPROMPT_DOC2MD = ' + repr(self.prompt) + '\n'

    def run_on(self, archive):
        c = self.d / 'c.json'
        c.write_text(json.dumps(CANDS))
        subprocess.run([sys.executable, str(SCRIPT), str(c), '--from', str(archive)], check=True, capture_output=True)
        return json.loads(c.read_text())[0]

    def wheel(self, name, text):
        p = self.d / name
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('infinity_parser2/prompts.py', text)
        return p

    def test_same_wheel(self):
        r = self.run_on(self.wheel('a.whl', self.src))
        self.assertIs(r['prompt_check']['same_as_transcription'], True)
        self.assertEqual(r['prompt'], self.prompt)

    def test_same_sdist(self):
        pkg = self.d / 'pkg' / 'infinity_parser2'
        pkg.mkdir(parents=True)
        (pkg / 'prompts.py').write_text(self.src)
        p = self.d / 'a.tar.gz'
        with tarfile.open(p, 'w:gz') as t:
            t.add(self.d / 'pkg', arcname='infinity-parser2-0.1')
        self.assertIs(self.run_on(p)['prompt_check']['same_as_transcription'], True)

    def test_package_wins(self):
        r = self.run_on(self.wheel('b.whl', 'PROMPT_DOC2MD = "other"\n'))
        self.assertIs(r['prompt_check']['same_as_transcription'], False)
        self.assertEqual(r['prompt'], 'other')
        self.assertEqual(r['prompt_check']['transcription'], self.prompt)

    def test_bad_archive_keeps_transcription(self):
        p = self.d / 'c.whl'
        p.write_text('not a zip')
        r = self.run_on(p)
        self.assertIn('error', r['prompt_check'])
        self.assertEqual(r['prompt'], self.prompt)

    def test_candidate_shape(self):
        c = CANDS[0]
        self.assertEqual((c['key'], c['gpus'], c['route']), ('infinity-parser2-pro', 2, 'native-text'))
        self.assertEqual(len(c['revision']), 40)
        self.assertTrue(self.prompt.startswith('\nYou are an AI assistant') and '\\frac{-b \\pm' in self.prompt)


if __name__ == '__main__':
    unittest.main()
