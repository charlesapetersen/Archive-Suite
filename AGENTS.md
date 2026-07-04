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
Prereq: `brew install xcodegen`. `-derivedDataPath` isolates DerivedData (not the shared user-level Clang cache) — treat it as "separate DerivedData per worktree."

## Ownership lanes (avoid two agents in one lane at once)
- **Android** — `ArchiveCapture/` (Gradle/Kotlin). Fully independent.
- **iPhone** — `ArchiveCaptureiOS/` (Swift 5). Independent except the phone↔Mac protocol.
- **macOS OCR core** — `Sources/ArchiveProcessor/{OCR, Models, Capture, Net}`.
- **macOS Views + Tagging** — `Sources/ArchiveProcessor/{Views, Tagging}`.

## Shared hotspots — coordinate before editing
- `Models/ProviderModels.swift` enums (`LLMProvider`, `TaggingMode`, `RotationMode`, …): **append cases only**; never renumber/reorder/change rawValues (Codable + persisted).
- Phone↔Mac protocol: `Net/CaptureServer.swift` ⇄ `ArchiveCaptureiOS/.../Net/MacClient.swift` (`/ping`, `/photo`, `/session/complete`, Bearer). Change both sides together.
- The two `project.yml` files.

## The two split classes (behavior-preserving refactor)
- `OCR/OCRProcessor.swift` holds **only stored state + member types**; methods are in `OCRProcessor+{Pipeline,OCR,Tagging,ReviewFlows}.swift`, types in `OCRProcessor+Types.swift`. New methods go in the extension matching their concern; **stored properties stay in `OCRProcessor.swift`**.
- `Views/OCRView.swift` is the main view; sheets/rows/diff are `OCRView+*.swift`.

## Rules
- Never hand-edit `.pbxproj` — edit `project.yml` + `xcodegen generate` (required after clone too).
- Small commits, rebase often, build-verify before committing (no CI).
- Releases: see **CLAUDE.md → Releasing** (use `/opt/homebrew/bin/gh`, not bare `gh`).
