#!/bin/bash
# Key-free ($0) self-test of the image page's searchable layer (W42.int-s5): runs TextLayerTestDriver headless. It
# draws its pages in a scratch folder, writes each output through PDFGenerator (Apple Vision for real, no model call,
# no network), and reads the PDFs back through PDFKit. Never the corpus, no window.
#
#   scripts/test-text-layer.sh        (TEXTLAYER_TEST_KEEP=<dir> keeps the layered PDFs there)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox
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
env ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    TEXTLAYER_TEST=1 TEXTLAYER_TEST_OUT="$report" ${TEXTLAYER_TEST_KEEP:+TEXTLAYER_TEST_KEEP="$TEXTLAYER_TEST_KEEP"} "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

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
grep -q '^ALL PASS$' "$report"
