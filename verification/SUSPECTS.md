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
