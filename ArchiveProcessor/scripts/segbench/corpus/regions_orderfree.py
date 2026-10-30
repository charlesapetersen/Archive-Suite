#!/usr/bin/env python3
"""W46.ocr-rescore-offline (1): the region and tile arms rescored order-free, beside the in-order NES they were judged on.

  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy --with python-Levenshtein \
      python ArchiveProcessor/scripts/segbench/corpus/regions_orderfree.py

The measurement audit's OCR-6 (execution-plans/processing-review/11-measurement-audit.md): the arms' losses on the 96
(-11.9 for Gemini 3.7 on PP-DocLayoutV3 regions, -5.7 on tiles) are character Levenshtein in reading order, and the
96's truth has no reading order to score (regions-20261021.md). This rereads every cached crop reading the two
reports scored, stitches each page exactly as they did (regions.stitch, the same receipts and validation), and adds
NewsBench's order-free bag-of-words F1, its order gap (bowF1 less 1 - CER) and the missed and added word rates. An
arm's bowF1 loss against the whole page is the loss left once the order penalty is taken away; the rest of its NES
loss is order. Sources:

  open readers  regions-20261021: GLM-OCR, PaddleOCR-VL 1.5, LightOnOCR-3 4B, Qwen3.6-27B; whole, DocLayout-YOLO,
                PP-DocLayoutV3, tiles; the 96 and L1, L3, L4, L9 (CACHE/sherlock-results/regions-20261021)
  Gemini 3.7    regions-gateway-20261028: whole, PP-DocLayoutV3, tiles; the 96 and 12 public pages, three a stratum
                (CACHE/ocr-regions-gateway, CACHE/gateway-gemini/panel)

The cells arms (regions-cells-20261025.md) are not here: they return named table fields scored by exact match per
field, which has no reading order to remove, and their receipts are on Sherlock, not this Mac.

Reads saved files only: no model, no network, no money. Writes score-only files (no text) under
segbench-results/bench-corpus/: regions-orderfree-20261030.md, .json and -pages.csv.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE.parent), str(HERE)]
import ocr_panel as P              # noqa: E402
import ocr_panel_score as S        # noqa: E402
import ocr_scorers as O            # noqa: E402
import regions as D                # noqa: E402
import regions_cluster as C        # noqa: E402
import routes as R                 # noqa: E402
from rapidfuzz import fuzz         # noqa: E402

# The tile stitch's word match (regions._same) uses python-Levenshtein's ratio when installed, which is not in the
# offline uv cache; rapidfuzz's fuzz.ratio is the same normalised Indel similarity, so the stitch is the reports'.
# main() checks each arm's NES against the committed reports.
D._ratio = lambda x, y: fuzz.ratio(x, y) / 100

CACHE = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
RUNS = CACHE / 'sherlock-results/regions-20261021'
OUT = P.RESULTS / 'bench-corpus'
NAME = 'regions-orderfree-20261030'
GROUPS = ('the 96', 'kind:handwritten', 'handwritten', 'typed, no table or clipping', 'clippings', 'tables', 'L9', 'L4', 'L3', 'L1')
ILLEGIBLE = re.compile(r'\[illegible\]', re.I)


def page_scores(ref: str, text: str, stratum: str | None, latin: bool) -> dict:
    """NES as the reports scored it, NewsBench's in-order and order-free figures, and the word counts."""
    sc = S.score(ref, text, stratum) if stratum else S.score(ref, text)
    row = {'ok': bool(text), 'nes': sc['nes'], 'words': sc['words'], 'missed': sc['missed'], 'added': sc['added']}
    if latin:   # NewsBench keeps only a-z and 0-9 (as ocr_rescore.py: the [illegible] marker is not text to read)
        nb = O.newsbench(ILLEGIBLE.sub(' ', ref), ILLEGIBLE.sub(' ', text))
        row.update(nb_overall=nb['overall'], bowf1=nb['bowF1'], gap=nb['gap'])
    return row


def owner_groups(panel_row: dict) -> list[str]:
    return ['the 96', *D.kinds_of(panel_row), 'kind:' + panel_row['kind']]


def open_readers():
    """Every page of regions-20261021, read and stitched as regions.cmd_report does."""
    import loop_rerun as L
    X, F = L.X, L.F
    pages = C.load_pages(RUNS)
    regions = {arm: json.loads((RUNS / 'regions' / f'{arm}.json').read_text())['pages'] for arm in C.ARMS if arm != 'tiles'}
    R.MANIFEST = D.MANIFEST
    truth = {R.job_id(r): r for r in R.frozen()}
    panel = {r['page']: r for r in P.rows()}
    for route in C.READERS:
        print(f'{route}: whole page and three crop arms', flush=True)
        mode = L.ROUTES[route]['mode']
        whole = {'public895': F.read_records(L.ROUTES[route]['dir']), 'owner99': D.whole96(route, L, F)}
        for p in pages:
            pid, set_ = p['id'], p['set']
            if set_ == 'public895':
                t = truth[pid]
                ref, stratum, groups, latin = Path(t['truth']).read_text(), t['stratum'], [t['stratum']], t.get('script', 'Latn') == 'Latn'
            else:
                if pid in P.AGREEMENT:
                    continue
                ref, stratum, groups, latin = (P.TRUTH / 'truth' / (pid + '.txt')).read_text(), None, owner_groups(panel[pid]), True
            if pid not in whole[set_]:
                raise ValueError(f'{route}/whole/{pid}: missing whole-page receipt')
            texts = {'whole': X.reading(whole[set_].get(pid), mode)}
            for arm in C.ARMS:
                recs = D.crop_records(RUNS, route, arm, pid)
                texts[arm] = D.page_reading(arm, recs, D.validate_crops(route, arm, pid, recs, regions), mode, X.reading)['text']
            for arm, text in texts.items():
                yield {'source': 'open readers', 'route': route, 'arm': arm, 'set': set_, 'page': pid,
                       'groups': groups, **page_scores(ref, text, stratum, latin)}


def gemini():
    """Every page of regions-gateway-20261028, from the re-validated receipts, as regions_gateway.score reads them."""
    import regions_gateway as G
    m = G.manifest()
    G.verify()
    ledger = {r['request_sha256']: r for r in G.effective() if r['event'] == 'settle'}
    panel = {r['page']: r for r in P.rows()}
    for p in m['pages']:
        ref = Path(p['truth']).read_text()
        for arm in G.ARMS:
            if not G.present(m, p, arm, ledger):
                raise ValueError(f'{p["id"]}/{arm}: receipts missing')
            got = [{'index': i, 'box': c['box'], **G.receipt(m, (p, arm, i, c), ledger)} for i, c in enumerate(p['crops'][arm])]
            good = [g for g in got if g['text']]
            text = D.stitch(arm, good) if good else ''
            if p['set'] == 'owner99':
                groups, stratum = owner_groups(panel[p['id']]), None
            else:
                groups, stratum = [p['stratum']], p['stratum']
            yield {'source': 'gemini', 'route': G.ROUTE, 'arm': arm, 'set': p['set'], 'page': p['id'], 'groups': groups,
                   **page_scores(ref, text, stratum, True)}


def mean(xs):
    return sum(xs) / len(xs) if xs else None


def summarise(rows: list[dict]) -> list[dict]:
    """Per route, arm and group: in-order and order-free means, the word rates, and each figure's paired difference
    from the whole page on the same pages (failures as 0 in both, as the reports scored them)."""
    out = []
    keys = sorted({(r['source'], r['route'], r['arm']) for r in rows})
    whole = {(r['source'], r['route'], r['page']): r for r in rows if r['arm'] == 'whole'}
    for src, route, arm in keys:
        mine = [r for r in rows if (r['source'], r['route'], r['arm']) == (src, route, arm)]
        for g in GROUPS:
            rr = sorted((r for r in mine if g in r['groups']), key=lambda r: r['page'])
            if not rr:
                continue
            ww = [whole[(src, route, r['page'])] for r in rr]
            words = sum(r['words'] for r in rr)
            latin = [r for r in rr if 'bowf1' in r]
            row = {'source': src, 'route': route, 'arm': arm, 'group': g, 'n': len(rr), 'ok': sum(r['ok'] for r in rr),
                   'nes': mean([r['nes'] for r in rr]), 'nb_overall': mean([r['nb_overall'] for r in latin]),
                   'bowf1': mean([r['bowf1'] for r in latin]), 'gap': mean([r['gap'] for r in latin]),
                   'missed_rate': sum(r['missed'] for r in rr) / words if words else None,
                   'added_rate': sum(r['added'] for r in rr) / words if words else None, 'latin_pages': len(latin)}
            if arm != 'whole':
                wl = [whole[(src, route, r['page'])] for r in latin]
                row['d_nes'] = S.paired([r['nes'] for r in rr], [w['nes'] for w in ww])
                row['d_bowf1'] = S.paired([r['bowf1'] for r in latin], [w['bowf1'] for w in wl])
                row['d_nb_overall'] = mean([r['nb_overall'] - w['nb_overall'] for r, w in zip(latin, wl)])
                row['d_gap'] = mean([r['gap'] - w['gap'] for r, w in zip(latin, wl)])
                wwords = sum(w['words'] for w in ww)
                row['d_missed_rate'] = row['missed_rate'] - sum(w['missed'] for w in ww) / wwords if wwords else None
                row['d_added_rate'] = row['added_rate'] - sum(w['added'] for w in ww) / wwords if wwords else None
                both = [(r, w) for r, w in zip(latin, wl) if r['ok'] and w['ok']]
                row['d_bowf1_answered'] = S.paired([r['bowf1'] for r, _ in both], [w['bowf1'] for _, w in both])
            out.append(round_all(row))
    return out


def round_all(x):
    if isinstance(x, float):
        return round(x, 4)
    if isinstance(x, dict):
        return {k: round_all(v) for k, v in x.items()}
    return x


NAMES = {'glm-ocr': 'GLM-OCR', 'paddleocr-vl1.5': 'PaddleOCR-VL 1.5', 'lightonocr3-4b': 'LightOnOCR-3 4B',
         'qwen3.6-27b': 'Qwen3.6-27B', 'gemini-3.7-flash-gw': 'Gemini 3.7 Flash'}
ARM_NAMES = {'doclayout_yolo': 'DocLayout-YOLO', 'pp-doclayoutv3': 'PP-DocLayoutV3', 'tiles': 'tiles'}


def pt(x, sign=False):
    return '—' if x is None else (f'{100 * x:+.1f}' if sign else f'{100 * x:.1f}')


def ci(d):
    return '—' if not d or not d['n'] else f"{100 * d['delta']:+.1f} ({100 * d['lo']:+.1f} to {100 * d['hi']:+.1f})"


def report(summary: list[dict], n_rows: int) -> str:
    by = {(r['source'], r['route'], r['arm'], r['group']): r for r in summary}
    gw, q = ('gemini', 'gemini-3.7-flash-gw'), ('open readers', 'qwen3.6-27b')

    def f(who, arm, g):
        r = by[(*who, arm, g)]
        return f"{pt(r['d_nes']['delta'], True)} in order, {ci(r['d_bowf1'])} order-free"

    L = ['# The region and tile arms, rescored order-free (W46.ocr-rescore-offline)', '',
         'Measured 2026-10-30 from the cached readings of `regions-20261021` (four open readers, Sherlock) and',
         '`regions-gateway-20261028` (Gemini 3.7 Flash, the Stanford gateway). Each page is stitched exactly as those',
         "reports stitched it, and every page's NES reproduces theirs, except the open readers' p025 and p088, which are",
         "rescored here on the owner's 2026-10-29 truth corrections. $0: no model, network or cluster.",
         f'Script: `scripts/segbench/corpus/regions_orderfree.py`. {n_rows:,} page readings scored.', '',
         '## What this changes', '',
         "- **Reading order inflated the arms' losses on the 96, and the losses still stand.** The measurement audit's OCR-6",
         "  asked how much of the -11.9 and -5.7 was order, since the 96's truth has no reading order to score.",
         f"  Gemini 3.7 Flash, PP-DocLayoutV3 regions: {f(gw, 'pp-doclayoutv3', 'the 96')}. Tiles: {f(gw, 'tiles', 'the 96')}.",
         f"  Qwen3.6-27B: regions {f(q, 'pp-doclayoutv3', 'the 96')}. Tiles: {f(q, 'tiles', 'the 96')}.",
         '  Every one of these intervals stays below 0, so whole-page reading remains the default. What is left after order',
         '  is roughly 40 to 70 per cent of the in-order loss.',
         '- **What is left after order is content.** Regions miss words: the missed rate rises, most of all on hands.',
         f"  Gemini on the 16 hand pages: {f(gw, 'pp-doclayoutv3', 'kind:handwritten')}, with the missed rate up",
         f"  {pt(by[(*gw, 'pp-doclayoutv3', 'kind:handwritten')]['d_missed_rate'], True)} points. Tiles add words: where the",
         '  stitch does not find the repeat, the overlap band is read twice. For Gemini on the 96 the added rate is up',
         f"  {pt(by[(*gw, 'tiles', 'the 96')]['d_added_rate'], True)} points, and on clippings it is up 23 to 36 for every reader.",
         f"  On hand pages, Gemini's tiles are a tie order-free ({ci(by[(*gw, 'tiles', 'kind:handwritten')]['d_bowf1'])}).",
         '- **Typed pages with no table or clipping:** tiles are a tie order-free for Gemini, Qwen and LightOn. The small',
         '  readers\' tile gains that regions-20261021.md reported (GLM-OCR, PaddleOCR-VL 1.5) keep their direction',
         '  order-free, but their intervals reach 0.',
         '- **Newspapers (L9) and registers (L4) do not change in kind.** On L9, regions lift the two small readers by more',
         '  than 60 points order-free. Tiles lift them about 11 points and cost LightOn and Qwen most of their L9 score, so the',
         '  fixed tiler stays ruled out.',
         '- **The cells arms are not rescored.** They return named table fields, each scored by exact match, so there is no',
         '  reading order to remove. Their receipts are on Sherlock, not on this Mac (regions-cells-20261025.md).', '',
         '## Measurement card', '',
         '- **Truth.** The 96: drafted by Claude Opus 5.5 and Gemini 3.8 Flash, with their disagreements adjudicated by the',
         '  owner and the two 2026-10-29 corrections applied. Gemini 3.7 is a close relative of a drafter, so its whole-page',
         '  figure may be flattered, but both sides of each difference are the same reader against the same truth. L1, L3,',
         "  L4 and L9 use the public sets' own published truth, which is independent of every route here.",
         "- **Selection.** The parent reports' pages: all 96, plus the frozen L1, L3, L4 and L9 pages of the 895 for the open",
         '  readers. For Gemini, three public pages a stratum, drawn by a stable hash of the page id (regions_gateway.choose).',
         '  No tested route and no ABBYY text chose a page.',
         "- **Comparison.** Each arm is compared page for page with the same reader's whole-page reading at the same settings.",
         '  A page an arm returned nothing for scores 0 on both NES and bowF1, as the reports scored it. Both OCR sets: the 96',
         "  and the public strata. Gemini's public rows are 3 pages a stratum, a labelled sample, not a set result.",
         '- **Noise.** 95% paired bootstrap intervals over pages (ocr_panel_score.paired). No rerun-noise floor exists yet',
         '  (W46.ocr-rerun-noise), so a difference whose interval crosses 0 is a tie.',
         '- **Scope.** bowF1 credits the right words in any order, but a reader of the page needs the order. The order-free',
         "  figure is therefore the lower bound of the content loss, and it does not make an arm's jumbled text usable. It does",
         '  not re-decide the layout routes for newspapers (W46.layout-photo, W46.layout-order) or the cells arms.', '',
         '## Columns', '',
         'ΔNES is the arm less the whole page in reading-order character similarity, the figure the reports judged on.',
         "ΔbowF1 is the same difference in NewsBench's bag-of-words F1, which ignores order: the loss left once the order",
         "penalty is removed. Δgap is the change in NewsBench's order gap (bowF1 less 1 - CER), its own order penalty.",
         '1 - CER falls below 0 where a reading repeats text, so the gap is large on tiles and is not on the NES scale.',
         "Missed and added are word rates over the truth's words, arm less whole. Intervals are 95% paired bootstrap over",
         'pages.', '']
    for src, title in (('gemini', 'Gemini 3.7 Flash (the gateway default)'), ('open readers', 'The four open readers')):
        L += [f'## {title}', '',
              '| group | reader | arm | pages | whole NES | arm NES | ΔNES | ΔbowF1 (order-free) | Δgap | Δmissed | Δadded |',
              '|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|']
        for g in GROUPS:
            for r in summary:
                if r['source'] != src or r['group'] != g or r['arm'] == 'whole':
                    continue
                w = by[(src, r['route'], 'whole', g)]
                L.append(f"| {g} | {NAMES[r['route']]} | {ARM_NAMES[r['arm']]} | {r['n']} | {pt(w['nes'])} | {pt(r['nes'])} | "
                         f"{ci(r['d_nes'])} | {ci(r['d_bowf1'])} | {pt(r['d_gap'], True)} | {pt(r['d_missed_rate'], True)} | "
                         f"{pt(r['d_added_rate'], True)} |")
        L.append('')
    return '\n'.join(L) + '\n'


# The two owner-approved truth corrections (W46.truth-edits, 2026-10-29). The gateway report was rescored on them;
# regions-20261021 kept the earlier truth, so its NES on these two pages differs here by design.
TRUTH_EDITED = {'p025', 'p088'}


def check_against_reports(rows: list[dict]):
    """Every page's NES must be the committed report's (the same readings, stitched the same way), except the open
    readers' two corrected truth pages."""
    import csv
    ref = {}
    for name in ('regions-20261021-pages.csv', 'regions-gateway-20261028-pages.csv'):
        with (OUT / name).open(newline='') as f:
            for r in csv.DictReader(f):
                ref[(r['route'], r['arm'], r['page'])] = float(r['nes'])
    off, edited = [], 0
    for r in rows:
        k = (r['route'], r['arm'], r['page'])
        if k not in ref:
            raise SystemExit(f'{k}: not in the committed reports')
        if abs(r['nes'] - ref[k]) > 1e-5:
            if r['source'] == 'open readers' and r['page'] in TRUTH_EDITED:
                edited += 1
            else:
                off.append((*k, r['nes'], ref[k]))
    if off:
        raise SystemExit(f'{len(off)} page readings differ from the committed reports, e.g. {off[:5]}')
    print(f'all {len(rows)} page NES match the committed reports ({edited} on the corrected truth pages differ, as expected)')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', type=Path, default=OUT)
    a = ap.parse_args()
    rows = [*gemini(), *open_readers()]
    check_against_reports(rows)
    summary = summarise(rows)
    a.out.mkdir(parents=True, exist_ok=True)
    S.write_csv(a.out / f'{NAME}-pages.csv',
                [{**{k: round(v, 6) if isinstance(v, float) else v for k, v in r.items()}, 'groups': ';'.join(r['groups'])}
                 for r in rows],
                ['source', 'route', 'arm', 'set', 'page', 'groups', 'ok', 'nes', 'nb_overall', 'bowf1', 'gap', 'words',
                 'missed', 'added'])
    (a.out / f'{NAME}.json').write_text(json.dumps({'report': f'bench-corpus/{NAME}.md', 'rows': summary}, indent=1) + '\n')
    (a.out / f'{NAME}.md').write_text(report(summary, len(rows)))
    print(f'{len(rows)} page readings, {len(summary)} rows -> {a.out}')


if __name__ == '__main__':
    main()
