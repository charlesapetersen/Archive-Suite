#!/usr/local/bin/python3
"""Aggregate W41 OCR panel scores. No network; raw text and page-level scores stay outside git.
Requires rapidfuzz, regex and sacrebleu==2.5.1 (see ocr-panel-requirements.txt).
"""
from __future__ import annotations
import collections
import csv
import json
import random
import re
import unicodedata
from pathlib import Path

import regex
from rapidfuzz.distance import Levenshtein
from sacrebleu.metrics import CHRF
import ocr_panel as P

CHRF2 = CHRF(char_order=6, word_order=0, beta=2, lowercase=False, whitespace=False, eps_smoothing=False)
PARAMETERS = {
 'qwen3.5-9b': 9653104368, 'qwen3.5-27b': 27781427952, 'qwen3.5-35b-a3b': 35951822704,
 'qwen3.6-27b': 27781427952, 'qwen3.6-35b-a3b': 35951822704,
 'gemma4-26b-a4b': 25805936206, 'gemma4-31b': 31273088876,
 'qwen3-vl-8b': 8767123696, 'qwen3-vl-30b-a3b': 31070754032, 'mistral-small-24b': 24011361280,
}
# Exact tensor counts including vision/MTP from the makers' HF safetensors metadata, 2026-10-14.
HF = {
 'qwen3.5-9b': 'Qwen/Qwen3.5-9B', 'qwen3.5-27b': 'Qwen/Qwen3.5-27B',
 'qwen3.5-35b-a3b': 'Qwen/Qwen3.5-35B-A3B', 'qwen3.6-27b': 'Qwen/Qwen3.6-27B',
 'qwen3.6-35b-a3b': 'Qwen/Qwen3.6-35B-A3B', 'gemma4-26b-a4b': 'google/gemma-4-26B-A4B-it',
 'gemma4-31b': 'google/gemma-4-31B-it', 'qwen3-vl-8b': 'Qwen/Qwen3-VL-8B-Instruct',
 'qwen3-vl-30b-a3b': 'Qwen/Qwen3-VL-30B-A3B-Instruct',
 'mistral-small-24b': 'mistralai/Mistral-Small-3.2-24B-Instruct-2506',
}


# W43.corpus-build. Unicode is NFC; the compatibility folds NFKC used to make silently are applied per character,
# except the characters a stratum's strict score keeps. On the owner's 96 (S0) nothing is kept, so S0 scores as
# before; the old and new scorers' S0 figures are compared in the commit that made this change.
LONG_S_AND_LIGATURES = frozenset('ſﬀﬁﬂﬃﬄﬅﬆ')
# Historical letter forms a mapped score folds. Strict scores keep every one of them as written.
HISTORICAL_MAP = {'ſ': 's', 'ꝛ': 'r', 'ﬀ': 'ff', 'ﬁ': 'fi', 'ﬂ': 'fl', 'ﬃ': 'ffi', 'ﬄ': 'ffl', 'ﬅ': 'st', 'ﬆ': 'st',
                  'æ': 'ae', 'Æ': 'Ae', 'œ': 'oe', 'Œ': 'Oe', 'v': 'u', 'V': 'U', 'j': 'i', 'J': 'I', 'ꝰ': 'us',
                  'ꝯ': 'con', 'ꝑ': 'p', 'ꝓ': 'p', 'ꝗ': 'q', 'ꝙ': 'q', '⁊': '&'}
# Combining abbreviation marks (macron, tilde, overline, the superscript letters) a mapped score drops.
ABBREVIATION_MARKS = re.compile('[̃̄̅̾ͣ-ͯᷓ-ᷴ]')
BIDI_CONTROLS = re.compile('[‎‏‪-‮⁦-⁩]')
GRAPHEME = regex.compile(r'\X')
CJK = re.compile('[⺀-鿿가-힯豈-﫿\U00020000-\U0003134f]')

# One entry per stratum of execution-plans/benchmark-corpus/00-plan.md. keep: characters the strict score keeps
# distinct; mapped: also report a score after HISTORICAL_MAP; hyphens: join a line-end '-' with the next line in
# truth and reading (By the People's convention); diacritics: also report a score without combining marks;
# nospace: also report a character score with all whitespace removed (the CER convention, for CJK).
STRATA = {
    'S0': {}, 'L1': {'hyphens': True}, 'L2': {'hyphens': True, 'keep': LONG_S_AND_LIGATURES, 'mapped': True},
    'L3': {'hyphens': True}, 'L4': {},
    **{s: {'keep': LONG_S_AND_LIGATURES, 'mapped': True} for s in ('L5', 'L6', 'L7', 'L8')}, 'L9': {},
    'N1': {'diacritics': True}, 'N2': {}, 'N3': {'diacritics': True}, 'N4': {'diacritics': True},
    'N5': {'nospace': True}, 'N6': {'diacritics': True},
}


def compat_fold(text, keep=frozenset()):
    """NFC, then NFKC's compatibility folds character by character, except the characters in keep."""
    text = unicodedata.normalize('NFC', text)
    if not keep:
        return unicodedata.normalize('NFKC', text)
    return unicodedata.normalize('NFC', ''.join(c if c in keep else unicodedata.normalize('NFKC', c) for c in text))


def normal(text, keep=frozenset(), hyphens=False):
    """Truth stores words only. Preserve case/spelling; unify Unicode typography/table separators.

    Star, bullet, and a *standalone* dash at the start of a line all count as a bullet.
    A prose dash, hyphenation and punctuation otherwise remain; no spelling corrections.
    Bidi control marks are dropped: truth is in logical order and is never reordered.
    """
    text = BIDI_CONTROLS.sub('', compat_fold(text, keep)).translate(str.maketrans(
        {'‘': "'", '’': "'", '“': '"', '”': '"', '–': '-', '—': '-', '−': '-', '|': ' ', '•': '*'}))
    if hyphens:
        text = re.sub(r'(\w)-[ \t]*\n[ \t]*(?=\w)', r'\1', text)
    text = re.sub(r'(?m)^\s*-\s+(?=\S)', '* ', text)
    return ' '.join(text.split())


def tokens(text):
    """Lower-cased words of letters, digits and combining marks; CJK characters count one word each."""
    words = CJK.sub(lambda m: f' {m.group()} ', text).split()
    # lower() turns a capital dotted İ into i + U+0307; that dot is an artefact of lower-casing, not a mark.
    return [t for w in words if (t := ''.join(c for c in w.lower().replace('i̇', 'i')
                                              if c.isalnum() or unicodedata.category(c) in ('Mn', 'Mc')))]


def nes(truth, hyp):
    """1 - Levenshtein / max(length), both counted in grapheme clusters, so a base letter and its marks are one."""
    a, b = GRAPHEME.findall(truth), GRAPHEME.findall(hyp)
    if len(a) == len(truth) and len(b) == len(hyp):
        a, b = truth, hyp  # one code point per cluster: the same distance, and much faster on strings
    n = max(len(a), len(b))
    return 1 - Levenshtein.distance(a, b) / n if n else 1.


def historical(text):
    return ABBREVIATION_MARKS.sub('', unicodedata.normalize('NFD', text.translate(str.maketrans(HISTORICAL_MAP))))


def no_marks(text):
    return unicodedata.normalize('NFC', ''.join(
        c for c in unicodedata.normalize('NFD', text) if unicodedata.category(c) != 'Mn'))


def score(truth, hyp, stratum='S0'):
    opt = STRATA[stratum]
    raw_truth, raw_hyp = truth, hyp
    truth = normal(truth, opt.get('keep', frozenset()), opt.get('hyphens', False))
    hyp = normal(hyp, opt.get('keep', frozenset()), opt.get('hyphens', False))
    n = max(len(truth), len(hyp))
    chrf = CHRF2.sentence_score(hyp, [truth]).score / 100 if n else 1.
    # Like Vision OCR's contested text, the literal marker isn't a scored word.
    # No word-span labels exist here; substantive handwriting remains scored (and separately grouped).
    known = re.sub(r'\[illegible\]', '', truth, flags=re.I)
    reading = re.sub(r'\[illegible\]', '', hyp, flags=re.I)
    a, b = collections.Counter(tokens(known)), collections.Counter(tokens(reading))
    nwords, nhyp = sum(a.values()), sum(b.values())
    matched = sum((a & b).values())
    out = {'nes': nes(truth, hyp), 'chrf': chrf, 'words': nwords, 'hyp_words': nhyp,
           'missed': nwords - matched, 'added': nhyp - matched,
           'illegible': len(re.findall(r'\[illegible\]', truth, flags=re.I))}
    if opt.get('mapped'):
        h = lambda t: normal(historical(compat_fold(t)), hyphens=opt.get('hyphens', False))
        out['nes_mapped'] = nes(h(raw_truth), h(raw_hyp))
    if opt.get('diacritics'):
        out['nes_no_marks'] = nes(no_marks(truth), no_marks(hyp))
    if opt.get('nospace'):
        out['nes_no_space'] = nes(''.join(truth.split()), ''.join(hyp.split()))
    return out


def paired(a, b, rounds=10000, seed=0):
    """Mean difference of two routes' per-page scores on the same pages, a two-sided paired permutation p (random
    sign flips) and a 95% bootstrap interval. Per-page differences are heavy-tailed, so no t-test (plan §4)."""
    d = [x - y for x, y in zip(a, b, strict=True)]
    if not d:
        return {'n': 0, 'delta': 0., 'p': 1., 'lo': 0., 'hi': 0.}
    rng = random.Random(seed); n = len(d); delta = sum(d) / n
    extreme = sum(abs(sum(x if rng.random() < .5 else -x for x in d)) >= abs(sum(d)) - 1e-12 for _ in range(rounds))
    boots = sorted(sum(rng.choice(d) for _ in range(n)) / n for _ in range(rounds))
    return {'n': n, 'delta': delta, 'p': (extreme + 1) / (rounds + 1),
            'lo': boots[int(.025 * rounds)], 'hi': boots[int(.975 * rounds) - 1]}


def aggregate(rr):
    n = len(rr); words = sum(r['words'] for r in rr); answered = [r for r in rr if r['ok']]
    return {'n': n, 'ok': len(answered),
            'failed': 1 - len(answered) / n if n else 0,
            # Plan §4: failures are their own figure, and NES over the answered pages halves the paired SD.
            'nes_answered': sum(r['nes'] for r in answered) / len(answered) if answered else 0,
            'nes': sum(r['nes'] for r in rr) / n if n else 0,
            'chrf': sum(r['chrf'] for r in rr) / n if n else 0,
            'miss': sum(r['missed'] for r in rr) / words if words else 0,
            'add': sum(r['added'] for r in rr) / words if words else 0,
            'cost': sum(r.get('cost', 0) for r in rr), 'words': words}


def group_values(r, cal):
    groups = {'stratum': r.get('stratum') or 'S0', 'collection': r['collection'], 'source': r['source'], 'date_bin': r['date_bin'],
              'kind': r['kind'], 'table_form': r['table_form'] or 'no', 'camera': r['camera'] or '(no EXIF)',
              'year_taken': r['year_taken'], 'ladder_member': r['ladder'] or 'no'}
    for field in ('handwritten', 'clippings', 'tables'):
        groups[field + '_tag'] = r[field] or 'no'
    for field in ('long_side', 'sharpness', 'year_taken'):
        groups[field + '_tertile'] = ('low', 'middle', 'high')[P.T.tertile(float(r[field]), cal[field])]
    # Tags overlap. Identity columns (file/folder/page) live only in the private per-page table.
    return [(k, v) for k, v in groups.items()] + [('tag', t.strip()) for t in r['tags'].split(';') if t.strip()]


def all_scores():
    m = P.manifest(); by_page = {r['page']: r for r in P.rows()}
    cal = json.loads((P.TRUTH / 'calibrate.json').read_text())
    attempted_jobs = {(r['key'],r['job']) for r in P.records()}
    out = []
    for key in [*P.MODELS, 'apple-vision']:
        for job in m['jobs']:
            page = job['page']; row = by_page[page]
            truth = (P.TRUTH / 'truth' / (page + '.txt')).read_text()
            if key == 'apple-vision':
                f = P.CACHE / 'vision' / (job['id'] + '.txt')
                ok = f.exists(); text = f.read_text() if ok else ''; meta = {'cost': 0}
                attempted = ok
            else:
                f = P.CACHE / 'responses' / key / (job['id'] + '.json')
                got = json.loads(f.read_text()) if f.exists() else {}
                meta = got.get('meta') or {}; parsed = got.get('parsed')
                ok = bool(parsed); text = parsed['text'] if ok else ''; attempted = f.exists() or (key, job['id']) in attempted_jobs
            s = score(truth, text)
            out.append({**job, **s, 'key': key, 'ok': ok, 'attempted': attempted, 'cost': meta.get('cost', 0),
                        'agreement': page in P.AGREEMENT, 'groups': group_values(row, cal),
                        'kind_correct': parsed['kind'] == row['kind'] if key != 'apple-vision' and ok else None,
                        'prompt_tokens': meta.get('prompt_tokens'), 'completion_tokens': meta.get('completion_tokens')})
    return out


def write_csv(path, rr, fields):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('w') as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction='ignore')
        writer.writeheader(); writer.writerows(rr)


def cloud_estimate(calls):
    """Measured usage proxy, not an assertion that different image tokenizers have equal costs."""
    usage = []
    for k in P.MODELS:
        rr = [r for r in calls if r['key'] == k and r['scale'] == 'original' and r['status'] == 'ok']
        if rr:
            usage.append((sum(r['prompt_tokens'] for r in rr)/len(rr),
                          sum(r['completion_tokens'] for r in rr)/len(rr)))
    if not usage:
        return ['No completed local calls from which to estimate cloud usage.']
    lo_in, hi_in = min(i for i,o in usage), max(i for i,o in usage)
    lo_out, hi_out = min(o for i,o in usage), max(o for i,o in usage)
    prices = json.loads(Path(__file__).with_name('ocr-panel-cloud-prices.json').read_text())
    L = ['## Cloud-panel estimate for the owner (no cloud-panel calls made)', '',
         f'Completed original-page routes average {lo_in:.0f}–{hi_in:.0f} input and '
         f'{lo_out:.0f}–{hi_out:.0f} output tokens/page. The range below applies these measured '
         'extremes to the current listed prices, **not** a measurement of the cloud models’ tokenizers. '
         'Image token budgets and reasoning can change it. The high figure adds a 50% retry/tokenization '
         'buffer. Pin actual providers and re-estimate from a three-page pilot before committing the rest. '
         'Twelve chat models, 99 originals each; no ladder variants in this estimate.', '',
         '| cloud model | listed $/M input/output | 99 pages, low proxy | 99 pages, high proxy +50% |',
         '|---|---:|---:|---:|']
    total_lo, total_hi = 0, 0
    for r in prices['models']:
        p, c = r['prompt_per_million'], r['completion_per_million']
        lo = 99*(lo_in*p + lo_out*c)/1e6
        hi = 1.5*99*(hi_in*p + hi_out*c)/1e6
        total_lo += lo; total_hi += hi
        L.append(f"| {r['model']} | {p:g}/{c:g} | ${lo:.2f} | ${hi:.2f} |")
    L += ['', f'**Total chat-panel proxy: ${total_lo:.2f}–${total_hi:.2f}.** '
          'Mistral’s dedicated OCR endpoint is additional and needs its own key and current per-page price check. '
          'Its 99 pages and any ladder extension must be added before approval. The existing '
          '`W41.ocr-panel-cloud-owner-ok` gate remains open; this is an estimate, not authorization to spend. '
          f'Prices: [OpenRouter model catalog]({prices["source"]}), snapshot {prices["date"]}. '
          'The snapshot is committed beside this scorer; listed minimum prices may differ from the pinned provider.', '']
    return L


def report():
    ss = all_scores()
    P.save(P.CACHE / 'scores.json', ss)  # every page score, no text, private
    write_csv(P.CACHE / 'scores.csv', ss, ['key', 'page', 'scale', 'ok', 'attempted', 'nes', 'chrf',
                                          'words', 'missed', 'added', 'cost', 'agreement', 'width', 'height'])
    main = [r for r in ss if r['scale'] == 'original' and not r['agreement']]
    by = collections.defaultdict(list)
    for r in main:
        for g in r['groups']:
            by[(r['key'], *g)].append(r)
    groups = [{'model': k, 'provider': P.MODELS[k][1] if k in P.MODELS else 'Apple Vision',
               'precision': P.MODELS[k][2] or 'unpublished' if k in P.MODELS else 'OS model',
               'attribute': a, 'value': v, **aggregate(rr)} for (k, a, v), rr in sorted(by.items())]
    write_csv(P.RESULTS / 'ocr-panel-local-groups.csv', groups,
              ['model', 'provider', 'precision', 'attribute', 'value', 'n', 'ok', 'nes', 'chrf', 'miss', 'add', 'words', 'cost'])
    L = ['# W41.ocr-panel-local — results', '',
         'Reproduce: `ocr_panel.py prepare`, `collect --probe`, `collect`, `vision` (under the heavy lock), then '
         '`ocr_panel_score.py`. Inputs, catalogs, raw responses, reservations and page scores: '
         '`~/Library/Caches/ArchiveSuiteRehearsal/ocr-panel-local/` (outside git).', '',
         f'Conservative OpenRouter budget accounting, every attempt: **${P.spent():.6f} / $2.00 cap**. '
         'Each row pins one endpoint and precision; temperature 0, reasoning off (Flash-Lite minimal; '
         'the VL Instruct/Mistral endpoints have no reasoning control). No paid retries.', '',
         '## Scoring and limits', '',
         '99 settled originals, 96 in the accuracy table below. p038 excluded by the owner. '
         'The three Michael Young letters p086/p094/p096 are shown separately as **agreement with Claude/Gemini**, '
         'not measured accuracy. The truth was drafted by Claude Opus 5.5 and Gemini 3.8 Flash, then adjudicated; '
         'unreviewed agreements can still favor those models.', '',
         'NES is 1 − character Levenshtein/max(lengths), as [socOCRbench](https://noahdasanaike.github.io/posts/sococrbench.html) '
         'defines it. chrF uses [SacreBLEU 2.5.1](https://github.com/mjpost/sacrebleu/tree/v2.5.1), '
         'character orders 1–6, beta 2, no word n-grams or whitespace, case preserved, effective orders. '
         'The benchmark does not publish its exact chrF/normalization settings; these explicit settings are our reproduction choice. '
         'NES/chrF are per-page means; word rates pool counts, as Vision OCR does.', '',
         'Normalization: NFKC, straight quotes/dashes, whitespace collapsed, table bars removed; spelling and case retained. '
         '“•”, “*” and a leading standalone “-” count as a bullet. Other dashes remain. '
         '`[illegible]` is literal in NES/chrF (agreement on the marker, not proof of reading the hidden word). '
         'For word rates it is removed from both sides. Words use Vision OCR’s lowercase/alphanumeric whitespace tokenizer '
         'and multiset intersection: missed=(truth−matched)/truth, added=(reading−matched)/truth. '
         'These rates ignore order and punctuation; unlike NES they do not detect column reordering. '
         'A real reading at an unknown truth span can count as added, so additions there are an upper bound. '
         'All substantive handwriting is included here; Vision OCR’s lab excludes its separately annotated hand/figure/contested spans, '
         'which this truth set does not label. Direct cross-corpus score comparisons would be invalid.', '',
         'Failed responses score as empty (NES/chrF 0, all words missed); missing inputs also score empty and are counted as not attempted. '
         'A panel with missing inputs is incomplete, not a finished model comparison. Kind labels do not choose the scoring groups: '
         'the owner’s truth-table labels do.', '',
         'Every source is converted to JPEG quality 90 and capped at 2400 pixels on its long side for every route, Vision included. '
         'Ladder half/quarter images are fractions of the **native source**, independently capped at 2400; they are not always '
         'half/quarter of the capped original. Actual input dimensions are in private `scores.csv`. '
         'Only 20 matched pages have ladder variants; compare them to their own originals, not to the other 79 pages. '
         'This measures photo downsampling plus each provider’s own visual token budget. No local quantization or throughput was measured.', '',
         '## Original pages (96, excluding the agreement-only letters)', '',
         '| model | completed / attempted / 96 | NES % | chrF2 % | words missed % | words added % | cost/original |',
         '|---|---:|---:|---:|---:|---:|---:|']
    for k in [*P.MODELS, 'apple-vision']:
        rr = [r for r in main if r['key'] == k]; a = aggregate(rr)
        n = sum(r['attempted'] for r in rr)
        L.append(f"| {k} | {a['ok']}/{n}/{a['n']} | {100*a['nes']:.2f} | {100*a['chrf']:.2f} | {100*a['miss']:.2f} | {100*a['add']:.2f} | ${a['cost']/n if n else 0:.6f} |")
    L += ['', '## Completed original responses only (coverage differs)', '',
          'These conditional scores diagnose transcription quality apart from response failures. '
          'Compare the coverage above; a small or selective successful subset can flatter a route.', '',
          '| model | completed / 96 | NES % | chrF2 % | missed % | added % |',
          '|---|---:|---:|---:|---:|---:|']
    for k in [*P.MODELS, 'apple-vision']:
        a = aggregate([r for r in main if r['key'] == k and r['ok']])
        L.append(f"| {k} | {a['n']}/96 | {100*a['nes']:.2f} | {100*a['chrf']:.2f} | {100*a['miss']:.2f} | {100*a['add']:.2f} |")
    L += ['', '## All 99 pages, agreement-only letters, and the matched ladder', '',
          '| model | subset | completed / n | NES % | chrF2 % | missed % | added % |',
          '|---|---|---:|---:|---:|---:|---:|']
    for k in [*P.MODELS, 'apple-vision']:
        rr = [r for r in ss if r['key'] == k]
        ladder = {r['page'] for r in rr if r['scale'] == 'half'}
        for label, subset in [('all-99', [r for r in rr if r['scale'] == 'original']),
                              ('agreement-only', [r for r in rr if r['scale'] == 'original' and r['agreement']]),
                              *[(f'ladder-{s}', [r for r in rr if r['page'] in ladder and r['scale'] == s])
                                for s in ('original', 'half', 'quarter')]]:
            a = aggregate(subset)
            L.append(f"| {k} | {label} | {a['ok']}/{a['n']} | {100*a['nes']:.2f} | {100*a['chrf']:.2f} | {100*a['miss']:.2f} | {100*a['add']:.2f} |")
    L += ['', 'The [attribute table](ocr-panel-local-groups.csv) includes collection, source, historical period, '
          'owner-confirmed kind, tag strata, table/form flag, camera, capture year, pixel/sharpness/year tertiles, '
          'ladder membership and every tag (overlapping groups). Small groups are descriptive, not reliable rankings. '
          'Page/folder/file identity fields are private; the per-page table allows any further grouping.', '',
          '## Pinned routes and measured costs', '']
    calls = P.records()
    policy_zero = sum(bool(r.get('cost_policy_zero')) for r in calls)
    if policy_zero:
        L += ['', f'{policy_zero} explicit empty provider errors are accounted at $0 under '
              '[OpenRouter’s zero-completion insurance](https://openrouter.ai/blog/announcements/never-pay-for-empty-ai-responses-again/). '
              'These are policy-covered failures, not successful free readings; raw error bodies are saved.']
    uncertain = [r for r in calls if r.get('cost_upper_bound')]
    if uncertain:
        upper = sum(r['cost'] for r in uncertain)
        keyed = sum(r.get('cost_basis') == 'key-usage-daily' for r in uncertain)
        basis = ('their full pre-call reservations' if not keyed else
                 f'{keyed} bounded by the API key’s own billing for the UTC day, which exceeded the measured charges '
                 f"by at most ${max(r['cost'] for r in uncertain if r.get('cost_basis') == 'key-usage-daily'):.6f}; "
                 'each such call carries that whole difference'
                 + ('' if keyed == len(uncertain) else '; the rest at their full pre-call reservations'))
        L += ['', f'**Billing uncertainty:** {len(uncertain)} provider errors or interrupted calls had no usable billing record. '
              f'{sum(r.get("billing_lookup_http")==404 for r in uncertain)} generation lookups returned 404; '
              'other failures had no retained generation ID. '
              f'Reported charges are ${P.spent()-upper:.6f}; an additional ${upper:.6f} ({basis}) '
              'is counted as a conservative ceiling against the cap. Cost columns include these ceilings and are not '
              'all measured charges. These failed calls are cached and never retried. Raw errors and lookup evidence '
              'remain in the private cache.']
    L += ['', '| model | endpoint | precision | accounted calls | failures | $/call (charges + uncertain ceilings) | mean input/output tokens |',
          '|---|---|---|---:|---:|---:|---:|']
    for k, spec in P.MODELS.items():
        rr = [r for r in calls if r['key'] == k and r['status'] in ('ok', 'failed')]; n = len(rr)
        L.append(f"| {k} | {spec[1]} | {spec[2] or 'unpublished'} | {n} | {sum(r['status']=='failed' for r in rr)} | "
                 f"${sum(r['cost'] for r in rr)/n if n else 0:.6f} | "
                 f"{sum(r.get('prompt_tokens') or 0 for r in rr)/n if n else 0:.0f}/{sum(r.get('completion_tokens') or 0 for r in rr)/n if n else 0:.0f} |")
    L += ['', 'Routes/prices were frozen from [OpenRouter’s endpoint catalog](https://openrouter.ai/api/v1/models); '
          '[provider routing](https://openrouter.ai/docs/guides/routing/provider-selection) disables fallbacks and filters precision. '
          'Provider-reported precision is not an audit of its weights. Hosted latency is not Mac inference speed.', '',
          '## Local memory: estimates, not tested fits', '',
          'Weight floors use the makers’ total safetensors counts (vision/MTP included where published), '
          'not MoE active counts: parameters × bits / 8 / 2³⁰. Planning totals below = weight floor ×1.15 + '
          '4 GiB runtime +4 GiB OS. This is a stated heuristic for one short page at a time; quantization scales, '
          'full-precision layers, images and KV/context can exceed it. “Fits” below means only that heuristic clears '
          'the installed memory; validate the actual build before recommending it.', '',
          '| model | Q4/Q8 weight GiB | Q4/Q8 planning GiB | estimated Q4 Macs | estimated Q8 Macs |',
          '|---|---:|---:|---|---|']
    for k, n in PARAMETERS.items():
        w4, w8 = n * .5 / 2**30, n / 2**30
        e4, e8 = w4*1.15+8, w8*1.15+8
        fits = lambda e: ', '.join(str(m) for m in (18,32,48,64) if m >= e)
        L.append(f'| [{k}](https://huggingface.co/{HF[k]}) | {w4:.2f}/{w8:.2f} | {e4:.2f}/{e8:.2f} | {fits(e4)} | {fits(e8)} |')
    L += ['', '18 GiB: 8–9B Q4 is the conservative candidate; VL-8B Q8 is marginal by this estimate and Qwen9B Q8 exceeds it. '
          '32 GiB: every listed model is a Q4 candidate; larger Q8 builds need 48 GiB. 48/64 GiB: all listed Q8 builds clear '
          'this estimate. No precision-specific accuracy claim follows: OpenRouter’s bf16/fp8 quality is **not measured Mac Q4 quality**.', '',
          'Vision OCR’s separate lab has Qwen3-VL-8B MLX4 results (65 newspaper pages; whole-page peak about 9.7 GB) '
          'and an abandoned Qwen3.5-9B run (8 whole/6 crop readings). They use different images and scoring masks, '
          'so they provide no matched hosted-vs-Q4 comparison and cannot quantify a quantization penalty. '
          'Source: read-only `vision-ocr/OCR-BAKEOFF-2026-10-07.tsv` and `ops/ocrlab/score-bakeoff.py`.', '']
    L += cloud_estimate(calls)
    (P.RESULTS / 'ocr-panel-local.md').write_text('\n'.join(L))
    print(f'report: {len(ss)} scored model-input pairs, ${P.spent():.6f} accounted')

if __name__ == '__main__':
    report()
