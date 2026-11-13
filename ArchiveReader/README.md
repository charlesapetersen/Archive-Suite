# Archive Reader

A native macOS app for **reading and triaging** large collections of historical-document PDFs that
were OCR'd and tagged by [**Archive Processor**](../ArchiveProcessor) (its sibling). Built for
historians and archivists working through thousands of scanned documents.

Archive Reader is the *reading & triage* companion to Archive Processor's *capture & tagging*: find
tagged PDFs, list them in chronological order, filter by tag / quality / read-state, search the
OCR text, read them two-up (image + OCR text), copy text and file links, edit tags, and mark
documents Read as you go. The two apps ship together as **Archive Suite** (this monorepo).

## Prime directive — the files are irreplaceable

Archival images cannot be re-shot and their tagging was extremely time-consuming. Archive Reader
**never deletes, moves, renames, or alters any existing archive file's bytes or location.** It changes
**macOS Finder tags** only as a deliberate, verified, reversible user action through a single audited
writer. Choosing a folder (in the Reader, or in Archive Notes) also creates one small identity file,
`.archive-suite-root.json`, at the archive root if it has none; it is never rewritten. Reopening, browsing
and tagging create no marker.
Keep that identity file with the folder so copied archive links continue to resolve. See [CLAUDE.md](CLAUDE.md) → Core Directive & Safety
Protocol.

## What it does

> **Status (2026-07-07):** shipped — v1 plus a full P2 pass (non-standard-PDF detection, near-duplicate
> tag finder, document-viewer refinements, duplicate-filename disambiguation); the test suite passes; the
> document-viewer flows are owner-verified. `CLAUDE.md` is the authoritative record.


- **Find** every PDF tagged `Read`/`Unread` under your archive root by walking the folder itself — no
  Spotlight, so a stale or dead index can never hide your files. ~102k PDFs walk in ~10 s, a warm start
  paints from the local index while it revalidates, and FSEvents keeps it live.
- **Navigation window** (Finder-Smart-Folder-like): columns for Document date · File name · File
  type · File tags · Quality · Read/Unread; multi-level sort (chronological by default; medieval-safe; a second level from the column header's
  right-click menu);
  separate filters for tags, Quality (Q1–Q3), and read-state.
- **Full-text search** across the OCR'd text.
- **Inspector** (View ▸ Show/Hide Inspector, ⌥⌘I, as in Archive Notes; Edit Info until 2026-11-11) toggles a resizable right-hand panel for one file or a group: tags, date and Sent-with date, Quality, marker color, read state and flag — safely. It stays open while browsing, follows the selection or open document, and remembers its visibility and width.
- **Copy file links** (`file://` URL / path / Markdown / HTML) for single files or groups.
- **Copy archive links** (`archivereader://`, ⇧⌘L in the Selection menu or the toolbar; ⌥⌘L in a document copies its page) that
  keep working after the folder moves. To open one, paste it into Archive Notes, Apple Notes, Mail or Messages
  and click it, or paste it into Safari's address bar; Archive Reader opens the document.
- **Mark Read/Unread** in one keystroke; read files drop out of an Unread view.
- **Document window**: two-up viewer (image left / OCR text right), independent per-pane zoom, a
  draggable splitter (default ⅔ : ⅓), keyboard-driven page-scroll + document cycling, intelligent copy
  (line-break-aware, de-hyphenating), and in-document Find. Preview's page views, in the document
  window and the preview sheet: **View ▸ Thumbnails** (⌥⌘2) is a sidebar of the scans of every open
  file, the file on view marked; **View ▸ Contact Sheet** (⌥⌘6) shows every PDF page of every open file
  as a numbered tile in one grid that fills the window and reflows when it is resized, as Preview does,
  OCR pages included, each file's heading on its first tile and the file on view tinted; **Hide Thumbnails** (⌥⌘1) returns to the page alone. Click a
  thumbnail or tile to read it. Both are also toolbar buttons, and draw from the on-disk thumbnail cache. Window tabbing is disabled to keep pages and
  windows distinct.
- **Options** (⌘,): link format, copy behavior, viewer defaults, and more.
- Fully keyboard-operable.

## Building

Prereq: Xcode 16+ (macOS 14+ target). The `.xcodeproj` is **generated** by XcodeGen and not
committed — run bootstrap first:

```bash
./bootstrap.sh            # installs XcodeGen if needed, generates the project
open macOS/ArchiveReader.xcodeproj
```

Headless build / CI check:

```bash
cd macOS && xcodegen generate && \
  xcodebuild -scheme ArchiveReader -configuration Debug build
```

Regenerate with `xcodegen generate` whenever files are added — `project.yml` is authoritative;
never hand-edit the `.pbxproj`.

## Project docs

- [CLAUDE.md](CLAUDE.md) — authoritative project guide: Core Directive, verified corpus facts, the
  `TagWriter` safety protocol, architecture, keyboard map, options, edge-case rules, decisions.
- [AGENTS.md](AGENTS.md) — multi-agent / worktree workflow and verification policy.
- [KNOWN_ISSUES.md](KNOWN_ISSUES.md) · [POTENTIAL_FEATURES.md](POTENTIAL_FEATURES.md).

## Architecture (short)

Swift 6 · SwiftUI (+ AppKit where needed) · PDFKit · `ArchiveCore.CorpusWalker` for discovery (a direct
filesystem walk — **no Spotlight**), `CorpusWatcher` (FSEvents) for live updates and a SQLite
`LibraryIndex` for warm start · `NSURL` resource values for tags · `NSFileCoordinator` for safe
metadata-only writes · system SQLite FTS5 (no third-party deps) for the disposable content/full-text
index. XcodeGen build. v1 sandboxed to a user-granted archive root; non-sandboxed whole-Mac search is a
long-term maybe and is **not** the mere entitlement flip this file used to claim (see
`POTENTIAL_FEATURES.md`). Domain logic lives UI-free in `Core/` so it can become the shared `ArchiveCore`
package when the suite converges.
