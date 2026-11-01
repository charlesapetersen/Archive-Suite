#!/bin/bash
# W46.kit-gate-sherlock, one model on one GPU: serve it as every FarmShare row was served (7 images a prompt, 20,480
# tokens, fp8 KV), a 4-window pilot, and only if at least 3 of the 4 parse, the role's whole pack (checkpack windows
# and the three locked boxes) through cluster_seg.py run (seg-window-modality/job.sh, one part).
#   sbatch ... job.sh ROOT teacher|2b|4b
set -euo pipefail
ROOT="$1"; ROLE="$2"
: "${SLURM_JOB_ID:?must run as a Slurm job}"
: "${FS_ENV:?source sh.env before submission}"
source "$FS_ENV"
export HF_HOME HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false SEGBENCH_CACHE="$ROOT/segbench-cache"
case "$ROLE" in
  teacher) KEY=fs-qwen3.5-27b; SERVED=Qwen/Qwen3.5-27B-FP8
           cache="$HF_HOME/hub/models--Qwen--Qwen3.5-27B-FP8"
           if [ -f "$cache/refs/main" ]; then MODEL="$cache/snapshots/$(cat "$cache/refs/main")"
           else snaps=("$cache"/snapshots/*); [ "${#snaps[@]}" -eq 1 ] || { echo 'ambiguous teacher snapshot'; exit 2; }
                MODEL="${snaps[0]}"; fi ;;
  2b) KEY=fs-seg-2b; SERVED=seg-2b; MODEL="$ROOT/seg-2b-merged" ;;
  4b) KEY=fs-seg-4b; SERVED=seg-4b; MODEL="$ROOT/seg-4b-merged" ;;
  *) echo "unknown role $ROLE"; exit 2 ;;
esac
[ -f "$MODEL/config.json" ] || { echo "model incomplete: $MODEL"; exit 2; }
VLLM_ARGS=(--tensor-parallel-size 1 --max-model-len 20480 --kv-cache-dtype fp8 --gpu-memory-utilization 0.92
           --max-num-seqs 32 --limit-mm-per-prompt '{"image":7}')
export IC_SEG_KEY="$KEY" IC_MODEL="$MODEL" IC_VLLM_ARGS="${VLLM_ARGS[*]}"
SAVED="$GROUP_HOME/$USER/archive-suite/sherlock-results/kit-gate-sherlock-20261031"
mkdir -p "$ROOT/logs" "$ROOT/runs" "$ROOT/runtime"
"$FS_PY" "$ROOT/support/segbench/kit_gate_sherlock.py" check --root "$ROOT"
PORT=$((16000 + SLURM_JOB_ID % 10000)); URL="http://127.0.0.1:$PORT"
LOG="$ROOT/logs/vllm-$ROLE-$SLURM_JOB_ID.log"
"$FS_PY" - "$MODEL" "$ROOT/runtime/$ROLE-$SLURM_JOB_ID.json" "${VLLM_ARGS[*]}" <<'PY'
import importlib.metadata as m, json, os, sys
# The teacher's snapshot hash is the path's last part: the only record of which weights were read.
json.dump({"model": sys.argv[1], "vllm_args": sys.argv[3],
           "gpu": os.popen("nvidia-smi --query-gpu=name --format=csv,noheader").read().strip(),
           "job": os.environ["SLURM_JOB_ID"], "vllm": m.version("vllm"), "transformers": m.version("transformers")},
          open(sys.argv[2], "x"), indent=1)
PY
"$FS_VLLM" serve "$MODEL" --served-model-name "$SERVED" --host 127.0.0.1 --port "$PORT" "${VLLM_ARGS[@]}" \
  > "$LOG" 2>&1 &
server=$!
finish() {
  rc=$?; trap - EXIT
  kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true
  # Answers and evidence leave purged scratch at once; each role owns its folders, so the jobs never collide.
  mkdir -p "$SAVED/runs" "$SAVED/runtime" "$SAVED/logs"
  for d in "$ROOT/runs/$ROLE" "$ROOT/runs/$ROLE-pilot"; do [ ! -d "$d" ] || rsync -a "$d" "$SAVED/runs/"; done
  rsync -a "$ROOT/runtime/" "$SAVED/runtime/"; cp "$LOG" "$SAVED/logs/" || true
  exit "$rc"
}
trap finish EXIT
for _ in $(seq 360); do   # weights load and CUDA graph capture: up to 30 minutes, as job.sbatch allows
  curl -sf "$URL/health" > /dev/null && break
  kill -0 "$server" 2>/dev/null || { echo 'vLLM exited during start-up:'; tail -50 "$LOG"; exit 1; }
  sleep 5
done
curl -sf "$URL/health" > /dev/null || { echo 'vLLM not healthy after 30 minutes'; tail -50 "$LOG"; exit 1; }
CS="$ROOT/support/segbench/cluster_seg.py"
"$FS_PY" "$CS" run --pack "$ROOT/$ROLE" --out "$ROOT/runs" --label "$ROLE-pilot" --model "$SERVED" \
  --url "$URL" --limit 4 --warmup
"$FS_PY" - "$ROOT/runs/$ROLE-pilot/answers.jsonl" <<'PY'
import json, sys
ok = sum(json.loads(l).get("status") == "ok" for l in open(sys.argv[1]) if l.strip())
print(f"pilot: {ok} of 4 windows parsed")
sys.exit(0 if ok >= 3 else 1)
PY
"$FS_PY" "$CS" run --pack "$ROOT/$ROLE" --out "$ROOT/runs" --label "$ROLE" --model "$SERVED" \
  --url "$URL" --concurrency 16 --gpus 1
