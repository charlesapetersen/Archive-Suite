#!/usr/bin/env bash
# PreToolUse(Bash) hook — no unattended session contacts Sherlock (owner, 2026-10-22).
#
# Sherlock's /etc/agents rules forbid agent sessions that a supervisor starts or feeds while nobody is there, and
# they cover tools that drive it over SSH. The engine prepares a (cluster: sherlock) item on the Mac and hands it to
# an owner-started session (root CLAUDE.md, "Cluster work runs on Sherlock"). cluster-reach.py never preflights it;
# this hook is the boundary for everything else: the owner's ~/.ssh/cm-sherlock master stays open for hours after a
# login, and any command could otherwise ride it.
#
# SCOPE — unattended only (ARCHIVE_UNATTENDED=1, exported by the daemon). An owner-started session is untouched.
# CONTRACT: exit 0 = allow (silent); exit 2 = DENY with the reason on stderr. Fail-OPEN on an internal error.
set -uo pipefail

[ "${ARCHIVE_UNATTENDED:-0}" = "1" ] || exit 0

payload="$(cat 2>/dev/null)" || exit 0
[ -n "$payload" ] || exit 0
cmd=""
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
fi
if [ -z "$cmd" ] && command -v python3 >/dev/null 2>&1; then
  cmd="$(printf '%s' "$payload" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null)"
fi
[ -n "$cmd" ] || exit 0

case "$cmd" in
  *sherlock.stanford.edu*|*cm-sherlock*)
    cat >&2 <<'MSG'
BLOCKED by .claude/hooks/no-sherlock.sh — a command that reaches Sherlock (its hosts or the cm-sherlock socket).

This is an UNATTENDED session (ARCHIVE_UNATTENDED=1). Sherlock's rules forbid supervisor-driven agent sessions, so
the engine never contacts it, not even to look.

Do this instead: finish the item's Mac-side preparation, write the submit command and job count in
execution-plans/items/<TAG>.md, run `ops/autonomous/plan-edit.sh .maintenance/AUTONOMOUS_PLAN.md hold TAG
'ready to submit: <command>'`, add a Daemon Report line (no decision), and pick another item.
MSG
    exit 2 ;;
esac
exit 0
