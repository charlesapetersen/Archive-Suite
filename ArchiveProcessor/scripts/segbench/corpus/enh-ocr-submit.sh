#!/bin/bash
# W46.enh-ocr-input: submit the cluster half from the FarmShare login node, then log out; nothing waits on the login.
#   bash enh-ocr-submit.sh ROOT [--dry-run]
# Two enhancement jobs: the four learned arms on the 96, and the two diffusion restorers twice each on the probe's
# 30. The readers follow their enhancement job afterok, so a failed arm stops before the readers' GPU hours:
# PP-OCRv6, Qwen3-VL 8B and GLM-OCR on regions after the first; Qwen3.6-27B on the probe after the second. Job ids
# in ROOT/jobs.tsv.
set -euo pipefail
ROOT="$1"; DRY="${2:-}"
cd "$ROOT"
for f in pages.json enh_ocr_cluster.py enh_ocr_arms.py enh-ocr-job.sh dewarp_cluster.py regions_cluster.py \
         regions/pp-doclayoutv3.json routes.json glm/routes.json probe/routes.json; do
  [ -s "$f" ] || { echo "ROOT is not prepared: $f"; exit 2; }
done
TSV=jobs.tsv; [ "$DRY" != --dry-run ] || TSV=jobs-dry.tsv
[ "$TSV" = jobs-dry.tsv ] || [ ! -e jobs.tsv ] || { echo "jobs.tsv exists: this run was submitted already"; exit 2; }
JOB="$ROOT/enh-ocr-job.sh"
run() { if [ "$DRY" = --dry-run ]; then printf '%q ' "$@" >&2; echo >&2; echo DRY; else "$@"; fi; }
gpu=(--partition=gpu --gres=gpu:1 --cpus-per-task=8 --mem=64G --output="$ROOT/logs/slurm-%j.out")
mkdir -p logs
: > "$TSV"
main=$(run sbatch --parsable "${gpu[@]}" --time=03:00:00 --job-name=enh-arms "$JOB" "$ROOT" enhance \
  docres-appearance,docres-deshadow,gcdrnet,sbb)
printf 'enhance\tmain\t%s\n' "$main" >> "$TSV"
probe=$(run sbatch --parsable "${gpu[@]}" --time=08:00:00 --job-name=enh-probe "$JOB" "$ROOT" enhance \
  resshift-s1,resshift-s2,nafdpm-s1,nafdpm-s2)
printf 'enhance\tprobe\t%s\n' "$probe" >> "$TSV"
for spec in "ppocr:-:2" "whole:qwen3-vl-8b:4" "regions:glm-ocr:4"; do
  IFS=: read -r kind route hours <<< "$spec"
  id=$(run sbatch --parsable "${gpu[@]}" --time="$hours:00:00" --dependency="afterok:$main" \
    --job-name="enh-$kind-$route" "$JOB" "$ROOT" "$kind" "$route" 0/1)
  printf '%s\t%s\t%s\n' "$kind" "$route" "$id" >> "$TSV"
done
id=$(run sbatch --parsable "${gpu[@]}" --time=05:00:00 --dependency="afterok:$probe" \
  --job-name=enh-probe-qwen3.6-27b "$JOB" "$ROOT" whole qwen3.6-27b 0/1 probe)
printf 'whole\tqwen3.6-27b\t%s\n' "$id" >> "$TSV"
cat "$TSV"
