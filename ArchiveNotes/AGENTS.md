# AGENTS.md — working on Archive Notes with multiple agents

Start with **[CLAUDE.md](CLAUDE.md)** — the authoritative app guide (Core Directive, stack & build,
the full Implementation Map). This file is the short version for coordinating **multiple concurrent
agents/instances**. Mirrors the sibling Processor's / Reader's process. The file-safety protocol for
tests + GUI drives lives in **[GUI_SAFETY.md](GUI_SAFETY.md)**.

## Golden rule
**Worktree-first, mandatory before any edit.** Be in your own git worktree; never work in the primary
checkout — **even if you think you're the only instance** (you can't know another won't start, and the
owner doesn't track worktrees). Two instances in one working directory clobber each other's uncommitted
edits and race the build cache. Suite-wide idempotent first-step check: root [`../CLAUDE.md`](../CLAUDE.md)
→ "Worktree-first". The commands below isolate a Notes worktree specifically.

```bash
git worktree add "../an-wt-<lane>" -b <branch>          # isolated checkout (paths have a space → quote)
cd "../an-wt-<lane>/ArchiveNotes" && xcodegen generate   # .xcodeproj is NOT committed — regenerate first
xcodebuild -scheme ArchiveNotes -configuration Debug -derivedDataPath ./build/DD build   # per-worktree DerivedData
git worktree remove "../an-wt-<lane>"                    # ./build is gitignored, won't block removal
```
Prereq: `brew install xcodegen` (or run `./bootstrap.sh` from the worktree root). `-derivedDataPath`
isolates DerivedData (not the shared user-level Clang cache) — treat it as "separate DerivedData per
worktree." Notes depends on the local `packages/ArchiveCore` Swift package.

## THE non-negotiable rule (this app writes to your notes — and can touch the corpus)
- **Only `Core/NotesTagProjector.swift` may write Finder tags**, and only onto a note's **own** `.md`
  file under `<store>/items/<uuid>/` (via `ArchiveCore.CoordinatedTagWriter`, component-boundary
  guarded). No other file may import or call a tag-write API. **No file may call a move / rename /
  delete / content-write API against the corpus** — corpus access is read-only (durable-link resolve +
  page render). Notes' own store writes (atomic `.md` save, assets, **Trash** delete) go only through
  the `NoteStore` actor.
- **Never test writes against the real store or a real corpus.** Build a scratch store first
  (`scripts/make-notes-fixture.sh` → `…/ArchiveNotes/AN-GUI-Fixture`, a *sibling* of the real `Store`).
  A DEBUG-only scratch-write guard in `NotesTagProjector` mechanically aborts any tag write outside
  scratch under a test / GUI-drive context — see [GUI_SAFETY.md](GUI_SAFETY.md).
- **Never drive the store picker** (File ▸ Choose Store Folder…) in a GUI run — it persists a bookmark
  over the owner's real `notesStoreRootBookmark`. Point the app at scratch via the DEBUG
  `-ANUITestStorePath` launch arg (in-memory only; never writes a bookmark).
- `NotesTagProjector`, `NoteStore` writes, `FrontMatterCodec`, and anything touching them are **Tier-2**
  (adversarial review + scratch-copy tests) on every change — see Verification below.

## Ownership lanes (one agent each)
- **Store/Index** — `Store/` + `Index/` — the on-disk store (`NoteStore` UUID-folder CRUD, atomic
  writes, assets, Trash delete), the disposable FTS5 cache (`NotesIndex`/`NotesIndexer`), the folder
  graph (`OrganizationStore`), and the `FrontMatterCodec`/`BlockParser` on-disk format.
- **Browse UI** — `Core/` + `Views/` — `NotesModel` (the `@MainActor` façade), `NotesNavigationModel`,
  the 3-pane browser, table, folder tree, filter bar, inspectors.
- **Editor** — `Editor/` — the Markdown editor (`MarkdownEditorView`, `EditorTextView`,
  `MarkdownBridge`, `NoteBodyEditorModel`, autosave/flush).
- **Links/Extracts** — `Links/` + `Sources/` + extract building — durable links, provenance
  source blocks, `ExtractBuilder`, `ReaderLinkResolver`.
- **Zotero** — `Zotero/` — reference/citation integration (all behind an injected transport).

## Shared hotspots — coordinate before editing
- **`Core/NotesTagProjector.swift`** — the single Finder-tag write surface; every change is Tier-2.
- **`ArchiveCore` public API** (`../packages/ArchiveCore`) — shared with Reader **and** Processor; a
  change there must build + test **all three** apps' test bundles (a non-exhaustive switch broke the
  Notes bundle once — see `KNOWN_ISSUES.md`).
- **The tag/PDF contract** — [`../SPEC/tag-format.md`](../SPEC/tag-format.md). Reader, Processor, and
  Notes must interpret tags/date facets/the `ArchiveSuite` marker identically; a divergence risks
  corrupting or mis-reading irreplaceable data.
- **The on-disk front-matter format** (`Store/FrontMatterCodec.swift`) — must round-trip losslessly
  (unknown keys preserved byte-for-byte); it *is* the durable note format.
- **`macOS/project.yml`** (never hand-edit `.pbxproj`; edit `project.yml` + `xcodegen generate`).

## Rules
- Never hand-edit `.pbxproj` — edit `project.yml` + `xcodegen generate` (required after clone too).
- Small commits, rebase often, **build-verify before committing** (no CI, no human reviewer).
- **Cadence: push commits often, release rarely.** Push to `origin` frequently — a clean build +
  self-review is enough; don't hoard local commits. A DMG + GitHub release is the sparse milestone.
- **Done = code + its docs in the *same commit*.** Flip the shipped `../SUITE_TODO.md` checkbox +
  update `KNOWN_ISSUES.md` as you go (root `../CLAUDE.md` → "Docs & backlog convention").
- Use `/opt/homebrew/bin/gh` for GitHub (bare `gh` is shadowed on this machine).

## Verification (tiered by risk — no human in the loop)
- **Tier 1 — every commit:** build clean, no new warnings; self-review the diff; `./test-smoke.sh notes`
  (build + unit suite; no network, no corpus).
- **Tier 2 — high-blast-radius (adversarial, any diff size):** anything touching `NotesTagProjector`,
  tag projection, `NoteStore` writes (atomic `.md`/assets/Trash delete), `FrontMatterCodec`, the
  `ArchiveCore` API, or `@MainActor`/actor/`Sendable` isolation → multi-agent *find → refute*
  adversarial review + a scratch-copy functional test. GUI verification uses the `ArchiveNotesUITests`
  harness on a scratch fixture ([`scripts/GUI-HARNESS.md`](scripts/GUI-HARNESS.md)); headless render
  truth (a PDF pane / thumbnail actually drew) via a render guard, per [CLAUDE.md](CLAUDE.md).
- **Tier 3 — before a release:** adversarial review of the whole accumulated diff + a live smoke test
  if the store-write / tag-projection / durable-link path changed.
- **Always adversarially *verify* a finding before acting on it** (default "not a bug" when uncertain).
