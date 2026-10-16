# Model presets for the FarmShare job (sourced; W41.farmshare-plan). One L40S = 48 GB; a node = 4 x L40S.
# preset <name> sets FS_MODEL (Hugging Face repo, also the served name), FS_GPUS (tensor-parallel size),
# FS_DISK_GB (download size, approximate) and FS_VLLM_ARGS. FS_MAX_LEN may be raised for newspapers.
# FS_LAYOUT=1 marks the layout-first route (fs_ocr.py --layout, news_layout.py): a layout detector runs beside vLLM
# on the same GPU, and FS_DET_REPO/FS_DET_FILE name its checkpoint, which download.sh fetches too.
# Panel scores are NES on the 96 accuracy pages (segbench-results/ocr-panel-local.md, ocr-panel-cloud.md).

preset() {
  FS_PRESET="$1"
  local len="${FS_MAX_LEN:-16384}" FS_EXTRA="" kv="${FS_KV_DTYPE:-fp8}" util=0.92 seqs="${FS_MAX_SEQS:-32}"
  FS_LAYOUT=0 FS_DET_REPO="" FS_DET_FILE=""
  case "$1" in
    qwen3.6-27b)       # first choice. Panel 94.28 (Chutes fp8). Official block-FP8 checkpoint.
      FS_MODEL=Qwen/Qwen3.6-27B-FP8; FS_GPUS=1; FS_DISK_GB=31 ;;
    qwen3.6-27b-dyn)   # fallback if this vLLM cannot run block-FP8 on Ada: bf16 weights, fp8 at load time.
      FS_MODEL=Qwen/Qwen3.6-27B; FS_GPUS=1; FS_DISK_GB=56; FS_EXTRA="--quantization fp8" ;;
    qwen3.6-35b-a3b)   # fast MoE (3B active). Panel 93.02 (DeepInfra fp8), 96/96 completed.
      FS_MODEL=Qwen/Qwen3.6-35B-A3B-FP8; FS_GPUS=1; FS_DISK_GB=38 ;;
    qwen3-vl-8b)       # cheap floor that ran at the precision measured (bf16). Panel 91.81; clippings 93.47.
      FS_MODEL=Qwen/Qwen3-VL-8B-Instruct; FS_GPUS=1; FS_DISK_GB=18 ;;
    qwen3.5-27b)       # segmentation's best open model (W41.seg-large: 95.0% on Deaver at fp8; submit.sh seg). OCR 95.76 completed-only.
      FS_MODEL=Qwen/Qwen3.5-27B-FP8; FS_GPUS=1; FS_DISK_GB=31 ;;
    qwen3.5-122b-a10b) # whole-node option, OCR unmeasured anywhere; segmentation 84.4% (< 27B). Only to settle "bigger?".
      FS_MODEL=Qwen/Qwen3.5-122B-A10B-FP8; FS_GPUS=4; FS_DISK_GB=126 ;;
    glm-ocr)           # layout-first newspapers (W41.farmshare-news-layout): DocLayout-YOLO + GLM-OCR 0.9B per region,
                       # NewsBench's 0.970 row. A region needs far less than a page, so FS_MAX_LEN does not apply.
                       # bf16 KV (as measured), 20% of the card left for the detector, MTP speculative decoding as
                       # the vLLM recipe for GLM-OCR gives it (FS_GLM_MTP=0 turns it off).
      FS_MODEL=zai-org/GLM-OCR; FS_GPUS=1; FS_DISK_GB=3; FS_LAYOUT=1; len=16384; kv="${FS_KV_DTYPE:-auto}"
      util=0.80; seqs="${FS_MAX_SEQS:-64}"
      FS_DET_REPO=juliozhao/DocLayout-YOLO-DocStructBench-imgsz1280-2501   # newspaper-ocr 0.11.0's default variant
      FS_DET_FILE=doclayout_yolo_docstructbench_imgsz1280_2501.pt
      [ "${FS_GLM_MTP:-1}" = 0 ] || FS_EXTRA='--speculative-config {"method":"mtp","num_speculative_tokens":1}' ;;
    *) echo "unknown preset '$1' (qwen3.6-27b qwen3.6-27b-dyn qwen3.6-35b-a3b qwen3-vl-8b qwen3.5-27b qwen3.5-122b-a10b glm-ocr)" >&2
       return 2 ;;
  esac
  # max-model-len must hold the prompt (~4,900 tokens) plus max_tokens (8192), or vLLM refuses every page.
  # One image a prompt (FS_MM_IMAGES=7 for segmentation's windows: submit.sh seg). An fp8 KV cache doubles the
  # batch beside the weights; FS_KV_DTYPE=auto if this vLLM will not take fp8 KV for the Qwen3.5/3.6
  # hybrid-attention layers (the start-up log says so).
  if [ "$len" -lt 13312 ]; then echo "FS_MAX_LEN=$len is below prompt + max_tokens (13312)" >&2; return 2; fi
  FS_VLLM_ARGS="--tensor-parallel-size $FS_GPUS --max-model-len $len --kv-cache-dtype $kv \
--gpu-memory-utilization $util --max-num-seqs $seqs --limit-mm-per-prompt {\"image\":${FS_MM_IMAGES:-1}} ${FS_EXTRA:-}"
  export FS_PRESET FS_MODEL FS_GPUS FS_DISK_GB FS_VLLM_ARGS FS_LAYOUT FS_DET_REPO FS_DET_FILE
}
