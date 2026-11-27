#!/bin/bash
# W46.ocr-family-coverage: DeepSeek-OCR-2, olmOCR-2, MinerU2.5-Pro, dots.ocr and Chandra-2 on the 895 and the 96,
# and CHURRO-3B on the 455 public pages its FarmShare run skipped, each in process through its card's route
# (family_run.py). Submit from an owner-started Sherlock session only (the batch runs it as the pack's submit script);
# nothing waits on the login node.
#   bash <pack>/support/sherlock/family-coverage/submit.sh <pack> [--dry-run]
# Twelve jobs, chained here so the batch holds, releases and collects them all: the CPU setup job (setup-job.sh:
# prompts, pinned snapshots, the subset, MinerU's overlay, checks), then per model its 895 on one card afterok the
# setup and its 96 afterok its 895 (CHURRO: the 455 only; its 96 was read on FarmShare, job 1855420). Each GPU job
# runs the three-page pilot gate before its set. A rerun pack carries only some of the keys (pack.sh FAMILY_KEYS;
# W46.ocr-family-coverage-rerun: DeepSeek-OCR-2 and MinerU2.5-Pro, five jobs). Ids go in the pack's jobs.tsv. --dry-run (the engine's only mode)
# checks the pack locally and prints the sbatch lines; it never contacts the cluster.
set -euo pipefail
PACK="${1:?PACK required}"; DRY="${2:-}"
[ -z "$DRY" ] || [ "$DRY" = --dry-run ] || { echo 'expected --dry-run'; exit 2; }
if [ "${ARCHIVE_UNATTENDED:-0}" = 1 ] && [ "$DRY" != --dry-run ]; then
  echo 'Sherlock needs an owner-attended session; engine sessions may only dry-run'; exit 2
fi
PACK="$(cd "$PACK" && pwd)"; NAME="$(basename "$PACK")"
SH_DIR="$PACK/support/sherlock"; CANDS="$SH_DIR/family-coverage/candidates-family-20261117.json"
for f in sh.env bin/py family-coverage/setup-job.sh family-coverage/job.sh family-coverage/family_run.py \
         family-coverage/family_parse.py family-coverage/family_setup.py family-coverage/churro-added455.txt \
         family-coverage/candidates-family-20261117.json new-open-boxes/boxes_run.py new-open-boxes/boxes_parse.py \
         new-open-boxes/boxes_setup.py new-open/prompt_source.py; do
  [ -s "$SH_DIR/$f" ] || { echo "pack is missing support/sherlock/$f"; exit 2; }
done
ROWS=$(python3 - "$CANDS" "$SH_DIR/family-coverage" <<'PY'
import json, pathlib, sys
c = json.load(open(sys.argv[1]))
ALL = ['olmocr-2-7b-fp8', 'chandra-ocr-2', 'dots-ocr', 'deepseek-ocr-2', 'mineru25-pro', 'churro-3b']
keys = [x['key'] for x in c]  # all six, or the subset a rerun packed (pack.sh FAMILY_KEYS), in this order
assert keys and keys == [k for k in ALL if k in keys], keys
for x in c:
    assert x['adapter'] in ('vllm', 'mineru') and x['sets'] in (['895', '96'], ['895']), x
    assert x['adapter'] == 'mineru' or (x['mode'] in ('chat', 'generate') and x['reduce']), x
    assert x.get('prompt') or x.get('prompt_from'), x
    if x.get('subset'):
        ids = (pathlib.Path(sys.argv[2]) / x['subset']).read_text().split()
        assert len(ids) == len(set(ids)) == 455, len(ids)
    print(x['key'], int(x['hours_895']), int(x['hours_96']) if '96' in x['sets'] else 0)
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
export FAMILY_RESULTS="$RES"
run() { if [ "$DRY" = --dry-run ]; then printf '%q ' "$@" >&2; printf '\n' >&2; echo 0; else "$@"; fi; }
record() {
  [[ "$2" =~ ^[0-9]+$ ]] || { echo 'invalid job id'; exit 2; }
  if [ "$DRY" = --dry-run ]; then printf '%s\t%s\n' "$1" "$2" >&2; else printf '%s\t%s\n' "$1" "$2" >> "$TSV"; fi
}
setup=$(run sbatch --parsable --partition=normal --cpus-per-task=4 --mem=32G --time=04:00:00 --job-name=family-setup \
  --output="$ROOT/logs/setup-%j.out" "$SH_DIR/family-coverage/setup-job.sh" "$SH_DIR" "$CANDS")
record setup "$setup"
ids="setup $setup"
while read -r key h895 h96; do
  g=(--partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G)
  a=$(run sbatch --parsable "${g[@]}" --time="$h895:00:00" --dependency="afterok:$setup" --job-name="family-895-$key" \
    --output="$ROOT/logs/slurm-895-$key-%j.out" "$SH_DIR/family-coverage/job.sh" "$SH_DIR" 895 "$key")
  record "895 $key" "$a"
  ids="$ids, $key $a"
  if [ "$h96" -gt 0 ]; then
    b=$(run sbatch --parsable "${g[@]}" --time="$h96:00:00" --dependency="afterok:$a" --job-name="family-96-$key" \
      --output="$ROOT/logs/slurm-96-$key-%j.out" "$SH_DIR/family-coverage/job.sh" "$SH_DIR" 96 "$key")
    record "96 $key" "$b"
    ids="$ids/$b"
  fi
done <<<"$ROWS"
echo "submitted: $ids (held by the batch until its import check); results: $RES"
