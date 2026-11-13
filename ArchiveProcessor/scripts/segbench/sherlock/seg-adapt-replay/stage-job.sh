#!/bin/bash
#SBATCH --job-name=sar-stage
#SBATCH --partition=normal
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=02:00:00
# W46.kit-continuation-replay: copy the Mac-frozen pack into scratch on a CPU node and fetch Qwen3.5-2B if the cache lacks it
# (seg-adapt-lora/stage-job.sh's pattern).
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
# Never replace answers, training output or a frozen pack in place.
rsync -a --ignore-existing --exclude=/runs --exclude=/runtime --exclude=/logs --exclude='/seg-2b-merged*' \
  --exclude=/lora --exclude='/lora-*' --exclude=/segbench-cache "$SOURCE/" "$ROOT/"
"$FS_PY" "$ROOT/support/segbench/seg_adapt_replay.py" check --root "$ROOT"
echo "download Qwen/Qwen3.5-2B"
apptainer -s exec --bind "$SCRATCH,$GROUP_HOME" --env HF_HOME="$HF_HOME" "$SH_IMG" hf download Qwen/Qwen3.5-2B > /dev/null
echo "Qwen--Qwen3.5-2B $(cat "$HF_HOME/hub/models--Qwen--Qwen3.5-2B/refs/main")"
du -sh "$HF_HOME"; echo "staged $ROOT"
