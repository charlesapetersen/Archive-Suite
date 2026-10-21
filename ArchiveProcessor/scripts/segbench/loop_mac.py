#!/usr/bin/env python3
"""W46.ocr-loops, the Mac arm: the 96's pages that Qwen3-VL 8B 4-bit looped on (W41.mac-local-measure) read again.

  run-guarded.sh --label mac-loops --need-gb 8 -- <lab venv>/bin/python loop_mac.py collect
  python3 loop_mac.py self-test

The same model, prompt, 8,192 tokens and temperature 0 as `ocr_mac_local.py collect`, with one change per arm, the
cluster arms' (`corpus/loop_rerun_cluster.py`):

  ngram  no 4-token sequence of the reply may occur twice (Hugging Face's no_repeat_ngram_size=4, counted over the
         generated tokens only, as vLLM's NGramPerReqLogitsProcessor counts them), as an mlx-vlm logits processor;
  half   the same JPEG at half its long edge (2400 -> 1200 px, Lanczos, JPEG 90), plain greedy decoding.

Readings go to CACHE/local/qwen3-vl-8b-mlx4-loops/<arm>/<page>.json in ocr_mac_local's shape. No money.
"""
from __future__ import annotations
import argparse
import tempfile
import time
from pathlib import Path

import ocr_mac_local as M
import ocr_panel as P

PAGES = ('p018-original', 'p031-original', 'p071-original')   # the three 8,192-token loops in ocr-mac-local.md
NGRAM = 4
OUT = P.CACHE / 'local' / (M.KEY + '-loops')


class NoRepeatNGram:
    """Bans any token that would complete an n-gram already generated. The first call sees the prompt only."""

    def __init__(self, n=NGRAM):
        self.n, self.start, self.out, self.seen = n, None, [], {}

    def banned(self, token=None):
        if token is not None:
            self.out.append(token)
            if len(self.out) >= self.n:
                self.seen.setdefault(tuple(self.out[-self.n:-1]), set()).add(self.out[-1])
        return self.seen.get(tuple(self.out[-(self.n - 1):]), set()) if len(self.out) >= self.n - 1 else set()

    def __call__(self, tokens, logits):
        import mlx.core as mx
        if self.start is None:
            self.start = tokens.size
            ban = self.banned()
        else:
            ban = self.banned(int(tokens[-1].item()))
        if ban:
            logits[:, mx.array(sorted(ban))] = -float('inf')
        return logits


def half(path, dest):
    from PIL import Image
    im = Image.open(path); im.load()
    w, h = im.size
    im.convert('RGB').resize((max(1, round(w / 2)), max(1, round(h / 2))), Image.LANCZOS).save(dest, 'JPEG', quality=90)
    return dest


def collect():
    import mlx.core as mx
    import mlx_vlm
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    jobs = {j['id']: j for j in M.jobs()}
    todo = [(arm, jobs[p]) for arm in ('ngram', 'half') for p in PAGES if not (OUT / arm / (p + '.json')).exists()]
    print(f'{len(todo)} readings to make', flush=True)
    if not todo:
        return
    mx.set_cache_limit(256 * 2**20)
    t0 = time.time(); model, processor = load(M.REPO); load_s = time.time() - t0
    chat = apply_chat_template(processor, model.config, P.PROMPT, num_images=1)
    tmp = Path(tempfile.mkdtemp(prefix='mac-loops-'))
    for arm, job in todo:
        image = P.CACHE / 'images' / (job['id'] + '.jpg')
        if P.digest(image.read_bytes()) != job['sha256']:
            raise SystemExit('image changed: ' + job['id'])
        kw = {}
        if arm == 'half':
            image = half(image, tmp / (job['id'] + '.jpg'))
        else:
            kw['logits_processors'] = [NoRepeatNGram()]
        mx.reset_peak_memory()
        start = time.time(); first = None; text = []; last = None
        for r in stream_generate(model, processor, chat, image=[str(image)], max_tokens=P.MAX_TOKENS, temperature=0.0, **kw):
            first = first or time.time(); text.append(r.text); last = r
        wall = time.time() - start
        raw = ''.join(text); got = M.parse({'reply': 'panel'}, raw)
        finish = 'length' if last is not None and last.generation_tokens >= P.MAX_TOKENS else 'stop'
        meta = {'key': M.KEY, 'arm': arm, 'job': job['id'], 'page': job['page'], 'model': M.REPO,
                'runtime': 'mlx-vlm ' + mlx_vlm.__version__, 'status': 'ok' if got and finish == 'stop' else 'failed',
                'finish': finish, 'wall_s': round(wall, 2), 'first_token_s': round((first or start + wall) - start, 2),
                'prompt_tokens': getattr(last, 'prompt_tokens', 0), 'completion_tokens': getattr(last, 'generation_tokens', 0),
                'gen_tps': round(getattr(last, 'generation_tps', 0.0), 1), 'mlx_peak_gb': round(mx.get_peak_memory() / 2**30, 2),
                'load_s': round(load_s, 1), 'settings': {'ngram_size': NGRAM} if arm == 'ngram' else {'scale': 0.5, 'jpeg_quality': 90},
                't': time.time()}
        P.save(OUT / arm / (job['id'] + '.raw.json'), {'text': raw})
        P.save(OUT / arm / (job['id'] + '.json'), {'meta': meta, 'parsed': got if meta['status'] == 'ok' else None})
        print(f"{arm} {job['id']} {meta['status']} {meta['finish']} {meta['wall_s']}s {meta['completion_tokens']} tok", flush=True)


def self_test():
    p = NoRepeatNGram(3)
    p.start = 0
    for t in (1, 2, 3, 1):
        p.banned(t)
    assert p.banned(2) == {3}, 'after 1 2 3 1 2, 3 would repeat the 3-gram 1 2 3'
    assert p.banned(5) == set()
    print('self-test ok')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['collect', 'self-test'])
    a = ap.parse_args()
    collect() if a.command == 'collect' else self_test()


if __name__ == '__main__':
    main()
