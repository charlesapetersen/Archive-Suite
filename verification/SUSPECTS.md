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
- **Status:** `open`
- **History:**
  - 2026-10-12 W40.b2 — raised.

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
