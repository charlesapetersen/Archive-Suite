#!/usr/bin/env python3
"""W46.ocr-gemini37-895-paid. Gemini 3.7 Flash, the gateway default, on the 895 frozen public pages.

  python3 ocr_gemini37_public.py prepare   # the 895's inputs: the 440 reference images, the other 455 made alike
  python3 ocr_gemini37_public.py probe     # one page, to check the request and the usage fields
  python3 ocr_gemini37_public.py run       # every page, under CAP
  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy \
      python ocr_gemini37_public.py report # 3.7 against the cached 3.8 on the 440 -> segbench-results/

The both-sets rule (owner, 2026-10-20) and the measurement audit's OCR-9: Gemini 3.7 Flash had read only the 96.
This reads the 895 with W46.gemini37-vs-38's settings (gateway_gemini.body: the panel's prompt, temperature 0, low
reasoning, 8,192 output tokens) and the reference routes' images (corpus/routes.py prepare: 2,400 px, JPEG quality
90). The 440 the reference routes read are reused byte for byte, checked against their run manifest; the other 455
are made by the same code from the frozen pages, checksums checked. ocr_rescore.py scores the readings with the
bench's scorers (answered-only and strict), beside every other route on the 895.

Real money on the Stanford PTA (root CLAUDE.md), the owner's yes recorded 2026-10-30 at about $3.80. CAP is this
item's own total, counted from the gateway's token usage at Gemini 3.8 Flash's list price (gateway_gemini.PRICE, an
estimate; the gateway's own figure per call is recorded beside it); the ledger is CACHE/calls.jsonl. Images, replies
and readings stay in the cache.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import io
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import gateway_gemini as G  # noqa: E402
import ocr_panel as P       # noqa: E402
import routes as R          # noqa: E402

CACHE = G.REHEARSAL / 'gemini37-public'   # the ledger, the new images and the replies
REF = R.RUN                                # the reference routes' run: images and manifest of the 440
CAP = 6.00   # this item's gateway total: the projection is $3.80 (895 at $0.0042) and Hebrew pages cost ~3x
RESULTS = HERE.parents[1] / 'segbench-results'


def configure():
    G.CACHE = CACHE            # the ledger, and so the cap, are this item's own
    G.CAP = CAP
    R.MANIFEST = R.RESULTS / 'manifest.jsonl'


def settings():
    """The request body less the messages: model, temperature, reasoning and the output cap, frozen in the manifest."""
    return {k: v for k, v in G.body(b'', '').items() if k != 'messages'}


def image_bytes(r):
    """corpus/routes.py prepare's encoding, unchanged."""
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    with Image.open(r['image']) as im:
        im = im.convert('RGB')
        im.thumbnail((P.SIDE, P.SIDE), Image.Resampling.LANCZOS)
        out = io.BytesIO(); im.save(out, 'JPEG', quality=90)
        return out.getvalue()


def prepare():
    configure()
    ref = {j['id']: j for j in json.loads((REF / 'manifest.json').read_text())['jobs']}
    jobs = []
    for r in R.frozen():
        jid = R.job_id(r)
        if jid in ref:
            b = (REF / 'images' / (jid + '.jpg')).read_bytes()
            if P.digest(b) != ref[jid]['sha256']:
                raise SystemExit('a reference image changed: ' + jid)
            src = 'reference'
        else:
            b = image_bytes(r)
            dest = CACHE / 'images' / (jid + '.jpg')
            if dest.exists() and dest.read_bytes() != b:
                raise SystemExit('a prepared image changed: ' + jid)
            dest.parent.mkdir(parents=True, exist_ok=True)
            if not dest.exists():
                dest.write_bytes(b)
            src = 'new'
        jobs.append({'id': jid, 'sha256': P.digest(b), 'images': src, 'stratum': r['stratum'], 'script': r['script']})
    if len(jobs) != 895 or sum(j['images'] == 'reference' for j in jobs) != 440:
        raise SystemExit(f'expected 895 pages, 440 of them reference: {len(jobs)}')
    m = {'jobs': R.run_order(jobs), 'prompt': P.PROMPT, 'model': G.MODEL, 'body': settings(),
         'manifest_sha256': R.C.sha256(R.MANIFEST)}
    dest = CACHE / 'manifest.json'
    if dest.exists() and json.loads(dest.read_text()) != json.loads(json.dumps(m)):
        raise SystemExit('run manifest changed: keep the existing run separate')
    P.save(dest, m)
    print(f'{len(jobs)} inputs; {dict(collections.Counter(j["stratum"] for j in jobs))}')


def manifest():
    configure()
    m = json.loads((CACHE / 'manifest.json').read_text())
    if (m['prompt'] != P.PROMPT or m['model'] != G.MODEL or m['manifest_sha256'] != R.C.sha256(R.MANIFEST)
            or m['body'] != settings()):
        raise SystemExit('run configuration changed')
    return m


def image(j):
    f = (REF if j['images'] == 'reference' else CACHE) / 'images' / (j['id'] + '.jpg')
    b = f.read_bytes()
    if hashlib.sha256(b).hexdigest() != j['sha256']:
        raise SystemExit('image changed: ' + j['id'])
    return b


def reply_path(jid):
    return CACHE / 'responses' / (jid + '.json')


def probe():
    m = manifest()
    j = m['jobs'][0]
    reply = G.call('probe', j['id'], image(j), m['prompt'], reply_path(j['id']))
    print(json.dumps(reply['meta'], indent=1)); print((reply.get('raw') or '')[:300])


def run():
    m = manifest()
    G.run('public', [(j['id'], image(j), reply_path(j['id'])) for j in m['jobs']], m['prompt'], concurrency=6)


def reading(jid):
    """The parsed text of a page's reply, or None for a failure (no reply, or one that did not parse)."""
    f = reply_path(jid)
    p = G.parsed(json.loads(f.read_text())) if f.exists() else None
    return p['text'] if p else None


def report():
    """3.7 against the cached 3.8 reading of the 440, paired, and the item's spend. The bench's scorers (every route,
    answered-only and strict) are ocr_rescore.py's; this is the calibration line beside them."""
    import ocr_rescore as O
    import ocr_panel_score as S
    m = manifest()
    truth = {R.job_id(r): r for r in R.frozen()}
    ref38 = REF / 'responses' / 'gemini3.8-flash'
    rows = []
    for j in m['jobs']:
        t = Path(truth[j['id']]['truth']).read_text()
        new = reading(j['id'])
        f38 = ref38 / (j['id'] + '.json')
        old = O._parsed(f38) if j['images'] == 'reference' and f38.exists() else None
        rows.append({'id': j['id'], 'stratum': j['stratum'], 'set': '440' if j['images'] == 'reference' else '455',
                     'ok37': new is not None, 'nes37': S.score(t, new)['nes'] if new else 0.0,
                     'ok38': bool(old), 'nes38': S.score(t, old)['nes'] if old else 0.0})
    calls = G.ledger()   # this item's own: the run and its one probe page
    ok_calls = [c for c in calls if c['http'] == 200]
    usage = {k: sum((c['usage'].get(k) or 0) for c in ok_calls) for k in ('prompt_tokens', 'completion_tokens')}
    finishes = collections.Counter()
    for j in m['jobs']:
        f = reply_path(j['id'])
        if f.exists():
            finishes[json.loads(f.read_text())['meta'].get('finish')] += 1
    mean = lambda xs: sum(xs) / len(xs) if xs else float('nan')
    ref = [r for r in rows if r['set'] == '440']
    both = [r for r in ref if r['ok37'] and r['ok38']]
    diff = S.paired([r['nes37'] for r in both], [r['nes38'] for r in both])
    strata = sorted({r['stratum'] for r in rows})
    out = {'model': G.MODEL + ' via the Stanford gateway', 'pages': len(rows), 'read': sum(r['ok37'] for r in rows),
           'strict': mean([r['nes37'] for r in rows]),
           'answered': mean([r['nes37'] for r in rows if r['ok37']]),
           'by_set': {s: {'pages': sum(r['set'] == s for r in rows), 'read': sum(r['ok37'] for r in rows if r['set'] == s),
                          'strict': mean([r['nes37'] for r in rows if r['set'] == s]),
                          'answered': mean([r['nes37'] for r in rows if r['set'] == s and r['ok37']])}
                      for s in ('440', '455')},
           'vs38_440': {'read38': sum(r['ok38'] for r in ref), 'both': len(both),
                        'nes37_both': mean([r['nes37'] for r in both]), 'nes38_both': mean([r['nes38'] for r in both]),
                        'paired_37_minus_38': diff},
           'by_stratum': {s: {'pages': sum(r['stratum'] == s for r in rows),
                              'read': sum(r['ok37'] for r in rows if r['stratum'] == s),
                              'strict': mean([r['nes37'] for r in rows if r['stratum'] == s]),
                              'answered': mean([r['nes37'] for r in rows if r['stratum'] == s and r['ok37']]),
                              'both38': sum(1 for r in both if r['stratum'] == s),
                              'nes37_both': mean([r['nes37'] for r in both if r['stratum'] == s]),
                              'nes38_both': mean([r['nes38'] for r in both if r['stratum'] == s])} for s in strata},
           'calls': len(calls), 'http_errors': collections.Counter(c['http'] for c in calls if c['http'] != 200),
           'finish': finishes, 'usage': usage, 'cost_list_estimate': sum(c['cost'] for c in calls),
           'cost_billed': G.billed(calls), 'cost_billed_note': G.billed_note(calls),
           'price_assumed': G.PRICE,
           'wall_s_median': sorted(c['wall_s'] for c in ok_calls)[len(ok_calls) // 2] if ok_calls else None}
    (RESULTS / 'gemini37-public.json').write_text(json.dumps(out, indent=1, default=dict))
    pct = lambda x: f'{100 * x:.1f}' if x == x else '-'
    v = out['vs38_440']
    L = ['# Gemini 3.7 Flash (Stanford gateway) on the 895 public pages (W46.ocr-gemini37-895-paid)', '',
         'The gateway default had read only the owner\'s 96; this is its reading of the 895 frozen public pages, with '
         'W46.gemini37-vs-38\'s settings (the panel prompt, temperature 0, low reasoning, 8,192 output tokens) and the '
         'reference routes\' 2,400 px JPEGs (the 440 reused byte for byte, the 455 made by the same code). NES is '
         '`ocr_panel_score.score`; **strict** counts a failed page as 0, **answered** is over the pages it read. The '
         'bench\'s other scorers (cMER, NewsBench bowF1, added and rewritten words) for this route are in '
         '`ocr-scorers.md`, beside every route on the 895; its NES there, through `ocr_scorers.py`, can differ from this '
         'table\'s by a few tenths. Script `scripts/segbench/ocr_gemini37_public.py`.', '',
         '| set | pages | read | NES strict | NES answered |', '|---|---:|---:|---:|---:|',
         f"| all 895 | {out['pages']} | {out['read']} | {pct(out['strict'])} | {pct(out['answered'])} |"]
    for s, b in out['by_set'].items():
        L.append(f"| the {s} | {b['pages']} | {b['read']} | {pct(b['strict'])} | {pct(b['answered'])} |")
    L += ['', f"Against Gemini 3.8 Flash's cached reading of the 440 (OpenRouter, W43.corpus-build; 3.8 read "
          f"{v['read38']}/440): on the {v['both']} both read, 3.7 {pct(v['nes37_both'])} against 3.8 "
          f"{pct(v['nes38_both'])}, paired 3.7 less 3.8 {100 * diff['delta']:+.2f} points (95% bootstrap "
          f"{100 * diff['lo']:+.2f} to {100 * diff['hi']:+.2f}; permutation p {diff['p']:.3f}).", '',
          '| stratum | pages | read | NES strict | NES answered | both read (440) | 3.7 | 3.8 |',
          '|---|---:|---:|---:|---:|---:|---:|---:|']
    for s, b in out['by_stratum'].items():
        L.append(f"| {s} | {b['pages']} | {b['read']} | {pct(b['strict'])} | {pct(b['answered'])} | {b['both38']} | "
                 f"{pct(b['nes37_both'])} | {pct(b['nes38_both'])} |")
    L += ['', f"Calls {out['calls']} (HTTP errors: {dict(out['http_errors']) or 'none'}); finish reasons "
          f"{dict(finishes)}. Tokens {usage['prompt_tokens']:,} in, {usage['completion_tokens']:,} out; median "
          f"{out['wall_s_median']} s a page. Spend about ${out['cost_list_estimate']:.2f}, an estimate at Gemini 3.8 "
          f"Flash's list ${G.PRICE[0]}/${G.PRICE[1]} per M tokens ({out['cost_billed_note']}), Stanford PTA.",
          '', '## Measurement card', '',
          '- **Truth:** each public dataset\'s own ground-truth transcription, frozen with the 895 (W43.corpus-build; '
          '`bench-corpus/manifest.jsonl` checksums). Not drafted by any scored route; the owner did not check them.',
          '- **Selection:** the frozen 895, stratified at freeze time by source and script; no page chosen by a tested '
          'route or by ABBYY text.',
          '- **Comparison:** the same images (the 440 byte for byte), prompt, output cap, temperature 0 and low reasoning '
          'as Gemini 3.8 Flash\'s reference reading of the 440, and as 3.7 on the 96. Both OCR sets: the 96 is '
          '`gemini37-vs-38.md` with the same settings, and `ocr-scorers.md` carries the route on both.',
          f"- **Noise:** n = {out['pages']} (paired with 3.8 on {v['both']}); the paired interval above. Gemini 3.7's "
          'rerun range on the 96 is 0.24 points (`ocr-rerun-noise.md`, W46.ocr-rerun-noise); a gap under twice it, or an '
          'interval crossing 0, is a tie, so 3.7 and 3.8 tie on the 440. No rerun on the 895. The 16 unread pages '
          'are all Gemini content-filter refusals (finish `content_filter`, empty text), model failures, not transport.',
          '- **Scope:** one reading, one prompt, one image size; it says how the gateway default reads the public '
          'strata, not which route the app should use for them, and nothing about the owner\'s material beyond the 96.']
    (RESULTS / 'gemini37-public.md').write_text('\n'.join(L) + '\n')
    print('\n'.join(L))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['prepare', 'probe', 'run', 'report'])
    {'prepare': prepare, 'probe': probe, 'run': run, 'report': report}[ap.parse_args().command]()


if __name__ == '__main__':
    main()
