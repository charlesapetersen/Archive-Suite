#!/usr/bin/env bash
# gate hook: runs ops/autonomous/health-gate.sh unchanged, passes its log through, and ends with the verdict in
# the form CONTRACT.md section 2 asks for:
#   HEALTH GATE: GREEN                                   exit 0
#   HEALTH GATE: RED — <step>, <step>                    exit 1
#   HEALTH GATE CLASS: doc|code|mixed                    (after a RED line)
#   no verdict at all (killed, refused, cannot start)    exit 3, inconclusive
# The step names are read from the gate's own RED line the way the daemon's _classify_red does; a document
# step is `context-budget`, the only step that measures document size. Heavy: the engine runs it under the
# heavy lock. It writes only what the gate writes (build products).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
log="$(mktemp -t agent-gate)" || exit 3
trap 'rm -f "$log"' EXIT
bash "$SCRIPTS/health-gate.sh" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
vline="$(grep -m1 '^HEALTH GATE: RED' "$log")"
if [ -n "$vline" ]; then
  steps="$(printf '%s' "$vline" | sed 's/^HEALTH GATE: RED[^A-Za-z0-9]*//' | tr -s ' ' | sed 's/^ *//; s/ *$//')"
  list=""; doc=0; code=0
  oldifs="$IFS"; IFS=' '   # split on spaces explicitly, as _classify_red does (bash 3.2: no empty-array expansion)
  for s in $steps; do
    list="${list:+$list, }$s"
    case "$s" in context-budget) doc=1 ;; *) code=1 ;; esac
  done
  IFS="$oldifs"
  [ -n "$list" ] || { list="unnamed"; code=1; }
  echo "HEALTH GATE: RED — $list"
  if [ "$doc" = 1 ] && [ "$code" = 1 ]; then echo "HEALTH GATE CLASS: mixed"
  elif [ "$doc" = 1 ]; then echo "HEALTH GATE CLASS: doc"
  else echo "HEALTH GATE CLASS: code"; fi
  exit 1
fi
if [ "$rc" = 0 ] && grep -q '^HEALTH GATE: GREEN' "$log"; then
  echo "HEALTH GATE: GREEN"
  exit 0
fi
echo "health-gate.sh gave no verdict (exit $rc): inconclusive"
exit 3
