# W40 — verification phase: the daemon's plan

Written 2026-10-04. **Status: APPROVED by the owner 2026-10-04** (`W40-owner-ok`, `W40.c2-owner-ok` and `W40.e8-owner-ok` all
granted; reviews stay paused). Starts when the current queue is exhausted. The owner-facing version, with the
reasoning and the owner's answers, is `00-owner-plan.md` in this folder. Read it once before the first W40 item;
it is short.

This plan is the *detail*. The *order* is the `### TIER 7` block in `.maintenance/AUTONOMOUS_PLAN.md` `## WORK QUEUE`,
mirrored by the `W40` section of `SUITE_TODO.md`, tags byte-identical. `next-queue-item.sh` reads only the
`(blocked-on: …)` tags, so every dependency below is written as one. The edges were loosened on 2026-10-07 (rule 7):
`b0`, `d6`, `e5`, `f1` and `f2` wait on nothing, and `e1`, `e6` and `e7` on `a1` rather than `a3`.

## Why this phase exists (the evidence, 2026-10-04 survey)

- **Completion overstated, about fifteen recorded cases.** Notes W0–W8 ticked with whole features unreachable
  (`archive-notes/09-gap-closure.md`); the GUI-VM lane printing ✓ for zero tests; the `tag-vocabulary` gate step
  never once passing; two KNOWN_ISSUES entries describing protections that do not exist (`SUITE_TODO.md` Wave 17);
  five Wave-26 harnesses with no caller; the E2E oracle's tag branch dead until `092adb9`.
- **Gates lapsed.** No `health-gate.sh` run on the 58 commits after `862e305` (2026-09-24); Codex sessions never
  call it. The gate does not run ArchiveCore `swift test` (the residue of `W9.c1`), relay-golden, the E2E or Android.
- **Runtime evidence is thin.** Processor: no unit-test target; Process Files on real material last run July;
  Anthropic/Mistral/OpenAI never called through the app's own clients; no real batch submission; USB bridge has no
  entry point and no run. Notes: typing → autosave → flush on ⌘Q never driven; Zotero only ever a stub; last *full*
  GUI-suite pass 2026-09-19 and the suite is order-dependent (G19 deletes the fixture note). Reader: FTS index, the
  AppKit list and the health popover never measured at corpus size; owner GUI passes all predate the August discovery rewrite.
- **Docs claim what code does not do.** Reader `InlineEditCells.swift` cells have zero references (single-click
  Read toggle, date pop-up); Reader `CLAUDE.md` §12 promises an append-only audit ledger that does not exist (undo
  is in memory, `Views/NavigationModel.swift` `undoLast`); Processor `KNOWN_ISSUES.md` §1 says
  `loadStagingManifest()` calls `migrateLegacyManifestSegments`, which no production path calls.
- **Review precision.** Lean paced reviews: 50 confirmed of 65 candidates. Published work (2025–26) puts LLM
  false-rejection of correct code at 26–62%, rising when asked to explain-and-fix. Findings need execution.

## Phase rules — these bind every W40 item and every item it files

1. **Evidence or it did not happen.** A claim that something works cites a run artifact kept under
   `verification/evidence/<app>/` (log excerpt, screenshot path, output-check transcript) and the commit it ran at.
   "The tests pass" is not runtime evidence for a user-facing feature.
2. **The feature ledger is the measure of done, not checkboxes.** One ledger per app in `verification/`. Format in
   `verification/README.md` (`W40.b0`). Rows start `unproven`. Allowed statuses: `unproven` · `works` · `broken` ·
   `unreachable` · `fixed-pending-recheck` (rule 6) · `dropped` (owner only) · `unverifiable-here` (needs owner
   hardware or accounts; say which).
3. **Write from the promise, then read the code.** A ledger row and a journey's expected outcome are written from
   SPEC, the plans, the guides and the done-records, before opening the implementation. Then check the code.
4. **Promise-tests are protected.** A fix may not change what a journey test or a ledger-derived test expects
   unless the commit message says why and the ledger row records it. Never delete or skip a failing promise-test to
   get green; that is a park-worthy defect, not a fix.
5. **Reproduce before filing.** A bug enters the queue only with a reproduction: a failing test, or a scripted run
   on scratch data with its artifact. Anything weaker goes in `verification/SUSPECTS.md` with what would confirm it.
   AI-generated findings are suspects until reproduced.
6. **Builder is not verifier.** The session that fixes a bug or wires a feature may move its ledger row only to
   `fixed-pending-recheck`. A later, separate item (`W40.h2`, or the next journey re-run) moves it to `works`.
7. **Feature freeze, per area (owner, 2026-10-07: "Start the independent parts now").** No new features in this
   phase. Allowed new code: wiring or removing a ledger row the owner has ruled on, fixing a reproduced bug, and test
   or diagnostic tooling. The freeze is per app, not suite-wide: the phase starts while features are still being
   finished elsewhere, and only an app's **ledger and journeys** wait for that app's unfinished features —
   Processor `W40.b3` and `W40.d1`–`d4` on `W36.seg-decision` (and on any `W36.seg-build*` it files), the Reader and
   Notes ledgers `W40.b1`/`b2` on `W24.cal1`, whose journeys follow through the ledgers. Gate, tooling and
   suspicion items (`a1`–`a5`, `b0`, `d6`, `e*`, `f*`) do not wait for features. Until 2026-10-07 `W40.a1` waited on
   every open feature item and the whole phase hung off it.
8. **Severity orders fixes.** Reproduced bugs are filed as `W40.fix-<slug>` with a severity:
   `S1` data loss or a write to the wrong file · `S2` a promised feature broken or unreachable · `S3` wrong but
   recoverable · `S4` cosmetic. `S1` goes to the TOP of TIER 7; `S2`–`S4` go to the `W40 fixes` sub-block, above
   the discovery items not yet started. Every fix ships with the test that failed before it.
9. **Unchanged:** the real corpus (`~/Desktop/Google Drive/Archival Photos/`) is never written; nothing draws on
   the owner's screen (VM lane only); Tier-2 for irreversible paths; worktree-first; cost stated before any paid
   run, cheapest capable model, smallest input that proves the behaviour.
10. **Decisions go to the Daemon Report**, one entry per decision, in the established form. Typical ones: finish or
    drop an `unreachable` row; whether a promised-but-absent safeguard (the Reader audit ledger) is built or the
    promise withdrawn.
11. **A declined owner gate does not strand its dependants.** The owner's "no" is recorded by ticking the
    `-owner-ok` line with `DECLINED` and the date, and the gated item closes the same way in the same commit. Its
    dependants then take their fallback: `W40.c2` declined → `W40.d7` runs on the synthetic tree only and says so;
    `W40.e8` declined → its entry moves to the DECLINED
    list in `SUITE_TODO.md`.
12. **Reviews.** This phase does not lift the `REVIEW.md` pause. Its finders are tools, journeys and the owner's
    sessions. Owner approval of `W40-owner-ok` is the authorization for the `W40.e*` items specifically.

## Sizing

Each item below is meant to finish in one session, two at most (`resume-prompt.txt` rule). An item that turns
out larger splits itself: file `<tag>a`, `<tag>b` … with `(blocked-on:)` chains and complete the first part.

## A — honest gates (first; everything else depends on them)

- **`W40.a1` — health gate green at HEAD, and run at hand-off [M].** Run `ops/autonomous/health-gate.sh` at HEAD;
  fix or file whatever is red. Change `CODEX_RUNBOOK.md` so an external agent runs the gate on the daemon's cadence
  (read `STATE/last-gate`, same commit threshold), so the 58-commit gap cannot recur. Blocked on the owner's
  approval and on the gate-relevant queue items (`W9.cand2`, `W9.e4`, `W37.dual-date`); not on unfinished features
  (rule 7).
- **`W40.a2` — the gate runs ArchiveCore's tests [S].** Add `swift test` for `packages/ArchiveCore` to
  `health-gate.sh`. Prove it bites: plant a failing Core assertion, see the gate go red, revert.
- **`W40.a3` — every lane green in full, in any order [M].** Run all three apps' full VM UI suites, the phone↔Mac
  E2E and `scripts/test-relay-golden.sh` at HEAD. Make the Notes suite order-independent (G19 deletes the fixture
  note `setUpOnMainActor` needs). Put relay-golden in the gate. Record counts and durations in the ledger README.
- **`W40.a4` — remove tests that cannot fail [S].** `SmokePlaceholderTests.testAppExists`
  (`XCTAssertTrue(true)`), assertion-free tests such as `SourceBlockViewTests.fitResetsAutoScale`, the
  `EditorBindingTests` lint that passes when its directory is missing, and fixture-missing `XCTSkipUnless` in the
  gate lanes (a skipped suite in the gate is a failure there). Sweep each app for the same shapes.
- **`W40.a5` — test drivers out of Release [S].** Processor's 17 env-gated drivers and their `*Contract.swift`
  seams compile into Release (`ContentView.swift` dispatch). Put them behind `#if DEBUG` or a build flag, or prove
  why a script needs them in Release. Prove absence with `nm` on the Release binary. Tier-2.

## I — revive the iPhone companion (owner, 2026-10-04: before testing)

- **`W40.i1` — build it again [S-M].** Check free disk first (the runtime is about 16 GB; stop and report under
  30 GB free). `xcodebuild -downloadPlatform iOS`, `xcodegen generate`, simulator build, fix compile breaks. Restore
  the iOS build line in `ArchiveProcessor/CLAUDE.md`, add an iOS build step to the gate, delete
  `ArchiveCaptureiOS/PARKED.md`, and amend the "ON HOLD" text in `SUITE_TODO.md` §Project focus.
- **`W40.i2` — parity with Android [M].** A feature-by-feature comparison of iOS and Android, written into
  `verification/capture.md`. Include every fix recorded as Android-only while parked (search the done-records for
  "iOS twin" and "PARKED"; `W23.m1` is one). File each gap as `W40.i-fix-<slug>` (blocked-on: W40.i2).
- **`W40.i3` — iOS in the phone↔Mac E2E [M].** Extend `ArchiveProcessor/scripts/e2e-phone-mac.sh` to drive the
  iOS simulator through the same inject seam Android uses. Blocked on the parity fixes the comparison files; add
  their tags to this line when they are filed.
- **`W40.i5` — borrowed-iPhone session pack [S].** The owner has no iPhone and no paid developer account; a
  phone is borrowed for one concentrated period. Prepare `verification/sessions/iphone-1.md` so that period goes
  on testing: free-Apple-ID signing steps in Xcode (Personal Team; the install lasts seven days), enabling
  Developer Mode on the phone and trusting the developer, pairing with the Mac over Wi-Fi and USB, then the
  capture tasks in order with a note form. Everything the simulator can show must already be shown, so the
  borrowed phone tests only camera, real network and the device itself.
- **`W40.i4` — real-iPhone pass — OWNER.** HOLD QUEUE only. The owner's concentrated session with a borrowed
  phone, using the `W40.i5` pack.

## B — feature ledgers

- **`W40.b0` — ledger format [S].** `verification/README.md`: the statuses, the evidence rule, the row fields
  (feature as promised · where promised · how a user reaches it, file:line · real-path test · runtime evidence
  with date, commit and artifact · status · notes), and how `SUSPECTS.md` works. Plain markdown, one section per
  feature, no tables wider than the page.
- **`W40.b1` — Reader ledger [M].** Sources: `ArchiveReader/CLAUDE.md`, `README.md`, `SMOKE_TEST.md`, `SPEC/`,
  Reader done-records. Roughly 35 rows. Mark the dead `InlineEditCells` features `unreachable`; mark the §12 audit
  ledger as a promise with no implementation.
- **`W40.b2` — Notes ledger [M].** Sources: `00-overview.md`, `09-gap-closure.md`, `ArchiveNotes/CLAUDE.md`,
  `SMOKE_TEST.md`. Takes in the `W9.e1`/`W9.e2` results rather than repeating them. Roughly 40 rows.
- **`W40.b3` — Processor ledger [M].** Sources: `ArchiveProcessor/CLAUDE.md`, `README.md`, `TESTING.md`,
  `LIVE_CAPTURE_ANDROID_TEST.md`, `SPEC/tag-format.md`. Roughly 37 rows.
- **`W40.b4` — capture ledger, Android and iOS [S].** Extends `verification/capture.md` from `W40.i2`.
- **`W40.b5` — doc drift [S-M].** Correct what the ledgers found the guides claiming falsely: Reader map entries
  for dead or deleted files and its stale test counts; Processor `TESTING.md` (pypdf, "586 PDFs", "no test
  target"); Processor `KNOWN_ISSUES.md` §1's migration claim. Leave the Reader §12 promise until the owner rules
  on `W40.f1`, but mark it there as unimplemented.

## C — rehearsal material

All rehearsal material lives outside `~/Claude`, under `~/Library/Caches/ArchiveSuiteRehearsal/`, and is
regenerable. It is never committed. Each set gets a `MANIFEST.txt` saying what it is and how it was made.

- **`W40.c1` — Processor and Notes sets [S-M].** Catalogue `ArchiveProcessor/Test Files/` (about 1,000 images
  with five ground-truth segmentation CSVs) and pick the smallest ground-truth collection for `W40.d1`. Build a
  Notes rehearsal store larger and messier than `AN-GUI-Fixture`. Work out and document how sets reach the Tart VM.
- **`W40.c2` — Reader sample of the real corpus [S].** Gated on `W40.c2-owner-ok`. Read-only copy of about 5,000
  PDFs and their JPEG partners with xattrs preserved (`ditto`), sampled across the tree, not the first 5,000.
  Before copying, list each sampled file's size, mtime and tag xattr; after, list them again and prove them
  identical. That listing is the evidence the corpus was not touched.
- **No Google Drive sync test.** The corpus path contains `Google Drive`, but it is a plain local folder and Google
  Drive is not running on this machine (owner, 2026-10-04; also `SUITE_TODO.md` §Wave 26). There is no sync
  behaviour to test. Do not file one.

## D — journeys (rehearse the four real uses end to end)

Every journey runs in the VM or headless, on rehearsal material, writes its evidence under
`verification/evidence/`, and updates ledger rows. A journey that finds a bug files it under rule 5 and carries on
where it can.

- **`W40.d1` — bulk OCR on a ground-truth collection [M].** Process Files through the real app with the
  cheapest capable provider; state the cost first. Score the split into documents against the CSV. Check every
  output PDF with `qpdf --check` and `pdfcpu validate`, decode every Finder-tag xattr (`xattr -px` → `plutil`),
  and compare page 2 and the tags against `SPEC/tag-format.md`.
- **`W40.d2` — Processor review dialogs by hand [M].** In the VM, drive segmentation review, box/folder confirm,
  manual tagging and rotation review with real choices (not the auto-pilot), and check the output reflects them.
- **`W40.d3` — every provider through the app's own client [S-M].** Anthropic, Mistral, OpenAI and Apple Vision
  on two to five real images each; Local Agent if a CLI is installed, otherwise `unverifiable-here`.
- **`W40.d4` — one tiny real batch job per batch-capable provider [S-M].** Submit, poll, collect; and a cancel.
  State the cost first.
- **`W40.d5` — live capture with hand-driven review [M].** Emulator, real images from `Test Files` through the
  inject seam, tag cards and finalize done by hand, the stage-for-later hand-off. Prove originals go to the Trash
  only after their output is on disk.
- **`W40.d6` — USB transport [S].** Establish whether any user path reaches `USBBridge`. If none, the row is
  `unreachable` and goes to the owner.
- **`W40.d7` — Reader at size [M].** On the `W40.c2` sample, and on the 150k synthetic tree for list length:
  FTS index build time, search latency, list scrolling, health-popover cost, memory. Compare with the 2026-08-10
  scale numbers in Reader `KNOWN_ISSUES.md`.
- **`W40.d8` — Reader triage writes [M].** Mark Read & Next, inline subject edit, group edit, rename across
  files, merge similar tags, undo, smart folders. Decode the xattrs after every step; quit and relaunch; check
  unrelated tags and colours survive.
- **`W40.d9` — Notes writing session [M].** Real keystrokes (`typeText`), autosave, ⌘Q, relaunch, bytes match;
  window close; a note's `.md` edited outside the app while open (suspected silent overwrite); a forced
  asset-write failure (`ArchiveNotes/KNOWN_ISSUES.md`: logged, never shown).
- **`W40.d10` — Notes integrations [M].** Real Zotero installed in the VM, auto-fill and attach; real Reader
  launch and deep links both ways; Copy Link; an inbound `archivenotes://` URL dispatched by the OS.
- **`W40.d11` — the shared contract across apps [S-M].** Open `W40.d1`'s output in the Reader; tags, dates,
  quality and classification must read as written. Make a Notes source block from one of them.

## E — machine bug-finders

- **`W40.e1` — sanitizers [M].** Thread Sanitizer and Address Sanitizer configurations (separate runs) for
  ArchiveCore and the Reader and Notes unit suites; Processor drivers under TSan. Triage every report under rule 5.
- **`W40.e2` — crash, hang and leak harvest [S-M].** After each VM run, copy new `.ips` files out of the guest's
  `DiagnosticReports` and fail the run on any new one; `leaks --atExit` on the unit suites.
- **`W40.e3` — accessibility audit [S-M].** `performAccessibilityAudit` on each main screen in each UI suite;
  findings are `S2`–`S4`.
- **`W40.e4` — never-executed code [M].** `xccov` over unit, UI and journey runs. List functions no run reached;
  each goes to its ledger as a question (dead, unreachable, or untested).
- **`W40.e5` — dead-code scan [S-M].** Periphery per app. Each hit is deleted (library code with no promise), or
  goes to its ledger (a promised feature with no entry point).
- **`W40.e6` — parser robustness [M].** In-suite fuzz loops (truncate, flip bytes, nest) over the tag format, note
  front-matter, the relay object format, the staging manifest and page-2 metadata; property tests for tag
  write-then-read round trips. A crash or a silent wrong value is a bug; a clean error is a pass.
- **`W40.e7` — mutation sample on the irreversible paths [M].** About ten planted mutants each in the tag writer,
  finalize/Trash, note save and Reader undo. Prove each mutant landed before believing it survived. Survivors are
  missing tests, filed as `S3`.
- **`W40.e8` — Android screens without an emulator [M].** Gated on `W40.e8-owner-ok` (an instrumented lane was
  declined 2026-07-31). Robolectric Compose tests plus Roborazzi screenshots under `testDebugUnitTest`.

## F — specific suspicions to settle

- **`W40.f1` — Reader undo durability [S].** Demonstrate: undo is memory-only, and `undoLast` drops files it
  cannot undo (`try?`) and reports only the count it did. Then a Daemon Report decision: build the promised audit
  ledger, or withdraw the promise and say so in the guide.
- **`W40.f2` — the Reader's root marker [S].** The Reader writes `.archive-suite-root.json` into the granted root
  (`RootMarker.swift`). Once the owner points it at the corpus, that is a byte-level write into the corpus tree
  that the Core Directive does not disclose. Demonstrate on scratch, then a Daemon Report decision.

## G — the owner's guided sessions

- **`W40.g1` / `W40.g2` / `W40.g3` — session packs for Reader, Notes, Processor + capture [S each].** Each pack in
  `verification/sessions/<app>-1.md`: a 45-minute list of real tasks in the owner's terms, where the rehearsal
  material is and how to open it, and a one-page note form (task · what you expected · what happened · how much it
  mattered). After the owner returns a form, the next session files each note as a reproduced bug, a design
  question for the Daemon Report, or a `SUSPECTS.md` entry. Repeat packs (`-2`, `-3`) after fix batches.
- The sessions themselves are the owner's (`W40.g-sessions`, HOLD QUEUE).

## H — re-check and release

- **`W40.h2` — re-run every journey at HEAD [M, may split].** Moves `fixed-pending-recheck` rows to `works` or
  back to `broken`. Blocked on every D and E item and every open `W40.fix-*` S1/S2.
- **`W40.h3` — release candidate — OWNER (Tier-3).** HOLD QUEUE.
- **`W40.h4` — the owner's acceptance pass with the ledgers — OWNER.** HOLD QUEUE. When it passes, the DEVONthink
  hold and the feature freeze are the owner's to lift.
