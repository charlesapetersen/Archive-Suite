#!/usr/bin/env bash
# Unattended Android UI test harness for the Archive Capture companion.
# Drives the app on a HEADLESS emulator via adb (no physical phone, no owner intervention) and verifies
# results on the Mac's backup/manifest files. See execution-plans/android-ui-test-harness.md.
#
# Usage:
#   scripts/android-ui-drive.sh boot                 # create (if needed) + boot the headless AVD
#   scripts/android-ui-drive.sh install              # gradle installDebug to the emulator
#   scripts/android-ui-drive.sh pair <port> <token>  # pair via manual entry (host=10.0.2.2)
#   scripts/android-ui-drive.sh flow                 # run a capture/tag/save flow, screenshotting each step
#   scripts/android-ui-drive.sh all <port> <token>   # boot+install+pair+flow
#   scripts/android-ui-drive.sh shot <name>          # one screenshot
# The Mac side (headless) is launched separately with LIVECAPTURE_AUTOSTART=1 LIVECAPTURE_READYFILE=… ,
# which prints `port` + `token` to read into `pair`.
set -uo pipefail

SDK="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
export ANDROID_HOME="$SDK"
ADB="$(command -v adb || echo "$SDK/platform-tools/adb")"
# SAFETY: target ONLY the emulator, never a physical phone that may also be attached (a real device
# could be in use). Pin every adb + gradle call to the emulator serial via ANDROID_SERIAL (both honor it).
# Derived best-effort at load; the strict "exactly one emulator" check is ENFORCED LAZILY by
# require_emulator (below) so that `boot` can cold-start the FIRST emulator — the strict check can't run
# before an emulator exists, but every command that touches a RUNNING emulator still refuses unless one
# is isolated.
EMU_SERIAL="${EMU_SERIAL:-$("$ADB" devices | awk '/^emulator-/{print $1}')}"
[ -n "$EMU_SERIAL" ] && export ANDROID_SERIAL="$EMU_SERIAL"
EMULATOR="$SDK/emulator/emulator"
AVDMANAGER="$SDK/cmdline-tools/latest/bin/avdmanager"
SDKMANAGER="$SDK/cmdline-tools/latest/bin/sdkmanager"
AVD="${AVD:-ap_test}"
SYSIMG="${SYSIMG:-system-images;android-34;google_apis;arm64-v8a}"
PKG="com.archiveprocessor.capture"
ACT="$PKG/.MainActivity"
MACHOST="10.0.2.2"                 # emulator's alias for the Mac host loopback (Wi-Fi mode)
OUT="${OUT:-/tmp/ap-ui-shots}"; mkdir -p "$OUT"
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # the Android project root (…/ArchiveCapture)
APPDIR="$HERE/ArchiveCapture"

log(){ printf '\033[36m[harness]\033[0m %s\n' "$*"; }
die(){ printf '\033[31m[harness] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

# Enforce the SAFETY invariant lazily: exactly one emulator attached, pinned via ANDROID_SERIAL, never a
# physical phone. Called by every command that drives a RUNNING emulator (NOT by `boot`, which creates it).
require_emulator(){
  EMU_SERIAL="$("$ADB" devices | awk '/^emulator-/{print $1}')"
  [ -n "$EMU_SERIAL" ] || die "no emulator found (adb devices shows nothing matching emulator-*) — run 'boot' first"
  [ "$(printf '%s\n' "$EMU_SERIAL" | grep -c .)" -eq 1 ] || die "multiple emulators: $EMU_SERIAL — set EMU_SERIAL=… explicitly"
  export ANDROID_SERIAL="$EMU_SERIAL"; }

# --- UI observation / driving --------------------------------------------------------------------
dump(){ "$ADB" shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1; "$ADB" shell cat /sdcard/ui.xml 2>/dev/null; }

# center_of "<label>" : print "X Y" of the node whose text or content-desc EQUALS the label (first match).
center_of(){ dump | python3 -c '
import sys,re
target=sys.argv[1]; xml=sys.stdin.read()
for m in re.finditer(r"<node[^>]*>", xml):
    tag=m.group(0)
    def a(n):
        mm=re.search(n+r"=\"([^\"]*)\"", tag); return mm.group(1) if mm else ""
    if a("text")==target or a("content-desc")==target:
        b=re.search(r"bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", tag)
        if b:
            x1,y1,x2,y2=map(int,b.groups()); print((x1+x2)//2,(y1+y2)//2); sys.exit(0)
sys.exit(1)' "$1"; }

tap_text(){ local xy; xy=$(center_of "$1") || die "element not found: $1"; log "tap '$1' @ $xy"; "$ADB" shell input tap $xy; sleep 1; }
# Tap if present; skip (don't fail) if absent — for conditional controls (e.g. "Save to phone" only shows
# while items are still un-sent on the phone).
tap_text_opt(){ local xy; xy=$(center_of "$1") && { log "tap '$1' @ $xy"; "$ADB" shell input tap $xy; sleep 1; } || log "skip '$1' (not shown — nothing pending)"; }
type_into(){ local xy; xy=$(center_of "$1") || die "field not found: $1"; "$ADB" shell input tap $xy; sleep 0.5; "$ADB" shell input text "$2"; sleep 0.3; }  # soft IME is disabled at boot, so no dismissal needed
shot(){ local n="${1:-shot}"; "$ADB" exec-out screencap -p > "$OUT/$n.png" 2>/dev/null && log "screenshot → $OUT/$n.png"; }

# Tap the (unlabeled) shutter: the middle of the Box…Folder row.
tap_shutter(){ local bx by fx fy; read bx by < <(center_of "Box") || die "no Box btn"; read fx fy < <(center_of "Folder") || die "no Folder btn"; log "tap shutter @ $(((bx+fx)/2)) $by"; "$ADB" shell input tap $(((bx+fx)/2)) "$by"; sleep 1; }

# --- Lifecycle -----------------------------------------------------------------------------------
ensure_avd(){ [ -x "$EMULATOR" ] || die "emulator not installed — run: sdkmanager --install emulator '$SYSIMG'"
  "$AVDMANAGER" list avd 2>/dev/null | grep -q "Name: $AVD" || { log "creating AVD $AVD"; echo no | "$AVDMANAGER" create avd -n "$AVD" -k "$SYSIMG" -d pixel_6 || die "avd create failed"; }
  # Force a HARDWARE keyboard so the soft IME never pops (it would cover the Host/Port/Token fields and make
  # field taps miss). Without this, scripted text entry collapses all fields into the first one.
  local cfg="$HOME/.android/avd/$AVD.avd/config.ini"
  if [ -f "$cfg" ] && ! grep -qi '^hw.keyboard=yes' "$cfg"; then
    grep -qi '^hw.keyboard=' "$cfg" && sed -i '' 's/^hw.keyboard=.*/hw.keyboard=yes/' "$cfg" || printf 'hw.keyboard=yes\n' >> "$cfg"
    log "set hw.keyboard=yes in $cfg"
  fi; }
boot(){ ensure_avd; log "booting headless emulator $AVD"; "$EMULATOR" -avd "$AVD" -no-window -no-audio -no-boot-anim -no-snapshot -camera-back virtualscene -gpu swiftshader_indirect >/tmp/ap-emu.log 2>&1 &
  "$ADB" wait-for-device; require_emulator   # emulator now exists → pin ANDROID_SERIAL for the calls below
  log "waiting for boot…"; until [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 2; done
  "$ADB" shell input keyevent 82 >/dev/null 2>&1                    # dismiss the keyguard
  "$ADB" shell settings put secure show_ime_with_hard_keyboard 0 >/dev/null 2>&1  # never pop the soft IME (would cover buttons)
  log "booted."; }
install(){ [ -f "$APPDIR/local.properties" ] || echo "sdk.dir=$SDK" > "$APPDIR/local.properties"
  # Build the APK, then install to the EMULATOR ONLY with an explicit -s serial. NOT `gradle installDebug`,
  # which can push to every attached device (incl. a physical phone in use). adb -s can only hit the emulator.
  ( cd "$APPDIR" && ./gradlew :app:assembleDebug ) || die "assemble failed"
  local apk="$APPDIR/app/build/outputs/apk/debug/app-debug.apk"; [ -f "$apk" ] || die "APK not found: $apk"
  "$ADB" -s "$EMU_SERIAL" install -r "$apk" || die "install to $EMU_SERIAL failed"
  # Clear app data so every run starts at the CONNECT screen (deterministic pairing). `install -r` keeps
  # data, so a saved endpoint from a prior run would launch straight to the capture screen and the pairing
  # taps would miss. (pm clear also revokes CAMERA — re-granted next; pair() re-grants too.)
  "$ADB" -s "$EMU_SERIAL" shell pm clear "$PKG" >/dev/null 2>&1 || true
  "$ADB" -s "$EMU_SERIAL" shell pm grant "$PKG" android.permission.CAMERA >/dev/null 2>&1 || true; }

launch(){ "$ADB" shell am start -n "$ACT" >/dev/null 2>&1; sleep 2; }

pair(){ local port="$1" token="$2"
  "$ADB" shell pm grant "$PKG" android.permission.CAMERA >/dev/null 2>&1 || true  # pm clear revokes it; the Wi-Fi screen requests it
  launch; shot 01-launch
  tap_text "Wi-Fi (same network)"; shot 02-mode
  tap_text "Enter manually instead"; shot 03-manual
  type_into "Host" "$MACHOST"; type_into "Port" "$port"; type_into "Token" "$token"; shot 04-filled
  tap_text "Connect"; sleep 3; shot 05-connected; }

# A throwaway "fake Mac receiver": returns 200 to every route so the app pairs + thinks uploads succeed,
# exercising the WHOLE UI (incl. the CaptureScreen) with NO real Mac app — fully unattended, no Mac-GUI
# contention. Run it in the background on a port that is NOT the real 48627, e.g.:  scripts/…-drive.sh stub &
# then:  pair 48628 <anytoken>.  (For real end-to-end verification, pair to the real Mac instead and check
# its backup/manifest files.)
stub(){ local port="${1:-48628}"; log "stub (fake Mac receiver) on 127.0.0.1:$port — emulator reaches it at 10.0.2.2:$port"
  python3 - "$port" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def _ok(self):
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(b'{"ok":true,"app":"ArchiveProcessor"}')
    def do_GET(self): self._ok()
    def do_POST(self):
        n=int(self.headers.get('Content-Length',0) or 0)
        if n: self.rfile.read(n)
        self._ok()
    def log_message(self,*a): sys.stderr.write("STUB %s %s\n"%(self.command,self.path)); sys.stderr.flush()
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
}

# NOTE: `adb screencap` does NOT composite Compose's ModalBottomSheet popup, so the tag-sheet step's PNG
# shows the capture screen behind it — but `uiautomator` DOES see the sheet, so tapping its buttons by text
# works (the flow's "Skip (tag on Mac)" tap fires POST /segment/complete). Assert sheet steps via traffic /
# uiautomator, not the screenshot.
flow(){ log "capture flow"
  tap_text_opt "Save to phone"; shot 05b-save-before   # backup control (shown while pages are still un-sent)
  tap_shutter; tap_shutter; shot 06-two-pages      # 2-page document
  tap_text "End segment"; sleep 2; shot 07-tagsheet   # settle so the tag sheet renders before the shot
  tap_text "Skip (tag on Mac)"; sleep 1; shot 08-after-skip   # ends + sends the segment (→ POST /segment/complete)
  tap_text "Box"; sleep 1; shot 09-box              # a box marker (→ POST /photo)
  tap_text_opt "Save to phone"; shot 10-save; }     # hidden once everything has drained to the Mac

# --- Deterministic capture inject (real phone<->Mac E2E; see e2e-phone-mac.sh) --------------------
# Stage a known document image where the DEBUG-only capture-inject seam picks it up as the next shot
# (files/test_inject.jpg). Requires a DEBUG build (release strips the seam). One tap consumes one image.
inject(){ local fx="$1"; [ -f "$fx" ] || die "inject fixture not found: $fx"
  "$ADB" push "$fx" /data/local/tmp/inject.jpg >/dev/null || die "adb push failed: $fx"
  "$ADB" shell run-as "$PKG" cp /data/local/tmp/inject.jpg files/test_inject.jpg || die "inject cp failed (needs debug build + run-as)"; }

# Drive the REAL capture flow for each doc in a ground_truth.json: inject it as the next shot, capture it
# as a single-page document segment, End segment, then Skip (tags applied by the Mac's LLM). Called by
# e2e-phone-mac.sh AFTER pairing to the REAL Mac; the Mac auto-skips/finalizes and asserts the round-trip.
inject_flow(){ local fixdir="$1" gt="$2" i=0
  # Read the doc list on FD 3, NOT stdin: `adb shell` in the loop body forwards stdin to the device until
  # EOF, so a plain `while read … < <(…)` would let the first adb call swallow the remaining doc lines and
  # the loop would run only once. FD 3 keeps the list out of adb's reach.
  while IFS= read -r f <&3; do
    i=$((i+1)); log "e2e doc $i: inject $f + capture"
    inject "$fixdir/$f"
    tap_shutter; shot "doc$i-captured"
    tap_text "End segment"; sleep 2; shot "doc$i-tagsheet"
    tap_text_opt "Skip (tag on Mac)"; sleep 1
  done 3< <(python3 -c 'import json,sys
for d in json.load(open(sys.argv[1])): print(d["file"])' "$gt")
  tap_text_opt "Save to phone"; shot "zz-drained"; }

case "${1:-all}" in
  boot) boot;;
  install) require_emulator; install;;
  pair) require_emulator; pair "$2" "$3";;
  flow) require_emulator; flow;;
  inject) require_emulator; inject "$2";;
  inject-flow) require_emulator; inject_flow "$2" "$3";;
  shot) require_emulator; shot "${2:-shot}";;
  stub) stub "${2:-48628}";;
  all) boot; require_emulator; install; pair "${2:?port}" "${3:?token}"; flow; log "done — screenshots in $OUT";;
  *) die "unknown cmd: $1";;
esac
