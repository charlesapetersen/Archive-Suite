#!/bin/bash
# W46.seg-adapt-lora retry, 2026-11-05, owner-attended session. The first trainings (51209105, 51209147) failed in
# seg_adapt_lora.py replay: the corpus set train/full/data (5,885 windows, the 2B's own) was skipped because its
# data.json has no "rule" key, and its images (FarmShare ~/fs-cleanpack/images) were never on Sherlock. The images
# were copied to $GROUP_HOME/cp1/archive-suite/fs-cleanpack (owner approved the FarmShare copy, 2026-11-05) and
# ~/fs-cleanpack links there, the path data.json records. This resubmits only train-k50, k50, train-k200, k200,
# naming the corpus set with SAL_REPLAY; the merged base and the base run are reused.
set -euo pipefail
P="$GROUP_HOME/$USER/archive-suite/seg-adapt-lora-20261105"
JOB="$P/support/job"
source "$JOB/sh.env"
ROOT="$FS_ROOT/seg-adapt-lora-20261105"
export SAL_REPLAY="$GROUP_HOME/$USER/archive-suite/FarmShare-scratch-20261022/fs-ocr/train/full/data"
[ -s "$SAL_REPLAY/train.jsonl" ] || { echo "no replay set at $SAL_REPLAY"; exit 2; }
[ -d "$HOME/fs-cleanpack/images" ] || { echo "replay images missing at ~/fs-cleanpack/images"; exit 2; }
[ -f "$ROOT/seg-2b-merged/config.json" ] || { echo "merged base missing"; exit 2; }
TSV="$ROOT/jobs-retry-20261105.tsv"
(set -o noclobber; : > "$TSV") || { echo "$TSV exists: inspect the existing retry"; exit 2; }
gpu() {  # name, dependency (or empty), time limit, script, args...
  local name="$1" dep="$2" limit="$3"; shift 3
  local d=(); [ -z "$dep" ] || d=(--dependency="$dep" --kill-on-invalid-dep=yes)
  sbatch --parsable --partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G --time="$limit" \
    ${d[@]+"${d[@]}"} --job-name="sal-$name" --output="$ROOT/logs/$name-%j.out" "$@"
}
for k in 50 200; do
  t=$(gpu "train-k$k" "" 01:30:00 "$JOB/train-job.sh" "$ROOT" "$k")
  printf 'train-k%s\t%s\n' "$k" "$t" >> "$TSV"
  s=$(gpu "k$k" "afterok:$t" 00:45:00 "$JOB/job.sh" "$ROOT" "k$k")
  printf 'k%s\t%s\n' "$k" "$s" >> "$TSV"
done
cat "$TSV"
