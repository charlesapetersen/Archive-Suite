#!/bin/bash
#SBATCH --job-name=ppocr-setup
#SBATCH --partition=normal
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=01:30:00
# PP-OCRv6 on Sherlock (W46.enh-dewarp, W46.enh-ocr-input), one CPU job: Sherlock keeps installs off login nodes.
#   sbatch --output=... setup-ppocr-job.sh SH_DIR
# Stages FarmShare's ppocrv6-20261019 (pinned det/rec weights, paddlex cache, recovery/ppocrv6_run.py) into
# $SCRATCH/fs-ocr at its FarmShare path, and rebuilds FarmShare's overlay the way ppocrv6_setup.sh made it: a
# --system-site-packages venv over the vLLM environment (here the image, in $GROUP_HOME, never $SCRATCH), with
# paddleocr 3.7.0, paddlex[ocr-core] 3.7.2 and transformers 5.20.2, every version held to FarmShare's own freeze. The
# freeze's torch, torchvision, nvidia-* and cuda-* lines are left out of the constraints: FarmShare's torch was a CUDA
# 13 build that driver 550 cannot run, and the image's 2.13.0+cu129 already satisfies torch==2.13.0.
set -euo pipefail
SH_DIR="$1"; source "$SH_DIR/sh.env"
SRC="$GROUP_HOME/$USER/archive-suite/FarmShare-scratch-20261022/fs-ocr/ppocrv6-20261019"
rsync -a "$SRC/" "$FS_ROOT/ppocrv6-20261019/"
mkdir -p "$SH_SHIM" "$SCRATCH/cache/pip"
printf 'import sys\nsys.modules.setdefault("torchcodec", None)\n' > "$SH_SHIM/sitecustomize.py"
grep -v -i -E '^(torch|torchvision|triton|nvidia-|cuda-)' "$SRC/requirements-resolved.txt" > "$SCRATCH/ppocr-constraints-$SLURM_JOB_ID.txt"
run() { apptainer -s exec --bind "$SCRATCH,$GROUP_HOME" --env PIP_CACHE_DIR="$SCRATCH/cache/pip" \
  --env PYTHONPATH="$SH_SHIM" "$SH_IMG" "$@"; }
[ -x "$SH_PPOCR_ENV/bin/python" ] || run python3 -m venv --system-site-packages "$SH_PPOCR_ENV"
run "$SH_PPOCR_ENV/bin/python" -m pip install -q --disable-pip-version-check \
  -c "$SCRATCH/ppocr-constraints-$SLURM_JOB_ID.txt" \
  'paddleocr==3.7.0' 'paddlex[ocr-core]==3.7.2' 'transformers==5.20.2' 'numpy==2.3.5'
run "$SH_PPOCR_ENV/bin/python" -m pip freeze > "$SH_PPOCR_ENV/requirements-resolved.txt"
run "$SH_PPOCR_ENV/bin/python" -c 'import torch, paddleocr, paddlex, transformers, numpy
print("torch", torch.__version__, torch.__file__); print("paddleocr", paddleocr.__version__, "paddlex", paddlex.__version__,
      "transformers", transformers.__version__, "numpy", numpy.__version__)
assert torch.__version__.endswith("+cu129"), "the overlay replaced the image torch"'
rm -f "$SCRATCH/ppocr-constraints-$SLURM_JOB_ID.txt"
echo "PP-OCRv6 overlay ready: $SH_PPOCR_ENV"
