#!/bin/bash
# W46.ocr-regions: one Slurm job, either the DocLayout-YOLO pass or one route reading one shard of its crops.
#   sbatch ... regions-job.sh ROOT detect
#   sbatch ... regions-job.sh ROOT read ROUTE SHARD [LIMIT]   (SHARD i/n; LIMIT > 0 is the pilot)
# ROOT holds pages.jsonl, routes.json, regions/ and regions_cluster.py. The server is the open sweep's (the same
# start-up, health wait and snapshot fallback as loop-rerun-job.sh), with the route's recorded vLLM arguments.
set -euo pipefail
ROOT="$1"; MODE="$2"
# FarmShare's env by default; Sherlock's sherlock/sh.env sets FS_ENV (and FS_CONTAINER: vLLM runs in its image).
source "${FS_ENV:-/home/users/cp1/Archive-Suite/ArchiveProcessor/scripts/segbench/farmshare/fs.env}"
export HF_HOME HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
mkdir -p "$ROOT/logs"
if [ "$MODE" = detect ]; then
  exec "$FS_ROOT/npo-venv/bin/python" "$ROOT/regions_cluster.py" detect-yolo --root "$ROOT"
fi
ROUTE="$3"; SHARD="$4"; LIMIT="${5:-0}"
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
if [ -z "${FS_CONTAINER:-}" ]; then   # the image carries its own CUDA toolkit
  CUDA=$("$FS_PY" -c 'import nvidia,os;print(os.path.join(list(nvidia.__path__)[0],"cu13"))')
  export CUDA_HOME="$CUDA" PATH="$CUDA/bin:$PATH"
  export FLASHINFER_EXTRA_LDFLAGS="-L$CUDA/lib -L$FS_ROOT/cuda-link"
fi
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
"$FS_PY" "$ROOT/regions_cluster.py" read --root "$ROOT" --route "$ROUTE" --shard "$SHARD" --limit "$LIMIT"
