#!/bin/bash
# S-051: run the real Process Files batch submission twice with one synthetic image.
# A loopback stand-in sends either an explicit 401 or an incomplete success reply.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"
set -euo pipefail
cd "$(dirname "$0")/.."

bin="$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$bin" ] || { echo "ArchiveProcessor Debug build is required" >&2; exit 1; }
work=$(mktemp -d)
source "$PWD/scripts/test-child.sh"
processor_test_init "$work"
mkdir "$work/input"
magick -size 320x240 xc:white -fill black -draw 'rectangle 40,40 200,100' "$work/input/scan.jpg"

cat >"$work/stand-in.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

outcome = sys.argv[1]

class StandIn(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        if outcome == "refused":
            status = 401
            body = b'{"error":{"message":"Synthetic authorization refusal"}}'
            length = len(body)
        else:
            status = 200
            body = b'{"name":'
            length = len(body) + 100
        print(f"POST {outcome} {status}")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Connection", "close")
        self.send_header("Content-Length", str(length))
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def log_message(self, *_):
        pass

with HTTPServer(("127.0.0.1", 0), StandIn) as server:
    print(server.server_port)
    server.serve_forever()
PY

for outcome in refused cut-off; do
    out="$work/$outcome"
    mkdir -p "$out/state" "$out/backup" "$out/home"
    processor_test_start server python3 -u "$work/stand-in.py" "$outcome" >"$out/wire.log"
    for ((i=0; i<50; i++)); do
        [ -s "$out/wire.log" ] && break
        sleep 0.1
    done
    port=$(head -1 "$out/wire.log")
    [[ "$port" =~ ^[0-9]+$ ]] || { echo "Loopback stand-in failed to start" >&2; exit 1; }
    CFFIXED_USER_HOME="$out/home" \
    ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$out/backup" \
        BATCHRESUME_TEST=1 ARCHIVEPROC_TEST_STATE_ROOT="$out/state" \
        PROCESSFILES_TESTMODE=1 PROCESSFILES_TESTKEY=stand-in-key \
        PROCESSFILES_PROVIDER=Gemini PROCESSFILES_MODEL=gemini-3.8-flash \
        PROCESSFILES_BATCH=1 PROCESSFILES_TAGGING=none PROCESSFILES_ROTATION=off \
        PROCESSFILES_TESTIN="$work/input" PROCESSFILES_TESTOUT="$out" \
        PROCESSFILES_TESTDONE="$out/DONE.txt" PROCESSFILES_MAXIMAGES=1 \
        PROCESSFILES_METER=1 PROCESSFILES_CAP_USD=1 \
        PROCESSFILES_REDIRECT_URL="http://127.0.0.1:$port/create" \
        processor_test_start app "$bin" -rotationDefaultMigratedV1 YES -contextRemovedMigratedV1 YES >"$out/app.log" 2>&1
    for ((i=0; i<90; i++)); do
        [ ! -e "$out/state/pending_batch.json" ] && [ -f "$out/DONE.txt" ] && break
        sleep 1
    done
    processor_test_stop "$app"
    processor_test_stop "$server"

    set -- "$out"/run-*
    run="$1"
    if [ ! -f "$run/status.txt" ] || [ ! -f "$run/batch-recovery.tsv" ]; then
        cat "$out/DONE.txt" 2>/dev/null || true
        tail -30 "$out/app.log"
        exit 1
    fi
    [ "$(grep -c ':batchGenerateContent' "$run/requests.tsv")" -eq 1 ]
    [ "$(wc -l < "$out/wire.log" | tr -d ' ')" -eq 2 ]
    [ -z "$(find "$run" -name '*.pdf' -print -quit)" ]
    tail -n +2 "$out/wire.log"
    cat "$run/status.txt" "$run/batch-recovery.tsv"
    grep -F 'paid-batch submission interrupted:' "$out/app.log" || true
done
