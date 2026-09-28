#!/usr/bin/env bash
# tidy.sh — the daemon's between-cycle upkeep, for an agent that works the queue while the daemon is stopped.
#
# The daemon runs two things after every session: compact-plan.sh, which keeps .maintenance/AUTONOMOUS_PLAN.md
# small, and housekeeping(), which removes spent worktrees. Neither ran from 2026-08-13 to 2026-09-28, while
# Codex worked the queue with the daemon stopped: the plan grew to 157 KB against its 150 KB budget, and nine
# merged worktrees (about 3.7 GB) were left in ~/Claude. CODEX_RUNBOOK.md runs this before the first item and
# after each hand-off.
#
# It runs the SAME code the daemon runs: compact-plan.sh as-is, and housekeeping() extracted from
# archive-suite-autonomous.sh (as tests/prove-housekeeping.sh does), so there is one implementation of each.
# Housekeeping removes only worktrees on wt/* or codex/* branches that are merged into origin/main, with a
# plain `git worktree remove` that git refuses on any uncommitted or untracked content.
#
# USAGE:  ops/autonomous/tidy.sh [PRIMARY_CHECKOUT]   (defaults to this script's checkout's primary)
# EXIT:   0 done · 2 refused (the daemon is running; it does this itself)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${1:-}" ]; then REPO="$1"
else
  gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || { echo "tidy: $HERE is not inside a checkout; pass the primary checkout's path" >&2; exit 1; }
  REPO="$(dirname "$gcd")"
fi
[ -f "$REPO/.maintenance/AUTONOMOUS_PLAN.md" ] || { echo "tidy: no plan at $REPO/.maintenance — not the primary checkout?" >&2; exit 1; }

# The daemon, or its launchd job, would tidy between its own cycles. (A prove-daemon.sh sandbox daemon also
# matches the pattern; refusing while one runs is harmless.)
if pgrep -f 'archive-suite-autonomous\.sh' >/dev/null 2>&1 \
   || launchctl print "gui/$(id -u)/com.archivesuite.autonomous" >/dev/null 2>&1; then
  echo "tidy: the daemon (or its launchd job) is up and tidies between its own cycles — not touching anything." >&2
  exit 2
fi

echo "== compact-plan ($REPO)"
bash "$HERE/compact-plan.sh" "$REPO"; rc=$?
[ "$rc" = 0 ] || echo "tidy: compact-plan.sh exited $rc — a pass aborted and left the plan untouched (detail above)."

echo "== housekeeping"
log() { echo "  $*"; }
STATE=""   # no daemon state: housekeeping's once-per-change log dedupe is off, so it always reports
eval "$(awk '/^housekeeping\(\) \{/{f=1} f{print} /^\}/{if(f)exit}' "$HERE/archive-suite-autonomous.sh")"
declare -F housekeeping >/dev/null || { echo "tidy: could not load housekeeping() from the daemon script" >&2; exit 1; }
# Unlike the daemon, tidy runs while an agent may be INSIDE a worktree it just made: a fresh or fully pushed one
# is merged and clean, so housekeeping would remove it. Lock every wt/ or codex/ worktree touched in the last
# 3 hours for the duration (git refuses to remove a locked worktree), then unlock only the ones locked here.
locked=""
while IFS=$'\t' read -r dir ref; do
  case "$ref" in refs/heads/wt/*|refs/heads/codex/*) ;; *) continue ;; esac
  [ -n "$(find "$dir" -type f -mmin -180 -not -path '*/build/*' -print 2>/dev/null | head -1)" ] || continue
  git -C "$REPO" worktree lock --reason "tidy.sh: recently active" "$dir" 2>/dev/null && locked="$locked"$'\n'"$dir"
done < <(git -C "$REPO" worktree list --porcelain | awk '/^worktree /{w=substr($0,10)} /^branch /{print w"\t"substr($0,8)}')
housekeeping
printf '%s\n' "$locked" | while read -r dir; do [ -n "$dir" ] && git -C "$REPO" worktree unlock "$dir"; done
[ -n "$locked" ] && echo "  (kept, recently active:$(printf '%s' "$locked" | tr '\n' ' '))"
git -C "$REPO" worktree list
exit 0
