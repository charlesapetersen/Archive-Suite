#!/bin/bash
# despotlight-audit.sh — W26.verify's completion audit: no code in this suite relies on Spotlight.
#
# The wave exists because a dead Spotlight index made the Reader report "no tagged PDFs" over 1,849
# correctly-tagged files (owner directive 2026-08-04: *"Spotlight is fundamentally unreliable on macOS."*).
# The item's stated gate was a single grep, and `execution-plans/despotlight.md` §7a.7 recorded that that
# grep is **unsatisfiable as written**, because the wave's own work adds new mentions — the xattr name
# itself, the tests that prove Spotlight is blind, and the prose recording what was removed. So it is
# split into the two rules §7a.7 prescribes, and made runnable rather than remembered.
#
#   RULE 1  No Spotlight API or CLI in EXECUTABLE code: NSMetadataQuery, NSMetadataItem, MDQuery,
#           CoreSpotlight, CSSearchable, mdfind, mdimport, mdutil, mdls. A mention in a COMMENT or a
#           module docstring is fine and expected — that is how the suite records what it removed.
#   RULE 2  `kMDItemUserTags` is permitted only as part of the extended-attribute name
#           `com.apple.metadata:_kMDItemUserTags` (a filesystem read, not a Spotlight query). A bare
#           `kMDItemUserTags` — the Spotlight attribute — is banned in code, and any OTHER `kMDItem*`
#           attribute is banned outright.
#
# **Comment detection is multi-line aware, on purpose.** A rule keyed on "the line starts with //" would
# have flagged two lines of `assert_mac.py`'s module docstring and, worse, would have passed a Spotlight
# call written across two lines. §7a.8 of the plan records the same trap in the write-surface lint's
# enumerator rule: a rule that cannot see a whole construct passes vacuously, "the worst kind of green".
# So each file is tokenised for `//`, `#`, `/* … */` and `""" … """` regions before matching.
#
# Three files are allowed to break rule 1 on purpose, each because its whole job is to prove Spotlight
# cannot be trusted; they are listed with their reason below, and an allowance whose file no longer has
# any hit is a HARD FAILURE (a pre-approved hole nobody is using is a hole waiting for a new write).
#
# Scope: source and scripts under ArchiveReader/, ArchiveProcessor/, packages/, scripts/. Markdown is
# deliberately OUT of scope — prose about Spotlight is `W26.docs`'s remit and it shipped; auditing it
# here would just re-flag every sentence explaining the removal.
#
#   ./ops/despotlight-audit.sh              # audit the tree
#   ./ops/despotlight-audit.sh --self-test  # prove each rule FAILS on a planted violation
#
# Exit 0 = clean. 1 = a violation (or a stale allowance). 2 = the audit could not run.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF_TEST=0
[ "${1:-}" = "--self-test" ] && SELF_TEST=1

audit() {
  python3 - "$1" <<'PYTHON'
import os, re, sys

BASE = sys.argv[1]
SCOPES = ["ArchiveReader", "ArchiveProcessor", "packages", "scripts"]
EXTENSIONS = {".swift", ".py", ".sh", ".rb", ".pl", ".m", ".h", ".kt", ".java", ".plist", ".yml", ".yaml"}
PRUNE = {"build", ".build", "DerivedData", "old", "node_modules", ".git"}

SPOTLIGHT = re.compile(r"NSMetadataQuery|NSMetadataItem|MDQuery|CoreSpotlight|CSSearchable"
                       r"|mdfind|mdimport|mdutil|mdls")
XATTR_NAME = "com.apple.metadata:_kMDItemUserTags"

# (path relative to BASE) -> why it is allowed to name Spotlight in executable code.
ALLOWED = {
    "ArchiveProcessor/scripts/finder_tags.py":
        "W26.oracle's self-test: runs mdls on a tagged /tmp fixture to re-measure the blindness "
        "this module exists to remove",
    "ArchiveProcessor/scripts/test-finder-tags.sh":
        "the harness half of the same measurement: mdls must NOT see the year the xattr read finds",
    "ArchiveReader/scripts/test-fixture-scripts.sh":
        "W26.scripts' tripwire: shims mdimport/mdfind to catch a reintroduced poll, and runs mdfind "
        "once as an UNindexed negative control",
}

def candidate_files():
    for scope in SCOPES:
        top = os.path.join(BASE, scope)
        if not os.path.isdir(top):
            continue
        for dirpath, dirnames, filenames in os.walk(top):
            dirnames[:] = [d for d in dirnames if d not in PRUNE and not d.endswith(".xcodeproj")]
            for name in filenames:
                if os.path.splitext(name)[1] in EXTENSIONS:
                    yield os.path.join(dirpath, name)

def code_lines(path, text):
    """Yield (line_number, code_only_text) with comments and docstrings blanked out.

    Multi-line aware by construction: a C block comment or a Python triple-quoted region is prose for
    its whole extent, and a construct split across lines is still matched because the code text is what
    remains. Blanked rather than dropped so line numbers stay true to the file.
    """
    is_hash = path.endswith((".sh", ".py", ".rb", ".pl", ".yml", ".yaml"))
    in_block = False          # /* … */
    in_docstring = None       # the triple-quote that opened it
    for number, raw in enumerate(text.splitlines(), start=1):
        line = raw
        if in_block:
            end = line.find("*/")
            if end < 0:
                yield number, ""
                continue
            line = line[end + 2:]
            in_block = False
        if in_docstring:
            end = line.find(in_docstring)
            if end < 0:
                yield number, ""
                continue
            line = line[end + 3:]
            in_docstring = None
        # Strip inline comments and open a block/docstring if one starts on this line.
        for quote in ('"""', "'''"):
            index = line.find(quote)
            # A docstring only counts when the line does not also close it.
            if index >= 0 and line.find(quote, index + 3) < 0:
                in_docstring = quote
                line = line[:index]
                break
        index = line.find("/*")
        if index >= 0 and line.find("*/", index + 2) < 0:
            in_block = True
            line = line[:index]
        if is_hash:
            index = line.find("#")
            if index >= 0:
                line = line[:index]
        else:
            index = line.find("//")
            if index >= 0:
                line = line[:index]
            stripped = line.lstrip()
            if stripped.startswith("*"):     # continuation line of a block comment
                line = ""
        yield number, line

failures = []
allowed_hits = {}
files = sorted(candidate_files())
if not files:
    print("❌ no candidate files found — the scope globs are wrong")
    sys.exit(2)
print(f"auditing {len(files)} files under {', '.join(SCOPES)}")

for path in files:
    relative = os.path.relpath(path, BASE)
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError as error:
        failures.append(f"could not read {relative}: {error}")
        continue
    if not (SPOTLIGHT.search(text) or "kMDItem" in text):
        continue
    reason = ALLOWED.get(relative)
    for number, code in code_lines(path, text):
        if not code.strip():
            continue
        # RULE 1
        if SPOTLIGHT.search(code):
            if reason:
                allowed_hits[relative] = allowed_hits.get(relative, 0) + 1
            else:
                failures.append(f"RULE 1 — Spotlight in executable code: {relative}:{number}\n"
                                f"        {code.strip()[:140]}")
        # RULE 2 — what is left once every legitimate xattr name is removed.
        residue = code.replace(XATTR_NAME, "")
        if "kMDItem" in residue:
            if reason:
                allowed_hits[relative] = allowed_hits.get(relative, 0) + 1
            else:
                failures.append(f"RULE 2 — a Spotlight attribute, not the xattr name: {relative}:{number}\n"
                                f"        {code.strip()[:140]}")

# Stale-allowance guard, the same shape W26.lint's write-surface lint hard-fails on: an allowance for a
# file with nothing left to allow is a pre-approved hole for the next write to slip into.
for relative, why in sorted(ALLOWED.items()):
    if not os.path.isfile(os.path.join(BASE, relative)):
        failures.append(f"STALE ALLOWANCE: {relative} no longer exists — remove it from this audit")
    elif relative not in allowed_hits:
        failures.append(f"STALE ALLOWANCE: {relative} no longer names Spotlight in code — "
                        f"remove it ({why})")

for line in failures:
    print("❌ " + line)
if failures:
    print(f"\n❌ AUDIT FAILED — {len(failures)} finding(s)")
    sys.exit(1)
total = sum(allowed_hits.values())
print(f"✓ no Spotlight reliance in executable code "
      f"({total} deliberate hits across {len(allowed_hits)} allowed file(s))")
sys.exit(0)
PYTHON
}

if [ "$SELF_TEST" = 0 ]; then
  echo "=== de-Spotlight audit (W26.verify)"
  audit "$ROOT"
  exit $?
fi

# ── SELF-TEST ─────────────────────────────────────────────────────────────────────────────────────
# The audit is only worth its green if it can go red. Each case plants ONE violation in a throwaway
# copy of the tree and requires the expected verdict — including the two cases that must still PASS, so
# the rules cannot decay into "any mention anywhere is a violation", which would make the suite's own
# record of what it removed unwritable.
echo "=== self-test: every rule watched to fail (and to tolerate what it must)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
for scope in ArchiveReader ArchiveProcessor packages scripts; do
  [ -d "$ROOT/$scope" ] || continue
  mkdir -p "$TMP/$scope"
  # Only what the audit reads. A plain `cp -R` of ArchiveReader would drag in gigabytes of DerivedData.
  rsync -a --include='*/' \
    --include='*.swift' --include='*.py' --include='*.sh' --include='*.plist' --include='*.yml' \
    --exclude='build/' --exclude='.build/' --exclude='*' \
    "$ROOT/$scope/" "$TMP/$scope/" 2>/dev/null
done

VICTIM="$TMP/packages/ArchiveCore/Sources/ArchiveCore/Corpus/CorpusWalker.swift"
ORACLE="$TMP/ArchiveProcessor/scripts/finder_tags.py"
HARNESS="$TMP/ArchiveProcessor/scripts/test-finder-tags.sh"
for required in "$VICTIM" "$ORACLE" "$HARNESS"; do
  [ -f "$required" ] || { echo "❌ self-test could not stage $required"; exit 2; }
done
cp "$VICTIM" "$TMP/victim.orig"

PASSES=0
FAILS=0
expect() {
  local want="$1" label="$2"
  local rc=0
  audit "$TMP" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "$want" ]; then PASSES=$((PASSES + 1)); printf '✓ %s\n' "$label"
  else FAILS=$((FAILS + 1)); printf '❌ %s (wanted exit %s, got %s)\n' "$label" "$want" "$rc"; fi
  cp "$TMP/victim.orig" "$VICTIM"
}

expect 0 "the unmodified copy is clean"

printf '\nlet query = NSMetadataQuery()\n' >> "$VICTIM"
expect 1 "RULE 1 catches an NSMetadataQuery in Swift code"

printf '\n// a comment mentioning NSMetadataQuery must NOT trip it\n' >> "$VICTIM"
expect 0 "RULE 1 tolerates the same symbol in a line comment"

printf '\n/*\n a block comment mentioning mdfind and mdimport\n*/\n' >> "$VICTIM"
expect 0 "RULE 1 tolerates it inside a multi-line block comment"

printf '\nlet spread = NSMetadataQuery(\n  predicate: nil)\n' >> "$VICTIM"
expect 1 "RULE 1 catches a call split across lines"

printf '\nlet predicate = "kMDItemUserTags == %%@"\n' >> "$VICTIM"
expect 1 "RULE 2 catches a bare kMDItemUserTags query predicate"

printf '\nlet name = "com.apple.metadata:_kMDItemUserTags"\n' >> "$VICTIM"
expect 0 "RULE 2 permits the full xattr name"

printf '\nlet other = "kMDItemContentModificationDate"\n' >> "$VICTIM"
expect 1 "RULE 2 catches a different kMDItem attribute"

printf '\nsubprocess.run(["mdfind", "-onlyin", "/tmp"])\n' >> "$ORACLE"
expect 0 "an ALLOWED file may hold the measurement it exists for"
git -C "$ROOT" show HEAD:ArchiveProcessor/scripts/finder_tags.py > "$ORACLE" 2>/dev/null \
  || cp "$ROOT/ArchiveProcessor/scripts/finder_tags.py" "$ORACLE"

python3 - "$HARNESS" <<'STRIP'
import re, sys
path = sys.argv[1]
pattern = re.compile(r"NSMetadataQuery|NSMetadataItem|MDQuery|CoreSpotlight|CSSearchable"
                     r"|mdfind|mdimport|mdutil|mdls|kMDItem")
lines = [l for l in open(path).read().splitlines(True) if not pattern.search(l)]
open(path, "w").writelines(lines)
STRIP
expect 1 "a STALE allowance (file no longer names Spotlight) hard-fails"

echo
echo "self-test: $PASSES passed, $FAILS failed"
[ "$FAILS" = 0 ] || exit 1
echo "✓ SELF-TEST CLEAN — every rule has been watched to fail, and to tolerate what it must"
