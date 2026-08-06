#!/usr/bin/env python3
"""Assert the Mac side of the phone->Mac round-trip.

Given the isolated TESTOUT dir and the fixtures' ground_truth.json, verify that
every injected document actually flowed through the REAL Mac pipeline:
  1. every unique OCR token appears in some output (PDF text layer OR a manifest), and
  2. every expected year appears in an output filename OR a Finder tag.

PDF text is extracted by the compiled `pdftext` helper (PDFKit). We also scan any
*.json/*.txt manifest under TESTOUT so the check is robust to output layout.

Finder tags are read from the tag **xattr** (`finder_tags.read_tags`), never via `mdls`/Spotlight —
TESTOUT lives under `/tmp` (`e2e-phone-mac.sh:34-35`), which Spotlight does not index, so `mdls` used
to answer `(null)` here for correctly tagged output and this half of the year check never fired at all.

Usage: assert_mac.py <TESTOUT_DIR> <ground_truth.json> <pdftext_bin>
Exit 0 = PASS, 1 = FAIL.
"""
import json, os, subprocess, sys, glob

from finder_tags import read_tags, UNREADABLE

testout, gt_path, pdftext = sys.argv[1], sys.argv[2], sys.argv[3]
gt = json.load(open(gt_path))

def sh(*a):
    try:
        return subprocess.run(a, capture_output=True, text=True, timeout=30).stdout
    except Exception:
        return ""

pdfs = sorted(glob.glob(os.path.join(testout, "**", "*.pdf"), recursive=True))
manifests = (sorted(glob.glob(os.path.join(testout, "**", "*.json"), recursive=True)) +
             sorted(glob.glob(os.path.join(testout, "**", "*.txt"), recursive=True)))

# All extracted text (PDF text layers + any manifest/text sidecars).
blob = []
for p in pdfs:
    blob.append(sh(pdftext, p))
for m in manifests:
    try:
        blob.append(open(m, "r", errors="ignore").read())
    except Exception:
        pass
alltext = "\n".join(blob)

# Filenames + Finder tags across everything under TESTOUT (years land in the name and/or as a Finder tag).
names = "\n".join(os.path.relpath(p, testout) for p in glob.glob(os.path.join(testout, "**", "*"), recursive=True))
# Tags from the xattr, not Spotlight — see the module docstring. `read_tags` also says whether an empty
# answer is verified-empty or unreadable, so a blind read cannot be reported as a tagging failure.
tag_names, unreadable = [], []
for p in pdfs:
    found, _label, status = read_tags(p)
    tag_names.extend(found)
    if status == UNREADABLE:
        unreadable.append(os.path.relpath(p, testout))
name_tag_blob = names + "\n" + "\n".join(tag_names)

print(f"[assert] TESTOUT={testout}")
print(f"[assert] {len(pdfs)} PDF(s), {len(manifests)} manifest/text file(s)")
for p in pdfs:
    print(f"[assert]   pdf: {os.path.relpath(p, testout)}")
print(f"[assert] Finder tags on output (xattr, no Spotlight): {sorted(set(tag_names)) or '(none)'}")
if unreadable:
    print(f"[assert] WARN: could not READ Finder tags on {len(unreadable)} file(s) — any tag-based check "
          f"below is blind, not failing: {', '.join(unreadable[:5])}")

fails = []
for d in gt:
    tok, yr, f = d["token"], d["year"], d["file"]
    tok_ok = tok in alltext
    yr_ok = (yr in name_tag_blob) or (yr in alltext)
    print(f"[assert] {f}: token '{tok}' {'OK' if tok_ok else 'MISSING'} | year '{yr}' {'OK' if yr_ok else 'MISSING'}")
    if not tok_ok:
        fails.append(f"{f}: OCR token '{tok}' not found in any output (OCR or plumbing broke)")
    if not yr_ok:
        why = "date extraction or tagging broke"
        if unreadable:
            why += (f"; but the tag read FAILED on {len(unreadable)} file(s), so this may be a blind "
                    f"check rather than a real failure — see the WARN above")
        fails.append(f"{f}: year '{yr}' not in any filename/tag/text ({why})")

if not pdfs:
    fails.append("no output PDFs under TESTOUT (finalize did not produce documents)")

if fails:
    print("\n[assert] FAIL:")
    for x in fails:
        print("  -", x)
    sys.exit(1)
print("\n[assert] PASS — all tokens + years present end-to-end")
sys.exit(0)
