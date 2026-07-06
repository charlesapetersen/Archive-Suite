# STATUS — resume pointer

Single source of "where are we, what's next," kept current every work session so a fresh instance
(e.g. after a usage-credit cutoff) can resume immediately. **Read order:** CLAUDE.md → AGENTS.md →
PLAN.md → this file.

## Current state (2026-07-06)
- **Milestone:** **UI Batch-2 (PLAN_NEAR_TERM_UI Milestones A–E) COMPLETE + GUI-VERIFIED**, on top of
  v1 (M0–M3 + High-priority backlog). Batch-2 shipped the left sidebar (navigable folder tree + smart
  folders), create-smart-folder-from-filters, all item-4 UI wins, and item-5 (corpus tag rename + count
  badges). Two adversarial review passes (E1): the 2026-07-05 pass (10 findings → 7 fixes) and a
  2026-07-06 re-review of the fix diff that caught the **subjectsSig parity** regression; GUI testing
  caught the **folder-tree-click-doesn't-scope** regression. Both follow-up regressions fixed & verified.
- **Build:** GREEN. `cd ArchiveReader && xcodegen generate && xcodebuild -scheme ArchiveReader -configuration Debug -derivedDataPath ./build/DD build` → **BUILD SUCCEEDED**;
  `xcodebuild … test` → **95/95 pass**; `bash scripts/lint-write-surface.sh` → clean.
- **Latest commits:** `e4d93d0` E1 follow-up (folder-tree @State scoping + subjectsSig parity via
  `Core/LibraryChangeSignature` + 7 tests) · `2488df4` E1: 10 review findings → 7 fixes.
- **GUI-verified (2026-07-06, machine free):** folder-tree scoping (Batch-A/B + All Files consistent),
  tag cloud = subjects-only, save-smart-folder flow + count badge, delete. **Harness limitation** (not an
  app defect, not focus contention): synthetic input can't drive SwiftUI `.plain` content buttons /
  `.alert` text fields (they expose no AX label + ignore synthetic clicks); AppKit-bridged menu bar /
  labeled toolbar items / `List` rows drive fine. Chip click-to-filter + custom-name typing = owner-manual.
- **Shipped (see CLAUDE.md §Implementation map for the file tree):**
  - **M0** `Core/TagWriter` — single audited write choke-point (delta edits, coordinated metadata-only
    write, trustworthy-read guard, multiset+label verify, drift restore, label-only inverse undo,
    batch). Read-only Core: `DocumentTags`, `TagReading`, `TagEditing`, `FileLink`, `ArchiveFile`,
    `LibraryFilter`, `CopyTextCleaner`, `DocumentRuns`, `AppSettings`. `scripts/lint-write-surface.sh`.
  - **M1** navigation window: `Search/{RootFolderStore, ArchiveLibrary}` +
    `Views/{NavigationModel, NavigationWindowView}` — Spotlight discovery, table, 3 filters, multi-level
    sort, copy-links (⌘⇧C), mark Read/Unread + grouped undo, open (⌘O).
  - **M1.5** `Search/{ContentIndex (SQLite FTS5), PDFTextExtractor, ContentIndexer}` — corpus full-text
    search wired into the nav window.
  - **M2** `Views/{PDFPaneView, DocumentViewerModel, DocumentWindowView}` — two-up viewer, independent
    zoom, draggable ⅔:⅓ splitter, ↑/↓ cycling, intelligent copy, in-doc find.
  - **M3** `Views/{TagEditorView, OptionsView}` — group-aware Tag Editor (⌘I), Options (⌘,),
    VoiceOver announcements, library-health popover.
  - **High-priority:** `Search/{NotesStore, SavedSearch}` — notes/flags (outside the corpus),
    reading-session resume, saved searches, Quick Look (⌘Y), opt-in document-run selection.
  - **Tests:** 83 across DocumentTags, FileLink, TagWriter, LibrarySortFilter, ContentIndex,
    CopyTextCleaner, TagEditing, NotesStore, SavedSearch, DocumentRuns, **ArchiveLibraryOverride** (the
    new pure `overrideDecision` reconciliation, 8 tests).
- **Latest commits:** `2b4a66b` mark-Read render-skip fix (ArchiveFile value-equality) + smoke results ·
  `2e9c661` Spotlight-clobber overlay + 4 reactive-timing bugs (multi-agent review) · `af69463` app icon ·
  `4f11dc7` smoke harness · `cc26aec` willSet 0-of-N fix.

## UI refinement batch (2026-07-05) — 14 owner-requested changes, all shipped (see `UI_REFINEMENTS.md`)
Header-click column sort (all columns, both directions, multi-level); File-tags column excludes date
tokens; "Add tag filter" with `NSComboBox` autocomplete; removed "No read-state"; right-margin tag
cloud (size ∝ visible-file count, click-to-filter); inline list editing of tags/priority/read/date
(single-file; multi-file via ⌘I); Reveal in Finder (⌘⇧R + context menu); two copy modes (plain ⌘C /
cleaned ⌘⇧C); reworked viewer keys (↑/↓ scroll page, ⌘↑/⌘↓ top-anchored zoom, ⌘⇧↑/⌘⇧↓ page-in-segment,
⌘⌥←/→ focus panes with a focus border); preview ↑/↓ browse the file list. Each cluster built + 83
tests green + GUI-verified + committed/pushed. **Scratch corpus moved** off the Desktop to
`~/Library/Application Support/ArchiveReader/AR-Smoke` (smoke-setup.sh updated).

## ACTIVE PLAN (2026-07-05) → `PLAN_NEAR_TERM_UI.md` — **COMPLETE (2026-07-06)**
Owner-approved UI Batch 2 — left sidebar (file tree + smart folders), create-smart-folder-from-filters,
all of item 4 (small UI wins), and item 5 (tag rename + count badges). **Milestones A–E all `[x]`.**
Item 3 (non-standard PDFs) was deferred to `POTENTIAL_FEATURES.md`. Remaining tail (non-blocking):
full `SMOKE_TEST.md` expansion + Batch-1 regression pass (E2 tail), and the owner-manual GUI checks the
synthetic-input harness can't drive (tag-cloud chip click-to-filter; smart-folder/tag rename custom-name
typing — the rename *mechanism* is proven via the save flow + unit tests).

## Next action — remaining work (none blocking; app is feature-complete + GUI-verified for v1)
1. **GUI smoke test — DONE (2026-07-05).** Driven live on a scratch corpus (`~/Library/Application Support/ArchiveReader/AR-Smoke`, 30
   tagged copies) via `screencapture`/System Events/`cliclick`; **18/22 steps PASS, 0 FAIL** (full
   record + the 4 `[~]` indirectly-covered steps in `SMOKE_TEST.md`). It caught the mark-Read display
   bug and 4 reactive-timing bugs, all fixed (see `KNOWN_ISSUES.md`). *Optional follow-up:* drive the
   4 remaining steps live — C (read-state filter), E (subject filter), K (viewer ⌘C/⌘F), S (saved
   search) — and the exhaustive viewer zoom/splitter. **Automation note:** before a GUI run, **ask the
   owner whether the machine will be free or in use** (see memory `gui-testing-machine-availability`):
   free → drive everything incl. modal sheets; in use → the focused host app contends for focus, so
   verify sheet-confirm flows via unit/visual checks + a frontmost-guard (a blind capture could grab
   another window — a privacy hazard). Launch with `open -a`.
2. **Perf-check** the nav Table at ~150k (data layer abstracted; AppKit `NSTableView` swap possible).
3. **Deferred / optional:** Medium & Lower `POTENTIAL_FEATURES` (explicitly out of the overnight
   scope); non-sandboxed whole-Mac search (code-ready — a build-time entitlement flip, see below).

## Autonomous overnight run
- **Scope:** implement the PLAN (M0→M4), then **only the "High priority" items in
  POTENTIAL_FEATURES.md** (skip Medium/Lower). No check-ins.
- **Driver (active): in-session CronCreate** job `857d39e7`, every 15 min — re-fires the resume
  prompt (`.maintenance/resume-prompt.txt`) to continue the build. Survives the usage-limit
  pause/resume (session persists). Session-only; gone if the whole session ends.
- **Backstop (NEEDS ONE-TIME ENABLE): launchd dead-man's switch.** Files are ready
  (`.maintenance/autobuild.sh`, `~/Library/LaunchAgents/com.archivereader.autobuild.plist`) but
  `chmod +x` and `launchctl load` were **blocked by the Bash permission classifier**. To enable the
  cross-session (true-death) backstop, the user runs:
  ```sh
  chmod +x "/Users/<user>/Desktop/Claude/Archive Suite/.maintenance/autobuild.sh"
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.archivereader.autobuild.plist"
  ```
  It fires every 30 min and resumes headless only when the heartbeat is >45 min stale.

## Git remote (2026-07-05)
- **This repo is the `Archive Suite` monorepo**, PRIVATE at
  **`github.com/charlesapetersen/Archive-Suite`** (`origin`, `main` tracks `origin/main`). It currently
  holds only **Archive Reader** at the repo root; `Test files/`, `build/`, `*.xcodeproj/`, and
  `.maintenance/` are gitignored and were **not** pushed (verified). Use `/opt/homebrew/bin/gh`.
- **When Archive Processor joins** (per CLAUDE.md §Archive Suite): `git mv` the current root into an
  `ArchiveReader/` subdir and add `ArchiveProcessor/` (and later `ArchiveCore/`) as siblings — deferred
  by the owner. History is preserved through the move.

## Resilience protocol (against credit cutoffs) — standard practice
- Commit after each buildable sub-step; keep the build GREEN at every commit; **`git push origin main`**
  after committing (remote is the off-machine durable record now that `origin` exists).
- Update **Current state** + **Next action** here (and `.maintenance/RESUME.md` heartbeat) every turn.
- Prefer many small commits over one large uncommitted change; git history is the durable record.

## How to STOP the overnight loop
- `touch "/Users/<user>/Desktop/Claude/Archive Suite/.maintenance/STOP"`  (halts both drivers), and/or
- cancel the cron in the live session, and/or `launchctl bootout gui/$(id -u)/com.archivereader.autobuild`.
