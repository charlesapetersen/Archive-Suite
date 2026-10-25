#!/bin/bash
# Run from an owner-started Sherlock session only. Three jobs: CPU stage + two
# independent one-GPU capability pilots. The nine-page bank is NOT submitted.
# bash regions-cells-submit.sh GROUP_PACK [--dry-run]
set -euo pipefail
SOURCE="${1:?GROUP_PACK required}"; DRY="${2:-}"
[ -z "$DRY" ] || [ "$DRY" = --dry-run ] || { echo 'expected --dry-run'; exit 2; }
if [ "${ARCHIVE_UNATTENDED:-0}" = 1 ] && [ "$DRY" != --dry-run ]; then
  echo 'Sherlock needs an owner-attended session; engine sessions may only dry-run'; exit 2
fi
CORPUS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH_DIR="$(cd "$CORPUS/../sherlock" && pwd)"
source "$SH_DIR/sh.env"
ROOT="$FS_ROOT/ocr-regions-cells-20261025"
[ -s "$SOURCE/freeze.json" ] && [ -s "$SOURCE/truth.json" ] || { echo 'prepared source pack required'; exit 2; }
if [ "$DRY" = --dry-run ]; then
  # Local-only verification. Never contacts the cluster or creates a remote-shaped tree.
  python3 "$CORPUS/regions_cells.py" check --root "$SOURCE"
  TSV=''
else
  mkdir -p "$ROOT/logs"
  TSV="$ROOT/jobs.tsv"
  # Reserve before sbatch: another invocation cannot silently submit the same work.
  (set -o noclobber; : > "$TSV") || { echo 'jobs.tsv exists: inspect existing submissions'; exit 2; }
fi
run() {
  if [ "$DRY" = --dry-run ]; then printf '%q ' "$@" >&2; printf '\n' >&2; echo 0
  else "$@"; fi
}
record() {
  [[ "$2" =~ ^[0-9]+$ ]] || { echo 'invalid job id'; exit 2; }
  if [ "$DRY" = --dry-run ]; then printf '%s\t%s\n' "$1" "$2" >&2
  else printf '%s\t%s\n' "$1" "$2" >> "$TSV"; fi
}
stage=$(run sbatch --parsable --output="$ROOT/logs/stage-%j.out" "$CORPUS/regions-cells-stage-job.sh" "$SOURCE" "$ROOT" "$SH_DIR")
record stage "$stage"
for route in glm-ocr qwen3.6-27b; do
  job=$(run sbatch --parsable --partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G --time=01:00:00 \
    --dependency="afterok:$stage" --job-name="cells-$route" --output="$ROOT/logs/slurm-%j.out" \
    "$CORPUS/regions-cells-job.sh" "$ROOT" "$route")
  record "$route" "$job"
done
