#!/bin/bash
# W46.layout-photo: submit from an owner-started Sherlock session only; nothing waits on the login node.
#   bash layout-photo-submit.sh GROUP_PACK [--dry-run]
# One CPU stage job; an eight-page GLM-OCR pilot (one page of every Real5 condition, every arm) afterok the stage;
# two GLM-OCR shards afterok the pilot, so a broken pack or reader stops the chain before the GPU hours. GLM-OCR
# read W46.ocr-regions' 5,449 crops in 329 s on one card; this pack's crop count is in freeze.json, and each shard
# has a three-hour wall for about one hour of reading. Job ids: <scratch root>/jobs.tsv. --dry-run (the engine's
# only mode) checks the pack locally and prints the sbatch lines; it never contacts the cluster.
set -euo pipefail
SOURCE="${1:?GROUP_PACK required}"; DRY="${2:-}"
[ -z "$DRY" ] || [ "$DRY" = --dry-run ] || { echo 'expected --dry-run'; exit 2; }
if [ "${ARCHIVE_UNATTENDED:-0}" = 1 ] && [ "$DRY" != --dry-run ]; then
  echo 'Sherlock needs an owner-attended session; engine sessions may only dry-run'; exit 2
fi
CORPUS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH_DIR="$(cd "$CORPUS/../sherlock" && pwd)"
[ -s "$SOURCE/freeze.json" ] && [ -s "$SOURCE/pages.jsonl" ] || { echo 'prepared source pack required'; exit 2; }
SOURCE="$(cd "$SOURCE" && pwd)"
if [ "$DRY" = --dry-run ]; then
  python3 "$CORPUS/layout_photo_cluster.py" check --root "$SOURCE"
  ROOT="/scratch/users/cp1/fs-ocr/$(basename "$SOURCE")"; TSV=''
  SH_GPU_C='GPU_MEM:48GB|GPU_MEM:80GB'
else
  source "$SH_DIR/sh.env"
  ROOT="$FS_ROOT/$(basename "$SOURCE")"
  mkdir -p "$ROOT/logs"
  TSV="$ROOT/jobs.tsv"
  (set -o noclobber; : > "$TSV") || { echo 'jobs.tsv exists: inspect existing submissions'; exit 2; }
fi
run() { if [ "$DRY" = --dry-run ]; then printf '%q ' "$@" >&2; printf '\n' >&2; echo 0; else "$@"; fi; }
record() {
  [[ "$2" =~ ^[0-9]+$ ]] || { echo 'invalid job id'; exit 2; }
  if [ "$DRY" = --dry-run ]; then printf '%s\t%s\n' "$1" "$2" >&2; else printf '%s\t%s\n' "$1" "$2" >> "$TSV"; fi
}
JOB="$CORPUS/layout-photo-job.sh"
gpu=(--partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G --output="$ROOT/logs/slurm-%j.out")
stage=$(run sbatch --parsable --output="$ROOT/logs/stage-%j.out" "$CORPUS/layout-photo-stage-job.sh" "$SOURCE" "$ROOT" "$SH_DIR")
record stage "$stage"
pilot=$(run sbatch --parsable "${gpu[@]}" --time=00:30:00 --dependency="afterok:$stage" --job-name=layout-photo-pilot \
  "$JOB" "$ROOT" 0/1 8)
record pilot "$pilot"
for i in 0 1; do
  id=$(run sbatch --parsable "${gpu[@]}" --time=03:00:00 --dependency="afterok:$pilot" --job-name="layout-photo-$i" \
    "$JOB" "$ROOT" "$i/2")
  record "glm-ocr $i/2" "$id"
done
