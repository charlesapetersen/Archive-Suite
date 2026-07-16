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
KEEP="${KEEP:-12}"          # recent Session Log entries to retain inline
TRIGGER="${TRIGGER:-40}"    # only compact when the log exceeds this many entries (else no-op)

[ -f "$PLAN" ] || { echo "compact-plan: no plan at $PLAN — skip"; exit 0; }

H=$(grep -nE '^## Session Log' "$PLAN" | head -1 | cut -d: -f1)
[ -n "$H" ] || { echo "compact-plan: no '## Session Log' header — skip"; exit 0; }

TOTAL=$(wc -l < "$PLAN" | tr -d ' ')
# region end = first '## ' header strictly after the Session Log header, else EOF+1
E=$(awk -v h="$H" 'NR>h && /^## /{print NR; exit}' "$PLAN")
[ -n "$E" ] || E=$((TOTAL + 1))

# count entry lines ('- ' bullets) inside the Session Log region only
N=$(awk -v h="$H" -v e="$E" 'NR>h && NR<e && /^- /{c++} END{print c+0}' "$PLAN")
if [ "$N" -le "$TRIGGER" ]; then
  echo "compact-plan: $N Session Log entries <= trigger $TRIGGER — no-op"; exit 0
fi

CUT=$((N - KEEP))
[ "$CUT" -gt 0 ] || { echo "compact-plan: nothing to cut (N=$N KEEP=$KEEP) — no-op"; exit 0; }

TMP=$(mktemp) || exit 1
DROP=$(mktemp) || { rm -f "$TMP"; exit 1; }

# Drop the FIRST $CUT entry lines in the region (oldest), keep the last $KEEP; everything else verbatim.
awk -v h="$H" -v e="$E" -v cut="$CUT" -v drop="$DROP" '
  BEGIN { seen = 0 }
  (NR > h && NR < e && /^- /) {
    seen++
    if (seen <= cut) { print >> drop; next }
  }
  { print }
' "$PLAN" > "$TMP" || { rm -f "$TMP" "$DROP"; exit 1; }

# VALIDATE — every live anchor must survive, or abort with the plan untouched.
for a in '^## PRIME DIRECTIVES' '^## RESUME PROTOCOL' '^## WORK QUEUE' '^## Session Log' '^RUN STATUS:'; do
  grep -qE "$a" "$TMP" || { echo "compact-plan: VALIDATION FAIL ($a missing) — abort, plan untouched"; rm -f "$TMP" "$DROP"; exit 1; }
done
if grep -qE '^## Morning Review' "$PLAN"; then
  grep -qE '^## Morning Review' "$TMP" || { echo "compact-plan: Morning Review lost — abort, plan untouched"; rm -f "$TMP" "$DROP"; exit 1; }
fi
# The entire pre-log region (everything through the Session Log header) must be byte-identical.
if ! diff -q <(sed -n "1,${H}p" "$PLAN") <(sed -n "1,${H}p" "$TMP") >/dev/null 2>&1; then
  echo "compact-plan: pre-log region changed — abort, plan untouched"; rm -f "$TMP" "$DROP"; exit 1
fi
NEW=$(wc -l < "$TMP" | tr -d ' ')
[ "$NEW" -lt "$TOTAL" ] || { echo "compact-plan: no line reduction — abort, plan untouched"; rm -f "$TMP" "$DROP"; exit 1; }

# Commit: back up the plan, append the dropped entries to the archive, then atomically replace.
cp "$PLAN" "$PLAN.bak" || { rm -f "$TMP" "$DROP"; exit 1; }
{
  echo ""
  echo "<!-- $(date -u +%Y-%m-%dT%H:%MZ) archived $CUT Session Log entries from AUTONOMOUS_PLAN.md (kept last $KEEP inline) -->"
  cat "$DROP"
} >> "$ARCHIVE"
mv "$TMP" "$PLAN"
rm -f "$DROP"
echo "compact-plan: archived $CUT entries; plan $TOTAL -> $NEW lines; archive=$ARCHIVE"
