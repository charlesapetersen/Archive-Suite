#!/usr/bin/env python3
"""W43.corpus-build — the three reference routes on the frozen public pages (plan §7 step 7).

  routes.py prepare            # frozen manifest -> JPEG inputs (the panel's 2400 px, quality 90), checksums checked
  routes.py probe              # the first PROBE pages of the run order, both paid routes; prints the projection
  routes.py collect            # every page, both paid routes, under CAP (all attempts count)
  routes.py vision             # Apple Vision on the Latin-script pages (the app's settings, en-US)
  routes.py reconcile          # bound uncertain charges by the key's UTC-day billing (the panel's rule)
  routes.py reask              # after reconcile: ask again the calls this runner's interruption cut off
  routes.py report             # scores by stratum -> segbench-results/bench-corpus/routes.*

The paid calls go through ocr_panel.collect with ocr_cloud's pinned endpoints, bodies and reservations, so this
run keeps the panel's write-ahead ledger: an uncertain call is never silently retried, and the cap counts every
attempt. Prompt, routes and image sizing are the 96's, unchanged, so a route's public score sits beside its S0
score. Raw replies and images stay in CACHE; the repo gets aggregates only.

Cap (owner, 2026-10-16 walkthrough): $5.10 for corpus-build, W43.corpus-build-more included. This run's CAP is
the share for the strata frozen here; the rest stays for the strata W43.corpus-build-more adds.
"""
from __future__ import annotations

import argparse
import collections
import io
import json
import os
import random
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import common as C          # noqa: E402
import ocr_cloud as OC       # noqa: E402
import ocr_panel as P        # noqa: E402

RUN = C.CACHE / 'routes'
RESULTS = HERE.parents[2] / 'segbench-results' / 'bench-corpus'
MANIFEST = RESULTS / 'manifest.jsonl'
INDEX = C.FROZEN / 'index.jsonl'
ROUTES = {k: OC.MODELS[k] for k in ('gemini3.8-flash', 'qwen3-vl-235b')}
# Of the $5.10. The 30-page probe (2026-10-17) measured $0.00334 a page for Gemini and $0.00217 for Qwen: about
# $2.49 for the 440 pages. The cap check also counts the reservations in flight (about $0.06 a call), so $2.60
# would stop the run near 85%; $2.90 leaves W43.corpus-build-more $2.20 of the item's cap.
CAP = 2.90
PROBE = 30
VISION_SCRIPTS = {'Latn'}


def key(r):
    return r['source'] + ':' + r['page_id']


def job_id(r):
    return key(r).replace(':', '__').replace('/', '_')


def frozen():
    """The committed manifest joined to the kept copies (sample.py keep; FROZEN/index.jsonl). Every checksum must
    match: a page whose bytes moved since the freeze is not the frozen page."""
    kept = {r['key']: {'image': str(C.FROZEN / r['image']), 'truth': str(C.FROZEN / r['truth'])}
            for r in C.read_jsonl(INDEX)}
    rows = []
    for m in C.read_jsonl(MANIFEST):
        d = kept.get(key(m))
        if d is None:
            raise SystemExit(f'{key(m)}: frozen but not kept (run sample.py keep)')
        if C.sha256(Path(d['image'])) != m['image_sha256'] or C.sha256(Path(d['truth'])) != m['truth_sha256']:
            raise SystemExit(f'{key(m)}: image or truth differs from the frozen checksum')
        rows.append({**m, 'image': d['image'], 'truth': d['truth']})
    return rows


def run_order(jobs):
    """A fixed shuffle, so the probe's first pages cover every stratum rather than the first one."""
    jobs = sorted(jobs, key=lambda j: j['id'])
    random.Random('W43.corpus-build/routes').shuffle(jobs)
    return jobs


def prepare():
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None   # archival scans; the files are checked against the frozen checksums
    jobs = []
    for r in frozen():
        with Image.open(r['image']) as im:
            im = im.convert('RGB')
            im.thumbnail((P.SIDE, P.SIDE), Image.Resampling.LANCZOS)
            out = io.BytesIO(); im.save(out, 'JPEG', quality=90)
            b = out.getvalue()
        jid = job_id(r)
        dest = RUN / 'images' / (jid + '.jpg')
        if dest.exists() and dest.read_bytes() != b:
            raise SystemExit('a prepared image changed: ' + jid)
        dest.parent.mkdir(parents=True, exist_ok=True)
        if not dest.exists():
            dest.write_bytes(b)
        jobs.append({'page': jid, 'scale': 'original', 'id': jid, 'sha256': P.digest(b),
                     'width': im.width, 'height': im.height, 'stratum': r['stratum'], 'script': r['script']})
    m = {'jobs': run_order(jobs), 'prompt': P.PROMPT, 'models': ROUTES, 'max_tokens': P.MAX_TOKENS,
         'manifest_sha256': C.sha256(MANIFEST)}
    dest = RUN / 'manifest.json'
    if dest.exists() and json.loads(dest.read_text()) != json.loads(json.dumps(m)):
        raise SystemExit('run manifest changed: keep the existing run separate')
    P.save(dest, m)
    print(f'{len(jobs)} inputs; {dict(collections.Counter(j["stratum"] for j in jobs))}')


def manifest(limit=None):
    m = json.loads((RUN / 'manifest.json').read_text())
    if (m['prompt'] != P.PROMPT or m['models'] != json.loads(json.dumps(ROUTES)) or m['max_tokens'] != P.MAX_TOKENS
            or m['manifest_sha256'] != C.sha256(MANIFEST)):
        raise SystemExit('run configuration changed')
    if len(P.PROMPT.encode()) + 1024 + 4784 >= OC.INPUT_BOUND:
        raise SystemExit('prompt/envelope no longer fits the documented input bound')
    return {**m, 'jobs': m['jobs'][:limit]} if limit else m


def configure(limit=None):
    P.CACHE, P.MODELS, P.CAP = RUN, ROUTES, CAP
    OC.MODELS.update(ROUTES)
    P.body, P.endpoint, P.reservation = OC.body, OC.endpoint, OC.reservation
    P.manifest = lambda: manifest(limit)
    P.estimate = lambda: estimate()
    os.environ.setdefault('OCR_PANEL_CONCURRENCY', '4')   # fewer reservations held against the cap


def estimate():
    n = len(manifest()['jobs']); total = 0
    print(f'ITEM SPENT ${P.spent():.6f} of the ${CAP:.2f} run cap')
    for k in ROUTES:
        # A call bounded by reconcile is booked at a ceiling, not measured; it would inflate the average.
        calls = [r for r in P.records() if r['key'] == k and r['status'] in ('ok', 'failed')
                 and not r.get('cost_upper_bound')]
        if not calls:
            continue
        avg = sum(r['cost'] for r in calls) / len(calls); total += avg * n
        toks = [r for r in calls if r.get('prompt_tokens')]
        print(f'{k}: n={len(calls)}, ${avg:.6f}/page, prompt {sum(r["prompt_tokens"] for r in toks) / max(1, len(toks)):.0f} '
              f'completion {sum(r["completion_tokens"] or 0 for r in toks) / max(1, len(toks)):.0f} tokens; '
              f'projected {n} pages ${avg * n:.3f}')
    print(f'projection, both routes, all {n} pages: ${total:.3f}')


def reask():
    """Calls cut off by an interruption of this runner (finish 'interrupted', bounded and booked by reconcile)
    are a fact about the session, not the route: left as failures they would count against the route's score.
    Their cached reply is set aside (kept, renamed) so collect asks again; the ledger keeps the booked cost, so
    the cap still counts it. Only interrupted calls: a route's own failure is never re-asked."""
    n = 0
    for f in sorted((RUN / 'responses').glob('*/*.json')):
        if f.name.endswith(('.raw.json', '.interrupted.json')):
            continue
        meta = json.loads(f.read_text()).get('meta') or {}
        if meta.get('finish') == 'interrupted':
            f.rename(f.with_name(f.name[:-5] + '.interrupted.json')); n += 1
            print(f"re-ask {meta['key']} {meta['job']} (booked ${meta['cost']:.6f})")
    print(f'{n} interrupted calls set aside for collect')


def vision():
    m = manifest()
    jobs = [j for j in m['jobs'] if j['script'] in VISION_SCRIPTS]
    tsv = RUN / 'vision-jobs.tsv'
    tsv.write_text(''.join(f"{RUN / 'images' / (j['id'] + '.jpg')}\t{RUN / 'vision' / (j['id'] + '.txt')}\n"
                           for j in jobs if not (RUN / 'vision' / (j['id'] + '.txt')).exists()))
    (RUN / 'vision').mkdir(parents=True, exist_ok=True)
    subprocess.run([str(P.T.OCR_BIN), str(tsv)], check=True)


def report():
    import ocr_panel_score as S
    m = manifest(); truth = {job_id(r): r for r in frozen()}
    out = []
    for j in m['jobs']:
        t = Path(truth[j['id']]['truth']).read_text()
        for k in [*ROUTES, 'apple-vision']:
            if k == 'apple-vision':
                if j['script'] not in VISION_SCRIPTS:
                    continue
                f = RUN / 'vision' / (j['id'] + '.txt')
                attempted, text, meta = f.exists(), (f.read_text() if f.exists() else None), {}
            else:
                f = RUN / 'responses' / k / (j['id'] + '.json')
                got = json.loads(f.read_text()) if f.exists() else {}
                attempted, meta = f.exists(), got.get('meta') or {}
                text = (got.get('parsed') or {}).get('text')
            if not attempted:
                continue
            s = S.score(t, text or '', j['stratum'])
            out.append({'key': k, 'page': j['id'], 'stratum': j['stratum'], 'script': j['script'], 'ok': bool(text), **s,
                        'cost': meta.get('cost', 0), 'prompt_tokens': meta.get('prompt_tokens'),
                        'completion_tokens': meta.get('completion_tokens')})
    P.save(RUN / 'scores.json', out)
    by = collections.defaultdict(list)
    for r in out:
        by[(r['key'], r['stratum'])].append(r); by[(r['key'], 'all')].append(r)
    extra = ['nes_mapped', 'nes_no_marks']
    rows = []
    for (k, s), rr in sorted(by.items()):
        a = S.aggregate(rr)
        for e in extra:
            xs = [r[e] for r in rr if e in r]
            a[e] = sum(xs) / len(xs) if xs and len(xs) == len(rr) else None
        rows.append({'route': k, 'stratum': s, **a})
    fields = ['route', 'stratum', 'n', 'ok', 'failed', 'nes', 'nes_answered', 'nes_mapped', 'nes_no_marks', 'chrf',
              'miss', 'add', 'words', 'cost']
    S.write_csv(RESULTS / 'routes.csv', rows, fields)
    # One row per route and page, for the sweep's difficulty and cascade analysis. Page ids are the public
    # datasets' own; no text leaves the cache.
    S.write_csv(RESULTS / 'routes-pages.csv', [{**r, 'route': r['key']} for r in out],
                ['route', 'page', 'stratum', 'script', 'ok', 'nes', 'nes_mapped', 'nes_no_marks', 'chrf', 'words',
                 'hyp_words', 'cost', 'completion_tokens'])
    # Separation: the two paid routes paired page by page, within each stratum and pooled.
    pairs = {}
    a_key, b_key = ROUTES
    for s in sorted({r['stratum'] for r in out}) + ['all']:
        sa = [r for r in out if r['key'] == a_key and (s == 'all' or r['stratum'] == s)]
        sb = [r for r in out if r['key'] == b_key and (s == 'all' or r['stratum'] == s)]
        if len(sa) == len(sb) and sa:
            pairs[s] = S.paired([r['nes'] for r in sa], [r['nes'] for r in sb], rounds=2000)
    P.save(RESULTS / 'routes-paired.json', {'a': a_key, 'b': b_key, 'by_stratum': pairs,
                                             'spent': P.spent(), 'cap': CAP})
    for r in rows:
        print(f"{r['route']:16s} {r['stratum']:4s} n={r['n']:3d} ok={r['ok']:3d} NES {r['nes']:.3f} "
              f"answered {r['nes_answered']:.3f} chrF {r['chrf']:.3f} ${r['cost']:.4f}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['prepare', 'probe', 'collect', 'vision', 'reconcile', 'reask', 'report'])
    a = ap.parse_args()
    if a.command == 'prepare':
        return prepare()
    configure(PROBE if a.command == 'probe' else None)
    if a.command in ('probe', 'collect'):
        P.collect()
    else:
        {'vision': vision, 'reconcile': P.reconcile, 'reask': reask, 'report': report}[a.command]()


if __name__ == '__main__':
    main()
