#!/bin/bash
#SBATCH --job-name=ctx-merge
#SBATCH --partition=normal
#SBATCH --cpus-per-task=4
#SBATCH --mem=48G
#SBATCH --time=01:00:00
# W46.seg-context: rebuild the trained 2B that every fs-seg-2b row was read with. Sherlock holds only its FarmShare
# adapter (sherlock-access.md: the copy has adapters, not merged models), so this merges it onto Qwen/Qwen3.5-2B with
# FarmShare's own train_seg.py merge, on CPU. peft is the one package the vLLM image lacks: it goes in a
# --system-site-packages venv over the image ($GROUP_HOME, never $SCRATCH), every package the image already has held
# to the image's version, as setup-ppocr-job.sh builds PP-OCRv6's overlay.
#   sbatch ... merge-job.sh ROOT JOB          SEG_CONTEXT_ADAPTER overrides the adapter folder
set -euo pipefail
ROOT="$1"; JOB="$2"
: "${SLURM_JOB_ID:?must run as a Slurm job}"
source "$JOB/sh.env"
ADAPTER="${SEG_CONTEXT_ADAPTER:-$GROUP_HOME/$USER/archive-suite/FarmShare-scratch-20261022/fs-ocr/train/seg-2b/adapter}"
OUT="$ROOT/seg-2b-merged"
ENV="$GROUP_HOME/$USER/envs/peft-overlay"
[ -s "$ADAPTER/adapter_config.json" ] && [ -s "$ADAPTER/../train.json" ] || {
  echo "no seg-2b adapter (adapter_config.json and ../train.json) at $ADAPTER; set SEG_CONTEXT_ADAPTER"; exit 2; }
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
# Direct-reference lines (pkg @ file://...) are not valid constraints; the version lines hold torch and the rest.
run python3 -m pip freeze | grep -v ' @ ' > "$SCRATCH/peft-constraints-$SLURM_JOB_ID.txt"
run "$ENV/bin/python" -m pip install -q --disable-pip-version-check -c "$SCRATCH/peft-constraints-$SLURM_JOB_ID.txt" \
  "peft${peft_version:+==$peft_version}" accelerate
rm -f "$SCRATCH/peft-constraints-$SLURM_JOB_ID.txt"
run "$ENV/bin/python" -c 'import torch, transformers, peft
print("torch", torch.__version__, "transformers", transformers.__version__, "peft", peft.__version__)
assert torch.__version__.endswith("+cu129"), "the overlay replaced the image torch"'
run env HF_HUB_OFFLINE=1 "$ENV/bin/python" "$ROOT/support/segbench/train_seg.py" merge --adapter "$ADAPTER" --out "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
run python3 - "$ADAPTER" "$OUT" "$ROOT/runtime/merge-$SLURM_JOB_ID.json" <<'PY'
import hashlib, json, sys
from pathlib import Path
adapter, out, rec = map(Path, sys.argv[1:])
h = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
base = Path(__import__("os").environ["HF_HOME"]) / "hub/models--Qwen--Qwen3.5-2B/refs/main"
json.dump({"adapter": str(adapter), "base_revision": base.read_text().strip() if base.exists() else None, "train_json": json.loads((adapter.parent / "train.json").read_text()),
           "adapter_files": {p.name: h(p) for p in sorted(adapter.iterdir()) if p.is_file()},
           "merged_files": {p.name: h(p) for p in sorted(out.iterdir()) if p.is_file() and p.stat().st_size < 2**33}},
          open(rec, "x"), indent=1)
PY
echo "merged -> $OUT"
