#!/bin/bash
set -euo pipefail
ROOT="$1"
KEY="$2"
source /home/users/cp1/Archive-Suite/ArchiveProcessor/scripts/segbench/farmshare/fs.env
export HF_HOME
export SESSION_ROOT="$ROOT/$KEY"
PREPARED="$SESSION_ROOT/prepared.json"
if ! "$FS_PY" -c 'import json,sys;sys.exit(json.load(open(sys.argv[1]))["state"] != "ready")' "$PREPARED"; then
  echo "Preparation unavailable/skipped for $KEY; inspect prepared.json and setup log."
  exit 2
fi
SNAPSHOT=$("$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["snapshot"])' "$PREPARED")
exec /bin/bash /scratch/users/cp1/fs-ocr/interactive-20261018/serve.sh "$SNAPSHOT" "$KEY" \
  "$FS_PY" "$ROOT/recovery/open_sweep_run.py"
