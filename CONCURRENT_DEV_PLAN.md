# Concurrent / Multi-Agent Development — Implementation Plan

**STATUS:** NOT STARTED · **NEXT ACTION:** Phase 0 pre-flight (verify `.pbxproj` regenerates faithfully + scheme survives) on a branch off `main`.

> This is the durable, executable plan. It supersedes the scratch copy under `~/.claude/plans/`.
> Every step below carries its **own verification** — you check that each step worked *before* moving to the next, rather than doing one big verification at the end. Checks are tagged **[free]** (no API spend — builds are compile-only), **[manual]** (human observation), or **[paid]** (costs API money — exactly one, last).

---

## Context

The repo is **not safe for two instances editing the same working directory at once** (they clobber uncommitted edits and race on the build cache). It *is* well-suited to safe **parallel** work (isolated git worktrees → merge) once three things are fixed:

1. **Generated `.pbxproj` is committed** → the #1 Xcode merge-conflict source. (Verified tracked: both `project.pbxproj` **and** both `project.xcworkspace/contents.xcworkspacedata`.)
2. **Two god files** concentrate most features: `OCRProcessor.swift` (~3,860 lines) and `OCRView.swift` (~2,657 lines).
3. **No documented isolated-parallel workflow.**

**Scope:** these 3 tasks only. Open-source enablement (LICENSE, CI, CONTRIBUTING, fixtures) is **deferred** — see the end.

**Verified build facts:** both `project.yml` use a **directory glob** (`sources: - Sources/<App>`) so `xcodegen generate` auto-includes new `.swift` files. Schemes: `ArchiveProcessor` (macOS, Swift 6 strict concurrency) and `ArchiveCaptureiOS` (iOS, Swift 5). Canonical build: `cd ArchiveProcessor && xcodegen generate && xcodebuild -scheme ArchiveProcessor -configuration Debug build`. `build/` and `DerivedData/` are gitignored; **`.pbxproj` is not** (yet). No CI; sparse tests. Baseline build is green.

**Order & why:** Phase 0 → **Task A** (untrack `.pbxproj` first, so Task C's ~23 new files cause zero project-file churn) → **Task B** (documents the new post-clone `xcodegen generate` requirement) → **Task C** (the big refactor, last, under the new hygiene). Do everything on a branch; keep `main` green.

---

## How to use this doc

- Tick each `[ ]` only after **all** of its checks pass. If a check fails, apply the step's **Rollback** and fix before continuing.
- Work on a branch: `git switch -c refactor/concurrent-dev` (Task C uses its own branch — see C-S0).
- All paths contain a space → **always double-quote** paths.

---

## Global verify recipes (defined once; corrected for real behavior)

These are reused across Task C's per-commit moves. **The commands below are the fixed versions** — naive variants silently pass/fail (see "Why" notes).

- **BUILD [free]** — the workhorse; catches file-scoped-`private` breaks, missing imports, dup/lost symbols:
  `cd ArchiveProcessor && xcodegen generate >/dev/null 2>&1 && xcodebuild -scheme ArchiveProcessor -configuration Debug build 2>&1 | tail -1` → `** BUILD SUCCEEDED **`.
- **WARNINGS [free]** — Swift-6 isolation drift hides in warnings, not errors. Capture a baseline at C-S0 and diff per commit:
  `xcodebuild -scheme ArchiveProcessor -configuration Debug build 2>&1 | grep -cE ': warning:'` → must not exceed baseline; investigate any new `sending`/`actor-isolated`/`Sendable` warning. *(Why: piping to `tail -1` throws warnings away.)*
- **MOVE-PROOF [free]** — proves a commit relocated bytes verbatim, not rewrote them. Content-diff (tty-independent):
  ```
  SRC=<source>; NEW=<newfile>
  git show HEAD -- "$SRC" | grep '^-' | grep -v '^---' | sed 's/^-//' | sort > /tmp/removed.txt
  git show HEAD -- "$NEW" | grep '^+' | grep -v '^+++' | sed 's/^+//' | grep -vE '^import ' | sort > /tmp/added.txt
  diff /tmp/removed.txt /tmp/added.txt
  ```
  Expect the **only** differences to be (a) the new file's `import` header and (b) any `private ` keywords intentionally dropped. *(Why: `git show --color-moved | grep <ANSI>` returns 0 when piped — git disables color for non-tty — so it "passes" for any commit, even a full rewrite. Verified 0 in this repo.)*
- **ACCESS-AUDIT [free]** — finds members actually relaxed `private→internal`, then proves each has a real cross-file caller (no over-relaxation). Census diff, not keyword grep:
  ```
  privlist() { grep -oE 'private (static )?(nonisolated )?(func|var|let) [A-Za-z0-9_]+' "$@" | sed -E 's/.* ([A-Za-z0-9_]+)$/\1/' | sort -u; }
  git show main:ArchiveProcessor/Sources/ArchiveProcessor/OCR/OCRProcessor.swift | privlist /dev/stdin > /tmp/priv-main.txt
  cat ArchiveProcessor/Sources/ArchiveProcessor/OCR/OCRProcessor*.swift | privlist /dev/stdin > /tmp/priv-head.txt
  comm -23 /tmp/priv-main.txt /tmp/priv-head.txt   # = members that lost `private`
  ```
  For each name printed, `grep -rn` it across `Sources/ArchiveProcessor` and confirm a caller in a **different file**; if none, revert it to `private` in a fixup commit. *(Why: grepping added lines for the `internal` keyword never matches — Swift `internal` is implicit/keyword-less; grepping deleted `private` lines flags every verbatim-moved private member as a false positive.)*
- **DOWNSTREAM-CONSUMER [free]** — the four external call sites must keep resolving:
  `grep -nE 'OCRProcessor\.(performOCRCall|rotationModeForRun|loadStandardImageMB|performResolutionTestCall)' ArchiveProcessor/Sources/ArchiveProcessor/Capture/LiveCaptureProcessor.swift ArchiveProcessor/Sources/ArchiveProcessor/Views/ToolsView.swift` → sites present; BUILD proves they compile. (These are already `nonisolated static`/`internal` — the risk is dropping `nonisolated` or changing a signature.)
- **Rollback (any C move)** — `git revert --no-edit HEAD && cd ArchiveProcessor && xcodegen generate`, or if it's the untip: `git reset --hard HEAD~1 && rm -f <newfile> && xcodegen generate`. Never squash/amend — unsquashed history makes a bad move bisectable.

---

## Phase 0 — Pre-flight (no destructive changes; guards Task A)

- [ ] **0.1 Drift check.** Prove `project.yml` is the complete source of truth (regen loses no hand-tweaked settings):
  `cd ArchiveProcessor && xcodegen generate && git --no-pager diff --stat ArchiveProcessor.xcodeproj/project.pbxproj` — expect only UUID/ordering noise, **no removed sources / changed build settings**. Repeat for `ArchiveCaptureiOS`. If real settings differ → port them into `project.yml` first.
- [ ] **0.2 Scheme survives a from-scratch regen.** `cd ArchiveProcessor && rm -rf ArchiveProcessor.xcodeproj && xcodegen generate && xcodebuild -scheme ArchiveProcessor -configuration Debug build 2>&1 | tail -1` → `** BUILD SUCCEEDED **`. If the scheme is missing, add a `schemes:`/`scheme:` block to `project.yml` before Task A. Repeat the regen for `ArchiveCaptureiOS` (`-sdk iphonesimulator`).

---

## Task A — Stop committing the generated `.pbxproj`

Files: `.gitignore`, both `*.xcodeproj/` bundles, `README.md` (Building), `CLAUDE.md`. **All checks are [free]** (no API key needed). Rollback is trivial: `git reset HEAD <path>` + `git checkout -- .gitignore`.

- [ ] **A.1 Untrack both bundles (keep on disk).** `git rm -r --cached ArchiveProcessor/ArchiveProcessor.xcodeproj ArchiveCaptureiOS/ArchiveCaptureiOS.xcodeproj`
  - **Check — nothing tracked** [free]: `git ls-files | grep -i pbxproj` → **no output** (grep exits 1). Also `git ls-files | grep -i xcodeproj` → no output (sweeps the two `contents.xcworkspacedata` too). *Catches: only one of the two projects untracked.*
  - **Check — files still on disk** [free]: `test -f ArchiveProcessor/ArchiveProcessor.xcodeproj/project.pbxproj && test -f ArchiveCaptureiOS/ArchiveCaptureiOS.xcodeproj/project.pbxproj` → exit 0. *Catches: a `git rm` without `--cached` deleting the working file.*
- [ ] **A.2 Add the ignore rule.** Add `*.xcodeproj/` to `.gitignore` (the whole bundle is generated; the old piecemeal `*.xcodeproj/xcuserdata/…` lines become redundant — remove them). Keep `build/`, `DerivedData/`.
  - **Check — now ignored** [free]: `git check-ignore -v ArchiveProcessor/ArchiveProcessor.xcodeproj/project.pbxproj && git check-ignore -v ArchiveCaptureiOS/ArchiveCaptureiOS.xcodeproj/project.pbxproj` → both exit 0 and print the matching `.gitignore` line. *Catches: without this, the next `git add -A` silently re-adds the file (xcodegen rewrites it every generate).*
- [ ] **A.3 Regenerate + build both apps; confirm still-ignored after regen.**
  - **Check — macOS** [free]: `cd ArchiveProcessor && xcodegen generate && xcodebuild -scheme ArchiveProcessor -configuration Debug build 2>&1 | tail -1` → `** BUILD SUCCEEDED **`; then `cd .. && git status --short` shows the regenerated `.pbxproj` as **not** appearing (ignored). *Catches: an over-broad ignore breaking generate, or the rule not holding post-regen.*
  - **Check — iOS** [free]: `cd ArchiveCaptureiOS && xcodegen generate && xcodebuild -scheme ArchiveCaptureiOS -sdk iphonesimulator -configuration Debug build 2>&1 | tail -1` → `** BUILD SUCCEEDED **`.
- [ ] **A.4 Update docs for the new onboarding step.** README `## Building`: add `brew install xcodegen` prerequisite; make `xcodegen generate` a **required first step** (a fresh clone has no `.xcodeproj`); add the headless `xcodebuild` line. CLAUDE.md: note `.pbxproj` is no longer tracked.
  - **Check — docs mention the new requirement** [free]: `grep -c 'xcodegen' README.md` ≥ 2 and `grep -ci 'brew install xcodegen' README.md` = 1. **[manual]** read the Building section: a newcomer following it top-to-bottom reaches a green build.
- [ ] **A.5 Commit** (`git add -A && git commit`). Onboarding regression is now documented; an optional `bootstrap.sh` (`brew install xcodegen && (cd ArchiveProcessor && xcodegen generate) && (cd ArchiveCaptureiOS && xcodegen generate)`) would smooth it further — add only if wanted.

---

## Task B — Worktree workflow + coordination doc

Add a **`## Concurrent / multi-agent development`** section to `CLAUDE.md` (after `## Architecture Notes`). It's docs-only, but the risk is a *wrong doc agents follow into breakage* — so we **prove the documented workflow by running it literally** in a scratch worktree. Baseline first: `git status --porcelain` clean and snapshot `shasum ArchiveProcessor/.../project.yml ArchiveCaptureiOS/.../project.yml > /tmp/main_baseline.txt` (compare later to prove main stayed untouched).

**Document (with real names):** worktree lifecycle (`git worktree add "../ap-wt-<lane>" -b <branch>` / `git worktree remove`); per-worktree build isolation (`xcodebuild -scheme ArchiveProcessor -configuration Debug -derivedDataPath ./build/DD build`, plus the iOS analog with `-scheme ArchiveCaptureiOS -sdk iphonesimulator`); the **four ownership lanes** (Android=`ArchiveCapture/`, iOS=`ArchiveCaptureiOS/`, macOS-OCR-core=`Sources/ArchiveProcessor/{OCR,Models,Capture,Net}`, macOS-Views+Tagging=`Sources/ArchiveProcessor/{Views,Tagging}`); **shared hotspots** (`Models/ProviderModels.swift` enums; the phone↔Mac protocol `Net/CaptureServer.swift` routes `GET /ping`,`POST /photo`,`POST /session/complete` w/ `Authorization: Bearer` ↔ `ArchiveCaptureiOS/.../Net/MacClient.swift`; both `project.yml`); the **enum-append rule** (append cases only — never renumber/reorder/change rawValues, they're `Codable`/persisted); **never hand-edit `.pbxproj`** (edit `project.yml` + regenerate); and the **`build/` caveat** below.

- [ ] **B.1 Draft the section (docs-only).**
  - **Check — only CLAUDE.md changed** [free]: `git status --porcelain` → exactly ` M CLAUDE.md`. *Catches: stray code/config edits.*
  - **Check — fences balanced in the NEW section** [free]: `awk '/^## Concurrent \/ multi-agent development/{f=1} f&&/^```/{n++} END{print "fences="n" even="(n%2==0)}' CLAUDE.md` → even, and >0. *(Why scoped: a whole-file parity count is masked by the 2 fences already in CLAUDE.md.)*
  - **Check — scheme names are real** [free]: `grep -Eo '\-scheme [A-Za-z]+' CLAUDE.md | sort -u` → only `-scheme ArchiveProcessor` and `-scheme ArchiveCaptureiOS`.
  - **Check — the DD path is actually ignored** [free]: `git check-ignore -v ArchiveProcessor/build/DD` → exit 0, prints `.gitignore:...:build/`. *(Why not `git check-ignore build`: the `build/` rule is directory-anchored and there is no root `build` dir, so a bare `build` arg exits 1 and false-fails.)*
  - **Check — coordination rules cite real symbols** [free]: `for e in LLMProvider ThinkingLevel DocumentClassification TaggingMode RotationMode; do grep -q "enum $e" ArchiveProcessor/Sources/ArchiveProcessor/Models/ProviderModels.swift && echo "$e OK" || echo "$e MISSING"; done` (all OK) and `grep -qE '/ping|/photo|/session/complete' ArchiveProcessor/Sources/ArchiveProcessor/Net/CaptureServer.swift && grep -qE '/ping|/photo|/session/complete' ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Net/MacClient.swift && echo PROTO_OK`. *Catches: the highest-consequence rule (append-only on persisted enums; the protocol contract) naming stale files.*
- [ ] **B.2 Prove the worktree lifecycle literally.** Run the documented command: `git worktree add "../ap-wt-verify" -b wt-verify-scratch`.
  - **Check — created & isolated** [free]: `git worktree list` shows main on `[main]` + `.../ap-wt-verify` on `[wt-verify-scratch]`; the scratch checkout has `project.yml` + `ProviderModels.swift`; and `git status --porcelain` in main is still only ` M CLAUDE.md`.
- [ ] **B.3 Prove regen + isolated build inside the worktree.**
  - **Check — regen works on the (stale) checkout** [free]: `cd "../ap-wt-verify/ArchiveProcessor" && xcodegen generate 2>&1 | tail -1` → "Created project…"; `grep -c 'ProviderModels.swift' ArchiveProcessor.xcodeproj/project.pbxproj` ≥ 1 (glob picked up sources). Note: after Task A the worktree has *no* `.xcodeproj` until this runs — that's the point.
  - **Check — main untouched by the worktree's regen** [free]: `cd` back to main and `shasum -c /tmp/main_baseline.txt` → all OK.
  - **Check — DD lands only in the worktree** [free, mtime probe]: `touch /tmp/mkr && cd "../ap-wt-verify/ArchiveProcessor" && xcodebuild -scheme ArchiveProcessor -configuration Debug -derivedDataPath ./build/DD build 2>&1 | tail -1` → SUCCEEDED; then `find "<main>/ArchiveProcessor/build" -newer /tmp/mkr -type f -print -quit | grep -q . && echo LEAKED || echo MAIN_UNTOUCHED` → `MAIN_UNTOUCHED`. *(Why mtime, not `git status -- build`: `build/` is gitignored so git status can never see a leak into it.)*
- [ ] **B.4 Prove the iOS lane builds in the worktree** (documented but must be *run*, not assumed) [free]: `cd "../ap-wt-verify/ArchiveCaptureiOS" && xcodegen generate && xcodebuild -scheme ArchiveCaptureiOS -sdk iphonesimulator -configuration Debug -derivedDataPath ./build/DD build 2>&1 | tail -1` → SUCCEEDED.
- [ ] **B.5 Prove two concurrent builds don't collide** (from CLEAN DDs — a warm run proves nothing) [free]: `rm -rf` both DDs, launch the worktree build and a main build (into `./build/DD-main`) in background, `wait`, and assert on **exit codes**: `[ "$R1" = 0 ] && [ "$R2" = 0 ] && echo BOTH_OK`. **Document the caveat:** `-derivedDataPath` isolates DerivedData/module caches but **not** the shared user-level `CACHE_ROOT` (`/var/folders/.../com.apple.DeveloperTools/…`). So the doc should say "separate DerivedData per worktree" — not "fully isolated." If worried, run 2–3 clean concurrent iterations.
- [ ] **B.6 Prove the documented teardown — including the trap.** Run the **plain** documented command first: `git worktree remove "../ap-wt-verify"`. If it errors with "contains modified or untracked files" (it will, because `./build/DD` is untracked), that's a **real doc defect** → the doc must instruct `rm -rf ./build` (or `--force`) first. Then complete cleanup: `git worktree remove --force "../ap-wt-verify" && git branch -D wt-verify-scratch && rm -rf "<main>/ArchiveProcessor/build/DD-main"`.
  - **Check — clean final state** [free]: `git worktree list` shows only main; `git status --porcelain` shows only ` M CLAUDE.md`; `shasum -c /tmp/main_baseline.txt` all OK; and a final `xcodegen generate && xcodebuild … build` in main is green.
- [ ] **B.7 Commit** (CLAUDE.md only).

---

## Task C — Split the two god files (behavior-preserving; own branch)

Pure code movement, one symbol/cluster per commit, each gated by the recipes above. **C1 (OCRView) first** (lowest risk, ~65% reduction), then **C2 (OCRProcessor)**.

- [ ] **C-S0 Branch + baselines.** `git switch -c refactor/split-ocr-files`. Enable move coloring for interactive use: `git config diff.colorMoved zebra && git config diff.colorMovedWS allow-indentation-change`. Capture baselines **programmatically** (do not hardcode): green BUILD; the **WARNINGS** count; the private-member count `grep -cE '^    private ' ArchiveProcessor/Sources/ArchiveProcessor/OCR/OCRProcessor.swift > /tmp/priv-count.txt` (≈79 today); and a symbol census (see C-S-final). Do **not** edit `project.yml` (glob auto-includes new files).

### C1 — OCRView.swift → `Views/OCRView+*.swift` (main `struct OCRView`, lines ~6–916, stays untouched)

Per move: cut the range **verbatim** into the new file, prepend the **full OCRView.swift import header** (`import SwiftUI` **plus** `UniformTypeIdentifiers`, `PDFKit`, `ImageIO` — copy all; unused imports cost nothing and prevent a whole failure class). Then run **BUILD + MOVE-PROOF + LINE-ACCOUNTING** (`grep -c 'struct <Name>' <old> <new>` → `0` and `1/2`). *(Import note: the `CollectionReviewSheet`/`DocumentSegmentReviewSheet` blocks use `PDFKit`; `ResolutionDropSheet` uses `UniformTypeIdentifiers` — copying the full header covers all.)*

| Commit | Move (verbatim) → new file | approx lines |
|---|---|---|
| C1.1 | `FileRowView` → `OCRView+FileRowView.swift` | 920–1038 |
| C1.2 | `OCRRetrySheet` → `OCRView+OCRRetrySheet.swift` | 1040–1182 |
| C1.3 | `CollectionReviewSheet` + `CollectionReviewRow` → `OCRView+CollectionReviewSheet.swift` | 1183–1360 |
| C1.4 | `DocumentSegmentReviewSheet` + `DocumentReviewRow` → `OCRView+DocumentSegmentReviewSheet.swift` | 1361–1750 |
| C1.5 | `WordDiff` (non-View engine) → `OCRView+WordDiff.swift` | 1928–2148 |
| C1.6 | `ModelTestEntry` + `ModelTestResult` → `OCRView+ModelTestTypes.swift` | 2149–2165 |
| C1.7 | `ResolutionTestSheet` → `OCRView+ResolutionTestSheet.swift` | 1751–1927 |
| C1.8 | `ModelSelectionSheet` → `OCRView+ModelSelectionSheet.swift` | 2166–2309 |
| C1.9 | `ModelTestResultsSheet` → `OCRView+ModelTestResultsSheet.swift` | 2310–2524 |
| C1.10 | `ResolutionDropSheet` → `OCRView+ResolutionDropSheet.swift` | 2525–2592 |
| C1.11 | `SegmentationEditSheet` → `OCRView+SegmentationEditSheet.swift` | 2593–2657 |

(Extract `WordDiff`/`ModelTestTypes` before their consumer sheets. All land in one target, so any order compiles — this order just keeps each diff self-explanatory.)

- [ ] **C1 done-gate** [free]: `grep -nE '^(struct|enum|class|extension)' Views/OCRView.swift` → exactly one line: `struct OCRView: View` (main struct untouched; Phase B deferred).
- [ ] **C1 FREE UI smoke [manual]** — build, launch the app (`open "$HOME/Library/Developer/Xcode/DerivedData/ArchiveProcessor-*/Build/Products/Debug/ArchiveProcessor.app"`), and **without running OCR**: drag ~5 `Test Files/Herrnstein/*.jpg` (rows render = `FileRowView` OK); double-click a row (`SegmentationEditSheet` opens/closes); Tools → Compare Models (`ModelSelectionSheet`/`ModelTestResultsSheet`/`WordDiff`); Tools → Test Resolution (`ResolutionTestSheet`/`ResolutionDropSheet`). Every sheet opens/dismisses; no crash. *(Corroborate with `ls -t ~/Library/Logs/DiagnosticReports/ArchiveProcessor* 2>/dev/null | head` — treat observed rendering as authoritative, the log as secondary; `log show --predicate 'process == "ArchiveProcessor"'` can miss SwiftUI precondition crashes.)* Catches runtime SwiftUI breaks a green build can't.

### C2 — OCRProcessor.swift → `OCR/OCRProcessor+*.swift`

**Stays in the primary file:** the class header, **ALL** stored properties, member types (`FinalReviewAction`, `RetryAction`, `BatchContext`, `PendingBatch`, `PendingRun` — unless grep shows one is used only inside a single moved cluster), and the static run-time knobs (`loadStandardImageMB` @~166, `targetDimensionScale` @~190, and the `nonisolated(unsafe) static var` block). Extensions carry **method bodies only** — `extension OCRProcessor { … }` with **no `@MainActor`** (isolation is inherited) and `nonisolated` preserved on the members that have it.

**Per move:** relax to `internal` (drop `private`) **only** the private methods *and* private stored properties touched across the new boundary — Swift `private` is file-scoped even within one type. Run **BUILD + WARNINGS + MOVE-PROOF + ACCESS-AUDIT + DOWNSTREAM-CONSUMER**, plus a **stored-props-stayed-in-primary** grep for that cluster's state (e.g. `grep -nE 'var activeBatch|struct BatchContext' OCRProcessor.swift OCRProcessor+BatchOCR.swift` → declared only in primary).

Move order (leaf clusters first; **`+MainPipeline` LAST** — it calls into every cluster, so by the time it moves, every helper it needs is already relaxed):

| Commit | Cluster → new file | Notes |
|---|---|---|
| C2.1 | 8 top-level types (lines ~4–93) → `OCRProcessor+Types.swift` | FIRST; already `internal`, no access change |
| C2.2 | `+Persistence` (save/load/delete batch+run, `saveResultToPendingRun`, `checkForPendingBatch`, `dismiss*`, `pending*FileURLs`) | keep file-local statics `private` if all callers move too |
| C2.3 | `+ParallelOCR` (`performOCRPhase`, `performOCRSequential/Parallel`, `handleOCRResult`, `isTimeoutError`, `performOCRCall` `nonisolated static`, `detectRotation` `nonisolated static`, `isRetryableError`, `retryHighUseFailures`) | keep `nonisolated` intact |
| C2.4 | `+BatchOCR` (`performBatchOCR`, `pollBatchUntilComplete`, `processBatchResults`, `resumeBatch`) | `activeBatch`/`BatchContext` stay in primary, relaxed |
| C2.5 | `+DocumentMerging` (`performDocumentMerging`) | |
| C2.6 | `+CollectionSegmentation` (`performCollectionSegmentation`, `buildReviewItems`, `applyReviewEdits`, `confirmCollectionReview`, `rebuildCollectionSegments`) | relax `collectionConfirmationContinuation` |
| C2.7 | `+DocumentSegmentation` (`performDocumentSegmentationReview`, `confirmDocumentReview`, `updateClassification`, `showFullSegmentationReview`, `showBoxFolderConfirmation`, `confirmBoxFolderReview`, `applyDocumentReviewEdits`, `rebuildSegments`, `applyPreGroupedClassifications`) | relax the two continuations |
| C2.8 | `+RotationReview` (`showRotationReview`) | |
| C2.9 | `+TaggingPhase` (`performTaggingPhase`, `applyGeneratedTags`, `writeSegmentJSON`, `applyBoxFolderLabelTags(+Unconditionally)`, `applyCapturePriorityTags`, `phoneYearTag`/`phoneMonthTag`, `exportOriginalImages`, `performAutomaticTaggingWithReview`) | |
| C2.10 | `+ManualTagging` (`performManualTaggingPhase`, `prefetchManualDates`, `advance/previous/finishManualTagging`, `performManualSegmentAndTag`, all `manualSeg*` intents, `fetchManualSegDate`) | densest private-stored-prop cluster (`manualSegContinuation`, `manualSegProvider/Model/Thinking/ApiKey`, `manualSegPreOCRed`) — relax those in primary |
| C2.11 | `+LiveCapture` (`performPreOCRedProcessing`, `classifyViaLLM` **+ its 4 `classifyCall{Gateway,Anthropic,Gemini,Mistral}` `private nonisolated` helpers — MUST move together**) | `convertPDFInputs`/`cleanupTempFiles`: assign to the file their callers live in (grep first; else defer to C2.12) |
| C2.12 | `+MainPipeline` **LAST** (`startProcessing`, `cancel`, `resumeRun`, `performOCRPhaseForIndices`, `handleRestoredResult`, `retryFailedFiles`, `continueWithoutRetry`, `promptRetryForFailedFiles`, `retryLoopForFailedFiles`, `confirmFinalReview`, `redoTagging`, `postCompletionNotification`, `writeLogFile`, `requestNotificationPermission`) | |

- [ ] **C2 done-gate** [free]: primary file holds no method bodies except the static knobs — `grep -nE '^    (private |nonisolated |@MainActor )*(static )?func ' ArchiveProcessor/Sources/ArchiveProcessor/OCR/OCRProcessor.swift` → only `loadStandardImageMB` and `targetDimensionScale`. *(Why this pattern: the naive `^    (private )?func` misses `private static func`/`nonisolated static func`/`private nonisolated func` — exactly the members being moved.)*
- [ ] **C2 FREE UI smoke [manual]** — repeat the C1 smoke checklist *plus* open the Live Capture tab (staging pane renders — exercises the `staged*/preGrouped*` wiring and `+Types` move) and the review-flow sheets from an interrupted/staged state. No OCR run.

### Final gates

- [ ] **C-S-final invariance [free].** Symbol **multiset** conservation (not `sort -u` — that hides duplicate definitions): `git grep -hoE '(struct|enum|class|func) [A-Za-z0-9_]+' main -- 'ArchiveProcessor/Sources/ArchiveProcessor/**' | sort | uniq -c > /tmp/sym-main.txt`, same for `HEAD`, then `diff` → empty (no symbol added/dropped/renamed **or duplicated**; censused over the whole source tree so nothing escaped the glob). Then a from-scratch `xcodebuild … clean build` → SUCCEEDED, and WARNINGS ≤ baseline.
- [ ] **C-S-paid — the ONE [paid] check, last, key from user first (per CLAUDE.md; est. < $0.01, gemini-2.5-flash-lite).** The batch/instance-method path (`startProcessing` → segmentation/collection review → `performTaggingPhase` → finalize) is **not** exercised by `LiveCaptureTestDriver` (that harness only drives the live-staging pipeline via `LiveCaptureProcessor`, which touches `OCRProcessor` solely through the nonisolated statics). So do a **real 2–3 image batch via the Process Files GUI tab** with the user's key: drop a box marker + a couple of document pages from `Test Files/Herrnstein/`, run automatic tagging, confirm each input produces a PDF (page 1 image + page 2 non-empty extracted text) and tags apply. *(Optionally also run the `LiveCaptureTestDriver` headless path to cover `+LiveCapture` + `performOCRCall`.)* This is the only regression class no free check reaches.

---

## Risks & rollback

- **Refactor breaks a shipped app (main risk):** mitigated by small build-verified per-commit moves on a branch, the corrected MOVE-PROOF/ACCESS-AUDIT/WARNINGS gates, two free UI smokes, one paid batch smoke; every commit independently `git revert`-able; unsquashed history is bisectable.
- **`.pbxproj` drift / missing scheme:** caught by Phase 0 before anything is deleted.
- **Over-relaxed access:** the census-diff ACCESS-AUDIT flags any member that lost `private` without a cross-file caller → revert.
- **Swift-6 isolation drift:** the WARNINGS-delta gate catches new `sending`/`actor-isolated`/`Sendable` warnings a green build hides.
- **Onboarding regression (Task A):** documented in README/CLAUDE; optional bootstrap script.

## Out of scope (deferred, per decision)

LICENSE (repo stays all-rights-reserved for now), GitHub Actions CI, `CONTRIBUTING.md`/`CODE_OF_CONDUCT.md`/`SECURITY.md`, committed test-image fixtures, a smoke-test target. The repo is otherwise clean to open later (no committed secrets, no hardcoded user paths, code-signing off, generic bundle IDs).
