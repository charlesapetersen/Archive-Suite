#!/usr/bin/env bash
# health-gate.sh (WS7) — periodic FULL regression gate for a long unattended run. The daemon runs it every
# AUTONOMOUS_GATE_EVERY commits (see the daemon's health_gate()) and PARKS + alerts on a nonzero exit, so a
# compounding regression can't hide across dozens of unreviewed commits. Deterministic (build/test/grep, no
# LLM) — that's why the daemon runs it directly rather than spending a session on it.
#
# FREE by default: Reader + Notes smoke (build + unit suites, via the existing ./test-smoke.sh) + a Processor
# BUILD (compile-break check — NOT the paid OCR smoke) + a light coherence check. Set AUTONOMOUS_GATE_OCR=1
# to also run the paid Processor OCR smoke (a few cents). Exit 0 = GREEN, nonzero = RED.
#
# Run from anywhere (cd's to the repo root). Builds into gitignored build dirs; makes NO commits, no edits.
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT" || { echo "cannot cd to repo root $ROOT"; exit 2; }
# The gate runs in the DAEMON LOOP, not in a `claude` session — so the PreToolUse hook does not apply to it
# and the session's ARCHIVE_UNATTENDED is not in scope. Nothing was protecting it. But the gate is
# unattended BY DEFINITION, so declare it: this activates every script-level self-guard it invokes (both
# test-smoke.sh scripts, and the Processor's host launch step), and the PATH shims below catch the rest.
# Concretely, without this `AUTONOMOUS_GATE_OCR=1` would open the Processor on the owner's screen.
export ARCHIVE_UNATTENDED=1
export PATH="$ROOT/ops/autonomous/bin:$PATH"
LOG="$(mktemp)"; fails=""
trap 'rm -f "$LOG"' EXIT

# Run a named check; capture its output to $LOG; record a failure without aborting (no set -e).
step() { local name="$1"; shift; printf '── %s ──\n' "$name"; if "$@" >>"$LOG" 2>&1; then echo "  ✓ $name"; else echo "  ✗ $name (rc=$?)"; fails="$fails $name"; fi; }

# Like step(), but for a check that can legitimately be INCONCLUSIVE (exit 3 = skipped). A skip is not
# a pass: it prints ⊘ with the reason and is named in the final summary line.
#
# WHY (2026-07-29, root-caused 2026-07-30): the GUI-VM lane failed to reach the VM's guest agent, ran
# ZERO tests, fail-opened with exit 0 — and plain step() printed "✓ gui-vm". The gate reported GREEN
# including a GUI lane that had never executed, and the reason was buried in $LOG, which is only shown
# on RED. A gate that says ✓ for work it did not do is worse than no gate. Never collapse this back
# into step().
skips=""; warns=""
step_skippable() {
  local name="$1"; shift
  printf '── %s ──\n' "$name"
  # Capture THIS step's output separately. Reading the shared $LOG would report the first 'SKIPPED:'
  # anywhere in the file — including one left by an earlier step — as this step's reason.
  local out; out="$(mktemp)"
  "$@" >"$out" 2>&1; local rc=$?
  cat "$out" >>"$LOG"
  case "$rc" in
    0) echo "  ✓ $name" ;;
    3) local why; why="$(grep 'SKIPPED:' "$out" | tail -1)"
       echo "  ⊘ $name SKIPPED — ${why:-no reason reported}"; skips="$skips $name" ;;
    # 4 = ran, reproducibly FAILED, but the failures are known/tracked so they must not park the run.
    # The detail is echoed HERE, to the gate's own stdout, which is what lands in last-gate.log — not
    # buried in $LOG, which is only shown on RED and deleted on exit. The first cut of the warn tier got
    # this wrong and printed a bare "✓", which is the silent-green bug wearing a different hat.
    4) echo "  ⚠ $name — KNOWN FAILURES (ran, did not pass; not parking):"
       grep -E 'GUI-VM gate: (WARN|passed)|Test Case .*failed|error:' "$out" | sed 's/^/      /' | head -20
       warns="$warns $name" ;;
    *) echo "  ✗ $name (rc=$rc)"; fails="$fails $name" ;;
  esac
  rm -f "$out"
}

# UNIT tests only — `-only-testing:<UnitBundle>`, NOT the whole scheme. This is load-bearing for an UNATTENDED
# gate: the schemes also contain UITest bundles (ArchiveReaderUITests / ArchiveNotesUITests), and running a
# UITest pops the macOS "Enable UI Automation" / taskport prompt — which would HANG this gate (and, since the
# daemon runs the gate synchronously, the whole daemon) and wake the owner. `./test-smoke.sh reader|notes`
# runs the FULL scheme, so the gate does NOT use it; it invokes the unit bundle directly. (build is implied.)
# NOTE — `-only-testing:<UnitBundle>` does NOT mean "no GUI". Both unit bundles are APP-HOSTED
# (TEST_HOST = the .app), so this LAUNCHES the real app. Until 2026-07-30 that put a window on the owner's
# screen for the whole run (Reader 2m52s, Notes 49s) on every gate — the daemon's single biggest screen
# intrusion. Fixed at the source, not here: ArchiveCore `ArchiveTestHost` makes each app draw nothing when
# it is only a unit-test host, pinned by TestHostWindowSuppressionTests in both suites. Side effect worth
# knowing: with no UI to build, the Reader suite went 172s → ~2s. Don't "simplify" that away.
# -skip-testing the ONE known-environmental failure: DeepLinkTests.testRevealAndSelectNoRoot fails whenever
# this machine's shared com.archivereader.app defaults hold a persisted archiveRootBookmark (NavigationModel
# resolves a root, so the "No archive folder" assertion fails) — it's env, not a regression, and without the
# skip the gate would RED (false-park) on every run. Documented in KNOWN_ISSUES; fix it and drop the skip.
# Pixel-truth runs here too: DocumentRenderGuardTests (RenderProbe) lives INSIDE ArchiveReaderTests and renders a
# PDF page / SwiftUI view to a bitmap headlessly (no "Enable UI Automation"/TCC prompt) — so "did it actually
# draw" (blank PDF pane, blank thumbnail) is caught in this gate without the UITest hang. See ops/gui/README.md.
step reader bash -c 'cd ArchiveReader/macOS && xcodegen generate >/dev/null 2>&1 && xcodebuild test -scheme ArchiveReader -destination "platform=macOS" -only-testing:ArchiveReaderTests -skip-testing:ArchiveReaderTests/DeepLinkTests/testRevealAndSelectNoRoot -derivedDataPath ./build/gate-DD'
step notes  bash -c 'cd ArchiveNotes/macOS  && xcodegen generate >/dev/null 2>&1 && xcodebuild test -scheme ArchiveNotes  -destination "platform=macOS" -only-testing:ArchiveNotesTests  -derivedDataPath ./build/gate-DD'
# Processor: BUILD only (free) — catches compile breaks without the paid OCR round-trip. xcodebuild exits
# nonzero on a build error, which is the pass/fail signal (own DD so it can't clobber a live build/DD).
step processor-build bash -c 'cd ArchiveProcessor/macOS && xcodegen generate >/dev/null 2>&1 && xcodebuild -scheme ArchiveProcessor -configuration Debug -derivedDataPath ./build/gate-DD build'
# Opt-in paid OCR smoke. PREREQ before enabling this in an unattended run: the Gemini key must be readable
# WITHOUT a prompt — test-smoke.sh reads it via `security find-generic-password`, so run the WS12 keychain
# fix (ops/autonomous/fix-keychain-access.sh) first, else this either prompts (→ the daemon's GATE_MAXRUN
# kills it) or fails to read the key (→ RED, but the daemon retries once before parking). It's also a paid
# network round-trip, so leave it OFF unless you specifically want OCR-pipeline coverage in the gate.
[ "${AUTONOMOUS_GATE_OCR:-0}" = 1 ] && step processor-ocr bash ./test-smoke.sh processor   # paid, opt-in (OCR only; no UITest)
# Coherence: WARN-ONLY (never REDs the gate). A dirty TRACKED tree hints at a half-committed/aborted state,
# but it's fragile as a park trigger — the gate must not false-park a healthy run over it (and a build can
# leave transient tracked churn on some setups). The builds + unit suites above are the real RED signal.
if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  echo "  ⚠ coherence: working tree has uncommitted TRACKED changes (warning only — not failing the gate):"
  git status --porcelain --untracked-files=no 2>/dev/null | head -10 | sed 's/^/      /'
else
  echo "  ✓ coherence (clean tree)"
fi

# Tracker sync: the plan's WORK QUEUE and SUITE_TODO must agree about what is already done. WARN-ONLY, for
# the same reason as coherence above — a doc mismatch must not park a run whose builds and suites are green.
# It is here rather than nowhere because the failure it catches is silent and expensive: on 2026-08-01 the
# plan still listed W21.vmgui-path as open after it shipped, so the resolver was offering finished work.
bash "$ROOT/ops/autonomous/check-tracker-sync.sh" || true

# Run EVERY app's UITests in a headless Tart VM — off the owner's screen, and without the "Enable UI
# Automation" prompt that makes the steps above avoid UITests on the host. ON by default (2026-07-28;
# set AUTONOMOUS_GUI_VM=0 to disable). Fail-open: a missing VM / boot failure / guest-agent timeout SKIPs
# (so it's inert where no VM is built); only a reproducible UITest failure REDs (park). Runs via
# step_skippable, NOT step — a lane that ran zero tests must never print ✓ (see its comment).
# The VM step adds ~15-20 min, which is why the daemon's GATE_MAXRUN is 50 min.
# See ops/autonomous/gui-vm-gate.sh + ops/gui/README.md §3.
[ "${AUTONOMOUS_GUI_VM:-1}" = 1 ] && step_skippable gui-vm bash "$ROOT/ops/autonomous/gui-vm-gate.sh"

# Context budget (2026-08-04) — the ONE thing nothing was watching. Owner: "token use is the real
# bottleneck for development, not build speed." A fresh session's dominant fixed cost is the orientation
# read (plan + tracker + app guide + resume prompt), and on 2026-08-04 AUTONOMOUS_PLAN.md had reached
# 462 KB / ~117k tokens while its own compactor reported "no-op" every cycle for weeks. Nothing failed,
# nothing warned — the docs just got bigger and every session silently paid. This step is free (pure
# shell, zero tokens), which is the point: context is the expensive thing to spend and the cheap thing to
# measure. It is a REAL step (not step_skippable): being over budget is a fact, never inconclusive.
# When it REDs, fix the DOCUMENT, not the budget — per-file remedies are in context-budget.sh's header.
step context-budget bash "$ROOT/ops/autonomous/context-budget.sh" "$ROOT"

echo
if [ -n "$fails" ]; then
  echo "HEALTH GATE: RED —$fails"
  echo "--- failing output (tail) ---"; tail -40 "$LOG"
  exit 1
fi
# A skip never REDs the gate (infra must not park a healthy run) but it MUST be visible here — this
# line is what lands in last-gate.log and what the owner reads. "GREEN" alone would claim coverage the
# run does not have.
if [ -n "$skips" ] || [ -n "$warns" ]; then
  echo "HEALTH GATE: GREEN (builds + Reader/Notes unit suites + coherence)${skips:+ — NOT VERIFIED:$skips}${warns:+ — KNOWN FAILURES:$warns}"
  [ -n "$skips" ] && echo "  ↳ the skipped lane(s) ran ZERO tests. Reason above; artifacts in ~/.tart-mirror/vm-artifacts/."
  [ -n "$warns" ] && echo "  ↳ the warned lane(s) RAN and FAILED; they are tracked, so they don't park the run. Detail above + ~/.tart-mirror/vm-artifacts/gui-vm-<app>-LAST-FAILURE.log."
  exit 0
fi
echo "HEALTH GATE: GREEN (all builds + Reader/Notes suites + coherence + GUI-VM UITests)"
exit 0
