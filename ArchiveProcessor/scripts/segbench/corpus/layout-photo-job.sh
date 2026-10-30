#!/bin/bash
# W46.layout-photo: GLM-OCR on one shard of the pack's crops (every arm each page names).
#   sbatch ... layout-photo-job.sh ROOT SHARD [LIMIT]     (SHARD i/n; LIMIT > 0 is the pilot)
# The server start-up and health wait are W46.ocr-regions' (regions-job.sh), with the route's recorded vLLM
# arguments; the request is regions_cluster.py's, through layout_photo_cluster.py. Receipts are copied to
# $GROUP_HOME/$USER/archive-suite/sherlock-results/<pack>/ when the job ends, success or not.
set -euo pipefail
ROOT="$1"; SHARD="$2"; LIMIT="${3:-0}"; ROUTE=glm-ocr
: "${SLURM_JOB_ID:?must run as a Slurm job}"
: "${FS_ENV:?source sherlock/sh.env before submission}"
source "$FS_ENV"
export HF_HOME HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
mkdir -p "$ROOT/logs"
"$FS_PY" "$ROOT/layout_photo_cluster.py" check --root "$ROOT" --strict
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
SERVER_LOG="$ROOT/logs/vllm-${SLURM_JOB_ID}-${ROUTE}.log"
# shellcheck disable=SC2086  # ARGS is the recorded word list
"$FS_VLLM" serve "$MODEL" --served-model-name "$NAME" --host 127.0.0.1 --port "$PORT" $ARGS > "$SERVER_LOG" 2>&1 &
server=$!
finish() {
  rc=$?; trap - EXIT
  kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true
  saved="$GROUP_HOME/$USER/archive-suite/sherlock-results/$(basename "$ROOT")"
  mkdir -p "$saved/out" "$saved/logs"
  if [ -d "$ROOT/out" ]; then rsync -a "$ROOT/out/" "$saved/out/"; fi
  cp "$SERVER_LOG" "$saved/logs/" 2>/dev/null || true
  exit "$rc"
}
trap finish EXIT
for i in $(seq 1 360); do
  curl -sf "$FS_URL/health" >/dev/null && break
  kill -0 "$server" 2>/dev/null || { tail -60 "$SERVER_LOG"; exit 1; }
  sleep 5
done
curl -sf "$FS_URL/health" >/dev/null || { tail -60 "$SERVER_LOG"; exit 1; }
"$FS_PY" "$ROOT/layout_photo_cluster.py" read --root "$ROOT" --route "$ROUTE" --shard "$SHARD" --limit "$LIMIT"
