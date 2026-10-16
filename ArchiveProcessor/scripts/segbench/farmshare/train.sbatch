#!/bin/bash
# W41.seg-finetune: one LoRA run of train_seg.py on one L40S, then the merged model vLLM can serve.
#   sbatch --partition=gpu --qos=gpu --gres=gpu:1 --cpus-per-task=8 --mem=64G --time=480 \
#     --job-name=seg-train --output=$FS_ROOT/logs/%x-%j.out \
#     --export=ALL,TRAIN_DATA=DIR,TRAIN_MODEL=Qwen/Qwen3.5-4B,TRAIN_OUT=DIR train.sbatch
# Offline: the base models are in $HF_HOME (setup-train.sh). Extra train_seg.py options in $TRAIN_ARGS.
set -euo pipefail
cd "${SLURM_SUBMIT_DIR:-$(dirname "$0")}"
source fs.env
export HF_HOME HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
V="$FS_ROOT/train-venv/bin/python"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
"$V" train_seg.py train --data "$TRAIN_DATA" --model "$TRAIN_MODEL" --out "$TRAIN_OUT" --save-every 50 ${TRAIN_ARGS:-}
"$V" train_seg.py merge --adapter "$TRAIN_OUT/adapter" --out "$TRAIN_OUT/merged"
echo "trained and merged: $TRAIN_OUT/merged"
