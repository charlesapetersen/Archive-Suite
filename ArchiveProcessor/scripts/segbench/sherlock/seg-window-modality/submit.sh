#!/bin/bash
# W46.seg-window-modality on Sherlock, from an owner-started session only (execution-plans/items/W46.seg-window-modality.md).
#   bash <pack>/support/job/submit.sh <pack> [--dry-run]   <pack>: $GROUP_HOME/$USER/archive-suite/seg-window-modality-20261029
# Six jobs, every one after the stage:
#   stage     CPU: copy the frozen pack into scratch, check its hashes, fetch the three base models if absent
#   teacher   one GPU, afterok stage: Qwen3.5-27B-FP8, the vote's 1,260 units (6 runs x 210 windows)
#   merge-2b  CPU, afterok stage: the trained 2B's FarmShare adapter onto Qwen3.5-2B
#   2b        one GPU, afterok merge-2b: vote 1,260, sweep 2,312, folder 42
#   merge-4b  CPU, afterany merge-2b (never two venv builds at once): the trained 4B onto Qwen3.5-4B
#   4b        one GPU, afterok merge-4b: vote 1,260
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
ROOT="$FS_ROOT/seg-window-modality-20261029"
if [ "$DRY" = --dry-run ]; then
  python3 "$SOURCE/support/segbench/seg_window_modality.py" check --root "$SOURCE"   # local only: no cluster
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
gpu() {  # name, dependency, time limit, role
  run sbatch --parsable --partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G --time="$3" \
    --dependency="$2" --kill-on-invalid-dep=yes --job-name="swm-$1" --output="$ROOT/logs/$1-%j.out" \
    "$JOB/job.sh" "$ROOT" "$4"
}
stage=$(run sbatch --parsable --output="$ROOT/logs/stage-%j.out" "$JOB/stage-job.sh" "$SOURCE" "$ROOT" "$JOB")
record stage "$stage"
teacher=$(gpu teacher "afterok:$stage" 03:30:00 teacher)
record teacher "$teacher"
merge2=$(run sbatch --parsable --dependency="afterok:$stage" --kill-on-invalid-dep=yes \
  --output="$ROOT/logs/merge-2b-%j.out" "$JOB/merge-job.sh" "$ROOT" "$JOB" 2b)
record merge-2b "$merge2"
s2=$(gpu 2b "afterok:$merge2" 01:30:00 2b)
record 2b "$s2"
merge4=$(run sbatch --parsable --dependency="afterany:$merge2" --kill-on-invalid-dep=yes \
  --output="$ROOT/logs/merge-4b-%j.out" "$JOB/merge-job.sh" "$ROOT" "$JOB" 4b)
record merge-4b "$merge4"
s4=$(gpu 4b "afterok:$merge4" 01:00:00 4b)
record 4b "$s4"
