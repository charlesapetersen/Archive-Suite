#!/bin/bash
# W46.ocr-family-coverage on Sherlock: one reader on one set, in process inside the vLLM image (MinerU: its overlay).
#   sbatch ... job.sh SH_DIR SET KEY      (SET 895 | 96)
# family_run.py reads with no server: the three-page pilot, then the set (on the 895, the key's own subset when
# setup wrote one: CHURRO's 455). The 96 run first takes the 895 run's cache-contract.json as its sweep-contract.json,
# so it refuses any difference in settings. A model setup skipped exits at once. With FAMILY_RESULTS set (submit.sh
# exports it), the finished session folder is copied there under SET/, so the batch's collect finds it in $GROUP_HOME.
set -euo pipefail
SH_DIR="$1"; SET="$2"; KEY="$3"; source "$SH_DIR/sh.env"
ROOT="$FS_ROOT/family-$SET"; SESSION_ROOT="$ROOT/$KEY"
P="$SESSION_ROOT/prepared.json"
"$FS_PY" -c 'import json,sys;sys.exit(json.load(open(sys.argv[1]))["state"] != "ready")' "$P" ||
  { echo "$KEY not ready:"; cat "$P"; exit 2; }
case "$SET" in
  895) MANIFEST=$("$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("manifest_895","public895.jsonl"))' "$P") ;;
  96) MANIFEST=truth99.jsonl ;;
  *) echo "SET 895 or 96"; exit 2 ;;
esac
if [ "$SET" = 96 ]; then
  C="$FS_ROOT/family-895/$KEY/cache-contract.json"
  [ -s "$C" ] || { echo "no 895 contract for $KEY"; exit 2; }
  cp "$C" "$SESSION_ROOT/sweep-contract.json"
fi
PY=$("$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["python"])' "$P")
mkdir -p "$SESSION_ROOT/logs"
apptainer -s exec --nv --bind "$SCRATCH,$GROUP_HOME" --env SESSION_ROOT="$SESSION_ROOT" --env HF_HOME="$HF_HOME" \
  --env HF_HUB_OFFLINE=1 --env TOKENIZERS_PARALLELISM=false --env PYTHONPATH="$SH_SHIM" "$SH_IMG" \
  "$PY" "$SH_DIR/family-coverage/family_run.py" "$MANIFEST"
# Best effort: the readings are complete in scratch, which the batch's collect also copies, so a failed copy must not
# fail the job (the 96 runs afterok the 895).
if [ -n "${FAMILY_RESULTS:-}" ]; then
  { mkdir -p "$FAMILY_RESULTS/$SET" && cp -r "$SESSION_ROOT" "$FAMILY_RESULTS/$SET/"; } ||
    echo "results copy failed; the session is in $SESSION_ROOT" >&2
fi
