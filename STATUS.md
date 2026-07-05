# STATUS — resume pointer

Single source of "where are we, what's next," kept current every work session so a fresh instance
(e.g. after a usage-credit cutoff) can resume immediately. **Read order:** CLAUDE.md → AGENTS.md →
PLAN.md → this file.

## Current state (2026-07-04)
- **Milestone:** M0 (safety core) — foundation laid; `TagWriter` not yet written.
- **Build:** GREEN.
  - `cd ArchiveReader && xcodegen generate && xcodebuild -scheme ArchiveReader -configuration Debug -derivedDataPath ./build/DD build` → **BUILD SUCCEEDED**
  - `xcodebuild -scheme ArchiveReader -destination 'platform=macOS' -derivedDataPath ./build/DD test` → **11/11 pass**
- **Done:**
  - Durable docs: CLAUDE.md, PLAN.md, README.md, AGENTS.md, KNOWN_ISSUES.md, POTENTIAL_FEATURES.md, STATUS.md.
  - Repo scaffold: .gitignore, bootstrap.sh, XcodeGen project (sandboxed), minimal two-window SwiftUI app.
  - Read-only Core: `DocumentTags` (facet parser), `TagReading` (safe read + trustworthy-read
    distinction), `FileLink` (link formatting). Tests: `DocumentTagsTests`, `FileLinkTests`.

## Next action
- **M0 — write `Core/TagWriter.swift`**: the single audited write choke-point implementing the full
  Safety Protocol (CLAUDE.md): delta edits (`add`/`remove`/color), coordinated metadata-only write,
  trustworthy-read guard, verify-by-reread (multiset + bytes), inverse-delta undo, color-drift
  restore, batch idempotence, audit ledger. Then scratch-copy integration tests + Tier-2 adversarial
  review. **NEVER test against the corpus — copy to scratchpad first.**
- After M0: M1 (Spotlight discovery + table + filters + copy-links + mark-read + tag editor).

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
