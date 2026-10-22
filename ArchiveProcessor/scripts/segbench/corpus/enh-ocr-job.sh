#!/bin/bash
# W46.enh-ocr-input: one Slurm job.
#   sbatch ... enh-ocr-job.sh ROOT enhance ARMS            (ARMS a comma list; GPU; then the three pages.jsonl)
#   sbatch ... enh-ocr-job.sh ROOT ppocr  - SHARD          (PP-OCRv6 on ROOT/pages.jsonl, truth96's pinned pipeline)
#   sbatch ... enh-ocr-job.sh ROOT whole  ROUTE SHARD SUB  (a vLLM route on SUB/pages.jsonl whole page; SUB . or probe)
#   sbatch ... enh-ocr-job.sh ROOT regions glm-ocr SHARD   (GLM-OCR on ROOT/glm, PP-DocLayoutV3's regions)
# The vLLM start-up is dewarp-job.sh's (the open sweep's health wait and snapshot fallback, the route's recorded
# arguments); the readers are dewarp_cluster.py and regions_cluster.py, unchanged.
set -euo pipefail
ROOT="$1"; KIND="$2"; ARG="${3:-}"; SHARD="${4:-0/1}"; SUB="${5:-.}"
mkdir -p "$ROOT/logs"
source /home/users/cp1/Archive-Suite/ArchiveProcessor/scripts/segbench/farmshare/fs.env
if [ "$KIND" = enhance ]; then
  exec "$FS_PY" "$ROOT/enh_ocr_cluster.py" enhance --root "$ROOT" --arms "$ARG"
fi
if [ "$KIND" = ppocr ]; then
  sweep=/scratch/users/cp1/fs-ocr/ppocrv6-20261019
  export HF_HOME="$sweep/hf" PADDLE_PDX_CACHE_HOME="$ROOT/paddlex-cache" PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True
  export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-8}"
  exec "$sweep/venv/bin/python" "$ROOT/dewarp_cluster.py" ppocr --root "$ROOT" --shard "$SHARD"
fi
export HF_HOME HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
RUN="$ROOT/$SUB"; [ "$KIND" = regions ] && RUN="$ROOT/glm"
get() { "$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]])' "$RUN/routes.json" "$ARG" "$1"; }
MODEL=$(get model); NAME=$(get served); ARGS=$(get vllm_args)
cache="$HF_HOME/hub/models--${MODEL//\//--}"
if [ ! -d "$MODEL" ] && [ ! -f "$cache/refs/main" ]; then
  snaps=("$cache"/snapshots/*)
  [ "${#snaps[@]}" -eq 1 ] && [ -f "${snaps[0]}/config.json" ] || { echo "no usable snapshot for $MODEL"; exit 1; }
  MODEL="${snaps[0]}"
fi
export FS_MODEL="$MODEL" FS_SERVED="$NAME"
PORT=$((16000 + SLURM_JOB_ID % 10000)); export FS_URL="http://127.0.0.1:$PORT"
CUDA=$("$FS_PY" -c 'import nvidia,os;print(os.path.join(list(nvidia.__path__)[0],"cu13"))')
export CUDA_HOME="$CUDA" PATH="$CUDA/bin:$PATH"
export FLASHINFER_EXTRA_LDFLAGS="-L$CUDA/lib -L$FS_ROOT/cuda-link"
SERVER_LOG="$ROOT/logs/vllm-${SLURM_JOB_ID}-${ARG}.log"
# shellcheck disable=SC2086  # ARGS is the recorded word list
"$FS_VLLM" serve "$MODEL" --served-model-name "$NAME" --host 127.0.0.1 --port "$PORT" $ARGS > "$SERVER_LOG" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true' EXIT
for i in $(seq 1 360); do
  curl -sf "$FS_URL/health" >/dev/null && break
  kill -0 "$server" 2>/dev/null || { tail -60 "$SERVER_LOG"; exit 1; }
  sleep 5
done
curl -sf "$FS_URL/health" >/dev/null || { tail -60 "$SERVER_LOG"; exit 1; }
if [ "$KIND" = regions ]; then
  "$FS_PY" "$ROOT/regions_cluster.py" read --root "$RUN" --route "$ARG" --arms pp-doclayoutv3 --shard "$SHARD" --concurrency 16
else
  "$FS_PY" "$ROOT/dewarp_cluster.py" read --root "$RUN" --route "$ARG" --shard "$SHARD" --concurrency 8
fi
