#!/usr/bin/env bash
# ============================================================================
# W40.d6 — does the Live Capture USB transport reach `USBBridge`, and does the tunnel carry traffic?
#
# The USB transport is `adb reverse tcp:P tcp:P`, asserted by the Mac (`Net/USBBridge.swift`) from
# `CaptureSession.serverDidStart` once the LAN `CaptureServer` binds. The phone's "Wired (USB cable)" mode then
# talks to 127.0.0.1:P. Inside an Android device 127.0.0.1 is the device itself, so a request to it reaches the
# Mac ONLY through that reverse mapping — which makes the emulator a faithful stand-in for the tunnel. (The
# emulator's other route to the Mac, 10.0.2.2, is what e2e-phone-mac.sh uses, so that run never touches USB.)
#
# What this proves, in order, against the REAL headless app (no stubs, no adb run by this script to create the
# mapping — every mapping it sees was made by the app):
#   1. the app is started first, with NO device attached, so its initial `adb reverse` has nothing to bind;
#   2. the emulator boots afterwards, and the app's 5 s heal timer creates `tcp:P tcp:P` on its own;
#   3. an authenticated GET /ping from inside the emulator to 127.0.0.1:P is answered by CaptureServer (200),
#      and the same request with a wrong token gets 401 (so it really is CaptureServer answering);
#   4. after `adb reverse --remove-all` (what an unplug does to the mapping) the request fails, and the app
#      re-creates the mapping within ~5 s without any help.
#
# Isolated: output under /tmp/ap-usb-probe-*, never the real corpus; emulator only, headless (-no-window).
# Usage:  scripts/usb-reverse-probe.sh            (builds nothing; set APP= to a built binary, or build first)
# Exit:   0 all four held · 1 a step failed (REPORT.txt says which) · 2 setup problem
# ============================================================================
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$HERE/android-ui-drive.sh"
export PATH="/opt/homebrew/bin:$PATH"
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
ADB="$(command -v adb || echo "$ANDROID_HOME/platform-tools/adb")"
APP="${APP:-$HERE/../macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor}"

RUN="$(mktemp -d /tmp/ap-usb-probe-XXXXXX)" || exit 2
REPORT="$RUN/REPORT.txt"; MACLOG="$RUN/mac.log"; READYFILE="$RUN/ready.txt"
mkdir "$RUN/out"
log(){ printf '[usb-probe] %s\n' "$*" | tee -a "$REPORT"; }
MAC_PID=""; FAILED=0
fail(){ log "FAIL: $*"; FAILED=1; }
# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup(){
  [ -n "$MAC_PID" ] && { kill "$MAC_PID" 2>/dev/null; wait "$MAC_PID" 2>/dev/null; }
  "$ADB" reverse --remove-all >/dev/null 2>&1
  [ "${KEEP_EMU:-0}" = 1 ] || "$ADB" emu kill >/dev/null 2>&1
  [ -f "$READYFILE" ] && sed -i '' -E 's/token=[^ ]+/token=[REDACTED]/g' "$READYFILE"
  [ -f "$MACLOG" ] && sed -i '' -E 's/token=[^ ]+/token=[REDACTED]/g' "$MACLOG"
}
trap cleanup EXIT

[ -x "$APP" ] || { log "setup: no built app at $APP"; exit 2; }
[ -x "$ADB" ] || { log "setup: no adb"; exit 2; }
"$ADB" start-server >/dev/null 2>&1
if "$ADB" devices | sed 1d | grep -q .; then
  log "setup: a device is already attached — step 1 needs none; detach it or kill the emulator first"; exit 2
fi
log "run dir: $RUN · app: $APP · commit: $(git -C "$HERE" rev-parse --short HEAD 2>/dev/null)"

# --- 1. the real app, headless, with no device attached ----------------------
ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$RUN/backup" LIVECAPTURE_AUTOSTART=1 \
LIVECAPTURE_READYFILE="$READYFILE" LIVECAPTURE_TESTOUT="$RUN/out" "$APP" >"$MACLOG" 2>&1 &
MAC_PID=$!
for _ in $(seq 1 60); do grep -q '^LIVECAPTURE_READY port=' "$READYFILE" 2>/dev/null && break
  kill -0 "$MAC_PID" 2>/dev/null || { log "setup: app exited early (see $MACLOG)"; exit 2; }; sleep 1; done
LINE="$(grep '^LIVECAPTURE_READY port=' "$READYFILE" 2>/dev/null | head -1)"
PORT="$(printf '%s\n' "$LINE" | sed -n 's/.* port=\([0-9][0-9]*\).*/\1/p')"
TOKEN="$(printf '%s\n' "$LINE" | sed -n 's/.* token=\([^ ]*\).*/\1/p')"
[ -n "$PORT" ] && [ "${#TOKEN}" -ge 32 ] || { log "setup: no READY line with port + token"; exit 2; }
case "$TOKEN" in *[!ABCDEFGHJKMNPQRSTUVWXYZ23456789]*) log "setup: token has unexpected characters"; exit 2;; esac
log "step 1: app listening on port $PORT; devices attached at that moment: none"

# --- 2. boot the emulator afterwards; the app's heal timer must create the mapping ----
bash "$DRIVER" boot >>"$RUN/emu.log" 2>&1 || { log "setup: emulator boot failed (see $RUN/emu.log)"; exit 2; }
mapped(){ "$ADB" reverse --list 2>/dev/null | grep -q "tcp:$PORT tcp:$PORT"; }
wait_mapped(){ for _ in $(seq 1 "$1"); do mapped && return 0; sleep 1; done; return 1; }
if wait_mapped 15; then log "step 2: app created the mapping by itself: $("$ADB" reverse --list | tr '\n' ' ')"
else fail "step 2: no tcp:$PORT mapping 15 s after the emulator came up (reverse --list: $("$ADB" reverse --list | tr '\n' ' '))"; fi

# --- 3. traffic from inside the device to 127.0.0.1:P -----------------------
# The request goes over adb's stdin so the bearer never appears in an argv. stdin is held open for 3 s because
# toybox nc quits at stdin EOF, before the reply arrives (measured: an immediate EOF reads back nothing). Note an
# empty answer is ambiguous: adbd accepts the device-side connect even when nothing listens on the Mac end.
ping_status(){ # $1 = bearer → HTTP status line from CaptureServer, or empty
  { printf 'GET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer %s\r\nConnection: close\r\n\r\n' "$1"; sleep 3; } |
    "$ADB" shell "nc -w 5 127.0.0.1 $PORT" 2>/dev/null | head -1 | tr -d '\r'
}
s_ok="$(ping_status "$TOKEN")"; s_bad="$(ping_status "WRONGTOKENWRONGTOKENWRONGTOKEN22")"
log "step 3: in-device GET 127.0.0.1:$PORT/ping → right token: '$s_ok' · wrong token: '$s_bad'"
case "$s_ok" in *" 200"*) ;; *) fail "step 3: authenticated ping not answered with 200";; esac
case "$s_bad" in *" 401"*) ;; *) fail "step 3: wrong-token ping not answered with 401";; esac

# --- 4. drop the mapping (an unplug does this) and watch the app heal it -------
"$ADB" reverse --remove-all >/dev/null 2>&1
mapped && fail "step 4: mapping still present right after --remove-all"
s_gone="$(ping_status "$TOKEN")"
log "step 4: after --remove-all → ping: '${s_gone:-<no answer>}'"
case "$s_gone" in *" 200"*) fail "step 4: ping still answered with the mapping removed";; esac
t0=$(date +%s)
if wait_mapped 12; then log "step 4: app re-created the mapping after $(( $(date +%s) - t0 )) s"
  s_back="$(ping_status "$TOKEN")"; log "step 4: ping after heal → '$s_back'"
  case "$s_back" in *" 200"*) ;; *) fail "step 4: ping not answered after the heal";; esac
else fail "step 4: mapping not re-created within 12 s"; fi
unset TOKEN

if [ "$FAILED" = 0 ]; then log "RESULT: PASS — USBBridge is reached from session start and the tunnel carries authenticated traffic"
else log "RESULT: FAIL"; fi
exit "$FAILED"
