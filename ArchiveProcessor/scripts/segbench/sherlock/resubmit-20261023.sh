#!/bin/bash
# The 2026-10-22 night's failed W46 jobs, submitted again from a Sherlock login node in an owner-started session
# (2026-10-23), once their causes are fixed. Causes, from the logs:
#   - truth pack: every job reading the owner's 99 pages looked for FarmShare's /home/users/cp1/fs-truthpack, never
#     staged. It is rebuilt on the Mac (institutional-compute/cluster_ocr.py pack, from the panel's frozen originals)
#     and copied to the same path here; its 99 images match every hash the packs record.
#   - enh-probe: scipy, albumentations and whatever else the restorers import that the vLLM image lacks
#     (fix-20261023-job.sh adds them in an overlay venv, $SH_ENH_ENV).
#   - postcorrect: six 895 images missing from interactive-20261019 (fix-20261023-job.sh copies them).
#   bash resubmit-20261023.sh [--dry-run]          ONLY=regions,logprob,... for some sections
# Sections, each running its job script unchanged with the hours and cards it had on 2026-10-22:
#   regions      W46.ocr-regions, the seven reader shards
#   logprob      W46.ocr-logprob, its two jobs (each runs its own three-page gate)
#   new96        W46.ocr-new-open, the 96-set runs of the three models whose 895 runs passed
#   enhprobe     W46.enh-ocr-input's probe: the two diffusion restorers, then Qwen3.6-27B on them afterok
#   postcorrect  W46.ocr-postcorrect: postcorrect_cluster.py sends only the requests with no output yet
# Not resubmitted: the capture ladder's 27B shards (31 of 1,581 requests over the 600 s generation limit, a result),
# OvisOCR2 (its pilot capped a page, the harness's own refusal), TeleOCR (vLLM 0.31 refuses its rotary embedding),
# and Ling's two held jobs, which need only scontrol release. Job ids: $FS_ROOT/sherlock-20261023.tsv.
set -euo pipefail
DRY="${1:-}"
SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SH_DIR/sh.env"
ONLY="${ONLY:-}"
want() { [ -z "$ONLY" ] || [[ ",$ONLY," == *",$1,"* ]]; }
TSV="$FS_ROOT/sherlock-20261023${ONLY:+-${ONLY//,/-}}.tsv"; [ "$DRY" != --dry-run ] || TSV=/dev/stderr
[ "$DRY" = --dry-run ] || [ ! -e "$TSV" ] || { echo "$TSV exists: this resubmission was submitted already"; exit 2; }
run() { if [ "$DRY" = --dry-run ]; then printf '%q ' "$@" >&2; echo >&2; echo 0; else "$@"; fi; }
rec() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$TSV"; }
G1=(--partition=gpu -G 1 -C "$SH_GPU_C" --cpus-per-task=8 --mem=64G)
CORPUS="$(cd "$SH_DIR/../corpus" && pwd)"
REG="$FS_ROOT/regions-20261021" LP="$FS_ROOT/logprob-20261022" ENH="$FS_ROOT/enh-ocr-input-20261022"
PC="$FS_ROOT/postcorrect-20261022"
field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]].get(sys.argv[3]) or "-")' "$@"; }

# Each fix is checked before anything is queued, so a section never waits on a GPU for a cause still in place.
n=$(ls "$HOME/fs-truthpack/images" 2>/dev/null | wc -l)
[ "$n" -eq 99 ] || { echo "truth pack: $n of 99 images in $HOME/fs-truthpack"; exit 2; }
if want enhprobe; then
  [ -e "$SH_ENH_ENV/.imports-ok" ] || { echo "enhprobe: run fix-20261023-job.sh first (no $SH_ENH_ENV/.imports-ok)"; exit 2; }
fi
if want postcorrect; then
  python3 - "$PC/requests.jsonl" <<'PY' || exit 2
import json, os, sys
miss = set()
for line in open(sys.argv[1]):
    r = json.loads(line)
    for im in (r.get('images') or [r.get('image')]):
        if im and not os.path.exists(im):     # a text-only request has no image
            miss.add(im)
if miss:
    sys.exit('postcorrect: %d images still missing, e.g. %s' % (len(miss), sorted(miss)[0]))
PY
fi

if want regions; then
for spec in glm-ocr:1:6 paddleocr-vl1.5:1:8 lightonocr3-4b:1:8 qwen3.6-27b:4:12; do
  IFS=: read -r route shards h <<< "$spec"
  for ((i = 0; i < shards; i++)); do
    id=$(run sbatch --parsable "${G1[@]}" --time="$h:00:00" --job-name="regions-$route-$i" \
      --output="$REG/logs/slurm-%j.out" "$CORPUS/regions-job.sh" "$REG" read "$route" "$i/$shards")
    rec regions "$route/$i/$shards" "$id"
  done
done
fi

if want logprob; then
for route in lightonocr3-4b qwen3.5-9b; do
  h=$(field "$LP/routes.json" "$route" hours)
  id=$(run sbatch --parsable "${G1[@]}" --time="$h:00:00" --job-name="logprob-$route" \
    --output="$LP/logs/slurm-%j.out" "$CORPUS/logprob-job.sh" "$LP" "$route")
  rec logprob "$route" "$id"
done
fi

if want new96; then
for key in paddleocr-vl16 xiaomi-ocr-0 qwen38-27b-fp8; do
  prep="$FS_ROOT/new-open-895/$key/prepared.json"
  c=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("gpu_c") or "-")' "$prep")
  h=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("hours", 4))' "$prep")
  [ "$c" != - ] || c="$SH_GPU_C"
  id=$(run sbatch --parsable --partition=gpu -G 1 -C "$c" --cpus-per-task=8 --mem=64G --time="$h:00:00" \
    --job-name="new-open-96-$key" --output="$FS_ROOT/new-open-96/$key/logs/slurm-%j.out" \
    "$SH_DIR/new-open/job.sh" "$SH_DIR" 96 "$key")
  rec new96 "$key" "$id"
done
fi

if want enhprobe; then
probe=$(run sbatch --parsable "${G1[@]}" --time=08:00:00 --job-name=enh-probe \
  --output="$ENH/logs/slurm-%j.out" "$CORPUS/enh-ocr-job.sh" "$ENH" enhance resshift-s1,resshift-s2,nafdpm-s1,nafdpm-s2)
rec enh enhance/probe "$probe"
id=$(run sbatch --parsable "${G1[@]}" --time=05:00:00 --dependency="afterok:$probe" --job-name=enh-probe-qwen3.6-27b \
  --output="$ENH/logs/slurm-%j.out" "$CORPUS/enh-ocr-job.sh" "$ENH" whole qwen3.6-27b 0/1 probe)
rec enh whole/qwen3.6-27b/probe "$id"
fi

if want postcorrect; then
id=$(run sbatch --parsable "${G1[@]}" --time=01:00:00 --job-name=postcorrect \
  --output="$PC/logs/slurm-%j.out" "$SH_DIR/postcorrect-job.sh" "$SH_DIR" "$PC")
rec postcorrect full "$id"
fi

[ "$DRY" = --dry-run ] || cat "$TSV"
