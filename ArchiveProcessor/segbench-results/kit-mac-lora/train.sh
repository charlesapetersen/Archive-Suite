#!/bin/bash
# train.sh DATA RANK ITERS [extra mlx_vlm.lora args] — one guarded mlx_vlm.lora run; log in logs/<data>-r<rank>-i<iters>.log
set -u
K="$HOME/Library/Caches/ArchiveSuiteRehearsal/kit-mac-lora"
data="$1" rank="$2" iters="$3"; shift 3
name="$data-r$rank-i$iters"
mkdir -p "$K/adapters/$name" "$K/logs"
cd "$K"
"$HOME/Claude/vision-ocr/ops/ocrlab/run-guarded.sh" --label "kit-mac-lora-$name" --rss-gb "${RSS:-8}" -- \
  env PYTHONPATH="$K/pylib" "$HOME/.local/share/visionocr-ocrlab/venv/bin/python" "${TRAINER:-/Users/cp1/Claude/.worktrees/archive-suite/suite-wt-20261104-124908-79933/ArchiveProcessor/scripts/segbench/kit_mac_lora.py}" train \
  --model-path "${BASE:-$HOME/.local/share/visionocr-ocrlab/mlx/seg-qwen3.5-2b-8bit}" --dataset "$K/$data" \
  --batch-size 1 --iters "$iters" --steps-per-report "${REPORT:-1}" --steps-per-eval 1000000 --steps-per-save 1000000 \
  --lora-rank "$rank" --lora-alpha $((rank * 2)) --grad-checkpoint --train-on-completions \
  --max-seq-length 16384 --learning-rate 1e-4 --output-path "$K/adapters/$name" "$@" > "$K/logs/$name.log" 2>&1
rc=$?
echo "exit=$rc" >> "$K/logs/$name.log"
exit $rc
