#!/usr/bin/env bash
# W41.farmshare-plan — one-time environment on a Slurm cluster login node (no GPU needed to install).
#   bash setup.sh            # reads the cluster's limits, then builds the venv on scratch
#   bash setup.sh --layout   # afterwards, for the glm-ocr preset: adds newspaper-ocr + DocLayout-YOLO to that venv
# Writes: ./limits.env (from limits.py) and ./compute.env (paths every later step sources).
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = --layout ]; then
  # W41.farmshare-news-layout. The library NewsBench's 0.970 row came from (news_layout.py), at the version whose
  # docstring states it, with its DocLayout-YOLO and API extras. Every package already in the venv is pinned at its
  # installed version (torch, numpy, transformers, pydantic, opencv...), so pip adds around vLLM or stops with a
  # conflict; it never upgrades or swaps what the measured runs used.
  # Like the plain run, do this with no job queued.
  [ -f compute.env ] || { echo "run bash setup.sh first"; exit 1; }
  source compute.env
  source runtime.sh; load_cluster_modules
  pins="$IC_ROOT/vllm-pins.txt"
  "$IC_PY" -m pip freeze | grep -E '^[A-Za-z0-9._-]+==' > "$pins"
  "$IC_PY" -m pip install -q -c "$pins" "newspaper-ocr[api,doclayout]==0.11.0"
  "$IC_PY" -c 'import news_layout as N, newspaper_ocr.detectors.doclayout, vllm; print(N.versions(), "vllm", vllm.__version__)'
  exit 0
fi

profile=farmshare
if [ "${1:-}" = --profile ]; then profile="${2:?--profile needs NAME or FILE}"; shift 2; fi
[ $# -eq 0 ] || { echo 'usage: setup.sh [--profile NAME|FILE] (or --layout after setup)' >&2; exit 2; }
profile_env="$(python3 profiles.py "$profile")"; eval "$profile_env"
source runtime.sh; load_cluster_modules
python3 limits.py --profile "$IC_PROFILE" --out limits.env
source limits.env
ROOT="$IC_ROOT"
[ -d "$IC_SCRATCH" ] && [ -w "$IC_SCRATCH" ] || { echo "scratch is not writable: $IC_SCRATCH" >&2; exit 2; }
mkdir -p "$ROOT"/{hf,runs,logs} "$IC_STORAGE"

PY="$(command -v python3.12 || command -v python3.11 || command -v python3)"
"$PY" -c 'import sys; assert (3, 10) <= sys.version_info[:2] <= (3, 13), sys.version' \
  || { echo "need Python 3.10-3.13 for vLLM; try: module avail python"; exit 1; }

if [ ! -x "$ROOT/venv/bin/python" ]; then
  "$PY" -m venv "$ROOT/venv"
fi
"$ROOT/venv/bin/pip" install -q --upgrade pip
# vLLM's wheel carries its own CUDA runtime; the node only needs the NVIDIA driver. Not pinned: the Qwen3.6
# architecture needs a recent release. The version that ran is recorded in every run's summary (pip freeze).
"$ROOT/venv/bin/pip" install -q "vllm${IC_VLLM_VERSION:+==$IC_VLLM_VERSION}" "huggingface_hub[cli]" \
  -r ../ocr-panel-requirements.txt

# FlashInfer compiles kernels at start-up with the venv's own CUDA toolkit (job.sbatch points CUDA_HOME at it). pip
# brought the 13.4 compiler (nvcc, crt and nvvm's cicc) beside torch's 13.0 runtime headers and ptxas, and the
# compile stopped first at "CUDA compiler and CUDA toolkit headers are incompatible", then at "Unsupported .version
# 9.4" (2026-10-15). Pin all three to torch's CUDA version. Do this with no job queued: a job that starts mid-swap
# mixes the two versions.
cu="$("$ROOT/venv/bin/python" -c 'import torch; print(torch.version.cuda or "")')"
if [ "$IC_CUDA_MODE" = pip-toolkit ] && [ -n "$cu" ]; then
  "$ROOT/venv/bin/pip" install -q "nvidia-cuda-nvcc==$cu.*" "nvidia-cuda-crt==$cu.*" "nvidia-nvvm==$cu.*"
fi

# Quote every assignment: cluster scratch/storage paths can contain spaces.
IC_ROOT="$ROOT" HF_HOME="$ROOT/hf" IC_PY="$ROOT/venv/bin/python" IC_VLLM="$ROOT/venv/bin/vllm" \
  python3 - "$IC_PROFILE" > compute.env <<'PYENV'
import os, sys
from profiles import load, shell
values = load(sys.argv[1])
values.update({k: os.environ[k] for k in ('IC_ROOT', 'HF_HOME', 'IC_PY', 'IC_VLLM')})
print(shell(values), end='')
PYENV
"$ROOT/venv/bin/python" -c 'import vllm, sacrebleu, rapidfuzz, regex, PIL; print("vllm", vllm.__version__)'
echo "ready: $(cat compute.env | tr '\n' ' ')"
