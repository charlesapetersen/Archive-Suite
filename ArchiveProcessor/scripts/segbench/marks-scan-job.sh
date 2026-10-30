#!/bin/bash
# One reader over the frozen scan pages. Requests stop at --deadline so the
# exit copy runs inside the 3-hour limit; unread pages wait for a later job.
set -euo pipefail
ROOT="$1"
: "${SLURM_JOB_ID:?must be a Slurm job}"
source "$ROOT/support/sherlock/sh.env"
export HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
mkdir -p "$ROOT/logs" "$ROOT/runtime"
"$FS_PY" "$ROOT/support/marks_scan.py" check --root "$ROOT"
# One reader per pack: a second job on this ROOT would turn the first one's
# in-flight request into "interrupted" and lose its reply.
exec 9> "$ROOT/logs/read.lock"
flock -n 9 || { echo 'another job is reading this pack'; exit 2; }
CACHE="$HF_HOME/hub/models--Qwen--Qwen3.6-27B-FP8"
if [ -f "$CACHE/refs/main" ]; then revision=$(cat "$CACHE/refs/main")
else
  snapshots=("$CACHE"/snapshots/*)
  [ "${#snapshots[@]}" -eq 1 ] || { echo 'missing/ambiguous cached revision'; exit 2; }
  revision="$(basename "${snapshots[0]}")"
fi
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { echo 'invalid snapshot revision'; exit 2; }
MODEL="$CACHE/snapshots/$revision"
[ -f "$MODEL/config.json" ] || { echo 'incomplete model snapshot'; exit 2; }
RUNTIME="$ROOT/runtime/$SLURM_JOB_ID.json"
"$FS_PY" "$ROOT/support/marks_scan.py" runtime --root "$ROOT" --revision "$revision" --out "$RUNTIME"
read -r -a ARGS <<< "$("$FS_PY" -c 'import sys;sys.path.insert(0,sys.argv[1]);import marks_scan as M;print(" ".join(M.VLLM_ARGS))' "$ROOT/support")"
NAME=$("$FS_PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["served"])' "$RUNTIME")
# A free local port plus a per-job served name keeps another server from
# satisfying readiness and being attributed to this job's cached snapshot.
PORT=$(python3 - <<'PY'
import socket
with socket.socket() as s:
 s.bind(('127.0.0.1',0)); print(s.getsockname()[1])
PY
)
URL="http://127.0.0.1:$PORT"
server=''
finish() {
  rc=$?; trap - EXIT
  if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi
  saved="$GROUP_HOME/$USER/archive-suite/sherlock-results/marks-scan-20261029"
  mkdir -p "$saved"
  for folder in out intents runtime logs; do
    if [ -d "$ROOT/$folder" ]; then mkdir -p "$saved/$folder"; rsync -a "$ROOT/$folder/" "$saved/$folder/"; fi
  done
  cp "$ROOT/freeze.json" "$saved/freeze.json"
  exit "$rc"
}
trap finish EXIT
"$FS_VLLM" serve "$MODEL" --served-model-name "$NAME" --host 127.0.0.1 --port "$PORT" "${ARGS[@]}" > "$ROOT/logs/vllm-$SLURM_JOB_ID.log" 2>&1 &
server=$!
health() { python3 - "$URL" "$NAME" <<'PY'
import json,sys,urllib.request
try:
 class NoRedirect(urllib.request.HTTPRedirectHandler):
  def redirect_request(self,*args): raise ValueError('redirect')
 opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect())
 with opener.open(sys.argv[1]+'/v1/models',timeout=2) as r:
  assert sys.argv[2] in [m['id'] for m in json.load(r)['data']]
except Exception: sys.exit(1)
PY
}
for ((i=0;i<180;i++)); do
  kill -0 "$server" 2>/dev/null || { tail -40 "$ROOT/logs/vllm-$SLURM_JOB_ID.log"; exit 1; }
  if health; then kill -0 "$server" 2>/dev/null && break; fi
  sleep 2
done
health || { echo 'vLLM health timed out'; exit 1; }
kill -0 "$server" 2>/dev/null || { echo 'owned server exited'; exit 1; }
"$FS_PY" "$ROOT/support/marks_scan.py" read --root "$ROOT" --url "$URL" --runtime "$RUNTIME" --deadline 9300
"$FS_PY" "$ROOT/support/marks_scan.py" summary --root "$ROOT" > "$ROOT/logs/scan-summary.json"
