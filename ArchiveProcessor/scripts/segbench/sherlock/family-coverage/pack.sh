#!/bin/bash
# W46.ocr-family-coverage, Mac side: assemble the pack the batch copies to Sherlock, then dry-run its submit script.
#   bash pack.sh [OUT]        (default $AGENT_STATE/artifacts/ocr-family-coverage-20261117)
#   FAMILY_KEYS='deepseek-ocr-2 mineru25-pro' FAMILY_TAG=W46.ocr-family-coverage-rerun bash pack.sh OUT
#                             a rerun: only those keys' candidates go in the pack (same file name), so submit.sh
#                             chains only their jobs; the setup leaves a key already `ready` on scratch as it is
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
CANDS="$S/family-coverage/candidates-family-20261117.json"
if [ -n "${FAMILY_KEYS:-}" ]; then
  # shellcheck disable=SC2086  # FAMILY_KEYS is a word list
  python3 -c '
import json, sys
path, want = sys.argv[1], sys.argv[2:]
c = json.load(open(path))
missing = sorted(set(want) - {x["key"] for x in c})
if missing:
    raise SystemExit(f"FAMILY_KEYS not among the candidates: {missing}")
with open(path, "w") as f:
    json.dump([x for x in c if x["key"] in want], f, indent=1, ensure_ascii=False)
    f.write("\n")
' "$CANDS" $FAMILY_KEYS
  read -r JOBS HOURS KEYS < <(python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
print(1 + sum(len(x["sets"]) for x in c), sum(x["hours_895"] + (x["hours_96"] if "96" in x["sets"] else 0) for x in c),
      ", ".join(x["key"] for x in c))
' "$CANDS")
  TAG="${FAMILY_TAG:?FAMILY_TAG required with FAMILY_KEYS}"
  cat > "$OUT/README.md" <<EOF
# $TAG — $KEYS on the 895 and the 96 (W46.ocr-family-coverage's kit, rerun)

Submit only from an owner-started Sherlock session (the batch runs this unchanged):

    bash <pack>/support/sherlock/family-coverage/submit.sh <pack>

$JOBS jobs: CPU setup (a key already prepared on scratch is left as it is), then per model the 895 on one card
(three-page pilot gate first) and the 96 afterok. $HOURS GPU-hours reserved.
Results: \`\$GROUP_HOME/\$USER/archive-suite/sherlock-results/$(basename "$OUT")/\`.
Size and necessity review: \`execution-plans/items/$TAG.md\` in the repo.
EOF
else
  cat > "$OUT/README.md" <<EOF
# W46.ocr-family-coverage — five OCR families never measured, on the 895 and the 96, and CHURRO on its skipped 455

Submit only from an owner-started Sherlock session (the batch runs this unchanged):

    bash <pack>/support/sherlock/family-coverage/submit.sh <pack>

Twelve jobs: CPU setup (card prompts, snapshots, CHURRO's subset, MinerU's overlay venv, checks), then per model the
895 on one card (three-page pilot gate first) and the 96 afterok; CHURRO-3B reads only the 455. About 9 GPU-hours
expected, 40 reserved. Results: \`\$GROUP_HOME/\$USER/archive-suite/sherlock-results/$(basename "$OUT")/\`.
Size and necessity review: \`execution-plans/items/W46.ocr-family-coverage.md\` in the repo.
EOF
fi
ARCHIVE_UNATTENDED="${ARCHIVE_UNATTENDED:-0}" bash "$S/family-coverage/submit.sh" "$OUT" --dry-run
