#!/usr/bin/env bash
# compact-plan.sh — keep AUTONOMOUS_PLAN.md small by archiving old Session Log entries.
#
# WHY: the plan's "## Session Log" grows one fat line per completed item, forever. Every fresh daemon
# session reads the whole plan to orient, so an un-pruned log silently inflates the per-session startup
# cost (measured ~62k tokens at 243 entries — most of it dead history). This trims the log back to the
# last $KEEP entries and appends the rest to an archive file, so the plan a session reads stays ~20k.
#
# WHEN: the daemon calls this BETWEEN cycles (after a session exits + the lock is released, before the
# next launch) — so NO claude session is active and this can never race a session's Session Log append.
#
# SAFE BY CONSTRUCTION:
#   * operates ONLY inside the "## Session Log" region (bounded below by the next '## ' header, i.e.
#     "## Morning Review"); the DIRECTIVES / RESUME PROTOCOL / WORK QUEUE / E2E / Morning Review are
#     never touched;
#   * builds the result in a temp file and VALIDATES every live anchor survives (and that the entire
#     pre-log region is byte-identical) BEFORE replacing the plan;
#   * keeps a .bak of the pre-compaction plan; BAILS (leaving the plan untouched) on any anomaly;
#   * idempotent — a no-op once the log is at/under $TRIGGER entries.
# The plan file is gitignored, so .bak + the archive file are the recovery points (not git).
set -u

REPO="${1:-/Users/<user>/Claude/Archive Suite}"
PLAN="${AUTONOMOUS_PLAN:-$REPO/.maintenance/AUTONOMOUS_PLAN.md}"
ARCHIVE="${AUTONOMOUS_SESSION_ARCHIVE:-$REPO/.maintenance/AUTONOMOUS_SESSION_LOG_ARCHIVE.md}"
KEEP="${KEEP:-6}"           # recent Session Log entries to retain inline
TRIGGER="${TRIGGER:-10}"    # only compact when the log exceeds this many entries (else no-op)
# ===== 2026-08-04 (owner: "token use is the real bottleneck") — THREE BUGS FIXED HERE =====
# The plan had grown to 462 KB / ~115k tokens of per-session orientation cost with this compactor
# reporting "no-op" every cycle. Root causes, all measured on the live plan:
#
#  (1) FORMAT DRIFT SILENTLY DISABLED PASS 1. Sessions write Session Log entries as bare date-led lines
#      ("2026-08-04 W3.cap-r3-fu9 `sha` — result"), not the "- " bullets Pass 1 counted with /^- /. Of 44
#      real entries only 14 were visible; the other 1,059 lines fell BEFORE the first "- " and were treated
#      as untouchable region preamble. 115 KB of dead history the compactor could not see.
#  (2) PASS 1 RAN BACKWARDS. The section is NEWEST-FIRST (sessions prepend; dates ran 08-04 at the top down
#      to 08-02 at the bottom) but Pass 1 was written to "drop the FIRST $CUT entries (oldest), keep the
#      last $KEEP" — correct only for an append-ordered log. The header text still SAID "append", which is
#      how the mismatch survived. Had (1) ever been fixed alone, N=44 > TRIGGER=40 would have fired and
#      archived the 32 NEWEST entries while keeping the oldest. A latent landmine, masked by the no-op.
#  (3) PASS 1 TORE MULTI-LINE ENTRIES. Its split moved only lines matching /^- /, so an entry's
#      continuation lines stayed in the plan while its first line went to the archive (measured: dropping 2
#      entries would have moved 217 bytes and ORPHANED 1,631 bytes). Pass 2 never had this bug.
#
# Pass 1 is now a MIRROR of Pass 2 — newest-first, structural entry detection, whole-entry ordinal split,
# line-conservation check — plus a BYTE BUDGET on both passes so that a future authoring drift can never
# again silently un-bound the file: entry COUNT is a proxy for cost, bytes are the cost.
SL_MAX_BYTES="${SL_MAX_BYTES:-30000}"   # Session Log region byte budget (~7.5k tokens); 0 disables
# An entry header in the Session Log is a COLUMN-0 line that is either a "- " bullet or date-led
# (20YY-MM-DD…). Continuations are indented or blank, so — unlike Morning Review — a preceding blank line is
# NOT required (entries here are not reliably blank-separated; requiring it would under-count). Heuristic
# LIMIT (LOW, conservation-safe): a continuation line starting at column 0 with a date would read as a new
# entry, shifting a boundary; no byte is lost (conservation holds, the archive is the recovery point).
# Morning Review rotation (WS8) — the '## Morning Review' section is newest-first, one '**[date]' entry
# per session; it grows unbounded (~1.8k lines observed) and every session reads it. Keep the newest
# $MR_KEEP entries inline, archive the older tail (recoverable — never deleted).
MR_ARCHIVE="${AUTONOMOUS_MR_ARCHIVE:-$REPO/.maintenance/AUTONOMOUS_MORNING_REVIEW_ARCHIVE.md}"
MR_KEEP="${MR_KEEP:-8}"         # recent Morning Review entries to retain inline
MR_TRIGGER="${MR_TRIGGER:-12}" # only rotate when the section exceeds this many entries (else no-op)
MR_MAX_BYTES="${MR_MAX_BYTES:-30000}"   # Morning Review region byte budget (~7.5k tokens); 0 disables

[ -f "$PLAN" ] || { echo "compact-plan: no plan at $PLAN — skip"; exit 0; }

# ===== Pass 1: Session Log compaction (subshell so its internal `exit`s don't skip Pass 2) =====
(
H=$(grep -nE '^## Session Log' "$PLAN" | head -1 | cut -d: -f1)
[ -n "$H" ] || { echo "compact-plan: no '## Session Log' header — skip"; exit 0; }

TOTAL=$(awk 'END{print NR}' "$PLAN")

# Count entries AND region bytes in one pass. Region = header .. first BLANK-PRECEDED '## ' after it (same
# rule as Pass 2, so a column-0 '## ' pasted mid-body cannot truncate the region early). Entry header rule
# per the note above: column-0 '- ' bullet OR date-led. Regexes are awk-PROGRAM literals, never via -v
# (BSD awk strips backslashes from -v values).
read -r N REGB <<EOF
$(awk -v h="$H" '
  {
    if (NR == h) { inreg=1; prevblank=0; next }
    if (inreg && /^## / && prevblank) inreg=0
    if (inreg) { bytes += length($0) + 1
                 if (/^- / || /^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) c++ }
    prevblank = ($0 ~ /^[[:space:]]*$/)
  }
  END { print c+0, bytes+0 }' "$PLAN")
EOF

# Fire on COUNT or on BYTES — either exceeding its budget means the section is costing too much context.
OVER_BYTES=0
[ "$SL_MAX_BYTES" -gt 0 ] && [ "$REGB" -gt "$SL_MAX_BYTES" ] && OVER_BYTES=1
if [ "$N" -le "$TRIGGER" ] && [ "$OVER_BYTES" = 0 ]; then
  echo "compact-plan: $N Session Log entries <= trigger $TRIGGER and ${REGB}B <= budget ${SL_MAX_BYTES}B — no-op"; exit 0
fi

# Effective keep: walk entries NEWEST-FIRST accumulating whole-entry bytes, and keep only those that fit the
# byte budget (clamped to [1, KEEP]). So a single 37 KB entry cannot hold the whole section hostage.
EKEEP="$KEEP"
if [ "$SL_MAX_BYTES" -gt 0 ]; then
  EKEEP=$(awk -v h="$H" -v keep="$KEEP" -v budget="$SL_MAX_BYTES" '
    {
      if (NR == h) { inreg=1; prevblank=0; next }
      if (inreg && /^## / && prevblank) inreg=0
      if (inreg) {
        if (/^- / || /^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) e++
        if (e > 0) sz[e] += length($0) + 1
      }
      prevblank = ($0 ~ /^[[:space:]]*$/)
    }
    END {
      run = 0; fit = 0
      for (i = 1; i <= e && i <= keep; i++) { run += sz[i]; if (run > budget) break; fit++ }
      if (fit < 1) fit = 1
      print fit
    }' "$PLAN")
fi
[ -n "$EKEEP" ] && [ "$EKEEP" -ge 1 ] || EKEEP=1

CUT=$((N - EKEEP))
[ "$CUT" -gt 0 ] || { echo "compact-plan: nothing to cut (N=$N effective KEEP=$EKEEP) — no-op"; exit 0; }

TMP=$(mktemp) || exit 1
DROP=$(mktemp) || { rm -f "$TMP"; exit 1; }

# Split in ONE awk pass keyed on the entry ORDINAL, NEWEST-FIRST (this section is prepend-ordered): the
# header + preamble + entries 1..EKEEP + everything OUTSIDE the region -> kept; entries EKEEP+1..end ->
# archived. Whole entries travel together, so continuation lines can never be orphaned (bug 3).
awk -v h="$H" -v keep="$EKEEP" -v drop="$DROP" '
  {
    if (NR == h) { inreg=1; prevblank=0; print; next }
    if (inreg && /^## / && prevblank) inreg=0
    if (inreg && (/^- / || /^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) entry++
    if (inreg && entry > keep) print >> drop
    else print
    prevblank = ($0 ~ /^[[:space:]]*$/)
  }
' "$PLAN" > "$TMP" || { rm -f "$TMP" "$DROP"; exit 1; }

# VALIDATE — every live anchor must survive, or abort with the plan untouched.
for a in '^## PRIME DIRECTIVES' '^## RESUME PROTOCOL' '^## WORK QUEUE' '^## Session Log' '^RUN STATUS:'; do
  grep -qE "$a" "$TMP" || { echo "compact-plan: VALIDATION FAIL ($a missing) — abort, plan untouched"; rm -f "$TMP" "$DROP"; exit 1; }
done
# LINE CONSERVATION (kept + dropped == original) — Pass 2 always had this; Pass 1 did not, which is how a
# torn multi-line entry could pass validation. Counts via awk END{NR} so a missing final newline can't skew.
L_ORIG=$(awk 'END{print NR}' "$PLAN"); L_KEPT=$(awk 'END{print NR}' "$TMP"); L_DROP=$(awk 'END{print NR}' "$DROP")
if [ "$((L_KEPT + L_DROP))" != "$L_ORIG" ]; then
  echo "compact-plan: line conservation FAIL (kept $L_KEPT + dropped $L_DROP != orig $L_ORIG) — abort, plan untouched"; rm -f "$TMP" "$DROP"; exit 1
fi
[ "$L_DROP" -gt 0 ] || { echo "compact-plan: nothing dropped — abort, plan untouched"; rm -f "$TMP" "$DROP"; exit 1; }
if grep -qE '^## Morning Review' "$PLAN"; then
  grep -qE '^## Morning Review' "$TMP" || { echo "compact-plan: Morning Review lost — abort, plan untouched"; rm -f "$TMP" "$DROP"; exit 1; }
fi
# The entire pre-log region (everything through the Session Log header) must be byte-identical.
if ! diff -q <(sed -n "1,${H}p" "$PLAN") <(sed -n "1,${H}p" "$TMP") >/dev/null 2>&1; then
  echo "compact-plan: pre-log region changed — abort, plan untouched"; rm -f "$TMP" "$DROP"; exit 1
fi
[ "$L_KEPT" -lt "$L_ORIG" ] || { echo "compact-plan: no line reduction — abort, plan untouched"; rm -f "$TMP" "$DROP"; exit 1; }

# Commit: back up the plan, append the dropped entries to the archive (GUARDED, before the mv, so entries are
# never removed from the plan without a copy landing in the archive), then atomically replace.
cp "$PLAN" "$PLAN.bak" || { rm -f "$TMP" "$DROP"; exit 1; }
{
  echo ""
  echo "<!-- $(date -u +%Y-%m-%dT%H:%MZ) archived $CUT Session Log entries (oldest) from AUTONOMOUS_PLAN.md (kept newest $EKEEP inline; ${REGB}B region vs ${SL_MAX_BYTES}B budget) -->"
  cat "$DROP"
} >> "$ARCHIVE" || { echo "compact-plan: Session Log archive write failed — abort, plan untouched"; rm -f "$TMP" "$DROP"; exit 1; }
mv "$TMP" "$PLAN"
rm -f "$DROP"
echo "compact-plan: archived $CUT Session Log entries (newest $EKEEP kept of $N); plan $L_ORIG -> $L_KEPT lines; archive=$ARCHIVE"
) || echo "compact-plan: Pass 1 (Session Log) exited nonzero — plan left untouched by Pass 1 (see message above)"

# ===== Pass 2: Morning Review rotation (WS8) =====
# '## Morning Review' is newest-first — each session PREPENDS an entry at the top — so keep the newest $MR_KEEP
# entries inline and archive the older tail. Same safety contract as Pass 1 (region-bounded, validate-before-
# replace, .bak, archive-not-delete, idempotent, trigger-gated), with these hardenings from the WS8 adversarial
# reviews:
#   * The split is a SINGLE awk pass keyed on the entry ORDINAL — never wc/sed line ranges — so a plan whose
#     last line lacks a trailing newline can't silently drop that line (`wc -l` undercounts it; awk's NR/print
#     counts AND re-terminates it). A line-CONSERVATION check (kept + dropped == original) backstops any bug.
#   * An entry HEADER is detected STRUCTURALLY, not by header text: a column-0 '**[' line whose PREVIOUS line is
#     blank. Entries are blank-separated and newest-prepended, so this matches every real header shape — plain
#     '**[2026-07-17] …', date+qualifier '**[2026-07-14, GUI-ON session] …', and non-date '**[HISTORICAL …]' /
#     '**[owner …]' — which a date-shaped regex misses (→ under-rotation). A CONTIGUOUS-body mid-line that
#     starts with '**[' (a '**[note]' bullet, a quoted '**[2026-05-09]' cross-ref) is correctly treated as body
#     (not blank-preceded), so the cut doesn't tear the entry. A header written WITHOUT a blank separator merges
#     into the entry above (safe: content stays together). Heuristic LIMIT (LOW, conservation-safe): a body that
#     itself contains a blank line immediately followed by a column-0 '**[' paragraph WOULD be mis-split as a new
#     entry → that logical entry can be torn across plan/archive. No byte is ever lost (conservation holds; the
#     archive is the recovery point). Authoring contract: keep a Morning Review entry body contiguous (no blank
#     line directly before a column-0 '**[' inside one entry).
#   * ALL regexes are awk-PROGRAM literals, never passed via `-v` — BSD awk strips backslashes from `-v` values
#     (it turned an earlier `-v re='^\*\*\['` into an unanchored pattern that matched dates mid-line), so `-v`
#     for a regex is unsafe here.
#   * The archive append is GUARDED and precedes the mv, so entries are never removed from the plan without a
#     copy first landing in the archive (the archive — not the clobber-prone .bak — is the durable record).
# Region end = the first BLANK-PRECEDED '## ' after the header (real section headers are always blank-separated),
# so a column-0 '## ' pasted mid-body (a quoted H2 / diff hunk, not blank-preceded) can NOT truncate the region
# early. A blank-preceded '## ' inside a body (rare) could still end it → under-rotation, never data loss
# (conservation guarantees every line lands in plan or archive). Same rule mirrored in the count and the split.
MH=$(grep -nE '^## Morning Review' "$PLAN" | head -1 | cut -d: -f1)
[ -n "$MH" ] || { echo "compact-plan: no '## Morning Review' header — skip MR"; exit 0; }

# count entries in the Morning Review region (region = header .. first '## ' after it, else EOF). A header =
# a column-0 '**[' line preceded by a blank line (see the structural rationale above).
MN=$(awk -v h="$MH" '
  {
    if (NR == h) { inreg=1; prevblank=0; next }
    if (inreg && /^## / && prevblank) inreg=0
    if (inreg && (/^### 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ || /^- \*\*\[/ || /^\*\*\[/) && prevblank) c++
    prevblank = ($0 ~ /^[[:space:]]*$/)
  }
  END { print c+0 }' "$PLAN")
# Region bytes, for the byte budget (same region rule as the count above).
MREGB=$(awk -v h="$MH" '
  {
    if (NR == h) { inreg=1; prevblank=0; next }
    if (inreg && /^## / && prevblank) inreg=0
    if (inreg) bytes += length($0) + 1
    prevblank = ($0 ~ /^[[:space:]]*$/)
  }
  END { print bytes+0 }' "$PLAN")
MR_OVER=0
[ "$MR_MAX_BYTES" -gt 0 ] && [ "$MREGB" -gt "$MR_MAX_BYTES" ] && MR_OVER=1
if [ "$MN" -le "$MR_TRIGGER" ] && [ "$MR_OVER" = 0 ]; then
  echo "compact-plan: $MN Morning Review entries <= trigger $MR_TRIGGER and ${MREGB}B <= budget ${MR_MAX_BYTES}B — no-op"; exit 0
fi

# Effective keep from the byte budget, newest-first (this section is already prepend-ordered), clamped to
# [1, MR_KEEP] — so one enormous entry cannot hold the section over budget indefinitely.
MR_EKEEP="$MR_KEEP"
if [ "$MR_MAX_BYTES" -gt 0 ]; then
  MR_EKEEP=$(awk -v h="$MH" -v keep="$MR_KEEP" -v budget="$MR_MAX_BYTES" '
    {
      if (NR == h) { inreg=1; prevblank=0; next }
      if (inreg && /^## / && prevblank) inreg=0
      if (inreg) {
        if ((/^### 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ || /^- \*\*\[/ || /^\*\*\[/) && prevblank) e++
        if (e > 0) sz[e] += length($0) + 1
      }
      prevblank = ($0 ~ /^[[:space:]]*$/)
    }
    END {
      run = 0; fit = 0
      for (i = 1; i <= e && i <= keep; i++) { run += sz[i]; if (run > budget) break; fit++ }
      if (fit < 1) fit = 1
      print fit
    }' "$PLAN")
fi
[ -n "$MR_EKEEP" ] && [ "$MR_EKEEP" -ge 1 ] || MR_EKEEP="$MR_KEEP"

MR_CUT=$((MN - MR_EKEEP))
[ "$MR_CUT" -gt 0 ] || { echo "compact-plan: MR nothing to cut (MN=$MN effective MR_KEEP=$MR_EKEEP) — no-op"; exit 0; }

MTMP=$(mktemp) || exit 1
MDROP=$(mktemp) || { rm -f "$MTMP"; exit 1; }

# Split in ONE awk pass: within the region, the preamble + entries 1..MR_KEEP + everything OUTSIDE the region
# (including any section AFTER Morning Review) -> kept ($MTMP); entries MR_KEEP+1..end -> dropped ($MDROP).
# Keyed on the running entry ordinal (same blank-preceded '**[' header rule as the count) — no line-range
# arithmetic, no lost final line.
awk -v h="$MH" -v keep="$MR_EKEEP" -v drop="$MDROP" '
  {
    if (NR == h) { inreg=1; prevblank=0; print; next }   # the header itself is always kept
    if (inreg && /^## / && prevblank) inreg=0             # first BLANK-PRECEDED "## " after the header ends it
    if (inreg && (/^### 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ || /^- \*\*\[/ || /^\*\*\[/) && prevblank) entry++          # crossing a real entry header advances the ordinal
    if (inreg && entry > keep) print >> drop              # entries MR_KEEP+1..end -> archived
    else print                                            # preamble, kept entries, all after-region lines
    prevblank = ($0 ~ /^[[:space:]]*$/)
  }
' "$PLAN" > "$MTMP" || { rm -f "$MTMP" "$MDROP"; exit 1; }

# VALIDATE — anchors survive, pre-Morning-Review region byte-identical, real reduction, and LINE CONSERVATION
# (kept + dropped == original), or abort with the plan untouched. Counts via awk END{NR} so a missing final
# newline can't skew them.
for a in '^## PRIME DIRECTIVES' '^## RESUME PROTOCOL' '^## WORK QUEUE' '^## Session Log' '^## Morning Review' '^RUN STATUS:'; do
  grep -qE "$a" "$MTMP" || { echo "compact-plan: MR VALIDATION FAIL ($a missing) — abort, plan untouched"; rm -f "$MTMP" "$MDROP"; exit 1; }
done
if ! diff -q <(sed -n "1,${MH}p" "$PLAN") <(sed -n "1,${MH}p" "$MTMP") >/dev/null 2>&1; then
  echo "compact-plan: MR pre-region changed — abort, plan untouched"; rm -f "$MTMP" "$MDROP"; exit 1
fi
L_ORIG=$(awk 'END{print NR}' "$PLAN"); L_KEPT=$(awk 'END{print NR}' "$MTMP"); L_DROP=$(awk 'END{print NR}' "$MDROP")
if [ "$((L_KEPT + L_DROP))" != "$L_ORIG" ]; then
  echo "compact-plan: MR line conservation FAIL (kept $L_KEPT + dropped $L_DROP != orig $L_ORIG) — abort, plan untouched"; rm -f "$MTMP" "$MDROP"; exit 1
fi
[ "$L_KEPT" -lt "$L_ORIG" ] || { echo "compact-plan: MR no line reduction — abort, plan untouched"; rm -f "$MTMP" "$MDROP"; exit 1; }
[ "$L_DROP" -gt 0 ] || { echo "compact-plan: MR nothing dropped — abort, plan untouched"; rm -f "$MTMP" "$MDROP"; exit 1; }

# Commit: back up, append the dropped tail to the archive (GUARDED — abort BEFORE the mv if the archive write
# fails, so entries are never removed from the plan without a copy landing in the archive), then atomically mv.
cp "$PLAN" "$PLAN.bak" || { rm -f "$MTMP" "$MDROP"; exit 1; }
{
  echo ""
  echo "<!-- $(date -u +%Y-%m-%dT%H:%MZ) archived $MR_CUT Morning Review entries from AUTONOMOUS_PLAN.md (kept newest $MR_EKEEP inline; ${MREGB}B region vs ${MR_MAX_BYTES}B budget) -->"
  cat "$MDROP"
} >> "$MR_ARCHIVE" || { echo "compact-plan: MR archive write failed — abort, plan untouched"; rm -f "$MTMP" "$MDROP"; exit 1; }
mv "$MTMP" "$PLAN"
rm -f "$MDROP"
echo "compact-plan: archived $MR_CUT Morning Review entries (newest $MR_EKEEP kept of $MN); plan $L_ORIG -> $L_KEPT lines; archive=$MR_ARCHIVE"
