#!/bin/bash
# W46.ocr-regions: submit the whole run from the FarmShare login node, then log out; nothing waits on the login.
#   bash regions-submit.sh ROOT [--dry-run]
# The DocLayout-YOLO pass goes first, held until every job is accepted; a three-page pilot (GLM-OCR, all three
# arms) follows it afterok; each route's shards follow the pilot afterok, so a broken detector or reader stops the
# chain before the GPU hours. Qwen3.6-27B, about 65 whole pages a GPU-hour, is split into four page shards.
# ROOT must already hold pages.jsonl, routes.json and regions/pp-doclayoutv3.json (regions.py). Job ids: ROOT/jobs.tsv.
set -euo pipefail
ROOT="$1"; DRY="${2:-}"
cd "$ROOT"
[ -s pages.jsonl ] && [ -s routes.json ] && [ -s regions/pp-doclayoutv3.json ] || { echo "ROOT is not prepared"; exit 2; }
TSV=jobs.tsv; [ "$DRY" != --dry-run ] || TSV=jobs-dry.tsv
[ "$TSV" = jobs-dry.tsv ] || [ ! -e jobs.tsv ] || { echo "jobs.tsv exists: this run was submitted already"; exit 2; }
JOB="$ROOT/regions-job.sh"
run() { if [ "$DRY" = --dry-run ]; then printf '%q ' "$@" >&2; echo >&2; echo DRY; else "$@"; fi; }
gpu=(--partition=gpu --gres=gpu:1 --cpus-per-task=8 --mem=64G --output="$ROOT/logs/slurm-%j.out")
detect=$(run sbatch --parsable --hold "${gpu[@]}" --time=02:00:00 --job-name=regions-detect "$JOB" "$ROOT" detect)
printf 'detect\t-\t%s\n' "$detect" > "$TSV"
pilot=$(run sbatch --parsable "${gpu[@]}" --time=01:00:00 --dependency="afterok:$detect" --job-name=regions-pilot \
  "$JOB" "$ROOT" read glm-ocr 0/1 3)
printf 'pilot\tglm-ocr\t%s\n' "$pilot" >> "$TSV"
for spec in glm-ocr:1:6 paddleocr-vl1.5:1:8 lightonocr3-4b:1:8 qwen3.6-27b:4:12; do
  IFS=: read -r route shards hours <<< "$spec"
  for ((i = 0; i < shards; i++)); do
    id=$(run sbatch --parsable "${gpu[@]}" --time="$hours:00:00" --dependency="afterok:$pilot" \
      --job-name="regions-$route-$i" "$JOB" "$ROOT" read "$route" "$i/$shards")
    printf '%s\t%s/%s\t%s\n' "$route" "$i" "$shards" "$id" >> "$TSV"
  done
done
run scontrol release "$detect" >/dev/null
cat "$TSV"
