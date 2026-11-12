#!/usr/bin/env bash
# vm-keep-reaper.sh — stop a guest that `VM_KEEP=1 ops/gui/vm-gui-runner.sh …` left running, once nobody is
# testing (W40.vm-macos27-runtime (4)). Started detached by the runner; never run it by hand.
#
# The kept guest holds 6 GB of an 18 GB Mac, and memory pressure already holds the engine's third slot for
# hours a week (owner, 2026-11-12), so it must not stay up while nobody tests. It is stopped — cleanly, through
# tart_stop_clean, under the GUI VM lock so a run that has just started is never cut off — as soon as ANY of:
#   idle      no runner has held the GUI VM lock for VM_KEEP_IDLE seconds (default 300);
#   pressure  the Mac's memory pressure is above normal (kern.memorystatus_vm_pressure_level != 1);
#   owner     the session that kept it (the nearest `claude` ancestor of the runner) has exited;
#   signal    this reaper is sent TERM/HUP/INT.
# The next runner call boots it again. State: $VM_KEEP_STATE (key=value; the runner writes it). Every
# minute it appends one line to $VM_KEEP_LOG (epoch, Mac pressure level, kept/stop reason), which is how the
# memory pressure a kept guest adds is measured against the engine log's slot holds.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/tart-lib.sh"
STATE="${VM_KEEP_STATE:-$HOME/.tart-mirror/.vm-keep}"
LOG="${VM_KEEP_LOG:-$HOME/.tart-mirror/vm-keep.log}"
IDLE="${VM_KEEP_IDLE:-300}"
POLL="${VM_KEEP_POLL:-15}"

field() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | tail -n 1; }
note()  { printf '%s\t%s\t%s\n' "$(date +%s)" "$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)" "$*" >>"$LOG"; }

stop_guest() {   # $1 = reason
  local vm; vm="$(field vm)"
  # A runner holding the lock is testing: never stop under it. It rewrites the state when it is done.
  tart_lock_acquire 0 || { note "keep: $1, but a run holds the VM lock — not stopping"; return 1; }
  # Re-read under the lock: a runner may have just taken the guest over (it deletes the state when it does).
  if [ "$(field reaper)" = "$$" ]; then
    note "stop: $1 (vm $vm)"
    tart_stop_clean "$vm"
    rm -f "$STATE"
  fi
  tart_lock_release
  exit 0
}
trap 'stop_guest signal' TERM HUP INT

last_note=0
while :; do
  sleep "$POLL"
  [ -f "$STATE" ] || exit 0
  [ "$(field reaper)" = "$$" ] || exit 0                 # superseded by a newer reaper
  vm="$(field vm)"
  tart list 2>/dev/null | awk -v v="$vm" '$2==v && $NF=="running"{f=1} END{exit !f}' \
    || { note "gone: vm $vm is not running"; rm -f "$STATE"; exit 0; }
  now="$(date +%s)"
  # A run is on (its pid is alive); the runner refreshes last= when it ends. A lock left by a killed run is
  # not a run: tart_lock_acquire in stop_guest breaks it.
  lock_pid="$(cat "$TART_LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then continue; fi
  level="$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 1)"
  owner="$(field owner)"; last="$(field last)"; last="${last:-0}"
  if [ "$level" != 1 ]; then stop_guest "pressure level $level"
  elif [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then stop_guest "owner session $owner exited"
  elif [ $(( now - last )) -ge "$IDLE" ]; then stop_guest "idle $(( now - last )) s"
  fi
  [ $(( now - last_note )) -ge 60 ] && { note "kept: idle $(( now - last )) s"; last_note="$now"; }
done
