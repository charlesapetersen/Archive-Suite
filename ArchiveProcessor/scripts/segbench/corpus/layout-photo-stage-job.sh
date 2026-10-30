#!/bin/bash
#SBATCH --job-name=w46-layout-photo-stage
#SBATCH --partition=normal
#SBATCH --cpus-per-task=2
#SBATCH --mem=4G
#SBATCH --time=00:20:00
# W46.layout-photo: copy the Mac-frozen pack into scratch on a CPU node and check it (owner-attended submission).
#   sbatch ... layout-photo-stage-job.sh SOURCE ROOT SH_DIR
# Never replaces receipts or changes a staged pack in place; no download: GLM-OCR's weights and the open sweep's
# prompt are the ones W46.ocr-regions staged, and the 96, L9 and L4 page copies are its frozen cluster copies.
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
"$FS_PY" "$ROOT/layout_photo_cluster.py" check --root "$ROOT" --strict
cache="$HF_HOME/hub/models--zai-org--GLM-OCR"
[ -d "$cache/snapshots" ] || { echo 'missing GLM-OCR weight cache'; exit 2; }
prompt=$("$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["glm-ocr"]["prompt"])' "$ROOT/routes.json")
[ -f "$prompt" ] || { echo "missing prompt $prompt"; exit 2; }
