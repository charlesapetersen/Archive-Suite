#!/usr/bin/env bash
# next-review-unit.sh — WS11: pick the code-review unit most in need of a re-review, on a cadence, so a long
# unattended run keeps re-reviewing CHANGED code instead of drifting. DETERMINISTIC (the session doesn't
# eyeball "what changed" — this does), delta-aware, and cadence-gated so review interleaves with feature work
# instead of starving it.
#
# METHOD is REVIEW.md's paced lean review — ONE unit per session (never a whole-project fan-out; that blows a
# usage window). This script only DECIDES which unit + whether one is due; the session runs `lean-review` on
# the unit it names, files findings as queued fixes, then calls `--record <unit>`.
#
# STATE lives in the PRIMARY checkout ($REPO), gitignored, accessed by absolute path — because .maintenance/
# is entirely gitignored (a worktree session can't see it via git), exactly like AUTONOMOUS_PLAN.md. Deltas
# are measured against $REPO's HEAD, which the run keeps current with origin/main.
#
# USAGE:
#   next-review-unit.sh            # if a review is DUE, print one line "UNIT=… PATHS=… CHANGED=n SINCE=sha";
#                                  #   exit 0. If not due, print "none due (…)"; exit 3.
#   next-review-unit.sh --status   # table of every unit's unreviewed-commit count + last-review (exit 0)
#   next-review-unit.sh --record U # stamp unit U as reviewed at the current $REPO HEAD (call after review)
set -uo pipefail

REPO="${AUTONOMOUS_REPO:-/Users/<user>/Claude/Archive Suite}"
STATE_DIR="$REPO/.maintenance/review"
TSV="$STATE_DIR/last-reviewed.tsv"                 # rows: <unit>\t<sha>\t<iso-date>  (+ a __any__ cadence row)
REVIEW_EVERY="${AUTONOMOUS_REVIEW_EVERY:-20}"      # global cooldown: ≥ this many commits since the LAST review
                                                   #   (of any unit) before another is due — keeps review from
                                                   #   dominating feature work.

# ---- MASTER SWITCH: paced code reviews are OFF (owner directive, 2026-07-29) --------------------------------
# WHY: an owner-commissioned Codex full-suite review (2026-07-29) filed 24 confirmed findings as SUITE_TODO
# Wave 23 (5 HIGH / 15 MED / 4 LOW). The bottleneck is now FIXING those, not discovering more — so the daemon
# should spend every cycle draining W23 instead of generating findings it won't get to. This is a deliberate
# pause, not a retirement.
#
# EVERYTHING BELOW IS INTACT AND UNCHANGED — this is one switch, not a removal. The unit table, the two-tier
# never-reviewed-first ranking, the cooldown, the fail-open stale-sha handling and `--record` all still work,
# and `--status` still reports honestly (it prints a DISABLED banner but the real table underneath).
#
# TO RE-ENABLE: set REVIEW_ENABLED_DEFAULT=1 below (or export AUTONOMOUS_REVIEW_ENABLED=1 for a one-off run),
# then re-install + re-arm from the PRIMARY checkout (`arm.sh` installs from $REPO's working tree, not
# origin/main — so `git merge --ff-only origin/main` there FIRST or you'll re-install the old copy).
#
# HOW IT DISABLES: the script reports `none due …` and exits 3 — the *existing*, already-handled path in the
# resume prompt's STEP 2.0 ("`none due …` (exit 3) → skip this step; go to STEP 2"). So a session just picks a
# normal queue item. No caller changes, no new failure mode; `prove-review-cadence.sh` exercises the machinery
# by exporting AUTONOMOUS_REVIEW_ENABLED=1, so the harness keeps passing.
REVIEW_ENABLED_DEFAULT=0
REVIEW_ENABLED="${AUTONOMOUS_REVIEW_ENABLED:-$REVIEW_ENABLED_DEFAULT}"

# Canonical review units — KEEP IN SYNC WITH REVIEW.md's unit table. iOS (unit 7) is intentionally absent
# (ON HOLD, maintain-only). Format: "name<TAB>space-separated repo-relative paths".
UNITS="Processor/Capture	ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture/
Processor/Net	ArchiveProcessor/macOS/Sources/ArchiveProcessor/Net/
Processor/OCR	ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/
Processor/Tagging+Models	ArchiveProcessor/macOS/Sources/ArchiveProcessor/Tagging/ ArchiveProcessor/macOS/Sources/ArchiveProcessor/Models/
Processor/Views	ArchiveProcessor/macOS/Sources/ArchiveProcessor/Views/
Android	ArchiveProcessor/ArchiveCapture/
Reader/Core	ArchiveReader/macOS/Sources/ArchiveReader/Core/
Reader/Search	ArchiveReader/macOS/Sources/ArchiveReader/Search/
Reader/Views	ArchiveReader/macOS/Sources/ArchiveReader/Views/
Notes/Store+Tags	ArchiveNotes/macOS/Sources/ArchiveNotes/Store/ ArchiveNotes/macOS/Sources/ArchiveNotes/Core/NotesTagProjector.swift ArchiveNotes/macOS/Sources/ArchiveNotes/Core/NotesTagVocabulary.swift
Notes/Index+Org	ArchiveNotes/macOS/Sources/ArchiveNotes/Index/
Notes/Core	ArchiveNotes/macOS/Sources/ArchiveNotes/Core/ ArchiveNotes/macOS/Sources/ArchiveNotes/Models/
Notes/Editor	ArchiveNotes/macOS/Sources/ArchiveNotes/Editor/
Notes/Views	ArchiveNotes/macOS/Sources/ArchiveNotes/Views/
Notes/Zotero+Links+Paste	ArchiveNotes/macOS/Sources/ArchiveNotes/Zotero/ ArchiveNotes/macOS/Sources/ArchiveNotes/Sources/"

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "next-review-unit: $REPO is not a git repo"; exit 2; }
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"

# last recorded sha for $1 (empty if never reviewed)
# last recorded sha for $1, but ONLY if it's still a valid/reachable commit. A stale/rewritten/corrupt sha
# returns EMPTY -> the caller treats the unit as never-reviewed (full-history rescan). This FAILS OPEN: a bad
# sha makes a unit look maximally stale (so it gets re-reviewed), never silently "0 changed" (which would
# stall the cadence — a bad `__any__` sha would otherwise freeze the WHOLE loop). See the review finding.
last_sha() {
  local s; s="$([ -f "$TSV" ] && awk -F'\t' -v u="$1" '$1==u{print $2; exit}' "$TSV" 2>/dev/null)"
  [ -n "$s" ] && git -C "$REPO" cat-file -e "$s^{commit}" 2>/dev/null && printf '%s' "$s"
}
# commits touching a unit's paths since its last review (all history if the sha is empty/invalid)
changed_count() {
  local sha="$1"; shift
  if [ -n "$sha" ]; then git -C "$REPO" rev-list --count "$sha..HEAD" -- "$@" 2>/dev/null || echo 0
  else                    git -C "$REPO" rev-list --count HEAD -- "$@" 2>/dev/null || echo 0; fi
}

# ---- --record: stamp a unit (and the global cadence marker) at the current HEAD ----
if [ "${1:-}" = "--record" ]; then
  u="${2:-}"; [ -n "$u" ] || { echo "usage: $0 --record <unit>"; exit 2; }
  # Exact-string field match (awk), NOT regex — unit names contain / and + (ERE metachars).
  printf '%s\n' "$UNITS" | awk -F'\t' -v u="$u" '$1==u{f=1} END{exit !f}' || { echo "unknown unit: $u"; exit 2; }
  mkdir -p "$STATE_DIR"
  tmp="$TSV.tmp.$$"; when="$(date '+%F %T')"
  { [ -f "$TSV" ] && awk -F'\t' -v u="$u" '$1!=u && $1!="__any__"' "$TSV" 2>/dev/null
    printf '%s\t%s\t%s\n' "$u" "$HEAD_SHA" "$when"
    printf '%s\t%s\t%s\n' "__any__" "$HEAD_SHA" "$when"
  } > "$tmp" && mv -f "$tmp" "$TSV"
  echo "recorded: $u @ ${HEAD_SHA:0:12}"
  exit 0
fi

# ---- master switch (top of file): reviews paused by owner directive -> always "not due" ----
# Placed HERE deliberately: after `--record` (stamping a manual review must keep working while paused) but
# BEFORE the ranking loop, which costs ~15 `git rev-list --count` walks over full history. Every daemon session
# calls this script, so short-circuiting after the loop would burn that cost on every cycle for a result that
# is fixed. `--status` is exempted so the owner can still see real coverage — it falls through to the loop and
# prints the table under a DISABLED banner.
if [ "$REVIEW_ENABLED" != "1" ] && [ "${1:-}" != "--status" ]; then
  echo "none due (paced reviews DISABLED — owner directive 2026-07-29; draining SUITE_TODO Wave 23. Re-enable via REVIEW_ENABLED_DEFAULT=1 or AUTONOMOUS_REVIEW_ENABLED=1)"
  exit 3
fi

# ---- rank units, TWO-TIER (the review finding): a NEVER-REVIEWED unit with changes ALWAYS outranks any
#      already-reviewed one, and never-reviewed units are taken in the canonical table order (= REVIEW.md's
#      RISK order: Capture, Net, OCR, …). Otherwise a low-churn but high-risk unit (Net has the FEWEST commits
#      of all) would be starved forever by a high-churn one. Only once every unit has been reviewed at least
#      once does churn (unreviewed commits since last review) drive the pick. Ties within the reviewed tier go
#      to the first in table order (strict `>` keeps the earlier one) — deterministic, risk-ordered.
first_never_u=""; first_never_paths=""; first_never_n=0     # tier 1: first never-reviewed unit WITH changes
best_rev_u=""; best_rev_paths=""; best_rev_n=-1; best_rev_since=""   # tier 2: max-churn reviewed unit
report=""
while IFS=$'\t' read -r name paths; do
  [ -n "$name" ] || continue
  sha="$(last_sha "$name")"     # empty if never reviewed OR the recorded sha is stale/invalid (fail-open)
  # $paths is deliberately word-split into multiple git pathspecs (e.g. unit 4 has two):
  # shellcheck disable=SC2086
  n="$(changed_count "$sha" $paths)"; case "$n" in ''|*[!0-9]*) n=0 ;; esac
  disp="never"; [ -n "$sha" ] && disp="${sha:0:12}"
  report="$report$(printf '  %-26s %5s unreviewed commit(s)   last=%s' "$name" "$n" "$disp")"$'\n'
  if [ -z "$sha" ]; then
    [ -z "$first_never_u" ] && [ "$n" -gt 0 ] && { first_never_u="$name"; first_never_paths="$paths"; first_never_n="$n"; }
  else
    [ "$n" -gt "$best_rev_n" ] && { best_rev_u="$name"; best_rev_paths="$paths"; best_rev_n="$n"; best_rev_since="$sha"; }
  fi
done <<EOF
$UNITS
EOF

# The pick: tier 1 (a never-reviewed unit) if any, else the most-churned reviewed unit.
if [ -n "$first_never_u" ]; then
  best_u="$first_never_u"; best_paths="$first_never_paths"; best_n="$first_never_n"; best_since=""
else
  best_u="$best_rev_u"; best_paths="$best_rev_paths"; best_n="$best_rev_n"; best_since="$best_rev_since"
fi

if [ "${1:-}" = "--status" ]; then
  [ "$REVIEW_ENABLED" = "1" ] || echo "⏸  PACED REVIEWS DISABLED (owner directive 2026-07-29 — draining SUITE_TODO Wave 23 instead).
   Nothing below is due; the table is shown for reference. Re-enable: REVIEW_ENABLED_DEFAULT=1 in this script."
  echo "review units (never-reviewed picked first in this order; then most-changed since last review):"
  printf '%s' "$report"
  any_sha="$(last_sha __any__)"
  echo "  cooldown: $(changed_count "$any_sha") commit(s) since last review (of any unit); due at >= $REVIEW_EVERY"
  exit 0
fi

# ---- due? global cooldown: >= REVIEW_EVERY commits since the last review of ANY unit ----
any_sha="$(last_sha __any__)"
since_any="$(changed_count "$any_sha")"; case "$since_any" in ''|*[!0-9]*) since_any=0 ;; esac
if [ -n "$any_sha" ] && [ "$since_any" -lt "$REVIEW_EVERY" ]; then
  echo "none due ($since_any commit(s) since last review < cooldown $REVIEW_EVERY)"; exit 3
fi
if [ -z "$best_u" ] || [ "$best_n" -le 0 ]; then
  echo "none due (no unit has changed since its last review)"; exit 3
fi
printf 'UNIT=%s\tPATHS=%s\tCHANGED=%s\tSINCE=%s\n' "$best_u" "$best_paths" "$best_n" "${best_since:-never}"
exit 0
