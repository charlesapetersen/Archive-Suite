# Archive Suite — Agent / Concurrent-Development Guide

Umbrella conventions for working in this monorepo (solo or with multiple agents in parallel). Each app
also has its own `AGENTS.md` with app‑specific lanes — read it before working inside a subdir:
[`ArchiveProcessor/AGENTS.md`](ArchiveProcessor/AGENTS.md) · [`ArchiveReader/AGENTS.md`](ArchiveReader/AGENTS.md) · [`ArchiveNotes/CLAUDE.md`](ArchiveNotes/CLAUDE.md).

## Ground rules

- **Worktree-first — mandatory, not optional.** Before *any* edit/build/commit, be in your own git
  worktree; never work in the primary checkout, even if you think you're the only instance running. Run the
  idempotent first-step check in [`CLAUDE.md`](CLAUDE.md) → **"Worktree-first"** (it creates
  `../suite-wt-<stamp>` only if you're not already isolated, so it's safe to run every session). Per‑worktree
  DerivedData (`-derivedDataPath ./build/DD`, already the default in each `launch.sh`) keeps parallel builds
  from colliding. **Remove your worktree once your work is pushed** so they don't pile up for the owner.
  **Only ever touch worktrees you created.** In particular, **ignore the Codex worktree**
  (`~/Documents/GPT/archive-suite-processor-fixes`, branch `wt/codex-processor-bugfixes-*`) — it belongs to a
  different agent (Codex) and often carries uncommitted WIP. Never clean it up, remove it, salvage it, or
  report it to the owner as a stray; leave it entirely alone (owner instruction 2026-07-16).
- **After any pull/switch, `xcodegen generate`** (or the app's `bootstrap.sh`) — the `.xcodeproj` is gitignored.
- **Stay in your lane.** A change scoped to one app touches only that subdir. Loading the *other* app is
  almost always unnecessary (see the token‑efficiency directive in [`CLAUDE.md`](CLAUDE.md)).
- **Never** write to a real corpus during dev/test (copy to scratchpad); **never** add a tag‑write call
  outside Reader's audited `TagWriter`, or any move/rename/delete/content‑write call anywhere.
- **Done = code + docs in the *same commit*.** Ship a `SUITE_TODO.md` item → flip its checkbox (cite the
  commit); fix/find a bug → update `KNOWN_ISSUES.md`; ship an `execution-plans/` plan → delete it.
  `SUITE_TODO.md` is the tracker of record — an unattended run reconciles it *before ending*, never leaning
  on a private plan file. The owner shouldn't have to catch a stale tracker. (Full rule:
  [`CLAUDE.md`](CLAUDE.md) → "Docs & backlog convention.")

## Ownership lanes (safe to run in parallel)

| Lane | Territory |
|------|-----------|
| **reader** | `ArchiveReader/` — views, navigation, tag editing (via `TagWriter`), content index |
| **processor-macOS** | `ArchiveProcessor/macOS/` — OCR pipeline, tagging, review flows, capture server |
| **processor-iOS** | `ArchiveProcessor/ArchiveCaptureiOS/` — iPhone capture companion |
| **processor-android** | `ArchiveProcessor/ArchiveCapture/` — Android capture companion |
| **notes** | `ArchiveNotes/` — note/extract store, editor, index, cross-app linking, Zotero |
| **suite** | root docs, `SPEC/`, `release/`, `launch.sh` dispatcher |

## Shared hotspots — coordinate before editing

- **`SPEC/tag-format.md`** — the tag/PDF contract. A change here means the Processor *writer* and Reader
  *reader/editor* both change, together, in one reviewed unit. Highest‑risk shared surface.
- **`packages/ArchiveCore/`** — the shared read-side contract (tags, PDF, durable links, suite marker).
  Cross-app surface: changes here affect Reader, Processor, and Notes.
- **Each app's `project.yml`** — the XcodeGen source of truth (schemes, targets, entitlements).
- **`release/build-suite-dmg.sh`** — the single build/packaging path.
- **Processor's phone↔Mac Live‑Capture protocol** and its append‑only `ProviderModels` enums — see
  `ArchiveProcessor/AGENTS.md`.

## Verification

Build‑verify the app(s) you touched before merging to `main`:
`cd <app>/macOS && xcodegen generate && xcodebuild -scheme <App> -configuration Debug -derivedDataPath ./build/DD build`.
Run the app's tests where present (Reader has an XCTest bundle + `scripts/lint-write-surface.sh`;
Processor has `scripts/test-smoke.sh` / `test-tier2.sh`, plus `scripts/e2e-phone-mac.sh` — the full
phone↔Mac round-trip E2E on the emulator, the functional test for `Capture/`/`Net/` changes). Tag‑write
changes are Tier‑2 (adversarial review + tests on scratch copies).

### GUI verification — you can drive it yourself; don't punt it to the owner

**All the TCC grants are in place (verified 2026-07-16): Screen Recording, Accessibility, and Automation** —
plus `cliclick` at `/opt/homebrew/bin/cliclick`, and the Processor's Keychain **"Always Allow" is seeded** so
its GUI launches unattended. Quick self-check: `screencapture -x /tmp/x.png` writes a non-empty file, and
`osascript -e 'tell application "System Events" to return name of first process whose frontmost is true'`
returns the frontmost app.

So **a session can launch, drive, and screenshot any of the three apps itself.** Triage a GUI check before
asking the owner for anything:

| What you're verifying | How |
|---|---|
| A control **exists / is wired** ("is the toggle there?", "is it bound to the right key?") | **Read the code** — a grep. Never an owner question. |
| It **renders / behaves** (layout, interaction, a bug repro) | **Drive it yourself**: `./launch.sh reader\|processor\|notes` from your worktree, `cliclick` for pointer input, `osascript` System Events for keys/menus, `screencapture` → **read the shot**. |
| **Subjective taste** (does this look right?), an **API key**, or an **account/device** action | Genuinely owner-only — ask. |

Rules while driving: point the app at a **scratch copy, never the real corpus** (choosing a folder clobbers the
owner's root bookmark — see the Reader Core Directive), and quit the app when done
(`osascript -e 'quit app "ArchiveReader"'`). If a check truly can't be driven, say *why* — don't assert "GUI
blocked" as a blanket reason; that claim was stale for a long time and cost the owner a lot of pointless
eyeballing.
