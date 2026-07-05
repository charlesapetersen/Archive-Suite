# STATUS — resume pointer

Single source of "where are we, what's next," kept current every work session so a fresh instance
(e.g. after a usage-credit cutoff) can resume immediately. **Read order:** CLAUDE.md → AGENTS.md →
PLAN.md → this file.

## Current state (2026-07-05)
- **Milestone:** M0 + **M1 COMPLETE** (safety core + navigation window). Starting **M1.5** (content index).
- **Build:** GREEN. `xcodegen generate && xcodebuild … build` → **BUILD SUCCEEDED**;
  `xcodebuild … test` → **33/33 pass**; `bash scripts/lint-write-surface.sh` → clean.
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

## Next action (M1.5 — content index + full-text search)
1. **Content index** in `Search/` (or `Core/`): a background extractor that, per file in the library,
   opens the PDF with PDFKit, extracts page-2 (and page-1 if present) text + the `Classification:`
   line + header metadata, and stores it in a **system SQLite FTS5** DB (`libsqlite3`, no third-party
   dep) under Application Support — a disposable, rebuildable cache keyed by path + content-mod-date.
   Incremental (skip unchanged). Run off the main actor; show progress.
2. **Full-text search** wired into `LibraryFilter`/the nav window: a query box that AND-combines an
   FTS match (returns matching file paths) with the existing tag facet filters. In-document ⌘F comes
   with M2's viewer.
3. Keep it UI-free where possible; guard non-2-page/corrupt/non-PDF (extractor must not crash).
- Then M2 doc viewer, M3 options/keymap/accessibility, M4 + High-priority backlog.
- **Also pending:** perf-check the nav Table at ~150k (data layer is abstracted; AppKit NSTableView
  swap stays possible) and the manual GUI smoke test noted above.

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
