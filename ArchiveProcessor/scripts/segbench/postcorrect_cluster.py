#!/usr/bin/env python3
"""The cluster half of W46.ocr-postcorrect and W46.date-image: send a pack's requests to a local vLLM server; stdlib only.

    python3 postcorrect_cluster.py --root ROOT [--concurrency 8] [--limit N]

ROOT holds requests.jsonl (and any images the pack uploads). Each reply is saved as ROOT/out/<id>.json; a request already
answered is not sent again, so a resubmitted job only does what is left. An image whose hash differs from the
request's is refused, never sent. Temperature 0, thinking off, max_tokens 8192, as the open sweep's collector.
"""
import argparse, base64, concurrent.futures as cf, hashlib, json, os, pathlib, time, urllib.request

ap = argparse.ArgumentParser(); ap.add_argument('--root', type=pathlib.Path, required=True)
ap.add_argument('--concurrency', type=int, default=8); ap.add_argument('--limit', type=int, default=0)
a = ap.parse_args()
url, model = os.environ['FS_URL'], os.environ['FS_SERVED']
out = a.root / 'out'; out.mkdir(exist_ok=True)
reqs = [json.loads(l) for l in (a.root / 'requests.jsonl').read_text().splitlines()]
if a.limit:
    reqs = reqs[:a.limit]
todo = [r for r in reqs if not (out / f"{r['id']}.json").exists()]


def send(r):
    content = []
    # One image (`image`, `image_sha256`) or several in order (`images`, `image_sha256s`), as the pack gives them.
    pairs = list(zip(r.get('images') or [], r.get('image_sha256s') or []))
    if r.get('image'):
        pairs.append((r['image'], r['image_sha256']))
    for path, digest in pairs:
        b = pathlib.Path(path).read_bytes()
        if hashlib.sha256(b).hexdigest() != digest:
            raise ValueError('image hash differs: ' + path)
        content.append({'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,' + base64.b64encode(b).decode()}})
    content.append({'type': 'text', 'text': r['prompt']})
    body = {'model': model, 'messages': [{'role': 'user', 'content': content}], 'temperature': 0, 'max_tokens': 8192,
            'chat_template_kwargs': {'enable_thinking': False}}
    t = time.time()
    q = urllib.request.Request(url + '/v1/chat/completions', json.dumps(body).encode(), {'Content-Type': 'application/json'})
    got = json.load(urllib.request.urlopen(q, timeout=1800))
    c = got['choices'][0]
    rec = {'id': r['id'], 'text': c['message'].get('content') or '', 'finish': c.get('finish_reason'),
           'usage': got.get('usage'), 'seconds': round(time.time() - t, 1), 'job': os.environ.get('SLURM_JOB_ID')}
    tmp = out / f"{r['id']}.part"; tmp.write_text(json.dumps(rec, ensure_ascii=False)); tmp.replace(out / f"{r['id']}.json")
    return rec


start, ok, cap, err = time.time(), 0, 0, 0
with cf.ThreadPoolExecutor(a.concurrency) as pool:
    for f in cf.as_completed([pool.submit(send, r) for r in todo]):
        try:
            rec = f.result(); ok += rec['finish'] == 'stop'; cap += rec['finish'] == 'length'
        except Exception as e:
            err += 1; print('error:', e, flush=True)
print(json.dumps({'requests': len(reqs), 'sent': len(todo), 'stop': ok, 'capped': cap, 'errors': err,
                  'wall_s': round(time.time() - start, 1), 'model': model, 'job': os.environ.get('SLURM_JOB_ID')}))
raise SystemExit(1 if err else 0)
