#!/bin/bash
# W46.ocr-loops: one route, one arm, on that route's capped pages from the open sweep.
#   sbatch ... loop-rerun-job.sh ROOT ROUTE ARM      (ROOT holds routes.json, caps/<route>.jsonl, the two scripts)
# The server is the open sweep's (serve.sh's start-up and health wait) with the route's own recorded vLLM
# arguments, plus vLLM's built-in n-gram logits processor, which only a request naming ngram_size switches on.
set -euo pipefail
ROOT="$1"; ROUTE="$2"; ARM="$3"
source /home/users/cp1/Archive-Suite/ArchiveProcessor/scripts/segbench/farmshare/fs.env
export HF_HOME HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
get() { "$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]])' "$ROOT/routes.json" "$ROUTE" "$1"; }
MODEL=$(get model); NAME=$(get served); ARGS=$(get vllm_args); PROMPT=$(get prompt); CONC=$(get concurrency)
export FS_MODEL="$MODEL" FS_SERVED="$NAME"
PORT=$((16000 + SLURM_JOB_ID % 10000)); export FS_URL="http://127.0.0.1:$PORT"
CUDA=$("$FS_PY" -c 'import nvidia,os;print(os.path.join(list(nvidia.__path__)[0],"cu13"))')
export CUDA_HOME="$CUDA" PATH="$CUDA/bin:$PATH"
export FLASHINFER_EXTRA_LDFLAGS="-L$CUDA/lib -L$FS_ROOT/cuda-link"
mkdir -p "$ROOT/logs" "$ROOT/out/$ROUTE"
SERVER_LOG="$ROOT/logs/vllm-${SLURM_JOB_ID}-${ROUTE}-${ARM}.log"
# shellcheck disable=SC2086  # ARGS is the recorded word list
"$FS_VLLM" serve "$MODEL" --served-model-name "$NAME" --host 127.0.0.1 --port "$PORT" $ARGS \
  --logits-processors vllm.model_executor.models.deepseek_ocr:NGramPerReqLogitsProcessor > "$SERVER_LOG" 2>&1 &
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
