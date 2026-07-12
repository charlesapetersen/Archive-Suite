# Archive Notes — App Guide

Provenance‑first note‑taking from archival PDFs (via Reader) and Zotero references, at
100k‑note / 2M‑word scale. Third app in the Archive Suite monorepo. Umbrella conventions,
the shared contract, and the release process live in the root [`CLAUDE.md`](../CLAUDE.md);
this file is authoritative for Notes‑specific work.

## Core Directive — file safety

- Notes writes **only its own store** (UUID‑folder Markdown+assets under
  `~/Library/Application Support/ArchiveNotes/`). The archive corpus is **read‑only** — durable‑link
  resolution and page rendering only; no tag writes, no moves, no deletes on corpus files.
- The **only** Finder‑tag writer is `NotesTagProjector` (W2), which mirrors front‑matter onto the
  note's own `.md` file via `ArchiveCore.CoordinatedTagWriter` — never onto corpus PDFs.
- Test/scratch output goes to `mktemp` / `TESTOUT` — **never** the real store or corpus during dev/test.

## Stack & build

- **XcodeGen** — `macOS/project.yml` is authoritative; the `.xcodeproj` is generated and gitignored.
  `brew install xcodegen`, Xcode 16, macOS 14+, Swift 6.
- **ArchiveCore dependency** — `packages/ArchiveCore` (local Swift package). Shared tags, PDF parsing,
  durable links, suite marker.
- **Build:** `cd ArchiveNotes/macOS && xcodegen generate && xcodebuild -scheme ArchiveNotes -configuration Debug -derivedDataPath ./build/DD build`
- **Run:** `./launch.sh notes` from the repo root, or `cd ArchiveNotes && ./launch.sh`.
- **Test:** `./test-smoke.sh notes` from the repo root, or `cd ArchiveNotes && ./test-smoke.sh`.
- **Bundle ID:** `com.archivenotes.app`. Ad‑hoc signed (`CODE_SIGN_IDENTITY "-"`), not notarized.

## Implementation Map

```
macOS/Sources/ArchiveNotes/
  ArchiveNotesApp.swift            @main; Notes + Extracts windows + Settings + FormatCommands
  ArchiveNotesCommands.swift       Format menu (⌘B/I/K, ⌘⌥0-6/C/Q/K, ⌘⇧U/O) via FocusedValue
  Models/
    NotesFilter.swift              Tag/kind filter (§16.3 interface contract)
  Store/
    Item.swift                     Item/ZoteroRef/UnknownKey domain models
    FrontMatterCodec.swift         Hand-rolled YAML front-matter (de)serializer
    BlockParser.swift              Block/SourceAnchor + HTML-comment header parser
    NoteStore.swift                actor — UUID-folder CRUD, atomic writes, Trash delete, assets
    RootFolderStore.swift          Security-scoped bookmark to the Notes store root
    RootMarkerStore.swift          Idempotent .archive-suite-root.json lifecycle
  Index/
    NoteIndexRow.swift             NoteIndexRow (extraction payload) + ItemSummary (list/sort projection)
    NotesIndex.swift               actor — FTS5 + items table + org CRUD (folders/memberships/templates)
    NotesIndexer.swift             @MainActor driver — incremental build, parallel extraction, prune, search
    OrganizationStore.swift        @MainActor — folder tree + memberships + templates + organization.json
    OrganizationFile.swift         Atomic export/import of org graph to organization.json
  Core/
    NotesTagVocabulary.swift       Managed-token vocabulary (titleCased subjects + ArchiveSuite marker)
    NotesTagProjector.swift        THE audited Finder-tag mirror — projects front-matter onto .md files
  Editor/
    EditorTextView.swift           NSTextView subclass (TextKit 2 enforced, undo/find, rich text,
                                   list keyboard behavior: Tab/Shift-Tab indent, Return continue,
                                   Backspace-at-start outdent)
    MarkdownEditorView.swift       NSViewRepresentable: two-way binding, debounced write-back,
                                   freeze-during-edit, raw-toggle (⌘/), bridge-backed styled mode
    MarkdownBridge.swift           Parse (Markdown→styled NSAttributedString) + serialize (back to
                                   CommonMark); idempotent for the supported formatting subset
    MarkdownAttributes.swift       Custom NSAttributedString.Key defs (noteBlockKind, noteInlineCode,
                                   noteImageRelPath, noteBlockSource) + MarkdownStyler (semantic→visual)
    NoteBlock.swift                NoteBody / NoteBlock value types (editor's block model, Sendable)
    EditorFormatting.swift         FormattingState + FormattingContext (ObservableObject) +
                                   EditorFormatting actions (bold/italic/code/link/heading/list/
                                   blockquote/code-block/indent/outdent) + FocusedValue key
    FormattingToolbar.swift        SwiftUI toolbar reflecting + driving formatting state
  Views/
    NotesShellView.swift           3-pane shell (HStack + PanelDivider), detail → NoteEditorPane
    NoteEditorPane.swift           Center pane: FormattingToolbar + raw toggle + MarkdownEditorView;
                                   publishes FormattingContext via focusedSceneValue
    PanelDivider.swift             Draggable divider (copied from Reader)
    NotesSettingsView.swift        Settings form (placeholder)

macOS/Tests/ArchiveNotesTests/
  SmokePlaceholderTests.swift      Trivial test for the smoke gate
  ArchiveCoreWiringTests.swift     DurableLink/RootMarker/ArchiveSuiteMarker from Notes target
  NotesFilterTests.swift           NotesFilter defaults/isEmpty/Codable/Equatable
  NoteStoreTests.swift             13 tests: create/load/rename/delete/allItemIDs/assets/sanitize/mdURL
  RootMarkerStoreTests.swift       5 tests: fresh/idempotent/corrupt-guard/empty/JSON-round-trip
  NotesTagProjectorTests.swift     9 adversarial tests: unreadable-abort, lossless, remove-only-managed,
                                   collision-dedup, verify-re-read, no-label, concurrent-third-party,
                                   boundary-guard, recover-managed
  NotesIndexTests.swift            10 tests: bm25 ordering, sanitizer, mtime-skip, prune, WAL,
                                   search, summaryRoundTrip, org tables exist
  OrganizationStoreTests.swift     13 tests: system-folder seeding, create/rename/move(cycle-guard)/
                                   delete(reparent+orphans), replication add/remove/wasLastInstance/
                                   forceRemove, template assignment+inheritance, JSON+DB round-trip
  OrganizationFileTests.swift      3 tests: round-trip, loadMissing, atomicWrite
  EditorBindingTests.swift         9 tests: TextKit 2, undo/find bar, raw-mode font, write-back
                                   flush, programmatic suppress, mode-switch undo-clear/text-preserve,
                                   lint (no .layoutManager in Editor/)
  MarkdownBridgeTests.swift        28 tests: per-construct idempotency (h1–h6, bold, italic,
                                   bold+italic, inline code, link, ul, ol, blockquote, code block,
                                   code block+lang), mixed doc, second-round-trip no-op,
                                   unknown-styling-drops-text-preserved, Apple-parser semantic
                                   snapshots, block-kind stamping, text-never-dropped
  FormattingActionTests.swift      22 tests: per-action apply-then-serialize (bold, italic,
                                   inline code, bold+italic, link apply/remove, h1/h2/heading→plain,
                                   ul/ol/blockquote/code-block toggle + toggle-twice-no-op), state
                                   query (bold/heading/list reflected correctly)

packages/ArchiveCore/              Shared read-side contract — see root CLAUDE.md repo map
  Tags/                            DocumentTags, GeneratedTags, TagReading, TagEditing, TagWrite
  PDF/                             ExtractedContent (PDFHeaderParser), PDFFormatStatus
  DurableLink.swift                Cross-app link URLs (archivereader:// / archivenotes://)
  RootMarker.swift                 .archive-suite-root.json identity + Codable
  ArchiveSuiteMarker.swift         Suite membership tag recognition + filter
```

The map grows with each wave (W2 storage, W3 editor, W4 linking, W5 Zotero, W6 viewers,
W7 extracts, W8 tests). Master plan: `execution-plans/archive-notes/00-overview.md`.
