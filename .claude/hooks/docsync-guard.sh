#!/usr/bin/env bash
# Stop hook — DOC-SYNC BACKSTOP. Blocks finishing the turn if this session pushed code (*.swift/*.kt) to
# origin/main without touching a tracker (SUITE_TODO.md / KNOWN_ISSUES.md) in the same range — i.e. the
# "docs move with the code, same commit" rule (root CLAUDE.md -> "How we work", step 4).
#
# Design: SessionStart records origin/main (docsync-baseline.sh); here we diff baseline..origin/main, so we
# only see what THIS session landed on main. Fail-OPEN on every error (never deadlock a session). Escapes:
#   - a change that ships no tracked item (refactor / mid-feature / infra):  touch .docsync-ok
#   - offline / nothing pushed: baseline == origin/main -> passes automatically.
# Test overrides: DOCSYNC_TEST_BASE / DOCSYNC_TEST_HEAD (commit-ish) bypass the baseline file.
#
# WHY the ack file sits at the REPO ROOT and not in .claude/ (do NOT "tidy" it back — it was moved here
# deliberately on 2026-07-28): the ack is the one file the MODEL has to create, and tool writes anywhere under
# .claude/ are refused as a sensitive path. That guard is correct — .claude/ holds settings.json + these hooks,
# so an agent that could write there could rewrite its own permissions — and the unattended daemon runs with
# `--permission-mode default`, so the refusal is auto-denied with no human to approve it. Twice on 2026-07-28
# the daemon could not ack a legitimate code-only mid-feature checkpoint (both Bash `touch` AND Write were
# blocked) and the obligation fell through to the owner's interactive session. Root-level keeps the .claude/
# guard fully intact while letting the daemon ack with its already-allowed Bash tool. The BASELINE file stays
# in .claude/ on purpose: only this hook writes it, and hooks are not subject to tool permissions.
set -uo pipefail
dir="${CLAUDE_PROJECT_DIR:-.}"
cd "$dir" 2>/dev/null || exit 0
command -v git >/dev/null 2>&1 || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# One-shot acknowledgement that the change legitimately ships no tracked item.
ack="$dir/.docsync-ok"
if [ -f "$ack" ]; then rm -f "$ack" 2>/dev/null; exit 0; fi

base_file="$dir/.claude/.docsync-baseline"
base="${DOCSYNC_TEST_BASE:-}"
[ -n "$base" ] || { [ -f "$base_file" ] && base="$(cat "$base_file" 2>/dev/null)"; }
[ -n "$base" ] || exit 0
head="${DOCSYNC_TEST_HEAD:-$(git rev-parse --verify -q origin/main 2>/dev/null)}"
[ -n "$head" ] || exit 0
[ "$base" = "$head" ] && exit 0                                   # nothing landed on main this session

files="$(git diff --name-only "$base..$head" 2>/dev/null)" || exit 0
[ -z "$files" ] && exit 0
code="$(printf '%s\n' "$files"    | grep -E '\.(swift|kt)$' || true)"
tracker="$(printf '%s\n' "$files" | grep -E '(^|/)(SUITE_TODO|KNOWN_ISSUES)\.md$' || true)"

if [ -n "$code" ] && [ -z "$tracker" ]; then
  n="$(git rev-list --count "$base..$head" 2>/dev/null || echo '?')"
  cat >&2 <<EOF
🚧 doc-sync backstop (root CLAUDE.md -> "How we work", step 4)

This session landed $n commit(s) on origin/main that change code (*.swift / *.kt), but the range touches
NEITHER SUITE_TODO.md NOR KNOWN_ISSUES.md. If a backlog item shipped, its checkbox is probably still "[ ]".

Before finishing, do ONE of:
  * flip the shipped SUITE_TODO.md checkbox (and/or update KNOWN_ISSUES.md), commit, and push; or
  * if this change ships no tracked item (refactor / mid-feature / infra), run:
        touch .docsync-ok
    and finish again (one-shot acknowledgement).
EOF
  exit 2                                                          # block the stop; stderr is fed back to the model
fi

# In sync (tracker touched, or no code) -> advance the baseline so these commits aren't re-flagged.
printf '%s\n' "$head" > "$base_file" 2>/dev/null
exit 0
