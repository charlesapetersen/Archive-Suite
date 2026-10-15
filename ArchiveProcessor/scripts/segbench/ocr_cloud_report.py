"""Public aggregate pilot evidence. No page text, filenames, or corpus paths."""
import json
from pathlib import Path
import ocr_cloud as C
import ocr_panel as P
from ocr_panel_score import score, aggregate


def report():
    m=C.manifest(); calls=P.records(); rows=[]; total=0; high=0; complete=True
    lines=['# W41.ocr-panel-cloud — three-page pilot', '',
      'Owner authorization, 2026-10-15: three pages per route, well under $1, then ask again. '
      '**The full panel has not run and is not approved.**', '',
      'Frozen pages: p010 (clipping), p062 (typescript/bullets), p086 (difficult handwriting). '
      'These are the local panel’s original, byte-identical JPEGs (2400 px ceiling) and owner-ruled '
      'transcription prompt. No ladder variants. p086 is agreement with the drafting models, '
      'not adjudicated accuracy. Two accuracy pages cannot establish a ranking.', '',
      '## Measured calls and extrapolation', '',
      '| route | endpoint / precision | completed / 3 | pilot cost | mean input / output / reasoning tokens | '
      '99 pages, mean cost | 99 pages, worst pilot-page cost |',
      '|---|---|---:|---:|---:|---:|---:|']
    for key,spec in C.MODELS.items():
        rr=[r for r in calls if r['key']==key and r['status'] in ('ok','failed')]
        ok=sum(r['status']=='ok' for r in rr); cost=sum(r['cost'] for r in rr)
        if len(rr)!=3: complete=False
        avg=cost/len(rr) if rr else 0; worst=max((r['cost'] for r in rr),default=0)
        total+=99*avg;high+=99*worst
        toks='/'.join(str(round(sum(r.get(f) or 0 for r in rr)/len(rr))) if rr else '—'
                      for f in ('prompt_tokens','completion_tokens','reasoning_tokens'))
        lines.append(f'| {key} | {spec[1]} / {spec[2] or "unpublished"} | {ok} | ${cost:.6f} | {toks} | '
                     f'${99*avg:.3f} | ${99*worst:.3f} |')
        for j in m['jobs']:
            f=P.CACHE/'responses'/key/(j['id']+'.json')
            got=json.loads(f.read_text()) if f.exists() else {}
            text=(got.get('parsed') or {}).get('text','')
            truth=(P.TRUTH/'truth'/(j['page']+'.txt')).read_text()
            rows.append({'key':key,'page':j['page'],'ok':bool(got.get('parsed')),
                         **score(truth,text),'agreement':j['page'] in P.AGREEMENT})
    mf=P.CACHE/'mistral-summary.json'; mistral=json.loads(mf.read_text()) if mf.exists() else None
    mistral_cost=mistral.get('accounted_cost',0) if mistral else 0
    if mistral:
        lines+=['',f'Dedicated Mistral OCR: {mistral["completed"]}/3 completed; '
                f'${mistral_cost:.6f} accounted at the published $4/1000 pages. '
                'The app’s actual `MistralClient`, `ImageEncoding` and `NetworkSession` were compiled '
                'into a headless driver; its encoder caps at 2048 px and JPEG quality 0.85, '
                'so this row is not byte-identical to the chat routes. It takes no panel prompt. '
                'Reported model, usage and raw bodies remain in the private cache. '
                'The app’s `mistral-ocr-latest` alias resolved to OCR 4.1 at preparation; the pilot pins `mistral-ocr-4-1`.']
        if mistral['completed']!=3: complete=False
        total+=.396;high+=.396
    else:
        limited=sorted((P.CACHE/'mistral'/'rate-limited').glob('*/'))
        lines+=['',(f'Dedicated Mistral OCR not collected: {len(limited)} attempt(s) at the first page, each answered '
                    'only by HTTP 429 `rate_limited` (nothing processed, nothing billed; the replies are kept in the '
                    'private cache). Add ' if limited else 'Dedicated Mistral OCR not yet collected; add ')
                + '$0.396 for 99 single-page calls.']
        complete=False;total+=.396;high+=.396
    held=sum(json.loads(p.read_text())['reserve'] for p in (P.CACHE/'pending').glob('*.json'))
    # Every chat route settled three attempts; only the dedicated OCR row is unmeasured (flat published price).
    chat_complete=all(len([r for r in calls if r['key']==k and r['status'] in ('ok','failed')])==3
                      for k in C.MODELS) and not held
    held+=sum(json.loads(p.read_text())['reserve'] for p in (P.CACHE/'mistral').glob('*.pending.json'))
    complete=complete and not held
    lines+=['',f'**Pilot accounted: ${P.spent()+mistral_cost:.6f} / $0.75 combined ceiling; '
            f'outstanding reservations ${held:.6f}.**']
    if complete:
        lines += [f'Full 99-original panel (all twelve chat models plus dedicated OCR), '
          f'mean-cost extrapolation: **${total:.2f}**; using each route’s dearest pilot page: **${high:.2f}**. '
          f'A further 50% planning buffer on the mean gives **${1.5*total:.2f}**. '
          'These are sample estimates, not guaranteed prices or authorization. '
          'The estimate includes the three already-bought pages; the remaining 96 are 96/99 of it. '
          'No retries, resolution ladder, batch discount, or corpus-wide extrapolation is included. '
          'Three deliberately varied pages are not a random cost sample.']
    elif chat_complete:
        lines += [f'Dedicated Mistral OCR did not complete (see above), so its row is at the published '
          f'$4/1000 pages, not measured. Full 99-original panel (all twelve chat models measured, plus that '
          f'dedicated OCR row), mean-cost extrapolation: **${total:.2f}**; using each chat route’s dearest pilot '
          f'page: **${high:.2f}**. A further 50% planning buffer on the mean gives **${1.5*total:.2f}**. '
          'These are sample estimates, not guaranteed prices or authorization. '
          'No retries, resolution ladder, batch discount, or corpus-wide extrapolation is included. '
          'Three deliberately varied pages are not a random cost sample.']
    else:
        lines += ['**Combined full-panel projection withheld: at least one route has not settled three attempts.** '
                  'Per-route partial extrapolations above are diagnostic only; missing routes are not free.']
    if mistral:
        for j in m['jobs']:
            f=P.CACHE/'mistral'/(j['id']+'.json')
            got=json.loads(f.read_text()) if f.exists() else {}
            truth=(P.TRUTH/'truth'/(j['page']+'.txt')).read_text()
            rows.append({'key':'mistral-ocr-4-1','page':j['page'],'ok':bool(got.get('text')),
                         **score(truth,got.get('text') or ''),'agreement':j['page'] in P.AGREEMENT})
    lines+=['',f'Pilot collection complete: **{"yes" if complete else "no"}** '
      '(paid failed responses count as attempted, never as successful readings).', '',
      '## Scores (diagnostic only)', '',
      '| route | two adjudicated pages: completed | NES % | chrF2 % | words missed % | words added % | '
      'p086 agreement NES % |', '|---|---:|---:|---:|---:|---:|---:|']
    for key in [*C.MODELS, *(['mistral-ocr-4-1'] if mistral else [])]:
        rr=[r for r in rows if r['key']==key]
        s=aggregate([r for r in rr if not r['agreement']])
        a=next(r for r in rr if r['agreement'])
        lines.append(f'| {key} | {s["ok"]}/2 | {100*s["nes"]:.2f} | {100*s["chrf"]:.2f} | '
                     f'{100*s["miss"]:.2f} | {100*s["add"]:.2f} | {100*a["nes"]:.2f} |')
    lines+=['','Scoring is exactly the [local panel’s normalization, NES, SacreBLEU chrF2, and multiset word rates]'
      '(ocr-panel-local.md#scoring-and-limits). Failed readings score empty. All attribute and resolution '
      'comparisons wait for the approved full panel; the pilot cannot answer Question 2.', '',
      '## Reproduction and spending controls', '',
      '`ocr_cloud.py prepare`, `ocr_cloud.py pilot`, `ocr_cloud_mistral.py <compiled-driver>`, '
      '`ocr_cloud.py report`. Default private cache `/tmp/w41-ocr-panel-cloud/`; set `OCR_CLOUD_CACHE` '
      'to preserve it elsewhere. Frozen truth and local image cache are read only. '
      'The manifest permits exactly three originals; there is no full-run command. Requests are serial, '
      'provider-pinned, fallbacks disabled, max 8192 output tokens; failures are never repurchased. '
      'Unknown network/billing outcomes retain their full write-ahead reservations and block continuation.', '',
      'Gemini 3.1 Pro/3.8 Flash and Claude Sonnet 5.5 request low reasoning (Claude’s endpoint refused reasoning off with a free HTTP 400, so it was re-run at low; its usage reports 0 reasoning tokens, so any thinking is inside the billed output count); Gemini 3.5 Flash/Flash-Lite and GPT-5.4 Mini request minimal; the other reasoning-capable routes request off; '
      'Qwen3-VL Instruct has none. Temperature is zero except Claude/OpenAI, whose catalog does not '
      'advertise it; it is omitted there. OpenAI detail is explicitly high. Actual reasoning tokens '
      'above show whether the providers still used internal tokens.', '',
      'Input reservations for Google/Anthropic/OpenAI are 32768 tokens for one image plus the short '
      'prompt, far above documented visual tiers: '
      '[Gemini up to 2240 (approximate table)](https://ai.google.dev/gemini-api/docs/media-resolution), '
      '[Claude 4784](https://platform.claude.com/docs/en/build-with-claude/vision), '
      '[the three OpenAI models at high detail, 2500 patches ×1.2]'
      '(https://developers.openai.com/api/docs/guides/images-vision). '
      'The runner stops if measured input exceeds that bound. Mistral and Qwen reserve their entire '
      'endpoint context; published applicable price tiers are included. The largest reservation runs first '
      '(Mistral Large, $0.730153), and settles before the next call. $0.012 is held separately for OCR.', '',
      'Prices/providers frozen from the [OpenRouter endpoint catalog](https://openrouter.ai/api/v1/models) '
      'on 2026-10-15; full snapshots in the private cache. '
      '[Mistral OCR pricing](https://docs.mistral.ai/inference/pricing): $4/1000 pages standard; batch is not used.', '']
    out=P.RESULTS/'ocr-panel-cloud-pilot.md';out.write_text('\n'.join(lines))
    projected=complete or chat_complete
    P.save(P.CACHE/'pilot-estimate.json',{'complete':complete,'chat_complete':chat_complete,
      'pilot_cost':P.spent()+mistral_cost,'held':held,'mean_99':total if projected else None,
      'worst_99':high if projected else None,'buffered_99':1.5*total if projected else None})
    detail=(f'99-page mean ${total:.2f}, buffered ${1.5*total:.2f}'
            + ('' if complete else ' (dedicated OCR at published price)')) if projected \
        else 'full-panel projection withheld (incomplete pilot)'
    print(f'{out}: pilot ${P.spent()+mistral_cost:.6f}; {detail}')
