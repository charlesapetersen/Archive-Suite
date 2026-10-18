#!/usr/bin/env bash
# One LoRA run and merge; submit with the selected profile's exported runtime and scheduler arrays (README).
# TRAIN_DATA / TRAIN_MODEL / TRAIN_OUT required. Extra options: TRAIN_ARGS. Compute nodes stay offline.
set -euo pipefail
cd "${SLURM_SUBMIT_DIR:-$(dirname "$0")}"
: "${IC_ROOT:?source compute.env before submitting}" "${HF_HOME:?missing cache snapshot}"
source runtime.sh; load_cluster_modules
export HF_HOME HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
V="$IC_ROOT/train-venv/bin/python"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
"$V" train_seg.py train --data "$TRAIN_DATA" --model "$TRAIN_MODEL" --out "$TRAIN_OUT" --save-every 50 ${TRAIN_ARGS:-}
"$V" train_seg.py merge --adapter "$TRAIN_OUT/adapter" --out "$TRAIN_OUT/merged"
echo "trained and merged: $TRAIN_OUT/merged"
