#!/bin/bash
set -euo pipefail
ROOT="$1"
KEY=inkling-small-gguf-q4
source /home/users/cp1/Archive-Suite/ArchiveProcessor/scripts/segbench/farmshare/fs.env
export SESSION_ROOT="$ROOT/$KEY" FS_SERVED="$KEY"
CUDA=$("$FS_PY" -c 'import nvidia,os;print(os.path.join(list(nvidia.__path__)[0],"cu13"))')
export LD_LIBRARY_PATH="$ROOT/build/bin:$CUDA/lib:$CUDA/lib64:$FS_ROOT/cuda-link:${LD_LIBRARY_PATH:-}"
PREPARED="$SESSION_ROOT/prepared.json"
"$FS_PY" -c 'import json,sys;assert json.load(open(sys.argv[1]))["state"]=="ready"' "$PREPARED"
mapfile -t CONFIG < <("$FS_PY" -c 'import json,sys;from pathlib import Path;c=json.load(open(sys.argv[1]));s=Path(c["snapshot"]);print(c["binary"]);print(s/c["files"][0]);print(s/c["projector"])' "$PREPARED")
PORT=$((16000 + SLURM_JOB_ID % 10000))
export FS_URL="http://127.0.0.1:$PORT"
ARGS=(-m "${CONFIG[1]}" --mmproj "${CONFIG[2]}" --alias "$KEY" --host 127.0.0.1 --port "$PORT"
  --n-gpu-layers 999 --split-mode layer --tensor-split 1,1,1,1 --ctx-size 16384 --parallel 1
  --n-predict 8192 --temp 0 --seed 0 --jinja --reasoning-budget 0 --fit on --fit-ctx 16384 --fit-target 1024)
export FS_VLLM_ARGS="${ARGS[*]}"
"${CONFIG[0]}" "${ARGS[@]}" > "$SESSION_ROOT/logs/llama-${SLURM_JOB_ID}.log" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true' EXIT
for i in $(seq 1 240); do
  curl -sf "$FS_URL/health" >/dev/null && break
  kill -0 "$server" 2>/dev/null || { tail -60 "$SESSION_ROOT/logs/llama-${SLURM_JOB_ID}.log"; exit 1; }
  sleep 5
done
curl -sf "$FS_URL/health" >/dev/null
"$FS_PY" "$ROOT/recovery/open_sweep_run.py"
