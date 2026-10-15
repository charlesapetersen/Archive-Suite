#!/usr/local/bin/python3
"""W41.ocr-panel-cloud: ONLY the owner's three-page pilot, never the full panel.

prepare -> pilot -> report. Raw material stays in OCR_CLOUD_CACHE (default /tmp).
The full 99-page run requires a new owner answer and deliberately has no command here.
"""
from __future__ import annotations
import argparse
import json
import math
import os
from pathlib import Path
import shutil

import ocr_panel as P

CACHE = Path(os.environ.get('OCR_CLOUD_CACHE', '/tmp/w41-ocr-panel-cloud'))
LOCAL = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/ocr-panel-local'
CAP = .75  # includes the dedicated Mistral OCR pilot, if available
MISTRAL_RESERVE = .012  # OCR latest resolves to 4.1: three pages, $4/1000 pages
INPUT_BOUND = 32768
MODELS = {
 'gemini3.1-pro': ('google/gemini-3.1-pro-preview', 'google-ai-studio', None, 'low', None),
 'gemini3.5-flash': ('google/gemini-3.5-flash', 'google-ai-studio', None, 'minimal', None),
 'gemini3.8-flash': ('google/gemini-3.8-flash', 'google-ai-studio', None, 'low', None),
 'gemini3.5-flash-lite': ('google/gemini-3.5-flash-lite', 'google-ai-studio', None, 'minimal', None),
 'claude-sonnet5.5': ('anthropic/claude-sonnet-5.5', 'anthropic', None, 'off', None),
 'gpt5.6-sol': ('openai/gpt-5.6-sol', 'openai', None, 'off', None),
 'gpt5.6-luna': ('openai/gpt-5.6-luna', 'openai', None, 'off', None),
 'gpt5.4-mini': ('openai/gpt-5.4-mini', 'openai', None, 'minimal', None),
 'mistral-medium3.5': ('mistralai/mistral-medium-3-5', 'mistral', None, 'off', None),
 'mistral-large4': ('mistralai/mistral-large-4-0', 'mistral', None, 'off', None),
 'qwen3.5-397b': ('qwen/qwen3.5-397b-a17b', 'deepinfra/fp8', 'fp8', 'off', None),
 'qwen3-vl-235b': ('qwen/qwen3-vl-235b-a22b-instruct', 'deepinfra/fp8', 'fp8', None, None),
}
_base_body, _base_manifest, _base_endpoint = P.body, P.manifest, P.endpoint


def reservation(e):
    """One JPEG + short prompt: reserve 32K input for the documented bounded families.

    Claude >=4.7: <=4784 visual tokens, platform.claude.com/docs/en/build-with-claude/vision
    OpenAI exact three models at detail=high: <=2500 patches *1.2,
      developers.openai.com/api/docs/guides/images-vision
    Gemini: largest documented resolution tier 2240 tokens (approximate table),
      ai.google.dev/gemini-api/docs/media-resolution
    32K includes generous text/envelope headroom, not an image-token measurement.
    Mistral/Qwen retain the entire endpoint context bound. No tools, extra images,
    cache writes or web search. Published long-context price overrides are included
    whenever their threshold could be reached by this reservation.
    """
    p = e['pricing']; model = e['_model']
    bounded = model.startswith(('google/', 'openai/', 'anthropic/'))
    n = min(INPUT_BOUND, int(e['context_length'])) if bounded else int(e['context_length'])
    rates = [p] + [r for r in p.get('overrides', []) if r.get('min_prompt_tokens', 0) <= n]
    prompt = max(float(r.get('prompt', p['prompt'])) for r in rates)
    output = max(float(r.get('completion', p['completion'])) for r in rates)
    if float(p.get('image', 0)) > prompt:
        raise SystemExit('image price exceeds reserved prompt unit price')
    if float(p.get('internal_reasoning', 0)) > output:
        raise SystemExit('reasoning price exceeds reserved output unit price')
    if float(p.get('request', 0)):
        raise SystemExit('unhandled per-request fee')
    reserve = n * prompt + P.MAX_TOKENS * output
    if not math.isfinite(reserve) or reserve <= 0:
        raise SystemExit('invalid reservation')
    return reserve


def body(key, job, prices):
    b = _base_body(key, job, prices)
    b['provider']['require_parameters'] = True
    if MODELS[key][0].startswith(('openai/', 'anthropic/')):
        b.pop('temperature')  # not supported on these endpoints
    if MODELS[key][0].startswith('openai/'):
        b['messages'][0]['content'][0]['image_url']['detail'] = 'high'
    return b


def endpoint(key):
    e = {**_base_endpoint(key), '_model': MODELS[key][0]}
    if e['_model'].startswith(('google/', 'openai/', 'anthropic/')):
        e['_input_bound'] = INPUT_BOUND
    required = {'max_tokens'} | ({'reasoning'} if MODELS[key][3] else set())
    if not required.issubset(e.get('supported_parameters', [])):
        raise SystemExit('pinned endpoint lacks required controls: ' + key)
    reservation(e)  # validate all pricing before key access
    return e


def manifest():
    m = _base_manifest()
    if m.get('pilot_pages') != sorted(P.PROBE) or m.get('cap') != CAP:
        raise SystemExit('not the approved cloud pilot')
    jobs = m['jobs']
    if (len(jobs) != 3 or {j['page'] for j in jobs} != P.PROBE
            or any(j['scale'] != 'original' or j['id'] != j['page'] + '-original'
                   or not (0 < j['width'] <= P.SIDE and 0 < j['height'] <= P.SIDE) for j in jobs)):
        raise SystemExit('pilot accepts exactly three frozen original images')
    if len(P.PROMPT.encode()) + 1024 + 4784 >= INPUT_BOUND:
        raise SystemExit('prompt/envelope no longer fits documented input bound')
    return m


def configure():
    P.CACHE, P.MODELS, P.CAP = CACHE, MODELS, CAP - MISTRAL_RESERVE
    P.body, P.manifest, P.endpoint, P.reservation = body, manifest, endpoint, reservation
    P.estimate = lambda: print(f"Chat pilot accounted ${P.spent():.6f}; full run requires owner approval.")
    os.environ['OCR_PANEL_CONCURRENCY'] = '1'


def prepare():
    # Reuse the exact local-panel JPEG bytes; do not open the corpus or re-encode them.
    local = json.loads((LOCAL / 'manifest.json').read_text())
    if local['prompt'] != P.PROMPT:
        raise SystemExit('local/cloud prompt differs')
    jobs = [j for j in local['jobs'] if j['page'] in P.PROBE and j['scale'] == 'original']
    m = {**local, 'jobs': jobs, 'models': MODELS, 'pilot_pages': sorted(P.PROBE), 'cap': CAP}
    dest = CACHE / 'manifest.json'
    if dest.exists() and json.loads(dest.read_text()) != json.loads(json.dumps(m)):
        raise SystemExit('cloud manifest changed; preserve existing run')
    for j in jobs:
        src = LOCAL / 'images' / (j['id'] + '.jpg')
        if P.digest(src.read_bytes()) != j['sha256']:
            raise SystemExit('local frozen image changed')
        target = CACHE / 'images' / src.name
        if target.exists() and target.read_bytes() != src.read_bytes():
            raise SystemExit('cloud frozen image changed')
    for j in jobs:
        src = LOCAL / 'images' / (j['id'] + '.jpg')
        (CACHE / 'images').mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, CACHE / 'images' / src.name)
    P.save(dest, m)
    manifest()  # hashes truth through original manifest validator
    print('Frozen three originals, twelve routes, $0.75 combined ceiling; full run unavailable.')


def pilot():
    manifest()
    validate_ledger()
    P.collect(probe=True)
    validate_ledger()


def validate_ledger():
    for r in P.records():
        if r.get('cost', 0) > r.get('reserve', float('inf')):
            raise SystemExit('prior price/context reservation exceeded; do not continue')
        if r.get('prompt_tokens', 0) and r['model'].startswith(('google/', 'openai/', 'anthropic/')):
            if r['prompt_tokens'] > INPUT_BOUND:
                raise SystemExit('documented input bound exceeded; do not continue')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('command', choices=['prepare', 'pilot', 'report'])
    args = ap.parse_args()
    configure()
    if args.command == 'prepare':
        prepare()
    elif args.command == 'pilot':
        pilot()
    else:
        import ocr_cloud_report
        ocr_cloud_report.report()


if __name__ == '__main__':
    main()
