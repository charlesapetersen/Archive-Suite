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
#   5. **The two lanes above agree about the WALK, and the run states ONE per-file cost.** They walk the
#      same tree in different processes, and a process's QoS moves every filesystem primitive by ~5-6x
#      (`W26.verify-fu1`), so their raw per-file absolutes are not comparable and only the unclamped one
#      is a cost the app would pay. Each lane therefore also measures a reference pass, and step 3c
#      compares the ratios.
#
# The corpus is SCRATCH and synthetic — never the owner's archive. `scale-corpus.swift` refuses any root
# whose leaf is not named `scale-corpus*`, and refuses outright any path mentioning the real corpus.
#
#   ./ops/scale/run-scale-verify.sh                 # the real lane: 150,000 files
#   ./ops/scale/run-scale-verify.sh --files 120000
#   ./ops/scale/run-scale-verify.sh --self-test     # cheap: proves the no-write guard can FAIL
#   ./ops/scale/run-scale-verify.sh --keep          # leave the corpus for a follow-up lane
#   ./ops/scale/run-scale-verify.sh --prove-calibration   # seconds, no corpus: proves step 3c can FAIL
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
PROVE_CALIB=0
# How far the two lanes' NORMALISED walk costs may sit apart before step 3c calls it a disagreement about
# the code rather than about the environment. 2.0x, and the width is deliberate: repeated runs of one lane
# spread ~20%, while the disagreement this exists to catch was 4.4x. A tight bound flakes; the absent
# bound is what filed `W26.verify-fu1`.
CALIB_TOLERANCE=2.0

while [ $# -gt 0 ]; do
  case "$1" in
    --files)     FILES="$2"; shift 2 ;;
    --dirs)      DIRS="$2"; shift 2 ;;
    --root)      ROOT="$2"; shift 2 ;;
    # On a 2,000-file tree the reference pass is ~30 ms, so the ratio is timer-dominated: measured
    # spreads of 1.7x are ordinary there and mean nothing. The self-test proves the guard's teeth via
    # --prove-calibration, not by running a real measurement on a tree too small to measure.
    --self-test) SELF_TEST=1; FILES=2000; DIRS=40; MIN_FILES=1000; CALIB_TOLERANCE=3.0; shift ;;
    --keep)      KEEP=1; shift ;;
    --prove-calibration) PROVE_CALIB=1; shift ;;
    -h|--help)   sed -n '2,31p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$ROOT" ] || ROOT="$SCRATCH/scale-corpus-$( [ "$SELF_TEST" = 1 ] && echo selftest || echo "$FILES" )"
[ -n "$MIN_FILES" ] || MIN_FILES="$FILES"
BIN="$REPO/build/scale/scale-corpus"
HOSTILE="$ROOT-hostile"
BEFORE="$SCRATCH/manifest-before.tsv"
AFTER="$SCRATCH/manifest-after.tsv"
REPORT="$SCRATCH/report.txt"

FAILED=0
step()   { printf '\n=== %s\n' "$*"; }
fail()   { printf '❌ %s\n' "$*"; FAILED=1; }
ok()     { printf '✓ %s\n' "$*"; }

# ── the cross-lane calibration comparator (step 3c) ───────────────────────────────────────────────
# Kept up here, as a pure function of two `SCALE calib` lines, so `--prove-calibration` can watch it
# FAIL without a corpus. It reports; the CALLER decides what a non-zero return does to the run.
calib_line()  { grep -o "SCALE calib lane=$2 .*" "$1" | tail -1; }
calib_field() { printf '%s\n' "$1" | tr ' ' '\n' | awk -F= -v k="$2" '$1 == k { print $2 }'; }

# calibration_verdict <core-line> <reader-line> → 0 agree, 1 disagree, 2 a line is missing/unparseable.
calibration_verdict() {
  local core="$1" reader="$2" core_n reader_n spread headline taxed line head_lane head_us tax summary
  # A missing line is a FAILURE, not a skip: a lane that quietly stopped calibrating would take this
  # whole check with it and leave the headline number unguarded again — silently.
  if [ -z "$core" ] || [ -z "$reader" ]; then
    printf '❌ a lane emitted no SCALE calib line (core=%s reader=%s)\n' "${core:-<none>}" "${reader:-<none>}"
    return 2
  fi
  printf '%s\n%s\n' "$core" "$reader"
  core_n="$(calib_field "$core" normalised)"
  reader_n="$(calib_field "$reader" normalised)"
  if [ -z "$core_n" ] || [ -z "$reader_n" ]; then
    printf '❌ a SCALE calib line carries no normalised= field (core=%s reader=%s)\n' "$core" "$reader"
    return 2
  fi
  spread="$(awk -v a="$core_n" -v b="$reader_n" \
    'BEGIN { if (a+0 <= 0 || b+0 <= 0) print 0; else printf "%.2f", (a > b ? a/b : b/a) }')"

  # The headline: only an UNCLAMPED lane may state what discovery costs. Chosen from the reported qos,
  # not hardcoded — run this interactively and both lanes are unclamped; run it from the daemon and only
  # the app-hosted one is.
  headline=""; taxed=""
  for line in "$core" "$reader"; do
    if [ "$(calib_field "$line" clamped)" = "no" ]; then headline="$line"; else taxed="$line"; fi
  done
  if [ -n "$headline" ]; then
    head_lane="$(calib_field "$headline" lane)"
    head_us="$(calib_field "$headline" walk)"
    summary="one number: a full walk costs ${head_us} us/file (lane=${head_lane}, qos=$(calib_field "$headline" qos), unclamped)"
    if [ -n "$taxed" ]; then
      tax="$(awk -v a="$(calib_field "$taxed" walk)" -v b="$head_us" \
        'BEGIN { printf "%.1f", (b+0 > 0 ? a/b : 0) }')"
      summary="$summary; lane=$(calib_field "$taxed" lane) reports $(calib_field "$taxed" walk) us/file, ${tax}x inflated by its QOS_CLASS_BACKGROUND clamp — not a cost the app pays"
    fi
    printf '✓ %s\n' "$summary"
    [ -n "${REPORT:-}" ] && printf 'SCALE headline %s\n' "$summary" >> "$REPORT"
  else
    # Not a failure: it means the run had no unclamped lane, so it has no shipping number to quote.
    printf '⚠️  every lane was QoS-clamped; the per-file absolutes above are inflated and none of them\n'
    printf '   is a cost the app would pay. Re-run from an unclamped shell for a headline number.\n'
    [ -n "${REPORT:-}" ] && printf 'SCALE headline UNAVAILABLE — every lane was QoS-clamped\n' >> "$REPORT"
  fi

  if awk -v s="$spread" -v t="$CALIB_TOLERANCE" 'BEGIN { exit !(s+0 > 0 && s+0 <= t+0) }'; then
    printf '✓ the lanes agree on the WALK once the process is normalised out (%s vs %s, %sx apart, tolerance %sx)\n' \
      "$core_n" "$reader_n" "$spread" "$CALIB_TOLERANCE"
    return 0
  fi
  printf '❌ the lanes disagree about the walk itself, not just their environments: normalised %s vs %s (%sx > %sx)\n' \
    "$core_n" "$reader_n" "$spread" "$CALIB_TOLERANCE"
  return 1
}

# ── --prove-calibration: a guard nobody has watched fail is not a guard ───────────────────────────
if [ "$PROVE_CALIB" = 1 ]; then
  REPORT=""    # nothing is appended to a real report by a proof run
  PROOF_FAILED=0
  expect() {   # expect <want-rc> <label> <core-line> <reader-line>
    local want="$1" label="$2"; shift 2
    calibration_verdict "$@" > /dev/null 2>&1
    local got=$?
    if [ "$got" = "$want" ]; then ok "$label (rc=$got)"
    else printf '❌ %s: wanted rc=%s, got rc=%s\n' "$label" "$want" "$got"; PROOF_FAILED=1; fi
  }
  AGREE_CORE='SCALE calib lane=core qos=9 clamped=yes files=150000 walk=218.7 reference=24.5 normalised=8.93'
  AGREE_READ='SCALE calib lane=reader qos=25 clamped=no files=150000 walk=37.7 reference=5.0 normalised=7.51'
  step "proving the cross-lane comparator can pass AND fail"
  expect 0 "two lanes whose ratios agree are accepted"            "$AGREE_CORE" "$AGREE_READ"
  expect 1 "a 4.4x disagreement in the RATIO is rejected" \
    "${AGREE_CORE/normalised=8.93/normalised=33.0}" "$AGREE_READ"
  expect 1 "the same rejection in the other direction" \
    "$AGREE_CORE" "${AGREE_READ/normalised=7.51/normalised=1.7}"
  expect 2 "a missing core line is a failure, not a skip"          ""            "$AGREE_READ"
  expect 2 "a missing reader line is a failure, not a skip"        "$AGREE_CORE" ""
  expect 2 "a line with no normalised= field is a failure"         "SCALE calib lane=core qos=9" "$AGREE_READ"
  # Inflated ABSOLUTES with matching ratios are exactly the real 2026-08-10 case: accepted, because the
  # tax is the environment's, and the headline must then quote the unclamped lane.
  expect 0 "a 5.8x absolute gap with agreeing ratios is accepted"  "$AGREE_CORE" "$AGREE_READ"
  # The two headline checks CAPTURE the verdict and match the string, rather than piping it into
  # `grep -q`. That pipe is a SIGPIPE race, and it is not theoretical: `grep -q` exits on the first
  # match while `calibration_verdict` is still writing, the writing subshell dies 141, and `pipefail`
  # reports the whole pipeline as failed — so both of these checks read RED against a comparator that
  # had in fact printed exactly the right sentence. A proof that fails when the thing it watches is
  # correct is worse than no proof.
  says() {     # says <label> <expected-substring> <core-line> <reader-line>
    local label="$1" want="$2"; shift 2
    local out; out="$(calibration_verdict "$@")"
    case "$out" in
      *"$want"*) ok "$label" ;;
      *) printf '❌ %s — no line matched %s\n' "$label" "$want"; PROOF_FAILED=1 ;;
    esac
  }
  says "the headline quotes the UNCLAMPED lane's number" \
       'costs 37.7 us/file (lane=reader' "$AGREE_CORE" "$AGREE_READ"
  says "with no unclamped lane it refuses to quote a number" \
       'every lane was QoS-clamped' "$AGREE_CORE" "${AGREE_READ/clamped=no/clamped=yes}"
  if [ "$PROOF_FAILED" = 0 ]; then echo; echo "✅ calibration comparator proof GREEN"; exit 0; fi
  echo; echo "❌ calibration comparator proof RED"; exit 1
fi

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
# The hostile sibling is walked too, so it needs the same guard — and it is the more interesting half:
# these are the files the walker must report as unreadable, and a "fix" that made them readable (or
# writable) would show up here as a ctime change rather than as a passing test.
"$BIN" manifest --root "$HOSTILE" --out "$BEFORE.hostile" || exit 1

# ── 3. the ArchiveCore lane ───────────────────────────────────────────────────────────────────────
step "ArchiveCore lane — walk, fingerprint pass, cancel semantics"
CORE_LOG="$SCRATCH/core-lane.log"
(
  cd "$REPO/packages/ArchiveCore" || exit 1
  # RELEASE, because that is what ships. It is NOT what makes this lane's number what it is, though:
  # measured on the same 30k tree, 2026-08-10, debug walks it at 230.1 us/file and release at 218.7 —
  # a 5% difference, i.e. noise, because the walk is syscall-bound and there is nothing for -O to
  # inline away. (An earlier comment here blamed a ~350 us/file debug figure on -Onone; the real term
  # is the process's QoS clamp, which moves this lane ~5-6x on its own — step 3c and `W26.verify-fu1`.)
  ARCHIVE_SCALE_ROOT="$ROOT" ARCHIVE_SCALE_HOSTILE_ROOT="$HOSTILE" \
  ARCHIVE_SCALE_MIN_FILES="$MIN_FILES" \
    xcrun swift test -c release --build-path .build --filter 'CorpusWalkerScaleTests' 2>&1
) | tee "$CORE_LOG"
grep -q 'with 0 failures' "$CORE_LOG" || fail "ArchiveCore scale lane did not pass (see $CORE_LOG)"
grep -q 'tests skipped' "$CORE_LOG" && fail "ArchiveCore scale lane SKIPPED — the env gate did not take"
grep -E '^ *(SCALE|filesSeen|CorpusWalker|old resourceValues|footprint)' "$CORE_LOG" > "$REPORT"

# ── 3b. the Reader warm-start lane ────────────────────────────────────────────────────────────────
# Cold index build, warm start, steady revalidation, and the cancel semantics `W26.idx` never ran at
# scale. This is the app-HOSTED unit bundle, which since 2026-07-30 renders nothing under
# `ArchiveTestHost` — it draws no window and never touches the owner's screen or their granted root.
# `-only-testing` keeps it to the unit bundle; the UITests belong to the VM lane, never the host.
#
# The corpus path is handed over in a FILE, not an env var. A `TEST_RUNNER_`-prefixed build setting is
# the documented way to forward environment into a test process, and the build tool does accept it — but
# measured here, the value never reaches an app-HOSTED unit test: every case skipped while the run still
# reported TEST SUCCEEDED. The path is fixed rather than derived from $SCRATCH, because inside the
# sandbox the test can only compute an absolute /Users/<name>/… path (its own $HOME is the container).
step "Reader lane — cold index, warm start, steady revalidation, cancel semantics"
READER_LOG="$SCRATCH/reader-lane.log"
HANDSHAKE="$HOME/Library/Caches/ArchiveSuiteScale/scale-lane-root.txt"
mkdir -p "$(dirname "$HANDSHAKE")"
printf '%s\n%s\n' "$ROOT" "$MIN_FILES" > "$HANDSHAKE"
(
  cd "$REPO/ArchiveReader/macOS" || exit 1
  export PATH=/opt/homebrew/bin:$PATH
  xcodegen generate >/dev/null 2>&1
  xcodebuild test -scheme ArchiveReader -destination "platform=macOS" \
    -only-testing:ArchiveReaderTests/LibraryIndexScaleTests \
    -derivedDataPath ./build/scale-DD 2>&1
) | tee "$READER_LOG" | grep -E '^(SCALE|  |Test Suite .Selected|.*(error|failed|passed|Skipped))' | tail -40
if grep -q 'TEST SUCCEEDED' "$READER_LOG"; then
  ok "Reader warm-start lane passed"
else
  fail "Reader warm-start lane did not pass (see $READER_LOG)"
fi
# A SKIPPED case is a FAILED lane here. This is the check that caught the env-forwarding gap above:
# without it the run reported TEST SUCCEEDED over two cases that had measured nothing at all.
grep -qE "Test Case.*' skipped" "$READER_LOG" && \
  fail "Reader lane SKIPPED — the handshake did not reach the test process ($HANDSHAKE)"
grep -E '^ *(SCALE|filesSeen|cold|WARM|steady|sqlite|footprint)' "$READER_LOG" >> "$REPORT"

# ── 3c. cross-lane calibration — ONE per-file number, not two ─────────────────────────────────────
# `W26.verify-fu1`. The two lanes above walk the SAME tree and disagreed by 4.4x on the per-file cost,
# with nothing to say which was real. The answer is that neither absolute is a property of the walker:
# an unattended daemon session runs at QOS_CLASS_BACKGROUND, so `swift test` — spawned by that session —
# is clamped to efficiency cores, while the app-hosted lane escapes because `testmanagerd` launches its
# host. Measured by decomposing the walk, EVERY filesystem primitive is ~5-6x dearer under the clamp,
# including bare enumeration and a bare stat(2), neither of which contains a line of our code.
#
# So each lane emits a `SCALE calib` line pairing its walk with a reference pass (the shipped stat-only
# walk) taken moments later at the same warmth, and this step compares the two RATIOS. The ratio is what
# survives the environment. The absolute quoted as "what discovery costs" is then the one from the
# UNCLAMPED lane, chosen from the reported `qos`, not hardcoded — run this interactively and both lanes
# are unclamped; run it from the daemon and only the app-hosted one is.
step "cross-lane calibration (W26.verify-fu1)"
calibration_verdict "$(calib_line "$CORE_LOG" core)" "$(calib_line "$READER_LOG" reader)" || FAILED=1

# ── 4. the after manifest, and the no-write assertion ─────────────────────────────────────────────
step "fingerprinting the tree AFTER, and diffing"
"$BIN" manifest --root "$ROOT" --out "$AFTER" || exit 1
if "$BIN" compare --before "$BEFORE" --after "$AFTER"; then
  ok "no-write assertion holds across the whole tree"
else
  fail "the discovery lane MUTATED the tree — see the diff above"
fi
"$BIN" manifest --root "$HOSTILE" --out "$AFTER.hostile" || exit 1
if "$BIN" compare --before "$BEFORE.hostile" --after "$AFTER.hostile"; then
  ok "no-write assertion holds across the hostile sibling too"
else
  fail "the discovery lane MUTATED the hostile tree — see the diff above"
fi

# ── 5. self-test: the no-write guard must be able to fail ─────────────────────────────────────────
# A guard nobody has watched fail is not a guard. This mutates one file's tags the way a real write
# would and requires `compare` to catch it; then it restores the tree and requires green again.
if [ "$SELF_TEST" = 1 ]; then
  step "self-test — proving the no-write guard has teeth"
  VICTIM="$(find "$ROOT" -name '*.pdf' | head -1)"
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
