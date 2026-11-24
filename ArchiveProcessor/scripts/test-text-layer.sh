#!/bin/bash
# Key-free ($0) self-test of the image page's searchable layer (W42.int-s5): runs TextLayerTestDriver headless. It
# draws its pages in a scratch folder, writes each output through PDFGenerator (Apple Vision for real, no model call,
# no network), and reads the PDFs back through PDFKit. Never the corpus, no window.
#
#   scripts/test-text-layer.sh        (TEXTLAYER_TEST_KEEP=<dir> keeps the layered PDFs there)
#   TEXTLAYER_CATALOGUE_ONLY=preservation scripts/test-text-layer.sh  (only the scratch preservation filing checks)
#
# When veraPDF is installed (/opt/homebrew/bin/verapdf), every kept output is validated as PDF/A-2b too (W42.int-s5).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox
set -euo pipefail
cd "$(dirname "$0")/.."

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
if [ ! -x "$bin" ]; then
    echo "ArchiveProcessor is not built; run the documented Debug build first." >&2
    exit 1
fi

work=$(mktemp -d)
source "$PWD/scripts/test-child.sh"
processor_test_init "$work"
report="$work/result.txt"
log="$work/app.log"
keep="${TEXTLAYER_TEST_KEEP:-$work/keep}"
mkdir -p "$keep"
TMPDIR="$work" ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    TEXTLAYER_TEST=1 TEXTLAYER_TEST_OUT="$report" TEXTLAYER_TEST_KEEP="$keep" \
    TEXTLAYER_TEST_STATE="$work/state" processor_test_start pid "$bin" >"$log" 2>&1

for _ in $(seq 1 180); do
    [ -f "$report" ] && break
    sleep 1
done
if [ ! -f "$report" ]; then
    echo "Text layer test timed out." >&2
    tail -40 "$log" >&2
    exit 1
fi
cat "$report"
status=0
grep -q '^ALL PASS$' "$report" || status=1
verapdf=/opt/homebrew/bin/verapdf
if [ -x "$verapdf" ]; then
    for pdf in "$keep"/*.pdf; do
        if "$verapdf" --flavour 2b "$pdf" 2>/dev/null | grep -q 'isCompliant="true"'; then
            echo "PASS veraPDF: $(basename "$pdf") is PDF/A-2b"
        else
            echo "FAIL veraPDF: $(basename "$pdf") is not PDF/A-2b"; status=1
        fi
    done
else
    echo "NOTE veraPDF not installed: PDF/A-2b not validated"
fi
exit $status
