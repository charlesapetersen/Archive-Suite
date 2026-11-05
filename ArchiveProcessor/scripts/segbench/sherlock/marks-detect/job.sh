#!/bin/bash
# W46.marks-detect GPU job: train YOLO11m on the combined public set, then box the 32 evaluation pages.
#   sbatch ... job.sh ROOT SH_DIR NAME EPOCHS HOURS
# Ultralytics' time= stops training at HOURS (the wall is set above it); best.pt by validation mAP is kept.
set -euo pipefail
ROOT="$1"; SH_DIR="$2"; NAME="$3"; EPOCHS="$4"; HOURS="$5"; source "$SH_DIR/sh.env"
ENV="$GROUP_HOME/$USER/envs/marks-yolo"; DATA="$FS_ROOT/marks-detect-data"
OUT="$GROUP_HOME/$USER/archive-suite/sherlock-results/$(basename "$ROOT")"
run() { apptainer -s exec --nv --bind "$SCRATCH,$GROUP_HOME" --env PYTHONPATH="$SH_SHIM" \
  --env YOLO_CONFIG_DIR="$ROOT/.ultralytics" "$SH_IMG" "$@"; }
cd "$ROOT"
nvidia-smi --query-gpu=name,memory.total --format=csv
start=$(date +%s)
run "$ENV/bin/python" "$ROOT/marks_detect_cluster.py" train --root "$ROOT" --data "$DATA" --name "$NAME" \
  --epochs "$EPOCHS" --hours "$HOURS" --weights "$ROOT/yolo11m.pt"
echo "train seconds: $(( $(date +%s) - start ))"
run "$ENV/bin/python" "$ROOT/marks_detect_cluster.py" predict --root "$ROOT" --name "$NAME"
mkdir -p "$OUT/runs/$NAME"
cp "$ROOT/out/$NAME.json" "$ROOT/out/dataset.json" "$OUT/"
cp "$ROOT/runs/$NAME/results.csv" "$ROOT/runs/$NAME/args.yaml" "$OUT/runs/$NAME/"
cp "$ROOT/runs/$NAME/weights/best.pt" "$OUT/runs/$NAME/"
cp "$ENV/requirements-resolved.txt" "$OUT/"
