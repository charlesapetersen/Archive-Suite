#!/bin/bash
# W46.enh-ocr-input: submit the cluster half from the FarmShare login node, then log out; nothing waits on the login.
#   bash enh-ocr-submit.sh ROOT [--dry-run]
# Two enhancement jobs: DocRes's two arms on the 96 (shading, GCDRNet and SBB come made from the Mac), and the two diffusion restorers twice each on the probe's
# 30. The readers follow their enhancement job afterok, so a failed arm stops before the readers' GPU hours:
# PP-OCRv6, Qwen3-VL 8B and GLM-OCR on regions after the first; Qwen3.6-27B on the probe after the second. Job ids
# in ROOT/jobs.tsv.
# Resumable: a job already in jobs.tsv is not submitted again, so when the GPU QOS's 32-submitted-jobs limit
# refuses one (other items' jobs fill it), the run stops there (exit 3) and a rerun later submits the rest.
set -euo pipefail
ROOT="$1"; DRY="${2:-}"
cd "$ROOT"
for f in images/gcdrnet/p001.jpg images/sbb/p001.jpg pages.json enh_ocr_cluster.py enh_ocr_arms.py enh-ocr-job.sh dewarp_cluster.py regions_cluster.py \
         regions/pp-doclayoutv3.json routes.json glm/routes.json probe/routes.json; do
  [ -s "$f" ] || { echo "ROOT is not prepared: $f"; exit 2; }
done
TSV=jobs.tsv; [ "$DRY" != --dry-run ] || { TSV=jobs-dry.tsv; : > "$TSV"; }
JOB="$ROOT/enh-ocr-job.sh"
gpu=(--partition=gpu --gres=gpu:1 --cpus-per-task=8 --mem=64G --output="$ROOT/logs/slurm-%j.out")
mkdir -p logs; touch "$TSV"
# sub KIND KEY SBATCH-ARGS...: KEY's id from jobs.tsv, else a new submission recorded there
sub() {
  local kind="$1" key="$2" id; shift 2
  id=$(awk -F'\t' -v k="$kind" -v r="$key" '$1==k && $2==r {print $3}' "$TSV")
  if [ -z "$id" ]; then
    if [ "$DRY" = --dry-run ]; then printf '%q ' sbatch "$@" >&2; echo >&2; id="DRY-$kind-$key"
    else id=$(sbatch --parsable "$@") || { echo "sbatch refused $kind $key (QOS limit?): rerun this script later" >&2; cat "$TSV" >&2; exit 3; }
    fi
    printf '%s\t%s\t%s\n' "$kind" "$key" "$id" >> "$TSV"
  fi
  echo "$id"
}
# dep ID: afterok while ID is queued or running; nothing once it has COMPLETED (a resumed run, Slurm has forgotten it)
dep() {
  case "$1" in DRY-*) echo "--dependency=afterok:$1"; return;; esac
  if [ -n "$(squeue -h -j "$1" 2>/dev/null)" ]; then echo "--dependency=afterok:$1"; return; fi
  local st; st=$(sacct -nX -P -j "$1" -o State 2>/dev/null | head -1)
  [ "$st" = COMPLETED ] && { echo "--begin=now"; return; }
  echo "enhancement job $1 is ${st:-unknown}, not COMPLETED: its readers are not submitted" >&2; exit 4
}
main=$(sub enhance main "${gpu[@]}" --time=02:00:00 --job-name=enh-arms "$JOB" "$ROOT" enhance \
  docres-appearance,docres-deshadow)
probe=$(sub enhance probe "${gpu[@]}" --time=08:00:00 --job-name=enh-probe "$JOB" "$ROOT" enhance \
  resshift-s1,resshift-s2,nafdpm-s1,nafdpm-s2)
dmain=$(dep "$main"); dprobe=$(dep "$probe")
for spec in "ppocr:-:2" "whole:qwen3-vl-8b:4" "regions:glm-ocr:4"; do
  IFS=: read -r kind route hours <<< "$spec"
  sub "$kind" "$route" "${gpu[@]}" --time="$hours:00:00" "$dmain" \
    --job-name="enh-$kind-$route" "$JOB" "$ROOT" "$kind" "$route" 0/1 > /dev/null
done
sub whole qwen3.6-27b "${gpu[@]}" --time=05:00:00 "$dprobe" \
  --job-name=enh-probe-qwen3.6-27b "$JOB" "$ROOT" whole qwen3.6-27b 0/1 probe > /dev/null
cat "$TSV"
