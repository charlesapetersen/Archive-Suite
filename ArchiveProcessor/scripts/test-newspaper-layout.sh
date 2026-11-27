#!/bin/bash
# W46.layout-newspapers: key-free, no-wire scratch functional checks and a pixel render. Optional public model
# files exercise the real detector in the installed shared runtime without installing into the owner's model home.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"
set -euo pipefail
cd "$(dirname "$0")/.."
. ../ops/autonomous/heavy-enter.sh
bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
work=$(mktemp -d)
source scripts/test-child.sh
processor_test_init "$work"
report="$work/report.txt"
shot="${NEWSPAPER_RENDER_OUT:-/tmp/W46.layout-newspapers-download.png}"
if [ -n "${NEWSPAPER_MODEL_FILES:-}" ]; then
    home="$work/models"
    snapshot="$home/Models/hub/models--HashNuke--pp-doclayout-v3-mlx/snapshots/cd50996ad0c7e35a7e20c27480f99cec1822cf7b"
    mkdir -p "$snapshot"
    runtime="$HOME/Library/Application Support/ArchiveSuite/VisionOCRKit/Runtime"
    [ -x "$runtime/bin/python3" ] || { echo 'Missing shared runtime'; exit 1; }
    ln -s "$runtime" "$home/Runtime"
    cp "$NEWSPAPER_MODEL_FILES/config.json" "$NEWSPAPER_MODEL_FILES/model.safetensors" "$snapshot/"
    python3 - "$snapshot" <<'PY'
import hashlib,sys
from pathlib import Path
p=Path(sys.argv[1])
for name,expected in [('config.json','3cf834b91d23a756b1519bce4db42c09e852f3e35c35092dd5a3e253a50c071a'),('model.safetensors','57d0def397166f9518572b7a01472e2d23c14de0455f1b82fae465a78ca6d9e5')]:
    assert hashlib.sha256((p/name).read_bytes()).hexdigest()==expected,name
PY
    export VISIONOCR_MODEL_HOME="$home" NEWSPAPER_REAL_DETECTOR=1
fi
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" NEWSPAPER_TEST=1 \
    NEWSPAPER_TEST_OUT="$report" NEWSPAPER_RENDER="$shot" processor_test_start pid "$bin" > "$work/app.log" 2>&1
source scripts/test-report-wait.sh
wait_for_test_report "$report" "$work/app.log" "$pid" newspaper NEWSPAPER 180
cat "$report"
grep -q '^ALL PASS$' "$report"
echo "ARTIFACT download row: $shot"
