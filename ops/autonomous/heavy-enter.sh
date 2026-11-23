#!/usr/bin/env bash
# Source before changing cwd or taking another lock. Re-enter the caller under
# the supervisor; validated descendants continue without replacing caller traps.
_heavy_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/heavy-run.py"
if python3 "$_heavy_helper" enter; then
  :
else
  _heavy_rc=$?
  [ "$_heavy_rc" = 1 ] || exit "$_heavy_rc"
  exec python3 "$_heavy_helper" run -- bash "$0" "$@"
fi
unset _heavy_helper _heavy_rc
