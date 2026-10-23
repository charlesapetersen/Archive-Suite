#!/bin/bash
# W46.ocr-postcorrect on Sherlock: Qwen3.6-27B FP8 corrects postcorrect.py's pack, image-grounded and text-only.
#   sbatch ... postcorrect-job.sh SH_DIR ROOT [LIMIT]     (LIMIT > 0 is the pilot)
# The server is started with the vLLM arguments the regions run recorded for this route (regions-20261021/routes.json),
# so the corrector is the same Qwen3.6-27B the bench's readers were.
set -euo pipefail
SH_DIR="$1"; ROOT="$2"; LIMIT="${3:-0}"; source "$SH_DIR/sh.env"
export HF_HOME HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
R="$FS_ROOT/regions-20261021/routes.json"
get() { "$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["qwen3.6-27b"][sys.argv[2]])' "$R" "$1"; }
MODEL=$(get model); ARGS=$(get vllm_args)
export FS_SERVED=qwen3.6-27b PORT=$((16000 + SLURM_JOB_ID % 10000)); export FS_URL="http://127.0.0.1:$PORT"
mkdir -p "$ROOT/logs"; LOG="$ROOT/logs/vllm-$SLURM_JOB_ID.log"
# shellcheck disable=SC2086  # ARGS is the recorded word list
"$FS_VLLM" serve "$MODEL" --served-model-name "$FS_SERVED" --host 127.0.0.1 --port "$PORT" $ARGS > "$LOG" 2>&1 &
server=$!; trap 'kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true' EXIT
for _ in $(seq 1 360); do
  curl -sf "$FS_URL/health" >/dev/null && break
  kill -0 "$server" 2>/dev/null || { tail -60 "$LOG"; exit 1; }
  sleep 5
done
curl -sf "$FS_URL/health" >/dev/null || { tail -60 "$LOG"; exit 1; }
"$FS_PY" "$SH_DIR/../postcorrect_cluster.py" --root "$ROOT" --limit "$LIMIT"
