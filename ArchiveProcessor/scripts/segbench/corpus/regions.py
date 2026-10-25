#!/usr/bin/env python3
"""W46.ocr-regions — whole page against detector regions against tiles, four open readers (the Mac half).

  <lab venv>/bin/python regions.py prepare --out DIR    # DIR/regions/pp-doclayoutv3.json
  regions.py report --runs DIR --out DIR                # stitch each arm's crops, score them beside whole page

`prepare` runs PP-DocLayoutV3 (the mlx-vlm port `layout.py` uses, conf 0.5, its own reading order) on this Mac
over the run's pages, L9, L4, L3 and L1 of the 895 (the frozen originals) and the owner's 99 (the panel's frozen
originals), and writes the boxes as page fractions keyed by the cluster's page id, so the cluster job can cut the
same boxes from the 2,400 px copy each route read whole. DocLayout-YOLO runs on the cluster (newspaper-ocr's
detector is not installed here). The cluster half, the arms and the request: `regions_cluster.py`; submission:
`regions-submit.sh`. No money; no page text or pixels leave the Mac in this step beyond the region boxes.
"""
from pathlib import Path
import argparse
import json
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import os                                # noqa: E402
import routes as R                       # noqa: E402
import regions_cluster as C              # noqa: E402

LTS = Path(os.environ.get('LTS', Path.home() / 'Claude/Long term storage'))
MANIFEST = LTS / 'FarmShare-20261019/recovery/manifest-895.jsonl'   # as loop_rerun.py (no scorer import here)
DETECTOR = 'PP-DocLayoutV3 (mlx-vlm port), conf 0.5, 1024 px, model reading order'


def mac_pages():
    """(cluster id, set, stratum, image path on this Mac) for every page of the run."""
    R.MANIFEST = MANIFEST
    out = [(R.job_id(r), 'public895', r['stratum'], Path(r['image'])) for r in R.frozen() if r['stratum'] in C.STRATA]
    import ocr_panel as P
    m = json.loads((P.CACHE / 'manifest.json').read_text())
    out += [(j['page'], 'owner99', None, P.CACHE / 'images' / (j['id'] + '.jpg'))
            for j in m['jobs'] if j['scale'] == 'original']
    return out


def boxes_pp(found: list[dict]) -> list[dict]:
    """PP-DocLayoutV3's viewer schema ([y0, x0, y1, x1] in 0-1000, 1-based order) as the cluster's records."""
    rows = [{'label': r['label'], 'order': r['reading_order'], 'score': round(float(r['score']), 3),
             'box': [max(0.0, r['bbox'][1] / 1000), max(0.0, r['bbox'][0] / 1000),
                     min(1.0, r['bbox'][3] / 1000), min(1.0, r['bbox'][2] / 1000)]} for r in found]
    return sorted(rows, key=lambda r: r['order'])


TAIL_WORDS = 250     # prev's last words the next tile may repeat (a 30% band overlap is ~120 words of dense type)
HEAD_EXTRA = 40      # cur's head is searched this many words past the tail's length
END_SLACK = 8        # the repeat may end this many words before prev's end (prev's last line, cut by the band edge)
SKIP_COST = 0.5      # each cur word skipped before the repeat starts (cur's first line, cut by the band edge)
MIN_REPEAT = 4.0     # alignment score (matched words less mismatches and gaps) for a repeat to count
SAME_WORD = 0.8      # edit ratio at which two normalised words are the same word read twice


def _words(text: str) -> list[tuple[str, int]]:
    """Normalised words with the offset where each ends in text; punctuation-only tokens are left out."""
    import re
    out = []
    for m in re.finditer(r'\S+', text):
        w = re.sub(r'^\W+|\W+$', '', m.group().lower())
        if w:
            out.append((w, m.end()))
    return out


try:
    from Levenshtein import ratio as _ratio
except ImportError:   # the scorer venv has it; difflib gives the same verdicts here, slower
    from difflib import SequenceMatcher
    _ratio = lambda x, y: SequenceMatcher(None, x, y).ratio()


def _same(a: str, b: str) -> bool:
    if a == b:
        return True
    if min(len(a), len(b)) < 4 or abs(len(a) - len(b)) > 2:
        return False
    return _ratio(a, b) >= SAME_WORD


def drop_repeated_head(prev: str, cur: str) -> str:
    """cur without the head that repeats prev's tail. The readers reflow a band's lines into paragraphs, so the
    repeat starts mid-line: words are aligned, not lines. The alignment starts anywhere in prev's tail, at a small
    cost per cur word skipped first, and must end within END_SLACK words of prev's end; cur is cut where it ends.
    Below MIN_REPEAT nothing is dropped. A word the band edge cut through stays as read (scored as written)."""
    pw = [w for w, _ in _words(prev)][-TAIL_WORDS:]
    cw = _words(cur)[:len(pw) + HEAD_EXTRA]
    n, m = len(pw), len(cw)
    if not n or not m:
        return cur.strip()
    NEG = float('-inf')
    H = [[NEG] * (m + 1) for _ in range(n + 1)]
    best, cut = NEG, 0
    for i in range(1, n + 1):
        row, up = H[i], H[i - 1]
        for j in range(1, m + 1):
            s = 1.0 if _same(pw[i - 1], cw[j - 1][0]) else -1.0
            v = max(up[j - 1] + s, up[j] - 1.0, row[j - 1] - 1.0)
            if s > 0:
                v = max(v, s - SKIP_COST * (j - 1))
            row[j] = v
            if i >= n - END_SLACK and v > best:
                best, cut = v, j
    if best < MIN_REPEAT:
        return cur.strip()
    return cur[cw[cut - 1][1]:].strip()


def stitch(arm: str, crops: list[dict]) -> str:
    """One page's text from its crops' readings ({'index', 'box', 'text'}), in the order they were sent. Regions
    are joined as paragraphs; tiles in the same column lose the head their overlap repeats."""
    crops = sorted(crops, key=lambda c: c['index'])
    if arm != 'tiles':
        return '\n\n'.join(c['text'].strip() for c in crops if c['text'].strip())
    out, prev = [], None
    for c in crops:
        text = c['text'].strip()
        if prev is not None and prev['box'][0] == c['box'][0]:
            text = drop_repeated_head(prev['text'], text)
        if text:
            out.append(text)
        prev = c
    return '\n'.join(out)

LO = LTS / 'FarmShare-regions-20261021'
# Qwen3.6-27B's whole-page readings of the 99: the truth run whose server settings are the regions run's (kv-cache
# auto; 1849739 used fp8), copied from runs/truth/qwen3.6-27b-1849744/replies. The other three: the truth96 run.
QWEN96 = LO / 'whole96-qwen3.6-27b-1849744/replies'
T96_DIR = {'glm-ocr': 't96-glm-ocr', 'paddleocr-vl1.5': 't96-paddleocr-vl1.5', 'lightonocr3-4b': 't96-lightonocr3-4b'}
KINDS = ('clippings', 'tables', 'handwritten', 'typed, no table or clipping')


def kinds_of(row: dict) -> list[str]:
    """The 96's kind groups a panel row belongs to (the panel's tags and kinds; a page may be in two)."""
    out = [k for k in ('clippings', 'tables') if (row.get(k) or 'no') != 'no']
    if row.get('kind') == 'handwritten' or (row.get('handwritten') or 'no') != 'no':
        out.append('handwritten')
    if not out and row.get('kind') == 'typewritten':
        out.append('typed, no table or clipping')
    return out


def page_reading(arm: str, records: list[dict], expected: int | None, mode: str, reading) -> dict:
    """One page's stitched text from its crop records (any status), with the crops that gave nothing counted.
    expected is the kept-region count for a detector arm (None for tiles: the records say how many were cut)."""
    good = []
    for r in records:
        text = reading(r, mode)
        if text:
            good.append({'index': r['index'], 'box': r['box'], 'text': text})
    n = expected if expected is not None else len(records)
    return {'text': stitch(arm, good) if good else '', 'crops': n, 'crops_failed': n - len(good),
            'prompt_tokens': sum((r.get('usage') or {}).get('prompt_tokens') or 0 for r in records),
            'completion_tokens': sum((r.get('usage') or {}).get('completion_tokens') or 0 for r in records)}


def validate_crops(route: str, arm: str, pid: str, records: list[dict], regions: dict) -> int:
    """Refuse an incomplete collection instead of silently scoring only the pages/crops that came back.
    Tiles retain their exact fractional boxes and pixel bounds, so the page size and complete grid can be
    recovered without opening an image. Caps remain failed crops when scored; unknown token usage is refused
    rather than assigning an optimistic price to a transport failure.
    """
    label = f'{route}/{arm}/{pid}'
    if arm == 'tiles':
        if not records:
            raise ValueError(f'{label}: missing tile receipts')
        w = max(r['px'][2] for r in records)
        h = max(r['px'][3] for r in records)
        boxes = C.tile_boxes(w, h)
    else:
        boxes = [r['box'] for r in C.keep_regions(regions[arm][pid])]
    if [r['index'] for r in records] != list(range(len(boxes))):
        raise ValueError(f'{label}: incomplete crop indices (expected {len(boxes)}, got {len(records)})')
    for i, (r, box) in enumerate(zip(records, boxes)):
        if ((r['page'], r['route'], r['arm']) != (pid, route, arm) or len(r['box']) != 4
                or any(abs(a - b) > 1e-8 for a, b in zip(r['box'], box))):
            raise ValueError(f'{label}/{i}: crop identity or geometry differs from pack')
        if any(not isinstance((r.get('usage') or {}).get(k), int) for k in ('prompt_tokens', 'completion_tokens')):
            raise ValueError(f'{label}/{i}: missing token usage')
    return len(boxes)


def crop_records(runs: Path, route: str, arm: str, pid: str) -> list[dict]:
    """A page's crop readings, the last attempt at each index: NNN.json, else its NNN.error.json."""
    d = runs / 'out' / route / arm / pid
    got = {}
    for f in sorted(d.glob('*.json')) if d.is_dir() else []:
        k = int(f.name.split('.')[0])
        if f.name.endswith('.error.json') and k in got:
            continue
        got[k] = json.loads(f.read_text())
    return [got[k] for k in sorted(got)]


def score_rows(rr: list[dict], S) -> dict:
    agg = S.aggregate(rr)
    edits = [r['order_edit'] for r in rr if isinstance(r.get('order_edit'), float)]
    return {'n': agg['n'], 'ok': agg['ok'], 'nes': round(agg['nes'], 4), 'nes_answered': round(agg['nes_answered'], 4),
            'chrf': round(agg['chrf'], 4), 'order_edit': round(sum(edits) / len(edits), 4) if edits else '',
            'order_pages': len(edits), 'crops': sum(r.get('crops') or 0 for r in rr),
            'crops_failed': sum(r.get('crops_failed') or 0 for r in rr),
            'prompt_tokens': sum(r.get('prompt_tokens') or 0 for r in rr),
            'completion_tokens': sum(r.get('completion_tokens') or 0 for r in rr)}


def whole96(route: str, L, F):
    if route == 'qwen3.6-27b':
        out = {}
        for f in QWEN96.glob('*.json'):
            j = json.loads(f.read_text())
            out[f.stem] = {'raw': j['reply'].get('raw', ''), 'status': j['meta'].get('status'),
                           'finish': j['meta'].get('finish'),
                           'usage': {k: j['meta'].get(k) for k in ('prompt_tokens', 'completion_tokens')}}
        return out
    return F.read_records(L.T96[T96_DIR[route]]['dir'])


def markup_summary(table_markup: list[dict]) -> list[dict]:
    out = []
    for route in C.READERS:
        for arm in ('whole', *C.ARMS):
            rr = [r for r in table_markup if (r['route'], r['arm']) == (route, arm)]
            if rr:
                out.append({'route': route, 'arm': arm, 'n': len(rr),
                            **{k: round(sum(r[k] for r in rr) / len(rr), 6) for k in ('strict', 'markup_stripped')},
                            'markup_pages': sum(r['has_markup'] for r in rr)})
    return out


def cmd_report(a):
    import loop_rerun as L
    import ocr_panel as P
    import ocr_panel_score as S
    import ocr_scorers as O
    X, F = L.X, L.F
    runs = a.runs
    pages = C.load_pages(runs)
    regions = {arm: json.loads((runs / 'regions' / f'{arm}.json').read_text())['pages'] for arm in C.ARMS if arm != 'tiles'}
    R.MANIFEST = MANIFEST
    truth = {R.job_id(r): r for r in R.frozen()}
    panel = {r['page']: r for r in P.rows()}
    rows, page_rows, table_markup = [], [], []
    for route in C.READERS:
        print(f'{route}: scoring whole page and three crop arms', flush=True)
        mode = L.ROUTES[route]['mode']
        whole = {'public895': F.read_records(L.ROUTES[route]['dir']), 'owner99': whole96(route, L, F)}
        for p in pages:
            pid, set_ = p['id'], p['set']
            if set_ == 'public895':
                ref, stratum = Path(truth[pid]['truth']).read_text(), truth[pid]['stratum']
                groups = [stratum]
            else:
                ref, stratum = (P.TRUTH / 'truth' / (pid + '.txt')).read_text(), None
                if pid in P.AGREEMENT:
                    continue   # the three agreement-only letters: not truth the 96 can rank readers on
                groups = ['the 96', *kinds_of(panel[pid]), 'kind:' + panel[pid]['kind']]
            if pid not in whole[set_]:
                raise ValueError(f'{route}/whole/{pid}: missing whole-page receipt')
            readings = {'whole': {'text': X.reading(whole[set_].get(pid), mode), 'crops': '', 'crops_failed': '',
                                  'prompt_tokens': ((whole[set_].get(pid) or {}).get('usage') or {}).get('prompt_tokens', ''),
                                  'completion_tokens': ((whole[set_].get(pid) or {}).get('usage') or {}).get('completion_tokens', '')}}
            for arm in C.ARMS:
                recs = crop_records(runs, route, arm, pid)
                expected = validate_crops(route, arm, pid, recs, regions)
                readings[arm] = page_reading(arm, recs, expected, mode, X.reading)
            for arm, got in readings.items():
                sc = S.score(ref, got['text'], stratum) if stratum else S.score(ref, got['text'])
                if set_ == 'owner99' and 'tables' in groups:
                    table_markup.append({'route': route, 'arm': arm, 'page': pid, 'strict': sc['nes'],
                                         'markup_stripped': S.score(ref, O.strip_markup(got['text']))['nes'],
                                         'has_markup': O.has_markup(got['text'])})
                order = O.reading_order_edit(ref, got['text']) if got['text'] else None
                page_rows.append({'set': set_, 'groups': ';'.join(groups), 'route': route, 'arm': arm, 'page': pid,
                                  'ok': bool(got['text']), **sc, 'order_edit': (order or {}).get('edit'),
                                  **{k: got[k] for k in ('crops', 'crops_failed', 'prompt_tokens', 'completion_tokens')}})
    for route in C.READERS:
        for arm in ('whole', *C.ARMS):
            mine = [r for r in page_rows if r['route'] == route and r['arm'] == arm]
            for g in sorted({g for r in mine for g in r['groups'].split(';')}):
                rr = [r for r in mine if g in r['groups'].split(';')]
                ids = {r['page'] for r in rr}
                same = [r for r in page_rows if r['route'] == route and r['arm'] == 'whole' and r['page'] in ids
                        and g in r['groups'].split(';')]
                rows.append({'group': g, 'route': route, 'arm': arm, **score_rows(rr, S),
                             'whole_nes_same': round(S.aggregate(same)['nes'], 4) if same else ''})
    gpu = gpu_hours(runs)
    a.out.mkdir(parents=True, exist_ok=True)
    S.write_csv(a.out / f'{a.name}.csv', rows, ['group', 'route', 'arm', 'n', 'ok', 'nes', 'nes_answered', 'chrf',
                                                'order_edit', 'order_pages', 'crops', 'crops_failed', 'whole_nes_same',
                                                'prompt_tokens', 'completion_tokens'])
    S.write_csv(a.out / f'{a.name}-pages.csv', [{k: round(v, 6) if isinstance(v, float) else v for k, v in r.items()}
                                                for r in page_rows],
                ['set', 'groups', 'route', 'arm', 'page', 'ok', 'nes', 'chrf', 'words', 'missed', 'added', 'order_edit',
                 'crops', 'crops_failed', 'prompt_tokens', 'completion_tokens'])
    (a.out / f'{a.name}-tables.md').write_text(tables(rows, gpu))
    (a.out / f'{a.name}.json').write_text(json.dumps({
        'report': f'bench-corpus/{a.name}.md', 'rows': rows, 'gpu_hours': gpu,
        'pages': len(pages), 'scored_pages': len(page_rows) // (len(C.READERS) * (1 + len(C.ARMS))),
        'arms': list(C.ARMS), 'readers': list(C.READERS), 'table_markup': markup_summary(table_markup),
    }, indent=2) + '\n')
    print(f'{len(rows)} rows, {len(page_rows)} page rows -> {a.out}')


def gpu_hours(runs: Path) -> dict:
    """GPU-hours each route's read jobs spent (one GPU a job; the pilot is GLM-OCR's), from their summaries."""
    out = {}
    for f in (runs / 'out').glob('*/summary-*.json'):
        s = json.loads(f.read_text())
        out[s['route']] = out.get(s['route'], 0) + s['wall_s'] / 3600
    return {k: round(v, 2) for k, v in out.items()}


GROUP_ORDER = ('L9', 'L4', 'L3', 'L1', 'the 96', *KINDS)


def tables(rows: list[dict], gpu: dict) -> str:
    """One table a group: each reader's NES % by arm (answered / pages), the arm's change on whole page, and the
    reading-order edit (OmniDocBench's, over matched blocks; lower is better)."""
    by = {(r['group'], r['route'], r['arm']): r for r in rows}
    arms = ('whole', *C.ARMS)
    out = ['NES % (pages answered / pages); a failed page scores 0. Δ is the arm against whole page on the same pages, in points.',
           'Order: mean reading-order edit (matched-page count) over pages with two or more matched truth blocks;',
           'lower is better, but each arm has its own matched-page subset, so these means are not paired.',
           'not scorable on the 96, whose truth is kept as one line with no paragraph breaks.', '']
    for g in [g for g in GROUP_ORDER if any(k[0] == g for k in by)]:
        out += [f'### {g}', '', '| reader | ' + ' | '.join(arms) + ' | ' + ' | '.join(f'Δ {a}' for a in C.ARMS) +
                ' | order: ' + ' / '.join(arms) + ' |', '|---|' + '---:|' * (2 * len(arms))]
        for route in C.READERS:
            rs = [by.get((g, route, arm)) for arm in arms]
            if not any(rs):
                continue
            cell = lambda r: '–' if r is None else f"{100 * r['nes']:.1f} ({r['ok']}/{r['n']})"
            delta = lambda r: '–' if r is None or r['whole_nes_same'] == '' else \
                f"{100 * (r['nes'] - r['whole_nes_same']):+.1f}"
            order = ' / '.join('–' if r is None or r['order_edit'] == '' else
                               f"{r['order_edit']:.2f} ({r['order_pages']})" for r in rs)
            out.append(f'| {route} | ' + ' | '.join(cell(r) for r in rs) + ' | ' +
                       ' | '.join(delta(r) for r in rs[1:]) + f' | {order} |')
        out.append('')
    if gpu:
        out += ['GPU-hours spent reading crops (all three arms, the 354 pages): ' +
                ', '.join(f'{k} {v}' for k, v in sorted(gpu.items())), '']
    return '\n'.join(out)


def cmd_prepare(a):
    from PIL import Image
    import layout
    Image.MAX_IMAGE_PIXELS = None
    a.out.mkdir(parents=True, exist_ok=True)
    dest = a.out / 'regions' / 'pp-doclayoutv3.json'
    store = json.loads(dest.read_text()) if dest.exists() else {'detector': DETECTOR, 'pages': {}}
    pages = mac_pages()
    todo = [p for p in pages if p[0] not in store['pages']]
    model = layout.load_model() if todo else None
    t0 = time.time()
    for n, (pid, _set, _stratum, path) in enumerate(todo, 1):
        im = Image.open(path)
        im.draft('RGB', (1024, 1024))
        store['pages'][pid] = boxes_pp(model.detect(im.convert('RGB')))
        if n % 50 == 0 or n == len(todo):
            dest.parent.mkdir(parents=True, exist_ok=True)
            tmp = dest.with_suffix('.part'); tmp.write_text(json.dumps(store)); tmp.replace(dest)
            print(f'{n}/{len(todo)} pages, {(time.time() - t0) / n:.2f} s a page', flush=True)
    print(len(pages), 'pages with regions ->', dest)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('prepare'); p.add_argument('--out', type=Path, required=True)
    r = sub.add_parser('report'); r.add_argument('--runs', type=Path, required=True, help='the run folder brought back')
    r.add_argument('--out', type=Path, required=True); r.add_argument('--name', default='regions-20261021')
    a = ap.parse_args()
    {'prepare': cmd_prepare, 'report': cmd_report}[a.cmd](a)


if __name__ == '__main__':
    main()
