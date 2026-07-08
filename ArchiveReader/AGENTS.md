# AGENTS.md — working on Archive Reader with multiple agents

Start with **[CLAUDE.md](CLAUDE.md)** — the authoritative project guide (Core Directive, Verified
Facts, `TagWriter` Safety Protocol, architecture, Archive Suite plan). This file is the short version
for coordinating **multiple concurrent agents/instances**. Mirrors the sibling Archive Processor's
process.

## Golden rule
**Worktree-first, mandatory before any edit.** Be in your own git worktree; never work in the primary
checkout — **even if you think you're the only instance** (you can't know another won't start, and the
owner doesn't track worktrees). Two instances in one working directory clobber each other's uncommitted
edits and race the build cache. Suite-wide idempotent first-step check: root [`../CLAUDE.md`](../CLAUDE.md)
→ "Worktree-first". The commands below isolate a Reader worktree specifically.

```bash
git worktree add "../ar-wt-<lane>" -b <branch>              # isolated checkout (paths have a space → quote)
cd "../ar-wt-<lane>/ArchiveReader" && xcodegen generate     # .xcodeproj is NOT committed — regenerate first
xcodebuild -scheme ArchiveReader -configuration Debug -derivedDataPath ./build/DD build   # per-worktree DerivedData
git worktree remove "../ar-wt-<lane>"                        # ./build is gitignored, won't block removal
```
Prereq: `brew install xcodegen` (or run `./bootstrap.sh` from the worktree root). `-derivedDataPath`
isolates DerivedData (not the shared user-level Clang cache) — treat it as "separate DerivedData per
worktree."

## THE non-negotiable rule (this app writes to irreplaceable data)
- **Only `Core/TagWriter.swift` may write tags.** No other file may import or call a tag-write API
  (`setResourceValue(s)`, `setxattr`, …). **No file, not even `TagWriter`, may call a move / rename /
  delete / trash / content-write API** (`FileManager.removeItem/moveItem/trashItem/…`,
  `PDFDocument.write`, `Data.write`, `FileHandle` writes). A CI-style lint enforces this; the lint is
  one layer — the real guarantee is the isolation.
- **Never test tag writes against the real corpus.** Always copy files to the scratchpad first.
- `TagWriter` and anything touching it is **Tier-2** (adversarial review + scratch-copy tests) on
  every change — see Verification below.

## Ownership lanes (one agent each)
- **Core** — `Sources/ArchiveReader/Core/` — UI-free domain: tag facets, `TagWriter`, PDF/
  classification model, date parsing, file-link formatting. **Package-ready** (becomes `ArchiveCore`
  at suite convergence — keep it free of SwiftUI/AppKit imports).
- **Search/Index** — Spotlight (`NSMetadataQuery`) discovery + the SQLite FTS content index.
- **Nav UI** — the navigation window: table, filters, tag editor, copy-links, mark-read.
- **Doc UI** — the document window: two-up PDF viewer, zoom, splitter, intelligent copy, find.

## Shared hotspots — coordinate before editing
- **The tag/PDF contract** (`CLAUDE.md` → Verified Facts). Both Archive Reader and Archive Processor
  must interpret it identically; a divergence risks corrupting/mis-reading irreplaceable data.
- **`project.yml`** (never hand-edit `.pbxproj`; edit `project.yml` + `xcodegen generate`).
- **`Core/` public API** once it is extracted into the `ArchiveCore` package.

## Rules
- Never hand-edit `.pbxproj` — edit `project.yml` + `xcodegen generate` (required after clone too).
- Small commits, rebase often, **build-verify before committing** (no CI, no human reviewer).
- **Cadence: push commits often, release rarely.** Push to `origin` frequently — a clean build +
  self-review is enough; don't hoard local commits. A DMG + GitHub release is the sparse milestone.
- Use `/opt/homebrew/bin/gh` for GitHub (bare `gh` is shadowed on this machine).

## Verification (tiered by risk — no human in the loop)
- **Tier 1 — every commit:** build clean, no new warnings; self-review the diff.
- **Tier 2 — high-blast-radius (adversarial, any diff size):** anything touching `Core/TagWriter.swift`,
  tag reading/writing, bookmark resolution, the content-index writer, or `@MainActor`/`Sendable`
  isolation → multi-agent *find → refute* adversarial review + scratch-copy functional test.
- **Tier 3 — before a release:** adversarial review of the whole accumulated diff + a live smoke test
  if the tag/PDF/viewer path changed.
- **Always adversarially *verify* a finding before acting on it** (default "not a bug" when uncertain).
