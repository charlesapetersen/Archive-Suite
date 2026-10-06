#!/usr/bin/env bash
# Source before changing cwd or taking another lock. Re-enter the caller under
# the supervisor; validated descendants continue without replacing caller traps.
# Old installed supervisors do not know lock-wait liveness or acquisition timing.
# Keep their unattended scripts on the old path until the owner restarts them.
if [ "${ARCHIVE_UNATTENDED:-0}" = 1 ] && [ "${AUTONOMOUS_HEAVY_ENABLED:-0}" != 1 ]; then
  return 0
fi
_heavy_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/heavy-run.py"
if python3 "$_heavy_helper" enter; then
  :
else
  _heavy_rc=$?
  [ "$_heavy_rc" = 1 ] || exit "$_heavy_rc"
  exec python3 "$_heavy_helper" run -- bash "$0" "$@"
fi
unset _heavy_helper _heavy_rc
