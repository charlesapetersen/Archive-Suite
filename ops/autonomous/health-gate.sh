#!/usr/bin/env bash
# health-gate.sh (WS7) — periodic FULL regression gate for a long unattended run. The daemon runs it every
# AUTONOMOUS_GATE_EVERY commits (see the daemon's health_gate()) and PARKS + alerts on a nonzero exit, so a
# compounding regression can't hide across dozens of unreviewed commits. Deterministic (build/test/grep, no
# LLM) — that's why the daemon runs it directly rather than spending a session on it.
#
# FREE by default: Reader + Notes smoke (build + unit suites, via the existing ./test-smoke.sh) + a Processor
# BUILD AND HEADLESS LAUNCH (compile/startup check — NOT the paid OCR smoke) + the write-surface lint and the
# hermetic script gates (W26.lint-fu) + a light coherence check. Set AUTONOMOUS_GATE_OCR=1 to also
# run the paid Processor OCR smoke (a few cents). Exit 0 = GREEN, nonzero = RED.
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

# Run a named check; record a failure without aborting (no set -e); on failure, append THAT STEP'S OWN tail
# to $LOG.
#
# WHY per-step and not one shared transcript (2026-08-08): $LOG used to accumulate every step's output and
# the RED branch printed `tail -40 "$LOG"` — i.e. the tail of whichever step ran LAST, which on a green-tailed
# run is a passing one. The 2026-08-08 park on `tag-vocabulary` reported "36 passed, 0 failed" under the
# heading "failing output", because `status-proof` and `dispatch-proof` run after it and overwrote the tail.
# The owner-facing park note and ARCHIVE-SUITE-RUN-PARKED.txt are built from this text, so the one artifact
# naming the failure showed a step that had passed. Same family as the `step_skippable` bug below: a gate
# that misreports what it did is worse than a gate that says less.
step() {
  local name="$1"; shift
  printf '── %s ──\n' "$name"
  local out; out="$(mktemp)"
  if "$@" >"$out" 2>&1; then
    echo "  ✓ $name"
  else
    local rc=$?
    echo "  ✗ $name (rc=$rc)"; fails="$fails $name"
    { printf '\n===== %s (rc=%s) =====\n' "$name" "$rc"; tail -40 "$out"; } >>"$LOG"
  fi
  rm -f "$out"
}

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
  # Capture THIS step's output separately. Reading a shared transcript would report the first 'SKIPPED:'
  # anywhere in the file — including one left by an earlier step — as this step's reason. ($LOG is now
  # failures-only for the same class of reason; see step() above. Only the `*)` arm contributes to it —
  # a skip and a known-failure are both reported inline, and neither is what RED is asking about.)
  local out; out="$(mktemp)"
  "$@" >"$out" 2>&1; local rc=$?
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
    *) echo "  ✗ $name (rc=$rc)"; fails="$fails $name"
       { printf '\n===== %s (rc=%s) =====\n' "$name" "$rc"; tail -40 "$out"; } >>"$LOG" ;;
  esac
  rm -f "$out"
}

# UNIT tests only — `-only-testing:<UnitBundle>`, NOT the whole scheme. This is load-bearing for an UNATTENDED
# gate: the schemes also contain UITest bundles (ArchiveReaderUITests / ArchiveNotesUITests), and running a
# UITest pops the macOS "Enable UI Automation" / taskport prompt — which would HANG this gate (and, since the
# daemon runs the gate synchronously, the whole daemon) and wake the owner. Reader's smoke wrapper selects
# the unit bundle when this gate sets ARCHIVE_UNATTENDED; Notes' wrapper now does so on every run (W9.c4).
# The gate still invokes the unit bundles directly, with build implied.
# NOTE — `-only-testing:<UnitBundle>` does NOT mean "no GUI". Both unit bundles are APP-HOSTED
# (TEST_HOST = the .app), so this LAUNCHES the real app. Until 2026-07-30 that put a window on the owner's
# screen for the whole run (Reader 2m52s, Notes 49s) on every gate — the daemon's single biggest screen
# intrusion. Fixed at the source, not here: each app's local `ArchiveTestHost` makes it draw nothing when
# it is only a unit-test host, pinned by TestHostWindowSuppressionTests in both suites. Side effect worth
# knowing: with no UI to build, the Reader suite went 172s → ~2s. Don't "simplify" that away.
# DeepLinkTests.testRevealAndSelectNoRoot is deliberately INCLUDED: W26.fixturehang made the defaults
# injectable and the test now passes an unpinned `fixtureDefaults()` suite to NavigationModel. It cannot
# resolve the owner's `archiveRootBookmark`, so a regression in the no-root path must RED rather than hide
# behind an environmental skip. See ArchiveReader/KNOWN_ISSUES.md (W20.deeplink-isolation).
# Pixel-truth runs here too: DocumentRenderGuardTests (RenderProbe) lives INSIDE ArchiveReaderTests and renders a
# PDF page / SwiftUI view to a bitmap headlessly (no "Enable UI Automation"/TCC prompt) — so "did it actually
# draw" (blank PDF pane, blank thumbnail) is caught in this gate without the UITest hang. See ops/gui/README.md.
step reader bash -c 'cd ArchiveReader/macOS && xcodegen generate >/dev/null 2>&1 && xcodebuild test -scheme ArchiveReader -destination "platform=macOS" -only-testing:ArchiveReaderTests -derivedDataPath ./build/gate-DD'
step notes  bash -c 'cd ArchiveNotes/macOS  && xcodegen generate >/dev/null 2>&1 && xcodebuild test -scheme ArchiveNotesUnit -destination "platform=macOS" -only-testing:ArchiveNotesTests -derivedDataPath ./build/gate-DD'
# Processor: build then launch the SAME gate artifact, free. The recovery driver is synthetic/headless
# ($0, no network, no OCR, no GUI) and confirms the app reached main; a build alone cannot catch a pre-main
# abort. `ARCHIVEPROC_TEST_BINARY` is explicit so this cannot accidentally pass against stale build/DD.
step processor-build bash -c 'cd ArchiveProcessor/macOS && xcodegen generate >/dev/null 2>&1 && xcodebuild -scheme ArchiveProcessor -configuration Debug -derivedDataPath ./build/gate-DD build'
step processor-launch bash -c 'cd ArchiveProcessor && ARCHIVEPROC_TEST_BINARY="$PWD/macOS/build/gate-DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor" bash scripts/test-recovery.sh'
# Opt-in paid OCR smoke. PREREQ before enabling this in an unattended run: the Gemini key must be readable
# WITHOUT a prompt — test-smoke.sh reads it via `security find-generic-password`, so run the WS12 keychain
# fix (ops/autonomous/fix-keychain-access.sh) first, else this either prompts (→ the daemon's GATE_MAXRUN
# kills it) or fails to read the key (→ RED, but the daemon retries once before parking). It's also a paid
# network round-trip, so leave it OFF unless you specifically want OCR-pipeline coverage in the gate.
[ "${AUTONOMOUS_GATE_OCR:-0}" = 1 ] && step processor-ocr bash ./test-smoke.sh processor   # paid, opt-in (OCR only; no UITest)

# ── Tier-2 script gates that nothing was running (W26.lint-fu, 2026-08-07) ────────────────────────
# Five harnesses shipped across Wave 26, each the mechanism proof for a Core-Directive or
# de-Spotlight guarantee — and every one of them had NO CALLER anywhere in the repo. The
# write-surface lint's own header claimed it was "also invoked by the autonomous build"; measured
# false on 2026-08-05. So the automated half of the Core Directive ran only when a human remembered
# it, which is the same failure as a lint that passes vacuously, moved up one level: the guarantee
# reads as enforced and is not.
#
# All seven are free and hermetic — no key, no network, no GUI, no app build, mktemp scratch only,
# and no real-corpus path anywhere. The original five measured ≈105 s on 2026-08-07; W9.c2 adds
# two fast source-only checks. They sit ahead of the ~15-20 min VM lane deliberately, so a RED lands
# in the gate's first few minutes.
#
# These seven named gate checks below are REAL steps: each was run green on a clean tree before being
# wired (the item's "the gate must not start RED"), and each failure mode is a fact about the source,
# never inconclusive.
step write-surface-lint       bash "$ROOT/ArchiveReader/scripts/lint-write-surface.sh"
step write-surface-lint-proof bash "$ROOT/ArchiveReader/scripts/test-lint-write-surface.sh"
step processor-write-surface-lint       bash "$ROOT/ArchiveProcessor/scripts/lint-write-surface.sh"
step processor-write-surface-lint-proof bash "$ROOT/ArchiveProcessor/scripts/test-lint-write-surface.sh"
step tag-vocabulary           bash "$ROOT/ArchiveProcessor/scripts/test-tag-vocabulary.sh"
# PYTHONDONTWRITEBYTECODE: this one imports `finder_tags.py` from the source tree, so CPython would
# leave a `__pycache__` dir in ArchiveProcessor/scripts on every gate run. The repo ignores that path
# now as well, but the gate should not be dirtying the checkout it is judging in the first place.
step finder-tags              env PYTHONDONTWRITEBYTECODE=1 bash "$ROOT/ArchiveProcessor/scripts/test-finder-tags.sh"
# The odd one out: it needs `/opt/homebrew/bin/tag` and PREFLIGHTS it. W26.lint-fu asked which way a
# missing prerequisite should go here — RED, or a WARN-skip like the VM lane — and the answer is a skip,
# for the VM lane's reason: an absent prerequisite is not a regression, and a gate that parks the run
# over one teaches its reader to ignore parks. The script exits 3 with a `SKIPPED:` line for exactly
# that missing CLI, so the lane is named in the "NOT VERIFIED:" tail of the summary instead of passing
# silently. Its Reader and Notes GUI builders generate their PDFs by default, so a gitignored corpus is
# no longer a gate prerequisite; the old corpus-backed smoke-fixture portion reports itself separately.
step_skippable fixture-scripts bash "$ROOT/ArchiveReader/scripts/test-fixture-scripts.sh"

# W28.cert-fu3: prove the launch gate itself runs a binary that aborts before main and reports a failing
# launch, rather than merely checking that the command text still mentions `test-recovery.sh`.
step processor-launch-proof bash "$ROOT/ops/autonomous/tests/prove-processor-launch-gate.sh"

# W31.handoff-gate: an open tracker item must be mirrored into the primary plan or `next-queue-item.sh` cannot
# offer it. Use only check-handoff's visibility mode here: full handoff rightly rejects an active worktree and
# fetches origin, neither of which is a deterministic mid-session gate condition.
step handoff env HANDOFF_MODE=visibility bash "$ROOT/ops/autonomous/check-handoff.sh"

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

# Ticked stubs in SUITE_TODO: it holds OPEN items only, so a `[x]` left there is counted TWICE in the
# owner-facing "N finished" (status-digest.sh sums both trackers with no dedup). WARN-ONLY for the same reason
# as the two above — a docs-hygiene nit must never park a run whose builds and suites are green. Deliberately a
# SEPARATE script from tracker-sync: that one's job is comparing `[x]` state between the plan and SUITE_TODO, so
# it must treat a `[x]` there as valid input; asserting the opposite in the same file contradicted it and broke
# 5 of its fixtures (W26.donecount).
bash "$ROOT/ops/autonomous/check-todo-stubs.sh" || true

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
# It now REDs ONLY on the per-session ORIENTATION TOTAL (owner, 2026-08-13 — per-file caps are advisory, so a
# single long document cannot stop engineering work). When it REDs, shrink a TRACKER; do not raise the budget.
step context-budget bash "$ROOT/ops/autonomous/context-budget.sh" "$ROOT"

# …and prove the guard still speaks the language the daemon parses. Since 2026-08-12 the doc pre-gate
# (doc_pregate() in archive-suite-autonomous.sh) reads context-budget.sh's `context-budget: OVER|NEAR|TOTAL …`
# lines to decide WHICH remedy to run — so a renamed field no longer just looks different to a human, it means
# the pre-gate finds no over-budget file, queues no trim, and the run parks for the exact problem the pre-gate
# exists to absorb. This also statically asserts rule 1 (ORIENT_TOTAL stays tighter than the sum of the
# per-file budgets); raise a budget without re-checking that and aggregate creep silently stops being guarded.
step budget-contract bash "$ROOT/ops/autonomous/tests/prove-context-budget.sh"

# compact-plan.sh is the ONLY thing keeping the plan's orientation cost bounded, so its correctness is a gate
# concern, not a nicety. On 2026-08-06 it was found to have been ABORTING Pass 1 on EVERY cycle for weeks: the
# live plan's '## Daemon Report' header had no blank line before it, so the Session Log region ran to EOF and
# swept that section into the drop set; the anchor guard caught it, so the plan was never corrupted — and never
# compacted either, drifting to 96% of its budget while ~11 KB/cycle went unreclaimed. Three things had to be
# true for that to survive: the abort was swallowed by the daemon's `|| true`; nothing measured the REGION
# sizes; and this harness — the mechanism proof for exactly that code — was itself RED on main and wired into
# NOTHING (its only mention in the repo was one sentence in ops/autonomous/README.md). Three Case A ordering
# assertions had been failing since ce49ead made Pass 1 newest-first without updating the fixture.
# REAL step: sandbox fixtures via mktemp (never the live plan), no network, no GUI, ~2 s. If it REDs the
# compactor is broken and the plan WILL drift back over budget — fix the compactor, don't skip this.
step compact-proof bash "$ROOT/ops/autonomous/tests/prove-compact.sh"

# Same argument, for the remaining hermetic ops harnesses. All are seconds long, sandbox-only (mktemp
# fixtures + an isolated $HOME) and deterministic, so there is no reason to leave them unwatched:
#   * prove-status.sh — the ONE status renderer the owner reads. It sat silently at 34/2 until 2026-08-06, and
#     the cause was the harness itself reading the owner's REAL ~/Desktop park note: 34/2 with that file
#     present, 36/0 without. Its verdict depended on state outside its own sandbox. Now isolated.
#   * prove-daemon-dispatch.sh — daemon.sh's command dispatch, driven through `--dry-run` so it never installs
#     or launches anything. Guards the 2026-08-06 rename (arm.sh -> daemon.sh, verb `arm` -> `start`),
#     including that the retired `arm` verb is REJECTED rather than quietly still working as an alias.
#   * prove-gate-report.sh — THIS script's own RED report (W27.gatetail, owner-approved 2026-08-08). It
#     extracts the real step()/step_skippable()/verdict text from this file and drives it against synthetic
#     steps, so the block the daemon quotes into the park note cannot silently go back to reporting the LAST
#     step instead of the FAILING one — a regression that is only ever observed during an incident, and that
#     misreported three of the owner's parks before it was fixed. Self-referential on purpose: nothing else
#     watches the gate's own honesty.
#   * prove-keychain-partition.sh — the one-time provider-key repair and the daemon's stale-marker warning.
#     SKIPPABLE (the third, after fixture-scripts and gui-vm): it greps with `rg`, so it needs ripgrep.
#     It replaces `security` with a fixture stub, so it proves the complete shared account list, no secret
#     read/write, no false-covered marker after a partial repair, and the later-added-provider warning without
#     touching the login Keychain.
#   * prove-docsync-packages.sh — the Stop hook's package boundary. It creates a private Git history with an
#     ArchiveCore Swift-only commit, proves the real hook blocks that range, then adds `SUITE_TODO.md` and
#     proves the same range passes. A root-only fixture would not establish that `packages/` is covered.
#   * prove-vm-lane.sh — the GUI lane's exit-code -> owner-visible-text mapping, the per-app table, the VM
#     lock, and (W26.fixwarn) that a `tart exec` transport error is never mistaken for a failed fixture
#     build. Missed by the 2026-08-08 sweep above, so it was the fifth harness in the same position: ~4 s,
#     fully stubbed — no VM, no network, no Xcode — and watching the one lane whose whole documented history
#     is "reported green while running zero tests." Added 2026-08-10 with W26.fixwarn's own assertions.
#     It needs nothing from the PATH line at the top of this file: measured 60/0 both with the shim dir
#     first AND under a bare /usr/bin:/bin, because tart-lib.sh resolves Homebrew itself. It also cannot
#     collide with the gui-vm step that drives the REAL lane — it stubs `tart` and points TART_LOCK_DIR at
#     its own mktemp, so it never touches the shared VM or the shared lock.
#   * prove-gui-vm.sh — the real round-robin gate with fake Tart/XcodeGen. It verifies each app's turn,
#     retry and fail-open outcomes, and per-app artifact isolation without starting a VM, Xcode, or GUI.
step status-proof   bash "$ROOT/ops/autonomous/tests/prove-status.sh"
step dispatch-proof bash "$ROOT/ops/autonomous/tests/prove-daemon-dispatch.sh"
# step_skippable, not step: this harness greps with `rg`, which is a brew prereq rather than a repo file,
# so a machine without ripgrep must report ⊘ NOT VERIFIED — not park the run. See the harness header.
step_skippable keychain-partition-proof bash "$ROOT/ops/autonomous/tests/prove-keychain-partition.sh"
step docsync-packages-proof  bash "$ROOT/ops/autonomous/tests/prove-docsync-packages.sh"
step gate-report    bash "$ROOT/ops/autonomous/tests/prove-gate-report.sh"
step handoff-proof  bash "$ROOT/ops/autonomous/tests/prove-handoff.sh"
step vm-lane-proof  bash "$ROOT/ops/autonomous/tests/prove-vm-lane.sh"
step gui-vm-proof   bash "$ROOT/ops/autonomous/tests/prove-gui-vm.sh"

# W26.fixwarn-fu1 (2026-08-10) — the SIX remaining hermetic harnesses. Wiring them one at a time is how this
# list came to be wrong five times: `f64649b` swept four in, W26.fixwarn found a fifth, and counting them to
# justify the word "fifth" turned up SEVEN more that nothing ran. Each was baselined against pristine main
# first (memory `ops-harnesses-red-on-main`: inheriting someone else's RED would park the daemon on it) and
# then re-run in THIS gate's own env — shim dir first on PATH, ARCHIVE_UNATTENDED=1 — because that env is
# where a harness turns a green gate red. All six: green on main, seconds long, mktemp-sandboxed.
#   * prove-dep-gating.sh (5 s, 42/0) — next-queue-item.sh's `blocked-on` resolver, i.e. the code that
#     decides what the daemon works on next. A wrong verdict there ships work out of order — `W23.h5-fu`
#     carried its dependency in prose only and was offered as actionable, which is the near-miss this guards.
#   * prove-tracker-sync.sh (6 s, 25/0) — check-tracker-sync.sh, which the `tracker sync` line above already
#     runs warn-only. The guard was in the gate; the proof that the guard still fires was not.
#   * prove-housekeeping.sh (7 s) — the daemon's worktree/branch GC. This one deletes things: its whole
#     contract is which worktrees are reclaimed and which are KEPT, and a `W26.tagvocab-salvage` worktree is
#     being kept RIGHT NOW for a file that exists in no commit.
#   * prove-no-host-gui.sh (7 s, 28/0) — the host-GUI firewall hook. A pattern that silently stopped matching
#     would hand the owner's display back to the daemon with no symptom until they were interrupted. Note it
#     passes with ARCHIVE_UNATTENDED=1 already exported (it sets the axis per case), which is the gate's env.
#   * prove-exit-logging.sh (7 s, 12/0) — why the daemon exited. Flagged in the item as
#     "plausibly too invasive": it does run the REAL daemon and SIGTERM it, but measured, it is hermetic —
#     throwaway $HOME/$STATE/repo, a fake `claude`, and its own stub dir FIRST on PATH (so its launchctl and
#     osascript stubs win over this gate's shims). It never touches the real state dir or the real launchd job,
#     and its VERDICT depends on nothing outside its own mktemp. It is not leak-proof under SIGKILL — each
#     case kills its own daemon, so at most one orphaned sandbox loop survives a killed gate — but that
#     orphan is unsupervised, private to a temp dir, and stays dead once killed. Contrast prove-keepalive
#     below, where both halves of that sentence go the other way.
#   * prove-review-cadence.sh (43 s, 17/0) — the slowest of the six, and the only one worth a second thought
#     for runtime; 43 s against a ~22 min gate is not the exclusion prove-daemon.sh earns. It forces
#     AUTONOMOUS_REVIEW_ENABLED=1 on purpose: paced reviews are OFF by owner directive, and the picker
#     machinery must keep working while the deployment default is off, so this stays watched while it sleeps.
step dep-gating-proof     bash "$ROOT/ops/autonomous/tests/prove-dep-gating.sh"
step tracker-sync-proof   bash "$ROOT/ops/autonomous/tests/prove-tracker-sync.sh"
step todo-stubs-proof     bash "$ROOT/ops/autonomous/tests/prove-todo-stubs.sh"
step housekeeping-proof   bash "$ROOT/ops/autonomous/tests/prove-housekeeping.sh"
step host-gui-proof       bash "$ROOT/ops/autonomous/tests/prove-no-host-gui.sh"
step exit-log-proof       bash "$ROOT/ops/autonomous/tests/prove-exit-logging.sh"
step review-cadence-proof bash "$ROOT/ops/autonomous/tests/prove-review-cadence.sh"

# ── The two harnesses that are NOT gate steps, and why ────────────────────────────────────────────────────
# The line below is MACHINE-READ: `prove-gate-report.sh` asserts that every ops/autonomous/tests/prove-*.sh
# is either a `step` above or named here (W26.fixwarn-fu1 part 2), so harness #14 cannot land unwatched the
# way seven of them did. Adding a name here SILENCES that assertion for it — so a name belongs here only
# with its reason written out, and only because the harness genuinely does not belong in the gate. It is not
# a snooze button. (The assertion also fails if a name here is stale or is in fact wired, so the list cannot
# quietly rot into a blanket exemption.)
#
#   * prove-daemon.sh — RUNTIME. ~10 min of real daemon loops does not belong in a gate that already runs
#     ~22 min against GATE_MAXRUN=50 min. Run it by hand for daemon-behaviour changes. (Runtime, not
#     principle — which is why the sub-second prove-gate-report.sh above IS in.)
#   * prove-keepalive.sh — SIDE EFFECTS OUTSIDE ITS OWN SANDBOX. It is fast (7 s) and green on main, so
#     runtime is not the objection: it drives the owner's REAL launchd, bootstrapping a throwaway
#     `com.archivesuite.ws1probe.<pid>` job into gui/$UID, `kill -9`ing it and booting it out. Two problems
#     for a gate. (1) Its verdict depends on state outside its own sandbox — real launchd's behaviour — which
#     is exactly how prove-status.sh sat at 34/2 for weeks: it was reading the owner's real ~/Desktop park
#     note. A harness whose RED can be the environment's is how a real park becomes a false one, and the gate
#     is a park trigger. (2) Cleanup is `trap cleanup EXIT`, and the daemon's watchdog backstop is a detached
#     `kill -KILL` (archive-suite-autonomous.sh ~line 701) — SIGKILL runs no EXIT trap, so a gate killed
#     mid-step leaves a job LOADED in gui/$UID, and it is `KeepAlive=true`: it RELAUNCHES itself forever. The
#     label is `$$`-unique, so that accumulates one phantom supervised `com.archivesuite.ws1probe.*` per
#     killed gate, in the same domain and under the same prefix the owner reads while diagnosing the daemon.
# GATE-UNWATCHED-BY-DESIGN: prove-daemon.sh prove-keepalive.sh

echo
if [ -n "$fails" ]; then
  echo "HEALTH GATE: RED —$fails"
  # Every FAILING step's own tail, each under its own banner — not the tail of a shared transcript, which
  # is the tail of whatever ran last. This text is what the daemon quotes into the park note.
  echo "--- failing output (tail, per failing step) ---"; cat "$LOG"
  exit 1
fi
# A skip never REDs the gate (infra must not park a healthy run) but it MUST be visible here — this
# line is what lands in last-gate.log and what the owner reads. "GREEN" alone would claim coverage the
# run does not have.
if [ -n "$skips" ] || [ -n "$warns" ]; then
  echo "HEALTH GATE: GREEN (builds + Reader/Notes unit suites + write-surface lint + script gates + coherence)${skips:+ — NOT VERIFIED:$skips}${warns:+ — KNOWN FAILURES:$warns}"
  # The artifact directory belongs to gui-vm alone. Since W26.lint-fu, `fixture-scripts` can skip too and
  # leaves nothing there, so the pointer is attributed rather than stated as if it covered every skip —
  # sending the reader to an empty directory is how a summary line starts lying about what it knows.
  [ -n "$skips" ] && echo "  ↳ the skipped lane(s) ran ZERO tests — the reason is printed above (gui-vm additionally leaves artifacts in ~/.tart-mirror/vm-artifacts/)."
  [ -n "$warns" ] && echo "  ↳ the warned lane(s) RAN and FAILED; they are tracked, so they don't park the run. Detail above + ~/.tart-mirror/vm-artifacts/gui-vm-<app>-LAST-FAILURE.log."
  exit 0
fi
echo "HEALTH GATE: GREEN (all builds + Reader/Notes suites + write-surface lint + script gates + coherence + GUI-VM UITests)"
exit 0
