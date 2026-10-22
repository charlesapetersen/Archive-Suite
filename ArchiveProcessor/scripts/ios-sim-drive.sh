#!/usr/bin/env bash
# ============================================================================
# iOS simulator driver for the phone<->Mac E2E (W40.i3) — the iPhone twin of android-ui-drive.sh's
# boot / install / pair / inject-flow subcommands, used by `e2e-phone-mac.sh --ios`.
#
# Headless: `simctl boot` runs the device with no window. Simulator.app is never opened (it is the part
# that would draw on the screen; .claude/hooks/no-host-gui.sh denies it). Screenshots come from
# `simctl io screenshot`, which reads the device's framebuffer, not the display.
#
# The simulator has no camera and no `adb input`, so the app's DEBUG-only E2E harness does the taps
# (ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Debug/E2EHarness.swift): this script stages the fixtures in
# the app's Documents/e2e-inbox, launches it with the pairing payload and ARCHIVECAP_E2E_DRIVE=1, and follows
# its progress file. The pages still travel the real path: shutter → inject seam → persist → upload.
#
# Subcommands:
#   boot                       create (once) and boot the dedicated E2E device
#   install                    build the Debug app for the simulator, fresh-install it, grant the camera
#   run <port> <fixdir> <gt>   stage fixtures, launch paired to 127.0.0.1:<port>, drive, screenshot;
#                              the LAN token is read from stdin (never argv)
#   shutdown                   shut the device down
# Env: OUT (screenshot dir, default /tmp/ios-e2e-shots), IOS_E2E_DEVICE (device name, default ap-e2e-iphone).
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IOSROOT="$(cd "$HERE/../ArchiveCaptureiOS" && pwd)"
BUNDLE=com.archiveprocessor.capture.ios
DEVICE="${IOS_E2E_DEVICE:-ap-e2e-iphone}"
OUT="${OUT:-/tmp/ios-e2e-shots}"; mkdir -p "$OUT"
export PATH="/opt/homebrew/bin:$PATH"

log(){ printf '\033[36m[ios]\033[0m %s\n' "$*"; }
die(){ printf '\033[31m[ios] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

udid(){ xcrun simctl list devices -j | python3 -c 'import json,sys
name=sys.argv[1]
for rt, devs in json.load(sys.stdin)["devices"].items():
    for d in devs:
        if d["name"] == name and d.get("isAvailable", True): print(d["udid"]); sys.exit(0)' "$DEVICE"; }

shot(){ local u; u="$(udid)" || return 0
  xcrun simctl io "$u" screenshot "$OUT/$1.png" >/dev/null 2>&1 && log "screenshot → $OUT/$1.png"; }

boot(){
  local u rt dt
  u="$(udid)"
  if [ -z "$u" ]; then
    rt="$(xcrun simctl list runtimes -j | python3 -c 'import json,sys
rs=[r for r in json.load(sys.stdin)["runtimes"] if r["platform"]=="iOS" and r["isAvailable"]]
print(rs[-1]["identifier"] if rs else "")')"
    [ -n "$rt" ] || die "no iOS simulator runtime installed (xcodebuild -downloadPlatform iOS, about 8 GB)"
    dt="$(xcrun simctl list devicetypes -j | python3 -c 'import json,sys
ts=[t["identifier"] for t in json.load(sys.stdin)["devicetypes"] if t["name"].startswith("iPhone") and t.get("productFamily","iPhone")=="iPhone"]
print(ts[-1] if ts else "")')"
    [ -n "$dt" ] || die "no iPhone device type"
    u="$(xcrun simctl create "$DEVICE" "$dt" "$rt")" || die "simctl create failed ($dt, $rt)"
    log "created $DEVICE ($dt, $rt) = $u"
  fi
  xcrun simctl boot "$u" 2>/dev/null || true          # already booted is fine
  xcrun simctl bootstatus "$u" -b >/dev/null || die "device $u did not finish booting"
  log "booted $DEVICE ($u), headless"
}

require_booted(){ U="$(udid)"; [ -n "$U" ] || die "no $DEVICE device (run boot first)"
  xcrun simctl list devices | grep -q "$U) (Booted)" || die "$DEVICE is not booted"; }

install(){
  require_booted
  log "building the iPhone companion (Debug, simulator)…"
  ( cd "$IOSROOT" && xcodegen generate >/dev/null && \
    xcodebuild -scheme ArchiveCaptureiOS -destination 'generic/platform=iOS Simulator' -configuration Debug \
      -derivedDataPath ./build/DD build >/tmp/e2e-ios-build.log 2>&1 ) || die "iOS build failed (see /tmp/e2e-ios-build.log)"
  local app="$IOSROOT/build/DD/Build/Products/Debug-iphonesimulator/ArchiveCaptureiOS.app"
  [ -d "$app" ] || die "app not found: $app"
  xcrun simctl terminate "$U" "$BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$U" "$BUNDLE" >/dev/null 2>&1 || true   # fresh state: no saved pairing, empty Documents
  xcrun simctl install "$U" "$app" || die "simctl install failed"
  xcrun simctl privacy "$U" grant camera "$BUNDLE" >/dev/null 2>&1 || log "WARN: camera grant failed (the inject seam does not need it)"
  log "installed $BUNDLE fresh"
}

run(){
  local port="$1" fixdir="$2" gt="$3" token data status i=0 f n last="" line
  require_booted
  IFS= read -r token || die "LAN token missing on stdin"
  data="$(xcrun simctl get_app_container "$U" "$BUNDLE" data)" || die "no data container (install first)"
  mkdir -p "$data/Documents/e2e-inbox"; rm -f "$data/Documents/e2e-status.txt"
  status="$data/Documents/e2e-status.txt"
  # Name-ordered inbox in ground-truth order, so doc i on the Mac is doc i in ground_truth.json.
  while IFS= read -r f <&3; do
    i=$((i+1)); [ -f "$fixdir/$f" ] || die "fixture not found: $fixdir/$f"
    cp "$fixdir/$f" "$data/Documents/e2e-inbox/$(printf '%02d' "$i")-$f"
  done 3< <(python3 -c 'import json,sys
for d in json.load(open(sys.argv[1])): print(d["file"])' "$gt")
  n=$i; log "staged $n fixture(s) in the app's inbox"
  # The payload rides in the child's environment (SIMCTL_CHILD_ prefix), never in argv.
  SIMCTL_CHILD_ARCHIVECAP_E2E_PAIR="$(python3 -c 'import json,sys;print(json.dumps({"host":"127.0.0.1","port":int(sys.argv[1]),"token":sys.stdin.read().strip(),"name":"E2E Mac"}))' "$port" <<<"$token")" \
  SIMCTL_CHILD_ARCHIVECAP_E2E_DRIVE=1 \
    xcrun simctl launch "$U" "$BUNDLE" >/dev/null || die "simctl launch failed"
  unset token
  log "launched; following the app's E2E progress"
  local seen=0 total
  for _ in $(seq 1 1800); do                      # 0.1 s steps: 180 s for pairing + capture + drain
    total="$(wc -l < "$status" 2>/dev/null | tr -d ' ')"; total="${total:-0}"
    while [ "$seen" -lt "$total" ]; do            # every new line, in order, so no step is skipped
      seen=$((seen+1)); line="$(sed -n "${seen}p" "$status")"; last="$line"; log "app: $line"
      case "$line" in
        paired) shot 05-connected ;;
        "captured "*) shot "doc${line#captured }-captured" ;;
        "DONE "*) shot zz-drained; return 0 ;;
        FAIL*) shot zz-fail; die "app reported: $line" ;;
      esac
    done
    sleep 0.1
  done
  shot zz-timeout; die "no DONE from the app after 180 s (last: ${last:-nothing})"
}

shutdown(){ local u; u="$(udid)"; [ -n "$u" ] && xcrun simctl shutdown "$u" >/dev/null 2>&1; true; }

case "${1:-}" in
  boot) boot ;;
  install) install ;;
  run) shift; [ $# -eq 3 ] || die "usage: run <port> <fixdir> <ground_truth.json> (token on stdin)"; run "$@" ;;
  shutdown) shutdown ;;
  *) die "usage: $0 boot|install|run <port> <fixdir> <gt>|shutdown" ;;
esac
