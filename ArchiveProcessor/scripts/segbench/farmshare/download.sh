#!/usr/bin/env bash
# W41.farmshare-plan — fetch one preset's weights into $HF_HOME on scratch (login node; resumable).
#   bash download.sh qwen3.6-27b
set -euo pipefail
cd "$(dirname "$0")"
source fs.env; source models.sh; preset "$1"
export HF_HOME
free_gb=$(df -Pk "$HF_HOME" | awk 'NR==2 {print int($4/1048576)}')
if [ "$free_gb" -lt $((FS_DISK_GB + 5)) ]; then
  echo "need ~${FS_DISK_GB} GB for $FS_MODEL, $free_gb GB free under $HF_HOME"; exit 1
fi
# Public Apache-2.0 repos: no Hugging Face token needed.
bin="$(dirname "$FS_PY")"
cli="$bin/hf"; [ -x "$cli" ] || cli="$bin/huggingface-cli"   # huggingface_hub 1.x renamed the CLI to hf
"$cli" download "$FS_MODEL" --exclude '*.gguf' '*.pth' 'original/*'
du -sh "$HF_HOME"
