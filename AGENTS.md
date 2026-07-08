# Archive Suite — Agent / Concurrent-Development Guide

Umbrella conventions for working in this monorepo (solo or with multiple agents in parallel). Each app
also has its own `AGENTS.md` with app‑specific lanes — read it before working inside a subdir:
[`ArchiveProcessor/AGENTS.md`](ArchiveProcessor/AGENTS.md) · [`ArchiveReader/AGENTS.md`](ArchiveReader/AGENTS.md).

## Ground rules

- **Worktree-first — mandatory, not optional.** Before *any* edit/build/commit, be in your own git
  worktree; never work in the primary checkout, even if you think you're the only instance running. Run the
  idempotent first-step check in [`CLAUDE.md`](CLAUDE.md) → **"Worktree-first"** (it creates
  `../suite-wt-<stamp>` only if you're not already isolated, so it's safe to run every session). Per‑worktree
  DerivedData (`-derivedDataPath ./build/DD`, already the default in each `launch.sh`) keeps parallel builds
  from colliding. **Remove your worktree once your work is pushed** so they don't pile up for the owner.
- **After any pull/switch, `xcodegen generate`** (or the app's `bootstrap.sh`) — the `.xcodeproj` is gitignored.
- **Stay in your lane.** A change scoped to one app touches only that subdir. Loading the *other* app is
  almost always unnecessary (see the token‑efficiency directive in [`CLAUDE.md`](CLAUDE.md)).
- **Never** write to a real corpus during dev/test (copy to scratchpad); **never** add a tag‑write call
  outside Reader's audited `TagWriter`, or any move/rename/delete/content‑write call anywhere.

## Ownership lanes (safe to run in parallel)

| Lane | Territory |
|------|-----------|
| **reader** | `ArchiveReader/` — views, navigation, tag editing (via `TagWriter`), content index |
| **processor-macOS** | `ArchiveProcessor/ArchiveProcessor/` — OCR pipeline, tagging, review flows, capture server |
| **processor-iOS** | `ArchiveProcessor/ArchiveCaptureiOS/` — iPhone capture companion |
| **processor-android** | `ArchiveProcessor/ArchiveCapture/` — Android capture companion |
| **suite** | root docs, `SPEC/`, `release/`, `launch.sh` dispatcher |

## Shared hotspots — coordinate before editing

- **`SPEC/tag-format.md`** — the tag/PDF contract. A change here means the Processor *writer* and Reader
  *reader/editor* both change, together, in one reviewed unit. Highest‑risk shared surface.
- **Each app's `project.yml`** — the XcodeGen source of truth (schemes, targets, entitlements).
- **`release/build-suite-dmg.sh`** — the single build/packaging path.
- **Processor's phone↔Mac Live‑Capture protocol** and its append‑only `ProviderModels` enums — see
  `ArchiveProcessor/AGENTS.md`.

## Verification

Build‑verify the app(s) you touched before merging to `main`:
`cd <app>/<App> && xcodegen generate && xcodebuild -scheme <App> -configuration Debug -derivedDataPath ./build/DD build`.
Run the app's tests where present (Reader has an XCTest bundle + `scripts/lint-write-surface.sh`;
Processor has `scripts/test-smoke.sh` / `test-tier2.sh`). Tag‑write changes are Tier‑2 (adversarial
review + tests on scratch copies).
