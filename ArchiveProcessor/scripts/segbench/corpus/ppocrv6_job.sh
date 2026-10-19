#!/bin/bash
set -euo pipefail
root=$1
export HF_HOME="$root/hf"
export PADDLE_PDX_CACHE_HOME="$root/paddlex-cache"
export PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-8}"
"$root/venv/bin/python" "$root/recovery/ppocrv6_run.py" run "$root"
