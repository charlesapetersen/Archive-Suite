#!/usr/bin/env bash
# W41.farmshare-plan — one GPU job: start vLLM on this node, run one fs_ocr.py mode against it, stop it.
# Submitted by submit.sh, which passes partition/QOS/GPUs/time fitted to limits.env; do not sbatch it by hand.
# Env from submit.sh: FS_DIR FS_MODE FS_PRESET_NAME FS_WALL_MIN [FS_PACK | FS_IN FS_OUT FS_SHARDS FS_CHAIN ...]
set -euo pipefail
cd "$FS_DIR"
source fs.env; source models.sh; preset "$FS_PRESET_NAME"
# FlashInfer compiles attention kernels (prefill, and the fp8 KV cache's) at start-up and needs nvcc. The GPU nodes
# have none in /usr/local/cuda, and FarmShare's cuda/12.9.0 module is the wrong one: vLLM's torch is built for
# CUDA 13, so a kernel built by 12.9 links libcudart.so.12 and fails to load (2026-10-15). The venv already holds
# the CUDA 13 toolkit torch came with (nvidia/cu13: nvcc, headers, libcudart.so.13), so compile with that.
FS_CUDA="$("$FS_PY" -c 'import nvidia, os; print(os.path.join(list(nvidia.__path__)[0], "cu13"))' 2>/dev/null || true)"
if [ -x "$FS_CUDA/bin/nvcc" ]; then
  export CUDA_HOME="$FS_CUDA" PATH="$FS_CUDA/bin:$PATH"; nvcc --version | tail -1
  # FlashInfer links with -L$CUDA_HOME/lib64 -lcudart, but the pip toolkit keeps its libraries in lib/ and has only
  # libcudart.so.13. GNU ld applies every -L to every -l, so add lib/ and a folder holding a libcudart.so link.
  mkdir -p "$FS_ROOT/cuda-link"; ln -sf "$FS_CUDA/lib/libcudart.so.13" "$FS_ROOT/cuda-link/libcudart.so"
  export FLASHINFER_EXTRA_LDFLAGS="-L$FS_CUDA/lib -L$FS_ROOT/cuda-link"
else
  echo "WARNING: no CUDA 13 nvcc in the venv ($FS_CUDA); FlashInfer's start-up compile will fail"
fi
export HF_HOME HF_HUB_OFFLINE=1 FS_GPUS   # weights were fetched on the login node; compute nodes stay offline
start=$(date +%s)
port=$((8100 + ${SLURM_JOB_ID:-0} % 800))
log="$FS_ROOT/logs/vllm-${SLURM_JOB_ID:-local}.log"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv | tee "$FS_ROOT/logs/gpu-${SLURM_JOB_ID:-local}.csv"

# shellcheck disable=SC2086  # FS_VLLM_ARGS is a word list on purpose
"$FS_VLLM" serve "$FS_MODEL" --host 127.0.0.1 --port "$port" $FS_VLLM_ARGS >"$log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null; wait $server 2>/dev/null || true' EXIT
for _ in $(seq 360); do   # weights load + CUDA graph capture: allow 30 min
  curl -sf "http://127.0.0.1:$port/health" >/dev/null && break
  kill -0 $server 2>/dev/null || { echo "vLLM exited during start-up:"; tail -50 "$log"; exit 1; }
  sleep 5
done
curl -sf "http://127.0.0.1:$port/health" >/dev/null || { echo "vLLM not healthy after 30 min"; tail -50 "$log"; exit 1; }
echo "vLLM up after $(( $(date +%s) - start )) s"
export FS_URL="http://127.0.0.1:$port"
label="${FS_PRESET_NAME}-${SLURM_JOB_ID:-local}"

case "$FS_MODE" in
  truth) "$FS_PY" fs_ocr.py truth --pack "$FS_PACK" --out "$FS_ROOT/runs/truth" --label "$label" --warmup ;;
  news)  "$FS_PY" fs_ocr.py news --newsbench "$FS_ROOT/newsbench" --out "$FS_ROOT/runs/news" --label "$label" ;;
  bulk)
    # Stop sending new pages 15 min before the wall limit, so the job ends itself instead of being killed.
    deadline=$(( start + FS_WALL_MIN * 60 - 900 ))
    shard="${SLURM_ARRAY_TASK_ID:-0}/$FS_SHARDS"
    set +e
    "$FS_PY" fs_ocr.py bulk --in "$FS_IN" --out "$FS_OUT" --shard "$shard" --deadline "$deadline"
    rc=$?
    set -e
    if [ $rc -eq 75 ] && [ "${FS_CHAIN:-0}" -lt "${FS_CHAIN_MAX:-30}" ]; then
      # Not finished: queue the same shard again. Done pages are skipped, so a rerun only does what is left.
      FS_CHAIN=$(( ${FS_CHAIN:-0} + 1 )) sbatch --export=ALL $FS_SBATCH_ARGS --array="${SLURM_ARRAY_TASK_ID:-0}" job.sbatch
      exit 0
    fi
    exit $rc ;;
  *) echo "FS_MODE must be truth, news or bulk"; exit 2 ;;
esac
