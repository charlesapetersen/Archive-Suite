#!/bin/bash
# W46.layout-partition-score, step 1: the app's own newspaper plans for the 15 L9 scans.
#
#   ArchiveProcessor/scripts/segbench/layout_partition_plans.sh
#
# Runs the Debug Processor headless with NEWSPAPER_PLAN_DUMP (NewspaperLayoutTestDriver.dumpPlans): the kind gate,
# NewspaperPagePlan.prepare with the real PP-DocLayoutV3 detector, and the exact region and fill images it hands a
# reader, copied to $WORK/plans/<page>/. The frozen originals are only read. The detector runs from a scratch model
# home: the shared runtime linked in, and the lab's PP-DocLayoutV3 MLX copy, whose 857 tensors W46.layout-newspapers
# found equal to the app's pinned snapshot (the files differ in header bytes only). No reader, network or money.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/require-unsandboxed.sh"
set -euo pipefail
cd "$(dirname "$0")/../.."
. ../ops/autonomous/heavy-enter.sh
WORK="${ARCHIVE_BENCH_CACHE:-$HOME/Library/Caches/ArchiveSuiteRehearsal}/layout-partition-score"
bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
lab="$HOME/.local/share/visionocr-ocrlab/layout/pp-doclayout-v3-mlx"
runtime="$HOME/Library/Application Support/ArchiveSuite/VisionOCRKit/Runtime"
[ -x "$bin" ] || { echo "Build the Debug Processor first"; exit 1; }
[ -x "$runtime/bin/python3" ] || { echo 'Missing shared runtime'; exit 1; }
home="$WORK/model-home"
snapshot="$home/Models/hub/models--HashNuke--pp-doclayout-v3-mlx/snapshots/cd50996ad0c7e35a7e20c27480f99cec1822cf7b"
mkdir -p "$snapshot" "$WORK/plans"
[ -e "$home/Runtime" ] || ln -s "$runtime" "$home/Runtime"
for f in config.json model.safetensors; do [ -e "$snapshot/$f" ] || ln -s "$lab/$f" "$snapshot/$f"; done
python3 - "$lab" "$WORK/pages.tsv" "$HOME/Library/Caches/ArchiveSuiteRehearsal/layout-photo/pages.jsonl" <<'PY'
import hashlib, json, struct, sys
from pathlib import Path
lab, out, pages = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
assert hashlib.sha256((lab / 'config.json').read_bytes()).hexdigest() == \
    '3cf834b91d23a756b1519bce4db42c09e852f3e35c35092dd5a3e253a50c071a', 'config differs from the pin'
with open(lab / 'model.safetensors', 'rb') as f:
    n = struct.unpack('<Q', f.read(8))[0]
    tensors = [k for k in json.loads(f.read(n)) if k != '__metadata__']
assert len(tensors) == 857, len(tensors)
rows = [json.loads(x) for x in pages.read_text().splitlines() if x.strip()]
rows = [r for r in rows if r.get('stratum') == 'L9']
assert len(rows) == 15, len(rows)
for r in rows:
    assert hashlib.sha256(Path(r['image']).read_bytes()).hexdigest() == r['image_sha256'], r['id']
out.write_text(''.join(f"{r['id']}\t{r['image']}\n" for r in rows))
print(len(rows), 'L9 pages, originals checked by sha256')
PY
work=$(mktemp -d)
source scripts/test-child.sh
processor_test_init "$work"
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" VISIONOCR_MODEL_HOME="$home" \
    NEWSPAPER_PLAN_DUMP="$WORK/pages.tsv" NEWSPAPER_PLAN_OUT="$WORK/plans" \
    processor_test_start pid "$bin" > "$work/app.log" 2>&1
source scripts/test-report-wait.sh
wait_for_test_report "$WORK/plans/report.txt" "$work/app.log" "$pid" newspaper-plans NEWSPAPER 1800
cat "$WORK/plans/report.txt"
grep -q '^ALL PASS$' "$WORK/plans/report.txt"
