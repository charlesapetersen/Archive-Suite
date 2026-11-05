#!/usr/bin/env python3
"""W46.vision-27-reread: did the macOS 27.2 update move Apple Vision's readings on the bench?

Every Vision baseline the bench reports was read before macOS 27.2 was installed (2026-10-30): the owner panel's
139 images on 2026-10-14 (`ocr-panel-local/vision`), the 440 reference set's 320 Latin-script pages on 2026-10-17
(`bench-corpus/routes/vision`) and the capture ladder's raw row on 2026-10-22 (`enh-dewarp/lines/raw`). This reads
the same images again with the same tools and settings on the current OS, into sibling `*-27.2` folders (the old
readings are kept, dated, beside them), and scores old and new with the same scorer against the same truth.
Vision is deterministic, so a change between the two is the OS.

W46.vision-27-swap (2026-11-04) then made the 27.2 readings the bench's: each dated folder moved aside as `*-26.6`
and a copy of its `*-27.2` sibling put in its place (the `*-27.2` folders stay, so this script and fm_foundation.py
read the same files as before). This script reads the dated readings from the `*-26.6` folders since then.

    python3 ops/autonomous/heavy-run.py run -- python3 vision_reread.py read
    python3 ops/autonomous/heavy-run.py run -- python3 vision_reread.py fill          # the 3 agreement pages' raw
    python3 ops/autonomous/heavy-run.py run -- python3 vision_reread.py repeat-hands  # both tools, 19 handwritten
    python3 vision_reread.py report      # segbench-results/vision-27-reread.{md,json}
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import platform
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE / 'corpus'))

import ocr_panel as P            # noqa: E402
import ocr_panel_score as S      # noqa: E402
import routes as R               # noqa: E402
import capture_ladder as L       # noqa: E402
from ocr_card import DRAW_96   # noqa: E402

TAG = '27.2'
OUT = HERE.parents[1] / 'segbench-results' / 'vision-27-reread'
PANEL_NEW = P.CACHE / f'vision-{TAG}'
BENCH_NEW = R.RUN / f'vision-{TAG}'
RAW_NEW = L.DEWARP / 'lines' / f'raw-{TAG}'
PANEL_OLD = P.CACHE / 'vision-26.6'             # the dated readings, moved aside by W46.vision-27-swap
BENCH_OLD = R.RUN / 'vision-26.6'
RAW_OLD = L.DEWARP / 'lines' / 'raw-26.6'


def os_version():
    v = subprocess.run(['sw_vers'], capture_output=True, text=True).stdout
    return {k.strip(): x.strip() for k, x in (l.split(':', 1) for l in v.splitlines() if ':' in l)}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()[:16]


def run(binary, mode, rows, name):
    jobs = OUT.parent / f'.vision-reread-{name}-jobs.tsv'
    jobs.write_text(''.join(f'{s}\t{d}\n' for s, d in rows))
    try:
        subprocess.run([str(binary), *([mode] if mode else []), str(jobs)], check=True)
    finally:
        jobs.unlink()


def panel_jobs():
    return [(P.CACHE / 'images' / f"{j['id']}.jpg", PANEL_NEW / f"{j['id']}.txt") for j in P.manifest()['jobs']]


def bench_jobs():
    return [(R.RUN / 'images' / f"{j['id']}.jpg", BENCH_NEW / f"{j['id']}.txt")
            for j in R.manifest()['jobs'] if j['script'] in R.VISION_SCRIPTS]


def raw_jobs():
    return [(L.image('raw', r['page']), RAW_NEW / f"{r['page']}.json") for r in L.scored_pages()]


def cmd_fill(_):
    """The raw lines of the three agreement pages, which `read` skipped (the ladder scores without them), so the
    27.2 folder that replaces the dated `raw` holds the same 99 files it did."""
    run(L.BIN, 'lines', [(L.image('raw', p), RAW_NEW / f'{p}.json') for p in sorted(P.AGREEMENT)
                         if not (RAW_NEW / f'{p}.json').exists()], 'fill')


def cmd_read(_):
    for d in (PANEL_NEW, BENCH_NEW, RAW_NEW):
        d.mkdir(parents=True, exist_ok=True)
    run(P.T.OCR_BIN, None, panel_jobs(), 'panel')
    run(P.T.OCR_BIN, None, bench_jobs(), 'bench')
    run(L.BIN, 'lines', raw_jobs(), 'raw')
    (OUT.parent / f'vision-27-reread.read.json').write_text(json.dumps(
        {'os': os_version(), 'machine': platform.machine(),
         'segbench-ocr': {'sha256_16': sha(P.T.OCR_BIN), 'source': 'ocr.swift'},
         'segbench-dewarp': {'sha256_16': sha(L.BIN)}}, indent=1) + '\n')


def cmd_repeat(_):
    """Vision read twice on the same OS: the first 15 panel jobs and 15 bench pages again, into a temporary folder,
    compared byte for byte with the 27.2 readings (the noise floor the verdict rests on)."""
    import tempfile
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        rows = [(s_, t / 'p' / d.name, d) for s_, d in panel_jobs()[:15]] + \
               [(s_, t / 'b' / d.name, d) for s_, d in bench_jobs()[:15]]
        run(P.T.OCR_BIN, None, [(s_, d) for s_, d, _ in rows], 'repeat')
        same = sum(d.read_bytes() == ref.read_bytes() for _, d, ref in rows)
    meta = OUT.parent / 'vision-27-reread.read.json'
    m = json.loads(meta.read_text()); m['repeat'] = {'n': len(rows), 'identical': same}
    meta.write_text(json.dumps(m, indent=1) + '\n')
    print(f'repeat: {same} of {len(rows)} identical')


def handwritten_originals():
    """Every handwritten original of the panel, the agreement pages too (19; 16 are scored)."""
    return sorted(r['page'] for r in P.rows() if r['kind'] == 'handwritten')


def cmd_repeat_hands(_):
    """Both tools again on the handwritten originals, each compared byte for byte with its own 27.2 reading
    (`ocr.swift` against the panel folder, `segbench-dewarp lines` against the raw folder), with each changed page's
    NES on the two reads; and the two tools compared with each other on every scored original, on both OS builds."""
    import tempfile
    pages = handwritten_originals()
    truth = {p: (P.TRUTH / 'truth' / f'{p}.txt').read_text() for p in pages}
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        (t / 'p').mkdir(); (t / 'r').mkdir()
        run(P.T.OCR_BIN, None, [(P.CACHE / 'images' / f'{p}-original.jpg', t / 'p' / f'{p}.txt') for p in pages],
            'repeat-ocr')
        run(L.BIN, 'lines', [(L.image('raw', p), t / 'r' / f'{p}.json') for p in pages], 'repeat-lines')
        pairs = {'ocr.swift': {p: ((PANEL_NEW / f'{p}-original.txt').read_text(), (t / 'p' / f'{p}.txt').read_text())
                               for p in pages},
                 'segbench-dewarp lines': {p: (lines_text(RAW_NEW / f'{p}.json'), lines_text(t / 'r' / f'{p}.json'))
                                           for p in pages}}
    tools = {}
    for tool, by in pairs.items():
        moved = {p: round(100 * (S.score(truth[p], b)['nes'] - S.score(truth[p], a)['nes']), 2)
                 for p, (a, b) in by.items() if a != b}
        tools[tool] = {'identical': len(pages) - len(moved), 'changed_nes': moved}
    scored = [r['page'] for r in L.scored_pages()]
    cross = [p for p in scored if lines_text(RAW_NEW / f'{p}.json') != (PANEL_NEW / f'{p}-original.txt').read_text()]
    cross_old = [p for p in scored if lines_text(RAW_OLD / f'{p}.json') != (PANEL_OLD / f'{p}-original.txt').read_text()]
    meta = OUT.parent / 'vision-27-reread.read.json'
    m = json.loads(meta.read_text())
    m['repeat_hands'] = {'n': len(pages), 'pages': pages, 'tools': tools,
                         'cross_tool': {'n': len(scored), 'differ_27.2': cross, 'differ_26.6': cross_old}}
    meta.write_text(json.dumps(m, indent=1) + '\n')
    print(json.dumps(m['repeat_hands'], indent=1))


def lines_text(path):
    return '\n'.join(l['text'] for l in json.loads(Path(path).read_text())['lines'])


def bowf1(s):
    n = s['words'] + s['hyp_words']
    return 2 * (s['words'] - s['missed']) / n if n else 1.


def pair(old, new, key):
    """Paired new minus old on one key, in points; with how many pages changed text at all."""
    p = S.paired([r[key] for r in new], [r[key] for r in old], rounds=10000)
    return {k: (100 * v if k in ('delta', 'lo', 'hi') else v) for k, v in p.items()}


def score_set(items):
    """items: (group labels, truth, old text, new text, stratum). Returns per-page rows."""
    rows = []
    for groups, truth, old, new, stratum in items:
        so, sn = S.score(truth, old, stratum), S.score(truth, new, stratum)
        rows.append({'groups': groups, 'same': old == new, 'ans_old': bool(old.strip()), 'ans_new': bool(new.strip()),
                     'old': {'nes': so['nes'], 'bowf1': bowf1(so), 'chrf': so['chrf']},
                     'new': {'nes': sn['nes'], 'bowf1': bowf1(sn), 'chrf': sn['chrf']}})
    return rows


def summarise(rows):
    by = collections.defaultdict(list)
    for r in rows:
        for g in r['groups']:
            by[g].append(r)
    out = {}
    for g, rr in by.items():
        old = [r['old'] for r in rr]; new = [r['new'] for r in rr]
        cell = {'n': len(rr), 'identical': sum(r['same'] for r in rr),
                'answered_old': sum(r['ans_old'] for r in rr), 'answered_new': sum(r['ans_new'] for r in rr),
                'lost': sum(r['ans_old'] and not r['ans_new'] for r in rr),
                'gained': sum(r['ans_new'] and not r['ans_old'] for r in rr),
                'moved5': sum(abs(r['new']['nes'] - r['old']['nes']) >= .05 for r in rr)}
        for k in ('nes', 'bowf1', 'chrf'):
            cell[f'old_{k}'] = 100 * sum(x[k] for x in old) / len(rr)
            cell[f'new_{k}'] = 100 * sum(x[k] for x in new) / len(rr)
            cell[f'd_{k}'] = pair(old, new, k) if cell['identical'] < len(rr) else {'n': len(rr), 'delta': 0.,
                                                                                    'lo': 0., 'hi': 0., 'p': 1.}
        out[g] = cell
    return out


def panel_items():
    by_page = {r['page']: r for r in P.rows()}
    for j in P.manifest()['jobs']:
        row = by_page[j['page']]; variant = j['id'].removeprefix(j['page'] + '-')
        truth = (P.TRUTH / 'truth' / f"{j['page']}.txt").read_text()
        old = (PANEL_OLD / f"{j['id']}.txt").read_text()
        new = (PANEL_NEW / f"{j['id']}.txt").read_text()
        groups = [f'all {variant}', f'{variant} · {row["kind"]}']
        if variant == 'original' and j['page'] not in P.AGREEMENT:
            groups.append('original · scored')
        yield groups, truth, old, new, 'S0'


def bench_items():
    truth = {R.job_id(r): r for r in R.frozen()}
    for j in R.manifest()['jobs']:
        if j['script'] not in R.VISION_SCRIPTS:
            continue
        old = BENCH_OLD / f"{j['id']}.txt"
        yield (['all', j['stratum']], Path(truth[j['id']]['truth']).read_text(), old.read_text(),
               (BENCH_NEW / f"{j['id']}.txt").read_text(), j['stratum'])


def resave_rows():
    """The capture ladder's re-save comparison, three ways: as reported (raw on 26.6 against the re-save on 27.2),
    the update alone on the raw file, and the re-encode alone (both on 27.2)."""
    out = []
    for r in L.scored_pages():
        p = r['page']; truth = (P.TRUTH / 'truth' / f'{p}.txt').read_text()
        src = 'original' if r['source'] == 'original' else 'pdf image'
        texts = {'raw-26.6': lines_text(RAW_OLD / f'{p}.json'), 'raw-27.2': lines_text(RAW_NEW / f'{p}.json'),
                 'resave-27.2': lines_text(L.lines_path(L.RESAVE, p))}
        sc = {k: S.score(truth, t) for k, t in texts.items()}
        out.append({'page': p, 'source': src, 'same_raw': texts['raw-26.6'] == texts['raw-27.2'],
                    **{k: {'nes': s['nes'], 'bowf1': bowf1(s)} for k, s in sc.items()}})
    return out


def resave_summary(rows):
    def comp(a, b, rr):
        return {k: pair([r[b] for r in rr], [r[a] for r in rr], k) for k in ('nes', 'bowf1')}
    res = {}
    for name, sel in (('all', rows), ('pdf image', [r for r in rows if r['source'] == 'pdf image'])):
        if not sel:
            continue
        res[name] = {'n': len(sel), 'raw_identical': sum(r['same_raw'] for r in sel),
                     'reported (resave 27.2 - raw 26.6)': comp('resave-27.2', 'raw-26.6', sel),
                     'update alone (raw 27.2 - raw 26.6)': comp('raw-27.2', 'raw-26.6', sel),
                     're-encode alone (resave 27.2 - raw 27.2)': comp('resave-27.2', 'raw-27.2', sel)}
    return res


def ci(d):
    if d['n'] < 10:   # no interval on fewer than about ten pages
        return f"{d['delta']:+.1f}"
    return f"{d['delta']:+.1f} ({d['lo']:+.1f} to {d['hi']:+.1f})"


def table(summary, order, title_col):
    L_ = [f'| {title_col} | n | text identical | answered before → after | NES before → after | ΔNES (95% CI) | '
          f'Δ bowF1 (95% CI) | pages moved ≥5 NES |', '|---|---|---|---|---|---|---|---|']
    for g in order:
        c = summary[g]
        L_.append(f"| {g} | {c['n']} | {c['identical']} | {c['answered_old']} → {c['answered_new']} | "
                  f"{c['old_nes']:.1f} → {c['new_nes']:.1f} | {ci(c['d_nes'])} | "
                  f"{ci(c['d_bowf1'])} | {c['moved5']} |")
    return L_


def cmd_report(_):
    meta = json.loads((OUT.parent / 'vision-27-reread.read.json').read_text())
    panel = summarise(score_set(panel_items()))
    bench_rows = score_set(bench_items()); bench = summarise(bench_rows)
    rs_rows = resave_rows(); resave = resave_summary(rs_rows)
    res = {'os_now': meta['os'], 'tools': {k: meta[k] for k in ('segbench-ocr', 'segbench-dewarp')},
           'panel': panel, 'bench': bench, 'resave': resave}
    (OUT.parent / 'vision-27-reread.json').write_text(json.dumps(res, indent=1, sort_keys=True) + '\n')

    po = sorted(panel, key=lambda g: (not g.startswith('all'), not g.startswith('original'), g))
    bo = ['all'] + sorted(g for g in bench if g != 'all')
    o = panel['original · scored']; b = bench['all']
    moved = any(c['identical'] < c['n'] for c in [*panel.values(), *bench.values()])
    a, ra = resave['all'], resave['all']
    l7 = [r for r in bench_rows if 'L7' in r['groups']]
    l7_kept = [r for r in l7 if r['ans_old'] == r['ans_new']]
    l7_rest = 100 * sum(r['new']['nes'] - r['old']['nes'] for r in l7_kept) / len(l7_kept)
    l7_lost = 100 * sum(r['new']['nes'] - r['old']['nes'] for r in l7 if r['ans_old'] and not r['ans_new']) / len(l7)
    flips = '; '.join(f"{g}: {c['lost']} lost" + (f", {c['gained']} gained" if c['gained'] else '')
                      for g, c in sorted({**{f'panel {k}': v for k, v in panel.items() if k.startswith('all')},
                                          **{f'public {k}': v for k, v in bench.items() if k != 'all'}}.items())
                      if c['lost'] or c['gained'])
    rh = meta['repeat_hands']; ct = rh['cross_tool']
    tool_line = '; '.join(f"`{t}` {v['identical']} of {rh['n']} identical" +
                          (' (' + ', '.join(f'{p} {d:+.1f}' for p, d in sorted(v['changed_nes'].items())) + ' NES)'
                           if v['changed_nes'] else '') for t, v in rh['tools'].items())
    floor = max([abs(d) for v in rh['tools'].values() for d in v['changed_nes'].values()] or [0.])
    M = ['# Apple Vision re-read on macOS 27.2 (W46.vision-27-reread)', '',
         f"Re-read on macOS {meta['os'].get('ProductVersion')} ({meta['os'].get('BuildVersion')}), {meta['machine']}, "
         "with the same tools and settings as the dated readings (`ocr.swift`: `.accurate`, language correction on, "
         "en-US, the app's defaults; the capture ladder's `segbench-dewarp lines`). The dated readings were made on "
         "macOS 26.6 (installed 2026-08-06; 27.2 was installed 2026-10-30): the owner panel on 2026-10-14, the "
         "440 reference set's Latin-script pages on 2026-10-17, the capture ladder's raw row on 2026-10-22. "
         "New readings sit beside the old, which are kept: `ocr-panel-local/vision-27.2/`, "
         "`bench-corpus/routes/vision-27.2/`, `enh-dewarp/lines/raw-27.2/` under "
         "`~/Library/Caches/ArchiveSuiteRehearsal`. Δ is after minus before, in points, paired by page.", '',
         "**Swapped in (W46.vision-27-swap, regenerated 2026-11-04).** The 27.2 readings are now the bench's Vision "
         "route: each dated folder moved aside as `*-26.6` (kept, nothing deleted) and a copy of its `*-27.2` "
         "sibling put in its place. `raw-27.2` held 96 files to the dated `raw`'s 99, since `read` skipped the three "
         "agreement pages the ladder does not score; `fill` read those on 27.2, so both hold 99. This regeneration adds "
         "the answered column, the empty-page finding, the two-tool repeat on the handwritten originals and the "
         "list below; no figure of the first report moved.", '',
         '## Verdict', '',
         (f"**The update moved Vision.** On the owner's {o['n']} scored originals NES goes {o['old_nes']:.1f} → "
          f"{o['new_nes']:.1f}, {ci(o['d_nes'])}, with {o['n'] - o['identical']} of {o['n']} texts changed; on the "
          f"440's {b['n']} Latin-script pages {b['old_nes']:.1f} → {b['new_nes']:.1f}, {ci(b['d_nes'])}, "
          f"{b['n'] - b['identical']} changed. On the 96 the NES change does not clear zero but bag-of-words F1 does "
          f"({ci(o['d_bowf1'])}); the panel's downscaled copies went the other way (half "
          f"{ci(panel['all half']['d_nes'])}, quarter {ci(panel['all quarter']['d_nes'])} NES), and on the 440 "
          f"one stratum fell (L7 {ci(bench['L7']['d_nes'])}). The texts changed on nearly every page, so every "
          "Vision figure read before 2026-10-30 is a macOS 26.6 figure and is labelled so. "
          f"**On 27.2 Vision returns nothing on {bench['L7']['lost']} of the 80 L7 pages** it answered on 26.6 "
          f"(answered {bench['L7']['answered_old']} → {bench['L7']['answered_new']}), and those pages are all of L7's "
          f"fall: they contribute {l7_lost:+.1f} of its {bench['L7']['d_nes']['delta']:+.1f}, and the other pages "
          f"average {l7_rest:+.1f}. With the swap the public Vision row answers {b['answered_new']} of {b['n']} pages, "
          f"not {b['answered_old']}; Vision is the second reader of the bench's suspect columns, so on those pages "
          f"every word another route reads is suspect. Pages that changed from answered to empty or back: {flips}." if moved else
          "**The update did not move Vision.** Every re-read text is byte-identical to its dated reading, on both "
          "sets."),
         (f"The capture ladder's re-save sentence compared a 26.6 raw reading with a 27.2 re-save. Measured on one "
          f"OS, the re-encode alone moves bowF1 {ci(a['re-encode alone (resave 27.2 - raw 27.2)']['bowf1'])} and NES "
          f"{ci(a['re-encode alone (resave 27.2 - raw 27.2)']['nes'])} on {a['n']} pages; the update alone on the raw "
          f"file moves bowF1 {ci(a['update alone (raw 27.2 - raw 26.6)']['bowf1'])} "
          f"({a['raw_identical']} of {a['n']} raw texts identical)."), '',
         "## The owner's 96 (139 images)", '',
         *table(panel, po, 'set'), '',
         "\"original · scored\" is the panel's headline set (the three agreement pages out). The half and "
         "quarter rows are the panel's downscaled copies of the same pages. Answered: a non-empty text.", '',
         '## The 440 reference set, Latin-script pages (Vision reads only these)', '',
         *table(bench, bo, 'stratum'), '',
         "## The capture ladder's re-save baseline", '',
         '| comparison | set | n | Δ bowF1 (95% CI) | ΔNES (95% CI) |', '|---|---|---|---|---|']
    for s, c in resave.items():
        for k in ('reported (resave 27.2 - raw 26.6)', 'update alone (raw 27.2 - raw 26.6)',
                  're-encode alone (resave 27.2 - raw 27.2)'):
            M.append(f"| {k} | {s} | {c['n']} | {ci(c[k]['bowf1'])} | {ci(c[k]['nes'])} |")
    M += ['', '## Which reports carry which Vision', '',
          "As of the swap (2026-11-04). **Now macOS 27.2, regenerated together:** `ocr-panel-local.md` "
          "(ocr_panel_score.py), `ocr-scorers.md`, `ocr-pages.csv` and `ocr-pages-agree.csv` (ocr_rescore.py, "
          "ocr_pages_export.py; the bench page's Vision rows and its cascade and agreement tables), "
          "`bench-corpus/routes.csv` (corpus/routes.py), every row of `capture-ladder.md`, the apple-vision row of "
          "`ocr-hands-rescore.md`, every Vision text in `ocr-ppocrv6-hands.md`, and the bench page. Already 27.2 "
          "before the swap: `r1-foundation.md` (complete; `r1-foundation.json` byte-identical after the swap), the "
          "capture ladder's defect and re-save rows and `capture-ladder-paid`, the hands panel's line boxes and "
          "`apple-vision (lines)`, and the layout-photo document route (read 2026-10-30 20:00 UTC).", '',
          "**Still macOS 26.6, labelled so and pinned to the `*-26.6` folders until every arm is re-read on one OS:** "
          "`enh-dewarp.md` (all 16 arms, its raw row included: on 27.2 the two tools no longer agree byte for byte, "
          "so its guard reads the 26.6 pair), `enh-ocr-input.md` (every arm, and its suspect counts) and "
          "`truth-jpeg-upgrade.md` (both sides; with one side swapped Vision's JPEG-minus-PDF change would read "
          "-7.0 for -4.2). The bench page labels their Vision routes 26.6.", '',
          "**Kept on their own dated inputs, never re-read** (a re-read would change a request a cached model reply is "
          "keyed on, so every cached reply would become a paid re-call, or the input belongs to another item): "
          "`ent-robust.md` (reads the `vision-26.6` folders), `ocr-postcorrect.md`, `date-traceable.md` (read "
          "2026-10-30 16:33-16:45 UTC, before the 19:06 install), `date-image.md`, `chaos-probe.md`, the "
          "`vision-words.json` of 2026-10-14 behind the placement truth, and the segmentation Vision text cache "
          "(data.py's: Dean, Deaver, Herrnstein, RG165 and Stanton 2026-10-05 on 26.6; Sasha, SC0122, the Illustrated "
          "Review and the checkpack boxes 2026-11-01 on 27.2), which `seg_window_gateway.py` hashes into every "
          "request; `r1-foundation.md`'s Deaver text-only windows carry that 26.6 text. `layout-order.md` and "
          "`place-geom.md` read Vision caches of their own, which the swap does not touch, so neither was "
          "regenerated.", '']
    M += ['', '## Measurement card', '',
          "- **Truth.** Unchanged and the same files the dated scores used: the owner panel's adjudicated truth "
          "(`ocr_truth` cache, owner-checked pages as recorded there) and the 440's frozen public truths. No model "
          "drafted anything here; this item compares Vision with itself.",
          "- **Selection.** Every image the dated readings covered: all 139 panel jobs, all 320 Latin-script "
          "pages of the 440 (Vision's script filter, unchanged), the capture ladder's scored pages (the panel's originals less the three agreement pages). Nothing "
          "chosen by a route or by ABBYY text. The panel's pages were drawn through Vision (26.6) itself: " + DRAW_96,
          "- **Comparison.** Same images byte for byte, same tool source and settings, same scorer "
          "(`ocr_panel_score.score`, the 440's per-stratum options) and truth; only the OS differs. The "
          "`segbench-ocr` (2026-11-03) and `segbench-dewarp` (2026-10-31) binaries were rebuilt on 27.2 from "
          "unchanged sources. The request revision is the default in both runs: on 27.2 with the 27.2 SDK it "
          "defaults to 3 and supports 1-3, as before, and the dated readings' tool was itself a 27.0-SDK build, so "
          "the change is inside revision 3, in the OS, and reaches the app whatever SDK it is built with.",
          f"- **Noise.** Read twice on 27.2, {meta['repeat']['identical']} of {meta['repeat']['n']} texts (15 panel "
          "images, 15 public pages, one of them handwritten) came back byte-identical. Handwriting is not: the "
          f"{rh['n']} handwritten originals read again with both tools (W46.vision-27-swap) gave {tool_line}; an "
          f"earlier repeat of the 16 scored ones gave {rh['first_run']['ocr_identical']} and "
          f"{rh['first_run']['lines_identical']} of 16. So on 27.2 Vision varies run to run on a few handwritten "
          f"pages, by up to {floor:.1f} NES on a page, under 0.1 point on the 96's mean, far inside every interval "
          "here, and the pages that vary are the ones where the two tools disagree on 27.2 "
          f"({', '.join(ct['differ_27.2'])}; {ct['n'] - len(ct['differ_27.2'])} of {ct['n']} scored originals "
          f"agree, {ct['n'] - len(ct['differ_26.6'])} of {ct['n']} on 26.6): the tools are not different, the "
          "readings are. Intervals are paired bootstrap 95% over pages (10,000 resamples, "
          "`ocr_panel_score.paired`); none is given under ten pages.",
          "- **Scope.** Apple Vision text only, on these images. It does not re-read the capture ladder's defect "
          "rows (all read on 27.2 on 2026-11-03, and paired against the same-run re-save, so their deltas stand), "
          "nor the Processor's own Vision path in the app.", '']
    (OUT.parent / 'vision-27-reread.md').write_text('\n'.join(M))
    print('\n'.join(M))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['read', 'fill', 'repeat', 'repeat-hands', 'report'])
    a = ap.parse_args()
    {'read': cmd_read, 'fill': cmd_fill, 'repeat': cmd_repeat, 'repeat-hands': cmd_repeat_hands,
     'report': cmd_report}[a.command](a)


if __name__ == '__main__':
    main()
