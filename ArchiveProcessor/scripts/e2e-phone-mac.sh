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
# Cost: three synthetic images through gemini-2.5-flash-lite (a few cents).
# Usage:  OCR_KEY=<gemini-key> scripts/e2e-phone-mac.sh
#         (if OCR_KEY unset, falls back to the Keychain Gemini key)
#   caffeinate -di scripts/e2e-phone-mac.sh     # keep the Mac awake for the run
#   scripts/e2e-phone-mac.sh --ios              # the iPhone companion instead (W40.i3): a headless iOS
#         simulator via ios-sim-drive.sh, same Mac, fixtures and assertions. Needs an iOS simulator runtime.
#   scripts/e2e-phone-mac.sh --ios --cable      # the iPhone over the cable route (W40.i-usb-build): a fake
#         usbmuxd (fake-usbmuxd.py) reports one USB device and connects the Mac's real USBMuxBridge into the
#         app's 48628 tunnel listener on the shared loopback; the app pairs in Cable mode with an empty host,
#         so every request goes relay → tunnel → bridge → server. Also asserts the fake carried the tunnels.
#         Only the real usbmuxd's forwarding and a device's network stack are not exercised (REFERENCE.md §Live Capture, USB local relay).
# ============================================================================
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox (2026-10-05)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"                 # …/ArchiveProcessor/scripts
PHONE=android; CABLE=0
for a in "$@"; do
  case "$a" in --ios) PHONE=ios ;; --android) ;; --cable) CABLE=1 ;;
    *) printf '[e2e] usage: %s [--android|--ios [--cable]]\n' "$0" >&2; exit 2 ;; esac
done
[ "$CABLE" = 1 ] && [ "$PHONE" != ios ] && { printf '[e2e] --cable is the iPhone route; Android uses adb reverse\n' >&2; exit 2; }
if [ "$PHONE" = ios ]; then DRIVER="$HERE/ios-sim-drive.sh"   # headless simulator + the app's DEBUG E2E harness
else DRIVER="$HERE/android-ui-drive.sh"; fi                    # proven emulator + UI driver (subcommands)
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
export OUT="$SHOTS"                                    # the phone driver's screenshots land here

log(){ printf '\033[35m[e2e]\033[0m %s\n' "$*" | tee -a "$REPORT"; }
MAC_PID=""; FAKE_PID=""; MUXSOCK="$RUN/usbmuxd"; KEEP_EMU="${KEEP_EMU:-onfail}"
phone_down(){ if [ "$PHONE" = ios ]; then bash "$DRIVER" shutdown; else "$ADB" emu kill 2>/dev/null; fi; }
redact_ready_token(){
  # The READY file briefly carries the LAN bearer needed for emulator pairing. The app has finished its one
  # READY write before this runs, so replacing it cannot detach a live writer from its artifact path.
  [ -f "$READYFILE" ] && sed -i '' -E 's/token=[^ ]+/token=[REDACTED]/g' "$READYFILE"
}
redact_closed_maclog(){
  # sed -i replaces an inode. Call this only after wait has closed the Mac process's stdout/stderr, or later
  # diagnostics would continue into an unlinked inode and silently disappear from the retained mac.log.
  [ -f "$MACLOG" ] && sed -i '' -E 's/token=[^ ]+/token=[REDACTED]/g' "$MACLOG"
}
# Inspect only the captured direct child. A missing/zombie child can be reaped; a live nonchild
# or an inspection failure must never authorize a signal. Do not match apps by name or kill a group.
mac_child_state(){
  local row parent state
  if ! row="$(ps -p "$MAC_PID" -o ppid= -o stat= 2>/dev/null)"; then
    if kill -0 "$MAC_PID" 2>/dev/null; then return 1; fi
    printf '%s\n' exited; return 0
  fi
  read -r parent state <<< "$row"
  [ "$parent" = "$$" ] || return 1
  case "$state" in *Z*) printf '%s\n' exited ;; *) printf '%s\n' running ;; esac
}
stop_mac_test_child(){
  [ -n "$MAC_PID" ] || return 0
  [[ "$MAC_PID" =~ ^[1-9][0-9]*$ ]] || return 1
  local state n
  state="$(mac_child_state)" || { log "FAIL: cannot verify Mac test-child ownership"; return 1; }
  if [ "$state" = running ]; then
    kill -TERM "$MAC_PID" 2>/dev/null || true
    for n in $(seq 1 50); do
      state="$(mac_child_state)" || return 1
      [ "$state" = exited ] && break
      sleep 0.1
    done
    if [ "$state" = running ]; then
      # A TERM-resistant scratch child must not stall teardown after the OCR oracle passed.
      state="$(mac_child_state)" || return 1
      if [ "$state" = running ]; then
        log "Mac test child did not stop after TERM; stopping the owned scratch child with KILL"
        kill -KILL "$MAC_PID" 2>/dev/null || true
      fi
      for n in $(seq 1 50); do
        state="$(mac_child_state)" || return 1
        [ "$state" = exited ] && break
        sleep 0.1
      done
    fi
  fi
  [ "$state" = exited ] || { log "FAIL: Mac test child survived shutdown; log left open"; return 1; }
  wait "$MAC_PID" 2>/dev/null || true
  MAC_PID=""
}
stop_fake_usbmuxd(){
  [ -n "$FAKE_PID" ] || return 0
  kill -TERM "$FAKE_PID" 2>/dev/null || true; wait "$FAKE_PID" 2>/dev/null || true; FAKE_PID=""
}
cleanup(){
  stop_mac_test_child || return 1
  stop_fake_usbmuxd
  redact_ready_token
  redact_closed_maclog
}
die(){ printf '\033[31m[e2e] FAIL:\033[0m %s\n' "$*" | tee -a "$REPORT" >&2; cleanup
       [ "$KEEP_EMU" = never ] && phone_down; exit 1; }

# Defensive cleanup: scrub any token-bearing artifact even if a child/older driver revision emitted one.
# shellcheck disable=SC2329  # invoked by the EXIT trap below
sanitize_artifacts(){
  redact_ready_token
  [ -f "$REPORT" ] && sed -i '' -E 's/ \(token [^)]*\)/ (token [REDACTED])/g' "$REPORT"
  rm -f "$SHOTS/04-filled.png"
}
finish_harness(){
  local status=$?
  trap - EXIT
  cleanup || { [ "$status" != 0 ] || status=1; }
  sanitize_artifacts || { [ "$status" != 0 ] || status=1; }
  exit "$status"
}
trap finish_harness EXIT

# --- 0. preflight ------------------------------------------------------------
# The Keychain fallback can wait forever on a permission prompt when nobody is there (W40.i-usb-build, unattended);
# 20 s bounds it, so the run fails with the no-key message below instead of hanging.
KEY="${OCR_KEY:-$(/usr/bin/perl -e 'alarm 20; exec @ARGV' /usr/bin/security find-generic-password -s com.archiveprocessor.app -a Gemini -w 2>/dev/null)}"
[ -n "$KEY" ] || die "no OCR key (set OCR_KEY=… or store Gemini in the Keychain)"
[ -f "$GT" ] || die "fixtures missing: $GT"
[ -f "$DRIVER" ] || die "driver missing: $DRIVER"
command -v xcodegen >/dev/null || die "xcodegen not on PATH"
log "run dir: $RUN (phone: $PHONE$([ "$CABLE" = 1 ] && printf ', cable'))"

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
MUXPATH=""   # empty = the bridge's default /var/run/usbmuxd (the override is DEBUG-only and ignores empty)
if [ "$CABLE" = 1 ]; then
  # The stand-in usbmuxd: one attached USB device, whose Connect(48628) reaches the simulator app's tunnel
  # listener, because the simulator shares this Mac's loopback. A DEBUG-only override points the bridge at it.
  log "starting the fake usbmuxd (one USB device) at ${MUXSOCK}…"
  /usr/bin/python3 "$HERE/fake-usbmuxd.py" "$MUXSOCK" --attach 1:USB >"$RUN/fake-usbmuxd.log" 2>&1 &
  FAKE_PID=$!
  for _ in $(seq 1 50); do [ -S "$MUXSOCK" ] && break; sleep 0.1; done
  [ -S "$MUXSOCK" ] || die "fake usbmuxd did not start (see $RUN/fake-usbmuxd.log)"
  MUXPATH="$MUXSOCK"
fi
# The engine may mask TERM; unblock it only in this captured child, then exec preserves its PID.
# NSArgumentDomain overrides are process-local: never rewrite the owner's saved settings.
# AUTOSTART starts the receiver, but does NOT select live rather than stage-for-later.
# Pin that choice and the cheap real OCR route so a saved Vision/local-agent/gateway profile,
# custom prompt or paid rotation setting cannot silently change what this E2E proves or costs.
ARCHIVEPROC_HEADLESS=1 \
ARCHIVEPROC_TEST_BACKUP_ROOT="$RUN/backup" \
LIVECAPTURE_AUTOSTART=1 \
LIVECAPTURE_TRANSPORT=lan \
LIVECAPTURE_READYFILE="$READYFILE" \
LIVECAPTURE_OCRKEY="$KEY" \
LIVECAPTURE_AUTOSKIPTAGS=1 \
LIVECAPTURE_AUTOFINALIZE=1 \
LIVECAPTURE_TESTOUT="$TESTOUT" \
ARCHIVE_USBMUX_SOCKET="$MUXPATH" \
python3 -c 'import os, signal, sys; signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM}); os.execv(sys.argv[1], sys.argv[1:])' \
  "$APP" -liveProcessingMode live \
  -selectedProvider Gemini -selectedModelId_Gemini gemini-2.5-flash-lite \
  -selectedThinking Low -useAppleVision NO -visionUseLLMJudgment NO \
  -useGateway NO -useLocalAgent NO -taggingModeRaw automatic \
  -rotationModeRaw off -reviewRotation NO -mergeDocuments NO \
  -imageResolutionPercent 100 -standardImageSizeMB 3 \
  -customOCRPrompt '' -tagVocabulary '' -outputDirectory "$TESTOUT" \
  >"$MACLOG" 2>&1 &
MAC_PID=$!

log "waiting for the Mac READY line…"
for _ in $(seq 1 60); do
  grep -q "LIVECAPTURE_READY " "$READYFILE" 2>/dev/null && break
  kill -0 "$MAC_PID" 2>/dev/null || die "Mac process exited early (see $MACLOG)"
  sleep 1
done
grep -q "LIVECAPTURE_READY " "$READYFILE" 2>/dev/null || die "no READY line after 60s (see $MACLOG)"
READY_LINE="$(grep '^LIVECAPTURE_READY port=' "$READYFILE" | head -1)"
PORT="$(printf '%s\n' "$READY_LINE" | sed -n 's/.* port=\([0-9][0-9]*\).*/\1/p')"
# W21.e2e-fu2: this test-only LAN READY line publishes the exact high-entropy bearer CaptureServer
# authenticates. Read it from the line (never defaults), then keep it stdin-only/redacted thereafter.
TOKEN="$(printf '%s\n' "$READY_LINE" | sed -n 's/.* token=\([^ ]*\).*/\1/p')"
[ -n "$PORT" ] && [ "${#TOKEN}" -ge 32 ] \
  || die "could not resolve port + high-entropy LAN token after READY (see $READYFILE)"
# Production mints only this 31-symbol alphabet. Fail closed on a corrupted defaults value before it reaches
# either an emulator-shell stdin command or curl's stdin config parser; future longer tokens remain allowed.
case "$TOKEN" in *[!ABCDEFGHJKMNPQRSTUVWXYZ23456789]*) die "READY LAN token has invalid characters";; esac
redact_ready_token
log "Mac listening on LAN port $PORT"

if [ "$PHONE" = ios ]; then
# --- 3+4 (iOS). simulator + app, then pair + inject in one launch ------------
# The simulator shares the Mac's network, so the app pairs to 127.0.0.1:$PORT directly. It pairs from the
# payload through the scanner's own path, then its DEBUG harness presses shutter / End segment / Skip per
# fixture, each page entering through the inject seam (ios-sim-drive.sh header).
bash "$DRIVER" boot            || die "simulator boot failed"
bash "$DRIVER" install         || die "app install failed"
# --cable: the driver pairs in Cable mode with an empty host, so the app has no address but its relay.
printf '%s\n' "$TOKEN" | IOS_E2E_CABLE="$CABLE" bash "$DRIVER" run "$PORT" "$FIXTURES" "$GT" || die "iOS pair + inject flow failed"
else
# --- 3. emulator + app + pair over LAN (proven driver subcommands) -----------
# The emulator is launched (backgrounded) inside `boot` and survives as an
# adb-tracked orphan across subsequent subcommands.
bash "$DRIVER" boot            || die "emulator boot failed"
bash "$DRIVER" install         || die "app install failed"
printf '%s\n' "$TOKEN" | bash "$DRIVER" pair "$PORT" || die "pairing failed"

# --- 4. inject the known documents through the REAL capture path -------------
bash "$DRIVER" inject-flow "$FIXTURES" "$GT" || die "inject-flow failed"
fi

# --- 5. signal session-complete → Mac auto-finalizes -------------------------
# The companion has NO session-finish UI (it finishes per-segment; whole-session
# finalize is a Mac-operator action). So the harness sends the documented
# `POST /session/complete` control signal itself, over the Bearer route the
# protocol defines → completeAllOpenDocGroups → (B2) AUTOFINALIZE, whose
# requestFinish is drain-gated (holds until the phone drained), then finalize.
# 10.0.2.2:$PORT (what the emulator paired to) forwards to the Mac's 127.0.0.1:$PORT; the iOS
# simulator paired to 127.0.0.1:$PORT itself.
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
# iOS: the connected shot and each page's shot (its own thumbnail) all differ, so identical files mean the app
# drew nothing new while its driver ran. Every --ios run before W40.i3-fu-shots had all its shots on the
# launch-time frame: attaching the camera preview to a camera-less session froze the main thread's layout
# (CameraController.hasCamera). A phone-side failure. Android is left as it was.
if [ "$PHONE" = ios ]; then
  distinct=$(for f in 05-connected $(seq -f 'doc%g-captured' 1 "$ndocs"); do md5 -q "$SHOTS/$f.png" 2>/dev/null; done | sort -u | wc -l | tr -d ' ')
  [ "$distinct" = "$((ndocs + 1))" ] || { log "  STALE screencaps: $distinct distinct of $((ndocs + 1)) shots — the app drew no new frame"; PHONE_OK=1; }
fi

# --cable: the photos can only have come through the tunnels, but say so from the fake's own count, so a
# route that somehow bypassed the bridge fails here rather than passing.
CABLE_OK=0
if [ "$CABLE" = 1 ]; then
  stats="$(/usr/bin/python3 - "$MUXSOCK" <<'PY'
import plistlib, socket, struct, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
body = plistlib.dumps({"MessageType": "FakeStats"}, fmt=plistlib.FMT_XML)
s.sendall(struct.pack("<IIII", 16 + len(body), 1, 8, 1) + body)
def rd(n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: sys.exit(1)
        b += c
    return b
length = struct.unpack("<IIII", rd(16))[0]
m = plistlib.loads(rd(length - 16))
print(m.get("ConnectsByDevice", {}).get("1", 0), m.get("Refused", 0))
PY
)" || stats=""
  read -r connects refused <<< "${stats:-0 0}"
  log "cable: the fake usbmuxd served $connects Connect(s) to device 1 ($refused refused)"
  [ "${connects:-0}" -gt 0 ] || { log "  NO TUNNELS: the bridge never connected through the fake usbmuxd"; CABLE_OK=1; }
fi

# --- 7. verdict --------------------------------------------------------------
echo | tee -a "$REPORT"
if [ "$MAC_OK" = 0 ] && [ "$PHONE_OK" = 0 ] && [ "$CABLE_OK" = 0 ]; then
  cleanup || die "Mac test-child cleanup failed (output assertions passed; teardown did not)"
  log "RESULT: PASS ✅  (round-trip verified; artifacts in $RUN)"
  [ "$KEEP_EMU" != always ] && phone_down; exit 0
else
  log "RESULT: FAIL ❌  (mac=$MAC_OK phone=$PHONE_OK cable=$CABLE_OK; artifacts + logs in $RUN)"
  cleanup; [ "$KEEP_EMU" = never ] && phone_down; exit 1
fi
