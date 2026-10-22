#!/bin/bash
# W46.enh-dewarp: submit the cluster half from the FarmShare login node, then log out; nothing waits on the login.
#   bash dewarp-submit.sh ROOT [--dry-run]
# A three-image pilot per reader goes first (Qwen3.6-27B, LightOnOCR-3 4B, PP-OCRv6); each reader's shards follow
# its own pilot afterok, so a broken server or reader stops before its GPU hours. Qwen3.6-27B, about 65 whole pages a
# GPU-hour, is split into four shards. Nine jobs with the pilots; job ids in ROOT/jobs.tsv.
set -euo pipefail
ROOT="$1"; DRY="${2:-}"
cd "$ROOT"
[ -s pages.jsonl ] && [ -s routes.json ] && [ -s dewarp_cluster.py ] && [ -s regions_cluster.py ] || { echo "ROOT is not prepared"; exit 2; }
TSV=jobs.tsv; [ "$DRY" != --dry-run ] || TSV=jobs-dry.tsv
[ "$TSV" = jobs-dry.tsv ] || [ ! -e jobs.tsv ] || { echo "jobs.tsv exists: this run was submitted already"; exit 2; }
JOB="$ROOT/dewarp-job.sh"
run() { if [ "$DRY" = --dry-run ]; then printf '%q ' "$@" >&2; echo >&2; echo DRY; else "$@"; fi; }
gpu=(--partition=gpu --gres=gpu:1 --cpus-per-task=8 --mem=64G --output="$ROOT/logs/slurm-%j.out")
: > "$TSV"
for spec in qwen3.6-27b:4:4 lightonocr3-4b:1:2 ppocrv6:1:2; do
  IFS=: read -r route shards hours <<< "$spec"
  # The pilot reads the first three images whole; the shards then skip them (an image already read is not resent).
  pilot=$(run sbatch --parsable "${gpu[@]}" --time=01:00:00 --job-name="dewarp-pilot-$route" "$JOB" "$ROOT" "$route" 0/1 3)
  printf 'pilot\t%s\t%s\n' "$route" "$pilot" >> "$TSV"
  for ((i = 0; i < shards; i++)); do
    id=$(run sbatch --parsable "${gpu[@]}" --time="$hours:00:00" --dependency="afterok:$pilot" \
      --job-name="dewarp-$route-$i" "$JOB" "$ROOT" "$route" "$i/$shards")
    printf '%s\t%s/%s\t%s\n' "$route" "$i" "$shards" "$id" >> "$TSV"
  done
done
cat "$TSV"
