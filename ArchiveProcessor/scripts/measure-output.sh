#!/bin/bash
# Key-free ($0) measurement of the output forms on a smoke set (W42.int-s5 step 7): runs OutputMeasureTestDriver
# headless. Each image in <in-dir> (a scratch copy, never the corpus) and a drawn memo page is read by Apple Vision and
# written as image-plus-text with the layer, with the layer unstraightened, and without one; each is read back through
# PDFKit with Finder tags, and the layered outputs are merged. Then, when built, Vision OCR 1.16.0's searchable PDF
# of the same files (packages/VisionOCRKit `visionocr-pdf`), and veraPDF on every output when it is installed.
#
#   scripts/measure-output.sh <in-dir> <out-dir>
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -eq 2 ] || { echo "usage: scripts/measure-output.sh <in-dir> <out-dir>" >&2; exit 2; }
in=$(cd "$1" && pwd); mkdir -p "$2"; out=$(cd "$2" && pwd)

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
if [ ! -x "$bin" ]; then
    echo "ArchiveProcessor is not built; run the documented Debug build first." >&2
    exit 1
fi

work=$(mktemp -d)
report="$work/result.txt"
env ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" OUTPUT_MEASURE=1 OUTPUT_MEASURE_IN="$in" \
    OUTPUT_MEASURE_OUT="$out/processor" OUTPUT_MEASURE_REPORT="$report" "$bin" >"$work/app.log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 900); do
    [ -f "$report" ] && break
    sleep 1
done
if [ ! -f "$report" ]; then
    echo "Output measurement timed out." >&2
    tail -40 "$work/app.log" >&2
    exit 1
fi
cat "$report"
status=0
grep -q '^ALL PASS$' "$report" || status=1

tool=../packages/VisionOCRKit/.build/release/visionocr-pdf
if [ -x "$tool" ]; then
    echo "VISIONOCR-1.16.0	bytes	seconds	outcome	input"
    "$tool" "$out/visionocr" "$out/processor/smoke-memo.jpg" "$in"/* | sed 's/^/VISIONOCR-1.16.0	/' || status=1
else
    echo "NOTE visionocr-pdf not built (swift build -c release -Xswiftc -enable-testing --product visionocr-pdf)"
fi

verapdf=/opt/homebrew/bin/verapdf
if [ -x "$verapdf" ]; then
    for pdf in "$out"/processor/*.pdf; do
        if "$verapdf" --flavour 2b "$pdf" 2>/dev/null | grep -q 'isCompliant="true"'; then
            echo "PASS veraPDF: $(basename "$pdf") is PDF/A-2b"
        else
            echo "FAIL veraPDF: $(basename "$pdf") is not PDF/A-2b"; status=1
        fi
    done
fi
exit $status
