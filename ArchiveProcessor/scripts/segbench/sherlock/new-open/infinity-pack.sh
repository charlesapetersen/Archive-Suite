#!/bin/bash
# W46.ocr-new-open-sherlock, Mac side: assemble the pack the batch copies to Sherlock, then dry-run its submit script.
#   bash infinity-pack.sh [OUT]        (default $AGENT_STATE/artifacts/new-open-sherlock-20261031)
# The pack is this kit's files only: the pages, images and runners are the ones W46.ocr-new-open used, already in
# $FS_ROOT on Sherlock (the manifest's `requires`), so nothing from the corpus is copied.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; SH="$(cd "$HERE/.." && pwd)"; CORPUS="$(cd "$SH/../corpus" && pwd)"
OUT="${1:-${AGENT_STATE:?AGENT_STATE or OUT required}/artifacts/new-open-sherlock-20261031}"
[ ! -e "$OUT" ] || { echo "$OUT exists: inspect it, then remove it or pick another folder"; exit 2; }
mkdir -p "$OUT/support/sherlock/bin" "$OUT/support/sherlock/new-open" "$OUT/support/corpus"
cp -p "$SH/sh.env" "$OUT/support/sherlock/"; cp -p "$SH/bin/py" "$SH/bin/vllm" "$OUT/support/sherlock/bin/"
for f in setup-job.sh job.sh prompt_source.py candidates-infinity-20261031.json infinity-submit.sh; do
  cp -p "$HERE/$f" "$OUT/support/sherlock/new-open/"
done
cp -p "$CORPUS/open_sweep_setup.py" "$OUT/support/corpus/"
cat > "$OUT/README.md" <<EOF
# W46.ocr-new-open-sherlock — Infinity-Parser2-Pro on the 895 and the 96

Submit only from an owner-started Sherlock session (the batch runs this unchanged):

    bash <pack>/support/sherlock/new-open/infinity-submit.sh <pack>

Three jobs: CPU setup, the 895 on two cards (three-page pilot gate first), the 96 afterok. About 3 GPU-hours
expected, 16 reserved. Results: \`\$GROUP_HOME/\$USER/archive-suite/sherlock-results/$(basename "$OUT")/\`.
Size and necessity review: \`execution-plans/items/W46.ocr-new-open-sherlock.md\` in the repo.
EOF
ARCHIVE_UNATTENDED="${ARCHIVE_UNATTENDED:-0}" bash "$OUT/support/sherlock/new-open/infinity-submit.sh" "$OUT" --dry-run
