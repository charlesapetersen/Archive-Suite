#!/usr/bin/env bash
# vm-clear-panic-probe.sh — prove tart_clear_panic (W49.vm-guest-crash-dialog, tart-lib.sh) against the REAL
# guest: plant a pending kernel panic, force a restart, and check that the alert comes back and is cleared.
#
#   1. a pending panic survives a hard power-off (`tart stop`) and Diagnostics Reporter raises it at boot
#   2. tart_clear_panic -> 1, names the panic, copies the report out; the link and the alert are gone
#   3. a second call -> 0 (nothing pending)
#   4. after another restart there is still nothing pending and no alert
#
# The planted panic is a copy of a real one the guest already retired (Retired/panic-acknowledged-*), so
# Diagnostics Reporter reads what a real panic leaves; with none retired it writes a minimal one of the same
# shape. Each run therefore leaves one more retired copy in the guest (about 64 KB). Takes the VM lock and
# stops any kept guest first, since that guest may mount a checkout without the guest half; ~4 minutes; $0.
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
pending(){ tart exec "$VM" bash -lc '[ -L /private/var/db/PanicReporter/current.panic ] || [ -e /private/var/db/PanicReporter/current.panic ]' >/dev/null 2>&1; }
: > "$ART/clear-panic-probe-tart.log"
boot

echo "== 1. a pending panic survives a forced restart and raises the alert =="
# Never delete here: only copies go in, and tart_clear_panic retires them like a real one.
tart exec "$VM" bash -lc '
  dr=/Library/Logs/DiagnosticReports
  src=$(ls -d "$dr"/Retired/panic-acknowledged-*/ 2>/dev/null | while read -r d; do [ -e "$d.contents.panic" ] && ls "$d"panic-full-*.panic >/dev/null 2>&1 && echo "$d"; done | tail -n 1)
  stamp=$(date +%Y-%m-%d-%H%M%S)
  if [ -n "$src" ]; then
    sudo -n cp "$src.contents.panic" "$dr/.contents.panic"
    sudo -n cp "$(ls "$src"panic-full-*.panic | tail -n 1)" "$dr/panic-full-$stamp.0002.panic"
  else
    body="{\"product\" : \"VirtualMac2,1\", \"panicString\" : \"panic(cpu 0 caller 0x0): planted by vm-clear-panic-probe\\n\"}"
    printf "%s\n" "$body" | sudo -n tee "$dr/.contents.panic" >/dev/null
    { printf "{\"bug_type\":\"210\"}\n"; printf "%s\n" "$body"; } | sudo -n tee "$dr/panic-full-$stamp.0002.panic" >/dev/null
  fi
  sudo -n mkdir -p /private/var/db/PanicReporter
  sudo -n ln -sfn "$dr/.contents.panic" /private/var/db/PanicReporter/current.panic
  sync
' >/dev/null 2>&1
pending && ok "panic planted" || no "could not plant the panic"
tart stop "$VM" >/dev/null 2>&1   # the forced restart: a hard power-off
for i in $(seq 1 30); do running || break; sleep 1; done
boot
pending && ok "still pending after a hard power-off and boot" || no "the planted panic did not survive the restart"
reporter_up 90 && ok "Diagnostics Reporter raised the alert at boot (the defect)" \
               || no "Diagnostics Reporter never started — the repro did not reproduce"

echo "== 2. tart_clear_panic clears it =="
since="$(mktemp)"; sleep 1
crc=0; tart_clear_panic "$VM" || crc=$?
[ "$crc" = 1 ] && ok "-> 1: $TART_PANIC_NOTE" || no "clear returned $crc: $TART_PANIC_NOTE"
pending && no "current.panic is still there" || ok "current.panic is gone"
sleep 3
tart exec "$VM" pgrep -x 'Diagnostics Reporter' >/dev/null 2>&1 && no "the alert's process is still running" || ok "the alert is closed"
[ -n "$(find "$ART/guest-panics" -name 'panic-full-*.panic' -newer "$since" 2>/dev/null)" ] \
  && ok "report copied to $ART/guest-panics" || no "report not copied out"
rm -f "$since"

echo "== 3. nothing pending -> 0 =="
crc=0; tart_clear_panic "$VM" || crc=$?
[ "$crc" = 0 ] && ok "second call -> 0" || no "second call returned $crc: $TART_PANIC_NOTE"

echo "== 4. it stays gone across a restart =="
tart_stop_clean "$VM"; BOOTED=0
boot
pending && no "a panic is pending again after the restart" || ok "nothing pending after the restart"
# A new real panic from that shutdown would be pending here too; say so rather than blame the clear.
reporter_up 45 && no "Diagnostics Reporter started again (a new panic from the shutdown? $(tart exec "$VM" bash -lc 'ls /Library/Logs/DiagnosticReports | grep panic-full' 2>/dev/null))" \
               || ok "no alert at boot"

echo
echo "vm-clear-panic-probe: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
