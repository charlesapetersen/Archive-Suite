#!/bin/bash
# W47.wh-mixed-preflag: the app's mixed-page pre-flag against ATRIUM as W46.kind-atrium ran it (PyTorch), on the 144
# owner-labelled pages.
#
#   ArchiveProcessor/scripts/segbench/mixed_preflag_parity.sh
#
# Needs the Debug Processor built, kind_atrium.py's saved run (`kind-atrium/k144.npz`) and the 144 pages in the bench
# cache, and the download packages/VisionOCRKit/ops/make-atrium.sh made, in $MIXED_PREFLAG_SOURCE (default the
# autonomous state's model-files/atrium-build). The app installs it into a scratch model home through its own installer
# (checked against the pinned size and SHA-256), reads every page, and the comparison is written to
# segbench-results/mixed-preflag-parity.md (MIXED_PREFLAG_PAGES=n reads only the first n, for a quick look).
# The pages are only read. No reader, no money.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/require-unsandboxed.sh"
set -euo pipefail
cd "$(dirname "$0")/../.."
CACHE="${ARCHIVE_BENCH_CACHE:-$HOME/Library/Caches/ArchiveSuiteRehearsal}"
src="${MIXED_PREFLAG_SOURCE:-$HOME/.local/state/archive-autonomous/model-files/atrium-build}"
[ -f "$src/atrium-page-kind.tgz" ] || { echo "Run packages/VisionOCRKit/ops/make-atrium.sh first"; exit 1; }
[ -f "$CACHE/kind-atrium/k144.npz" ] || { echo "No kind_atrium.py run at $CACHE/kind-atrium"; exit 1; }
PY="$(scripts/segbench/torch-env.sh)"
work=$(mktemp -d)
trap 'mv "$work" "$HOME/.Trash/mixed-preflag-parity-$$" 2>/dev/null || true' EXIT
"$PY" - "$CACHE/kind-classifier/labels.tsv" "$work/pages.tsv" "${MIXED_PREFLAG_PAGES:-}" <<'PY'
import csv, sys
from pathlib import Path
rows = [r for r in csv.DictReader(open(sys.argv[1]), delimiter='\t') if not r['set'].startswith('ladder')]
assert len(rows) == 144 and all(Path(r['file']).exists() for r in rows), len(rows)
n = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else len(rows)
Path(sys.argv[2]).write_text(''.join(f"{r['id']}\t{r['file']}\n" for r in rows[:n]))
PY
export MIXED_PREFLAG_LIST="$work/pages.tsv" MIXED_PREFLAG_OUT="$work/app.tsv" MIXED_PREFLAG_HOME="$work/home" \
    VISIONOCR_MODEL_SOURCE="$src"
OCRPAGEKIND_WAIT=2400 PAGE_KIND_PARITY=0 PAGE_KIND_PIN=0 scripts/test-ocr-page-kind.sh
"$PY" scripts/segbench/mixed_preflag_parity.py "$CACHE/kind-atrium/k144.npz" "$work/app.tsv" \
    --report segbench-results/mixed-preflag-parity.md
