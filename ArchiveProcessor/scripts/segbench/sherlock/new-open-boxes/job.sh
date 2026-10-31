#!/bin/bash
# W46.ocr-new-open-boxes on Sherlock: one box-emitting reader on one set, in its overlay venv inside the vLLM image.
#   sbatch ... job.sh SH_DIR SET KEY      (SET 895 | 96)
# boxes_run.py reads in process (no server): the three-page pilot, then the set. The 96 run first takes the 895 run's
# cache-contract.json as its sweep-contract.json, so it refuses any difference in settings. A model setup-job.sh
# skipped exits at once. With NEW_OPEN_RESULTS set (submit.sh exports it), the finished session folder is copied
# there under SET/, so the batch's collect finds it in $GROUP_HOME.
set -euo pipefail
SH_DIR="$1"; SET="$2"; KEY="$3"; source "$SH_DIR/sh.env"
ROOT="$FS_ROOT/new-open-boxes-$SET"; SESSION_ROOT="$ROOT/$KEY"
case "$SET" in 895) MANIFEST=public895.jsonl ;; 96) MANIFEST=truth99.jsonl ;; *) echo "SET 895 or 96"; exit 2 ;; esac
P="$SESSION_ROOT/prepared.json"
"$FS_PY" -c 'import json,sys;sys.exit(json.load(open(sys.argv[1]))["state"] != "ready")' "$P" ||
  { echo "$KEY not ready:"; cat "$P"; exit 2; }
if [ "$SET" = 96 ]; then
  C="$FS_ROOT/new-open-boxes-895/$KEY/cache-contract.json"
  [ -s "$C" ] || { echo "no 895 contract for $KEY"; exit 2; }
  cp "$C" "$SESSION_ROOT/sweep-contract.json"
fi
PY=$("$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["python"])' "$P")
mkdir -p "$SESSION_ROOT/logs"
apptainer -s exec --nv --bind "$SCRATCH,$GROUP_HOME" --env SESSION_ROOT="$SESSION_ROOT" --env HF_HOME="$HF_HOME" \
  --env HF_HUB_OFFLINE=1 --env TOKENIZERS_PARALLELISM=false --env PYTHONPATH="$SH_SHIM" "$SH_IMG" \
  "$PY" "$SH_DIR/new-open-boxes/boxes_run.py" "$MANIFEST"
# Best effort: the readings are complete in scratch, which the batch's collect also copies, so a failed copy must not
# fail the job (the 96 runs afterok the 895).
if [ -n "${NEW_OPEN_RESULTS:-}" ]; then
  { mkdir -p "$NEW_OPEN_RESULTS/$SET" && cp -r "$SESSION_ROOT" "$NEW_OPEN_RESULTS/$SET/"; } ||
    echo "results copy failed; the session is in $SESSION_ROOT" >&2
fi
