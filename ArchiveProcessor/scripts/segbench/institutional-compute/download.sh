#!/usr/bin/env bash
# W41.farmshare-plan — fetch one preset's weights into $HF_HOME on scratch (login node; resumable).
#   bash download.sh qwen3.6-27b
#   bash download.sh glm-ocr       # GLM-OCR and the DocLayout-YOLO checkpoint the layout route needs
set -euo pipefail
cd "$(dirname "$0")"
source compute.env
source runtime.sh; load_cluster_modules; source models.sh; preset "$1"
export HF_HOME
free_gb=$(df -Pk "$HF_HOME" | awk 'NR==2 {print int($4/1048576)}')
if [ "$free_gb" -lt $((IC_DISK_GB + 5)) ]; then
  echo "need ~${IC_DISK_GB} GB for $IC_MODEL, $free_gb GB free under $HF_HOME"; exit 1
fi
# Public Apache-2.0 repos: no Hugging Face token needed.
bin="$(dirname "$IC_PY")"
cli="$bin/hf"; [ -x "$cli" ] || cli="$bin/huggingface-cli"   # huggingface_hub 1.x renamed the CLI to hf
# One pattern per --exclude: hf 1.x takes a single value per flag and reads any further words as FILE NAMES, so
# "--exclude a b c" downloaded nothing at all on 2026-10-15 ("Fetching 0 files").
"$cli" download "$IC_MODEL" --exclude '*.gguf' --exclude '*.pth' --exclude 'original/*'
# The detector loads its checkpoint with hf_hub_download, which finds it in this cache on the offline GPU node.
[ -z "${IC_DET_REPO:-}" ] || "$cli" download "$IC_DET_REPO" "$IC_DET_FILE"
du -sh "$HF_HOME"
