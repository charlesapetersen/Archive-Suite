#!/bin/bash
# W46.marks-detect: submit from an owner-started Sherlock session only; nothing waits on the login node.
#   bash submit.sh PACK [--dry-run]
# One CPU setup job (overlay, data, dataset); a one-epoch GPU pilot afterok it (its time per epoch is the pilot
# figure for the review in execution-plans/items/W46.marks-detect.md); the 80-epoch training afterok the pilot,
# stopped by Ultralytics at 6 hours inside a 7-hour wall. GPU ceiling 6.5 hours. Job ids: <root>/jobs.tsv.
# --dry-run (the engine's only mode) checks the pack locally and prints the sbatch lines; it never contacts the cluster.
set -euo pipefail
SOURCE="${1:?PACK required}"; DRY="${2:-}"
[ -z "$DRY" ] || [ "$DRY" = --dry-run ] || { echo 'expected --dry-run'; exit 2; }
if [ "${ARCHIVE_UNATTENDED:-0}" = 1 ] && [ "$DRY" != --dry-run ]; then
  echo 'Sherlock needs an owner-attended session; engine sessions may only dry-run'; exit 2
fi
SOURCE="$(cd "$SOURCE" && pwd)"
[ -s "$SOURCE/freeze.json" ] || { echo 'prepared pack required'; exit 2; }
if [ "$DRY" = --dry-run ]; then
  python3 "$SOURCE/marks_detect_cluster.py" check --root "$SOURCE"
  ROOT="/scratch/users/cp1/fs-ocr/$(basename "$SOURCE")"; SH_DIR="$ROOT/support/sherlock"; TSV=''
  SH_GPU_C='GPU_MEM:48GB|GPU_MEM:80GB'
else
  source "$SOURCE/support/sherlock/sh.env"
  ROOT="$FS_ROOT/$(basename "$SOURCE")"
  [ ! -e "$ROOT" ] || { echo "$ROOT exists: inspect existing submissions"; exit 2; }
  mkdir -p "$ROOT/logs"
  rsync -a "$SOURCE/" "$ROOT/"
  SH_DIR="$ROOT/support/sherlock"
  TSV="$ROOT/jobs.tsv"
  (set -o noclobber; : > "$TSV") || { echo 'jobs.tsv exists: inspect existing submissions'; exit 2; }
fi
run() { if [ "$DRY" = --dry-run ]; then printf '%q ' "$@" >&2; printf '\n' >&2; echo 0; else "$@"; fi; }
record() {
  [[ "$2" =~ ^[0-9]+$ ]] || { echo 'invalid job id'; exit 2; }
  if [ "$DRY" = --dry-run ]; then printf '%s\t%s\n' "$1" "$2" >&2; else printf '%s\t%s\n' "$1" "$2" >> "$TSV"; fi
}
gpu=(--partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G --output="$ROOT/logs/slurm-%j.out")
setup=$(run sbatch --parsable --output="$ROOT/logs/setup-%j.out" "$ROOT/setup-job.sh" "$ROOT" "$SH_DIR")
record setup "$setup"
pilot=$(run sbatch --parsable "${gpu[@]}" --time=00:45:00 --dependency="afterok:$setup" --job-name=marks-detect-pilot \
  "$ROOT/job.sh" "$ROOT" "$SH_DIR" pilot 1 0.5)
record pilot "$pilot"
main=$(run sbatch --parsable "${gpu[@]}" --time=07:00:00 --dependency="afterok:$pilot" --job-name=marks-detect-train \
  "$ROOT/job.sh" "$ROOT" "$SH_DIR" public 80 6)
record train "$main"
