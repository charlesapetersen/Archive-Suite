#!/bin/bash
# W46.ocr-new-open-boxes: the two models batch 20261031-131437's setup skipped, submitted again from an owner-started
# Sherlock session (2026-10-31) once their causes were fixed. Causes, from setup-50536481.out:
#   - unlimited-ocr: its remote code imports matplotlib, which the overlay lacked (candidates: matplotlib added).
#   - nemotron-parse-2: pip ResolutionImpossible on torch==2.13.0+cu129, whose nccl pin (2.29.7) the image's 2.30.7
#     breaks (candidates: constraints "none", a --no-deps install of the full pin list; dry runs in job 50549022).
# granite-docling-258m is left alone: it is ready, and its jobs (50536486/7) are running from the first submission.
#   bash <pack>/support/sherlock/new-open-boxes/resubmit-20261031.sh <pack> [--dry-run]
# Run after copying this checkout's candidates, setup-job.sh and submit.sh into the pack. It removes the unlimited-ocr
# overlay (built without matplotlib) so setup rebuilds it, then queues the setup job again and, per model, the 895
# afterok the setup and the 96 afterok its 895, with the first submission's hours and cards. Rows are appended to
# the pack's jobs.tsv as "retry ...", so the batch's collect reads them beside the failed first ones.
set -euo pipefail
PACK="${1:?PACK required}"; DRY="${2:-}"
[ -z "$DRY" ] || [ "$DRY" = --dry-run ] || { echo 'expected --dry-run'; exit 2; }
[ "${ARCHIVE_UNATTENDED:-0}" != 1 ] || { echo 'Sherlock needs an owner-attended session'; exit 2; }
PACK="$(cd "$PACK" && pwd)"; NAME="$(basename "$PACK")"
SH_DIR="$PACK/support/sherlock"; CANDS="$SH_DIR/new-open-boxes/candidates-boxes-20261031.json"
source "$SH_DIR/sh.env"
ROOT="$FS_ROOT/$NAME"; TSV="$ROOT/jobs.tsv"
grep -q matplotlib "$CANDS" && grep -q '"constraints": "none"' "$CANDS" ||
  { echo "the pack's candidates are not the fixed ones: copy them in first"; exit 2; }
grep -q 'retry setup' "$TSV" 2>/dev/null && { echo "$TSV has a retry already: inspect it"; exit 2; }
run() { if [ "$DRY" = --dry-run ]; then printf '%q ' "$@" >&2; printf '\n' >&2; echo 0; else "$@"; fi; }
record() {
  [[ "$2" =~ ^[0-9]+$ ]] || { echo 'invalid job id'; exit 2; }
  if [ "$DRY" = --dry-run ]; then printf 'retry %s\t%s\n' "$1" "$2" >&2; else printf 'retry %s\t%s\n' "$1" "$2" >> "$TSV"; fi
}
[ "$DRY" = --dry-run ] || rm -rf "$GROUP_HOME/$USER/envs/boxes-unlimited-ocr" "$GROUP_HOME/$USER/envs/boxes-nemotron-parse-2"
export NEW_OPEN_RESULTS="$GROUP_HOME/$USER/archive-suite/sherlock-results/$NAME"
setup=$(run sbatch --parsable --partition=normal --cpus-per-task=4 --mem=32G --time=04:00:00 --job-name=boxes-setup \
  --output="$ROOT/logs/setup-%j.out" "$SH_DIR/new-open-boxes/setup-job.sh" "$SH_DIR" "$CANDS")
record setup "$setup"
ids="setup $setup"
for key in unlimited-ocr nemotron-parse-2; do
  read -r h895 h96 < <(python3 -c 'import json,sys
c=[x for x in json.load(open(sys.argv[1])) if x["key"]==sys.argv[2]][0];print(int(c["hours_895"]),int(c["hours_96"]))' \
    "$CANDS" "$key")
  g=(--partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G)
  a=$(run sbatch --parsable "${g[@]}" --time="$h895:00:00" --dependency="afterok:$setup" --job-name="boxes-895-$key" \
    --output="$ROOT/logs/slurm-895-$key-%j.out" "$SH_DIR/new-open-boxes/job.sh" "$SH_DIR" 895 "$key")
  record "895 $key" "$a"
  b=$(run sbatch --parsable "${g[@]}" --time="$h96:00:00" --dependency="afterok:$a" --job-name="boxes-96-$key" \
    --output="$ROOT/logs/slurm-96-$key-%j.out" "$SH_DIR/new-open-boxes/job.sh" "$SH_DIR" 96 "$key")
  record "96 $key" "$b"
  ids="$ids, $key $a/$b"
done
echo "submitted: $ids; results: $NEW_OPEN_RESULTS"
