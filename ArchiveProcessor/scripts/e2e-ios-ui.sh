#!/usr/bin/env bash
# ============================================================================
# The iPhone companion's own controls, pressed by touch, against the real Mac (W40.i-sim-ui).
#
# `e2e-phone-mac.sh --ios` proves the upload path but presses no button: the app's DEBUG driver calls the
# actions. This script runs `ArchiveCaptureiOSUITests` (XCUITest, real taps) in the same headless simulator
# (ios-sim-drive.sh boot: `simctl boot`, Simulator.app never opened) against the same real headless Mac, and
# serves what the tests ask for through files in $RUN/ctl:
#   mac-stop / mac-start   stop the Mac session and start it again (same fixed port 48627 and saved token)
#   segment-tagged         finalize the session on the Mac and read the filed PDF's Finder tags
#   mark <label>           log the moment, with how many photos the Mac has received so far
# Before the tests it opens a port with nothing listening and a server that answers /ping with 404, for the
# connect diagnostics. The camera is a feed directory of the e2e fixtures (E2EHarness `ARCHIVECAP_UITEST_FEED`).
#
#   caffeinate -di ArchiveProcessor/scripts/e2e-ios-ui.sh      # E2E_RUNDIR=/tmp/ap-e2e-… to name the run dir
#
# Real OCR (the pinned Gemini Flash-Lite route of e2e-phone-mac.sh, a few cents a run). Output only under the
# run dir. The LAN token reaches the test runner in its environment, never argv, and is redacted from every
# kept log; the xcresult bundle (which records typed text) is deleted unless KEEP_XCRESULT=1.
# Exit 0 = every test passed and the Mac-side checks held. Evidence: $RUN/REPORT.txt, $RUN/ctl/shots/.
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IOSROOT="$(cd "$HERE/../ArchiveCaptureiOS" && pwd)"
APPROOT="$(cd "$HERE/../macOS" && pwd)"
FIXTURES="$HERE/e2e-fixtures"
BUNDLE=com.archiveprocessor.capture.ios
export PATH="/opt/homebrew/bin:$PATH"

RUN="${E2E_RUNDIR:-/tmp/ap-e2e-ui-$$}"
case "$RUN" in /tmp/ap-e2e-*/*|/tmp/ap-e2e-) echo "E2E_RUNDIR must be one /tmp/ap-e2e-* directory" >&2; exit 2;;
  /tmp/ap-e2e-*) ;; *) echo "E2E_RUNDIR must be a /tmp/ap-e2e-* path" >&2; exit 2;; esac
umask 077
mkdir "$RUN" || { echo "cannot claim fresh run dir $RUN" >&2; exit 2; }
CTL="$RUN/ctl"; FEED="$RUN/feed"; REPORT="$RUN/REPORT.txt"; READYFILE="$RUN/ready.txt"
mkdir -p "$CTL/shots" "$FEED" "$RUN/out1" "$RUN/out2"

log(){ printf '\033[35m[ui]\033[0m %s\n' "$*" | tee -a "$REPORT"; }
MAC_PID=""; REFUSE_PID=""; XCB_PID=""; TOKEN=""; PORT=""; MACN=0; TESTOUT=""; FAILS=0
fail(){ log "FAIL: $*"; FAILS=$((FAILS+1)); }

# --- the Mac: the same pinned headless session as e2e-phone-mac.sh §2 (keep the two in step) -----------
KEY="${OCR_KEY:-$(security find-generic-password -s com.archiveprocessor.app -a Gemini -w 2>/dev/null)}"
[ -n "$KEY" ] || { echo "no OCR key (OCR_KEY or the Keychain's Gemini entry)" >&2; exit 1; }
start_mac(){   # $1 = output dir
  MACN=$((MACN+1)); TESTOUT="$1"; rm -f "$READYFILE"
  ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$RUN/backup" LIVECAPTURE_AUTOSTART=1 \
  LIVECAPTURE_TRANSPORT=lan LIVECAPTURE_READYFILE="$READYFILE" LIVECAPTURE_OCRKEY="$KEY" \
  LIVECAPTURE_AUTOSKIPTAGS=1 LIVECAPTURE_AUTOFINALIZE=1 LIVECAPTURE_TESTOUT="$TESTOUT" \
  python3 -c 'import os, signal, sys; signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM}); os.execv(sys.argv[1], sys.argv[1:])' \
    "$MACBIN" -liveProcessingMode live \
    -selectedProvider Gemini -selectedModelId_Gemini gemini-2.5-flash-lite \
    -selectedThinking Low -useAppleVision NO -visionUseLLMJudgment NO \
    -useGateway NO -useLocalAgent NO -taggingModeRaw automatic \
    -rotationModeRaw off -reviewRotation NO -mergeDocuments NO \
    -imageResolutionPercent 100 -standardImageSizeMB 3 \
    -customOCRPrompt '' -tagVocabulary '' -outputDirectory "$TESTOUT" \
    >"$RUN/mac$MACN.log" 2>&1 &
  MAC_PID=$!
  local line p t
  for _ in $(seq 1 60); do grep -q '^LIVECAPTURE_READY port=' "$READYFILE" 2>/dev/null && break; sleep 0.5; done
  line="$(grep '^LIVECAPTURE_READY port=' "$READYFILE" 2>/dev/null | head -1)"
  sed -i '' -E 's/token=[^ ]+/token=[REDACTED]/g' "$READYFILE" 2>/dev/null
  p="$(printf '%s\n' "$line" | sed -n 's/.* port=\([0-9][0-9]*\).*/\1/p')"
  t="$(printf '%s\n' "$line" | sed -n 's/.* token=\([^ ]*\).*/\1/p')"
  [ -n "$p" ] && [ "${#t}" -ge 32 ] || { fail "Mac #$MACN gave no READY line"; return 1; }
  if [ -n "$PORT" ] && { [ "$p" != "$PORT" ] || [ "$t" != "$TOKEN" ]; }; then
    fail "Mac #$MACN came back on another port or token (port $p, was $PORT): the phone's saved pairing is stale"; return 1
  fi
  PORT="$p"; TOKEN="$t"; log "Mac #$MACN listening on $PORT (pid $MAC_PID, output $(basename "$TESTOUT"))"
}
stop_mac(){
  [ -n "$MAC_PID" ] || return 0
  kill -TERM "$MAC_PID" 2>/dev/null
  for _ in $(seq 1 100); do kill -0 "$MAC_PID" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$MAC_PID" 2>/dev/null && { log "Mac #$MACN ignored TERM; KILL"; kill -KILL "$MAC_PID" 2>/dev/null; }
  wait "$MAC_PID" 2>/dev/null; MAC_PID=""; log "Mac #$MACN stopped"
}
received(){ find "$RUN/backup" -name '*.jpg' 2>/dev/null | wc -l | tr -d ' '; }
finalize_mac(){   # session complete → DONE.txt in the current output dir
  local code
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl --config - -s -o /dev/null -w '%{http_code}' \
    -X POST "http://127.0.0.1:$PORT/session/complete")
  [ "$code" = 200 ] || { fail "/session/complete returned $code"; return 1; }
  for _ in $(seq 1 300); do [ -f "$TESTOUT/DONE.txt" ] && break; sleep 1; done
  [ -f "$TESTOUT/DONE.txt" ] || { fail "no DONE.txt in $(basename "$TESTOUT") after 300 s"; return 1; }
  log "finalized: $(tr '\n' ' ' < "$TESTOUT/DONE.txt")"
}
pdf_tags(){   # print each PDF under $1 with its Finder tags
  python3 - "$1" <<'PY'
import glob, os, sys
sys.path.insert(0, os.environ["HERE"])
from finder_tags import read_tags
for p in sorted(glob.glob(os.path.join(sys.argv[1], "**", "*.pdf"), recursive=True)):
    names, _label, status = read_tags(p)
    print(f"{os.path.relpath(p, sys.argv[1])}\t{status}\t{','.join(names)}")
PY
}
export HERE

cleanup(){
  local s=$?
  trap - EXIT
  [ -n "$XCB_PID" ] && kill "$XCB_PID" 2>/dev/null
  [ -n "$REFUSE_PID" ] && kill "$REFUSE_PID" 2>/dev/null
  stop_mac >/dev/null 2>&1
  [ "${KEEP_XCRESULT:-0}" = 1 ] || rm -rf "$RUN/ui.xcresult"
  for f in "$RUN"/*.log "$REPORT"; do [ -f "$f" ] && [ -n "$TOKEN" ] && sed -i '' "s/$TOKEN/[REDACTED]/g" "$f"; done
  [ "${KEEP_SIM:-0}" = 1 ] || bash "$HERE/ios-sim-drive.sh" shutdown
  exit "$s"
}
trap cleanup EXIT

# --- 1. builds ----------------------------------------------------------------------------------------
log "run dir: $RUN"
log "building the Mac app (Debug)…"
( cd "$APPROOT" && xcodegen generate >/dev/null && \
  xcodebuild -scheme ArchiveProcessor -configuration Debug -derivedDataPath ./build/DD build >"$RUN/build-mac.log" 2>&1 ) \
  || { log "FAIL: Mac build (see build-mac.log)"; exit 1; }
MACBIN="$APPROOT/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
bash "$HERE/ios-sim-drive.sh" boot || { log "FAIL: simulator boot"; exit 1; }
U="$(xcrun simctl list devices -j | python3 -c 'import json,sys
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"] == (sys.argv[1]) and d["state"] == "Booted": print(d["udid"])' "${IOS_E2E_DEVICE:-ap-e2e-iphone}")"
[ -n "$U" ] || { log "FAIL: no booted E2E device"; exit 1; }
log "building the iPhone app and its UI tests for the simulator…"
( cd "$IOSROOT" && xcodegen generate >/dev/null && \
  xcodebuild build-for-testing -scheme ArchiveCaptureiOS -destination "id=$U" -configuration Debug \
    -derivedDataPath ./build/DD >"$RUN/build-ios.log" 2>&1 ) || { log "FAIL: iOS build-for-testing (see build-ios.log)"; exit 1; }
APP="$IOSROOT/build/DD/Build/Products/Debug-iphonesimulator/ArchiveCaptureiOS.app"
xcrun simctl terminate "$U" "$BUNDLE" >/dev/null 2>&1; xcrun simctl uninstall "$U" "$BUNDLE" >/dev/null 2>&1
xcrun simctl install "$U" "$APP" || { log "FAIL: install"; exit 1; }
xcrun simctl privacy "$U" grant camera "$BUNDLE" >/dev/null 2>&1 || log "WARN: camera grant failed"
log "installed $BUNDLE fresh (no pairing, empty queue)"

# --- 2. the Mac, a dead port, a 404 server, the feed ---------------------------------------------------
start_mac "$RUN/out1" || exit 1
free_port(){ python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
DEAD="$(free_port)"; REFUSE="$(free_port)"
mkdir -p "$RUN/empty"
( cd "$RUN/empty" && exec python3 -m http.server "$REFUSE" --bind 127.0.0.1 ) >"$RUN/refuse.log" 2>&1 &
REFUSE_PID=$!
log "nothing listens on $DEAD; /ping answers 404 on $REFUSE"
i=0; for n in $(seq 1 8); do for f in doc1_memo doc2_letter doc3_report; do i=$((i+1)); cp "$FIXTURES/$f.jpg" "$FEED/$(printf '%03d' $i)-$f.jpg"; done; done
log "feed: $i fixture copies"

# --- 3. the UI tests, with the control loop ------------------------------------------------------------
( cd "$IOSROOT" && TEST_RUNNER_E2E_CTL="$CTL" TEST_RUNNER_E2E_FEED="$FEED" TEST_RUNNER_E2E_PORT="$PORT" \
  TEST_RUNNER_E2E_DEAD_PORT="$DEAD" TEST_RUNNER_E2E_REFUSE_PORT="$REFUSE" TEST_RUNNER_E2E_TOKEN="$TOKEN" \
  exec xcodebuild test-without-building -scheme ArchiveCaptureiOS -destination "id=$U" -derivedDataPath ./build/DD \
    -only-testing:ArchiveCaptureiOSUITests -collect-test-diagnostics never -resultBundlePath "$RUN/ui.xcresult" ) >"$RUN/xcodebuild.log" 2>&1 &
XCB_PID=$!
log "UI tests running (pid $XCB_PID)"
answer(){ printf '%s' "$2" > "$CTL/ack-$1"; }
# The xcodebuild shim runs the test under heavy-run.py, which holds the Mac heavy lock until every process in
# its child session has exited. A simulator test leaves DTServiceHub in that session after xcodebuild exits,
# which held the lock for 8.5 h on 2026-10-22 (W40.fix-heavy-run-xcode-helpers, the real fix). Until that
# lands: note the session while xcodebuild runs, and once the log says the tests are over, end the Xcode and
# simulator helpers left in it, by name, and log each one.
XSID=""; ENDED_AT=0
xcode_sid(){ python3 - "$XCB_PID" <<'PY'
import os, subprocess, sys
root = int(sys.argv[1]); kids = {}
for line in subprocess.run(["ps", "-ax", "-o", "pid=,ppid=,comm="], capture_output=True, text=True).stdout.splitlines():
    f = line.split(None, 2)
    if len(f) == 3: kids.setdefault(int(f[1]), []).append((int(f[0]), f[2]))
todo = [root]
while todo:
    for pid, comm in kids.get(todo.pop(), []):
        if comm.endswith("/xcodebuild"):
            try: print(os.getsid(pid)); sys.exit(0)
            except ProcessLookupError: pass
        todo.append(pid)
PY
}
end_helpers(){ python3 - "$1" <<'PY'
import os, re, signal, subprocess, sys
sid = int(sys.argv[1])
for line in subprocess.run(["ps", "-ax", "-o", "pid=,comm="], capture_output=True, text=True).stdout.splitlines():
    f = line.split(None, 1)
    if len(f) != 2: continue
    pid, comm = int(f[0]), f[1]
    try:
        if os.getsid(pid) != sid: continue
    except ProcessLookupError: continue
    if re.search(r"DTServiceHub|CoreSimulator|simctl|XCTest|Instruments|SimulatorTrampoline", comm):
        print(f"ended {pid} {comm}"); os.kill(pid, signal.SIGTERM)
    else:
        print(f"left {pid} {comm}")
PY
}
while kill -0 "$XCB_PID" 2>/dev/null; do
  [ -n "$XSID" ] || XSID="$(xcode_sid 2>/dev/null)"
  if [ -n "$XSID" ] && grep -qE '^\*\* TEST (SUCCEEDED|FAILED|EXECUTE (SUCCEEDED|FAILED))|^Testing failed:' "$RUN/xcodebuild.log" 2>/dev/null; then
    [ "$ENDED_AT" = 0 ] && ENDED_AT=$(date +%s)
    if [ $(( $(date +%s) - ENDED_AT )) -ge 20 ]; then
      log "tests over but xcodebuild's session lives on: ending its Xcode helpers"
      bash "$HERE/ios-sim-drive.sh" shutdown
      end_helpers "$XSID" | tee -a "$REPORT"; ENDED_AT=$(( $(date +%s) + 40 ))
    fi
  fi
  for r in "$CTL"/req-*; do
    [ -e "$r" ] || continue
    name="${r##*/req-}"; [ -e "$CTL/ack-$name" ] && continue
    verb="${name#*-}"
    case "$verb" in
      mac-stop) stop_mac; answer "$name" ok ;;
      mac-start) if start_mac "$TESTOUT"; then answer "$name" ok; else answer "$name" "FAIL Mac restart"; fi ;;
      mark_*) log "MARK ${verb#mark_}: the Mac has received $(received) photo(s)"; answer "$name" ok ;;
      segment-tagged)
        log "the tagged segment ended on the phone; finalizing on the Mac"
        if finalize_mac; then
          pdf_tags "$TESTOUT" | tee -a "$REPORT" > "$RUN/tags1.tsv"
          stop_mac; start_mac "$RUN/out2" && answer "$name" ok || answer "$name" "FAIL Mac restart"
        else answer "$name" "FAIL finalize"; fi ;;
      *) answer "$name" "FAIL unknown request $verb" ;;
    esac
  done
  sleep 0.2
done
wait "$XCB_PID"; XRC=$?; XCB_PID=""
grep -E "Test Case .*(passed|failed)|error:|XCTAssert" "$RUN/xcodebuild.log" | sed "s/$TOKEN/[REDACTED]/g" | tee -a "$REPORT"
[ "$XRC" = 0 ] || fail "UI tests exited $XRC (see xcodebuild.log)"

# --- 4. the Mac side ------------------------------------------------------------------------------------
if [ -n "$MAC_PID" ]; then finalize_mac && pdf_tags "$TESTOUT" | tee -a "$REPORT" > "$RUN/tags2.tsv"; fi
# C-37/C-38: the document tagged Q2 + 1962 on the phone carries both as Finder tags.
if [ -s "$RUN/tags1.tsv" ] && awk -F'\t' '$3 ~ /(^|,)Q2(,|$)/ && $3 ~ /(^|,)1962(,|$)/' "$RUN/tags1.tsv" | grep -q .; then
  log "C-38: a filed PDF carries Q2 and 1962 from the phone's tag sheet"
else fail "C-38: no filed PDF carries both Q2 and 1962 (tags1.tsv)"; fi
# C-42: the Mac heard a non-zero count while pages waited, and 0 once drained.
hb="$(cat "$RUN"/mac*.log | sed -n 's/^LIVECAPTURE_PHONE_PENDING //p' | tr '\n' ' ')"
log "heartbeat counts as the Mac received them: $hb"
echo "$hb" | tr ' ' '\n' | grep -qE '^[1-9][0-9]*$' || fail "C-42: the Mac never heard a non-zero pending count"
[ "$(echo "$hb" | awk '{print $NF}')" = 0 ] || fail "C-42: the last count the Mac heard is not 0"
# Never lose a photo: every photo the app took is a filed PDF (-mergeDocuments NO), except the one test6 deletes.
fed="$(find "$FEED" -name '*.used' | wc -l | tr -d ' ')"
filed="$(find "$RUN/out1" "$RUN/out2" -name '*.pdf' | wc -l | tr -d ' ')"
log "photos taken: $fed; PDFs filed: $filed (one deleted on the phone on purpose)"
[ "$filed" = $((fed - 1)) ] || fail "photos taken and PDFs filed do not match ($fed taken, 1 deleted, $filed filed)"
log "screenshots: $(ls "$CTL/shots" | tr '\n' ' ')"
if [ "$FAILS" = 0 ]; then log "RESULT: PASS"; exit 0; else log "RESULT: FAIL ($FAILS)"; exit 1; fi
