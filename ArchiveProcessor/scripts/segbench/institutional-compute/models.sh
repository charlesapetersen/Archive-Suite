# Model presets chosen by per-card GPU memory, independent of a cluster or GPU product name.
# preset <name> sets IC_MODEL (Hugging Face repo, also the served name), IC_GPUS (tensor-parallel size),
# IC_DISK_GB (download size, approximate) and IC_VLLM_ARGS. IC_MAX_LEN may be raised for newspapers.
# IC_LAYOUT=1 marks the layout-first route (cluster_ocr.py --layout, news_layout.py): a layout detector runs beside vLLM
# on the same GPU, and IC_DET_REPO/IC_DET_FILE name its checkpoint, which download.sh fetches too.
# Panel scores are NES on the 96 accuracy pages (segbench-results/ocr-panel-local.md, ocr-panel-cloud.md).

preset() {
  local name="$1" memory="${IC_GPU_MEMORY_GB:-48}"
  if [ "$name" = auto ]; then
    if [ "$memory" -ge 48 ]; then name=qwen3.6-27b; else name=qwen3-vl-8b; fi
  fi
  IC_PRESET="$name"
  local len="${IC_MAX_LEN:-16384}" IC_EXTRA="" kv="${IC_KV_DTYPE:-fp8}" util="${IC_GPU_UTIL:-0.92}" seqs="${IC_MAX_SEQS:-32}"
  IC_LAYOUT=0 IC_DET_REPO="" IC_DET_FILE="" IC_SERVED=""
  case "$name" in
    qwen3.6-27b)       # first choice. Panel 94.28 (Chutes fp8). Official block-FP8 checkpoint.
      IC_MODEL=Qwen/Qwen3.6-27B-FP8; IC_GPUS=1; IC_DISK_GB=31 ;;
    qwen3.8-27b)       # Qwen3.6 27B's successor (Aug 2026), same Qwen3.5 architecture and block-FP8 checkpoint.
                       # Measured 2026-10-15: 93.10 NES (Qwen3.6 27B 95.25) at the same speed; weaker on newspapers.
      IC_MODEL=Qwen/Qwen3.8-27B-FP8; IC_GPUS=1; IC_DISK_GB=31 ;;
    qwen3.6-27b-dyn)   # fallback if this vLLM cannot run block-FP8 on Ada: bf16 weights, fp8 at load time.
      IC_MODEL=Qwen/Qwen3.6-27B; IC_GPUS=1; IC_DISK_GB=56; IC_EXTRA="--quantization fp8" ;;
    qwen3.6-35b-a3b)   # fast MoE (3B active). Panel 93.02 (DeepInfra fp8), 96/96 completed.
      IC_MODEL=Qwen/Qwen3.6-35B-A3B-FP8; IC_GPUS=1; IC_DISK_GB=38 ;;
    qwen3-vl-8b)       # cheap floor that ran at the precision measured (bf16). Panel 91.81; clippings 93.47.
      IC_MODEL=Qwen/Qwen3-VL-8B-Instruct; IC_GPUS=1; IC_DISK_GB=18 ;;
    qwen3.5-27b)       # segmentation's best open model (W41.seg-large: 95.0% on Deaver at fp8; submit.sh seg). OCR 95.76 completed-only.
      IC_MODEL=Qwen/Qwen3.5-27B-FP8; IC_GPUS=1; IC_DISK_GB=31 ;;
    qwen3.5-122b-a10b) # whole-node option, OCR unmeasured anywhere; segmentation 84.4% (< 27B). Only to settle "bigger?".
      IC_MODEL=Qwen/Qwen3.5-122B-A10B-FP8; IC_GPUS=4; IC_DISK_GB=126 ;;
    glm-ocr)           # layout-first newspapers (W41.farmshare-news-layout): DocLayout-YOLO + GLM-OCR 0.9B per region,
                       # NewsBench's 0.970 row. A region needs far less than a page, so IC_MAX_LEN does not apply.
                       # bf16 KV (as measured), 20% of the card left for the detector, MTP speculative decoding as
                       # the vLLM recipe for GLM-OCR gives it (IC_GLM_MTP=0 turns it off).
      IC_MODEL=zai-org/GLM-OCR; IC_GPUS=1; IC_DISK_GB=3; IC_LAYOUT=1; len=16384; kv="${IC_KV_DTYPE:-auto}"
      util=0.80; seqs="${IC_MAX_SEQS:-64}"
      IC_DET_REPO=juliozhao/DocLayout-YOLO-DocStructBench-imgsz1280-2501   # newspaper-ocr 0.11.0's default variant
      IC_DET_FILE=doclayout_yolo_docstructbench_imgsz1280_2501.pt
      [ "${IC_GLM_MTP:-1}" = 0 ] || IC_EXTRA='--speculative-config {"method":"mtp","num_speculative_tokens":1}' ;;
    qwen3.5-4b|qwen3.5-2b)  # W41.seg-finetune: the students' untrained bases, the baselines (bf16)
      IC_MODEL="Qwen/Qwen3.5-$(echo "${name#qwen3.5-}" | tr b B)"; IC_GPUS=1; IC_DISK_GB=10 ;;
    seg-student)       # W41.seg-finetune: a merged student (train.sbatch), served under IC_STUDENT_NAME
      IC_MODEL="${IC_STUDENT:?IC_STUDENT=<a merged model directory>}"; IC_SERVED="${IC_STUDENT_NAME:?IC_STUDENT_NAME=<served name>}"
      IC_EXTRA="--served-model-name $IC_SERVED"; IC_GPUS=1; IC_DISK_GB=10 ;;
    *) echo "unknown preset '$1' (qwen3.6-27b qwen3.8-27b qwen3.6-27b-dyn qwen3.6-35b-a3b qwen3-vl-8b qwen3.5-27b qwen3.5-122b-a10b glm-ocr qwen3.5-4b qwen3.5-2b seg-student)" >&2
       return 2 ;;
  esac
  # Conservative serving budgets: weights plus KV/cache and runtime headroom. A preset can use tensor
  # parallelism on 24 GB cards; larger cards serve the same checkpoint without pretending quality improved.
  local required=48
  case "$name" in
    qwen3-vl-8b|qwen3.5-4b|qwen3.5-2b|seg-student|glm-ocr) required=24;;
    qwen3.6-27b-dyn) required=80;;
    qwen3.5-122b-a10b) required=192;;
  esac
  IC_GPUS=$(((required + memory - 1) / memory))
  # Tensor-parallel counts must divide the model's attention heads. Use powers of two.
  local parallel=1; while [ "$parallel" -lt "$IC_GPUS" ]; do parallel=$((parallel * 2)); done
  IC_GPUS="$parallel"
  # max-model-len must hold the prompt (~4,900 tokens) plus max_tokens (8192), or vLLM refuses every page.
  # One image a prompt (IC_MM_IMAGES=7 for segmentation's windows: submit.sh seg). An fp8 KV cache doubles the
  # batch beside the weights; IC_KV_DTYPE=auto if this vLLM will not take fp8 KV for the Qwen3.5/3.6
  # hybrid-attention layers (the start-up log says so).
  if [ "$len" -lt 13312 ]; then echo "IC_MAX_LEN=$len is below prompt + max_tokens (13312)" >&2; return 2; fi
  IC_VLLM_ARGS="--tensor-parallel-size $IC_GPUS --max-model-len $len --kv-cache-dtype $kv \
--gpu-memory-utilization $util --max-num-seqs $seqs --limit-mm-per-prompt {\"image\":${IC_MM_IMAGES:-1}} ${IC_EXTRA:-}"
  export IC_SERVED IC_PRESET IC_MODEL IC_GPUS IC_DISK_GB IC_VLLM_ARGS IC_LAYOUT IC_DET_REPO IC_DET_FILE
}
