# Archive Notes

A native macOS app for **provenance-first note-taking** from archival sources. Built for historians
and archivists who read documents in [**Archive Reader**](../ArchiveReader) (its sibling) and want to
write notes and extracts that link *durably* back to the exact page they came from. The third app in
**Archive Suite** (this monorepo).

Archive Notes is the *think & write* companion to the Processor's *capture & tag* and the Reader's
*find & read*: take notes and build extracts from archival PDFs, keep a durable link to the source
page (survives a computer move), attach Zotero references, organize with folders / smart folders /
replication, and search everything full-text — designed to stay fast at **100,000 notes / 2 million
words**.

## Prime directive — file safety

- Archive Notes writes **only its own store** (UUID-folder Markdown + assets under
  `~/Library/Application Support/ArchiveNotes/`). The archive **corpus is read-only** — durable-link
  resolution and page rendering only; never a tag write, move, rename, or delete on a corpus file.
- The **only** Finder-tag writer is `NotesTagProjector`, which mirrors a note's front-matter subjects
  and canonical Quality (`Q1`–`Q3`; 0/unrated has no Q tag) onto that note's **own** `.md` file via
  `ArchiveCore.CoordinatedTagWriter` — never onto corpus PDFs.
- Never test against the real store or corpus — scratch/`mktemp`/`TESTOUT` output only. Full protocol:
  [GUI_SAFETY.md](GUI_SAFETY.md).

## What it does

> **Status:** W0–W8 shipped — the app is built and **data-safe** (all five tag-safety invariants, the
> delete-last-instance guard, atomic writes, and autosave/flush are verified). A post-ship
> **gap-closure** pass (`../execution-plans/archive-notes/09-gap-closure.md`) is wiring the last
> built-but-unexposed features. [CLAUDE.md](CLAUDE.md) is the authoritative record.

- **Notes** — a note is a single Markdown file with a title, date, author, quality rating, and
  subjects, all in durable YAML front-matter. Styled editor with a raw-Markdown toggle (⌘/).
- **Provenance** — paste a page/document link copied from Archive Reader to drop a **source block**
  with a chip that jumps back to (and previews) the exact source; links are GUID-based, so they
  survive the corpus moving to another computer (one re-grant).
- **Extracts** — build an extract from selected passages across notes; each extract carries its own
  title/date/author and an embedded, snapshot-independent copy of the source passage's bytes.
- **Zotero** — attach Zotero reference links and citation metadata to a note.
- **Organize** — a mutable folder tree, **smart folders** (saved searches), and **replication** (one
  note in many folders as memberships, never copies) with a delete-last-instance guard. Templates
  per folder.
- **Search** — full-text (SQLite FTS5, bm25-ranked, as-you-type) across titles, bodies, authors, and
  subjects; filter by kind / quality / date range / tags.
- Two windows (**Notes** and **Extracts**), a virtualized list that stays smooth at scale, and
  keyboard-driven editing.

## Building

Prereq: Xcode 16+ (macOS 14+ target), `brew install xcodegen`. The `.xcodeproj` is **generated** by
XcodeGen and not committed — run bootstrap first:

```bash
./bootstrap.sh            # installs XcodeGen if needed, generates the project
open macOS/ArchiveNotes.xcodeproj
```

Headless build / CI check:

```bash
cd macOS && xcodegen generate && \
  xcodebuild -scheme ArchiveNotes -configuration Debug -derivedDataPath ./build/DD build
```

Regenerate with `xcodegen generate` whenever files are added — `project.yml` is authoritative; never
hand-edit the `.pbxproj`.

## Running & testing

```bash
./launch.sh notes         # from the repo root (build-if-stale, then launch)
cd ArchiveNotes && ./launch.sh   # …or from this app dir

./test-smoke.sh notes     # from the repo root — build + unit suite (no network, no corpus)
cd ArchiveNotes && ./test-smoke.sh
```

GUI verification uses the XCUITest harness (`ArchiveNotesUITests`) with a scratch fixture built by
[`scripts/make-notes-fixture.sh`](scripts/make-notes-fixture.sh) — its default generates the embedded
Reader PDFs and does not require any corpus — and driven by
[`scripts/gui-drive-notes.sh`](scripts/gui-drive-notes.sh) — see
[`scripts/GUI-HARNESS.md`](scripts/GUI-HARNESS.md). It is deliberately opt-in (off-screen via
`ops/gui/vm-gui-runner.sh notes xcuitest`), never part of the `ArchiveNotesUnit` smoke scheme. The
durable-link scenario has a build-free proof,
[`scripts/e2e-durable-links.sh`](scripts/e2e-durable-links.sh). **Never point any of these at the real
store or corpus** — [GUI_SAFETY.md](GUI_SAFETY.md).

## Project docs

- [CLAUDE.md](CLAUDE.md) — authoritative app guide: Core Directive, stack & build, the full
  Implementation Map.
- [AGENTS.md](AGENTS.md) — multi-agent / worktree workflow, ownership lanes, and verification policy.
- [GUI_SAFETY.md](GUI_SAFETY.md) — the test/GUI file-safety protocol (the one write surface,
  scratch-only rules, the DEBUG scratch-write guard).
- [SMOKE_TEST.md](SMOKE_TEST.md) — the manual/driven GUI smoke-test procedure and record.
- [KNOWN_ISSUES.md](KNOWN_ISSUES.md).

## Architecture (short)

Swift 6 · SwiftUI (+ AppKit where needed) · PDFKit · system SQLite FTS5 (no third-party deps) ·
XcodeGen build · sandboxed to a user-granted store root (security-scoped bookmark). Depends on the
shared [`ArchiveCore`](../packages/ArchiveCore) package for tags, PDF parsing, durable links, and the
suite marker. The store is a set of UUID-folder Markdown notes (`NoteStore`), indexed into a
disposable FTS5 cache (`NotesIndex`); folders/memberships/templates live in an
`OrganizationStore` graph; `NotesTagProjector` is the single audited Finder-tag write surface. Domain
logic stays UI-free so the safety-critical write path is testable in isolation.
