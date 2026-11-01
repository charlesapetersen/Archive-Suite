#!/bin/bash
# One bounded GPU job, pilot and full conditions together; no installs or model download.
set -euo pipefail
SOURCE="${1:?pack required}"; DRY="${2:-}"
[[ -z "$DRY" || "$DRY" = --dry-run ]] || exit 2
if [[ "${ARCHIVE_UNATTENDED:-0}" = 1 && "$DRY" != --dry-run ]]; then
  echo 'Sherlock submission requires an owner-started session'; exit 2
fi
JOB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$DRY" = --dry-run ]]; then
  export SCRATCH="${SCRATCH:-/scratch/users/cp1}" GROUP_HOME="${GROUP_HOME:-/home/groups/dry-run}"
fi
source "$JOB/sh.env"
ROOT="$FS_ROOT/hand-icl-20261101"
if [[ "$DRY" = --dry-run ]]; then
  printf '%q ' sbatch --parsable --partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G \
    --time=01:30:00 --job-name=hand-icl --output="$ROOT/logs/job-%j.out" "$JOB/job.sh" "$SOURCE" "$ROOT"
  printf '\n'; exit 0
fi
[[ -s "$SOURCE/freeze.json" && -s "$SH_IMG" ]] || { echo 'missing pack or existing container'; exit 2; }
mkdir -p "$ROOT/logs"
(set -o noclobber; : > "$ROOT/jobs.tsv") || { echo 'jobs.tsv exists: inspect prior submission'; exit 2; }
j=$(sbatch --parsable --partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G \
  --time=01:30:00 --job-name=hand-icl --output="$ROOT/logs/job-%j.out" "$JOB/job.sh" "$SOURCE" "$ROOT")
[[ "$j" =~ ^[0-9]+$ ]] || { echo 'invalid job ID'; exit 2; }
printf 'hand-icl\t%s\n' "$j" >> "$ROOT/jobs.tsv"
echo "submitted $j"
