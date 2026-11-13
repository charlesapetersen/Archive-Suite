#!/bin/bash
# W46.kit-continuation-replay on Sherlock, from an owner-started session only
# (execution-plans/items/W46.kit-continuation-replay.md).
#   bash <pack>/support/job/submit.sh <pack> [--dry-run]   <pack>: $GROUP_HOME/$USER/archive-suite/seg-adapt-replay-20261113
# Six jobs, every one after the stage (seg-adapt-lora/submit.sh's chain without its base arm: the base and k = 200
# answers are already home):
#   stage        CPU: copy the frozen pack into scratch, check its hashes, fetch Qwen3.5-2B if absent
#   merge-2b     CPU, afterok stage: the corpus 2B's FarmShare adapter onto Qwen3.5-2B (also builds the peft overlay)
#   train-none   one GPU, afterok merge-2b: box 1's k = 200 corrections alone (62 windows), LoRA, merged
#   none         one GPU, afterok train-none: the 175 scoring windows (box 1's 88, box 2's 87)
#   train-public one GPU, afterok merge-2b: the same plus 186 TABME++ windows (248), LoRA, merged
#   public       one GPU, afterok train-public: the same 175 windows
# A failed training costs only its own arm.
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
ROOT="$FS_ROOT/seg-adapt-replay-20261113"
if [ "$DRY" = --dry-run ]; then
  python3 "$SOURCE/support/segbench/seg_adapt_replay.py" check --root "$SOURCE"   # local only: no cluster
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
gpu() {  # name, dependency, time limit, script, args...
  local name="$1" dep="$2" limit="$3"; shift 3
  run sbatch --parsable --partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G --time="$limit" \
    --dependency="$dep" --kill-on-invalid-dep=yes --job-name="sar-$name" --output="$ROOT/logs/$name-%j.out" "$@"
}
stage=$(run sbatch --parsable --output="$ROOT/logs/stage-%j.out" "$JOB/stage-job.sh" "$SOURCE" "$ROOT" "$JOB")
record stage "$stage"
merge=$(run sbatch --parsable --dependency="afterok:$stage" --kill-on-invalid-dep=yes \
  --output="$ROOT/logs/merge-2b-%j.out" "$JOB/merge-job.sh" "$ROOT" "$JOB" 2b)
record merge-2b "$merge"
for arm in none public; do
  limit=01:30:00; [ "$arm" = public ] || limit=00:45:00
  t=$(gpu "train-$arm" "afterok:$merge" "$limit" "$JOB/train-job.sh" "$ROOT" "$arm")
  record "train-$arm" "$t"
  s=$(gpu "$arm" "afterok:$t" 00:45:00 "$JOB/job.sh" "$ROOT" "$arm")
  record "$arm" "$s"
done
