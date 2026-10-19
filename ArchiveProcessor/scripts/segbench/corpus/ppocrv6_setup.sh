#!/bin/bash
set -euo pipefail
root=$1
base=/scratch/users/cp1/fs-ocr/venv/bin/python
export HF_HOME="$root/hf"
export PADDLE_PDX_CACHE_HOME="$root/paddlex-cache"
export PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-8}"
test ! -e "$root/venv"
"$base" -m venv --system-site-packages "$root/venv"
# All overlays live in this new venv. Never upgrade the shared vLLM environment.
"$root/venv/bin/python" -m pip install --disable-pip-version-check \
  'paddleocr==3.7.0' 'paddlex[ocr-core]==3.7.2' 'transformers==5.20.2' \
  'torch==2.13.0' 'torchvision==0.28.0' 'numpy==2.3.5'
"$root/venv/bin/python" -m pip freeze > "$root/requirements-resolved.txt"
"$root/venv/bin/python" "$root/recovery/ppocrv6_run.py" prepare "$root"
