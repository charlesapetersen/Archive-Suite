#!/usr/bin/env python3
"""W46.ocr-postcorrect: image-grounded post-correction in the NES 70-90 band only (C test 6).

    python3 postcorrect.py pack --out DIR --public-manifest public895.jsonl   # on the Mac; no model call
    uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy \
        python3 postcorrect.py score --pack DIR                               # the collected replies; no model call

The pack is chosen from segbench-results/ocr-scorers-pages.csv, the rescorer's own per-page NES, and the readings come
from ocr_rescore.py's loaders, so the input is exactly the text those scores were computed on:

  band     pages a cheap reading scored NES 0.70-0.90: on the 96 the app's cheap readers (Apple Vision, LightOnOCR-3 4B
           on the Mac, Qwen3-VL 8B, Gemini 3.5 Flash-Lite), all of them; on the 895 the better open routes (GLM-OCR,
           LightOnOCR-3 4B, Qwen3-VL 8B) in L1, L2, L4 and L6, at most CAP_PUBLIC a route, spread over the strata.
  easy     the abstention check: on the 96, up to CAP_EASY pages a cheap reader scored 0.97 or more, which a corrector
           must leave as they are.

Each item goes to the corrector twice: with the page image (the field's safe design) and as text only (the control,
the design the literature finds fails). Corrector: Qwen3.6-27B FP8, thinking off, temperature 0, on Sherlock.

Each route is one (route, family) source. The 2026-10-22 pack keyed the readings by route alone, so the 96's two
Qwen3-VL 8B families (local panel, FarmShare panel) collapsed: every request carried the FarmShare panel's reading,
while 30 rows repeated an id and 34 band rows carried the local panel's NES (W46.fix-postcorrect-pack). The pack now
pins one family per route, refuses an id with two different inputs, and writes each request once. `score` reads a
collected pack as it is: one score per id, the baseline recomputed from the reading the prompt actually carried,
never the stored `nes`.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import random
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
RESULTS = HERE.parent.parent / 'segbench-results'

# (route, family). Qwen3-VL 8B on the 96 is the FarmShare panel's reading: the one the collected run was sent.
OWNER_ROUTES = (('apple-vision', 'Mac'), ('lightonocr-3-4b-mlx8', 'Mac local'), ('qwen3-vl-8b', 'FarmShare panel'),
                ('gemini3.5-flash-lite', 'cloud panel'))
PUBLIC_ROUTES = (('glm-ocr', 'FarmShare native'), ('lightonocr3-4b', 'FarmShare native'),
                 ('qwen3-vl-8b', 'FarmShare panel'))
FAMILY = {('owner96', r): f for r, f in OWNER_ROUTES} | {('public895', r): f for r, f in PUBLIC_ROUTES}
PUBLIC_STRATA = ('L1', 'L2', 'L4', 'L6')
LOW, HIGH, EASY = 0.70, 0.90, 0.97
CAP_PUBLIC, CAP_EASY, SEED = 40, 10, 46
# Where each set's page images sit on Sherlock: the 895 as the open sweep staged them; the 96 go up with the pack.
PUBLIC_IMAGES = '/scratch/users/cp1/fs-ocr/interactive-20261019/ocr/images'

PROMPT_IMAGE = (
    "Below is an OCR reading of the page in the image. Correct the reading against the image: fix characters and "
    "words that were misread, restore words that were dropped, and remove text that is not on the page. Do not "
    "translate, modernise, normalise spelling, rephrase or add anything that is not visible on the page. Keep the "
    "reading's line breaks and order wherever they are right. If the reading is already correct, return it unchanged. "
    "Reply with the corrected transcription only.\n\nOCR reading:\n")
PROMPT_TEXT = (
    "Below is an OCR reading of a historical document page. Correct OCR errors only: fix characters and words that "
    "were misread. Do not translate, modernise, normalise spelling, rephrase or add anything. Keep the line breaks and "
    "order. If the reading has no OCR error, return it unchanged. Reply with the corrected transcription only.\n\n"
    "OCR reading:\n")


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


MODEL_INPUT = ('arm', 'image', 'image_sha256', 'prompt')


def unique_requests(requests):
    """[request] with each id once, in first-seen order, and the number of repeats dropped. An id that recurs with a
    different model input is an error: which reply belongs to which reading could not be told."""
    seen, repeats = {}, 0
    for r in requests:
        first = seen.setdefault(r['id'], r)
        if first is r:
            continue
        diff = [k for k in MODEL_INPUT if first.get(k) != r.get(k)]
        if diff:
            raise SystemExit(f"{r['id']}: repeated with a different {', '.join(diff)}")
        repeats += 1
    return list(seen.values()), repeats


def reading_of(request) -> str:
    """The OCR reading a request sent: its prompt after the arm's fixed instruction."""
    prefix = PROMPT_IMAGE if request['arm'] == 'image' else PROMPT_TEXT
    if not request['prompt'].startswith(prefix):
        raise SystemExit(f"{request['id']}: prompt is not the {request['arm']} arm's")
    return request['prompt'][len(prefix):]


def cmd_pack(a):
    import ocr_rescore as X
    rows = list(csv.DictReader((RESULTS / 'ocr-scorers-pages.csv').open()))
    nes = lambda r: float(r['nes']) if r['ok'] == 'True' and r['nes'] else None
    rng = random.Random(SEED)
    owner_src = X.owner_sources()
    X.R.MANIFEST = RESULTS / 'bench-corpus/manifest.jsonl'
    public_src = X.public_sources(X.R.frozen())
    for set_, src in (('owner96', owner_src), ('public895', public_src)):
        for (s, route), family in FAMILY.items():
            if s == set_ and (route, family) not in src:
                raise SystemExit(f'{set_}: no source {route} ({family})')

    items, keys = [], {}
    def add(set_, route, family, page, kind, score, text):
        if not (text and text.strip()):
            return
        key = (set_, route, page)   # the request id's parts: one family per route, so one reading per key
        if key in keys:
            if keys[key]['reading'] != text or keys[key]['family'] != family:
                raise SystemExit(f'{key}: two different readings')
            return
        keys[key] = it = {'set': set_, 'route': route, 'family': family, 'page': page, 'kind': kind, 'nes': score,
                          'reading': text}
        items.append(it)

    for route, family in OWNER_ROUTES:
        mine = [r for r in rows if r['set'] == 'owner96' and r['route'] == route and r['family'] == family
                and nes(r) is not None]
        texts = owner_src[(route, family)]
        for r in mine:
            if LOW <= nes(r) <= HIGH:
                add('owner96', route, family, r['page'], 'band', nes(r), texts.get(r['page']))
        easy = [r for r in mine if nes(r) >= EASY]
        for r in rng.sample(easy, min(CAP_EASY, len(easy))):
            add('owner96', route, family, r['page'], 'easy', nes(r), texts.get(r['page']))
    for route, family in PUBLIC_ROUTES:
        band = [r for r in rows if r['set'] == 'public895' and r['route'] == route and r['family'] == family
                and r['stratum'] in PUBLIC_STRATA and nes(r) is not None and LOW <= nes(r) <= HIGH]
        # Spread the cap over the strata: shuffle, then take round-robin by stratum.
        by_s = {s: rng.sample([r for r in band if r['stratum'] == s], len([r for r in band if r['stratum'] == s]))
                for s in PUBLIC_STRATA}
        pick = []
        while len(pick) < CAP_PUBLIC and any(by_s.values()):
            for s in PUBLIC_STRATA:
                if by_s[s] and len(pick) < CAP_PUBLIC:
                    pick.append(by_s[s].pop())
        for r in pick:
            add('public895', route, family, r['page'], 'band', nes(r), public_src[(route, family)].get(r['page']))

    out = a.out; (out / 'images').mkdir(parents=True, exist_ok=True)
    # The open sweep's manifest of the 895 as staged on the cluster (id, image, sha256); the job checks each image.
    public_sha = {r['id']: r['sha256'] for r in map(json.loads, a.public_manifest.read_text().splitlines())}
    requests = []
    for it in items:
        if it['set'] == 'owner96':
            # The original-scale image the panel and truth96 read (its hash is truth99.jsonl's), not ocr-truth/pages.
            src = X.CACHE / 'ocr-panel-local/images' / f"{it['page']}-original.jpg"
            dst = out / 'images' / src.name
            if not dst.exists():
                shutil.copy2(src, dst)
            image, digest = f"{a.remote}/images/{src.name}", sha(src)
        else:
            image, digest = f"{PUBLIC_IMAGES}/{it['page']}.jpg", public_sha.get(it['page'])
        for arm, prompt in (('image', PROMPT_IMAGE), ('text', PROMPT_TEXT)):
            rid = f"{it['set']}__{it['route']}__{it['page']}__{arm}"
            requests.append({'id': rid, **{k: it[k] for k in ('set', 'route', 'family', 'page', 'kind', 'nes')}, 'arm': arm,
                             'image': image if arm == 'image' else None, 'image_sha256': digest,
                             'prompt': prompt + it['reading']})
    if len(unique_requests(requests)[0]) != len(requests):
        raise SystemExit('a request id repeats')
    with (out / 'requests.jsonl').open('w') as f:
        for r in requests:
            f.write(json.dumps(r, ensure_ascii=False) + '\n')
    counts = {}
    for it in items:
        k = f"{it['set']}/{it['kind']}"; counts[k] = counts.get(k, 0) + 1
    (out / 'pack.json').write_text(json.dumps({'items': len(items), 'requests': len(requests), 'counts': counts,
        'owner_routes': OWNER_ROUTES, 'public_routes': PUBLIC_ROUTES, 'public_strata': PUBLIC_STRATA,
        'band': [LOW, HIGH], 'easy': EASY, 'cap_public': CAP_PUBLIC, 'cap_easy': CAP_EASY, 'seed': SEED,
        'prompt_image_sha256': hashlib.sha256(PROMPT_IMAGE.encode()).hexdigest(),
        'prompt_text_sha256': hashlib.sha256(PROMPT_TEXT.encode()).hexdigest()}, indent=1) + '\n')
    print(json.dumps(counts), len(items), 'items,', len(requests), 'requests')


SCORE_FIELDS = ['id', 'set', 'route', 'family', 'page', 'stratum', 'kind', 'arm', 'finish', 'stored_nes', 'in_band',
                'nes_before', 'nes_after', 'nes_gain', 'cmer_before', 'cmer_after', 'inserted_before',
                'inserted_after', 'rewritten_before', 'rewritten_after', 'reading_words', 'reply_words', 'changed', 'words_changed']


def score_rows(requests, replies, truth_of, source_of=None):
    """One row per unique request id that has a reply: the reading's NES (recomputed against truth, from the reading
    the prompt carried) beside the corrected reply's. source_of(request) -> the pinned source's text, when given, must
    equal that reading, so a row's family is the one its input came from."""
    import ocr_rescore as X
    uniq, repeats = unique_requests(requests)
    rows, missing = [], []
    for r in uniq:
        reading = reading_of(r)
        family = r.get('family') or FAMILY[(r['set'], r['route'])]
        if source_of is not None and (source_of(r) or '') != reading:
            raise SystemExit(f"{r['id']}: the reading is not {r['route']} ({family})'s")
        got = replies.get(r['id'])
        if got is None:
            missing.append(r['id']); continue
        truth, stratum, latin = truth_of(r)
        reply = (got.get('text') or '').strip()
        before = X.page_row(truth, reading.strip(), stratum, None, latin)
        after = X.page_row(truth, reply, stratum, None, latin)
        rows.append({'id': r['id'], 'set': r['set'], 'route': r['route'], 'family': family, 'page': r['page'],
                     'stratum': stratum, 'kind': r['kind'], 'arm': r['arm'], 'finish': got.get('finish'),
                     'stored_nes': r.get('nes'), 'in_band': LOW <= before['nes'] <= HIGH,
                     'nes_before': before['nes'], 'nes_after': after['nes'], 'nes_gain': after['nes'] - before['nes'],
                     'cmer_before': before['cmer'], 'cmer_after': after['cmer'],
                     'inserted_before': before['inserted'], 'inserted_after': after['inserted'],
                     'rewritten_before': before['rewritten'], 'rewritten_after': after['rewritten'],
                     'reading_words': before['reading_words'], 'reply_words': after['reading_words'],
                     'changed': reply != reading.strip(),
                     'words_changed': X.words(reply, stratum) != X.words(reading, stratum)})
    return rows, repeats, missing


def summarise(rows):
    """Means by set, kind, route and arm, and by set, kind and arm over all routes."""
    import statistics
    groups = {}
    for r in rows:
        for route in (r['route'], 'all'):
            groups.setdefault((r['set'], r['kind'], route, r['arm']), []).append(r)
    mean = lambda rr, k: statistics.fmean(x[k] for x in rr)
    return [{'set': s, 'kind': k, 'route': route, 'arm': arm, 'n': len(rr),
             'off_band': sum(1 for x in rr if k == 'band' and not x['in_band']),
             'capped': sum(1 for x in rr if x['finish'] != 'stop'),
             'nes_before': mean(rr, 'nes_before'), 'nes_after': mean(rr, 'nes_after'), 'nes_gain': mean(rr, 'nes_gain'),
             'cmer_before': mean(rr, 'cmer_before'), 'cmer_after': mean(rr, 'cmer_after'),
             'added_before': sum(x['inserted_before'] for x in rr) / max(1, sum(x['reading_words'] for x in rr)),
             'added_after': sum(x['inserted_after'] for x in rr) / max(1, sum(x['reply_words'] for x in rr)),
             'changed': mean(rr, 'changed'), 'words_changed': mean(rr, 'words_changed'), 'worse': sum(1 for x in rr if x['nes_gain'] < 0)}
            for (s, k, route, arm), rr in sorted(groups.items())]


def cmd_score(a):
    import ocr_rescore as X
    requests = [json.loads(l) for l in (a.pack / 'requests.jsonl').read_text().splitlines()]
    replies = {f.stem: json.loads(f.read_text()) for f in (a.pack / 'out').glob('*.json')}
    X.R.MANIFEST = RESULTS / 'bench-corpus/manifest.jsonl'
    frozen = X.R.frozen()
    by = {X.R.job_id(r): r for r in frozen}

    def truth_of(r):
        if r['set'] == 'owner96':
            return (X.P.TRUTH / 'truth' / f"{r['page']}.txt").read_text(), 'S0', True
        j = by[r['page']]
        return Path(j['truth']).read_text(), j['stratum'], j['script'] == 'Latn'

    source_of = None
    if not a.no_source_check:
        src = {'owner96': X.owner_sources(), 'public895': X.public_sources(frozen)}
        source_of = lambda r: src[r['set']][(r['route'], r.get('family') or FAMILY[(r['set'], r['route'])])].get(r['page'])
    rows, repeats, missing = score_rows(requests, replies, truth_of, source_of)
    out = a.out or a.pack
    out.mkdir(parents=True, exist_ok=True)
    with (out / 'scores.csv').open('w', newline='') as f:
        w = csv.DictWriter(f, SCORE_FIELDS)
        w.writeheader()
        for r in rows:
            w.writerow({k: (f'{v:.6f}' if isinstance(v, float) else v) for k, v in r.items()})
    summary = summarise(rows)
    (out / 'scores.json').write_text(json.dumps({'pack_rows': len(requests), 'unique': len(requests) - repeats,
        'repeats_dropped': repeats, 'scored': len(rows), 'missing': missing,
        'stored_nes_differs': sum(1 for r in rows if abs(float(r['stored_nes']) - r['nes_before']) > 1e-4),
        'summary': summary}, indent=1) + '\n')
    print(f'{len(requests)} pack rows, {len(requests) - repeats} unique, {len(rows)} scored, {len(missing)} missing '
          f'-> {out}')
    for g in summary:
        if g['route'] == 'all':
            print(f"{g['set']:9} {g['kind']:4} {g['arm']:5} n={g['n']:3} NES {g['nes_before']:.3f} -> "
                  f"{g['nes_after']:.3f}  changed {g['changed']:.0%} (words {g['words_changed']:.0%})  worse {g['worse']}  off-band {g['off_band']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('pack'); p.add_argument('--out', type=Path, required=True)
    p.add_argument('--remote', default='/scratch/users/cp1/fs-ocr/postcorrect-20261022')
    p.add_argument('--public-manifest', type=Path, required=True, help="open-sweep-20261019/public895.jsonl")
    p = sub.add_parser('score'); p.add_argument('--pack', type=Path, required=True, help='requests.jsonl and out/')
    p.add_argument('--out', type=Path, help='where scores.csv and scores.json go (default: the pack)')
    p.add_argument('--no-source-check', action='store_true', help="skip matching each reading to its source's text")
    a = ap.parse_args()
    {'pack': cmd_pack, 'score': cmd_score}[a.cmd](a)


if __name__ == '__main__':
    main()
