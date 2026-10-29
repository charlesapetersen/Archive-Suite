#!/bin/bash
#SBATCH --job-name=ctx-stage
#SBATCH --partition=normal
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=03:00:00
# W46.seg-context: copy the Mac-frozen pack into scratch on a CPU node and fetch the two base models if the cache
# lacks them (Sherlock keeps copies and downloads off its login nodes; stage-job.sh's pattern).
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
rsync -a --ignore-existing --exclude=/runs --exclude=/runtime --exclude=/logs --exclude=/seg-2b-merged --exclude=/segbench-cache \
  "$SOURCE/" "$ROOT/"
"$FS_PY" "$ROOT/support/segbench/seg_context.py" check --root "$ROOT"
# The teacher at the checkpoint every FarmShare teacher row used, and the student's base. hf download skips files
# already in the cache.
for repo in Qwen/Qwen3.5-27B-FP8 Qwen/Qwen3.5-2B; do
  echo "download $repo"
  apptainer -s exec --bind "$SCRATCH,$GROUP_HOME" --env HF_HOME="$HF_HOME" "$SH_IMG" hf download "$repo" > /dev/null
done
du -sh "$HF_HOME"; echo "staged $ROOT"
