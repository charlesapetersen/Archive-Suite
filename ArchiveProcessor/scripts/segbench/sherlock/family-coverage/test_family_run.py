#!/usr/bin/env python3
"""W46.ocr-family-coverage: family_run's adapters through boxes_run's pilot gate, records and contract, with a fake
engine (no model, no vLLM).   python3 test_family_run.py"""
from pathlib import Path
from types import SimpleNamespace as NS
import base64
import hashlib
import io
import json
import os
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parents[1] / 'corpus'), str(HERE.parents[1])]
import family_run as F  # noqa: E402
try:  # the scorers' reading(); its scoring stack (regex, rapidfuzz) is not in every Mac python
    import farmshare_results  # noqa: E402
except ImportError:
    farmshare_results = None

R = F.R


def jpeg(w, h):
    from PIL import Image
    buf = io.BytesIO()
    Image.new('RGB', (w, h), 'white').save(buf, format='JPEG')
    return buf.getvalue()


class FakeLLM:
    """Records what it was sent; replies per page from `replies` (keyed by the call order), or raises."""

    def __init__(self):
        self.calls, self.replies, self.fail_batches = [], {}, False

    def _out(self, i):
        text, finish = self.replies.get(i, ('<p>Page text</p>', 'stop'))
        if text is None:
            raise RuntimeError('engine fell over')
        return NS(prompt_token_ids=[1] * 12, outputs=[NS(text=text, token_ids=[2] * 5, finish_reason=finish)])

    def chat(self, convs, params, use_tqdm=False, chat_template_kwargs=None, **kw):
        self.calls.append(('chat', convs, params, chat_template_kwargs, kw))
        if self.fail_batches and len(convs) > 1:
            raise RuntimeError('batch failed')
        return [self._out(self._page(c)) for c in convs]

    def generate(self, reqs, params, use_tqdm=False):
        self.calls.append(('generate', reqs, params))
        return [self._out(None) for _ in reqs]

    def _page(self, conv):
        url = conv[-1]['content'][0]['image_url']['url']
        return self.by_url.get(url)


class Adapter(unittest.TestCase):
    def cfg(self, **k):
        return {'key': 'chandra-ocr-2', 'model': 'm', 'revision': 'r', 'snapshot': '/snap', 'adapter': 'vllm',
                'mode': 'chat', 'prompt': 'OCR this image to HTML.', 'reduce': 'chandra', **k}

    def test_engine_and_sampling_from_the_card(self):
        c = self.cfg(vllm={'trust_remote_code': True, 'enable_prefix_caching': False,
                           'logits_processors': ['json:JSONDecoder']},
                     sampling={'skip_special_tokens': False, 'extra_args': {'ngram_size': 30,
                                                                            'whitelist_token_ids': [7, 8]}})
        e, s = F.engine_kwargs(c), F.sampling_kwargs(c)
        self.assertEqual((e['max_model_len'], e['max_num_seqs'], e['trust_remote_code']), (16384, 16, True))
        self.assertIs(e['logits_processors'][0], json.JSONDecoder)
        self.assertEqual((s['temperature'], s['max_tokens'], s['skip_special_tokens']), (0.0, 8192, False))
        self.assertEqual(s['extra_args']['whitelist_token_ids'], {7, 8})
        self.assertEqual(F.describe(s)['extra_args']['whitelist_token_ids'], [7, 8])
        self.assertEqual(F.describe(e)['logits_processors'], ['JSONDecoder'])

    def test_messages_user_and_system(self):
        self.assertEqual([m['role'] for m in F.messages(self.cfg(), 'u')], ['user'])
        self.assertEqual(F.messages(self.cfg(), 'u')[0]['content'][1], {'type': 'text', 'text': 'OCR this image to HTML.'})
        sys_msgs = F.messages(self.cfg(prompt_role='system', prompt='Transcribe.'), 'u')
        self.assertEqual(sys_msgs[0], {'role': 'system', 'content': 'Transcribe.'})
        self.assertEqual(sys_msgs[1]['content'], [{'type': 'image_url', 'image_url': {'url': 'u'}}])

    def test_image_bytes_verbatim_or_scaled_png(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d, 'a.jpg')
            p.write_bytes(jpeg(2400, 1200))
            _, url, size = F.load_image(p)
            self.assertEqual(base64.b64decode(url.split(',', 1)[1]), p.read_bytes())
            im, url, size = F.load_image(p, 1288)
            self.assertEqual((im.size, size), ((1288, 644), (2400, 1200)))
            self.assertTrue(url.startswith('data:image/png;base64,'))
            self.assertTrue(F.load_image(p, 4000)[1].startswith('data:image/jpeg;'))  # never scaled up

    def test_batch_failure_reads_page_by_page_and_records_the_error(self):
        with tempfile.TemporaryDirectory() as d:
            paths = []
            for i in range(3):
                p = Path(d, f'{i}.jpg')
                p.write_bytes(jpeg(100 + i, 100))
                paths.append(p)
            llm = FakeLLM()
            urls = [F.load_image(p)[1] for p in paths]
            llm.by_url = dict(zip(urls, range(3)))
            llm.replies = {1: (None, None), 2: ('<p>cut</p>', 'length')}
            llm.fail_batches = True
            out = list(F.Vllm(self.cfg(), llm=llm).read_many(paths))
        self.assertEqual([o[5] for o in out], ['stop', 'error', 'length'])
        self.assertEqual(out[0][1], 'Page text')
        self.assertIn('engine fell over', out[1][4]['error'])
        self.assertEqual([c[0] for c in llm.calls], ['chat'] * 4)  # the batch, then each page once
        self.assertEqual(llm.calls[0][3], {'enable_thinking': False})

    def test_generate_mode_sends_the_raw_prompt(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d, 'a.jpg')
            p.write_bytes(jpeg(50, 50))
            llm = FakeLLM()
            llm.replies = {None: ('<|ref|>text<|/ref|><|det|>[[1, 2, 3, 4]]<|/det|>\nFree text', 'stop')}
            out = list(F.Vllm(self.cfg(mode='generate', prompt='<image>\nFree OCR.', reduce='deepseek'),
                              llm=llm).read_many([p]))
        self.assertEqual(llm.calls[0][1][0]['prompt'], '<image>\nFree OCR.')
        self.assertEqual(out[0][1], 'Free text')

    def test_mineru_client(self):
        class Client:
            def __init__(self):
                self.prompts = {'[default]': '\nText Recognition:'}

            def batch_two_step_extract(self, images):
                return [[NS(type='text', bbox=[0, 0, 1, 1], angle=0, content='Hello')] for _ in images]
        with tempfile.TemporaryDirectory() as d:
            p = Path(d, 'a.jpg')
            p.write_bytes(jpeg(40, 30))
            m = F.MinerU({'snapshot': '/s', 'prompt': 'x'}, client=Client())
            out = list(m.read_many([p]))
        self.assertEqual((out[0][1], out[0][3], out[0][5]), ('Hello', (40, 30), 'stop'))
        self.assertIn('prompts', m.settings()['client_settings'])
        self.assertNotIn('logits_processors', m.engine)


class EndToEnd(unittest.TestCase):
    """boxes_run.main with the vllm adapter on a fake engine: pilot, full run, records the scorers read."""

    def test_pilot_then_set(self):
        with tempfile.TemporaryDirectory() as d:
            parent = Path(d)
            rows = []
            for i in range(4):
                img = parent / f'p{i}.jpg'
                img.write_bytes(jpeg(60 + i, 60))
                rows.append({'id': f'p{i}', 'image': str(img), 'sha256': hashlib.sha256(img.read_bytes()).hexdigest()})
            (parent / 'pilot3.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows[:3]))
            (parent / 'sub.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
            root = parent / 'churro-3b'
            root.mkdir()
            cfg = {'key': 'churro-3b', 'model': 'stanford-oval/churro-3B', 'revision': 'abc', 'snapshot': '/s',
                   'adapter': 'fake-vllm', 'mode': 'chat', 'prompt_role': 'system',
                   'prompt': 'Transcribe the entirety of this historical document to XML format.', 'reduce': 'churro',
                   'state': 'ready'}
            (root / 'prepared.json').write_text(json.dumps(cfg))
            llm = FakeLLM()
            llm.by_url = {}
            llm.replies = {None: ('<HistoricalDocument><Page><Body><Line>Old words</Line></Body></Page>'
                                  '</HistoricalDocument>', 'stop')}
            R.ADAPTERS['fake-vllm'] = lambda c: F.Vllm(c, llm=llm)
            os.environ['SESSION_ROOT'] = str(root)
            sys.argv = ['family_run.py', 'sub.jsonl']
            try:
                R.main()
            finally:
                del R.ADAPTERS['fake-vllm']
            out = root / 'results/ocr/churro-3b'
            rec = json.loads((out / 'p3.json').read_text())
            self.assertEqual((rec['raw'], rec['status'], rec['mode']), ('Old words', 'ok', 'native'))
            self.assertIn('HistoricalDocument', rec['model_raw'])
            if farmshare_results:
                self.assertEqual(farmshare_results.reading(rec, 'native'), 'Old words')
            self.assertEqual(json.loads((root / 'status.json').read_text())['counts'], {'ok': 4, 'cap': 0, 'error': 0})
            contract = json.loads((root / 'cache-contract.json').read_text())
            self.assertEqual(contract['settings']['prompt_role'], 'system')
            self.assertEqual(contract['settings']['family_parse_sha256'],
                             hashlib.sha256(Path(F.P.__file__).read_bytes()).hexdigest())


if __name__ == '__main__':
    unittest.main()
