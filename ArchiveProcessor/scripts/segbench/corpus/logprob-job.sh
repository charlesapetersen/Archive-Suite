#!/bin/bash
# W46.ocr-logprob: one route reads the 895 and the 96's pack again with log-probabilities on.
#   sbatch ... logprob-job.sh ROOT ROUTE     (ROOT holds routes.json, pages/{pilot3,public895,truth99}.jsonl, the script)
# The server is loop-rerun-job.sh's (the open sweep's start-up and health wait, the route's recorded vLLM
# arguments). A three-page pilot goes first and must return one log-probability per completion token
# (logprob_cluster.py --check), so a server that drops them costs minutes, not the whole run.
set -euo pipefail
ROOT="$1"; ROUTE="$2"
# FarmShare's env by default; Sherlock's sherlock/sh.env sets FS_ENV (and FS_CONTAINER: vLLM runs in its image).
source "${FS_ENV:-/home/users/cp1/Archive-Suite/ArchiveProcessor/scripts/segbench/farmshare/fs.env}"
export HF_HOME HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
get() { "$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]])' "$ROOT/routes.json" "$ROUTE" "$1"; }
MODEL=$(get model); NAME=$(get served); ARGS=$(get vllm_args); PROMPT=$(get prompt); CONC=$(get concurrency)
# As loop-rerun-job.sh: offline, a repo with no refs/main and a single snapshot is served from that directory.
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
mkdir -p "$ROOT/logs" "$ROOT/out/$ROUTE"
SERVER_LOG="$ROOT/logs/vllm-${SLURM_JOB_ID}-${ROUTE}.log"
# shellcheck disable=SC2086  # ARGS is the recorded word list
"$FS_VLLM" serve "$MODEL" --served-model-name "$NAME" --host 127.0.0.1 --port "$PORT" $ARGS \
  > "$SERVER_LOG" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true' EXIT
for i in $(seq 1 360); do
  curl -sf "$FS_URL/health" >/dev/null && break
  kill -0 "$server" 2>/dev/null || { tail -60 "$SERVER_LOG"; exit 1; }
  sleep 5
done
curl -sf "$FS_URL/health" >/dev/null || { tail -60 "$SERVER_LOG"; exit 1; }
run() { "$FS_PY" "$ROOT/logprob_cluster.py" --pages "$ROOT/pages/$1.jsonl" --prompt "$PROMPT" --out "$ROOT/out/$ROUTE/$1" \
  --concurrency "$CONC" "${@:2}"; }
run pilot3 --check
run truth99 --check
run public895 --check
