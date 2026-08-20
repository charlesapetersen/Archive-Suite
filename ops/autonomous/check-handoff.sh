#!/usr/bin/env bash
# check-handoff.sh — the ONE mechanical gate an agent runs before saying "the batch is done".
#
# WHY THIS EXISTS. `AGENTS.md` §"Working the to-do list as an external agent" has carried a six-item
# handoff checklist since the 2026-07-29 Codex handoff, and every item on it is a real repair someone had
# to do by hand afterwards. A prose checklist is not a gate, though: on 2026-08-13 a pre-restart readiness
# audit found 27 open `SUITE_TODO` items with no checkbox line anywhere in the daemon's plan — invisible to
# `next-queue-item.sh`, so the daemon would have skipped them in silence, with no error anywhere.
#
# ⚠️ AND THE CULPRIT WAS NOT THE EXTERNAL AGENT. Attribution of all 27 (`git log -S<tag> -- SUITE_TODO.md`)
# put every one of them in a commit written in this project's OWN convention — `fix(notes): W23.m14 — …`,
# `fix(ops): two status lines that lied`, `docs(trackers): …`. Three came from one commit (`c0be2cc`) and
# two more from another (`763eade`): the signature of a session closing a parent item, filing the `-fu`
# follow-up it just discovered into `SUITE_TODO`, and never mirroring it into the plan. So the failure mode
# belongs to whoever is at the keyboard — daemon, interactive session, or Codex — which is exactly why this
# script takes no argument about who you are.
#
# Read-only with respect to worktrees: it runs no build and edits no tracked file or plan. The default FULL
# mode fetches remote refs to verify the published state and is the final external-agent handoff check.
# `HANDOFF_MODE=visibility` is the health-gate subset: it deliberately checks only that every open tracker item
# is visible in the primary plan. It neither fetches nor judges mid-session worktrees, so a daemon can use it
# at every periodic gate without confusing active work for a failed handoff.
#
# Usage:  ./ops/autonomous/check-handoff.sh                         # full handoff, from any checkout
#         HANDOFF_OFFLINE=1 ./ops/autonomous/check-handoff.sh       # intentional offline full handoff
#         HANDOFF_EXPECT_OPEN=0 ./ops/autonomous/check-handoff.sh   # intentional final closure only
#         HANDOFF_MODE=visibility ./ops/autonomous/check-handoff.sh # gate-safe tracker→plan check
# Exit:   0 = clean · 1 = at least one FAIL · 2 = invalid input or mode
set -uo pipefail

# Resolve the PRIMARY checkout from wherever we are — a worktree's common dir points at it. Never write a
# bare `cd "$REPO"`: with REPO unset that is `cd ""`, which bash and zsh treat as a silent no-op (rc 0).
git rev-parse --git-dir >/dev/null 2>&1 || { echo "check-handoff: not inside a git repo" >&2; exit 2; }
TREE="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -d "$TREE" ] || { echo "check-handoff: cannot resolve the checkout being checked" >&2; exit 2; }
# `--git-common-dir` answers RELATIVELY (`.git`) when you are standing in the primary checkout and
# absolutely when you are in a worktree, so `dirname` alone yields `.` in the primary case. `git worktree
# list` always answers absolutely, and step 1 identifies the primary by comparing against this value — so
# a relative ROOT made the primary checkout fail to match and get reported as a stray worktree. Resolve it.
ROOT="$(cd "$(dirname "$(git rev-parse --git-common-dir)")" 2>/dev/null && pwd)"
[ -d "$ROOT" ] || { echo "check-handoff: cannot resolve the primary checkout" >&2; exit 2; }
PLAN="${AUTONOMOUS_PLAN:-$ROOT/.maintenance/AUTONOMOUS_PLAN.md}"
# The plan is deliberately primary-only (it is ignored), but a handoff from a worktree must inspect THAT
# checkout's uncommitted SUITE_TODO edit. Otherwise the exact moment a follow-up is filed but not mirrored
# reads green because the primary still has the old tracker.
TODO="${AUTONOMOUS_TODO:-$TREE/SUITE_TODO.md}"
HANDOFF_EXPECT_OPEN="${HANDOFF_EXPECT_OPEN:-1}"
case "$HANDOFF_EXPECT_OPEN" in
  ''|*[!0-9]*) echo "check-handoff: HANDOFF_EXPECT_OPEN must be a non-negative integer (got '$HANDOFF_EXPECT_OPEN')" >&2; exit 2 ;;
esac
HANDOFF_OFFLINE="${HANDOFF_OFFLINE:-0}"
case "$HANDOFF_OFFLINE" in
  0|1) ;;
  *) echo "check-handoff: HANDOFF_OFFLINE must be 0 or 1 (got '$HANDOFF_OFFLINE')" >&2; exit 2 ;;
esac
HANDOFF_MODE="${HANDOFF_MODE:-full}"
case "$HANDOFF_MODE" in
  full|visibility) ;;
  *) echo "check-handoff: HANDOFF_MODE must be full or visibility (got '$HANDOFF_MODE')" >&2; exit 2 ;;
esac
# NB: SUITE_TODO_DONE.md is deliberately NOT read here, unlike in check-tracker-sync.sh. Step 3 asks only
# "is every OPEN item visible in the plan", and a shipped item is not open — so the archive cannot answer it.
# (check-tracker-sync.sh must read the archive for a different question: whether the two files AGREE on state.)

fails=0; warns=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗ FAIL\033[0m %s\n' "$*"; fails=$((fails + 1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; warns=$((warns + 1)); }
head_() { printf '\n\033[1m── %s\033[0m\n' "$*"; }

echo "check-handoff: primary checkout $ROOT"
[ "$TREE" = "$ROOT" ] || echo "check-handoff: tracker checkout $TREE (plan remains primary-only)"
[ "$HANDOFF_MODE" = visibility ] && echo "check-handoff: visibility mode (no remote/worktree handoff checks)"

# ---------------------------------------------------------------------------------------------------
if [ "$HANDOFF_MODE" = full ]; then
head_ "1. no worktree is holding uncommitted work"
# A STRAY worktree is tolerable (the owner said so explicitly): the daemon's housekeeping GCs a clean,
# already-merged one by itself. Uncommitted work inside one is NOT tolerable — that is the near-miss of
# 2026-08-13 (107 green lines, zero commits) and the actual loss of 2026-07-29 (~2,900 lines, 12 days
# stale, 76 commits behind). Note housekeeping's `git worktree remove` does not refuse a worktree whose
# only content is gitignored, so "it has a build dir" protects nothing.
dirty_wt=0
while IFS= read -r wt; do
  [ -n "$wt" ] || continue
  [ "$wt" = "$ROOT" ] && continue
  # A FAILED `status` also yields empty stdout, so ask about the exit code before reading the output —
  # a moved/deleted worktree dir, a locked index or a stale gitdir must not read as "clean".
  if ! st="$(git -C "$wt" status --porcelain 2>/dev/null)"; then
    fail "cannot read status of $wt (moved, deleted without prune, locked, or permissions) — judge by hand"
    dirty_wt=1
  elif [ -n "$st" ]; then
    fail "worktree has UNCOMMITTED work: $wt"
    git -C "$wt" status --porcelain 2>/dev/null | sed 's/^/       /'
    dirty_wt=1
  else
    # ⚠️ NEVER use `@{u}..HEAD` here. A worktree branch created with `git worktree add -b` has NO upstream,
    # `git log @{u}..HEAD` then FATALS to suppressed stderr, `wc -l` counts an empty stream as 0, and the
    # worktree was reported "clean" however many unpushed commits it held — a false CLEAN on precisely the
    # 2026-07-29 loss this step exists to prevent. Reproduced 2026-08-13 with a one-commit probe worktree.
    # This repo integrates on ONE branch, so compare against `origin/main` and never mind the upstream.
    base="$(git -C "$wt" rev-parse --verify -q origin/main 2>/dev/null)"
    if [ -z "$base" ]; then
      fail "cannot resolve origin/main from $wt — unable to judge whether its commits are pushed"
      dirty_wt=1
    elif ! unpushed="$(git -C "$wt" rev-list --count "$base"..HEAD 2>/dev/null)" || [ -z "$unpushed" ]; then
      fail "cannot count commits in $wt (detached HEAD, or a broken gitdir) — judge it by hand"
      dirty_wt=1
    elif [ "$unpushed" -gt 0 ]; then
      fail "worktree has $unpushed commit(s) NOT on origin/main: $wt"
      dirty_wt=1
    else
      warn "stray worktree, clean (fine — housekeeping will GC it once merged): $wt"
    fi
  fi
done < <(git -C "$ROOT" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}')
[ "$dirty_wt" = 0 ] && ok "no worktree is holding uncommitted or unpushed work"

# ---------------------------------------------------------------------------------------------------
head_ "2. the PRIMARY checkout is level with origin/main"
# The daemon reads the plan from the primary checkout, measures review deltas against ITS HEAD, and
# `daemon.sh` installs the daemon scripts from ITS working tree — so a lagging primary silently
# re-installs stale daemon scripts the next time the owner starts it.
remote_ready=0
if git -C "$ROOT" fetch origin --quiet 2>/dev/null && git -C "$ROOT" rev-parse --verify -q origin/main >/dev/null 2>&1; then
  remote_ready=1
elif [ "$HANDOFF_OFFLINE" = 1 ]; then
  warn "could not fetch or resolve origin/main — HANDOFF_OFFLINE=1 accepts no remote comparison"
else
  fail "could not fetch and resolve origin/main — cannot verify the primary is published (set HANDOFF_OFFLINE=1 only for an intentional offline handoff)"
fi
if [ "$remote_ready" = 1 ] && counts="$(git -C "$ROOT" rev-list --left-right --count HEAD...origin/main 2>/dev/null)"; then
  ahead="$(echo "$counts" | cut -f1)"; behind="$(echo "$counts" | cut -f2)"
  [ "$behind" = 0 ] || fail "primary is $behind commit(s) BEHIND origin/main — run: git -C \"\$primary\" merge --ff-only origin/main"
  [ "$ahead"  = 0 ] || fail "primary is $ahead commit(s) AHEAD of origin/main (unpushed)"
  [ "$behind" = 0 ] && [ "$ahead" = 0 ] && ok "primary == origin/main"
elif [ "$remote_ready" = 1 ]; then
  fail "cannot compare primary HEAD with origin/main — judge neither as published"
fi

if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
  fail "primary checkout tree is DIRTY — the health gate's coherence step requires it clean"
  git -C "$ROOT" status --porcelain 2>/dev/null | sed 's/^/       /'
else
  ok "primary checkout tree is clean"
fi
fi

# ---------------------------------------------------------------------------------------------------
head_ "3. every open SUITE_TODO item is VISIBLE in the plan"
# This is the 27-item gap. `next-queue-item.sh` walks the plan's `## WORK QUEUE`; an item filed only in
# `SUITE_TODO` is skipped with no error. `check-tracker-sync.sh` cannot see it either — it compares the
# items the two files SHARE, so an item present in one and absent from the other is outside its question.
# Parking an owner-gated item in `## HOLD QUEUE` counts as visible: it is not offered, but it IS counted.
if [ ! -f "$PLAN" ]; then
  if [ "$HANDOFF_MODE" = visibility ]; then
    fail "no plan at $PLAN — the daemon has nowhere to see newly filed work"
  else
    warn "no plan at $PLAN — skipping (nothing to hand off to)"
  fi
elif [ ! -f "$TODO" ]; then
  fail "no SUITE_TODO.md at $TODO"
else
  # Same tag grammar as check-tracker-sync.sh: strip bold markers AND an optional leading backtick.
  items() {
    awk -v region="$2" -v bad="$3" -v source="$4" '
      function emit(  st, t, id) {
        st = (tolower($0) ~ /\[x\]/) ? "x" : " "
        match($0, /^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]*/)
        t = substr($0, RLENGTH + 1)
        sub(/^\*+[[:space:]]*/, "", t)
        sub(/^`/, "", t)
        if (match(t, /^[A-Za-z0-9][A-Za-z0-9._-]*/)) {
          id = substr(t, 1, RLENGTH)
          # Preserve duplicate first words. The exemption file authorizes one specific item, not every later
          # bullet that happens to begin the same way; comm below consumes that one exemption and leaves a
          # second unmatched occurrence loud instead of silently applying first-occurrence-wins.
          print id "\t" st
        } else if (st == " ") {
          # A visible open checkbox needs a real tag. Keep its complete source line for the diagnostic rather
          # than allowing a punctuation-led item to disappear before the plan comparison sees it.
          print source ": " $0 > bad
        }
      }
      # W32.fence-order — fence rule FIRST, matching next-queue-item.sh (and check-tracker-sync.sh, fixed
      # with it). A column-0 `## ` inside a fenced example otherwise truncates the region here but not in the
      # resolver, hiding every item below it. Same bug, same file-pair; fixed in both so they cannot drift.
      /^[[:space:]]*(```|~~~)/ { infence = !infence; next }
      infence                  { next }
      /^[[:space:]]*>/         { next }
      region && /^## (WORK|HOLD) QUEUE/ { inq = 1; next }
      region && inq && /^## /           { inq = 0 }
      region && !inq                    { next }
      /^[[:space:]]*[-*][[:space:]]+\[[ xX]\]/ { emit() }
    ' "$1"
  }
  P="$(mktemp)"; T="$(mktemp)"; BP="$(mktemp)"; BT="$(mktemp)"
  trap 'rm -f "$P" "$T" "$BP" "$BT"' EXIT
  # Do not de-duplicate here. `comm`'s multiplicity means a real exemption consumes exactly one matching
  # open item; a second bullet starting with the same first word remains missing and cannot be swallowed.
  items "$PLAN" 1 "$BP" "primary plan" | cut -f1 | sort > "$P"
  items "$TODO" 0 "$BT" "SUITE_TODO" | awk -F'\t' '$2==" "{print $1}' | sort > "$T"
  open_count="$(wc -l < "$T" | tr -d '[:space:]')"
  open_floor_ok=1
  if [ "$open_count" -lt "$HANDOFF_EXPECT_OPEN" ]; then
    fail "only $open_count parsable open SUITE_TODO item(s) in $TODO (need >= $HANDOFF_EXPECT_OPEN) — an empty or unparseable tracker cannot be handed off; set HANDOFF_EXPECT_OPEN=0 only for an intentional final closure"
    open_floor_ok=0
  fi
  unparseable="$(cat "$BP" "$BT")"
  if [ -n "$unparseable" ]; then
    n_unparseable="$(printf '%s\n' "$unparseable" | grep -c .)"
    fail "$n_unparseable UNPARSEABLE OPEN ITEM(s) cannot be handed off — every item needs an alphanumeric tag:"
    printf '%s\n' "$unparseable" | while IFS= read -r bad; do
      [ -n "$bad" ] && printf '       \033[31m⚠ UNPARSEABLE ITEM\033[0m — %s\n' "$bad"
    done
    open_floor_ok=0
  fi
  # Some items are deliberately in NEITHER region because their own spec forbids both — out of scope until a
  # qualitative bar is met, which is NOT the same as awaiting an owner gate (parking those in HOLD QUEUE
  # mislabels them and makes the "held back" count lie). Those tags live in handoff-exempt.txt with a citation.
  EX="$(mktemp)"; trap 'rm -f "$P" "$T" "$EX"' EXIT
  # Beside THIS script, not under $ROOT: the list and the rule that reads it ship together, so running a
  # worktree's copy honours that worktree's list. ($ROOT is the primary checkout, which is a different tree.)
  exempt_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/handoff-exempt.txt"
  if [ -f "$exempt_file" ]; then
    grep -vE '^[[:space:]]*(#|$)' "$exempt_file" | awk '{print $1}' | sort -u > "$EX"
  else
    : > "$EX"
  fi
  missing="$(comm -23 "$T" "$P" | comm -23 - "$EX")"
  exempted="$(comm -23 "$T" "$P" | comm -12 - "$EX")"
  [ -n "$exempted" ] && printf '%s\n' "$exempted" | while read -r t; do
    [ -n "$t" ] && printf '  \033[36mi\033[0m %s — in neither region ON PURPOSE (ops/autonomous/handoff-exempt.txt)\n' "$t"
  done
  if [ -n "$missing" ]; then
    n="$(printf '%s\n' "$missing" | grep -c .)"
    fail "$n open SUITE_TODO item(s) have NO checkbox line in the plan — the daemon cannot see them:"
    printf '%s\n' "$missing" | sed 's/^/       /'
    echo "       → mirror the daemon-buildable ones into '## WORK QUEUE' as one-liners with BYTE-IDENTICAL"
    echo "         tags (so blocked-on resolves), and park the owner-gated ones in '## HOLD QUEUE'."
  elif [ "$open_floor_ok" = 1 ]; then
    ok "every open SUITE_TODO item has a checkbox line in the plan"
  fi
fi

if [ "$HANDOFF_MODE" = visibility ]; then
  printf '\n'
  if [ "$fails" -gt 0 ]; then
    printf '\033[31mHANDOFF VISIBILITY: %d FAIL(s)\033[0m — mirror the tracker item before the daemon can continue.\n' "$fails"
    exit 1
  fi
  printf '\033[32mHANDOFF VISIBILITY: CLEAN\033[0m\n'
  exit 0
fi

# ---------------------------------------------------------------------------------------------------
head_ "4. the two trackers agree on the items they share"
if [ -x "$ROOT/ops/autonomous/check-tracker-sync.sh" ]; then
  if out="$("$ROOT/ops/autonomous/check-tracker-sync.sh" 2>&1)"; then
    printf '%s\n' "$out" | sed 's/^ *//; s/^/  /'
  else
    fail "check-tracker-sync.sh reports a disagreement:"; printf '%s\n' "$out" | sed 's/^/       /'
  fi
else
  warn "check-tracker-sync.sh not found or not executable"
fi
if [ -x "$ROOT/ops/autonomous/check-todo-stubs.sh" ]; then
  if out="$("$ROOT/ops/autonomous/check-todo-stubs.sh" 2>&1)"; then
    printf '%s\n' "$out" | sed 's/^ *//; s/^/  /'
  else
    fail "check-todo-stubs.sh: a shipped item is still ticked in place in SUITE_TODO.md:"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
fi

# ---------------------------------------------------------------------------------------------------
head_ "5. the repo's PROSE does not contradict its own policy"
# The gap that let a policy change be inert in ten places while every other check stayed green: the others all
# read checkbox and byte state, none reads prose. See check-policy-coherence.sh's header for the incident.
if [ -x "$(dirname "${BASH_SOURCE[0]}")/check-policy-coherence.sh" ]; then
  if out="$("$(dirname "${BASH_SOURCE[0]}")/check-policy-coherence.sh" 2>&1)"; then
    printf '%s\n' "$out" | tail -1 | sed 's/^/  /'
  else
    fail "check-policy-coherence.sh reports the prose contradicting current policy:"
    printf '%s\n' "$out" | sed -n '/──/,$p' | sed 's/^/     /'
  fi
else
  warn "check-policy-coherence.sh not found or not executable"
fi

head_ "6. eyeball what the daemon would pick up next"
# AGENTS.md's own closing instruction: confirm the first `ok` line is the item you INTEND to be next, and
# that nothing you just finished still appears. Only a human can judge that, so this prints, never fails.
if [ -x "$ROOT/ops/autonomous/next-queue-item.sh" ]; then
  "$ROOT/ops/autonomous/next-queue-item.sh" 2>/dev/null | grep '^ok' | head -3 | cut -c1-150 | sed 's/^/  → /'
  echo "  (is the first line the item you intend? does anything you just finished still appear?)"
else
  warn "next-queue-item.sh not found or not executable"
fi

# ---------------------------------------------------------------------------------------------------
printf '\n'
if [ "$fails" -gt 0 ]; then
  printf '\033[31mHANDOFF: %d FAIL(s)\033[0m%s — fix these before saying the batch is done.\n' \
    "$fails" "$([ "$warns" -gt 0 ] && printf ', %d warning(s)' "$warns")"
  exit 1
fi
printf '\033[32mHANDOFF: CLEAN\033[0m%s\n' "$([ "$warns" -gt 0 ] && printf ' (%d warning(s) — read them, none is blocking)' "$warns")"
exit 0
