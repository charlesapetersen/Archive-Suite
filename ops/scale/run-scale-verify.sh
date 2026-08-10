#!/bin/bash
# run-scale-verify.sh — W26.verify's scale + safety lane, end to end.
#
# What it proves, in one run:
#   1. A Spotlight-free discovery pass over 100k+ files is affordable, measured on the SAME tree as the
#      path it replaced (so the ratio is apples-to-apples rather than against the plan's real-corpus
#      figures, which were measured on a different tree).
#   2. The stat-only revalidation pass — warm start's first phase — is the cheap phase it is designed
#      to be.
#   3. Cancelling mid-walk yields a result that is NOT clean and NOT completed, so it can never
#      authorise pruning rows the walk had not reached.
#   4. **Discovery writes nothing.** A separate program fingerprints every path in the tree (inode,
#      size, mtime, ctime, xattr digest) before and after, and any difference at all fails the run.
#      `execution-plans/despotlight.md` §7a.7: the subject cannot take this measurement about itself.
#
# The corpus is SCRATCH and synthetic — never the owner's archive. `scale-corpus.swift` refuses any root
# whose leaf is not named `scale-corpus*`, and refuses outright any path mentioning the real corpus.
#
#   ./ops/scale/run-scale-verify.sh                 # the real lane: 150,000 files
#   ./ops/scale/run-scale-verify.sh --files 120000
#   ./ops/scale/run-scale-verify.sh --self-test     # cheap: proves the no-write guard can FAIL
#   ./ops/scale/run-scale-verify.sh --keep          # leave the corpus for a follow-up lane
#
# Exit 0 = every lane green. Non-zero = a real failure; the corpus is left in place for inspection.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="${ARCHIVE_SCALE_SCRATCH:-$HOME/Library/Caches/ArchiveSuiteScale}"
FILES=150000
DIRS=650
SELF_TEST=0
KEEP=0
MIN_FILES=""
ROOT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --files)     FILES="$2"; shift 2 ;;
    --dirs)      DIRS="$2"; shift 2 ;;
    --root)      ROOT="$2"; shift 2 ;;
    --self-test) SELF_TEST=1; FILES=2000; DIRS=40; MIN_FILES=1000; shift ;;
    --keep)      KEEP=1; shift ;;
    -h|--help)   sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$ROOT" ] || ROOT="$SCRATCH/scale-corpus-$( [ "$SELF_TEST" = 1 ] && echo selftest || echo "$FILES" )"
[ -n "$MIN_FILES" ] || MIN_FILES="$FILES"
BIN="$REPO/build/scale/scale-corpus"
BEFORE="$SCRATCH/manifest-before.tsv"
AFTER="$SCRATCH/manifest-after.tsv"
REPORT="$SCRATCH/report.txt"

FAILED=0
step()   { printf '\n=== %s\n' "$*"; }
fail()   { printf '❌ %s\n' "$*"; FAILED=1; }
ok()     { printf '✓ %s\n' "$*"; }

mkdir -p "$SCRATCH" "$REPO/build/scale"

# ── 0. the observer tool ──────────────────────────────────────────────────────────────────────────
step "compiling the observer (ops/scale/scale-corpus.swift)"
if ! xcrun swiftc -O -o "$BIN" "$REPO/ops/scale/scale-corpus.swift"; then
  echo "could not compile scale-corpus.swift" >&2; exit 1
fi
ok "observer built"

# ── 1. the scratch corpus ─────────────────────────────────────────────────────────────────────────
step "scratch corpus: $ROOT"
# The self-test deliberately MUTATES the tree to prove the guard can fail, and a mutation moves `ctime`
# irreversibly — so a self-test corpus is disposable by construction and must never be reused as a
# baseline. (Reusing one silently absorbed a planted tag write into the "before" manifest once already.)
if [ "$SELF_TEST" = 1 ] && [ -f "$ROOT.meta.json" ]; then
  "$BIN" wipe --root "$ROOT" || exit 1
fi
if [ -f "$ROOT.meta.json" ]; then
  ok "reusing the corpus already built here"
  cat "$ROOT.meta.json"
else
  # A fresh build needs the room: ~150k small files is a few GB with APFS block overhead.
  AVAIL_MB=$(df -m "$SCRATCH" | awk 'NR==2 {print $4}')
  NEED_MB=$(( FILES / 100 + 500 ))
  if [ "$AVAIL_MB" -lt "$NEED_MB" ]; then
    echo "only ${AVAIL_MB} MiB free at $SCRATCH; need about ${NEED_MB} MiB" >&2; exit 1
  fi
  "$BIN" build --root "$ROOT" --files "$FILES" --dirs "$DIRS" || exit 1
fi

# ── 2. the before manifest ────────────────────────────────────────────────────────────────────────
step "fingerprinting the tree BEFORE any walk"
"$BIN" manifest --root "$ROOT" --out "$BEFORE" || exit 1

# ── 3. the ArchiveCore lane ───────────────────────────────────────────────────────────────────────
step "ArchiveCore lane — walk, fingerprint pass, cancel semantics"
CORE_LOG="$SCRATCH/core-lane.log"
(
  cd "$REPO/packages/ArchiveCore" || exit 1
  # RELEASE, deliberately. A debug ArchiveCore walks at ~350 us/file (measured on the self-test tree),
  # which is an -Onone artefact and would make the headline number a fiction: the app ships optimised,
  # and the ~12 s baseline this lane is measured against was taken with optimised Foundation calls.
  ARCHIVE_SCALE_ROOT="$ROOT" ARCHIVE_SCALE_MIN_FILES="$MIN_FILES" \
    xcrun swift test -c release --build-path .build --filter 'CorpusWalkerScaleTests' 2>&1
) | tee "$CORE_LOG"
grep -q 'with 0 failures' "$CORE_LOG" || fail "ArchiveCore scale lane did not pass (see $CORE_LOG)"
grep -q 'tests skipped' "$CORE_LOG" && fail "ArchiveCore scale lane SKIPPED — the env gate did not take"
grep -E '^ *(SCALE|filesSeen|CorpusWalker|old resourceValues|footprint)' "$CORE_LOG" > "$REPORT"

# ── 4. the after manifest, and the no-write assertion ─────────────────────────────────────────────
step "fingerprinting the tree AFTER, and diffing"
"$BIN" manifest --root "$ROOT" --out "$AFTER" || exit 1
if "$BIN" compare --before "$BEFORE" --after "$AFTER"; then
  ok "no-write assertion holds across the whole tree"
else
  fail "the discovery lane MUTATED the tree — see the diff above"
fi

# ── 5. self-test: the no-write guard must be able to fail ─────────────────────────────────────────
# A guard nobody has watched fail is not a guard. This mutates one file's tags the way a real write
# would and requires `compare` to catch it; then it restores the tree and requires green again.
if [ "$SELF_TEST" = 1 ]; then
  step "self-test — proving the no-write guard has teeth"
  VICTIM="$(find "$ROOT" -name '*.pdf' -not -path '*zz-hostile*' | head -1)"
  if [ -z "$VICTIM" ]; then
    fail "self-test found no file to mutate"
  else
    # No attempt is made to restore the victim: `ctime` moves on any xattr write and cannot be put
    # back, so the tree is wiped at the end of a self-test rather than pretending to be pristine.
    xattr -w com.apple.metadata:_kMDItemUserTags 'planted-by-self-test' "$VICTIM"
    "$BIN" manifest --root "$ROOT" --out "$AFTER" >/dev/null
    if "$BIN" compare --before "$BEFORE" --after "$AFTER" >/dev/null 2>&1; then
      fail "MUTATION NOT DETECTED — the no-write assertion is vacuous"
    else
      ok "a planted tag write is detected (guard is live)"
    fi

    step "self-test — a NEW FILE in the tree must also be caught"
    PLANTED="$ROOT/.archive-suite-root.json"
    printf '{"guid":"planted"}' > "$PLANTED"
    "$BIN" manifest --root "$ROOT" --out "$AFTER" >/dev/null
    if "$BIN" compare --before "$BEFORE" --after "$AFTER" >/dev/null 2>&1; then
      fail "A PLANTED MARKER FILE WAS NOT DETECTED — §7a.7's exact case would pass unnoticed"
    else
      ok "a planted .archive-suite-root.json is detected as an added path"
    fi
    rm -f "$PLANTED"
  fi
  KEEP=0   # a mutated tree is never a baseline; see the wipe note above
fi

# ── 6. report ─────────────────────────────────────────────────────────────────────────────────────
step "report"
cat "$REPORT" 2>/dev/null
echo
if [ "$KEEP" = 1 ] || [ "$FAILED" = 1 ]; then
  echo "corpus kept at $ROOT (wipe: $BIN wipe --root '$ROOT')"
else
  "$BIN" wipe --root "$ROOT"
fi

if [ "$FAILED" = 0 ]; then echo "✅ scale lane GREEN"; exit 0; fi
echo "❌ scale lane RED"; exit 1
