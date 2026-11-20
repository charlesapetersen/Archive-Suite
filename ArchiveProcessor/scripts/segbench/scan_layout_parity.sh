#!/bin/bash
# W47.wh-yolo-scans: the app's scanned-newspaper detector against the route W46.ocr-regions measured, on the 15 L9 scans.
#
#   ArchiveProcessor/scripts/segbench/scan_layout_parity.sh
#
# Needs $WORK (below) as packages/VisionOCRKit/ops/make-scan-newspaper-layout.sh leaves it: the conversion venv, the
# newspaper-ocr checkout, the pinned checkpoint and doclayout-yolo-1280.tgz. Runs the measured route itself
# (scan_layout_parity.py oracle, PyTorch), installs the download into a scratch model home through the app's own
# installer path (the archive is checked against the pinned size and SHA-256 by `ModelDownloads`), runs the Debug
# Processor headless with SCAN_LAYOUT_DUMP, and compares. The frozen originals are only read. No reader, no money.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/require-unsandboxed.sh"
set -euo pipefail
cd "$(dirname "$0")/../.."
. ../ops/autonomous/heavy-enter.sh
WORK="${ARCHIVE_BENCH_CACHE:-$HOME/Library/Caches/ArchiveSuiteRehearsal}/wh-yolo-scans"
bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
runtime="$HOME/Library/Application Support/Vision OCR/Runtime"
[ -x "$bin" ] || { echo "Build the Debug Processor first"; exit 1; }
[ -x "$runtime/bin/python3" ] || { echo 'Missing shared runtime'; exit 1; }
[ -f "$WORK/doclayout-yolo-1280.tgz" ] || { echo "Run make-scan-newspaper-layout.sh first"; exit 1; }
python3 - "$WORK/pages.tsv" "$HOME/Library/Caches/ArchiveSuiteRehearsal/layout-photo/pages.jsonl" <<'PY'
import hashlib, json, sys
from pathlib import Path
out, pages = Path(sys.argv[1]), Path(sys.argv[2])
rows = [json.loads(x) for x in pages.read_text().splitlines() if x.strip()]
rows = [r for r in rows if r.get('stratum') == 'L9']
assert len(rows) == 15, len(rows)
for r in rows:
    assert hashlib.sha256(Path(r['image']).read_bytes()).hexdigest() == r['image_sha256'], r['id']
out.write_text(''.join(f"{r['id']}\t{r['image']}\n" for r in rows))
print(len(rows), 'L9 pages, originals checked by sha256')
PY
[ -f "$WORK/oracle.json" ] || HF_HUB_CACHE="$WORK/hub" HF_HUB_OFFLINE=1 "$WORK/venv/bin/python" \
    scripts/segbench/scan_layout_parity.py oracle --npo "$WORK/npo/src" --pages "$WORK/pages.tsv" --out "$WORK/oracle.json"
home="$WORK/model-home"
mkdir -p "$home/Models" "$WORK/app"
[ -e "$home/Runtime" ] || ln -s "$runtime" "$home/Runtime"
if [ ! -d "$home/Models/doclayout-yolo-1280.mlmodelc" ]; then
    python3 - "$WORK/doclayout-yolo-1280.tgz" <<'PY'
import hashlib, sys
data = open(sys.argv[1], 'rb').read()
assert len(data) == 64_147_778 and hashlib.sha256(data).hexdigest() == \
    '99c62ee608f9f5d63fcaf21295d102b918c1545d6b6f275dac2d8669de8eeec9', 'the archive is not the pinned download'
PY
    tar -xzf "$WORK/doclayout-yolo-1280.tgz" -C "$home/Models"
fi
work=$(mktemp -d)
source scripts/test-child.sh
processor_test_init "$work"
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" VISIONOCR_MODEL_HOME="$home" \
    SCAN_LAYOUT_DUMP="$WORK/pages.tsv" SCAN_LAYOUT_OUT="$WORK/app" \
    processor_test_start pid "$bin" > "$work/app.log" 2>&1
source scripts/test-report-wait.sh
wait_for_test_report "$WORK/app/report.txt" "$work/app.log" "$pid" scan-layout SCAN_LAYOUT 900
cat "$WORK/app/report.txt"
grep -q '^ALL PASS$' "$WORK/app/report.txt"
python3 scripts/segbench/scan_layout_parity.py compare "$WORK/oracle.json" "$WORK/app" \
    --report segbench-results/scan-layout-parity.md --min-share "${SCAN_LAYOUT_MIN_SHARE:-1}"
