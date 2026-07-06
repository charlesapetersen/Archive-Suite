# AGENTS.md — working on Archive Processor with multiple agents

Start with **[CLAUDE.md](CLAUDE.md)** — it's the authoritative project guide. This file is the short version for coordinating **multiple concurrent agents/instances**.

## Golden rule
**One git worktree per agent.** Never run two instances in the same working directory — they clobber each other's uncommitted edits and race on the build cache.

```bash
git worktree add "../ap-wt-<lane>" -b <branch>          # isolated checkout (paths have a space → quote)
cd "../ap-wt-<lane>/ArchiveProcessor" && xcodegen generate   # .xcodeproj is NOT committed — regenerate first
xcodebuild -scheme ArchiveProcessor -configuration Debug -derivedDataPath ./build/DD build   # per-worktree DerivedData
git worktree remove "../ap-wt-<lane>"                   # ./build is gitignored, so it won't block removal
```
Prereq: `brew install xcodegen` (or just run `./bootstrap.sh` from the worktree root — it installs XcodeGen if missing and regenerates every project). `-derivedDataPath` isolates DerivedData (not the shared user-level Clang cache) — treat it as "separate DerivedData per worktree."

## Lanes, hotspots & split classes (quick reference)
The **authoritative, detailed** versions — ownership lanes, the shared hotspots, and the `OCRProcessor` /
`OCRView` split-class rules — live in **[CLAUDE.md](CLAUDE.md) → "Concurrent / multi-agent development."**
Kept here as a glance so this file stands alone; edit the detail in CLAUDE.md, not here.
- **Lanes** (one agent each): Android `ArchiveCapture/` · iPhone `ArchiveCaptureiOS/` · macOS OCR core `Sources/ArchiveProcessor/{OCR,Models,Capture,Net}` · macOS Views+Tagging `Sources/ArchiveProcessor/{Views,Tagging}`.
- **Coordinate before editing:** the `ProviderModels.swift` persisted enums (all `String`-backed — never rename a case or change an explicit rawValue string; appending is safe, reordering is harmless); the phone↔Mac protocol (`Net/CaptureServer.swift` ⇄ iOS `Net/MacClient.swift` — change both sides); the two `project.yml` files.
- **Split classes:** `OCRProcessor.swift` = stored state only (methods in `OCRProcessor+*.swift`, types in `+Types.swift`); `OCRView.swift` = main view (sheets/rows/diff in `OCRView+*.swift`).

## Rules
- Never hand-edit `.pbxproj` — edit `project.yml` + `xcodegen generate` (required after clone too).
- Small commits, rebase often, build-verify before committing (no CI).
- **Cadence: push commits often, release rarely.** Push to `origin` frequently — a clean build + self-review
  is enough; don't hoard local commits. A DMG + GitHub release is the sparse milestone (see below).
- **Review tiered by risk** (no human reviewer): every commit builds clean + self-review; high-blast-radius
  changes (`Capture/`, `Net/`, file-writing tag/output, manifest persistence, actor isolation) get an
  *adversarial* multi-agent review; the **pre-release** batch gets a full find→refute review + live smoke test.
  Full policy: **CLAUDE.md → "Verification & review policy (no human in the loop)."**
- Releases: see **CLAUDE.md → Releasing** (use `/opt/homebrew/bin/gh`, not bare `gh`).
