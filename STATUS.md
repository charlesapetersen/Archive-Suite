# STATUS — resume pointer

Single source of "where are we, what's next," kept current every work session so a fresh instance
(e.g. after a usage-credit cutoff) can resume immediately. **Read order:** CLAUDE.md → AGENTS.md →
PLAN.md → this file.

## Current state (2026-07-05)
- **Milestone:** **M0, M1, M1.5, M2 COMPLETE** (safety core + navigation window + content index/
  full-text search + two-up document viewer). The core reading app is functional. Starting **M3**.
- **Build:** GREEN. `xcodegen generate && xcodebuild … build` → **BUILD SUCCEEDED**;
  `xcodebuild … test` → **48/48 pass**; `bash scripts/lint-write-surface.sh` → clean.
- **Latest commits:** `f951711` M2 · `3dc8368` M2a · `45cf2e3` M1.5 · `2d8e9c7` M1 · `91c0afd` M0.
- **Added since M1:** `Core/CopyTextCleaner` (intelligent copy); `Search/{ContentIndex(SQLite FTS5),
  PDFTextExtractor, ContentIndexer}`; `Views/{PDFPaneView, DocumentViewerModel, DocumentWindowView}`;
  full-text search wired into the nav window.
- **⚠ Verification caveat:** the Core/logic layers are unit-tested (33), but the **SwiftUI GUI has not
  been driven at runtime** (headless env can't launch/interact with the sandboxed app, and nested
  `claude` is blocked). A manual GUI smoke test is pending: launch the app, choose the `Test files`
  folder as root, confirm the list populates, filters work, and mark-Read moves a row out of an
  Unread view. Treat GUI wiring as "compiles + logic-tested," not "runtime-verified."
- **Done:**
  - Durable docs; repo scaffold; sandboxed XcodeGen two-window app.
  - Read-only Core: `DocumentTags` (+displayDate), `TagReading`, `FileLink`, `ArchiveFile`,
    `LibraryFilter` (filter + multi-level nil-last sort).
  - **`Core/TagWriter.swift`** — single audited write choke-point (delta edits, coordinated
    metadata-only write, trustworthy-read guard, multiset+label verify, drift restore, inverse-delta
    undo, batch). `scripts/lint-write-surface.sh` enforces the write surface.
  - **M1 navigation window:** `Search/RootFolderStore` (security-scoped bookmark),
    `Search/ArchiveLibrary` (NSMetadataQuery discovery + optimistic updates),
    `Views/NavigationModel` + `Views/NavigationWindowView` (table, 3 filters, sort menu, copy-links,
    mark Read/Unread via TagWriter + undo, open selection; keyboard shortcuts).
  - Tests: DocumentTags, FileLink, TagWriter, LibrarySortFilter (33 total).

## Next action (M3 — Options panel + keymap + accessibility + data-quality)
1. **Options panel (⌘,)** — replace the `OptionsView` scaffold with real settings persisted via
   `@AppStorage`: link format + newlines-after-link (wire into `FileLinkFormatter`); copy behavior
   (`CopyTextOptions`: de-hyphenate, collapse-single-newlines, paragraph-on-blank, skip-OCR-header)
   → thread into `DocumentViewerModel.copyOptions`; default split ratio + per-pane default zoom;
   date display format; subject-combine default; read-state default; tag-editing prefs
   (near-dup warning, controlled vocab, large-group confirm threshold); archive-root management.
2. **Keyboard map** — finalize collision-free shortcuts (see PLAN.md §Keyboard); ensure nav digit
   type-select doesn't fight priority toggles.
3. **Accessibility** — honor Reduce Motion (instant row removal), VoiceOver announcements on
   mark-Read, deterministic focus after a batch leaves the view.
4. **Data-quality view** — counts of no-date / no-priority / Date-Uncertain / both-Read+Unread /
   unreadable, from the library.
- Then **M4** power features, then **High-priority** POTENTIAL_FEATURES only (skip Med/Low).
- **Still pending (not blocking):** the M1 **tag editor** (⌘I inspector: add/remove subjects, set
  date/priority/color for single + group via `TagWriter`) was specced but not yet built — do it in
  M3/M4. Perf-check nav Table at ~150k. Manual GUI smoke test (headless env can't drive the GUI).

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
