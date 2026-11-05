#!/bin/bash
# W46.seg-adapt-lora, one LoRA continuation on one GPU: the k corrections of box 1 plus three corpus windows for
# each (seg_adapt_lora.py replay), trained onto the merged corpus 2B with train_seg.py's recipe (rank 16, lr 1e-4,
# accum 8) for two epochs, then merged so vLLM serves it as the base is served. The peft overlay venv is the one
# merge-job.sh built (afterok), so no job installs anything here.
#   sbatch ... train-job.sh ROOT 50|200
set -euo pipefail
ROOT="$1"; K="$2"
: "${SLURM_JOB_ID:?must run as a Slurm job}"
: "${FS_ENV:?source sh.env before submission}"
source "$FS_ENV"
case "$K" in 50|200) ;; *) echo "unknown k $K"; exit 2 ;; esac
export HF_HOME HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
FS_COPY="$GROUP_HOME/$USER/archive-suite/FarmShare-scratch-20261022/fs-ocr"
ADAPTER="${KGS_ADAPTER_2B:-}"
if [ -z "$ADAPTER" ]; then   # merge-job.sh's own search, so replay reads the train.json of the adapter merged
  for c in "$FS_COPY/train/seg-2b/adapter" "$FS_COPY/train/full/qwen3.5-2b/adapter"; do
    [ -s "$c/adapter_config.json" ] && { ADAPTER="$c"; break; }
  done
fi
[ -s "${ADAPTER:-/nonexistent}/../train.json" ] || { echo "no 2B adapter with train.json"; exit 2; }
BASE="$ROOT/seg-2b-merged"; DATA="$ROOT/data/k$K"; OUT="$ROOT/lora/k$K"; MERGED="$ROOT/lora-k$K-merged"
ENV="$GROUP_HOME/$USER/envs/peft-overlay"
SAVED="$GROUP_HOME/$USER/archive-suite/sherlock-results/seg-adapt-lora-20261105"
[ -f "$BASE/config.json" ] || { echo "merged base missing: $BASE"; exit 2; }
[ -x "$ENV/bin/python" ] || { echo "peft overlay missing: $ENV"; exit 2; }
[ ! -e "$MERGED/config.json" ] || { echo "already trained and merged: $MERGED"; exit 0; }
mkdir -p "$ROOT/logs" "$ROOT/runtime" "$ROOT/lora"
finish() {
  rc=$?; trap - EXIT
  mkdir -p "$SAVED/lora/k$K"
  for f in "$DATA/data.json" "$OUT/train.json" "$OUT/train-log.jsonl"; do [ ! -f "$f" ] || cp "$f" "$SAVED/lora/k$K/"; done
  [ ! -d "$OUT/adapter" ] || rsync -a "$OUT/adapter" "$SAVED/lora/k$K/"
  exit "$rc"
}
trap finish EXIT
[ -s "$DATA/train.jsonl" ] || "$FS_PY" "$ROOT/support/segbench/seg_adapt_lora.py" replay --root "$ROOT" --k "$K" \
  --adapter "$ADAPTER" --search "$FS_COPY" --out "$DATA"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
run() { apptainer -s exec --nv --bind "$SCRATCH,$GROUP_HOME" --env PYTHONPATH="$SH_SHIM" --env HF_HOME="$HF_HOME" \
  --env HF_HUB_OFFLINE=1 "$SH_IMG" "$ENV/bin/python" "$@"; }
TS="$ROOT/support/segbench/train_seg.py"
[ -d "$OUT/adapter" ] || run "$TS" train --data "$DATA" --model "$BASE" --out "$OUT" --epochs 2
rm -rf "$MERGED.tmp"
run "$TS" merge --adapter "$OUT/adapter" --out "$MERGED.tmp"
mv "$MERGED.tmp" "$MERGED"
echo "trained and merged: $MERGED"
