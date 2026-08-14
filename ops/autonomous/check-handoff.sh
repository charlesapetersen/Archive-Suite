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
# Read-only: it runs no build, writes nothing, and touches no state. Safe to run at any time, including
# while the daemon is running. It is deliberately NOT wired into `health-gate.sh` yet — that is
# `W31.handoff-gate` in `SUITE_TODO.md`, since a new gate step is Tier-2 autonomous-setup discipline.
#
# Usage:  ./ops/autonomous/check-handoff.sh            # from anywhere in the repo or a worktree
# Exit:   0 = handed off cleanly · 1 = at least one FAIL · 2 = cannot run (bad repo/plan)
set -uo pipefail

# Resolve the PRIMARY checkout from wherever we are — a worktree's common dir points at it. Never write a
# bare `cd "$REPO"`: with REPO unset that is `cd ""`, which bash and zsh treat as a silent no-op (rc 0).
git rev-parse --git-dir >/dev/null 2>&1 || { echo "check-handoff: not inside a git repo" >&2; exit 2; }
# `--git-common-dir` answers RELATIVELY (`.git`) when you are standing in the primary checkout and
# absolutely when you are in a worktree, so `dirname` alone yields `.` in the primary case. `git worktree
# list` always answers absolutely, and step 1 identifies the primary by comparing against this value — so
# a relative ROOT made the primary checkout fail to match and get reported as a stray worktree. Resolve it.
ROOT="$(cd "$(dirname "$(git rev-parse --git-common-dir)")" 2>/dev/null && pwd)"
[ -d "$ROOT" ] || { echo "check-handoff: cannot resolve the primary checkout" >&2; exit 2; }
PLAN="${AUTONOMOUS_PLAN:-$ROOT/.maintenance/AUTONOMOUS_PLAN.md}"
TODO="$ROOT/SUITE_TODO.md"
DONE_FILE="$ROOT/SUITE_TODO_DONE.md"

fails=0; warns=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗ FAIL\033[0m %s\n' "$*"; fails=$((fails + 1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; warns=$((warns + 1)); }
head_() { printf '\n\033[1m── %s\033[0m\n' "$*"; }

echo "check-handoff: primary checkout $ROOT"

# ---------------------------------------------------------------------------------------------------
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
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    fail "worktree has UNCOMMITTED work: $wt"
    git -C "$wt" status --porcelain 2>/dev/null | sed 's/^/       /'
    dirty_wt=1
  else
    unpushed="$(git -C "$wt" log --oneline @{u}..HEAD 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${unpushed:-0}" != "0" ] 2>/dev/null; then
      fail "worktree has $unpushed UNPUSHED commit(s): $wt"
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
git -C "$ROOT" fetch origin --quiet 2>/dev/null || warn "could not fetch origin (offline?) — comparison may be stale"
if counts="$(git -C "$ROOT" rev-list --left-right --count HEAD...origin/main 2>/dev/null)"; then
  ahead="$(echo "$counts" | cut -f1)"; behind="$(echo "$counts" | cut -f2)"
  [ "$behind" = 0 ] || fail "primary is $behind commit(s) BEHIND origin/main — run: git -C \"\$primary\" merge --ff-only origin/main"
  [ "$ahead"  = 0 ] || fail "primary is $ahead commit(s) AHEAD of origin/main (unpushed)"
  [ "$behind" = 0 ] && [ "$ahead" = 0 ] && ok "primary == origin/main"
else
  warn "no origin/main to compare against"
fi

if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
  fail "primary checkout tree is DIRTY — the health gate's coherence step requires it clean"
  git -C "$ROOT" status --porcelain 2>/dev/null | sed 's/^/       /'
else
  ok "primary checkout tree is clean"
fi

# ---------------------------------------------------------------------------------------------------
head_ "3. every open SUITE_TODO item is VISIBLE in the plan"
# This is the 27-item gap. `next-queue-item.sh` walks the plan's `## WORK QUEUE`; an item filed only in
# `SUITE_TODO` is skipped with no error. `check-tracker-sync.sh` cannot see it either — it compares the
# items the two files SHARE, so an item present in one and absent from the other is outside its question.
# Parking an owner-gated item in `## HOLD QUEUE` counts as visible: it is not offered, but it IS counted.
if [ ! -f "$PLAN" ]; then
  warn "no plan at $PLAN — skipping (nothing to hand off to)"
elif [ ! -f "$TODO" ]; then
  fail "no SUITE_TODO.md at $TODO"
else
  # Same tag grammar as check-tracker-sync.sh: strip bold markers AND an optional leading backtick.
  items() {
    awk -v region="$2" '
      function emit(  st, t, id) {
        st = (tolower($0) ~ /\[x\]/) ? "x" : " "
        match($0, /^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]*/)
        t = substr($0, RLENGTH + 1)
        sub(/^\*+[[:space:]]*/, "", t)
        sub(/^`/, "", t)
        if (match(t, /^[A-Za-z0-9][A-Za-z0-9._-]*/)) {
          id = substr(t, 1, RLENGTH)
          if (!(id in seen)) { seen[id] = 1; print id "\t" st }
        }
      }
      region && /^## (WORK|HOLD) QUEUE/ { inq = 1; next }
      region && inq && /^## /           { inq = 0 }
      region && !inq                    { next }
      /^[[:space:]]*(```|~~~)/ { infence = !infence; next }
      infence                  { next }
      /^[[:space:]]*>/         { next }
      /^[[:space:]]*[-*][[:space:]]+\[[ xX]\]/ { emit() }
    ' "$1"
  }
  P="$(mktemp)"; T="$(mktemp)"; trap 'rm -f "$P" "$T"' EXIT
  items "$PLAN" 1 | cut -f1 | sort -u > "$P"
  items "$TODO" 0 | awk -F'\t' '$2==" "{print $1}' | sort -u > "$T"
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
  else
    ok "every open SUITE_TODO item has a checkbox line in the plan"
  fi
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
