#!/bin/bash
# W46.ocr-family-coverage, Mac side: assemble the pack the batch copies to Sherlock, then dry-run its submit script.
#   bash pack.sh [OUT]        (default $AGENT_STATE/artifacts/ocr-family-coverage-20261117)
# The pack is this kit's files and the two kits it builds on (new-open-boxes' runner and setup, new-open's
# prompt_source): the pages and images are the ones W46.ocr-new-open used, already in $FS_ROOT on Sherlock (the
# manifest's `requires`), so nothing from the corpus is copied.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; SH="$(cd "$HERE/.." && pwd)"
OUT="${1:-${AGENT_STATE:?AGENT_STATE or OUT required}/artifacts/ocr-family-coverage-20261117}"
[ ! -e "$OUT" ] || { echo "$OUT exists: inspect it, then remove it or pick another folder"; exit 2; }
S="$OUT/support/sherlock"
mkdir -p "$S/bin" "$S/family-coverage" "$S/new-open-boxes" "$S/new-open"
cp -p "$SH/sh.env" "$S/"; cp -p "$SH/bin/py" "$S/bin/"
for f in setup-job.sh job.sh submit.sh family_run.py family_parse.py family_setup.py churro-added455.txt \
         candidates-family-20261117.json; do
  cp -p "$HERE/$f" "$S/family-coverage/"
done
for f in boxes_run.py boxes_parse.py boxes_setup.py; do cp -p "$SH/new-open-boxes/$f" "$S/new-open-boxes/"; done
cp -p "$SH/new-open/prompt_source.py" "$S/new-open/"
cat > "$OUT/README.md" <<EOF
# W46.ocr-family-coverage — five OCR families never measured, on the 895 and the 96, and CHURRO on its skipped 455

Submit only from an owner-started Sherlock session (the batch runs this unchanged):

    bash <pack>/support/sherlock/family-coverage/submit.sh <pack>

Twelve jobs: CPU setup (card prompts, snapshots, CHURRO's subset, MinerU's overlay venv, checks), then per model the
895 on one card (three-page pilot gate first) and the 96 afterok; CHURRO-3B reads only the 455. About 9 GPU-hours
expected, 40 reserved. Results: \`\$GROUP_HOME/\$USER/archive-suite/sherlock-results/$(basename "$OUT")/\`.
Size and necessity review: \`execution-plans/items/W46.ocr-family-coverage.md\` in the repo.
EOF
ARCHIVE_UNATTENDED="${ARCHIVE_UNATTENDED:-0}" bash "$S/family-coverage/submit.sh" "$OUT" --dry-run
