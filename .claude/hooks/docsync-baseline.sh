#!/usr/bin/env bash
# SessionStart hook — snapshot origin/main so the Stop guard (docsync-guard.sh) can tell what THIS session
# actually pushed to main. Fail-OPEN: any problem → exit 0, never disrupt a session.
set -uo pipefail
dir="${CLAUDE_PROJECT_DIR:-.}"
cd "$dir" 2>/dev/null || exit 0
command -v git >/dev/null 2>&1 || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
sha="$(git rev-parse --verify -q origin/main 2>/dev/null)" || exit 0
[ -n "$sha" ] && printf '%s\n' "$sha" > "$dir/.claude/.docsync-baseline" 2>/dev/null
exit 0
