#!/bin/bash
# W46.seg-context on Sherlock, from an owner-started session only (execution-plans/items/W46.seg-context.md).
#   bash <pack>/support/job/submit.sh <pack> [--dry-run]       <pack>: $GROUP_HOME/$USER/archive-suite/seg-context-20261029
# Four jobs, every one after the stage:
#   stage    CPU: copy the frozen pack into scratch, check its hashes, fetch the two base models if absent
#   teacher  one GPU, afterok stage: Qwen3.5-27B-FP8, 4-window pilot gate, then all 510 requests (255 spans x 2 arms)
#   merge    CPU, afterok stage: the trained 2B's FarmShare adapter onto Qwen3.5-2B (train_seg.py merge, a peft overlay)
#   student  one GPU, afterok merge: the merged 2B served as seg-2b, the same pilot gate and 510 requests
# The teacher does not wait on the merge, so a failed merge costs only the student's arm.
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
ROOT="$FS_ROOT/seg-context-20261029"
if [ "$DRY" = --dry-run ]; then
  python3 "$SOURCE/support/segbench/seg_context.py" check --root "$SOURCE"   # local only: no cluster, no remote tree
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
stage=$(run sbatch --parsable --output="$ROOT/logs/stage-%j.out" "$JOB/stage-job.sh" "$SOURCE" "$ROOT" "$JOB")
record stage "$stage"
teacher=$(run sbatch --parsable --partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G --time=02:30:00 \
  --dependency="afterok:$stage" --job-name=ctx-teacher --output="$ROOT/logs/teacher-%j.out" \
  "$JOB/job.sh" "$ROOT" teacher)
record teacher "$teacher"
merge=$(run sbatch --parsable --dependency="afterok:$stage" --output="$ROOT/logs/merge-%j.out" \
  "$JOB/merge-job.sh" "$ROOT" "$JOB")
record merge "$merge"
student=$(run sbatch --parsable --partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G --time=01:00:00 \
  --dependency="afterok:$merge" --job-name=ctx-student --output="$ROOT/logs/student-%j.out" \
  "$JOB/job.sh" "$ROOT" student)
record student "$student"
