# Archive Notes — feature ledger

Format and statuses: [`README.md`](README.md). Written by `W40.b2`, 2026-10-12.

- **Sources the promises were written from (rule 3, before the code was opened):**
  `ArchiveNotes/CLAUDE.md` (Core Directive, Stack & build, Implementation Map — used for features only, not
  for code paths), `ArchiveNotes/SMOKE_TEST.md` (steps A–P), `execution-plans/archive-notes/00-overview.md`
  (§1, §2 D1–D10, §3–§9, §11, §16, §17), the deleted `09-gap-closure.md` as of just before `W9.e4`
  (Phases A–E incl. the E1 result), and the Notes done-records in `SUITE_TODO_DONE.md`: `W9.b1`–`W9.b9`,
  `W9.c6`, `W9.cand1`, `W9.cand2`, `W9.cand2-fu1`, `W9.d1`–`W9.d12d`, `W9.b5-fu1`, `W9.e1`, `W9.e2-notes`,
  `W9.e2-search`, `W9.e2-folders`, `W9.e2-fu1`, `W9.e2-zotero`, `W9.e2-links`, `W9.e2-paste`, `W9.e2`,
  `W9.e4`, `W9.g4-flake`, `W9.g16-flake`, `W14.3`, `W14.4`, `W19.date`, `W19.q4`, `W23.l4`/`-fu`, `W23.m3`,
  `W23.m9`/`-fu3`, `W23.m14`/`-fu`, `W37.dual-date`, `W24.cal1`, `W24.cal1-toggle`, `W24.cal1-validator`,
  and the W0–W8 records under §*Archive Notes — NEW APP*.
- **Sources and code read at:** `9e8959ef`.
- **Count:** `unproven 48 · works 2 · broken 2 · unreachable 0` (works: N-34, N-45; broken: N-12, N-44). Updated by `W48.appearance-notes`, 2026-10-30 (N-52 added).

**Runtime evidence, for every row below: none yet.** The W40.a3 full VM suite
([`evidence/notes/W40.a3-full-ui.md`](evidence/notes/W40.a3-full-ui.md)) and the `W9.e2` runtime sweep passed
the UITests named under *Real-path test* here. A green suite is not runtime evidence for a feature (README
§Statuses), so no row moves to `works` on it. The journeys (`W40.d9`, `W40.d10`, …) provide the evidence. The
`W9.e1`/`W9.e2` results are taken in under *Real-path test* and *Notes*, not repeated as rows.

**Drift.** Where the code does not do what the promise says, *Notes* starts with **Drift** (rows N-01, N-03,
N-04, N-12, N-17, N-38, N-43, N-47). A drift note is input for `W40.b5`. It is not a reproduced bug and does not
make the row `broken` (rule 5). Suspects found while tracing are `S-006`–`S-014` in [`SUSPECTS.md`](SUSPECTS.md).
Doc-against-doc drift and the §17 deferrals are listed at the end.

Paths below are relative to `ArchiveNotes/macOS/Sources/ArchiveNotes/` unless they say otherwise. Test bundles
are `ArchiveNotesTests` (unit, app-hosted), `ArchiveNotesUITests` (XCUITest, VM only) and `ArchiveCoreTests`.

---

## Library, store and file safety

### N-01 · The Notes store folder and its marker

- **Promise:** Notes keeps its notes in one store folder, by default under `~/Library/Application
  Support/ArchiveNotes/`. The store gets a portable identity marker so the whole folder can be moved to another
  computer. (The user-picked store, File ▸ Choose Store Folder…, was split off as `N-48`.)
- **Promised in:** `CLAUDE.md` §Core Directive, Impl Map `RootFolderStore`, `RootMarkerStore`; `SMOKE_TEST.md`
  safety block (names File ▸ Choose Store Folder…); `00-overview.md` §4, §8.1, D5; `SUITE_TODO_DONE.md`
  `W23.l3-fu` (marker writer).
- **Reached by:** the default store only, by launching the app. `ArchiveNotesApp.swift:12` builds `NotesModel()`,
  whose app init (`Core/NotesModel.swift:210-218`) builds `RootFolderStore()` (`Store/RootFolderStore.swift:19`).
  That resolves a saved bookmark (`:63`) or creates `Application Support/ArchiveNotes/Store` (`:88-102`). Either
  way it calls `RootMarkerStore.ensureMarker` (`:104-112`, `Store/RootMarkerStore.swift:16`). The first window's
  `.task` then runs `NotesModel.bootstrap` (`Views/NotesBrowserView.swift:70`, `Core/NotesModel.swift:288`).
  The user pick is `N-48` (File ▸ Choose Store Folder…, wired by `W40.fix-notes-choose-store`). A chosen store
  whose bookmark no longer opens, or that no longer passes the store check, now leaves no store open rather than
  the default store in its place.
- **Real-path test:** `ArchiveNotesTests/RootMarkerStoreTests.idempotent` and `.corruptThrows` (the marker writer
  the launch path calls). `ArchiveNotesTests/NotesStoreLocatorOverrideTests.testAdoptTestStoreDoesNotPersistBookmark`
  covers the DEBUG UITest override. The real resolve of a saved store bookmark is `N-48`'s tests.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
  - 2026-10-12 W40.b2 — split: the user-picked store moved to `N-48` (`unreachable`).
- **Notes:** **Drift.**
  - The user-picked half of the promise is `N-48`, reachable since `W40.fix-notes-choose-store`.
  - The app is sandboxed (`ArchiveNotes.entitlements`), so the default store is in the app container,
    `~/Library/Containers/com.archivenotes.app/Data/Library/Application Support/ArchiveNotes/Store`. It is not under
    `~/Library/Application Support/ArchiveNotes/`.
  - With no picker, a store copied from another computer can only be adopted by copying it into that container
    path. The marker survives the move (idempotent `ensure`), but nothing lets the user point Notes at it.
  - The index database is outside the store (`Application Support/ArchiveNotes/notes-index-v1.sqlite3`,
    `Core/NotesModel.swift:247`). That fits "disposable index": `organization.json` travels in the store.
  - The promise draft records no W9.e2 result. The store picker is never driven by tests, by design (`GUI_SAFETY.md`).
  - Promise source note: the store move is promised in §4 ("Moving computers = copy the whole `<NotesStore>/` folder").

### N-48 · Pick a different store folder

- **Promise:** the user can pick the folder Notes keeps its store in (File ▸ Choose Store Folder…), and the pick is
  remembered across relaunches, so a store copied from another computer can be adopted where it lies.
- **Promised in:** `CLAUDE.md` §Core Directive, Impl Map `RootFolderStore`; `SMOKE_TEST.md` safety block (names
  File ▸ Choose Store Folder…); `00-overview.md` §4, §8.1, D5.
- **Reached by:** File ▸ Choose Store Folder… (`ArchiveNotesCommands.swift`, `ReaderRootCommands`) →
  `NotesModel.storeFolderChooser` → `StoreFolderChooser.choose` (`Store/StoreFolderChooser.swift`): the panel, the
  store check, a confirmation, `RootFolderStore.rememberRootAtQuit`, then the app quits. The bookmark is written in
  `willTerminate`, so a quit that is called off switches nothing. The next launch's `RootFolderStore.resolveSaved`
  opens the folder after checking it again, and `NotesModel.indexFileName` gives it its own index, so its own
  `organization.json` is read rather than the previous store's folders.
- **Real-path test:** `ArchiveNotesTests/StoreFolderChooserTests` (14 tests on scratch stores and a throwaway
  defaults suite: the pick survives a relaunch and the notes are read from it; an empty folder becomes a store;
  a Reader archive, a folder inside one or inside another store, a folder of other files, a linked `items/` and
  a broken marker are refused and nothing is written; a called-off quit remembers nothing; a remembered folder
  that has since become an archive, or sits inside a granted one, is not opened; one index per store).
  `ArchiveNotesUITests/ChooseStoreFolderUITests` (VM): the menu, the confirmation, the quit and the relaunch into
  the fixture's adopted store, with `-ANUITestStorePickPath` standing in for the panel.
- **Runtime evidence:** none (a green suite is not runtime evidence, README §Statuses).
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — split from `N-01`, `unreachable`.
  - 2026-10-29 W40.fix-notes-choose-store — wired (owner ruling, 2026-10-12 walkthrough: wire it), `unproven`.
- **Notes:** the check cannot always see an archive enclosing the picked folder: the sandbox does not let Notes
  read the folder's parents, so an empty folder inside an archive never granted to Notes is accepted
  (`ArchiveNotes/KNOWN_ISSUES.md`, LIMIT W40.fix-notes-choose-store).

### N-02 · Items are plain Markdown, legible without the app

- **Promise:** each note or extract is one UUID-named folder holding `<Title>.md` (title = file name) and an
  `assets/` folder. Metadata is YAML front-matter, which is authoritative; unknown keys survive a save; source
  blocks are HTML-comment headers plus an ordinary image line, so the file reads correctly in any Markdown tool.
- **Promised in:** `CLAUDE.md` §Core Directive, Impl Map `FrontMatterCodec`, `BlockParser`, `NoteStore`;
  `00-overview.md` §1, D1, D2, §3.1, §4, §5, §6; `SUITE_TODO_DONE.md` `W9.d12d` (a filename/title
  divergence is logged, neither rewritten).
- **Reached by:** every create and save. New note (N-11) → `NotesModel.newItem` (`Core/NotesModel.swift:701`) →
  `NoteStore.create` → `createEntry` (`Store/NoteStore.swift:116`, `:343-349`). That makes `items/<uuid>/`, its
  `assets/` and `<sanitizedTitle>.md`. Every edit goes through `NotesModel.mutateItem` (`Core/NotesModel.swift:1266`)
  → `NoteStore.withItem` → `saveEntry` (`Store/NoteStore.swift:373-381`), which renames the file when the title
  changes. Encoding is `Store/FrontMatterCodec.swift` and `Store/BlockParser.swift`.
- **Real-path test:** `ArchiveNotesTests/NoteStoreTests.createBasic` and `.saveRetitle`;
  `ArchiveNotesTests/FrontMatterCodecTests.testUnknownKeysPreserved`;
  `ArchiveNotesUITests/NotesGUITests.testG1_CreateNoteWritesNewItemFile` (a `.md` lands in a new item directory).
- **Runtime evidence:** [`evidence/notes/W40.d9-writing.md`](evidence/notes/W40.d9-writing.md) (`WritingJourneyUITests`, VM): after typing, ⌘Q and a relaunch the `.md` is byte-identical to what was saved and opening it rewrites nothing; front matter unchanged but `modified:`. An edit made to the `.md` outside the app while the note is open was overwritten by the next save, without a word; since W40.fix-notes-outside-edit-overwrite it is reloaded or kept beside a recovered draft, with a notice ([evidence](evidence/notes/W40.fix-notes-outside-edit-overwrite.md)).
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
  - 2026-10-15 W40.d9 — runtime evidence added; stays `unproven` (the store layout, unknown keys and source-block legibility were not checked). The outside-edit overwrite is not a stated N-02 promise but loses text; filed `W40.fix-notes-outside-edit-overwrite` (S1).
  - 2026-10-15 W40.fix-notes-outside-edit-overwrite — the overwrite is fixed: a clean editor reloads an outside body edit and says so; a dirty one keeps the original untouched and saves the in-app text as a separate "Recovered draft" note ([evidence](evidence/notes/W40.fix-notes-outside-edit-overwrite.md), VM 5/5). Stays `unproven` for the same unchecked layout/unknown-key/source-block reasons.
- **Notes:** "title = file name" holds after `NoteStore.sanitizedTitle` (`Store/NoteStore.swift:511-528`): illegal
  characters are replaced, the length is capped, and an empty title becomes `Untitled.md`. The `W9.d12d`
  divergence log is `NotesIndexer.filenameDivergence` (`Index/NotesIndexer.swift:117`, `:372`), pinned by
  `ArchiveNotesTests/NotesIndexTests.filenameDivergenceLogsWithoutChangingTheNote`. The promise draft records no
  W9.e2 result.

### N-03 · The archive corpus is never written

- **Promise:** Notes reads the Reader corpus only to resolve links and render pages. It never writes a tag,
  moves, or deletes a corpus file.
- **Promised in:** `CLAUDE.md` §Core Directive; `00-overview.md` §9, §12, §8.4; `SMOKE_TEST.md` step O
  ("corpus never touched"); `SUITE_TODO_DONE.md` `W9.b4` (renderer holds no write authority, never
  materialises dataless files).
- **Reached by:** a negative promise. These are the user paths that touch the corpus at all:
  - File ▸ Choose Archive Folder… (`ArchiveNotesCommands.swift:62`), or a preview popover's re-grant, runs
    `ReaderRootChooser.runOpenPanel` (`Links/ReaderRootChooser.swift:111`) and then `ReaderRootStore.grantRoot`.
    That bookmarks the root (`Links/ReaderRootStore.swift:127`) and only *reads* its marker (`:220`).
  - Clicking a source block's preview runs `ReaderPreviewPopover.show` (`Views/ReaderPreviewPopover.swift:46`),
    then `showPDF` (`:224`), which calls `PDFDocument(url:)`.
  - Chip thumbnails: `SourceBlockThumbnailRenderer.png` (`Views/SourceBlockThumbnailRenderer.swift:20`) calls
    ArchiveCore `PDFThumbnailer`. Its open is wrapped in `CorpusWalker.withDatalessMaterializationDisabled`
    (`packages/ArchiveCore/Sources/ArchiveCore/Thumbnails/PDFThumbnailer.swift:87-89`), and its PNG cache is in
    Caches (`Views/ReaderPreviewPopover.swift:456`).
  - Link resolution: `ReaderLinkResolver` (`Links/ReaderLinkResolver.swift:203`).

  Code reading found no tag write, move, trash or file write aimed at a Reader root. The one Finder-tag writer,
  `NotesTagProjector.projectWithDelta` (`Core/NotesTagProjector.swift:94`), refuses any URL outside the note's own
  item directory (`:104-112`).
- **Real-path test:** none for the negative promise. No test opens, previews or resolves a corpus file and then
  checks that its bytes, tags and mtime are unchanged. Nearest: `ArchiveNotesTests/NotesTagProjectorTests.outsideItemDirRejected`
  and `ArchiveNotesTests/NotesTagProjectorSafetyTests.scratchPathPredicate` (the projector's guards), plus
  `ArchiveNotesTests/ReaderLinkContainmentTests` (resolution cannot escape the root).
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** **Drift.**
  - The promise holds by code discipline, not by the OS. The app has `files.user-selected.read-write`
    (`ArchiveNotes.entitlements`), and the Reader-root bookmark is minted without
    `.securityScopeAllowOnlyReadAccess` (`Links/ReaderRootStore.swift:127`), so a granted archive root is writable
    from Notes.
  - The `W9.b4` "never materialises dataless files" guard covers the thumbnailer, but not the preview popover's
    `PDFDocument(url:)` (`Views/ReaderPreviewPopover.swift:225`). See suspect `S-007`.
  - The promise draft records no W9.e2 result.

### N-04 · Finder-tag mirror on the note's own file

- **Promise:** the note's own `.md` carries Finder tags mirroring its subjects (title-cased), its Quality as
  `Q1`–`Q3` (none when unrated), and its date as the existing Year/Month/Day/Decade facets. Unrelated Finder
  tags and the colour label are kept; a matching tag someone else wrote is never adopted or removed; the old
  `ArchiveSuite` stamp is stripped. Authors are never mirrored.
- **Promised in:** `CLAUDE.md` §Core Directive, Impl Map `NotesTagProjector`, `NotesTagVocabulary`;
  `00-overview.md` D2, D4, D9, §7, §9, §17 (A11); `SMOKE_TEST.md` steps L, O; `SUITE_TODO_DONE.md`
  `W19.q4`, `W19.date`, `W9.b3`, `W9.c5`.
- **Reached by:**
  - **Subjects:** the inspector tag field (`Views/NoteTagsInspector.swift:70-73`) calls `NotesModel.addTag` or
    `removeTag` (`Core/NotesModel.swift:855`, `:863`). Both run through `mutateItem` (`:1266`), which saves with
    `projectSubjectTags` (`:870`). That calls `NotesTagProjector.project` (`Core/NotesTagProjector.swift:75`).
  - **Quality:** the inspector (`Views/NoteMetadataInspector.swift:415`), the inline list menu
    (`Views/NotesTableView.swift:336`) or the row context menu (`Views/NotesContextMenu.swift:82`) calls
    `NotesNavigationModel.setQuality` (`Core/NotesNavigationModel.swift:241`). That runs `NotesModel.setQuality`
    (`Core/NotesModel.swift:975`), then `reconcileFacetProjection` (`:1035`), then `projectFacetTags` (`:1007`).
  - **Date:** the inspector date row (`Views/NoteMetadataInspector.swift:476`) calls `NotesNavigationModel.setDate` (`Core/NotesNavigationModel.swift:203`), then
    `NotesModel.setDate` (`:887`), which saves through `mutateItem` and then `reconcileFacetProjection`.

  Every other save (a body autosave too) also re-runs the facet projection through `mutateItem`.
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testG17_InlineRenameAndInspectorTagsPersist` (reads the
  Finder projection back through `tagNamesKey`); `ArchiveNotesTests/QualityWriteTests.projectsCanonicalQualityTagLosslessly`;
  `ArchiveNotesTests/DateTagProjectionTests.externalMatchingDateTokenSurvivesClear`. The two unit tests drive
  `NotesModel` against a scratch `NoteStore`.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** **Drift.**
  - "A matching tag someone else wrote is never adopted or removed" holds for date facets, which have an exact
    ownership ledger. It does not hold for Quality. The facet projection treats `Q1`–`Q3` as always owned
    (`previouslyManaged: ownedDateFacetTokens.union(NotesTagVocabulary.qualityTokens)`, `Core/NotesModel.swift:1017`).
    So a hand-applied `Q2` that is not also a subject is removed on the note's next save. `W19.q4` ("replaces
    stale Q") makes this look intended, so the guide is what needs correcting.
  - The `ArchiveSuite` stamp is stripped lazily, on that note's next projection, not on launch. The strip also
    catches a *current* subject spelled `ArchiveSuite` on the facet path. See `S-006`.
  - Sent-with dates are mirrored too (`Core/NotesTagVocabulary.swift:45-50`, `W37.dual-date`). The promise does
    not say so.
  - Authors are not mirrored: `managedTokens` holds subjects, Quality and date facets only (`:25-32`). The label
    is never written (`Core/NotesTagProjector.swift:159`, `:166-170`).
  - The code follows D2/§9 in the source conflict the promise draft recorded (`00-overview.md` §5 "writes exactly
    `tags`" vs. D2/§9 and `CLAUDE.md`): it mirrors subjects plus Quality plus date facets.
  - W9.e2 result: `W9.e2-notes` verified tag editing with the projection read back via `tagNamesKey` (`testG17_…`).
    The W9.e2 records name no Quality or date-facet checks.

### N-05 · The index is built from disk, and a broken index says so

- **Promise:** on launch Notes builds its search index from the files in the store and the list fills; the
  index is disposable and rebuildable. If the index cannot be opened, the sidebar shows a warning instead of
  an empty library, and a repaired index repopulates.
- **Promised in:** `CLAUDE.md` Impl Map `NotesIndex`, `NotesIndexer` (W23.m9), `NotesModel` bootstrap;
  `SMOKE_TEST.md` step A; `00-overview.md` §3, §4, §11; `SUITE_TODO_DONE.md` `W23.m9`, `W23.m9-fu2`,
  `W23.m9-fu3`, `W23.h2-fu`.
- **Reached by:** launch → `Views/NotesBrowserView.swift:70` `.task` → `NotesModel.bootstrap`
  (`Core/NotesModel.swift:288`). That runs `reloadItems` (`:317`), then `buildIndexFromDisk` (`:343`), which calls
  `NotesIndexer.startIndexing` / `awaitSettled` and then `adoptIndexFailure` (`:368`). A failure sets
  `statusMessage`, which the sidebar shows (`Views/NotesFolderTreeView.swift:374-385`, `an.sidebar.status`). The
  list's empty-state overlay is suppressed while `indexFailure` is set (`Views/NotesBrowserView.swift:263`).
  Repair is noticed on the next read: `openIndexForQuery` (`Core/NotesModel.swift:403`) calls
  `scheduleIndexRepopulationAfterRecovery` (`:456`).
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testCorruptIndexWarningRetractsAfterScratchRepairAndReindex`
  (needs the fixture built with `AN_GUI_CORRUPT_INDEX=1`, skips otherwise);
  `ArchiveNotesUITests/NotesGUITests.testG0_IndexReadyProbeResolvesAfterInitialBuild`;
  `ArchiveNotesTests/NotesIndexRepopulationTests.repairedIndexIsRefilledOnALaterRead`.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:**
  - A repaired index is only noticed by a query: a search keystroke or a `reloadItems`. Nothing re-polls on its
    own.
  - The warning goes away on a tap (`Views/NotesFolderTreeView.swift:384`) and comes back on the next read.
  - The W9.e2 runs list the corrupt-index UITest as *skipped*. `W40.a3` ran it on its required fixture
    (1 passed, `evidence/notes/W40.a3-full-ui.md`). A green suite is not runtime evidence.

### N-06 · Works at 100,000 notes and 2 million words

- **Promise:** the app stays fast with 100k notes / 2M words: indexing, search, list and navigation.
- **Promised in:** `CLAUDE.md` intro; `00-overview.md` §11; `09-gap-closure.md` C6; `SUITE_TODO_DONE.md`
  `W9.c6` (index 28.75 s, search <1 ms, navigation 1.293 s).
- **Reached by:** the N-05 launch path over a large store (`Core/NotesModel.swift:288`, `:343`). Search goes
  through `NotesModel.search` (`:497`), and the list recomputes through `NotesNavigationModel.recompute`.
- **Real-path test:** `ArchiveNotesTests/NotesScalePerfTests.fullIndexSearchSummariesAndNavigationStayBoundedAtCorpusScale`.
  It drives the real `buildIndexFromDisk`, indexer search, `allSummaries` and `NotesNavigationModel.recompute` on
  a generated 100k / 2M-word store. It is disabled unless `ARCHIVE_NOTES_SCALE_ACCEPTANCE=1`, so an ordinary
  unit run reports it skipped (until W40.a4 it returned early and reported a pass).
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:**
  - The test's limits (index < 300 s, search < 5 s, summaries < 10 s, recompute < 5 s) are far looser than the
    `W9.c6` figures the promise cites. A pass does not reproduce those numbers.
  - It builds the model with the injection init, not `bootstrap`, so first paint at launch is not timed.
  - The promise draft records no W9.e2 result. W9.e1 notes that C6 is opt-in and run by nothing.

## Windows and the item list

### N-07 · Notes and Extracts windows

- **Promise:** two three-pane windows (folder tree · item list · detail): the Notes window features notes and
  the Extracts window features extracts, through a kind control whose per-window choice persists.
- **Promised in:** `CLAUDE.md` Impl Map `ArchiveNotesApp`, `NotesBrowserView`, `NotesNavigationModel`,
  `NotesAppSettings`; `SMOKE_TEST.md` step C; `00-overview.md` §1, D10.
- **Reached by:**
  - The Notes window opens at launch (`ArchiveNotesApp.swift:36`).
  - The Extracts window opens from Window ▸ Extracts (SwiftUI lists each `Window` scene there,
    `ArchiveNotesApp.swift:71`), or is raised by `openWindow` on an extract jump/create
    (`Views/NoteEditorPane.swift:353`).
  - Both are `NotesBrowserView` (`Views/NotesBrowserView.swift:41-56`: tree · list · detail), each with its own
    `NotesNavigationModel(..., persistingKindTo: .standard)` (`:37-38`).
  - The kind control is the segmented `Picker` (`Views/NotesFilterBar.swift:54-62`). It sets `nav.kindFilter`, and
    `filter.didSet` persists the choice per window (`Core/NotesNavigationModel.swift:61`). The choice is restored
    in `init` (`:159`).
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testG12_SourcesColumnIsHiddenInTheNoteWindowAndShownInTheExtractsWindow`
  (opens both windows, drives the kind control); `ArchiveNotesTests/NotesNavigationModelTests.kindFilterScopesDisplayed`.
  `ArchiveNotesTests/NotesAppSettingsTests.windowKindRoundTripsPerWindowIndependently` tests the settings helper
  only. No test passes `persistingKindTo:`, so "the choice persists" has no real-path test.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** the folder scope (`NotesModel.selectedFolderId`) lives on the shared model, not per window. See the
  N-11 note. The promise draft records no W9.e2 result.

### N-08 · Item list columns and remembered layout

- **Promise:** the list shows kind, title, instances, date, quality, sources and tags; columns can be hidden
  per window (the Notes window hides Sources by default); window size and panel widths are remembered.
- **Promised in:** `CLAUDE.md` Impl Map `NotesTableView`, `NotesAppSettings` (W21, W14.4d),
  `NotesBrowserView`; `SUITE_TODO_DONE.md` `W14.4` (d); `09-gap-closure.md` 2026-07-17 addendum (d).
- **Reached by:**
  - **Columns** are built in `Views/NotesTableView.swift:85-104`: kind `⬦`, Title, In, Date, Quality, Sources,
    Tags.
  - **Hiding a column:** right-click the header, which opens `ColumnPickerHeaderView.menu` (`:439`). That runs
    `toggleColumn` and then `NotesAppSettings.setWindowHiddenColumns`. The initial hidden set comes from
    `windowHiddenColumns` (`:106`). Its default hides `sources` in the Note window only
    (`Core/NotesAppSettings.swift:147-149`).
  - **Panel widths:** dragging a `PanelDivider` updates `@AppStorage` (`Views/NotesBrowserView.swift:24-26`,
    `:47`, `:52`).
  - **Window size** is saved in `onDisappear` (`:72-78`, `NotesAppSettings.persistWindowSizeOnDisappear`) and
    restored in `configureWindow` (`:211-228`).
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testG12_SourcesColumnIsHiddenInTheNoteWindowAndShownInTheExtractsWindow`
  (the per-window default). `ArchiveNotesTests/NotesAppSettingsTests.windowHiddenColumnsDefaultHidesSourcesInNoteWindowOnly`
  and `.windowSizeRoundTrips` test the settings helpers only. No test hides a column through the header menu, and
  none checks sizes across a relaunch.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:**
  - One window size is shared by both windows (`NotesAppSettings.windowSize`).
  - Size is written only in `onDisappear`, which may not run on ⌘Q. See `S-008`.
  - The kind column's title is `⬦`, so the column menu's item for it reads `⬦`.
  - The promise draft records no W9.e2 result.

### N-09 · Sort, with Reader's chronological order

- **Promise:** the list sorts by title, date, kind or quality, with secondary sort and items lacking a value
  last. Date order matches Reader's: decades at their start, uncertain dates sort by their date (in italics),
  medieval years correct.
- **Promised in:** `SMOKE_TEST.md` step D; `CLAUDE.md` Impl Map `NotesSort`, `ItemSummaryDisplay`;
  `00-overview.md` §7, §16.5.
- **Reached by:**
  - **Primary sort:** a header click calls `sortDescriptorsDidChange` (`Views/NotesTableView.swift:389-396`). That
    runs `NotesNavigationModel.setSort` (`Core/NotesNavigationModel.swift:247`), which recomputes the list with
    `NotesSort.sorted` (`Core/NotesSort.swift:30`). Missing values sort last in either direction (`:47-70`).
  - **Secondary sort:** header right-click ▸ "Set as Secondary Sort" (`Views/NotesTableView.swift:466-478`).
  - **Uncertain dates:** the date cell is italic when the date is uncertain (`:306-309`).
- **Real-path test:** `ArchiveNotesTests/NotesSortTests.dateAscendingUndatedLast` and `.multiLevelDateThenTitle`;
  `ArchiveNotesTests/ItemSortDateTests.testItemSortDateMatchesArchiveCoreSharedFormula` (with `.testMedieval`,
  `.testDecadeStart1970s`, `.testUncertainDateStillSorts`). No UITest clicks a header.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** a non-empty search swaps the sort to relevance and swaps it back on clear
  (`Core/NotesNavigationModel.swift:474-477`). The promise draft records no W9.e2 result.
  2026-10-16 `W40.e5`: Periphery reports `sortDescriptorsDidChange` unused, and the code reads that way (it sits
  on the delegate, not the data source), so the header-click path above may be dead: suspect `S-016`.

### N-10 · Empty-list guidance

- **Promise:** once indexing settles, an empty list says whether the library is empty, the folder is empty,
  or nothing matches the search/filter; a failed index never looks like an empty library.
- **Promised in:** `CLAUDE.md` Impl Map `NotesBrowserView` (W9.d8); `09-gap-closure.md` D8;
  `SUITE_TODO_DONE.md` `W9.d8`.
- **Reached by:** the list's overlay (`Views/NotesBrowserView.swift:259-268`). It shows only when
  `isIndexReady && indexFailure == nil && displayed.isEmpty`, and picks library, folder or matches in
  `emptyState` (`:275-291`).
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testW9D8_EmptyFolderAndNoMatchesExplainTheResult` (the
  folder and no-match cases). No test reaches `an.list.empty.library`. No test asserts that the overlay is absent
  over a failed index.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:**
  - Over a failed index the list is an empty table with no overlay, and the only explanation is the sidebar line
    (N-05). Tapping that line dismisses it (`Views/NotesFolderTreeView.swift:384`). The window then shows a bare
    empty table until the next read re-posts the line.
  - "Folder is empty" is decided by `folder.itemCount == 0` (`Views/NotesBrowserView.swift:281`). A folder holding only items of the other
    kind reads as "No matches".
  - W9.e2 result: `W9.e2-notes` verified the empty states with `NotesGUITests.testW9D8_…`.

### N-49 · The stacked layout: list above the note

- **Promise:** besides side by side, the Notes and Extracts windows offer a stacked layout: the folder tree stays on
  the left, the item list sits on top of the right-hand area and the note below it. Switching keeps the selection,
  the open note's unsaved edits and the scroll position. The audit, layout sweep, visual review and writing journey
  that cover the side-by-side windows hold in the stacked one too, light and dark.
- **Promised in:** `SUITE_TODO.md` `W48.notes-stacked-layout` (owner, 2026-10-28).
- **Reached by:** View ▸ List Above Note (`ArchiveNotesCommands.swift`, `LayoutCommands`) writes `an.layoutMode`;
  `NotesBrowserView` lays the list, divider and detail out in one `AnyLayout` (`VStackLayout` when stacked), so the
  editor is not rebuilt by a switch.
- **Real-path test:** `ArchiveNotesUITests/StackedLayoutUITests.testSwitchingLayoutsKeepsSelectionUnsavedTextAndScroll`
  (VM: four switches with a line typed inside the autosave delay before each, in the Notes window, then both ways in
  the Extracts window). `AccessibilityAuditUITests.testMainScreensPassAuditStacked{Light,Dark}Mode`,
  `LayoutGuardUITests.testMainScreensLayOutStacked{Light,Dark}Mode` (typical, minimum, and narrow-and-tall),
  `VisualReviewUITests.testTourStacked{Light,Dark}` (opt-in) and `WritingJourneyStackedUITests` (the whole W40.d9
  journey stacked).
- **Runtime evidence:** none (a green suite is not runtime evidence, README §Statuses).
- **Status:** `unproven`
- **History:**
  - 2026-10-29 W48.notes-stacked-layout — row written and the layout built, `unproven`; the re-check is
    `W48.notes-stacked-layout-verify`.
- **Notes:**
  - One choice for both windows, like the panel widths.
  - The VM runs while it was built found five things, fixed in the same item: the note was squeezed to a 9 pt
    editor in a short window (the list now gives way, the note keeps 480 pt, the list 220 pt, the stacked
    panes' minimum 707 pt), the list's filter bar spilling under the toolbar at a 140 pt list, and three accessibility-audit findings the side-by-side audit never reached because the narrower
    list kept those columns off screen: the Quality cell's unnamed group, empty Tags and Sources cells, and the
    filter bar's decorative date dash. The builder's runs: [`evidence/notes/W48.notes-stacked-layout.md`](evidence/notes/W48.notes-stacked-layout.md).

### N-50 · The stacked layout's divider

- **Promise:** a horizontal divider between the list and the note drags to resize the list, clamps at both ends,
  and its height is remembered across relaunches. It is the same accessible splitter as the vertical dividers
  (role splitter, a value, increment and decrement), oriented horizontally; VoiceOver meets the list, then the
  divider, then the note, and Tab still reaches the note from the list.
- **Promised in:** `SUITE_TODO.md` `W48.notes-stacked-layout`.
- **Reached by:** `PanelDivider(axis: .vertical)` (`Views/PanelDivider.swift`) over `an.listHeight`, clamped
  220–440 pt by `NotesLayoutSettings.clampedListHeight` (`Core/NotesAppSettings.swift`), and further by
  `stackedListRange(paneHeight:)` so the note below keeps 480 pt; the remembered height is kept for a taller window.
- **Real-path test:** `ArchiveNotesTests/PanelDividerAccessibilityTests.testStackedDividerIsAHorizontalSplitterOverTheListHeight`
  and `NotesAppSettingsTests.listHeightClampsLikeTheWidths` (unit). `ArchiveNotesUITests/StackedLayoutUITests.testStackedDividerDragsClampsAndSurvivesRelaunch`
  and `.testStackedOrderIsListThenNoteAndFocusCrossesTheDivider` (VM).
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-29 W48.notes-stacked-layout — row written, `unproven`.

### N-51 · The layout choice is remembered

- **Promise:** the layout is a View menu choice (Side by Side / List Above Note), remembered across relaunches, and
  both windows follow it.
- **Promised in:** `SUITE_TODO.md` `W48.notes-stacked-layout`.
- **Reached by:** `LayoutCommands` and `NotesBrowserView` share `@AppStorage(an.layoutMode)`; a foreign value reads
  as side by side (`NotesLayoutSettings`).
- **Real-path test:** `ArchiveNotesTests/NotesAppSettingsTests.layoutModeDefaultsToSideBySideAndRoundTrips` (unit);
  `StackedLayoutUITests.testStackedDividerDragsClampsAndSurvivesRelaunch` (VM: stacked and its height after a
  relaunch) and `.testSwitchingLayoutsKeepsSelectionUnsavedTextAndScroll` (both windows switch together).
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-29 W48.notes-stacked-layout — row written, `unproven`.

## Writing and editing

### N-11 · Create a note

- **Promise:** ⌘N or the toolbar New menu creates a new note (filed in Inbox when no folder is chosen) that
  appears in the list at once; New from Template ▸ offers the templates for that kind.
- **Promised in:** `CLAUDE.md` Impl Map `NotesBrowserView`, `NotesModel.newItem`; `00-overview.md` §16.6;
  `SUITE_TODO_DONE.md` `W9.cand1`, `W9.e2-zotero`.
- **Reached by:**
  - **Toolbar New menu:** "New Note" (⌘N), or New from Template ▸ Blank or a template name
    (`Views/NotesBrowserView.swift:111-130`). Both run `newItem(from:)` (`:196`), then `NotesModel.newItem`
    (`Core/NotesModel.swift:701`). That files the item in the selected folder, or else in Inbox (`:713-714`), and
    upserts its index row (`:723-726`). The window then selects it (`Views/NotesBrowserView.swift:203-204`).
  - **Row context menu:** "New from Template" (`Views/NotesContextMenu.swift:49-61`).
  - **Template filter:** `model.templates(matching: nav.windowKind)` (`Core/NotesModel.swift:546`).
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testTemplateNewFromTemplateCreatesNoteWithTemplateBody`
  (the toolbar menu, the file on disk and the row in the list); `ArchiveNotesUITests/NotesGUITests.testG1_CreateNoteWritesNewItemFile`.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:**
  - ⌘N is a `.keyboardShortcut` on a button inside the toolbar `Menu`. G1 presses ⌘N but falls back to clicking
    the menu if nothing appears, so a G1 pass does not show that ⌘N works.
  - The folder scope is shared by both windows. ⌘N in the Extracts window files the new extract into a folder
    picked in the Notes window.
  - With a smart folder selected, the new note goes to Inbox and may not match the visible query, so it does not
    "appear in the list at once".
  - The context-menu New from Template does not flush a pending template-body edit first. The toolbar does
    (`Views/NotesBrowserView.swift:198-200`). See `S-011`.
  - W9.e2 result: `W9.e2-zotero` found that `newItem` never wrote the new row to the index. It was fixed there
    (`Core/NotesModel.swift:720-726`) and pinned by `testTemplateNewFromTemplateCreatesNoteWithTemplateBody`, whose
    class is `NotesGUITests`, plus `NotesModelTemplateTests`. `W9.cand1` was VM-green on
    `testG1_CreateNoteWritesNewItemFile`, which checked the file on disk but not the list.

### N-12 · Styled editor with formatting

- **Promise:** a rich-text editor that saves Markdown: bold, italic, code, link, headings, lists, blockquote,
  code block, indent/outdent from a toolbar and the Format menu; Tab/Shift-Tab, Return and Backspace behave
  in lists; undo and find work; ordered lists renumber from their first number.
- **Promised in:** `CLAUDE.md` Impl Map `EditorTextView`, `EditorFormatting`, `FormattingToolbar`,
  `MarkdownBridge`; `00-overview.md` D6; `SMOKE_TEST.md` step G; `SUITE_TODO_DONE.md` `W9.d12b`.
- **Reached by:**
  - **Format menu** (`ArchiveNotesCommands.swift:8-48`: ⌘B, ⌘I, ⌥⌘C, ⌘K, ⌥⌘0–6, ⇧⌘U, ⇧⌘O, ⌥⌘Q, ⌥⌘K) and the
    editor toolbar (`Editor/FormattingToolbar.swift:25-90`). Both call `FormattingContext`
    (`Editor/EditorFormatting.swift:39`, e.g. `toggleBold` `:103`), which calls the static `EditorFormatting`
    actions (`:398`).
  - **List keys:** `EditorTextView.insertTab` / `insertBacktab` / `insertNewline` / `deleteBackward`
    (`Editor/EditorTextView.swift:504-603`). These call `EditorFormatting.indentList` / `outdentList` (`:552`,
    `:566`).
  - **Find:** `usesFindBar = true` (`Editor/EditorTextView.swift:448`).
  - **Saving:** `MarkdownBridge.serialize`, which renumbers ordered lists from the first ordinal
    (`Editor/MarkdownBridge.swift:420-431`).
- **Real-path test:** `ArchiveNotesTests/FormattingActionTests.toggleBoldProducesBoldMarkdown` (and the other
  `FormattingActionTests` cases). These call `EditorFormatting` directly, which is the function the menu and
  toolbar reach, but they skip `FormattingContext`. Also `ArchiveNotesTests/MarkdownBridgeTests.orderedListRenumbersFromFirst`
  and `ArchiveNotesTests/EditorBindingTests.textViewFindBarEnabled`. No test presses Tab, Shift-Tab, Return or
  Backspace in a list.
- **Runtime evidence:** [`evidence/notes/W40.d9-writing.md`](evidence/notes/W40.d9-writing.md): text typed with `typeText` into the styled editor saves; but each Return typed there is saved as one newline, so typed paragraphs merge into one when the note is reopened.
- **Status:** `broken`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
  - 2026-10-15 W40.d9 — `unproven` → `broken`: typed paragraph breaks are lost on reopen; filed `W40.fix-notes-return-paragraph` (S2).
- **Notes:** **Drift.**
  - There is no indent or outdent button on the toolbar and no Indent/Outdent item in the Format menu.
    `indentList` and `outdentList` are reached only from Tab and Shift-Tab, and `outdentList` also from Return or
    Backspace on an empty list item (`Editor/EditorTextView.swift:504-603`).
  - Undo is cleared on every raw/styled toggle (`Editor/MarkdownEditorView.swift:566`, by design per plan §6).
  - The typing gesture is owner-eye (GUI-HARNESS G2).
  - The promise draft records no W9.e2 result.

### N-13 · Raw Markdown toggle

- **Promise:** ⌘/ switches a note between styled and raw Markdown with no data loss; if the raw text cannot
  be styled, the editor stays raw and shows why.
- **Promised in:** `SMOKE_TEST.md` step G; `CLAUDE.md` Impl Map `MarkdownEditorView` (W9.d7);
  `00-overview.md` D6; `09-gap-closure.md` D7; `SUITE_TODO_DONE.md` `W9.d7`.
- **Reached by:**
  - The toggle button in the editor's strip, `an.editor.rawToggle`, with `.keyboardShortcut("/", .command)`
    (`Views/NoteEditorPane.swift:470-481`). It flips `isRaw`, and `MarkdownEditorView.updateNSView`
    (`Editor/MarkdownEditorView.swift:242-259`) then calls `Coordinator.switchMode` (`:523`).
  - That flushes write-back first (`:526`). Going to styled it probes with `MarkdownBridge.parseWithStatus`
    (`:531`). On failure it stays raw and calls `onParseFailure` with the reason (`:541-548`). The pane shows the
    reason as a label (`Views/NoteEditorPane.swift:78-80`).
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testG3_RawMarkdownToggleShowsSourceAndIsLossless` (clicks
  the button, not ⌘/); `ArchiveNotesTests/EditorBindingTests.hardStyledParseFailureKeepsRawSourceAndShowsReason`
  (forces the failure through a DEBUG flag on the real `switchMode`); `ArchiveNotesTests/EditorBindingTests.switchModePreservesText`.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:**
  - G3 checks "lossless" after normalising whitespace. Its own comment records that a toggle used to canonicalise
    whitespace on disk. `EditorBindingTests.flushOfUneditedStyledNoteDoesNotRewriteIt` pins the later
    no-rewrite rule.
  - Nothing presses ⌘/.
  - The promise draft records no W9.e2 result.

### N-14 · Autosave, on switching and on quit

- **Promise:** edits save themselves; switching notes flushes the outgoing edit first; quitting within the
  autosave delay still saves the edit.
- **Promised in:** `SMOKE_TEST.md` steps G, P; `CLAUDE.md` Impl Map `NoteBodyEditorModel`,
  `EditorFlushRegistry`, `ArchiveNotesApp` (W7-S6); `SUITE_TODO_DONE.md` W7 record (S6).
- **Reached by:**
  - **Typing:** `NoteBodyEditorModel.markdown` `didSet` calls `scheduleSave`, which waits 600 ms
    (`Editor/NoteBodyEditorModel.swift:55`, `:136`). It then calls the `save` closure
    (`Views/NoteEditorPane.swift:380`), which runs `NotesModel.setBody` (`Core/NotesModel.swift:1121`) and then
    `mutateItem`.
  - **Switching notes:** `.onChange(of: nav.selectedItemID)` (`Views/NoteEditorPane.swift:134`) calls
    `bodyEditor.select` (`Editor/NoteBodyEditorModel.swift:78`), which runs `flushEditor()` and `flush()` before it
    loads the next note.
  - **Quit:** `NotesAppDelegate.applicationShouldTerminate` (`ArchiveNotesApp.swift:108-117`) awaits
    `EditorFlushRegistry.flushAll`, bounded at 2 s. Each pane registers its flush at `Views/NoteEditorPane.swift:123`.
- **Real-path test:** `ArchiveNotesTests/EditorTerminateFlushTests.editWithinDebounceFlushedToDisk` (a real
  `NoteBodyEditorModel` → `NotesModel.setBody` → a scratch `NoteStore`, flushed through `EditorFlushRegistry`; it
  calls `flushAll` itself, not the app delegate); `ArchiveNotesTests/NoteBodyEditorModelTests.editThenSwitchSavesOutgoingOnly`
  (the real switch logic, with closure stubs for load/save); `ArchiveNotesTests/TerminateFlushCoordinatorTests.boundedReplyOnTimeout`.
- **Runtime evidence:** [`evidence/notes/W40.d9-writing.md`](evidence/notes/W40.d9-writing.md): typing autosaves with no other action (on disk after 1.3 s); ⌘Q pressed straight after typing, inside both debounces, saved the edit; closing the window straight after typing saved it. Held in every VM run.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
  - 2026-10-15 W40.d9 — runtime evidence for idle autosave, quit and window close; stays `unproven`: switching notes with an unsaved edit was not driven.
- **Notes:**
  - No test quits the real app within the debounce.
  - On quit, a store write that takes longer than 2 s is abandoned, by design.
  - The promise draft records no W9.e2 result.

### N-15 · Inline images

- **Promise:** pasting or dragging an image into a note stores it in that note's own `assets/` and shows it
  inline; a reference outside the note's own assets is never shown (a Blocked placeholder), a missing file
  shows Missing.
- **Promised in:** `CLAUDE.md` Impl Map `EditorTextView`, `InlineImageAttachment`, `AssetPathResolver`
  (W23.m3), `InlineImageMarkdown`; `00-overview.md` §4; `SUITE_TODO_DONE.md` `W23.m3`, `W9.g4-flake`.
- **Reached by:**
  - **Pasting (⌘V):** `EditorTextView.paste` (`Editor/EditorTextView.swift:652`) calls `tryPasteImage` (`:707`).
  - **Dragging:** `performDragOperation` (`:692`) calls the same `tryPasteImage`.
  - **Storing:** `tryPasteImage` calls `ItemAssetStore.addAsset` (`Editor/InlineImageAttachment.swift:355`), which
    writes the bytes through `NoteStore.writeReservedAsset`. The asset store is retargeted to the selected item at
    `Views/NoteEditorPane.swift:393-394`.
  - **Display:** `MarkdownBridge.parse` resolves each image reference with `assetStore.resolve`
    (`Editor/MarkdownBridge.swift:293-306`). That is `ItemAssetStore.resolve` (`Editor/InlineImageAttachment.swift:375`),
    which calls `AssetPathResolver.resolve` (`Editor/AssetPathResolver.swift:47`). An unresolved reference gets the
    Missing or Blocked placeholder (`Editor/InlineImageAttachment.swift:96-97`).
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testG4_PasteImageWritesAssetAndInlineReference` (through
  the DEBUG seam `an.editor.test.pasteImage`, which calls the real `tryPasteImage` but bypasses the ⌘V gesture);
  `ArchiveNotesTests/InlineImageReadSeamTests.rendererRefusesEscapingReference` and `.rendererKeepsMissingDistinctFromBlocked`;
  `ArchiveNotesTests/ItemAssetStoreTests.addPersistsAndSurvivesReload`. No test drags an image.
- **Runtime evidence:** [`evidence/notes/W40.d9-writing.md`](evidence/notes/W40.d9-writing.md): with the note's `assets/` read-only, a pasted PNG reports `ok`, the note gains the `![](assets/pasted-…)` reference, no file lands, and nothing tells the user.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
  - 2026-10-15 W40.d9 — runtime evidence for the failed-write path; stays `unproven` (a successful paste and a drag were not driven here). The silent failure is filed `W40.fix-notes-asset-write-silent` (S3).
- **Notes:**
  - Every image is stored as PNG named `pasted-<yyyyMMdd-HHmmss>.png` (TIFF, JPEG and HEIC are converted,
    `Editor/EditorTextView.swift:712-735`).
  - The paste path does not check raw mode, and G4 switches to styled mode before it pastes. See `S-009`.
  - The promise draft records no W9.e2 result. `W9.g4-flake` names `NotesGUITests.testG4_PasteImageWritesAssetAndInlineReference`
    (10/10 after the `--no-clipboard` fix).

## Item metadata

### N-16 · Rename a note

- **Promise:** a note is renamed inline in the list (Return, double-click, or Rename…); the `.md` is renamed
  inside its UUID folder, body and links survive, and a rejected rename restores the shown title.
- **Promised in:** `CLAUDE.md` Impl Map `NotesTableView`, `NoteTitleTextField` (W9.b3); `09-gap-closure.md`
  B3; `SUITE_TODO_DONE.md` `W9.b3`; `SMOKE_TEST.md` step L.
- **Reached by:** Return on a single selected row (`Views/NotesTableView.swift:544`, `ContextMenuTableView.keyDown`),
  double-click (`:398`, `tableViewDoubleClicked` → `renameSelection`), or the row menu's Rename… (inserted at
  `:74`). All three call `Coordinator.beginRename` (`:411`) → `NoteTitleTextField.beginRename`
  (`Views/NoteTitleTextField.swift:20`). Commit is `finishRename` (`:52`) → the cell's `onCommit`
  (`Views/NotesTableView.swift:275`) → `NotesModel.renameNote` (`Core/NotesModel.swift:843`) → `setTitle`
  (`:836`) → `mutateItem` (`:1266`) → `NoteStore.withItem` → `saveEntry` (`Store/NoteStore.swift:373`), which
  moves the `.md` to the new sanitized title inside the item dir (`:384-397`) and then replaces its bytes in
  place (`:404-408`).
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testG17_InlineRenameAndInspectorTagsPersist` (double-click +
  Escape no-write, Return rename, context-menu Rename…; asserts the UUID-folder filename and `title:`);
  `ArchiveNotesTests/NotesTagProjectorSafetyTests.renameRetainsSubjects` (model path: UUID, body, subjects,
  third-party tags and label survive); `ArchiveNotesTests/NoteStoreTests.saveRetitle`.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** the W9.e2 result named no rename test; `W9.b3` says G17 drives all three rename routes VM-green.
  The rejected-rename restore (`NoteTitleTextField.swift:69-73`, guarded on the same rename id and item id) has
  no test that forces `renameNote` to return false. Double-click on a single row always renames; the browser's
  `onDoubleClick` closure is empty (`Views/NotesBrowserView.swift:254`). "Links survive" holds by construction:
  links are by UUID, and the UUID dir is not renamed.

### N-17 · Subjects (tags)

- **Promise:** subjects are added and removed in the inspector; the Finder mirror follows, and a failed mirror
  write is retried with the same change, even after relaunch.
- **Promised in:** `CLAUDE.md` Impl Map `NoteTagsInspector` (W9.b3); `00-overview.md` §3.1, §3.2 (tags are
  whole-note only); `09-gap-closure.md` B3; `SUITE_TODO_DONE.md` `W9.b3`.
- **Reached by:** select an item, then in the detail inspector's Tags section type into "New tag" and press Add
  or Return (`Views/NoteTagsInspector.swift:37-43`), or press a tag's minus button (`:23`). `save` (`:62`) calls
  `NotesModel.addTag` / `removeTag` (`Core/NotesModel.swift:855`, `:863`) → `mutateItem(projectSubjects: true)`
  (`:1266`) → `NoteStore.withEntry` (`Store/NoteStore.swift:174`), which writes the pending-subjects journal
  before the YAML (`:180-191`) and projects via `projectSubjectTags` → `NotesTagProjector.project`
  (`Core/NotesModel.swift:870-881`). A failed projection shows "Couldn't finish saving tags." with Retry
  (`Views/NoteTagsInspector.swift:45-50`), which replays the same delta. The section sits in
  `NoteMetadataInspector` (`Views/NoteMetadataInspector.swift:70`), placed by `Views/NotesBrowserView.swift:357`.
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testG17_InlineRenameAndInspectorTagsPersist` (add and
  remove through the inspector; Finder tags read back via `tagNamesKey`);
  `ArchiveNotesTests/NotesTagProjectorSafetyTests.subjectProjectionRetry` (failure keeps removal ownership across a
  restart and an identical retry); `.subjectEditsRespectFacets`.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** **Drift:** the in-app Retry is per-session view state (`@State failedEdit`,
  `NoteTagsInspector.swift:11`), so it is gone after a relaunch. What survives a relaunch is the
  pending-subjects journal beside the `.md` (`NoteStore.swift:180-206`): the user has to make the same edit
  again, and that edit then still removes the old subjects. Nothing retries automatically. The W9.e2 result
  names `NotesGUITests.testG17_…` (projection read back via `tagNamesKey`). No UITest drives the Retry button.

### N-18 · Quality

- **Promise:** Quality is None or 1–3, set from the inspector's facet buttons, the list's inline menu, or the
  row menu's Set Quality; it saves to front-matter and mirrors `Q1`–`Q3`.
- **Promised in:** `00-overview.md` D9; `CLAUDE.md` Impl Map `QualityControl`, `NotesTableView`,
  `NotesContextMenu`; `SMOKE_TEST.md` steps L, O; `09-gap-closure.md` D4; `SUITE_TODO_DONE.md` `W9.d4`,
  `W9.d2`, `W19.q4`.
- **Reached by:** inspector None/1/2/3 buttons, `QualityFacetRow` (`Views/QualityControl.swift:10`, placed at
  `Views/NoteMetadataInspector.swift:413`); the list's Quality cell menu, `QualityInlineMenu`
  (`Views/QualityControl.swift:33`, built at `Views/NotesTableView.swift:331`); row menu ▸ Set Quality
  (`Views/NotesContextMenu.swift:77-89`). All call `NotesNavigationModel.setQuality`
  (`Core/NotesNavigationModel.swift:241`) → `NotesModel.setQuality` (`Core/NotesModel.swift:975`), which clamps
  to 1...3 or nil, saves via `NoteStore.withItem`, then `reconcileFacetProjection` (`:1035`) mirrors the Q token.
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testW9D4_InlineQualityMenuPersistsAndClears` (inline
  list menu); `ArchiveNotesTests/QualityWriteTests.writesQuality`; `.projectsCanonicalQualityTagLosslessly`.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** the W9.e2 result names `NotesGUITests.testW9D4_…` (inline quality edit, already on main). No UITest
  drives the inspector facet buttons or the row menu's Set Quality. Those two routes reach the same model call.

### N-19 · Date with precision and uncertainty

- **Promise:** a date at decade, year, month or day precision, with an "uncertain" flag, edited in the
  inspector and saved to front-matter. An impossible day (31 February) is refused with a note and saved at
  month precision.
- **Promised in:** `00-overview.md` §3.1, §7; `CLAUDE.md` Impl Map `Item.normalizedDate`, `GregorianDay`,
  `DateFieldEntry`; `SMOKE_TEST.md` step L; `SUITE_TODO_DONE.md` `W23.l4`, `W23.l4-fu`.
- **Reached by:** inspector Date section (`Views/NoteMetadataInspector.swift:204-283`): the precision segmented
  control (`:208`, which commits on change, `:505`), the Year/Month/Day fields with Set or Return
  (`:220-253`), Clear (`:226`), and the "Date uncertain" toggle (`:276`). `commit` (`:472`) composes through
  `DateFieldEntry.commit` (`Views/DateFieldEntry.swift:159`) and calls `NotesNavigationModel.setDate`
  (`Core/NotesNavigationModel.swift:203`) → `NotesModel.setDate` (`Core/NotesModel.swift:887`) →
  `Item.normalizedDate` (`Store/Item.swift:143`) → `mutateItem`. The impossible-day warning is
  `DateFieldEntry.impossibleDayNote` (`Views/DateFieldEntry.swift:84`), shown at
  `NoteMetadataInspector.swift:255-262`. The day check is `GregorianDay.isValidDay` (`Store/GregorianDay.swift:40`).
  The uncertain flag goes through `setDateUncertain` (`Core/NotesModel.swift:896`).
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testDateRowWarnsAndDropsImpossibleDayButKeepsValidMonthEnd`;
  `ArchiveNotesTests/FrontMatterDateWriteTests.impossibleDayDowngrades`; `.uncertainSortsByValue`.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** `W23.l4-fu` names the off-screen UITest for the 2026-02-31 warning. The W9.e2 result named none;
  the `W9.e2` closing record says a draft "daterow" finding did not reproduce, and the date-row test passed in
  the `W9.g16-flake` full VM suite. Picking a month in the menu commits at once (`monthBinding`, `:527`), so an
  impossible day is written straight away at month precision, before Set is pressed. Set stays disabled for
  that day (`dayFieldCommittable`, `:460`).

### N-20 · A second "sent with" date

- **Promise:** an item can carry a second date, the date of the letter it was sent with. Its own date sorts
  (falling back to the sent-with date), a date filter matches either, and both project as Finder tokens.
- **Promised in:** `CLAUDE.md` Impl Map `NotesFilter` (W37), `FrontMatterCodec` (`additional_dates`);
  `SUITE_TODO_DONE.md` `W37.dual-date`, `W37.dual-date-owner-ok`; `W24.cal1-toggle` (sent-with displays).
- **Reached by:** inspector "Sent with" section under Date (`Views/NoteMetadataInspector.swift:321-405`):
  precision control, Year/Month/Day with Set or Return, Clear, and "Sent-with date uncertain". `commitSentWith`
  (`:479`) → `NotesNavigationModel.setSentWith` (`Core/NotesNavigationModel.swift:218`) →
  `NotesModel.setSentWith` (`Core/NotesModel.swift:918`), which refuses a year that is not 3–4 digits
  (`:934-937`). The sort fallback is `ItemSummary.sortDate` / `sortsBySentWith` (`Index/NoteIndexRow.swift:106-110`).
  The filter is `NotesFilter.matches` → `dateRange.matchingRoles(item.dateKeysByRole)`
  (`Models/NotesFilter.swift:95`). Finder tokens come from `NotesTagVocabulary.sentWithFacetTokens`
  (`Core/NotesTagVocabulary.swift:45`), via `dateFacetTokens` (`:39`) in the facet projection.
- **Real-path test:** `ArchiveNotesTests/DualDateTests.projectsSentWithLosslessly` (model write → `.md` Finder
  tokens); `.filterMatchesEitherRole`; `.sortFallback`. No UITest drives the Sent with fields.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** the W9.e2 result named none. The entry point is in the inspector, as `W24.cal1-validator` says.
  When the item has no own date, the inspector says the list is sorted by the sent-with date (`:398-404`).

### N-21 · Authors, typed by hand

- **Promise:** a note and an extract can each have authors set by hand, one per line, with Set and Clear,
  without Zotero. Authors are saved to front-matter only and are searchable.
- **Promised in:** `CLAUDE.md` §Core Directive; `00-overview.md` §3.1, D7; `09-gap-closure.md` B8;
  `SUITE_TODO_DONE.md` `W9.b8`.
- **Reached by:** inspector Authors field ("One author per line") with Set / Clear
  (`Views/NoteMetadataInspector.swift:180-200`), shown for both kinds. `commitAuthors` (`:497`) →
  `NotesNavigationModel.setAuthors` (`Core/NotesNavigationModel.swift:234`) → `NotesModel.setAuthors`
  (`Core/NotesModel.swift:965`), which trims, drops blanks and keeps order and duplicates → `mutateItem`
  (no subject projection) → index upsert.
- **Real-path test:** `ArchiveNotesUITests/NotesE2NoteLifecycleTests.testE2_ManualAuthorsPersistForNoteAndExtractAndAreSearchable`;
  `ArchiveNotesTests/NotesTagProjectorSafetyTests.authorEditsPersistAndIndexIndependently`.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** the W9.e2 result is `W9.e2-notes`: the new `NotesE2NoteLifecycleTests` sets authors on a note and an
  extract, checks the front matter, finds them by keyword search and clears them. Its red was a test bug, fixed by
  adding the ids `an.detail.authors.set`/`.clear`. Checkpoint `e59e3bd`. Code confirms "front matter only":
  `setAuthors` passes no subject projection, and the facet projection takes date and Q tokens only.

### N-22 · Round-up notes

- **Promise:** a "Round-up note" toggle in the inspector; when every linked PDF falls in one year, Notes offers
  to set the note's date to it (never automatically); round-up is a search and smart-folder criterion.
- **Promised in:** `00-overview.md` §3.5; `CLAUDE.md` Impl Map `NotesFilter`, `RoundupYearSuggestion`;
  `09-gap-closure.md` D6; `SUITE_TODO_DONE.md` `W9.d6`.
- **Reached by:** inspector "Round-up note" toggle, notes only (`Views/NoteMetadataInspector.swift:104`) →
  `NotesModel.setRoundup` (`Core/NotesModel.swift:954`). The offer is a `.task` (`NoteMetadataInspector.swift:91-99`)
  that runs `loadRoundupSourceLinks` (`Core/NotesModel.swift:1101`) and `SourceBlockPreviewState.roundupYear`
  (`Views/ReaderPreviewPopover.swift:423`) → `RoundupYearSuggestion.commonYear`
  (`Sources/RoundupYearSuggestion.swift:6`). The "Use YYYY as note date" button (`NoteMetadataInspector.swift:113`)
  is the only write. Search criterion: the filter bar's Round-up picker (`Views/NotesFilterBar.swift:24`) →
  `NotesFilter.roundup` (`Models/NotesFilter.swift:37`, `:76`). The field is Codable (`:129`), so Save as Smart
  Folder carries it.
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testW9_RoundupInspectorAndFilter` (toggle writes
  `roundup: true` without touching the date; the filter picker narrows the list);
  `ArchiveNotesTests/RoundupTests.toggleAndSavedQuery`; `.sourceYears`.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** the W9.e2 result named none. The year offer reads each linked PDF's Finder tags read-only, under
  roots that are already granted. Any missing, undated, non-PDF or ungranted source suppresses the offer
  (`RoundupYearSuggestion.swift:12-40`). No UITest drives the "Use YYYY" button.

### N-23 · Display dates in other calendars

- **Promise:** Settings ▸ Dates ▸ "Show dates in other calendars", off by default; with it on, each item can
  choose a calendar (Julian, English 1752, French Republican, Hebrew, Islamic) and its day dates show in it,
  Julian marked "(O.S.)". The stored date never changes.
- **Promised in:** `CLAUDE.md` Impl Map `DisplayCalendarSettings`, `ItemSummaryDisplay`, `NotesSettingsView`,
  ArchiveCore `Calendars/`; `SUITE_TODO_DONE.md` `W24.cal1-toggle`, `W24.cal1`.
- **Reached by:** ⌘, (the `Settings` scene, `ArchiveNotesApp.swift:82`) ▸ Dates toggle
  (`Views/NotesSettingsView.swift:41`, `@AppStorage(DisplayCalendarSettings.enabledKey)`, default false). With it
  on, the inspector shows a Calendar picker (`Views/NoteMetadataInspector.swift:279`, `:287-304`) →
  `NotesModel.setDisplayCalendar` (`Core/NotesModel.swift:905`), which writes only `display_calendar`. Display
  goes through `ItemSummary.dateColumnText` / `displaySentWith` / `activeCalendar`
  (`Core/ItemSummaryDisplay.swift:68`, `:58`, `:42`) → `DisplayCalendarSettings.shown`
  (`Core/DisplayCalendarSettings.swift:27`, "(O.S.)" at `:33-37`). The calendars are
  `packages/ArchiveCore/Sources/ArchiveCore/Calendars/DisplayCalendar.swift:29-45`.
- **Real-path test:** `ArchiveNotesTests/DisplayCalendarToggleTests.storedDateUnchanged` (model write, stored
  bytes unchanged); `.settingDefaultsOff`; `.headerRendersCalendarDate`. No UITest drives the Settings toggle
  or the picker.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** the W9.e2 result named none. Under `julianEnglish1752`, "(O.S.)" appears only before 14 September
  1752 (`DisplayCalendarSettings.swift:34`). After that date it shows no mark, which is correct.

### N-24 · Enter a date in the item's calendar

- **Promise:** with a calendar chosen, a day is typed in that calendar, checked against its month lengths
  (an English `1700-02-29` is accepted under Julian-1752), and stored as the ISO day; with the option off,
  entry is unchanged (`1500-02-29` still accepted).
- **Promised in:** `CLAUDE.md` Impl Map `DateFieldEntry` (W24.cal1-validator); `SUITE_TODO_DONE.md`
  `W24.cal1-validator`, `W24.cal1`.
- **Reached by:** the inspector's Date fields at Day precision when the item has an active calendar
  (`Views/NoteMetadataInspector.swift:246-274`; the fields' calendar is seeded by `DateFieldEntry.seed`,
  `Views/DateFieldEntry.swift:206`, from `item.activeCalendar(calendarsEnabled:)`, `:431`). The month menu comes
  from `DateFieldEntry.monthChoices`; the check is `acceptedDay` → `calendar.stored(from:)` (ArchiveCore); the
  write is `commit` (`Views/DateFieldEntry.swift:159`) → `NotesModel.setDate`. The same rules drive Sent with
  (`:351-392`).
- **Real-path test:** `ArchiveNotesTests/DateFieldCalendarEntryTests.writesIsoDay` (Julian-1752 commit through
  `NotesModel.setDate`, `.md` holds `1700-03-11`); `.englishLeapDayAccepted`; `.optionOffUnchanged`. None drives
  the window.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** the W9.e2 result named none (`W24.cal1-validator`: "No VM UITest run"). The calendar applies at day
  precision only (`DateFieldEntry.entryCalendar`, `:44`). A stored month or year is always entered in Gregorian,
  and the inspector says so (`NoteMetadataInspector.swift:446-452`).

## Folders, replication and templates

### N-25 · Folder tree and system folders

- **Promise:** the sidebar shows All Notes, Inbox, Extracts, user folders and Smart Folders. Folders and
  subfolders are created, renamed and deleted from the sidebar; selecting one scopes the list to its members.
  The folder graph is also written to `organization.json`, so it survives an index wipe or a computer move.
- **Promised in:** `SMOKE_TEST.md` step B; `00-overview.md` D3, §3.6, §4, §11, §16.6; `CLAUDE.md` Impl Map
  `NotesFolderTreeView`, `OrganizationStore`, `OrganizationFile`; `SUITE_TODO_DONE.md`
  `W9.d2.review-folder-graph`.
- **Reached by:** `Views/NotesFolderTreeView.swift`. The sections are Smart Folders (`:93`, shown only when there
  are any), Folders with All Notes plus the tree (`:106-113`), and Templates (`:115`). Create: the bottom-bar +
  (`:389`) or folder menu ▸ New Subfolder… (`:309`) → `NotesModel.createFolder` (`Core/NotesModel.swift:1425`).
  Rename… (`:310`) → `renameFolder` (`:1459`). Delete (`:326`) → `deleteFolder` (`:1488`), or
  `deleteFolderDeletingStranded` (`:1526`) when it would strand notes. Rename and Delete are disabled on the
  system folders (`:311`, `:331`). Scope: the row tap (`:234`) or list selection (`applySelection`, `:409`) →
  `NotesModel.setFolderScope` (`Core/NotesModel.swift:1387`). Each `OrganizationStore` mutation ends in
  `exportOrganization` (`Index/OrganizationStore.swift:779`). `load(storeRoot:)` (`:199`) rebuilds the DB from
  the JSON.
- **Real-path test:** `ArchiveNotesUITests/NotesE2FolderTests.testE2_FolderCreateSubfolderRenameMoveToTopAndDelete`
  (each step asserted on `organization.json`); `ArchiveNotesTests/OrganizationStoreTests.exportAndReloadFromJSON`;
  `ArchiveNotesTests/NotesNavigationModelTests.folderScopeNarrowsDisplayed`.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** the W9.e2 result is `W9.e2-folders`: `NotesE2FolderTests` creates from the bottom-bar +, then New
  Subfolder, Rename and Delete, each asserted on `organization.json`, 3/3 VM-green. The folder-delete dialog says
  it "will permanently delete" the stranded notes (`NotesFolderTreeView.swift:140`), but they go to the Trash
  (`trashItems`). The code comment at `:131` admits the wording. This is copy for `W40.b5`, not a behaviour drift.

### N-26 · Reorder and re-parent folders

- **Promise:** drag a folder between siblings to reorder, onto a folder to re-parent (a cycle is refused);
  Move Up / Move Down and Move to Top Level in the folder menu.
- **Promised in:** `CLAUDE.md` Impl Map `NotesFolderTreeView` (W9.d1); `09-gap-closure.md` D1;
  `SUITE_TODO_DONE.md` `W9.d1`, `W9.e2-folders`, `W9.e2-fu1`.
- **Reached by:** folder drag (`.onDrag`, `Views/NotesFolderTreeView.swift:238`) onto a row.
  `NotesFolderDropDelegate.performDrop` (`:487`) treats the top and bottom quarter of the row as an edge
  (`edge`, `:471`) → `placeFolder` (`:251`), which reorders that level. The middle of the row goes to
  `handleDrop` (`:163`) → `NotesModel.moveFolder` (`Core/NotesModel.swift:1472`), which refuses a cycle with
  a message (`:1473-1476`, `wouldCreateCycle` `:1645`). The level's `ForEach.onMove` (`:287`) also reorders.
  The menu's Move Up / Move Down (`:317-320`, `shiftFolder` `:187`) and Move to Top Level (`:321`,
  `moveToTopLevel` `:196`) end in `OrganizationStore.moveFolder` (`Index/OrganizationStore.swift:325`).
- **Real-path test:** `ArchiveNotesUITests/NotesE2FolderTests.testE2_FolderDragToBottomEdgeReorders`;
  `.testE2_FolderMoveUpAndDownReorderTheLevel`; `ArchiveNotesUITests/NotesGUITests.testG18_DragFolderOntoFolderReparentsIt`.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** the W9.e2 result: `W9.e2-folders` found both D1 doubts real. A gap drop re-parented instead of
  reordering (filed `W9.e2-fu1`, fixed `af7d049`, `NotesE2FolderTests.testE2_FolderDragToBottomEdgeReorders`,
  4/4), and there was no way back to the top level (fixed by Move to Top Level). Drop onto a folder:
  `testG18_DragFolderOntoFolderReparentsIt`. `.testE2_FolderDragToSiblingGapReorders` also exists. A reorder is
  one `moveFolder` call per sibling (`:208-212`, `:263-267`), not one transaction. No test drives the cycle
  refusal by drag; `ArchiveNotesTests/OrganizationStoreTests.moveFolderCycleGuardRefuses` covers the store.

### N-27 · Replication: one note in many folders

- **Promise:** a note can live in several folders as replicants of one file: ⌥-drag replicates, plain drag
  moves, Add to Folder / Move in the row menu do the same without a drag; the inspector's Locations lists
  every folder the note is in.
- **Promised in:** `00-overview.md` D3, §3.6; `SMOKE_TEST.md` step M; `CLAUDE.md` Impl Map `NotesItemDrag`,
  `NotesContextMenu`, `LocationsInspector`; `SUITE_TODO_DONE.md` `W9.d12c`.
- **Reached by:** dragging a table row (ids only, `NotesTableDataSource`, `Views/NotesTableView.swift:525`) onto
  a folder row. `NotesFolderDropDelegate.performDrop` reads ⌥ at drop time (`Views/NotesFolderTreeView.swift:494`)
  → `handleItemDrop` (`:146`) → `NotesNavigationModel.replicate` (`Core/NotesNavigationModel.swift:406`) or
  `move` (`:431`, source = the current folder scope). Row menu ▸ Add to Folder / Move to Folder
  (`Views/NotesContextMenu.swift:119-126`) calls the same two methods. Locations: `LocationsInspector`
  (`Views/LocationsInspector.swift:13`, placed at `Views/NotesBrowserView.swift:349`) → `nav.locations(of:)`.
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testG7_ReplicateItemIntoFolderAddsMembership` (row menu
  Add to Folder); `.testW9_TableDragOptionReplicatesAndPlainMoves` (⌥-drag and plain drag);
  `ArchiveNotesTests/NotesReplicationTests.locationsListsAllFoldersSorted`.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** the W9.e2 result is `W9.e2-folders`: replicate is `NotesGUITests.testG7_ReplicateItemIntoFolderAddsMembership`
  (already VM-green). A plain drag from All Notes, a smart folder or a search has no source folder, so it
  becomes an add (`move`, `:442-446`). Row menu ▸ Move to Folder has no UITest.

### N-28 · Delete, and the last-instance guard

- **Promise:** removing a replicant is quiet; removing the last one asks first ("this will delete the note
  itself"), re-checks at confirm, and moves the note to the Trash (recoverable). Whole-item Delete in the row
  menu does the same after confirmation; Cancel changes nothing.
- **Promised in:** `SMOKE_TEST.md` step M; `00-overview.md` §3.6, §16.1; `CLAUDE.md` Impl Map
  `NotesNavigationModel`, `NotesModel.trashItems`, `NoteStore`; `09-gap-closure.md` D2; `SUITE_TODO_DONE.md`
  `W9.d2`, `W23.h3`, `W23.h3-fu`, `W23.m12`.
- **Reached by:** Locations ▸ minus (`Views/LocationsInspector.swift:38`) or row menu ▸ Remove from “folder”
  (`Views/NotesContextMenu.swift:129-143`) → `NotesNavigationModel.removeMembership`
  (`Core/NotesNavigationModel.swift:304`). A replicant is removed quietly; the last instance sets
  `pendingDeletion`. Row menu ▸ Delete… (`Views/NotesContextMenu.swift:94`) → `requestDeleteItem` (`:323`). The
  alert is at `Views/NotesBrowserView.swift:82-101`. Delete Note → `confirmDeletion` (`:353`), which re-checks
  via `removeConfirmedLastMembership` under a hard-delete window, then `NotesModel.trashItems`
  (`Core/NotesModel.swift:1585`) → `NoteStore.delete` → `deleteEntry` (`Store/NoteStore.swift:415`), a
  coordinated `trashItem` of the whole `<uuid>/` dir. Cancel only clears `pendingDeletion`.
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testG8_DeleteLastInstanceGuardCancelKeepsThenConfirmTrashes`;
  `.testG19_ContextMenuDeleteRemovesAllPlacementsAfterConfirmation`;
  `ArchiveNotesTests/NotesReplicationTests.confirmAfterConcurrentReplicateKeepsFile`.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** the W9.e2 result is `W9.e2-notes`: note delete and the delete-last-instance guard,
  `NotesGUITests.testG8_…` and `.testG19_…` (already on main). On the source conflict, the code moves the whole
  `<uuid>/` folder to the Trash (`NoteStore.swift:415-430`, never `removeItem`), so §3.6/§16.1 ("deletes the
  item's folder") and SMOKE M ("→ Trash") are each half right. The multi-select row-menu remove is suspect
  `S-010`.

### N-29 · Templates

- **Promise:** templates are created, duplicated, renamed, deleted and edited in-app; a folder can be assigned
  a template (children inherit the nearest one); New from Template creates a note with its title, body and kind.
- **Promised in:** `00-overview.md` §3.7, §16.4; `CLAUDE.md` Impl Map `Template`, `TemplatesManagerView`,
  `NotesFolderTreeView`; `09-gap-closure.md` D3; `SUITE_TODO_DONE.md` `W9.d3`.
- **Reached by:** the sidebar Templates row (`Views/NotesFolderTreeView.swift:115`) or folder menu ▸ Template ▸
  Manage… (`:352`) opens `TemplatesManagerView`. In it: New (`Views/TemplatesManagerView.swift:50-52`) →
  `NotesModel.createTemplate` (`Core/NotesModel.swift:581`); Duplicate (`:91-95`, `:106-111`) →
  `duplicateTemplate` (`:636`); Rename… (`:60`, `:98`) → `renameTemplate` (`:650`); Delete (`:65-69`) →
  `deleteTemplate` (`:673`). The body editor is `TemplateBodyEditorPane` (`Views/NoteEditorPane.swift:494`; it
  saves at `:580`) → `setTemplateBody` (`Core/NotesModel.swift:614`). Assign: folder menu ▸ Template ▸ name
  (`Views/NotesFolderTreeView.swift:337-354`) → `assignTemplate` (`Core/NotesModel.swift:552`); inheritance is
  `effectiveTemplate` (`:563`). Create from one: toolbar New (⌘N, uses the nearest template) or New ▸ New from
  Template (`Views/NotesBrowserView.swift:113-123`, `newItem(from:)` `:196`), or row menu ▸ New from Template
  (`Views/NotesContextMenu.swift:49-75`). Both reach `NotesModel.newItem` (`Core/NotesModel.swift:701`).
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testTemplateNewFromTemplateCreatesNoteWithTemplateBody`;
  `.testTemplateBodyEditPersistsAndReloads`; `ArchiveNotesTests/NotesModelTemplateTests.newFromTemplate`.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** the W9.e2 result is `W9.e2-zotero`: `testTemplateBodyEditPersistsAndReloads` and the new
  `testTemplateNewFromTemplateCreatesNoteWithTemplateBody`, 5/5 run (which found the N-11 index bug).
  `newItem` sets the new item's kind to the window's (or the row's) kind, not the template's
  (`Core/NotesModel.swift:708`). Only matching-kind templates are offered, so the two agree. The row-menu route
  skips the template-body flush and failed-save guard that the toolbar route applies: suspect `S-011`. No UITest
  drives Duplicate, Delete or folder assignment.
  `ArchiveNotesTests/OrganizationStoreTests.assignTemplateAndInheritance` covers inheritance at the store.

### N-30 · Item-row context menu

- **Promise:** right-clicking a row offers Open, Reveal in Finder, New from Template, Set Quality, Delete…, Add
  to Folder / Move / Remove, and Copy Link.
- **Promised in:** `CLAUDE.md` Impl Map `NotesContextMenu`; `09-gap-closure.md` D2, B9; `SUITE_TODO_DONE.md`
  `W9.d2`, `W9.b9`.
- **Reached by:** right-click on a row → `ContextMenuTableView.menu(for:)` (`Views/NotesTableView.swift:551`),
  which selects the clicked row → `contextMenuProvider` (`:70`) → `NotesItemContextMenu.make`
  (`Views/NotesContextMenu.swift:19`, wired at `Views/NotesBrowserView.swift:255`). For a single row the items
  are: Rename… (prepended by `NotesTableView.swift:73-80`), Open (`nav.select`, `:31-35`), Reveal in Finder
  (`NotesModel.revealInFinder`, `Core/NotesModel.swift:114`), Copy Link (`copyOpenLink`, `:125`), New from
  Template, Set Quality, and Delete…. For any selection: Add to Folder and Move to Folder (`:119-126`), plus
  Remove from “folder” when the list is scoped to a normal folder (`:129-143`).
- **Real-path test:** `ArchiveNotesUITests/NotesE2NoteLifecycleTests.testE2_ContextMenuOpenSelectsAndLoadsTheRow`;
  `ArchiveNotesUITests/NotesE2LinkTests.testE2_ContextMenuCopyLinkNamesTheClickedRow`;
  `ArchiveNotesUITests/NotesGUITests.testG19_ContextMenuDeleteRemovesAllPlacementsAfterConfirmation`.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** the W9.e2 result is `W9.e2-notes`: Open loads the right-clicked note and opens no window,
  `NotesE2NoteLifecycleTests` (W9.e1 had flagged "Open only re-selects" for E2 to settle). In code, Open is
  `nav.select(id)`, and the right-click has already selected the row (`NotesTableView.swift:554-556`). So the
  Open test would pass with Open as a no-op, and it does not meet the README's reverted-implementation bar for
  Open itself. Open, Reveal, Copy Link, New from Template, Set Quality and Delete… appear only for a single
  selection. Rename… is in the menu but not in the promise. Reveal in Finder has no test. The multi-select
  Remove is suspect `S-010`.

## Search and smart folders

### N-31 · Keyword search as you type

- **Promise:** typing in the search field narrows the list by full-text search over title, tags, authors and
  body, ranked by relevance while a query is active; clearing restores the list.
- **Promised in:** `SMOKE_TEST.md` step E; `00-overview.md` §11; `CLAUDE.md` Impl Map `NotesFilterBar`,
  `NotesNavigationModel`, `NotesIndex`.
- **Reached by:** typing in the filter bar's "Search notes…" field (`Views/NotesFilterBar.swift:93`, bound to
  `nav.searchText`); a 150 ms debounce (`Core/NotesNavigationModel.swift:176`) calls `runFullTextSearch` (`:456`),
  which switches the sort to relevance (`beginSearch`, `:471`) and calls `NotesModel.search`
  (`Core/NotesModel.swift:497`) → `NotesIndex.search` (`Index/NotesIndex.swift:351`, FTS5 over title, tags,
  authors, body, ordered by `bm25(fts, 10, 6, 4, 1)`). The result is intersected and ranked in `recompute`
  (`Core/NotesNavigationModel.swift:501`). The field's clear button (`Views/NotesFilterBar.swift:97`) sets the
  text to "" and the same debounce drops the keyword filter and restores the default sort.
- **Real-path test:** `ArchiveNotesUITests/NotesE2SearchTests.testE2_KeywordSearchAndQualityTagDateFiltersNarrowTheList`
  (types into the real field, body-only word, then the clear button);
  `ArchiveNotesTests/NotesNavigationModelTests.keywordSearchIntersectsAndRanksByRelevance` (calls
  `runSearchAwaitingResult`, which skips the debounce but runs the same `beginSearch`/`applySearch`);
  `ArchiveNotesTests/NotesIndexTests.bm25TitleOutranksBody`.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** `W9.e2-search` ran `NotesE2SearchTests` 2/2 VM-green at checkpoint `850aac3` (the body-only word
  "egalitarian" found just its note). That is not runtime evidence. The FTS result set is held until the next
  keystroke: an edit that adds or removes the word in a note does not change the filtered list until the query
  is re-run (code reading, not checked).

### N-32 · Quality, tag and date filters

- **Promise:** ★1–★3 toggles, tag chips with ALL/ANY, and a year range each narrow the list; Clear resets them.
- **Promised in:** `SMOKE_TEST.md` step F; `00-overview.md` §16.3; `CLAUDE.md` Impl Map `NotesFilter`,
  `NotesFilterBar`.
- **Reached by:** filter bar row 2 (`Views/NotesFilterBar.swift:114`). The ★3…★1 buttons (`:127-139`) toggle
  `nav.filter.qualities`. The All/Any picker (`:146`) sets `tagCombine`. The "Tag…" field (`:156`) adds a chip on
  Return (`addPendingTag`, `:198`). The From/To year fields (`:182`, `:188`) set `dateFrom`/`dateTo` through
  bindings at `:216-236`. Each change recomputes the list through `NotesFilter.matches`
  (`Models/NotesFilter.swift:73`). Clear (`Views/NotesFilterBar.swift:81`) calls
  `NotesNavigationModel.clearUserFilters` (`Core/NotesNavigationModel.swift:257`), which keeps the kind.
- **Real-path test:** `ArchiveNotesUITests/NotesE2SearchTests.testE2_KeywordSearchAndQualityTagDateFiltersNarrowTheList`;
  `ArchiveNotesTests/NotesNavigationModelTests.qualityAndDateFacetsNarrowDisplayed` and
  `.clearUserFiltersResetsFacetsKeepsKind`; `ArchiveNotesTests/NotesFilterTests.testTagsAllVsAny` (predicate only).
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** `W9.e2-search` (`NotesE2SearchTests`): Quality 3, the intel tag and 1960–1970 each narrowed the
  list, and Clear restored it. That run's tag check used fixture tags written in lower case by
  `ArchiveNotes/scripts/make-notes-fixture.sh:159,183`. Tags entered in the app are stored title-cased, and the
  tag field matches the typed text exactly, so the green run may not reflect a real library. See suspect `S-012`.

### N-33 · Smart folders

- **Promise:** Save as Smart Folder keeps the current filter as a sidebar folder that scopes the list to its
  matches and shows a live match count, including zero.
- **Promised in:** `SMOKE_TEST.md` step F; `00-overview.md` §3.6, §16.3; `CLAUDE.md` Impl Map
  `NotesFolderTreeView`, `NotesModel` (W9.d9); `09-gap-closure.md` D9; `SUITE_TODO_DONE.md` `W9.d9`.
- **Reached by:** filter bar "Save as Smart Folder" button (`Views/NotesFilterBar.swift:72`) → name alert
  (`:37-43`) → `NotesNavigationModel.saveAsSmartFolder` (`Core/NotesNavigationModel.swift:277`, which folds the
  shared scope with `currentUserFilter`) → `NotesModel.createSmartFolder` (`Core/NotesModel.swift:1441`). The
  sidebar "Smart Folders" section (`Views/NotesFolderTreeView.swift:93-100`) shows each one with
  `model.smartFolderCounts`, `showZero: true` (`:98`, `:221`). Picking one (`:413-415`) calls
  `NotesModel.applySmartScope` (`Core/NotesModel.swift:1406`). The counts come from `refreshSmartFolderCounts`
  (`:1314`).
- **Real-path test:** `ArchiveNotesUITests/NotesE2SearchTests.testE2_SmartFolderFromFacetAndKeywordScopesTheList`;
  `ArchiveNotesUITests/NotesGUITests.testW9D9_SmartFolderShowsSavedQueryCount`;
  `ArchiveNotesTests/NotesNavigationModelTests.smartFolderBadgeCountsSavedQueryAndRefreshesOnItemsAndMembership`.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** `W9.e2-search` added the smart-folder test to `NotesE2SearchTests` (tag-saved and keyword-saved
  folders, `kind: smart` in `organization.json`, scoping), and `testW9D9_…` was already on main. Source conflict
  confirmed in code: `currentUserFilter` (`Core/NotesNavigationModel.swift:269`) folds the live keyword into
  `searchText`, which `NotesFilter.matches` tests as a title substring (`Models/NotesFilter.swift:107-108`). A
  smart folder saved from a body-only word therefore does not match the note that contains it. The promise
  sources record this as design. A smart folder saved with a tag facet also inherits `S-012`.

## Reader sources and provenance

### N-34 · Paste Reader links as source blocks

- **Promise:** pasting links copied in Reader (⌘⇧V, or a plain-text `archivereader://` URL) makes one source
  block per link, page or whole document, each headed by a provenance chip with a human label.
- **Promised in:** `00-overview.md` §1 (loop step 2), §3.2, §3.3, §8.4; `CLAUDE.md` Impl Map
  `SourceBlockPaster`, `ArchiveNotesCommands` (⌘⇧V), `BlockHeaderAttachment`; `SMOKE_TEST.md` step H.
- **Reached by:** Edit ▸ Paste as Source Block(s), ⌘⇧V (`ArchiveNotesCommands.swift:73-76`) →
  `FormattingContext.pasteSourceBlocks` (`Editor/EditorFormatting.swift:182`) → `SourceBlockPaster.readPasteboard`
  (`Sources/SourceBlockPaster.swift:28`: the Reader UTI payload first, then `archivereader://` lines in plain
  text) → `Coordinator.handleSourceBlockPaste` (`Editor/MarkdownEditorView.swift:597`). A plain ⌘V reaches the
  same handler through `EditorTextView.paste` (`Editor/EditorTextView.swift:652`) → `tryPasteSourceBlocks`
  (`:685`), wired at `Editor/MarkdownEditorView.swift:175`. A page link becomes `.readerPage` and a link with no
  page becomes `.readerDoc`. The plain-text label is the file name plus "— p. N".
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testG5_PasteArchiveLinkAsSourceBlockWritesReaderPageBlock`
  (seeds a plain-text link, clicks the real Edit-menu item, reads the `.md` back);
  `ArchiveNotesTests/SourceBlockPasterTests.testScanURLsMultipleLines` and `.testPayloadMultipleEntries`
  (parser only).
- **Runtime evidence:** [`evidence/notes/W40.d10-integrations.md`](evidence/notes/W40.d10-integrations.md): a page link copied with Document ▸ Copy Archive Link to This Page in the real Reader (string plus the Reader UTI payload) and pasted with Edit ▸ Paste as Source Block(s) became one `reader-page` block with its link, `display: "pages — p.3"` and `page: 3`. 2 of 2 VM runs. The plain-text route (G5) passed in the `W40.a3` full suite.
- **Status:** `works`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
  - 2026-10-15 W40.d10 — runtime evidence with the real Reader; `works`. The plain ⌘V route and a multi-link paste are still untested.
- **Notes:** `W9.e2-paste`: `testG5_…` ran 24/24 VM-green (`TEST_ITERATIONS=3`), commit `7ae8f24` (checkpoint
  `0d3df02`). No test covers the plain-⌘V route or a Reader UTI payload pasted in the GUI. In an extract the
  paste is declined and the text goes in as plain text (`Editor/MarkdownEditorView.swift:601`, §D7). That is by
  design, but the promise does not say so. A paste is capped at 100 links (`:605`).

### N-35 · Page thumbnails on pasted page links

- **Promise:** a pasted page link shows a rendered thumbnail of that page, even when Reader sent only the
  link, provided the archive folder is already granted; the block itself is kept at once.
- **Promised in:** `00-overview.md` §3.2, §5; `CLAUDE.md` Stack (W9.b4), Impl Map `SourceBlockThumbnailRenderer`;
  `09-gap-closure.md` B4; `SUITE_TODO_DONE.md` `W9.b4`.
- **Reached by:** the N-34 paste. `handleSourceBlockPaste` (`Editor/MarkdownEditorView.swift:597`) inserts the
  blocks first with pending ids (`:618-622`). It then asks `missingThumbnailProvider`
  (`Views/NoteEditorPane.swift:195`) → `SourceBlockPreviewState.thumbnail` (`Views/ReaderPreviewPopover.swift:419`)
  → `SourceBlockThumbnailRenderer.png` (`Views/SourceBlockThumbnailRenderer.swift:20`), which renders only for an
  exact, granted, contained page path. The image goes in through `hydratePendingSourceBlock` and
  `showInlineImagesOnceWritten` (`Editor/MarkdownEditorView.swift:640-650`).
- **Real-path test:** `ArchiveNotesUITests/NotesE2PasteTests.testE2_PastedPageLinkShowsARenderedThumbnail`;
  `ArchiveNotesTests/SourceBlockThumbnailRendererTests.rendersInkyPageToPNG` and `.skipsRenamedCandidate`.
- **Runtime evidence:** [`evidence/notes/W40.d10-integrations.md`](evidence/notes/W40.d10-integrations.md): the block pasted from the real Reader stored `assets/p3-thumb.png`, and the thumbnail drew the page. 2 of 2 VM runs.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
  - 2026-10-15 W40.d10 — thumbnail drawn for a link pasted from the real Reader; stays `unproven`: that paste carried Reader's own thumbnail payload, so the link-only render was not isolated.
- **Notes:** in `W9.e2-paste`, `testE2_PastedPageLinkShowsARenderedThumbnail` failed first: a fresh chip showed
  "Missing" until the note was reloaded. It was fixed in the same item (`showInlineImagesOnceWritten`) and then
  passed. A thumbnail embedded in a Reader UTI payload skips the renderer. It is size-capped at 5 MB of base64
  (`Sources/SourceBlockPaster.swift:70`).

### N-36 · Reveal in Reader and Preview

- **Promise:** a source chip's Reveal opens the PDF in Reader at the page; Preview shows the page in a popover
  inside Notes.
- **Promised in:** `SMOKE_TEST.md` steps H, K; `00-overview.md` §1 (loop step 5), §8.3, §8.4; `CLAUDE.md` Impl
  Map `BlockHeaderAttachment`, `ReaderPreviewPopover`, `NotesPDFPaneView`, `NoteEditorPane`.
- **Reached by:** the chip's Reveal and Preview buttons (`Editor/BlockHeaderAttachment.swift:240`, `:246`) →
  `revealClicked`/`previewClicked` (`:281`, `:285`). Reveal → `onRevealBlock` (`Views/NoteEditorPane.swift:183`)
  → `openExternalURL` (`Core/WorkspaceOpen.swift:17`) with the stored `archivereader://reveal…&page=N` link.
  Preview → `onPreviewBlock` (`Views/NoteEditorPane.swift:191`) → `SourceBlockPreviewState.show`
  (`Views/ReaderPreviewPopover.swift:409`) → `ReaderPreviewPopover.show` (`:46`) → `showPDF` (`:224`).
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testG6_RevealSourceBlockDispatchesReaderDeepLink`. It
  drives the same `onReveal` closure through a DEBUG seam rather than the chip button, and under a UITest launch
  the URL is recorded, not opened. `ArchiveNotesUITests/NotesE2PasteTests.testE2_MovedArchiveReGrantsFromThePreviewPopover`
  reaches Preview, also through the seam (`an.editor.test.preview`).
- **Runtime evidence:** [`evidence/notes/W40.d10-integrations.md`](evidence/notes/W40.d10-integrations.md): Reveal on a block pasted from the real Reader brought Reader forward and opened `pages.pdf` at "page 2 of 3", the pair holding the linked PDF page 3. Driven through the `an.editor.test.reveal` seam (same `onReveal` closure), with `-ANUITestRealWorkspaceOpen` so the URL went to the OS. 2 of 2 VM runs.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
  - 2026-10-15 W40.d10 — Reveal reaches the real Reader at the page; stays `unproven`: Preview was not driven, and Reveal with Reader not running was not covered.
- **Notes:** W9.e2 had no Reveal result. Preview showing the PDF is part of
  `NotesE2PasteTests.testE2_MovedArchiveReGrantsFromThePreviewPopover` (`W9.e2-paste`). Clicking the chip buttons
  and a real Reader launch (G6) are left to the owner per §17. Notes only hands Reader the URL. Whether Reader
  opens at the page is Reader's promise.

### N-37 · A moved archive is re-granted in Notes

- **Promise:** links name the archive by its identity, not its path, so after moving the archive (or the
  computer) the preview offers "Choose Archive Folder…"; picking the right folder resolves the link, a wrong
  folder is refused, and an unavailable root asks for access rather than calling the source missing.
- **Promised in:** `00-overview.md` D5, §8.1–§8.3; `SMOKE_TEST.md` step K; `CLAUDE.md` Stack (W8-S9),
  Impl Map `ReaderRootStore`, `ReaderLinkResolver`, `ReaderPreviewPopover`; `09-gap-closure.md` B7;
  `SUITE_TODO_DONE.md` `W9.b7`, `W23.m14-fu`.
- **Reached by:** Preview (N-36) → `ReaderLinkResolver.resolveExact` (`Links/ReaderLinkResolver.swift:202`). An
  unknown root GUID gives `.needsRootGrant`, and the popover shows "Choose Archive Folder…"
  (`Views/ReaderPreviewPopover.swift:105-117`) → `grantAction` (`:174`) → `ReaderRootChooser.chooseRootAndResolve`
  (`Links/ReaderRootChooser.swift:97`) → `ReaderLinkResolver.grantAndResolve` (`Links/ReaderLinkResolver.swift:279`),
  which returns `.wrongArchive` for a different marker GUID and `.grantRefused` for a folder that is not an
  archive root. There is also File ▸ Choose Archive Folder… (`ArchiveNotesCommands.swift:62`) →
  `SourceBlockPreviewState.chooseArchiveFolder` (`Views/ReaderPreviewPopover.swift:428`) →
  `ReaderRootChooser.chooseRoot` (`Links/ReaderRootChooser.swift:79`).
- **Real-path test:** `ArchiveNotesUITests/NotesE2PasteTests.testE2_MovedArchiveReGrantsFromThePreviewPopover`;
  `ArchiveNotesTests/ReaderRootChooserTests.pickingTheRightRootResolvesTheLink` and
  `.pickingTheWrongRootReportsMismatch`; `ArchiveNotesTests/DurableLinkE2ETests.linkResolvesThenSurvivesComputerMove`.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** `W9.e2-paste` covered this with `NotesE2PasteTests.testE2_MovedArchiveReGrantsFromThePreviewPopover`.
  The grant button appears only when the GUID has no stored root. A root that is still recorded but whose folder
  is no longer at its path (moved while Notes runs, or a volume ejected) goes to the basename search instead.
  When the root path is wholly absent, `scanForBasename` counts that as proof of absence
  (`Links/ReaderLinkResolver.swift:351-361`, the "W8-S9 computer-move contract"), and the popover says "Source
  file not found in the archive." with no grant button. See suspect `S-014`.

### N-38 · A renamed or moved file is searched for, without freezing

- **Promise:** when a linked file is not at its path, Notes searches the granted archive for the same file
  name in the background with an "N items checked" count, offers the match, never follows a symlink out of the
  archive, and says "search incomplete" rather than "not found" if it stopped early.
- **Promised in:** `00-overview.md` §8.3 (fallbacks); `CLAUDE.md` Impl Map `ReaderLinkResolver` (W23.m14,
  W23.l1), `ReaderPreviewPopover`; `SUITE_TODO_DONE.md` `W23.m14`, `W23.l1`.
- **Reached by:** Preview (N-36) → `ReaderPreviewPopover.show` (`Views/ReaderPreviewPopover.swift:62-85`). On
  `.needsBasenameSearch` it shows a searching popover and runs `ReaderLinkResolver.resolve`
  (`Links/ReaderLinkResolver.swift:250`) → `scanForBasename` (`:326`) off the main actor, bounded and
  cancellable, with canonical containment (`:113-122`). Progress reads "N items checked"
  (`Views/ReaderPreviewPopover.swift:330`). The outcomes are presented at `:119-141`.
- **Real-path test:** `ArchiveNotesTests/ReaderLinkScanTests.walkRunsOffTheMainThread`,
  `.boundReportsIncompleteNotAbsence` and `.searchStillFindsRenamedCandidate`;
  `ArchiveNotesTests/ReaderLinkContainmentTests.basenameFallbackRefusesEscapingMatch`. All drive the resolver,
  not the popover.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** **Drift:** "offers the match" overstates it. A `.renamedCandidate` shows a message naming the
  found file (`lastPathComponent` only) with no button: there is no way to preview it, open it or re-link the
  chip to it (`Views/ReaderPreviewPopover.swift:119-123`). The resolver's comment says "Offer (don't auto-open)"
  (`Links/ReaderLinkResolver.swift:234`). The early-stop text says "did not finish (N items examined)… may still
  be there", not "search incomplete". The meaning matches; the wording differs. W9.e2 had no result for this row,
  and no UITest drives the popover's search.

## Extracts

### N-39 · Create Extract and Append to Extract

- **Promise:** Extract ▸ Create Extract (⌘⌥E) or Append to Extract… turns a selected passage into an extract
  with its own copy of the text and images and a link back to the source; the source note is untouched. The
  Extracts window comes forward (opening if closed) with the extract selected; the title is the passage's first
  line without Markdown.
- **Promised in:** `SMOKE_TEST.md` step I; `00-overview.md` §1 (loop step 3), D7; `CLAUDE.md` Impl Map
  `ArchiveNotesCommands`, `ExtractBuilder`; `09-gap-closure.md` B6, D5; `SUITE_TODO_DONE.md` `W9.b6`, `W14.4`
  (b), `W9.b5-fu1`, `W3.notes-extract-title-*`.
- **Reached by:** Extract ▸ Create Extract, ⌘⌥E (`ArchiveNotesCommands.swift:111`) →
  `FormattingContext.createExtract` (`Editor/EditorFormatting.swift:312`, via `makeNotePassageSource`, `:290`) →
  `NotesModel.createExtract` (`Core/NotesModel.swift:767`) → `ExtractBuilder.createExtract`
  (`Core/ExtractBuilder.swift:290`, title from `defaultTitle`, `:265`). Extract ▸ Append to Extract…
  (`ArchiveNotesCommands.swift:114`) → `FormattingContext.appendToExtract` (`Editor/EditorFormatting.swift:323`,
  NSAlert picker) → `NotesModel.appendToExtract` (`Core/NotesModel.swift:796`). Both end in `openItem`
  (`:107`), and `NoteEditorPane.handleOpen` (`Views/NoteEditorPane.swift:340`) selects the extract and opens or
  raises the Extracts window.
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testG9_CreateExtractFromSelectionWritesExtractItem`;
  `ArchiveNotesUITests/NotesGUITests.testG15_OpenRequestOpensTheClosedFeaturingWindow` (⌘⌥E with Extracts
  closed); `ArchiveNotesUITests/NotesE2PasteTests.testE2_MenuCreatedExtractEmbedsTheImageBytes`. Unit:
  `ArchiveNotesTests/ExtractCommandTests.createExtractMenuActionKeepsTheSourceItemAssetBoundary`.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** W9.e1 rated D5 PARTIAL (nothing was raised when the Extracts window was closed). That led to
  `W9.b5-fu1` and `testG15_OpenRequestOpensTheClosedFeaturingWindow`. In `W9.e2-paste`,
  `testE2_MenuCreatedExtractEmbedsTheImageBytes` showed byte-identical image bytes and an unchanged source note.
  Two tests are named `testG15_…` in `NotesGUITests`; cite them by full name. `appendToExtract` does not re-run
  the facet projection that `createExtract` does (`Core/NotesModel.swift:775-776` against `:803-807`). That may be
  correct, since append changes no date or quality, but it is not checked.

### N-40 · Copy a passage, paste it into an extract

- **Promise:** copying a passage in a note and pasting it into an extract brings its provenance chip (shown as
  a chip, not raw text) and imports the image bytes into the extract's own assets.
- **Promised in:** `CLAUDE.md` Impl Map `PassagePasteboard`, `NotesPassagePayload`, `ExtractBuilder` (W14.3);
  `SUITE_TODO_DONE.md` `W14.3`, `W9.cand2`, `W9.cand2-fu1`; `09-gap-closure.md` 2026-07-18 addendum (retired
  candidate).
- **Reached by:** ⌘C in a note's styled editor → `EditorTextView.copy` (`Editor/EditorTextView.swift:633`) →
  `Coordinator.copyPassageIfNote` (`Editor/MarkdownEditorView.swift:760`) → `PassagePasteboard.write` (writes the
  passage UTI, RTF and plain text). ⌘V in an extract's editor → `EditorTextView.paste` (`:652`) →
  `tryPastePassage` (`:678`) → `Coordinator.handlePassagePaste` (`Editor/MarkdownEditorView.swift:775`) →
  `ExtractBuilder.pastedExtractMarkdown`, which copies image bytes through `assetStore.addAsset`, then parses the
  result to chips.
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testG13_LiveCopyPasteImportsInlineImageBytesIntoTheExtract`;
  `ArchiveNotesTests/PasteboardPassageTests.testCopyPastePayloadRoundTripPreservesProvenance` (payload only);
  `ArchiveNotesTests/ExtractBuilderTests.pasteImportsBytesNoCollision`.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** `W9.e2-paste`: `testG13_…` passed 3/3 (no `<!-- block:` after the paste, ⌘Z/⇧⌘Z, reselect), which
  retired the 2026-07-18 candidate. The copy path is off in raw mode and for extracts. There, ⌘C is a normal
  copy and the paste lands as plain text (`Editor/MarkdownEditorView.swift:761-762`).

### N-41 · Jump to Source and live provenance chips

- **Promise:** an extract's note-passage chip shows the source note's current title (updating across windows)
  and has Jump to Source, which brings the Notes window forward (opening it if closed), selects the note and
  scrolls to the passage. A deleted source greys the chip.
- **Promised in:** `SMOKE_TEST.md` step H; `00-overview.md` D7; `CLAUDE.md` Impl Map `NotePassageResolve`,
  `BlockHeaderAttachment`, `NoteEditorPane`; `SUITE_TODO_DONE.md` `W14.4` (b, c), `W9.b5-fu1`, `W9.d12a`,
  `W21.vmgui-c-fu`, `W9.w21-red`.
- **Reached by:** the chip's "Jump to Source" button (`Editor/BlockHeaderAttachment.swift:227`) → `jumpClicked`
  (`:289`) → `onJumpBlock` (`Views/NoteEditorPane.swift:198`) → `NotesModel.openItem` (`Core/NotesModel.swift:107`)
  → `NoteEditorPane.handleOpen` (`Views/NoteEditorPane.swift:340`) → `NotePassageResolve.openAction`. The result
  is `.selectAndScroll` in the Notes window, `.openFeaturingWindow` when that window is closed (`:359-367`), or
  `.reportSourceMissing`. The live title and missing state come from `passageSummaries`/`passageGeneration`
  (`Views/NoteEditorPane.swift:206-207`), and the chip renders them at `Editor/BlockHeaderAttachment.swift:192`.
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testG10_JumpToSourceSelectsSourceNoteInNoteWindow`;
  `ArchiveNotesUITests/NotesGUITests.testG15_OpenRequestOpensTheClosedFeaturingWindow` (jump through the
  `an.editor.test.jump` seam with the Notes window closed);
  `ArchiveNotesUITests/NotesGUITests.testW21_CrossWindowPassageChipReStylesAfterSourceTrash`.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** W9.e1 rated this PARTIAL (a jump with the Notes window closed did nothing). `W9.b5-fu1` fixed it, and
  VM `testG15_OpenRequestOpensTheClosedFeaturingWindow` covers both directions. That test drives Jump through a
  DEBUG seam, not the chip button. If the source's block ordinal no longer matches, the jump selects the note
  without scrolling and says "The source note has changed since this extract was made."
  (`Views/NoteEditorPane.swift:216-222`).

### N-42 · Extract provenance summary and Sources column

- **Promise:** an extract's inspector groups its passages by source note with live titles and counts (missing
  notes keep their saved label); the Sources column counts an extract's distinct source notes.
- **Promised in:** `CLAUDE.md` Impl Map `NoteIndexRow`, `ItemSummaryDisplay`, `SourceAnchor+NotePassage`
  (W9.d10); `09-gap-closure.md` D10; `SUITE_TODO_DONE.md` `W9.d10`, W7 record (S4).
- **Reached by:** selecting an extract shows the inspector's Sources section (`Views/NoteMetadataInspector.swift:58`,
  `:128`). It loads through `NotesModel.loadExtractSources` (`Core/NotesModel.swift:1091`) →
  `[Block].notePassageSourceUsage` (`Store/SourceAnchor+NotePassage.swift:61`), and the live title comes from
  `sourceDisplay` (`Views/NoteMetadataInspector.swift:171`), falling back to the saved chip label and "Source note
  missing". The Sources column cell (`Views/NotesTableView.swift:316`) shows `ItemSummary.sourcesText`
  (`Core/ItemSummaryDisplay.swift:96`), indexed from `distinctSourceNoteCount` (`Index/NoteIndexRow.swift:64`).
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testW9_ExtractInspectorShowsSourceSummary`;
  `ArchiveNotesUITests/NotesGUITests.testG12_SourcesColumnIsHiddenInTheNoteWindowAndShownInTheExtractsWindow`;
  `ArchiveNotesTests/KindFilterQueryTests.sourceUsage`; `ArchiveNotesTests/NotesIndexTests.sourceCountRoundTrip`.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** W9.e2 had no result for this row. The inspector reloads when the extract's mtime changes. Live titles
  follow `allItems`, so they update without a reload.

## Zotero

### N-43 · Attach Zotero links, citation chips

- **Promise:** a `zotero://select/…` link (item or attachment) can be attached to a block (Note ▸ Attach Zotero
  Link…) or to the whole note (inspector Attach to note). It shows a chip that opens the item in Zotero and
  fetches a citation in the configured style, with a spinner, an offline warning and Retry. A Zotero link on
  the clipboard is offered once, not for links already attached. Zotero not running degrades gracefully.
- **Promised in:** `00-overview.md` D8, §3.4; `SMOKE_TEST.md` step J; `CLAUDE.md` Impl Map
  `ZoteroChipView`, `NoteZoteroInspector`, `ZoteroClipboardDetect`, `ZoteroStatusModel`, `ZoteroClient`;
  `09-gap-closure.md` B2; `SUITE_TODO_DONE.md` `W9.b2`, `W9.g16-flake`.
- **Reached by:** Note ▸ Attach Zotero Link… (`ArchiveNotesCommands.swift:93`) → `FormattingContext.attachZoteroLink`
  (`Editor/EditorFormatting.swift:191`, which uses the clipboard link or else an NSAlert prompt) →
  `insertZoteroBlock` (`:215`). The inspector's "Attach to note" (`Zotero/NoteZoteroInspector.swift:35`) →
  `attach` (`:49`) → `NotesModel.attachZoteroReference` (`Core/NotesModel.swift:1140`), then `fetch` (`:68`) →
  `ZoteroStatusModel.fetchCitation` (`Zotero/ZoteroStatusModel.swift:75`), with "Retry citation" at `:24`. The
  clipboard banner (`Views/NoteEditorPane.swift:68`, `:436`) is deduplicated against links already attached
  (`:419-424`), and its Attach calls the block path. The chip opens Zotero from `ZoteroChipView.open`
  (`Zotero/ZoteroChipView.swift:71`) and from the block chip's "Open in Zotero"
  (`Editor/BlockHeaderAttachment.swift:257`, `:293`).
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testG16_NoteZoteroAttachmentChipsAndClipboardDedup`;
  `ArchiveNotesUITests/NotesGUITests.testG11_ZoteroChipDispatchesSelectLink`;
  `ArchiveNotesTests/ZoteroClipboardDetectTests.dedupCanonical`.
- **Runtime evidence:** [`evidence/notes/W40.d10-integrations.md`](evidence/notes/W40.d10-integrations.md): a note-level attachment fetched its citation from the real Zotero 10.0.6 local API (APA: `Lovelace, A. (1843). Notes on the Analytical Engine (W40.d10 seed). Richard and John E. Taylor.`), and the chip's open raised Zotero with the item selected. 2 of 2 VM runs.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
  - 2026-10-15 W40.d10 — real Zotero citation and Open in Zotero shown; stays `unproven`: the clipboard offer and Zotero-not-running were not driven against the real Zotero.
- **Notes:** **Drift:** the citation fetch, spinner and Retry exist only on the note-level inspector path. A
  block attached through Note ▸ Attach Zotero Link… (or the clipboard banner's Attach) shows `ref.citation ??
  itemKey` (`Editor/EditorFormatting.swift:217-218`). Nothing fetches a citation for it except Auto-fill (N-44):
  the only callers of `fetchCitation` are `NoteZoteroInspector.swift:74` and `ZoteroStatusModel.swift:71`.
  `W9.e2-zotero` checked `testG16_…` (chip, Fetching → citation, `selectLink` persisted, click dispatch, survives
  reselection) and `testG11_…` (select-link dispatch) through the DEBUG in-process transport only. Left to the
  owner: the real Zotero local API, a real citation, and `zotero://select` raising Zotero.

### N-44 · Auto-fill from Zotero

- **Promise:** Note ▸ Auto-fill from Zotero… fetches the attached reference's metadata and shows a per-field
  current→proposed sheet (empty fields preselected); Apply writes only the chosen fields and the citation,
  Cancel writes nothing; more than one reference is refused rather than guessed.
- **Promised in:** `00-overview.md` D8; `CLAUDE.md` Impl Map `ZoteroAutoFill`, `ZoteroAutoFillModel`,
  `ZoteroAutoFillSheet`; `09-gap-closure.md` B1; `SUITE_TODO_DONE.md` `W9.b1`.
- **Reached by:** Note ▸ Auto-fill from Zotero… (`ArchiveNotesCommands.swift:95`, enabled from
  `canAutoFillFromZotero` via `Views/NoteEditorPane.swift:96`) → `FormattingContext.autoFillFromZotero`
  (`Editor/EditorFormatting.swift:236`). It resolves the reference: none, or `.ambiguous` → status message
  (`:252-258`). Then `ZoteroStatusModel.fetchAutoFillData` (`Zotero/ZoteroStatusModel.swift:67`) → the sheet
  (`Views/NoteEditorPane.swift:99`, `ZoteroAutoFillSheet`) → `ZoteroAutoFillModel.confirm`
  (`Zotero/ZoteroAutoFillModel.swift:144`) → `NotesModel.applyZoteroAutoFill` (`Core/NotesModel.swift:1173`). The
  default selection is `plan.defaultSelection` (`Zotero/ZoteroAutoFillModel.swift:106`).
- **Real-path test:** `ArchiveNotesUITests/NotesGUITests.testG15_AutoFillFromZoteroShowsDiffCancelNoOpAndWritesAcceptedFields`;
  `ArchiveNotesTests/ZoteroAutoFillTests.modelCancelWritesNothing`, `.planFillEmpty` and
  `.attachedReferenceResolverRejectsAmbiguousNote`.
- **Runtime evidence:** [`evidence/notes/W40.d10-integrations.md`](evidence/notes/W40.d10-integrations.md): against the real Zotero, Note ▸ Auto-fill from Zotero… crashes Notes (SIGABRT in `ZoteroClient.fetchCSLviaLocalAPI`; Zotero returns `csljson` as a string holding an array). 2 of 2 VM runs, plus the crash report.
- **Status:** `broken` — `W40.fix-notes-zotero-csljson-crash` (S2)
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
  - 2026-10-15 W40.d10 — reproduced against the real Zotero; `broken`, filed `W40.fix-notes-zotero-csljson-crash` (S2).
- **Notes:** `W9.e2-zotero` ran `testG15_AutoFill…` (attach → Cancel writes nothing → Apply writes only the
  accepted date plus the configured-style citation) through the DEBUG in-process transport. There are two
  `testG15_…` tests; this row means the AutoFill one. A citation fetch that fails does not block Auto-fill
  (`Zotero/ZoteroStatusModel.swift:71`, `try?`).

## Links into Notes

### N-45 · Copy Link to a note or extract

- **Promise:** Note ▸ Copy Link and the row menu's Copy Link put the item's `archivenotes://open?id=…` URL on
  the clipboard, ready to paste into Scrivener.
- **Promised in:** `00-overview.md` §1 (loop step 5), §8.2, §16.8; `09-gap-closure.md` B9;
  `SUITE_TODO_DONE.md` `W9.b9`.
- **Reached by:** Note ▸ Copy Link (`ArchiveNotesCommands.swift:90`, enabled from `copyLinkAvailable`,
  `Views/NoteEditorPane.swift:98`) → `FormattingContext.copyCurrentItemLink` (`Editor/EditorFormatting.swift:98`)
  → `NotesModel.copyOpenLink` (`Core/NotesModel.swift:125`, writes plain text). The row context menu's "Copy
  Link" (`Views/NotesContextMenu.swift:43-44`) calls the same `copyOpenLink`.
- **Real-path test:** `ArchiveNotesUITests/NotesE2LinkTests.testE2_CopyLinkRoundTripSelectsTheLinkedNote`;
  `ArchiveNotesUITests/NotesE2LinkTests.testE2_ContextMenuCopyLinkNamesTheClickedRow`;
  `ArchiveNotesTests/NotesTagProjectorSafetyTests.copyOpenLinkWritesPlainTextURL` (declared in
  `NoteMetadataEditingTests.swift`).
- **Runtime evidence:** [`evidence/notes/W40.d10-integrations.md`](evidence/notes/W40.d10-integrations.md): Note ▸ Copy Link wrote `archivenotes://open?id=22222222-…` as plain text, and that URL opened the note. 2 of 2 VM runs. The row-menu Copy Link test passed in the `W40.a3` full suite ([`evidence/notes/W40.a3-full-ui.md`](evidence/notes/W40.a3-full-ui.md)).
- **Status:** `works`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
  - 2026-10-15 W40.d10 — runtime evidence; `works`. Scrivener taking the link stays with the owner (§17).
- **Notes:** `W9.e2-links` found Note ▸ Copy Link disabled with a note selected (`W9.e2-fu2`) and fixed it in that
  item. `NotesE2LinkTests` (menu and row-menu Copy Link) then passed 10/10, commit `83a117c` (checkpoint
  `b8c596d`). W9.e1 had rated B9 PARTIAL (the closed-window case), which led to `W9.b5-fu1`. Whether Scrivener
  accepts the scheme is left to the owner (§17).

### N-46 · Open an `archivenotes://` link

- **Promise:** opening an `archivenotes://open?id=…` link (from Scrivener, Reader or the clipboard) selects and
  raises that note or extract, opening its window if closed, and scrolls to `#block-n` if given; a link
  arriving at launch waits for the index instead of reporting the note missing.
- **Promised in:** `00-overview.md` §8.2, §16.1 (`openItem`), §16.8; `CLAUDE.md` Impl Map
  `NotesDeepLinkRouter` (W9.b5); `09-gap-closure.md` B5; `SUITE_TODO_DONE.md` `W9.b5`, `W9.b5-fu1`.
- **Reached by:** Launch Services URL → `.onOpenURL` on the Notes window's content (`ArchiveNotesApp.swift:46-48`)
  → `NotesDeepLinkRouter.handle` (`Links/NotesDeepLinkRouter.swift:19`) → `pendingOpen`. It is held until
  `isIndexReady` (`ArchiveNotesApp.swift:54-59`, `forwardPendingDeepLinkIfReady` `:88`, `forwardPendingOpen`), then
  `NotesModel.openItem` (`Core/NotesModel.swift:107`) → `NoteEditorPane.handleOpen` (`Views/NoteEditorPane.swift:340`),
  which selects, scrolls and raises, or opens the featuring window.
- **Real-path test:** `ArchiveNotesUITests/NotesE2LinkTests.testE2_CopyLinkRoundTripSelectsTheLinkedNote` (hands the
  URL to the running app through Launch Services, with the Notes window open);
  `ArchiveNotesTests/NotesDeepLinkRouterTests.forwardsAfterIndexReady` (declared in `ReaderLinkResolverTests.swift`).
- **Runtime evidence:** [`evidence/notes/W40.d10-integrations.md`](evidence/notes/W40.d10-integrations.md): the copied URL handed to the OS with no app named (Launch Services picks the app by scheme) selected and loaded the note with the Notes window open, with every window closed, and with only Extracts open. 2 of 2 VM runs. Suspect `S-013` cleared.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
  - 2026-10-15 W40.d10 — OS-dispatched link shown in three window states, `S-013` cleared; stays `unproven`: a link arriving while Notes is not running, and `#block-n`, were not driven.
- **Notes:** W9.e1 rated this PARTIAL, which led to `W9.b5-fu1` (`testG15_OpenRequestOpensTheClosedFeaturingWindow`).
  That test covers the in-app open request, not an external URL. In `W9.e2-links`, `NotesE2LinkTests` handed the
  copied URL to the running app through Launch Services, and it re-selected and loaded the note. Only the Notes
  window's content has `.onOpenURL` and the forwarding `onReceive`s. Nothing tests an external URL arriving with
  the Notes window closed, or with only the Extracts window open. See suspect `S-013`. A deep link to a deleted
  item reports with the passage wording "The source note for this passage no longer exists…"
  (`Views/NoteEditorPane.swift:357`). Scrivener honouring the scheme is a §17 deferral.

## Settings

### N-47 · Settings window

- **Promise:** ⌘, opens Settings with a Zotero section (enable, clipboard detection, citation style, advanced
  host and port) and a Dates section (N-23), each remembered.
- **Promised in:** `SMOKE_TEST.md` step N; `CLAUDE.md` Impl Map `NotesSettingsView`, `ZoteroSettings`;
  `SUITE_TODO_DONE.md` `W24.cal1-toggle`.
- **Reached by:** Archive Notes ▸ Settings…, ⌘, (the SwiftUI `Settings` scene, `ArchiveNotesApp.swift:82`) →
  `NotesSettingsView` (`Views/NotesSettingsView.swift:14`). Its `@AppStorage` keys (`:7-12`) are read back through
  `ZoteroSettingsStore.current` and `DisplayCalendarSettings.enabledKey`.
- **Real-path test:** none drives the Settings window. `ArchiveNotesTests/ZoteroSettingsTests.storedValuesRoundTrip`
  and `ArchiveNotesTests/DisplayCalendarToggleTests.settingDefaultsOff` read the same defaults keys the view
  writes, but not through the view.
- **Runtime evidence:** none
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b2 — row written, `unproven`.
- **Notes:** **Drift:** the advanced host and port are remembered, but they apply only at launch. The
  `ZoteroClient` is built once from `ZoteroSettingsStore.current.clientConfig` (`ArchiveNotesApp.swift:17-18`) and
  nothing rebuilds it. A changed port has no effect until relaunch, and the Settings text does not say so.
  Enable, clipboard detection and citation style are read when used and apply at once
  (`Zotero/ZoteroStatusModel.swift:36,53,69,77`). W9.e2 had no result for this row. Source conflict: `SMOKE_TEST.md`
  N lists only the Zotero section, but the code has both Zotero and Dates (`Views/NotesSettingsView.swift:40-50`).

### N-52 · The Appearance setting

- **Promise:** Settings offers Appearance: System (the default, following macOS), Light or Dark. A choice changes
  every open window at once, with a sheet or panel open, and every custom colour follows it; it is back before the
  first window on the next launch. The UI-test argument `-ArchiveUITestAppearance` still wins over it.
- **Promised in:** `SUITE_TODO.md` `W48.appearance-notes` (owner, 2026-10-29).
- **Reached by:** the Picker at the top of `Views/NotesSettingsView.swift`, `@AppStorage(AppAppearance.defaultsKey)`
  (`archiveAppearance`, the key all three apps share); `AppAppearance.follow()` (`Core/AppAppearance+AppKit.swift`, the
  AppKit half ArchiveCore may not hold) in `ArchiveNotesApp.init`
  applies it to `NSApp.appearance` at launch and on every defaults change, unless the UI-test argument forced a mode.
  Two things Notes drew once now redraw per appearance: the source chip's fill (`Editor/BlockHeaderAttachment.swift`,
  `BlockHeaderChipView.updateLayer`, a CGColor) and the Missing / Blocked image tiles
  (`Editor/InlineImageAttachment.swift`, a drawing-handler image); every other colour is a dynamic system colour.
- **Real-path test:** `ArchiveNotesTests/NotesAppearanceSettingTests` (stored value and default, the UI-test reset,
  the chip's fill in each appearance) and `ArchiveCoreTests/AppAppearanceTests` (unit).
  `ArchiveNotesUITests/AppearanceSettingUITests` (VM: Light and Dark live in the note window, a sheet and Settings;
  System back; restored after a relaunch; the argument wins). `AccessibilityAuditUITests` and `VisualReviewUITests`
  gain `…BySetting` variants that force the mode through the setting (`LayoutGuard.dark/lightSettingArguments`).
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-30 W48.appearance-notes — row written, `unproven`. The builder's runs:
    [`evidence/notes/W48.appearance-notes.md`](evidence/notes/W48.appearance-notes.md).

---

## Deferred — not rows

From `00-overview.md` §17 (moved there from `09-gap-closure.md` by `W9.e4`), plus open questions §15:

- Mirroring **author** into Finder tags / a SPEC `Author:` facet — open owner choice (A11, §15.4).
- A single merged unified-writer signature (§15.2).
- Unifying the page-2 header *builder*.
- A shared suite-wide storage path (§15.1, §13 "(later)").
- Page-within-merged-PDF scroll navigation (quick-preview page navigation).
- Editor tables, footnotes, task lists, strikethrough, HTML; undo across the raw toggle.
- Per-block stable GUIDs and the reverse "N extracts derive from this note" index.
- Scrivener round-trip confirmation (§15.6).
- Extract re-snapshot / refresh.
- Author inheritance.
- `zotero://open-pdf` page-anchored links.
- Zotero write-back (§15.5).
- Multi-root Reader.
- Universal-Clipboard cross-Mac confirmation (owner-eye, W8).
- Owner-eye GUI checks in `scripts/GUI-HARNESS.md`: G2 typing gesture, G6 real Reader launch, G11 real Zotero
  launch, chip-button click gestures (dispatch auto-asserted via spies/DEBUG seams).
- One Notes+Reader unified window (§15.3).
- DEVONthink import — on hold (umbrella `CLAUDE.md`), not a Notes promise yet.
- Off-main AST for large styled pastes (W9.d11: "future performance work"); a large paste may pause the UI.

## Source drift — doc against doc, for `W40.b5`

- `00-overview.md` §5 says the Finder mirror "writes exactly `tags` … nothing else"; D2, §9 and `CLAUDE.md`
  say subjects + `Q1`–`Q3` + date facets (N-04).
- `00-overview.md` §16.7 puts `PDFThumbnailer` "in the ArchiveNotes app target, NOT ArchiveCore"; §17's
  deviations and the `CLAUDE.md` map put it in ArchiveCore `Thumbnails/`.
- `00-overview.md` §3.6 and §16.1 `delete` say the last-instance delete removes the item's folder; `SMOKE_TEST.md`
  M and `CLAUDE.md` say it goes to the Trash (N-28).
- `00-overview.md` header says "A future cleanup pass may fold §16 … or promote it to `SPEC/` and then delete
  this file", and §14 says "keep `00-overview.md` until the whole app ships, then fold"; `CLAUDE.md`
  §*00-overview.md is the interface spec* records the owner's 2026-07-29 decision to keep it permanently.
- `00-overview.md` §3.6 gives `Folder.templateId`; §16.4 says there is no such field (self-declared superseded,
  but the §3.6 text was not updated).
- `SMOKE_TEST.md` step L: "Author / title / subject editing land as the gap-closure Phase B items wire in" —
  B3 and B8 shipped (`W9.b3`, `W9.b8`).
- `SMOKE_TEST.md` cites "the detailed automated check catalog (G0–G11)"; `CLAUDE.md` says G0–G17; the done
  records name G18, G19, `W9D*`, `W21_*` and five `NotesE2*Tests` classes beyond both.
- `SMOKE_TEST.md` §Results: "driven runs are gated on GUI mode being ON" and every step is `[ ]`; the Notes
  UITests have run in the VM lane since 2026-07-30 (`CLAUDE.md` Stack) and W40.a3 ran 57 of them.
- `SMOKE_TEST.md` step N lists only the Zotero section; Settings now also has Dates (`W24.cal1-toggle`).
- `CLAUDE.md` Impl Map `TemplatesManagerView`: "body editing rides the (deferred) note-editor wiring" —
  template body editing shipped in `W9.d3`.
- `CLAUDE.md` Impl Map `NotesContextMenu` lists Add to Folder / Open / Reveal / New from Template / Set Quality /
  Delete but omits Copy Link, which `W9.b9` added to the row menu.
- `09-gap-closure.md` 2026-07-18 addendum: "there is **no `File` menu** at all" and "⌘N appears unbound"; later
  records use File ▸ Choose Archive Folder… (`W9.e1` B7, `W9.e2-paste`) and `W9.cand1` shows ⌘N works.
  `SMOKE_TEST.md` also names File ▸ Choose Store Folder….
- `SUITE_TODO_DONE.md` W1 record: "The SPEC `ArchiveSuite` marker prose section (A4) is still pending — see
  `archive-notes/09-gap-closure.md`"; A4 was removed by R13d and the plan is deleted (`W9.e4`).
- `09-gap-closure.md` A8 / `SMOKE_TEST.md` cross-ref "G0–G11" while `CLAUDE.md` says the suite joined the VM
  lane with G0–G17 — same catalogue-number drift as above, seen from the plan.
- `00-overview.md` §8.4 says Reader's Copy Archive Link payload carries `thumbnailPNGbase64?`; `W9.b4` says Notes
  must also render thumbnails for "text-only pasted page links", i.e. the payload is not always present —
  consistent, but §8.4 reads as if the thumbnail always comes from Reader.
