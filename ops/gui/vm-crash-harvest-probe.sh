#!/usr/bin/env bash
# vm-crash-harvest-probe.sh — prove the crash harvest (W40.e2, tart_crash_harvest in tart-lib.sh) against
# the REAL guest, not a stub: boot the GUI VM, plant real crashes, and check the three verdicts.
#
#   1. a clean run                                  -> 0 (nothing new)
#   2. a crash of a process named like ours         -> 1, the report copied out
#      (a trapping C program compiled in the guest as ArchiveCrashProbe; ReportCrash writes the .ips)
#   3. a crash of a process that is not ours        -> 0, but the report is named and copied
#
# prove-vm-lane.sh §13 pins the classification against stubs; this is the check that the guest really
# writes reports where the harvest looks, which no stub can show. Takes the VM lock; ~2 minutes; $0.
# USAGE: ops/gui/vm-crash-harvest-probe.sh      ENV: VM_NAME, ART_DIR, AGENT_WAIT
set -uo pipefail
. "$(dirname "$0")/../autonomous/heavy-enter.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/tart-lib.sh"

VM="${VM_NAME:-archive-gui-runner}"
ART="${ART_DIR:-$HOME/.tart-mirror/vm-artifacts}"
REPO="$(cd "$HERE/../.." && pwd)"
SUB="crash-probe"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 2; }

tart_require || die "tart missing"
tart list 2>/dev/null | awk '{print $2}' | grep -qx "$VM" || die "VM '$VM' does not exist"
cleanup(){ [ "${BOOTED:-0}" = 1 ] && tart stop "$VM" >/dev/null 2>&1; tart_lock_release; }
trap cleanup EXIT
tart_lock_acquire "${LOCK_WAIT:-120}" || die "the GUI VM is in use (pid ${TART_LOCK_OWNER:-?})"
mkdir -p "$ART"
if ! tart list 2>/dev/null | awk -v v="$VM" '$2==v && $NF=="running"{f=1} END{exit !f}'; then
  BOOTED=1
  tart run "$VM" --no-graphics --no-clipboard --dir=repo:"$REPO" --dir=out:"$ART" >"$ART/crash-probe-tart.log" 2>&1 &
  tart ip "$VM" --wait 120 >/dev/null || die "no IP"
fi
tart_wait_agent "$VM" "${AGENT_WAIT:-240}" || die "guest agent never answered"

crash() {  # $1 = process name to compile and crash in the guest
  tart exec "$VM" bash -lc "
    d=\$(mktemp -d); printf 'int main(void){ __builtin_trap(); }\n' > \"\$d/p.c\"
    clang -o \"\$d/$1\" \"\$d/p.c\" && \"\$d/$1\"; true
  " >/dev/null 2>&1
}
harvest(){ hrc=0; tart_crash_harvest "$VM" "$SUB" || hrc=$?; }

echo "== 1. clean run =="
tart_crash_mark "$VM"
[ -n "$TART_CRASH_TOKEN" ] && ok "mark written in the guest" || no "mark not written"
harvest
[ "$hrc" = 0 ] && ok "nothing new -> 0" || no "clean run harvested as $hrc (suite: $TART_CRASH_SUITE)"

echo "== 2. a crash of a process named like ours =="
tart_crash_mark "$VM"
crash ArchiveCrashProbe
TART_CRASH_SETTLE=10 harvest
[ "$hrc" = 1 ] && ok "real ReportCrash report found -> 1: $TART_CRASH_SUITE" \
               || no "planted crash harvested as $hrc (suite='$TART_CRASH_SUITE' foreign='$TART_CRASH_FOREIGN')"
ls "$ART/$SUB"/ArchiveCrashProbe* >/dev/null 2>&1 && ok "report copied to $ART/$SUB" || no "report not copied to the host"

echo "== 3. a crash of a process that is not ours =="
tart_crash_mark "$VM"
crash OtherCrashProbe
TART_CRASH_SETTLE=10 harvest
[ "$hrc" = 0 ] && ok "foreign crash does not fail -> 0" || no "foreign crash harvested as $hrc"
case "$TART_CRASH_FOREIGN" in *OtherCrashProbe*) ok "…but it is named: $TART_CRASH_FOREIGN" ;;
  *) no "foreign crash not named (foreign='$TART_CRASH_FOREIGN')" ;; esac

echo
echo "vm-crash-harvest-probe: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
