# Suspects — suspected bugs not yet reproduced

Format, statuses and rules: [`README.md`](README.md) §*SUSPECTS.md*. A suspect becomes a `W40.fix-<slug>` item
only once a failing test or a scripted run on scratch data reproduces it (phase rule 5).

<!-- First entry is S-001. Append new suspects below, newest at the bottom. -->

### S-001 · Reader ⌘Z may undo a tag change while the user is undoing typing

- **Raised:** 2026-10-12 · W40.b1 · code reading while writing ledger row `R-21`.
- **Suspected behaviour:** Tags ▸ Undo Tag Change is bound to ⌘Z for the whole navigation window
  (`ArchiveReader/macOS/Sources/ArchiveReader/ArchiveReaderCommands.swift:112-114`) and is enabled whenever
  `undoDepth > 0`. If the menu item takes ⌘Z before a focused text field (filter, OCR search, the inline tag
  field) does, a user who means to undo some typing instead re-writes Finder tags on the last-edited files. The
  write is a real tag write to an archive file. This is an irreversible-path suspect: worth a journey's time
  before anything cosmetic.
- **Where:** `ArchiveReaderCommands.swift:112`; `Views/NavigationModel.swift:1096` `undoLast`; ledger `R-21`.
- **Would confirm it:** on the VM, with the scratch fixture: mark one file Read, click in the name-filter field,
  type "abc", press ⌘Z, then read that file's tags back from disk. Confirmed if it is `Unread` again or the
  status line says "Undid".
- **Would clear it:** the same run leaves the file `Read` and only removes the typed text.
- **Status:** `open`
- **History:**
  - 2026-10-12 W40.b1 — raised.

### S-002 · Reader's viewer, preview or thumbnails may download a cloud placeholder

- **Raised:** 2026-10-12 · W40.b1 · code reading while writing ledger row `R-04`.
- **Suspected behaviour:** the "never materialised" promise is enforced on the indexing and scan paths
  (`withDatalessMaterializationDisabled`) and on the link thumbnail. No such guard was seen on
  `DocumentViewerModel.load`, `PreviewSheet` or other thumbnail paths. If a user opens a dataless row, PDFKit may
  download the whole file. The cost is bandwidth and disk, not data loss.
- **Where:** `Views/DocumentViewerModel.swift` `loadCurrent`; `Views/PreviewSheet.swift`; ledger `R-04`.
- **Would confirm it:** a dataless file is hard to make here (no cloud-synced root). Either create a scratch
  file-provider placeholder (`SF_DATALESS`) in a test, open it through `DocumentViewerModel.load`, and check that
  the flag is still set afterwards, or decide that opening a file is an explicit user request to download it and
  record that.
- **Would clear it:** the flag is still set after the viewer loads, or the owner rules that opening a file may
  download it.
- **Status:** `open`
- **History:**
  - 2026-10-12 W40.b1 — raised.

### S-003 · A dead Reader content index still shows "No matches" in the list

- **Raised:** 2026-10-12 · W40.b1 · code reading while writing ledger row `R-12`.
- **Suspected behaviour:** with the index unavailable, an OCR query empties the list and shows the generic
  "No matches" overlay (`Views/NavigationWindowView.swift:255`). The amber status-bar line names the failure, but
  the main area still reads as an answer. `W23.m9` promised a dead index is never answered as "no matches".
- **Where:** `NavigationWindowView.swift:255`, `:629-635`; ledger `R-12`.
- **Would confirm it:** the corrupt-index VM fixture (`ContentIndexFailureUITests`): type an OCR query and take a
  screenshot of the list area. Confirmed if it says "No matches" while the failure line shows.
- **Would clear it:** the overlay says the index is unavailable, or no overlay is drawn while the failure line
  shows.
- **Status:** `open`
- **History:**
  - 2026-10-12 W40.b1 — raised.

### S-004 · Reader view state from another root may restore everything except the folder prefix

- **Raised:** 2026-10-12 · W40.b1 · code reading while writing ledger row `R-17`.
- **Suspected behaviour:** `restoreViewState` guards only the folder prefix against a different root
  (`Views/NavigationModel.swift:620-627`). `sanitizedPathPrefix` passes the prefix through when
  `rootStore.discoveredPathPrefix` is nil (`:642`), and restore runs in `init` (`:152`), possibly before that
  value is known. A prefix saved under an old root could then hide every row in the new one, and the list would
  read as empty. Recoverable (Clear fixes it), so S3 at most.
- **Where:** `NavigationModel.swift:152`, `:613-645`; ledger `R-17`.
- **Would confirm it:** a unit test: persist view state with a `pathPrefix` under root A, build a new
  `NavigationModel` on root B with the same defaults domain, and assert on `filter.pathPrefix` and the displayed
  count.
- **Would clear it:** the prefix is dropped (or `discoveredPathPrefix` is set before restore) and root B lists its
  files.
- **Status:** `open`
- **History:**
  - 2026-10-12 W40.b1 — raised.

### S-005 · The Reader does not recognise an encrypted PDF

- **Raised:** 2026-10-12 · W40.b1 · code reading while writing ledger rows `R-38`, `R-39`.
- **Suspected behaviour:** no Reader or ArchiveCore code checks `PDFDocument.isLocked` or `isEncrypted`.
  `PDFFormatStatus`'s own comment counts an encrypted PDF as unreadable. If PDFKit opens a locked file with no
  readable text, the indexer probably flags it as no-text rather than unreadable, and the viewer shows an empty
  pane or "has no pages" instead of saying it is encrypted. Cosmetic or misleading, not data loss.
- **Where:** `Views/DocumentViewerModel.swift` `loadCurrent`; `Search/ContentIndexer.swift:268-277`;
  `packages/ArchiveCore/Sources/ArchiveCore/PDF/PDFFormatStatus.swift`; ledger `R-38`, `R-39`.
- **Would confirm it:** make a password-protected PDF in a scratch directory (`CGPDFContext` with
  `kCGPDFContextUserPassword`). Run it through `ContentIndexer`'s row extraction and `DocumentViewerModel.load`,
  and record the format status and the error shown.
- **Would clear it:** the status is `unreadable` and the viewer names the problem.
- **Status:** `open`
- **History:**
  - 2026-10-12 W40.b1 — raised.

### S-006 · A Notes subject spelled "ArchiveSuite" loses its Finder tag on the note's next save

- **Raised:** 2026-10-12 · W40.b2 · code reading while writing ledger row `N-04`.
- **Suspected behaviour:** the projector strips the retired `ArchiveSuite` stamp whenever it is not in `desired`
  (`retiredTokens.subtracting(desired)`, `Core/NotesTagProjector.swift:46`, `:131-132`). The subject path passes
  every subject as `desired`, so a current subject `ArchiveSuite` survives there. But the facet path, which runs on
  *every* `mutateItem` save including a body autosave, passes only `facetProjectionTokens` (Quality, date facets,
  and Q- or date-looking subjects) as `desired` (`Core/NotesModel.swift:1015-1022`). So the next save of a note whose
  subject is `ArchiveSuite` removes that tag from the note's `.md`, while the front-matter subject stays. The Finder
  mirror then disagrees with YAML until the subject is re-saved, and the next body save strips it again. The
  existing tests (`NotesTagProjectorSafetyTests.subjectLiterallyArchiveSuiteCollision`,
  `NotesTagProjectorTests.archiveSuiteSubjectCollisionNoDup`) call `project` with the full subject set and never
  reach the facet path. Severity guess S4. The tag write is on the note's own file, not the corpus, and is
  recoverable, but it is the Finder-tag write path.
- **Where:** `ArchiveNotes/macOS/Sources/ArchiveNotes/Core/NotesTagProjector.swift:46`, `:131-132`;
  `Core/NotesModel.swift:1007-1022` (`projectFacetTags`), `:1266` (`mutateItem`); ledger `N-04`.
- **Would confirm it:** a unit test in `ArchiveNotesTests` on a scratch store (the `QualityWriteTests` Env shape):
  1. Create a note.
  2. `await model.setTags(["ArchiveSuite"], to: id)`.
  3. Assert that `TagReading.read(mdURL).tagNames` contains `ArchiveSuite`.
  4. `await model.setBody("edited", for: id)`.
  5. Read the tags again.

  Confirmed if `ArchiveSuite` is gone while `store.load(id).tags` still holds it.
- **Would clear it:** the tag is still present after the body save.
- **Status:** `open`
- **History:**
  - 2026-10-12 W40.b2 — raised.

### S-007 · Notes' source-block preview may download a cloud placeholder

- **Raised:** 2026-10-12 · W40.b2 · code reading while writing ledger row `N-03`.
- **Suspected behaviour:** `W9.b4` promises that Notes never materialises dataless corpus files. The chip
  thumbnail path is guarded: `PDFThumbnailer.renderPage` runs inside `CorpusWalker.withDatalessMaterializationDisabled`.
  The preview popover is not. `ReaderPreviewPopover.showPDF` calls `PDFDocument(url:)` directly
  (`Views/ReaderPreviewPopover.swift:224-225`). So clicking a source block whose target is a cloud placeholder may
  download the whole file. The cost is bandwidth and disk, not data loss. Severity guess S4, not on an
  irreversible path. This is the Notes counterpart of `S-002` (Reader viewer).
- **Where:** `ArchiveNotes/macOS/Sources/ArchiveNotes/Views/ReaderPreviewPopover.swift:224-225`; ledger `N-03`.
- **Would confirm it:** the same constraint as `S-002`, since a dataless file is hard to make here. Either:
  - create a scratch file-provider placeholder (`SF_DATALESS`), open it through the popover's resolve-then-show
    path, and check that the flag is still set afterwards; or
  - decide that opening a preview is an explicit request to download, and record that.
- **Would clear it:** the flag is still set after the preview opens, or the owner rules that a preview may
  download.
- **Status:** `open`
- **History:**
  - 2026-10-12 W40.b2 — raised.

### S-008 · Notes may not remember a window size changed just before ⌘Q

- **Raised:** 2026-10-12 · W40.b2 · code reading while writing ledger row `N-08`.
- **Suspected behaviour:** the window size is written only from SwiftUI `onDisappear`
  (`Views/NotesBrowserView.swift:72-78`). If `onDisappear` does not run when the app terminates, a resize followed
  by ⌘Q never reaches `NotesAppSettings`. On the next launch `configureWindow` (`:211-228`) then applies the
  *older* saved size, possibly over the frame SwiftUI's own state restoration had restored. Severity guess S4,
  cosmetic.
- **Where:** `Views/NotesBrowserView.swift:72-78`, `:211-228`; `Core/NotesAppSettings.swift:96`; ledger `N-08`.
- **Would confirm it:** in the VM, on a normal (non-UITest-harness) launch, because the harness suppresses size
  persistence:
  1. Resize the Notes window to a distinctive size.
  2. Quit with ⌘Q, without closing the window first.
  3. Relaunch and read the window frame.

  Confirmed if the frame is not the size it was resized to.
- **Would clear it:** the relaunched window has the resized size.
- **Status:** `open`
- **History:**
  - 2026-10-12 W40.b2 — raised.

### S-009 · Pasting or dropping an image in raw mode may write an orphan asset and a stray character into the note

- **Raised:** 2026-10-12 · W40.b2 · code reading while writing ledger row `N-15`.
- **Suspected behaviour:** `EditorTextView.paste` and `performDragOperation` call `tryPasteImage` without checking
  raw mode (`Editor/EditorTextView.swift:652-701`). The asset store stays wired in raw mode
  (`Editor/MarkdownEditorView.swift:236-237`). In raw mode the image bytes are written to `assets/pasted-….png`,
  and an `NSTextAttachment` is inserted into a plain-text view (`:750-752`). Raw write-back serialises
  `textView.string` (`Editor/MarkdownEditorView.swift:479-485`), so the note would save a U+FFFC object-replacement
  character instead of `![](assets/…)`. The image vanishes from the note and an orphan file stays in `assets/`. G4
  avoids this by switching to styled mode before it pastes. Severity guess S3. It is on the note-save path: the
  user's paste is silently lost and the saved body gains a junk character.
- **Where:** `ArchiveNotes/macOS/Sources/ArchiveNotes/Editor/EditorTextView.swift:652-701`, `:707-751`;
  `Editor/MarkdownEditorView.swift:236-237`, `:479-485`; ledger `N-15`.
- **Would confirm it:** either of these.
  - **VM:** a variant of `NotesGUITests.testG4_PasteImageWritesAssetAndInlineReference` that clicks
    `an.editor.rawToggle` first, seeds PNG bytes, fires `an.editor.test.pasteImage`, then reads the note's `.md`.
    Confirmed if a new `pasted-*.png` exists while the `.md` has no `](assets/pasted-` reference, or contains
    U+FFFC.
  - **App-hosted unit test:** call `applyRawMode(true, …)` on an `EditorTextView` with a `ScratchAssetStore`, then
    `uiTestPasteImage()`, then inspect `string` and the scratch `assets/`.
- **Would clear it:** the raw-mode paste is declined (no asset written), or it inserts the literal
  `![](assets/…)` text.
- **Status:** `open`
- **History:**
  - 2026-10-12 W40.b2 — raised.

### S-010 · Removing several sole-instance notes from a folder at once asks about only the last one

- **Raised:** 2026-10-12 · W40.b2 · code reading while writing ledger row `N-28` (also `N-30`).
- **Suspected behaviour:** row menu ▸ "Remove N Items from “folder”" runs
  `for id in ids { await nav.removeMembership(id, from: source) }`. Each sole-instance item sets
  `nav.pendingDeletion` and returns without changing anything, so every later sole-instance item overwrites the
  earlier one. Only the last item reaches the confirmation alert. The earlier sole-instance notes stay in the
  folder and nothing says so, while the menu title said they would all be removed. The code comment says it
  "confirms one at a time", but nothing queues the confirmations. Severity guess S3. Nothing is lost: the bug
  deletes less than asked, not more. It does sit next to an irreversible path (confirm → Trash), so check that
  the item named in the alert is the one that gets trashed.
- **Where:** `ArchiveNotes/macOS/Sources/ArchiveNotes/Views/NotesContextMenu.swift:135-139`;
  `Core/NotesNavigationModel.swift:304-320` (`removeMembership`, `pendingDeletion` assignment at `:316`). Ledger
  `N-28`, `N-30`.
- **Would confirm it:** a unit test in `ArchiveNotesTests` on a scratch store: make folder F holding sole-instance
  notes A and B and replicant C (also in G). Run the menu's exact loop over `[A, B, C]`. Expect, if real:
  `nav.pendingDeletion?.itemId == B`, A still a member of F with no pending prompt, and C removed from F. Then
  `confirmPendingDeletion()` trashes only B and A stays. A VM UITest version: select two sole-instance rows in a
  folder, right-click ▸ Remove 2 Items, confirm, and assert one note dir still exists with its F membership.
- **Would clear it:** the loop produces a confirmation for each sole-instance item, one after another, or one
  batched confirmation naming both. After confirming, neither A nor B is still filed in F without having been
  asked about.
- **Status:** `open`
- **History:**
  - 2026-10-12 W40.b2 — raised.

### S-011 · Row-menu "New from Template" skips the template-body flush and failed-save guard

- **Raised:** 2026-10-12 · W40.b2 · code reading while writing ledger row `N-29`.
- **Suspected behaviour:** the toolbar route (`NotesBrowserView.newItem(from:)`) first awaits
  `flushRegistry.flushAll()`, and refuses when `model.hasFailedTemplateBodySave(templateId)`. The item-row
  menu's New from Template calls `model.newItem(…, from: templateId)` directly with neither step. The
  templates manager lists both kinds, so the other window can have that template's body editor open. A body
  edit still inside the debounce (~400 ms editor plus 600 ms autosave) is then missing from the new note. If
  the body's last save failed, the note is made from the stale on-disk body, which the toolbar route
  deliberately refuses to do. Severity guess S4. No data loss: the template draft stays in its editor, and the
  new note is just incomplete.
- **Where:** `ArchiveNotes/macOS/Sources/ArchiveNotes/Views/NotesContextMenu.swift:52-63` vs
  `Views/NotesBrowserView.swift:196-205`; `Editor/NoteBodyEditorModel.swift:55` (`saveDebounce`). Ledger `N-29`, `N-11`.
- **Would confirm it:** a VM UITest. Open the Extracts window, enter Templates and select a *note* template T.
  Type a unique marker into its body. Within 0.5 s, right-click a row in the Notes window ▸ New from Template ▸ T.
  Read the new note's `.md` and assert the marker is missing. Or, without timing: in a unit test, put T into
  `failedTemplateBodySaves` (via the existing failed-save seam in `NotesModelTemplateTests.failedTemplateBodySaveCanRetry`),
  call the row-menu closure's `model.newItem`, and assert that a note is created.
- **Would clear it:** the row-menu path flushes and refuses the same way the toolbar path does, or the new note
  holds the marker.
- **Status:** `open`
- **History:**
  - 2026-10-12 W40.b2 — raised.

### S-012 · The tag filter may miss every tag entered in the app unless it is typed with the stored capitals

- **Raised:** 2026-10-12 · W40.b2 · code reading while writing ledger row `N-32`.
- **Suspected behaviour:** tags added in Notes are stored title-cased (`NotesModel.setTags`/add-tag call
  `NotesTagVocabulary.normalizedSubjects`, `Core/NotesModel.swift:849-866`), so "intel" is saved as "Intel". The
  filter bar's tag field appends the raw trimmed text (`Views/NotesFilterBar.swift:198-203`), and
  `NotesFilter.matches` does an exact set comparison against the stored tags
  (`Models/NotesFilter.swift:98-105`, `ItemSummary.managedTags` = raw `item.tags`, `Index/NoteIndexRow.swift:45`).
  A user who types "intel" would then see an empty list for notes tagged in the app. A smart folder saved from
  that facet would count zero for good. The VM test passes because the fixture writes lower-case tags straight
  into front matter (`ArchiveNotes/scripts/make-notes-fixture.sh:159,183`), which the app itself never does.
  Recoverable (retype with capitals), not on an irreversible path. S3: the list reads as an answer.
- **Where:** `Views/NotesFilterBar.swift:198`; `Models/NotesFilter.swift:98`; ledger `N-32`, `N-33`.
- **Would confirm it:** a unit test in `NotesNavigationModelTests`. Create a note, add tag "intel" through
  `NotesModel` (the path the inspector uses), set `nav.filter.tags = ["intel"]` the way `addPendingTag` does, and
  assert that `nav.displayed` contains the note. Confirmed if it is empty.
- **Would clear it:** the note is displayed, i.e. the filter or the stored tag is normalised somewhere this
  reading missed.
- **Status:** `open`
- **History:**
  - 2026-10-12 W40.b2 — raised.

### S-013 · An `archivenotes://` link may be dropped when the Notes window is closed

- **Raised:** 2026-10-12 · W40.b2 · code reading while writing ledger row `N-46`.
- **Suspected behaviour:** `.onOpenURL` and both forwarding `onReceive`s are attached only to the Notes window's
  content (`ArchiveNotesApp.swift:46-59`). The Extracts window has none (`:71-80`). If the user has closed the
  Notes window, a link clicked in Scrivener or Reader depends on SwiftUI opening that `Window` scene to deliver
  the URL. If SwiftUI instead routes the event to the open Extracts window, or delivers it to no view, nothing
  happens. If the window opens late, the link may wait in `pendingOpen` until the next index change. The promise
  says the link opens its window if closed. `testG15_OpenRequestOpensTheClosedFeaturingWindow` covers only the
  in-app open request, and `NotesE2LinkTests` sends its URL with the Notes window open. No data is at risk. S3.
- **Where:** `ArchiveNotesApp.swift:36-59`, `:71-80`; ledger `N-46`.
- **Would confirm it:** in a VM UITest based on `NotesE2LinkTests.testE2_CopyLinkRoundTripSelectsTheLinkedNote`,
  copy a note's link, close the "Archive Notes" window (Extracts left open), then call `openInRunningApp(url)`.
  Confirmed if within 15 s the Notes window does not exist or its editor does not show the linked note. Run it a
  second time with both windows closed.
- **Would clear it:** in both runs the Notes window opens with the linked note loaded.
- **Status:** `cleared` — `W40.d10`, [`evidence/notes/W40.d10-integrations.md`](evidence/notes/W40.d10-integrations.md)
- **History:**
  - 2026-10-12 W40.b2 — raised.
  - 2026-10-15 W40.d10 — cleared: `IntegrationJourneyUITests.testD10_4_CopyLinkOpenedByTheOS` handed the copied link to the OS (no app named) with every window closed and again with only Extracts open; both times the Notes window opened on the linked note. 2 of 2 VM runs.

### S-014 · A recorded archive root that is no longer at its path reports "Source file not found"

- **Raised:** 2026-10-12 · W40.b2 · code reading while writing ledger row `N-37`.
- **Suspected behaviour:** `ReaderRootStore` keeps the root URL it resolved at launch or grant
  (`Links/ReaderRootStore.swift:294-305`, `:258`). If the archive folder is moved or renamed while Notes runs, or
  its volume is ejected, `root(for:)` still returns the old path. That holds if `startAccessingSecurityScopedResource`
  succeeds on a missing path, which is not checked. Then `resolveExact` misses, the basename search finds the root
  path wholly absent (`rootIsWhollyAbsent`, `Links/ReaderLinkResolver.swift:144`, `:351-361`) and returns
  `.exhausted`, and the popover says "Source file not found in the archive." with no "Choose Archive Folder…"
  button (`Views/ReaderPreviewPopover.swift:124`). The promise is that an unavailable root asks for access rather
  than calling the source missing. The code comment calls this the W8-S9 contract, so this may be design that
  the promise sources contradict. Misleading only, not on an irreversible path. S3.
- **Where:** `Links/ReaderLinkResolver.swift:202-236`, `:351-361`; `Links/ReaderRootStore.swift:186-197`; ledger `N-37`.
- **Would confirm it:** a unit test in `ReaderLinkScanTests` style. Grant a scratch root with a marker through
  `ReaderRootStore.grantRoot`, rename the root directory, then `await resolver.resolve(rootGUID:relativePath:)`
  for a file that was in it. Confirmed if the result is `.notFound`. Repeat the check with a relaunch-style fresh
  `ReaderRootStore` on the same defaults, which should give `.needsRootGrant` or `.resolved` through bookmark
  tracking.
- **Would clear it:** the in-session case yields `.needsRootGrant` or `.searchIncomplete`, or the owner rules that
  "not found" is correct for a vanished root and `W40.b5` corrects the promise.
- **Status:** `open`
- **History:**
  - 2026-10-12 W40.b2 — raised.

### S-015 · The list's `[`, `]` and `\` keys may fire inside the inline tag editor, and `\` would mark a file Read

- **Raised:** 2026-10-14 · W40.d8 · journey observation plus code reading.
- **Suspected behaviour:** while typing in a row's inline tag editor, `]`/`[` move the selection and `\` runs Mark
  Read & Advance, which writes the Read tag to the selected file. A tag write from a key typed into a text field
  is on an irreversible path. The same handler block's Space key was reproduced firing there (`W40.fix-reader-inline-keys`).
- **Where:** `ArchiveReader/macOS/Sources/ArchiveReader/Views/NavigationWindowView.swift:149-157` (the
  `.onKeyPress` cluster on the `AppKitTableView`, beside the Space handler at `:140`); ledger `R-20`, `R-23`.
- **Would confirm it:** in `TriageJourneyUITests`, focus a row's tag editor with the row already selected, type
  `]`, and check the selection moved. W40.d8 tried it once from an unselected row and the editor never took
  focus, so that run proves nothing either way.
- **Would clear it:** the editor keeps focus and the `]` lands in the field. Fixing
  `W40.fix-reader-inline-keys` should clear it at the same time, because it is the same handler path.
- **Status:** `open`
- **History:**
  - 2026-10-14 W40.d8 — raised.

### S-016 · Clicking a column header in the Notes list may not sort it

- **Raised:** 2026-10-16 · W40.e5 · Periphery reported the sort callback unused; confirmed by reading the code.
- **Suspected behaviour:** `tableView(_:sortDescriptorsDidChange:)` is an `NSTableViewDataSource` callback, but
  Notes implements it on `Coordinator` (`ArchiveNotes/macOS/Sources/ArchiveNotes/Views/NotesTableView.swift:389`),
  which is only the table's delegate, and the method is not `@objc`. The data source is
  `NotesTableDataSource` (`:522`, a `NSTableViewDiffableDataSource`), which does not implement or forward it. The
  columns do set `sortDescriptorPrototype` (`:101`), so a header click moves the sort arrow while the model's
  order stays as it was. Reader had the same defect and fixed it with `SortableDiffableDataSource`
  (`ArchiveReader/macOS/Sources/ArchiveReader/Views/AppKitTableView.swift:581-591`). Secondary sort, from the
  header menu, is a separate path and is not affected.
- **Where:** `Views/NotesTableView.swift:389-396`; ledger `N-09` (whose *Reached by* names this callback).
- **Would confirm it:** on the VM with the rehearsal store, click the Title header and read the row order; or a
  unit test that sets `tableView.sortDescriptors` on the live table and checks `NotesNavigationModel`'s sort.
  Confirmed if the order does not change.
- **Would clear it:** the rows reorder by title.
- **Status:** `open`
- **History:**
  - 2026-10-16 W40.e5 — raised.

### S-017 · A pre-OCRed Processor run drops the operator's per-document segmentation review

- **Raised:** 2026-10-16 · W40.e5 · Periphery reported the parameter unused; confirmed by reading the code.
- **Suspected behaviour:** `performPreOCRedProcessing` takes `reviewDocumentSegmentation`
  (`ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/OCRProcessor+OCR.swift:92`) but never uses it, and passes
  a literal `reviewDocumentSegmentation: false` to `performCollectionSegmentation` (`:246`). Its callers, a fresh run
  and a resume from PendingRun (`OCR/OCRProcessor+Pipeline.swift:1866`, `:2931`), pass the operator's persisted
  choice. So on a pre-OCRed input the "review document segmentation" step would be skipped even when it is on.
  It may be deliberate (pre-OCRed input has no images), but nothing says so. Git history traces it to the
  de-nest refactor or earlier.
- **Where:** `OCR/OCRProcessor+OCR.swift:81-92`, `:246`.
- **Would confirm it:** a headless driver run of a pre-OCRed scratch input with collection segmentation and
  document-segmentation review on. Confirmed if no review is requested.
- **Would clear it:** the review is requested, or a design note shows pre-OCRed runs are meant to skip it (then it
  is a doc and signature fix, not a bug).
- **Status:** `open`
- **History:**
  - 2026-10-16 W40.e5 — raised.

### S-018 · The Processor tells the user it paces to the subscription window, but OCR does not

- **Raised:** 2026-10-16 · W40.e5 · Periphery reported `LocalAgentClient.lastUsageWindowResetAt` written and never
  read.
- **Suspected behaviour:** on a CLI rate limit the app says "The app paces to your subscription window and
  retries" (`ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/LocalAgentClient.swift:329`), and
  `ArchiveProcessor/CLAUDE.md` (lines 90 and 473) promises "usage-window pacing" for the local-agent OCR path. The
  parsed reset time is stored in `lastUsageWindowResetAt` (`:54`, written at `:239`), whose comment says the OCR
  loop consumes it in `W13.cli-4`, but nothing reads it. Only segmentation (`Segmentation/WindowTransports.swift:285`)
  uses the parsed reset.
- **Where:** `OCR/LocalAgentClient.swift:54`, `:239`, `:329`.
- **Would confirm it:** a headless run of the local-agent OCR path against a stub CLI that reports a rate limit
  with a reset time. Confirmed if the run does not wait for that time before retrying. Kept until then (a
  promised feature, so not deleted); the Processor ledger (`W40.b3`) should carry it as a row.
- **Would clear it:** the run waits for the reset.
- **Status:** `open`
- **History:**
  - 2026-10-16 W40.e5 — raised.

### S-019 · Typing `-->` after an unclosed Notes block header may drop the lines before it

- **Raised:** 2026-10-20 · W40.e6 · the Tier-2 review of the unclosed-header fix, by code reading.
- **Suspected behaviour:** a degraded block (an unclosed `<!-- block: reader-doc` header, kept as text) is still
  live syntax. If the user types prose and then a line holding `-->` into it and saves, the next read takes
  everything up to that `-->` as the header, and `parseHeader` drops every header line without a colon
  (`ArchiveNotes/macOS/Sources/ArchiveNotes/Store/BlockParser.swift:236`), so the prose lines vanish. The same
  happened before the W40.e6 fix.
- **Where:** `Store/BlockParser.swift` `parseSegment` / `parseHeader`.
- **Would confirm it:** a unit test: decode a note whose body is `<!-- block: reader-doc\n link: x\nSome prose\nA --> B`,
  encode it, decode again, and look for "Some prose" in the blocks' markdown.
- **Would clear it:** "Some prose" survives.
- **Status:** `open`
- **History:**
  - 2026-10-20 W40.e6 — raised.

### S-020 · An extract built from a degraded Notes block may detach its text from the passage

- **Raised:** 2026-10-20 · W40.e6 · the Tier-2 review of the unclosed-header fix, by code reading.
- **Suspected behaviour:** `ExtractBuilder.flattenedNestedHeaders` (`ArchiveNotes/macOS/Sources/ArchiveNotes/Core/
  ExtractBuilder.swift:207`) keeps an unclosed opener in a passage's text. An extract covering a degraded block is
  then saved as a note-passage header followed by that opener; on reload the note-passage block is empty and the
  text is a separate freeform block with no provenance.
- **Where:** `Core/ExtractBuilder.swift:200-215`.
- **Would confirm it:** a unit test: build an extract from a note holding a degraded block, encode, decode, and
  check that the passage's block still holds the text.
- **Would clear it:** the passage keeps its text and its source.
- **Status:** `open`
- **History:**
  - 2026-10-20 W40.e6 — raised.

### S-021 · Android's Drive relay reports a segment signal as sent when the Drive write failed

- **Raised:** 2026-10-21 · W40.i2 · parity comparison, by code reading.
- **Suspected behaviour:** `DriveRelayTransport.segmentComplete` (`ArchiveProcessor/ArchiveCapture/app/src/main/java/
  com/archiveprocessor/capture/net/DriveRelayTransport.kt:88-93`) returns `true` after `upsert`, which swallows every
  exception. If the `<group>.segment.json` write fails, the phone records the segment as acked and never re-sends
  the signal, so the Mac shows no tag card for that segment until Finish force-completes it. iOS returns `false`
  here and retries.
- **Where:** `DriveRelayTransport.kt:33-40`, `:88-93`.
- **Would confirm it:** a test in `DriveRelayTransportTest` whose `MockDrive` answers the segment create with a 500:
  `segmentComplete` returns `true` and no segment object exists.
- **Would clear it:** `segmentComplete` returns `false` in that test.
- **Status:** `open`
- **History:**
  - 2026-10-21 W40.i2 — raised.

### S-022 · iOS may write a HEIC photo, or a wrongly rotated one, into a `.jpg` the Mac reads as JPEG

- **Raised:** 2026-10-21 · W40.i2 · parity comparison, by code reading.
- **Suspected behaviour:** `CameraController` (`ArchiveProcessor/ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Camera/
  CameraController.swift:63-92`) captures with default `AVCapturePhotoSettings()` and sets neither the codec nor the
  connection's orientation. If the default were HEVC, `fileDataRepresentation()` would be HEIC bytes saved as
  `img_*.jpg` and sent as `image/jpeg`. A portrait shot may also carry an orientation the Mac's pipeline does not
  apply.
- **Where:** `Camera/CameraController.swift:63-92`.
- **Would confirm it:** on a simulator with a camera stand-in, or the borrowed phone (`W40.i4`), capture one portrait
  and one landscape page and check the first bytes (`FF D8 FF`) and the EXIF orientation of what reaches the Mac.
- **Would clear it:** both files are JPEG and both read upright on the Mac.
- **Status:** `open`
- **History:**
  - 2026-10-21 W40.i2 — raised.

### S-023 · iOS uploads may be cut off whenever the phone leaves the app

- **Raised:** 2026-10-21 · W40.i2 · parity comparison, by code reading.
- **Suspected behaviour:** the iOS companion requests no background time (`beginBackgroundTask`) and uses a default
  `URLSession`. When the operator switches apps or locks the phone mid-upload, iOS suspends the process and the
  request fails; the 8 s auto-retry resends it on return. Nothing is lost, but uploads stall while the app is away,
  and a Mac waiting on Finish waits with it.
- **Where:** `Capture/CaptureViewModel.swift:416-460`, `Net/MacClient.swift`.
- **Would confirm it:** in the `W40.i3` simulator E2E, background the app during a multi-page upload and record
  whether in-flight requests fail.
- **Would clear it:** the uploads finish while the app is in the background.
- **Status:** `open`
- **History:**
  - 2026-10-21 W40.i2 — raised.

### S-024 · The key wizard reports a key as validated when the Keychain refused to save it

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** `ProviderKeyWizard.validate()` ignores `KeychainHelper.save`'s result
  (`ArchiveProcessor/macOS/Sources/ArchiveProcessor/Views/ProviderKeyWizard.swift:206`) and sets
  `keyValidated_<account>` (`:207`); `keyStatusChip` trusts that flag without checking a key exists
  (`Views/SettingsView.swift:735-737`). A locked or denying Keychain leaves Settings showing "Validated" over an empty
  key field, and the run then fails for want of a key.
- **Where:** `P-04`; the two lines above.
- **Would confirm it:** drive the wizard where `save` returns false (headless mode already makes it do so,
  `Models/KeychainHelper.swift:30`) and read the chip state.
- **Would clear it:** the chip reads "Save failed" or not-set in that run.
- **Status:** `open`
- **History:**
  - 2026-10-21 W40.b3 — raised.

### S-025 · The gateway's "Fill in OpenAI preset" picks a reasoning model the gateway request cannot drive

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** `applyOpenAIGatewayPreset` looks for the first OpenAI model with `!supportsThinking`
  (`Views/SettingsView.swift:1066`), but every entry in `LLMModel.openaiModels` is `supportsThinking: true`
  (`Models/ProviderModels.swift:351-391`), so it falls back to `gpt-5-nano`, a reasoning model. The gateway sends plain
  `max_tokens` (`OCR/OpenAICompatibleClient.swift:63`), which `CLAUDE.md` §OpenAI-compatible gateway says OpenAI's
  reasoning models reject. Every page of a run set up by the preset would fail.
- **Where:** `P-08`.
- **Would confirm it:** apply the preset and read `gatewayModelID`, then send one page through the no-wire seam and
  check the body; a single live page against OpenAI (under a cent) would show the 400.
- **Would clear it:** OpenAI accepts the request, or the preset picks a model that takes `max_tokens`.
- **Status:** `open`
- **History:**
  - 2026-10-21 W40.b3 — raised.

### S-026 · Batch OCR is not size-based: large images go up at full size

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** the direct path scales each image by `targetDimensionScale` toward the standard size; the
  batch path passes the raw slider fraction to `ImageEncoding.loadImageAsJPEG(scale:)`
  (`OCR/OCRProcessor+OCR.swift:787-801`, `OCR/BatchOCR.swift:59`), a plain dimension scale. At 100% a 10 MB scan is sent
  whole in batch, so batch costs and times exceed the estimate, which assumes size-based scaling.
- **Where:** `P-17`, `P-19`.
- **Would confirm it:** encode one oversized JPEG through both paths at 100% and compare the bytes sent.
- **Would clear it:** both paths send the same size.
- **Status:** `open`
- **History:**
  - 2026-10-21 W40.b3 — raised.

### S-027 · Batch mode is offered for providers with no batch, and still changes the run

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** the Batch toggle stays enabled for OpenAI, OpenRouter and the Local Agent
  (`Views/SettingsView.swift:758`). With it on, the cost panes show a batch total (`Views/OCRView.swift:701`,
  `Views/SettingsView.swift:295`) the run never gets (it goes standard, `OCR/OCRProcessor+Pipeline.swift:2857`), and the
  raw flag still drops per-page readers and the institutional import (`:2776`, `:2780`) — features the user turned on.
- **Where:** `P-03`, `P-14`, `P-15`, `P-19`.
- **Would confirm it:** OpenAI selected, Batch on, page kinds on: check the estimate and whether the run read pages
  with the per-kind reader.
- **Would clear it:** the toggle is disabled there, or those sites test `provider.supportsBatch`.
- **Status:** `open`
- **History:**
  - 2026-10-21 W40.b3 — raised.

### S-028 · A chosen folder is read one level deep; nested photos are silently left out

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** README promises a recursive search, but folder input uses `contentsOfDirectory`
  (`Views/OCRView.swift:1211`, `:1231`). A box folder with sub-folders adds only its top-level images, with no message;
  the user may believe a box was processed when part of it was not. Re-adding a file also appends a duplicate (`:1217`).
- **Where:** `P-22`.
- **Would confirm it:** a scratch folder holding `a/b/x.jpg` and `y.jpg`, dropped: count the rows.
- **Would clear it:** both files are listed.
- **Status:** `open`
- **History:**
  - 2026-10-21 W40.b3 — raised.

### S-029 · An LLM rotation failure silently falls back to the weaker local detector

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** when LLM rotation fails, or the route has none (gateway, Local Agent, Mistral), detection
  falls back to local Vision (`OCR/OCRProcessor+OCR.swift:1841-1851`, `OCR/LLMRotationDetector.swift:44-45`), which the
  app's help calls about 60% accurate (`Models/ProviderModels.swift:155`). Nothing records the fallback, so sideways
  pages can land in output PDFs that README says are always upright.
- **Where:** `P-25`.
- **Would confirm it:** a run of rotated synthetic scans with LLM rotation set and the key removed: check page 1
  orientation and whether anything reports the fallback.
- **Would clear it:** the fallback is reported, or the pages come out upright.
- **Status:** `open`
- **History:**
  - 2026-10-21 W40.b3 — raised.

### S-030 · The run log can give one failed file another's reason

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** `writeLogFile` finds each failure's job by base name
  (`OCR/OCRProcessor+Pipeline.swift:3419`), so two failing files with the same name in different folders both get the
  first one's reason. Its write is `try?` (`:3444`), so a failed log write is silent.
- **Where:** `P-26`.
- **Would confirm it:** a run with two same-named failing files from two folders, logging on.
- **Would clear it:** each line carries its own file's reason.
- **Status:** `open`
- **History:**
  - 2026-10-21 W40.b3 — raised.

### S-031 · Under a window segmentation approach, enclosures may get no `Sent With` date

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** the window prompts treat an enclosure as its own document
  (`Segmentation/WindowPrompts.swift:53`), but nothing in `Segmentation/` sets `enclosureOf`; the relation comes only
  from the OCR `[enclosure]` marker in `DocumentSegmenter`. If the window path bypasses that, a letter's enclosure
  loses its cover date.
- **Where:** `P-28`, `P-30`.
- **Would confirm it:** a window-approach run (recorded answers) on a letter plus an enclosure page carrying the
  marker: check the enclosure's tags for `Sent With`.
- **Would clear it:** `Sent With` is written.
- **Status:** `open`
- **History:**
  - 2026-10-21 W40.b3 — raised.

### S-032 · A segmentation approach with no key can be started, and fails only after the OCR is paid for

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** the chooser comment says an unavailable approach "is gated where the run starts"
  (`Views/SegmentationChooserView.swift:44-46`), but `canStartProcessing` (`Views/OCRView.swift:799`) does not check it.
  The run OCRs every page, then `WindowStageTransport.make` fails (`Segmentation/RunSegmentation.swift:225`) and the user
  is asked what to do after the spend.
- **Where:** `P-30`, `P-31`.
- **Would confirm it:** choose Gemini only with no Gemini key, three pages on a cheap OCR model; watch when the prompt
  appears.
- **Would clear it:** Start is disabled, or the run stops before OCR.
- **Status:** `open`
- **History:**
  - 2026-10-21 W40.b3 — raised.

### S-033 · A tag reply with no year and `date_uncertain: false` gets no date tags at all

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** `parseTagResponse` (`Tagging/TagGenerator.swift:170-181`) adds `Date Uncertain` only when
  the model says so; JSON with `year: null` and the flag false or absent yields a document with no year, no month and
  no `Date Uncertain`, against the promise that an undated document is always marked.
- **Where:** `P-33`.
- **Would confirm it:** feed that JSON to the parser in a driver and read the tags.
- **Would clear it:** `Date Uncertain` is forced when there is no year.
- **Status:** `open`
- **History:**
  - 2026-10-21 W40.b3 — raised.

### S-034 · No tagging and Copy source tags still write Box/Folder tags when collection segmentation is on

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** with collection segmentation on, `applyBoxFolderLabelTags`
  (`OCR/OCRProcessor+Tagging.swift:260`, from `OCR/OCRProcessor+Pipeline.swift:3176`) writes `Box` + Red or `Folder` +
  Purple in every mode. Under Copy source tags this replaces the copied source tags on those PDFs; under No tagging it
  writes tags the mode promises not to. A tag write on an irreversible path: worth a journey's time.
- **Where:** `P-35`; `SPEC/tag-format.md` §Invariant 6.
- **Would confirm it:** a scratch Copy source run with collection segmentation on and a tagged box photo; read the
  output's tags.
- **Would clear it:** the source tags survive (or the owner rules that Red/Purple belongs in those modes, and the SPEC
  says so).
- **Status:** `open`
- **History:**
  - 2026-10-21 W40.b3 — raised.

### S-035 · Resuming a batch skips the per-page review and the box/folder confirmation

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** `resumeBatch` (`OCR/OCRProcessor+Pipeline.swift:1556-1583`) segments straight from the
  stored classifications for non-window plans and tags with no Tagging Review. Skipping the Tagging Review is
  commented as deliberate (`:1572`); skipping the per-page dialog and the box/folder confirmation is not. A resumed
  batch files outputs the user never reviewed.
- **Where:** `P-32`, `P-37`, `P-40`.
- **Would confirm it:** `scripts/test-batch-resume.sh`-style resume of a finished batch under Automatic + Manual:
  record which review gates are raised.
- **Would clear it:** the dialog and confirmation are raised, or the skip is a recorded decision.
- **Status:** `open`
- **History:**
  - 2026-10-21 W40.b3 — raised.

### S-036 · An edited collection name is used as typed when the user clicks Confirm

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** the review sheet normalises a name only on Return
  (`Views/OCRView+CollectionReviewSheet.swift:127-130`); `applyReviewEdits` takes the typed text
  (`OCR/OCRProcessor+ReviewFlows.swift:224`), and `organizeOutput` builds the folder from it
  (`Tagging/CollectionSegmenter.swift:306`). A name with `/` makes filing throw part-way; `..` files outside the chosen
  output folder; an empty name files into the output folder itself. An output-path write: worth a journey's time.
- **Where:** `P-39`.
- **Would confirm it:** call `organizeOutput` (as `scripts/test-collection-organize.sh` does) with the names `a/b`,
  `..` and empty, in a scratch directory.
- **Would clear it:** each is normalised or refused before anything is filed.
- **Status:** `open`
- **History:**
  - 2026-10-21 W40.b3 — raised.

### S-037 · No pairing QR at all when the Mac's address is not on en0 or en1

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** `primaryIPv4()` (`Views/LiveCaptureView.swift:748-770`) looks only at en0 and en1. On a Mac
  whose only address is on another interface (a USB-C Ethernet adapter, or Wi-Fi off with a USB-tethered Android),
  `pairingPayload` is nil and the whole Pair the phone box disappears, manual host included — even though USB pairing
  needs no Wi-Fi address.
- **Where:** `P-43`.
- **Would confirm it:** in the VM, with the guest's only interface renamed off en0/en1 (or a stubbed address list),
  open Live Capture and Start.
- **Would clear it:** a QR or a fallback host is shown.
- **Status:** `open`
- **History:**
  - 2026-10-21 W40.b3 — raised.

### S-038 · Over the Drive relay, Finish cannot wait for the phone to drain

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** the drain gate is fed only by `POST /phone/status` (`Net/CaptureServer.swift:575-579`);
  `SPEC/relay-object-format.md` has no status object, so over the relay `phonePendingActive` is always false and Finish
  finalizes while photos are still on the phone, in segments still being shot.
- **Where:** `P-48`; `SPEC/relay-object-format.md`.
- **Would confirm it:** `scripts/test-filerelay.sh`-style session with an ended segment whose last page has not yet
  arrived: press Finish and count pages filed.
- **Would clear it:** Finish holds until the page lands.
- **Status:** `open`
- **History:**
  - 2026-10-21 W40.b3 — raised.

### S-039 · Stage for later can hand the same photos to Process Files twice

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** `stageForProcessing` (`Views/LiveCaptureView.swift:721`) neither removes nor marks the
  photos it hands off, so a second click, or one after a relaunch, sends the same photos again and they are OCRed and
  paid for twice; the existing filter blocks only photos whose output is already verified in staging.
- **Where:** `P-50`.
- **Would confirm it:** in a driver, hand off twice and count the files Process Files receives.
- **Would clear it:** the second hand-off is empty or refused.
- **Status:** `open`
- **History:**
  - 2026-10-21 W40.b3 — raised.
