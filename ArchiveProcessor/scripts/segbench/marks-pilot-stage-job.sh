#!/bin/bash
#SBATCH --job-name=w46-marks-stage
#SBATCH --partition=normal
#SBATCH --cpus-per-task=2
#SBATCH --mem=4G
#SBATCH --time=00:10:00
# New Mac pack; CPU-node copies follow sherlock/stage-job.sh's container pattern.
set -euo pipefail
SOURCE="$1"; ROOT="$2"; SH_DIR="$3"
: "${SLURM_JOB_ID:?must be a Slurm job}"
source "$SH_DIR/sh.env"
[ -s "$SOURCE/freeze.json" ] || { echo 'source missing'; exit 2; }
mkdir -p "$ROOT"
if [ -e "$ROOT/freeze.json" ]; then
  cmp "$SOURCE/freeze.json" "$ROOT/freeze.json" || { echo 'different pack staged'; exit 2; }
fi
rsync -a --ignore-existing --exclude=/out --exclude=/intents --exclude=/runtime --exclude=/logs "$SOURCE/" "$ROOT/"
"$FS_PY" "$ROOT/support/marks_pilot.py" check --root "$ROOT"
# Existing Qwen weights only. No network, download or route expansion.
[ -d "$HF_HOME/hub/models--Qwen--Qwen3.6-27B-FP8/snapshots" ] || { echo 'cached Qwen weights missing'; exit 2; }
