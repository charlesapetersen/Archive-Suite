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
LOG="$(mktemp)"; fails=""
trap 'rm -f "$LOG"' EXIT

# Run a named check; capture its output to $LOG; record a failure without aborting (no set -e).
step() { local name="$1"; shift; printf '── %s ──\n' "$name"; if "$@" >>"$LOG" 2>&1; then echo "  ✓ $name"; else echo "  ✗ $name (rc=$?)"; fails="$fails $name"; fi; }

# UNIT tests only — `-only-testing:<UnitBundle>`, NOT the whole scheme. This is load-bearing for an UNATTENDED
# gate: the schemes also contain UITest bundles (ArchiveReaderUITests / ArchiveNotesUITests), and running a
# UITest pops the macOS "Enable UI Automation" / taskport prompt — which would HANG this gate (and, since the
# daemon runs the gate synchronously, the whole daemon) and wake the owner. `./test-smoke.sh reader|notes`
# runs the FULL scheme, so the gate does NOT use it; it invokes the unit bundle directly. (build is implied.)
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

echo
if [ -n "$fails" ]; then
  echo "HEALTH GATE: RED —$fails"
  echo "--- failing output (tail) ---"; tail -40 "$LOG"
  exit 1
fi
echo "HEALTH GATE: GREEN (all builds + Reader/Notes suites + coherence)"
exit 0
