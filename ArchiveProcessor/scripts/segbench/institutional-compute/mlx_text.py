#!/usr/bin/env python3
"""Measure a locally converted MLX model on the unchanged text packs, under the Mac memory guard.

  mlx_text.py --model DIR --out DIR --label L --pack corpus=DIR --pack public=DIR

No network calls; writes only raw benchmark answers and timing in --out. Each pack is requests.jsonl.
The answer schema is cluster_text.py's, so the existing dating import/scoring commands are unchanged.
"""
import argparse
import hashlib
import json
from pathlib import Path
import time


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--model', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--label', required=True)
    ap.add_argument('--pack', action='append', required=True, help='name=directory')
    a = ap.parse_args()
    import mlx.core as mx
    from mlx_vlm import load, generate
    from mlx_vlm.prompt_utils import apply_chat_template
    mx.set_cache_limit(256 * 2**20)
    t0 = time.monotonic()
    model, processor = load(str(a.model))
    load_s = time.monotonic() - t0
    for arg in a.pack:
        name, source = arg.split('=', 1)
        requests = Path(source) / 'requests.jsonl'
        rows = [json.loads(line) for line in requests.open()]
        dest = a.out / name / a.label
        dest.mkdir(parents=True, exist_ok=True)
        settings = {'model': str(a.model.resolve()), 'label': a.label,
                    'requests_sha256': hashlib.sha256(requests.read_bytes()).hexdigest(),
                    'config_sha256': hashlib.sha256((a.model / 'config.json').read_bytes()).hexdigest(),
                    'max_tokens': 512, 'temperature': 0, 'thinking': False}
        frozen = dest / 'run.json'
        if frozen.exists() and json.loads(frozen.read_text()) != settings:
            raise SystemExit('Run settings changed; choose another label/output instead of mixing answers')
        frozen.write_text(json.dumps(settings, indent=2))
        answers = dest / 'answers.jsonl'
        done = {json.loads(line)['id'] for line in answers.open()} if answers.exists() else set()
        start = time.monotonic()
        n = 0
        for row in rows:
            if row['id'] in done:
                continue
            chat = apply_chat_template(processor, model.config, row['prompt'], num_images=0, enable_thinking=False)
            t1 = time.monotonic()
            reply = generate(model, processor, chat, max_tokens=512, temperature=0.0, verbose=False)
            tokens = getattr(reply, 'generation_tokens', 0)
            record = {'id': row['id'], 'raw': reply.text, 'finish': 'length' if tokens >= 512 else 'stop',
                      'usage': {'prompt_tokens': getattr(reply, 'prompt_tokens', 0), 'completion_tokens': tokens},
                      'wall_s': round(time.monotonic() - t1, 3), 'peak_gb': round(mx.get_peak_memory() / 2**30, 3)}
            with answers.open('a') as fh:
                fh.write(json.dumps(record, ensure_ascii=False) + '\n')
                fh.flush()
            done.add(row['id'])
            n += 1
            if n % 20 == 0:
                print(name, len(done), '/', len(rows), 'peak GB', record['peak_gb'], flush=True)
            mx.clear_cache()
        summary = {'model': str(a.model), 'label': a.label, 'pack': name, 'requests': len(rows),
                   'completed': len(done), 'new_answers': n, 'load_s': round(load_s, 2),
                   'wall_s': round(time.monotonic() - start, 2), 'peak_gb': round(mx.get_peak_memory() / 2**30, 3)}
        (dest / 'summary.json').write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary), flush=True)


if __name__ == '__main__':
    main()
