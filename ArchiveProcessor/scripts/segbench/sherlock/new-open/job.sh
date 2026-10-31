#!/bin/bash
# W46.ocr-new-open on Sherlock: one model on one set, as the open sweep and truth96 ran it.
#   sbatch ... job.sh SH_DIR SET KEY      (SET 895 | 96)
# serve.sh's start-up with its fixed server arguments, plus the candidate's own `vllm_extra` (e.g. --trust-remote-code),
# which the runner records in the settings contract. The 96 run first takes the 895 run's cache-contract.json as its
# sweep-contract.json, so truth96's runner refuses any difference in settings. A candidate's `gpus` (default 1) is the
# tensor-parallel size. With NEW_OPEN_RESULTS set (the submitting script exports it), the finished session folder is
# copied there under SET/, so the batch's collect finds it in $GROUP_HOME.
set -euo pipefail
SH_DIR="$1"; SET="$2"; KEY="$3"; source "$SH_DIR/sh.env"
ROOT="$FS_ROOT/new-open-$SET"; export SESSION_ROOT="$ROOT/$KEY"
export HF_HOME HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
P="$SESSION_ROOT/prepared.json"
"$FS_PY" -c 'import json,sys;sys.exit(json.load(open(sys.argv[1]))["state"] != "ready")' "$P" || { echo "$KEY not ready"; exit 2; }
if [ "$SET" = 96 ]; then
  C="$FS_ROOT/new-open-895/$KEY/cache-contract.json"
  [ -s "$C" ] || { echo "no 895 contract for $KEY"; exit 2; }
  cp "$C" "$SESSION_ROOT/sweep-contract.json"
fi
SNAP=$("$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["snapshot"])' "$P")
EXTRA=$("$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("vllm_extra",""))' "$P")
TP=$("$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("gpus",1))' "$P")
export FS_MODEL="$SNAP" FS_SERVED="$KEY"
PORT=$((16000 + SLURM_JOB_ID % 10000)); export FS_URL="http://127.0.0.1:$PORT"
export FS_VLLM_ARGS="--tensor-parallel-size $TP --max-model-len 16384 --kv-cache-dtype auto --gpu-memory-utilization 0.90 --max-num-seqs 16${EXTRA:+ $EXTRA}"
LOG="$SESSION_ROOT/logs/vllm-$SLURM_JOB_ID-$KEY.log"
# shellcheck disable=SC2086  # FS_VLLM_ARGS is a word list
"$FS_VLLM" serve "$SNAP" --served-model-name "$KEY" --host 127.0.0.1 --port "$PORT" $FS_VLLM_ARGS > "$LOG" 2>&1 &
server=$!; trap 'kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true' EXIT
for _ in $(seq 1 360); do
  curl -sf "$FS_URL/health" >/dev/null && break
  kill -0 "$server" 2>/dev/null || { tail -60 "$LOG"; exit 1; }
  sleep 5
done
curl -sf "$FS_URL/health" >/dev/null || { tail -60 "$LOG"; exit 1; }
"$FS_PY" "$ROOT/recovery/open_sweep_run.py"
# Best effort: the readings are complete in scratch, which the batch's collect also copies, so a failed copy must not
# fail the job (the 96 runs afterok the 895).
if [ -n "${NEW_OPEN_RESULTS:-}" ]; then
  { mkdir -p "$NEW_OPEN_RESULTS/$SET" && cp -r "$SESSION_ROOT" "$NEW_OPEN_RESULTS/$SET/"; } ||
    echo "results copy failed; the session is in $SESSION_ROOT" >&2
fi
