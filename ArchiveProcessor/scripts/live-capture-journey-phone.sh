#!/usr/bin/env bash
# ============================================================================
# W40.d5 — the PHONE leg of the live-capture journey (the Mac leg is LiveCaptureJourneyUITests in the VM).
#
# Started in the background by `PROCESSOR_JOURNEY=livecapture ops/gui/vm-gui-runner.sh processor xcuitest`
# while the UI test runs in the guest. For each phase the test launches (live, fail, stage, in that order) it:
#   1. waits for the app's READY line in the guest (<guest-dir>/ready-<phase>.txt, read over `tart exec`),
#      takes the port + LAN bearer from it, then blanks the token in the guest copy;
#   2. relays 127.0.0.1:<port> on the host to the guest (tcp-relay.py over the Tart agent), which is what
#      the AVD's 10.0.2.2 reaches;
#   3. resets the companion, pairs it by hand-typed host/port/token, and drives the real capture flow on
#      real photos (Dean Papers, from ArchiveProcessor/Test Files) through the debug inject seam.
# The AVD is headless (`-no-window`, android-ui-drive.sh boot). Nothing here reads or writes a real corpus:
# the photos are copied into the run directory first.
#
# Usage: live-capture-journey-phone.sh <vm> <guest-dir> <run-dir>
# ============================================================================
set -uo pipefail
VM="$1"; GDIR="$2"; RUN="$3"
HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$HERE/android-ui-drive.sh"
export PATH="/opt/homebrew/bin:$PATH"
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
ADB="$(command -v adb || echo "$ANDROID_HOME/platform-tools/adb")"
PKG="com.archiveprocessor.capture"
# Test Files is gitignored, so a worktree has none: take the primary checkout's.
COMMON="$(cd "$HERE" && cd "$(git rev-parse --git-common-dir)/.." && pwd)"
PHOTOS="${W40D5_PHOTOS:-$COMMON/ArchiveProcessor/Test Files/Dean Papers}"
PHASES=(live:3 fail:2 stage:2)

mkdir -p "$RUN/shots"; LOG="$RUN/phone.log"; : > "$LOG"
export OUT="$RUN/shots"
log(){ printf '[phone %s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }
RELAYS=()
cleanup(){ for p in "${RELAYS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
trap 'exit 143' TERM INT
die(){ log "FAIL: $*"; echo "PHONE_LEG_FAIL $*" >> "$LOG"; exit 1; }

# --- fixtures: real photos, copied, renamed without spaces ---
[ -d "$PHOTOS" ] || die "no photos at $PHOTOS"
SRC=()
while IFS= read -r f; do SRC+=("$f"); done < <(find "$PHOTOS" -maxdepth 1 -iname '*.jpg' | sort | head -7)
[ "${#SRC[@]}" -ge 7 ] || die "need 7 photos in $PHOTOS, found ${#SRC[@]}"
k=0
for spec in "${PHASES[@]}"; do
  phase="${spec%%:*}"; n="${spec##*:}"; d="$RUN/fixtures/$phase"; mkdir -p "$d"
  printf '[' > "$d/ground_truth.json"
  for i in $(seq 1 "$n"); do
    cp "${SRC[$k]}" "$d/dean$i.jpg"
    printf '%s{"file":"dean%s.jpg","source":"%s"}' "$([ "$i" = 1 ] || echo ,)" "$i" "$(basename "${SRC[$k]}")" >> "$d/ground_truth.json"
    k=$((k+1))
  done
  printf ']\n' >> "$d/ground_truth.json"
done
log "fixtures: $(find "$RUN/fixtures" -name '*.jpg' | wc -l | tr -d ' ') photos from $PHOTOS"

# --- AVD up (headless) and the companion built + installed ---
if ! "$ADB" devices 2>/dev/null | grep -q '^emulator-'; then
  log "booting the headless AVD…"
  bash "$DRIVER" boot >> "$LOG" 2>&1 || die "AVD boot failed"
fi
[ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] || die "the AVD did not boot"
log "AVD booted; building + installing the companion…"
bash "$DRIVER" install >> "$LOG" 2>&1 || die "companion install failed"

for spec in "${PHASES[@]}"; do
  phase="${spec%%:*}"; ready="$GDIR/ready-$phase.txt"
  log "phase $phase: waiting for the Mac's READY line…"
  line=""
  for _ in $(seq 1 900); do
    line="$(tart exec "$VM" bash -c "grep '^LIVECAPTURE_READY port=' '$ready' 2>/dev/null | head -1")"
    [ -n "$line" ] && break; sleep 2
  done
  [ -n "$line" ] || die "phase $phase: no READY line in the guest after 30 min"
  port="$(printf '%s\n' "$line" | sed -n 's/.* port=\([0-9][0-9]*\).*/\1/p')"
  token="$(printf '%s\n' "$line" | sed -n 's/.* token=\([^ ]*\).*/\1/p')"
  tart exec "$VM" bash -c "sed -i '' -E 's/token=[^ ]+/token=[REDACTED]/g' '$ready'" || true
  [ -n "$port" ] && [ "${#token}" -ge 32 ] || die "phase $phase: no port/token in the READY line"
  case "$token" in *[!ABCDEFGHJKMNPQRSTUVWXYZ23456789]*) die "phase $phase: READY token has invalid characters";; esac
  log "phase $phase: Mac listening on $port; relaying"
  python3 "$HERE/tcp-relay.py" "$port" "tart:$VM" >> "$RUN/relay-$phase.log" 2>&1 &
  RELAYS+=($!)
  for _ in $(seq 1 30); do grep -q '^\[relay\]' "$RUN/relay-$phase.log" && break; sleep 1; done
  # A fresh companion per phase: the previous phase's Mac is gone, and pairing starts at the CONNECT screen.
  "$ADB" shell pm clear "$PKG" >/dev/null 2>&1 || true
  "$ADB" shell pm grant "$PKG" android.permission.CAMERA >/dev/null 2>&1 || true
  OUT="$RUN/shots/$phase"; mkdir -p "$OUT"; export OUT
  printf '%s\n' "$token" | bash "$DRIVER" pair "$port" >> "$LOG" 2>&1 || die "phase $phase: pairing failed"
  unset token
  bash "$DRIVER" inject-flow "$RUN/fixtures/$phase" "$RUN/fixtures/$phase/ground_truth.json" >> "$LOG" 2>&1 \
    || die "phase $phase: inject-flow failed"
  log "phase $phase: photos sent"
done
log "PHONE_LEG_DONE"
# Keep the relays up until the runner stops this leg: the Mac finalizes the last phase after the phone is done.
wait
