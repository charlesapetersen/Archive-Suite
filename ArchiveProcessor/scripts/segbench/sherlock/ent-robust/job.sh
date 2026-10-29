#!/bin/bash
# W46.ent-robust on one GPU: serve Qwen3.6-27B-FP8 as the bench's readers were served (seg-context/job.sh's flags,
# images allowed for the G17 letters), send each arm's 8-request pilot, and only if at least 6 of the 8 stop
# cleanly, every request, through postcorrect_cluster.py (temperature 0, thinking off).
#   sbatch ... job.sh ROOT
# Arms: ent/ (the page entity prompt on 2,066 truth and OCR texts) and g17/ (Business Letters, 57 letters).
set -euo pipefail
ROOT="$1"
: "${SLURM_JOB_ID:?must run as a Slurm job}"
: "${FS_ENV:?source sh.env before submission}"
source "$FS_ENV"
export HF_HOME HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
cache="$HF_HOME/hub/models--Qwen--Qwen3.6-27B-FP8"
if [ -f "$cache/refs/main" ]; then MODEL="$cache/snapshots/$(cat "$cache/refs/main")"
else snaps=("$cache"/snapshots/*); [ "${#snaps[@]}" -eq 1 ] || { echo 'ambiguous snapshot'; exit 2; }; MODEL="${snaps[0]}"; fi
[ -f "$MODEL/config.json" ] || { echo "model incomplete: $MODEL"; exit 2; }
VLLM_ARGS=(--tensor-parallel-size 1 --max-model-len 20480 --kv-cache-dtype fp8 --gpu-memory-utilization 0.92
           --max-num-seqs 32 --limit-mm-per-prompt '{"image":7}')
SAVED="$GROUP_HOME/$USER/archive-suite/sherlock-results/ent-robust-20261029"
mkdir -p "$ROOT/logs" "$ROOT/runtime"
"$FS_PY" "$ROOT/support/check_pack.py" "$ROOT"
export FS_SERVED=qwen3.6-27b PORT=$((16000 + SLURM_JOB_ID % 10000)); export FS_URL="http://127.0.0.1:$PORT"
LOG="$ROOT/logs/vllm-$SLURM_JOB_ID.log"
"$FS_PY" - "$MODEL" "$ROOT/runtime/$SLURM_JOB_ID.json" <<'PY'
import importlib.metadata as m, json, os, sys
json.dump({"model": sys.argv[1], "gpu": os.popen("nvidia-smi --query-gpu=name --format=csv,noheader").read().strip(),
           "job": os.environ["SLURM_JOB_ID"], "vllm": m.version("vllm"), "transformers": m.version("transformers")},
          open(sys.argv[2], "x"), indent=1)
PY
"$FS_VLLM" serve "$MODEL" --served-model-name "$FS_SERVED" --host 127.0.0.1 --port "$PORT" "${VLLM_ARGS[@]}" \
  > "$LOG" 2>&1 &
server=$!
finish() {
  rc=$?; trap - EXIT
  kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true
  # Answers leave purged scratch at once.
  for arm in ent g17; do [ ! -d "$ROOT/$arm/out" ] || { mkdir -p "$SAVED/$arm"; rsync -a "$ROOT/$arm/out" "$SAVED/$arm/"; }; done
  mkdir -p "$SAVED/runtime" "$SAVED/logs"; rsync -a "$ROOT/runtime/" "$SAVED/runtime/"; cp "$LOG" "$SAVED/logs/" || true
  exit "$rc"
}
trap finish EXIT
for _ in $(seq 360); do   # weights load and CUDA graph capture: up to 30 minutes
  curl -sf "$FS_URL/health" > /dev/null && break
  kill -0 "$server" 2>/dev/null || { echo 'vLLM exited during start-up:'; tail -50 "$LOG"; exit 1; }
  sleep 5
done
curl -sf "$FS_URL/health" > /dev/null || { echo 'vLLM not healthy after 30 minutes'; tail -50 "$LOG"; exit 1; }
PC="$ROOT/support/postcorrect_cluster.py"
pilot_ok() {
  "$FS_PY" - "$1" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
ids = [json.loads(l)["id"] for l in (root / "requests.jsonl").read_text().splitlines()[:8]]
ok = sum((root / "out" / f"{i}.json").exists() and json.loads((root / "out" / f"{i}.json").read_text()).get("finish") == "stop"
         for i in ids)
print(f"{root.name} pilot: {ok} of {len(ids)} stopped cleanly")
sys.exit(0 if ok >= 6 else 1)
PY
}
# The arms are independent: a failed pilot or run in one does not stop the other; the job fails if either did.
failed=0
for arm in ent g17; do
  "$FS_PY" "$PC" --root "$ROOT/$arm" --limit 8 || true
  if pilot_ok "$ROOT/$arm"; then "$FS_PY" "$PC" --root "$ROOT/$arm" --concurrency 32 || failed=1; else failed=1; fi
done
exit "$failed"
