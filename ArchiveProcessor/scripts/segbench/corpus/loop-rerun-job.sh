#!/bin/bash
# W46.ocr-loops: one route, one arm, on that route's capped pages from the open sweep.
#   sbatch ... loop-rerun-job.sh ROOT ROUTE ARM      (ROOT holds routes.json, caps/<route>.jsonl, the two scripts)
# The server is the open sweep's (serve.sh's start-up and health wait) with the route's own recorded vLLM
# arguments, plus vLLM's built-in n-gram logits processor, which only a request naming ngram_size switches on.
set -euo pipefail
ROOT="$1"; ROUTE="$2"; ARM="$3"
# FarmShare's env by default; Sherlock's sherlock/sh.env sets FS_ENV (and FS_CONTAINER: vLLM runs in its image).
source "${FS_ENV:-/home/users/cp1/Archive-Suite/ArchiveProcessor/scripts/segbench/farmshare/fs.env}"
export HF_HOME HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
get() { "$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]])' "$ROOT/routes.json" "$ROUTE" "$1"; }
MODEL=$(get model); NAME=$(get served); ARGS=$(get vllm_args); PROMPT=$(get prompt); CONC=$(get concurrency)
# Offline, a repo id resolves only through refs/main, and some cached repos have none (LightOnOCR-3, PaddleOCR-VL
# 1.5: the first pilot, 1863313, died on it). With no ref and a single snapshot, serve that snapshot's directory.
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
# The n-gram processor is a V1 logits processor; vLLM 0.31 defaults to Model Runner V2, which refuses it at
# start-up (the second pilot, 1863911). Only the ngram arm loads it, on the V1 runner; the half arm keeps the
# sweep's own runner and loads no processor.
LP=()
if [ "$ARM" = ngram ]; then
  export VLLM_USE_V2_MODEL_RUNNER=0
  LP=(--logits-processors vllm.model_executor.models.deepseek_ocr:NGramPerReqLogitsProcessor)
fi
mkdir -p "$ROOT/logs" "$ROOT/out/$ROUTE"
SERVER_LOG="$ROOT/logs/vllm-${SLURM_JOB_ID}-${ROUTE}-${ARM}.log"
# shellcheck disable=SC2086  # ARGS is the recorded word list
"$FS_VLLM" serve "$MODEL" --served-model-name "$NAME" --host 127.0.0.1 --port "$PORT" $ARGS \
  "${LP[@]}" > "$SERVER_LOG" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true' EXIT
for i in $(seq 1 360); do
  curl -sf "$FS_URL/health" >/dev/null && break
  kill -0 "$server" 2>/dev/null || { tail -60 "$SERVER_LOG"; exit 1; }
  sleep 5
done
curl -sf "$FS_URL/health" >/dev/null || { tail -60 "$SERVER_LOG"; exit 1; }
"$FS_PY" "$ROOT/loop_rerun_cluster.py" --caps "$ROOT/caps/$ROUTE.jsonl" --prompt "$PROMPT" --arm "$ARM" \
  --out "$ROOT/out/$ROUTE/$ARM" --concurrency "$CONC"
