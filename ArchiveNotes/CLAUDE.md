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
  ArchiveNotesApp.swift            @main; Notes + Extracts windows + Settings + FormatCommands;
                                   injects ZoteroStatusModel into both windows
  ArchiveNotesCommands.swift       Format menu, SourceBlockCommands (⌘⇧V), ZoteroCommands
                                   (Note ▸ Attach Zotero Link…), DebugBlockCommands
  Models/
    NotesFilter.swift              Filter type (§16.3) + matches(_:folderItemIDs:) (kind/quality/
                                   date-range/tags ALL|ANY/title-substring/graph folder-membership),
                                   effective(base:user:) merge, tolerant init(from:) (W6-S4)
  Store/
    Item.swift                     Item/ZoteroRef/UnknownKey domain models
    Template.swift                 Template projection (id/name/kind) + pure TemplateResolution
                                   (nearest-ancestor walk + dangling detection, §16.4) (W6-S6)
    FrontMatterCodec.swift         Hand-rolled YAML front-matter (de)serializer
    BlockParser.swift              Block/SourceAnchor + HTML-comment header parser
    NoteStore.swift                actor — UUID-folder CRUD, atomic writes, Trash delete, assets;
                                   container-generic workers also back template storage under
                                   Templates/<uuid>/ (create/load/save/delete/allTemplates) (W6-S6)
    RootFolderStore.swift          Security-scoped bookmark to the Notes store root
    RootMarkerStore.swift          Idempotent .archive-suite-root.json lifecycle
    SourceAnchor+NotePassage.swift note-passage provenance anchor factory + notePassageTarget parser
                                   (reuses ArchiveCore.DurableLink §8.2 URL) (W7-S1)
    NotesPassagePayload.swift      Copy-in-Notes → paste-into-Extract pasteboard payload
                                   (com.archivenotes.passage; snapshot bytes per segment) (W7-S1)
  Index/
    NoteIndexRow.swift             NoteIndexRow (extraction payload) + ItemSummary (list/sort projection)
    NotesIndex.swift               actor — FTS5 + items table + org CRUD (folders/memberships/templates);
                                   allSummaries() list projection (W6-S3)
    NotesIndexer.swift             @MainActor driver — incremental build, parallel extraction, prune, search
    OrganizationStore.swift        @MainActor — folder tree + memberships + templates + organization.json;
                                   subtreeItemIDs(of:) cycle-safe subtree membership union (W6-S4 scope)
    OrganizationFile.swift         Atomic export/import of org graph to organization.json
  Core/
    NotesModel.swift               @MainActor UI façade (§16.1) — owns the shared OrganizationStore
                                   (+ index/root in the app path); @Published folder tree + scope;
                                   async create/rename/move/delete folders + selection scope (W6-S2);
                                   shared item source (allItems + reloadItems/replaceItems) for the
                                   per-window list VMs (W6-S3); search(_:) FTS façade + createSmartFolder
                                   (W6-S4); NoteStore-backed delete path — strandedByDeletingFolder
                                   (fresh read), trashItems (recoverable Trash), deleteFolderDeletingStranded
                                   (batched), titles(for:) (W6-S5); templates — @Published templates +
                                   reloadTemplates, assignTemplate/effectiveTemplate (resolver + lazy
                                   dangling-cleanup)/templates(matching:), create/duplicate/rename/delete
                                   template, newItem(kind:in:from:) instantiation (W6-S6); mutateItem
                                   write path (load→atomic .md save→one-row re-index→publish) behind
                                   setDate/setDateUncertain/setQuality (W6-S7, front-matter only) and
                                   loadBody/setBody (W7-S1a, body markdown⇄(trailingBodyRaw,blocks))
    NotesNavigationModel.swift     @MainActor per-window item-list VM (full NotesFilter w/ kindFilter
                                   proxy / sort / selection / displayed + displayedGeneration +
                                   instanceCounts); observes shared allItems + scope (mirrored from the
                                   delivered @Published value); recompute() = scope → user filter →
                                   keyword FTS (bm25, debounced, relevance auto-sort, generation guard) →
                                   order; clearUserFilters / saveAsSmartFolder (W6-S3/S4); replication +
                                   delete-last-instance guard — removeMembership (replicant→quiet,
                                   last→pendingDeletion modal), confirmDeletion/cancel (FRESH re-check
                                   at confirm), move/replicate, locations(of:) (W6-S5); windowKind +
                                   showingTemplates (templates-manager mode) (W6-S6)
    NotesItemDrag.swift            Pure id-only pasteboard codec (JSON [uuidString], custom UTI +
                                   .string) + ⌥=replicate/plain=move resolution; foreign→[] (W6-S5)
    NotesSort.swift                NoteSortField (title/date/kind/quality/relevance) + NoteSortDescriptor
                                   + deterministic nil-last multi-level sort over ItemSummary (W6-S3;
                                   adapts Reader LibrarySort)
    ItemSummaryDisplay.swift       Pure item-list cell rendering: displayDate (decade/year/month/day),
                                   qualityStars, displayTags (hides ArchiveSuite marker) (W6-S3)
    NotesFolderNode.swift          Id-keyed folder-tree node + buildNormalForest (group-by-parentId,
                                   sortOrder→name sort, distinct-subtree counts, orphan/cycle-safe)
                                   + smartFolderNodes (W6-S2)
    NotesAppSettings.swift         Browser layout/window persistence: NotesLayoutSettingsKey (an.* keys)
                                   + NotesLayoutSettings(reading:) (validated, clamped) + NotesAppSettings
                                   point-of-use accessor (window size, hidden columns) — mirrors Reader AppSettings
    NotesTagVocabulary.swift       Managed-token vocabulary (titleCased subjects + ArchiveSuite marker)
    NotesTagProjector.swift        THE audited Finder-tag mirror — projects front-matter onto .md files
    ExtractBuilder.swift           @MainActor — selection/payload → note-passage Blocks + createExtract/
                                   append (snapshot copy via NoteStore.importAsset), defaultTitle,
                                   extract-references-notes-only coercion; PassageSelectionSource seam (W7-S1)
  Editor/
    EditorTextView.swift           NSTextView subclass (TextKit 2 enforced, undo/find, rich text,
                                   list keyboard: Tab/Shift-Tab indent, Return continue,
                                   Backspace-at-start outdent, paste/drag image + text)
    MarkdownEditorView.swift       NSViewRepresentable: two-way binding, debounced write-back,
                                   freeze-during-edit, raw-toggle (⌘/), bridge-backed styled mode,
                                   EditorAssetStore plumbing, onRevealBlock seam, insertBlock method;
                                   EditorFlushBox handle → force a synchronous write-back (W7-S1a)
    NoteBodyEditorModel.swift      @MainActor — owns the editor body for ONE selected item; autosave-
                                   safe across selection switches (captures loadedID at schedule time,
                                   flush-outgoing-before-load, drops superseded loads via a generation,
                                   same-id reselect no-op); injected load/save/flushEditor seams (W7-S1a)
    MarkdownBridge.swift           Parse (Markdown→styled NSAttributedString) + serialize (back to
                                   CommonMark); block-header chips (<!-- block: --> → chip attachments);
                                   inline images (![alt](path)); buildInsertableBlock seam; idempotent
    MarkdownAttributes.swift       Custom NSAttributedString.Key defs (noteBlockKind, noteInlineCode,
                                   noteImageRelPath, noteBlockSource) + MarkdownStyler (semantic→visual)
    InlineImageAttachment.swift    NSTextAttachment for inline images (thumbnail + rel-path),
                                   EditorAssetStore protocol, ScratchAssetStore (test impl)
    NoteBlock.swift                NoteBody / NoteBlock value types (editor's block model, Sendable)
    BlockHeaderAttachment.swift    NSTextAttachment + view provider for source-block header chips
                                   (SourceAnchorBox ref wrapper, non-editable chip with Reveal button,
                                   TextKit 2 view provider); W4 seam: onRevealBlock callback
    EditorFormatting.swift         FormattingState + FormattingContext (ObservableObject) +
                                   EditorFormatting actions (bold/italic/code/link/heading/list/
                                   blockquote/code-block/indent/outdent) + insertTestBlock +
                                   pasteSourceBlocks + FocusedValue key
    FormattingToolbar.swift        SwiftUI toolbar reflecting + driving formatting state
  Views/
    NotesBrowserView.swift         3-pane browsing shell (folder tree │ item list │ detail) for the
                                   Notes + Extracts windows (W6-S1); @AppStorage panel widths + tree
                                   toggle, NotesWindowAccessor window-size persistence; owns a per-window
                                   NotesNavigationModel (@StateObject seeded from window kind); item pane =
                                   kind Picker + NotesTableView, detail = selected-item header + NoteEditorPane
                                   (W6-S3); .task bootstraps the store. Toolbar "New" menu (New \(kind) ⌘N
                                   from nearest-ancestor template + New from Template ▸ matching kind); item
                                   pane swaps to TemplatesManagerView in templates mode (W6-S6)
    TemplatesManagerView.swift     Per-window templates manager (shown in the item pane in templates mode):
                                   list all templates + New/Duplicate/Rename/Delete via NotesModel; body
                                   editing rides the (deferred) note-editor wiring (W6-S6)
    NotesFolderTreeView.swift      Left pane — mutable id-keyed folder tree (OutlineGroup + two-way
                                   @State selection sync, Smart Folders / Folders sections, All Notes
                                   pseudo-row, context-menu create/rename/delete) (W6-S2). Adapts
                                   Reader SidebarView. Folder-row drop target (plain=MOVE / ⌥=REPLICATE
                                   via NSEvent.modifierFlags) + batched delete-last-instance guard
                                   (fresh stranded read → §5 confirm) (W6-S5); drag-reparent → future.
                                   Templates anchor row + folder "Template ▸" assignment submenu
                                   (None / each template / Manage…) → NotesModel.assignTemplate (W6-S6)
    NotesTableView.swift           Center pane — virtualized item table (NSViewRepresentable +
                                   NSTableViewDiffableDataSource<Int, UUID> + ColumnPickerHeaderView
                                   hide/show + secondary sort + ContextMenuTableView). Columns
                                   kind/title/instances/date/quality/tags; tags READ-ONLY (edited in
                                   detail, W6-S7). Adapts Reader AppKitTableView (no inline NSTokenField)
                                   (W6-S3). Drag source (NotesTableDataSource pasteboardWriterForRow,
                                   id-only) + accent-glyph replicant title styling (W6-S5)
    NotesFilterBar.swift           Item-list filter bar: kind segmented control · keyword search (FTS,
                                   bm25 relevance as-you-type) · quality ★1–★5 toggles · tag ALL/ANY +
                                   chips · year date range · Save-as-Smart-Folder / Clear (W6-S4)
    LocationsInspector.swift       Detail-pane "Locations" — every folder the selected item is in, each
                                   a scope shortcut + guarded Remove (replicant→quiet, last→modal) (W6-S5)
    NotesContextMenu.swift         Item-row NSMenu builder (closure-trampoline): Add to Folder ▸ /
                                   Move to Folder ▸ / Remove-from-scope — the a11y/keyboard drag path (W6-S5)
    NotesWindowAccessor.swift      NSViewRepresentable reaching the hosting NSWindow (restore/remember
                                   window size, DV-1 pattern; Reader's WindowAccessor is private)
    NoteEditorPane.swift           Center pane: FormattingToolbar + raw toggle + MarkdownEditorView,
                                   BOUND to the selected item's body via NoteBodyEditorModel (load-on-
                                   select + autosave + flush-on-switch, W7-S1a); publishes the item's
                                   id/title/date to FormattingContext for W7 Create-Extract; wires
                                   Reveal (NSWorkspace.open) + Preview (popover) callbacks
    PanelDivider.swift             Draggable divider (copied from Reader)
    NotesSettingsView.swift        ⌘, Options — Zotero section (enable / clipboard-detect / citation
                                   style / advanced host+port), @AppStorage-bound (§D.8)
    ThumbnailImageCache.swift      @MainActor NSCache<NSString, NSImage> (300 count / 64 MB)
    NotesPDFPaneView.swift         Notes-side PDFPaneController + PDFPaneView (read-only, no-persist)
    ReaderPreviewPopover.swift     NSPopover PDF preview via ReaderLinkResolver; degrade messages for
                                   needsRootGrant / renamedCandidate / notFound.
                                   SourceBlockPreviewState (ObservableObject bridge for @EnvironmentObject)
  Zotero/
    ZoteroRef.swift                ZoteroRef/ZoteroLibrary/ZoteroRefKind value types (§D.1)
    ZoteroSelectLink.swift         Pure total parser for zotero://select/… links (§D.2)
    ZoteroClient.swift             actor — probe cascade (BBT→localAPI→unavailable), CSL fetch,
                                   citation fetch, in-memory cache, injected ZoteroTransport (§D.3/D.4)
    ZoteroCacheStore.swift         actor — disposable on-disk JSON cache for CSL metadata (§D.6)
    ZoteroAutoFill.swift           CSL→front-matter mapping (authors/date+precision/title) +
                                   AutoFillPlan (per-field diff, fill-empty default policy) (§D.4/D.5)
    ZoteroAutoFillModel.swift      @MainActor confirmation view-model: per-field toggles, confirm
                                   writes via injected NoteStore save + stamps citation/fetchedAt,
                                   cancel writes nothing (§D.5)
    ZoteroClipboardDetect.swift    Pure clipboard-detect: (pasteboard string, attached links) →
                                   fresh ZoteroRef? (canonical-dedup); no NSPasteboard dep (§D.5)
    ZoteroStatusModel.swift        @MainActor bridge: backend availability (cancellable Task) +
                                   frontmost-gated clipboard detection (changeCount-gated, no timer)
    ZoteroChipView.swift           Reusable Zotero pill (SwiftUI) + pure ZoteroChipPresentation
                                   (label/glyph/a11y); click → NSWorkspace.open(selectLink) (§D.5)
    ZoteroSettings.swift           ZoteroSettingsKey + ZoteroSettings (validated resolve from
                                   UserDefaults, defaults, clientConfig) + ZoteroSettingsStore
                                   (point-of-use accessor); gates probe/clipboard-detect (§D.8)
  Sources/
    SourceBlockPaster.swift        Pasteboard → source blocks: custom UTI + plain-text URL fallback,
                                   thumbnail asset import, entry-count cap (100)
    PassagePasteboard.swift        com.archivenotes.passage codec (W7-S2): write/read NotesPassagePayload
                                   (custom UTI + plain-text fallback) for copy-Notes → paste-Extract (§5)

macOS/Tests/ArchiveNotesTests/
  SmokePlaceholderTests.swift      Trivial test for the smoke gate
  ArchiveCoreWiringTests.swift     DurableLink/RootMarker/ArchiveSuiteMarker from Notes target
  NotesFilterTests.swift           NotesFilter defaults/isEmpty/Codable/Equatable + matches (all facets,
                                   ALL/ANY, date range, membership), effective merge, tolerant decode (W6-S4)
  NotesReplicationTests.swift      16 Tier-2 scratch-store tests: guard (replicant-quiet / last→pending
                                   no-mutate / confirm→Trash / cancel-noop / fresh re-check TOCTOU ×2 /
                                   captured-value confirm), move/replicate (incl. smart-folder refusal),
                                   batched folder-delete, stranded fresh read, locations (W6-S5)
  NotesItemDragTests.swift         6 tests: id-codec round-trip, malformed/foreign→[], ⌥/plain op (W6-S5)
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
  TemplateTests.swift              19 tests (W6-S6): TemplateResolution (nearest-ancestor / self-over-
                                   ancestor / blank / dangling-reported / dangling-fall-through / cycle),
                                   NoteStore template CRUD + no-leak + rename-on-save, NotesModel
                                   assign/effective-dangling/delete-clears-assignments/new-from-template/
                                   blank-defaults-Inbox+Extracts/kind-filter
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
  ImageSerializationTests.swift    13 tests: attachment↔![alt](path) round-trip, missing-asset
                                   preserves path, multiple/empty-alt/second-round-trip, image+bold,
                                   scratch-store write+disambiguate+resolve, attachment metadata,
                                   downsample, parse-with-asset-store
  BlockChipTests.swift             13 tests: multi-block round-trip, reader-page/zotero/note-passage,
                                   unknown-fields preserved, absent-header=freeform, malformed tolerated,
                                   chip-first-char, consecutive-chips, second-round-trip-no-op,
                                   thumb-line-consumed, insert-block-seam, leading-text-preserved
  SourceBlockPasterTests.swift     21 tests: payload→entries (page/doc/invalid/oversized/multi),
                                   scanURLs (page/doc/multi/non-archive/empty/non-PDF), thumbnail
                                   import (page/doc/collision), pasteboardHasArchiveLinks (UTI/text/no),
                                   readPasteboard (UTI/text/empty), block header §6 round-trip
  PasteboardPassageTests.swift     12 tests (W7-S2): write→read round-trip (incl. asset bytes),
                                   plain-text fallback, prefer-UTI, degrade nil (text-only/malformed/
                                   empty), payload→note-passage blocks bridge, notes-only coercion
                                   (keep well-formed / drop reader-source + malformed→freeform)
  ReaderLinkResolverTests.swift    16 tests: resolve/unknown-guid/missing/renamed/traversal/
                                   grant/wrong-guid/special-chars + router + root-store
  SourceBlockViewTests.swift       7 tests: ThumbnailImageCache (set/miss/removeAll), controller
                                   no-crash, chip Reveal+Preview buttons, MarkdownBridge onPreview
                                   threading, buildInsertableBlock preview, reveal URL validation
  ZoteroClientTests.swift          23 tests: probe (BBT/localAPI/unavailable/cache-TTL/reset),
                                   fetch CSL (BBT/localAPI/cache-hit/unavailable-throws/citation/group),
                                   CSL mapping (year/month/day precision, literal/given-family author),
                                   cache store (round-trip/loadMissing/cacheKey)
  ZoteroAutoFillTests.swift        21 tests: CSL date-parts→precision (year/month/day, 3-digit year,
                                   out-of-range m/d, raw-year fallback, no-decade), author/title
                                   mapping, AutoFillPlan fill-empty/replace/no-op, apply-selected,
                                   view-model confirm/cancel (fill-empty, replace-with-confirm,
                                   no-write-on-cancel, stamps only the matching ref)

packages/ArchiveCore/              Shared read-side contract — see root CLAUDE.md repo map
  Tags/                            DocumentTags, GeneratedTags, TagReading, TagEditing, TagWrite
  PDF/                             ExtractedContent (PDFHeaderParser), PDFFormatStatus
  Links/                           DurableLink, RootMarker, ArchiveLinkPayload + UTI
  Thumbnails/                      PDFThumbnailer actor, ThumbnailCacheKey (disk LRU)
  ArchiveSuiteMarker.swift         Suite membership tag recognition + filter
```

The map grows with each wave (W2 storage, W3 editor, W4 linking, W5 Zotero, W6 viewers,
W7 extracts, W8 tests). Master plan: `execution-plans/archive-notes/00-overview.md`.
