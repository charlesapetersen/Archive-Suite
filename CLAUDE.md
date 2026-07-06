# Archive Suite — Umbrella Project Guide

Two native macOS apps in one monorepo: **Archive Processor** (capture · OCR · tag) and
**Archive Reader** (find · read · triage). This file is the *umbrella* guide — repo‑wide conventions,
the shared contract, and the release process. **Each app's own `CLAUDE.md` stays authoritative for
that app**; read it before working inside a subdirectory:

- [`ArchiveProcessor/CLAUDE.md`](ArchiveProcessor/CLAUDE.md) — the Processor + its iOS/Android capture companions.
- [`ArchiveReader/CLAUDE.md`](ArchiveReader/CLAUDE.md) — the Reader (incl. its bulletproof file‑safety Core Directive).

## Repo map

```
Archive-Suite/
├── SPEC/tag-format.md      # THE shared tag/PDF contract — single source of truth for both apps
├── release/                # suite-level release tooling (combined DMG)
├── launch.sh               # dispatcher → ./launch.sh reader|processor
├── ArchiveProcessor/       # outer = relocated app repo;  inner ArchiveProcessor/ = its XcodeGen project dir
│   ├── ArchiveProcessor/   #   project.yml (authoritative), Sources/, generated .xcodeproj (gitignored)
│   ├── ArchiveCapture/     #   Android capture companion
│   └── ArchiveCaptureiOS/  #   iOS capture companion
└── ArchiveReader/          # outer = relocated app repo;  inner ArchiveReader/ = its XcodeGen project dir
    └── ArchiveReader/      #   project.yml, Sources/, Tests/, generated .xcodeproj (gitignored)
```

**The double‑naming** (`ArchiveReader/ArchiveReader/`, `ArchiveProcessor/ArchiveProcessor/`) is a
harmless byproduct of the merge — outer = the app's dir, inner = that app's XcodeGen project dir. Each
app's `launch.sh`/`bootstrap.sh` use paths relative to themselves, so it's cosmetic only. It can be
flattened later as a separate, per‑app, build‑verified cleanup (see `SUITE_MERGE_PLAN.md` §Target
structure); not worth touching now.

## The shared contract is the risk

The two apps are coupled by exactly one thing: the **Finder‑tag vocabulary + 2‑page PDF format** the
Processor writes and the Reader reads. A silent divergence there could corrupt or mis‑read
irreplaceable data. That contract lives, authoritatively, in [`SPEC/tag-format.md`](SPEC/tag-format.md)
— **any change to how tags/dates/priority/color/classification are written or parsed must update both
apps and that spec together**, and is Tier‑2 (adversarial review + tests on scratch copies, never the
real corpus).

## Conventions

- **Build:** XcodeGen. `project.yml` is authoritative; the `.xcodeproj` is generated and **gitignored**
  — always `xcodegen generate` (or run the app's `bootstrap.sh`) after cloning/pulling. `brew install xcodegen`, Xcode 16, macOS 14+, Swift 6.
- **Run:** `./launch.sh reader|processor` from the root (build‑if‑stale, then launch), or `cd <app> && ./launch.sh`.
- **Per‑worktree DerivedData** (`-derivedDataPath ./build/DD`) so concurrent agents/worktrees don't collide. `build/` is gitignored.
- **Two apps, two bundle IDs** (`com.archiveprocessor.app`, `com.archivereader.app`) — never merged. Both are ad‑hoc signed (`CODE_SIGN_IDENTITY "-"`), not notarized.
- **Never** hand‑edit a `.pbxproj` (edit `project.yml` + regenerate). **Never** write to a real corpus during dev/test — copy to the scratchpad first (Reader's Core Directive).

## Working directive — token-efficient feature-add & maintenance

Treat context/token cost as a real budget alongside speed and correctness. Applies to every change in
this repo:

- **Right-size agents.** Delegate broad searches / multi‑file sweeps / independent authoring to
  subagents so the main thread keeps the *conclusion*, not file dumps. Don't spawn an agent (or re‑run
  a search you already delegated) for a single known‑location lookup. **Big `Workflow` fan‑outs are the
  biggest token sink** — scope them tightly, size the fleet to the remaining budget, and prefer
  accumulating heavy multi‑agent jobs (adversarial reviews, wide audits) to run **overnight/unattended**
  rather than firing them inline while interactive.
- **Read narrowly.** Scoped reads, `grep`/Explore to locate, `git log -- <path>` scoped to a subdir.
  Don't load whole files, or the *other* app, when a change touches one.
- **Structure shrinks context.** Per‑app `CLAUDE.md` with a tight **Implementation Map**, small
  single‑purpose files, ownership lanes (see `AGENTS.md`), and one shared spec mean a change loads
  *one app + one spec*, not the whole repo.
- **DRY docs & tooling.** Umbrella‑plus‑per‑app docs with no duplicated prose; one shared launch path.
- **Batch & cache.** Independent tool calls together; surgical `Edit`s over full rewrites.
- **Guardrail:** efficiency never overrides correctness or the Reader Prime Directive (file safety).
  When they conflict, quality wins — but take the cheapest path that fully meets the bar.

## Releasing (the combined DMG)

- **Versioning (D3):** the **Suite** has its own release line, tagged **`suite-vMAJOR.MINOR.PATCH`**
  (starting `suite-v1.0.0`). Each app keeps its own independent internal version. *Note:* the bare
  `vX.Y.Z` tags in this repo are **Archive Processor's historical app tags** (v1.0.0–v3.8.2), carried
  in with its history — that's why Suite releases are `suite-`‑prefixed (a bare `v1.0.0` already exists).
- **Build + DMG:** `release/build-suite-dmg.sh <ver>` — Release‑builds both macOS apps, stages both
  `.app`s + one `Applications` symlink + the "drag both here" background, and produces
  `/tmp/ArchiveSuite-<ver>.dmg`. The `.dmg` is a build artifact — **never commit it**.
- **Publish:** `/opt/homebrew/bin/gh release create suite-v<ver> /tmp/ArchiveSuite-<ver>.dmg --repo charlesapetersen/Archive-Suite --title "Archive Suite <ver>" --notes "…"`.
  ⚠️ Use the **full path** `/opt/homebrew/bin/gh` — a shadowing Python tool named `gh` is first on PATH and fails.
- Cut DMG/GitHub releases sparingly; push commits frequently.

See [`SUITE_MERGE_PLAN.md`](SUITE_MERGE_PLAN.md) for how the two repos were merged (durable, resumable
record) and the deferred follow‑ups (shared `ArchiveCore` package; de‑nesting).
