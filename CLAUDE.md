# Archive Suite — Umbrella Project Guide

Three native macOS apps in one monorepo: **Archive Processor** (capture · OCR · tag),
**Archive Reader** (find · read · triage), and **Archive Notes** (provenance‑first note‑taking from
archival sources). This file is the *umbrella* guide — repo‑wide conventions, the shared contract, and
the release process. **Each app's own `CLAUDE.md` stays authoritative for that app**; read it before
working inside a subdirectory:

- [`ArchiveProcessor/CLAUDE.md`](ArchiveProcessor/CLAUDE.md) — the Processor + its iOS/Android capture companions.
- [`ArchiveReader/CLAUDE.md`](ArchiveReader/CLAUDE.md) — the Reader (incl. its bulletproof file‑safety Core Directive).
- [`ArchiveNotes/CLAUDE.md`](ArchiveNotes/CLAUDE.md) — Notes (provenance‑first notes + extracts from archival PDFs).

## How we work — the loop for every change

The whole per-change checklist in one place, so no rule hides inside a longer section. Every change, in order:

1. **Isolate** — work in your own git worktree, never the primary checkout (→ *Worktree-first*, below).
2. **Build-verify** — clean build, **no new warnings**; run the touched app's smoke test.
3. **Review by risk** — Tier-2 (adversarial review + a functional test) for anything with **no undo**:
   `Capture/`·`Net/`, file-writing tag/output, manifest/finalize, actor isolation, or the tag/PDF SPEC.
   Full tiers + the phone↔Mac E2E gate: each app's `CLAUDE.md` → *Verification & review policy*. For a
   **full-codebase review**, use the paced method in [`REVIEW.md`](REVIEW.md) — one subsystem per session,
   lean fan-out, refute-verify; **never** one giant fan-out (it blows a usage window). Use the `/code-review`
   skill for the working diff.
4. **Docs move with the code — in the SAME commit** (→ *Docs & backlog convention*, below): flip the
   shipped `SUITE_TODO.md` checkbox, update `KNOWN_ISSUES.md`, delete a shipped `execution-plans/` plan.
   `SUITE_TODO.md` is the tracker of record; an unattended run reconciles it **before it ends**.
5. **Push often, release rarely** — a clean build + self-review is enough to push; a DMG/release is the
   sparse, Tier-3-gated milestone.
6. **Clean up** — remove your worktree once the work is pushed.

The sections below are the depth behind these steps. **The owner should never have to catch a skipped one**
(a doc-sync backstop hook enforces step 4 — see `.claude/hooks/`).

**Unattended / autonomous runs** follow the same loop, one bounded item per fresh session, off a durable plan
that survives usage cutoffs — see [`ops/autonomous/README.md`](ops/autonomous/README.md) (L0 durable plan → L1
self-resume daemon → L2 resume prompt), with the paced review in [`REVIEW.md`](REVIEW.md). Never run such a
session with `--dangerously-skip-permissions`; use `--permission-mode default` + a scoped allow/deny list.

## Worktree-first — mandatory before any edit (every agent & instance)

**Before you edit, build, or commit anything in this repo, be in your own dedicated git worktree — never
work directly in this primary checkout.** This is *unconditional*: do it even if you believe you are the
only instance running. You cannot know that another instance or subagent won't start in parallel, and
**the owner does not track worktrees** — so the only coordination-free way to stop parallel instances from
clobbering each other's uncommitted edits and racing the build cache is that *nobody* works in the primary
checkout. (A pure read-only / question-answering session that changes nothing is the only exception — don't
spin up a worktree just to answer a question.)

**Make this your first step — it's idempotent, so it's safe to run at the start of every session:**
```bash
# Run from the checkout you were launched in. Creates a worktree ONLY if you're not already in one.
if [ "$(git rev-parse --git-dir)" = "$(git rev-parse --git-common-dir)" ]; then
  stamp="$(date +%Y%m%d-%H%M%S)-$$"
  git worktree add "../suite-wt-$stamp" -b "wt/<task-slug>-$stamp"   # repo path has a space → keep quotes
  cd "../suite-wt-$stamp"
else
  echo "Already isolated in $(git rev-parse --show-toplevel) — keep working here."
fi
```
Then do **all** edits, builds, and commits from that worktree (use its absolute paths for Read/Edit/Write),
and run `xcodegen generate` there before building (the `.xcodeproj` is gitignored). Push as normal — every
worktree shares one `origin/main`. **When your task is pushed, remove your own worktree** so they don't pile
up for the owner: from the primary checkout, `git worktree remove "../suite-wt-…"` (`./build` is gitignored,
so it won't block); `git worktree list` / `git worktree prune` clear strays.

**Subagents that write files** must be isolated the same way — pass `isolation: "worktree"` to the Agent
tool (or `{isolation: 'worktree'}` on a `Workflow` `agent()` call) so each gets its own scratch worktree
instead of racing in yours.

Ownership lanes, per-app build commands, and shared hotspots: [`AGENTS.md`](AGENTS.md).

## Repo map

```
Archive-Suite/
├── SPEC/tag-format.md      # THE shared tag/PDF contract — single source of truth for all apps
├── packages/ArchiveCore/   # shared Swift package (tags, PDF, durable links, suite marker)
├── release/                # suite-level release tooling (combined DMG)
├── launch.sh               # dispatcher → ./launch.sh reader|processor|notes
├── ArchiveProcessor/       # outer = relocated app repo
│   ├── macOS/              #   XcodeGen project dir: project.yml (authoritative), Sources/, generated .xcodeproj (gitignored)
│   ├── ArchiveCapture/     #   Android capture companion
│   └── ArchiveCaptureiOS/  #   iOS capture companion
├── ArchiveReader/          # outer = relocated app repo
│   └── macOS/              #   XcodeGen project dir: project.yml, Sources/, Tests/, generated .xcodeproj (gitignored)
└── ArchiveNotes/           # provenance-first note-taking app
    └── macOS/              #   XcodeGen project dir: project.yml, Sources/, Tests/, generated .xcodeproj (gitignored)
```

The inner XcodeGen project dirs are named `macOS/` (de-nested from the old `App/App/` layout that
was a byproduct of the repo merge). Each app's `launch.sh`/`bootstrap.sh` use paths relative to
themselves.

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
- **Three apps, three bundle IDs** (`com.archiveprocessor.app`, `com.archivereader.app`, `com.archivenotes.app`) — never merged. All are ad‑hoc signed (`CODE_SIGN_IDENTITY "-"`), not notarized.
- **Never** hand‑edit a `.pbxproj` (edit `project.yml` + regenerate). **Never** write to a real corpus during dev/test — copy to the scratchpad first (Reader's Core Directive).

## Docs & backlog convention

**Definition of done — the docs move with the code, in the *same commit* (never a follow-up).** A change is
not done until the trackers match reality:
- flip the shipped item's `SUITE_TODO.md` checkbox to `[x]` (cite the commit) and add/close any
  `KNOWN_ISSUES.md` entry — **in the same commit as the code**, not "later";
- delete a shipped `execution-plans/` plan.

`SUITE_TODO.md` is the **tracker of record.** An unattended/autonomous run must **reconcile it before it
ends**; a private plan/progress file (e.g. an overnight plan) never stands in for it — sync the real
tracker, not just your scratch notes. **The owner should never have to catch a stale checkbox** — doc-sync
is part of the change, full stop.

Three tiers, so nothing sprawls or goes stale:
- **Near-term work → `SUITE_TODO.md`** (root) — the single live to-do queue; it also **indexes the active execution plans** (below).
- **Long-term ideas → each app's `POTENTIAL_FEATURES.md`** — the durable wishlist tier.
- **Short-term execution plans → `execution-plans/`** (root) — one detailed plan per in-flight feature, tracked from `SUITE_TODO.md`; **delete a plan once its feature ships** (git keeps the history). Don't let shipped plans linger.

Reference/authoritative material lives in each app's `CLAUDE.md` (with an **Implementation Map**), `README.md`, `AGENTS.md`, `KNOWN_ISSUES.md`, and test procedures; canonical cross-app contracts live in `SPEC/` (`tag-format.md`, `relay-object-format.md`). Don't keep a doc "just because" — fold durable bits into these and drop the rest. Untracked scratch docs that are done/superseded (e.g. completed-run review reports) are archived under the gitignored **`old/`** folder (see `old/README.md`) rather than deleted — recoverable, out of the way.

## Working directive — token-efficient feature-add & maintenance

Treat context/token cost as a real budget alongside speed and correctness. Applies to every change in
this repo:

- **Right-size agents.** Delegate broad searches / multi‑file sweeps / independent authoring to
  subagents so the main thread keeps the *conclusion*, not file dumps. Don't spawn an agent (or re‑run
  a search you already delegated) for a single known‑location lookup. **Big `Workflow` fan‑outs are the
  biggest token sink** — scope them tightly, size the fleet to the remaining budget, and prefer
  accumulating heavy multi‑agent jobs (adversarial reviews, wide audits) to run **autonomous/unattended**
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
- **Build + DMG:** `release/build-suite-dmg.sh <ver>` — Release‑builds all three macOS apps, stages
  all `.app`s + one `Applications` symlink + the "drag here" background, and produces
  `/tmp/ArchiveSuite-<ver>.dmg`. The `.dmg` is a build artifact — **never commit it**.
- **Publish:** `/opt/homebrew/bin/gh release create suite-v<ver> /tmp/ArchiveSuite-<ver>.dmg --repo charlesapetersen/Archive-Suite --title "Archive Suite <ver>" --notes "…"`.
  ⚠️ Use the **full path** `/opt/homebrew/bin/gh` — a shadowing Python tool named `gh` is first on PATH and fails.
- Cut DMG/GitHub releases sparingly; push commits frequently.

The two repos were merged into this monorepo and Archive Suite v1.0.0 shipped (see `git log` for the
record). De‑nesting shipped (`7706368`); `packages/ArchiveCore` shipped in the W0 refactor
(`49c0162`–`b90800f`); Archive Notes scaffolding is in progress.
