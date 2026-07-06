# Archive Reader

A native macOS app for **reading and triaging** large collections of historical-document PDFs that
were OCR'd and tagged by [**Archive Processor**](../Archive%20Processor) (its sibling). Built for
historians and archivists working through thousands of scanned documents.

Archive Reader is the *reading & triage* companion to Archive Processor's *capture & tagging*: find
tagged PDFs, list them in chronological order, filter by subject / priority / read-state, search the
OCR text, read them two-up (image + OCR text), copy text and file links, edit tags, and mark
documents Read as you go. The two apps will eventually converge as **Archive Suite**.

## Prime directive — the files are irreplaceable

Archival images cannot be re-shot and their tagging was extremely time-consuming. Archive Reader
**never deletes, moves, renames, or alters any file's bytes or location.** The *only* thing it ever
changes is a file's **macOS Finder tags** — and only as a deliberate, verified, reversible user
action routed through a single audited writer. See [CLAUDE.md](CLAUDE.md) → Core Directive & Safety
Protocol.

## What it does

> **Status (2026-07-05):** v1 feature-complete — all planned milestones + the High-priority backlog
> are shipped; 75 tests pass; a full adversarial code review is done. One gap: a manual GUI smoke
> test (the logic is unit-tested; the SwiftUI GUI hasn't been driven at runtime yet). (Historical
> status snapshots are archived under `docs/archive/ArchiveReader/STATUS.md`.)


- **Find** every PDF tagged `Read`/`Unread` under your archive root, via Spotlight — fast at 150k+.
- **Navigation window** (Finder-Smart-Folder-like): columns for Document date · File name · File
  type · File tags · Read/Unread; multi-level sort (chronological by default; medieval-safe);
  separate filters for subject tags, priority (P7–P10), and read-state.
- **Full-text search** across the OCR'd text.
- **Edit tags** for one file or a group (subjects, date facets, priority, color) — safely.
- **Copy file links** (`file://` URL / path / Markdown / HTML) for single files or groups.
- **Mark Read/Unread** in one keystroke; read files drop out of an Unread view.
- **Document window**: two-up viewer (image left / OCR text right), independent per-pane zoom, a
  draggable splitter (default ⅔ : ⅓), ↑/↓ to cycle the selection, intelligent copy (line-break-aware,
  de-hyphenating), and in-document Find.
- **Options** (⌘,): link format, copy behavior, viewer defaults, and more.
- Fully keyboard-operable.

## Building

Prereq: Xcode 16+ (macOS 14+ target). The `.xcodeproj` is **generated** by XcodeGen and not
committed — run bootstrap first:

```bash
./bootstrap.sh            # installs XcodeGen if needed, generates the project
open ArchiveReader/ArchiveReader.xcodeproj
```

Headless build / CI check:

```bash
cd ArchiveReader && xcodegen generate && \
  xcodebuild -scheme ArchiveReader -configuration Debug build
```

Regenerate with `xcodegen generate` whenever files are added — `project.yml` is authoritative;
never hand-edit the `.pbxproj`.

## Project docs

- [CLAUDE.md](CLAUDE.md) — authoritative project guide: Core Directive, verified corpus facts, the
  `TagWriter` safety protocol, architecture, stack, Archive Suite convergence.
- [PLAN.md](PLAN.md) — milestones, decisions, keyboard map, options, edge-case rules, backlog.
- [AGENTS.md](AGENTS.md) — multi-agent / worktree workflow and verification policy.
- [KNOWN_ISSUES.md](KNOWN_ISSUES.md) · [POTENTIAL_FEATURES.md](POTENTIAL_FEATURES.md).

## Architecture (short)

Swift 6 · SwiftUI (+ AppKit where needed) · PDFKit · `NSMetadataQuery` (Spotlight) · `NSURL`
resource values for tags · `NSFileCoordinator` for safe metadata-only writes · system SQLite FTS5
(no third-party deps) for the disposable content/full-text index. XcodeGen build. v1 sandboxed to a
user-granted archive root; non-sandboxed whole-Mac search planned. Domain logic lives UI-free in
`Core/` so it can become the shared `ArchiveCore` package when the suite converges.
