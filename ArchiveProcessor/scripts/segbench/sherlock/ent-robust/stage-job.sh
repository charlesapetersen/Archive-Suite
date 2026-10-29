#!/bin/bash
#SBATCH --job-name=entr-stage
#SBATCH --partition=normal
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=01:00:00
# W46.ent-robust: copy the Mac-frozen pack into scratch on a CPU node, check every file's hash, and fetch
# Qwen3.6-27B-FP8 if the cache lacks it (seg-context/stage-job.sh's pattern).
#   sbatch ... stage-job.sh SOURCE ROOT JOB
set -euo pipefail
SOURCE="$1"; ROOT="$2"; JOB="$3"
: "${SLURM_JOB_ID:?must run as a Slurm job}"
source "$JOB/sh.env"
[ -s "$SOURCE/freeze.json" ] || { echo 'source pack missing'; exit 2; }
mkdir -p "$ROOT" "$HF_HOME" "$SH_SHIM"
printf 'import sys\nsys.modules.setdefault("torchcodec", None)\n' > "$SH_SHIM/sitecustomize.py"
if [ -e "$ROOT/freeze.json" ]; then
  cmp "$SOURCE/freeze.json" "$ROOT/freeze.json" || { echo 'a different pack is already staged'; exit 2; }
fi
# Never replace answers or change a frozen pack in place.
rsync -a --ignore-existing --exclude=/logs --exclude='/*/out' "$SOURCE/" "$ROOT/"
"$FS_PY" "$ROOT/support/check_pack.py" "$ROOT"
echo "download Qwen/Qwen3.6-27B-FP8"
apptainer -s exec --bind "$SCRATCH,$GROUP_HOME" --env HF_HOME="$HF_HOME" "$SH_IMG" hf download Qwen/Qwen3.6-27B-FP8 > /dev/null
echo "Qwen--Qwen3.6-27B-FP8 $(cat "$HF_HOME/hub/models--Qwen--Qwen3.6-27B-FP8/refs/main")"
echo "staged $ROOT"
