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
# ⚠️ THIS LIST WAS STALE AND SAID THE OPPOSITE OF THE CODE (corrected 2026-08-10). It claimed the Daemon
# Report and WORK QUEUE "are never touched"; both have had their own pass for some time — Pass 2 rotates the
# Daemon Report (DR_KEEP/DR_TRIGGER) and Pass 3 archives completed WORK QUEUE items (WQ_MAX_BYTES). Reading
# the old wording, a session would have concluded the queue bloat was out of scope and gone looking for new
# machinery instead of the unreachable threshold that was actually the bug.
#
# THREE PASSES, each region-bounded: 1 = Session Log, 2 = Daemon Report, 3 = WORK QUEUE completed items.
# SAFE BY CONSTRUCTION:
#   * each pass operates ONLY inside its own region (bounded below by the next '## ' header); the
#     DIRECTIVES / RESUME PROTOCOL / E2E / HOLD QUEUE regions are never touched by any pass;
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
# (20YY-MM-DD…). Continuations are indented or blank, so — unlike Daemon Report — a preceding blank line is
# NOT required (entries here are not reliably blank-separated; requiring it would under-count). Heuristic
# LIMIT (LOW, conservation-safe): a continuation line starting at column 0 with a date would read as a new
# entry, shifting a boundary; no byte is lost (conservation holds, the archive is the recovery point).
# Daemon Report rotation (WS8) — the '## Daemon Report' section is newest-first, one '**[date]' entry
# per session; it grows unbounded (~1.8k lines observed) and every session reads it. Keep the newest
# $DR_KEEP entries inline, archive the older tail (recoverable — never deleted).
# The section was called "Morning Review" until 2026-08-05. Every match below accepts BOTH spellings:
# daemon.sh installs this script from the primary checkout, so a script/plan version skew is normal, and a
# compactor that cannot find its own header aborts the pass (or, worse, would drop the region).
DR_HEADER_RE='^## (Daemon Report|Morning Review)'
# ===== 2026-08-06 — BUG 4: the plan's top-level SECTION VOCABULARY, used to bound every managed region =====
# Every pass bounds its region with "the next '## ' after my header". That test used to be BLANK-PRECEDED
# ALONE, which is wrong in both directions:
#   * TOO NARROW (the live bug): '## Daemon Report' had no blank line before it, so Pass 1's Session Log region
#     ran to EOF, swept the Daemon Report into the drop set, and aborted on the anchor guard EVERY cycle for
#     weeks. Two sibling latent cases were reproduced on fixtures while fixing it: with '## HOLD QUEUE' not
#     blank-preceded, Pass 3 archives OWNER-GATED HOLD QUEUE items out of the plan (its guard counts only
#     '[ ]', so a '[x]' leaves silently); and with a section following '## Daemon Report' without a blank,
#     Pass 2 sweeps that whole section into the DR archive (it is not in Pass 2's anchor list).
#   * TOO WIDE is the hazard the blank rule was added for: a '## ' pasted INSIDE an entry body must not
#     truncate a region (prove-compact.sh Case I, '## fake heading pasted in a body').
# A real section header is now recognised by NAME as well as by the blank line — the plan is a
# machine-managed file with a small, known set of top-level sections, so enumerating them is a contract, not
# a guess. Measured: across 713 KB of real archived entry bodies there is not ONE column-0 '## ' line, so
# the name test never fires on body text; and Case I's pasted heading matches no name, so it stays body.
# DEGRADES SAFELY: a future section that is neither in this list nor blank-preceded behaves exactly as today
# (region over-runs → the anchor guard aborts the pass, plan untouched) — and the EXIT-CODE CONTRACT below now
# makes that abort LOUD instead of a log line nobody reads. Add new '## ' sections here when the plan grows one.
# Passed to awk via -v, which is safe ONLY because this pattern contains no backslashes (BSD awk strips
# backslashes from -v values — see the note in Pass 2's header).
SEC_HEADER_RE='^## (PRIME DIRECTIVES|RESUME PROTOCOL|WORK QUEUE|HOLD QUEUE|E2E findings|Session Log|Daemon Report|Morning Review|GUI VERIFICATION|OWNER AUTHORIZATIONS)'
DR_ARCHIVE="${AUTONOMOUS_DR_ARCHIVE:-${AUTONOMOUS_MR_ARCHIVE:-$REPO/.maintenance/AUTONOMOUS_DAEMON_REPORT_ARCHIVE.md}}"
DR_KEEP="${DR_KEEP:-${MR_KEEP:-8}}"         # recent Daemon Report entries to retain inline
DR_TRIGGER="${DR_TRIGGER:-${MR_TRIGGER:-12}}" # only rotate when the section exceeds this many entries (else no-op)
DR_MAX_BYTES="${DR_MAX_BYTES:-${MR_MAX_BYTES:-30000}}"   # Daemon Report region byte budget (~7.5k tokens); 0 disables

[ -f "$PLAN" ] || { echo "compact-plan: no plan at $PLAN — skip"; exit 0; }

# ===== 2026-08-06 — EXIT-CODE CONTRACT, so an aborting pass can never again be invisible =====
# A pass that ABORTS leaves the plan un-compacted for good; a pass that legitimately NO-OPs is healthy. Until
# now both were plain stdout and this script always exited 0, so the daemon's `|| true` erased the difference:
# "Daemon Report lost — abort" scrolled past in daemon.log every cycle for weeks, looking like routine output,
# while the plan grew to 96% of its context budget. Each pass runs in a subshell that `exit 0`s for a
# no-op/skip and `exit 1`s ONLY on an abort, so a nonzero subshell IS an abort — record it and report at the end.
#   exit 0 = every pass compacted or legitimately no-op'd    ·    exit 1 = at least one pass ABORTED
# The daemon logs a ⚠⚠ line on nonzero (it no longer swallows it), and health-gate's `compact-proof` step is
# the standing mechanism proof. Callers that only want best-effort compaction may still ignore the code.
ABORTED=""

# ===== Pass 1: Session Log compaction (subshell so its internal `exit`s don't skip Pass 2) =====
(
H=$(grep -nE '^## Session Log' "$PLAN" | head -1 | cut -d: -f1)
[ -n "$H" ] || { echo "compact-plan: no '## Session Log' header — skip"; exit 0; }

TOTAL=$(awk 'END{print NR}' "$PLAN")

# Count entries AND region bytes in one pass. Region = header .. the next SECTION header after it. Entry
# header rule per the note above: column-0 '- ' bullet OR date-led. Regexes are awk-PROGRAM literals, never
# via -v (BSD awk strips backslashes from -v values).
#
# ===== 2026-08-06 — BUG 4 FIXED HERE: the region never closed, so Pass 1 aborted EVERY cycle =====
# The rule used to be BLANK-PRECEDED '## ' alone. In the live plan '## Daemon Report' had NO blank line before
# it (the Session Log's entries are blank-SEPARATED and newest-PREPENDED, so the separator after the OLDEST
# entry — the one that sits against the next header — is exactly the one that goes missing). The region
# therefore ran to EOF and swallowed the whole Daemon Report into the drop set; the anchor guard below caught
# that and aborted, so the plan was never corrupted — and never compacted either. Measured on the live plan:
# the region read as 55,779B/26 entries (the 26 = 11 real entries + 15 Daemon Report '- **[' bullets, which
# match this pass's blank-agnostic '^- ' entry rule) instead of 39,057B/11. Against SL_MAX_BYTES=30000 Pass 1
# should have been reclaiming ~11 KB every cycle; instead it printed "Daemon Report lost — abort" for weeks
# while the plan grew to 96% of its context budget. The `|| true` at the daemon's call site swallowed it.
# The fix keeps the blank-preceded rule (it is load-bearing — prove-compact.sh Case I proves a '## ' pasted
# mid-body must NOT truncate the region) and ADDS the one header that legitimately bounds this region, blank
# or not. A pasted heading cannot match '## Daemon Report'/'## Morning Review', so Case I is unaffected.
# The general backstop for any FUTURE drift of this kind is `--audit` (below) + its health-gate step: it
# reports the outcome (a pass that aborted) instead of requiring anyone to predict the mechanism.
read -r N REGB <<EOF
$(awk -v h="$H" -v sec="$SEC_HEADER_RE" '
  {
    if (NR == h) { inreg=1; prevblank=0; next }
    if (inreg && /^## / && (prevblank || (sec != "" && $0 ~ sec))) inreg=0
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

# ⚠ ANTI-SILENT-FAILURE ALARM. If the region is over budget but we detected ~no entries, the entry-header
# pattern no longer matches how sessions write this section — which is EXACTLY how this compactor no-op'd
# for weeks before 2026-08-04. Say so loudly; a silent "nothing to cut" is what hid the last two bugs.
if [ "$OVER_BYTES" = 1 ] && [ "$N" -lt 2 ]; then
  echo "compact-plan: ⚠⚠ ALARM — Session Log is ${REGB}B (budget ${SL_MAX_BYTES}B) but only $N entries were DETECTED."
  echo "compact-plan:    The entry-header rule no longer matches the authored format. FIX THE DETECTOR in this"
  echo "compact-plan:    script — do NOT raise the budget. (health-gate's context-budget.sh will fail on the growth.)"
fi

# Effective keep: walk entries NEWEST-FIRST accumulating whole-entry bytes, and keep only those that fit the
# byte budget (clamped to [1, KEEP]). So a single 37 KB entry cannot hold the whole section hostage.
EKEEP="$KEEP"
if [ "$SL_MAX_BYTES" -gt 0 ]; then
  EKEEP=$(awk -v h="$H" -v sec="$SEC_HEADER_RE" -v keep="$KEEP" -v budget="$SL_MAX_BYTES" '
    {
      if (NR == h) { inreg=1; prevblank=0; next }
      if (inreg && /^## / && (prevblank || (sec != "" && $0 ~ sec))) inreg=0   # see BUG 4 above
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
awk -v h="$H" -v sec="$SEC_HEADER_RE" -v keep="$EKEEP" -v drop="$DROP" '
  {
    if (NR == h) { inreg=1; prevblank=0; print; next }
    if (inreg && /^## / && (prevblank || (sec != "" && $0 ~ sec))) inreg=0   # see BUG 4 above
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
if grep -qE "$DR_HEADER_RE" "$PLAN"; then
  grep -qE "$DR_HEADER_RE" "$TMP" || { echo "compact-plan: Daemon Report lost — abort, plan untouched"; rm -f "$TMP" "$DROP"; exit 1; }
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
) || { echo "compact-plan: Pass 1 (Session Log) exited nonzero — plan left untouched by Pass 1 (see message above)"; ABORTED="$ABORTED pass1"; }

# ===== Pass 2: Daemon Report rotation (WS8) =====
# '## Daemon Report' is newest-first — each session PREPENDS an entry at the top — so keep the newest $DR_KEEP
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
#     archive is the recovery point). Authoring contract: keep a Daemon Report entry body contiguous (no blank
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
(   # subshell: Pass 2's internal `exit`s must not skip Pass 3 (they silently did when Pass 3 landed)
MH=$(grep -nE "$DR_HEADER_RE" "$PLAN" | head -1 | cut -d: -f1)
[ -n "$MH" ] || { echo "compact-plan: no '## Daemon Report' header — skip DR"; exit 0; }

# count entries in the Daemon Report region (region = header .. first '## ' after it, else EOF). A header =
# a column-0 '**[' line preceded by a blank line (see the structural rationale above).
MN=$(awk -v h="$MH" -v sec="$SEC_HEADER_RE" '
  {
    if (NR == h) { inreg=1; prevblank=0; next }
    if (inreg && /^## / && (prevblank || (sec != "" && $0 ~ sec))) inreg=0
    if (inreg && (/^### 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ || /^- \*\*\[/ || /^\*\*\[/) && prevblank) c++
    prevblank = ($0 ~ /^[[:space:]]*$/)
  }
  END { print c+0 }' "$PLAN")
# Region bytes, for the byte budget (same region rule as the count above).
MREGB=$(awk -v h="$MH" -v sec="$SEC_HEADER_RE" '
  {
    if (NR == h) { inreg=1; prevblank=0; next }
    if (inreg && /^## / && (prevblank || (sec != "" && $0 ~ sec))) inreg=0
    if (inreg) bytes += length($0) + 1
    prevblank = ($0 ~ /^[[:space:]]*$/)
  }
  END { print bytes+0 }' "$PLAN")
DR_OVER=0
[ "$DR_MAX_BYTES" -gt 0 ] && [ "$MREGB" -gt "$DR_MAX_BYTES" ] && DR_OVER=1
if [ "$MN" -le "$DR_TRIGGER" ] && [ "$DR_OVER" = 0 ]; then
  echo "compact-plan: $MN Daemon Report entries <= trigger $DR_TRIGGER and ${MREGB}B <= budget ${DR_MAX_BYTES}B — no-op"; exit 0
fi

# ⚠ ANTI-SILENT-FAILURE ALARM (same rationale as Pass 1 — Pass 2 had this exact failure: it wanted a bare
# column-0 '**[' while the real section uses '### <date>' H3 headers and '- **[' bullets, so it saw MN=0
# entries in an 81 KB section and reported a clean no-op).
if [ "$DR_OVER" = 1 ] && [ "$MN" -lt 2 ]; then
  echo "compact-plan: ⚠⚠ ALARM — Daemon Report is ${MREGB}B (budget ${DR_MAX_BYTES}B) but only $MN entries were DETECTED."
  echo "compact-plan:    The entry-header rule no longer matches the authored format. FIX THE DETECTOR in this script."
fi

# Effective keep from the byte budget, newest-first (this section is already prepend-ordered), clamped to
# [1, DR_KEEP] — so one enormous entry cannot hold the section over budget indefinitely.
DR_EKEEP="$DR_KEEP"
if [ "$DR_MAX_BYTES" -gt 0 ]; then
  DR_EKEEP=$(awk -v h="$MH" -v sec="$SEC_HEADER_RE" -v keep="$DR_KEEP" -v budget="$DR_MAX_BYTES" '
    {
      if (NR == h) { inreg=1; prevblank=0; next }
      if (inreg && /^## / && (prevblank || (sec != "" && $0 ~ sec))) inreg=0
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
[ -n "$DR_EKEEP" ] && [ "$DR_EKEEP" -ge 1 ] || DR_EKEEP="$DR_KEEP"

DR_CUT=$((MN - DR_EKEEP))
[ "$DR_CUT" -gt 0 ] || { echo "compact-plan: DR nothing to cut (MN=$MN effective DR_KEEP=$DR_EKEEP) — no-op"; exit 0; }

MTMP=$(mktemp) || exit 1
MDROP=$(mktemp) || { rm -f "$MTMP"; exit 1; }

# Split in ONE awk pass: within the region, the preamble + entries 1..DR_KEEP + everything OUTSIDE the region
# (including any section AFTER Daemon Report) -> kept ($MTMP); entries DR_KEEP+1..end -> dropped ($MDROP).
# Keyed on the running entry ordinal (same blank-preceded '**[' header rule as the count) — no line-range
# arithmetic, no lost final line.
awk -v h="$MH" -v sec="$SEC_HEADER_RE" -v keep="$DR_EKEEP" -v drop="$MDROP" '
  {
    if (NR == h) { inreg=1; prevblank=0; print; next }   # the header itself is always kept
    if (inreg && /^## / && (prevblank || (sec != "" && $0 ~ sec))) inreg=0             # region ends at the next real SECTION header (BUG 4)
    if (inreg && (/^### 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ || /^- \*\*\[/ || /^\*\*\[/) && prevblank) entry++          # crossing a real entry header advances the ordinal
    if (inreg && entry > keep) print >> drop              # entries DR_KEEP+1..end -> archived
    else print                                            # preamble, kept entries, all after-region lines
    prevblank = ($0 ~ /^[[:space:]]*$/)
  }
' "$PLAN" > "$MTMP" || { rm -f "$MTMP" "$MDROP"; exit 1; }

# VALIDATE — anchors survive, pre-Daemon-Report region byte-identical, real reduction, and LINE CONSERVATION
# (kept + dropped == original), or abort with the plan untouched. Counts via awk END{NR} so a missing final
# newline can't skew them.
for a in '^## PRIME DIRECTIVES' '^## RESUME PROTOCOL' '^## WORK QUEUE' '^## Session Log' "$DR_HEADER_RE" '^RUN STATUS:'; do
  grep -qE "$a" "$MTMP" || { echo "compact-plan: DR VALIDATION FAIL ($a missing) — abort, plan untouched"; rm -f "$MTMP" "$MDROP"; exit 1; }
done
if ! diff -q <(sed -n "1,${MH}p" "$PLAN") <(sed -n "1,${MH}p" "$MTMP") >/dev/null 2>&1; then
  echo "compact-plan: DR pre-region changed — abort, plan untouched"; rm -f "$MTMP" "$MDROP"; exit 1
fi
L_ORIG=$(awk 'END{print NR}' "$PLAN"); L_KEPT=$(awk 'END{print NR}' "$MTMP"); L_DROP=$(awk 'END{print NR}' "$MDROP")
if [ "$((L_KEPT + L_DROP))" != "$L_ORIG" ]; then
  echo "compact-plan: DR line conservation FAIL (kept $L_KEPT + dropped $L_DROP != orig $L_ORIG) — abort, plan untouched"; rm -f "$MTMP" "$MDROP"; exit 1
fi
[ "$L_KEPT" -lt "$L_ORIG" ] || { echo "compact-plan: DR no line reduction — abort, plan untouched"; rm -f "$MTMP" "$MDROP"; exit 1; }
[ "$L_DROP" -gt 0 ] || { echo "compact-plan: DR nothing dropped — abort, plan untouched"; rm -f "$MTMP" "$MDROP"; exit 1; }

# Commit: back up, append the dropped tail to the archive (GUARDED — abort BEFORE the mv if the archive write
# fails, so entries are never removed from the plan without a copy landing in the archive), then atomically mv.
cp "$PLAN" "$PLAN.bak" || { rm -f "$MTMP" "$MDROP"; exit 1; }
{
  echo ""
  echo "<!-- $(date -u +%Y-%m-%dT%H:%MZ) archived $DR_CUT Daemon Report entries from AUTONOMOUS_PLAN.md (kept newest $DR_EKEEP inline; ${MREGB}B region vs ${DR_MAX_BYTES}B budget) -->"
  cat "$MDROP"
} >> "$DR_ARCHIVE" || { echo "compact-plan: DR archive write failed — abort, plan untouched"; rm -f "$MTMP" "$MDROP"; exit 1; }
mv "$MTMP" "$PLAN"
rm -f "$MDROP"
echo "compact-plan: archived $DR_CUT Daemon Report entries (newest $DR_EKEEP kept of $MN); plan $L_ORIG -> $L_KEPT lines; archive=$DR_ARCHIVE"
) || { echo "compact-plan: Pass 2 (Daemon Report) exited nonzero — plan left untouched by Pass 2 (see message above)"; ABORTED="$ABORTED pass2"; }

# ===== Pass 3: WORK QUEUE done-item archival (2026-08-04) =====
# WHY: the queue's job is the ORDER and the checkbox, and a `[x]` item contributes nothing to order — but
# 218 checkbox lines (173 of them `[x]`, with fat DONE write-ups) were sitting inline, 91 KB / ~23k tokens
# that every session read. The convention already says shipped work moves to `SUITE_TODO_DONE.md`; nothing
# enforced it for the plan's mirror.
#
# THE SAFETY RULE, and it is not optional: `next-queue-item.sh` builds its tag->state map from PLAN +
# SUITE_TODO + SUITE_TODO_DONE, and a tag it cannot find AT ALL reads as NOT done — which would block any
# dependent forever. So an item is archived from here ONLY IF its tag is independently recorded `[x]` in
# SUITE_TODO.md or SUITE_TODO_DONE.md. Resolvability is then preserved BY CONSTRUCTION, not by inspection.
# (Verified when this landed: of the 28 `(blocked-on: …)` prerequisites referenced in the queue, ZERO were
# among the 75 items whose done-state existed only in the plan — those 75 are a real tracker gap, and Pass 3
# deliberately LEAVES them rather than stranding a future dependent.)
#
# Same contract as Passes 1-2: region-bounded, whole-span moves, validate-before-replace, .bak, archive-not-
# delete, line conservation, idempotent.
QUEUE_ARCHIVE="${AUTONOMOUS_QUEUE_ARCHIVE:-$REPO/.maintenance/AUTONOMOUS_WORK_QUEUE_ARCHIVE.md}"
# WORK QUEUE region byte budget; 0 disables Pass 3.
# ⚠️ 2026-08-10 — WAS 120000, WHICH THIS PASS COULD NEVER REACH. context-budget.sh caps the WHOLE plan at
# 180,000 B, and the non-queue sections run ~94 KB, so the plan hits its own gate at a queue size around
# 86 KB — well under a 120 KB trigger. Net effect: Pass 3 no-op'd every cycle since it landed (the archive
# file had never been created), the plan drifted to 195,708 B / 108% of budget, and the gate PARKED the run
# instead — the machinery to fix it existed and was simply unreachable. Measured on the live plan: queue
# region 101,990 B, Pass 3 at this threshold archives 35 tracker-confirmed lines and reclaims 39,198 B,
# taking the plan to 156,510 B (context-budget.sh then exits 0).
# Why 70000 and not lower: the region SETTLES at 62,792 B, because the remaining `[x]` items are the ones
# whose done-state exists only in the plan and the safety rule above deliberately leaves them. A threshold
# under that floor would re-fire every cycle archiving nothing, churning the .bak for no gain. 70000 fires
# now and then cleanly no-ops (verified both runs).
WQ_MAX_BYTES="${WQ_MAX_BYTES:-70000}"

(
[ "$WQ_MAX_BYTES" -gt 0 ] || { echo "compact-plan: WQ pass disabled (WQ_MAX_BYTES=0)"; exit 0; }
QH=$(grep -nE '^## WORK QUEUE' "$PLAN" | head -1 | cut -d: -f1)
[ -n "$QH" ] || { echo "compact-plan: no '## WORK QUEUE' header — skip WQ"; exit 0; }
TODOF="$REPO/SUITE_TODO.md"; DONEF="$REPO/SUITE_TODO_DONE.md"
[ -f "$TODOF" ] || { echo "compact-plan: no SUITE_TODO.md — skip WQ (cannot prove done-state)"; exit 0; }
[ -f "$DONEF" ] || DONEF=/dev/null

QREGB=$(awk -v h="$QH" -v sec="$SEC_HEADER_RE" '
  { if (NR==h) { inreg=1; prevblank=0; next }
    if (inreg && /^## / && (prevblank || (sec != "" && $0 ~ sec))) inreg=0
    if (inreg) bytes += length($0)+1
    prevblank = ($0 ~ /^[[:space:]]*$/) } END { print bytes+0 }' "$PLAN")
[ "$QREGB" -gt "$WQ_MAX_BYTES" ] || { echo "compact-plan: WORK QUEUE ${QREGB}B <= budget ${WQ_MAX_BYTES}B — no-op"; exit 0; }

# Tags recorded [x] in the trackers (the ONLY items Pass 3 may touch).
SAFE=$(awk '
  match($0, /^[[:space:]]*[-*][[:space:]]+\[[xX]\][[:space:]]*/) {
    rest = substr($0, RLENGTH+1); sub(/^\*+[[:space:]]*/, "", rest)
    if (match(rest, /^[A-Za-z0-9][A-Za-z0-9._-]*/)) print substr(rest, 1, RLENGTH)
  }' "$TODOF" "$DONEF" | sort -u)
[ -n "$SAFE" ] || { echo "compact-plan: WQ no tracker-recorded done tags — no-op"; exit 0; }

QTMP=$(mktemp) || exit 1; QDROP=$(mktemp) || { rm -f "$QTMP"; exit 1; }
SAFEF=$(mktemp) || { rm -f "$QTMP" "$QDROP"; exit 1; }
printf '%s\n' "$SAFE" > "$SAFEF"

# Move the WHOLE span of each safe [x] item (its line + continuation lines) to the archive.
awk -v h="$QH" -v sec="$SEC_HEADER_RE" -v drop="$QDROP" -v safef="$SAFEF" '
  BEGIN { while ((getline t < safef) > 0) if (t != "") safe[t]=1 }
  function is_cb(l) { return l ~ /^[[:space:]]*[-*][[:space:]]+\[[ xX]\]/ }
  {
    if (NR == h) { inreg=1; prevblank=0; print; next }
    if (inreg && /^## / && (prevblank || (sec != "" && $0 ~ sec))) inreg=0
    if (inreg) {
      if (is_cb($0)) {
        dropping = 0
        if ($0 ~ /^[[:space:]]*[-*][[:space:]]+\[[xX]\]/) {
          rest = $0; sub(/^[[:space:]]*[-*][[:space:]]+\[[xX]\][[:space:]]*/, "", rest)
          sub(/^\*+[[:space:]]*/, "", rest)
          if (match(rest, /^[A-Za-z0-9][A-Za-z0-9._-]*/) && (substr(rest,1,RLENGTH) in safe)) dropping = 1
        }
      } else if ($0 ~ /^[[:space:]]*$/ || /^## / || /^### / || /^> /) dropping = 0
      if (dropping) { print >> drop; prevblank = ($0 ~ /^[[:space:]]*$/); next }
    }
    print
    prevblank = ($0 ~ /^[[:space:]]*$/)
  }
' "$PLAN" > "$QTMP" || { rm -f "$QTMP" "$QDROP" "$SAFEF"; exit 1; }

for a in '^## PRIME DIRECTIVES' '^## RESUME PROTOCOL' '^## WORK QUEUE' '^## Session Log' '^RUN STATUS:'; do
  grep -qE "$a" "$QTMP" || { echo "compact-plan: WQ VALIDATION FAIL ($a missing) — abort, plan untouched"; rm -f "$QTMP" "$QDROP" "$SAFEF"; exit 1; }
done
QO=$(awk 'END{print NR}' "$PLAN"); QK=$(awk 'END{print NR}' "$QTMP"); QD=$(awk 'END{print NR}' "$QDROP")
[ "$((QK + QD))" = "$QO" ] || { echo "compact-plan: WQ line conservation FAIL ($QK+$QD != $QO) — abort, plan untouched"; rm -f "$QTMP" "$QDROP" "$SAFEF"; exit 1; }
[ "$QD" -gt 0 ] || { echo "compact-plan: WQ nothing archivable (all remaining [x] are recorded ONLY in the plan) — no-op"; rm -f "$QTMP" "$QDROP" "$SAFEF"; exit 0; }
# Every OPEN item must survive untouched — Pass 3 must never remove actionable work.
OB=$(grep -cE '^[[:space:]]*[-*][[:space:]]+\[ \]' "$PLAN"); OA=$(grep -cE '^[[:space:]]*[-*][[:space:]]+\[ \]' "$QTMP")
[ "$OB" = "$OA" ] || { echo "compact-plan: WQ open-item count changed ($OB -> $OA) — abort, plan untouched"; rm -f "$QTMP" "$QDROP" "$SAFEF"; exit 1; }

cp "$PLAN" "$PLAN.bak" || { rm -f "$QTMP" "$QDROP" "$SAFEF"; exit 1; }
{
  echo ""
  echo "<!-- $(date -u +%Y-%m-%dT%H:%MZ) archived completed WORK QUEUE items from AUTONOMOUS_PLAN.md (done-state recorded in SUITE_TODO/_DONE; ${QREGB}B region vs ${WQ_MAX_BYTES}B budget) -->"
  cat "$QDROP"
} >> "$QUEUE_ARCHIVE" || { echo "compact-plan: WQ archive write failed — abort, plan untouched"; rm -f "$QTMP" "$QDROP" "$SAFEF"; exit 1; }
mv "$QTMP" "$PLAN"; rm -f "$QDROP" "$SAFEF"
echo "compact-plan: archived $QD WORK QUEUE line(s) of completed items; plan $QO -> $QK lines; archive=$QUEUE_ARCHIVE"
) || { echo "compact-plan: Pass 3 (WORK QUEUE) exited nonzero — plan left untouched by Pass 3 (see message above)"; ABORTED="$ABORTED pass3"; }

# ===== Final verdict (2026-08-06) — see the EXIT-CODE CONTRACT note above =====
if [ -n "$ABORTED" ]; then
  echo "compact-plan: ⚠⚠ ABORTED pass(es):$ABORTED — the plan was left UNTOUCHED by them, so its orientation"
  echo "compact-plan:    cost is NOT being bounded and will keep growing until this is fixed. Reproduce with"
  echo "compact-plan:    ops/autonomous/tests/prove-compact.sh (health-gate step 'compact-proof')."
  exit 1
fi
exit 0
