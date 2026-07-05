# STATUS — resume pointer

Single source of "where are we, what's next," kept current every work session so a fresh instance
(e.g. after a usage-credit cutoff) can resume immediately. **Read order:** CLAUDE.md → AGENTS.md →
PLAN.md → this file.

## Current state (2026-07-05)
- **Milestone:** **ALL PLANNED WORK COMPLETE** — M0–M3 + the entire **High-priority** backlog, plus a
  full adversarial code review (13 confirmed bugs fixed) and this documentation review.
- **Build:** GREEN. `cd ArchiveReader && xcodegen generate && xcodebuild -scheme ArchiveReader -configuration Debug -derivedDataPath ./build/DD build` → **BUILD SUCCEEDED**;
  `xcodebuild … test` → **75/75 pass**; `bash scripts/lint-write-surface.sh` → clean.
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
  - **Tests:** 75 across DocumentTags, FileLink, TagWriter, LibrarySortFilter, ContentIndex,
    CopyTextCleaner, TagEditing, NotesStore, SavedSearch, DocumentRuns.
- **Latest commits:** `763a40f` review fixes · `19267be` document-run · `720b738` Quick Look ·
  `76f36ff` saved searches · `fc7b564` notes/resume · `53b3ebe` tag editor.

## Next action — remaining work (none blocking; app is feature-complete for v1)
1. **Manual GUI smoke test (only real gap):** the SwiftUI GUI compiles + the logic is unit-tested, but
   the GUI has **not been driven at runtime** (this headless env can't launch/interact with the
   sandboxed app; nested `claude` is blocked). At the machine: launch the app, choose the `Test files`
   folder as root, confirm the list populates + sorts chronologically, filters + full-text work,
   mark-Read drops a row from an Unread view, ⌘O opens the two-up viewer, ⌘C copies cleaned text.
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

## Resilience protocol (against credit cutoffs) — standard practice
- Commit after each buildable sub-step; keep the build GREEN at every commit.
- Update **Current state** + **Next action** here (and `.maintenance/RESUME.md` heartbeat) every turn.
- Prefer many small commits over one large uncommitted change; git history is the durable record.

## How to STOP the overnight loop
- `touch "/Users/<user>/Desktop/Claude/Archive Reader/.maintenance/STOP"`  (halts both drivers), and/or
- cancel the cron in the live session, and/or `launchctl bootout gui/$(id -u)/com.archivereader.autobuild`.
