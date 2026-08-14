#!/usr/bin/env bash
# check-policy-coherence.sh — assert the repo's PROSE does not contradict its current policy.
#
# WHY THIS EXISTS, and it is worth reading before adding a rule.
# On 2026-08-13 the owner lifted the per-item authorization requirement (TIER-2 IS THE GATE — `AGENTS.md`
# §*Gating baseline*). Four files were edited to say so. The old rule turned out to be restated in **ten more
# places**, including three that fail dangerously:
#   * `.maintenance/AUTONOMOUS_PLAN.md` — read FIRST and IN FULL by every session — still gave the general rule
#     "an item not named in the committed file by tag is still hold-queue";
#   * `ops/autonomous/README.md` — the REFERENCE definition of WS10 that every other doc cites by number —
#     still listed SPEC changes and irreversible-path findings as never-auto-executed;
#   * `SUITE_TODO.md`'s `R13d` entry still said "leave existing stamps alone; only strip them if the owner
#     explicitly asks" — the exact opposite of what he decided that day. That one fails by WRONG SHIP, not by a
#     park, which is the direction that actually costs something.
# Every one of those passed `check-tracker-sync.sh`, `check-todo-stubs.sh`, `check-handoff.sh` and
# `context-budget.sh`, because **all of those inspect checkbox and byte state and none of them reads prose.**
# In a repo where prose IS the instruction set for an unsupervised agent, that is a hole, not a nicety.
#
# The mechanism is deliberately dumb: a list of (forbidden pattern, why, allowed-exception) triples. A rule
# earns its place by having actually gone wrong once. Prose is not parseable, so this cannot be complete — it
# is a ratchet that stops a KNOWN contradiction coming back, not a proof of coherence.
#
# ⛔ NEVER silence a hit by widening an exception. Either the prose is wrong (fix it) or the policy changed
# (change the rule here, in the same commit, and say why in the message).
#
# Usage:  ./ops/autonomous/check-policy-coherence.sh
# Exit:   0 = coherent · 1 = at least one contradiction · 2 = cannot run
set -uo pipefail

git rev-parse --git-dir >/dev/null 2>&1 || { echo "check-policy-coherence: not in a git repo" >&2; exit 2; }
# Check the tree you are STANDING IN, not the primary: this is a check on the CONTENT of a checkout, so run
# from a worktree and it must judge that worktree's prose (otherwise you cannot iterate on a fix).
TREE="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -d "$TREE" ] || { echo "check-policy-coherence: cannot resolve this checkout" >&2; exit 2; }
# ...with ONE exception: the plan is gitignored and exists ONLY in the primary checkout, and it is the most
# load-bearing prose file in the repo, so it is always read from there.
PRIMARY="$(cd "$(dirname "$(git rev-parse --git-common-dir)")" 2>/dev/null && pwd)"
cd "$TREE" || exit 2

fails=0
red()  { printf '\033[31m%s\033[0m' "$*"; }
green(){ printf '\033[32m%s\033[0m' "$*"; }

# Files whose prose instructs an agent. The gitignored plan is included ON PURPOSE — it is the single most
# load-bearing prose file in the repo and the only one no commit hook can ever see.
TARGETS=(
  AGENTS.md CLAUDE.md REVIEW.md OWNER_AUTHORIZATIONS.md SUITE_TODO.md
  ArchiveProcessor/CLAUDE.md ArchiveProcessor/AGENTS.md ArchiveProcessor/KNOWN_ISSUES.md
  ArchiveReader/CLAUDE.md ArchiveReader/AGENTS.md ArchiveReader/KNOWN_ISSUES.md
  ArchiveNotes/CLAUDE.md ArchiveNotes/AGENTS.md ArchiveNotes/KNOWN_ISSUES.md
  ops/autonomous/README.md ops/autonomous/resume-prompt.txt
  ArchiveProcessor/scripts/E2E-PHONE-MAC.md
)
# Absolute, because it never lives in a worktree.
[ -n "${PRIMARY:-}" ] && [ -f "$PRIMARY/.maintenance/AUTONOMOUS_PLAN.md" ] && TARGETS+=("$PRIMARY/.maintenance/AUTONOMOUS_PLAN.md")

# rule <id> <extended-regex> <why> [exception-regex]
# A line matching the exception is allowed — use it ONLY for a line that is explicitly historical
# (struck through, dated as superseded, or quoting the old rule in order to retire it).
# The regex is per-LINE, so it cannot see that a line is the CONTINUATION of a multi-line ~~strikethrough~~.
# For those, put an explicit `policy-ok` marker on the line — a comment in Markdown, e.g.
# `<!-- policy-ok: continuation of the struck-through pre-2026-08-13 rule above -->`. Explicit beats a fuzzy
# proximity window: the marker is greppable, and it forces whoever adds it to say why.
HIST='~~|superseded|SUPERSEDED|no longer|NO LONGER|REMOVED from|was lifted|do NOT put them back|until 2026-08-13|since 2026-08-13|de-gated|DE-GATED|NARROWED|reversed|REVERSED|WITHDRAWN|WAS WRONG|corrected 2026-08-13|historical|used to|check-policy-coherence|policy-ok|obsolete|retained as the record|That is obsolete'

rule() {
  local id="$1" pat="$2" why="$3" exc="${4:-$HIST}" hit=0
  for f in "${TARGETS[@]}"; do
    [ -f "$f" ] || continue
    while IFS=: read -r ln text; do
      [ -n "$ln" ] || continue
      printf '%s' "$text" | grep -qE "$exc" && continue
      [ "$hit" = 0 ] && { printf '  %s %s\n' "$(red '✗')" "$id — $why"; hit=1; fails=$((fails+1)); }
      printf '      %s:%s  %s\n' "$f" "$ln" "$(printf '%s' "$text" | cut -c1-110)"
    done < <(grep -nE "$pat" "$f" 2>/dev/null)
  done
  [ "$hit" = 0 ] && printf '  %s %s\n' "$(green '✓')" "$id"
}

echo "check-policy-coherence: $TREE"
printf '\n\033[1m── the 2026-08-13 gating baseline (TIER-2 IS THE GATE) ──\033[0m\n'

rule "no-wholesale-clause" \
  'never authorized wholesale|only item by item|per item, never per category' \
  'the per-item authorization rule was lifted 2026-08-13; this phrasing reinstates it'

rule "no-owner-routing-of-findings" \
  'needs-owner (HOLD|hold) queue' \
  'a HIGH finding on an irreversible path is now an ordinary Tier-2 item, NOT hold-queue'

rule "money-not-gated" \
  'Money paths are unchanged|request the appropriate API key from the user|needs: owner decision' \
  'money was de-gated 2026-08-13 — no per-item grant and no per-run permission step'

rule "spec-not-owner-gated" \
  '(SPEC|tag-format)[^.]{0,60}(HOLD.?QUEUE|owner.?gate|owner hold)|owner hold-queue' \
  'a SPEC/tag-format edit is Tier-2, not owner-gated, since 2026-08-13'

# Added 2026-08-13 after the adversarial review found the FIRST pass of these fixes had cleared the prose
# sentence on an item but left its bolded TITLE and its trailing metadata field saying "NEEDS THE OWNER" /
# "needs: owner" — and resume-prompt.txt defines that literal token as must-not-execute. A gate marker can hide
# in three places in one entry; the earlier rules only looked at one of them.
rule "no-stale-owner-marker" \
  'NEEDS THE OWNER|NEEDS OWNER|\| *needs: owner|owner-gated by default|HOLD QUEUE — money|Do NOT auto-fix|still HOLD-QUEUE' \
  'an item offered as actionable must not carry an owner-gate marker in its title, body or metadata tail'

rule "unlisted-is-not-hold" \
  'not named in the committed file by tag is still hold-queue|is still hold-queue' \
  'OWNER_AUTHORIZATIONS.md is a RECORD now — absence from it means nothing'

printf '\n\033[1m── decisions the owner has already made (a spec must not still ask) ──\033[0m\n'

rule "r13d-strips" \
  'leave existing stamps alone|do-NOT-strip|do NOT strip' \
  'R13d: the owner AUTHORIZED stripping on 2026-08-13; the old default is reversed'

rule "no-stale-decide-first" \
  'Decide first:' \
  'an item still asking the owner to decide something he has decided'

printf '\n\033[1m── gates that MUST survive (the inverse risk: too permissive) ──\033[0m\n'
must_exist() {
  local id="$1" pat="$2" n
  n="$(grep -rlE "$pat" "${TARGETS[@]}" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${n:-0}" -ge "${3:-1}" ]; then printf '  %s %s (%s file(s))\n' "$(green '✓')" "$id" "$n"
  else printf '  %s %s — expected >=%s file(s), found %s\n' "$(red '✗')" "$id" "${3:-1}" "$n"; fails=$((fails+1)); fi
}
# ⚠️ Added 2026-08-13 after the worst error of that day: a byte-budget trim DELETED the whole §Gating baseline
# section from AGENTS.md, leaving four dangling pointers to it and the policy stated nowhere — and THIS CHECKER
# passed, because it only looked for FORBIDDEN phrases. A ratchet that asserts what must be ABSENT and never what
# must be PRESENT cannot notice the authority disappearing. Assert the policy exists before asserting its edges.
must_exist "policy-section-exists" '^## Gating baseline — TIER-2 IS THE GATE' 1
must_exist "three-owner-gates-named" 'Still owner-gated — these three' 1
must_exist "real-corpus-still-gated" 'REAL corpus|real corpus' 5
must_exist "tier3-release-still-gated" 'Tier-3 release|gh release' 2
must_exist "tier2-still-mandatory" 'Tier-2' 8

printf '\n'
if [ "$fails" -gt 0 ]; then
  printf '%s — %d rule(s) violated. Fix the prose, or change the rule here IN THE SAME COMMIT and say why.\n' \
    "$(red 'POLICY COHERENCE: FAIL')" "$fails"
  exit 1
fi
printf '%s\n' "$(green 'POLICY COHERENCE: OK')"
exit 0
