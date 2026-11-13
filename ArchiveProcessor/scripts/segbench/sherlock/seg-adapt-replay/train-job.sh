#!/bin/bash
# W46.kit-continuation-replay, one LoRA continuation on one GPU: the rows the Mac froze in rows/<arm> (box 1's k = 200
# corrections alone, or with three TABME++ windows each), trained onto the merged corpus 2B with
# seg-adapt-lora/train-job.sh's recipe unchanged (train_seg.py defaults: rank 16, lr 1e-4, accum 8; two epochs, every
# window up to the 20,480 tokens vLLM serves), then merged so vLLM serves it as the base is served. No replay is drawn
# here: the pack holds every row. The peft overlay venv is the one merge-job.sh built (afterok).
#   sbatch ... train-job.sh ROOT none|public
set -euo pipefail
ROOT="$1"; ARM="$2"
: "${SLURM_JOB_ID:?must run as a Slurm job}"
: "${FS_ENV:?source sh.env before submission}"
source "$FS_ENV"
case "$ARM" in none|public) ;; *) echo "unknown arm $ARM"; exit 2 ;; esac
export HF_HOME HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
BASE="$ROOT/seg-2b-merged"; DATA="$ROOT/rows/$ARM"; OUT="$ROOT/lora/$ARM"; MERGED="$ROOT/lora-$ARM-merged"
ENV="$GROUP_HOME/$USER/envs/peft-overlay"
SAVED="$GROUP_HOME/$USER/archive-suite/sherlock-results/seg-adapt-replay-20261113"
[ -f "$BASE/config.json" ] || { echo "merged base missing: $BASE"; exit 2; }
[ -x "$ENV/bin/python" ] || { echo "peft overlay missing: $ENV"; exit 2; }
[ -s "$DATA/train.jsonl" ] || { echo "rows missing: $DATA"; exit 2; }
[ ! -e "$MERGED/config.json" ] || { echo "already trained and merged: $MERGED"; exit 0; }
mkdir -p "$ROOT/logs" "$ROOT/runtime" "$ROOT/lora"
finish() {
  rc=$?; trap - EXIT
  mkdir -p "$SAVED/lora/$ARM"
  for f in "$DATA/data.json" "$OUT/train.json" "$OUT/train-log.jsonl"; do [ ! -f "$f" ] || cp "$f" "$SAVED/lora/$ARM/"; done
  [ ! -d "$OUT/adapter" ] || rsync -a "$OUT/adapter" "$SAVED/lora/$ARM/"
  exit "$rc"
}
trap finish EXIT
"$FS_PY" "$ROOT/support/segbench/seg_adapt_replay.py" check --root "$ROOT"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
run() { apptainer -s exec --nv --bind "$SCRATCH,$GROUP_HOME" --env PYTHONPATH="$SH_SHIM" --env HF_HOME="$HF_HOME" \
  --env HF_HUB_OFFLINE=1 "$SH_IMG" "$ENV/bin/python" "$@"; }
TS="$ROOT/support/segbench/train_seg.py"
[ -d "$OUT/adapter" ] || run "$TS" train --data "$DATA" --images "$ROOT/rows/images" --model "$BASE" --out "$OUT" \
  --epochs 2 --max-len 20480
rm -rf "$MERGED.tmp"
run "$TS" merge --adapter "$OUT/adapter" --out "$MERGED.tmp"
mv "$MERGED.tmp" "$MERGED"
echo "trained and merged: $MERGED"
