#!/bin/bash
#SBATCH --job-name=w46-mixed-route-stage
#SBATCH --partition=normal
#SBATCH --cpus-per-task=2
#SBATCH --mem=4G
#SBATCH --time=00:20:00
# W46.mixed-route: copy the Mac-frozen pack into scratch on a CPU node and check it (owner-attended submission).
#   sbatch ... stage-job.sh SOURCE ROOT SH_DIR
# Never replaces receipts or changes a staged pack in place; no download: GLM-OCR's and Qwen3.6-27B's weights and
# prompts are the ones W46.ocr-regions staged. The 32 page images travel in the pack (images/).
set -euo pipefail
SOURCE="$1"; ROOT="$2"; SH_DIR="$3"
: "${SLURM_JOB_ID:?must run as a Slurm job}"
source "$SH_DIR/sh.env"
[ -s "$SOURCE/freeze.json" ] && [ -s "$SOURCE/pages.jsonl" ] || { echo 'source pack missing'; exit 2; }
mkdir -p "$ROOT"
if [ -e "$ROOT/freeze.json" ]; then
  cmp "$SOURCE/freeze.json" "$ROOT/freeze.json" || { echo 'different pack already staged'; exit 2; }
fi
rsync -a --ignore-existing --exclude=/out --exclude=/logs --exclude=/support "$SOURCE/" "$ROOT/"
"$FS_PY" "$ROOT/mixed_route_cluster.py" check --root "$ROOT" --strict
for model in zai-org--GLM-OCR Qwen--Qwen3.6-27B-FP8; do
  [ -d "$HF_HOME/hub/models--$model/snapshots" ] || { echo "missing $model weight cache"; exit 2; }
done
for route in glm-ocr qwen3.6-27b; do
  prompt=$("$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]["prompt"])' "$ROOT/routes.json" "$route")
  [ -f "$prompt" ] || { echo "missing prompt $prompt"; exit 2; }
done
