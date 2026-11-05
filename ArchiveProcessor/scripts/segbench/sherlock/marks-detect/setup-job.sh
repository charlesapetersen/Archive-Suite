#!/bin/bash
#SBATCH --job-name=marks-detect-setup
#SBATCH --partition=normal
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=04:00:00
# W46.marks-detect, one CPU job (Sherlock keeps installs and downloads off login nodes):
#   sbatch --output=... setup-job.sh ROOT SH_DIR
# 1. An ultralytics overlay: a --system-site-packages venv over the vLLM image (in $GROUP_HOME, never $SCRATCH), so
#    the image's CUDA torch stays; opencv swapped for the headless build. The freeze is kept beside the venv.
# 2. The public data into $FS_ROOT/marks-detect-data: AnnoPage 1.1.0 from Zenodo (CC BY 4.0, 4,963,670,899 bytes,
#    size checked) and SignverOD from Hugging Face (ondrs/signverod, two parquet shards).
# 3. yolo11m.pt, and the combined YOLO dataset (marks_detect_cluster.py prep). Any failure stops the chain here.
set -euo pipefail
ROOT="$1"; SH_DIR="$2"; source "$SH_DIR/sh.env"
ENV="$GROUP_HOME/$USER/envs/marks-yolo"; DATA="$FS_ROOT/marks-detect-data"
mkdir -p "$SH_SHIM" "$SCRATCH/cache/pip" "$DATA/signverod"
[ -s "$SH_SHIM/sitecustomize.py" ] || printf 'import sys\nsys.modules.setdefault("torchcodec", None)\n' > "$SH_SHIM/sitecustomize.py"
run() { apptainer -s exec --bind "$SCRATCH,$GROUP_HOME" --env PIP_CACHE_DIR="$SCRATCH/cache/pip" \
  --env PYTHONPATH="$SH_SHIM" --env HF_HOME="$HF_HOME" --env YOLO_CONFIG_DIR="$ROOT/.ultralytics" "$SH_IMG" "$@"; }
[ -x "$ENV/bin/python" ] || run python3 -m venv --system-site-packages "$ENV"
run "$ENV/bin/python" -m pip install -q --disable-pip-version-check 'ultralytics>=8.3.150,<9' pyarrow
run "$ENV/bin/python" -m pip uninstall -q -y opencv-python || true
run "$ENV/bin/python" -m pip install -q --disable-pip-version-check opencv-python-headless
run "$ENV/bin/python" -m pip freeze > "$ENV/requirements-resolved.txt"
run "$ENV/bin/python" -c 'import torch, ultralytics, cv2, pyarrow
print("torch", torch.__version__, "ultralytics", ultralytics.__version__, "cv2", cv2.__version__)
assert torch.__version__.endswith("+cu129"), "the overlay replaced the image torch"'
ZIP="$DATA/AnnoPage_Dataset.zip"
if [ "$(stat -c %s "$ZIP" 2>/dev/null || echo 0)" != 4963670899 ]; then
  curl -fL --retry 5 -C - -o "$ZIP" 'https://zenodo.org/api/records/17531858/files/AnnoPage_Dataset.zip/content'
fi
[ "$(stat -c %s "$ZIP")" = 4963670899 ] || { echo 'AnnoPage zip size differs from Zenodo record 17531858'; exit 1; }
run "$ENV/bin/python" -c 'import sys
from huggingface_hub import snapshot_download
snapshot_download("ondrs/signverod", repo_type="dataset", local_dir=sys.argv[1], allow_patterns=["data/*.parquet"])' "$DATA/signverod"
cd "$ROOT"
run "$ENV/bin/python" -c 'from ultralytics import YOLO; YOLO("yolo11m.pt")'
[ -s "$ROOT/yolo11m.pt" ] || { echo 'yolo11m.pt not downloaded'; exit 1; }
run "$ENV/bin/python" "$ROOT/marks_detect_cluster.py" prep --root "$ROOT" --data "$DATA"
echo "marks-detect setup ready: $ENV, $DATA/yolo"
