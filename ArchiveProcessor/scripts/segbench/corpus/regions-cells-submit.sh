#!/bin/bash
# Run from an owner-started Sherlock session only. One CPU stage job, then one
# independent one-GPU job per reader, dependent on the stage.
# bash regions-cells-submit.sh GROUP_PACK [--dry-run] [--phase capability|all] [--routes R[,R]]
# Defaults are the two-page capability pilot with both readers (W46.ocr-regions-cells).
# The bank run (W46.ocr-regions-cells-bank) is regions-cells-bank-submit.sh: --phase all, Qwen only.
# The scratch root and results folder are named after the pack folder, so two packs never share receipts.
set -euo pipefail
SOURCE="${1:?GROUP_PACK required}"; shift
DRY=''; PHASE=capability; ROUTES=glm-ocr,qwen3.6-27b
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=--dry-run; shift;;
    --phase) PHASE="${2:?--phase needs a value}"; shift 2;;
    --routes) ROUTES="${2:?--routes needs a value}"; shift 2;;
    *) echo "unexpected argument: $1"; exit 2;;
  esac
done
case "$PHASE" in capability|all) ;; *) echo 'phase must be capability or all'; exit 2;; esac
IFS=, read -r -a ROUTE_LIST <<< "$ROUTES"
[ "${#ROUTE_LIST[@]}" -ge 1 ] || { echo 'no reader given'; exit 2; }
seen=' '
for route in "${ROUTE_LIST[@]}"; do
  case "$route" in glm-ocr|qwen3.6-27b) ;; *) echo "unsupported reader: $route"; exit 2;; esac
  case "$seen" in *" $route "*) echo "reader given twice: $route"; exit 2;; esac
  seen="$seen$route "
done
if [ "${ARCHIVE_UNATTENDED:-0}" = 1 ] && [ "$DRY" != --dry-run ]; then
  echo 'Sherlock needs an owner-attended session; engine sessions may only dry-run'; exit 2
fi
CORPUS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH_DIR="$(cd "$CORPUS/../sherlock" && pwd)"
source "$SH_DIR/sh.env"
[ -s "$SOURCE/freeze.json" ] && [ -s "$SOURCE/truth.json" ] || { echo 'prepared source pack required'; exit 2; }
SOURCE="$(cd "$SOURCE" && pwd)"
ROOT="$FS_ROOT/$(basename "$SOURCE")"
if [ "$DRY" = --dry-run ]; then
  # Local-only verification. Never contacts the cluster or creates a remote-shaped tree.
  python3 "$CORPUS/regions_cells.py" check --root "$SOURCE" --phase "$PHASE"
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
for route in "${ROUTE_LIST[@]}"; do
  job=$(run sbatch --parsable --partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G --time=01:00:00 \
    --dependency="afterok:$stage" --job-name="cells-$route" --output="$ROOT/logs/slurm-%j.out" \
    "$CORPUS/regions-cells-job.sh" "$ROOT" "$route" "$PHASE")
  record "$route" "$job"
done
