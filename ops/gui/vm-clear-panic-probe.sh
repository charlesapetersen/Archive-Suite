#!/usr/bin/env bash
# vm-clear-panic-probe.sh — prove tart_clear_panic (W49.vm-guest-crash-dialog, tart-lib.sh) against the REAL
# guest: plant a pending kernel panic, clear it, and check that it stays cleared across a forced restart.
#
#   1. a planted pending panic (both PanicReporter links, `.contents.panic`, a `panic-full-*.panic`)
#   2. tart_clear_panic -> 1, names the panic, copies the report out; the folder is empty, no alert process
#   3. a second call -> 0 (nothing pending)
#   4. after a hard power-off (`tart stop`) and boot: still nothing pending and no alert process
#   5. after a clean restart: the same
#
# What it cannot show is the alert itself coming back from a planted panic. Diagnostics Reporter is a launchd
# QueueDirectories job on /var/db/PanicReporter, and it rejects a planted copy ("Invalid launch" in its
# com.apple.osanalytics.DiagnosticsReporter log) and removes the link, at boot as well as at once (measured
# 2026-11-27, five boots). The real path was proven the same day on a genuine pending panic (the 08:17
# Halt/Restart Timed Out): the runner cleared it at boot and the four AccessibilityAuditUITests that had failed
# under the alert passed. So the probe unloads the reporter for the planting boot (bootout, not disable: it
# loads again at the next boot), and the planted files are copies of a panic the guest already retired, so
# each run leaves one more retired copy (about 64 KB). Takes the VM lock and stops any kept guest first, since
# that guest may mount a checkout without the guest half; ~5 minutes; $0.
# ⚠️ Run it by hand only, never from a gate: step 4 powers the shared guest off hard on purpose, which loses
# whatever the guest had not flushed (W40.vm-macos27). It syncs first, and nothing else runs in the guest then.
# USAGE: ops/gui/vm-clear-panic-probe.sh      ENV: VM_NAME, ART_DIR, AGENT_WAIT
set -uo pipefail
. "$(dirname "$0")/../autonomous/heavy-enter.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/tart-lib.sh"

VM="${VM_NAME:-archive-gui-runner}"
ART="${ART_DIR:-$HOME/.tart-mirror/vm-artifacts}"
REPO="$(cd "$HERE/../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 2; }

tart_require || die "tart missing"
tart list 2>/dev/null | awk '{print $2}' | grep -qx "$VM" || die "VM '$VM' does not exist"
running(){ tart list 2>/dev/null | awk -v v="$VM" '$2==v && $NF=="running"{f=1} END{exit !f}'; }
cleanup(){ [ "${BOOTED:-0}" = 1 ] && tart_stop_clean "$VM"; tart_lock_release; }
trap cleanup EXIT
tart_lock_acquire "${LOCK_WAIT:-120}" || die "the GUI VM is in use (pid ${TART_LOCK_OWNER:-?})"
mkdir -p "$ART"
if running; then tart_stop_clean "$VM"; fi
rm -f "$TART_KEEP_STATE"   # a kept guest is gone now; its reaper exits
boot() {
  BOOTED=1
  tart run "$VM" --no-graphics --no-clipboard --dir=repo:"$REPO" --dir=out:"$ART" >>"$ART/clear-panic-probe-tart.log" 2>&1 &
  tart ip "$VM" --wait 120 >/dev/null || die "no IP"
  tart_wait_agent "$VM" "${AGENT_WAIT:-240}" || die "guest agent never answered"
}
# reporter_up SECONDS — 0 once Diagnostics Reporter (the alert's process) is running in the guest.
reporter_up() {
  local i
  for i in $(seq 1 "$1"); do
    tart exec "$VM" pgrep -x 'Diagnostics Reporter' >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}
pending(){ tart exec "$VM" bash -lc '[ -n "$(ls -A /private/var/db/PanicReporter 2>/dev/null)" ]' >/dev/null 2>&1; }
: > "$ART/clear-panic-probe-tart.log"
boot

echo "== 1. plant a pending panic =="
# Never delete here: only copies go in, and tart_clear_panic retires them like a real one.
tart exec "$VM" bash -lc '
  launchctl bootout "gui/$(id -u)/com.apple.DiagnosticsReporter" 2>/dev/null
  dr=/Library/Logs/DiagnosticReports
  src=$(ls -d "$dr"/Retired/panic-acknowledged-*/ 2>/dev/null | while read -r d; do [ -e "$d.contents.panic" ] && ls "$d"panic-full-*.panic >/dev/null 2>&1 && echo "$d"; done | tail -n 1)
  stamp=$(date +%Y-%m-%d-%H%M%S)
  if [ -n "$src" ]; then
    sudo -n cp -p "$src.contents.panic" "$dr/.contents.panic"
    sudo -n cp -p "$(ls "$src"panic-full-*.panic | tail -n 1)" "$dr/panic-full-$stamp.0002.panic"
  else
    body="{\"product\" : \"VirtualMac2,1\", \"panicString\" : \"panic(cpu 0 caller 0x0): planted by vm-clear-panic-probe\\n\"}"
    printf "%s\n" "$body" | sudo -n tee "$dr/.contents.panic" >/dev/null
    { printf "{\"bug_type\":\"210\"}\n"; printf "%s\n" "$body"; } | sudo -n tee "$dr/panic-full-$stamp.0002.panic" >/dev/null
  fi
  sudo -n mkdir -p /private/var/db/PanicReporter
  sudo -n ln -sfn "$dr/.contents.panic" /private/var/db/PanicReporter/current.panic
  sudo -n ln -sfn "$dr/.contents.panic" /private/var/db/PanicReporter/display.panic
  ls -la /private/var/db/PanicReporter/
' > "$ART/clear-panic-probe-plant.log" 2>&1
[ "$(tart exec "$VM" bash -lc 'ls -A /private/var/db/PanicReporter | wc -l' 2>/dev/null | tr -d ' ')" = 2 ] \
  && ok "panic planted (current.panic and display.panic)" \
  || no "could not plant the panic: $(tr '\n' ' ' < "$ART/clear-panic-probe-plant.log" | cut -c1-400)"

echo "== 2. tart_clear_panic clears it =="
since="$(mktemp)"; sleep 1
crc=0; tart_clear_panic "$VM" || crc=$?
[ "$crc" = 1 ] && ok "-> 1: $TART_PANIC_NOTE" || no "clear returned $crc: $TART_PANIC_NOTE"
pending && no "/var/db/PanicReporter is not empty" || ok "/var/db/PanicReporter is empty"
tart exec "$VM" bash -lc 'ls /Library/Logs/DiagnosticReports/.contents.panic /Library/Logs/DiagnosticReports/panic-full-*.panic' >/dev/null 2>&1 \
  && no "a panic report is still unretired" || ok "the reports are retired"
sleep 3
tart exec "$VM" pgrep -x 'Diagnostics Reporter' >/dev/null 2>&1 && no "the alert's process is running" || ok "no alert process"
[ -n "$(find "$ART/guest-panics" -name 'panic-full-*.panic' -newer "$since" 2>/dev/null)" ] \
  && ok "report copied to $ART/guest-panics" || no "report not copied out"
rm -f "$since"

echo "== 3. nothing pending -> 0 =="
crc=0; tart_clear_panic "$VM" || crc=$?
[ "$crc" = 0 ] && ok "second call -> 0" || no "second call returned $crc: $TART_PANIC_NOTE"

after_boot() {  # $1 = how the guest was restarted
  pending && no "$1: a panic is pending again" || ok "$1: nothing pending"
  # A new REAL panic from that shutdown would show here; say so rather than blame the clear.
  reporter_up 45 && no "$1: Diagnostics Reporter started (a new panic? $(tart exec "$VM" bash -lc 'ls /Library/Logs/DiagnosticReports | grep panic-full' 2>/dev/null))" \
                 || ok "$1: no alert process at boot"
}
echo "== 4. a forced restart (hard power-off) =="
tart exec "$VM" sync >/dev/null 2>&1
tart stop "$VM" >/dev/null 2>&1
for i in $(seq 1 30); do running || break; sleep 1; done
boot; after_boot "after tart stop"

echo "== 5. a clean restart =="
tart_stop_clean "$VM"; BOOTED=0
boot; after_boot "after a clean stop"

echo
echo "vm-clear-panic-probe: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
