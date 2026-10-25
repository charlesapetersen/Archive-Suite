#!/bin/bash
#SBATCH --job-name=w46-cells-stage
#SBATCH --partition=normal
#SBATCH --cpus-per-task=2
#SBATCH --mem=4G
#SBATCH --time=00:10:00
# Owner-attended submission only. Copies the new Mac-frozen pack on a CPU node;
# unlike the older stage-job.sh this source is not a FarmShare mirror.
set -euo pipefail
SOURCE="$1"; ROOT="$2"; SH_DIR="$3"
: "${SLURM_JOB_ID:?must run as a Slurm job}"
source "$SH_DIR/sh.env"
[ -s "$SOURCE/freeze.json" ] && [ -s "$SOURCE/truth.json" ] || { echo 'source pack missing'; exit 2; }
mkdir -p "$ROOT"
if [ -e "$ROOT/freeze.json" ]; then
  cmp "$SOURCE/freeze.json" "$ROOT/freeze.json" || { echo 'different pack already staged'; exit 2; }
fi
# Never replace receipts or change a frozen pack in place.
rsync -a --ignore-existing --exclude=/out --exclude=/runtime --exclude=/logs "$SOURCE/" "$ROOT/"
"$FS_PY" "$ROOT/regions_cells.py" check --root "$ROOT" --phase all
# Parent run already staged these weights. No download or model list expansion here.
for model in zai-org/GLM-OCR Qwen/Qwen3.6-27B-FP8; do
  cache="$HF_HOME/hub/models--${model//\//--}"
  [ -d "$cache/snapshots" ] || { echo "missing parent weight cache: $model"; exit 2; }
done
