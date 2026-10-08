#!/usr/bin/env bash
# gate hook: runs ops/autonomous/health-gate.sh unchanged, passes its log through, and ends with the verdict in
# the form CONTRACT.md section 2 asks for:
#   HEALTH GATE: GREEN                                   exit 0
#   HEALTH GATE: RED — <step>, <step>                    exit 1
#   HEALTH GATE CLASS: doc|code|mixed                    (after a RED line)
#   HEALTH GATE: SKIPPED — <reason>                      exit 3
# The one skip code: health-gate.sh exits 3 when it runs inside the Codex sandbox, where it refuses to launch
# apps (its own header). Any other nonzero exit without a RED line (killed, cannot cd, a tool missing) is RED,
# named "no verdict (exit N)", because the daemon reads every nonzero gate exit as RED. Exit 0 is GREEN, as the
# daemon reads it.
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
if [ "$rc" = 0 ]; then
  echo "HEALTH GATE: GREEN"
  exit 0
fi
if [ "$rc" = 3 ]; then
  echo "HEALTH GATE: SKIPPED — health-gate.sh exit 3: it refuses to launch apps inside the Codex sandbox"
  exit 3
fi
echo "HEALTH GATE: RED — no verdict (exit $rc)"
echo "HEALTH GATE CLASS: code"
exit 1
