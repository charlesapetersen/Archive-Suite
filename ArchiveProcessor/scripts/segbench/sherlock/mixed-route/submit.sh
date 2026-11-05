#!/bin/bash
# W46.mixed-route: submit from an owner-started Sherlock session only; nothing waits on the login node.
#   bash support/mixed-route/submit.sh PACK [--dry-run]
# One CPU stage job; GLM-OCR afterok the stage (it is also the pilot: about 100 requests, a one-hour wall); then
# Qwen3.6-27B afterok GLM-OCR, so a broken pack or request stops the chain before the larger model loads (a
# two-hour wall). GPU ceiling 3 hours; the request count is in freeze.json. Job ids: <scratch root>/jobs.tsv.
# --dry-run (the engine's only mode) checks the pack locally and prints the sbatch lines; it never contacts the cluster.
set -euo pipefail
SOURCE="${1:?PACK required}"; DRY="${2:-}"
[ -z "$DRY" ] || [ "$DRY" = --dry-run ] || { echo 'expected --dry-run'; exit 2; }
if [ "${ARCHIVE_UNATTENDED:-0}" = 1 ] && [ "$DRY" != --dry-run ]; then
  echo 'Sherlock needs an owner-attended session; engine sessions may only dry-run'; exit 2
fi
[ -s "$SOURCE/freeze.json" ] && [ -s "$SOURCE/pages.jsonl" ] || { echo 'prepared pack required'; exit 2; }
SOURCE="$(cd "$SOURCE" && pwd)"
SUPPORT="$SOURCE/support/mixed-route"
if [ "$DRY" = --dry-run ]; then
  python3 "$SOURCE/mixed_route_cluster.py" check --root "$SOURCE"
  ROOT="/scratch/users/cp1/fs-ocr/$(basename "$SOURCE")"; TSV=''; SH_DIR="$SOURCE/support/sherlock"
  SH_GPU_C='GPU_MEM:48GB|GPU_MEM:80GB'
else
  source "$SOURCE/support/sherlock/sh.env"
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
gpu=(--partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G --output="$ROOT/logs/slurm-%j.out")
stage=$(run sbatch --parsable --output="$ROOT/logs/stage-%j.out" "$SUPPORT/stage-job.sh" "$SOURCE" "$ROOT" "$SH_DIR")
record stage "$stage"
glm=$(run sbatch --parsable "${gpu[@]}" --time=01:00:00 --dependency="afterok:$stage" --job-name=mixed-route-glm \
  "$SUPPORT/job.sh" "$ROOT" glm-ocr)
record glm-ocr "$glm"
qwen=$(run sbatch --parsable "${gpu[@]}" --time=02:00:00 --dependency="afterok:$glm" --job-name=mixed-route-qwen \
  "$SUPPORT/job.sh" "$ROOT" qwen3.6-27b)
record qwen3.6-27b "$qwen"
