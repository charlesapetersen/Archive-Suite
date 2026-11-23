"""W46.r6-spot: Azure Document Intelligence and AWS Textract on 25 of the owner's 96 truth pages.

  r6_spot.py select            # freeze the 25 (seeded draw over page ids; no route or ABBYY text involved)
  r6_spot.py run azure|textract # one call per page; a reservation survives interruption and is never retried
  r6_spot.py report            # scores beside the panel's routes on the same 25 -> stdout (markdown)
  r6_spot.py transkribus-pack  # copy the 25 images and an instruction sheet for the owner's hand upload
                               # (report also scores its PAGE XML export, in the export's own reading order)
  R6_SET=rest r6_spot.py select|run  # W47.wh-readers-lost-vendors-read: Azure and Textract on the other 71
  R6_SET=all r6_spot.py report  # all 96 for Azure and Textract; Transkribus stays at 25 (owner call 25)

Azure: prebuilt-layout (text in reading order, paragraphs, per-span handwriting style), F0 free tier, $0.
Textract: AnalyzeDocument LAYOUT + one QUERY ("the document's date"), $4 + $15 per 1,000 pages at list, so
25 pages are about $0.48; CAPS below are each set's whole Textract allowance. Keys come from Keychain
(service com.archiveprocessor.app) and are never printed or written. Raw replies stay in CACHE, outside git.
"""
import datetime
import hashlib
import hmac
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

import ocr_cloud_full as F
import ocr_panel as P
from ocr_panel_score import score, paired

CACHE = Path(os.environ.get('R6_SPOT_CACHE', Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/r6-spot'))
IMAGES = F.CACHE / 'images'
N, SEED = 25, 4625
SET = os.environ.get('R6_SET', 'spot')  # spot: the 25 (W46.r6-spot); rest: the other 71; all: the 96 (report only)
CAPS = {'spot': 1.50, 'rest': 1.40}     # dollars, Textract, each set's whole allowance; Azure F0 bills nothing
SELECTION = {'spot': 'selection.json', 'rest': 'selection-rest.json'}
PACK = {'spot': 'transkribus-pack', 'rest': 'transkribus-pack-rest'}
TEXTRACT_PAGE = 0.004 + 0.015   # LAYOUT + QUERIES, per page, list
REGION = 'us-east-2'
DATE_QUERY = 'What is the date of this document?'
SERVICE = 'com.archiveprocessor.app'


def key(account):
    r = subprocess.run(['security', 'find-generic-password', '-s', SERVICE, '-a', account, '-w'],
                       capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f'Keychain item {account!r} missing')
    return r.stdout.strip()


def sets():
    return ['spot', 'rest'] if SET == 'all' else [SET]


def selection():
    jobs = [j for k in sets() for j in json.loads((CACHE / SELECTION[k]).read_text())['jobs']]
    return {'jobs': sorted(jobs, key=lambda j: j['page'])}


def cmd_select():
    CACHE.mkdir(parents=True, exist_ok=True)
    out = CACHE / SELECTION[SET]
    if out.exists():
        print('already frozen:', out); return
    jobs = [j for j in F.manifest()['jobs'] if j['page'] not in P.AGREEMENT]
    assert len(jobs) == 96, len(jobs)
    if SET == 'rest':
        spot = {j['id'] for j in json.loads((CACHE / SELECTION['spot']).read_text())['jobs']}
        pick = [j for j in jobs if j['id'] not in spot]
        assert len(pick) == 96 - N, len(pick)
    else:
        pick = sorted(random.Random(SEED).sample(jobs, N), key=lambda j: j['page'])
    for j in pick:
        data = (IMAGES / (j['id'] + '.jpg')).read_bytes()
        assert hashlib.sha256(data).hexdigest() == j['sha256'], j['id']
    out.write_text(json.dumps({'seed': SEED, 'n': len(pick), 'jobs': pick}, indent=1))
    print('froze', len(pick), 'pages:', ' '.join(j['page'] for j in pick))


def ledger():
    f = CACHE / 'ledger.jsonl'
    return [json.loads(l) for l in f.read_text().splitlines()] if f.exists() else []


def charge(entry):
    with (CACHE / 'ledger.jsonl').open('a') as f:
        f.write(json.dumps(entry) + '\n')


def http(req, timeout=120):
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def azure(data):
    endpoint, k = key('Azure DI endpoint').rstrip('/'), key('Azure DI')
    url = endpoint + '/documentintelligence/documentModels/prebuilt-layout:analyze?api-version=2024-11-30'
    st, hd, body = http(urllib.request.Request(url, data=data, method='POST', headers={
        'Ocp-Apim-Subscription-Key': k, 'Content-Type': 'image/jpeg'}))
    if st != 202:
        return {'http': st, 'error': body.decode(errors='replace')[:500]}
    loc = {k.lower(): v for k, v in hd.items()}['operation-location']
    for _ in range(120):
        time.sleep(2)
        st, _, body = http(urllib.request.Request(loc, headers={'Ocp-Apim-Subscription-Key': k}))
        got = json.loads(body) if body else {}
        if st == 429:
            time.sleep(10); continue
        if got.get('status') in ('succeeded', 'failed'):
            return {'http': st, **got}
    return {'http': st, 'error': 'poll timeout'}


def sigv4(body, target):
    kid, secret = key('AWS Textract key id'), key('AWS Textract')
    host = f'textract.{REGION}.amazonaws.com'
    now = datetime.datetime.now(datetime.timezone.utc)
    amz, day = now.strftime('%Y%m%dT%H%M%SZ'), now.strftime('%Y%m%d')
    h = {'content-type': 'application/x-amz-json-1.1', 'host': host, 'x-amz-date': amz, 'x-amz-target': target}
    signed = ';'.join(sorted(h))
    canon = '\n'.join(['POST', '/', '', *[f'{k}:{h[k]}' for k in sorted(h)], '', signed,
                       hashlib.sha256(body).hexdigest()])
    scope = f'{day}/{REGION}/textract/aws4_request'
    sts = '\n'.join(['AWS4-HMAC-SHA256', amz, scope, hashlib.sha256(canon.encode()).hexdigest()])
    k = ('AWS4' + secret).encode()
    for part in (day, REGION, 'textract', 'aws4_request'):
        k = hmac.new(k, part.encode(), hashlib.sha256).digest()
    sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
    h['authorization'] = f'AWS4-HMAC-SHA256 Credential={kid}/{scope}, SignedHeaders={signed}, Signature={sig}'
    return f'https://{host}/', h


def textract(data):
    import base64
    body = json.dumps({'Document': {'Bytes': base64.b64encode(data).decode()},
                       'FeatureTypes': ['LAYOUT', 'QUERIES'],
                       'QueriesConfig': {'Queries': [{'Text': DATE_QUERY, 'Alias': 'DATE'}]}}).encode()
    url, h = sigv4(body, 'Textract.AnalyzeDocument')
    st, _, out = http(urllib.request.Request(url, data=body, method='POST', headers=h))
    try:
        return {'http': st, **json.loads(out)}
    except ValueError:
        return {'http': st, 'error': out.decode(errors='replace')[:500]}


def cmd_run(route):
    call = {'azure': azure, 'textract': textract}[route]
    assert SET in CAPS, 'run one set at a time'
    root = CACHE / route; root.mkdir(parents=True, exist_ok=True)
    jobs = selection()['jobs']; ids = {j['id'] for j in jobs}
    for j in jobs:
        dest, pending = root / (j['id'] + '.json'), root / (j['id'] + '.pending')
        if dest.exists():
            continue
        if pending.exists():
            raise SystemExit(f'uncertain call for {j["id"]}: reconcile by hand, never retry')
        cost = TEXTRACT_PAGE if route == 'textract' else 0.
        spent = sum(e['cost'] for e in ledger() if e['job'] in ids)
        if spent + cost > CAPS[SET]:
            raise SystemExit(f'cap: ${spent:.3f} spent, ${cost:.3f} more would pass ${CAPS[SET]}')
        pending.write_text(str(time.time()))
        charge({'route': route, 'job': j['id'], 'cost': cost, 'at': time.time()})
        got = call((IMAGES / (j['id'] + '.jpg')).read_bytes())
        dest.write_text(json.dumps(got))
        ok = got.get('http') == 200 and got.get('status', 'succeeded') == 'succeeded'
        if not ok and got.get('http') in (400, 401, 403, 429):
            # Rejected before processing: nothing billed. Release the reservation and the charge, and stop.
            charge({'route': route, 'job': j['id'], 'cost': -cost, 'at': time.time(), 'refund': got.get('http')})
            dest.rename(root / (j['id'] + f'.rejected-{int(time.time())}.json'))
            pending.unlink()
            raise SystemExit(f'{route} {j["id"]}: HTTP {got.get("http")}: {got.get("error", "")[:200]}')
        pending.unlink()
        print(route, j['id'], 'ok' if ok else f'FAILED {got.get("http")}', flush=True)
        if route == 'azure':
            time.sleep(3.5)  # F0: 20 requests a minute, polls included


def azure_text(got):
    return (got.get('analyzeResult') or {}).get('content', '') or ''


def azure_handwritten(got):
    r = got.get('analyzeResult') or {}
    spans = [s for st in r.get('styles', []) if st.get('isHandwritten') for s in st.get('spans', [])]
    return sum(s['length'] for s in spans) / max(1, len(r.get('content', '')))


def textract_blocks(got):
    return {b['Id']: b for b in got.get('Blocks', [])}


def textract_text(got):
    """Lines in the order Textract's LAYOUT blocks give, falling back to LINE order."""
    blocks = textract_blocks(got)
    layout = [b for b in got.get('Blocks', []) if b['BlockType'].startswith('LAYOUT_')]
    seen, lines = set(), []
    for b in layout:
        for rel in b.get('Relationships', []):
            if rel['Type'] == 'CHILD':
                for i in rel['Ids']:
                    c = blocks.get(i)
                    if c and c['BlockType'] == 'LINE' and i not in seen:
                        seen.add(i); lines.append(c['Text'])
    rest = [b['Text'] for b in got.get('Blocks', []) if b['BlockType'] == 'LINE' and b['Id'] not in seen]
    return '\n'.join(lines + rest), '\n'.join(b['Text'] for b in got.get('Blocks', []) if b['BlockType'] == 'LINE')


def textract_date(got):
    for b in got.get('Blocks', []):
        if b['BlockType'] == 'QUERY_RESULT':
            return b.get('Text', ''), b.get('Confidence')
    return '', None


PAGE_NS = {'p': 'http://schema.primaresearch.org/PAGE/gts/pagecontent/2013-07-15'}


def transkribus_pages():
    """{page id: PAGE XML path} from the owner's export, keyed by the image the pack uploaded (0001_p005.jpg)."""
    import xml.etree.ElementTree as ET
    out = {}
    for f in sorted(f for k in sets() for f in (CACHE / PACK[k] / 'export').glob('*/*/page/*.xml')):
        img = ET.parse(f).getroot().find('p:Page', PAGE_NS).get('imageFilename')
        m = re.fullmatch(r'(?:\d+_)?(p\d+)\.jpg', img)
        assert m and m.group(1) not in out, (f, img)
        out[m.group(1)] = f
    return out


def transkribus_text(path, hyphen=True):
    """Lines in the export's reading order: regions by ReadingOrder, lines by their readingOrder index.
    Transkribus writes a line-end hyphen as '¬'; the truth keeps the printed hyphen ('pre- sent'), so it is
    mapped back to '-' unless hyphen=False."""
    import xml.etree.ElementTree as ET
    page = ET.parse(path).getroot().find('p:Page', PAGE_NS)
    regions = {r.get('id'): r for r in page.iter('{%s}TextRegion' % PAGE_NS['p'])}
    order = [x.get('regionRef') for x in sorted(page.iterfind('p:ReadingOrder//p:RegionRefIndexed', PAGE_NS),
                                                key=lambda x: int(x.get('index')))]
    order += [i for i in regions if i not in order]
    idx = lambda e, n: int(m.group(1)) if (m := re.search(r'readingOrder \{index:(\d+);', e.get('custom', ''))) else n
    lines = []
    for rid in order:
        tl = list(regions[rid].iterfind('p:TextLine', PAGE_NS))
        for _, _, line in sorted((idx(t, n), n, t) for n, t in enumerate(tl)):
            u = line.find('p:TextEquiv/p:Unicode', PAGE_NS)
            if u is not None and u.text:
                lines.append(u.text)
    text = '\n'.join(lines)
    return text.replace('¬', '-') if hyphen else text


def decades(tags):
    return {int(d) for d in re.findall(r'\b(1[5-9]\d0|20[0-2]0)s\b', tags)}


UNCORRECTABLE = 'p081'  # reported apart on the bench page (ArchiveOCRBench/build.py), so the rows' figures are on 95


def headline(sel, by_page, R):
    """W47.wh-readers-lost-vendors-read: each vendor on the 95 the reading rows are scored on (p081 apart), beside the
    panel's stored replies scored the same way, by page kind, and paired against Mistral OCR 4.1."""
    every = {j['id']: (P.TRUTH / 'truth' / (j['page'] + '.txt')).read_text() for j in sel}
    keep = [j for j in sel if j['page'] != UNCORRECTABLE]
    truth = {j['id']: every[j['id']] for j in keep}
    hyp = {'azure-di-layout': lambda j: azure_text(json.loads((CACHE / 'azure' / (j['id'] + '.json')).read_text())),
           'textract-layout': lambda j: textract_text(json.loads((CACHE / 'textract' / (j['id'] + '.json')).read_text()))[0]}
    per = {k: {j['id']: score(every[j['id']], f(j))['nes'] for j in sel} for k, f in hyp.items()}
    panel = {}
    for r in R.all_scores():
        if r['id'] in every:
            panel.setdefault(r['key'], {})[r['id']] = r['nes'] if r['ok'] else None
    print(f'\n## Answered and strict (failure as 0) on the 95, p081 apart; by kind strict on all 96, as the charts\n')
    print('| route | answered | strict | typewritten | printed | handwritten | mixed |\n|---|---|---|---|---|---|---|')
    def line(k, m):
        got = [m[i] for i in truth if m.get(i) is not None]
        kinds = {}
        for j in sel:
            kinds.setdefault(by_page[j['page']]['kind'], []).append(m.get(j['id']) or 0.)
        cell = lambda kd: f'{100 * sum(kinds[kd]) / len(kinds[kd]):.2f} ({len(kinds[kd])})' if kd in kinds else ''
        print(f'| {k} | {100 * sum(got) / len(got):.2f} ({len(got)}) | {100 * sum(m.get(i) or 0. for i in truth) / len(keep):.2f} '
              f'| {cell("typewritten")} | {cell("printed")} | {cell("handwritten")} | {cell("mixed")} |')
    for k, m in per.items():
        line(k, m)
    for k in ('mistral-ocr-4-1', 'gpt5.4-mini', 'qwen3.8-flash', 'apple-vision'):
        if k in panel and len(panel[k]) == len(sel):
            line(k, panel[k])
    base = panel.get('mistral-ocr-4-1', {})
    for k, m in per.items():
        ids = [i for i in truth if base.get(i) is not None]
        d = paired([m[i] for i in ids], [base[i] for i in ids])
        print(f'\npaired {k} - mistral-ocr-4-1 on {d["n"]}: {100 * d["delta"]:+.2f} ({100 * d["lo"]:+.2f} to {100 * d["hi"]:+.2f})')
    for k, m in per.items():
        print(f'{k} on all 96: {100 * sum(m.values()) / len(m):.2f}')
    d = paired([per['azure-di-layout'][i] for i in truth], [per['textract-layout'][i] for i in truth])
    print(f'\npaired azure-di-layout - textract-layout on {d["n"]}: {100 * d["delta"]:+.2f} ({100 * d["lo"]:+.2f} to {100 * d["hi"]:+.2f})')
    p = UNCORRECTABLE
    j = next((j for j in sel if j['page'] == p), None)
    if j:
        t = (P.TRUTH / 'truth' / (p + '.txt')).read_text()
        print(f'\n{p} apart:', {k: round(100 * score(t, f(j))['nes'], 2) for k, f in hyp.items()})


def cmd_report():
    import ocr_cloud_full_report as R
    sel = selection()['jobs']; ids = {j['id'] for j in sel}; N = len(sel)
    by_page = {r['page']: r for r in P.rows()}
    rows = {}
    tk = transkribus_pages()
    if tk and set(tk) != {j['page'] for j in sel}:
        assert set(tk) < {j['page'] for j in sel}, sorted(set(tk) - {j['page'] for j in sel})
        print(f'(Transkribus export covers {len(tk)} of the {N}; use the spot report for its 25-page result.)\n')
        tk = {}
    for j in sel:
        truth = (P.TRUTH / 'truth' / (j['page'] + '.txt')).read_text()
        a = json.loads((CACHE / 'azure' / (j['id'] + '.json')).read_text())
        t = json.loads((CACHE / 'textract' / (j['id'] + '.json')).read_text())
        lay, plain = textract_text(t)
        rows.setdefault('azure-di-layout', []).append(score(truth, azure_text(a))['nes'])
        rows.setdefault('textract-layout', []).append(score(truth, lay)['nes'])
        rows.setdefault('textract-lines', []).append(score(truth, plain)['nes'])
        if tk:
            rows.setdefault('transkribus-text-titan', []).append(score(truth, transkribus_text(tk[j['page']]))['nes'])
            rows.setdefault('transkribus-raw-hyphen', []).append(
                score(truth, transkribus_text(tk[j['page']], hyphen=False))['nes'])
    for r in R.all_scores():
        if r['id'] in ids and r['ok']:
            rows.setdefault(r['key'], []).append(r['nes'])
    full = {k: v for k, v in rows.items() if len(v) == N}
    if N == 96:
        headline(sel, by_page, R)
    print(f'| route | mean NES on the {N} | n |\n|---|---|---|')
    for k, v in sorted(full.items(), key=lambda kv: -sum(kv[1])):
        print(f'| {k} | {100 * sum(v) / N:.1f} | {len(v)} |')
    for base in ('mistral-ocr-4-1',):
        for k in ('azure-di-layout', 'textract-layout', 'transkribus-text-titan'):
            if base in full and k in full:
                print(f'\npaired {k} - {base}:', paired(full[k], full[base]))
    if 'transkribus-text-titan' in full:
        for k in ('azure-di-layout', 'textract-layout'):
            print(f'\npaired transkribus-text-titan - {k}:', paired(full['transkribus-text-titan'], full[k]))
        kinds = {}
        for j, v in zip(sel, full['transkribus-text-titan']):
            kinds.setdefault(by_page[j['page']]['kind'], []).append(v)
        print('\ntranskribus by kind:', {k: (round(100 * sum(v) / len(v), 1), len(v)) for k, v in kinds.items()})
        # Order-free: the share of truth words each vendor misses (a bag of words), so reading is told from order.
        miss = {'azure-di-layout': [0, 0], 'textract-layout': [0, 0], 'transkribus-text-titan': [0, 0]}
        for j in sel:
            truth = (P.TRUTH / 'truth' / (j['page'] + '.txt')).read_text()
            hyps = {'azure-di-layout': azure_text(json.loads((CACHE / 'azure' / (j['id'] + '.json')).read_text())),
                    'textract-layout': textract_text(json.loads((CACHE / 'textract' / (j['id'] + '.json')).read_text()))[0],
                    'transkribus-text-titan': transkribus_text(tk[j['page']])}
            for k, h in hyps.items():
                s = score(truth, h); miss[k][0] += s['missed']; miss[k][1] += s['words']
        print('\ntruth words missed (order-free):', {k: f'{100 * m / w:.1f}% of {w}' for k, (m, w) in miss.items()})
    print('\n| page | kind | handwritten share (Azure) | Textract date has a year | conf | year matches a tagged year | year in date bin |')
    print('|---|---|---|---|---|---|---|')
    tally = {'answered': 0, 'year': 0, 'tag_pages': 0, 'tag_hit': 0, 'bin_pages': 0, 'bin_hit': 0}
    for j in sel:
        row = by_page[j['page']]
        a = json.loads((CACHE / 'azure' / (j['id'] + '.json')).read_text())
        t = json.loads((CACHE / 'textract' / (j['id'] + '.json')).read_text())
        d, c = textract_date(t)
        ys = {int(y) for y in re.findall(r'\b(1[5-9]\d\d|20[0-2]\d)\b', d)}
        tagged = {int(y) for y in re.findall(r'\b(1[5-9]\d\d|20[0-2]\d)\b', row['tags'])}
        tagged |= {y for dec in decades(row['tags']) for y in range(dec, dec + 10)}
        lo_hi = {'before 1900': (0, 1899), '1900-1949': (1900, 1949), '1950-1984': (1950, 1984),
                 '1985 on': (1985, 2100)}.get(row['date_bin'])
        tag_ok = bin_ok = ''
        tally['answered'] += bool(d); tally['year'] += bool(ys)
        if ys and tagged:
            tag_ok = 'yes' if ys & tagged else 'no'; tally['tag_pages'] += 1; tally['tag_hit'] += tag_ok == 'yes'
        if ys and lo_hi:
            bin_ok = 'yes' if any(lo_hi[0] <= y <= lo_hi[1] for y in ys) else 'no'
            tally['bin_pages'] += 1; tally['bin_hit'] += bin_ok == 'yes'
        print(f"| {j['page']} | {row['kind']} | {azure_handwritten(a):.2f} | {'yes' if ys else ('no' if d else '(none)')} "
              f"| {round(c) if c is not None else ''} | {tag_ok} | {bin_ok} |")
    print(f"\nTextract date query: answered {tally['answered']} of {N}, a four-digit year in {tally['year']}; "
          f"year matches a tagged year or decade on {tally['tag_hit']} of {tally['tag_pages']}; "
          f"inside the page's date bin on {tally['bin_hit']} of {tally['bin_pages']}")
    print(f"ledger: ${sum(e['cost'] for e in ledger() if e['job'] in ids):.3f} accounted on these {N}")


SHEET = """# Transkribus hand upload — {item}

The {n} images in `images/` are the same pages the Azure and Textract arms read. Free credits only; buy nothing.

1. Sign in at https://app.transkribus.org with the Stanford account.
2. Create a collection named `{item}` and upload all {n} images from `images/` as one document.
3. Run text recognition with **{model}**, with its layout analysis switched on, on all pages
   (about {n} credits; {credits}).
4. When it finishes, export the document as **PAGE XML** and unzip it into `export/` beside this file.
5. Tell a session the export is there; it scores the PAGE XML text against the truth.
"""


def cmd_transkribus_pack():
    if SET != 'spot':
        raise SystemExit('Transkribus is limited to the 25-page spot check (owner call 25).')
    pack = CACHE / PACK[SET]
    (pack / 'images').mkdir(parents=True, exist_ok=True); (pack / 'export').mkdir(exist_ok=True)
    jobs = selection()['jobs']
    for j in jobs:
        shutil.copy2(IMAGES / (j['id'] + '.jpg'), pack / 'images' / (j['page'] + '.jpg'))
    (pack / 'README.md').write_text(SHEET.format(
        item='W46.r6-spot', model='Text Titan I', credits='the 50 free a month', n=len(jobs)))
    print(pack)


if __name__ == '__main__':
    F.configure()
    a = sys.argv[1:]
    {'select': lambda: cmd_select(), 'run': lambda: cmd_run(a[1]), 'report': lambda: cmd_report(),
     'transkribus-pack': lambda: cmd_transkribus_pack()}[a[0]]()
