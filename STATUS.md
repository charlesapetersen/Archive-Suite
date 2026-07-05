# STATUS — resume pointer

Single source of "where are we, what's next," kept current every work session so a fresh instance
(e.g. after a usage-credit cutoff) can resume immediately. **Read order:** CLAUDE.md → AGENTS.md →
PLAN.md → this file.

## Current state (2026-07-05)
- **Milestone:** **M0 COMPLETE** (safety core). Starting **M1** (navigation window).
- **Build:** GREEN.
  - `cd ArchiveReader && xcodegen generate && xcodebuild -scheme ArchiveReader -configuration Debug -derivedDataPath ./build/DD build` → **BUILD SUCCEEDED**
  - `xcodebuild -scheme ArchiveReader -destination 'platform=macOS' -derivedDataPath ./build/DD test` → **24/24 pass**
- **Done:**
  - Durable docs; repo scaffold; sandboxed XcodeGen two-window app.
  - Read-only Core: `DocumentTags`, `TagReading`, `FileLink`.
  - **`Core/TagWriter.swift`** — the single audited write choke-point: delta edits (add/remove/color),
    `NSFileCoordinator(.contentIndependentMetadataOnly)`, trustworthy-read guard, multiset+label
    verify, label-drift restore, inverse-delta undo, batch per-file results, Read/Unread fast path.
  - Tests: `DocumentTagsTests`, `FileLinkTests`, `TagWriterTests` (24 total). Tier-2 self-review done.

## Next action (M1 — navigation window)
1. Add a **write-surface lint** script (`scripts/lint-write-surface.sh`): grep app sources; fail if any
   tag-write API appears outside `TagWriter.swift` or any move/rename/delete/content-write API appears
   anywhere in the app target. Run before each commit.
2. **Spotlight discovery** (`Core/`, UI-free): an `NSMetadataQuery` wrapper scoped to a user-granted
   archive root (security-scoped bookmark), predicate `kMDItemUserTags == "Read" || == "Unread"`,
   returning items with tags + name + type + dates; live updates.
3. **Navigation table** (Views): columns Document date (from `DocumentTags.sortDate`, Date-Uncertain
   italic) · File name · File type · File tags · Read/Unread; multi-level sort (chronological→name);
   three filters (subject AND/OR · priority P7–P10 · read tri-state); copy links (⌘⇧C); mark Read/Unread
   via `TagWriter` with grouped undo; open selection (⌘O) → document window.
4. Perf-check the table at ~150k (abstract data layer so an AppKit `NSTableView` swap stays possible).
- Then M1.5 content index (full-text search), M2 doc viewer, M3 options, M4 + High-priority backlog.

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
