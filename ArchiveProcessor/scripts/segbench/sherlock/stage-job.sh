#!/bin/bash
#SBATCH --job-name=w46-stage
#SBATCH --partition=normal
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=08:00:00
# W46 restart on Sherlock (2026-10-22): one CPU job, because Sherlock keeps copies and downloads off its login nodes.
#   sbatch --output=... stage-job.sh SH_DIR ROOT...      (ROOT: a pack folder name under fs-ocr, e.g. regions-20261021)
# Stages each pack from the FarmShare copy in $GROUP_HOME into $SCRATCH/fs-ocr, under the absolute path it had on
# FarmShare, puts this checkout's job scripts beside it, and downloads every model its routes.json names into
# $SCRATCH/fs-ocr/hf. FarmShare's jobs.tsv is kept as jobs-farmshare.tsv; a Sherlock submission starts its own.
# Rerunnable: rsync only copies what changed, and hf download skips files already in the cache.
set -euo pipefail
SH_DIR="$1"; shift
source "$SH_DIR/sh.env"
SRC="$GROUP_HOME/$USER/archive-suite/FarmShare-scratch-20261022/fs-ocr"
[ -d "$SRC" ] || { echo "no FarmShare copy at $SRC"; exit 2; }
mkdir -p "$FS_ROOT" "$HF_HOME" "$SH_SHIM"
# The image's torchcodec cannot load (no FFmpeg, CUDA 13 build); this marks it absent in every interpreter.
printf 'import sys\nsys.modules.setdefault("torchcodec", None)\n' > "$SH_SHIM/sitecustomize.py"
models="$SCRATCH/w46-models-$SLURM_JOB_ID.txt"; : > "$models"
for root in "$@"; do
  rsync -a --exclude=/jobs.tsv "$SRC/$root/" "$FS_ROOT/$root/"
  [ ! -e "$SRC/$root/jobs.tsv" ] || [ -e "$FS_ROOT/$root/jobs-farmshare.tsv" ] || cp "$SRC/$root/jobs.tsv" "$FS_ROOT/$root/jobs-farmshare.tsv"
  for f in "$SH_DIR"/../corpus/*-job.sh "$SH_DIR"/../corpus/loop-rerun-seq.sh; do
    [ ! -e "$FS_ROOT/$root/$(basename "$f")" ] || cp "$f" "$FS_ROOT/$root/"
  done
  # A route's model is a repo id, or (Ling) a snapshot path under FarmShare's HF cache, which is this one.
  "$FS_PY" - "$FS_ROOT/$root/routes.json" "$HF_HOME" >> "$models" <<'PY'
import json, re, sys
for name, r in json.load(open(sys.argv[1])).items():
    m = r.get('model', '')
    snap = re.search(r'/hub/models--(.+?)--(.+?)/snapshots/([0-9a-f]{40})', m)
    if snap:
        print(f'{snap.group(1)}/{snap.group(2)} {snap.group(3)}')
    elif m and not m.startswith('/'):
        print(f'{m} main')
PY
done
# The old FarmShare kit's text mode (W46.date-traceable-vision, W46.date-enclosure): its job.sbatch runs as it is,
# with an fs.env that points at this cluster's container wrappers; its CUDA block only warns without a toolkit.
HOME_COPY="$SRC/../farmshare-home"
if [ -d "$HOME_COPY/farmshare" ]; then
  rsync -a --exclude=/fs.env --exclude=__pycache__ "$HOME_COPY/farmshare/" "$FS_ROOT/text-kit/"
  printf 'FS_ROOT=%s\nHF_HOME=%s\nFS_PY=%s\nFS_VLLM=%s\n' "$FS_ROOT" "$HF_HOME" "$FS_PY" "$FS_VLLM" > "$FS_ROOT/text-kit/fs.env"
  mkdir -p "$FS_ROOT/text-packs"
  for p in fs-tracepack-vision fs-enclosurepack; do rsync -a "$HOME_COPY/$p/" "$FS_ROOT/text-packs/$p/"; done
fi
sort -u "$models" | while read -r repo rev; do
  echo "download $repo @ $rev"
  apptainer -s exec --bind "$SCRATCH,$GROUP_HOME" --env HF_HOME="$HF_HOME" "$SH_IMG" \
    hf download "$repo" --revision "$rev" > /dev/null
done
rm -f "$models"
du -sh "$HF_HOME"; echo "staged: $*"
