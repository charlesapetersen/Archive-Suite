#!/usr/bin/env python3
"""W46.gateway-gpt-claude-readers. The strongest GPT and Claude readers the Stanford gateway serves, on both OCR sets.

  python3 ocr_gateway_readers.py models                 # every gateway model, frozen; picks each family's reader
  python3 ocr_gateway_readers.py estimate               # projected cost per route and set, from cached token usage
  python3 ocr_gateway_readers.py prepare                # the 895's 455 non-reference images, rebuilt and checked
  python3 ocr_gateway_readers.py probe ROUTE            # one page of the 96, to check the request and usage fields
  python3 ocr_gateway_readers.py run ROUTE 96           # the owner's 96 (99 settled jobs), the cloud panel's images
  python3 ocr_gateway_readers.py run ROUTE 895 [--sample N]   # the frozen public 895, or N a stratum, every stratum
  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy \
      python ocr_gateway_readers.py report              # -> segbench-results/gateway-gpt-claude.{md,json}

ROUTE is gpt or claude. Owner review of the pipeline doc, 2026-11-17: GPT had been read only through OpenRouter on the
96 (GPT-5.6 Luna 93.56, GPT-5.4 Mini 94.81) and neither family had a public-set figure. The settings are the gateway
default's (gateway_gemini.body: the panel prompt, temperature 0, low reasoning, 8,192 output tokens); the images are the
ones every other route read: the cloud panel's 2,400 px JPEGs for the 96, and for the 895 the inputs
ocr_gemini37_public.py prepared (the 440 reference images byte for byte, the 455 made alike), checksums checked.

The ChatGPT plan's reading row is the GPT reading here. Plan routes are not bench arms; since W46.gateway-models-ok
such an arm runs through the gateway (root CLAUDE.md, "Plan routes wait for the gateway"), so the plan's row is the
same model read through the gateway, labelled as what the plan would serve, as the Claude plan's row is Sonnet's.

Real money on the Stanford PTA. CAP is this item's total over both routes and both sets (the $7 rule; the ledger is
CACHE/calls.jsonl, one for the item). Each call counts the larger of the token estimate at the route's list price
and the gateway's own figure (gateway_gemini.charge), and none starts unless a worst-case page still fits.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import gateway_gemini as G  # noqa: E402

CACHE = G.REHEARSAL / 'gateway-gpt-claude'
PUBLIC = G.REHEARSAL / 'gemini37-public'     # ocr_gemini37_public.py's prepared 895: manifest and the 455 images
RESULTS = HERE.parents[1] / 'segbench-results'
CAP = 7.00          # the item's total, both routes and both sets; the $7 rule without asking
SETS = ('96', '895')
SAMPLE = 10         # the 895 sample's pages a stratum (L9 has 15), when the whole set is over the cap

# Each family's readers, strongest first: the first one the gateway lists is the route. $ per million tokens (input,
# output incl. reasoning) are list prices, labelled estimates (the gateway publishes none; its per-call figure is
# recorded beside them). Sources: OpenRouter's catalog cached by W41.ocr-panel-cloud (ocr-panel-cloud/catalog,
# 2026-10) for GPT-5.6 Sol and Luna, GPT-5.4 Mini and Claude Sonnet 5.5; the others are Anthropic's and OpenAI's
# published rates as last recorded, ceilings until the probe's gateway figure replaces them.
FAMILIES = {
    'gpt': [('gpt-5.6-sol', (2.00, 10.00)), ('gpt-5.6', (2.00, 10.00)), ('gpt-5.5', (1.25, 10.00)),
            ('gpt-5.4', (1.25, 10.00)), ('gpt-5.2', (1.25, 10.00)), ('gpt-5.6-luna', (0.10, 0.60)),
            ('gpt-5.4-mini', (0.75, 4.50)), ('gpt-5', (1.25, 10.00))],
    'claude': [('claude-opus-5-5', (5.00, 25.00)), ('claude-opus-5', (5.00, 25.00)),
               ('claude-sonnet-5-5', (2.00, 10.00)), ('claude-sonnet-5', (3.00, 15.00)),
               ('claude-opus-4-6', (5.00, 25.00)), ('claude-sonnet-4-5', (3.00, 15.00))],
}
FAMILY_RE = {'gpt': re.compile(r'gpt', re.I), 'claude': re.compile(r'claude|anthropic', re.I)}
# The estimate's basis on the 96: the OpenRouter panel's billed calls for the same model or its nearest kin, with
# that kin's list price, so a different model's figure is the kin's bill scaled by the price ratio.
PANEL_KIN = {'gpt': ('openai/gpt-5.6-sol', (2.00, 10.00)), 'claude': ('anthropic/claude-sonnet-5.5', (2.00, 10.00))}
EXACT_KIN = {'gpt-5.6-sol': 'openai/gpt-5.6-sol', 'gpt-5.6-luna': 'openai/gpt-5.6-luna',
             'gpt-5.4-mini': 'openai/gpt-5.4-mini', 'claude-sonnet-5-5': 'anthropic/claude-sonnet-5.5'}


def pick(ids, family):
    """The family's strongest reader among the gateway's model ids, with its price; None when it serves none."""
    have = set(ids)
    return next(((m, p) for m, p in FAMILIES[family] if m in have), None)


def configure(route=None):
    G.CACHE = CACHE
    G.CAP = CAP
    if route:
        r = chosen()[route]
        G.MODEL, G.PRICE, G.LABEL = r['model'], tuple(r['price']), r['label']


def chosen():
    f = CACHE / 'routes.json'
    if not f.exists():
        raise SystemExit('run `models` first: no route chosen')
    return json.loads(f.read_text())


def models():
    configure()
    r = G.request('/models', timeout=60)
    r.raise_for_status()
    ids = sorted(m['id'] for m in r.json().get('data', []))
    CACHE.mkdir(parents=True, exist_ok=True)
    (CACHE / 'models.json').write_text(json.dumps(r.json(), indent=1))
    routes = {}
    for fam in FAMILIES:
        listed = [i for i in ids if FAMILY_RE[fam].search(i)]
        print(f'{fam}: {", ".join(listed) or "none listed"}')
        unknown = [i for i in listed if i not in dict(FAMILIES[fam])]
        if unknown:
            print(f'  not in the {fam} preference list, so not chosen (add it there if it is stronger): {unknown}')
        got = pick(ids, fam)
        if got:
            routes[fam] = {'model': got[0], 'price': list(got[1]), 'label': got[0] + '-gw'}
    print(f'{len(ids)} models; chosen: {json.dumps(routes)}')
    (CACHE / 'routes.json').write_text(json.dumps(routes, indent=1))


def per_page(family, model, price):
    """Projected $ a page on the 96 and on the 895. The 96: the kin's mean billed cost a call (OpenRouter's bill runs
    2-3 times its token count at list price, so the bill is the basis), times the price ratio when the model is not the
    kin. The 895: the same, times how much more Gemini 3.7 wrote a page there than on the 96 (gemini37-public
    against gateway-gemini), applied to the output share of the bill."""
    calls = [json.loads(x) for x in (G.PANEL / 'calls.jsonl').read_text().splitlines()]
    kin_id, kin_price = PANEL_KIN[family]
    if model in EXACT_KIN:
        kin_id, kin_price = EXACT_KIN[model], price
    kin = [c for c in calls if c.get('model') == kin_id and c.get('status') == 'ok']
    tin = sum(c['prompt_tokens'] for c in kin) / len(kin)
    tout = sum(c['completion_tokens'] for c in kin) / len(kin)
    bill = sum(c['cost'] for c in kin) / len(kin)
    ratio = (tin * price[0] + tout * price[1]) / (tin * kin_price[0] + tout * kin_price[1])

    def mean_out(f):
        rows = [json.loads(x) for x in f.read_text().splitlines()] if f.exists() else []
        rows = [r for r in rows if r.get('http') == 200]
        return sum((r.get('usage') or {}).get('completion_tokens') or 0 for r in rows) / len(rows) if rows else None
    o96, o895 = mean_out(G.REHEARSAL / 'gateway-gemini' / 'calls.jsonl'), mean_out(PUBLIC / 'calls.jsonl')
    scale = o895 / o96 if o96 and o895 else 1.75
    share = tout * price[1] / (tin * price[0] + tout * price[1])
    c96 = bill * ratio
    return {'basis': f'{len(kin)} billed calls of {kin_id}, ${bill:.4f} each', 'per_page_96': c96,
            'per_page_895': c96 * (1 - share + share * scale), 'out_scale_895': round(scale, 2)}


def estimate():
    configure()
    try:
        routes = chosen()
    except SystemExit:
        routes = {f: {'model': FAMILIES[f][0][0], 'price': list(FAMILIES[f][0][1])} for f in FAMILIES}
        print('no gateway listing yet: estimating each family\'s first preference')
    total, n = 0.0, len(sample(json.loads((PUBLIC / 'manifest.json').read_text())['jobs'], SAMPLE))
    for fam, r in routes.items():
        e = per_page(fam, r['model'], r['price'])
        a, b = 99 * e['per_page_96'], 895 * e['per_page_895']
        total += a + b
        print(f"{fam} {r['model']} at ${r['price'][0]}/${r['price'][1]} per M ({e['basis']}; 895 output "
              f"x{e['out_scale_895']}): 96 ${a:.2f} (${e['per_page_96']:.4f} a page), 895 ${b:.2f}, "
              f"{SAMPLE} a stratum ({n} pages) ${b * n / 895:.2f}")
    print(f'all four runs about ${total:.2f}; CAP ${CAP:.2f}, spent ${G.spent():.4f}')


def prepare():
    """The 895's 455 non-reference images, rebuilt into this item's own cache by ocr_gemini37_public's code and checked
    against its frozen checksums (its own copies were removed when that item finished, W40.cache-budget). The 440
    reference images are read where the reference routes keep them."""
    import ocr_gemini37_public as O
    import routes as R
    O.configure()
    want = {j['id']: j['sha256'] for j in json.loads((PUBLIC / 'manifest.json').read_text())['jobs']
            if j['images'] != 'reference'}
    made = 0
    for r in R.frozen():
        jid = R.job_id(r)
        if jid not in want:
            continue
        dest = CACHE / 'images' / (jid + '.jpg')
        if dest.exists() and hashlib.sha256(dest.read_bytes()).hexdigest() == want[jid]:
            continue
        b = O.image_bytes(r)
        if hashlib.sha256(b).hexdigest() != want[jid]:
            raise SystemExit('rebuilt image differs from the frozen checksum: ' + jid)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(b)
        made += 1
    print(f'{len(want)} non-reference images in {CACHE / "images"}; {made} made now')


def panel_jobs():
    m, jobs = G.panel_manifest()
    out = []
    for j in jobs:
        image = (G.PANEL / 'images' / (j['id'] + '.jpg')).read_bytes()
        if hashlib.sha256(image).hexdigest() != j['sha256']:
            raise SystemExit('image changed: ' + j['id'])
        out.append({'id': j['id'], 'page': j['page'], 'image': image})
    return m['prompt'], out


def sample(jobs, n):
    """n a stratum (every one of a smaller stratum), drawn by a hash of the job id: never by a route's reading."""
    by = collections.defaultdict(list)
    for j in jobs:
        by[j['stratum']].append(j)
    keep = set()
    for s, js in by.items():
        js = sorted(js, key=lambda j: hashlib.sha256(('gateway-gpt-claude|' + j['id']).encode()).hexdigest())
        keep |= {j['id'] for j in js[:n]}
    return [j for j in jobs if j['id'] in keep]


def public_jobs(n=None):
    m = json.loads((PUBLIC / 'manifest.json').read_text())
    import routes as R
    jobs = m['jobs'] if n is None else sample(m['jobs'], n)
    out = []
    for j in jobs:
        f = (R.RUN if j['images'] == 'reference' else CACHE) / 'images' / (j['id'] + '.jpg')
        b = f.read_bytes()
        if hashlib.sha256(b).hexdigest() != j['sha256']:
            raise SystemExit('image changed: ' + j['id'])
        out.append({'id': j['id'], 'stratum': j['stratum'], 'image': b})
    return m['prompt'], out


def reply_path(route, set_name, jid):
    return CACHE / route / set_name / (jid + '.json')


def worst_case():
    """A page's most: the panel's input at MAX_TOKENS output, at the route's price."""
    return (4000 * G.PRICE[0] + G.MAX_TOKENS * G.PRICE[1]) / 1e6


def run(route, set_name, n=None, concurrency=4):
    configure(route)
    prompt, jobs = panel_jobs() if set_name == '96' else public_jobs(n)
    todo = [j for j in jobs if not reply_path(route, set_name, j['id']).exists()]
    need = worst_case() * concurrency
    print(f'{route} {G.MODEL} on the {set_name}: {len(jobs)} jobs, {len(todo)} to read; '
          f'${G.spent():.4f} spent of ${CAP}, a page at most ${worst_case():.3f}')
    for k in range(0, len(todo), concurrency):
        if G.spent() + need > CAP:
            raise SystemExit(f'cap: ${G.spent():.4f} spent of ${CAP}; stopped before {todo[k]["id"]}')
        G.run(f'{route}-{set_name}', [(j['id'], j['image'], reply_path(route, set_name, j['id']))
                                      for j in todo[k:k + concurrency]], prompt, concurrency)


def probe(route):
    configure(route)
    prompt, jobs = panel_jobs()
    j = jobs[0]
    if G.spent() + worst_case() > CAP:
        raise SystemExit('cap')
    reply = G.call('probe-' + route, j['id'], j['image'], prompt, CACHE / route / 'probe' / (j['id'] + '.json'))
    print(json.dumps(reply['meta'], indent=1)); print((reply.get('raw') or '')[:300])


def reading(route, set_name, jid):
    f = reply_path(route, set_name, jid)
    p = G.parsed(json.loads(f.read_text())) if f.exists() else None
    return p


def report():
    import ocr_panel as P
    import ocr_panel_score as S
    import routes as R
    configure()
    routes = chosen()
    mean = lambda xs: sum(xs) / len(xs) if xs else float('nan')
    out = {'routes': routes, 'sets': {}}
    by_page = {r['page']: r for r in P.rows()}
    truth895 = {R.job_id(r): r for r in R.frozen()}
    for fam, r in routes.items():
        res = {}
        _, jobs = G.panel_manifest()
        rows = []
        for j in jobs:
            if j['page'] in P.AGREEMENT:
                continue
            t = (P.TRUTH / 'truth' / (j['page'] + '.txt')).read_text()
            p = reading(fam, '96', j['id'])
            rows.append({**S.score(t, p['text'] if p else ''), 'ok': bool(p), 'kind': by_page[j['page']]['kind'],
                         'kind_right': bool(p) and p.get('kind') == by_page[j['page']]['kind']})
        if any(x['ok'] for x in rows):
            a = S.aggregate(rows)
            res['96'] = {'pages': len(rows), 'read': a['ok'], 'strict': mean([x['nes'] if x['ok'] else 0.0 for x in rows]),
                         'answered': mean([x['nes'] for x in rows if x['ok']]), 'agg': a,
                         'kind_right': sum(x['kind_right'] for x in rows),
                         'by_kind': {k: S.aggregate([x for x in rows if x['kind'] == k])
                                     for k in sorted({x['kind'] for x in rows})}}
        m = json.loads((PUBLIC / 'manifest.json').read_text())
        rows = []
        for j in m['jobs']:
            if not reply_path(fam, '895', j['id']).exists():
                continue   # a sample reads only some; unread-by-design pages are not failures
            t = Path(truth895[j['id']]['truth']).read_text()
            p = reading(fam, '895', j['id'])
            rows.append({'stratum': j['stratum'], 'ok': bool(p), 'nes': S.score(t, p['text'])['nes'] if p else 0.0})
        if rows:
            res['895'] = {'pages': len(rows), 'read': sum(x['ok'] for x in rows),
                          'strict': mean([x['nes'] for x in rows]),
                          'answered': mean([x['nes'] for x in rows if x['ok']]),
                          'by_stratum': {s: {'pages': sum(x['stratum'] == s for x in rows),
                                             'strict': mean([x['nes'] for x in rows if x['stratum'] == s])}
                                         for s in sorted({x['stratum'] for x in rows})}}
        calls = [c for c in G.ledger() if c['set'].startswith(fam + '-') or c['set'] == 'probe-' + fam]
        res['cost'] = G.billed(calls)
        res['cost_note'] = G.billed_note(calls)
        out['sets'][fam] = res
    (RESULTS / 'gateway-gpt-claude.json').write_text(json.dumps(out, indent=1, default=dict))
    pct = lambda x: f'{100 * x:.2f}' if x == x else '-'
    L = ['# GPT and Claude readers through the Stanford gateway, on both OCR sets (W46.gateway-gpt-claude-readers)', '',
         'Each family\'s strongest reader the gateway serves, chosen from its model list (`models`), with the gateway '
         'default\'s settings (the panel prompt, temperature 0, low reasoning, 8,192 output tokens) and the images every '
         'other route read. NES is `ocr_panel_score.score`; strict counts a failed page as 0. The GPT row is also the '
         'ChatGPT plan\'s reading row. Script `scripts/segbench/ocr_gateway_readers.py`.', '',
         '| route | set | pages | read | NES strict | NES answered | spend |', '|---|---|---:|---:|---:|---:|---|']
    for fam, res in out['sets'].items():
        for s in SETS:
            if s in res:
                v = res[s]
                L.append(f"| {routes[fam]['label']} | {s} | {v['pages']} | {v['read']} | {pct(v['strict'])} | "
                         f"{pct(v['answered'])} | |")
        L.append(f"| {routes[fam]['label']} | all | | | | | ${res['cost']['charged']:.2f} ({res['cost_note']}) |")
    L += ['', '## Original pages (96, excluding the agreement-only letters)', '',
          '| route | completed / attempted / 96 | NES % | chrF2 % | words missed % | words added % | kind right % | cost / page |',
          '|---|---:|---:|---:|---:|---:|---:|---:|']
    for fam, res in out['sets'].items():
        if '96' in res:
            v, a = res['96'], res['96']['agg']
            L.append(f"| {routes[fam]['label']} · Stanford AI API gateway | {a['ok']}/{v['pages']}/{v['pages']} | "
                     f"{100 * a['nes']:.2f} | {100 * a['chrf']:.2f} | {100 * a['miss']:.2f} | {100 * a['add']:.2f} | "
                     f"{round(100 * v['kind_right'] / v['pages'])} | ${res['cost']['charged'] / max(1, res['cost']['calls']):.5f} (estimate) |")
    L += ['', '## Measurement card', '',
          '- **Truth:** the owner\'s 96 (drafted by Claude Opus 5.5, owner-checked where the sheets asked; the Claude '
          'route is the drafter\'s family, OCR-1) and the public 895\'s own dataset transcriptions (W43.corpus-build).',
          '- **Selection:** the frozen sets; a 895 sample is drawn per stratum by a hash of the job id, never by a route.',
          '- **Comparison:** the same images, prompt and settings as Gemini 3.7 Flash on both sets.',
          '- **Noise:** one reading; Gemini 3.7\'s rerun range on the 96 is 0.24 points (`ocr-rerun-noise.md`), so a '
          'gap under twice it is a tie.',
          '- **Scope:** which hosted family reads best through the gateway; not a choice of app default.']
    (RESULTS / 'gateway-gpt-claude.md').write_text('\n'.join(L) + '\n')
    print('\n'.join(L))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['models', 'estimate', 'prepare', 'probe', 'run', 'report'])
    ap.add_argument('route', nargs='?', choices=list(FAMILIES))
    ap.add_argument('set', nargs='?', choices=SETS)
    ap.add_argument('--sample', type=int, help='895 only: this many pages a stratum')
    a = ap.parse_args()
    if a.command in ('probe', 'run') and not a.route:
        ap.error('a route is needed')
    if a.command == 'run' and not a.set:
        ap.error('a set is needed')
    {'models': models, 'estimate': estimate, 'prepare': prepare, 'report': report, 'probe': lambda: probe(a.route),
     'run': lambda: run(a.route, a.set, a.sample)}[a.command]()


if __name__ == '__main__':
    main()
