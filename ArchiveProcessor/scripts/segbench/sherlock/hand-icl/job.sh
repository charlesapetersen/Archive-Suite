#!/bin/bash
set -euo pipefail
SOURCE="$1"; ROOT="$2"
: "${SLURM_JOB_ID:?must run in a Slurm allocation}"
: "${L_SCRATCH_JOB:?node-local scratch required}"
JOB="$SOURCE/support/job"
source "$JOB/sh.env"
export HF_HOME HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
export OMP_NUM_THREADS="$SLURM_CPUS_PER_TASK" VLLM_WORKER_MULTIPROC_METHOD=spawn
LOCAL="$L_SCRATCH_JOB/hand-icl"
SAVED="$GROUP_HOME/$USER/archive-suite/sherlock-results/hand-icl-20261101"
df -h "$L_SCRATCH_JOB"
mkdir -p "$LOCAL" "$ROOT/runtime" "$SAVED"
rsync -a "$SOURCE/" "$LOCAL/"
"$FS_PY" "$LOCAL/support/hand_icl.py" check --root "$LOCAL"
REV=$("$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["revision"])' "$LOCAL/freeze.json")
MODEL="$HF_HOME/hub/models--Qwen--Qwen3.6-27B-FP8/snapshots/$REV"
[[ -s "$MODEL/config.json" ]] || { echo "missing reviewed snapshot $REV"; exit 2; }
PORT=$((18000 + SLURM_JOB_ID % 10000)); URL="http://127.0.0.1:$PORT"
server=''
finish() {
  rc=$?; trap - EXIT
  if [[ -n "$server" ]]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi
  if [[ -d "$LOCAL/results" ]]; then
    mkdir -p "$ROOT/results" "$SAVED/results"
    rsync -a "$LOCAL/results/" "$ROOT/results/"
    rsync -a "$LOCAL/results/" "$SAVED/results/"
  fi
  rsync -a "$ROOT/runtime/" "$SAVED/runtime/" || true
  rsync -a "$ROOT/logs/" "$SAVED/logs/" || true
  cp "$SOURCE/freeze.json" "$SAVED/freeze.json" || true
  exit "$rc"
}
trap finish EXIT
"$FS_PY" - "$ROOT/runtime/$SLURM_JOB_ID.json" "$REV" <<'PY'
import json, os, subprocess, sys, importlib.metadata as m
json.dump(dict(job=os.environ['SLURM_JOB_ID'], revision=sys.argv[2],
               vllm=m.version('vllm'), transformers=m.version('transformers'),
               gpu=subprocess.check_output(['nvidia-smi','--query-gpu=name','--format=csv,noheader'],text=True).strip(),
               context=32768, image_limit=17, max_num_seqs=1, enforce_eager=True),open(sys.argv[1],'x'),indent=1)
PY
"$FS_VLLM" serve "$MODEL" --served-model-name hand-icl-qwen --host 127.0.0.1 --port "$PORT" \
  --tensor-parallel-size 1 --max-model-len 32768 --max-num-seqs 1 --gpu-memory-utilization 0.88 \
  --kv-cache-dtype fp8 --enforce-eager --limit-mm-per-prompt '{"image":17}' \
  > "$ROOT/logs/vllm-$SLURM_JOB_ID.log" 2>&1 &
server=$!
for _ in $(seq 180); do
  curl -sf "$URL/health" > /dev/null && break
  kill -0 "$server" 2>/dev/null || { tail -40 "$ROOT/logs/vllm-$SLURM_JOB_ID.log"; exit 2; }
  sleep 5
done
curl -sf "$URL/health" > /dev/null || { echo 'model startup exceeded 15 minutes'; exit 2; }
"$FS_PY" "$LOCAL/support/hand_icl.py" run --root "$LOCAL" --url "$URL" --budget-seconds 3600
