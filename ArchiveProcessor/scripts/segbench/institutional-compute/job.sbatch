#!/usr/bin/env bash
# W41.farmshare-plan — one GPU job: start vLLM on this node, run one cluster_ocr.py (or cluster_seg.py) mode against it, stop it.
# Submitted by submit.sh, which passes partition/QOS/GPUs/time fitted to limits.env; do not sbatch it by hand.
# Env from submit.sh: IC_DIR IC_MODE IC_PRESET_NAME IC_WALL_MIN [IC_PACK | IC_IN IC_OUT IC_SHARDS IC_CHAIN ...]
set -euo pipefail
cd "$IC_DIR"
# Slurm captured the exported setup/profile snapshot at submission. Never reread mutable compute.env here:
# another setup while this job waits must not change its cluster label, GPU budget or runtime paths.
: "${CLUSTER_NAME:?submit.sh must export the selected cluster}" "${IC_PY:?submit.sh must export its runtime}"
# Model, tensor parallel size and vLLM arguments were resolved and exported by submit.sh too.
: "${IC_MODEL:?missing submitted model}" "${IC_GPUS:?missing GPU count}" "${IC_VLLM_ARGS:?missing model arguments}"
server="" wave_note=""
# A wave stage (wave.py) records how it ended, for the score job; a pilot that fails cancels the rest of its chain.
on_exit() {
  local rc=$?
  [ -z "$server" ] || { kill "$server" 2>/dev/null; wait "$server" 2>/dev/null || true; }
  if [ -n "${IC_WAVE_DIR:-}" ]; then
    printf 'rc=%s job=%s %s\n' "$rc" "${SLURM_JOB_ID:-local}" "$wave_note" \
      > "$IC_WAVE_DIR/state/${IC_WAVE_STAGE}-${SLURM_ARRAY_TASK_ID:-0}" || true
    [ "$IC_WAVE_STAGE" != pilot ] || [ "$rc" -eq 0 ] || "$IC_PY" wave.py fail "$IC_WAVE_DIR" "pilot job exit $rc" || true
  fi
}
trap on_exit EXIT
trap 'exit 143' TERM   # Slurm's SIGTERM at the wall limit or scancel: still record the exit
source runtime.sh; source scheduler.sh
load_cluster_modules; configure_cluster_cuda
slurm_args
export HF_HOME HF_HUB_OFFLINE=1 IC_GPUS   # weights were fetched on the login node; compute nodes stay offline
start=$(date +%s)
port=$((8100 + ${SLURM_JOB_ID:-0} % 800))
log="$IC_ROOT/logs/vllm-${SLURM_JOB_ID:-local}.log"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv | tee "$IC_ROOT/logs/gpu-${SLURM_JOB_ID:-local}.csv"

# shellcheck disable=SC2086  # IC_VLLM_ARGS is a word list on purpose
"$IC_VLLM" serve "$IC_MODEL" --host 127.0.0.1 --port "$port" $IC_VLLM_ARGS >"$log" 2>&1 &
server=$!   # on_exit stops it
for _ in $(seq 360); do   # weights load + CUDA graph capture: allow 30 min
  curl -sf "http://127.0.0.1:$port/health" >/dev/null && break
  kill -0 $server 2>/dev/null || { echo "vLLM exited during start-up:"; tail -50 "$log"; exit 1; }
  sleep 5
done
curl -sf "http://127.0.0.1:$port/health" >/dev/null || { echo "vLLM not healthy after 30 min"; tail -50 "$log"; exit 1; }
echo "vLLM up after $(( $(date +%s) - start )) s"
export IC_URL="http://127.0.0.1:$port"
label="${IC_LABEL:-${IC_PRESET_NAME}-${SLURM_JOB_ID:-local}}"
runs="${IC_RUNS:-$IC_ROOT/runs}"   # a wave gives each job and stage its own folder (IC_RUNS, IC_LABEL)
# IC_LAYOUT=1 (the glm-ocr preset) makes every mode below layout-first: cluster_ocr.py reads it as --layout.

case "$IC_MODE" in
  truth) "$IC_PY" cluster_ocr.py truth --pack "$IC_PACK" --out "$runs/truth" --label "$label" --warmup ;;
  # One folder per preset, not per job: a resubmission after exit 75 sends only the windows still unanswered.
  seg)   "$IC_PY" cluster_seg.py run --pack "$IC_PACK" --out "$runs/seg" --label "${IC_LABEL:-$IC_PRESET_NAME}" --warmup ;;
  # Text prompts as the app's local route sends them (cluster_text.py; the dating benchmark). IC_TEXT_ARGS: --thinking-off.
  text)  "$IC_PY" cluster_text.py --pack "$IC_PACK" --out "$runs/text" --label "${IC_LABEL:-$label}" ${IC_TEXT_ARGS:-} ;;
  news)  "$IC_PY" cluster_ocr.py news --newsbench "$IC_ROOT/newsbench" --out "$runs/news" --label "$label" ;;
  news-layout)  # a general model (served here) reading newspaper-ocr's regions, in its own venv (cluster_news_layout.py)
    "$IC_ROOT/npo-venv/bin/python" cluster_news_layout.py --newsbench "$IC_ROOT/newsbench" --out "$runs/news-layout" \
      --label "$label" --base-url "$IC_URL/v1" --model "$IC_MODEL" --reader openai \
      --detectors ${IC_DETECTORS:-doclayout_yolo paddlex} --workers "${IC_LAYOUT_WORKERS:-8}"
    # newspaper-ocr leaves a region blank when its request fails, so a page can look read while most of it is missing
    # (a vLLM crash did that on 2026-10-15). vLLM's own log says how many requests failed.
    echo "vLLM: $(grep -c 'chat/completions HTTP/1.1" 200' "$log") requests answered, $(grep -c 'chat/completions HTTP/1.1" [45]' "$log") refused"
    if grep -q "EngineDeadError" "$log"; then echo "vLLM's engine died during the run: regions after that came back blank"; exit 1; fi ;;
  bulk)
    # Stop sending new pages 15 min before the wall limit, so the job ends itself instead of being killed.
    deadline=$(( start + IC_WALL_MIN * 60 - 900 ))
    shard="${SLURM_ARRAY_TASK_ID:-0}/$IC_SHARDS"
    set +e
    "$IC_PY" cluster_ocr.py bulk --in "$IC_IN" --out "$IC_OUT" --shard "$shard" --deadline "$deadline" ${IC_BULK_ARGS:-}
    rc=$?
    set -e
    if [ $rc -eq 75 ] && [ "${IC_CHAIN:-0}" -lt "${IC_CHAIN_MAX:-30}" ]; then
      # Not finished: queue the same shard again. Done pages are skipped, so a rerun only does what is left.
      # A wave's pilot is never requeued: three pages that do not finish are a failed gate.
      if [ "${IC_WAVE_STAGE:-}" != pilot ]; then
        new="$(IC_CHAIN=$(( ${IC_CHAIN:-0} + 1 )) sbatch --parsable --export=ALL "${SBATCH_ARGS[@]}" --array="${SLURM_ARRAY_TASK_ID:-0}" job.sbatch)"
        echo "requeued as $new"; wave_note="requeued ${new%%;*}"
        exit 0
      fi
    fi
    [ $rc -eq 0 ] || exit $rc ;;
  *) echo "IC_MODE must be truth, seg, text, news, news-layout or bulk"; exit 2 ;;
esac
# A wave pilot passes only if every one of its items was read (wave.py gate); a failure here cancels the chain.
[ "${IC_WAVE_STAGE:-}" != pilot ] || "$IC_PY" wave.py gate "$IC_WAVE_DIR"
