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
  note's own `.md` file via `ArchiveCore.CoordinatedTagWriter` — never onto corpus PDFs. It projects **only `tags` (subjects) + the `ArchiveSuite` marker**;
  `authors`, `date`, and `quality` stay **front‑matter‑only** (authoritative, durable plain‑text YAML)
  — a deliberate deviation from the original spec (which wanted author/date in macOS tags and a quality
  ordering "akin to Reader's priority tag"): front‑matter still satisfies "durable against this program
  no longer being developed," and keeping author/date/quality out of the global Finder‑tag namespace
  avoids polluting the shared vocabulary (overview decisions **D2/D4/D9**). *Additionally* mirroring
  author/date/quality to Finder tags for cross‑app (Reader/Processor) parity is a **deferred owner
  decision** (author would also need a SPEC `Author:` facet) — see the W9 gap‑closure plan's
  out‑of‑scope list.
- Test/scratch output goes to `mktemp` / `TESTOUT` — **never** the real store or corpus during dev/test.
- **Full protocol:** [`GUI_SAFETY.md`](GUI_SAFETY.md) — the scratch-corpus rules (never drive the store
  picker; confirm scratch before any tag write) + the DEBUG scratch-write guard that mechanically aborts
  any `NotesTagProjector` write outside scratch under a test / GUI-drive context.

## Stack & build

- **XcodeGen** — `macOS/project.yml` is authoritative; the `.xcodeproj` is generated and gitignored.
  `brew install xcodegen`, Xcode 16, macOS 14+, Swift 6.
- **ArchiveCore dependency** — `packages/ArchiveCore` (local Swift package). Shared tags, PDF parsing,
  durable links, suite marker.
- **Build:** `cd ArchiveNotes/macOS && xcodegen generate && xcodebuild -scheme ArchiveNotes -configuration Debug -derivedDataPath ./build/DD build`
- **Run:** `./launch.sh notes` from the repo root, or `cd ArchiveNotes && ./launch.sh`.
- **Test:** `./test-smoke.sh notes` from the repo root, or `cd ArchiveNotes && ./test-smoke.sh`.
- **GUI harness (W8-S7/S8, complete):** `scripts/make-notes-fixture.sh` builds a SCRATCH store at
  `~/Library/Application Support/ArchiveNotes/AN-GUI-Fixture` (notes + reader-page/Zotero/extract items,
  replicated membership, embedded Reader corpus) and prints its path for the app's `#if DEBUG`
  `-ANUITestStorePath` override; `scripts/gui-drive-notes.sh` is the sourced cliclick/osascript drive
  library (scratch-only; reads tags to assert, never drives the store picker — **host-only, so unattended
  sessions are blocked from it**). The `ArchiveNotesUITests` XCUITest suite (G0–G11) runs **off-screen in the
  Tart VM** — it joined the VM lane on 2026-07-30, so it is part of the periodic health gate
  (`AUTONOMOUS_GUI_VM_APPS="reader notes"`) and the fixture is built inside the VM on demand.
  **README + check catalog + the owner-eye checks (G2 typing, G6/G11
  external launch, chip-button clicks): [`scripts/GUI-HARNESS.md`](scripts/GUI-HARNESS.md).**
- **Visual / render verification:** `ArchiveNotesUITests` asserts the accessibility tree, not pixels — it
  won't catch a PDF pane / page-thumbnail that renders blank. For the running app use the live sighted loop
  (`ops/gui/capture-window.sh` + `cliclick` → read the shot, → [`../ops/gui/README.md`](../ops/gui/README.md));
  for headless pixel truth, a Notes-target render guard mirroring the Reader's `RenderProbe` would guard
  `NotesPDFPaneView` / `PDFThumbnailer` rendering (not yet added — the guards live in the Reader bundle only).
- **Durable-link E2E + safety (W8-S9):** `scripts/e2e-durable-links.sh` is a build-free filesystem proof
  that a `reader-page` link survives a computer move (same GUID, new absolute path → still resolves;
  guarded teardown); `DurableLinkE2ETests` proves the resolver logic in the unit gate. Both are GUI-free.
  [`GUI_SAFETY.md`](GUI_SAFETY.md) is the authoritative test file-safety protocol.
- **Bundle ID:** `com.archivenotes.app`. Signed with the suite's local self‑signed cert
  (`CODE_SIGN_IDENTITY: "Archive Suite Dev"`), not ad‑hoc and not notarized — rationale, the
  `ops/setup-signing-cert.sh` setup, and the library‑validation caveat are in the root
  [`CLAUDE.md`](../CLAUDE.md) §*Conventions*. Notes' **Debug** entitlements
  (`ArchiveNotes.uitest.entitlements`) therefore carry `disable-library-validation` +
  `get-task-allow`; the Release file must never gain either.

## Implementation Map

```
macOS/Sources/ArchiveNotes/
  ArchiveNotesApp.swift            @main; Notes + Extracts windows + Settings + FormatCommands;
                                   injects ZoteroStatusModel into both windows; NotesAppDelegate
                                   (NSApplicationDelegateAdaptor) owns the EditorFlushRegistry +
                                   applicationShouldTerminate bounded editor-flush on quit (W7-S6)
  ArchiveNotesCommands.swift       Format menu, SourceBlockCommands (⌘⇧V), ZoteroCommands
                                   (Note ▸ Attach Zotero Link…), ExtractCommands (Extract ▸ Create
                                   Extract ⌘⌥E / Append to Extract…, W7-S2), DebugBlockCommands
  Models/
    NotesFilter.swift              Filter type (§16.3) + matches(_:folderItemIDs:) (kind/quality/
                                   date-range/tags ALL|ANY/title-substring/graph folder-membership),
                                   effective(base:user:) merge, tolerant init(from:) (W6-S4)
  Store/
    Item.swift                     Item/ZoteroRef/UnknownKey domain models; normalizedDate is THE
                                   write-path date normalizer (decade floors; month/day downgrade to the
                                   finest precision the string supports — incl. an impossible day, W23.l4)
    GregorianDay.swift             Does (year, month, day) name a real day? — the calendar every date
                                   INPUT seam validates against (Item.normalizedDate, DateFieldEntry,
                                   ZoteroCSLItem.mappedDate). Arithmetic, NOT Foundation.Calendar:
                                   ICU's hybrid calls 1500-02-29 valid and 1582-10-10 invalid, both wrong
                                   for an archival corpus; Feb 29 is allowed under either reckoning that
                                   could have produced the date (proleptic Gregorian / pre-1582 Julian)
                                   (W23.l4)
    Template.swift                 Template projection (id/name/kind) + pure TemplateResolution
                                   (nearest-ancestor walk + dangling detection, §16.4) (W6-S6)
    FrontMatterCodec.swift         Hand-rolled YAML front-matter (de)serializer
    BlockParser.swift              Block/SourceAnchor + HTML-comment header parser
    NoteStore.swift                actor — UUID-folder CRUD, atomic writes, Trash delete, assets;
                                   container-generic workers also back template storage under
                                   Templates/<uuid>/ (create/load/save/delete/allTemplates) (W6-S6);
                                   writeReservedAsset (pre-named, no re-disambiguation, never-overwrite,
                                   component-boundary) + nonisolated static path helpers + rootURL (W7-S5);
                                   allItemRefs() read-only enumeration for the full index (re)build (W8-S7)
    RootFolderStore.swift          Security-scoped bookmark to the Notes store root
    RootMarkerStore.swift          Idempotent .archive-suite-root.json lifecycle
    SourceAnchor+NotePassage.swift note-passage provenance anchor factory + notePassageTarget parser
                                   (reuses ArchiveCore.DurableLink §8.2 URL) (W7-S1);
                                   [Block].distinctSourceNoteCount for the extract Sources column (W7-S4)
    NotesPassagePayload.swift      Copy-in-Notes → paste-into-Extract pasteboard payload
                                   (com.archivenotes.passage; snapshot bytes per segment) (W7-S1)
  Index/
    NoteIndexRow.swift             NoteIndexRow (extraction payload) + ItemSummary (list/sort projection);
                                   both carry sourceCount/sourceNoteCount (distinct source notes) (W7-S4)
    NotesIndex.swift               actor — FTS5 + items table + org CRUD (folders/memberships/templates);
                                   allSummaries() list projection (W6-S3); items.source_count column +
                                   additive migration (W7-S4); open() is ALL-OR-NOTHING — a failed
                                   PRAGMA/migration/schema step discards the handle (W23.m9);
                                   multi-row org transactions deleteFolderGraph / moveMembership /
                                   deleteTemplateAssignments — whole methods, NOT an exposed BEGIN/COMMIT
                                   (invariant: no suspension between BEGIN and COMMIT) (W23.m13)
    NotesIndexer.swift             @MainActor driver — incremental build, parallel extraction, search;
                                   prune via pure `pruneDecision` two-emission gate (empty-snapshot-safe,
                                   W8-S3) — refuses to prune on an empty/unsettled snapshot; init(index:)
                                   DI (one shared sqlite handle) + indexGeneration/isIndexReady completion
                                   signal + awaitSettled() the app path awaits after the disk build (W8-S7 §3.4);
                                   `failure` (unavailable/incomplete) — isIndexReady means SETTLED, not
                                   healthy, so the health claim lives here → sidebar banner (W23.m9)
    OrganizationStore.swift        @MainActor — folder tree + memberships + templates + organization.json;
                                   subtreeItemIDs(of:) cycle-safe subtree membership union (W6-S4 scope);
                                   deleteFolder + moveMembership (the MOVE seam, insert-before-delete so
                                   the item is never member-less) are all-or-nothing, and in-memory state
                                   moves ONLY after the DB transaction commits (W23.m13);
                                   beginHardDelete/endHardDelete/isHardDeleting — a UUID refcount (nestable)
                                   making BOTH minting seams (addMembership, moveMembership) refuse an item
                                   whose confirmed delete is in flight, so nothing follows a note into the
                                   Trash (W23.h3-fu)
    OrganizationFile.swift         Atomic export/import of org graph to organization.json
  Links/
    ReaderRootStore.swift          @MainActor — GUID-keyed security-scoped bookmarks to Reader roots
                                   (grant / look-up / stop-scope); the only writer of readerRootBookmarks
    ReaderLinkResolver.swift       THE archivereader:// resolve seam, in TWO stages (W23.m14): resolveExact
                                   is the walk-free main-actor stage (unknown root / containment refusal /
                                   exact hit, else .needsBasenameSearch) and `nonisolated static
                                   scanForBasename` is the off-actor basename walk — cancellable (checked
                                   every 64 entries), bounded (BasenameScan.defaultLimit, an order of
                                   magnitude above the real corpus), progress-reporting. There is NO
                                   synchronous full-walk API by design; `resolve` is async-only so a
                                   main-actor archive walk cannot be reintroduced. A search that did not
                                   finish is .searchIncomplete(scanned:), NEVER .notFound. Containment for
                                   BOTH stages is ReaderRootContainment (same file): canonical
                                   (resolvingSymlinksInPath) on both sides + component-wise ancestry, so a
                                   symlink can't leave the granted root by either door — the exact path or
                                   a basename match, which is skipped (walk continues) if it escapes (W23.l1)
  Core/
    NotesModel.swift               @MainActor UI façade (§16.1) — owns the shared OrganizationStore
                                   (+ index/root in the app path); @Published folder tree + scope;
                                   async create/rename/move/delete folders + selection scope (W6-S2);
                                   shared item source (allItems + reloadItems/replaceItems) for the
                                   per-window list VMs (W6-S3); itemsGeneration counter (bumped in replaceItems)
                                   drives the editor's reactive provenance-chip title refresh + create/append
                                   route the extract through openItem for select+raise (W14.4 b/c);
                                   search(_:) FTS façade + createSmartFolder
                                   (W6-S4); NoteStore-backed delete path — strandedByDeletingFolder
                                   (fresh read), trashItems (recoverable Trash; drops an index row only once
                                   NoteStore.itemExists says the note is gone, returns the survivors — W23.m12;
                                   holds OrganizationStore's hard-delete window for the whole call, so no
                                   replicate/move can follow a note into the Trash — W23.h3-fu),
                                   deleteFolderDeletingStranded
                                   (batched), titles(for:) (W6-S5); templates — @Published templates +
                                   reloadTemplates, assignTemplate/effectiveTemplate (resolver + lazy
                                   dangling-cleanup)/templates(matching:), create/duplicate/rename/delete
                                   template, newItem(kind:in:from:) instantiation (W6-S6); mutateItem
                                   write path (load→atomic .md save→one-row re-index→publish) behind
                                   setDate/setDateUncertain/setQuality (W6-S7, front-matter only) and
                                   loadBody/setBody (W7-S1a, body markdown⇄(trailingBodyRaw,blocks));
                                   openItem(id:block:)/pendingOpen/consumeOpen — the shared cross-window
                                   jump-to-source channel + resolvePassage (W7-S3); bootstrap now runs
                                   buildIndexFromDisk (owns a NotesIndexer, (re)builds the disposable index
                                   from disk, awaits settle) + @Published isIndexReady/indexGeneration
                                   deterministic index-ready signal (W8-S7 §3.4)
    NotesNavigationModel.swift     @MainActor per-window item-list VM (full NotesFilter w/ kindFilter
                                   proxy — per-window default + persistence via persistingKindTo (W7-S4);
                                   sort / selection / displayed + displayedGeneration +
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
                                   qualityStars, displayTags (hides ArchiveSuite marker) (W6-S3);
                                   sourcesText (count for extracts, blank otherwise) (W7-S4)
    NotesFolderNode.swift          Id-keyed folder-tree node + buildNormalForest (group-by-parentId,
                                   sortOrder→name sort, distinct-subtree counts, orphan/cycle-safe)
                                   + smartFolderNodes (W6-S2)
    NotesAppSettings.swift         Browser layout/window persistence: NotesLayoutSettingsKey (an.* keys)
                                   + NotesLayoutSettings(reading:) (validated, clamped) + NotesAppSettings
                                   point-of-use accessor (window size, hidden columns) — mirrors Reader AppSettings;
                                   windowKindFilter(for:)/setWindowKindFilter per-window kind featuring (W7-S4);
                                   windowHiddenColumns(for:)/setWindowHiddenColumns per-window column visibility —
                                   Note window defaults to hiding the always-blank Sources column (W14.4d)
    NotesTagVocabulary.swift       Managed-token vocabulary (titleCased subjects + ArchiveSuite marker)
    NotesTagProjector.swift        THE audited Finder-tag mirror — projects front-matter onto .md files;
                                   isScratchPath + a DEBUG scratch-write guard (test/GUI-drive contexts
                                   only, off in the real app, out of Release) mechanically refuse a tag
                                   write outside scratch (W8-S2 §5)
    ExtractBuilder.swift           @MainActor — selection/payload → note-passage Blocks + createExtract/
                                   append (snapshot copy via NoteStore.importAsset), defaultTitle,
                                   extract-references-notes-only coercion; PassageSelectionSource seam (W7-S1);
                                   passagePayload (copy side) + pastedExtractMarkdown (paste side) (W7-S2);
                                   pastedExtractMarkdown(from:importingAssetsVia:) imports paste bytes into
                                   the extract's assets/ + rewrites refs on collision (W14.3)
    NotePassageSource.swift        NotePassageBlockMap (pure chip-delimited block-ordinal map, shared with
                                   the S3 jump-to-source side) + EditorPassageSource (the live
                                   PassageSelectionSource over a value snapshot of the editor text —
                                   D7 independence; snapshotMarkdown → CommonMark + inline-image bytes) (W7-S2)
    InlineImageMarkdown.swift      The ONE owner of the `![alt](path)` grammar — escape-aware pattern
                                   (possessive: backtracking here is waste), emit(alt:path:), and the
                                   label escape/unescape pair (CommonMark ASCII-punctuation rule). Used by
                                   MarkdownBridge's two emit sites + its parse pattern and by
                                   ExtractBuilder.strippedTitleLine, which needs the SAME grammar or an
                                   escaped alt survives stripping and becomes an extract's title
                                   (W3.notes-thumb-line-duplicates-fu1)
    NotePassageResolve.swift       Pure jump-to-source + provenance-chip logic over the in-memory
                                   [ItemSummary]: resolve(anchor:)→PassageResolution taxonomy, chipLabel
                                   (live title, snapshot fallback), isSourceMissing, scrollRange
                                   (#block-n ordinal→NSRange via NotePassageBlockMap), openAction
                                   (which window selects+scrolls vs reports-missing vs ignores) (W7-S3)
  Editor/
    EditorTextView.swift           NSTextView subclass (TextKit 2 enforced, undo/find, rich text,
                                   list keyboard: Tab/Shift-Tab indent, Return continue,
                                   Backspace-at-start outdent, paste/drag image + text); copy(_:) +
                                   passageCopyHandler / passagePasteHandler seams (W7-S2 copy/paste)
    MarkdownEditorView.swift       NSViewRepresentable: two-way binding, debounced write-back,
                                   freeze-during-edit, raw-toggle (⌘/), bridge-backed styled mode,
                                   EditorAssetStore plumbing, onRevealBlock seam, insertBlock method;
                                   EditorFlushBox handle → force a synchronous write-back (W7-S1a);
                                   onJumpBlock + passageSummaries (chip live-title resolve) +
                                   EditorScrollRequest scroll-to-block (token-coalesced) + onScrollOutcome
                                   stale-ordinal report (W7-S3)
    NoteBodyEditorModel.swift      @MainActor — owns the editor body for ONE selected item; autosave-
                                   safe across selection switches (captures loadedID at schedule time,
                                   flush-outgoing-before-load, drops superseded loads via a generation,
                                   same-id reselect no-op); injected load/save/flushEditor seams (W7-S1a);
                                   loadedID @Published so the pane gates a jump-to-source scroll (W7-S3);
                                   flushPending() (both-debounce flush) for the app-terminate path (W7-S6)
    EditorFlushRegistry.swift      App-level per-pane flush registry (EditorFlushRegistry — each
                                   NoteEditorPane registers its flushPending on appear, deregisters on
                                   disappear) + TerminateFlushCoordinator (bounded reply — flush-complete
                                   OR timeout, whichever first). Backs NotesAppDelegate's terminate flush
                                   so a force-quit within the autosave debounce can't lose an edit (W7-S6)
    MarkdownBridge.swift           Parse (Markdown→styled NSAttributedString) + serialize (back to
                                   CommonMark); block-header chips (<!-- block: --> → chip attachments);
                                   inline images (![alt](path)); buildInsertableBlock seam; idempotent;
                                   onJumpBlock + passageSummaries thread note-passage chip jump + live
                                   title/missing resolve into BlockHeaderAttachment (W7-S3)
    MarkdownAttributes.swift       Custom NSAttributedString.Key defs (noteBlockKind, noteInlineCode,
                                   noteImageRelPath, noteBlockSource) + MarkdownStyler (semantic→visual)
    InlineImageAttachment.swift    NSTextAttachment for inline images (thumbnail + rel-path,
                                   Missing/Blocked placeholder kinds); app-wide thumbnailCache keyed
                                   by cacheKey = maxPixels + the file's VERSION (size + ns mtime,
                                   one stat) + path, derived here and never caller-supplied
                                   (W23.m11 / m11-fu); EditorAssetStore protocol
                                   (resolve → AssetResolution; resolveAsset convenience),
                                   ScratchAssetStore (test impl), ItemAssetStore (production:
                                   @MainActor sync name-reserve → async NoteStore.writeReservedAsset
                                   byte-write; single name arbiter) (W7-S5)
    AssetPathResolver.swift        THE inline-image READ seam: resolves one ![](…) reference inside one
                                   item's assets/ dir or refuses it — syntactic gate (assets/-rooted,
                                   no .., not absolute/remote) + canonical containment
                                   (resolvingSymlinksInPath + component-wise ancestry, so a symlink
                                   inside assets/ can't escape). Typed AssetResolution; `resolved`
                                   carries the canonical URL (W23.m3)
    NoteBlock.swift                NoteBody / NoteBlock value types (editor's block model, Sendable)
    BlockHeaderAttachment.swift    NSTextAttachment + view provider for source-block header chips
                                   (SourceAnchorBox ref wrapper, non-editable chip with Reveal button,
                                   TextKit 2 view provider); W4 seam: onRevealBlock callback; W7-S3:
                                   note-passage chips get a "Jump to Source" button (onJump) + prefer the
                                   source's live label (passageLiveLabel) + grey a removed source
                                   (passageSourceMissing)
    EditorFormatting.swift         FormattingState + FormattingContext (ObservableObject; currentItemID/
                                   Title/DateDisplay/Kind + weak notesModel) + EditorFormatting actions
                                   (bold/italic/code/link/heading/list/blockquote/code-block/indent/
                                   outdent) + insertTestBlock + pasteSourceBlocks + createExtract/
                                   appendToExtract + makeNotePassageSource (W7-S2) + FocusedValue key
    FormattingToolbar.swift        SwiftUI toolbar reflecting + driving formatting state
  Views/
    NotesBrowserView.swift         3-pane browsing shell (folder tree │ item list │ detail) for the
                                   Notes + Extracts windows (W6-S1); @AppStorage panel widths + tree
                                   toggle, NotesWindowAccessor window-size persistence; owns a per-window
                                   NotesNavigationModel (@StateObject seeded from window kind); item pane =
                                   kind Picker + NotesTableView, detail = selected-item header + NoteEditorPane
                                   (W6-S3); .task bootstraps the store. Toolbar "New" menu (New \(kind) ⌘N
                                   from nearest-ancestor template + New from Template ▸ matching kind); item
                                   pane swaps to TemplatesManagerView in templates mode (W6-S6). Hosts the
                                   hidden `an.status.indexReady` a11y probe the GUI harness polls (W8-S7 §3.4)
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
                                   kind/title/instances/date/quality/sources/tags; sources = distinct
                                   source notes for extracts (blank for notes, W7-S4); tags READ-ONLY
                                   (edited in detail, W6-S7). Adapts Reader AppKitTableView (no NSTokenField)
                                   (W6-S3). Drag source (NotesTableDataSource pasteboardWriterForRow,
                                   id-only) + accent-glyph replicant title styling (W6-S5)
    NotesFilterBar.swift           Item-list filter bar: kind segmented control · keyword search (FTS,
                                   bm25 relevance as-you-type) · quality ★1–★5 toggles · tag ALL/ANY +
                                   chips · year date range · Save-as-Smart-Folder / Clear (W6-S4)
    LocationsInspector.swift       Detail-pane "Locations" — every folder the selected item is in, each
                                   a scope shortcut + guarded Remove (replicant→quiet, last→modal) (W6-S5)
    DateFieldEntry.swift           Pure rules behind NoteMetadataInspector's DATE row (year text +
                                   month index + day text ⟹ committed string, day-Set enablement, and
                                   the note shown when a day the chosen month cannot have is dropped) —
                                   extracted so they are unit-testable without a window (W23.l4)
    NotesContextMenu.swift         Item-row NSMenu builder (closure-trampoline): Add to Folder ▸ /
                                   Move to Folder ▸ / Remove-from-scope — the a11y/keyboard drag path (W6-S5)
    NotesWindowAccessor.swift      NSViewRepresentable reaching the hosting NSWindow (restore/remember
                                   window size, DV-1 pattern; Reader's WindowAccessor is private)
    NoteEditorPane.swift           Center pane: FormattingToolbar + raw toggle + MarkdownEditorView,
                                   BOUND to the selected item's body via NoteBodyEditorModel (load-on-
                                   select + autosave + flush-on-switch, W7-S1a); publishes the item's
                                   id/title/date to FormattingContext for W7 Create-Extract; wires
                                   Reveal (NSWorkspace.open) + Preview (popover) callbacks; W7-S3 jump-to-
                                   source: onJumpBlock→NotesModel.openItem (publish) + observes pendingOpen
                                   → openAction → select + scroll-to-block (consume, gated on loadedID)
    PanelDivider.swift             Draggable divider (copied from Reader)
    NotesSettingsView.swift        ⌘, Options — Zotero section (enable / clipboard-detect / citation
                                   style / advanced host+port), @AppStorage-bound (§D.8)
    ThumbnailImageCache.swift      @MainActor NSCache<NSString, NSImage> (300 count / 64 MB)
    NotesPDFPaneView.swift         Notes-side PDFPaneController + PDFPaneView (read-only, no-persist)
    ReaderPreviewPopover.swift     NSPopover PDF preview via ReaderLinkResolver; degrade messages for
                                   needsRootGrant / renamedCandidate / notFound / searchIncomplete.
                                   Shows the walk-free answer immediately and, when a basename search is
                                   needed, a live "N items checked" state it cancels on dismiss/re-show
                                   (PreviewSearchModel, generation-scoped so a finished search's straggler
                                   ticks can't inflate the next one's count) (W23.m14).
                                   SourceBlockPreviewState (ObservableObject bridge for @EnvironmentObject)
  Zotero/
    ZoteroRef.swift                ZoteroRef/ZoteroLibrary/ZoteroRefKind value types (§D.1)
    ZoteroSelectLink.swift         Pure total parser for zotero://select/… links (§D.2)
    ZoteroClient.swift             actor — probe cascade (BBT→localAPI→unavailable), CSL fetch,
                                   citation fetch, in-memory cache, injected ZoteroTransport (§D.3/D.4);
                                   URLSessionZoteroTransport has an init(session:) DI seam (W8-S5 tests)
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
  NotesTagProjectorSafetyTests.swift  10 crown-jewel safety tests (W8-S2, Tier-2, scratch .md +
                                   data-fork byte-equality): §3 read-failure aborts (no []-coercion,
                                   neighbors untouched), concurrent-projections-never-corrupt (marker
                                   + both racing subjects survive — §10 closed the lost-update race, W15.tu4),
                                   §5 unmanaged-tag lossless, §6 "ArchiveSuite"-subject collision
                                   (single/whole-string/marker-never-stripped), §8/§9 disk-backed
                                   verify + reconcile-via-fresh-delta, §5 no-op no-mtime-churn,
                                   title-casing, §7 label-never-written, isScratchPath predicate +
                                   scratch-guard-live-under-XCTest
  NotesIndexTests.swift            16 tests: bm25 ordering, sanitizer, mtime-skip, prune, WAL,
                                   search, summaryRoundTrip, org tables exist; + W8-S3: reindex-
                                   replaces-body, prune-gate ×4 (empty-snapshot-never-wipes /
                                   two-emission / transient-drop / confirmed-only), org-graph DB
                                   persist+reload (folders+memberships+template assignments)
  NotesIndexReadyTests.swift       7 tests (W8-S7 §3.4): NotesIndexer completion signal (fresh-not-ready,
                                   empty-scope-settles, build-indexes+settles, awaitSettled idle fast-path,
                                   coalesced-chain-settles-once) + NotesModel.buildIndexFromDisk (populates
                                   list + flips ready; no-indexer store still ready)
  NotesIndexRecoveryTests.swift    4 tests (W23.m9): open() is all-or-nothing — a corrupt file (SQLite opens
                                   it, then fails on the first PRAGMA) must leave NO handle, so replacing the
                                   file and reopening works; org tables reachable on the retry; close ×2 safe
  NotesIndexerFailureTests.swift   9 tests (W23.m9): query/summary + build over a dead index report
                                   `.unavailable` instead of an empty answer; a failed build STILL settles
                                   (the guard against hanging awaitSettled/bootstrap); recovery clears it;
                                   NotesModel surfaces it (real notes + dead index ⇒ Ready but reported);
                                   Outcome→Failure mapping + message plurals
  OrganizationStoreTests.swift     13 tests: system-folder seeding, create/rename/move(cycle-guard)/
                                   delete(reparent+orphans), replication add/remove/wasLastInstance/
                                   forceRemove, template assignment+inheritance, JSON+DB round-trip
  OrganizationFileTests.swift      3 tests: round-trip, loadMissing, atomicWrite
  OrganizationAtomicityTests.swift 16 tests (W23.m13, Tier-2): deleteFolder / move / deleteTemplate are
                                   all-or-nothing, memory never ahead of the disk. Real SQLite fault
                                   injection — a BEFORE DELETE…RAISE(ABORT) trigger via the DEBUG-only
                                   NotesIndex.executeForTesting seam, TARGETED BY ROW for the batch case
                                   (an all-rows refusal can't tell a rollback from a half-applied batch);
                                   2 fixture-honesty tests; the divergence tests compare memory AGAINST
                                   the DB, since pre-fix memory alone looked correct
  HardDeleteWindowTests.swift      10 tests (W23.h3-fu, Tier-2): nothing may be filed onto a note being
                                   trashed. 5 on the refcount itself (both minting seams refused, nesting
                                   composes, an unbalanced end is a no-op, per-item scope); 3 drive a real
                                   replicate/move INTO the open window from the DEBUG-only
                                   NotesModel.hardDeleteWindowHookForTesting seam (deterministic — the
                                   production race is sub-millisecond, so racing tasks would prove nothing),
                                   over both hard-delete callers; 2 on window balance, incl. a trash the
                                   disk refuses (UF_IMMUTABLE) leaving the survivor still fileable
  VirtualFolderReplicationTests.swift  7 tests (W8-S4, §1.5, Tier-2): item-in-K-folders=K-memberships,
                                   replicate=membership-row-not-a-copy, remove-replicant-only, remove-
                                   last→.wasLastInstance (fires ONLY on the last, no mutation), moveFolder-
                                   preserves-memberships, smart-folder=query-with-zero-rows, cycle-guard-on-
                                   reparent — all on a scratch OrganizationStore (temp index.db)
  ItemSortDateTests.swift          13 tests: (date,precision)→sortDate parity table (decade/year/month/day/
                                   medieval-842/uncertain/malformed/no-precision) + W8-S4 cross-impl parity
                                   guard (Item.sortDate ≡ ArchiveCore DocumentTags.sortDate — divergence tripwire)
  TemplateTests.swift              19 tests (W6-S6): TemplateResolution (nearest-ancestor / self-over-
                                   ancestor / blank / dangling-reported / dangling-fall-through / cycle),
                                   NoteStore template CRUD + no-leak + rename-on-save, NotesModel
                                   assign/effective-dangling/delete-clears-assignments/new-from-template/
                                   blank-defaults-Inbox+Extracts/kind-filter
  EditorBindingTests.swift         9 tests: TextKit 2, undo/find bar, raw-mode font, write-back
                                   flush, programmatic suppress, mode-switch undo-clear/text-preserve,
                                   lint (no .layoutManager in Editor/)
  MarkdownBridgeTests.swift        31 tests: per-construct idempotency (h1–h6, bold, italic,
                                   bold+italic, inline code, link, ul, ol, blockquote, code block,
                                   code block+lang), mixed doc, second-round-trip no-op,
                                   unknown-styling-drops-text-preserved, Apple-parser semantic
                                   snapshots, block-kind stamping, text-never-dropped; + W8-S1:
                                   attributed→md→attributed structural idempotency (per-char
                                   fingerprint), mid-paragraph unsupported-attr degrade, relative
                                   image-ref through bridge
  AssetPathResolverTests.swift     11 tests (W23.m3): the read-seam resolver in isolation, on mktemp
                                   items/{A,B} — reported ../OTHER traversal, traversal from inside
                                   assets/, escaping symlink, symlink into a sibling assets-elsewhere/,
                                   non-assets / absolute / ~ / remote refs all refused; own asset,
                                   nested subdir, same-item symlink, symlink-aliased item dir resolve;
                                   dangling ref stays .missing. Each escape case first asserts the bytes
                                   ARE reachable under the pre-fix rule
  InlineImageReadSeamTests.swift   8 tests (W23.m3): the resolver's two consumers honour it — renderer
                                   shows Blocked (not another item's image) with rel-path + serialization
                                   intact, Missing stays distinct, both placeholders draw differently;
                                   ItemAssetStore/ScratchAssetStore containment, nil-itemID resolves
                                   nothing; a passage snapshot embeds only the item's OWN bytes
  NotesFrontMatterTests.swift      9 tests (W8-S1): all-known-keys round-trip, unknown-key byte-for-byte
                                   (canonical) + repositioned-preserved, minimal-defaults, missing-id
                                   typed-throw, edge-whitespace-scalar characterization, + seeded
                                   splitmix64 fuzz (2000 garbage→no-crash/typed-only; 600 corrupt-fronts
                                   →idempotent-or-typed + unknown-never-dropped; 400 well-formed Items
                                   →byte-idempotent). Found+fixed the flow-list quote data-loss bug.
  BlockHeaderTests.swift           6 tests (W8-S1): every §6 kind round-trips, unrecognized header
                                   fields verbatim, headerless-body=single-freeform-region, malformed
                                   header degrades to freeform (text preserved), canonical §6 wire
                                   strings parse
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
  SourceBlockPasterTests.swift     27 tests: payload→entries (page/doc/invalid/oversized/multi/
                                   terminator-bearing-rel), scanURLs (page/doc/multi/non-archive/empty/
                                   non-PDF; and W3.notes-paste-url-line-split: two links over LF·CRLF·
                                   lone-CR, single terminated line, blank/junk lines, trailing VT·FF·
                                   U+2028·U+2029, percent-encoded %0D rejected), thumbnail
                                   import (page/doc/collision), pasteboardHasArchiveLinks (UTI/text/no),
                                   readPasteboard (UTI/text/empty), block header §6 round-trip
  PasteboardPassageTests.swift     18 tests (W7-S2): write→read round-trip (incl. asset bytes),
                                   plain-text fallback, prefer-UTI, degrade nil (text-only/malformed/
                                   empty), payload→note-passage blocks bridge, notes-only coercion
                                   (keep well-formed / drop reader-source + malformed→freeform);
                                   passagePayload (selection→payload) + pastedExtractMarkdown (paste
                                   side) + copy→paste provenance round-trip + system-RTF representation
  ExtractCommandTests.swift        6 tests (W7-S2): NotesModel.createExtract (files in Extracts home +
                                   indexed/listed + on-disk note-passage block) / into explicit folder /
                                   empty-selection no-op+status / appendToExtract cross-note segment /
                                   existingExtracts sorted
  NotePassageSourceTests.swift     13 tests (W7-S2): blockRanges (empty / plain / prose+chip / starts-with-
                                   chip / two-chips, all disjoint-covering), selection→passage (single /
                                   cross-block / empty / discontiguous-in-doc-order), snapshotMarkdown
                                   (serialize / image-bytes-by-bare-name / empty), live-init value-copy
  NotePassageResolveTests.swift    20 tests (W7-S3): resolve ×4 outcomes, chipLabel live/fallback/format,
                                   isSourceMissing, scrollRange in/out-of-range/nil/empty, openItem token
                                   re-fire, resolvePassage, openAction (select-scroll / kind-mismatch
                                   ignore / extract target / missing-on-note-window-only)
  ReaderLinkResolverTests.swift    16 tests: resolve/unknown-guid/missing/renamed/traversal/
                                   grant/wrong-guid/special-chars + router + root-store
  ReaderLinkScanTests.swift        10 tests (W23.m14): resolveExact defers the walk (and still answers
                                   the cheap cases); the walk runs OFF the main thread even when started
                                   from it (proved structurally — the raw progress callback runs on the
                                   scanning thread, so Thread.isMainThread answers directly); bound and
                                   cancellation both report .searchIncomplete, NEVER .notFound; cancel
                                   lands mid-walk and stops it early (gated on a parked progress tick, so
                                   it's deterministic, not a race); an unwalkable root isn't absence; the
                                   fallback still finds a moved file; progress reaches the main actor and
                                   its readout is monotonic + generation-scoped
  ReaderLinkContainmentTests.swift 10 tests (W23.l1): a symlink can't leave the granted root by either
                                   door — escaping file/dir symlink refused on the exact path, escaping
                                   basename match skipped by the walk (and the contained twin still
                                   offered); each escape case first asserts the PRE-FIX rule accepted the
                                   fixture, so none is vacuous. No-regression side: in-root symlink
                                   resolves, symlinked ANCESTOR root resolves, dangling symlink still
                                   falls through to the search; plus the predicate itself (component-wise
                                   ancestry, both path spellings of one file)
  DurableLinkE2ETests.swift        4 tests (W8-S9): the durable-link scenario — link round-trip +
                                   resolve, computer-move re-grant by GUID, unknown-GUID/wrong-folder
                                   needs-regrant (never silent), renamed-candidate; hermetic (scratch
                                   temp dirs + snapshot/restore readerRootBookmarks)
  SourceBlockViewTests.swift       7 tests: ThumbnailImageCache (set/miss/removeAll), controller
                                   no-crash, chip Reveal+Preview buttons, MarkdownBridge onPreview
                                   threading, buildInsertableBlock preview, reveal URL validation
  ZoteroClientTests.swift          23 tests: probe (BBT/localAPI/unavailable/cache-TTL/reset),
                                   fetch CSL (BBT/localAPI/cache-hit/unavailable-throws/citation/group),
                                   CSL mapping (year/month/day precision, literal/given-family author),
                                   cache store (round-trip/loadMissing/cacheKey) — via a protocol-level
                                   ZoteroTransport stub (never builds a URLSession)
  ZoteroLocalServerTests.swift     5 tests (W8-S5, §1.8): the REAL transport over an in-process
                                   URLProtocol stub (no network egress) — item metadata parse+auto-fill
                                   +citation, attachment ref parse/fetch (D8), multi-ref note round-trip
                                   +fetch, degrade-when-down (closed→.unavailable, never throws to caller),
                                   bounded request timeout (hang→URLSession timeout fires). Pointed at a
                                   non-default port to prove the Config base-URL seam
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
W7 extracts, W8 tests).

## `00-overview.md` is the interface spec — keep it (owner decision 2026-07-29)

`execution-plans/archive-notes/00-overview.md` is the **authoritative Archive Notes interface spec**, and it is
deliberately **exempt from the "delete a shipped `execution-plans/` plan" convention** (root `CLAUDE.md`
§*Docs & backlog convention*). That convention targets *stale* plans; this one is not stale. It is cited **65
times across 38 tracked files**, overwhelmingly from **source and test comments** — `NotesModel`,
`MarkdownBridge`, `FrontMatterCodec`, `BlockParser`, `Item`, `NoteStore`, `Template`, the whole `Zotero/` group,
`NotesGUITests`, `DurableLinkE2ETests`, `scripts/e2e-durable-links.sh`, and `packages/ArchiveCore`'s date-sort
parity tests — spanning 31 distinct sections: §2 (locked decisions D1–D10), §3.x (domain model), §5
(front-matter schema), §6 (block + round-trip policy), §7, §8.x (durable links), §9, §10, §13, §15.x (future
lines), §16.x (interface contract), §D.x (Zotero).

Deleting or relocating it means rewiring all 65 references inside shipped code for no functional gain. It was
also **not** promoted to `SPEC/` — that would make it a cross-app contract and put every future edit behind the
owner hold-queue, an ongoing tax on a Notes-internal document. If you are tempted to "tidy" it away, read the
CLOSED item in `SUITE_TODO.md` §*Suite doc hygiene* first: the deletion has been mis-scoped twice.
