#!/usr/bin/env python3
"""W46.gemini4-hydrogen-96. Gemini 4 Hydrogen on the owner's 96, through the personal AI Studio key:

  python3 ocr_hydrogen96.py models                 # free: the key's models list, Hydrogen's entry frozen into CACHE
  python3 ocr_hydrogen96.py probe                  # one page, to check the request shape and the usage fields
  python3 ocr_hydrogen96.py panel [--arm low]      # the 99 settled jobs (the 96 plus three agreement letters)
  python3 ocr_hydrogen96.py panel --arm default    # second arm, Hydrogen's own default thinking (no thinkingConfig)
  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy \
      python ocr_hydrogen96.py report              # against the cached Gemini 3.8 Flash -> segbench-results/

The arm copies the cloud panel's Gemini 3.8 Flash row (`ocr_cloud.py`'s `gemini3.8-flash`): the same frozen 2,400 px
JPEGs (ocr-panel-cloud/images, checked against the manifest's hashes), the same prompt, image first then text,
temperature 0, 8,192 output tokens, thinking level low, and no media-resolution setting (the panel's OpenRouter request
set none, so both run at the API's default). It calls AI Studio's v1beta `generateContent` directly, as
`method_gemini.py` does. The key is the personal one (Keychain service com.archiveprocessor.app, account Gemini), read
into memory once, sent only as the `x-goog-api-key` header, never printed or written; it is a prepaid paid-tier key
(root CLAUDE.md's exception to 1 Dec 2026, $5 in all across items). Real money: CAP bounds this item, counted from the
billed usage (`usageMetadata`) at Hydrogen's list price, thinking billed as output, and a call is refused unless its
worst case still fits. A 402 or a billing error stops the run without retrying. The ledger is CACHE/calls.jsonl.
Images, replies and readings stay in the cache (the owner's material); no truth text is sent.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]

API = 'https://generativelanguage.googleapis.com/v1beta/models'
MODEL = 'gemini-4-hydrogen'
ARMS = {'low': {'thinkingLevel': 'low'}, 'default': None}   # None: no thinkingConfig, the model's default
REHEARSAL = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
CACHE = REHEARSAL / 'gemini4-hydrogen-96'
PANEL = REHEARSAL / 'ocr-panel-cloud'          # the 3.8 run: manifest, images, responses/gemini3.8-flash
RESULTS = HERE.parents[1] / 'segbench-results'
# $ per million tokens (input, output incl. thinking): Google's list price for Gemini 4 Hydrogen, standard tier,
# November 2026, as the item states it. The models endpoint carries no prices.
PRICE = (1.50, 7.50)
CAP = 2.00            # the item's cap, of the $5 the personal key may spend across items to 1 Dec
MAX_TOKENS = 8192     # the panel's
WORST = (4000 * PRICE[0] + MAX_TOKENS * PRICE[1]) / 1e6   # one call's worst case, reserved before it is made
_key = None


class Stop(SystemExit):
    pass


def api_key() -> str:
    """Read once from the Keychain into memory. Never printed or written."""
    global _key
    if _key is None:
        r = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s', 'com.archiveprocessor.app',
                            '-a', 'Gemini', '-w'], capture_output=True, text=True)
        if r.returncode != 0 or not r.stdout.strip():
            raise Stop('no Gemini key in the Keychain (com.archiveprocessor.app / Gemini)')
        _key = r.stdout.strip()
    return _key


def request(path, body=None, timeout=300):
    import requests
    h = {'x-goog-api-key': api_key()}
    if body is None:
        return requests.get(API + path, headers=h, timeout=timeout)
    return requests.post(API + path, headers=h, json=body, timeout=timeout)


def ledger():
    f = CACHE / 'calls.jsonl'
    return [json.loads(x) for x in f.read_text().splitlines()] if f.exists() else []


def spent():
    return sum(r.get('cost') or 0 for r in ledger())


def cost(u):
    out = (u.get('candidatesTokenCount') or 0) + (u.get('thoughtsTokenCount') or 0)
    return ((u.get('promptTokenCount') or 0) * PRICE[0] + out * PRICE[1]) / 1e6


def models():
    r = request('?pageSize=1000', timeout=60)
    if r.status_code != 200:
        raise Stop(f'models list answered {r.status_code}: {r.text[:300]}')
    entry = next((m for m in r.json().get('models', []) if m.get('name') == 'models/' + MODEL), None)
    if entry is None:
        raise Stop(MODEL + ' is not served to this key')
    CACHE.mkdir(parents=True, exist_ok=True)
    (CACHE / 'model.json').write_text(json.dumps(entry, indent=1))
    print(json.dumps(entry, indent=1))


def body(image: bytes, prompt: str, arm: str):
    g = {'temperature': 0, 'maxOutputTokens': MAX_TOKENS}
    if ARMS[arm] is not None:
        g['thinkingConfig'] = ARMS[arm]
    return {'contents': [{'role': 'user', 'parts': [
                {'inlineData': {'mimeType': 'image/jpeg', 'data': base64.b64encode(image).decode()}},
                {'text': prompt}]}],
            'generationConfig': g}


_lock = __import__('threading').Lock()


def call(arm, job_id, image: bytes, prompt: str, dest: Path):
    """One reading, cached by destination; the ledger line is written before the reply is used."""
    if dest.exists():
        return json.loads(dest.read_text())
    with _lock:   # reserve the worst case: spent plus every call in flight
        call.inflight = getattr(call, 'inflight', 0)
        if spent() + (call.inflight + 1) * WORST > CAP:
            raise Stop(f'cap: ${spent():.4f} spent of ${CAP}')
        call.inflight += 1
    try:
        b = body(image, prompt, arm)
        t = time.time()
        for attempt in range(4):
            r = request(f'/{MODEL}:generateContent', b)
            if r.status_code in (429, 500, 502, 503, 504) and attempt < 3:
                time.sleep(15 * (attempt + 1)); continue
            break
        got = r.json() if r.headers.get('content-type', '').startswith('application/json') else {'raw': r.text[:2000]}
        u = got.get('usageMetadata') or {}
        rec = {'arm': arm, 'job': job_id, 'http': r.status_code, 't': t, 'wall_s': round(time.time() - t, 3),
               'model': got.get('modelVersion'), 'usage': u, 'cost': round(cost(u), 6),
               'request_sha256': hashlib.sha256(json.dumps(b, sort_keys=True).encode()).hexdigest()}
        with _lock:
            CACHE.mkdir(parents=True, exist_ok=True)
            with (CACHE / 'calls.jsonl').open('a') as f:
                f.write(json.dumps(rec) + '\n')
    finally:
        with _lock:
            call.inflight -= 1
    msg = json.dumps(got)[:400]
    if r.status_code == 402 or 'billing' in msg.lower() or 'FREE_TIER' in msg or 'free_tier' in msg:
        raise Stop(f'{job_id}: {r.status_code} {msg}')
    cand = (got.get('candidates') or [{}])[0]
    parts = (cand.get('content') or {}).get('parts') or []
    raw = ''.join(p.get('text', '') for p in parts if not p.get('thought')) if r.status_code == 200 else None
    out = {'meta': {**rec, 'finish': cand.get('finishReason')}, 'raw': raw or None,
           'error': None if r.status_code == 200 else got}
    if r.status_code == 200:
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(json.dumps(out, ensure_ascii=False, indent=1))
    else:
        print(job_id, r.status_code, msg[:300])
    return out


def parsed(reply):
    import ocr_truth as T
    raw = reply.get('raw') if reply else None
    return T.parse_draft(raw) if raw else None


def panel_manifest():
    m = json.loads((PANEL / 'manifest.json').read_text())
    return m, [j for j in m['jobs'] if j['scale'] == 'original']


def image(j):
    b = (PANEL / 'images' / (j['id'] + '.jpg')).read_bytes()
    if hashlib.sha256(b).hexdigest() != j['sha256']:
        raise Stop('image changed: ' + j['id'])
    return b


def panel(arm, concurrency=4):
    m, jobs = panel_manifest()
    todo = [(j['id'], image(j), CACHE / arm / (j['id'] + '.json')) for j in jobs]
    with ThreadPoolExecutor(concurrency) as ex:
        res = list(ex.map(lambda j: (j[0], call(arm, j[0], j[1], m['prompt'], j[2])), todo))
    bad = [i for i, r in res if not parsed(r)]
    print(f'{arm}: {len(res) - len(bad)}/{len(res)} parsed, ${spent():.4f} spent in all; unparsed: {bad}')


def probe():
    m, jobs = panel_manifest()
    j = jobs[0]
    reply = call('low', j['id'], image(j), m['prompt'], CACHE / 'low' / (j['id'] + '.json'))
    print(json.dumps(reply['meta'], indent=1)); print((reply.get('raw') or '')[:300])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['models', 'probe', 'panel', 'report'])
    ap.add_argument('--arm', choices=sorted(ARMS), default='low')
    a = ap.parse_args()
    if a.command == 'panel':
        panel(a.arm)
    elif a.command == 'report':
        import ocr_hydrogen96_report
        ocr_hydrogen96_report.report()
    else:
        {'models': models, 'probe': probe}[a.command]()


if __name__ == '__main__':
    main()
