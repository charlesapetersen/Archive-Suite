#!/bin/bash
# W46.ocr-logprob: submit from the FarmShare login node, then log out; nothing waits on the login.
#   bash logprob-submit.sh ROOT setup [--dry-run]   the CPU download job (Qwen3.5-9B), its id in ROOT/jobs.tsv
#   bash logprob-submit.sh ROOT run [--dry-run]     one GPU job per route; Qwen3.5-9B's waits afterok on setup
# Two GPU jobs in all (each runs its own three-page pilot gate first), because the gpu QOS takes at most 32
# submitted jobs per user and the other W46 waves hold most of them.
set -euo pipefail
ROOT="$1"; WHAT="$2"; DRY="${3:-}"
cd "$ROOT"; mkdir -p logs
run() { if [ "$DRY" = --dry-run ]; then printf '%q ' "$@" >&2; echo >&2; echo 0; else "$@"; fi; }
# A dry run records nothing: its placeholder ids would otherwise read as real jobs.
rec() { if [ "$DRY" = --dry-run ]; then printf '%s\n' "$*" >&2; else printf '%s\t%s\n' "$@" >> jobs.tsv; fi; }
if [ "$WHAT" = setup ]; then
  id=$(run sbatch --parsable --partition=normal --cpus-per-task=4 --mem=16G --time=02:00:00 --job-name=logprob-setup \
    --output="$ROOT/logs/slurm-%j.out" "$ROOT/logprob-setup-job.sh" "$ROOT")
  rec setup "$id"; cat jobs.tsv 2>/dev/null || true; exit 0
fi
setup=$(awk -F'\t' '$1 == "setup" {print $2}' jobs.tsv 2>/dev/null | tail -1)
for route in lightonocr3-4b qwen3.5-9b; do
  hours=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]["hours"])' routes.json "$route")
  dep=()
  if [ "$route" = qwen3.5-9b ] && [ -n "$setup" ] && [ ! -f setup.json ]; then dep=(--dependency="afterok:$setup"); fi
  id=$(run sbatch --parsable --partition=gpu --gres=gpu:1 --cpus-per-task=8 --mem=64G --time="$hours:00:00" "${dep[@]}" \
    --job-name="logprob-$route" --output="$ROOT/logs/slurm-%j.out" "$ROOT/logprob-job.sh" "$ROOT" "$route")
  rec "$route" "$id"
done
cat jobs.tsv
