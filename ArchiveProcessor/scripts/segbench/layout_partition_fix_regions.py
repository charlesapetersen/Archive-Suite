#!/usr/bin/env python3
"""W46.p16-score-hygiene: where the fixed newspaper partition loses a page, from per-region scores, not the texts.

  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy \
      python ArchiveProcessor/scripts/segbench/layout_partition_fix_regions.py \
      newsbench__mss3413201309-4 newsbench__mss3413201323-27

Each partition region read is paired with its best-matching raw region read (normalized Levenshtein similarity, not
one-to-one; the plan images that held the exact mapping went to the Trash when W46.layout-partition-fix shipped) and
swapped in alone, and the page's strict NES is rescored. Also: every region swapped at once, and the partition
without its outside crops. Saved reads only: no model, network or money. Prints; layout-partition-fix.md quotes it.
"""
from __future__ import annotations

import glob
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import layout_partition_score as P   # noqa: E402
from rapidfuzz.distance import Levenshtein   # noqa: E402

R, D = P.R, P.D
READS = P.L.WORK / 'reads'


def load(arm: str, pid: str) -> list[dict]:
    return [json.load(open(f)) for f in sorted(glob.glob(f'{READS}/{arm}/{pid}/*.json'))]


def nes(ref: str, recs: list[dict]) -> float:
    return 100 * P.page_scores(ref, P.stitch(recs))['nes']


def main() -> None:
    R.MANIFEST = D.MANIFEST
    truth = {R.job_id(r): r for r in R.frozen()}
    for pid in sys.argv[1:]:
        ref = Path(truth[pid]['truth']).read_text()
        part, raw = load('partition', pid), load('raw', pid)
        regs = [r for r in part if r['source'].startswith('region-')]
        outs = [r for r in part if r['source'].startswith('outside')]
        base = nes(ref, part)
        print(f'{pid}: partition {base:.1f}, raw {nes(ref, raw):.1f}; {len(regs)} region reads against {len(raw)} raw,'
              f' {len(outs)} outside crops')
        match, rows = {}, []
        for r in regs:
            sims = [Levenshtein.normalized_similarity(r['text'], x['text']) for x in raw]
            j = max(range(len(raw)), key=sims.__getitem__)
            match[id(r)] = raw[j]
            gain = nes(ref, [raw[j] if x is r else x for x in part]) - base
            rows.append((gain, r['source'], j, sims[j], len(r['text'].split()), len(raw[j]['text'].split()),
                         r['cut'], r['size']))
        rows.sort(key=lambda x: -x[0])
        print(f'  reads with similarity under 0.8: {sum(1 for x in rows if x[3] < 0.8)} of {len(rows)}')
        for g, src, j, sim, w, wr, cut, size in rows[:5]:
            print(f'  swap {src} for raw {j}: {g:+.2f} (similarity {sim:.2f}, {w} words against {wr}, cap {cut},'
                  f' {size[0]} x {size[1]} px)')
        print(f'  every region swapped: {nes(ref, [match.get(id(x), x) for x in part]) - base:+.1f};'
              f' outside crops dropped: {nes(ref, [x for x in part if x not in outs]) - base:+.1f}')


if __name__ == '__main__':
    main()
