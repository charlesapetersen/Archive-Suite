#!/bin/bash
#SBATCH --job-name=boxes-setup
#SBATCH --partition=normal
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --time=04:00:00
# W46.ocr-new-open-boxes on Sherlock: one CPU job, because Sherlock keeps installs and downloads off login nodes.
#   sbatch --output=... setup-job.sh SH_DIR CANDIDATES_JSON
# Two roots with W46.ocr-new-open's pages: $FS_ROOT/new-open-boxes-895 (open-sweep-20261019's public895.jsonl and
# pilot3.jsonl) and $FS_ROOT/new-open-boxes-96 (truth96-20261020's truth99.jsonl and pilot3.jsonl); the images stay
# where those manifests point. Then, per model: an overlay venv in $GROUP_HOME/$USER/envs/boxes-<key>
# (--system-site-packages over the vLLM image, as setup-ppocr-job.sh builds PP-OCRv6's) with the card's pins, the image's
# torch stack held by constraints (granite's venv holds the whole image, so docling-core cannot move a vLLM
# dependency); the pinned snapshot (boxes_setup.py download, in the image); and the import check in the venv
# (boxes_setup.py check). Rerunnable: a ready key and a built venv are left alone. Exits 3 when no model is ready, so
# the chained GPU jobs never start for nothing; a single skipped model's own jobs exit at once (job.sh).
set -euo pipefail
SH_DIR="$1"; CANDS="$2"; source "$SH_DIR/sh.env"
HERE="$SH_DIR/new-open-boxes"; ENVS="$GROUP_HOME/$USER/envs"
OS="$FS_ROOT/open-sweep-20261019" T96="$FS_ROOT/truth96-20261020" A="$FS_ROOT/new-open-boxes-895" B="$FS_ROOT/new-open-boxes-96"
mkdir -p "$A" "$B" "$ENVS" "$SH_SHIM" "$SCRATCH/cache/pip"
[ -s "$A/public895.jsonl" ] || cp "$OS/public895.jsonl" "$OS/pilot3.jsonl" "$A/"
[ -s "$B/truth99.jsonl" ] || cp "$T96/truth99.jsonl" "$T96/pilot3.jsonl" "$B/"
cp "$CANDS" "$A/candidates.json"
run() { apptainer -s exec --bind "$SCRATCH,$GROUP_HOME" --env PIP_CACHE_DIR="$SCRATCH/cache/pip" \
  --env HF_HOME="$HF_HOME" --env PYTHONPATH="$SH_SHIM" "$SH_IMG" "$@"; }
# The image's own packages, once: the torch stack alone for the transformers venvs, everything for granite's.
FREEZE="$A/image-freeze.txt"
run python3 -m pip freeze --all > "$FREEZE"
grep -i -E '^(torch|torchvision|torchaudio|triton|nvidia-[a-z0-9-]+)==' "$FREEZE" > "$A/constraints-torch.txt"
grep -E '^[A-Za-z0-9_.-]+==' "$FREEZE" > "$A/constraints-image.txt"
run python3 "$HERE/boxes_setup.py" download "$A/candidates.json" "$A" "$B"
keys=$("$FS_PY" -c 'import json,sys;print(" ".join(c["key"] for c in json.load(open(sys.argv[1]))))' "$A/candidates.json")
for key in $keys; do
  read -r cons pins < <("$FS_PY" -c 'import json,sys
c=[x for x in json.load(open(sys.argv[1])) if x["key"]==sys.argv[2]][0];print(c["constraints"], " ".join(c["pip"]))' \
    "$A/candidates.json" "$key")
  state=$("$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["state"])' "$A/$key/prepared.json")
  [ "$state" = downloaded ] || { echo "$key: $state, no venv"; continue; }
  E="$ENVS/boxes-$key"
  if [ ! -x "$E/bin/python" ]; then
    run python3 -m venv --system-site-packages "$E"
    # `image` tries the whole image first, then the torch stack alone; the import check then proves vLLM still loads.
    used=''
    for c in $([ "$cons" = image ] && echo image torch || echo torch); do
      # shellcheck disable=SC2086  # pins is a word list
      if run "$E/bin/python" -m pip install -q --disable-pip-version-check -c "$A/constraints-$c.txt" $pins; then
        used=$c; echo "$c" > "$E/constraints-used"; break
      fi
    done
    if [ -z "$used" ]; then
      "$FS_PY" - "$A" "$B" "$key" "pip install failed under the image constraints: $pins" <<'PY'
import json, pathlib, sys
for root in sys.argv[1:3]:
    p = pathlib.Path(root) / sys.argv[3] / 'prepared.json'; r = json.loads(p.read_text())
    r.update(state='skipped', reason=sys.argv[4]); p.write_text(json.dumps(r, indent=1) + '\n')
PY
      rm -rf "$E"; continue
    fi
    run "$E/bin/python" -m pip freeze > "$E/requirements-resolved.txt"
  fi
  apptainer -s exec --bind "$SCRATCH,$GROUP_HOME" --env HF_HOME="$HF_HOME" --env HF_HUB_OFFLINE=1 \
    --env PYTHONPATH="$SH_SHIM" "$SH_IMG" "$E/bin/python" "$HERE/boxes_setup.py" check "$key" "$A" "$B"
done
ready=$(cat "$A"/*/prepared.json | "$FS_PY" -c 'import json,sys
d=json.JSONDecoder();s=sys.stdin.read();i=0;n=[]
while True:
    while i<len(s) and s[i].isspace(): i+=1
    if i>=len(s): break
    r,i=d.raw_decode(s,i); n += [r["key"]] if r["state"]=="ready" else []
print(" ".join(n))')
du -sh "$HF_HOME" "$ENVS"/boxes-* 2>/dev/null || true
echo "ready: ${ready:-none}"
[ -n "$ready" ] || exit 3
