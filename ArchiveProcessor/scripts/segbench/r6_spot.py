"""W46.r6-spot: Azure Document Intelligence and AWS Textract on 25 of the owner's 96 truth pages.

  r6_spot.py select            # freeze the 25 (seeded draw over page ids; no route or ABBYY text involved)
  r6_spot.py run azure|textract # one call per page; a reservation survives interruption and is never retried
  r6_spot.py report            # scores beside the panel's routes on the same 25 -> stdout (markdown)
  r6_spot.py transkribus-pack  # copy the 25 images and an instruction sheet for the owner's hand upload

Azure: prebuilt-layout (text in reading order, paragraphs, per-span handwriting style), F0 free tier, $0.
Textract: AnalyzeDocument LAYOUT + one QUERY ("the document's date"), $4 + $15 per 1,000 pages at list, so
25 pages are about $0.48; CAP below is the item's whole Textract allowance. Keys come from Keychain
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
CAP = 1.50                      # dollars, Textract; Azure F0 bills nothing
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


def selection():
    return json.loads((CACHE / 'selection.json').read_text())


def cmd_select():
    CACHE.mkdir(parents=True, exist_ok=True)
    out = CACHE / 'selection.json'
    if out.exists():
        print('already frozen:', out); return
    jobs = [j for j in F.manifest()['jobs'] if j['page'] not in P.AGREEMENT]
    assert len(jobs) == 96, len(jobs)
    pick = sorted(random.Random(SEED).sample(jobs, N), key=lambda j: j['page'])
    for j in pick:
        data = (IMAGES / (j['id'] + '.jpg')).read_bytes()
        assert hashlib.sha256(data).hexdigest() == j['sha256'], j['id']
    out.write_text(json.dumps({'seed': SEED, 'n': N, 'jobs': pick}, indent=1))
    print('froze', N, 'pages:', ' '.join(j['page'] for j in pick))


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
    root = CACHE / route; root.mkdir(parents=True, exist_ok=True)
    for j in selection()['jobs']:
        dest, pending = root / (j['id'] + '.json'), root / (j['id'] + '.pending')
        if dest.exists():
            continue
        if pending.exists():
            raise SystemExit(f'uncertain call for {j["id"]}: reconcile by hand, never retry')
        cost = TEXTRACT_PAGE if route == 'textract' else 0.
        spent = sum(e['cost'] for e in ledger())
        if spent + cost > CAP:
            raise SystemExit(f'cap: ${spent:.3f} spent, ${cost:.3f} more would pass ${CAP}')
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


def decades(tags):
    return {int(d) for d in re.findall(r'\b(1[5-9]\d0|20[0-2]0)s\b', tags)}


def cmd_report():
    import ocr_cloud_full_report as R
    sel = selection()['jobs']; ids = {j['id'] for j in sel}
    by_page = {r['page']: r for r in P.rows()}
    rows = {}
    for j in sel:
        truth = (P.TRUTH / 'truth' / (j['page'] + '.txt')).read_text()
        a = json.loads((CACHE / 'azure' / (j['id'] + '.json')).read_text())
        t = json.loads((CACHE / 'textract' / (j['id'] + '.json')).read_text())
        lay, plain = textract_text(t)
        rows.setdefault('azure-di-layout', []).append(score(truth, azure_text(a))['nes'])
        rows.setdefault('textract-layout', []).append(score(truth, lay)['nes'])
        rows.setdefault('textract-lines', []).append(score(truth, plain)['nes'])
    for r in R.all_scores():
        if r['id'] in ids and r['ok']:
            rows.setdefault(r['key'], []).append(r['nes'])
    full = {k: v for k, v in rows.items() if len(v) == N}
    print(f'| route | mean NES on the {N} | n |\n|---|---|---|')
    for k, v in sorted(full.items(), key=lambda kv: -sum(kv[1])):
        print(f'| {k} | {100 * sum(v) / N:.1f} | {len(v)} |')
    for base in ('mistral-ocr-4-1',):
        for k in ('azure-di-layout', 'textract-layout'):
            if base in full:
                print(f'\npaired {k} - {base}:', paired(full[k], full[base]))
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
    print(f"ledger: ${sum(e['cost'] for e in ledger()):.3f} accounted")


SHEET = """# Transkribus hand upload — W46.r6-spot

The 25 images in `images/` are the same pages the Azure and Textract arms read. Free credits only; buy nothing.

1. Sign in at https://app.transkribus.org with the Stanford account.
2. Create a collection named `W46.r6-spot` and upload all 25 images from `images/` as one document.
3. Run text recognition with **Text Titan II**, with its layout analysis switched on, on all pages
   (about 25 credits of the 50 free a month).
4. When it finishes, export the document as **PAGE XML** and unzip it into `export/` beside this file.
5. Tell a session the export is there; it scores the PAGE XML text against the truth.
"""


def cmd_transkribus_pack():
    pack = CACHE / 'transkribus-pack'
    (pack / 'images').mkdir(parents=True, exist_ok=True); (pack / 'export').mkdir(exist_ok=True)
    for j in selection()['jobs']:
        shutil.copy2(IMAGES / (j['id'] + '.jpg'), pack / 'images' / (j['page'] + '.jpg'))
    (pack / 'README.md').write_text(SHEET)
    print(pack)


if __name__ == '__main__':
    F.configure()
    a = sys.argv[1:]
    {'select': lambda: cmd_select(), 'run': lambda: cmd_run(a[1]), 'report': lambda: cmd_report(),
     'transkribus-pack': lambda: cmd_transkribus_pack()}[a[0]]()
