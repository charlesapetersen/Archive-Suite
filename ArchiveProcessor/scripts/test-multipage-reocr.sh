#!/bin/bash
# Key-free ($0) synthetic regression for the multi-page-PDF re-OCR mode: renders synthetic
# multi-page PDFs, injects a fake per-page OCR result (no network), and asserts the rebuilt output
# PDF alternates image/OCR-text pages in order and never overwrites the input. Headless self-test
# (MULTIPAGE_REOCR_TEST=1), scratch-isolated to a mktemp dir — never the corpus.
set -euo pipefail
cd "$(dirname "$0")/.."

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
if [ ! -x "$bin" ]; then
    echo "ArchiveProcessor is not built; run the documented Debug build first." >&2
    exit 1
fi

work=$(mktemp -d)
report="$work/result.txt"
log="$work/app.log"
ARCHIVEPROC_HEADLESS=1 \
    MULTIPAGE_REOCR_TEST=1 MULTIPAGE_REOCR_TEST_OUT="$report" \
    "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 60); do
    [ -f "$report" ] && break
    sleep 1
done

if [ ! -f "$report" ]; then
    echo "Multi-page re-OCR test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi

cat "$report"
grep -q '^ALL PASS$' "$report"
