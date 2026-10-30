#!/usr/bin/env python3
"""W43.script-specialists — models built for the scripts and hands the reference routes read worst.

  heavy-run.py run -- python3 specialists.py segment [--strata L7,N4]   # kraken blla lines, once per page
  heavy-run.py run -- python3 specialists.py collect [--model KEY]      # each kraken model on its strata's lines
  uv run --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex python specialists.py report

The kraken lane runs on this Mac (CPU; the models are 16-25 MB, CC-BY or MIT, from Zenodo through `kraken get`),
on the same frozen pages, checked against their checksums, that routes.py read. The input is the kept original,
not the panel's 2400 px JPEG: a line recogniser wants the scan's own resolution, and blla segments it. Scores use
routes.py's scorer and its per-stratum options, so a specialist's row sits beside the reference routes'. The page
models that need a GPU (CHURRO-3B, Qari-OCR, the Bern Qwen and TrOCR line models) are FarmShare work, listed in
`segbench-results/bench-corpus/specialists.md`. No money. Raw text stays in CACHE; the repo gets aggregates only.

Contamination is part of each model's row: a model trained on a test source is scored but labelled, never put
forward as the stratum's specialist.
"""
from __future__ import annotations

import argparse
import collections
import concurrent.futures
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import common as C          # noqa: E402
import model_store          # noqa: E402
import routes as R          # noqa: E402

RUN = C.CACHE / 'specialists'
KRAKEN = Path(os.environ.get('KRAKEN_BIN', Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/kraken-venv/bin/kraken'))
MODELS_DIR = Path.home() / 'Library/Application Support/htrmopo'
RTL = {'Arab', 'Hebr'}
model_store.use()
BATCH = 10   # pages per kraken call: one model load per batch, and an interruption loses at most a batch
WORKERS = int(os.environ.get('SPECIALISTS_WORKERS', '4'))

# DOI -> the file `kraken get` puts under MODELS_DIR/<uuid>/. `contaminated` names the test sources a model's
# own record lists among its training data (2026-10-17, from the Zenodo records and their linked lists): TRIDIS
# v2 names the Königsfelden Abbey corpus. The Mannheim German models list READ's Konzilsprotokolle and Bozen,
# but every READ 2017 page here is an Alfred Escher letter (src_read2017.py), and the Kurrent set (2025) postdates
# them. McCATMuS, the Greek minuscule model and TrOCR Kurrent ("many other smaller collections") give no list
# that could be checked (`unknown`); '' = none of ours in a full list.
# BiblIA's model is trained on BiblIA itself and is scored only as a labelled upper bound.
MODELS = {
    'catmus-medieval': {'doi': '10.5281/zenodo.12743230', 'file': 'catmus-medieval.mlmodel',
                        'strata': ['L5', 'L7'], 'licence': 'CC-BY-4.0', 'contaminated': ''},
    'tridis': {'doi': '10.5281/zenodo.10788591', 'file': 'Tridis_Medieval_EarlyModern.mlmodel',
               'strata': ['L5', 'L7'], 'licence': 'MIT', 'contaminated': 'koenigsfelden'},
    'mccatmus': {'doi': '10.5281/zenodo.13788177', 'file': 'McCATMuS_nfd_nofix_V1.mlmodel',
                 'strata': ['L5', 'L6'], 'licence': 'CC-BY-4.0', 'contaminated': 'unknown'},
    'german-handwriting': {'doi': '10.5281/zenodo.7933463', 'file': 'german_handwriting.mlmodel',
                           'strata': ['L6'], 'licence': 'CC-BY-SA-4.0', 'contaminated': ''},
    'kurrent-v3': {'doi': '10.5281/zenodo.21747522', 'file': 'german_handwriting_kurrent_v3.mlmodel',
                   'strata': ['L6'], 'licence': 'CC-BY-4.0', 'contaminated': ''},
    # A line model on the same kraken lines, read by trocr_lines.py (transformers, MPS); 0.3B.
    'trocr-kurrent': {'hf': 'dh-unibe/trocr-kurrent', 'strata': ['L6'], 'licence': 'MIT', 'contaminated': 'unknown'},
    'greek-minuscule': {'doi': '10.5281/zenodo.15838142', 'file': 'greek_minuscule_s9-12_NFC.mlmodel',
                        'strata': ['N3'], 'licence': 'CC-BY-SA-4.0', 'contaminated': 'unknown'},
    'biblia': {'doi': '10.5281/zenodo.5468286', 'file': 'BiblIA_01.mlmodel',
               'strata': ['N4'], 'licence': 'CC-BY-SA-4.0', 'contaminated': 'biblia', 'visual_rtl': True},
    'fs-churro': {'runner': 'farmshare', 'strata': ['L5', 'L6', 'L7', 'L8', 'N1', 'N3', 'N4'],
                  'licence': 'Qwen research', 'contaminated': '',
                  'contaminated_by_stratum': {'L5': 'iforal,castilian,voc', 'L7': 'koenigsfelden', 'L8': 'ocrd'}},
    'fs-qari': {'runner': 'farmshare', 'strata': ['N1'], 'licence': 'Apache-2.0', 'contaminated': ''},
    'fs-german-xix': {'runner': 'farmshare', 'strata': ['L6'], 'licence': 'not stated; scoring only',
                      'contaminated': 'unknown; possible Hufeland overlap'},
    'fs-fanar': {'runner': 'farmshare', 'strata': ['N1'], 'licence': 'Apache-2.0', 'contaminated': 'unknown'},
}


def model_path(key):
    if 'hf' in MODELS[key]:
        return MODELS[key]['hf']    # trocr_lines.py loads it by id, from HF_HOME's cache once fetched
    name = MODELS[key]['file']
    found = sorted(MODELS_DIR.glob('*/' + name))
    if not found:
        raise SystemExit(f'{key}: {name} not under {MODELS_DIR}; run: {KRAKEN} get {MODELS[key]["doi"]}')
    return found[0]


def pages(strata):
    return [r for r in R.frozen() if r['stratum'] in strata]


def seg_path(r):
    return RUN / 'seg' / (R.job_id(r) + '.xml')


def text_path(key, r):
    return RUN / 'text' / key / (R.job_id(r) + '.txt')


def batches(xs):
    return [xs[i:i + BATCH] for i in range(0, len(xs), BATCH)]


def kraken(opts, pairs, *cmd):
    args = [str(KRAKEN), *opts]
    for a, b in pairs:
        args += ['-i', str(a), str(b)]
    subprocess.run(args + list(cmd), check=True)


def segment(strata):
    todo = [r for r in pages(strata) if not seg_path(r).exists()]
    (RUN / 'seg').mkdir(parents=True, exist_ok=True)
    jobs = [(b, 'horizontal-rl' if script in RTL else 'horizontal-lr')
            for script in sorted({r['script'] for r in todo})
            for b in batches([r for r in todo if r['script'] == script])]
    # blla on a full-resolution scan is mostly one core (about 30 s a page here); one kraken per worker.
    # `-x` (PAGE XML) is a top-level option, before the inputs.
    with concurrent.futures.ThreadPoolExecutor(WORKERS) as ex:
        for f in [ex.submit(kraken, ['-x'], [(r['image'], seg_path(r)) for r in b], 'segment', '-bl',
                            '--text-direction', d) for b, d in jobs]:
            f.result()
    print(f'{len(todo)} pages segmented')


def collect(keys):
    for k in keys:
        if MODELS[k].get('runner') == 'farmshare':
            print(f'{k}: import completed cluster outputs with farmshare_results.py; no local model call')
            continue
        m = model_path(k)
        rows = pages(MODELS[k]['strata'])
        missing = [r for r in rows if not seg_path(r).exists()]
        if missing:
            raise SystemExit(f'{k}: {len(missing)} pages not segmented (run segment)')
        todo = [r for r in rows if not text_path(k, r).exists()]
        text_path(k, rows[0]).parent.mkdir(parents=True, exist_ok=True)
        if 'hf' in MODELS[k]:
            jobs = RUN / f'{k}-jobs.tsv'
            jobs.write_text(''.join(f'{seg_path(r)}\t{text_path(k, r)}\n' for r in todo))
            subprocess.run([str(KRAKEN.with_name('python')), str(HERE / 'trocr_lines.py'), m, str(jobs)], check=True)
        else:
            for b in batches(todo):
                kraken(['-f', 'page'], [(seg_path(r), text_path(k, r)) for r in b], 'ocr', '-m', str(m))
        print(f'{k}: {len(todo)} pages read')


def report():
    import ocr_panel_score as S
    general = collections.defaultdict(dict)
    for g in _read_csv(R.RESULTS / 'routes-pages.csv'):
        general[g['route']][g['page']] = float(g['nes']) if g['ok'] == 'True' and g['nes'] else 0.0
    out = []
    for k, spec in MODELS.items():
        for r in pages(spec['strata']):
            f = text_path(k, r)
            if not f.exists():
                continue
            text = f.read_text()
            if spec.get('visual_rtl'):
                text = logical(text)
            s = S.score(Path(r['truth']).read_text(), text, r['stratum'])
            out.append({'route': k, 'page': R.job_id(r), 'stratum': r['stratum'], 'source': r['source'],
                        'script': r['script'], 'ok': bool(f.read_text().strip()), **s})
    rows, by = [], collections.defaultdict(list)
    for r in out:
        by[(r['route'], r['stratum'])].append(r)
    for (k, s), rr in sorted(by.items()):
        a = S.aggregate(rr)
        for e in ('nes_mapped', 'nes_no_marks'):
            xs = [r[e] for r in rr if e in r]
            a[e] = sum(xs) / len(xs) if xs and len(xs) == len(rr) else None
        contamination = MODELS[k].get('contaminated_by_stratum', {}).get(s, MODELS[k]['contaminated'])
        row = {'route': k, 'stratum': s, 'contaminated': contamination, **a}
        # Paired against each general route on the same pages: specialist minus general, NES points.
        for g, short in (('gemini3.8-flash', 'gemini'), ('qwen3-vl-235b', 'qwen')):
            p = S.paired([r['nes'] for r in rr], [general[g].get(r['page'], 0.0) for r in rr], rounds=2000)
            row[f'vs_{short}'], row[f'vs_{short}_lo'], row[f'vs_{short}_hi'] = p['delta'], p['lo'], p['hi']
        rows.append(row)
    S.write_csv(R.RESULTS / 'specialists.csv', rows,
                ['route', 'stratum', 'contaminated', 'n', 'ok', 'failed', 'nes', 'nes_answered', 'nes_mapped',
                 'nes_no_marks', 'chrf', 'vs_gemini', 'vs_gemini_lo', 'vs_gemini_hi', 'vs_qwen', 'vs_qwen_lo',
                 'vs_qwen_hi'])
    S.write_csv(R.RESULTS / 'specialists-pages.csv', out,
                ['route', 'page', 'stratum', 'script', 'ok', 'nes', 'nes_mapped', 'nes_no_marks', 'chrf', 'words',
                 'hyp_words'])
    for r in rows:
        print(f"{r['route']:20s} {r['stratum']} n={r['n']:3d} NES {100 * r['nes']:.1f} "
              f"vs Gemini {_pts(r['vs_gemini'])} vs Qwen {_pts(r['vs_qwen'])} {r['contaminated']}")


def logical(text):
    """A line written in visual order (BiblIA's 2021 model: kraken's --reorder and --base-dir change nothing on a
    PAGE input) to logical order, reversed by grapheme cluster so a vowel point stays on its letter. Pure Hebrew
    lines only, which is all N4's main text is; a digit run would come out reversed."""
    import regex
    return '\n'.join(''.join(reversed(regex.findall(r'\X', line))) for line in text.split('\n'))


def _pts(x):
    return '   –' if x is None else f'{100 * x:+.1f}'


def _read_csv(path):
    import csv
    with open(path, newline='') as f:
        return list(csv.DictReader(f))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['segment', 'collect', 'report'])
    ap.add_argument('--strata', help='comma-separated; default: every stratum a model reads')
    ap.add_argument('--model', choices=list(MODELS))
    a = ap.parse_args()
    if a.command == 'segment':
        return segment(a.strata.split(',') if a.strata else sorted({s for m in MODELS.values() for s in m['strata']}))
    if a.command == 'collect':
        return collect([a.model] if a.model else list(MODELS))
    report()


if __name__ == '__main__':
    main()
