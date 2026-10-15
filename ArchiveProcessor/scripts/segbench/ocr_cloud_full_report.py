"""W41.ocr-panel-cloud full-panel report. Public aggregates only: no page text, filenames or corpus paths."""
import collections
import json
from pathlib import Path
import ocr_cloud_full as F
import ocr_panel as P
from ocr_panel_score import score, aggregate, group_values, write_csv

MISTRAL = 'mistral-ocr-4-1'
LOCAL_SCORES = F.C.LOCAL / 'scores.json'


def route_label(key):
    if key in F.SUB:
        return f'{key} · `{F.SUB[key][0]} -p`, subscription' if F.SUB[key][0] == 'claude' else \
            f'{key} · `codex exec` ({F.SUB[key][2]}), subscription'
    if key == MISTRAL:
        return f'{MISTRAL} · Mistral OCR API, app client'
    return f'{key} · OpenRouter {F.PAID[key][1]}'


def reading(key, job):
    """(attempted, parsed-or-None, meta) for one route and page."""
    if key == MISTRAL:
        f = F.CACHE / 'mistral' / (job['id'] + '.json')
        got = json.loads(f.read_text()) if f.exists() else {}
        text = got.get('text') or ''
        return f.exists(), ({'text': text, 'kind': None} if text else None), {'cost': .004 if f.exists() else 0}
    f = (F.sub_path(key, job) if key in F.SUB else F.CACHE / 'responses' / key / (job['id'] + '.json'))
    got = json.loads(f.read_text()) if f.exists() else {}
    return f.exists(), got.get('parsed'), got.get('meta') or {}


def all_scores():
    m = F.manifest(); by_page = {r['page']: r for r in P.rows()}
    cal = json.loads((P.TRUTH / 'calibrate.json').read_text())
    out = []
    for key in [*F.PAID, *F.SUB, MISTRAL]:
        for job in m['jobs']:
            page = job['page']; row = by_page[page]
            attempted, parsed, meta = reading(key, job)
            truth = (P.TRUTH / 'truth' / (page + '.txt')).read_text()
            s = score(truth, parsed['text'] if parsed else '')
            out.append({**job, **s, 'key': key, 'ok': bool(parsed), 'attempted': attempted,
                        'cost': meta.get('cost', 0) if key not in F.SUB else 0,
                        'agreement': page in P.AGREEMENT, 'groups': group_values(row, cal),
                        'kind_correct': (parsed['kind'] == row['kind']) if parsed and parsed.get('kind') else None,
                        'prompt_tokens': meta.get('prompt_tokens'), 'completion_tokens': meta.get('completion_tokens')})
    return out


def report():
    ss = all_scores()
    P.save(F.CACHE / 'scores.json', ss)
    write_csv(F.CACHE / 'scores.csv', ss, ['key', 'page', 'ok', 'attempted', 'nes', 'chrf', 'words', 'missed',
                                          'added', 'cost', 'agreement', 'kind_correct'])
    main = [r for r in ss if not r['agreement']]
    keys = [*F.PAID, *F.SUB, MISTRAL]
    by = collections.defaultdict(list)
    for r in main:
        for g in r['groups']:
            by[(r['key'], *g)].append(r)
    write_csv(P.RESULTS / 'ocr-panel-cloud-groups.csv',
              [{'route': k, 'attribute': a, 'value': v, **aggregate(rr)} for (k, a, v), rr in sorted(by.items())],
              ['route', 'attribute', 'value', 'n', 'ok', 'nes', 'chrf', 'miss', 'add', 'words'])
    calls = P.records(); full = [r for r in calls if not r.get('pilot')]
    held = sum(json.loads(p.read_text())['reserve'] for p in (F.CACHE / 'pending').glob('*.json'))
    bills = [json.loads(p.read_text()) for p in (F.CACHE / 'mistral').glob('*.billing.json')]
    ocr_cost = sum(b['accounted_cost'] for b in bills)
    uncertain = [r for r in calls if r.get('cost_upper_bound')]
    sol = [r for r in ss if r['key'] == 'gpt5.6-sol' and r['attempted']]
    L = ['# W41.ocr-panel-cloud — the cloud panel on the truth set', '',
         'Question 2 of the W41 bake-off: how the paid and subscription leaders read the 99 frozen truth pages, '
         'with the [local panel](ocr-panel-local.md)’s images, prompt and scoring unchanged. Owner approval, '
         'second walkthrough 2026-10-15: the full panel, with Claude and OpenAI on the subscriptions, a $9 paid cap '
         'on top of the $0.312 pilot ([pilot report](ocr-panel-cloud-pilot.md)).', '',
         f'**Item spend: ${P.spent() + ocr_cost:.6f}** of the ${F.CAP:.2f} item cap: the pilot’s ${F.PILOT_SPENT:.6f}, '
         f'${P.spent() - F.PILOT_SPENT:.6f} of OpenRouter calls in the full run, and ${ocr_cost:.3f} of Mistral OCR '
         f'({len(bills)} pages at the published $4/1000). Outstanding reservations ${held:.6f}. The owner’s own '
         'interactive Mistral check (one synthetic page, about $0.004) is outside this ledger.'
         + (f' {len(uncertain)} calls carry a conservative cost ceiling (no billing record); their ceilings are in '
            'the figure.' if uncertain else ''), '',
         '## Routes', '',
         '- **OpenRouter** (paid): one pinned endpoint and precision per row, fallbacks off, the pilot’s settings '
         '(reasoning off or the lowest the endpoint accepts, temperature 0 where advertised, OpenAI image detail high). '
         'The pilot’s three pages are reused, not bought again.',
         '- **Claude Sonnet 5.5 through `claude -p`** (Claude subscription, no money): Claude Code’s own harness and '
         'system prompt; the image is a file the model opens with the Read tool, which may resize it; no '
         'temperature or effort setting. One reading per page; a harness error with no answer is tried once more.',
         '- **GPT-5.6 Sol and Luna through `codex exec`** were the plan (Codex offers both, at lowest effort low; it '
         'does not offer GPT-5.4 Mini, which stayed on OpenRouter). On the first full-run call Codex answered '
         '“Your workspace is out of credits”. As the owner ruled, **Luna fell back to OpenRouter** with the pilot’s '
         'route, and **Sol, which runs only by subscription, is ' + ('included' if sol else 'dropped') + '**.',
         '- **Mistral OCR 4.1** through the app’s own `MistralClient`, `ImageEncoding` and `NetworkSession`, compiled '
         'into a headless driver: no panel prompt, the app’s 2048 px / JPEG 0.85 encoding, and its reply as the app '
         'receives it, which is Markdown (`#` headings, `|` tables); the scoring removes table bars but not other '
         'Markdown. It returns no kind label.', '',
         '## Scoring and limits', '',
         'The local panel’s [normalization, NES, chrF2 and word rates](ocr-panel-local.md#scoring-and-limits), '
         'unchanged. 96 pages in the accuracy table; the three Michael Young letters are agreement with the '
         'drafters, not accuracy. **The truth was drafted by Claude Opus 5.5 and Gemini 3.8 Flash, then adjudicated**, '
         'so it can lean toward those models’ families, Gemini 3.8 Flash itself most of all. Failed readings score '
         'empty. One corpus, about 100 pages: differences of a point or two are not a ranking.', '',
         '## Original pages (96, excluding the agreement-only letters)', '',
         '| route | completed / attempted / 96 | NES % | chrF2 % | words missed % | words added % | kind right % | '
         'cost / page |', '|---|---:|---:|---:|---:|---:|---:|---:|']
    order = sorted(keys, key=lambda k: -aggregate([r for r in main if r['key'] == k])['nes'])
    for k in order:
        rr = [r for r in main if r['key'] == k]; a = aggregate(rr); n = sum(r['attempted'] for r in rr)
        if not n:
            continue
        kc = [r['kind_correct'] for r in rr if r['kind_correct'] is not None]
        cost = ('subscription' if k in F.SUB else
                f"${sum(r['cost'] for r in ss if r['key'] == k and r['attempted']) / sum(r['attempted'] for r in ss if r['key'] == k):.5f}")
        L.append(f"| {route_label(k)} | {a['ok']}/{n}/{a['n']} | {100*a['nes']:.2f} | {100*a['chrf']:.2f} | "
                 f"{100*a['miss']:.2f} | {100*a['add']:.2f} | {f'{100*sum(kc)/len(kc):.0f}' if kc else '—'} | {cost} |")
    if LOCAL_SCORES.exists():
        local = [r for r in json.loads(LOCAL_SCORES.read_text()) if r['scale'] == 'original' and not r['agreement']]
        lk = sorted({r['key'] for r in local}, key=lambda k: -aggregate([r for r in local if r['key'] == k])['nes'])
        L += ['', 'The local panel on the same 96 pages, for comparison (its own report has the detail):', '',
              '| local-panel route | completed / 96 | NES % | chrF2 % | words missed % | words added % |',
              '|---|---:|---:|---:|---:|---:|']
        for k in lk:
            a = aggregate([r for r in local if r['key'] == k])
            L.append(f"| {k} | {a['ok']}/{a['n']} | {100*a['nes']:.2f} | {100*a['chrf']:.2f} | "
                     f"{100*a['miss']:.2f} | {100*a['add']:.2f} |")
    L += ['', '## Completed readings only, and the agreement-only letters', '',
          '| route | completed / 96 | NES % (completed) | agreement letters NES % (completed / 3) |',
          '|---|---:|---:|---:|']
    for k in order:
        ok = aggregate([r for r in main if r['key'] == k and r['ok']])
        ag = [r for r in ss if r['key'] == k and r['agreement']]; aa = aggregate(ag)
        if any(r['attempted'] for r in ag + [r for r in main if r['key'] == k]):
            L.append(f"| {k} | {ok['n']}/96 | {100*ok['nes']:.2f} | {100*aa['nes']:.2f} ({aa['ok']}/3) |")
    L += ['', '## Measured paid calls (full run, pilot pages reused)', '',
          '| route | calls bought in the full run | failures | full-run cost | mean input / output / reasoning tokens |',
          '|---|---:|---:|---:|---:|']
    for k in F.PAID:
        rr = [r for r in full if r['key'] == k and r['status'] in ('ok', 'failed')]; n = len(rr)
        toks = '/'.join(f"{sum(r.get(f) or 0 for r in rr) / n:.0f}" if n else '—'
                        for f in ('prompt_tokens', 'completion_tokens', 'reasoning_tokens'))
        L.append(f"| {k} | {n} | {sum(r['status'] == 'failed' for r in rr)} | ${sum(r['cost'] for r in rr):.4f} | {toks} |")
    L += ['', f'Mistral OCR: {sum(b["status"] == "ok" for b in bills)}/{len(bills)} pages returned text.', '',
          'Per-attribute scores (collection, period, kind, table/form, camera, tertiles, every tag; overlapping, '
          'small groups descriptive only): [ocr-panel-cloud-groups.csv](ocr-panel-cloud-groups.csv).', '',
          '## Reproduction', '',
          '`ocr_cloud_full.py prepare`, `ocr_cloud_mistral.py --full <driver>`, `ocr_cloud_full.py paid`, '
          '`ocr_cloud_full.py sub <route>`, `ocr_cloud_full.py report`. Private cache '
          '`~/Library/Caches/ArchiveSuiteRehearsal/ocr-panel-cloud/` (images, ledger, replies, page scores). '
          'The pilot’s spending controls hold: write-ahead reservations, pinned providers, no paid retries, the '
          'OCR reserve held apart, an uncertain outcome blocks continuation.', '']
    (P.RESULTS / 'ocr-panel-cloud.md').write_text('\n'.join(L))
    print(f'report: {len(ss)} route-page pairs; item ${P.spent() + ocr_cost:.6f}')
