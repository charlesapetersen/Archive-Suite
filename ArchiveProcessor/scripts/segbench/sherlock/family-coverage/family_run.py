#!/usr/bin/env python3
"""W46.ocr-family-coverage on Sherlock: one reader from a family never measured, on one page set, in process.

  SESSION_ROOT=<root>/<key> family_run.py MANIFEST     (MANIFEST in <root>: public895.jsonl | truth99.jsonl |
                                                         public895-<key>.jsonl, a subset family_setup.py wrote)

boxes_run.py's runner unchanged (three-page pilot gate, one record per page, resume, the settings contract the 96 run
must match), with two adapters it does not have (prepared.json `adapter`):
  vllm    vLLM's offline engine, one image and the card's prompt, greedy, at most 8,192 new tokens in a 16,384 context
          (the open sweep's limits). `mode` chat sends the open sweep's collector message, the image as the JPEG's
          own bytes (a data URL) then the prompt text, thinking off; `prompt_role` system sends the prompt as the
          system message and the image alone (CHURRO's preset). `mode` generate sends the card's raw prompt with its
          <image> placeholder (DeepSeek-OCR-2's vLLM recipe). `vllm`, `chat_kwargs` and `sampling` carry the card's engine and
          sampling settings (logits processors, processor kwargs, dots.ocr's string content format, per-request
          extra_args); `max_side` scales the
          image down to the card's longest side first (olmOCR's 1,288 px), sent as PNG so nothing is re-compressed.
  mineru  MinerU2.5 through mineru-vl-utils' two-step client (layout, then each block) on the same offline engine.
          The client does not report a finish reason, so a block cut at its token limit is not visible: every
          answered page is recorded as a stop, and the contract says so.
`raw` is the reply reduced to text (family_parse; the scorers read it as a native reply), `model_raw` the reply as
written. A batch that raises is read again page by page; a page that still raises is recorded as an error, which
scores 0, and the run goes on (one bad page does not cost the model its set).
"""
from pathlib import Path
import base64
import hashlib
import importlib
import io
import json
import os
import sys

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent / 'new-open-boxes')]
import boxes_run as R  # noqa: E402
import family_parse as P  # noqa: E402

MAX_MODEL_LEN = 16384


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_image(path, max_side=None):
    """The page as PIL RGB and as the URL the chat message carries: the file's own JPEG bytes, or a PNG of the image
    scaled down so its longest side is max_side (never up)."""
    from PIL import Image
    data = Path(path).read_bytes()
    im = Image.open(io.BytesIO(data)).convert('RGB')
    size = im.size
    if max_side and max(size) > max_side:
        k = max_side / max(size)
        im = im.resize((max(1, round(size[0] * k)), max(1, round(size[1] * k))), Image.LANCZOS)
        buf = io.BytesIO()
        im.save(buf, format='PNG')
        url = 'data:image/png;base64,' + base64.b64encode(buf.getvalue()).decode()
    else:
        url = 'data:image/jpeg;base64,' + base64.b64encode(data).decode()
    return im, url, size


def messages(cfg, url):
    image = {'type': 'image_url', 'image_url': {'url': url}}
    if cfg.get('prompt_role') == 'system':
        return [{'role': 'system', 'content': cfg['prompt']}, {'role': 'user', 'content': [image]}]
    return [{'role': 'user', 'content': [image, {'type': 'text', 'text': cfg['prompt']}]}]


def engine_kwargs(cfg):
    """LLM() arguments: the open sweep's limits, then the card's own (`vllm`). A logits processor is named
    'module:Class' and imported here."""
    v = dict(cfg.get('vllm') or {})
    kw = {'model': cfg['snapshot'], 'limit_mm_per_prompt': {'image': 1}, 'seed': 0, 'max_num_seqs': 16,
          'max_model_len': MAX_MODEL_LEN, 'gpu_memory_utilization': 0.85}
    procs = v.pop('logits_processors', None)
    kw.update(v)
    if procs:
        kw['logits_processors'] = [getattr(importlib.import_module(p.split(':')[0]), p.split(':')[1]) for p in procs]
    return kw


def sampling_kwargs(cfg):
    s = dict(cfg.get('sampling') or {})
    extra = s.pop('extra_args', None)
    if extra and 'whitelist_token_ids' in extra:
        extra = {**extra, 'whitelist_token_ids': set(extra['whitelist_token_ids'])}  # the recipe passes a set
    kw = {'temperature': 0.0, 'max_tokens': R.MAX_NEW, **s}
    if extra:
        kw['extra_args'] = extra
    return kw


def describe(kw):
    return json.loads(json.dumps(kw, default=lambda o: sorted(o) if isinstance(o, (set, frozenset))
                                 else getattr(o, '__name__', repr(o))))


class Vllm:
    kind = 'vllm'

    def __init__(self, cfg, llm=None):
        # Spawned, not forked: a forked engine deadlocked in boxes_run's granite route (job 50536486).
        os.environ.setdefault('VLLM_WORKER_MULTIPROC_METHOD', 'spawn')
        self.cfg, self.reduce = cfg, P.REDUCE[cfg['reduce']]
        self.engine = engine_kwargs(cfg)
        self.sampling = sampling_kwargs(cfg)
        if llm is None:
            from vllm import LLM, SamplingParams
            llm = LLM(**self.engine)
            self.params = SamplingParams(**self.sampling)
        else:  # tests
            self.params = self.sampling
        self.llm = llm

    def settings(self):
        return {'engine': describe(self.engine), 'sampling': describe(self.sampling), 'mode': self.cfg['mode'],
                'prompt_role': self.cfg.get('prompt_role', 'user'), 'max_side': self.cfg.get('max_side'),
                'chat_template_kwargs': {'enable_thinking': False} if self.cfg['mode'] == 'chat' else None,
                'chat_kwargs': self.cfg.get('chat_kwargs'),
                'reduce': self.cfg['reduce'], 'family_run_sha256': sha(__file__), 'family_parse_sha256': sha(P.__file__),
                'vllm_worker_multiproc_method': os.environ['VLLM_WORKER_MULTIPROC_METHOD']}

    def _generate(self, pages):
        if self.cfg['mode'] == 'chat':
            convs = [messages(self.cfg, url) for _, url, _ in pages]
            return self.llm.chat(convs, self.params, use_tqdm=False, chat_template_kwargs={'enable_thinking': False},
                                 **(self.cfg.get('chat_kwargs') or {}))
        reqs = [{'prompt': self.cfg['prompt'], 'multi_modal_data': {'image': im}} for im, _, _ in pages]
        return self.llm.generate(reqs, self.params, use_tqdm=False)

    def _record(self, out, size):
        c = out.outputs[0]
        text, boxes = self.reduce(c.text)
        usage = {'prompt_tokens': len(out.prompt_token_ids or []), 'completion_tokens': len(c.token_ids)}
        finish = c.finish_reason if c.finish_reason in ('stop', 'length') else str(c.finish_reason)
        return c.text, text, boxes, size, usage, finish

    def read_many(self, paths):
        pages = [load_image(p, self.cfg.get('max_side')) for p in paths]
        try:  # every record built before any is yielded, so a failure part-way never repeats a page
            done = [self._record(out, size) for out, (_, _, size) in zip(self._generate(pages), pages, strict=True)]
        except Exception:  # noqa: BLE001  read again one at a time, so only the page that fails is lost
            done = None
        if done is not None:
            yield from done
            return
        for page in pages:
            try:
                yield self._record(self._generate([page])[0], page[2])
            except Exception as exc:  # noqa: BLE001
                yield '', '', [], page[2], {'error': f'{type(exc).__name__}: {exc}'[:500]}, 'error'


class MinerU:
    kind = 'mineru'

    def __init__(self, cfg, client=None):
        os.environ.setdefault('VLLM_WORKER_MULTIPROC_METHOD', 'spawn')
        self.cfg = cfg
        self.engine = {**engine_kwargs({**cfg, 'vllm': {}}), **(cfg.get('vllm') or {})}
        self.engine.pop('logits_processors', None)  # MinerU's own processor, below
        self.engine.pop('limit_mm_per_prompt', None)
        if client is None:
            from mineru_vl_utils import MinerUClient, MinerULogitsProcessor
            from vllm import LLM
            client = MinerUClient(backend='vllm-engine',
                                  vllm_llm=LLM(**self.engine, logits_processors=[MinerULogitsProcessor]))
        self.client = client

    def settings(self):
        seen = {}
        for k, v in sorted(vars(self.client).items()):
            if isinstance(v, (int, float, bool, str)) or k.endswith(('prompts', 'sampling_params', 'image_size')):
                seen[k] = repr(v)[:2000]
        return {'engine': describe(self.engine), 'client': 'mineru-vl-utils MinerUClient, backend vllm-engine, '
                'two_step_extract; finish reasons not reported (an answered page is a stop)',
                'client_settings': seen, 'mineru_vl_utils': R.version('mineru-vl-utils'),
                'family_run_sha256': sha(__file__), 'family_parse_sha256': sha(P.__file__),
                'vllm_worker_multiproc_method': os.environ['VLLM_WORKER_MULTIPROC_METHOD']}

    def _one(self, blocks, size):
        dicts = [b if isinstance(b, dict) else {k: getattr(b, k, None) for k in ('type', 'bbox', 'angle', 'content')}
                 for b in blocks]
        text, boxes = P.mineru(dicts)
        return json.dumps(dicts, ensure_ascii=False, default=repr), text, boxes, size, {'blocks': len(dicts)}, 'stop'

    def read_many(self, paths):
        pages = [load_image(p)[::2] for p in paths]   # (PIL image, original size)
        batch = getattr(self.client, 'batch_two_step_extract', None)
        if batch:
            try:
                done = [self._one(blocks, size) for blocks, (_, size) in zip(batch([im for im, _ in pages]), pages,
                                                                            strict=True)]
            except Exception:  # noqa: BLE001
                done = None
            if done is not None:
                yield from done
                return
        for im, size in pages:
            try:
                yield self._one(self.client.two_step_extract(im), size)
            except Exception as exc:  # noqa: BLE001
                yield '', '', [], size, {'error': f'{type(exc).__name__}: {exc}'[:500]}, 'error'


R.ADAPTERS.update(vllm=Vllm, mineru=MinerU)

if __name__ == '__main__':
    # As boxes_run: exit outright, so a spawned engine never holds the card after the run (job 50573600).
    try:
        R.main()
    except BaseException:
        import traceback
        traceback.print_exc()
        sys.stdout.flush(); sys.stderr.flush()
        os._exit(1)
    sys.stdout.flush(); sys.stderr.flush()
    os._exit(0)
