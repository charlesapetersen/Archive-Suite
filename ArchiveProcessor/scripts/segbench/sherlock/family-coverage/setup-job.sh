#!/bin/bash
#SBATCH --job-name=family-setup
#SBATCH --partition=normal
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --time=04:00:00
# W46.ocr-family-coverage on Sherlock: one CPU job, because Sherlock keeps installs and downloads off login nodes.
#   sbatch --output=... setup-job.sh SH_DIR CANDIDATES_JSON
# Two roots with the pages W46.ocr-new-open read: $FS_ROOT/family-895 (open-sweep-20261019's public895.jsonl and
# pilot3.jsonl) and $FS_ROOT/family-96 (truth96-20261020's truth99.jsonl and pilot3.jsonl); the images stay where those
# manifests point. In the vLLM image: each card prompt read from its own package or file (family_setup.py prompts),
# the pinned snapshots (download), CHURRO's 455-page subset (subset). Then per model the check in the python it runs
# in: the image's own for the five vLLM readers, an overlay venv in $GROUP_HOME/$USER/envs/family-<key> for MinerU
# (mineru-vl-utils, the whole image held by constraints, so it cannot move a vLLM dependency). Rerunnable: a ready
# key and a built venv are left alone, and the pack's candidates file is copied fresh, so a corrected pack is what a
# rerun prepares. A step that fails for one model (subset, venv, check) marks that model skipped and setup goes on.
# Exits 3 when no model is ready, so the chained GPU jobs never start for nothing; a single skipped model's own jobs
# exit at once (job.sh).
set -euo pipefail
SH_DIR="$1"; CANDS="$2"; source "$SH_DIR/sh.env"
HERE="$SH_DIR/family-coverage"; ENVS="$GROUP_HOME/$USER/envs"
OS="$FS_ROOT/open-sweep-20261019" T96="$FS_ROOT/truth96-20261020" A="$FS_ROOT/family-895" B="$FS_ROOT/family-96"
mkdir -p "$A" "$B" "$ENVS" "$SH_SHIM" "$SCRATCH/cache/pip"
[ -s "$A/public895.jsonl" ] || cp "$OS/public895.jsonl" "$OS/pilot3.jsonl" "$A/"
[ -s "$B/truth99.jsonl" ] || cp "$T96/truth99.jsonl" "$T96/pilot3.jsonl" "$B/"
cp "$CANDS" "$A/candidates.json"
skip() {  # skip KEY REASON: in both roots, so that model's GPU jobs exit at once
  "$FS_PY" - "$A" "$B" "$1" "$2" <<'PY'
import json, pathlib, sys
for root in sys.argv[1:3]:
    p = pathlib.Path(root) / sys.argv[3] / 'prepared.json'; r = json.loads(p.read_text())
    r.update(state='skipped', reason=sys.argv[4]); p.write_text(json.dumps(r, indent=1) + '\n')
PY
}
run() { apptainer -s exec --bind "$SCRATCH,$GROUP_HOME" --env PIP_CACHE_DIR="$SCRATCH/cache/pip" \
  --env HF_HOME="$HF_HOME" --env PYTHONPATH="$SH_SHIM" "$SH_IMG" "$@"; }
FREEZE="$A/image-freeze.txt"
run python3 -m pip freeze --all > "$FREEZE"
grep -E '^[A-Za-z0-9_.-]+==' "$FREEZE" > "$A/constraints-image.txt"
run python3 "$HERE/family_setup.py" prompts "$A/candidates.json"
run python3 "$HERE/family_setup.py" download "$A/candidates.json" "$A" "$B"
keys=$("$FS_PY" -c 'import json,sys;print(" ".join(c["key"] for c in json.load(open(sys.argv[1]))))' "$A/candidates.json")
for key in $keys; do
  read -r state sub pins < <("$FS_PY" -c 'import json,sys
c=json.load(open(sys.argv[1]));print(c["state"], c.get("subset") or "-", " ".join(c.get("pip") or []))' \
    "$A/$key/prepared.json")
  [ "$state" = downloaded ] || { echo "$key: $state"; continue; }
  if [ "$sub" != - ] && ! run python3 "$HERE/family_setup.py" subset "$A" "$key" "$HERE/$sub"; then
    skip "$key" "subset $sub failed"; continue
  fi
  PY=python3
  if [ -n "$pins" ]; then
    E="$ENVS/family-$key"; PY="$E/bin/python"
    # Built means its freeze was written (the venv's python links to the image's, so a host-side -x test cannot tell).
    if [ ! -s "$E/requirements-resolved.txt" ]; then
      rm -rf "$E"
      run python3 -m venv --system-site-packages "$E" || { skip "$key" 'venv failed'; rm -rf "$E"; continue; }
      # shellcheck disable=SC2086  # pins is a word list
      if run "$E/bin/python" -m pip install -q --disable-pip-version-check -c "$A/constraints-image.txt" $pins; then
        echo image > "$E/constraints-used"
        run "$E/bin/python" -m pip freeze > "$E/requirements-resolved.txt"
      else
        skip "$key" "pip install failed under the image's constraints: $pins"
        rm -rf "$E"; continue
      fi
    fi
  fi
  apptainer -s exec --bind "$SCRATCH,$GROUP_HOME" --env HF_HOME="$HF_HOME" --env HF_HUB_OFFLINE=1 \
    --env BOXES_IMAGE_FREEZE="$FREEZE" --env PYTHONPATH="$SH_SHIM" "$SH_IMG" \
    "$PY" "$HERE/family_setup.py" check "$key" "$A" "$B" || skip "$key" 'check crashed (see the setup log)'
done
ready=$(cat "$A"/*/prepared.json | "$FS_PY" -c 'import json,sys
d=json.JSONDecoder();s=sys.stdin.read();i=0;n=[]
while True:
    while i<len(s) and s[i].isspace(): i+=1
    if i>=len(s): break
    r,i=d.raw_decode(s,i); n += [r["key"]] if r["state"]=="ready" else []
print(" ".join(n))')
du -sh "$HF_HOME" "$ENVS"/family-* 2>/dev/null || true
echo "ready: ${ready:-none}"
[ -n "$ready" ] || exit 3
