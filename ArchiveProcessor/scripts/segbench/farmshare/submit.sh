#!/usr/bin/env bash
# W41.farmshare-plan — submit a job fitted to the limits this cluster reported (limits.env, from setup.sh).
#   bash submit.sh truth PRESET --pack ~/fs-truthpack       # the 99 truth pages: score + pages/hour
#   bash submit.sh seg   qwen3.5-27b --pack ~/fs-segpack    # segmentation's Deaver windows (fs_seg.py pack)
#   bash submit.sh news  PRESET                              # NewsBench's 19 Library of Congress pages
#   bash submit.sh bulk  PRESET --in DIR --out DIR [--shards N]
#   bash submit.sh news-layout PRESET                        # NewsBench by regions for a general model (fs_news_layout.py)
# PRESET glm-ocr reads layout-first (DocLayout-YOLO + GLM-OCR per region) in any mode; it needs setup.sh --layout.
# Options: --hours H (capped at the cluster's limit), --dry-run (print the sbatch line only).
set -euo pipefail
cd "$(dirname "$0")"
FS_DIR="$(pwd)"
[ -f limits.env ] && [ -f fs.env ] || { echo "run setup.sh first"; exit 1; }
source limits.env; source fs.env; source models.sh

FS_MODE="${1:?mode: truth|seg|news|news-layout|bulk}"; FS_PRESET_NAME="${2:?preset (see models.sh)}"; shift 2
hours="" dry="" FS_PACK="" FS_IN="" FS_OUT="" FS_SHARDS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pack) FS_PACK="$(cd "$2" && pwd)"; shift 2 ;;
    --in) FS_IN="$(cd "$2" && pwd)"; shift 2 ;;
    --out) mkdir -p "$2"; FS_OUT="$(cd "$2" && pwd)"; shift 2 ;;
    --shards) FS_SHARDS="$2"; shift 2 ;;
    --hours) hours="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done
[ "$FS_MODE" = news ] && export FS_MAX_LEN="${FS_MAX_LEN:-32768}"  # 10k image tokens + up to 16k of text
# A segmentation window is up to seven pages (method_window.WINDOW) in one prompt: at most 11,734 prompt tokens on
# OpenRouter, plus 3,000 for the retry. 16,384 would leave too little room if vLLM counts the images higher.
# A detector beside vLLM on the same GPU (DocLayout-YOLO took 3.95 GB): at 92% vLLM ran out of memory partway and the
# later regions came back blank (2026-10-15), so news-layout serves at 80%, as the glm-ocr preset does.
[ "$FS_MODE" = news-layout ] && export FS_GPU_UTIL="${FS_GPU_UTIL:-0.80}"
[ "$FS_MODE" = seg ] && export FS_MM_IMAGES=7 FS_MAX_LEN="${FS_MAX_LEN:-20480}"
preset "$FS_PRESET_NAME"

if [ "$FS_GPUS" -gt "$FS_GPUS_PER_NODE" ] || [ "$FS_GPUS" -gt "$FS_MAXGPU_PU" ]; then
  echo "$FS_PRESET_NAME needs $FS_GPUS GPUs on one node; this cluster gives $FS_GPUS_PER_NODE a node, $FS_MAXGPU_PU a user"
  exit 1
fi
case "$FS_MODE" in
  truth) [ -n "$FS_PACK" ] || { echo "truth needs --pack (made on the Mac by fs_ocr.py pack)"; exit 2; }
         default_min=120 ;;
  seg)   [ -n "$FS_PACK" ] || { echo "seg needs --pack (made on the Mac by fs_seg.py pack)"; exit 2; }
         want_model="$("$FS_PY" -c 'import json, sys; print(json.load(open(sys.argv[1]))["model"])' "$FS_PACK/pack.json")"
         served="${FS_SERVED:-$FS_MODEL}"   # a student is served under its own name (models.sh seg-student)
         [ "$want_model" = "$served" ] || { echo "the pack is for $want_model; preset $FS_PRESET_NAME serves $served"; exit 2; }
         default_min=60 ;;
  news|news-layout)
         if [ "$FS_MODE" = news-layout ] && [ ! -x "$FS_ROOT/npo-venv/bin/python" ]; then
           echo "news-layout needs its newspaper-ocr venv: bash setup-layout.sh"; exit 2
         fi
         if [ ! -d "$FS_ROOT/newsbench" ]; then  # public domain scans + CC0 text; the commit the Vision OCR lab scored
           git clone -q https://github.com/nealcaren/newsbench.git "$FS_ROOT/newsbench"
           git -C "$FS_ROOT/newsbench" checkout -q 2372b6b6c63e71c7eb43e34ef655c8f5c4f1620b
         fi
         default_min=120 ;;
  bulk)  [ -n "$FS_IN" ] && [ -n "$FS_OUT" ] || { echo "bulk needs --in and --out"; exit 2; }
         default_min="$FS_MAXWALL_MIN"
         # As many one-node shards as the per-user GPU, running-job and submit limits all allow.
         cap=$(( FS_MAXGPU_PU / FS_GPUS )); [ "$FS_MAXJOBS_PU" -lt "$cap" ] && cap="$FS_MAXJOBS_PU"
         [ "$FS_MAXSUBMIT_PU" -lt "$cap" ] && cap="$FS_MAXSUBMIT_PU"
         FS_SHARDS="${FS_SHARDS:-$cap}" ;;
  *) echo "mode must be truth, seg, news, news-layout or bulk"; exit 2 ;;
esac
want=$(awk -v h="${hours:-0}" 'BEGIN { printf "%d", h * 60 }'); [ "$want" -gt 0 ] || want="$default_min"
FS_WALL_MIN=$(( want < FS_MAXWALL_MIN ? want : FS_MAXWALL_MIN ))

FS_SBATCH_ARGS="--partition=$FS_PARTITION ${FS_QOS:+--qos=$FS_QOS} --gres=gpu:$FS_GPUS --cpus-per-task=$(( 8 * FS_GPUS )) \
--mem=$(( 48 * FS_GPUS + 32 ))G --time=$FS_WALL_MIN --job-name=fs-ocr-$FS_MODE --output=$FS_ROOT/logs/%x-%j.out"
array=""; [ "$FS_MODE" = bulk ] && array="--array=0-$(( FS_SHARDS - 1 ))"
export FS_DIR FS_MODE FS_PRESET_NAME FS_WALL_MIN FS_PACK FS_IN FS_OUT FS_SHARDS FS_SBATCH_ARGS FS_CHAIN=0
echo "sbatch --export=ALL $FS_SBATCH_ARGS $array job.sbatch   ($FS_MODEL, $FS_GPUS GPU, ${FS_WALL_MIN} min)"
[ -n "$dry" ] && exit 0
# shellcheck disable=SC2086
sbatch --export=ALL $FS_SBATCH_ARGS $array job.sbatch
