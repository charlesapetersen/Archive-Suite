#!/bin/bash
#SBATCH --job-name=swm-merge
#SBATCH --partition=normal
#SBATCH --cpus-per-task=4
#SBATCH --mem=64G
#SBATCH --time=01:00:00
# W46.seg-window-modality: rebuild a trained student (2b or 4b) from its FarmShare adapter, on CPU, exactly as
# seg-context/merge-job.sh rebuilds the 2B (train_seg.py merge; peft alone, --no-deps, in the shared overlay venv; see
# that script for why). The two merges run one after the other (submit.sh), so they never build the venv at once.
#   sbatch ... merge-job.sh ROOT JOB 2b|4b     SWM_ADAPTER_2B / SWM_ADAPTER_4B override the adapter folders
set -euo pipefail
ROOT="$1"; JOB="$2"; SIZE="$3"
: "${SLURM_JOB_ID:?must run as a Slurm job}"
source "$JOB/sh.env"
FS_TRAIN="$GROUP_HOME/$USER/archive-suite/FarmShare-scratch-20261022/fs-ocr/train"
case "$SIZE" in
  2b) ADAPTER="${SWM_ADAPTER_2B:-}" ;;
  4b) ADAPTER="${SWM_ADAPTER_4B:-}" ;;
  *) echo "unknown size $SIZE"; exit 2 ;;
esac
# FarmShare's train.sbatch wrote train/seg-<size>; the Sherlock copy holds the full runs as train/full/qwen3.5-<size>,
# with train/seg-2b linked to the 2B's (owner session, 2026-10-29). The first that holds an adapter is used.
if [ -z "$ADAPTER" ]; then
  for c in "$FS_TRAIN/seg-$SIZE/adapter" "$FS_TRAIN/full/qwen3.5-$SIZE/adapter"; do
    [ -s "$c/adapter_config.json" ] && { ADAPTER="$c"; break; }
  done
fi
ADAPTER="${ADAPTER:-$FS_TRAIN/seg-$SIZE/adapter}"
OUT="$ROOT/seg-$SIZE-merged"
ENV="$GROUP_HOME/$USER/envs/peft-overlay"
[ -s "$ADAPTER/adapter_config.json" ] && [ -s "$ADAPTER/../train.json" ] || {
  echo "no seg-$SIZE adapter (adapter_config.json and ../train.json) at $ADAPTER"; exit 2; }
# The merge writes into $OUT.tmp and is moved into place whole, so a merge that died mid-save is never served.
[ ! -e "$OUT/config.json" ] || { echo "merged model already at $OUT"; exit 0; }
rm -rf "$OUT.tmp"
mkdir -p "$SCRATCH/cache/pip" "$ROOT/runtime"
run() { apptainer -s exec --bind "$SCRATCH,$GROUP_HOME" --env PIP_CACHE_DIR="$SCRATCH/cache/pip" \
  --env PYTHONPATH="$SH_SHIM" --env HF_HOME="$HF_HOME" "$SH_IMG" "$@"; }
peft_version=$(run python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("peft_version") or "")' \
  "$ADAPTER/adapter_config.json")
[[ -z "$peft_version" || "$peft_version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "unpinnable peft_version $peft_version"; exit 2; }
if [ ! -x "$ENV/bin/python" ]; then
  run python3 -m venv --system-site-packages "$ENV"
fi
run "$ENV/bin/python" -m pip install -q --disable-pip-version-check --no-deps "peft${peft_version:+==$peft_version}"
run "$ENV/bin/python" -c 'import accelerate, safetensors, huggingface_hub'
run "$ENV/bin/python" -c 'import torch, transformers, peft
print("torch", torch.__version__, "transformers", transformers.__version__, "peft", peft.__version__)
assert torch.__version__.endswith("+cu129"), "the overlay replaced the image torch"'
run env HF_HUB_OFFLINE=1 "$ENV/bin/python" "$ROOT/support/segbench/train_seg.py" merge --adapter "$ADAPTER" --out "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
run python3 - "$ADAPTER" "$OUT" "$ROOT/runtime/merge-$SIZE-$SLURM_JOB_ID.json" <<'PY'
import hashlib, json, os, sys
from pathlib import Path
adapter, out, rec = map(Path, sys.argv[1:])
h = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
train = json.loads((adapter.parent / "train.json").read_text())
base = Path(os.environ["HF_HOME"]) / "hub" / ("models--" + str(train.get("model", "")).replace("/", "--")) / "refs/main"
json.dump({"adapter": str(adapter), "base_revision": base.read_text().strip() if base.exists() else None, "train_json": train,
           "adapter_files": {p.name: h(p) for p in sorted(adapter.iterdir()) if p.is_file()},
           "merged_files": {p.name: h(p) for p in sorted(out.iterdir()) if p.is_file() and p.stat().st_size < 2**33}},
          open(rec, "x"), indent=1)
PY
echo "merged -> $OUT"
