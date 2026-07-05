# STATUS — resume pointer

Single source of "where are we, what's next," kept current every work session so a fresh instance
(e.g. after a usage-credit cutoff) can resume immediately. **Read order:** CLAUDE.md → AGENTS.md →
PLAN.md → this file.

## Current state (2026-07-05)
- **Milestone:** **ALL PLANNED WORK COMPLETE + GUI SMOKE-TESTED LIVE.** M0–M3 + the entire
  **High-priority** backlog, a full adversarial code review (13 bugs fixed), a documentation review,
  and now a **driven interactive GUI smoke test (18/22 steps PASS live, 0 FAIL; 4 covered indirectly)**
  which caught + fixed the mark-Read display bug (two compounding causes) and 4 reactive-timing bugs.
- **Build:** GREEN. `cd ArchiveReader && xcodegen generate && xcodebuild -scheme ArchiveReader -configuration Debug -derivedDataPath ./build/DD build` → **BUILD SUCCEEDED**;
  `xcodebuild … test` → **83/83 pass**; `bash scripts/lint-write-surface.sh` → clean.
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

## ACTIVE PLAN (2026-07-05) → `PLAN_NEAR_TERM_UI.md`
Owner-approved UI Batch 2 — left sidebar (file tree + smart folders), create-smart-folder-from-filters,
all of item 4 (small UI wins), and item 5 (tag rename + count badges). **Durable & resumable**: the
plan's checkboxes are the source of truth; resume at the first `[ ]`. Each milestone builds green +
tests green + code-reviewed + GUI/smoke-tested + committed/pushed before the next. Item 3 (non-standard
PDFs) was deferred to `POTENTIAL_FEATURES.md`. **Status: plan written; awaiting owner go-ahead to start
Milestone A** (or reprioritize).

## Next action — remaining work (none blocking; app is feature-complete + GUI-verified for v1)
1. **GUI smoke test — DONE (2026-07-05).** Driven live on a scratch corpus (`~/Library/Application Support/ArchiveReader/AR-Smoke`, 30
   tagged copies) via `screencapture`/System Events/`cliclick`; **18/22 steps PASS, 0 FAIL** (full
   record + the 4 `[~]` indirectly-covered steps in `SMOKE_TEST.md`). It caught the mark-Read display
   bug and 4 reactive-timing bugs, all fixed (see `KNOWN_ISSUES.md`). *Optional follow-up:* drive the
   4 remaining steps live — C (read-state filter), E (subject filter), K (viewer ⌘C/⌘F), S (saved
   search) — and the exhaustive viewer zoom/splitter. **Automation note:** launch the built app with
   `open -a` and **verify `ArchiveReader` is frontmost before every click/capture** (the VS Code host
   reclaims focus; a blind region capture can grab another window — a privacy hazard).
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
  chmod +x "/Users/<user>/Desktop/Claude/Archive Reader/.maintenance/autobuild.sh"
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
- `touch "/Users/<user>/Desktop/Claude/Archive Reader/.maintenance/STOP"`  (halts both drivers), and/or
- cancel the cron in the live session, and/or `launchctl bootout gui/$(id -u)/com.archivereader.autobuild`.
