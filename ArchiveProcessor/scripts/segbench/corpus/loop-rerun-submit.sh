#!/bin/bash
# W46.ocr-loops: submit the whole rerun from the FarmShare login node, then log out; nothing waits on the login.
#   bash loop-rerun-submit.sh ROOT [--dry-run]
# A three-page pilot (LightOnOCR-3 0.8B, n-gram arm) goes first, held until every job is accepted; each one-GPU
# route x arm job follows it afterok, and Ling's two four-GPU jobs follow all of those (afterany), so a whole-node
# job never sits ahead of the one-GPU queue under the four-GPU user limit. Job ids land in ROOT/jobs.tsv.
#   bash loop-rerun-submit.sh ROOT t96 PILOT_JOB [--dry-run]
# The 96's own caps (routes.json's t96-* entries, from the truth96 run), one GPU job per route x arm, after the
# same pilot. Appended to jobs.tsv.
set -euo pipefail
ROOT="$1"; DRY="${2:-}"
cd "$ROOT"
JOB="$ROOT/loop-rerun-job.sh"
run() { if [ "$DRY" = --dry-run ]; then printf '%q ' "$@" >&2; echo >&2; echo 0; else "$@"; fi; }
if [ "${2:-}" = t96 ]; then
  PILOT="$3"; DRY="${4:-}"
  for route in $(python3 -c 'import json;print(" ".join(k for k in json.load(open("routes.json")) if k.startswith("t96-")))'); do
    for arm in ngram half; do
      id=$(run sbatch --parsable --partition=gpu --gres=gpu:1 --cpus-per-task=8 --mem=64G --time=01:00:00 \
        --dependency="afterok:$PILOT" --job-name="loops-$route-$arm" --output="$ROOT/logs/slurm-%j.out" \
        "$JOB" "$ROOT" "$route" "$arm")
      printf '%s\t%s\t%s\n' "$route" "$arm" "$id" >> jobs.tsv
    done
  done
  cat jobs.tsv; exit 0
fi
head -3 caps/lightonocr3-0.8b.jsonl > caps/pilot.jsonl
python3 - "$ROOT/routes.json" <<'EOF'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['pilot']=dict(d['lightonocr3-0.8b'], hours=1, caps=3); json.dump(d,open(p,'w'),indent=2)
EOF
: > jobs.tsv
pilot=$(run sbatch --parsable --hold --partition=gpu --gres=gpu:1 --cpus-per-task=8 --mem=64G --time=01:00:00 \
  --job-name=loops-pilot --output="$ROOT/logs/slurm-%j.out" "$JOB" "$ROOT" pilot ngram)
printf 'pilot\tngram\t%s\n' "$pilot" >> jobs.tsv
deps=()
for route in lightonocr3-0.8b paddleocr-vl1.5 glm-ocr lightonocr3-4b qwen3.5-4b qwen3-vl-8b qwen3.6-35b-a3b qwen3.6-27b qwen3.5-27b; do
  hours=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]["hours"])' routes.json "$route")
  for arm in ngram half; do
    id=$(run sbatch --parsable --partition=gpu --gres=gpu:1 --cpus-per-task=8 --mem=64G --time="$hours:00:00" \
      --dependency="afterok:$pilot" --job-name="loops-$route-$arm" --output="$ROOT/logs/slurm-%j.out" \
      "$JOB" "$ROOT" "$route" "$arm")
    printf '%s\t%s\t%s\n' "$route" "$arm" "$id" >> jobs.tsv; deps+=("$id")
  done
done
prev=$(IFS=:; echo "${deps[*]}")
for arm in ngram half; do
  id=$(run sbatch --parsable --partition=gpu --nodes=1 --gres=gpu:4 --cpus-per-task=16 --mem=220G --time=06:00:00 \
    --dependency="afterany:$prev" --job-name="loops-ling-$arm" --output="$ROOT/logs/slurm-%j.out" \
    "$JOB" "$ROOT" ling3-flash-vl-fp8 "$arm")
  printf 'ling3-flash-vl-fp8\t%s\t%s\n' "$arm" "$id" >> jobs.tsv; prev="$id"
done
run scontrol release "$pilot" >/dev/null
cat jobs.tsv
