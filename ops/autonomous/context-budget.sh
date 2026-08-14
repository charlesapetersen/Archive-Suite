#!/usr/bin/env bash
# context-budget.sh — guard the SIZE of every document a fresh session reads to orient.
#
# WHY (owner, 2026-08-04: "token use is the real bottleneck for development, not build speed"):
# a daemon session's dominant fixed cost is the orientation read — the plan, the tracker, the app guide,
# the resume prompt. That cost is invisible: nothing fails, nothing warns, the docs just get bigger and
# every session silently pays more. On 2026-08-04 `AUTONOMOUS_PLAN.md` had reached 462 KB (~117k tokens)
# with its compactor reporting "no-op" every cycle for weeks (three bugs — see compact-plan.sh's header).
# Two separate silent failures compounded: the compactor could not see the entries, and NOTHING was
# watching the number that mattered. This script is the second half of that fix.
#
# It costs ZERO tokens (pure shell, run by the health gate), which is the entire point: the expensive
# thing to measure is context, and the cheap place to measure it is a gate.
#
# WHY THE NUMBERS ARE WHAT THEY ARE (re-derived 2026-08-12; the first set was arbitrary, and it parked a run).
# The 2026-08-04 set was "today's size, rounded up", and the headroom that fell out of the rounding ranged from
# +13% (ArchiveProcessor/CLAUDE.md) to +66% (ArchiveReader/CLAUDE.md) — the three app guides all got the same
# 64000 despite measuring 38K / 56K / 54K. Nobody decided the Reader's guide deserved five times the Processor's
# slack; 64000 was just a round number. So WHICH document failed first was decided by which one drew the
# thinnest arbitrary slack, not by which one actually cost anything. On 2026-08-12 that was the umbrella
# CLAUDE.md: 1,682 bytes over, 5.9% of a session's orientation read, and it stopped the daemon for the night —
# while SUITE_TODO.md sat at 91% of a budget ten times larger, free to add ten times as many tokens in silence.
#
# TWO RULES SET EVERY NUMBER BELOW:
#
#  1. THE TOTAL IS THE COST CONTROL. The per-file budgets only LOCALISE a failure ("which file do I fix?").
#     What a session actually pays is $ORIENT_TOTAL — the docs every session reads, plus the LARGEST single
#     app guide (a change loads one app, per CLAUDE.md's token directive). That sum is checked as its own
#     condition, and it is deliberately TIGHTER than the sum of the per-file budgets: individual files get
#     real room, but they cannot all be maxed at once, so aggregate creep still fails.
#  2. A FILE'S BUDGET REFLECTS HOW EXPENSIVE IT IS TO GET BACK UNDER IT. Cheap-to-shrink files carry the
#     TIGHT budgets; judgement-to-shrink files carry the GENEROUS ones. That is the inversion of the old set:
#       * AUTONOMOUS_PLAN.md   — `compact-plan.sh` shrinks it automatically, in-cycle, for free.  TIGHTEST.
#       * SUITE_TODO.md        — a session moves shipped entries to SUITE_TODO_DONE.md by an established
#                                convention. Mechanical, but it costs a session.                  MIDDLE.
#       * prose guides + plans — folding detail into KNOWN_ISSUES/README, or tombstoning a shipped section,
#                                is editorial judgement. Tripping one costs a whole session.       ROOMIEST.
#     Squeezing a prose guide to save 400 tokens while the auto-compactable plan may add 13,000 unremarked is
#     the wrong trade in both directions.
#
# MEASURED GROWTH (7-day rate to 2026-08-12) — so the next person to weigh a budget has data, not a hunch:
#   SUITE_TODO.md  +2800 B/day  ->  reaches 205000 in ~8 days   <- the one that will trip next, by a wide margin
#   AGENTS.md       +181 B/day  ->  ~29 days        ArchiveProcessor/CLAUDE.md  +177 B/day  ->  ~101 days
#   ArchiveReader   +184 B/day  ->  ~189 days       ArchiveNotes/CLAUDE.md      +101 B/day  ->  ~218 days
#   REVIEW.md        +25 B/day  ->  ~213 days (paced reviews are paused, so it is nearly static)
#   resume-prompt.txt  -19 B/day and execution-plans/despotlight.md -1239 B/day — both SHRINKING; the
#   2026-08-06 tombstoning of despotlight.md is why, and it is the worked example the remedy list below cites.
#   CLAUDE.md reads +661 B/day, but ~3.2 KB of that 7-day window was the ONE-OFF history-rewrite section
#   (8732bab). Excluding it the rate is ~+200 B/day (~42 days). Don't budget against a one-off.
# THE TOTAL grows with SUITE_TODO.md, so ~+2.8 KB/day: 434506 today, warn at 475000 (~14 days), over at
# 500000 (~22 days). That is EXPECTED and is not a reason to raise it — the total's remedy is tracker hygiene,
# and $ACT_PCT now schedules that automatically at ~93%, roughly every 8 days at the current rate. A tracker
# that grows because work is being tracked is healthy; what was unhealthy was only ever finding out by parking.
#
# WHEN ONE TRIPS, the fix is still almost never "raise the budget" — it is:
#   * AUTONOMOUS_PLAN.md      -> let `compact-plan.sh` run (or find out why it no-op'd, again)
#   * SUITE_TODO.md           -> move shipped entries to SUITE_TODO_DONE.md (the convention already says so)
#   * execution-plans/*.md    -> the plan shipped; delete it (git keeps the history). If the plan is still
#                              IN FLIGHT, tombstone the sections whose work HAS shipped: replace each with a
#                              few lines naming the commit and keeping only the facts other sections / live
#                              code still cite by number (2026-08-06 did this to despotlight.md, -20 KB).
#   * an app's CLAUDE.md      -> fold detail into the app's KNOWN_ISSUES / README, keep the map tight
#   * the TOTAL               -> shrink the two TRACKERS. They are ~72% of it; the prose guides are noise by
#                              comparison, so trimming one to fix a total overage is theatre.
# Raise a budget only with a reason recorded in the commit — and if you raise one, check the TOTAL still holds.
#
# The daemon reads the machine-readable `context-budget: OVER|WARN|TOTAL …` lines below to decide what to
# repair (doc_pregate() in archive-suite-autonomous.sh). Keep them stable, and keep them one-per-line.
#
# EXIT: 0 = the PER-SESSION ORIENTATION TOTAL is within budget (per-file overages are printed as ADVISORY and
#        do NOT affect the exit code — owner, 2026-08-13) · 1 = the orientation TOTAL is over.
set -u

ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT" || { echo "context-budget: cannot cd to $ROOT"; exit 1; }

WARN_PCT="${WARN_PCT:-85}"   # print a ⚠ at this % of budget so drift is visible BEFORE it fails
# ACT_PCT is the higher tier the DAEMON acts on pre-emptively (doc_pregate() spends a session trimming a file
# that reaches it, so the OVER state is never reached and nothing ever parks). Deliberately well above
# $WARN_PCT: a warn is for a human to notice, and firing a trim session at 85% would mean a trim session
# almost every cycle — on 2026-08-12 three of nine files sat between 85% and 90% quite legitimately.
ACT_PCT="${ACT_PCT:-93}"

# file<TAB>budget-bytes. Keep this list to what a session actually READS to orient.
# Every number here is rule 2 above: tight where a script can fix it, roomy where only judgement can.
#
# CLAUDE.md's 34000 is EVIDENCE-BASED, and the evidence is worth recording because it is the whole argument
# against cosmetic trimming. On 2026-08-12 it was 1,682 B over the old 24000 and a trim was attempted first,
# on the fattest target in the file (the signing bullet, ~2.4 KB, whose full narrative already lives in
# SUITE_TODO_DONE.md §Signing + TCC consent by its own pointer). Removing every line that was NARRATIVE rather
# than an imperative or a ⛔ constraint recovered EIGHTY-NINE BYTES. The document is not bloated: it is ~25.6 KB
# of repo map, standing owner directives and hard-won traps for a three-app monorepo. So the number moved, not
# the document — and the trim that "should" have fixed this would have been 93 bytes of theatre to dodge a warn.
BUDGETS=$(cat <<'EOF'
.maintenance/AUTONOMOUS_PLAN.md	150000
SUITE_TODO.md	205000
CLAUDE.md	34000
AGENTS.md	21000
REVIEW.md	20000
ArchiveReader/CLAUDE.md	77000
ArchiveProcessor/CLAUDE.md	77000
ArchiveNotes/CLAUDE.md	77000
ops/autonomous/resume-prompt.txt	31000
EOF
)
# The three app guides share ONE number, and it is derived from the LARGEST of them (+~30%) rather than from a
# round figure — that is the whole fix for the 2026-08-04 spread, where the same 64000 left the Processor at 92%
# and the Reader at 65%. No app guide is on a knife-edge because another app's guide happens to be smaller.
#
# Every in-flight execution plan shares one per-file budget (they are read whole when their wave is worked).
PLAN_BUDGET="${PLAN_BUDGET:-125000}"

# --- rule 1: the TOTAL a single session pays to orient -------------------------------------------------
# Every session reads these…
ORIENT_ALWAYS=".maintenance/AUTONOMOUS_PLAN.md SUITE_TODO.md CLAUDE.md AGENTS.md ops/autonomous/resume-prompt.txt"
# …plus exactly ONE app guide (a change loads one app), so the worst case is the LARGEST of them. REVIEW.md is
# deliberately NOT in the set: it is read when a paced review runs, and those are paused by owner directive.
ORIENT_APP_GUIDES="ArchiveReader/CLAUDE.md ArchiveProcessor/CLAUDE.md ArchiveNotes/CLAUDE.md"
# 500000 B ~= 125k tokens. Two properties make this the real guard rather than decoration:
#   * it is TIGHTER THAN THE SUM of the per-file budgets for the same set (514000) ON PURPOSE — that 14 KB gap
#     is what still catches aggregate creep once individual files have been given honest room. If you raise a
#     per-file budget, this is the number that stops all of them being maxed at once;
#   * today's actual is 434506 B (87%), so it fails on GROWTH, not on the status quo.
# ⚠️ Its warn threshold is deliberately HIGHER than the per-file $WARN_PCT: at 87% today, an 85% warn would
# fire on day one and never stop, and doc_pregate() ACTS on warnings — a permanent warn would mean a permanent
# trim session. Warn at 95% instead, which is ~50 KB of real creep away.
ORIENT_TOTAL="${ORIENT_TOTAL:-500000}"
TOTAL_WARN_PCT="${TOTAL_WARN_PCT:-95}"

over=""; warned=""; total=0
# mach = the machine-readable block, printed AFTER the human table so the table stays a table. SIZES is the
# per-file record the ORIENT_TOTAL arithmetic reads back (one path<TAB>bytes line per checked file).
mach=""; SIZES=""
printf '%-46s %9s %9s %6s\n' "document" "bytes" "budget" "used"
printf '%-46s %9s %9s %6s\n' "----------------------------------------------" "---------" "---------" "------"

check() {  # $1=path $2=budget
  local f="$1" b="$2" s pct
  [ -f "$f" ] || return 0
  s=$(wc -c < "$f" | tr -d ' ')
  total=$((total + s))
  SIZES="$SIZES$f	$s
"
  pct=$(( s * 100 / b ))
  if [ "$s" -gt "$b" ]; then
    printf '%-46s %9d %9d %5d%% ✗ OVER\n' "$f" "$s" "$b" "$pct"; over="$over $f"
    mach="$mach
context-budget: OVER $f $s $b"
  elif [ "$pct" -ge "$ACT_PCT" ]; then
    # NEAR = close enough that the daemon should spend a session on it NOW rather than wait to park.
    printf '%-46s %9d %9d %5d%% ⚠ NEAR\n' "$f" "$s" "$b" "$pct"; warned="$warned $f"
    mach="$mach
context-budget: NEAR $f $s $b"
  elif [ "$pct" -ge "$WARN_PCT" ]; then
    printf '%-46s %9d %9d %5d%% ⚠\n' "$f" "$s" "$b" "$pct"; warned="$warned $f"
    mach="$mach
context-budget: WARN $f $s $b"
  else
    printf '%-46s %9d %9d %5d%%\n' "$f" "$s" "$b" "$pct"
  fi
}

while IFS=$'\t' read -r f b; do
  [ -n "${f:-}" ] || continue
  check "$f" "$b"
done <<< "$BUDGETS"

# execution-plans/**.md — one budget each; a shipped plan should be DELETED, not trimmed.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  check "$f" "$PLAN_BUDGET"
done < <(find execution-plans -name '*.md' -type f 2>/dev/null | sort)

# --- rule 1: the number that actually governs — what ONE session pays to orient -------------------------
size_of() { printf '%s' "$SIZES" | awk -F'\t' -v k="$1" '$1==k{print $2; exit}'; }
osum=0
for f in $ORIENT_ALWAYS; do s="$(size_of "$f")"; [ -n "$s" ] && osum=$(( osum + s )); done
# Exactly one app guide is read per change, so the worst case is the biggest one — not their sum.
big=0; big_f="(no app guide found)"
for f in $ORIENT_APP_GUIDES; do
  s="$(size_of "$f")"
  if [ -n "$s" ] && [ "$s" -gt "$big" ]; then big="$s"; big_f="$f"; fi
done
osum=$(( osum + big ))
opct=$(( osum * 100 / ORIENT_TOTAL ))
total_over=""
[ "$osum" -gt "$ORIENT_TOTAL" ] && total_over=1

printf '\n  all guarded documents: %d bytes (~%dk tokens)\n' "$total" "$(( total / 4000 ))"
printf '  PER-SESSION ORIENTATION: %d / %d bytes (%d%%, ~%dk tokens) = always-read set + %s\n' \
  "$osum" "$ORIENT_TOTAL" "$opct" "$(( osum / 4000 ))" "$big_f"

# Machine-readable block — doc_pregate() parses these to decide WHICH remedy to run. One fact per line.
printf '%s\n' "$mach" | sed '/^$/d'
if [ -n "$total_over" ]; then                echo "context-budget: TOTAL OVER $osum $ORIENT_TOTAL"
elif [ "$opct" -ge "$TOTAL_WARN_PCT" ]; then echo "context-budget: TOTAL WARN $osum $ORIENT_TOTAL"
else                                         echo "context-budget: TOTAL OK $osum $ORIENT_TOTAL"
fi

# ── OWNER DECISION 2026-08-13: PER-FILE IS ADVISORY. ONLY THE TOTAL FAILS. ──────────────────────────
# The per-file caps used to fail this script, which REDDENED the health gate and made `doc_pregate` dispatch a
# trim session — so a prose edit could stop all engineering work, and three chronically-NEAR documents kept the
# pressure permanent. The owner's words: the byte budget "is causing a lot more trouble than it's worth".
# The evidence for that was earned the same day: the per-file cap on `AGENTS.md` is what prompted a trim that
# DELETED the repo's whole §Gating baseline policy section, and the falling byte count was reported as success.
# The PER-SESSION ORIENTATION TOTAL still fails, because that is the number tied to real cost — every session
# reads that set — whereas which individual file carries the bytes is an editorial matter, not a gate.
# ⛔ Do NOT restore a per-file `exit 1` without the owner. Raising a budget is still the wrong reflex: prefer
# moving rationale OUT of the always-read set to a referenced tier over deleting the reasoning itself.
if [ -n "$total_over" ]; then
  # Keep this exact wording: the health gate quotes it and the park note is parsed from it.
  [ -n "$over" ] && echo "✗ context-budget: OVER budget:$over"
  echo "✗ context-budget: PER-SESSION ORIENTATION TOTAL over budget: $osum > $ORIENT_TOTAL bytes"
  echo "  Shrink a TRACKER (AUTONOMOUS_PLAN.md / SUITE_TODO.md) — together they are ~72% of this number."
  echo "  Fix the DOCUMENT, not the budget (see this script's header for the per-file remedy)."
  exit 1
fi
[ -n "$over" ] && echo "⚠ context-budget: OVER budget (ADVISORY since 2026-08-13, not a failure):$over"

[ -n "$warned" ] && echo "⚠ context-budget: approaching budget (>=${WARN_PCT}%):$warned"
[ "$opct" -ge "$TOTAL_WARN_PCT" ] && echo "⚠ context-budget: per-session orientation at ${opct}% of $ORIENT_TOTAL bytes"
if [ -n "$over" ]; then
  # Do NOT claim every document is within budget when one is not — the per-file cap is advisory, but the
  # statement would be false, and a session quotes this line as evidence. Say what is true instead.
  echo "✓ context-budget: per-session orientation TOTAL within budget (per-file advisory above:$over)"
else
  echo "✓ context-budget: all orientation documents within budget"
fi
exit 0
