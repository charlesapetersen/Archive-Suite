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

## Resilience protocol (against credit cutoffs)
- Commit after each buildable sub-step; keep the build GREEN at every commit.
- Update this file's **Current state** + **Next action** at the end of each work session.
- Prefer many small commits over one large uncommitted change; the git history is the durable record.
