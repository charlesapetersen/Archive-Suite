#!/bin/bash
# One reader on the two frozen capability pages, all three arms. No expansion.
set -euo pipefail
ROOT="$1"; ROUTE="$2"
: "${SLURM_JOB_ID:?must run as a Slurm job}"
: "${FS_ENV:?source sherlock/sh.env before submission}"
source "$FS_ENV"
case "$ROUTE" in glm-ocr|qwen3.6-27b) ;; *) echo 'unsupported reader'; exit 2;; esac
export HF_HOME HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
mkdir -p "$ROOT/logs" "$ROOT/runtime/$ROUTE"
"$FS_PY" "$ROOT/regions_cells.py" check --root "$ROOT"
get() { "$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["routes"][sys.argv[2]][sys.argv[3]])' "$ROOT/freeze.json" "$ROUTE" "$1"; }
REPO=$(get model); NAME=$(get served); ARG_TEXT=$(get vllm_args)
cache="$HF_HOME/hub/models--${REPO//\//--}"
if [ -f "$cache/refs/main" ]; then
  revision=$(cat "$cache/refs/main")
else
  snapshots=("$cache"/snapshots/*)
  [ "${#snapshots[@]}" -eq 1 ] || { echo 'ambiguous/missing cached revision'; exit 2; }
  revision="$(basename "${snapshots[0]}")"
fi
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { echo 'invalid snapshot revision'; exit 2; }
MODEL="$cache/snapshots/$revision"
[ -f "$MODEL/config.json" ] || { echo 'model snapshot is incomplete'; exit 2; }
read -r -a ARGS <<< "$ARG_TEXT"
export FS_MODEL="$MODEL" FS_SERVED="$NAME"
PORT=$((16000 + SLURM_JOB_ID % 10000)); export FS_URL="http://127.0.0.1:$PORT"
RUNTIME="$ROOT/runtime/$ROUTE/$SLURM_JOB_ID.json"
"$FS_PY" - "$ROOT" "$ROUTE" "$revision" "$RUNTIME" <<'PY'
import importlib.metadata,os,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1]);import regions_cells as R
root,route,revision,out=Path(sys.argv[1]),sys.argv[2],sys.argv[3],Path(sys.argv[4])
frozen,truth=R.check(root)
runtime=dict(**frozen['routes'][route],revision=revision,job=os.environ['SLURM_JOB_ID'],
             vllm_version=importlib.metadata.version('vllm'),
             transformers_version=importlib.metadata.version('transformers'),code_sha256=R.code_hashes())
R.runtime_check(runtime,route,frozen);R.write_new(out,R.encoded(runtime))
PY
"$FS_VLLM" serve "$MODEL" --served-model-name "$NAME" --host 127.0.0.1 --port "$PORT" "${ARGS[@]}" > "$ROOT/logs/vllm-$SLURM_JOB_ID-$ROUTE.log" 2>&1 &
server=$!
finish() {
  rc=$?; trap - EXIT
  kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true
  # Preserve successful and failed receipts promptly outside purged scratch.
  # Each reader owns its subfolders, so the two jobs never overwrite each other.
  saved="$GROUP_HOME/$USER/archive-suite/sherlock-results/ocr-regions-cells-20261025"
  mkdir -p "$saved/out/$ROUTE" "$saved/runtime/$ROUTE" "$saved/logs/$ROUTE"
  if [ -d "$ROOT/out/$ROUTE" ]; then rsync -a "$ROOT/out/$ROUTE/" "$saved/out/$ROUTE/"; fi
  rsync -a "$ROOT/runtime/$ROUTE/" "$saved/runtime/$ROUTE/"
  cp "$ROOT/logs/vllm-$SLURM_JOB_ID-$ROUTE.log" "$saved/logs/$ROUTE/"
  exit "$rc"
}
trap finish EXIT
health() { python3 - "$FS_URL" <<'PY'
import sys,urllib.request
try:
 with urllib.request.urlopen(sys.argv[1]+'/health',timeout=2) as r: assert r.status==200
except Exception: sys.exit(1)
PY
}
for ((i=0;i<180;i++)); do
  health && break
  kill -0 "$server" 2>/dev/null || { tail -40 "$ROOT/logs/vllm-$SLURM_JOB_ID-$ROUTE.log"; exit 1; }
  sleep 2
done
health || { echo 'server health timed out'; exit 1; }
for arm in whole table cell; do
  "$FS_PY" "$ROOT/regions_cells.py" read --root "$ROOT" --route "$ROUTE" --arm "$arm" --runtime "$RUNTIME"
done
