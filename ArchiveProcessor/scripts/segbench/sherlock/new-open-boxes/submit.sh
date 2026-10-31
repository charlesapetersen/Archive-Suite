#!/bin/bash
# W46.ocr-new-open-boxes: Unlimited-OCR, Nemotron-Parse 2.0 and granite-docling-258M on the 895 and the 96, each through
# its card's own runtime (boxes_run.py). Submit from an owner-started Sherlock session only (the batch runs it as the
# pack's submit script); nothing waits on the login node.
#   bash <pack>/support/sherlock/new-open-boxes/submit.sh <pack> [--dry-run]
# Seven jobs, chained here so the batch holds, releases and collects them all: the CPU setup job (setup-job.sh: venvs,
# pinned snapshots, import checks), then per model the 895 on one card afterok the setup and the 96 afterok its 895.
# Each GPU job runs the three-page pilot gate before its set. Ids go in the pack's jobs.tsv. --dry-run (the engine's
# only mode) checks the pack locally and prints the sbatch lines; it never contacts the cluster.
set -euo pipefail
PACK="${1:?PACK required}"; DRY="${2:-}"
[ -z "$DRY" ] || [ "$DRY" = --dry-run ] || { echo 'expected --dry-run'; exit 2; }
if [ "${ARCHIVE_UNATTENDED:-0}" = 1 ] && [ "$DRY" != --dry-run ]; then
  echo 'Sherlock needs an owner-attended session; engine sessions may only dry-run'; exit 2
fi
PACK="$(cd "$PACK" && pwd)"; NAME="$(basename "$PACK")"
SH_DIR="$PACK/support/sherlock"; CANDS="$SH_DIR/new-open-boxes/candidates-boxes-20261031.json"
for f in sh.env bin/py new-open-boxes/setup-job.sh new-open-boxes/job.sh new-open-boxes/boxes_run.py \
         new-open-boxes/boxes_parse.py new-open-boxes/boxes_setup.py new-open-boxes/candidates-boxes-20261031.json; do
  [ -s "$SH_DIR/$f" ] || { echo "pack is missing support/sherlock/$f"; exit 2; }
done
ROWS=$(python3 - "$CANDS" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
assert [x['key'] for x in c] == ['unlimited-ocr', 'nemotron-parse-2', 'granite-docling-258m'], c
for x in c:
    assert x['adapter'] in ('unlimited', 'nemotron', 'granite') and x['constraints'] in ('torch', 'image') and x['pip'], x
    print(x['key'], int(x['hours_895']), int(x['hours_96']))
PY
)
if [ "$DRY" = --dry-run ]; then
  FS_ROOT=/scratch/users/cp1/fs-ocr; RES="\$GROUP_HOME/\$USER/archive-suite/sherlock-results/$NAME"
  SH_GPU_C='GPU_MEM:48GB|GPU_MEM:80GB'
else
  source "$SH_DIR/sh.env"
  RES="$GROUP_HOME/$USER/archive-suite/sherlock-results/$NAME"
fi
ROOT="$FS_ROOT/$NAME"; TSV=''
if [ -z "$DRY" ]; then
  mkdir -p "$ROOT/logs" "$RES"; TSV="$ROOT/jobs.tsv"
  (set -o noclobber; : > "$TSV") || { echo 'jobs.tsv exists: inspect existing submissions'; exit 2; }
fi
export NEW_OPEN_RESULTS="$RES"
run() { if [ "$DRY" = --dry-run ]; then printf '%q ' "$@" >&2; printf '\n' >&2; echo 0; else "$@"; fi; }
record() {
  [[ "$2" =~ ^[0-9]+$ ]] || { echo 'invalid job id'; exit 2; }
  if [ "$DRY" = --dry-run ]; then printf '%s\t%s\n' "$1" "$2" >&2; else printf '%s\t%s\n' "$1" "$2" >> "$TSV"; fi
}
setup=$(run sbatch --parsable --partition=normal --cpus-per-task=4 --mem=32G --time=04:00:00 --job-name=boxes-setup \
  --output="$ROOT/logs/setup-%j.out" "$SH_DIR/new-open-boxes/setup-job.sh" "$SH_DIR" "$CANDS")
record setup "$setup"
ids="setup $setup"
while read -r key h895 h96; do
  g=(--partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G)
  a=$(run sbatch --parsable "${g[@]}" --time="$h895:00:00" --dependency="afterok:$setup" --job-name="boxes-895-$key" \
    --output="$ROOT/logs/slurm-895-$key-%j.out" "$SH_DIR/new-open-boxes/job.sh" "$SH_DIR" 895 "$key")
  record "895 $key" "$a"
  b=$(run sbatch --parsable "${g[@]}" --time="$h96:00:00" --dependency="afterok:$a" --job-name="boxes-96-$key" \
    --output="$ROOT/logs/slurm-96-$key-%j.out" "$SH_DIR/new-open-boxes/job.sh" "$SH_DIR" 96 "$key")
  record "96 $key" "$b"
  ids="$ids, $key $a/$b"
done <<<"$ROWS"
echo "submitted: $ids (held by the batch until its import check); results: $RES"
