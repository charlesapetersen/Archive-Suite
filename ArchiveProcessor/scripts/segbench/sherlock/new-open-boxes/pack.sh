#!/bin/bash
# W46.ocr-new-open-boxes, Mac side: assemble the pack the batch copies to Sherlock, then dry-run its submit script.
#   bash pack.sh [OUT]        (default $AGENT_STATE/artifacts/new-open-boxes-20261031)
# The pack is this kit's files only: the pages and images are the ones W46.ocr-new-open used, already in $FS_ROOT on
# Sherlock (the manifest's `requires`), so nothing from the corpus is copied.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; SH="$(cd "$HERE/.." && pwd)"
OUT="${1:-${AGENT_STATE:?AGENT_STATE or OUT required}/artifacts/new-open-boxes-20261031}"
[ ! -e "$OUT" ] || { echo "$OUT exists: inspect it, then remove it or pick another folder"; exit 2; }
mkdir -p "$OUT/support/sherlock/bin" "$OUT/support/sherlock/new-open-boxes"
cp -p "$SH/sh.env" "$OUT/support/sherlock/"; cp -p "$SH/bin/py" "$OUT/support/sherlock/bin/"
for f in setup-job.sh job.sh submit.sh boxes_run.py boxes_parse.py boxes_setup.py candidates-boxes-20261031.json; do
  cp -p "$HERE/$f" "$OUT/support/sherlock/new-open-boxes/"
done
cat > "$OUT/README.md" <<EOF
# W46.ocr-new-open-boxes — Unlimited-OCR, Nemotron-Parse 2.0 and granite-docling-258M on the 895 and the 96

Submit only from an owner-started Sherlock session (the batch runs this unchanged):

    bash <pack>/support/sherlock/new-open-boxes/submit.sh <pack>

Seven jobs: CPU setup (venvs, snapshots, import checks), then per model the 895 on one card (three-page pilot
gate first) and the 96 afterok. About 10 GPU-hours expected, 52 reserved. Results:
\`\$GROUP_HOME/\$USER/archive-suite/sherlock-results/$(basename "$OUT")/\`.
Size and necessity review: \`execution-plans/items/W46.ocr-new-open-boxes.md\` in the repo.
EOF
ARCHIVE_UNATTENDED="${ARCHIVE_UNATTENDED:-0}" bash "$OUT/support/sherlock/new-open-boxes/submit.sh" "$OUT" --dry-run
