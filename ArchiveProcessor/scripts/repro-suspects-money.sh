#!/bin/bash
# repro-suspects-money.sh — W49.proc-suspects-money: the Processor's four spending suspects (verification/SUSPECTS.md
# S-039, S-032, S-026, S-027), one reproduce attempt each under phase rule 5a. Every case is a real Process Files run
# through `startProcessing` (PROCESSFILES_TESTMODE) on synthetic scratch images. Nothing leaves the Mac: the gateway
# route goes to the stand-in (scripts/fake_gateway.py) on 127.0.0.1, and a direct provider's requests are sent there
# instead of to the provider (PROCESSFILES_REDIRECT_URL), each recorded in requests.tsv as the app built it. $0.
#
#   ./scripts/repro-suspects-money.sh [s039|s032|s026|s027]...   (default: all four)
#
# Each case prints what it measured and a verdict line `CASE <name>: ...`. It never reads or writes anything outside a
# fresh mktemp directory (the Live Capture session of s039 included, under ARCHIVEPROC_TEST_BACKUP_ROOT).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
BIN="$REPO/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$BIN" ] || { echo "ArchiveProcessor is not built (macOS/build/DD)" >&2; exit 1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ap-money.XXXXXX")
echo "scratch: $WORK"
source "$REPO/scripts/test-child.sh"
processor_test_init "$WORK"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
CASES=("$@"); [ ${#CASES[@]} -eq 0 ] && CASES=(s039 s032 s026 s027)

mkdir -p "$WORK/in" "$WORK/big"
for i in 1 2 3 4 5 6; do
    magick -size 600x400 xc:white -fill black -draw "rectangle 40,40 $((100 + i * 60)),$((80 + i * 30))" "$WORK/in/p$i.jpg"
done
# S-026: a dense scan under the 2,048 px cap but over the 3 MB standard size, and a large one over both.
magick -size 2000x1500 xc: +noise Random -quality 100 "$WORK/big/a-dense.jpg"
magick -size 6000x4000 xc: +noise Random -quality 92 "$WORK/big/b-large.jpg"
ls -l "$WORK/big" | awk 'NR>1 {print "  input " $NF ": " $5 " bytes"}'

LAST=""   # the run folder of the last case
run_case() {   # name env...
    local name="$1"; shift
    local out="$WORK/$name"
    mkdir -p "$out"
    python3 "$REPO/scripts/fake_gateway.py" "$PORT" "$out/gateway.log" 500 stand-in-key &
    local gw=$!
    sleep 1
    local kv vars=(ARCHIVEPROC_HEADLESS=1 "ARCHIVEPROC_TEST_BACKUP_ROOT=$WORK/backup"
        PROCESSFILES_TESTMODE=1 PROCESSFILES_TESTKEY=stand-in-key
        PROCESSFILES_METER=1 PROCESSFILES_CAP_USD=100 PROCESSFILES_TAGGING=none
        "PROCESSFILES_TESTIN=$WORK/in" "PROCESSFILES_TESTOUT=$out" "PROCESSFILES_TESTDONE=$out/DONE.txt"
        PROCESSFILES_MAXIMAGES=6 "$@")
    for kv in "${vars[@]}"; do export "$kv"; done
    processor_test_start pid "$BIN" >"$out/app.log" 2>&1
    for kv in "${vars[@]}"; do unset "${kv%%=*}"; done
    local i
    for i in $(seq 1 180); do [ -f "$out/DONE.txt" ] && break; sleep 1; done
    processor_test_stop "$pid"
    kill "$gw" 2>/dev/null; wait "$gw" 2>/dev/null
    rm -f "$HOME/Library/Application Support/ArchiveProcessor/pending_run.json"
    LAST=$(ls -d "$out"/run-* 2>/dev/null | head -1)
    echo "── $name   driver: $(cat "$out/DONE.txt" 2>/dev/null || echo '(timed out)')"
    [ -n "$LAST" ] && echo "  status: $(cat "$LAST/status.txt" 2>/dev/null)"
    [ -n "$LAST" ] && echo "  estimate: $(cat "$LAST/estimate.txt" 2>/dev/null)"
    echo "  stand-in calls: $(cut -f1 "$out/gateway.log" 2>/dev/null | sort | uniq -c | awk '{printf "%s %s, ", $2, $1}')"
}
GW=("PROCESSFILES_GATEWAY_URL=http://127.0.0.1:$PORT/v1" PROCESSFILES_GATEWAY_MODEL=stand-in)
REDIRECT="PROCESSFILES_REDIRECT_URL=http://127.0.0.1:$PORT/v1/chat/completions"
ocr_calls() { grep -c '^ocr' "$WORK/$1/gateway.log" 2>/dev/null || echo 0; }

for c in "${CASES[@]}"; do case "$c" in
s039)   # Stage for later: "Process N →", a run, then the button again; then a relaunch and the button again.
    run_case s039-first "${GW[@]}" PROCESSFILES_STAGED=1 "ARCHIVEPROC_TEST_BACKUP_ROOT=$WORK/backup-s039"
    first="$LAST"; cat "$first/handoff.tsv" 2>/dev/null | sed 's/^/  /'
    run_case s039-relaunch "${GW[@]}" PROCESSFILES_STAGED=1 "ARCHIVEPROC_TEST_BACKUP_ROOT=$WORK/backup-s039"
    cat "$LAST/handoff.tsv" 2>/dev/null | sed 's/^/  /'
    echo "CASE s039: first run OCRed $(ocr_calls s039-first) photo(s); after the run the pane would hand over" \
         "$(awk -F'files=' '/^after-run/ {print $2}' "$first/handoff.tsv") again; the relaunched app handed over" \
         "$(awk -F'files=' '/^handoff/ {print $2}' "$LAST/handoff.tsv") and OCRed $(ocr_calls s039-relaunch) more"
    ;;
s032)   # Gemini only in the chooser, no Gemini key; three pages on the stand-in's OCR route.
    run_case s032-gemini-nokey "${GW[@]}" PROCESSFILES_SEGAPPROACH=gemini PROCESSFILES_MAXIMAGES=3 PROCESSFILES_TAGGING=automatic
    cat "$LAST/gates.tsv" 2>/dev/null | sed 's/^/  gate: /'
    echo "CASE s032: $(ocr_calls s032-gemini-nokey) OCR call(s) were sent; the window stage asked:" \
         "$(grep '^windowStop' "$LAST/gates.tsv" 2>/dev/null | cut -f2- || echo 'never')"
    ;;
s026)   # The same two scans at 100%: Gemini direct, then Gemini batch, both redirected to the stand-in.
    for mode in direct batch; do
        extra=(); [ "$mode" = batch ] && extra=(PROCESSFILES_BATCH=1)
        run_case "s026-$mode" PROCESSFILES_PROVIDER=Gemini PROCESSFILES_MODEL=gemini-3.8-flash "$REDIRECT" \
            "PROCESSFILES_TESTIN=$WORK/big" PROCESSFILES_MAXIMAGES=2 ${extra[@]+"${extra[@]}"}
        sed 's/^/  request: /' "$LAST/requests.tsv" 2>/dev/null
        eval "REQ_$mode=\$LAST/requests.tsv"
    done
    python3 - "$REQ_direct" "$REQ_batch" <<'EOF'
import re, sys
def images(p):
    out = []
    for line in open(p):
        m = re.search(r'\timages=([^\t]+)', line)
        if m:
            out += m.group(1).split(',')
    return sorted(out, key=lambda s: int(s.split(':')[0]))
print(f'CASE s026: direct sent {images(sys.argv[1])}; batch sent {images(sys.argv[2])} (bytes:pixels)')
EOF
    ;;
s027)   # OpenAI, every page given a gpt-5-nano reader, the stored Batch flag off and on.
    for flag in off on; do
        extra=(); [ "$flag" = on ] && extra=(PROCESSFILES_BATCH_STORED=1)
        run_case "s027-batch-$flag" PROCESSFILES_PROVIDER=OpenAI PROCESSFILES_MODEL=gpt-5.4-mini "$REDIRECT" \
            PROCESSFILES_READER_MODEL=gpt-5-nano PROCESSFILES_MAXIMAGES=4 ${extra[@]+"${extra[@]}"}
        echo "  OCR calls by model: $(awk -F'\t' '/^ocr/ {print $2}' "$WORK/s027-batch-$flag/gateway.log" | sort | uniq -c | awk '{printf "%s %s, ", $2, $1}')"
    done
    echo "CASE s027: batch flag off, OCR models: $(awk -F'\t' '/^ocr/ {print $2}' "$WORK/s027-batch-off/gateway.log" | sort -u | tr '\n' ' ');" \
         "on: $(awk -F'\t' '/^ocr/ {print $2}' "$WORK/s027-batch-on/gateway.log" | sort -u | tr '\n' ' ')"
    ;;
*) echo "unknown case $c" >&2 ;;
esac; done
