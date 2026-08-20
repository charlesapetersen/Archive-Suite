#!/usr/bin/env python3
"""Assert a ProcessFilesTestDriver run against the Tier-2 contract — reading everything from disk.

Usage: tier2_assert.py <runDir> <mode> [--gt <ground_truth.csv>] [--check-exports]

The app driver writes only a tiny `manifest.tsv` (per-file classification + status from the pipeline's
in-memory state) plus the output PDFs/JSON sidecars/tags. This asserter reads the run dir externally
(after the app has exited — no metadata-subsystem contention): PDF page count + page-2 header via
pypdf, applied Finder tags via the raw xattr, sidecar presence, and cross-references the manifest.

Hard checks (exit 1 on any failure) verify the PIPELINE produced correct output for the tagging mode.
Segmentation accuracy vs the LLM is reported as a metric, not a hard gate.
"""
import sys, re, os, csv, glob, logging

# The Finder-tag xattr read is shared with assert_mac.py — one Spotlight-free reader, one place. Unlike the
# legacy compatibility shape, this preserves the distinction between verified-empty and unreadable so the
# Tier-2 oracle cannot report a blind tag read as a pass.
from finder_tags import read_tags, UNREADABLE

logging.getLogger("pypdf").setLevel(logging.ERROR)   # silence "Ignoring wrong pointing object" noise
try:
    from pypdf import PdfReader
except Exception:
    PdfReader = None

YEAR = re.compile(r'^\d{4}$')
MONTH = re.compile(r'^\d{2} [A-Z][a-z]+$')          # "03 March"
DAY = re.compile(r'^Day \d+$')
GT_MAP = {'box': 'box_label', 'folder': 'folder_label',
          'new': 'document_start', 'cont': 'document_continuation'}


def pdf_facts(path):
    """(pageCount, page2_text) via pypdf; (None,'') if unreadable."""
    if PdfReader is None:
        return None, ''
    try:
        r = PdfReader(path)
        n = len(r.pages)
        p2 = r.pages[1].extract_text() if n > 1 else ''
        return n, (p2 or '')
    except Exception:
        return None, ''


def main():
    if len(sys.argv) < 3:
        print("usage: tier2_assert.py <runDir> <mode> [--gt csv] [--check-exports]"); return 2
    run_dir, mode = sys.argv[1], sys.argv[2]
    gt = sys.argv[sys.argv.index('--gt') + 1] if '--gt' in sys.argv else None
    check_exports = '--check-exports' in sys.argv
    fails, warns = [], []

    def check(cond, msg):
        if not cond:
            fails.append(msg)

    # Manifest: per-file (pdf_basename, classification, status), in pipeline order.
    manifest_path = os.path.join(run_dir, 'manifest.tsv')
    check(os.path.exists(manifest_path), "no manifest.tsv (driver did not finish)")
    header, entries = '', []
    if os.path.exists(manifest_path):
        for line in open(manifest_path):
            line = line.rstrip('\n')
            if line.startswith('# provider'):
                header = line
            elif line.startswith('#') or not line.strip():
                continue
            else:
                parts = line.split('\t')
                if len(parts) >= 3:
                    entries.append({'pdf': parts[0], 'classification': parts[1], 'status': parts[2]})
    print(f"  mode={mode}  {header.lstrip('# ')}")
    check(len(entries) > 0, "manifest has no file rows")
    check(PdfReader is not None, "pypdf not available — cannot verify PDF structure")

    for e in entries:
        name = e['pdf'] or '(no pdf)'
        if e['status'] != 'succeeded':
            fails.append(f"{name}: status={e['status']}")
            continue
        check(bool(e['pdf']), f"{name}: no output PDF recorded")
        pdf_path = os.path.join(run_dir, e['pdf'])
        check(os.path.exists(pdf_path), f"{name}: output PDF missing on disk")
        if not os.path.exists(pdf_path):
            continue
        npages, p2 = pdf_facts(pdf_path)
        check(npages == 2, f"{name}: pageCount={npages} (want 2)")
        check(p2.startswith('Extracted text.'), f"{name}: page-2 header not 'Extracted text.' (got {p2[:20]!r})")

        tags, lbl, tag_status = read_tags(pdf_path)
        sidecar = os.path.exists(os.path.splitext(pdf_path)[0] + '.json')

        if tag_status == UNREADABLE:
            check(False, f"{name}: could not READ Finder tags (tag xattr unreadable; refusing a blind pass)")
        elif mode == 'none':
            check(tags == [], f"{name}: mode=none but tags={tags}")
            check(lbl == 0, f"{name}: mode=none but labelNumber={lbl}")
        elif mode == 'copySource':
            check('Unread' not in tags, f"{name}: copySource must not stamp Unread (tags={tags})")
        elif mode == 'automatic':
            unread_last = (len(tags) > 0 and tags[-1] == 'Unread')
            check(unread_last, f"{name}: Unread not last (tags={tags})")
            cls = e['classification']
            if cls == 'box_label':
                check(lbl == 6 and 'Red' in tags and 'Box' in tags,
                      f"{name}: box should be Red(6)+Box, got label={lbl} tags={tags}")
            elif cls == 'folder_label':
                check(lbl == 3 and 'Purple' in tags and 'Folder' in tags,
                      f"{name}: folder should be Purple(3)+Folder, got label={lbl} tags={tags}")
            else:  # document (start or continuation)
                uncertain = 'Date Uncertain' in tags
                check(any(YEAR.match(t) for t in tags) or uncertain,
                      f"{name}: doc has neither a year nor 'Date Uncertain' (tags={tags})")
                # Month is present only when the source gives one; a legitimately year-only document
                # (no month in the text, e.g. a doc dated just "1918") is valid — warn, don't fail.
                if not uncertain and not any(MONTH.match(t) for t in tags):
                    warns.append(f"{name}: no 'MM Month' tag (year-only date?) tags={tags}")
                subjects = [t for t in tags if not (YEAR.match(t) or MONTH.match(t) or DAY.match(t)
                            or t in ('Date Uncertain', 'Unread', 'Red', 'Purple', 'Box', 'Folder'))]
                if not (2 <= len(subjects) <= 6):
                    warns.append(f"{name}: {len(subjects)} subject tags (spec says 2-6): {subjects}")
        # A JSON sidecar is written per SEGMENT, on the document_start page only — continuation pages share it
        # and correctly have none of their own. This is independent of whether the tag xattr could be read.
        if mode == 'automatic' and e['classification'] == 'document_start':
            check(sidecar, f"{name}: document_start missing JSON sidecar")

    if check_exports:
        imgs = [x for x in glob.glob(os.path.join(run_dir, '*'))
                if x.lower().rsplit('.', 1)[-1] in ('jpg', 'jpeg', 'png', 'tiff', 'tif', 'heic')]
        check(len(imgs) >= len([e for e in entries if e['status'] == 'succeeded']),
              f"exportOriginals: only {len(imgs)} sibling images for {len(entries)} outputs")
        print(f"  exportOriginals: {len(imgs)} sibling images present")

    if gt and os.path.exists(gt):
        expected = []
        with open(gt, newline='') as g:
            for row in csv.DictReader(g):
                expected.append(GT_MAP.get((row.get('Status') or '').strip().lower()))
        got = [e['classification'] for e in entries]
        n = min(len(expected), len(got))
        match = sum(1 for i in range(n) if expected[i] and expected[i] == got[i])
        rate = (match / n * 100) if n else 0
        print(f"  segmentation vs ground truth: {match}/{n} = {rate:.0f}% match")
        if rate < 60:
            warns.append(f"segmentation match {rate:.0f}% < 60% vs ground truth (LLM call rate; not a pipeline bug)")

    for w in warns:
        print(f"  ⚠ WARN  {w}")
    if fails:
        for x in fails:
            print(f"  ✗ FAIL  {x}")
        print(f"  RESULT: FAIL ({len(fails)} hard failures, {len(warns)} warnings)")
        return 1
    print(f"  RESULT: PASS ({len(entries)} files, {len(warns)} warnings)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
