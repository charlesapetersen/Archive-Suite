#!/usr/bin/env python3
"""W43.corpus-build — draw, check and freeze the broader truth set (plan §7 steps 4-5).

  sample.py list                 # every source's candidates -> CACHE/candidates.jsonl, counts by stratum
  sample.py draw                 # seeded draw per stratum, quarter cap per collection; fetch the drawn pages
  sample.py sanity               # Apple Vision reads the drawn Latin/Cyrillic/Arabic pages; flags low scorers
  sample.py drop KEY REASON      # drop a drawn page (wrong or misplaced truth); the next draw replaces it
  sample.py freeze               # write the committed manifest; no model call may come before its commit

The draw is a pure function of the candidates, SEED and the drops file: each stratum's candidates are sorted by
key and shuffled with Random(f'{SEED}:{stratum}'), then taken in that order while no collection has more than a
quarter of the stratum's target. If the cap leaves the stratum short, a second pass in the same order fills it
and marks those pages `over_cap`, so a thin stratum is visible rather than quietly capped. Drops are recorded
with their reason and replaced from further down the same order: the sample is not quietly made easy.

Images and truth stay in CACHE (third-party material; the owner publishes scores only). The repo gets the
manifest: source, item URL, licence, checksums, stratum, convention, contamination and the publish flag.
"""
from __future__ import annotations

import argparse
import collections
import importlib
import json
import random
import statistics
import subprocess
import sys
from pathlib import Path

import common as C

SEED = 'W43.corpus-build/2026-10-16'
TARGET = {**{f'L{i}': 80 for i in range(1, 10)}, **{f'N{i}': 40 for i in range(1, 7)}}
SOURCES = ['read2017', 'kurrent', 'eparchos', 'biblia', 'muharaf', 'sbb',
           'tapus', 'ocrd', 'iforal', 'newsbench',
           'koenigsfelden', 'castilian', 'voc', 'bentham']
RESULTS = Path(__file__).resolve().parents[3] / 'segbench-results' / 'bench-corpus'
CANDIDATES = C.CACHE / 'candidates.jsonl'
DRAW = C.CACHE / 'sample' / 'draw.jsonl'
DROPS = C.CACHE / 'sample' / 'drops.jsonl'
TRUTH = C.CACHE / 'sample' / 'truth'
VISION = C.CACHE / 'sample' / 'vision'
OCR_BIN = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/segbench/bin/segbench-ocr'
# The Vision helper runs the app's settings (en-US, language correction on), so it is a fair sanity reader for
# Latin script only. Other scripts are checked by hand on a few pages instead.
VISION_SCRIPTS = {'Latn'}
FLAG_BELOW = 0.5   # a page under half its stratum's median Vision NES is opened and compared by hand


def modules():
    out = {}
    for name in SOURCES:
        try:
            out[name] = importlib.import_module(f'src_{name}')
        except ModuleNotFoundError:
            pass   # a source with no converter (blocked or dropped) contributes nothing
    return out


def safe(key: str) -> str:
    return key.replace(':', '__').replace('/', '_')


def cmd_list():
    rows = []
    for name, mod in modules().items():
        cs = mod.candidates()
        rows += [c.row() for c in cs]
        print(f'{name}: {len(cs)} candidates', file=sys.stderr)
    keys = [r['source'] + ':' + r['page_id'] for r in rows]
    dup = [k for k, n in collections.Counter(keys).items() if n > 1]
    if dup:
        raise SystemExit(f'duplicate keys: {dup[:5]}')
    C.write_jsonl(CANDIDATES, rows)
    by = collections.defaultdict(collections.Counter)
    for r in rows:
        by[r['stratum']][r['source']] += 1
    for s in sorted(TARGET):
        print(f'{s} target {TARGET[s]:3d}  have {sum(by[s].values()):5d}  {dict(by[s])}')


def order(cands: list[dict], stratum: str) -> list[dict]:
    pool = sorted(cands, key=lambda r: (r['source'], r['page_id']))
    random.Random(f'{SEED}:{stratum}').shuffle(pool)
    return pool


def choose(pool: list[dict], target: int, dropped: set[str]) -> list[dict]:
    """Take the shuffled pool in order under the quarter cap, then fill any shortfall marked over_cap."""
    cap = max(1, target // 4)
    per, chosen, rest = collections.Counter(), [], []
    for r in pool:
        k = r['source'] + ':' + r['page_id']
        if k in dropped:
            continue
        coll = r['source'] + '/' + r['collection']
        if len(chosen) < target and per[coll] < cap:
            per[coll] += 1
            chosen.append({**r, 'over_cap': False})
        else:
            rest.append(r)
    for r in rest:
        if len(chosen) >= target:
            break
        chosen.append({**r, 'over_cap': True})
    return chosen


def drops() -> dict[str, str]:
    return {d['key']: d['reason'] for d in C.read_jsonl(DROPS)} if DROPS.exists() else {}


def cmd_draw():
    mods, rows = modules(), C.read_jsonl(CANDIDATES)
    dropped = drops()
    by = collections.defaultdict(list)
    for r in rows:
        by[r['stratum']].append(r)
    out = []
    for s in sorted(TARGET):
        while True:
            chosen = choose(order(by[s], s), TARGET[s], set(dropped))
            failed = False
            for r in chosen:
                k = r['source'] + ':' + r['page_id']
                truth_path = TRUTH / (safe(k) + '.txt')
                try:
                    img, text = mods[r['source']].materialise(C.Candidate(**{f: r[f] for f in C.Candidate.__dataclass_fields__}))
                except Exception as e:   # a page that cannot be fetched is dropped with the error, then replaced
                    dropped[k] = f'materialise failed: {type(e).__name__}: {e}'[:300]
                    _append_drop(k, dropped[k])
                    failed = True
                    break
                if not text.strip():
                    dropped[k] = 'empty truth'
                    _append_drop(k, dropped[k])
                    failed = True
                    break
                truth_path.parent.mkdir(parents=True, exist_ok=True)
                truth_path.write_text(text)
                r.update(image=str(img), truth=str(truth_path), image_sha256=C.sha256(img),
                         truth_sha256=C.sha256(truth_path), truth_chars=len(text))
            if not failed:
                break
        out += chosen
        over = sum(r['over_cap'] for r in chosen)
        print(f'{s}: {len(chosen)}/{TARGET[s]}' + (f' ({over} over the quarter cap)' if over else ''))
    C.write_jsonl(DRAW, out)


def _append_drop(key: str, reason: str):
    DROPS.parent.mkdir(parents=True, exist_ok=True)
    with DROPS.open('a') as f:
        f.write(json.dumps({'key': key, 'reason': reason}, ensure_ascii=False) + '\n')


def cmd_drop(key: str, reason: str):
    if key not in {r['source'] + ':' + r['page_id'] for r in C.read_jsonl(DRAW)}:
        raise SystemExit(f'{key} is not in the draw')
    _append_drop(key, reason)
    print(f'dropped {key}; run `sample.py draw` to replace it')


def cmd_sanity():
    rows = [r for r in C.read_jsonl(DRAW) if r['script'] in VISION_SCRIPTS]
    jobs = C.CACHE / 'sample' / 'vision-jobs.tsv'
    jobs.write_text(''.join(f"{r['image']}\t{VISION / (safe(r['source'] + ':' + r['page_id']) + '.txt')}\n"
                            for r in rows))
    subprocess.run([str(OCR_BIN), str(jobs)], check=False)
    # Scored with the panel's scorer, which needs regex/rapidfuzz/sacrebleu (run this under uv, as the
    # reports are: uv run --with regex --with rapidfuzz --with 'sacrebleu==2.5.1' python sample.py sanity).
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    import ocr_panel_score as S
    by = collections.defaultdict(list)
    for r in rows:
        k = r['source'] + ':' + r['page_id']
        v = VISION / (safe(k) + '.txt')
        hyp = v.read_text() if v.exists() else ''
        by[r['stratum']].append((S.score(Path(r['truth']).read_text(), hyp, r['stratum'])['nes'], k))
    flagged = []
    for s, xs in sorted(by.items()):
        med = statistics.median(x for x, _ in xs)
        low = sorted((x, k) for x, k in xs if x < FLAG_BELOW * med)
        print(f'{s}: {len(xs)} pages, Vision NES median {med:.3f}, {len(low)} flagged')
        flagged += [{'stratum': s, 'key': k, 'nes': round(x, 3), 'median': round(med, 3)} for x, k in low]
    C.write_jsonl(C.CACHE / 'sample' / 'flagged.jsonl', flagged)
    for f in flagged:
        print(f"  {f['key']}  {f['nes']} (median {f['median']})")


MANIFEST_FIELDS = ['stratum', 'source', 'collection', 'page_id', 'item_url', 'licence', 'convention',
                   'contamination', 'publish_image', 'script', 'era', 'kind', 'over_cap',
                   'image_sha256', 'truth_sha256', 'truth_chars']


def cmd_freeze():
    rows = C.read_jsonl(DRAW)
    RESULTS.mkdir(parents=True, exist_ok=True)
    # The owner's 2026-10-16 decision: scores only, no third-party page images on the published bench,
    # whatever the licence. `licence_permits_images` keeps what the licence alone would allow.
    C.write_jsonl(RESULTS / 'manifest.jsonl',
                  [{**{f: r[f] for f in MANIFEST_FIELDS if f != 'publish_image'},
                    'licence_permits_images': r['publish_image'], 'publish_image': False} for r in rows])
    C.write_jsonl(RESULTS / 'drops.jsonl', [{'key': k, 'reason': v} for k, v in sorted(drops().items())])
    print(f'{len(rows)} pages frozen in {RESULTS / "manifest.jsonl"}')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['list', 'draw', 'sanity', 'drop', 'freeze'])
    ap.add_argument('args', nargs='*')
    a = ap.parse_args()
    if a.command == 'drop':
        if len(a.args) != 2:
            raise SystemExit('usage: sample.py drop KEY REASON')
        cmd_drop(*a.args)
    else:
        {'list': cmd_list, 'draw': cmd_draw, 'sanity': cmd_sanity, 'freeze': cmd_freeze}[a.command]()


if __name__ == '__main__':
    main()
