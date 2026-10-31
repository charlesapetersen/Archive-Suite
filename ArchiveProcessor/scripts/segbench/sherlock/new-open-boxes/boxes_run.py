#!/usr/bin/env python3
"""W46.ocr-new-open-boxes on Sherlock: one box-emitting reader on one page set, in process, through its card's route.

  SESSION_ROOT=<root>/<key> boxes_run.py MANIFEST        (MANIFEST public895.jsonl | truth99.jsonl, in <root>)

open_sweep_run.py's shape without its frozen collector, which sends one image and one prompt to an OpenAI-style
server and keeps only the text: these three need their card's own runtime (prepared.json `adapter`):
  unlimited  baidu/Unlimited-OCR through its remote code's infer() (gundam mode, the card's n-gram window), transformers
  nemotron   nvidia/NVIDIA-Nemotron-Parse-2.0 as its run_transformers_inference.py: greedy, repetition penalty 1.1
  granite    ibm-granite/granite-docling-258M (revision untied) through vLLM's offline LLM, special tokens kept
Each page is greedy, one reading, at most 8,192 new tokens (granite: what its 8,192-token context leaves after the
prompt). The three-page pilot (pilot3.jsonl in <root>) runs first and must answer every page, uncapped and
non-empty, or nothing more is read. Records keep the frozen collector's fields, so the scorers read them as native
replies (farmshare_expanded_report.reading): `raw` is the reading text from boxes_parse, `model_raw` the reply as the
model wrote it, `boxes` its blocks in the model's own units (for W46.place-print). A page that raises is written as
<id>.error.json and stops the run (no retries); a page already read is not read again. cache-contract.json binds
the settings: the 96 run takes the 895 run's as sweep-contract.json and refuses a difference.
"""
from pathlib import Path
import hashlib
import importlib.metadata
import json
import os
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import boxes_parse as B  # noqa: E402

MAX_NEW = 8192


def save(path, obj):
    tmp = path.with_suffix('.part')
    tmp.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + '\n')
    tmp.replace(path)


def version(name):
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return None


def image_path(row, root):
    p = Path(row['image'])
    return p if p.is_absolute() else root / 'ocr' / p


class Transformers:
    """Shared by the two transformers routes: the snapshot on sys.path (their postprocessing modules), bf16 on one card."""

    def __init__(self, cfg):
        import torch
        self.torch, self.cfg, self.snap = torch, cfg, cfg['snapshot']
        sys.path.insert(0, self.snap)

    def finish(self, new_ids, eos):
        n = len(new_ids)
        return n, ('length' if n >= MAX_NEW or not n or int(new_ids[-1]) not in eos else 'stop')


class Nemotron(Transformers):
    kind = 'nemotron'

    def __init__(self, cfg):
        super().__init__(cfg)
        from transformers import AutoModel, AutoProcessor, GenerationConfig
        torch = self.torch
        self.model = AutoModel.from_pretrained(self.snap, trust_remote_code=True, torch_dtype=torch.bfloat16,
                                               local_files_only=True).to('cuda').eval()
        self.processor = AutoProcessor.from_pretrained(self.snap, trust_remote_code=True, local_files_only=True)
        g = GenerationConfig.from_pretrained(self.snap, trust_remote_code=True, local_files_only=True)
        g.max_new_tokens, g.do_sample, g.num_beams = MAX_NEW, False, 1
        g.repetition_penalty = cfg.get('repetition_penalty', 1.1)
        self.gen = g
        self.eos = {int(x) for x in ([g.eos_token_id] if isinstance(g.eos_token_id, int) else g.eos_token_id)}
        from postprocessing import postprocess_text  # the snapshot's own module
        self.post = postprocess_text

    def settings(self):
        return {'generation': {k: getattr(self.gen, k) for k in ('max_new_tokens', 'do_sample', 'num_beams',
                                                                 'repetition_penalty', 'eos_token_id', 'forced_eos_token_id')},
                'decode': 'batch_decode skip_special_tokens=True (run_transformers_inference.py)'}

    def read(self, path):
        from PIL import Image
        image = Image.open(path).convert('RGB')
        inputs = self.processor(images=[image], text=self.cfg['prompt'], return_tensors='pt',
                                add_special_tokens=False).to('cuda')
        with self.torch.inference_mode():
            out = self.model.generate(**inputs, generation_config=self.gen)
        ids = out[0].tolist()
        # An encoder-decoder: generate() returns the decoder sequence, which begins with the task prompt it was seeded
        # with. forced_eos_token_id puts an EOS on a page that reaches the limit too, so the length decides a cap.
        seed = inputs['input_ids'].shape[1] if 'input_ids' in inputs else 0
        n = max(0, len(ids) - seed)
        finish = 'length' if n >= MAX_NEW - 1 or not ids or ids[-1] not in self.eos else 'stop'
        raw = self.processor.batch_decode(out, skip_special_tokens=True)[0]
        text, boxes = B.nemotron(raw, postprocess_text=self.post)
        return raw, text, boxes, image.size, {'prompt_tokens': seed, 'completion_tokens': n}, finish


class Unlimited(Transformers):
    kind = 'unlimited'

    def __init__(self, cfg):
        super().__init__(cfg)
        from transformers import AutoModel, AutoTokenizer
        torch = self.torch
        self.tok = AutoTokenizer.from_pretrained(self.snap, trust_remote_code=True, local_files_only=True)
        # As the card's transformers example loads it (README, read 2026-10-31): bf16, the config's own attention.
        self.model = AutoModel.from_pretrained(self.snap, trust_remote_code=True, use_safetensors=True,
                                               torch_dtype=torch.bfloat16, local_files_only=True).eval().cuda()
        self.attn = getattr(self.model.config, '_attn_implementation', None)
        self.eos = {int(self.tok.eos_token_id)}
        self.captured = {}
        orig = self.model.generate

        def generate(*a, **k):
            # infer() decodes and strips the stop string, so keep the ids to tell a cap from a stop. It also passes
            # max_length, which counts the image and prompt tokens; the harness's limit is 8,192 NEW tokens.
            k.pop('max_length', None)
            k['max_new_tokens'] = MAX_NEW
            out = orig(*a, **k)
            self.captured = {'ids': out, 'input_len': k['input_ids'].shape[1],
                             'kwargs': {x: v for x, v in k.items() if isinstance(v, (int, float, bool, str))}}
            return out
        self.model.generate = generate
        self.tmp = tempfile.mkdtemp(prefix='uocr-')

    def settings(self):
        return {'infer': {k: self.cfg['infer'][k] for k in sorted(self.cfg['infer'])}, 'attn_implementation': self.attn,
                'generate': 'max_length replaced by max_new_tokens 8192; eos ' + str(sorted(self.eos))}

    def read(self, path):
        from PIL import Image
        with Image.open(path) as im:
            size = im.size
        self.captured = {}
        with self.torch.inference_mode():
            raw = self.model.infer(self.tok, prompt=self.cfg['prompt'], image_file=str(path), output_path=self.tmp,
                                   eval_mode=True, save_results=False, **self.cfg['infer'])
        c = self.captured
        if not c:
            raise RuntimeError('infer() did not call generate(); the remote code changed')
        new = c['ids'][0, c['input_len']:].tolist()
        n, finish = self.finish(new, self.eos)
        raw = raw or ''
        text, boxes = B.unlimited(raw)
        return raw, text, boxes, size, {'prompt_tokens': c['input_len'], 'completion_tokens': n,
                                        'generate_kwargs': c['kwargs']}, finish


class Granite:
    kind = 'granite'

    def __init__(self, cfg):
        from transformers import AutoProcessor
        from vllm import LLM, SamplingParams
        self.cfg = cfg
        self.processor = AutoProcessor.from_pretrained(cfg['snapshot'], local_files_only=True)
        self.llm = LLM(model=cfg['snapshot'], limit_mm_per_prompt={'image': 1}, seed=0, max_num_seqs=16,
                       gpu_memory_utilization=0.85)
        # max_tokens None: what the 8,192-token context leaves after the prompt (the card asks for 8,192 new tokens,
        # which no page can have); a page that fills it ends with finish_reason length, a cap.
        self.params = SamplingParams(temperature=0.0, max_tokens=None, skip_special_tokens=False)
        messages = [{'role': 'user', 'content': [{'type': 'image'}, {'type': 'text', 'text': cfg['prompt']}]}]
        self.prompt = self.processor.apply_chat_template(messages, add_generation_prompt=True)
        from docling_core.types.doc.document import DocTagsDocument  # noqa: F401  (fail before reading, not after)

    def settings(self):
        return {'sampling': 'temperature 0, max_tokens None (context 8192 less the prompt), skip_special_tokens False',
                'chat_prompt_sha256': hashlib.sha256(self.prompt.encode()).hexdigest(),
                'max_model_len': self.llm.llm_engine.model_config.max_model_len, 'docling_core': version('docling-core')}

    def read_many(self, paths):
        from PIL import Image
        images = [Image.open(p).convert('RGB') for p in paths]
        outs = self.llm.generate([{'prompt': self.prompt, 'multi_modal_data': {'image': im}} for im in images],
                                 self.params, use_tqdm=False)
        for im, o in zip(images, outs):
            c = o.outputs[0]
            raw = c.text
            text, boxes = B.doctags(raw, to_markdown=lambda r: B.docling_markdown(r, im))
            finish = 'stop' if c.finish_reason == 'stop' else 'length' if c.finish_reason == 'length' else str(c.finish_reason)
            yield raw, text, boxes, im.size, {'prompt_tokens': len(o.prompt_token_ids or []),
                                              'completion_tokens': len(c.token_ids)}, finish


ADAPTERS = {'nemotron': Nemotron, 'unlimited': Unlimited, 'granite': Granite}


def run_rows(adapter, rows, root, out, cfg, label):
    """Read every row without a record; write each as it finishes. Returns the statuses of the pages read."""
    todo = [r for r in rows if not (out / (r['id'] + '.json')).exists()]
    for r in todo:
        if hashlib.sha256(image_path(r, root).read_bytes()).hexdigest() != r['sha256']:
            raise ValueError('image changed: ' + r['id'])
    statuses = []
    chunk = 32 if hasattr(adapter, 'read_many') else 1
    for i in range(0, len(todo), chunk):
        part = todo[i:i + chunk]
        t = time.time()
        try:
            if hasattr(adapter, 'read_many'):
                results = list(adapter.read_many([image_path(r, root) for r in part]))
            else:
                results = [adapter.read(image_path(part[0], root))]
            error = None
        except Exception as exc:  # one record per page that raised; the run stops after writing it
            results, error = [], f'{type(exc).__name__}: {exc}'[:500]
        wall = (time.time() - t) / len(part)
        if error:
            for r in part:
                save(out / (r['id'] + '.error.json'), {**r, 'label': label, 'model': cfg['model'], 'mode': 'native',
                                                     'status': 'error', 'error': error, 'job': os.environ.get('SLURM_JOB_ID')})
            raise RuntimeError(f"{part[0]['id']}: {error}")
        for r, (model_raw, text, boxes, size, usage, finish) in zip(part, results):
            status = 'ok' if finish == 'stop' else 'cap'
            save(out / (r['id'] + '.json'), {**r, 'label': label, 'model': cfg['model'], 'mode': 'native',
                                             'raw': text, 'model_raw': model_raw, 'boxes': boxes,
                                             'image_size': list(size), 'finish': finish, 'status': status,
                                             'error': None, 'usage': usage, 'wall_s': round(wall, 3),
                                             'job': os.environ.get('SLURM_JOB_ID')})
            statuses.append(status)
        print(label, i + len(part), '/', len(todo), flush=True)
    return statuses


def main():
    manifest = sys.argv[1]
    root = Path(os.environ['SESSION_ROOT'])
    parent = root.parent
    cfg = json.loads((root / 'prepared.json').read_text())
    if cfg['state'] != 'ready':
        raise SystemExit(cfg['key'] + ' not ready')
    label = cfg['key']
    t0 = time.time()
    adapter = ADAPTERS[cfg['adapter']](cfg)
    load_s = round(time.time() - t0, 1)
    contract = {'model': cfg['model'], 'revision': cfg['revision'], 'adapter': cfg['adapter'],
                'prompt_sha256': hashlib.sha256(cfg['prompt'].encode()).hexdigest(),
                'runner_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                'parser_sha256': hashlib.sha256(Path(B.__file__).read_bytes()).hexdigest(),
                'max_new_tokens': MAX_NEW, 'greedy': True, 'settings': adapter.settings(),
                'versions': {k: version(k) for k in ('torch', 'transformers', 'vllm', 'docling-core')}}
    contract = json.loads(json.dumps(contract, default=str))
    sweep = root / 'sweep-contract.json'
    if sweep.exists() and json.loads(sweep.read_text()) != contract:
        raise ValueError('settings differ from the 895 run; use a separate experiment')
    binding = root / 'cache-contract.json'
    if binding.exists() and json.loads(binding.read_text()) != contract:
        raise ValueError('Different OCR settings; use a separate experiment')
    save(binding, contract)
    status = {'state': 'pilot', 'job': os.environ.get('SLURM_JOB_ID'), 'load_s': load_s, 'settings': contract}
    save(root / 'status.json', status)
    out = root / 'results/ocr' / label
    out.mkdir(parents=True, exist_ok=True)
    rows_of = lambda name: [json.loads(x) for x in (parent / name).read_text().splitlines() if x.strip()]
    try:
        pilot = rows_of('pilot3.jsonl')
        run_rows(adapter, pilot, root, out, cfg, label)
        for row in pilot:
            answer = json.loads((out / (row['id'] + '.json')).read_text())
            if answer['status'] != 'ok' or not answer['raw'].strip():
                raise ValueError('Pilot failed (capped/empty answer); no full run')
        status.update(state='full', pilot_passed=len(pilot))
        save(root / 'status.json', status)
        rows = rows_of(manifest)
        assert len({r['id'] for r in rows}) == len(rows)
        t = time.time()
        run_rows(adapter, rows, root, out, cfg, label)
        counts = {'ok': 0, 'cap': 0}
        for row in rows:
            answer = json.loads((out / (row['id'] + '.json')).read_text())
            if any(answer.get(k) != row[k] for k in ('id', 'sha256')) or answer['model'] != cfg['model']:
                raise ValueError('Cached page/model identity differs')
            counts[answer['status']] += 1
        status.update(state='completed_raw', terminal=len(rows), counts=counts, wall_s=round(time.time() - t, 1))
    except Exception as exc:
        status.update(state='needs_inspection', error=str(exc)[:1000])
        save(root / 'status.json', status)
        raise
    save(root / 'status.json', status)
    save(out / 'summary.json', {'label': label, 'expected': len(rows), **counts, 'model': cfg['model'],
                                'job': os.environ.get('SLURM_JOB_ID'), 'load_s': load_s, 'wall_s': status['wall_s']})


if __name__ == '__main__':
    main()
