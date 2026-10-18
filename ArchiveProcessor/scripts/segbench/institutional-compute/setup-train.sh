#!/usr/bin/env bash
# W41.seg-finetune: the training venv (LoRA of Qwen3.5 4B and 2B), beside the vLLM venv the jobs serve from and never
# touching it, and the two base models fetched into the HF cache the GPU jobs read offline.
# Source compute.env first. Install directly only if login-node policy permits it; otherwise ask your office
# for a CPU allocation and submit this script with --export=ALL and those CPU partition/account/QOS settings.
# CPU partitions are site-specific and are not inferred from the profile's GPU partition.
set -euo pipefail
cd "${SLURM_SUBMIT_DIR:-$(dirname "$0")}"
: "${IC_ROOT:?source compute.env before running/submitting}" "${HF_HOME:?missing cache snapshot}"
source runtime.sh; load_cluster_modules
V="$IC_ROOT/train-venv"
# The same torch as the vLLM venv (2.13 cu130), so the node's driver serves both; transformers as that venv's.
TORCH="${IC_TRAIN_TORCH:-2.13.0}"; TF="${IC_TRAIN_TRANSFORMERS:-5.17.0}"
PY="$(command -v python3.12 || command -v python3.11 || command -v python3)"
[ -x "$V/bin/python" ] || "$PY" -m venv "$V"
"$V/bin/pip" install -q --upgrade pip
"$V/bin/pip" install -q "torch==$TORCH" torchvision --index-url https://download.pytorch.org/whl/cu130
"$V/bin/pip" install -q "transformers==$TF" peft accelerate pillow "huggingface_hub[cli]"
# Qwen3.5's gated-delta-net layers fall back to slow reference PyTorch without these Triton kernels (seen 2026-10-15).
"$V/bin/pip" install -q flash-linear-attention
"$V/bin/python" -c 'import torch, transformers, peft; print("torch", torch.__version__, "transformers", transformers.__version__, "peft", peft.__version__)'
for m in Qwen/Qwen3.5-4B Qwen/Qwen3.5-2B Qwen/Qwen3.5-0.8B; do  # 0.8B: the CPU smoke run
  HF_HOME="$HF_HOME" "$V/bin/hf" download "$m" --quiet >/dev/null && echo "fetched $m"
done
