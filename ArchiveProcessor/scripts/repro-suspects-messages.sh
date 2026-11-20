#!/bin/bash
# repro-suspects-messages.sh — W49.proc-suspects-messages: the Processor's five misleading-message suspects
# (verification/SUSPECTS.md S-024, S-025, S-018, S-029, S-030), one reproduce attempt each under phase rule 5a.
# S-018, S-025, S-029 and S-030 are real Process Files runs through `startProcessing` (PROCESSFILES_TESTMODE) on synthetic
# scratch images; S-024 runs the key wizard's and the key row's own code in a headless launch (KeyWizardTestDriver).
# Nothing leaves the Mac: the gateway goes to the stand-in (scripts/fake_gateway.py) on 127.0.0.1, every other request
# is sent there too (PROCESSFILES_REDIRECT_URL), and the Local Agent CLI is a stub script in the scratch folder. $0.
#
#   ./scripts/repro-suspects-messages.sh [s024|s025|s018|s029|s030]...   (default: all five)
#
# Each case prints what it measured and a verdict line `CASE <name>: ...`. It never reads or writes anything outside a
# fresh mktemp directory; the run log of s030 is switched on for that launch only (`-writeLogFile YES`, the argument
# domain, which writes nothing to the app's defaults).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
BIN="$REPO/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$BIN" ] || { echo "ArchiveProcessor is not built (macOS/build/DD)" >&2; exit 1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ap-messages.XXXXXX")
echo "scratch: $WORK"
source "$REPO/scripts/test-child.sh"
processor_test_init "$WORK"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
CASES=("$@"); [ ${#CASES[@]} -eq 0 ] && CASES=(s024 s025 s018 s029 s030)

mkdir -p "$WORK/in" "$WORK/rot" "$WORK/tree/a" "$WORK/tree/b"
for i in 1 2; do
    magick -size 600x400 xc:white -fill black -draw "rectangle 40,40 $((100 + i * 60)),$((80 + i * 30))" "$WORK/in/p$i.jpg"
done
# S-029: a page of printed lines, turned 90, 180 and 270 degrees clockwise (so it needs 270, 180 and 90 to stand up).
magick -size 1200x1600 xc:white -fill black -font Helvetica -pointsize 44 \
    -annotate +80+160 'WAR DEPARTMENT, WASHINGTON' -annotate +80+260 'March 12, 1918. Memorandum for the Chief' \
    -annotate +80+340 'of Staff. Subject: the reorganization of the' -annotate +80+420 'Military Intelligence Section, its duties' \
    -annotate +80+500 'and the officers assigned to it this month.' -annotate +80+580 'The section will report to the Chief daily.' \
    "$WORK/upright.jpg"
for d in 90 180 270; do magick "$WORK/upright.jpg" -rotate "$d" "$WORK/rot/turned-$d.jpg"; done
# S-030: two failing files with the same name, in two folders.
cp "$WORK/in/p1.jpg" "$WORK/tree/a/same.jpg"
cp "$WORK/in/p2.jpg" "$WORK/tree/b/same.jpg"

LAST=""   # the run folder of the last case
APPARGS=()
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
        "PROCESSFILES_REDIRECT_URL=http://127.0.0.1:$PORT/v1/chat/completions"
        "PROCESSFILES_TESTIN=$WORK/in" "PROCESSFILES_TESTOUT=$out" "PROCESSFILES_TESTDONE=$out/DONE.txt"
        PROCESSFILES_MAXIMAGES=2 "$@")
    for kv in "${vars[@]}"; do export "$kv"; done
    processor_test_start pid "$BIN" ${APPARGS[@]+"${APPARGS[@]}"} >"$out/app.log" 2>&1
    for kv in "${vars[@]}"; do unset "${kv%%=*}"; done
    local i
    for i in $(seq 1 240); do [ -f "$out/DONE.txt" ] && break; sleep 1; done
    processor_test_stop "$pid"
    kill "$gw" 2>/dev/null; wait "$gw" 2>/dev/null
    rm -f "$HOME/Library/Application Support/ArchiveProcessor/pending_run.json"
    LAST=$(ls -d "$out"/run-* 2>/dev/null | head -1)
    echo "── $name   driver: $(cat "$out/DONE.txt" 2>/dev/null || echo '(timed out)')"
    [ -n "$LAST" ] && echo "  status: $(cat "$LAST/status.txt" 2>/dev/null)"
    echo "  stand-in calls: $(cut -f1 "$out/gateway.log" 2>/dev/null | sort | uniq -c | awk '{printf "%s %s, ", $2, $1}')"
}
GW=("PROCESSFILES_GATEWAY_URL=http://127.0.0.1:$PORT/v1" PROCESSFILES_GATEWAY_MODEL=stand-in)

for c in "${CASES[@]}"; do case "$c" in
s024)   # The wizard's live check passed; the Keychain refuses the key (headless mode refuses every write).
    out="$WORK/s024"; mkdir -p "$out"
    export ARCHIVEPROC_HEADLESS=1 KEYWIZARD_TESTMODE=1 "KEYWIZARD_OUT=$out/keywizard.tsv"
    processor_test_start pid "$BIN" >"$out/app.log" 2>&1
    unset ARCHIVEPROC_HEADLESS KEYWIZARD_TESTMODE KEYWIZARD_OUT
    for i in $(seq 1 60); do [ -s "$out/keywizard.tsv" ] && break; sleep 1; done
    processor_test_stop "$pid"
    sed 's/^/  /' "$out/keywizard.tsv" 2>/dev/null
    echo "CASE s024: after a refused save the key row shows: $(awk -F'chip=' '{print $2}' "$out/keywizard.tsv" 2>/dev/null | sort -u | tr '\n' ' ')" \
         "over a field that is $(awk -F'field_after_reload=' '{split($2,a,"\t"); print a[1]}' "$out/keywizard.tsv" 2>/dev/null | sort -u | tr '\n' ' ')"
    ;;
s025)   # "Fill in OpenAI preset", then one page through the gateway, the request kept as the app built it.
    run_case s025-openai-preset PROCESSFILES_GATEWAY_PRESET=openai PROCESSFILES_MAXIMAGES=1
    sed 's/^/  request: /' "$LAST/requests.tsv" 2>/dev/null | grep -v '^  request: #'
    echo "CASE s025: the preset's gateway request: $(grep -v '^#' "$LAST/requests.tsv" 2>/dev/null | head -1 | cut -f1,4,5)"
    ;;
s018)   # The Local Agent CLI reports a usage limit with a reset 45 s ahead, and works from then on: Codex, then Claude.
    for tool in codex claude; do
        stub="$WORK/stub-$tool"
        cat >"$stub" <<EOF
#!/bin/bash
# A stand-in $tool CLI: a usage limit until 45 s after its first call, then a transcription. Each call is logged.
now=\$(date +%s)
[ -f "$WORK/s018-$tool.first" ] || echo "\$now" >"$WORK/s018-$tool.first"
reset=\$(( \$(cat "$WORK/s018-$tool.first") + 45 ))
cat >/dev/null
if [ "\$now" -lt "\$reset" ]; then
    echo "\$now limited" >>"$WORK/s018-$tool.calls"
    if [ "$tool" = claude ]; then
        echo '{"type":"result","is_error":true,"result":"Claude AI usage limit reached|'"\$reset"'"}'
    else
        echo "Error: usage limit reached|\$reset" >&2
    fi
    exit 1
fi
echo "\$now ok" >>"$WORK/s018-$tool.calls"
if [ "$tool" = claude ]; then
    echo '{"type":"result","is_error":false,"result":"[document_start]\\n[rotate_0]\\nStand-in transcription."}'
else
    printf '[document_start]\n[rotate_0]\nStand-in transcription.\n'
fi
EOF
        chmod +x "$stub"
        run_case "s018-$tool" "PROCESSFILES_LOCALAGENT=$tool:$stub" PROCESSFILES_MAXIMAGES=1
        first=$(cat "$WORK/s018-$tool.first" 2>/dev/null || echo 0)
        echo "  CLI calls (seconds after the first): $(awk -v f="$first" '{printf "%s@%ds ", $2, $1 - f}' "$WORK/s018-$tool.calls" 2>/dev/null)"
        grep -h -o 'usage limit reached[^"]*' "$WORK/s018-$tool/app.log" 2>/dev/null | sort -u | head -2 | sed 's/^/  app said: /'
        echo "  pages: $(grep -v '^#' "$LAST/manifest.tsv" 2>/dev/null | cut -f3 | sort | uniq -c | awk '{printf "%s %s, ", $2, $1}')"
    done
    echo "CASE s018: codex CLI calls $(awk '{printf "%s ", $2}' "$WORK/s018-codex.calls" 2>/dev/null)→ $(cat "$WORK/s018-codex/DONE.txt" 2>/dev/null);" \
         "claude CLI calls $(awk '{printf "%s ", $2}' "$WORK/s018-claude.calls" 2>/dev/null)→ $(cat "$WORK/s018-claude/DONE.txt" 2>/dev/null)"
    ;;
s029)   # LLM rotation (one vote) on the gateway, every vote failing; then the default (agreement) the same way.
    for mode in llmSingle agreement; do
        FAKE_GATEWAY_FAIL_OTHER=1 run_case "s029-$mode" "${GW[@]}" "PROCESSFILES_TESTIN=$WORK/rot" \
            PROCESSFILES_MAXIMAGES=3 "PROCESSFILES_ROTATION=$mode"
        sed 's/^/  page: /' "$LAST/rotation.tsv" 2>/dev/null
        grep -o 'otat[^"]*' "$WORK/s029-$mode/app.log" 2>/dev/null | sort -u | head -5 | sed 's/^/  app.log: /'
    done
    echo "CASE s029: needed turned-90→270 turned-180→180 turned-270→90;" \
         "llmSingle gave $(cut -f1,2 "$WORK"/s029-llmSingle/run-*/rotation.tsv 2>/dev/null | sed 's/\.jpg\trotation=/→/' | tr '\n' ' ')" \
         "unsure=$(grep -c 'unsure=true' "$WORK"/s029-llmSingle/run-*/rotation.tsv 2>/dev/null);" \
         "agreement unsure=$(grep -c 'unsure=true' "$WORK"/s029-agreement/run-*/rotation.tsv 2>/dev/null)"
    ;;
s030)   # Two same-named files in two folders, every OCR call refused with a message naming the call; run log on.
    APPARGS=(-writeLogFile YES)
    FAKE_GATEWAY_FAIL_OCR=$(seq -s, 1 40) run_case s030-same-names "${GW[@]}" "PROCESSFILES_TESTIN=$WORK/tree" PROCESSFILES_TREE=1
    APPARGS=()
    grep -v '^ocr-400' "$WORK/s030-same-names/gateway.log" | head -3 | sed 's/^/  other call: /'
    log=$(grep -l 'OCR Log' "$LAST"/*.txt "$LAST"/*/*.txt 2>/dev/null | head -1)
    echo "  log: ${log:-none}"
    [ -n "$log" ] && grep -A3 'did not produce' "$log" | sed 's/^/  /'
    echo "CASE s030: the log's failure lines: $([ -n "$log" ] && grep '•' "$log" | grep -o 'call [0-9]*' | tr '\n' ' ')"
    ;;
*) echo "unknown case $c" >&2 ;;
esac; done
