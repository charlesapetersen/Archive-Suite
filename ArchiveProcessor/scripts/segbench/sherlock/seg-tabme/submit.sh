#!/bin/bash
# W46.seg-tabme on Sherlock, from an owner-started session only (execution-plans/items/W46.seg-tabme.md).
#   bash <pack>/support/job/submit.sh <pack> [--dry-run]   <pack>: $GROUP_HOME/$USER/archive-suite/seg-tabme-20261105
# Seven jobs, every one after the stage; each GPU job is one model on one arm of 2,079 K = 7 windows:
#   stage       CPU: copy the frozen pack into scratch, check its hashes, fetch the three base models if absent
#   teacher-it  one GPU, afterok stage: Qwen3.5-27B-FP8, images and text (5.0 s a window measured: about 2.9 h)
#   teacher-t   one GPU, afterok stage: the same windows, OCR text only (no measured rate; under the image arm's)
#   merge-2b    CPU, afterok stage: the trained 2B's FarmShare adapter onto Qwen3.5-2B
#   2b-it       one GPU, afterok merge-2b (0.5 s a window: about 20 minutes)
#   merge-4b    CPU, afterok stage and afterany merge-2b (never two venv builds at once): the trained 4B onto Qwen3.5-4B
#   4b-it       one GPU, afterok merge-4b (0.9 s a window: about 35 minutes)
# The teacher waits on no merge, and a failed 4B merge costs only the 4B's arm.
set -euo pipefail
SOURCE="${1:?pack folder required}"; DRY="${2:-}"
[ -z "$DRY" ] || [ "$DRY" = --dry-run ] || { echo 'expected --dry-run'; exit 2; }
if [ "${ARCHIVE_UNATTENDED:-0}" = 1 ] && [ "$DRY" != --dry-run ]; then
  echo 'Sherlock needs an owner-attended session; engine sessions may only dry-run'; exit 2
fi
JOB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -s "$SOURCE/freeze.json" ] || { echo 'prepared pack required'; exit 2; }
if [ "$DRY" = --dry-run ]; then
  SCRATCH="${SCRATCH:-/scratch/users/$USER}" GROUP_HOME="${GROUP_HOME:-/home/groups/dry-run}"
  export SCRATCH GROUP_HOME
fi
source "$JOB/sh.env"
ROOT="$FS_ROOT/seg-tabme-20261105"
if [ "$DRY" = --dry-run ]; then
  python3 "$SOURCE/support/segbench/seg_tabme.py" check --root "$SOURCE"   # local only: no cluster
  TSV=''
else
  mkdir -p "$ROOT/logs"; TSV="$ROOT/jobs.tsv"
  # Reserve before sbatch, so a second invocation cannot submit the same work.
  (set -o noclobber; : > "$TSV") || { echo 'jobs.tsv exists: inspect the existing submissions'; exit 2; }
fi
run() { if [ "$DRY" = --dry-run ]; then printf '%q ' "$@" >&2; printf '\n' >&2; echo 0; else "$@"; fi; }
record() {
  [[ "$2" =~ ^[0-9]+$ ]] || { echo "invalid job id for $1"; exit 2; }
  if [ "$DRY" = --dry-run ]; then printf '%s\t%s\n' "$1" "$2" >&2; else printf '%s\t%s\n' "$1" "$2" >> "$TSV"; fi
}
gpu() {  # role, arm, dependency, time limit
  run sbatch --parsable --partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G --time="$4" \
    --dependency="$3" --kill-on-invalid-dep=yes --job-name="tabme-$1-$2" --output="$ROOT/logs/$1-$2-%j.out" \
    "$JOB/job.sh" "$ROOT" "$1" "$2"
}
stage=$(run sbatch --parsable --output="$ROOT/logs/stage-%j.out" "$JOB/stage-job.sh" "$SOURCE" "$ROOT" "$JOB")
record stage "$stage"
tit=$(gpu teacher it "afterok:$stage" 05:00:00)
record teacher-it "$tit"
tt=$(gpu teacher t "afterok:$stage" 04:00:00)
record teacher-t "$tt"
merge2=$(run sbatch --parsable --dependency="afterok:$stage" --kill-on-invalid-dep=yes \
  --output="$ROOT/logs/merge-2b-%j.out" "$JOB/merge-job.sh" "$ROOT" "$JOB" 2b)
record merge-2b "$merge2"
s2=$(gpu 2b it "afterok:$merge2" 01:00:00)
record 2b-it "$s2"
merge4=$(run sbatch --parsable --dependency="afterok:$stage,afterany:$merge2" --kill-on-invalid-dep=yes \
  --output="$ROOT/logs/merge-4b-%j.out" "$JOB/merge-job.sh" "$ROOT" "$JOB" 4b)
record merge-4b "$merge4"
s4=$(gpu 4b it "afterok:$merge4" 01:30:00)
record 4b-it "$s4"
