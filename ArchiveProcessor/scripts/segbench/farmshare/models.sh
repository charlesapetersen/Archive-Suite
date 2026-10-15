# Model presets for the FarmShare job (sourced; W41.farmshare-plan). One L40S = 48 GB; a node = 4 x L40S.
# preset <name> sets FS_MODEL (Hugging Face repo, also the served name), FS_GPUS (tensor-parallel size),
# FS_DISK_GB (download size, approximate) and FS_VLLM_ARGS. FS_MAX_LEN may be raised for newspapers.
# Panel scores are NES on the 96 accuracy pages (segbench-results/ocr-panel-local.md, ocr-panel-cloud.md).

preset() {
  FS_PRESET="$1"
  local len="${FS_MAX_LEN:-16384}" FS_EXTRA=""
  case "$1" in
    qwen3.6-27b)       # first choice. Panel 94.28 (Chutes fp8). Official block-FP8 checkpoint.
      FS_MODEL=Qwen/Qwen3.6-27B-FP8; FS_GPUS=1; FS_DISK_GB=31 ;;
    qwen3.6-27b-dyn)   # fallback if this vLLM cannot run block-FP8 on Ada: bf16 weights, fp8 at load time.
      FS_MODEL=Qwen/Qwen3.6-27B; FS_GPUS=1; FS_DISK_GB=56; FS_EXTRA="--quantization fp8" ;;
    qwen3.6-35b-a3b)   # fast MoE (3B active). Panel 93.02 (DeepInfra fp8), 96/96 completed.
      FS_MODEL=Qwen/Qwen3.6-35B-A3B-FP8; FS_GPUS=1; FS_DISK_GB=38; len="${FS_MAX_LEN:-12288}" ;;
    qwen3-vl-8b)       # cheap floor that ran at the precision measured (bf16). Panel 91.81; clippings 93.47.
      FS_MODEL=Qwen/Qwen3-VL-8B-Instruct; FS_GPUS=1; FS_DISK_GB=18 ;;
    qwen3.5-27b)       # segmentation's best open model (W41.seg-large: 95.0% on Deaver at fp8). OCR 95.76 completed-only.
      FS_MODEL=Qwen/Qwen3.5-27B-FP8; FS_GPUS=1; FS_DISK_GB=31 ;;
    qwen3.5-122b-a10b) # whole-node option, OCR unmeasured anywhere; segmentation 84.4% (< 27B). Only to settle "bigger?".
      FS_MODEL=Qwen/Qwen3.5-122B-A10B-FP8; FS_GPUS=4; FS_DISK_GB=126 ;;
    *) echo "unknown preset '$1' (qwen3.6-27b qwen3.6-27b-dyn qwen3.6-35b-a3b qwen3-vl-8b qwen3.5-27b qwen3.5-122b-a10b)" >&2
       return 2 ;;
  esac
  # One image a prompt; fp8 KV cache doubles the batch that fits beside the weights; no prefix caching (every
  # image differs, only the prompt text repeats and it is short).
  FS_VLLM_ARGS="--tensor-parallel-size $FS_GPUS --max-model-len $len --kv-cache-dtype fp8 \
--gpu-memory-utilization 0.92 --max-num-seqs ${FS_MAX_SEQS:-32} --limit-mm-per-prompt {\"image\":1} ${FS_EXTRA:-}"
  export FS_PRESET FS_MODEL FS_GPUS FS_DISK_GB FS_VLLM_ARGS
}
