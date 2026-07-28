#!/usr/bin/env bash
# prove-housekeeping.sh — proves housekeeping()'s worktree/branch GC scope + safety.
#
# Extracts the REAL housekeeping() from archive-suite-autonomous.sh (no replica) and runs it
# against a scratch repo covering every worktree state, asserting the widened-scope contract:
#   * ANY merged + clean wt/* worktree is reclaimed (autonomous slug OR improvised slug — the
#     fix that stops improvised-slug build/DD from piling up over a multi-day run).
#   * A worktree with uncommitted/untracked-non-ignored content is KEPT (plain remove refuses).
#   * A clean but UNPUSHED worktree is KEPT (merged gate: not an ancestor of origin/main).
#   * The primary checkout is never touched.
# Self-contained, no network, no TCC; safe to run anywhere. Scratch repo is auto-removed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../archive-suite-autonomous.sh"
[ -f "$SRC" ] || { echo "cannot find daemon script at $SRC"; exit 2; }
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/prove-hk.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
cd "$ROOT"

git init -q --bare origin.git
git clone -q origin.git main 2>/dev/null
cd main
git config user.email t@t; git config user.name t
printf 'build/\n' > .gitignore
git add -A && git commit -qm init
git push -q origin HEAD:main
git branch --set-upstream-to=origin/main "$(git rev-parse --abbrev-ref HEAD)" 2>/dev/null
REPO="$ROOT/main"

mkwt() { git -C "$REPO" worktree add -q "$REPO/../$1" -b "$2" origin/main 2>/dev/null; }
mkwt a-auto        wt/autonomous-x1                                   # merged+clean          -> removed
mkwt b-notes       wt/notes-w3s1                                      # merged+clean (slug)   -> removed (FIX)
mkwt c-buildonly   wt/review-net-y                                    # merged, only build/   -> removed
mkdir -p "$REPO/../c-buildonly/build/DD"; echo x > "$REPO/../c-buildonly/build/DD/art"
mkwt d-dirty       wt/w15tu1-undo                                     # merged+dirty tracked  -> kept
echo mod >> "$REPO/../d-dirty/.gitignore"
mkwt e-unpushed    wt/feature-unpushed                               # clean but unpushed    -> kept
( cd "$REPO/../e-unpushed" && echo n > n.txt && git add -A && git commit -qm wip )
mkwt f-auto-dirty  wt/autonomous-x2                                   # untracked non-ignored -> kept
echo untracked > "$REPO/../f-auto-dirty/new.txt"

# extract & source the actual function; stub the daemon logger
awk '/^housekeeping\(\) \{/{f=1} f{print} /^\}/{if(f)exit}' "$SRC" > "$ROOT/hk.fn"
log() { :; }
# shellcheck disable=SC1090
source "$ROOT/hk.fn"
housekeeping

fail=0
gone(){ [ ! -e "$REPO/../$1" ] && echo "PASS: $1 removed ($2)" || { echo "FAIL: $1 STILL PRESENT (want removed: $2)"; fail=1; }; }
kept(){ [ -e "$REPO/../$1" ] && echo "PASS: $1 kept ($2)" || { echo "FAIL: $1 REMOVED (want kept: $2)"; fail=1; }; }
gone a-auto      "autonomous slug, merged+clean"
gone b-notes     "improvised slug, merged+clean — THE FIX"
gone c-buildonly "improvised slug, merged, only gitignored build/"
kept d-dirty     "merged but dirty tracked file"
kept e-unpushed  "clean but unpushed (merged gate)"
kept f-auto-dirty "untracked non-ignored file"
[ -e "$REPO/.git" ] && echo "PASS: primary checkout untouched" || { echo "FAIL: primary checkout gone"; fail=1; }
echo; [ $fail -eq 0 ] && echo "prove-housekeeping: ALL PASSED" || echo "prove-housekeeping: FAILURES"
exit $fail
