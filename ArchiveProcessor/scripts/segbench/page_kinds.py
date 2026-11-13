#!/usr/bin/env python3
"""W42.int-s3. The app's one list of page kinds (OCR/PageKinds.swift), measured per kind as the app calls them.

  page_kinds.py list                      # CACHE/owner.tsv and CACHE/newspaper.tsv: the pages and their truth
  heavy-run.py run -- page_kinds.py run [OUT]  # the app's measure (OCRPageKindTestDriver §11) -> calls-*.tsv
  page_kinds.py report                    # -> segbench-results/page-kinds.md and .json
  page_kinds.py pin CALLS_OWNER CALLS_NEWS  # exit 1 when a fresh run gets fewer pages right per kind than the json

Two truth sets. The owner's labelled pages: kind_classifier.py's 144 originals (its ladder copies left out), hand
and form as its labels.tsv holds them (KND-1: partly a session's, and the bundled weights were fitted on them, so
this is the app's in-sample call; the held-out figure stays kind-atrium.md §1's 137/141). Vision OCR's newspaper
truth pages: PAGE-KIND-2026-10-12.tsv (ocr-newspaper-detect), 67 sample pages and 85 others, labelled newspaper or
other, a newspaper as a whole page or a clipping. The app is run on each page as it reads a page: an image file
with its camera tags and Finder tags, a PDF page rendered as the run renders it (PDFToImageConverter). Where the
truth set records the original photograph's Finder tags (ocr-truth pages.tsv) they are passed in place of the
cached copy's missing ones, and the call is also scored with no tags.

Reads the documents and images where they are (the Zotero library, the private caches); writes only CACHE and the
report. The repo is public: the report holds aggregates and page ids only. No money: Apple Vision on this Mac.
"""
from __future__ import annotations
import csv
import json
import os
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP_DIR = HERE.parents[1]
RESULTS = APP_DIR / 'segbench-results'
REHEARSAL = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
CACHE = Path(os.environ.get('PAGE_KINDS_CACHE', REHEARSAL / 'page-kinds'))
LABELS = REHEARSAL / 'kind-classifier/labels.tsv'
TRUTH_PAGES = REHEARSAL / 'ocr-truth/pages.tsv'
VOCR = Path.home() / 'Claude/vision-ocr'
NEWS_TRUTH = VOCR / 'PAGE-KIND-2026-10-12.tsv'
MANIFEST = VOCR / 'testdocs/manifest.tsv'
ZOTERO = Path.home() / 'Zotero/storage'
NEWSBENCH = [Path.home() / 'Claude/Long term storage/FarmShare-20261019/ocr/images']
OWNER_SUPPLIED = Path.home() / '.local/state/visionocr-autonomous/owner-supplied'
APP = APP_DIR / 'macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor'
KINDS = ['handwritten', 'typewritten', 'printed', 'forms', 'newspapers', 'clippings', 'registers', 'mixed']
# PageKindName.routingKind: the model guide's kind whose pick reads each kind.
ROUTING = {'handwritten': 'handwritten', 'typewritten': 'typewritten', 'printed': 'printed', 'forms': 'forms',
           'newspapers': 'printed', 'clippings': 'printed', 'registers': 'forms', 'mixed': 'handwritten'}


def read_tsv(path):
    with open(path, newline='', encoding='utf-8') as f:
        return list(csv.DictReader((l for l in f if not l.startswith('#')), delimiter='\t'))


def write_rows(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write('# id\tfile\tpage\ttags\ttruth\tset\n')
        for r in rows:
            f.write('\t'.join([r['id'], r['file'], str(r['page']), r.get('tags', ''), r['truth'], r['set']]) + '\n')


def owner_rows():
    tags = {r['page']: r.get('tags', '') for r in read_tsv(TRUTH_PAGES)}
    out = []
    for r in read_tsv(LABELS):
        if r['set'].startswith('ladder'):
            continue
        truth = 'forms' if r['form'] == 'yes' else r['hand']
        # Only the truth set records its originals' tags; the cached copies carry none. The held-out hand pages are
        # read where they are, so the app reads their own tags; the drawn pages were drawn by a tag and get none.
        t = tags.get(r['id'], '') if r['set'] == 'truth' else ''
        out.append({'id': r['id'], 'file': r['file'], 'page': 1, 'tags': t, 'truth': truth, 'set': r['set']})
    return out


def zotero_index():
    by_name = defaultdict(list)
    if ZOTERO.is_dir():
        for key in ZOTERO.iterdir():
            if key.is_dir():
                for f in key.iterdir():
                    if f.suffix.lower() == '.pdf':
                        by_name[f.name].append(f)
    return by_name


def resolve(document, keys, by_name):
    """The document's file: Vision OCR's sample by its Zotero key, else by name in the library or the other folders."""
    kind, _, name = document.partition('/')
    if kind == 'newsbench':
        for root in NEWSBENCH:
            p = root / f'newsbench__{name}'
            if p.exists():
                return p
        return None
    if document in keys:
        d = ZOTERO / keys[document]
        hits = [f for f in d.glob('*.pdf')] if d.is_dir() else []
        exact = [f for f in hits if f.name == name]
        if exact or len(hits) == 1:
            return (exact or hits)[0]
    if kind == 'owner':
        p = OWNER_SUPPLIED / name
        if p.exists():
            return p
    hits = by_name.get(name, [])
    if len(hits) >= 1:
        return sorted(hits)[0]
    # A name the library shortened or extended (". . ." in a title): the one file whose name starts the same.
    stem = Path(name).stem
    near = [f for n, fs in by_name.items() if n.startswith(stem[:40]) for f in fs]
    return near[0] if len({f.name for f in near}) == 1 else None


def newspaper_rows():
    keys = {r['file']: r['zotero_key'] for r in read_tsv(MANIFEST)} if MANIFEST.exists() else {}
    by_name = zotero_index()
    out, missing = [], []
    for r in read_tsv(NEWS_TRUTH):
        p = resolve(r['document'], keys, by_name)
        if p is None:
            missing.append(r['id'])
            continue
        # A whole newspaper page is the newspaper kind; a clipping is print (one article in two to four wide columns,
        # which is what the rule reads it as) unless a tag says clipping; the rest are not newspapers.
        truth = 'newspapers' if r['label'] == 'newspaper' and r['layout'] == 'page' else \
            ('clippings' if r['label'] == 'newspaper' else 'other')
        out.append({'id': r['id'], 'file': str(p), 'page': int(r['page']), 'truth': truth, 'set': r['set']})
    return out, missing


def cmd_list():
    owner = owner_rows()
    news, missing = newspaper_rows()
    write_rows(CACHE / 'owner.tsv', owner)
    write_rows(CACHE / 'newspaper.tsv', news)
    (CACHE / 'newspaper-missing.txt').write_text('\n'.join(missing) + '\n')
    print(f'owner {len(owner)} pages; newspaper {len(news)} pages, {len(missing)} not found: {" ".join(missing)}')


def run_app(list_path, out_path):
    with tempfile.TemporaryDirectory() as work:
        report = Path(work) / 'result.txt'
        env = dict(os.environ, ARCHIVEPROC_HEADLESS='1', ARCHIVEPROC_TEST_BACKUP_ROOT=f'{work}/backup',
                   OCRPAGEKIND_TEST='1', OCRPAGEKIND_TEST_OUT=str(report),
                   OCRPAGEKIND_KINDS_LIST=str(list_path), OCRPAGEKIND_KINDS_OUT=str(out_path))
        subprocess.run([str(APP)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3600)
        text = report.read_text() if report.exists() else ''
        if not text.startswith('ALL PASS'):
            sys.exit(f'the app\'s page-kind driver did not pass:\n{text[:2000]}')


def cmd_run(out=CACHE):
    if not APP.exists():
        sys.exit('ArchiveProcessor is not built')
    for name in ('owner', 'newspaper'):
        run_app(CACHE / f'{name}.tsv', out / f'calls-{name}.tsv')
        print(f'{name}: {sum(1 for _ in open(out / f"calls-{name}.tsv"))} pages called')


CALL_COLS = ['id', 'call', 'source', 'confidence', 'classifier', 'lines', 'wideW', 'photographed', 'untagged',
             'seconds', 'engine_newspaper']


def calls(path):
    out = {}
    for line in open(path, encoding='utf-8'):
        f = line.rstrip('\n').split('\t')
        if f and f[0]:
            out[f[0]] = dict(zip(CALL_COLS, f)) if len(f) > 2 else {'id': f[0], 'call': 'unread'}
    return out


def truth_rows(path):
    rows = []
    for line in open(path, encoding='utf-8'):
        if line.startswith('#'):
            continue
        f = line.rstrip('\n').split('\t')
        rows.append({'id': f[0], 'tags': f[3], 'truth': f[4], 'set': f[5]})
    return rows


def score_owner(truth, got):
    """Per true kind: pages, right with the file's tags, right with none, and what the wrong ones were called."""
    per = {}
    for k in ['handwritten', 'typewritten', 'printed', 'forms', 'mixed']:
        rows = [r for r in truth if r['truth'] == k]
        if not rows:
            continue
        # A mixed page has no class: the rule counts it right when it goes to the handwritten pick (a mixed call, a
        # handwritten one), as routing reads it (kind-classifier.md §1).
        ok = {'mixed': {'mixed', 'handwritten'}}.get(k, {k})
        with_tags = Counter(got.get(r['id'], {}).get('call', 'missing') for r in rows)
        untagged = Counter(got.get(r['id'], {}).get('untagged', 'missing') for r in rows)
        # Routed right: the call's pick is the true kind's (a clipping call on a printed page reaches print's pick).
        routes = lambda c: sum(v for kk, v in c.items() if ROUTING.get(kk) == ROUTING[k])
        per[k] = {'n': len(rows), 'right': sum(with_tags[c] for c in ok), 'right_untagged': sum(untagged[c] for c in ok),
                  'routed': routes(with_tags), 'routed_untagged': routes(untagged),
                  'calls': dict(with_tags.most_common())}
    tagged = [r for r in truth if r['tags'] and any(t in r['tags'].split('; ') for t in
                                                    ('Handwritten', 'Clippings', 'Statistics'))]
    sources = Counter(got.get(r['id'], {}).get('source', '-') for r in truth)
    photographed = sum(1 for r in truth if got.get(r['id'], {}).get('photographed') == '1')
    newspaper_false = sum(1 for r in truth if got.get(r['id'], {}).get('call') == 'newspapers')
    changed = Counter((r['truth'], got.get(r['id'], {}).get('call')) for r in truth
                      if got.get(r['id'], {}).get('source') == 'finder_tag'
                      and got.get(r['id'], {}).get('call') != got.get(r['id'], {}).get('untagged'))
    secs = sorted(float(g['seconds']) for g in got.values() if g.get('seconds'))
    return {'per_kind': per, 'n': len(truth), 'tagged_pages': len(tagged), 'sources': dict(sources),
            'photographed': photographed, 'newspaper_calls': newspaper_false,
            'tag_changed': {f'{a} -> {b}': v for (a, b), v in changed.most_common()},
            'engine_newspaper': sum(1 for r in truth if got.get(r['id'], {}).get('engine_newspaper') == '1'),
            'read_seconds_median': secs[len(secs) // 2] if secs else None,
            'unread': sum(1 for r in truth if got.get(r['id'], {}).get('call') in (None, 'unread', 'unknown'))}


# A page the app did not read or could not tell is never right, whatever its truth.
NOT_READ = ('missing', 'unread', 'unknown')


def score_news(truth, got):
    per = {}
    for k in ['newspapers', 'clippings', 'other']:
        rows = [r for r in truth if r['truth'] == k]
        c = Counter(got.get(r['id'], {}).get('call', 'missing') for r in rows)
        # Right: a whole page called a newspaper; a clipping or another page called anything else. The rule is not
        # meant to call a clipping a newspaper (03-layout.md: it reads as the print it is).
        right = c['newspapers'] if k == 'newspapers' else \
            sum(v for kk, v in c.items() if kk not in ('newspapers',) + NOT_READ)
        per[k] = {'n': len(rows), 'right': right, 'calls': dict(c.most_common())}
    by_set = {}
    for s in ('sample', 'outside'):
        rows = [r for r in truth if r['set'] == s]
        by_set[s] = {'n': len(rows), 'right': sum(
            1 for r in rows if got.get(r['id'], {}).get('call', 'missing') not in NOT_READ
            and (got.get(r['id'], {}).get('call') == 'newspapers') == (r['truth'] == 'newspapers'))}
    wrong = sorted(r['id'] for r in truth
                   if (got.get(r['id'], {}).get('call') == 'newspapers') != (r['truth'] == 'newspapers'))
    secs = sorted(float(g['seconds']) for g in got.values() if g.get('seconds'))
    return {'per_kind': per, 'n': len(truth), 'by_set': by_set, 'wrong': wrong,
            'read_seconds_median': secs[len(secs) // 2] if secs else None,
            'read_seconds_max': secs[-1] if secs else None,
            'photographed': sum(1 for r in truth if got.get(r['id'], {}).get('photographed') == '1')}


def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * ((p * (1 - p) / n + z * z / (4 * n * n)) ** 0.5) / d
    return (round(100 * (c - h)), round(100 * (c + h)))


def scores(owner_calls, news_calls):
    return {'owner': score_owner(truth_rows(CACHE / 'owner.tsv'), calls(owner_calls)),
            'newspaper': score_news(truth_rows(CACHE / 'newspaper.tsv'), calls(news_calls))}


def cmd_report():
    s = scores(CACHE / 'calls-owner.tsv', CACHE / 'calls-newspaper.tsv')
    missing = [l for l in (CACHE / 'newspaper-missing.txt').read_text().split() if l]
    s['newspaper']['not_found'] = missing
    s['measured'] = 'W42.int-s3, 2026-11-13, M3 Pro 18 GB, macOS 27.2'
    (RESULTS / 'page-kinds.json').write_text(json.dumps(s, indent=1, sort_keys=True) + '\n')
    o, n = s['owner'], s['newspaper']
    L = ['# Page kinds: the app\'s one list, measured per kind (W42.int-s3)', '',
         'The Processor\'s page-kind call (`OCR/PageKinds.swift`, `PageKind.detect`) on two truth sets, run through the '
         'app itself (`OCRPageKindTestDriver` §11) by `scripts/segbench/page_kinds.py`. The call puts three signals '
         'together: a Finder tag (Handwritten, Clippings, Statistics) corrects everything; then a whole newspaper '
         'page told by the shape of Vision\'s lines (VisionOCRKit\'s ocr-newspaper-detect rule); then the bundled '
         'classifier. Photographed is a second axis, from the engine\'s page-kinds-three rule. Clippings, registers '
         'and mixed pages are not detected: they come from a tag or the collection interview.', '',
         '## Owner\'s labelled pages', '',
         f'{o["n"]} pages: kind_classifier.py\'s 144 labelled originals. A form is a page labelled a form or table, '
         'whatever its hand; mixed pages count right when they reach the handwritten pick.', '',
         '| Kind | Pages | Right, with the tags | Right, no tags | Its pick, with the tags | Its pick, no tags | Called |',
         '|---|---:|---:|---:|---:|---:|---|']
    for k, v in o['per_kind'].items():
        lo, hi = wilson(v['right'], v['n'])
        L.append(f'| {k} | {v["n"]} | {v["right"]} ({lo}-{hi}%) | {v["right_untagged"]} | {v["routed"]} | '
                 f'{v["routed_untagged"]} | '
                 + ', '.join(f'{c} {m}' for c, m in v['calls'].items()) + ' |')
    tot = sum(v['right'] for v in o['per_kind'].values())
    tot_u = sum(v['right_untagged'] for v in o['per_kind'].values())
    lo, hi = wilson(tot, o['n'])
    routed = sum(v['routed'] for v in o['per_kind'].values())
    routed_u = sum(v['routed_untagged'] for v in o['per_kind'].values())
    L += ['', f'All: {tot} of {o["n"]} right with the tags ({lo}-{hi}%, Wilson), {tot_u} with none; {routed} reach their '
          f'kind\'s pick with the tags, {routed_u} with none. Pages a Finder tag decided: '
          f'{o["sources"].get("finder_tag", 0)} ({o["tagged_pages"]} by the truth set\'s record of the original\'s tags, '
          f'the rest the held-out hand pages\' own). Where a tag changed the call (label -> call): '
          + ', '.join(f'{k} {v}' for k, v in o['tag_changed'].items()) + '. '
          f'Pages called a newspaper: {o["newspaper_calls"]} (the engine\'s reading called {o["engine_newspaper"]}, '
          f'on a page the classifier did not call printed, so it was not read for it). Called photographed: '
          f'{o["photographed"]}. Unread or no kind: {o["unread"]}.', '',
          '## Vision OCR\'s newspaper truth pages', '',
          f'{n["n"]} of the 152 pages of `PAGE-KIND-2026-10-12.tsv` found on this Mac'
          + (f' ({len(missing)} not found: {", ".join(missing)})' if missing else '') + '. A whole newspaper page should be '
          'called a newspaper; a clipping (one article cut to a page) and every other page should not.', '',
          '| Truth | Pages | Right | Called |', '|---|---:|---:|---|']
    for k, v in n['per_kind'].items():
        lo, hi = wilson(v['right'], v['n'])
        L.append(f'| {k} | {v["n"]} | {v["right"]} ({lo}-{hi}%) | '
                 + ', '.join(f'{c} {m}' for c, m in v['calls'].items()) + ' |')
    L += ['', 'By set: ' + '; '.join(f'{k} {v["right"]} of {v["n"]}' for k, v in n['by_set'].items())
          + '. Wrong on the newspaper question: ' + (', '.join(n['wrong']) or 'none') + '.', '',
          '## Time', '',
          f'The engine\'s newspaper reading (banded Vision, split at the gutters) took a median {o["read_seconds_median"]:.2f} s '
          f'a page on the owner pages and {n["read_seconds_median"]:.2f} s on the newspaper set (most {n["read_seconds_max"]:.1f} s), '
          'on an M3 Pro 18 GB under another session\'s load, beside the classifier\'s 0.6 s (kind-atrium.md §7). The app '
          'reads only pages the classifier calls printed for it. The app\'s own single Vision pass, tried first, called '
          '13 of the 32 whole pages (it found 128 lines on a page the engine reads 615 on), so it was not kept.', '',
          '## Measurement card', '',
          '- **Truth.** Owner pages: kind_classifier.py\'s labels (KND-1: partly a session\'s and not blind; the bundled '
          'weights were fitted on these pages, so these figures are in-sample; the held-out figure is kind-atrium.md '
          '§1\'s 137 of 141). Tags: the truth set\'s record of each original\'s Finder tags (ocr-truth pages.tsv); the '
          'held-out hand pages\' own tags, read where they are; the drawn pages none (they were drawn by a tag). '
          'Newspaper pages: Vision OCR\'s labels (the sample\'s route or the Zotero item type, one relabelled by looking; '
          'whole page or clipping judged from size and lines, three viewed).',
          '- **Selection.** Owner pages: kind_classifier.py\'s draws (truth set, held-out hand folder, Statistics-tagged '
          'forms draw, low-resolution draw); none chosen by the call measured here. Newspaper pages: Vision OCR\'s '
          'sample plus the newspaper and print pages it gathered for the rule, which the rule\'s edges were set on, so '
          'the newspaper figure is the rule\'s fit through the app\'s Vision pass, not a held-out test.',
          '- **Comparison.** None between routes: one detector, as the app runs it. The engine measured the rule on its '
          'own render and gutter-fitted lines; the app reads its classifier\'s Vision pass on the run\'s 2x render.',
          '- **Noise.** Vision is deterministic on one Mac and OS; intervals are Wilson 95% on the page counts.',
          '- **Scope.** No clipping, register or mixed detector is measured (none exists; they are asked). The '
          'photographed axis is reported, not scored (no truth for it here). Tags were not checked against the hand '
          'labels beyond these pages.', '',
          'Pinned by `scripts/test-ocr-page-kind.sh` (when the caches are on the Mac): a fresh run may not get fewer '
          'pages right per kind than this file\'s json.', '']
    (RESULTS / 'page-kinds.md').write_text('\n'.join(L))
    print('\n'.join(L))


def cmd_pin(owner_calls, news_calls):
    pinned = json.loads((RESULTS / 'page-kinds.json').read_text())
    fresh = scores(Path(owner_calls), Path(news_calls))
    bad = []
    for part in ('owner', 'newspaper'):
        for k, v in pinned[part]['per_kind'].items():
            got = fresh[part]['per_kind'].get(k, {}).get('right', 0)
            if got < v['right']:
                bad.append(f'{part} {k}: {got} right, pinned {v["right"]} of {v["n"]}')
            else:
                print(f'PIN {part} {k}: {got} of {v["n"]} right (pinned {v["right"]})')
    if bad:
        print('PIN FAILED: ' + '; '.join(bad))
        sys.exit(1)


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'list':
        cmd_list()
    elif cmd == 'run':
        cmd_run(Path(sys.argv[2]) if len(sys.argv) > 2 else CACHE)
    elif cmd == 'report':
        cmd_report()
    elif cmd == 'pin' and len(sys.argv) == 4:
        cmd_pin(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
