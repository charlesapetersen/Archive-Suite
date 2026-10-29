#!/usr/local/bin/python3
"""W46.enh-ocr-input. Content-removing enhancement as OCR input, on the owner's truth pages.

  V=~/Library/Caches/ArchiveSuiteRehearsal/enh-dewarp/venv/bin/python
  $V enh_ocr_input.py mac-arms   # shading, GCDRNet and SBB on the Mac (their own venvs)
  $V enh_ocr_input.py stage      # the cluster pack: the Mac's arms, regions, code, weights
  $V enh_ocr_input.py fetch      # link the cluster's enhanced images from the collected Sherlock tree (COLLECTED)
  $V enh_ocr_input.py vision     # Apple Vision on every arm's image (segbench-dewarp lines)
  $V enh_ocr_input.py report     # segbench-results/enh-ocr-input.md, -pages.csv, .json

Arms (enh_ocr_arms.py says how each is made) all start from the panel's frozen raw image, the 2400 px JPEG 90 every
saved route read, and keep its size, so a word box, a PP-DocLayoutV3 region or a mark box found on raw applies to
every arm as it is. raw, shading, gcdrnet and sbb are made here; docres-appearance and docres-deshadow on a
Sherlock GPU (`corpus/enh_ocr_cluster.py enhance`; the pack was staged for FarmShare first), because DocRes at
1,600 square does not fit this Mac. Each output is saved as JPEG 90, as raw was.

Readers: Apple Vision here with the app's settings; on Sherlock, in one run after the enhancement job,
PP-OCRv6 (truth96's pinned pipeline), Qwen3-VL 8B (whole page, the panel prompt) and GLM-OCR on PP-DocLayoutV3's
regions of the raw image (the regions run's detector output, crops of each arm's image at the same boxes), each
reading raw again so every comparison is inside one run. The two-seed hallucination probe: ResShift (PreP-OCR) and
NAF-DPM, each twice with a different seed, on the 30 pages with the lowest median NES over the saved routes,
read by Qwen3.6-27B and by Vision.
Gemini 3.7 Flash through the Stanford gateway reads every arm on the 96 (`enh_ocr_input_gateway.py`,
W46.enh-ocr-input-paid); its section appears once every image is read.

Measures, per reader and arm against raw, on the 96 (the panel's 99 less its three agreement pages), originals and
PDF images apart and by capture-defect tag (capture-tags.json, W46.fix-capture-tags):
  NES, chrF2 and the panel scorer's bag-of-words added and missed rates (ocr_panel_score.score);
  the strand's invented-text measures (D-enhancement.md §6.4), from a word alignment to the truth: aligned added
    words (insertions) and rewritten words (substitutions more than one edit from their truth word), per truth word;
    restoration-only words, in the enhanced reading but in neither the truth nor the same reader's raw reading, per
    1,000 words read;
  the reference-free suspect rate: words in the enhanced reading found in neither the same reader's raw reading nor
    Vision's raw reading, per 1,000 words read; its threshold is set on these pages (in-sample, said so), as the
    gate an app would apply with no truth;
  for the probe, the reseeding instability: words that differ between the two seeds' readings, per 1,000 words.

Page images and raw text stay in CACHE; committed results hold page ids and numbers only. No network, no money.
"""
from __future__ import annotations
import argparse
import collections
import csv
import difflib
import json
import os
import statistics
import subprocess
import sys
from pathlib import Path

import ocr_panel as P

CACHE = Path(os.environ.get('ENH_OCR_CACHE', Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/enh-ocr-input'))
SRC = CACHE / 'src'
DOCRES_SRC = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/enh-dewarp/src'  # DocRes d3e3a18c + docres.pkl
BIN = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/segbench/bin/segbench-dewarp'
REGIONS = Path.home() / 'Claude/Long term storage/FarmShare-regions-20261021/pp-doclayoutv3.json'
RESULTS = P.RESULTS
REPORT, PAGES, BENCH = RESULTS / 'enh-ocr-input.md', RESULTS / 'enh-ocr-input-pages.csv', RESULTS / 'enh-ocr-input.json'
MAC_ARMS = ('shading', 'gcdrnet', 'sbb')
CLUSTER_ARMS = ('docres-appearance', 'docres-deshadow')
ARMS = ('raw', *MAC_ARMS, *CLUSTER_ARMS)
PROBE = ('resshift', 'nafdpm')
SEEDS = (1, 2)
PROBE_ARMS = tuple(f'{m}-s{s}' for m in PROBE for s in SEEDS)
PROBE_N = 30
FS_ROOT = '/scratch/users/cp1/fs-ocr/enh-ocr-input-20261022'  # the pack's root, on FarmShare and then Sherlock
# Sherlock's run of the pack, collected by an owner session through the DTN (2026-10-24; no engine session contacts
# Sherlock): out/<reader>/<arm>/<page>.json, glm/out/glm-ocr/pp-doclayoutv3/<arm>/<page>/NNN.json,
# probe/out/qwen3.6-27b/<arm>/<page>.json and images/<arm>/<page>.jpg.
COLLECTED = Path(os.environ.get('ENH_OCR_COLLECTED', Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/'
                                'sherlock-results/enh-ocr-input-20261022'))
FETCHED = COLLECTED / 'out'
# reader -> (farmshare_expanded_report mode, what it reads)
READERS = {'ppocrv6': 'pipeline', 'qwen3-vl-8b': 'panel', 'glm-ocr': 'native'}
PROBE_READER = 'qwen3.6-27b'
# The arms each cluster reader was given. PP-OCRv6's job (49137314) read a list built before DocRes's images were
# made, so it has the four Mac arms only; its DocRes rows are reported as not run, not as pending.
READER_ARMS = {'ppocrv6': ('raw', *MAC_ARMS)}
TAGS = {'shadow or low light': ('shadow', 'low_light'), 'faint ink': ('faint_ink',), 'show-through': ('show_through',),
        'colour': ('colour',), 'blur': ('defocus', 'motion_blur'), 'glare': ('glare',)}


# ---------- invented-text measures (pure; test_enh_ocr_input.py) ----------

def words(text):
    import ocr_panel_score as S
    return S.tokens(S.normal(re_illegible(text)))


def re_illegible(text):
    import re
    return re.sub(r'\[illegible\]', '', text, flags=re.I)


def aligned(truth, hyp):
    """Insertions and far substitutions of hyp's words against truth's, by difflib's alignment of the word
    sequences. A replace block pairs words in order; its surplus on the hyp side counts as inserted. A pair is
    rewritten when the two words are more than one edit apart (a near miss is an OCR error, not new text)."""
    from rapidfuzz.distance import Levenshtein
    t, h = words(truth), words(hyp)
    ins = rew = 0
    for op, i0, i1, j0, j1 in difflib.SequenceMatcher(None, t, h, autojunk=False).get_opcodes():
        if op == 'insert':
            ins += j1 - j0
        elif op == 'replace':
            k = min(i1 - i0, j1 - j0)
            rew += sum(Levenshtein.distance(t[i0 + m], h[j0 + m]) > 1 for m in range(k))
            ins += max(0, (j1 - j0) - (i1 - i0))
    return {'words': len(t), 'read': len(h), 'inserted': ins, 'rewritten': rew}


def novel(hyp, *refs):
    """Words of hyp (with repeats) whose form appears in none of refs."""
    seen = set()
    for r in refs:
        seen.update(words(r))
    return [w for w in words(hyp) if w not in seen]


def unstable(a, b):
    """Words that differ between two readings of the same page, as a multiset: (|A - B| + |B - A|) and the words
    read (|A| + |B|)."""
    A, B = collections.Counter(words(a)), collections.Counter(words(b))
    return sum((A - B).values()) + sum((B - A).values()), sum(A.values()) + sum(B.values())


def per_k(n, d):
    return 1000 * n / d if d else 0.


def gate(rows, thresholds):
    """The reference-free gate on one reader and arm: keep the enhanced reading unless its suspect rate is above t,
    else fall back to raw. rows: [{'nes', 'raw_nes', 'suspect_k'}]. Returns [(t, mean NES, pages kept)]."""
    out = []
    for t in thresholds:
        kept = [r['suspect_k'] <= t for r in rows]
        nes = [r['nes'] if k else r['raw_nes'] for r, k in zip(rows, kept)]
        out.append((t, statistics.mean(nes) if nes else 0., sum(kept)))
    return out


# ---------- pages and images ----------

def pages():
    return [r['page'] for r in P.rows() if r['page'] not in P.AGREEMENT]


def raw_image(page):
    return P.CACHE / 'images' / (page + '-original.jpg')


def arm_image(arm, page):
    return raw_image(page) if arm == 'raw' else CACHE / 'images' / arm / (page + '.jpg')


def save_jpeg(arr, dest):
    from PIL import Image
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix('.tmp')
    Image.fromarray(arr).save(tmp, 'JPEG', quality=90)
    tmp.replace(dest)


SBB = '''
import os, sys, importlib.util
from pathlib import Path
import numpy as np
from PIL import Image
os.environ['TF_CPP_MIN_LOG_LEVEL'] = '2'
base, raw, out, *ids = sys.argv[1:]
spec = importlib.util.spec_from_file_location('sbb', base + '/src/sbb_binarization/sbb_binarize/sbb_binarize.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
b = m.SbbBinarizer(base + '/weights/sbb/saved_model')
for p in ids:
    dest = Path(out) / 'sbb' / (p + '.jpg')
    if dest.exists():
        continue
    tmp = dest.with_suffix('.png'); dest.parent.mkdir(parents=True, exist_ok=True)
    b.run(image_path=str(Path(raw) / (p + '.jpg')), save=str(tmp))
    with Image.open(tmp) as im:
        Image.fromarray(np.asarray(im.convert('RGB'))).save(dest.with_suffix('.tmp'), 'JPEG', quality=90)
    dest.with_suffix('.tmp').replace(dest); tmp.unlink()
    print('sbb', p, flush=True)
'''


def mac_arms():
    """shading here; GCDRNet in the enh-ocr-input venv (timm); SBB's 2022-08-16 model in venv-tf (TensorFlow 2.15,
    the oldest with an arm64 wheel; its README asks for below 2.13), through sbb_binarize.SbbBinarizer.run, the
    0/255 result saved as three equal channels."""
    import numpy as np
    from PIL import Image
    import enh_ocr_arms as A
    for p in pages():
        d = arm_image('shading', p)
        if not d.exists():
            with Image.open(raw_image(p)) as im:
                save_jpeg(A.shading(np.asarray(im.convert('RGB'))), d)
    here = Path(__file__).resolve().parent
    raw = str(P.CACHE / 'images')
    link = CACHE / 'raw-links'  # <page>.jpg -> the panel's <page>-original.jpg, the name the runners expect
    link.mkdir(exist_ok=True)
    for p in pages():
        if not (link / (p + '.jpg')).exists():
            (link / (p + '.jpg')).symlink_to(raw_image(p))
    subprocess.run([str(CACHE / 'venv/bin/python'), str(here / 'enh_ocr_arms.py'), 'gcdrnet', str(CACHE), str(link),
                    str(CACHE / 'images'), *pages()], check=True)
    subprocess.run([str(CACHE / 'venv-tf/bin/python'), '-c', SBB, str(CACHE), str(link), str(CACHE / 'images'),
                    *pages()], check=True)
    print('shading, gcdrnet, sbb ->', CACHE / 'images')


def probe_pages():
    """The PROBE_N pages with the lowest median NES over the saved routes (ocr-pages.csv), ties by page id."""
    by = collections.defaultdict(list)
    with (RESULTS / 'ocr-pages.csv').open() as f:
        for r in csv.DictReader(f):
            if r['page'] not in P.AGREEMENT and r['nes']:
                by[r['page']].append(float(r['nes']))
    return sorted(by, key=lambda p: (statistics.median(by[p]), p))[:PROBE_N]


# ---------- the cluster ----------

def stage():
    """CACHE/stage: images/raw and images/shading, pages.json (the 96 and the probe's 30), regions, the DocRes
    code and weights, and the other methods' clones under src/ (copied by the submit script's rsync)."""
    import shutil
    out = CACHE / 'stage'
    for arm in ('raw', *MAC_ARMS):
        for p in pages():
            dst = out / 'images' / arm / (p + '.jpg')
            dst.parent.mkdir(parents=True, exist_ok=True)
            if not dst.exists():
                shutil.copyfile(arm_image(arm, p), dst)
    regions = json.loads(REGIONS.read_text())
    keep = {'detector': regions['detector'], 'pages': {p: regions['pages'][p] for p in pages()}}
    (out / 'regions').mkdir(exist_ok=True)
    (out / 'regions' / 'pp-doclayoutv3.json').write_text(json.dumps(keep) + '\n')
    (out / 'pages.json').write_text(json.dumps({'pages': pages(), 'probe': probe_pages()}, indent=1) + '\n')
    here = Path(__file__).resolve().parent
    for f in ('enh_ocr_arms.py', 'corpus/enh_ocr_cluster.py', 'corpus/enh-ocr-job.sh', 'corpus/enh-ocr-submit.sh',
              'corpus/regions_cluster.py', 'corpus/dewarp_cluster.py'):
        shutil.copyfile(here / f, out / Path(f).name)
    d = out / 'src' / 'DocRes'
    if not d.exists():
        shutil.copytree(DOCRES_SRC / 'DocRes', d, ignore=shutil.ignore_patterns('.git', 'data', 'restorted', 'input'))
    for name in ('ResShift', 'NAF-DPM'):  # GCDRNet and SBB run on the Mac
        if not (out / 'src' / name).exists():
            shutil.copytree(SRC / name, out / 'src' / name, ignore=shutil.ignore_patterns('.git', 'testdata', 'figs'))
    d = out / 'src' / 'PreP-OCR' / 'configs'  # PreP-OCR's config only; the rest of its clone is synthetic-data tooling
    if not d.exists():
        shutil.copytree(SRC / 'PreP-OCR' / 'configs', d)
    for name in ('prep-ocr', 'naf'):
        if not (out / 'weights' / name).exists():
            shutil.copytree(CACHE / 'weights' / name, out / 'weights' / name)
    print(out)


def fetch():
    """Link the cluster's arms (DocRes and the probe's restorers) from COLLECTED/images into CACHE/images, checking
    each keeps the raw image's size. The Mac's own arms are already there (the collected copies are the staged ones)."""
    from PIL import Image
    n = 0
    for arm, ids in [(a, pages()) for a in CLUSTER_ARMS] + [(a, probe_pages()) for a in PROBE_ARMS]:
        for p in ids:
            src, dst = COLLECTED / 'images' / arm / (p + '.jpg'), arm_image(arm, p)
            if dst.exists():
                continue
            with Image.open(src) as a, Image.open(raw_image(p)) as b:
                if a.size != b.size:
                    raise SystemExit(f'{arm} {p}: {a.size} is not the raw size {b.size}')
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.symlink_to(src)
            n += 1
    print(n, 'images linked from', COLLECTED / 'images')


def cluster_readings():
    """({reader: {(arm, page): text or None}}, {reader: {(arm, page): (prompt, completion tokens)}}); None = no
    record. A failed or capped reading is ''."""
    sys.path.insert(0, str(Path(__file__).resolve().parent / 'corpus'))
    import farmshare_expanded_report as X
    import regions as RG

    def toks(recs):
        return (sum((r.get('usage') or {}).get('prompt_tokens') or 0 for r in recs),
                sum((r.get('usage') or {}).get('completion_tokens') or 0 for r in recs))

    glm_regions = {'pp-doclayoutv3': json.loads((COLLECTED / 'glm' / 'regions' / 'pp-doclayoutv3.json').read_text())['pages']}
    out, tokens = {}, {}
    for route, mode in READERS.items():
        if not (FETCHED / route).exists() and not (COLLECTED / 'glm' / 'out' / route).exists():
            continue
        by, tk = {}, {}
        for arm in READER_ARMS.get(route, ARMS):
            for p in pages():
                if route == 'glm-ocr':
                    # every kept region's crop must be there (validate_crops refuses a gap); a page where the
                    # detector kept none (p047) reads as empty and scores 0, the regions run's convention
                    recs = RG.crop_records(COLLECTED / 'glm', route, f'pp-doclayoutv3/{arm}', p)
                    n = RG.validate_crops(route, 'pp-doclayoutv3', f'{arm}/{p}', recs, glm_regions)
                    by[arm, p] = RG.page_reading('pp-doclayoutv3', recs, n, mode, X.reading)['text']
                    tk[arm, p] = toks(recs)
                else:
                    f = FETCHED / route / arm / (p + '.json')
                    rec = json.loads(f.read_text()) if f.exists() else None
                    by[arm, p] = X.reading(rec, mode) if rec else None
                    tk[arm, p] = toks([rec] if rec else [])
        out[route], tokens[route] = by, tk
    route = PROBE_READER
    if (COLLECTED / 'probe' / 'out' / route).exists():
        by = {}
        for arm in ('raw', *PROBE_ARMS):
            for p in probe_pages():
                f = COLLECTED / 'probe' / 'out' / route / arm / (p + '.json')
                by[arm, p] = X.reading(json.loads(f.read_text()), 'panel') if f.exists() else None
        out[route] = by
    return out, tokens


# ---------- Vision ----------

def vision():
    rows = [(arm_image(a, p), CACHE / 'lines' / a / (p + '.json')) for a in ARMS for p in pages()]
    rows += [(arm_image(a, p), CACHE / 'lines' / a / (p + '.json')) for a in PROBE_ARMS for p in probe_pages()]
    rows = [r for r in rows if r[0].exists() and not r[1].exists()]
    if rows:
        jobs = CACHE / 'lines-jobs.tsv'
        jobs.write_text(''.join(f'{a}\t{b}\n' for a, b in rows))
        subprocess.run([str(BIN), 'lines', str(jobs)], check=True)
    print(len(rows), 'images read')


def vision_text(arm, page):
    f = CACHE / 'lines' / arm / (page + '.json')
    return '\n'.join(l['text'] for l in json.loads(f.read_text())['lines']) if f.exists() else None


# ---------- report ----------

def measure(readings, arms, ids, vision_raw):
    """Per (arm, page) rows for one reader's readings {(arm, page): text}."""
    import ocr_panel_score as S
    rows = {}
    for p in ids:
        truth = (P.TRUTH / 'truth' / (p + '.txt')).read_text()
        raw = readings.get(('raw', p))
        for arm in arms:
            text = readings.get((arm, p))
            if text is None or raw is None:
                continue
            al = aligned(truth, text)
            r = {'page': p, 'arm': arm, **S.score(truth, text), **al,
                 'restoration_only': len(novel(text, truth, raw)) if arm != 'raw' else 0,
                 'suspect': len(novel(text, raw, vision_raw[p])) if arm != 'raw' and vision_raw.get(p) is not None else 0}
            rows[arm, p] = r
    for (arm, p), r in rows.items():
        r['raw_nes'] = rows['raw', p]['nes'] if ('raw', p) in rows else r['nes']
        r['suspect_k'] = per_k(r['suspect'], r['read'])
    return rows


def table(by, groups, arms, base='raw'):
    import ocr_panel_score as S
    L = [f'| pages | n | arm | NES % | Δ NES vs {base} (95% CI, p) | chrF2 % | inserted % | rewritten % | '
         'restoration-only /1k | suspect /1k |', '|---|---:|---|---:|---|---:|---:|---:|---:|---:|']
    for name, ps in groups.items():
        for arm in arms:
            qs = [p for p in ps if (arm, p) in by and (base, p) in by]
            if not qs:
                continue
            rr = [by[arm, p] for p in qs]
            if arm == base:
                d = '—'
            else:
                t = S.paired([r['nes'] for r in rr], [by[base, p]['nes'] for p in qs])
                d = f"{100 * t['delta']:+.1f} ({100 * t['lo']:+.1f} to {100 * t['hi']:+.1f}, p {t['p']:.3f})"
            w = sum(r['words'] for r in rr) or 1
            read = sum(r['read'] for r in rr) or 1
            L.append(f"| {name} | {len(qs)} | {arm} | {100 * statistics.mean(r['nes'] for r in rr):.1f} | {d} | "
                     f"{100 * statistics.mean(r['chrf'] for r in rr):.1f} | {100 * sum(r['inserted'] for r in rr) / w:.1f} | "
                     f"{100 * sum(r['rewritten'] for r in rr) / w:.1f} | "
                     f"{per_k(sum(r['restoration_only'] for r in rr), read):.1f} | {per_k(sum(r['suspect'] for r in rr), read):.1f} |")
    return L


def summary(by, groups, arms, reader, base='raw'):
    import ocr_panel_score as S
    out = []
    for name, ps in groups.items():
        for arm in arms:
            qs = [p for p in ps if (arm, p) in by and (base, p) in by]
            if not qs:
                continue
            rr = [by[arm, p] for p in qs]
            read = sum(r['read'] for r in rr) or 1
            row = {'reader': reader, 'pages': name, 'n': len(qs), 'arm': arm, 'base': base,
                   'nes': statistics.mean(r['nes'] for r in rr), 'chrf': statistics.mean(r['chrf'] for r in rr),
                   'inserted': sum(r['inserted'] for r in rr) / (sum(r['words'] for r in rr) or 1),
                   'rewritten': sum(r['rewritten'] for r in rr) / (sum(r['words'] for r in rr) or 1),
                   'restoration_only_k': per_k(sum(r['restoration_only'] for r in rr), read),
                   'suspect_k': per_k(sum(r['suspect'] for r in rr), read)}
            if arm != base:
                t = S.paired([r['nes'] for r in rr], [by[base, p]['nes'] for p in qs])
                row.update(d_nes=t['delta'], lo=t['lo'], hi=t['hi'], p=t['p'])
            out.append({k: round(v, 5) if isinstance(v, float) else v for k, v in row.items()})
    return out


def chart_rows(by, reader, arms, ids, tokens, price=None):
    """The full-96 and panel-kind rows for the bench page's OCR charts, one per enhanced arm (raw is each reader's
    own route there). ok = a reading with text; tokens include caps. price: ($ per million prompt, completion
    tokens) for a route billed per token here (the gateway), which adds an estimated cost."""
    kind = {r['page']: r['kind'] for r in P.rows()}
    groups = {'the 96': ids, **{f'kind:{k}': [p for p in ids if kind[p] == k] for k in sorted({kind[p] for p in ids})}}
    out = []
    for arm in arms:
        if arm == 'raw':
            continue
        for group, ps in groups.items():
            rr = [by[arm, p] for p in ps if (arm, p) in by]
            if len(rr) != len(ps):
                raise SystemExit(f'{reader} {arm}: {len(rr)} of {len(ps)} pages in {group}')
            tk = [tokens.get((arm, p), (0, 0)) for p in ps]
            out.append({'route': reader, 'arm': arm, 'group': group, 'n': len(rr), 'ok': sum(r['read'] > 0 for r in rr),
                        'nes': round(statistics.mean(r['nes'] for r in rr), 5),
                        'prompt_tokens': sum(a for a, _ in tk), 'completion_tokens': sum(b for _, b in tk),
                        **({'cost': round(sum(a * price[0] + b * price[1] for a, b in tk) / 1e6, 6)} if price else {})})
    return out


FIELDS = ['reader', 'page', 'arm', 'source', 'nes', 'raw_nes', 'chrf', 'words', 'read', 'missed', 'added', 'inserted',
          'rewritten', 'restoration_only', 'suspect', 'suspect_k']
THRESHOLDS = (0, 5, 10, 20, 40, 80, 160, 1e9)


def report():
    tags = {r['page']: r for r in json.loads((RESULTS / 'capture-tags.json').read_text())['pages']}
    panel = {r['page']: r for r in P.rows()}
    ids = pages()
    vision_raw = {p: vision_text('raw', p) for p in ids}
    readers = {'apple-vision': {(a, p): vision_text(a, p) for a in ARMS for p in ids}}
    cluster, tokens = cluster_readings()
    readers.update(cluster)
    import enh_ocr_input_gateway as GW
    gateway = GW.readings()  # None until every image is read (W46.enh-ocr-input-paid)
    if gateway:
        readers[GW.ROUTE], tokens[GW.ROUTE], gw_status = gateway
    origin = lambda p: 'original' if panel[p]['source'] == 'original' else 'pdf image'
    groups = {'96': ids, 'originals': [p for p in ids if origin(p) == 'original'],
              'PDF images': [p for p in ids if origin(p) != 'original']}
    tag_groups = {f'tagged {name}': [p for p in ids if any(tags[p][t] for t in ts)] for name, ts in TAGS.items()}
    L = ['# W46.enh-ocr-input: content-removing enhancement as OCR input, on the truth pages', '',
         'Generated by `scripts/segbench/enh_ocr_input.py report`; the method is in its docstring and in '
         '`enh_ocr_arms.py`. Page-level numbers: `enh-ocr-input-pages.csv`. Δ is paired by page: the mean, a 95% '
         'bootstrap interval and a permutation p. inserted and rewritten are per truth word, from a word alignment; '
         'restoration-only words are in neither the truth nor the same reader\'s raw reading; suspect words are in '
         'neither the same reader\'s raw reading nor Vision\'s (no truth needed), both per 1,000 words read.', '']
    allrows, bench, pending, charts = [], [], [], []
    for reader in ('apple-vision', *READERS, GW.ROUTE):
        if reader not in readers:
            pending.append(reader)
            L += [f'## {reader}', '', 'Not read yet (no collected cluster reading).' if reader != GW.ROUTE else
                  'Not read yet (`enh_ocr_input_gateway.py run`).', '']
            continue
        rd = readers[reader]
        arms = READER_ARMS.get(reader, ARMS)
        missing = sum(v is None for (a, p), v in rd.items())
        by = measure(rd, arms, ids, vision_raw)
        if missing:
            pending.append(reader)
        L += [f'## {reader}' + (f' ({missing} of {len(rd)} images not read yet)' if missing else ''), '']
        if reader == GW.ROUTE:
            L += ["Gemini 3.7 Flash through the Stanford gateway, with the cloud panel's request "
                  "(`enh_ocr_input_gateway.py`, W46.enh-ocr-input-paid), every arm on the 96; raw is "
                  "W46.fix-ocr-scorers-paid's reading of the same image, hash checked. "
                  f"{gw_status['ok']} of {sum(gw_status.values())} replies parsed ({gw_status['cap']} capped, "
                  f"{gw_status['blank']} unparsed, {gw_status['error']} failed; those score empty). Estimated cost "
                  f"of the {len(GW.jobs())} new calls ${GW.spent():.2f}, at 3.8 Flash's list price ($0.75 / $3.75 "
                  "per million tokens), which the gateway, returning no bill, is taken not to exceed. Its suspect "
                  "rate is against Vision's raw reading, as for every reader.", '']
        if arms != ARMS:
            L += ['Not run: ' + ', '.join(a for a in ARMS if a not in arms) + ' (its job read a list made before '
                  'those images existed).', '']
        L += table(by, groups, arms) + ['', 'By capture-defect tag (any page carrying the tag):', '']
        L += table(by, tag_groups, arms)
        # repair by tag: an enhancement only on the pages its defect calls for, raw elsewhere
        L += ['', 'Repair by tag: the arm on pages tagged shadow or low light only, raw on the rest; blur-tagged '
              'pages always raw.', '', '| arm | NES % by tag | Δ vs raw (CI, p) |', '|---|---:|---|']
        import ocr_panel_score as S
        target = set(tag_groups['tagged shadow or low light']) - set(tag_groups['tagged blur'])
        for arm in arms[1:]:
            qs = [p for p in ids if (arm, p) in by and ('raw', p) in by]
            if not qs:
                continue
            pol = [by[arm, p]['nes'] if p in target else by['raw', p]['nes'] for p in qs]
            t = S.paired(pol, [by['raw', p]['nes'] for p in qs])
            L.append(f"| {arm} | {100 * statistics.mean(pol):.1f} | {100 * t['delta']:+.1f} "
                     f"({100 * t['lo']:+.1f} to {100 * t['hi']:+.1f}, p {t['p']:.3f}) |")
        # the reference-free gate, thresholds set on these pages
        L += ['', 'The reference-free gate: the enhanced reading unless its suspect rate is above t per 1,000, raw '
              'otherwise. Set on these same pages, so the best t is in-sample.', '',
              '| arm | always raw | always arm | ' + ' | '.join(f't={t:g}' if t < 1e9 else 't=∞' for t in THRESHOLDS[:-1]) + ' |',
              '|---|---:|---:|' + '---:|' * (len(THRESHOLDS) - 1)]
        for arm in arms[1:]:
            rr = [by[arm, p] for p in ids if (arm, p) in by]
            if not rr:
                continue
            g = gate(rr, THRESHOLDS)
            L.append(f"| {arm} | {100 * statistics.mean(r['raw_nes'] for r in rr):.1f} | "
                     f"{100 * statistics.mean(r['nes'] for r in rr):.1f} | "
                     + ' | '.join(f'{100 * n:.1f} ({k})' for t, n, k in g[:-1]) + ' |')
        L.append('')
        for (arm, p), r in by.items():
            allrows.append({**r, 'reader': reader, 'source': origin(p)})
        bench += summary(by, {k: groups[k] for k in ('96', 'originals', 'PDF images')}, arms, reader)
        if not missing:
            charts += chart_rows(by, reader, arms, ids, tokens.get(reader, {}),
                                 GW.G.PRICE if reader == GW.ROUTE else None)
    # the two-seed probe
    probe = probe_pages()
    L += ['## The two-seed hallucination probe', '',
          f'ResShift (PreP-OCR) and NAF-DPM, each run twice with seeds {SEEDS}, on the {PROBE_N} pages with the lowest '
          'median NES over the saved routes. Instability: words that differ between the two seeds\' readings of a '
          'page, per 1,000 words read.', '']
    probe_readers = {'apple-vision': {(a, p): vision_text(a, p) for a in ('raw', *PROBE_ARMS) for p in probe}}
    if PROBE_READER in readers:
        probe_readers[PROBE_READER] = readers[PROBE_READER]
    else:
        pending.append(PROBE_READER)
    for reader, rd in probe_readers.items():
        if not any(rd.get((a, p)) is not None for a in PROBE_ARMS for p in probe):
            L += [f'{reader}: not read yet.', '']
            continue
        by = measure(rd, ('raw', *PROBE_ARMS), probe, vision_raw)
        L += [f'### {reader}', ''] + table(by, {'probe 30': probe}, ('raw', *PROBE_ARMS))
        L += ['', '| method | pages | unstable /1k | suspect /1k, seed 1 |', '|---|---:|---:|---:|']
        for m in PROBE:
            qs = [p for p in probe if rd.get((f'{m}-s1', p)) is not None and rd.get((f'{m}-s2', p)) is not None]
            if not qs:
                continue
            u = [unstable(rd[f'{m}-s1', p], rd[f'{m}-s2', p]) for p in qs]
            sus = [by[f'{m}-s1', p] for p in qs if (f'{m}-s1', p) in by]
            L.append(f"| {m} | {len(qs)} | {per_k(sum(a for a, _ in u), sum(b for _, b in u)):.1f} | "
                     f"{per_k(sum(r['suspect'] for r in sus), sum(r['read'] for r in sus) or 1):.1f} |")
        L.append('')
        for (arm, p), r in by.items():
            allrows.append({**r, 'reader': reader + ' (probe)', 'source': origin(p)})
        bench += summary(by, {'probe 30': probe}, ('raw', *PROBE_ARMS), reader)
    with PAGES.open('w') as f:
        w = csv.DictWriter(f, FIELDS, extrasaction='ignore', lineterminator='\n')
        w.writeheader()
        for r in allrows:
            w.writerow({k: (round(v, 6) if isinstance(v, float) else v) for k, v in r.items()})
    BENCH.write_text(json.dumps({'item': 'W46.enh-ocr-input', 'report': REPORT.name,
                                 'readers_pending': sorted(set(pending)),
                                 'not_run': {k: [a for a in ARMS if a not in v] for k, v in READER_ARMS.items()},
                                 'probe_pages': len(probe), 'rows': bench, 'chart_rows': charts,
                                 'gateway': {'item': 'W46.enh-ocr-input-paid', 'model': GW.G.MODEL, 'route': GW.ROUTE,
                                             'calls': len(GW.jobs()), 'cost_estimate': round(GW.spent(), 4),
                                             'price_assumed': GW.G.PRICE,
                                             'coverage': dict(gw_status) if gateway else None}}, indent=1) + '\n')
    REPORT.write_text('\n'.join(L) + '\n')
    print(REPORT)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('cmd', choices=['mac-arms', 'stage', 'fetch', 'vision', 'report', 'probe-pages'])
    a = ap.parse_args()
    if a.cmd == 'probe-pages':
        print(' '.join(probe_pages()))
        return
    {'mac-arms': mac_arms, 'stage': stage, 'fetch': fetch, 'vision': vision, 'report': report}[a.cmd]()


if __name__ == '__main__':
    sys.exit(main())
