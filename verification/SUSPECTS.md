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
- **Status:** `cleared` — fixed by `W40.fix-reader-undo-focus`, [`evidence/reader/W40.fix-reader-undo-focus.md`](evidence/reader/W40.fix-reader-undo-focus.md)
- **History:**
  - 2026-10-12 W40.b1 — raised.
  - 2026-11-04 owner session reader-1 — reproduced by hand on a session copy of the sample ([`sessions/reader-1-returned.md`](sessions/reader-1-returned.md) row 32): typing in the file-name filter, then ⌘Z, undid the last tag change and left the typing. Filed as `W40.fix-reader-undo-focus` (S2, Tier-2).
  - 2026-11-05 W40.fix-reader-undo-focus — fixed: a bare ⌘Z with an editable text view focused now undoes the typing and never reaches Undo Tag Change. The VM run above leaves the file's tags unchanged and removes the typed text; with the fix switched off the same run re-wrote the tags.

### S-002 · Reader's viewer, preview or thumbnails may download a cloud placeholder

- **Raised:** 2026-10-12 · W40.b1 · code reading while writing ledger row `R-04`.
- **Suspected behaviour:** the "never materialised" promise is enforced on the indexing and scan paths
  (`withDatalessMaterializationDisabled`) and on the link thumbnail. No such guard was seen on
  `DocumentViewerModel.load`, `PreviewSheet` or other thumbnail paths. If a user opens a dataless row, PDFKit may
  download the whole file. The cost is bandwidth and disk, not data loss.
- **Where:** `Views/DocumentViewerModel.swift` `loadCurrent`; `Views/PreviewSheet.swift`; ledger `R-04`.
- **Would confirm it:** on a real cloud-only PDF outside the corpus, `SF_DATALESS` clears after selection
  prefetch or opening the PDF, before the user approves a download.
- **Would clear it:** the file stays cloud-only through those paths and downloads when the user chooses
  **Download and Show**, as required by owner call 30 (2026-11-21).
- **Status:** `cleared` — fixed by `W49.fix-reader-dataless-prefetch`.
  [Original reproduction](evidence/reader/W49.reader-s002-dataless-viewer.md) ·
  [Independent reproduction and fix regression](evidence/reader/W49.reader-s002-reproduce-check.md)
- **History:**
  - 2026-10-12 W40.b1 — raised.
  - 2026-11-20 W49.notes-s007-reproduce (no test of the Reader) — the route for this check exists now. The owner's OneDrive holds dataless PDFs, and a bare `PDFDocument(url:)` on one downloads it, while the thread guard keeps it dataless ([`evidence/notes/W49.notes-s007-dataless-preview.md`](evidence/notes/W49.notes-s007-dataless-preview.md)). An engine session must set the process materialization policy back to on first: it inherits off.
  - 2026-11-20 W49.reader-s002-reproduce (Opus 5.5) — reproduced on the same OneDrive placeholder as S-007, and
    wider than raised. `loadDocument` (viewer and preview) opens it bare; the open downloaded the whole 6.2 MB file
    (2.5 s). Worse, the shipped `PreviewImagePrefetcher`, compiled into a probe and called as a list selection change
    calls it, downloaded it (1.6 s) to draw a bitmap: **selecting the row is enough**, preview shown or not, and the
    rows either side and the document window's neighbours are drawn too. Its `FileStamp` reads `SF_DATALESS`; nothing
    checks it. The neighbour open holds (`NeighbourCache.start` skips a dataless file, its comment saying that would
    download unasked), so the prefetcher's download is not deliberate; whether an explicit open may download is asked
    in the Daemon Report. `performFind` over a multi-file selection opens bare as well. Evicted after each run.
  - 2026-11-21 W49.reader-s002-reproduce-check (Codex gpt-6.2-sol) — the shipped selection prefetch
    and viewer model each cleared `SF_DATALESS` on a 6.2 MB non-corpus OneDrive PDF. The guarded control
    left it cloud-only, and it was evicted after both downloads. Owner call 30 requires **Download and Show**
    for an explicit open and prohibits downloads during selection, thumbnail rendering and neighbor prefetch.

### S-003 · A dead Reader content index still shows "No matches" in the list

- **Raised:** 2026-10-12 · W40.b1 · code reading while writing ledger row `R-12`.
- **Suspected behaviour:** with the index unavailable, an OCR query empties the list and shows the generic
  "No matches" overlay. The amber status-bar line names the failure, but
  the main area still reads as an answer. `W23.m9` promised a dead index is never answered as "no matches".
- **Where:** `NavigationWindowView.tableOverlay` and the `ar.status.indexFailure` status label; ledger `R-12`.
- **Would confirm it:** the corrupt-index VM fixture (`ContentIndexFailureUITests`): type an OCR query and take a
  screenshot of the list area. Confirmed if it says "No matches" while the failure line shows.
- **Would clear it:** the overlay says the index is unavailable, or no overlay is drawn while the failure line
  shows.
- **Status:** `cleared` — fixed by `W49.fix-reader-dead-index-overlay` (S3). Regressions:
  `DeadIndexEmptyListSuspectTests` and `ContentIndexFailureUITests`.
  [Opus 5.5 model reproduction](evidence/reader/W49.reader-s003-dead-index.md) and
  [Codex gpt-6.2-sol VM reproduction](evidence/reader/W49.reader-s003-reproduce-check.md).
- **History:**
  - 2026-10-12 W40.b1 — raised.
  - 2026-11-20 W49.reader-s003-reproduce (Opus 5.5) — reproduced on the model, scratch data. With the indexer on a
    1 KiB garbage index file, an OCR query records `.unavailable` (the amber line) and `searchRanked` returns an empty
    path set, not nil, so `ftsPaths = []`, the list empties, and `LibraryEmptyState.forPhase` gives `.filteredOut`:
    the "No matches" overlay, its sentence "The OCR search “smith” hides every file." and a Clear Text button.
    Nothing on that path reads `indexFailure`. Not deliberate: `openForQuery`'s comment names exactly this outcome
    as what W23.m9 prevents; the overlay's sentence came later (`W40.fix-reader-filter-bar`). The check is an
    `XCTExpectFailure`. Pixels not captured; the view's switch has no other input.
  - 2026-11-21 W49.reader-s003-reproduce-check (Codex gpt-6.2-sol) — typed “California” in the
    real window on the generated VM fixture. The list went from 12 rows to zero and showed “No matches”
    and “The OCR search ‘California’ hides every file.” while the status bar reported the failure.

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
- **Status:** `cleared` — not reproduced; tests `ViewStateRootChangeTests` (ArchiveReaderTests)
- **History:**
  - 2026-10-12 W40.b1 — raised.
  - 2026-11-20 owner walkthrough (call 24) — reproduce attempt queued as `W49.reader-s004-reproduce`.
  - 2026-11-20 W49.reader-s004-reproduce — cleared with the test the entry asks for, on the real bookmark path (the
    fixture pin turns view-state restore off, so it could not show the defect): root A is granted, scoped to its
    "Box 1" and its view state saved; root B is granted in the same defaults domain and a new `NavigationModel` is
    built. `RootFolderStore.init` resolves the bookmark synchronously (`resolveSaved`), and `rootStore` is assigned
    before `restoreViewState()` runs, so `discoveredPathPrefix` is already B's: the prefix is dropped, the rest of
    the view state is kept, and B lists its file. A control test keeps the scope under its own root. The only time
    the prefix passes through is a launch where the bookmark does not resolve (no root, so no list); a later pick
    goes through `chooseRoot`, which clears `filter.pathPrefix`.

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
- **Status:** `cleared` — fixed by `W49.fix-reader-encrypted-pdf`. Regressions:
  `ArchiveReaderTests/EncryptedPDFSuspectTests`. [Scratch reproduction](evidence/reader/W49.reader-s005-reproduce-check.md).
- **History:**
  - 2026-10-12 W40.b1 — raised.
  - 2026-11-20 owner walkthrough (call 24) — reproduce attempt queued as `W49.reader-s005-reproduce`.
  - 2026-11-20 W49.reader-s005-reproduce (Opus 5.5) — the code still reads as the entry says: nothing in the Reader
    checks `isLocked`/`isEncrypted`, and `loadDocument` sets `loadError` only for a nil document or zero pages. A
    two-page text PDF written on scratch with `kCGPDFContextUserPassword` was run through the real pipeline.
    **Indexer: holds.** `PDFHeaderParser.extract` (ArchiveCore `ExtractedContent.swift`) already returns nil for a
    locked document, so a real `ContentIndexer` pass stores the row `.unreadable` ("Unreadable"; it does not say
    why). **Viewer: reproduced.** `DocumentViewerModel.load` gets a locked `PDFDocument` with its real page count
    (2) and no readable text: `loadError` is nil and `formatNote` says "No OCR text layer — this document is
    image-only…", which is wrong for a text PDF behind a password, and nothing mentions a password or encryption.
    Not deliberate: `PDFFormatStatus`'s comment counts an encrypted PDF as unreadable. The viewer check is an
    `XCTExpectFailure`, so the bundle stays green until a fix removes it. Cosmetic or misleading, no data loss.
  - 2026-11-21 W49.reader-s005-reproduce-check (Codex, gpt-6.2-sol, `ba39eeb4`) — a separately
    generated, qpdf-encrypted text PDF loaded locked with two pages, no load error and the image-only
    banner. Its plaintext control showed no banner; PDFKit could read the encrypted copy’s text after
    unlocking it separately. The existing indexer test still marked its locked fixture unreadable.
  - 2026-11-21 W49.fix-reader-encrypted-pdf (Codex, gpt-6.2-sol) — both a direct open and a switch to a
    prepared locked PDF show the password error without the image-only note. Switching back to a readable
    PDF clears the error. The indexer still classifies the locked file as unreadable.

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
- **Status:** `cleared` — fixed by `W49.notes-s006-fix`; test
  `QualityWriteTests.archiveSuiteSubjectSurvivesBodySave` (ArchiveNotesTests) passes without `withKnownIssue`
- **History:**
  - 2026-10-12 W40.b2 — raised.
  - 2026-11-20 owner walkthrough (call 27) — reproduce attempt queued as `W49.notes-s006-reproduce`.
  - 2026-11-20 W49.notes-s006-reproduce — reproduced with the unit test above on a scratch store, and worse than
    suspected: the tag is already missing straight after `setTags(["ArchiveSuite"])`, before any body save, because
    `mutateItem` runs the facet reconciliation after the subject projection in the same save. The front-matter
    subject stays `ArchiveSuite` throughout, so the Finder mirror never carries it. The test's Finder checks are
    wrapped in `withKnownIssue` until `W49.notes-s006-fix` lands; the fix removes the wrapper.
  - 2026-11-20 W49.notes-s006-fix — cleared: the facet path's `desired` keeps a current `ArchiveSuite` subject. The
    test now passes plainly, and also checks that removing the subject removes the tag. Notes unit bundle: 1244 passed.

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
- **Status:** `cleared` — fixed by `W49.notes-s007-fix`, [`evidence/notes/W49.notes-s007-dataless-preview.md`](evidence/notes/W49.notes-s007-dataless-preview.md)
- **History:**
  - 2026-10-12 W40.b2 — raised.
  - 2026-11-20 owner walkthrough (call 27) — reproduce attempt queued as `W49.notes-s007-reproduce`.
  - 2026-11-20 W49.notes-s007-reproduce — reproduced on a real OneDrive placeholder (a 6.2 MB personal PDF, no corpus file). The popover's bare `PDFDocument(url:)` downloaded the whole file in 1.9 s and cleared `SF_DATALESS`. Inside the thread guard the file stayed dataless and the open returned nil. The file was evicted again afterwards. Engine sessions run with materialization off process-wide, so a probe has to set the process policy back to on to see this. Filed `W49.notes-s007-fix`.
  - 2026-11-20 W49.notes-s007-fix — fixed. The preview stats the file first and opens it inside the thread guard; a placeholder gets a message and a "Download and Show" button. Re-probed on the same OneDrive placeholder: the preview left it dataless (0.00 s), the button downloaded it (2.9 s) and the preview then showed all 54 pages; evicted again afterwards. Cleared.

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
- **Status:** `cleared` — `W49.notes-suspects-small`, VM test `ArchiveNotesUITests/NotesWindowSizeQuitUITests` `testB_ResizeThenQuitKeepsTheSize`
- **History:**
  - 2026-10-12 W40.b2 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.notes-suspects-small` under phase rule 5a.
  - 2026-11-20 W49.notes-suspects-small — cleared. The code is unchanged (the size is still written only from
    `onDisappear`, `Views/NotesBrowserView.swift:155`), but a quit runs it. In the VM (macOS 27.2), with
    `-ANUITestPersistWindowSize YES` (new, DEBUG: saves the size as a normal launch does): the control resized the
    window to 1536×699, closed it, quit, and relaunched at 1536×699; then, with that size saved, the window was
    resized to 1479×612 and quit from Archive Notes ▸ Quit at once, and it relaunched at 1479×612. Two runs, same
    result. Had the quit not saved it, the relaunch would have applied the older 1536×699.

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
- **Status:** `cleared` — fixed by W49.fix-notes-raw-image-paste. [Paste verification](evidence/notes/W49.notes-suspects-text-check.md#s-009-fix-verification). Regression `NotesTextLossSuspectTests.s009RawModeImagePaste`.
- **History:**
  - 2026-10-12 W40.b2 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.notes-suspects-text` under phase rule 5a.
  - 2026-11-20 W49.notes-suspects-text — reproduced. The code is unchanged in substance (`tryPasteImage`, now
    `Editor/EditorTextView.swift:1218`, checks `isEditable` and the asset store, not raw mode; the store stays wired in
    raw mode, `MarkdownEditorView.swift:138`, `:252`). An app-hosted test puts a real `EditorTextView` in raw mode
    (`applyRawMode(true, …)`) with a scratch asset store, seeds PNG bytes and sends `paste(nil)`, the ⌘V action.
    `assets/pasted-….png` is written and the text becomes `"Raw body\n\u{FFFC}"`, which is what raw write-back saves
    (`currentSerialization` returns `textView.string`). No comment or document promises an image paste in raw mode;
    G4 switches to styled mode first. Not run in the VM: the second session may confirm it there with the G4 variant
    above.
  - 2026-11-21 W49.notes-suspects-text-check (Codex, gpt-6.2-sol, `7252c39b`) — The off-screen VM raw-toggle and G4 paste path wrote a byte-identical PNG to the item. Its saved Markdown held one U+FFFC and no reference to the PNG. This check exercised paste.

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
- **Status:** `cleared` — W49.fix-notes-multi-remove. Scratch regressions: `NotesSmallSuspectTests.s010MultiRemove` and `NotesE2NoteLifecycleTests.testS010_MultiRemoveAsksAboutBothNotes`. [Original reproduction](evidence/notes/W49.notes-suspects-small-check.md).
- **History:**
  - 2026-10-12 W40.b2 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.notes-suspects-small` under phase rule 5a.
  - 2026-11-20 W49.notes-suspects-small — reproduced. The code is unchanged in substance (the row menu's loop is now
    `Views/NotesContextMenu.swift:140`, `pendingDeletion` assigned in `NotesNavigationModel.removeMembership`, `:580`).
    On a scratch store, notes A and B filed only in F and C in F and G, scoped to F: the real row menu's
    "Remove 3 Items from “F”" item fired. C left F quietly and one alert was pending, for A or B (the selection is a
    set, so which one varies). Confirming it trashed the note it named, and only that one; the other stayed filed in
    F with no alert. Nothing was deleted beyond what was confirmed. The menu comment says "confirms one at a time",
    which promises more than happens, so this is not intended behaviour.
  - 2026-11-21 W49.notes-suspects-small-check (Codex, gpt-6.2-sol, `b0539267`) — The VM alert named one of two selected sole-instance notes. Confirming moved precisely that note into the fixture Trash. The other stayed in Reading with no second prompt.
  - 2026-11-21 W49.fix-notes-multi-remove — The VM row menu produced two named prompts. Confirming the first
    moved its note to the library Trash. Escape on the second kept its note in Reading. The scratch unit
    regression also checks that confirming a newly replicated note only unlinks it from the source folder.

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
- **Status:** `cleared` — fixed by W49.fix-notes-template-create. Regressions `NotesSmallSuspectTests.s011RowMenuSkipsFlush` and `s011RowMenuSkipsFailedSaveGuard`. [Original reproduction](evidence/notes/W49.notes-suspects-small-check.md#s-011--the-row-command-creates-from-the-saved-template-body).
- **History:**
  - 2026-10-12 W40.b2 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.notes-suspects-small` under phase rule 5a.
  - 2026-11-20 W49.notes-suspects-small — reproduced, both halves. The toolbar's route is now
    `NewItemFlow.create` (`ArchiveNotesCommands.swift:166`), whose comment calls it "the one creation path behind
    every New"; the row menu (`Views/NotesContextMenu.swift:56`) still calls `model.newItem` directly. With note
    template T open in a template body editor wired as `TemplateBodyEditorPane` wires it (scratch store): a marker
    typed and still waiting to save is missing from the note the row menu's New from Template ▸ T makes, and
    present in one `NewItemFlow` makes. With T's last body save refused (read-only template folder),
    `NewItemFlow` makes nothing and the row menu makes a note from the stale body.
  - 2026-11-21 W49.notes-suspects-small-check (Codex, gpt-6.2-sol, `b0539267`) — Dispatching the AppKit row command created from the prior saved body both with a flush pending and after a real failed scratch save. Standard New flushed the first draft and refused creation after the failed save.
  - 2026-11-21 W49.fix-notes-template-create — The row command flushes the draft before reading the
    template. A scratch write refusal blocks creation, and restoring write access lets the command
    create a note with the recovered body. The off-screen row submenu check creates a fresh note
    with the named template's title, kind and body.

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
- **Status:** `cleared` — fixed by W49.fix-notes-tag-filter-case. Regression `NotesSmallSuspectTests.s012TagFilterCase`. [Original reproduction](evidence/notes/W49.notes-suspects-small-check.md#s-012--an-exact-lowercase-tag-can-hide-a-note-with-that-tag).
- **History:**
  - 2026-10-12 W40.b2 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.notes-suspects-small` under phase rule 5a.
  - 2026-11-20 W49.notes-suspects-small — reproduced, narrower than raised. Since the suspect was written the
    filter bar's field became `NoteTagChipsField` over `SubjectEntryField` with `fillsInAnyCase`, so a prefix
    ("inte") fills in "Intel" and Return adds the stored spelling. A tag typed in full in another case gets no
    completion (`TagEntry.completions` leaves out a case-insensitive exact match, and `filledInIndex` fills in
    nothing for one), so Return adds "intel" as typed (`NoteTagChipsField.add` only trims) and
    `NotesFilter.matches` compares exactly (`Models/NotesFilter.swift:101`). On a scratch store a note given
    "intel" through `NotesModel.addTag` is stored "Intel" and the list filtered by "intel" is empty. The comment
    there says "the filter bar supplies canonical tokens", which it does not for this case. Advanced Search
    lower-cases both sides (`NotesAdvancedSearch.swift:242`), so it finds the note.
  - 2026-11-21 W49.notes-suspects-small-check (Codex, gpt-6.2-sol, `b0539267`) — The VM confirmed the exact-input path. The filter chip `fieldwork` hid the note tagged `Fieldwork` on disk. After clearing, the chip `Fieldwork` found it. The complete token was pasted and submitted with Return.
  - 2026-11-21 W49.fix-notes-tag-filter-case — The filter bar now compares full tags without regard to
    capitalization, like the saved rules. The scratch regression submits `intel` against `Intel`,
    excludes `Intelligence`, and applies the saved smart folder with the same result.

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
- **Status:** `cleared` — fixed by W49.fix-notes-moved-root. Regression `NotesSmallSuspectTests.s014MovedRoot`. [Original reproduction](evidence/notes/W49.notes-suspects-small-check.md#s-014--the-source-still-exists-after-an-archive-folder-rename).
- **History:**
  - 2026-10-12 W40.b2 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.notes-suspects-small` under phase rule 5a.
  - 2026-11-20 W49.notes-suspects-small — reproduced, and asked rather than queued (rule 5a(3)). The code is
    unchanged (`ReaderRootStore.root(for:)` returns the active scope's URL; the basename scan's
    `rootIsWhollyAbsent` branch returns `.exhausted`, `Links/ReaderLinkResolver.swift:352-360`). A scratch root
    granted with its marker, a link into it resolved once, the folder renamed: the same resolver then answers
    `.notFound` ("Source file not found in the archive."). A fresh `ReaderRootStore`, as after a relaunch,
    resolves the link at the moved folder through its bookmark. The comment beside the branch, and the accepted
    `KNOWN_ISSUES.md` bullet from W23.m14, call "a stale root reports the file missing" the shipped W8-S9 rule, so
    whether the in-session answer should ask for the folder instead is the owner's call.
  - 2026-11-20 owner walkthrough of 13:42 (call 29) — option (a): when the root was moved or renamed in session,
    Notes asks for the folder (Choose Archive Folder) or says the search could not finish; it never says the file is
    gone. The fix follows the independent check `W49.notes-suspects-small-check`.
  - 2026-11-21 W49.notes-suspects-small-check (Codex, gpt-6.2-sol, `b0539267`) — The production chooser and resolver with isolated scratch bookmarks returned `.notFound` after an in-session rename, even with the old preview scope released. A fresh root store located the original file at the new path. Reopening the same source preview in the VM displayed “Source file not found in the archive.”
  - 2026-11-21 W49.fix-notes-moved-root — The focused VM test granted a scratch archive, previewed
    `sample.pdf`, renamed the archive and reopened the same source. The preview said the search did not
    finish. The unit regression also resolved the PDF through the bookmark with a fresh root store.

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
- **Status:** `cleared` — `W40.fix-reader-inline-keys`, [`evidence/reader/W40.fix-reader-inline-keys.md`](evidence/reader/W40.fix-reader-inline-keys.md)
- **History:**
  - 2026-10-14 W40.d8 — raised.
  - 2026-10-31 W40.fix-reader-inline-keys — cleared: with the fix, `]`, `[` and `\` typed into the focused inline editor of a selected row landed in the field; the selection did not move and nothing was written (VM, `TriageJourneyUITests` step 2a). The run before the fix was not repeated with these keys, so whether they fired there is not known; the guard now covers them.

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
- **Status:** `cleared` — fixed by W49.fix-notes-header-sort. Regression `NotesSmallSuspectTests.s016HeaderSort`. [Original reproduction](evidence/notes/W49.notes-suspects-small-check.md#s-016--title-column-clicks-change-the-arrow-and-leave-the-rows-in-place).
- **History:**
  - 2026-10-16 W40.e5 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.notes-suspects-small` under phase rule 5a.
  - 2026-11-20 W49.notes-suspects-small — reproduced. The code is unchanged (the callback is now
    `Views/NotesTableView.swift:531`, on `Coordinator`, the delegate; `NotesTableDataSource`, `:799`, does not
    answer it). The real `NotesTableView` hosted over two scratch notes, and the Title column's own sort prototype
    set as the table's sort descriptors (what a header click does): the header takes the Title sort, the model's
    sort and the row order stay by date, and the data source does not respond to
    `tableView(_:sortDescriptorsDidChange:)`. Called by hand, the coordinator's handler sorts by title.
  - 2026-11-21 W49.notes-suspects-small-check (Codex, gpt-6.2-sol, `b0539267`) — Two actual Title header clicks flipped the sort arrow in the VM. The three fixture notes kept the same row order.
  - 2026-11-21 W49.fix-notes-header-sort — After wiring the data-source callback, the two clicks reordered the
    three fixture notes by Title ascending and then descending in the focused VM regression.

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
- **Status:** `cleared` — `W49.proc-suspects-filing`, `ArchiveProcessor/scripts/repro-suspects-filing.sh` `s017-preocred`
- **History:**
  - 2026-10-16 W40.e5 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.proc-suspects-filing` under phase rule 5a.
  - 2026-11-20 W49.proc-suspects-filing — cleared. The parameter is still dead (`OCR/OCRProcessor+OCR.swift:98`) and
    `false` is still passed on (`:254`), but the pre-OCRed path raises the per-page review and the box/folder
    confirmation itself (`:184-189`), under the same condition as the image path. A real Process Files run on six
    scratch text-layer PDFs (Pre-OCRed, Automatic, Collection ID and Review document segmentation on, the stand-in
    gateway) raised the whole-run document review, the box/folder confirmation and the final review. The literal
    `false` matches the image path (`OCR/OCRProcessor+Pipeline.swift:3621`); that the setting does nothing on any fresh
    run is S-046.

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
- **Status:** `fixed` — W49.proc-fix-s018: the Codex and Gemini message no longer promises pacing. [Independent VM evidence](evidence/processor/W49.proc-suspects-messages-check.md).
- **History:**
  - 2026-10-16 W40.e5 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.proc-suspects-messages` under phase rule 5a.
  - 2026-11-20 W49.proc-suspects-messages — reproduced, narrower than raised. The Claude CLI now waits for the reset
    (W41.app-claude-plan-reading): a stub reporting a limit 45 s ahead was called again at 105 s and the page read. The
    Codex CLI, same stub: one call, the page failed at once with "… The app paces to your subscription window and
    retries." No wait and no retry. The Gemini CLI takes the same branch (code). `lastUsageWindowResetAt` is still never
    read.
  - 2026-11-21 W49.proc-suspects-messages-check (Codex gpt-6.2-sol, baseline `8e89c29b`) — Codex reported a known reset, but the app ended the page after one invocation and said it would pace and retry.
  - 2026-11-24 W49.proc-fix-s018 — fixed by the message: the unverified adapters keep failing the page without waiting (W41.app-claude-plan-reading's design), and now say the page was not read and to retry after the reset. Claude's wait is unchanged.

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
- **Status:** `cleared` — fixed by W49.fix-notes-unclosed-header. [Save and reopen evidence](evidence/notes/W49.notes-suspects-text-check.md#s-019-fix-verification). Regression `NotesTextLossSuspectTests.s019TypedCloserAfterUnclosedHeader`.
- **History:**
  - 2026-10-20 W40.e6 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.notes-suspects-text` under phase rule 5a.
  - 2026-11-20 W49.notes-suspects-text — reproduced through the editor, not only the parser. A scratch note whose
    file ends in the cut-off header `<!-- block: reader-doc\n     link: …a.pdf\n` is loaded from a scratch
    `NoteStore`, rendered into a real `EditorTextView`, and the user's typing is sent at the end (Return, `Some prose`,
    Return, `A --> B`); the editor's text is saved with `saveBody` and loaded again. The file then holds
    `link: …a.pdf\n\nSome prose\ -->` as the header and the block reloads as a `reader-doc` whose text is ` B`:
    `Some prose` is gone (`parseHeader` skips a line with no colon, `Store/BlockParser.swift:287`), and the next save
    writes it off disk. Without the first Return the prose is joined onto the link line (see S-043) and ends up inside
    the `link:` value. No comment calls the dropped lines deliberate.
  - 2026-11-21 W49.notes-suspects-text-check (Codex, gpt-6.2-sol, `7252c39b`) — The styled editor showed the typed prose and the text after the closer. The prose was already missing from the first saved Markdown and remained absent when the note reopened.

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
- **Status:** `cleared` — not reproduced; test `ArchiveNotesTests/NotesTextLossSuspectTests` `s020ExtractOfDegradedBlock`
- **History:**
  - 2026-10-20 W40.e6 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.notes-suspects-text` under phase rule 5a.
  - 2026-11-20 W49.notes-suspects-text — cleared. `flattenedNestedHeaders` no longer exists:
    `W40.fix-notes-block-marker-in-text` replaced it with the header-line escape, so `BlockParser.serialize` writes the
    opener inside a passage as `\<!-- block: reader-doc`, which reads back as text. The user's path, run on a scratch
    store: a note of `Intro line.` and a degraded block with `Quoted prose.`, rendered in a real `EditorTextView`,
    select all, `createExtract(fromSelectionIn:)`, reload. Both blocks of the extract are note-passages with their
    source, and the degraded block's opener and `Quoted prose.` stay inside the second passage.

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
- **Status:** `fixed` — W49.proc-fix-s021 returns the Drive write result and keeps failed completions queued. [Scratch evidence](evidence/processor/W49.relay-suspects-check.md).
- **History:**
  - 2026-10-21 W40.i2 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.relay-suspects` under phase rule 5a.
  - 2026-11-20 W49.relay-suspects — reproduced. The code still says it. The real `CaptureViewModel` (Robolectric):
    restored segment with its page on the Mac, cloud pairing, End segment, Skip; the real transport against the mock
    Drive answering the segment create with a 500. One create, refused, no retry; no segment object; the group left
    `endedSegments` on disk; a re-pair sent nothing. The comment it rests on is about photos; iOS returns `false`.
  - 2026-11-21 W49.relay-suspects-check (Codex gpt-6.2-sol at `5fa81705`, original Claude Opus 5.5 in `ae75bd87`) — Fresh capture through the Android view model received a valid photo receipt. The first completion create got a 500, the manifest cleared the pending segment, and cloud re-pair made no second create. The success control published the completion.

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
- **Status:** `reproduced` (orientation) · format cleared
- **History:**
  - 2026-10-21 W40.i2 — raised.
  - 2026-10-31 owner session iphone-1, task 6 (`sessions/iphone-1-returned.md`) — format cleared: both files `ffd8ff`.
    Orientation confirmed: both 4032×3024 with no EXIF orientation; the sideways shot filed upside down (rotation
    correction off). Filed as `W40.fix-ios-landscape-orientation`.
  - 2026-11-01 `W40.fix-ios-landscape-orientation` — fixed in code: each shot sets the device's rotation angle on the
    photo connection, so the JPEG carries its EXIF orientation. Re-check on the phone: task 6 of the iPhone pack.
  - 2026-11-13 `W46.capture-companions` — the codec is now set explicitly: each shot asks for JPEG when the output
    offers it, so the format no longer rests on the default.

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
- **Status:** `reproduced` (expected behaviour; no fix filed)
- **History:**
  - 2026-10-21 W40.i2 — raised.
  - 2026-10-23 W40.i-sim-ui — narrowed in the simulator: with three unsent pages and the Mac down, the app was sent to
    the background (Home), the Mac restarted, and all three reached the Mac while the app was away (Mac count 3 → 6
    before the app was brought back; five runs, `evidence/capture/W40.i-sim-ui.md`). Switching apps does not stall
    uploads there. Left open for a locked real phone, where iOS suspends harder (`sessions/iphone-1.md` task 7).
  - 2026-10-31 W40.i-usb-build — the iPhone's new cable route (W40.i-usb-*) behaves the same way by design: no
    background mode, so a suspended app's tunnels and relay go defunct; on return from the background the app
    re-creates both listeners and the Mac's 2 s top-up and 20 s idle expiry find them, with the 8 s auto-retry
    re-sending (`ArchiveProcessor/REFERENCE.md` §USB local relay). Same open question, now for both routes; the
    iPhone pack checks recovery after a lock over the cable too.
  - 2026-10-31 owner session iphone-1, task 5 (`sessions/iphone-1-returned.md`) — confirmed on the owner's iPhone over the
    cable: with the phone locked, sending stopped (34 s with no page) and resumed by itself on return; nothing lost.
    The limitation entry in `ArchiveProcessor/KNOWN_ISSUES.md` (cable route) records it.

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
- **Status:** `cleared` — fixed by W49.proc-fix-s024. [Independent VM reproduction](evidence/processor/W49.proc-suspects-messages-check.md).
- **History:**
  - 2026-10-21 W40.b3 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.proc-suspects-messages` under phase rule 5a.
  - 2026-11-20 W49.proc-suspects-messages — reproduced. The code still says it. The wizard's step for a passed check,
    run with `save` refusing (headless), then the key row as it reloads: `save` returned false, the field reloaded empty,
    and the chip was "Validated" (Gemini and OpenAI). The button press itself was not driven. Nothing calls it deliberate.
  - 2026-11-21 W49.proc-suspects-messages-check (Codex gpt-6.2-sol, baseline `8e89c29b`) — The OpenAI wizard passed the synthetic provider check. Returning to Accounts showed Validated beside an empty OpenAI key field.
  - 2026-11-22 W49.proc-fix-s024 — the off-screen regression checks the provider success and save warning in
    the wizard, then checks **Save failed** beside the empty OpenAI field after returning to Accounts.

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
- **Status:** `open` — preset and request mismatch confirmed and queued as W49.proc-fix-s025. Live OpenAI response remains open. [Independent VM evidence](evidence/processor/W49.proc-suspects-messages-check.md).
- **History:**
  - 2026-10-21 W40.b3 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.proc-suspects-messages` under phase rule 5a.
  - 2026-11-20 W49.proc-suspects-messages — reproduced up to the wire. The preset now falls back to GPT-5.4 mini, not
    GPT-5 nano (still `supportsThinking: true`). One photo through the preset's gateway: the request to
    api.openai.com named `gpt-5.4-mini` with `max_tokens: 8192` and no `max_completion_tokens`. OpenAI's 400 was not
    observed (no OpenAI key here); it rests on the app's own statement. The preset's comment means a model the request
    works with, so not intended.
  - 2026-11-21 W49.proc-suspects-messages-check (Codex gpt-6.2-sol, baseline `8e89c29b`) — The preset fills GPT-5.4 mini, which supports reasoning, while the help promises a non-reasoning model. Starting a run built a request with the deprecated max_tokens field. Live OpenAI acceptance remains open.

### S-026 · Batch OCR is not size-based: large images go up at full size

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** the direct path scales each image by `targetDimensionScale` toward the standard size; the
  batch path passes the raw slider fraction to `ImageEncoding.loadImageAsJPEG(scale:)`
  (`OCR/OCRProcessor+OCR.swift:787-801`, `OCR/BatchOCR.swift:59`), a plain dimension scale. At 100% a 10 MB scan is sent
  whole in batch, so batch costs and times exceed the estimate, which assumes size-based scaling.
- **Where:** `P-17`, `P-19`.
- **Would confirm it:** encode one oversized JPEG through both paths at 100% and compare the bytes sent.
- **Would clear it:** both paths send the same size.
- **Status:** `fixed` — W49.proc-fix-s026. [Scratch VM verification](evidence/processor/W49.proc-suspects-money-check.md#s-026-fix-verification).
- **History:**
  - 2026-10-21 W40.b3 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.proc-suspects-money` under phase rule 5a.
  - 2026-11-20 W49.proc-suspects-money — reproduced, narrower than raised. The code still says it (batch passes the
    slider to `loadImageAsJPEG(scale:)`, `OCR/OCRProcessor+OCR.swift:845-859`). Two noise scans at 100%, Gemini direct
    then batch, redirected to the stand-in: a 2000×1500, 8.8 MB scan went up at 1169×877 (0.9 MB) direct and as the file
    itself in batch; a 6000×4000 scan at 1606×1071 direct and 2048×1365 in batch. Both paths cap at 2,048 px, so a scan
    goes up whole only when it is already within the cap. Nothing calls it deliberate.
  - 2026-11-21 W49.proc-suspects-money-check (Codex gpt-6.2-sol at `f2b51e98`, original Claude Opus 5.5 in `325a3455`) — At 100% and the 3 MB standard size, direct Gemini sent 602,467 B at 985×739. Batch sent the original 12,349,513 B at 2000×1500. Both routes retain the 2,048-pixel cap.
  - 2026-11-24 W49.proc-fix-s026 (Claude Opus 5.5) — fixed: the three batch builders scale by `targetDimensionScale` with the run's standard size. Direct and batch sent the same 985×739, 602,467 B JPEG; a flat 4000×3000 batch image went up at 2048×1536.

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
- **Status:** `fixed` — W49.proc-fix-s027. [Scratch VM verification](evidence/processor/W49.proc-suspects-money-check.md#s-027-fix-verification).
- **History:**
  - 2026-10-21 W40.b3 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.proc-suspects-money` under phase rule 5a.
  - 2026-11-20 W49.proc-suspects-money — half cleared, half reproduced. The toggle is now disabled without a batch
    provider (W40.fix-processor-settings-backend-mismatch), but a flag left on is still passed on (`Views/OCRView.swift:1762`).
    OpenAI, every page given a GPT-5 nano reader: with the stored flag on, the run went standard and all four pages were
    read by GPT-5.4 mini instead, and the estimate's batch figure was $0.0105 against $0.0210; off, all four went to
    GPT-5 nano. The pane's batch line tests the raw flag (code; not drawn). Nothing intends a run with no batch to lose
    its readers.
  - 2026-11-21 W49.proc-suspects-money-check (Codex gpt-6.2-sol at `f2b51e98`, original Claude Opus 5.5 in `325a3455`) — Settings disables Batch for OpenAI. A stored on value still displays a $0.0052 batch estimate against $0.0105 standard and suppresses page-reader choices. Both standard requests used GPT-5.4 mini, where both with Batch off used the chosen GPT-5 nano.
  - 2026-11-23 W49.proc-fix-s027 — OpenAI offers the same estimate, reader menu and import picker with either
    stored Batch value. Both runs read their two pages with GPT-5 nano when that reader was selected.

### S-028 · A chosen folder is read one level deep; nested photos are silently left out

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** README promises a recursive search, but folder input uses `contentsOfDirectory`
  (`Views/OCRView.swift:1211`, `:1231`). A box folder with sub-folders adds only its top-level images, with no message;
  the user may believe a box was processed when part of it was not. Re-adding a file also appends a duplicate (`:1217`).
- **Where:** `P-22`.
- **Would confirm it:** a scratch folder holding `a/b/x.jpg` and `y.jpg`, dropped: count the rows.
- **Would clear it:** both files are listed.
- **Status:** `cleared` — `W49.proc-suspects-filing`, by the code change of `W47.ct-processor-intake` (no run: the question is SwiftUI with no headless seam)
- **History:**
  - 2026-10-21 W40.b3 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.proc-suspects-filing` under phase rule 5a.
  - 2026-11-20 W49.proc-suspects-filing — cleared as written; the code no longer says it. Since
    `W47.ct-processor-intake` (2026-11-19) drag-drop and Add Files… both go through `admit` (`Views/OCRView.swift:1505`),
    which asks "Read the folders inside?" whenever a chosen folder has subfolders; Yes reads the tree, No adds the top
    level by the user's choice. So nested photos are no longer left out silently. The tree read itself is covered by
    `PROCESSFILES_TREE=1`. The duplicate half is unchanged and was not attempted (no headless seam): S-048. The README
    still describes the old top-level-only read: S-049.

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
- **Status:** `cleared` — fixed by W49.proc-fix-s029. [Independent VM evidence](evidence/processor/W49.proc-suspects-messages-check.md).
- **History:**
  - 2026-10-21 W40.b3 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.proc-suspects-messages` under phase rule 5a.
  - 2026-11-20 W49.proc-suspects-messages — half reproduced. LLM comparative (one vote) on the gateway, three turned
    pages, every vote answered 500: nothing reported it (no page unsure, nothing in the status line). Vision turned all
    three synthetic pages correctly, so no sideways page came out. Since raised, the default (agreement) marks and counts
    a failed cloud call, the help measures Vision wrong on 3 of 119 (not about 60%), and README documents the fallback;
    the silence is undocumented. A fix keeps the fallback and reports it.
  - 2026-11-21 W49.proc-suspects-messages-check (Codex gpt-6.2-sol, baseline `8e89c29b`) — A failed comparative vote left a sideways scan in the PDF. The app reported OCR success and gave no rotation warning. A successful vote on the same image turned it upright.
  - 2026-11-23 W49.proc-fix-s029 — both comparative modes report the fallback and which pages were left unturned.

### S-030 · The run log can give one failed file another's reason

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** `writeLogFile` finds each failure's job by base name
  (`OCR/OCRProcessor+Pipeline.swift:3419`), so two failing files with the same name in different folders both get the
  first one's reason. Its write is `try?` (`:3444`), so a failed log write is silent.
- **Where:** `P-26`.
- **Would confirm it:** a run with two same-named failing files from two folders, logging on.
- **Would clear it:** each line carries its own file's reason.
- **Status:** `fixed` — W49.proc-fix-s030 counts every failed source path and logs its own reason. The log-write
  error path remains untested. [Independent VM evidence](evidence/processor/W49.proc-suspects-messages-check.md).
- **History:**
  - 2026-10-21 W40.b3 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.proc-suspects-messages` under phase rule 5a.
  - 2026-11-20 W49.proc-suspects-messages — reproduced, worse than raised. `a/same.jpg` and `b/same.jpg`, every OCR call
    refused: both failed (manifest), but the status line said "0 succeeded, 1 failed" and the log "Failed: 1" with one
    line and one reason. `failedFiles` is kept by name and skips a name it holds (`OCR/OCRProcessor+OCR.swift:1722`,
    `:1847`), so the second file is dropped, not given the first one's reason. The `try?` write was not tested.
  - 2026-11-21 W49.proc-suspects-messages-check (Codex gpt-6.2-sol, baseline `8e89c29b`) — Both jobs failed and generated their own PDFs. The status and run log counted one failure and recorded a single reason.

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
- **Status:** `cleared` — `W49.proc-suspects-filing`, `ArchiveProcessor/scripts/repro-suspects-filing.sh` `s031-window` (`SegmentationReviewTestDriver` §9a)
- **History:**
  - 2026-10-21 W40.b3 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.proc-suspects-filing` under phase rule 5a.
  - 2026-11-20 W49.proc-suspects-filing — cleared; the premise is wrong. The window stage ends in
    `rebuildSegments` (`OCR/OCRProcessor+WindowSegmentation.swift:116`), which runs `DocumentSegmenter` with the OCR's
    enclosure flags, so the window path does not bypass it. The real `runWindowSegmentationStage` on recorded window
    answers that agree with the OCR (folder, a two-page letter, its enclosure marked `[enclosure]`, a document) kept the
    relation: the enclosure's segment is `enclosureOf` the letter, which is what `applyGeneratedTags` writes `Sent With`
    from (proved end to end by `DUAL_DATE_TEST` §5). Windows that split the letter drop it (§9b): S-047.

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
- **Status:** `cleared` — fixed by W49.proc-fix-s032. [Original VM reproduction](evidence/processor/W49.proc-suspects-money-check.md).
- **History:**
  - 2026-10-21 W40.b3 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.proc-suspects-money` under phase rule 5a.
  - 2026-11-20 W49.proc-suspects-money — reproduced. `canStartProcessing` still has no segmentation term. Gemini in
    the chooser with no Gemini key, three photos, Automatic: all three pages were OCRed, then the window stage asked
    "Gemini needs an API key." (pages read 3/3). The run is resumable, so the reads are kept if the user adds the key and
    resumes. The chooser's comment promises the start gate, so it is not intended.
  - 2026-11-21 W49.proc-suspects-money-check (Codex gpt-6.2-sol at `f2b51e98`, original Claude Opus 5.5 in `325a3455`) — With Automatic tagging and Gemini-only segmentation, Start made three OCR requests before the missing-key alert. The interrupted run offered Stop and resume later.
  - 2026-11-22 W49.proc-fix-s032 (Codex gpt-6.2-sol) — Start shows the segmentation credential requirement
    before OCR. The off-screen regression recorded zero requests after pressing the Start shortcut.

### S-033 · A tag reply with no year and `date_uncertain: false` gets no date tags at all

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** `parseTagResponse` (`Tagging/TagGenerator.swift:170-181`) adds `Date Uncertain` only when
  the model says so; JSON with `year: null` and the flag false or absent yields a document with no year, no month and
  no `Date Uncertain`, against the promise that an undated document is always marked.
- **Where:** `P-33`.
- **Would confirm it:** feed that JSON to the parser in a driver and read the tags.
- **Would clear it:** `Date Uncertain` is forced when there is no year.
- **Status:** `cleared` — `W49.proc-suspects-filing`, `ArchiveProcessor/scripts/repro-suspects-filing.sh` `s033-noyear`
- **History:**
  - 2026-10-21 W40.b3 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.proc-suspects-filing` under phase rule 5a.
  - 2026-11-20 W49.proc-suspects-filing — cleared. The parser still behaves as described
    (`Tagging/TagGenerator.swift:180`), but the dating route runs after it on every real path and overwrites the flag
    (`Tagging/DateRoute+Run.swift:203-205`); its decision starts at `dateUncertain: true` and clears it only with a year.
    A real Process Files run (Automatic, stand-in gateway answering every tag call with `year: null`,
    `date_uncertain: false`) wrote `Date Uncertain` on 4 of 4 document PDFs.

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
- **Status:** `fixed` by `W40.fix-processor-copy-label-tags`. The collection pass adds the final label marker while retaining the copied names. [Original VM evidence](evidence/processor/W49.proc-suspects-filing-check.md).
- **History:**
  - 2026-10-21 W40.b3 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.proc-suspects-filing` under phase rule 5a.
  - 2026-11-20 W49.proc-suspects-filing — reproduced. The code is unchanged (`applyBoxFolderLabelTags`,
    `OCR/OCRProcessor+Tagging.swift:301-307`, passes for `.none` and `.copySource`). Real Process Files runs on six
    scratch photos with Collection ID on, the stand-in gateway classifying one box and one folder label: under No
    tagging the box PDF got `Box` and the folder PDF `Folder`; under Copy source tags, every photo carrying the source
    tag `Source Tag A`, the four document PDFs kept it and the box and folder PDFs lost it, replaced by `Box` and
    `Folder`. No colour was written (no colour is chosen by default, `Tagging/ItemTypeColourSetting.swift:4`). The
    function's comment calls this intended and `ProcessFilesTagWarningTestDriver` (`:178-192`) checks for it, while
    `SPEC/tag-format.md:538-546` promises the opposite, so it is asked rather than queued.
  - 2026-11-21 W49.proc-suspects-filing-check (Codex gpt-6.2-sol at `bdfe3274`, original Claude Opus 5.5 in `d8fb1269`) — In Process Files, No tagging wrote Box and Folder on the two label PDFs. Copy source file tags replaced both original Finder tags on those labels with the marker, while all four other PDFs kept both source tags. Owner call 30 keeps the label markers and requires preservation of every copied tag.

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
- **Status:** `reproduced` — independently confirmed; fix queued as `W40.fix-processor-resume-reviews`. [VM evidence](evidence/processor/W49.proc-suspects-filing-check.md).
- **History:**
  - 2026-10-21 W40.b3 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.proc-suspects-filing` under phase rule 5a.
  - 2026-11-20 W49.proc-suspects-filing — reproduced, wider than written. `resumeBatch` is now at
    `OCR/OCRProcessor+Pipeline.swift:1622`; a batch resume pins the approach to Manual (`:399-401`), so its segments come
    straight from the stored classes (`:1766-1782`). The real `resumeBatch`, on a finished Gemini batch journal in a
    scratch state directory (six pages: box, folder, a two-page letter, two documents; every chunk consumed; the wire
    stubbed), under Automatic, raised no review at all: no per-page review, no box/folder confirmation and no final
    review, and wrote tags on 6 of 6 outputs. A fresh Automatic run on the same kind of input raises all three
    (`s033-noyear`). The comment at `:1786-1788` calls skipping the redo-review loop deliberate ("a resumed batch has no
    interactive session"); nothing records the other two, yet the same resume does raise the collection-name sheet and
    the per-collection review when they are on. Asked, as the comment's reason could be meant to cover them.
  - 2026-11-21 W49.proc-suspects-filing-check (Codex gpt-6.2-sol at `bdfe3274`, original Claude Opus 5.5 in `d8fb1269`) — After reopening a persisted, fully read Gemini scratch batch, Resume Batch opened neither pre-tagging review nor final tagging review. It opened collection names and the later per-collection page review, then filed all six tagged PDFs. Owner call 30 requires every applicable review except where the user already explicitly skipped it.

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
- **Status:** `fixed` by `W40.fix-processor-collection-name-filing`. The VM regression exercises field Return and clicking Confirm and Organize with the field still active. [Original VM evidence](evidence/processor/W49.proc-suspects-filing-check.md).
- **History:**
  - 2026-10-21 W40.b3 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.proc-suspects-filing` under phase rule 5a.
  - 2026-11-20 W49.proc-suspects-filing — reproduced, with one detail corrected. The code is unchanged
    (`Views/OCRView+CollectionReviewSheet.swift:124-130`, `OCR/OCRProcessor+ReviewFlows.swift:219-225`,
    `Tagging/CollectionSegmenter.swift:306`). Real Process Files runs (Automatic, Collection ID, Confirm collection names,
    six scratch photos), with a name typed into the sheet's box row and Confirm and Organize pressed without Return:
    `..` filed all six PDFs in the PARENT of the chosen output folder (`000001 ...pdf`), and the run warned that two
    label PDFs "were not where the run left them"; `a/b` did not throw (the suspect's guess) but filed each PDF as
    `a/b/000001 a/b.pdf`, that is, a file `b.pdf` inside a new folder `000001 a`; an empty name left the six PDFs
    loose in the output folder as `000001 .pdf`. Nothing says this is deliberate; README promises normalised names
    and Live Capture's own sanitiser refuses dot-only names (`Capture/LiveCaptureProcessor.swift:3241-3248`).
    `normalizeCollectionName`, which Return runs, would also pass `..` through.
  - 2026-11-21 W49.proc-suspects-filing-check (Codex gpt-6.2-sol at `bdfe3274`, original Claude Opus 5.5 in `d8fb1269`) — In the box row of Review Collection Names, Confirm and Organize without Return used all three typed names as entered. Six PDFs went to the parent, six nested under the separator-containing name, and six landed loose for the empty name. The assigned output folder is the filing boundary.

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
- **Status:** `superseded` — fixed by `W40.i-usb-mac` (2026-10-31): the QR shows whenever the server listens
- **History:**
  - 2026-10-21 W40.b3 — raised.
  - 2026-10-31 W40.i-usb-mac — superseded by the fix it describes: the iPhone cable route needs no Wi-Fi address
    either, so the QR's `host` is now en0/en1, else another pairable IPv4 (a VPN, AirDrop or self-assigned address
    never stands in), else empty, valid for Cable, Wired and Cloud and refused for Wi-Fi on both phones
    (`LiveCaptureView.pairingHost`; Android `MacEndpoint.kt`, `MacEndpointQrTest`). Checked by
    `scripts/test-usbmux-bridge.sh` (two S-037 checks). `W40.i-usb-build`'s `e2e-phone-mac.sh --ios --cable` pairs
    the iPhone from an empty-host payload. The case the suspect names was by code reading: USB pairing needed no
    Wi-Fi address then too, for Android.

### S-038 · Over the Drive relay, Finish cannot wait for the phone to drain

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** the drain gate is fed only by `POST /phone/status` (`Net/CaptureServer.swift:575-579`);
  `SPEC/relay-object-format.md` has no status object, so over the relay `phonePendingActive` is always false and Finish
  finalizes while photos are still on the phone, in segments still being shot.
- **Where:** `P-48`; `SPEC/relay-object-format.md`.
- **Would confirm it:** `scripts/test-filerelay.sh`-style session with an ended segment whose last page has not yet
  arrived: press Finish and count pages filed.
- **Would clear it:** Finish holds until the page lands.
- **Status:** `reproduced` — independently confirmed. Fix queued as `W49.proc-fix-s038`. [Independent evidence](evidence/processor/W49.relay-suspects-check.md).
- **History:**
  - 2026-10-21 W40.b3 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.relay-suspects` under phase rule 5a.
  - 2026-11-20 W49.relay-suspects — reproduced. The code still says it (the heartbeat route is now
    `Net/CaptureServer.swift:633-637`; `FileRelayReceiver`, the Mac's receiver for both relays, never feeds the gate).
    The built app headless on the file relay, Apple Vision: page 1 of `g1` receipted, page 2 still on the phone, then
    Finish (the session-complete marker driving `requestFinish`): finalized about a second later, `g1` filed with one
    page. Page 2 then arrived, was receipted, and stayed in the backup folder as a page of an already-filed document.
    Nothing exempts the relay from `P-48`'s promise.
  - 2026-11-21 W49.relay-suspects-check (Codex gpt-6.2-sol at `5fa81705`, original Claude Opus 5.5 in `ae75bd87`) — The headless Mac relay filed one of two photos when Finish ran before the second arrived. The late receipt covered a photo still in Backup and the filed PDF was byte-identical. With both photos delivered before Finish, the PDF contained both.

### S-039 · Stage for later can hand the same photos to Process Files twice

- **Raised:** 2026-10-21 · W40.b3 · ledger trace, by code reading.
- **Suspected behaviour:** `stageForProcessing` (`Views/LiveCaptureView.swift:721`) neither removes nor marks the
  photos it hands off, so a second click, or one after a relaunch, sends the same photos again and they are OCRed and
  paid for twice; the existing filter blocks only photos whose output is already verified in staging.
- **Where:** `P-50`.
- **Would confirm it:** in a driver, hand off twice and count the files Process Files receives.
- **Would clear it:** the second hand-off is empty or refused.
- **Status:** `reproduced` — independently confirmed; fix queued as `W49.proc-fix-s039`. [VM evidence](evidence/processor/W49.proc-suspects-money-check.md).
- **History:**
  - 2026-10-21 W40.b3 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.proc-suspects-money` under phase rule 5a.
  - 2026-11-20 W49.proc-suspects-money — reproduced. Six photos received in Stage for later and handed over: after
    the run the pane hands the same six over again, and a relaunched app restores them and its run OCRs all six again (12
    OCR calls for six photos). Each hand-off still needs Start pressed. Keeping the photos is deliberate (the backup is
    the only copy); nothing calls the repeat hand-off deliberate.
  - 2026-11-21 W49.proc-suspects-money-check (Codex gpt-6.2-sol at `f2b51e98`, original Claude Opus 5.5 in `325a3455`) — Live Capture handed off the same two photos after a successful Process Files run and again after relaunch. A second Start read both photos again. The handoff itself sent zero requests.

### S-040 · A year typed on the phone keeps the day the OCR read from another date

- **Raised:** 2026-10-23 · W40.i-sim-ui · scripted run, then code reading.
- **Suspected behaviour:** when the phone's tag sheet gives a year (and no month), Live Capture's finalize replaces
  only `tags.year` (and the month, when one is given), and keeps the day and any month the model read from the
  page (`Capture/LiveCaptureProcessor.swift:1145-1148`). An operator who types a year because the page's date was
  read wrong gets that year combined with the wrong date's day. In run `/tmp/ap-e2e-ui-r5` the phone gave Q2 + 1962
  to a segment whose pages were the 1974-12-03 report and the 1962-03-14 memo; both PDFs were filed `1962, Day 3`.
  That segment held two different documents (the test's doing), so the run alone does not prove the case.
- **Where:** `C-38`, `C-08`; the lines above.
- **Would confirm it:** a one-document segment whose page reads, say, "December 3, 1974", tagged 1962 on the phone
  (the UI test's tag-sheet step with that fixture alone), filed with `Day 3` or `12 December`.
- **Would clear it:** the phone's year drops the day and month the model read (or keeps them only when the model's
  year matched).
- **Status:** `cleared` — fixed by `W49.proc-fix-s040`; test `scripts/test-date-route.sh` §6 Live D and E
- **History:**
  - 2026-10-23 W40.i-sim-ui — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.proc-fix-s040` (seen in a run: fix with that run as its test).
  - 2026-11-20 W49.proc-fix-s040 — fixed: a typed year other than the read one replaces the whole date; cleared.

### S-041 · Process Files' cost estimate leaves out the dating and item-field calls

- **Raised:** 2026-11-18 · W40.d1 · the $0 stand-in gateway run of the whole RG 165 box.
- **Suspected behaviour:** a run on the gateway route makes three calls per document that the Cost Estimate box
  does not count: the date route's two (`Tagging/DateRoute.swift`, "You are dating a document…" and "These are the
  first pages of one archival document…") and the item fields' one (`Tagging/ItemFieldExtractor.swift`), which
  sends images of up to ten of the document's pages. In the stand-in run they were 171 of 341 calls (113 OCR, 57
  tagging, 57 of each of the three). `CostEstimator.estimate` (`Models/CostEstimator.swift`) has terms for OCR,
  classification, tagging, collections and rotation only. Whether the dollar figure shown is low depends on the
  real tokens: the same estimator prices a Gemini page at 40,000 image tokens, which may more than cover them.
- **Where:** ledger `P-03`, `P-02`; the files above. Evidence of the call count:
  [`evidence/processor/W40.d1-bulk-ocr.md`](evidence/processor/W40.d1-bulk-ocr.md) §"The $0 runs".
- **Would confirm it:** W40.d1's paid run: its `spend.tsv` (metered from each reply's `usage`) above the
  `estimate.txt` total for the same pages and settings.
- **Would clear it:** the metered spend at or under the estimate, with the estimator's figures written down as
  the reason (then the omission is a wording matter for the box, not a low figure).
- **Status:** `cleared` — fixed by `W49.proc-fix-s041`, [`evidence/processor/W49.proc-fix-s041.md`](evidence/processor/W49.proc-fix-s041.md)
- **History:**
  - 2026-11-18 W40.d1 — raised.
  - 2026-11-18 W40.d1 — still `open`: the paid run went through OpenRouter (Qwen3.8 Flash), not the gateway; there the
    metered ceiling, $0.1056 for 113 photos in 195 calls, ran under the estimate of $0.1267. The gateway's dating and
    item-field calls are still unmeasured.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.proc-fix-s041` (seen in a run: fix with that run as its test).
  - 2026-11-20 W49.proc-fix-s041 — `cleared`: the estimate has a dating term (trace on every backend, the image pass on
    the measured route) and an item-field term (measured route, sidecars on, by the page), at the bench's gateway
    figures. The item-fields driver checks a term for each kind of call its runs make; the stand-in run's estimate
    goes from $3.85 to $4.15, the paid run's from $0.1267 to $0.1433 (metered $0.1056). The names call is S-044.

### S-042 · A failed tagging call leaves a document untagged, and the run still reports it tagged

- **Raised:** 2026-11-18 · W40.d1 · the $0 stand-in cap test (the meter refused 17 calls once a $0.45 cap was spent).
- **Suspected behaviour:** when a segment's tag-generation call fails, the document is written with no subject
  tags and no date, its job stays `succeeded`, and the run's status line still counts it ("12 succeeded, 0 failed.
  11 segments tagged."). In the cap test `00012 — RG 165.pdf` came out with no subject tags. The refusal there is a
  thrown `URLError(.cancelled)` from the test meter, so a real provider error (a 5xx, a timeout, a bad reply) may
  take another path; `scripts/test-processfiles-tagwarn.sh` covers a refused tag WRITE, not a failed tag CALL.
- **Where:** ledger `P-33`, `P-26`; `OCR/OCRProcessor+Tagging.swift` `performTaggingPhase`.
- **Would confirm it:** a stubbed tagging reply that errors (500, and a malformed body) on one segment of a small
  run: the PDF untagged, the job `succeeded`, and nothing in the status line or the log naming the document.
- **Would clear it:** the document is flagged in the file pane, the status line or the run log.
- **Status:** `cleared` — fixed by `W49.proc-fix-s042`, [`evidence/processor/W49.proc-fix-s042.md`](evidence/processor/W49.proc-fix-s042.md)
- **History:**
  - 2026-11-18 W40.d1 — raised.
  - 2026-11-20 owner, Backlog sheet (call 28) — queued as `W49.proc-fix-s042` (seen in a run: fix with that run as its test).
  - 2026-11-20 W49.proc-fix-s042 — reproduced and fixed: a failed tagging call (a throw after the network retries, a
    reply that is not the tag JSON) is now named in the status line and the run log and not counted as tagged. The
    W40.d1 cap test reports `00012 — RG 165`; a stand-in 500 on two tagging calls reports both.

### S-043 · Text typed after an unclosed Notes block header is joined onto the header's last line

- **Raised:** 2026-11-20 · W49.notes-suspects-text · seen in the S-019 reproduce run (phase rule 5a(5)).
- **Suspected behaviour:** a degraded block's text is its unclosed opener, which the editor holds as raw HTML. The
  file's newline after the opener's last line is dropped on save, so text typed at the end of such a note, without a
  Return first, is written on that line: `link: archivereader://reveal?rel=a.pdfSome prose`. The typed text then reads
  back as part of the opener (hidden inside the HTML comment, or a corrupted `link:` value once a `-->` closes it), and
  the block's source link no longer names the file.
- **Where:** `Editor/MarkdownBridge.swift` `plainLines` (raw HTML's own trailing newline is not written as a line,
  `MarkdownBridgeTests.rawHTMLNewlinesAreKept`); the S-019 run's `returnFirst → false` case.
- **Would confirm it:** the same run as S-019 without `-->`: type `Some prose` at the end of the loaded degraded note,
  save, reload, and look for `a.pdfSome prose` in the file. Then check what the user sees in the editor before saving:
  whether the caret stands on a new line after the link, which would make the join a surprise rather than what was
  typed.
- **Would clear it:** the typed text lands on a line of its own, or the editor shows it joined before saving.
- **Status:** `cleared` — not a defect: the editor shows the join before saving; test `ArchiveNotesTests/NotesTextLossSuspectTests` `s043TypedTextAfterUnclosedHeader`
- **History:**
  - 2026-11-20 W49.notes-suspects-text — raised.
  - 2026-11-20 owner walkthrough of 13:42 (call 29) — queued as `W49.notes-s043-reproduce` under phase rule 5a.
  - 2026-11-20 W49.notes-s043-reproduce — cleared. The join is real: the file ends
    `link: archivereader://reveal?rel=a.pdfSome prose`. But the newline is dropped on load, not on save
    (`MarkdownBridge.dropRawHTMLLineEnd`, documented as deliberate so a save adds no blank line), so the editor's
    text ends `a.pdf` and the caret stands at the end of the `link:` line. The opener is drawn as ordinary text (the
    system text colour at 14 pt, as the typed text), so `Some prose` appears joined on that line before the save, and
    the reopened note renders exactly what the editor showed. Run on a scratch store through a real `EditorTextView`.

### S-044 · Process Files' cost estimate leaves out the names call

- **Raised:** 2026-11-20 · W49.proc-fix-s041 · by code reading, while adding the dating and item-field terms.
- **Suspected behaviour:** with sidecars on and names ranked, each correspondence document the tagging call reads as
  a letter, memo or telegram gets one more text call on the run's own route (`EntityExtractor.extract`, after
  `EntityRunPolicy.decide`, in `performTaggingPhase`). `CostEstimator.estimate` has no term for it, so a run with
  names ranked costs more than the Cost Estimate box says, by about one text call on each such document.
- **Where:** ledger `P-03`, `P-02`; `Tagging/EntityExtractor.swift`, `OCR/OCRProcessor+Tagging.swift`,
  `Models/CostEstimator.swift`.
- **Would confirm it:** a run with names ranked on a box with letters, its calls by kind against the estimate's
  terms (the item-fields driver's part 6 counts them the same way).
- **Would clear it:** names are never ranked in a run the estimate prices, or the call is free on every route.
- **Status:** `cleared` — fixed by `W49.proc-fix-s044`; regression `NamesEstimateJourneyUITests`; [independent evidence](evidence/processor/W49.proc-s044-check.md); [`evidence/processor/W49.proc-s044-reproduce.md`](evidence/processor/W49.proc-s044-reproduce.md), `ArchiveProcessor/scripts/repro-s044-names.sh`
- **History:**
  - 2026-11-20 W49.proc-fix-s041 — raised.
  - 2026-11-20 owner walkthrough of 13:42 (call 29) — queued as `W49.proc-s044-reproduce` under phase rule 5a.
  - 2026-11-20 W49.proc-s044-reproduce — reproduced. The code still says it (`OCR/OCRProcessor+Tagging.swift:1239-1244`;
    `Models/CostEstimator.swift` has no names term). Two real Process Files runs on six scratch photos, Automatic,
    sidecars on, the stand-in gateway reading every document as a Letter: with names ranked in the collection's
    settings, 3 names calls of 23 (one per document, 3 sidecars with `entities`), without, 0 of 24; both runs' estimates
    were the same, $0.0158, with no names term. Nothing calls the omission deliberate (`EntityRunPolicy.decide` says the
    call "costs money on a cloud route"), so no owner question.
  - 2026-11-21 W49.proc-s044-check — independently confirmed on Codex through the VM's real collection interview:
    Names starts at weight 0, is given a positive weight and moved first while the other priorities stay ranked.
    With gateway prices entered in Settings ($2/$10 per million), the estimate stays $0.0310. Real Start → review →
    Complete makes 5 requests, including one names request on the run's model; one sidecar holds entities.
    `W49.proc-fix-s044` queued; no estimator fix in this check.
  - 2026-11-21 W49.proc-fix-s044 — ranked Names adds a $0.0015 row and raises the VM journey's total from
    $0.0310 to $0.0325 at the stand-in gateway's $2/$10 prices. Start makes one names call and writes its
    sidecar on the same journey.

### S-045 · A failed tagging call in Live Capture is filed silently

- **Raised:** 2026-11-20 · W49.proc-fix-s042 · code reading (its adversarial review).
- **Suspected behaviour:** Live Capture's Automatic tagging (`LiveCaptureProcessor.computeTags`) calls
  `TagGenerator.generateTags`, which drops the failure reason `generateTagsReporting` now returns. A segment whose
  tagging call fails (a 5xx or timeout, which `NetworkSession` does not retry for a paid call, or a reply that is not
  the tag JSON) is filed with no subject tags and nothing in the session's status or the Mac's file list says so,
  as S-042 was in Process Files.
- **Where:** ledger `P-33`; `Capture/LiveCaptureProcessor.swift` `computeTags`; `Tagging/TagGenerator.swift`
  `generateTagsReporting`.
- **Would confirm it:** the Live Capture recovery driver's injected transport answering one segment's tagging call
  with a 500: the staged document has no subject tags and no status line or row names it.
- **Would clear it:** the session names the document, or a failed call holds the segment for retry.
- **Status:** `reproduced` — [scratch Live Capture run](evidence/processor/W49.proc-s045-verify.md), independently confirmed by `W49.proc-s045-check`; fix queued as `W49.proc-fix-s045`.
- **History:**
  - 2026-11-20 W49.proc-fix-s042 — raised.
  - 2026-11-21 owner walkthrough (call 30) — verification queued as `W49.proc-s045-verify`; standing authorization for all bug suspects, phase rule 5a retained.
  - 2026-11-21 W49.proc-s045-verify — Codex gpt-6.2-sol reproduced on baseline `7252c39b`. After one
    HTTP 500 and one successful control, both PDFs filed with OCR text. The refused one kept its date and
    Unread tags and had no model subjects. The Processing row showed success and no error. Finish said
    “Finalized 1 collection · 2 files moved.” without a warning.
  - 2026-11-24 W49.proc-s045-check — Claude Opus 5.5 confirmed it at `645c7845`. The refused PDF's Finder tags,
    read with `xattr`, were 1918 / 3 March / Unread, its OCR text was intact and no record noted the failure. Filed `W49.proc-fix-s045`.


### S-046 · "Review document segmentation" changes nothing on a fresh Process Files run

- **Raised:** 2026-11-20 · W49.proc-suspects-filing · while reproducing S-017.
- **Suspected behaviour:** both fresh paths pass a literal `reviewDocumentSegmentation: false` to
  `performCollectionSegmentation` (`OCR/OCRProcessor+Pipeline.swift:3621`, `OCR/OCRProcessor+OCR.swift:254`); only the
  two resume paths pass the stored setting (`:1831`, `:2243`). The Settings help promises "Pause after OCR to review
  and correct each page's classification … before tagging" (`Views/SettingsPanels/SettingsDocumentsPanel.swift:100-106`).
  On a fresh run the whole-run review comes whatever the toggle says, and the per-collection review it switches never
  appears; on a resume it does. `verification/processor.md` P-32 already notes the toggle is forced off.
- **Where:** ledger `P-32`.
- **Seen:** `ArchiveProcessor/scripts/repro-suspects-filing.sh s017-images-toggle`: Automatic + Collection ID, toggle on
  and off, raised the same gates (whole-run review, box/folder confirmation, final review).
- **Would confirm it:** observe the same review sequence on two fresh user-started runs with the Documents switch
  on and off. The owner chooses whether the whole-run review should remain required or be explicitly skippable.
- **Would clear it:** fresh document review defaults on and an explicit off skips the before-tagging review.
  Owner call 31 approved this behavior. Shipped as `W49.proc-s046-review-toggle`.
- **Status:** `fixed` — [scratch VM evidence and separate confirmation](evidence/processor/W49.proc-s046-verify.md).
- **History:**
  - 2026-11-20 W49.proc-suspects-filing — raised.
  - 2026-11-21 owner walkthrough (call 30) — verification queued as `W49.proc-s046-verify`; standing authorization for all bug suspects, phase rule 5a retained.
  - 2026-11-21 W49.proc-s046-verify — Codex gpt-6.2-sol reproduced at `d1b38279`. Both switch values led
    to the same whole-run per-page review, box/folder confirmation, final tagging review and collection
    name confirmation. Both finished without a per-collection review. The whole-run review was introduced
    deliberately in `a6da4e62`, so the behavior choice goes to the owner.
  - 2026-11-23 W49.proc-s046-check — a separate Codex gpt-6.2-sol VM run under the owner override confirmed
    the same sequence at `df7f295d`. Both switch values reached Done with six succeeded and zero failed.
  - 2026-11-23 W49.proc-s046-review-toggle — the switch defaults on and an explicit off skips the fresh
    whole-run review. The other review stages still apply.


### S-047 · Windows that split a letter the OCR read as one document drop its enclosure's `Sent With`

- **Raised:** 2026-11-20 · W49.proc-suspects-filing · while reproducing S-031.
- **Suspected behaviour:** a relation survives the window stage only if the cover's page sequence matches the OCR's own
  boundaries (`Tagging/DocumentSegmenter.swift:102-109`). When the windows split the letter, the enclosure is still a
  document of its own but loses `enclosureOf`, so it gets no `Sent With`. That is the safe side (never a wrong date),
  and may be intended by the "never inferred from adjacency" rule (`:11-16`).
- **Where:** ledger `P-28`, `P-30`.
- **Seen:** `SegmentationReviewTestDriver` §9b (`repro-suspects-filing.sh s031-window`): folder, a two-page letter,
  its enclosure marked `[enclosure]`, a document; windows answering "new" between the letter's two pages; the
  enclosure's cover is none.
- **Would confirm it:** the owner's call that Processor should ask which segment is the actual cover when the
  window splits it.
- **Would clear it:** a ruling that a changed cover boundary drops the relation by design.
- **Status:** `reproduced` — independently confirmed by `W49.proc-s047-check`; owner call 33's optional cover
  selection queued as `W49.proc-s047-cover-select`.
  [Scratch evidence](evidence/processor/W49.proc-s047-verify.md).
- **History:**
  - 2026-11-20 W49.proc-suspects-filing — raised.
  - 2026-11-21 owner walkthrough (call 30) — verification queued as `W49.proc-s047-verify`; standing authorization for all bug suspects, phase rule 5a retained.
  - 2026-11-21 W49.proc-s047-verify — Codex gpt-6.2-sol reproduced at `d1ec616d`. The control
    points to the two-page letter. The window split leaves the marked enclosure separate with no cover.
    W37 deliberately drops proposals when cover pages change. The window vote gives only a boundary, so
    keeping a relation after a split would need confirmation of the actual cover.
  - 2026-11-24 W49.proc-s047-check — Claude Opus 5.5 confirmed at `732f5920`: both drivers passed, 9b again left
    the enclosure with no cover, and the code trace matches (provisional cover page 3 fails the `[page-2, page-3]`
    baseline). Owner call 33 filed as `W49.proc-s047-cover-select`.


### S-048 · Adding a file Process Files already lists adds it again

- **Raised:** 2026-11-20 · W49.proc-suspects-filing · code reading (the half of S-028 the intake change left).
- **Suspected behaviour:** `add()` appends the intake's files with no de-duplication (`Views/OCRView.swift:1520-1523`),
  so dropping or choosing a file already in the list lists it twice, and a run would read it, pay for it and file it
  twice.
- **Where:** ledger `P-22`.
- **Would confirm it:** in the VM, add the same scratch photo twice through the real window and count the rows (or
  the run's outputs).
- **Would clear it:** one row, or a de-duplication before the run starts.
- **Status:** `reproduced` — independently confirmed by `W49.proc-s048-check`; fix queued as `W49.proc-fix-s048`.
  [Scratch evidence](evidence/processor/W49.proc-s048-verify.md).
- **History:**
  - 2026-11-20 W49.proc-suspects-filing — raised.
  - 2026-11-21 owner walkthrough (call 30) — verification queued as `W49.proc-s048-verify`; standing authorization for all bug suspects, phase rule 5a retained.
  - 2026-11-21 W49.proc-s048-verify — Codex gpt-6.2-sol reproduced at `1f5cc337`. Choosing twice or choosing
    then dropping the same photo produced two rows and two OCR requests. One add produced one request.
    Each run left one PDF and used only the guest loopback gateway.
  - 2026-11-24 W49.proc-s048-check — Claude Opus 5.5 confirmed at `0a954a3e`: both routes gave two rows of the one
    file in the folder and two OCR requests with identical image digests; one add gave one. The duplicate runs now
    stop at catalogue filing ("The preservation copy could not be verified") with no PDF. Fix: `W49.proc-fix-s048`.

### S-049 · The Processor README says a chosen folder is read only at its top level

- **Raised:** 2026-11-20 · W49.proc-suspects-filing · reading docs while checking S-028.
- **Suspected behaviour:** `ArchiveProcessor/README.md:282` says "Directory selection — adds the images in the selected
  folder (for now only its top level: images in sub-folders are not picked up)", but since `W47.ct-processor-intake` the
  app asks whether to read the folders inside. A user reading the README would not expect the question.
- **Where:** ledger `P-22`.
- **Would confirm it:** the README line beside `Views/OCRView.swift:1505-1543`.
- **Would clear it:** the README describes the question.
- **Status:** `cleared` — corrected in `ArchiveProcessor/README.md` (W49.proc-s049-verify).
- **History:**
  - 2026-11-20 W49.proc-suspects-filing — raised.
  - 2026-11-21 owner walkthrough (call 30) — verification queued as `W49.proc-s049-verify`; standing authorization for all bug suspects, phase rule 5a retained.
  - 2026-11-21 W49.proc-s049-verify — confirmed the old README wording against baseline `37dbe229`.
    `OCRView.admit` asks the question for a folder with subfolders, and `OCRView.answer` passes the choice to
    `ProcessFilesTree.collect`. The README now describes both choices.


### S-050 · Resuming an interrupted (non-batch) run also skips the per-page review and the box/folder confirmation

- **Raised:** 2026-11-20 · W49.proc-suspects-filing · code reading, beside S-035.
- **Suspected behaviour:** `OCRProcessor.resumeRun` in `OCRProcessor+Pipeline.swift` segments without the
  per-page dialog or the box/folder confirmation. It then calls `performAutomaticTaggingWithReview`, where
  the user can still reclassify pages.
- **Where:** ledger `P-32`, `P-37`, `P-40`.
- **Would confirm it:** a real Process Files run under Automatic, interrupted at its first review and resumed
  through the app after relaunch. Compare the visible stages with the document review setting saved on and off.
- **Would clear it:** Resume presents each applicable review unless the user explicitly skipped it (owner call 30).
- **Status:** `confirmed` — independently reproduced by W49.proc-s050-check; fix queued as
  `W40.fix-processor-resume-reviews`. [VM evidence](evidence/processor/W49.proc-s050-verify.md).
- **History:**
  - 2026-11-20 W49.proc-suspects-filing — raised.
  - 2026-11-21 owner walkthrough (call 30) — verification queued as `W49.proc-s050-verify`; Resume should omit only explicitly skipped reviews (also S-035).
  - 2026-11-21 W49.proc-s050-verify — Codex gpt-6.2-sol reproduced at `5cd1bd29`. Both resumed runs bypassed
    the whole-run page review and label confirmation, then opened final tagging review. Only a saved On opened
    the later per-collection review, even when the live setting had been changed. Both reused all six OCR results.
  - 2026-11-24 W49.proc-s050-check — Claude Opus 5.5 independently reproduced at `1d4a91e1` on a fresh guest
    run, with the same review sequence and six OCR calls in both cases; ordinary Resume joins the S-035 fix.


### S-051 · A batch create refused outright is reported as an uncertain submission

- **Raised:** 2026-11-20 · W49.proc-suspects-money · seen in a run (the S-026 batch case).
- **Suspected behaviour:** the stand-in answered the Gemini batch create with a 401, and the run ended "Batch
  submission outcome is uncertain. No server job was acknowledged, but a create whose reply was lost may still have been
  accepted. The recovery journal was kept", though a 401 is a reply, and it says the create was refused. The kept journal
  then asks the user to resume or dismiss a batch that cannot exist.
- **Where:** `OCR/OCRProcessor+OCR.swift` batch submission (W49.proc-quit-waits-batch-submit's uncertain-outcome path).
- **Would confirm it:** a submission answered 4xx with no batch ID, its status line and whether the journal is kept.
- **Would clear it:** only a lost or cut-off reply is reported as uncertain.
- **Status:** `cleared` — fixed by W49.proc-fix-s051. [Scratch evidence and regression](evidence/processor/W49.proc-s051-verify.md).
- **History:**
  - 2026-11-20 W49.proc-suspects-money — raised.
  - 2026-11-21 owner walkthrough (call 30) — verification queued as `W49.proc-s051-verify`; standing authorization for all bug suspects, phase rule 5a retained.
  - 2026-11-21 W49.proc-s051-verify — Codex gpt-6.2-sol reproduced the full 401 separately from the original Claude Opus 5.5 run. The 401 and the cut-off 200 both kept a journal with zero acknowledged IDs and showed the same warning and pending-batch banner.

  - 2026-11-22 W49.proc-fix-s051 — the 401 showed its reason and cleared the empty journal. The
    cut-off reply, blank job ID and 503 kept recovery. Scratch contracts verified that a later
    refusal preserves acknowledged jobs and a first refusal preserves completed mixed PDF work.

### S-052 · Label reads that fail are counted as read

- **Raised:** 2026-11-20 · W49.proc-suspects-messages · seen in a run (the S-029 case).
- **Suspected behaviour:** both box/folder label reads through the gateway were answered 500, yet the run summary said
  "2 box or folder labels read through the gateway (GPT 5.6 Luna), $0.0000." and gave no "read nothing" warning. A user
  reads that as two labels read.
- **Where:** `Capture/ContainerLabelCapture.swift` `spendNote` (counts calls) and `warningNote`.
- **Would confirm it:** a run whose label calls all fail; read the summary and the container file's markers.
- **Would clear it:** the summary says the reads failed, or counts only answered calls.
- **Status:** `cleared` — fixed by W49.proc-fix-s052. [Scratch evidence and regression](evidence/processor/W49.proc-s052-verify.md).
- **History:**
  - 2026-11-20 W49.proc-suspects-messages — raised.
  - 2026-11-21 owner walkthrough (call 30) — verification queued as `W49.proc-s052-verify`; standing authorization for all bug suspects, phase rule 5a retained.
  - 2026-11-21 W49.proc-s052-verify (Codex gpt-6.2-sol, `43501730`) — independently repeated the
    HTTP 500 label replies seen by Claude Opus 5.5. The summary still counted two gateway reads.
    Vision supplied Box 17 and the blank folder produced an empty marker and a local warning.
  - 2026-11-21 W49.proc-fix-s052 — Process Files counts only labels with a usable gateway field, reports
    failed attempts separately, and charges each attempt as before.


### S-053 · The label reader asks any gateway for GPT 5.6 Luna

- **Raised:** 2026-11-20 · W49.proc-suspects-messages · seen in a run (the S-025 case).
- **Suspected behaviour:** with the gateway set to OpenAI by "Fill in OpenAI preset", a box label read went to
  api.openai.com naming `gpt-5.6-luna` (`max_tokens: 1200`, `reasoning_effort: low`). A gateway that does not serve that
  model fails every label read. The S-052 fix reports these as failed attempts. This check covers whether
  the reader can detect and explain the unavailable model.
- **Where:** `Capture/ContainerLabelCapture.swift` (the label reader's gateway call).
- **Would confirm it:** the label read against a gateway that does not list the model; read its reply and the summary.
- **Would clear it:** the reader uses a supported configured route or tells the operator that the label model
  is unavailable, with failed attempts excluded from the successful label count.
- **Status:** `cleared` — fixed by W49.proc-fix-s053. [Scratch evidence and regression](evidence/processor/W49.proc-s053-verify.md).
- **History:**
  - 2026-11-20 W49.proc-suspects-messages — raised.
  - 2026-11-21 owner walkthrough (call 30) — verification queued as `W49.proc-s053-verify`; standing authorization for all bug suspects, phase rule 5a retained.
  - 2026-11-21 W49.proc-s053-verify (Codex gpt-6.2-sol, `85f7a7a8`) — independently captured
    the request first observed by Claude Opus 5.5 (`08f85025`) and reproduced the refusal
    on a gateway without Luna. Two page transcriptions succeeded. Both label attempts were
    refused with HTTP 404 `model_not_found` and counted as failures without a diagnosis.
  - 2026-11-21 W49.proc-fix-s053 — Process Files explains the gateway's explicit model refusal once in
    the summary and keeps Vision proposals and the S-052 counts and charges.
