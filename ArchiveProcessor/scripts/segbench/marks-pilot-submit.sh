#!/bin/bash
# Owner-attended Sherlock only. CPU staging + ONE 15-page GPU pilot.
# No full preflag/draft/audit sweep is scheduled by this script.
set -euo pipefail
SOURCE="${1:?prepared pack required}"; DRY="${2:-}"
[ -z "$DRY" ] || [ "$DRY" = --dry-run ] || { echo 'expected --dry-run'; exit 2; }
if [ "${ARCHIVE_UNATTENDED:-0}" = 1 ] && [ "$DRY" != --dry-run ]; then
  echo 'Sherlock requires an owner-attended session; engine may only dry-run'; exit 2
fi
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -s "$SOURCE/freeze.json" ] || { echo 'prepared source pack missing'; exit 2; }
SOURCE="$(cd "$SOURCE" && pwd)"
# Refuse stale checkout entrypoints. Actual jobs and environment always use the
# transferred frozen support; full input/hash validation runs on the CPU node.
for name in marks_pilot.py marks-pilot-submit.sh marks-pilot-stage-job.sh marks-pilot-job.sh sherlock/sh.env sherlock/bin/py sherlock/bin/vllm; do
  cmp "$KIT/$name" "$SOURCE/support/$name" || { echo 'entrypoint differs from frozen support'; exit 2; }
done
FROZEN_KIT="$(cd "$SOURCE/support" && pwd)"
source "$FROZEN_KIT/sherlock/sh.env"
ROOT="$FS_ROOT/marks-preflag-20261025"
if [ "$DRY" = --dry-run ]; then
  python3 "$KIT/marks_pilot.py" check --root "$SOURCE"
  TSV=''
else
  mkdir -p "$ROOT/logs"
  TSV="$ROOT/jobs.tsv"
  (set -o noclobber; : > "$TSV") || { echo 'jobs.tsv exists; inspect submissions before any retry'; exit 2; }
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
stage=$(run sbatch --parsable --output="$ROOT/logs/stage-%j.out" "$FROZEN_KIT/marks-pilot-stage-job.sh" "$SOURCE" "$ROOT" "$FROZEN_KIT/sherlock")
record stage "$stage"
pilot=$(run sbatch --parsable --partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G --time=01:00:00 \
  --dependency="afterok:$stage" --job-name=marks-preflag-pilot --output="$ROOT/logs/slurm-%j.out" \
  "$FROZEN_KIT/marks-pilot-job.sh" "$ROOT")
record pilot "$pilot"
