#!/bin/bash
# Isolated multi-GPU extension; pending single-GPU jobs retain their frozen wrapper.
set -euo pipefail
ROOT="$1"
KEY="$2"
source /home/users/cp1/Archive-Suite/ArchiveProcessor/scripts/segbench/farmshare/fs.env
export HF_HOME HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
export SESSION_ROOT="$ROOT/$KEY"
PREPARED="$SESSION_ROOT/prepared.json"
if ! "$FS_PY" -c 'import json,sys;sys.exit(json.load(open(sys.argv[1]))["state"] != "ready")' "$PREPARED"; then
  echo "Preparation unavailable/skipped for $KEY; inspect prepared.json and setup log."
  exit 2
fi
SNAPSHOT=$("$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["snapshot"])' "$PREPARED")
mapfile -t ARGS < <("$FS_PY" -c 'import json,sys;print("\n".join(json.load(open(sys.argv[1]))["server_args"]))' "$PREPARED")
export FS_MODEL="$SNAPSHOT" FS_SERVED="$KEY" FS_VLLM_ARGS="${ARGS[*]}"
PORT=$((16000 + SLURM_JOB_ID % 10000))
export FS_URL="http://127.0.0.1:$PORT"
CUDA=$("$FS_PY" -c 'import nvidia,os;print(os.path.join(list(nvidia.__path__)[0],"cu13"))')
export CUDA_HOME="$CUDA" PATH="$CUDA/bin:$PATH"
export FLASHINFER_EXTRA_LDFLAGS="-L$CUDA/lib -L$FS_ROOT/cuda-link"
SERVER_LOG="$SESSION_ROOT/logs/vllm-${SLURM_JOB_ID}-${KEY}.log"
"$FS_VLLM" serve "$SNAPSHOT" --served-model-name "$KEY" --host 127.0.0.1 --port "$PORT" "${ARGS[@]}" > "$SERVER_LOG" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true' EXIT
for i in $(seq 1 240); do
  curl -sf "$FS_URL/health" >/dev/null && break
  kill -0 "$server" 2>/dev/null || { tail -60 "$SERVER_LOG"; exit 1; }
  sleep 5
done
curl -sf "$FS_URL/health" >/dev/null || { tail -60 "$SERVER_LOG"; exit 1; }
"$FS_PY" "$ROOT/recovery/open_sweep_run.py"
