#!/usr/bin/env python3
"""W40.d1 — check a bulk OCR journey's output against the ground truth and SPEC/tag-format.md.

Usage: journey_bulk_ocr_check.py <bulk-ocr dir> --truth <Ground Truth.csv> [--mode automatic|none|copySource]
                                 [--json <out.json>]

<bulk-ocr dir> is what `PROCESSOR_JOURNEY=bulkocr ops/gui/vm-gui-runner.sh processor xcuitest` brings back: one
`run-<epoch>/` from ProcessFilesTestDriver (the PDFs, their sidecars, `manifest.tsv`, `estimate.txt`, and
`spend.tsv` on a metered route) and `tags-guest.tsv`, the guest's own hex reading of every PDF's tag xattr.

What it checks, per PDF: `qpdf --check` and `pdfcpu validate` pass; two pages (merging is off, one image to one
PDF); page 2 starts with the SPEC header (sentinel, source name, `<Provider> · <Model> · <D Month YYYY>`, the
Classification the pipeline recorded); the Finder-tag xattr decoded with `xattr -px` and `plutil` equals the
guest's reading byte for byte, and its tags follow the SPEC for the mode (Unread once and last; the item-type
token on a label photo and nowhere else; year, month and day in their exact forms and at most one each; no
Quality token, which a model never writes; no colour label, which a new user has not chosen). The split into
documents is scored against the truth CSV: page labels, boundaries and whole documents. Exit 1 on any hard failure.
"""
import argparse
import csv
import glob
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile

try:
    from pypdf import PdfReader
except Exception:  # the checker says so instead of passing blind
    PdfReader = None

TRUTH = {'box': 'box_label', 'folder': 'folder_label', 'new': 'document_start', 'cont': 'document_continuation'}
DISPLAY = {'box_label': 'Box', 'folder_label': 'Folder', 'document_start': 'Document Start',
           'document_continuation': 'Continuation'}
MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October',
          'November', 'December']
YEAR = re.compile(r'^\d{3,4}$')
MONTH = re.compile(r'^([1-9]|1[0-2]) (' + '|'.join(MONTHS) + r')$')
MONTH_SHAPED = re.compile(r'^0?\d{1,2} [A-Z][a-z]+$')
DAY = re.compile(r'^Day (?:[1-9]|[12]\d|3[01])$')
PROVENANCE = re.compile(r'^.+ · .+ · \d{1,2} (' + '|'.join(MONTHS) + r') \d{4}$')
QUALITY = {'Q1', 'Q2', 'Q3'}
COLOURS = {'Red', 'Orange', 'Yellow', 'Green', 'Blue', 'Purple', 'Gray', 'Grey'}


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()


def tag_xattr_hex(path):
    """The raw tag xattr as hex, '' when the file has none, None when it cannot be read."""
    rc, out = run(['xattr', '-px', 'com.apple.metadata:_kMDItemUserTags', path])
    if rc == 0:
        return re.sub(r'\s+', '', out)
    return '' if 'No such xattr' in out else None


def decode_tags(hexstr):
    """Decode with plutil, as the item asks; each entry is 'Name' or 'Name\\nColour'."""
    with tempfile.NamedTemporaryFile(suffix='.plist', delete=False) as f:
        f.write(bytes.fromhex(hexstr))
        tmp = f.name
    try:
        rc, out = run(['plutil', '-convert', 'json', '-o', '-', tmp])
        if rc != 0:
            raise ValueError(f'plutil could not decode the tag xattr: {out}')
        entries = json.loads(out)
    finally:
        os.unlink(tmp)
    # Cross-check plutil against Python's own binary-plist reader.
    assert entries == plistlib.loads(bytes.fromhex(hexstr)), 'plutil and plistlib disagree'
    return [e.split('\n')[0] for e in entries], entries


def label_number(path):
    """Finder's colour label from FinderInfo (byte 9, bits 1-3), 0 when there is none."""
    rc, out = run(['xattr', '-px', 'com.apple.FinderInfo', path])
    if rc != 0:
        return 0
    b = bytes.fromhex(re.sub(r'\s+', '', out))
    return (b[9] >> 1) & 7 if len(b) > 9 else 0


def page_texts(path):
    if PdfReader is None:
        return None, []
    r = PdfReader(path)
    return len(r.pages), [(p.extract_text() or '') for p in r.pages]


def units(labels):
    """[start, end] page spans: a box, folder or document start opens a unit; a continuation extends one."""
    spans = []
    for i, lab in enumerate(labels):
        if lab == 'document_continuation' and spans:
            spans[-1][1] = i
        else:
            spans.append([i, i])
    return [tuple(s) for s in spans]


def score_split(truth, got, numbers):
    n = min(len(truth), len(got))
    truth, got = truth[:n], got[:n]
    pages_ok = sum(1 for a, b in zip(truth, got) if a == b)
    confusion = {}
    for a, b in zip(truth, got):
        confusion.setdefault(a, {}).setdefault(b or '(none)', 0)
        confusion[a][b or '(none)'] += 1
    tb = {s for s, _ in units(truth)} - {0}
    gb = {s for s, _ in units(got)} - {0}
    hit = len(tb & gb)
    tu, gu = units(truth), set(units(got))
    docs = [u for u in tu if truth[u[0]] == 'document_start']
    return {
        'pages': n, 'pages_exact': pages_ok,
        'confusion': confusion,
        'boundaries_truth': len(tb), 'boundaries_found': len(gb), 'boundaries_right': hit,
        'boundary_precision': round(hit / len(gb), 4) if gb else None,
        'boundary_recall': round(hit / len(tb), 4) if tb else None,
        'units_truth': len(tu), 'units_exact': sum(1 for u in tu if u in gu),
        'documents_truth': len(docs), 'documents_exact': sum(1 for u in docs if u in gu),
        'unclassified': sum(1 for b in got if b is None),
        # File numbers (the truth CSV's), not positions: a row without a PDF would shift positions.
        'missed_boundaries': sorted(numbers[i] for i in tb - gb),
        'extra_boundaries': sorted(numbers[i] for i in gb - tb),
    }


def check_tags(names, entries, cls, mode, fails, warns, label):
    if mode in ('none',):
        if names:
            fails.append(f'{label}: mode {mode} wrote tags {names}')
        return
    if mode != 'automatic':
        return
    if names.count('Unread') != 1 or names[-1:] != ['Unread']:
        fails.append(f'{label}: Unread must appear once and last (SPEC invariant 6): {names}')
    kind = DISPLAY.get(cls)
    types = [t for t in names if t in ('Box', 'Folder')]
    if cls in ('box_label', 'folder_label'):
        if types != [kind]:
            fails.append(f'{label}: a {kind.lower()} photo carries exactly the {kind} token (SPEC §Item type): {names}')
    elif types:
        fails.append(f'{label}: a document carries an item-type token {types}: {names}')
    years = [t for t in names if YEAR.match(t)]
    months = [t for t in names if MONTH.match(t)]
    days = [t for t in names if DAY.match(t)]
    for facet, vals in (('Year', years), ('Month', months), ('Day', days)):
        if len(vals) > 1:
            fails.append(f'{label}: more than one {facet} token {vals} (SPEC: 0-1)')
    bad_month = [t for t in names if MONTH_SHAPED.match(t) and not MONTH.match(t)]
    bad_month += [t for t in months if MONTHS[int(MONTH.match(t).group(1)) - 1] != MONTH.match(t).group(2)]
    if bad_month:
        fails.append(f'{label}: month token not in the SPEC form "M Month": {bad_month}')
    q = [t for t in names if t in QUALITY]
    if q:
        fails.append(f'{label}: a Quality token {q} on generated output (SPEC: never LLM-emitted)')
    if cls in ('document_start', 'document_continuation'):
        if not years and 'Date Uncertain' not in names:
            warns.append(f'{label}: a document with neither a Year nor Date Uncertain: {names}')
        facets = set(years + months + days + types + ['Unread', 'Date Uncertain'])
        subjects = [t for t in names if t not in facets and not t.startswith('Sent With')]
        if not 2 <= len(subjects) <= 6:
            warns.append(f'{label}: {len(subjects)} subject tags (README: 2-6): {subjects}')
    coloured = [e for e in entries if '\n' in e and e.split('\n')[1] not in ('', '0')]
    if coloured:
        warns.append(f'{label}: tag entries carry a colour: {coloured}')


def check_page2(text, src_name, cls, fails, label):
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    if not lines or lines[0] != 'Extracted text.':
        fails.append(f'{label}: page 2 does not start with the sentinel "Extracted text." ({lines[:1]})')
        return None
    i = 1
    if i < len(lines) and lines[i] == src_name:
        i += 1
    else:
        fails.append(f'{label}: page 2 has no source-name line {src_name!r} after the sentinel ({lines[1:2]})')
    if i < len(lines) and PROVENANCE.match(lines[i]):
        prov = lines[i]
        i += 1
    else:
        fails.append(f'{label}: no "<Provider> · <Model> · <D Month YYYY>" line ({lines[i:i + 1]})')
        return None
    got_cls = lines[i][len('Classification: '):] if i < len(lines) and lines[i].startswith('Classification: ') else None
    want = DISPLAY.get(cls)
    if want and got_cls != want:
        fails.append(f'{label}: page-2 Classification {got_cls!r}, the pipeline recorded {want!r}')
    body = [ln for ln in lines[i:] if not re.match(r'^(Classification|Kind|Document date|Sent with|Date evidence|'
                                                   r'Document kind|Title|Byline|Publication|Publication date|'
                                                   r'Recipient place): ', ln)]
    if not body:
        fails.append(f'{label}: page 2 has a header and no body')
    return prov


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dir')
    ap.add_argument('--truth', required=True)
    ap.add_argument('--mode', default='automatic')
    ap.add_argument('--json')
    a = ap.parse_args()
    fails, warns = [], []
    runs = sorted(glob.glob(os.path.join(a.dir, 'run-*')))
    if len(runs) != 1:
        print(f'want exactly one run-* in {a.dir}, found {len(runs)}')
        return 1
    rd = runs[0]
    for tool in ('qpdf', 'pdfcpu'):
        if run(['which', tool])[0] != 0:
            fails.append(f'{tool} is not installed')
    if PdfReader is None:
        fails.append('pypdf is not available; page 2 cannot be read')

    header, rows = '', []
    for line in open(os.path.join(rd, 'manifest.tsv'), encoding='utf-8'):
        line = line.rstrip('\n')
        if line.startswith('# provider'):
            header = line[2:]
        elif line and not line.startswith('#'):
            pdf, cls, status = (line.split('\t') + ['', '', ''])[:3]
            rows.append({'pdf': pdf, 'cls': cls, 'status': status})
    guest = {}
    gt_path = os.path.join(a.dir, 'tags-guest.tsv')
    if os.path.exists(gt_path):
        for line in open(gt_path, encoding='utf-8'):
            name, _, hx = line.rstrip('\n').partition('\t')
            guest[os.path.basename(name)] = hx
    else:
        fails.append('no tags-guest.tsv: the guest reading of the tags did not come back')

    truth_by_no = {}
    with open(a.truth, newline='', encoding='utf-8-sig') as f:
        for r in csv.DictReader(f):
            if (r.get('Status') or '').strip():
                truth_by_no[int(r['File Number'])] = TRUTH.get(r['Status'].strip().lower())

    per_pdf, provs, qpdf_warn = [], set(), 0
    truth_seq, got_seq, numbers = [], [], []
    for r in rows:
        label = r['pdf'] or '(no pdf)'
        if r['status'] != 'succeeded':
            fails.append(f'{label}: status {r["status"]}')
        if not r['pdf']:
            continue
        # A failed page still writes its PDF (page 2 says why), and that file gets every check below.
        m = re.match(r'^(\d+)', r['pdf'])
        no = int(m.group(1)) if m else None
        truth_seq.append(truth_by_no.get(no))
        got_seq.append(r['cls'] or None)
        numbers.append(no)
        path = os.path.join(rd, r['pdf'])
        if not os.path.exists(path):
            fails.append(f'{label}: missing on disk')
            continue
        rc, out = run(['qpdf', '--check', path])
        if rc == 3:
            qpdf_warn += 1
            warns.append(f'{label}: qpdf --check warnings: {out.splitlines()[-1:]}')
        elif rc != 0:
            fails.append(f'{label}: qpdf --check failed ({rc}): {out.splitlines()[-2:]}')
        rc, out = run(['pdfcpu', 'validate', '-q', path])
        if rc != 0:
            fails.append(f'{label}: pdfcpu validate failed: {out.splitlines()[-2:]}')
        npages, texts = page_texts(path) if PdfReader else (None, [])
        if npages != 2:
            fails.append(f'{label}: {npages} pages, want 2 (merging is off)')
        prov = check_page2(texts[1] if len(texts) > 1 else '', os.path.splitext(r['pdf'])[0] + '.jpg', r['cls'],
                           fails, label) if texts else None
        if prov:
            provs.add(prov.rsplit(' · ', 1)[0])
        hx = tag_xattr_hex(path)
        names, entries = [], []
        if hx is None:
            fails.append(f'{label}: tag xattr unreadable (never read as empty, SPEC invariant 3)')
        else:
            if guest and r['pdf'] not in guest:
                fails.append(f'{label}: missing from the guest reading of the tags')
            elif r['pdf'] in guest and guest[r['pdf']] != hx:
                fails.append(f'{label}: host tag xattr differs from the guest reading (the copy changed it)')
            if hx:
                names, entries = decode_tags(hx)
            check_tags(names, entries, r['cls'], a.mode, fails, warns, label)
        lbl = label_number(path)
        if lbl:
            fails.append(f'{label}: colour label {lbl} on output (SPEC invariant 7: none until the user picks one)')
        if a.mode == 'automatic' and r['cls'] == 'document_start' \
                and not os.path.exists(os.path.splitext(path)[0] + '.json'):
            fails.append(f'{label}: document start without its JSON sidecar')
        per_pdf.append({'pdf': r['pdf'], 'classification': r['cls'], 'truth': truth_by_no.get(no), 'tags': names})

    split = score_split(truth_seq, got_seq, numbers)
    spend = open(os.path.join(rd, 'spend.tsv')).read().strip() if os.path.exists(os.path.join(rd, 'spend.tsv')) else ''
    if spend and '\tunmetered=0\t' not in spend:
        fails.append(f'some replies carried no usage, so the spend is not fully counted: {spend}')
    if spend and '\trefused=0\t' not in spend:
        fails.append(f'the spend cap stopped calls, so this is not a whole run: {spend}')
    estimate = open(os.path.join(rd, 'estimate.txt')).read().strip() if os.path.exists(os.path.join(rd, 'estimate.txt')) else ''
    metered = bool(re.search(r'\tcap=\$', estimate))
    if metered and not spend:
        fails.append('a metered run (the estimate names a cap) has no spend.tsv')
    if spend:
        f = dict(kv.split('=', 1) for kv in spend.split('\t'))
        if float(f['spent_usd']) > float(f['cap_usd']) or float(f['spent_usd']) > 7:
            fails.append(f'spent {f["spent_usd"]} is over the cap {f["cap_usd"]} or the $7 rule')
    result = {'run': os.path.basename(rd), 'manifest': header, 'estimate': estimate, 'spend': spend,
              'pdfs': len(per_pdf), 'qpdf_warnings': qpdf_warn, 'provenance': sorted(provs), 'split': split,
              'fails': fails, 'warns': warns, 'files': per_pdf}
    if a.json:
        with open(a.json, 'w', encoding='utf-8') as f:
            json.dump(result, f, indent=1, ensure_ascii=False)
    print(f'run {result["run"]}: {header}')
    print(f'estimate: {estimate}')
    print(f'spend: {spend or "(not metered)"}')
    print(f'pdfs checked: {len(per_pdf)}; provenance: {sorted(provs)}')
    s = split
    print(f'pages labelled as the truth: {s["pages_exact"]}/{s["pages"]}; boundaries right {s["boundaries_right"]} '
          f'of {s["boundaries_truth"]} (found {s["boundaries_found"]}); whole documents {s["documents_exact"]}/'
          f'{s["documents_truth"]}; units {s["units_exact"]}/{s["units_truth"]}')
    for w in warns:
        print(f'  WARN {w}')
    for x in fails:
        print(f'  FAIL {x}')
    print(f'RESULT: {"FAIL" if fails else "PASS"} ({len(fails)} failures, {len(warns)} warnings)')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
