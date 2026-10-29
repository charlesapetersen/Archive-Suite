#!/bin/bash
# W46.ent-robust on Sherlock, from an owner-started session only (execution-plans/items/W46.ent-robust.md).
#   bash <pack>/support/job/submit.sh <pack> [--dry-run]     <pack>: $GROUP_HOME/$USER/archive-suite/ent-robust-20261029
# Two jobs: a CPU stage (copy, hash check, model fetch), then one GPU job afterok (job.sh: both arms, each pilot-gated).
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
ROOT="$FS_ROOT/ent-robust-20261029"
if [ "$DRY" = --dry-run ]; then
  python3 "$SOURCE/support/check_pack.py" "$SOURCE" --as-root "$ROOT"   # local only: no cluster, no remote tree
  TSV=''
else
  mkdir -p "$ROOT/logs"; TSV="$ROOT/jobs.tsv"
  (set -o noclobber; : > "$TSV") || { echo 'jobs.tsv exists: inspect the existing submissions'; exit 2; }
fi
run() { if [ "$DRY" = --dry-run ]; then printf '%q ' "$@" >&2; printf '\n' >&2; echo 0; else "$@"; fi; }
record() {
  [[ "$2" =~ ^[0-9]+$ ]] || { echo "invalid job id for $1"; exit 2; }
  if [ "$DRY" = --dry-run ]; then printf '%s\t%s\n' "$1" "$2" >&2; else printf '%s\t%s\n' "$1" "$2" >> "$TSV"; fi
}
stage=$(run sbatch --parsable --output="$ROOT/logs/stage-%j.out" "$JOB/stage-job.sh" "$SOURCE" "$ROOT" "$JOB")
record stage "$stage"
gpu=$(run sbatch --parsable --partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G --time=02:00:00 \
  --dependency="afterok:$stage" --kill-on-invalid-dep=yes --job-name=entr-27b --output="$ROOT/logs/gpu-%j.out" \
  "$JOB/job.sh" "$ROOT")
record gpu "$gpu"
