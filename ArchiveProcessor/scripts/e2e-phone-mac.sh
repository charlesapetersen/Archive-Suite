#!/usr/bin/env bash
# ============================================================================
# Full autonomous phone<->Mac round-trip E2E for Archive Processor Live Capture.
#
# Unlike android-ui-drive.sh (phone UI + wire protocol against a FAKE stub) and
# the Mac-only test drivers, THIS composes BOTH real apps and asserts the whole
# round-trip:
#
#   real headless Mac (LIVECAPTURE_AUTOSTART, real Gemini OCR)  <== LAN ==>  emulator
#   running the identical Android app, "capturing" KNOWN documents via the
#   debug-only inject seam (B1). The Mac OCRs (B2 LIVECAPTURE_OCRKEY), auto-skips
#   the tag card (AUTOSKIPTAGS), auto-finalizes (AUTOFINALIZE) into an ISOLATED
#   output dir, and drops DONE.txt. We then assert tokens + years survived
#   end-to-end (assert_mac.py) and that the phone UI reached each capture state.
#
# Deterministic + unattended: emulator only (never a physical phone), known
# fixtures, isolated output (never the real corpus), no skip-permissions.
#
# Usage:  OCR_KEY=<gemini-key> scripts/e2e-phone-mac.sh
#         (if OCR_KEY unset, falls back to the Keychain Gemini key)
#   caffeinate -di scripts/e2e-phone-mac.sh     # keep the Mac awake for the run
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"                 # …/ArchiveProcessor/scripts
DRIVER="$HERE/android-ui-drive.sh"                    # proven emulator + UI driver (subcommands)
FIXTURES="$HERE/e2e-fixtures"                          # doc*.jpg + ground_truth.json
GT="$FIXTURES/ground_truth.json"
APPROOT="$(cd "$HERE/../macOS" && pwd)"               # the XcodeGen project dir
export PATH="/opt/homebrew/bin:$PATH"
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
ADB="$(command -v adb || echo "$ANDROID_HOME/platform-tools/adb")"

RUN="${E2E_RUNDIR:-/tmp/ap-e2e-$$}"
TESTOUT="$RUN/out"                                     # isolated output dir (never the real corpus)
READYFILE="$RUN/ready.txt"
MACLOG="$RUN/mac.log"
REPORT="$RUN/REPORT.txt"
SHOTS="$RUN/shots"
case "$RUN" in
  /tmp/ap-e2e-*/*|/tmp/ap-e2e-) printf '[e2e] FAIL: E2E_RUNDIR must be one dedicated /tmp/ap-e2e-* directory\n' >&2; exit 2;;
  /tmp/ap-e2e-*) ;;
  *) printf '[e2e] FAIL: E2E_RUNDIR must be a dedicated /tmp/ap-e2e-* path\n' >&2; exit 2;;
esac
umask 077                                               # private from the instant the run directory is created
mkdir "$RUN" || { printf '[e2e] FAIL: cannot atomically claim fresh run directory: %s\n' "$RUN" >&2; exit 2; }
mkdir "$TESTOUT" "$SHOTS"
export OUT="$SHOTS"                                    # android-ui-drive.sh screencaps land here

log(){ printf '\033[35m[e2e]\033[0m %s\n' "$*" | tee -a "$REPORT"; }
MAC_PID=""; KEEP_EMU="${KEEP_EMU:-onfail}"
redact_ready_token(){
  # Until W21.e2e-fu2, the app writes its six-character Drive-relay credential here. The READY file is
  # complete before this runs, so replacing it cannot detach a live writer from its artifact path.
  [ -f "$READYFILE" ] && sed -i '' -E 's/token=[^ ]+/token=[REDACTED]/g' "$READYFILE"
}
redact_closed_maclog(){
  # sed -i replaces an inode. Call this only after wait has closed the Mac process's stdout/stderr, or later
  # diagnostics would continue into an unlinked inode and silently disappear from the retained mac.log.
  [ -f "$MACLOG" ] && sed -i '' -E 's/token=[^ ]+/token=[REDACTED]/g' "$MACLOG"
}
cleanup(){
  if [ -n "$MAC_PID" ]; then
    kill "$MAC_PID" 2>/dev/null || true
    wait "$MAC_PID" 2>/dev/null || true
    MAC_PID=""
  fi
  redact_ready_token
  redact_closed_maclog
}
die(){ printf '\033[31m[e2e] FAIL:\033[0m %s\n' "$*" | tee -a "$REPORT" >&2; cleanup
       [ "$KEEP_EMU" = never ] && "$ADB" emu kill 2>/dev/null; exit 1; }

# Defensive cleanup: scrub any token-bearing artifact even if a child/older driver revision emitted one.
# shellcheck disable=SC2329  # invoked by the EXIT trap below
sanitize_artifacts(){
  redact_ready_token
  [ -f "$REPORT" ] && sed -i '' -E 's/ \(token [^)]*\)/ (token [REDACTED])/g' "$REPORT"
  rm -f "$SHOTS/04-filled.png"
}
trap 'cleanup; sanitize_artifacts' EXIT

# --- 0. preflight ------------------------------------------------------------
KEY="${OCR_KEY:-$(security find-generic-password -s com.archiveprocessor.app -a Gemini -w 2>/dev/null)}"
[ -n "$KEY" ] || die "no OCR key (set OCR_KEY=… or store Gemini in the Keychain)"
[ -f "$GT" ] || die "fixtures missing: $GT"
[ -f "$DRIVER" ] || die "driver missing: $DRIVER"
command -v xcodegen >/dev/null || die "xcodegen not on PATH"
log "run dir: $RUN"

# --- 1. build the Mac app (Debug) --------------------------------------------
log "building Mac app (Debug)…"
( cd "$APPROOT" && xcodegen generate >/dev/null && \
  xcodebuild -scheme ArchiveProcessor -configuration Debug -derivedDataPath ./build/DD build >/tmp/e2e-mac-build.log 2>&1 ) \
  || die "Mac build failed (see /tmp/e2e-mac-build.log)"
APP="$APPROOT/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$APP" ] || die "Mac binary not found: $APP"

# --- 2. launch the REAL headless Mac session ---------------------------------
log "launching headless Mac session (real OCR, auto-skip-tags, auto-finalize, isolated output)…"
rm -f "$READYFILE" "$TESTOUT/DONE.txt"
ARCHIVEPROC_HEADLESS=1 \
ARCHIVEPROC_TEST_BACKUP_ROOT="$RUN/backup" \
LIVECAPTURE_AUTOSTART=1 \
LIVECAPTURE_READYFILE="$READYFILE" \
LIVECAPTURE_OCRKEY="$KEY" \
LIVECAPTURE_AUTOSKIPTAGS=1 \
LIVECAPTURE_AUTOFINALIZE=1 \
LIVECAPTURE_TESTOUT="$TESTOUT" \
"$APP" >"$MACLOG" 2>&1 &
MAC_PID=$!

log "waiting for the Mac READY line…"
for _ in $(seq 1 60); do
  grep -q "LIVECAPTURE_READY " "$READYFILE" 2>/dev/null && break
  kill -0 "$MAC_PID" 2>/dev/null || die "Mac process exited early (see $MACLOG)"
  sleep 1
done
grep -q "LIVECAPTURE_READY " "$READYFILE" 2>/dev/null || die "no READY line after 60s (see $MACLOG)"
PORT="$(grep -o 'port=[0-9]*' "$READYFILE" | head -1 | cut -d= -f2)"
# W16.lan2 split the LAN bearer from the six-character Drive-relay code, but the test-only LAN READY line
# still reports the relay `token` (W21.e2e-fu2, owner-gated because the seam lives in Capture/). Read the
# same persisted LAN credential CaptureServer loaded; never print or screenshot it.
TOKEN="$(defaults read com.archiveprocessor.app LiveCaptureLANToken 2>/dev/null)"
[ -n "$PORT" ] && [ "${#TOKEN}" -ge 32 ] \
  || die "could not resolve port + high-entropy LAN token after READY (see $READYFILE)"
# Production mints only this 31-symbol alphabet. Fail closed on a corrupted defaults value before it reaches
# either an emulator-shell stdin command or curl's stdin config parser; future longer tokens remain allowed.
case "$TOKEN" in *[!ABCDEFGHJKMNPQRSTUVWXYZ23456789]*) die "persisted LAN token has invalid characters";; esac
redact_ready_token
log "Mac listening on LAN port $PORT"

# --- 3. emulator + app + pair over LAN (proven driver subcommands) -----------
# The emulator is launched (backgrounded) inside `boot` and survives as an
# adb-tracked orphan across subsequent subcommands.
bash "$DRIVER" boot            || die "emulator boot failed"
bash "$DRIVER" install         || die "app install failed"
printf '%s\n' "$TOKEN" | bash "$DRIVER" pair "$PORT" || die "pairing failed"

# --- 4. inject the known documents through the REAL capture path -------------
bash "$DRIVER" inject-flow "$FIXTURES" "$GT" || die "inject-flow failed"

# --- 5. signal session-complete → Mac auto-finalizes -------------------------
# The companion has NO session-finish UI (it finishes per-segment; whole-session
# finalize is a Mac-operator action). So the harness sends the documented
# `POST /session/complete` control signal itself, over the Bearer route the
# protocol defines → completeAllOpenDocGroups → (B2) AUTOFINALIZE, whose
# requestFinish is drain-gated (holds until the phone drained), then finalize.
# 10.0.2.2:$PORT (what the emulator paired to) forwards to the Mac's 127.0.0.1:$PORT.
sleep 3
log "sending POST /session/complete (Bearer) → Mac auto-finalize…"
code=$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | \
  curl --config - -s -o /dev/null -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/session/complete")
unset TOKEN
[ "$code" = "200" ] || log "WARN: /session/complete returned HTTP $code (continuing)"

log "waiting for Mac auto-finalize (DONE.txt, up to 300s)…"
for _ in $(seq 1 300); do
  [ -f "$TESTOUT/DONE.txt" ] && break
  kill -0 "$MAC_PID" 2>/dev/null || die "Mac process exited before finalize (see $MACLOG)"
  sleep 1
done
[ -f "$TESTOUT/DONE.txt" ] || die "no DONE.txt after 300s — finalize did not complete (see $MACLOG)"
log "finalize complete:"; sed 's/^/    /' "$TESTOUT/DONE.txt" | tee -a "$REPORT"

# --- 6. assert BOTH sides ----------------------------------------------------
log "compiling PDF-text extractor…"
swiftc -O "$HERE/pdftext.swift" -o "$RUN/pdftext" 2>/dev/null || die "pdftext build failed"

log "asserting Mac output (tokens + years end-to-end)…"
python3 "$HERE/assert_mac.py" "$TESTOUT" "$GT" "$RUN/pdftext" 2>&1 | tee -a "$REPORT"
MAC_OK=${PIPESTATUS[0]}

log "asserting phone UI (per-doc capture screencaps present)…"
PHONE_OK=0
ndocs=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$GT")
for i in $(seq 1 "$ndocs"); do
  [ -s "$SHOTS/doc$i-captured.png" ] || { log "  MISSING screencap: doc$i-captured.png"; PHONE_OK=1; }
done
[ -s "$SHOTS/05-connected.png" ] || { log "  MISSING screencap: 05-connected.png (pairing)"; PHONE_OK=1; }

# --- 7. verdict --------------------------------------------------------------
echo | tee -a "$REPORT"
if [ "$MAC_OK" = 0 ] && [ "$PHONE_OK" = 0 ]; then
  log "RESULT: PASS ✅  (round-trip verified; artifacts in $RUN)"
  cleanup; [ "$KEEP_EMU" != always ] && "$ADB" emu kill 2>/dev/null; exit 0
else
  log "RESULT: FAIL ❌  (mac=$MAC_OK phone=$PHONE_OK; artifacts + logs in $RUN)"
  cleanup; [ "$KEEP_EMU" = never ] && "$ADB" emu kill 2>/dev/null; exit 1
fi
