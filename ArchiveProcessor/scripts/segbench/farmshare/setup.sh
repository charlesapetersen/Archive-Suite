#!/usr/bin/env bash
# W41.farmshare-plan — one-time environment on a FarmShare login node (no GPU needed to install).
#   bash setup.sh            # reads the cluster's limits, then builds the venv on scratch
# Writes: ./limits.env (from limits.py) and ./fs.env (paths every later step sources).
set -euo pipefail
cd "$(dirname "$0")"

python3 limits.py --out limits.env
source limits.env
ROOT="${FS_SCRATCH:-$HOME}/fs-ocr"
[ -n "${FS_SCRATCH:-}" ] || echo "WARNING: no scratch found, using \$HOME (check the quota printed above)"
mkdir -p "$ROOT"/{hf,runs,logs}

# Python: prefer a module, then whatever python3 is newest. vLLM wants 3.10-3.13.
if command -v module >/dev/null 2>&1; then
  module load python/3.12 2>/dev/null || module load python 2>/dev/null || true
fi
PY="$(command -v python3.12 || command -v python3.11 || command -v python3)"
"$PY" -c 'import sys; assert (3, 10) <= sys.version_info[:2] <= (3, 13), sys.version' \
  || { echo "need Python 3.10-3.13 for vLLM; try: module avail python"; exit 1; }

if [ ! -x "$ROOT/venv/bin/python" ]; then
  "$PY" -m venv "$ROOT/venv"
fi
"$ROOT/venv/bin/pip" install -q --upgrade pip
# vLLM's wheel carries its own CUDA runtime; the node only needs the NVIDIA driver. Not pinned: the Qwen3.6
# architecture needs a recent release. The version that ran is recorded in every run's summary (pip freeze).
"$ROOT/venv/bin/pip" install -q "vllm${FS_VLLM_VERSION:+==$FS_VLLM_VERSION}" "huggingface_hub[cli]" \
  -r ../ocr-panel-requirements.txt

# FlashInfer compiles kernels at start-up with the venv's own CUDA toolkit (job.sbatch points CUDA_HOME at it). pip
# brought the 13.4 compiler (nvcc, crt and nvvm's cicc) beside torch's 13.0 runtime headers and ptxas, and the
# compile stopped first at "CUDA compiler and CUDA toolkit headers are incompatible", then at "Unsupported .version
# 9.4" (2026-10-15). Pin all three to torch's CUDA version. Do this with no job queued: a job that starts mid-swap
# mixes the two versions.
cu="$("$ROOT/venv/bin/python" -c 'import torch; print(torch.version.cuda or "")')"
if [ -n "$cu" ]; then
  "$ROOT/venv/bin/pip" install -q "nvidia-cuda-nvcc==$cu.*" "nvidia-cuda-crt==$cu.*" "nvidia-nvvm==$cu.*"
fi

cat > fs.env <<EOF
FS_ROOT=$ROOT
HF_HOME=$ROOT/hf
FS_PY=$ROOT/venv/bin/python
FS_VLLM=$ROOT/venv/bin/vllm
EOF
"$ROOT/venv/bin/python" -c 'import vllm, sacrebleu, rapidfuzz, PIL; print("vllm", vllm.__version__)'
echo "ready: $(cat fs.env | tr '\n' ' ')"
