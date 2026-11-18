#!/usr/bin/env python3
"""W46.newspaper-photo-truth: a small word-level truth set of photographed newspaper pages from the owner's corpus.

Owner review of the pipeline doc, 2026-11-17: no photographed newspaper with truth exists (L9 is 15 scans), so the
staged route on photographed newspapers (W46.layout-photo-newspapers: the quad correction, then a layout detector)
has nothing to be scored on. This draws the pages, screens them, drafts their truth through the gateway and builds
the owner's sheet of disputes. The drafting, comparing, sheet and fold are owner_set_grow.py's, run on this item's
cache (its OUT is pointed here), so the two truth sets are made the same way.

  python3 newspaper_photo_truth.py pool                 # Clippings-tagged corpus PDFs (getxattr, read only) -> cache
  heavy-run.py run -- /usr/local/bin/python3 newspaper_photo_truth.py draw    # CANDIDATES pages, JPEG originals
  heavy-run.py run -- /usr/local/bin/python3 newspaper_photo_truth.py vision  # Vision word boxes, four-turn scores,
                                                        # and Vision OCR's page sorter on each prepared image
  python3 newspaper_photo_truth.py size                 # the owner's minutes, estimated before any draft ($0)
  python3 newspaper_photo_truth.py screen               # one short gateway question a page: newspaper or not (paid)
  python3 newspaper_photo_truth.py select               # the set: the first TARGET pages screened newspaper
  python3 newspaper_photo_truth.py draft --drafter NAME # owner_set_grow's blind truth draft, on the set (paid, CAP)
  python3 newspaper_photo_truth.py compare | sheet | fold ANSWERS.json | report

THE DRAW RULE, written before the draw ran (seed SEED):
  * Pool: every corpus PDF carrying the Finder tag "Clippings", outside the numbered workflow folders (as
    ocr_truth's pool), not tagged Red or Purple (box and folder label photos). The tag is the owner's, so no tested
    route chose the pool. Not all clippings are newspapers (magazines, newsletters, press releases are tagged too),
    hence the screen.
  * Order: sha256(SALT + the PDF's corpus path), ascending. Walking that order, a PDF is taken unless its folder
    already gave FOLDER_MAX or its collection (the top-level folder) COLLECTION_MAX; CANDIDATES are prepared.
  * Images: ocr_truth.prepare, with the JPEG-originals rule (the original by exact name, else its pairs.tsv JPEG at
    MIN_CORR, else the PDF's image; each row says which).
  * Screen: Gemini 3.7 Flash through the gateway answers SCREEN_PROMPT (newspaper, magazine or other; columns) on the
    upright page. A page is in the set when the answer is NEWSPAPER; the set is the first TARGET such pages in the
    hashed order. The screener is a kind judgement, not a reading, and the measurement card names it; the owner's
    sheet lists the screen's answer on every page, and a note can drop a page that is not a newspaper.
  * Vision OCR's page sorter (vision_kind/run.sh) is run on every candidate and recorded beside the screen, so its
    newspaper call can be checked against it. It does not select.

THE TRUTH: owner_set_grow's (two blind gateway drafters of different families; every disputed span and CONTROLS
agreed spans go to the owner, boxed from Apple Vision's word positions). A drafter that a later item scores is
scored there only on owner-ruled spans.

Reads the corpus read only; writes the bench cache (OUT). The committed result, segbench-results/newspaper-photo-
truth.md, is counts only: the repo is public and the pages are the owner's.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import ocr_truth as T                      # noqa: E402
import owner_set_grow as G                 # noqa: E402

REH = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
OUT = Path(os.environ.get('NEWSPAPER_PHOTO_TRUTH_CACHE', REH / 'newspaper-photo-truth'))
G.OUT = OUT                                # owner_set_grow's drafting, compare, sheet and fold run on this cache
RESULTS = HERE.parents[1] / 'segbench-results' / 'newspaper-photo-truth.md'
VISION_KIND = HERE / 'vision_kind' / 'run.sh'
SALT = 'W46.newspaper-photo-truth'
SEED = 20261118
FOLDER_MAX, COLLECTION_MAX = 3, 8
CANDIDATES = 60
TARGET = 20                                # L9's size (15) and some; the owner's minutes decide the final count
SCREENER = 'gemini-3.7-flash'
G.CAP = CAP = 3.00                         # the item's gateway total, screen and both drafters, under the $7 rule
SCREEN_PROMPT = """This is a photograph of one page or clipping from a US archive.
Answer in exactly two lines:
SOURCE: NEWSPAPER, MAGAZINE or OTHER (NEWSPAPER: printed newsprint, a newspaper page or a clipping cut from one; MAGAZINE: a magazine or journal page; OTHER: anything else, such as a letter, report, newsletter, press release or typed copy of an article)
COLUMNS: the number of text columns on the page (a whole number)"""
SKIP_TAGS = {'Red', 'Purple'}


def sh256(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def collection(path: str) -> str:
    return path.split('/', 1)[0]


# ---------------------------------------------------------------- the pool and the draw (pure parts first)

def hashed_order(paths: list[str]) -> list[str]:
    return sorted(paths, key=lambda p: sh256(SALT + p))


def capped(order, folder_max=FOLDER_MAX, collection_max=COLLECTION_MAX):
    """Yield paths in order, skipping one whose folder or collection is already at its cap (the cap counts taken
    paths; the caller stops when it has enough, and tells the generator a path failed with .send(False))."""
    nf, nc = collections.Counter(), collections.Counter()
    for p in order:
        f, c = os.path.dirname(p), collection(p)
        if nf[f] >= folder_max or nc[c] >= collection_max:
            continue
        ok = yield p
        if ok is not False:
            nf[f] += 1
            nc[c] += 1


def cmd_pool(_):
    import corpus_survey as CS
    paths = []
    for coll in T.collection_folders():
        for rel, pdfs in CS.walk(str(T.CORPUS / coll)):
            rel = coll if rel == '.' else os.path.join(coll, rel)
            for p in pdfs:
                tags = CS.read_tags(str(T.CORPUS / rel / p))
                if 'Clippings' in tags and not SKIP_TAGS & set(tags):
                    paths.append({'path': f'{rel}/{p}', 'tags': tags})
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'pool.jsonl').write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in paths))
    by = collections.Counter(collection(r['path']) for r in paths)
    print(len(paths), 'Clippings PDFs in', len(by), 'collections,', len({os.path.dirname(r['path']) for r in paths}),
          'folders')


def cmd_draw(_):
    if (OUT / 'pages.jsonl').exists():
        raise SystemExit(f'{OUT / "pages.jsonl"} exists: the draw is made once')
    pool = {r['path']: r['tags'] for r in G.load_jsonl(OUT / 'pool.jsonl')}
    idx = T.load_index()
    truth_cache, T.CACHE = T.CACHE, OUT          # ocr_truth.prepare writes under OUT/prep
    rows, failed = [], []
    gen = capped(hashed_order(list(pool)))
    ok = None
    try:
        while len(rows) < CANDIDATES:
            p = gen.send(ok) if ok is not None else next(gen)
            folder, name = os.path.split(p)
            rec = T.prepare(folder, name, pool[p], idx['originals'])
            ok = 'error' not in rec
            if not ok:
                failed.append({'path': p, 'error': rec['error'][:200]})
                continue
            rows.append({'id': f'n{len(rows) + 1:03d}', 'set': 'news', 'key': rec['key'], 'folder': folder,
                         'name': name, 'tags': pool[p], 'source': rec['source'],
                         'source_method': rec.get('source_method'), 'pair_rejected': rec.get('pair_rejected'),
                         'vision_words': rec['words'], 'order': len(rows) + len(failed)})
            print(len(rows), rec['source'], rec['words'], 'words', flush=True)
    except StopIteration:
        pass
    T.CACHE = truth_cache
    (OUT / 'candidates.jsonl').write_text(''.join(json.dumps(r, ensure_ascii=False) + '\n' for r in rows))
    (OUT / 'draw.json').write_text(json.dumps({
        'salt': SALT, 'seed': SEED, 'pool': len(pool), 'candidates': len(rows), 'failed': failed,
        'folder_max': FOLDER_MAX, 'collection_max': COLLECTION_MAX,
        'collections': collections.Counter(collection(r['folder']) for r in rows),
        'sources': collections.Counter(r['source'].split(' (')[0] for r in rows)}, indent=1))
    # owner_set_grow's vision step reads pages.jsonl: the candidates stand in until `select` writes the set
    (OUT / 'pages.jsonl').write_text((OUT / 'candidates.jsonl').read_text())
    print(len(rows), 'candidates,', len(failed), 'not readable')


def candidates() -> list[dict]:
    return G.load_jsonl(OUT / 'candidates.jsonl')


def cmd_vision(a):
    G.cmd_vision(a)
    rows = candidates()
    lst = OUT / 'sorter-list.tsv'
    lst.write_text(''.join(f"{r['id']}\t{G.image(r)}\n" for r in rows))
    out = subprocess.run(['bash', str(VISION_KIND), str(lst)], capture_output=True, text=True)
    if out.returncode:
        raise SystemExit(f'vision_kind: rc {out.returncode}\n{out.stderr[-1500:]}')
    (OUT / 'sorter.tsv').write_text(out.stdout)
    kinds = collections.Counter(line.split('\t')[1] for line in out.stdout.splitlines()[1:] if '\t' in line)
    print('sorter:', dict(kinds), out.stderr.strip().splitlines()[0] if out.stderr.strip() else '')


def sorter() -> dict[str, str]:
    f = OUT / 'sorter.tsv'
    if not f.exists():
        return {}
    return {x[0]: x[1] for x in (l.split('\t') for l in f.read_text().splitlines()[1:]) if len(x) > 1}


# ---------------------------------------------------------------- sizing the owner's time before any draft

def dispute_rate(rows: list[dict], kind: str | None = None) -> float:
    """Disputed spans a 1,000 words between two drafters, over ocr_truth compare.json rows (both drafters' kind
    `kind` when given): the prior for `size`. Words are the mean of the two drafts'."""
    n_disp = n_words = 0
    for p in rows:
        if kind and set(p['kind'].values()) != {kind}:
            continue
        n_disp += p['n_disputes']
        n_words += sum(p['words'].values()) / len(p['words'])
    if not n_words:
        raise SystemExit('no compare rows to count')
    return 1000 * n_disp / n_words


def estimate(words: list[int], rate: float, controls: int = G.CONTROLS) -> dict:
    disputes = round(sum(words) * rate / 1000)
    return {'pages': len(words), 'words': sum(words), 'disputes': disputes,
            'minutes': round(G.owner_minutes(len(words), disputes, controls, 0))}


def cmd_size(_):
    rows = candidates()
    cmp96 = json.loads((T.CACHE / 'compare.json').read_text())
    rate, printed = dispute_rate(cmp96), dispute_rate(cmp96, 'printed')
    words = sorted(r['vision_words'] for r in rows)
    per = sum(words) / len(words)
    out = {'disputes_per_kword_96': round(rate, 1), 'disputes_per_kword_96_printed': round(printed, 1),
           'vision_words_median': words[len(words) // 2], 'vision_words_mean': round(per),
           'at_printed_rate': {n: estimate([round(per)] * n, printed) for n in (10, 15, 20, 30)},
           'at_all_rate': {n: estimate([round(per)] * n, rate) for n in (10, 15, 20, 30)}}
    (OUT / 'size.json').write_text(json.dumps(out, indent=1))
    print(json.dumps(out, indent=1))


# ---------------------------------------------------------------- the screen (gateway) and the set

def parse_screen(raw: str | None):
    if not raw:
        return None
    s = re.search(r'^[\s*_#]*SOURCE[\s*_]*:[\s*_]*(NEWSPAPER|MAGAZINE|OTHER)\b', raw, re.M | re.I)
    c = re.search(r'^[\s*_#]*COLUMNS[\s*_]*:[\s*_]*(\d+)', raw, re.M | re.I)
    return {'source': s.group(1).upper(), 'columns': int(c.group(1)) if c else None} if s else None


def screen_path(r) -> Path:
    return OUT / 'screen' / f"{r['id']}.json"


def screened(r):
    d = screen_path(r)
    return parse_screen(json.loads(d.read_text()).get('raw')) if d.exists() else None


def cmd_screen(a):
    GW = G.gateway(SCREENER)
    rows = candidates()[:a.limit] if a.limit else candidates()
    GW.run('screen', [(r['id'], G.draft_image_bytes(r), screen_path(r)) for r in rows], SCREEN_PROMPT,
           concurrency=a.concurrency)
    got = collections.Counter((screened(r) or {}).get('source', 'unparsed') for r in rows)
    print(dict(got), f'${GW.spent():.4f} spent in all')


def choose(rows: list[dict], screens: dict, target: int = TARGET) -> list[dict]:
    """The first `target` rows in draw order whose screen says NEWSPAPER (rows keep their ids)."""
    return [r for r in sorted(rows, key=lambda r: r['order'])
            if (screens.get(r['id']) or {}).get('source') == 'NEWSPAPER'][:target]


def cmd_select(_):
    rows = candidates()
    screens = {r['id']: screened(r) for r in rows}
    if any(v is None for v in screens.values()):
        raise SystemExit(f"{sum(v is None for v in screens.values())} candidates are not screened yet")
    chosen = choose(rows, screens)
    (OUT / 'pages.jsonl').write_text(''.join(json.dumps({**r, 'screen': screens[r['id']]}, ensure_ascii=False)
                                             + '\n' for r in chosen))
    print(len(chosen), 'pages in the set of', len(rows), 'candidates;',
          dict(collections.Counter(v['source'] for v in screens.values())))


# ---------------------------------------------------------------- the sheet: owner_set_grow's, with this set's fields

def cmd_sheet(a):
    base_build, kinds = G.build, sorter()

    def build(cmp, rows, turns, vision):
        items, key = base_build(cmp, rows, turns, vision)
        by_id = {r['id']: r for r in rows}
        for it in items:
            r = by_id[it['page']]
            s = r.get('screen') or {}
            it['fields'] += [('screened as', f"{s.get('source', '?').lower()}, {s.get('columns', '?')} columns "
                                             f"(Gemini 3.7 Flash; a note can drop a page that is not a newspaper)"),
                             ('Vision OCR sorter', kinds.get(r['id'], 'not run'))]
        key['build'] = hashlib.sha256(json.dumps(items, sort_keys=True).encode()).hexdigest()[:12]
        return items, key

    G.build = build
    try:
        G.cmd_sheet(a)
    finally:
        G.build = base_build
    f = OUT / 'sheet' / 'index.html'
    f.write_text(f.read_text().replace('W46 owner set: disputed words', 'W46 photographed newspapers: disputed words'))


# ---------------------------------------------------------------- the committed result: counts only

def _json(name):
    f = OUT / name
    return json.loads(f.read_text()) if f.exists() else None


def report_lines() -> list[str]:
    """segbench-results/newspaper-photo-truth.md from what the cache holds now. Counts only: no path, name, folder
    or collection (the repo is public and the pages are the owner's). A step not run yet is left out or says so."""
    d, size, cmp, rul = _json('draw.json'), _json('size.json'), _json('compare.json'), _json('rulings.json')
    cands = candidates()
    kinds = sorter()
    screens = {r['id']: screened(r) for r in cands}
    chosen = [r for r in G.load_pages() if 'screen' in r]      # before `select`, pages.jsonl holds the candidates
    words = sorted(r['vision_words'] for r in cands)
    src = collections.Counter(r['source'].split(' (')[0] for r in cands)
    L = ['# W46.newspaper-photo-truth: a small truth set of photographed newspapers', '',
         'Owner review of the pipeline doc, 2026-11-17: no photographed newspaper with truth exists (L9 is 15 scans), '
         'so the staged route on photographed newspapers (W46.layout-photo-newspapers) has nothing to be scored on. '
         'Built by `scripts/segbench/newspaper_photo_truth.py`, which runs `owner_set_grow.py`\'s drafting, sheet and '
         'fold; images, drafts and the sheet stay in the bench cache, since the pages are the owner\'s.', '',
         '## The draw', '',
         f"- Pool: {d['pool']:,} corpus PDFs carrying the owner's Finder tag Clippings, outside the numbered workflow "
         'folders and not tagged Red or Purple.',
         f"- Order: sha256 of a fixed salt and the corpus path; at most {d['folder_max']} a folder and "
         f"{d['collection_max']} a collection. {d['candidates']} candidates from {len(d['collections'])} collections; "
         f"{len(d['failed'])} passed over as unreadable. Images: " + ', '.join(f'{n} {k}' for k, n in src.most_common())
         + '.',
         f"- Apple Vision words a candidate: median {words[len(words) // 2]}, range {words[0]:,}-{words[-1]:,}."]
    if kinds:
        L.append("- Vision OCR's page sorter (recorded, does not select): " + ', '.join(
            f'{n} {k}' for k, n in collections.Counter(kinds.get(r['id'], 'not run') for r in cands).most_common()) + '.')
    if size:
        p20, a20 = size['at_printed_rate'][str(TARGET)], size['at_all_rate'][str(TARGET)]
        L += ['', '## The owner\'s time, sized before any draft', '',
              f"At the 96's dispute rate between two drafters ({size['disputes_per_kword_96_printed']} disputed spans a "
              f"1,000 words on printed pages, {size['disputes_per_kword_96']} on all) and the candidates' mean of "
              f"{size['vision_words_mean']} Vision words, {TARGET} pages are about {p20['disputes']}-{a20['disputes']} "
              f"disputes and {p20['minutes']}-{a20['minutes']} owner minutes with {G.CONTROLS} controls. An estimate, "
              're-sized from the drafts before the sheet is offered.']
    if any(screens.values()):
        got = collections.Counter((v or {}).get('source', 'not screened') for v in screens.values())
        L += ['', '## The screen and the set', '',
              f"{SCREENER} through the gateway, on the upright page: " + ', '.join(
                  f'{n} {k.lower()}' for k, n in got.most_common()) + '.']
        if chosen:
            cols = collections.Counter((r['screen'] or {}).get('columns') for r in chosen)
            agree = sum(1 for r in chosen if kinds.get(r['id']) == 'newspaper')
            L.append(f"The set: the first {len(chosen)} screened newspaper in the hashed order (target {TARGET}). "
                     'Columns by the screen: ' + ', '.join(f'{k}: {n}' for k, n in sorted(cols.items(), key=str)) +
                     f". Vision OCR's sorter calls {agree} of them newspaper.")
    if cmp:
        s = G.summary(chosen or cands, cmp['pages'], cmp['missing'])
        L += ['', '## The drafts and the sheet', '',
              f"Drafters, blind: {cmp['a']} and {cmp['b']}, through the gateway. {s['pages']} pages drafted by both "
              f"({s['missing']} missing). {s['words']:,} words; {s['disputes']:,} disputed spans covering "
              f"{s['disputed_words']:,} words; {s['pages_without_dispute']} pages with none; {s['controls']} agreed "
              f"controls. Estimated owner time: about {s['owner_minutes']} minutes."]
    if rul:
        tot = collections.Counter()
        for r in rul['pages'].values():
            tot.update(r['counts'])
        kept = [r for r in rul['pages'].values() if r['status'] == 'settled' and not r['drop']]
        drops = collections.Counter(r['drop'] for r in rul['pages'].values() if r['drop'])
        L += ['', '## The owner\'s rulings', '', f"{len(kept)} pages settled and kept; dropped: " +
              (', '.join(f'{n} {k}' for k, n in drops.items()) or 'none') + '. ' +
              ', '.join(f'{k} {n}' for k, n in sorted(tot.items())) + '.']
    L += ['', '## Measurement card', '',
          '- **Truth:** ' + ('two gateway drafters of different families, blind; every disputed span and the controls '
                              'ruled by the owner on a blind sheet boxed from Apple Vision\'s word positions.' if rul else
                              'not made yet: the screen, the drafts and the owner\'s sheet are pending.'),
          '- **Selection:** the owner\'s Clippings tag and a salted hash order, capped by folder and collection; no '
          f'tested route and no ABBYY text chose a page. The newspaper screen is a kind judgement by {SCREENER}, not a '
          'reading; the sheet lists its answer and the owner can drop a page in a note.',
          '- **Comparison:** a route scored on this set is scored with the same scorer and settings as the 96 '
          '(`ocr_panel_score`) and reported beside them, never pooled. A drafter is scored only on owner-ruled spans.',
          f'- **Noise:** about {TARGET} pages: enough to see a route fail on newsprint columns, not to separate two '
          'close routes; a gap inside the paired interval is a tie.',
          '- **Scope:** photographed clippings in the owner\'s collections; not scans (L9 covers 15), and microfilm '
          'prints only as far as the draw took them.', '']
    return L


def cmd_report(_):
    RESULTS.write_text('\n'.join(report_lines()))
    print(RESULTS)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    for name, fn in (('pool', cmd_pool), ('draw', cmd_draw), ('vision', cmd_vision), ('size', cmd_size),
                     ('select', cmd_select), ('compare', G.cmd_compare), ('sheet', cmd_sheet),
                     ('models', G.cmd_models), ('report', cmd_report)):
        sub.add_parser(name).set_defaults(fn=fn)
    s = sub.add_parser('screen')
    s.add_argument('--limit', type=int)
    s.add_argument('--concurrency', type=int, default=4)
    s.set_defaults(fn=cmd_screen)
    d = sub.add_parser('draft')
    d.add_argument('--drafter', required=True, choices=sorted(G.DRAFTERS))
    d.add_argument('--limit', type=int)
    d.add_argument('--concurrency', type=int, default=4)
    d.set_defaults(fn=G.cmd_draft)
    f = sub.add_parser('fold')
    f.add_argument('answers')
    f.set_defaults(fn=G.cmd_fold)
    a = ap.parse_args()
    a.fn(a)


if __name__ == '__main__':
    main()
