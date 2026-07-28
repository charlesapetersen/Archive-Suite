#!/usr/bin/env bash
# next-queue-item.sh — deterministic `(blocked-on: <tag>)` dependency gating for the autonomous WORK QUEUE (WS9).
#
# WHY: accumulating dependent work must run in ORDER. An item may declare a prerequisite in its text, e.g.
#   - [ ] **W15.b — wire the pane** (blocked-on: W15.a) — needs the model from W15.a first.
# and this script tells a fresh session which `[ ]` WORK QUEUE items are actionable (all prerequisites done)
# vs blocked (a prerequisite is still `[ ]` or missing), so STEP 2 of the resume prompt never picks an item
# whose dependency isn't satisfied. It is DETERMINISTIC (parses checkbox state) rather than trusting the model
# to grep — the same philosophy as the idle-backoff fingerprint and next-review-unit.sh.
#
# HOW an item's TAG is read: the first `[A-Za-z0-9._-]` token after the checkbox (leading `**` stripped) — e.g.
# `- [x] **W3.f1 [HIGH] …**` → `W3.f1`. A prerequisite `T` is DONE iff some checkbox line's tag is `T` with
# `[x]` AND no `[ ]` line has tag `T`, scanning the plan's WORK QUEUE + SUITE_TODO.md. A missing `T` is treated
# as NOT done (blocked + surfaced) — an unresolved prerequisite should stall the item, not run out of order.
#
# OUTPUT: one line per `[ ]` WORK QUEUE item, in priority order:  <status>\t<tag>\t<text>
#   status = `ok`  (no blocked-on, or every prerequisite done)  |  `blocked:T1,T2` (these prerequisites unmet)
# EXIT: 0 = at least one `ok` item exists; 4 = `[ ]` items exist but ALL are dependency-blocked; 3 = no `[ ]`
# items at all; 2 = no plan file OR no `## WORK QUEUE` section (bad plan — surfaced, not silently "empty").
# (Hold-queue skips are layered by the resume prompt ON TOP of this — the script's ONLY concern is
# `blocked-on` dependency state. The tag->state scan reads the WHOLE plan + SUITE_TODO, not just the queue, so
# a prerequisite ticked anywhere counts as done; the `[ ]`-anywhere-wins rule keeps that safe.)
set -u

REPO="${1:-/Users/<user>/Claude/Archive Suite}"
PLAN="${AUTONOMOUS_PLAN:-$REPO/.maintenance/AUTONOMOUS_PLAN.md}"
TODO="${AUTONOMOUS_SUITE_TODO:-$REPO/SUITE_TODO.md}"
[ -f "$PLAN" ] || { echo "next-queue-item: no plan at $PLAN"; exit 2; }

grep -qE '^## WORK QUEUE' "$PLAN" || { echo "next-queue-item: no '## WORK QUEUE' section in $PLAN — bad plan"; exit 2; }

# --- 1) tag -> state map, from every checkbox line in SUITE_TODO + the plan (a [ ] anywhere blocks a tag) ---
# The checkbox STATE is read from the ANCHORED leading checkbox only — NOT a `[x]` substring anywhere on the
# line (an unchecked item whose TEXT mentions a bracketed x must NOT read as done). Lines inside a fenced code
# block (```…```) or a blockquote (`>`) are skipped so a format EXAMPLE can't pollute the map. Emit "TAG<TAB>x"
# / "TAG<TAB> " per real checkbox line; collapse in bash to done-set (x-only) vs pending-set.
STATES=$(awk '
  FNR==1 { infence=0 }                       # reset fence state at the start of each input file
  /^[[:space:]]*(```|~~~)/ { infence = !infence; next }   # backtick OR tilde code fence
  infence { next }
  /^[[:space:]]*>/ { next }                    # blockquote line — not a real item
  match($0, /^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]*/) {
    st = ($0 ~ /^[[:space:]]*[-*][[:space:]]+\[[xX]\]/) ? "x" : " "   # anchored checkbox, not a substring
    rest = substr($0, RLENGTH+1)               # text after the checkbox
    sub(/^\*+[[:space:]]*/, "", rest)          # strip a leading bold marker
    if (match(rest, /^[A-Za-z0-9][A-Za-z0-9._-]*/)) print substr(rest, 1, RLENGTH) "\t" st
  }
' "$TODO" "$PLAN" 2>/dev/null)

# done-set = tags seen as [x]; pending-set = tags seen as [ ]. A tag is DONE iff in done and NOT in pending.
DONE=$(printf '%s\n' "$STATES" | awk -F'\t' '$2=="x"{print $1}' | sort -u)
PEND=$(printf '%s\n' "$STATES" | awk -F'\t' '$2==" "{print $1}' | sort -u)

tag_done() {  # $1 = tag -> 0 if satisfied (done and not pending), else 1
  local t="$1"
  printf '%s\n' "$PEND" | grep -qxF -- "$t" && return 1   # still pending anywhere -> not done
  printf '%s\n' "$DONE" | grep -qxF -- "$t"               # done somewhere -> satisfied
}

# --- 2) walk the WORK QUEUE region: for each `[ ]` item, resolve ALL its (blocked-on: …) clauses ---
# region = '## WORK QUEUE' .. next '## ' (### Wave subheaders and fenced/blockquoted lines do NOT end it). An
# item spans its `- [ ]` line PLUS following continuation lines (until the next checkbox / blank / header). The
# whole span is accumulated into one string and scanned ONCE, so EVERY `(blocked-on: …)` clause is collected —
# a second clause, one wrapped onto a continuation line, OR one split ACROSS a line break can't be silently
# dropped (which would wrongly mark a blocked item actionable). Both backtick ``` and tilde ~~~ code fences are
# recognized so a `[x]` example inside a fence can't pollute anything. Known LIMIT (LOW): an UNCLOSED fence
# opened mid-item swallows following lines (incl. a dep continuation) — malformed markdown the plan never
# writes; it fails toward a wrong `ok`, so keep entry bodies fence-balanced.
ITEMS=$(awk '
  function alldeps(s,   out,inner,rest) {      # comma-join the contents of every (blocked-on: …) in s
    out=""; rest=s
    while (match(rest, /\(blocked-on:[^)]*\)/)) {
      inner = substr(rest, RSTART, RLENGTH)
      sub(/^\(blocked-on:[[:space:]]*/, "", inner); sub(/\)$/, "", inner)
      if (inner != "") out = (out=="" ? inner : out "," inner)
      rest = substr(rest, RSTART+RLENGTH)
    }
    return out
  }
  function flush() {   # scan the FULL accumulated item span once (catches clauses split across lines)
    if (curtag != "") { dep = alldeps(curbody); gsub(/\t/, " ", curtext)
                        print curtag "\t" (dep=="" ? "-" : dep) "\t" curtext }
    curtag=""; curbody=""; curtext=""
  }
  BEGIN { inq=0; infence=0; curtag="" }
  /^## WORK QUEUE/ { inq=1; next }
  !inq { next }
  /^[[:space:]]*(```|~~~)/ { infence = !infence; next }   # backtick OR tilde code fence
  infence { next }
  /^[[:space:]]*>/ { next }
  /^## / { flush(); inq=0; next }               # next real section ends the region
  match($0, /^[[:space:]]*[-*][[:space:]]+\[[ xX]\]/) {   # a checkbox line starts/ends an item
    flush()
    if ($0 ~ /^[[:space:]]*[-*][[:space:]]+\[ \]/) {      # only [ ] items become queue candidates
      match($0, /^[[:space:]]*[-*][[:space:]]+\[ \][[:space:]]*/)
      curtext = substr($0, RLENGTH+1); t = curtext; sub(/^\*+[[:space:]]*/, "", t)
      curtag = "?"; if (match(t, /^[A-Za-z0-9][A-Za-z0-9._-]*/)) curtag = substr(t, 1, RLENGTH)
      curbody = $0
    }
    next
  }
  /^[[:space:]]*$/ { flush(); next }            # blank line ends the current item
  curtag != "" { curbody = curbody " " $0 }     # continuation line — accumulate into the span
  END { flush() }
' "$PLAN")

[ -n "$ITEMS" ] || { echo "next-queue-item: no unchecked [ ] items in WORK QUEUE"; exit 3; }

any_ok=1   # 1 = none ok yet (shell-true is 0); flip to 0 when we find an ok item
while IFS=$'\t' read -r tag dep text; do
  [ -n "$tag" ] || continue
  [ "$dep" = "-" ] && dep=""    # sentinel -> no dependencies
  unmet=""
  if [ -n "$dep" ]; then
    # split the CSV on commas; trim spaces; check each prerequisite
    old_ifs="$IFS"; IFS=','
    for pr in $dep; do
      pr="$(printf '%s' "$pr" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$pr" ] || continue
      tag_done "$pr" || unmet="${unmet:+$unmet,}$pr"
    done
    IFS="$old_ifs"
  fi
  if [ -n "$unmet" ]; then
    printf 'blocked:%s\t%s\t%s\n' "$unmet" "$tag" "$text"
  else
    printf 'ok\t%s\t%s\n' "$tag" "$text"
    any_ok=0
  fi
done <<EOF
$ITEMS
EOF

[ "$any_ok" = 0 ] && exit 0
exit 4   # items exist, but every one is dependency-blocked
