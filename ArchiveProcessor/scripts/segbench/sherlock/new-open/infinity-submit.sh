#!/bin/bash
# W46.ocr-new-open-sherlock: Infinity-Parser2-Pro (35B-A3B, BF16) on the 895 and the 96, through W46.ocr-new-open's
# roots and harness unchanged. Submit from an owner-started Sherlock session only (the batch runs it as the pack's
# submit script); nothing waits on the login node.
#   bash <pack>/support/sherlock/new-open/infinity-submit.sh <pack> [--dry-run]
# Three jobs, chained here so the batch holds, releases and collects all three: the CPU setup job (setup-job.sh:
# the pinned snapshot, the prompt checked against the infinity-parser2 package, the frozen collector), then the 895
# on two cards afterok, then the 96 afterok. The 895 job runs the harness's three-page pilot gate before the full
# run. Their ids go in the pack's jobs.tsv and in new-open-jobs.tsv, whose line also stops setup-job.sh submitting
# the pair a second time. Each GPU job copies its finished session folder to the results folder. --dry-run (the
# engine's only mode) checks the pack locally and prints the sbatch lines; it never contacts the cluster.
set -euo pipefail
PACK="${1:?PACK required}"; DRY="${2:-}"
[ -z "$DRY" ] || [ "$DRY" = --dry-run ] || { echo 'expected --dry-run'; exit 2; }
if [ "${ARCHIVE_UNATTENDED:-0}" = 1 ] && [ "$DRY" != --dry-run ]; then
  echo 'Sherlock needs an owner-attended session; engine sessions may only dry-run'; exit 2
fi
PACK="$(cd "$PACK" && pwd)"; NAME="$(basename "$PACK")"
SH_DIR="$PACK/support/sherlock"; CANDS="$SH_DIR/new-open/candidates-infinity-20261031.json"; KEY=infinity-parser2-pro
for f in sh.env bin/py bin/vllm new-open/setup-job.sh new-open/job.sh new-open/prompt_source.py \
         ../corpus/open_sweep_setup.py new-open/candidates-infinity-20261031.json; do
  [ -s "$SH_DIR/$f" ] || { echo "pack is missing support/sherlock/$f"; exit 2; }
done
python3 - "$CANDS" "$KEY" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
assert [x['key'] for x in c] == [sys.argv[2]] and c[0]['gpus'] == 2 and c[0]['revision'], c
PY
if [ "$DRY" = --dry-run ]; then
  FS_ROOT=/scratch/users/cp1/fs-ocr; RES="\$GROUP_HOME/\$USER/archive-suite/sherlock-results/$NAME"
  SH_GPU_C='GPU_MEM:48GB|GPU_MEM:80GB'; TSV=''
else
  source "$SH_DIR/sh.env"
  RES="$GROUP_HOME/$USER/archive-suite/sherlock-results/$NAME"
  if grep -q -P "^$KEY\t" "$FS_ROOT/new-open-jobs.tsv" 2>/dev/null; then
    echo "$KEY is already in new-open-jobs.tsv: inspect that submission"; exit 2
  fi
fi
ROOT="$FS_ROOT/$NAME"
if [ -z "$DRY" ]; then
  mkdir -p "$ROOT/logs" "$RES"; TSV="$ROOT/jobs.tsv"
  (set -o noclobber; : > "$TSV") || { echo 'jobs.tsv exists: inspect existing submissions'; exit 2; }
fi
export NEW_OPEN_RESULTS="$RES" NEW_OPEN_SETUP_ONLY=1
run() { if [ "$DRY" = --dry-run ]; then printf '%q ' "$@" >&2; printf '\n' >&2; echo 0; else "$@"; fi; }
record() {
  [[ "$2" =~ ^[0-9]+$ ]] || { echo 'invalid job id'; exit 2; }
  if [ "$DRY" = --dry-run ]; then printf '%s\t%s\n' "$1" "$2" >&2; else printf '%s\t%s\n' "$1" "$2" >> "$TSV"; fi
}
setup=$(run sbatch --parsable --partition=normal --cpus-per-task=4 --mem=16G --time=06:00:00 --job-name=new-open-setup \
  --output="$ROOT/logs/setup-%j.out" "$SH_DIR/new-open/setup-job.sh" "$SH_DIR" "$CANDS")
record setup "$setup"
# Two cards: 70.2 GB of BF16 weights, tensor-parallel 2 as the card serves it; 48 GB cards leave about 5 GB each for
# the cache, which this hybrid-attention model needs little of. The 895 read is about an hour; six hours is the wall.
g=(--partition=gpu -G 2 -C "$SH_GPU_C" --cpus-per-task=16 --mem=128G)
a=$(run sbatch --parsable "${g[@]}" --time=06:00:00 --dependency="afterok:$setup" --job-name="new-open-895-$KEY" \
  --output="$ROOT/logs/slurm-895-%j.out" "$SH_DIR/new-open/job.sh" "$SH_DIR" 895 "$KEY")
record "895 $KEY" "$a"
b=$(run sbatch --parsable "${g[@]}" --time=02:00:00 --dependency="afterok:$a" --job-name="new-open-96-$KEY" \
  --output="$ROOT/logs/slurm-96-%j.out" "$SH_DIR/new-open/job.sh" "$SH_DIR" 96 "$KEY")
record "96 $KEY" "$b"
if [ -z "$DRY" ]; then printf '%s\t%s\t%s\n' "$KEY" "$a" "$b" >> "$FS_ROOT/new-open-jobs.tsv"; fi
echo "submitted: setup $setup, 895 $a, 96 $b (held by the batch until its import check); results: $RES"
