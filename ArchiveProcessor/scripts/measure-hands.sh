#!/bin/bash
# Key-free ($0) measurement of the hand placer in the app (W42.int-s5-hands): runs HandLayerMeasureTestDriver headless.
# Each image in <in-dir> (a scratch copy, never the corpus) is written as a handwritten page through PDFGenerator, read
# by the <name>.txt beside it when there is one, else by Apple Vision, and read back through PDFKit; the report gives
# each page's route (placed or the text page by the 0.67 gate), confidence, seconds and peak memory.
#
#   scripts/measure-hands.sh <in-dir> <out-dir> [<model home> [<model source>]]
#
# <model home> stands in for ~/Library/Application Support/Vision OCR (VISIONOCR_MODEL_HOME); with a <model source>
# (a folder holding hands.tgz, as ModelDownloads.Source reads one) the placer is first downloaded into it through the
# app's own download path. Run it under the heavy lock: each page loads blla and McCATMuS (about 3.5 GB).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 2 ] && [ $# -le 4 ] || { echo "usage: scripts/measure-hands.sh <in-dir> <out-dir> [<model home> [<model source>]]" >&2; exit 2; }
in=$(cd "$1" && pwd); mkdir -p "$2"; out=$(cd "$2" && pwd)

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
if [ ! -x "$bin" ]; then
    echo "ArchiveProcessor is not built; run the documented Debug build first." >&2
    exit 1
fi
extra=()
if [ $# -ge 3 ]; then mkdir -p "$3"; extra+=(VISIONOCR_MODEL_HOME="$(cd "$3" && pwd)"); fi
if [ $# -eq 4 ]; then extra+=(VISIONOCR_MODEL_SOURCE="$(cd "$4" && pwd)" HAND_MEASURE_INSTALL=1); fi

work=$(mktemp -d)
report="$work/result.txt"
env ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" HAND_MEASURE=1 HAND_MEASURE_IN="$in" \
    HAND_MEASURE_OUT="$out" HAND_MEASURE_REPORT="$report" ${extra[@]+"${extra[@]}"} "$bin" >"$work/app.log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 3600); do
    [ -f "$report" ] && break
    sleep 1
done
if [ ! -f "$report" ]; then
    echo "Hand placer measurement timed out." >&2
    tail -40 "$work/app.log" >&2
    exit 1
fi
cat "$report"
grep -q '^ALL PASS$' "$report"
