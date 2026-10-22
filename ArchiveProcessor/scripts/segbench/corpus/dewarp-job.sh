#!/bin/bash
# W46.enh-dewarp: one Slurm job, one reader on one shard of the dewarp test's images.
#   sbatch ... dewarp-job.sh ROOT ROUTE SHARD [LIMIT]   (ROUTE qwen3.6-27b | lightonocr3-4b | ppocrv6; SHARD i/n)
# The vLLM routes start their server exactly as regions-job.sh does (the open sweep's start-up, health wait and
# snapshot fallback, the route's recorded arguments); PP-OCRv6 runs in the 895-page sweep's venv with truth96's
# pinned weights, as truth96's own ppocrv6_job.sh did. ROOT holds pages.jsonl, routes.json and the two .py files.
set -euo pipefail
ROOT="$1"; ROUTE="$2"; SHARD="$3"; LIMIT="${4:-0}"
mkdir -p "$ROOT/logs"
if [ "$ROUTE" = ppocrv6 ]; then
  sweep=/scratch/users/cp1/fs-ocr/ppocrv6-20261019
  export HF_HOME="$sweep/hf" PADDLE_PDX_CACHE_HOME="$ROOT/paddlex-cache" PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True
  export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-8}"
  exec "$sweep/venv/bin/python" "$ROOT/dewarp_cluster.py" ppocr --root "$ROOT" --shard "$SHARD" --limit "$LIMIT"
fi
source /home/users/cp1/Archive-Suite/ArchiveProcessor/scripts/segbench/farmshare/fs.env
export HF_HOME HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
get() { "$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]])' "$ROOT/routes.json" "$ROUTE" "$1"; }
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
SERVER_LOG="$ROOT/logs/vllm-${SLURM_JOB_ID}-${ROUTE}.log"
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
"$FS_PY" "$ROOT/dewarp_cluster.py" read --root "$ROOT" --route "$ROUTE" --shard "$SHARD" --limit "$LIMIT"
