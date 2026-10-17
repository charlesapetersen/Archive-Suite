# Archive Reader — feature ledger

Format and statuses: [`README.md`](README.md). Written by `W40.b1`, 2026-10-12.

- **Sources the promises were written from (rule 3, before the code was opened):** `ArchiveReader/CLAUDE.md`
  (Core Directive, Safety Protocol, Architecture, §Keyboard map, §Options, §Edge-case rules, §Decisions),
  `ArchiveReader/README.md` §What it does, `ArchiveReader/SMOKE_TEST.md` (steps A–V and Batch 2), and the Reader
  done-records in `SUITE_TODO_DONE.md` (`W4`, `W18.reader-breadcrumb`, `W19.q3`, `W23.m2`, `W23.m4`, `W23.m6`,
  `W23.m9`, `W24.jpeg1`, `W24.cal1-reader`, `W26.walk2`, `W14.2-fu`). `SPEC/tag-format.md` is the contract
  behind R-05 and R-45.
- **Sources and code read at:** `caefe33a`.
- **Count:** `unproven 36 · works 3 · broken 4 · unreachable 3 · fixed-pending-recheck 1` (works: R-21, R-28, R-29; broken: R-11, R-13, R-23, R-45; unreachable: R-25, R-26, R-47; fixed-pending-recheck: R-46). Updated by `W40.audit-ledger`, 2026-10-17.

**Runtime evidence, for every row below: none yet.** The W40.a3 full VM suite
([`evidence/reader/W40.a3-full-ui.md`](evidence/reader/W40.a3-full-ui.md), `a5ab9e3c`) passed every UITest
named under *Real-path test* here. A green suite is not runtime evidence for a feature (README §Statuses), so
no row moves to `works` on it. The journeys (`W40.d*`) provide the evidence.

**Drift.** Where the code does not do what the promise says, *Notes* starts with **Drift**. A drift note is
input for `W40.b5`, which corrects the guide or files a fix. It is not a reproduced bug and does not make the
row `broken` (rule 5). Suspected bugs found while tracing are in [`SUSPECTS.md`](SUSPECTS.md).

Paths below are relative to `ArchiveReader/macOS/Sources/ArchiveReader/` unless they say otherwise. Test
bundles are `ArchiveReaderTests` (unit, app-hosted), `ArchiveReaderUITests` (XCUITest, VM only) and
`ArchiveCoreTests`.

---

## Discovery and the list

### R-01 · Choose the archive folder

- **Promise:** File ▸ Choose Archive Folder… (⌘⇧O) grants one archive root. The grant is a security-scoped
  bookmark, so the root comes back after a relaunch. The Options panel does not manage roots.
- **Promised in:** `CLAUDE.md` §Keyboard map, §Options (closing note), §Stack & Build; `README.md` §Architecture.
- **Reached by:** ⌘⇧O, `ArchiveReaderCommands.swift:52`, or the toolbar folder button,
  `Views/NavigationWindowView.swift:502`. Both call `NavigationModel.chooseRoot` (`Views/NavigationModel.swift:942`),
  which calls `RootFolderStore.setRoot` (`Search/RootFolderStore.swift:93`). On relaunch, `NavigationModel.init`
  re-resolves the saved root (`:142`), then calls `library.start` (`:235`).
- **Real-path test:** `ArchiveReaderTests/RootFolderStoreTests.testASymlinkedPickIsAdoptedAsItsTarget` and
  `.testARefusedPickLeavesAnAlreadyOpenRootAlone`. Both test the pick only. No test resolves a saved bookmark
  across a relaunch, and none drives the open panel.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.

### R-02 · Discovery by walking the root

- **Promise:** the Reader walks the granted root itself, with no Spotlight. It lists every file tagged `Read`
  or `Unread`, tagged non-PDF images included. A warm start paints from the local index, then revalidates, and
  progress is shown. About 102k PDFs walk in about 10 s.
- **Promised in:** `CLAUDE.md` §Verified Facts (Search/discovery), §Architecture, §Decisions, §Edge-case rules;
  `README.md` §What it does; `SUITE_TODO_DONE.md` `W26.walk2`; `SMOKE_TEST.md` step A.
- **Reached by:** launch with a saved root, or R-01, calls `library.start(scope:)`
  (`Views/NavigationModel.swift:235`, `:980`), which runs `ArchiveLibrary.start` (`Search/ArchiveLibrary.swift:249`).
  The warm paint is `publishWarmSnapshot` (`:550`) and revalidation is `beginScan` (`:569`). Progress text is
  `firstScanDetail`, `Views/NavigationWindowView.swift:263` and `:591`. The walker is
  `packages/ArchiveCore/Sources/ArchiveCore/Corpus/CorpusWalker.swift`. It filters on the read-state tag only,
  with no extension filter (`:263-275`, `:534-590`).
- **Real-path test:** `ArchiveReaderUITests/WarmStartUITests.testWarmRowsPaintAsRevalidatingBeforeTheyPaintAsSettled`;
  `ArchiveReaderTests/LibraryWarmStartTests.testColdQuitWarmPublishesCacheBeforeWalkThenCorrectsAClosedAppTagChange`;
  `ArchiveReaderUITests/ArchiveReaderUITests.testAnUntaggedFolderShowsTheScannedDenominator`.
- **Runtime evidence:** the timing clause only. [`evidence/reader/W40.d7-at-size.md`](evidence/reader/W40.d7-at-size.md): 150,000 synthetic files (115,999 listed) walk cold in
  6.98 s (43.8 µs/file, `.utility`), warm start 0.48 s; the `W40.c2` sample's 8,750 real files walk in 0.45–1.3 s.
  "About 102k in about 10 s" holds. Warm paint, progress and tagged non-PDF images were not exercised here.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
  - 2026-10-15 W40.d7 — walk timing measured at 150k and on the real sample; holds. Status unchanged (the rest of the promise is not exercised).
- **Notes:** no test lists a tagged non-PDF image. The code reading says it would be listed.

### R-03 · Live updates from FSEvents

- **Promise:** a tag change, addition or removal made outside the app shows up in the list without a full
  re-walk.
- **Promised in:** `CLAUDE.md` §Architecture, §Decisions; `README.md` §What it does.
- **Reached by:** automatic. `ArchiveLibrary.startWatcher` (`Search/ArchiveLibrary.swift:832`) starts a
  `CorpusWatcher` (`Search/CorpusWatcher.swift`), which re-reads only the changed paths or subtree.
- **Real-path test:** `ArchiveReaderTests/CorpusWatcherTests.testAPFSStreamSeesAThirdPartyFinderTagWriteAndFlushesDeterministically`
  (real FSEvents stream); `.testAThirdPartyPathReadUpdatesTheRowWithoutAFullWalk`; `.testMustScanSubDirsReplacesOnlyThatSubtree`.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.

### R-04 · Cloud placeholders are never downloaded

- **Promise:** a dataless cloud placeholder may be listed, but the Reader never materialises it to extract its
  content.
- **Promised in:** `CLAUDE.md` §Verified Facts (Search/discovery).
- **Reached by:** automatic. The walker's `SF_DATALESS` flag (`CorpusWalker.swift:798`) becomes
  `ArchiveFile.isDataless` (`Search/ArchiveLibrary.swift:1347`). Indexing skips dataless files
  (`Search/ContentIndexer.swift:169-179`) and wraps its reads in `withDatalessMaterializationDisabled`
  (`:265`, `Search/LibraryScan.swift:28`, `:49`). The link writer skips their thumbnail (`Core/ArchiveLinkWriter.swift:58`).
- **Real-path test:** `ArchiveReaderTests/ContentIndexerDatalessTests.testDatalessFileIsNeverOpenedAndItsDisposableContentRowIsRemoved`;
  `.testRacePathPDFOpenRunsInsideNoMaterialisationPolicy`.
- **Runtime evidence:** none. `unverifiable-here` may be the right status for the real-cloud half: the corpus
  is local disk, and a real placeholder needs a cloud-synced folder.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** the viewer, preview and thumbnail paths were not seen to guard dataless files (`S-002`).

### R-05 · Chronological default sort

- **Promise:** the list sorts by date by default, using the Year/Month/Day tags. Years of three or four digits
  sort correctly (medieval-safe). A decade such as `1970s` sorts at its start and shows in italics. A `Date
  Uncertain` file sorts by its year and shows in italics. Undated files come last.
- **Promised in:** `CLAUDE.md` §Verified Facts (Tag facets, Chronological sort key), §Decisions; `README.md`
  §What it does; `SMOKE_TEST.md` step B; `SPEC/tag-format.md`; `SUITE_TODO_DONE.md` `W5.a4`.
- **Reached by:** default. `LibrarySort.default` (`Core/LibraryFilter.swift`) is applied in
  `NavigationModel.recompute` (`Views/NavigationModel.swift:518`). The key is `DocumentTags.sortDateKey`
  (`packages/ArchiveCore/Sources/ArchiveCore/Tags/DocumentTags.swift:145`). Italics come from
  `dateCellIsSpeculative` (`Views/AppKitTableView.swift:317-320`), which uses `DocumentTags.dateIsSpeculative` (`:153`).
- **Real-path test:** `ArchiveReaderTests/LibrarySortFilterTests.testDefaultSortIsChronologicalThenNameWithUndatedLast`;
  `ArchiveCoreTests/DocumentTagsTests.testMedievalDecade`, `.testDecadeSortDate`, `.testDayTagAndSpeculativeDate`.
  Nothing checks the italic font on a drawn cell.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.

### R-06 · Sort menu and header sort

- **Promise:** Sort by Date, Name, Quality or Read-state from the menu (menu items, no shortcut), or click a
  column header. Sorting is multi-level.
- **Promised in:** `CLAUDE.md` §Keyboard map (menu-only list); `README.md` §What it does (multi-level sort);
  `SMOKE_TEST.md` step H.
- **Reached by:** Sort & Filter menu, `ArchiveReaderCommands.swift:119-122`, sets `nav.sort` via `sortBy`
  (`:178`). A header click goes through `applyHeaderSort` (`Views/AppKitTableView.swift:503`). A secondary sort
  comes from the header's right-click menu (`:679-703`).
- **Real-path test:** `ArchiveReaderUITests/NavigationUITests.testHeaderClickChangesSort` is weak: it asserts
  only that rows remain. `ArchiveReaderTests/LibrarySortFilterTests.testQualitySortNilLast` and
  `.testMonthAndDayRefineChronology` test the sort, not the menu.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** **Drift.** A menu item always sets `[field ascending, name ascending]` (`ArchiveReaderCommands.swift:178-180`).
  Multi-level sorting exists only through the header right-click menu. The header can also sort by Type and
  Tags, which the menu lacks.

### R-07 · Read-state filter

- **Promise:** a three-way read-state filter: All, Unread, Read, plus a No-read-state bucket so marker files
  are never silently lost. Its starting value comes from Options ▸ Navigation defaults.
- **Promised in:** `CLAUDE.md` §Edge-case rules, §Decisions, §Options; `README.md` §What it does;
  `SMOKE_TEST.md` step C.
- **Reached by:** the filter-bar segmented picker (`Views/NavigationWindowView.swift:346`) binds
  `model.filter.read`, which `LibraryFilter.matches` (`Core/LibraryFilter.swift`) applies. The default is
  `AppSettings.defaultReadFilter`, read at `Views/NavigationModel.swift:150` and `:359`, and set in
  `Views/OptionsView.swift:42-48`.
- **Real-path test:** `ArchiveReaderTests/LibrarySortFilterTests.testReadFilterTriState`. No test covers the
  picker or the Options default.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** **Drift.** The filter bar offers All, Unread and Read only (`NavigationWindowView.swift:347-349`).
  No-read-state can be reached only as the Options default, through a smart folder, or from saved view state.

### R-08 · Subject tag filter

- **Promise:** a token field filters by subject tags, with the selected tags shown inside the box. Tags
  combine with AND by default. ANY is available through the Options toggle and the tag cloud's All/Any, and
  NOT is available too. ⌘L focuses the field.
- **Promised in:** `CLAUDE.md` §Decisions ("Subject filters AND by default (OR/NOT via toggle)"),
  §Keyboard map, §Options; `README.md` §What it does; `SUITE_TODO_DONE.md` "Reader tag-filter → token field"
  (`b5a5a01`); `SMOKE_TEST.md` step E.
- **Reached by:** `SubjectFilterTokenField` (`Views/SubjectFilterTokenField.swift`, placed at
  `Views/NavigationWindowView.swift:470`). ⌘L, `ArchiveReaderCommands.swift:128`, calls
  `NavigationModel.requestFocusTagFilter` (`:72`). The All/Any picker shows only with two or more tags
  (`NavigationWindowView.swift:478-486`). The Options toggle is at `Views/OptionsView.swift:49`.
- **Real-path test:** `ArchiveReaderTests/LibrarySortFilterTests.testSubjectCombineAndVsOr`,
  `.testCombinedFilterMatchesWorkflowExample` (model only). No UITest drives the token field or ⌘L.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** **Drift.** There is no NOT. `LibraryFilter` has only `subjects` with `.all`/`.any`
  (`Core/LibraryFilter.swift:14-24`).

### R-09 · Quality filter

- **Promise:** filter by Quality Q1, Q2 or Q3. This replaced the old Priority filter (`W19.q3`).
- **Promised in:** `README.md` §What it does; `CLAUDE.md` §Verified Facts (Quality); `SUITE_TODO_DONE.md` `W19.q3`;
  `SMOKE_TEST.md` §2026-08-28.
- **Reached by:** the Q3, Q2 and Q1 toggle buttons, `Views/NavigationWindowView.swift:358-368`, which set
  `model.filter.qualities`.
- **Real-path test:** `ArchiveReaderUITests/NavigationUITests.testQualityControlsUseCanonicalScale` (the
  controls exist, Priority is gone); `ArchiveReaderTests/LibrarySortFilterTests.testQualityFilterExcludesUnrated`.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.

### R-10 · Filename filter and Clear

- **Promise:** a filename filter narrows the list, debounced at 150 ms so typing stays smooth. ⌘⇧K clears the
  filters and the search.
- **Promised in:** `CLAUDE.md` §Architecture (navigation table), §Keyboard map; `SMOKE_TEST.md` step F.
- **Reached by:** the `ar.filter.name` field (`Views/NavigationWindowView.swift:387`). A 150 ms debounce
  (`Views/NavigationModel.swift:165-171`) copies the text into `filter.searchText`. ⌘⇧K,
  `ArchiveReaderCommands.swift:124`, and the filter-bar Clear button (`NavigationWindowView.swift:427`) both
  call `clearUserFilters` (`NavigationModel.swift:357`).
- **Real-path test:** `ArchiveReaderUITests/NavigationUITests.testNameFilterReducesRows`;
  `ArchiveReaderTests/LibrarySortFilterTests.testFilenameSearch`. ⌘⇧K has no test.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** Clear returns the filters to the Options defaults, not necessarily to All. It keeps a folder or
  smart-folder scope, as R-16 promises.

### R-11 · Full-text OCR search

- **Promise:** search the OCR text of the whole archive (⌘⌥F focuses the field; the query runs on Return).
  The search uses the app's own FTS5 index, not Spotlight. Results are ranked by bm25, with name above
  classification above body. While a query is active the list sorts by relevance. When an index pass
  finishes, the query re-runs so new files appear.
- **Promised in:** `CLAUDE.md` §Architecture (content index), §Keyboard map, §Decisions; `README.md` §What it
  does; `SMOKE_TEST.md` step G ("Submit-on-Return").
- **Reached by:** ⌘⌥F, `ArchiveReaderCommands.swift:130`, focuses the `ar.filter.ocr` field
  (`Views/NavigationWindowView.swift:395`). A 150 ms debounce (`Views/NavigationModel.swift:175`) calls
  `runFullTextSearch` (`:656`), which sets the relevance sort (`:661`). The ranking is
  `ORDER BY bm25(fts,1.0,5.0,10.0)` in `Search/ContentIndex.swift:184`. The re-run after a pass is
  `refreshFullTextSearchIfActive` (`NavigationModel.swift:697`, wired at `:184`).
- **Real-path test:** `ArchiveReaderUITests/NavigationUITests.testOCRSearchShowsKeywordInContextSnippet`,
  `.testOCRSearchFieldExists`; `ArchiveReaderTests/ContentIndexTests.testBm25RankedSearch`.
- **Runtime evidence:** [`evidence/reader/W40.d7-at-size.md`](evidence/reader/W40.d7-at-size.md). On the `W40.c2` sample's real OCR text, and on that text replicated to 102,478
  rows: single distinctive terms answer in 11–146 ms at 102k, `the` in 0.7 s, but `Bureau of the Budget` takes
  2.2 s on the sample and **41.7 s** at 102k (`-O`). Index build: 5,268 PDFs in 9.2 s, one pass.
- **Status:** `broken` — `W40.fix-reader-fts-snippet-stall` (S2)
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
  - 2026-10-15 W40.d7 — `unproven` → `broken`: a multi-word query with common words takes 42 s at corpus size; filed `W40.fix-reader-fts-snippet-stall` (S2).
- **Notes:** **Drift.** The search runs as you type, after 150 ms. There is no `.onSubmit` on the field, so
  `SMOKE_TEST.md` step G's "Submit-on-Return" is out of date. The behaviour is arguably better, but the record
  is wrong.

### R-12 · A failed content index is reported

- **Promise:** when the content index cannot open or did not finish, the app says so with an amber status-bar
  line. It never presents the failure as "no matches" (`W23.m9`).
- **Promised in:** `CLAUDE.md` Implementation map (`ContentIndex`, `ContentIndexer`, Index health);
  `SUITE_TODO_DONE.md` `W23.m9`, `W23.m9-fu3`.
- **Reached by:** `ContentIndexer.failure` (`Search/ContentIndexer.swift:10-60`) is mirrored into
  `NavigationModel.indexFailure` (`Views/NavigationModel.swift:182`) and drawn as the orange `ar.status.indexFailure`
  label (`Views/NavigationWindowView.swift:629-635`).
- **Real-path test:** `ArchiveReaderUITests/ContentIndexFailureUITests.testCorruptIndexWarningRetractsAfterScratchRepairAndReindex`
  (needs the corrupt-index fixture); `ArchiveReaderTests/ContentIndexerFailureTests.testQueryOnUnopenableIndexReportsUnavailable`,
  `.testPassOnUnopenableIndexReportsUnavailable`.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** the list area itself still shows the generic "No matches" overlay
  (`NavigationWindowView.swift:255`) beside the status line (`S-003`).

### R-13 · The navigation table and its columns

- **Promise:** an AppKit table with columns Document date, File name, File type, File tags, Quality and
  Read/Unread. It stays smooth at 40k rows or more. An optional Provenance column (Box, Folder, Document
  Start, Continuation) is hidden by default. It is shown from the right-click column-header picker, and the
  choice persists.
- **Promised in:** `CLAUDE.md` §Architecture (Navigation table); `README.md` §What it does;
  `SUITE_TODO_DONE.md` `W2c`, `W18.reader-breadcrumb`; `SMOKE_TEST.md` Batch 2 (Column customization).
- **Reached by:** `Views/AppKitTableView.swift`. Columns are defined at `:24-32` and hidden ones applied at
  `:105`. The header picker is `ColumnPickerHeaderView` (`:639-710`). `toggleColumn` (`:712`) persists through
  `AppSettings.setHiddenColumns`.
- **Real-path test:** `ArchiveReaderTests/ProvenanceColumnTests.testProvenanceColumnIsPresentAndHiddenOnlyByDefault`,
  `.testNavigationModelPublishesIndexedClassificationForTheTable`; `ArchiveReaderUITests/NavigationUITests.testColumnHeadersExist`.
  No test uses the header picker.
- **Runtime evidence:** [`evidence/reader/W40.d7-at-size.md`](evidence/reader/W40.d7-at-size.md), 115,999 rows, `-O`, main thread: one tag edit → list 1,561 ms; `recompute()`
  1,021 ms; a sort change 0.96–5.5 s; the table's per-change refresh 107 ms. Scrolling's cell work is 2.7 ms a row
  (no frame rate measured; the unit host draws nothing).
- **Status:** `broken` — `W40.fix-reader-list-recompute-at-size` (S2)
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
  - 2026-10-15 W40.d7 — `unproven` → `broken`: every tag edit stalls the main thread ~1.6 s and a sort change 1–5.5 s at 116k rows; filed `W40.fix-reader-list-recompute-at-size` (S2).
- **Notes:** the headers read "Type" and "Read". There are also flag (⚑) and warning (⚠︎) columns that no
  guide lists.

### R-14 · Duplicate file names show their folder

- **Promise:** rows that share a file name show their containing folder as a subtitle, so they can be told
  apart.
- **Promised in:** `CLAUDE.md` §Edge-case rules, Implementation map (`DuplicateNames`); `README.md` §What it
  does (status line).
- **Reached by:** `NavigationModel.recompute` computes `duplicatedNames` (`Views/NavigationModel.swift:545`).
  The name cell appends the folder (`Views/AppKitTableView.swift:335-337`).
- **Real-path test:** `ArchiveReaderTests/DuplicateNamesTests.testDuplicatesDetectedAcrossDifferentFolders`,
  `.testDisambiguatorReturnsParentFolder` (detection only; nothing checks the drawn cell).
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** it is an inline `⌕ folder` suffix on the name line, not a separate subtitle. It is computed over
  the *filtered* rows, so a duplicate hidden by a filter takes its marker with it.

### R-15 · Sidebar folder tree

- **Promise:** the sidebar shows the archive's folder tree with recursive file counts. Selecting a folder
  scopes the list to it. All Files ends the scope.
- **Promised in:** `CLAUDE.md` Implementation map (`SidebarView`), §Decisions (smart folders); `SMOKE_TEST.md`
  Batch 2 (Sidebar folder tree, Count badges).
- **Reached by:** `Views/SidebarView.swift`. A click calls `applySelection`, which calls
  `NavigationModel.setFolderScope` (`Views/NavigationModel.swift:806`). All Files passes nil, which also clears
  a smart-folder scope (`:808`). Counts come from `buildFolderTree`.
- **Real-path test:** `ArchiveReaderTests/SymlinkedRootTests.testTheFolderTreePlacesFilesDiscoveredUnderALinkedRoot`
  (tree and counts only); `ArchiveReaderUITests/NavigationUITests.testSidebarToggles` (visibility only). No test
  selects a folder.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.

### R-16 · Smart folders

- **Promise:** File ▸ Save Current Search… saves the active filters and OCR query as a smart folder in the
  sidebar, with the name pre-filled from the filters. Selecting it enters a base scope. The user's filters
  layer on top, and Clear goes back to the base set. Smart folders can be renamed and deleted from their
  context menu, show counts, and the scope survives a relaunch.
- **Promised in:** `CLAUDE.md` §Decisions (Smart folders), §Keyboard map (menu-only); `SMOKE_TEST.md` step S
  and Batch 2.
- **Reached by:** File ▸ Save Current Search… (`ArchiveReaderCommands.swift:60`), the sidebar "+", the
  filter-bar button (`Views/NavigationWindowView.swift:424`) or the toolbar Saved menu (`:522`). All open the
  save dialog. `NavigationModel.saveCurrentSearch` (`Views/NavigationModel.swift:272`) saves; `applyScope`
  (`:342`) enters the scope. Rename and delete are in the sidebar context menu. Persistence is
  `persistViewState` and `restoreViewState` (`:603-627`).
- **Real-path test:** `ArchiveReaderUITests/TriageJourneyUITests.testTriageWritesKeepEveryOtherTagColourAndByte` (step 7, 8); `ArchiveReaderTests/SavedSearchTests.testSaveApplyRoundTripReloads`, `.testRenamePersists`
  (store only); `ArchiveReaderTests/LibrarySortFilterTests.testEffectiveSubjectsUnion`. No test goes through
  `applyScope` or a restored scope. View-state persistence is off in UI-test mode, so no UITest can cover the
  relaunch half.
- **Runtime evidence:** 2026-10-15 · `f5c31a95` · [`evidence/reader/W40.d8-triage.md`](evidence/reader/W40.d8-triage.md) (synthetic fixture and the real-corpus sample): Save Current Search… from a tag filter, the scope lists the two tagged files, Clear restores the full list, the smart folder survives a relaunch, and its context-menu Delete removes it. No file was written by any of it.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
  - 2026-10-15 W40.d8 — runtime evidence added; stays `unproven`: rename, the count badge, the pre-filled name and a restored scope after relaunch were not shown (view-state restore is off in UI-test mode).
- **Notes:** a smart folder that includes an OCR query shows no count badge.

### R-17 · View state survives a relaunch

- **Promise:** the filter and sort persist across launches, guarded so that a state saved under another root
  is not applied.
- **Promised in:** `SMOKE_TEST.md` Batch 2 (View-state persistence); `CLAUDE.md` Implementation map
  (`NavigationModel`: view-state persistence).
- **Reached by:** automatic. `recompute` calls `persistViewState` (`Views/NavigationModel.swift:547`, `:603`).
  Launch calls `restoreViewState` (`:152`, `:613`).
- **Real-path test:** `ArchiveReaderTests/NavigationModelDefaultsIsolationTests.testAnUnpinnedModelPersistsItsViewStateOnlyInTheInjectedDomain`
  (the write half); `ArchiveReaderTests/NavigationModelTests.testSanitizedPathPrefixDropsOutOfRootPrefix` (the
  pure guard). No test restores a saved state into a fresh model.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** the root guard covers the folder prefix only (`S-004`).

### R-18 · Tag cloud

- **Promise:** a tag-cloud panel lists the subjects. Its context menu can add or remove a filter, filter to
  that tag only, switch All/Any, and select the files carrying the tag.
- **Promised in:** `SMOKE_TEST.md` Batch 2 (C6); `CLAUDE.md` Implementation map (`NavigationWindowView`).
- **Reached by:** the toolbar `ar.toolbar.tagCloud` button (`Views/NavigationWindowView.swift:527`) or Show Tag
  Cloud (⌥⌘T, `ArchiveReaderCommands.swift:38`). The panel is `tagCloudPanel` (`NavigationWindowView.swift:273-330`).
  Its context menu (`:304-320`) edits `model.filter` or calls `NavigationModel.selectFiles(withTag:)`
  (`Views/NavigationModel.swift:437`).
- **Real-path test:** `ArchiveReaderUITests/NavigationUITests.testTagCloudShowsSubjectsNotDateTokens`,
  `.testTagCloudPanelToggles`. No test opens the context menu.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** All/Any appears only with more than one tag selected. The menu also carries Rename tag… and Find
  similar tags… (R-28, R-29).

## Triage and tag editing

### R-19 · Mark Read and Mark Unread

- **Promise:** ⌘R and ⌘U mark the selection Read or Unread through `TagWriter`. A file leaves an Unread view
  only after its write has verified. A marker file with no read-state tag gets none by default (an option,
  off). A batch reports its partial failures ("12 of 15 updated; 3 could not — Retry").
- **Promised in:** `CLAUDE.md` Safety Protocol §10–§11, §Keyboard map, §Decisions; `README.md` §What it does;
  `SMOKE_TEST.md` steps N and P.
- **Reached by:** ⌘R and ⌘U (`ArchiveReaderCommands.swift:95-98`), the toolbar buttons, the row context menu
  (`Views/NavigationWindowView.swift:171-172`) and the editor sheet. All call `NavigationModel.mark(_:)`
  (`Views/NavigationModel.swift:1064`), which calls `TagWriter.setReadState` (`Core/TagWriter.swift:132`).
  Only verified results reach `library.applyVerifiedWrites` (`NavigationModel.swift:1084`).
- **Real-path test:** `ArchiveReaderUITests/TriageJourneyUITests.testTriageWritesKeepEveryOtherTagColourAndByte` (step 1); `ArchiveReaderUITests/NavigationUITests.testMatchedIdentityWritesSucceedOnScratchFixture`
  (clicks Mark Read, reads the tags back from disk); `ArchiveReaderTests/TagWriterTests.testMarkReadIsNoOpOnFileWithoutReadState`;
  `ArchiveReaderTests/TriageTests.testMarkReadRemovesOnlyUnreadAndPreservesOtherTags`.
- **Runtime evidence:** 2026-10-15 · `f5c31a95` · [`evidence/reader/W40.d8-triage.md`](evidence/reader/W40.d8-triage.md): Mark Read on an Unread file removed only `Unread` and added `Read`; every other tag, colour and content byte held. It also stamped the file with `com.apple.quarantine` (R-45).
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
  - 2026-10-15 W40.d8 — runtime evidence added; stays `unproven`: the Unread-view exit after verify and the partial-failure message were not shown.
- **Notes:** **Drift.**
  - "Option, off" is not an option. The default is hard-coded (`TagWriter.swift:132`), and `OptionsView` has no
    toggle for it.
  - The partial-failure message is "Marked N; M could not update." (`NavigationModel.swift:1089-1090`). There
    is no Retry anywhere in the app.

### R-20 · Keyboard triage

- **Promise:** ⌘] and ⌘[ jump to the next and previous unread file. ⌘⇧M marks the selection Read and moves to
  the next unread. With the list focused, the bare keys `]`, `[` and `\` do the same, and they never fire
  inside a text field.
- **Promised in:** `CLAUDE.md` §Keyboard map (G4).
- **Reached by:** ⌘] and ⌘[ (`ArchiveReaderCommands.swift:87-90`) and ⌘⇧M (`:101-102`). The bare keys are
  `.onKeyPress` handlers on the table (`Views/NavigationWindowView.swift:149-156`). They call `selectNextUnread`
  (`Views/NavigationModel.swift:1132`), `selectPreviousUnread` (`:1134`) and `markReadAndAdvance` (`:1160`).
- **Real-path test:** `ArchiveReaderUITests/TriageJourneyUITests.testTriageWritesKeepEveryOtherTagColourAndByte` (step 1), ⌘⇧M only. For the pure helper, `ArchiveReaderTests/TriageTests.testNextUnreadSkipsReadRows`,
  `.testNextUnreadWrapsAround` and `.testPreviousUnreadSkipsReadRowsAndWraps` test the pure `TriageNavigation`.
  Nothing calls `markReadAndAdvance` or presses a key.
- **Runtime evidence:** 2026-10-15 · `f5c31a95` · [`evidence/reader/W40.d8-triage.md`](evidence/reader/W40.d8-triage.md): ⌘⇧M marked the file Read and selected the next Unread file in the list.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
  - 2026-10-15 W40.d8 — runtime evidence for ⌘⇧M; stays `unproven`: ⌘]/⌘[ and the bare keys were not pressed. Whether the bare keys fire inside the inline editor is `S-015` (the Space key there does: `W40.fix-reader-inline-keys`).

### R-21 · Undo a tag change

- **Promise:** ⌘Z (Tags ▸ Undo Tag Change) undoes the last tag change by applying its inverse delta to a
  fresh read of the file. A bulk action undoes as one step. There is no redo.
- **Promised in:** `CLAUDE.md` Safety Protocol §9, §Keyboard map; `SMOKE_TEST.md` step O; `SUITE_TODO_DONE.md`
  `W15.tu2`.
- **Reached by:** ⌘Z (`ArchiveReaderCommands.swift:112-114`, enabled only while `undoDepth > 0`) or the toolbar
  Undo button. Both call `NavigationModel.undoLast()` (`Views/NavigationModel.swift:1096`), which pops one batch
  and applies `TagWriter.applyOccurrence` to each entry (`:1108`).
- **Real-path test:** `ArchiveReaderUITests/TriageJourneyUITests.testTriageWritesKeepEveryOtherTagColourAndByte` (steps 5a, 5b), through `undoLast`. At the writer level, `ArchiveReaderTests/TagWriterTests.testOccurrenceUndoPreservesConcurrentUnrelatedTag`
  and `.testOccurrenceInverseRestoresDuplicateTag` test the writer's inverse.
- **Runtime evidence:** 2026-10-15 · `f5c31a95` · [`evidence/reader/W40.d8-triage.md`](evidence/reader/W40.d8-triage.md): one ⌘Z undid a three-file rename as one step, a second ⌘Z undid the three-file group edit, and the tags after the first undo equalled those before the rename. Every other file stayed byte-identical.
- **Status:** `works`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
  - 2026-10-15 W40.d8 — `works` (both runs).
- **Notes:**
  - The undo stack is memory-only (R-46).
  - `undoLast` drops a file whose undo fails (`try?`, `:1108`), and its count reports only the files it undid.
    Demonstrated 2026-10-16 by `W40.f1` ([`evidence/reader/W40.f1-undo.md`](evidence/reader/W40.f1-undo.md)):
    `W40.fix-reader-undo-partial` (S3).
  - `W40.f1` also found that undo re-tagged a file swapped under its path: the §6 identity check compared a
    `URL`'s cached `fileResourceIdentifier` with itself. Fixed 2026-10-17 by `W40.fix-identity-url-cache`
    (S1): `UndoDurabilityTests.testUndoRefusesAFileSwappedUnderItsPath` now passes without its expected
    failure. The row stays `works` for what it promises (the inverse delta, one step per batch); the §6
    refusal is R-45's safety promise, and the fix is recorded there too.
  - `S-001`: ⌘Z may fire Undo Tag Change while a text field has focus.

### R-22 · Tag editor sheet

- **Promise:** ⌘I opens a tag editor for one file or a group. It edits subjects, Year/Month/Day, Quality and
  color. A group shows tri-state presence (on all, some or none of the files). Each change is one
  `TagWriter` delta.
- **Promised in:** `CLAUDE.md` Core Directive, Safety Protocol §10, §Keyboard map, §Decisions; `README.md`
  §What it does; `SMOKE_TEST.md` step Q.
- **Reached by:** ⌘I (`ArchiveReaderCommands.swift:103-104`), the toolbar `ar.toolbar.editTags` button or the
  context menu set `showingEditor`, which presents `TagEditorView` (`Views/NavigationWindowView.swift:56`). The
  sheet calls `NavigationModel.applyEdit(_:)` (`Views/NavigationModel.swift:1186`).
- **Real-path test:** `ArchiveReaderUITests/TriageJourneyUITests.testTriageWritesKeepEveryOtherTagColourAndByte` (step 3, 6a); `ArchiveReaderUITests/NavigationUITests.testMatchedIdentityWritesSucceedOnScratchFixture`
  (adds a subject in the sheet, reads it back from disk); `ArchiveReaderTests/TagEditingIntegrationTests.testApplySetYearOnDisk`,
  `.testApplySetQualityWritesCanonicalTokenAndPreservesBytes` (writer level). Nothing tests Month, Day, color
  or group tri-state.
- **Runtime evidence:** 2026-10-15 · `f5c31a95` · [`evidence/reader/W40.d8-triage.md`](evidence/reader/W40.d8-triage.md): ⌘I on three selected files added a subject to all three and nothing else; ⌘I on one file did the same.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
  - 2026-10-15 W40.d8 — runtime evidence for subjects (single and group); stays `unproven`: Year/Month/Day, Quality, colour and tri-state were not shown.
- **Notes:** each control writes as soon as it changes (`Views/TagEditorView.swift:4-5`), so one sheet session
  makes several writes and several undo steps. Tri-state is real for subjects. For Quality, Color and Read it
  is only a "(mixed)" label. The sheet also holds Read state, Note and Flag.

### R-23 · Inline subject editor in each row

- **Promise:** each row's Tags cell is an editable token field. It autocompletes from the subjects in the
  archive and commits on Return and on leaving the field, so a word typed but not Returned still sticks. One
  commit is one delta, and existing tags are never lost.
- **Promised in:** `CLAUDE.md` Implementation map (`SubjectTokenField.swift`); `SUITE_TODO_DONE.md` "GUI-verified
  2026-07-08" (inline tag-editor commit).
- **Reached by:** a click in the Tags column opens the AppKit `TagTokenCellView` (`Views/AppKitTableView.swift:262`,
  `:521-541`). Autocomplete is `tokenField(_:completionsForSubstring…)` (`:544`). `controlTextDidEndEditing`
  (`:566-581`) calls `NavigationModel.commitSubjectEdit` (`Views/NavigationModel.swift:1290`).
- **Real-path test:** `ArchiveReaderUITests/TriageJourneyUITests.testTriageWritesKeepEveryOtherTagColourAndByte` (steps 2a, 2), through the cell. At the writer level, `ArchiveReaderTests/SubjectTokenEditIntegrationTests.testInlineEditPreservesFacetTokensAndBytes`
  and `.testInlineEditInverseRoundTrips` test `TagEditing.subjectDelta` and `TagWriter` directly.
- **Runtime evidence:** 2026-10-15 · `f5c31a95` · [`evidence/reader/W40.d8-triage.md`](evidence/reader/W40.d8-triage.md): a Space typed in the focused token field opened the Preview sheet instead (an earlier run's two-word tag was written as its first word), and Return did not commit; the tag was written only on leaving the field. Leaving the field kept every other tag and colour.
- **Status:** `broken`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
  - 2026-10-15 W40.d8 — `broken`: `W40.fix-reader-inline-keys` (S2).
- **Notes:** **Drift.** The live editor is the AppKit cell. `Views/SubjectTokenField.swift`, which the guide
  names, is referenced only by the dead `TagsCell` (R-25), so it is dead too. Autocomplete returns at most 20
  and leaves out an exact match. There is no case-duplicate warning here (R-27). 2026-10-16 `W40.e5` deleted
  `SubjectTokenField.swift` and `TagsCell` as dead code; the guide's Implementation map now names
  `TagTokenCellView`.

### R-24 · Quality pop-up in the list

- **Promise:** the Quality column's pop-up sets a file's Quality, through `TagWriter`.
- **Promised in:** `CLAUDE.md` Implementation map (`AppKitTableView`); `SUITE_TODO_DONE.md` `W19.q3`;
  `SMOKE_TEST.md` §2026-08-28.
- **Reached by:** the `NSPopUpButton` in the Quality column (`Views/AppKitTableView.swift:399-446`).
  `qualityMenuChanged` (`:443`) calls `model.applyEdit(.setQuality(q), to: file)` (`:446`), which runs
  `NavigationModel.applyEdit(_:to:)` (`Views/NavigationModel.swift:1278`).
- **Real-path test:** `ArchiveReaderUITests/NavigationUITests.testQualityControlsUseCanonicalScale` (picks Q3,
  reads `Q3` back from the scratch file).
- **Runtime evidence:** none. The `SMOKE_TEST.md` 2026-08-28 VM run was a test run, not a kept artifact.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.

### R-25 · Single-click Read toggle in the list

- **Promise:** clicking a row's Read cell flips it between Unread and Read. A right-click on the cell sets or
  clears the read state explicitly.
- **Promised in:** `SMOKE_TEST.md` Batch 2 (C8, recorded PASS on 2026-07-05); `CLAUDE.md` Implementation map
  (`InlineEditCells.swift`: `ReadStateCell`).
- **Reached by:** **none found.** The only implementation is `ReadStateCell` (`Views/InlineEditCells.swift:9-28`),
  which calls `toggleReadState`, `setReadStateInline` and `clearReadState` (`Views/NavigationModel.swift:1295-1308`).
  No code outside `InlineEditCells.swift` names `ReadStateCell`, and those three methods have no other caller.
  Searched: every `.swift` file in the repo for `ReadStateCell`, `DateCell`, `TagsCell`, `WarningBadgeCell` and
  `InlineEditCells`. The AppKit table's Read column is a plain label with no click or right-click action
  (`Views/AppKitTableView.swift:339-343`). Its comment at `:394-396` says the SwiftUI cells left with the
  move to AppKit.
- **Real-path test:** none.
- **Runtime evidence:** none. The 2026-07-05 PASS was on the SwiftUI `Table`, which `W2c` (`435b8c4`) replaced.
- **Status:** `unreachable`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unreachable`.
- **Notes:** a Daemon Report decision (2026-10-12): wire it into the AppKit table or drop it. ⌘R and ⌘U do the
  same state change for the selection, but they are not the promised gesture. "Clear read state" has no live
  entry point at all. 2026-10-16 `W40.e5` (Periphery) also found `ReadStateCell`, `toggleReadState` and
  `clearReadState` unused and kept them for `W40.fix-reader-read-toggle`; it deleted the other dead SwiftUI cells
  (`TagsCell`, `WarningBadgeCell`). `DateCell` was not flagged and stays for `W40.fix-reader-sent-with-date`.

### R-26 · Inline date editing in the list

- **Promise:** the list's date cell can be edited in place through a date pop-up.
- **Promised in:** `CLAUDE.md` Implementation map (`InlineEditCells.swift`: `DateCell`); `SUITE_TODO_DONE.md`
  `W6.2` (InlineEditCells year bounds); the W40 survey in `execution-plans/verification-phase/01-daemon-plan.md`.
- **Reached by:** **none found.** `DateCell` (`Views/InlineEditCells.swift:31-120`) has no reference outside its
  file (same search as R-25). The Date column is a plain label with a tooltip (`Views/AppKitTableView.swift:313-318`).
  Dates can be edited only in the ⌘I sheet (R-22). The dead `DateCell` also edits Sent-With, which the sheet
  lacks.
- **Real-path test:** none. `ArchiveReaderTests/DualDateLibraryTests.testDateCellLabelsEachRole` tests
  `ArchiveFile.dateCellText`, not the view.
- **Runtime evidence:** none.
- **Status:** `unreachable`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unreachable`.
- **Notes:** a Daemon Report decision (2026-10-12): wire it or drop it. Sent-With dates have no live editor in
  the Reader.

### R-27 · Warning on a subject that differs only by case

- **Promise:** when you add a subject that differs only by case from an existing one, the tag editor warns
  you. This is an Options toggle, on by default.
- **Promised in:** `CLAUDE.md` §Options, §Decisions (near-duplicate warning).
- **Reached by:** the ⌘I sheet's Add-subject field (`Views/TagEditorView.swift:66-70`) and `RenameTagSheet`
  both call `NavigationModel.nearDuplicateSubjects(of:)` (`Views/NavigationModel.swift:1357`), which checks
  `AppSettings.warnNearDuplicateTags` (default true, `Core/AppSettings.swift:92`; toggle at `Views/OptionsView.swift:71`).
- **Real-path test:** `ArchiveReaderUITests/TriageJourneyUITests.testTriageWritesKeepEveryOtherTagColourAndByte` (step 6a), the warning at its default; no test turns the option off.
- **Runtime evidence:** 2026-10-15 · `f5c31a95` · [`evidence/reader/W40.d8-triage.md`](evidence/reader/W40.d8-triage.md): typing a case variant of an existing subject into the ⌘I sheet showed the warning, with the option at its default.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
  - 2026-10-15 W40.d8 — runtime evidence added; stays `unproven`: the Options toggle was not turned off.
- **Notes:** the inline token editor (R-23) adds subjects with no warning.

### R-28 · Rename a tag across the archive

- **Promise:** Tags ▸ Rename Tag… (menu only) opens a sheet showing how many files the rename affects. It
  applies through a `TagWriter` batch and undoes as one step.
- **Promised in:** `CLAUDE.md` Implementation map (`RenameTagSheet`), §Keyboard map (menu-only);
  `SMOKE_TEST.md` Batch 2 (D1).
- **Reached by:** Tags ▸ Rename Tag… (`ArchiveReaderCommands.swift:105-106`) calls `NavigationModel.beginRenameTag()`
  (`Views/NavigationModel.swift:1229`). The sheet (`Views/NavigationWindowView.swift:57-59`) commits through
  `renameTag` (`:1234`), which loops `TagWriter.renameToken` and pushes one undo batch (`:1264`).
- **Real-path test:** `ArchiveReaderUITests/TriageJourneyUITests.testTriageWritesKeepEveryOtherTagColourAndByte` (step 4); `ArchiveReaderUITests/NavigationUITests.testMatchedIdentityWritesSucceedOnScratchFixture`
  (drives the menu item and the sheet, reads the tag back from disk); `ArchiveReaderTests/TagWriterTests.testConditionalRenameChangesOnlyAStillPresentOldToken`.
- **Runtime evidence:** 2026-10-15 · `f5c31a95` · [`evidence/reader/W40.d8-triage.md`](evidence/reader/W40.d8-triage.md): Tags ▸ Rename Tag… with the tag selected showed "Rename 3 Files", renamed it on exactly those three files (other tags and colours intact), and undid as one step (R-21).
- **Status:** `works`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
  - 2026-10-15 W40.d8 — `works` (both runs).
- **Notes:** it is also in the tag cloud's context menu, so it is not menu-only. With no tag filter, the sheet
  starts on the most-used tag.

### R-29 · Find similar tags and merge them

- **Promise:** Tags ▸ Find Similar Tags… (menu only) groups near-duplicate subjects. You pick the one to keep,
  and Merge runs the archive-wide rename (R-28). The finder only advises and never writes by itself.
- **Promised in:** `CLAUDE.md` Implementation map (`TagSimilarity`, `SimilarTagsSheet`), §Keyboard map;
  `README.md` §What it does (status line).
- **Reached by:** Tags ▸ Find Similar Tags… (`ArchiveReaderCommands.swift:107-108`) presents `SimilarTagsSheet`
  (`Views/NavigationWindowView.swift:61`), which calls `TagSimilarity.clusters`. Merge calls `startMerge`, which
  opens `RenameTagSheet` with the chosen tag.
- **Real-path test:** `ArchiveReaderUITests/TriageJourneyUITests.testTriageWritesKeepEveryOtherTagColourAndByte` (step 6b), through the sheet. For the clustering, `ArchiveReaderTests/TagSimilarityTests.testCaseVariantsCluster`,
  `.testLongTagTypoClusters` and `.testCanonicalIsMaxCountAndClustersSortedByTotalFiles` test the clustering.
- **Runtime evidence:** 2026-10-15 · `f5c31a95` · [`evidence/reader/W40.d8-triage.md`](evidence/reader/W40.d8-triage.md): two case variants on two files formed one cluster; with the kept spelling picked, Merge opened the rename sheet seeded with it and renamed only the variant's file. Opening the finder wrote nothing.
- **Status:** `works`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
  - 2026-10-15 W40.d8 — `works` (both runs).
- **Notes:** a Merge renames one variant, the most-used one that is not kept. A group of N tags needs N−1
  merges. It is also in the tag cloud's context menu.

### R-30 · Flag and note, kept in the app

- **Promise:** Toggle Flag (⌘⇧F) flags a file and a note can be attached. Both are stored by the app, never
  in the file. The list shows a flag column.
- **Promised in:** `CLAUDE.md` §Keyboard map, Implementation map (`NotesStore`); `SMOKE_TEST.md` step R.
- **Reached by:** ⌘⇧F (`ArchiveReaderCommands.swift:109-110`), the toolbar `ar.toolbar.flag` button, the
  context menu and the ⌘I sheet call `NavigationModel.toggleFlagSelection()` (`Views/NavigationModel.swift:433`),
  which calls `NotesStore.toggleFlag` (`Search/NotesStore.swift:36`). The flag column is drawn at
  `Views/AppKitTableView.swift:299-302`. A note can be edited only in the ⌘I sheet, for one file
  (`setNote`, `NavigationModel.swift:440`).
- **Real-path test:** `ArchiveReaderTests/NotesStoreTests.testSetNoteAndFlagPersist`, `.testGroupToggleFlag`
  (store only).
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** the list does not show that a file has a note.

### R-31 · Copy file links

- **Promise:** ⌘⇧C in the list copies a link to each selected file, as a `file://` URL, POSIX path, Markdown
  or HTML (Options), percent-encoded, with 0–5 blank lines between them. A group carries full paths.
- **Promised in:** `CLAUDE.md` §Keyboard map, §Options, §Edge-case rules; `README.md` §What it does;
  `SMOKE_TEST.md` step M.
- **Reached by:** ⌘⇧C, Selection ▸ Copy Link(s) (`ArchiveReaderCommands.swift:75-76`), the toolbar
  `ar.toolbar.copyLinks` button or the context menu. All call `NavigationModel.copyLinks()`
  (`Views/NavigationModel.swift:1366`), which uses `FileLinkFormatter.clipboardString` (`Core/FileLink.swift`).
- **Real-path test:** none through `copyLinks()`. `ArchiveReaderTests/FileLinkTests.testFileURLPercentEncodesEmDashAndSpaces`,
  `.testMarkdownUsesNameAndEncodedURL` and `.testGroupClipboardJoinsWithConfiguredBlankLines` test the
  formatter. Nothing tests the HTML format.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** ⌘⇧C is also Document ▸ Copy Cleaned for Prose (R-36). The focused window decides which one runs.

### R-32 · Reveal in Finder and Open in Default App

- **Promise:** ⌘⇧R reveals the selection in Finder. Open in Default App (a menu item with no shortcut) opens
  it in its default app. Neither writes anything.
- **Promised in:** `CLAUDE.md` §Keyboard map; `SMOKE_TEST.md` Batch 2 (C7).
- **Reached by:** ⌘⇧R, Selection ▸ Reveal in Finder (`ArchiveReaderCommands.swift:72-74`), or the context menu
  (`Views/NavigationWindowView.swift:165`) calls `NavigationModel.revealInFinder()` (`Views/NavigationModel.swift:1453`).
  Open in Default App is in the row context menu only (`NavigationWindowView.swift:166`) and calls
  `openInDefaultApp()` (`NavigationModel.swift:1460`).
- **Real-path test:** none.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** **Drift.** `CLAUDE.md` lists Open in Default App among the menu-bar items. It has no menu-bar item,
  only the row context menu. It opens every selected file, with no cap.

### R-33 · Select the document run

- **Promise:** Select Document Run (a menu item with no shortcut) extends the selection to the whole
  document: the `Document Start` and the `Continuation` pages after it. When the classification is missing,
  the selection simply stays as it is. The app never groups files by itself.
- **Promised in:** `CLAUDE.md` §Verified Facts (Document segments), §Architecture (Reading model), §Decisions,
  §Keyboard map.
- **Reached by:** Selection ▸ Select Document Run (`ArchiveReaderCommands.swift:82`) or the row context menu
  (`Views/NavigationWindowView.swift:183`) calls `NavigationModel.extendSelectionToDocumentRun()`
  (`Views/NavigationModel.swift:402`), which uses `DocumentRuns.runContaining` (`Core/DocumentRuns.swift:23`).
- **Real-path test:** none through the model. `ArchiveReaderTests/DocumentRunsTests.testRunContainingFromAnyPageInTheRun`,
  `.testUnknownClassificationDegradesToSingleItem` and `.testMarkerBoundaryStopsRun` test the pure helper.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** the run follows the path order of the files, not the order shown in the list. With no
  classification, the status line says "No document-run info".

## Reading

### R-34 · Preview sheet

- **Promise:** Space (with the list focused) or ⌘Y opens a quick two-up preview of the image and the OCR text.
  ↑/↓ move through the list, and the list selection follows. ←/→ step through a multi-file selection. ⌘C and
  ⌘⇧C copy, and ⌘↑, ⌘↓ and ⌘0 zoom the focused pane. ⌘O opens the full viewer, and Space or Esc closes the
  sheet. Find is disabled in the preview.
- **Promised in:** `CLAUDE.md` §Keyboard map (Preview sheet); `SMOKE_TEST.md` step L; `SUITE_TODO_DONE.md`
  `W26.previewzoom`, `W26.previewzoom-fu1`.
- **Reached by:** Space (`Views/NavigationWindowView.swift:140`), ⌘Y (`ArchiveReaderCommands.swift:69`), the
  toolbar `ar.toolbar.preview` button or the context menu set `showingPreview`, which presents
  `Views/PreviewSheet.swift` (`NavigationWindowView.swift:86`). The sheet loads through `model.load`
  (`PreviewSheet.swift:34`). Its header buttons carry the arrow, copy and Open shortcuts (`:58-83`). ↑/↓ call
  `NavigationModel.moveSelectionInList` (`Views/NavigationModel.swift:1441`). Find is off through
  `supportsFind: false` (`PreviewSheet.swift:24`).
- **Real-path test:** `ArchiveReaderUITests/ViewerUITests.testPreviewOpensAndDismisses`,
  `.testFitPageCommandReachesThePreviewSheet`, `.testFindCommandsAreDisabledInThePreviewSheetOnly`. None opens
  it with Space or tests browsing, cycling, copy or ⌘O.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** ↑/↓ replace a multi-file selection with one row. ⌘⇧C is bound three times while the sheet is
  open: the sheet's button, Copy Link(s) and Copy Cleaned. Which one wins has not been checked.

### R-35 · Document window

- **Promise:** ⏎, a double-click or ⌘O opens the selection in a document window. The image is on the left and
  the OCR text on the right, each with its own zoom (⌘↑/⌘↓, ⌘0 to fit). The focused pane has an accent border
  and ⌘⌥←/→ switches it. A draggable splitter starts at ⅔ : ⅓. The split, zoom and window size persist as
  the next default, and ⌥⌘0 resets them. ↑/↓ scroll, and ⌘⇧↑/↓ step through the pages of the opened run.
- **Promised in:** `CLAUDE.md` §Architecture (Document viewer), §Keyboard map; `README.md` §What it does;
  `SMOKE_TEST.md` steps I and J.
- **Reached by:** a double-click (`Views/AppKitTableView.swift:516`) or ⌘O (`ArchiveReaderCommands.swift:66`)
  calls `openSelection()` (`Views/NavigationWindowView.swift:652`), which opens the window and runs
  `model.load` (`Views/DocumentWindowView.swift:44`). Zoom is the Document menu (`ArchiveReaderCommands.swift:147-151`),
  pane focus `:142-144`, page stepping `:137-139`. The splitter is `DocumentWindowView.swift:128-132`. ⌥⌘0 is a
  toolbar button (`:214-217`). The split, zoom and window size are saved at `DocumentWindowView.swift:131`,
  `Views/PDFPaneView.swift:55` and `DocumentWindowView.swift:55`.
- **Real-path test:** `ArchiveReaderUITests/ViewerUITests.testDocumentViewerOpens` (⌘O opens a second window);
  `ArchiveReaderTests/DocumentViewerPagePairTests.testNextWalksPairsBeforeMovingToTheNextFileAndPreviousComesBackToTheLastPair`.
  Nothing tests the splitter, persistence, ⌥⌘0 or the focus border.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** **Drift.**
  - No ⏎ handler was found. Only a double-click and ⌘O open the viewer.
  - ⌥⌘0 resets the split to the saved default, not to ⅔.
  - A drag clamps to 0.15–0.85, but the Options slider to 0.2–0.8. Both write the same key.

### R-36 · Copying text in the viewer

- **Promise:** ⌘C copies verbatim. ⌘⇧C copies cleaned for prose: single line breaks become spaces, a blank
  line stays a paragraph break, and hyphenated line splits are rejoined. Both work in whichever pane holds the
  selection. The three cleaning rules are Options toggles.
- **Promised in:** `CLAUDE.md` §Architecture (Intelligent copy), §Keyboard map, §Options; `README.md` §What it
  does; `SMOKE_TEST.md` step K.
- **Reached by:** Document ▸ Copy, ⌘C (`ArchiveReaderCommands.swift:158`), calls
  `DocumentViewerModel.copyPlainSelection`. Document ▸ Copy Cleaned for Prose, ⌘⇧C (`:160`), calls
  `copySelection`, which reads `AppSettings.copyOptions` and runs `CopyTextCleaner.clean` (`Core/CopyTextCleaner.swift`).
- **Real-path test:** none through the viewer. `ArchiveReaderTests/CopyTextCleanerTests.testSingleNewlinesBecomeSpaces`,
  `.testBlankLineIsParagraphBreak` and `.testDeHyphenationJoinsSplitWord` test the cleaner.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** the code tries the text pane first, then the image pane. If both panes hold a selection, the text
  pane wins.

### R-37 · Find in the open documents

- **Promise:** ⌘F opens a find bar. Every match is highlighted, and ⌘G/⇧⌘G go to the next and previous match.
  The search wraps around and shows "N of M" across all the open documents.
- **Promised in:** `CLAUDE.md` §Architecture, §Keyboard map, §Decisions; `README.md` §What it does;
  `SMOKE_TEST.md` step K.
- **Reached by:** ⌘F (`ArchiveReaderCommands.swift:166`) shows the find bar (`Views/DocumentWindowView.swift:150`).
  ⌘G and ⇧⌘G (`:168`, `:170`) call `DocumentViewerModel.findNext` and `findPrevious`. Highlighting is
  `PDFPaneController.applyFind` (`Views/PDFPaneView.swift:116`). Wrapping and the count come from
  `FindNavigator` (`Core/DocumentFind.swift`).
- **Real-path test:** `ArchiveReaderTests/DocumentViewerPagePairTests.testFindWalksMatchesAcrossPairsAndDocumentsInReadingOrder`,
  `.testFindNavigatesToAMatchOnALaterPairsTextPage`; `ArchiveReaderTests/DocumentFindTests.testNextAdvancesThroughEveryMatchThenWraps`.
  Nothing tests the bar, the "N of M" text or the highlighting.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** the search runs on Return or ⌘G, not while typing, and matching ignores case.

### R-38 · Unusual files degrade instead of crashing

- **Promise:** a file that is not a 2-page PDF degrades without crashing: a 1-page PDF, a merged PDF of more
  than 2 pages, a corrupt or encrypted PDF, or a tagged non-PDF image. The viewer shows one pane or a
  "no OCR page" state. A merged PDF displays and searches every page (`W23.m2`).
- **Promised in:** `CLAUDE.md` §Verified Facts (PDF structure), §Edge-case rules, §Architecture; `SPEC/tag-format.md`;
  `SUITE_TODO_DONE.md` `W23.m2`.
- **Reached by:** opening such a file. `DocumentViewerModel.loadCurrent` handles each case.
  `Views/DocumentWindowView.swift:82-100` draws the no-text state. `DocumentPagePairs` steps through a merged PDF.
- **Real-path test:** `ArchiveReaderUITests/ViewerUITests.testNoTextLayerPDFShowsBanner`, `.testNonPDFImageDegrades`,
  `.testNonPDFImageRendersInPreviewAndViewer`; `ArchiveReaderTests/DocumentViewerPagePairTests.testInterleavedDocumentExposesEveryPagePair`,
  `.testTrailingScanWithNoOCRPageIsStillReachable`. Nothing tests a corrupt or encrypted PDF.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** no code checks whether a PDF is locked or encrypted (`S-005`).

### R-39 · Non-standard PDF detection

- **Promise:** a PDF is flagged only when it cannot be read or has no text. Its page count is never treated as
  a defect.
- **Promised in:** `CLAUDE.md` §Edge-case rules; `README.md` §What it does (status line).
- **Reached by:** computed during indexing. `Search/ContentIndexer.swift:268-277` produces a `formatFlags`
  value (`Search/ContentIndex.swift:287`) through `PDFFormatStatus.classify`
  (`packages/ArchiveCore/Sources/ArchiveCore/PDF/PDFFormatStatus.swift:20`). It shows as the ⚠︎ column
  (`Views/AppKitTableView.swift:305`), the "need attention" filter (`Views/NavigationWindowView.swift:411`) and
  a row in the health popover (R-40).
- **Real-path test:** `ArchiveCoreTests/PDFFormatStatusTests.testReadableNoTextIsNoTextLayer`,
  `.testNeedsAttentionIsEverythingButStandard`; `ArchiveReaderTests/ContentIndexTests.testFormatFlagsAndNeedsAttentionCount`
  (feeds rows into the index directly; the extraction step is not exercised).
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.

### R-40 · Library health popover

- **Promise:** the stethoscope button opens a popover with library counts: total, no date, no quality,
  box/folder markers, Date Uncertain, and files tagged both Read and Unread.
- **Promised in:** `SMOKE_TEST.md` step V (historical wording, Priority).
- **Reached by:** the status-bar `ar.status.health` button (`Views/NavigationWindowView.swift:636`) opens
  `DataQualityView` (`:703`), fed by `NavigationModel.dataQuality` (`Views/NavigationModel.swift:1334`).
- **Real-path test:** none.
- **Runtime evidence:** the cost only. [`evidence/reader/W40.d7-at-size.md`](evidence/reader/W40.d7-at-size.md): `dataQuality`, recomputed on every access, takes 30 ms over
  115,999 rows and 4 ms over the sample (`-O`). The popover was not opened.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
  - 2026-10-15 W40.d7 — popover data cost measured at 116k rows (30 ms). Status unchanged: the popover itself was not driven.
- **Notes:** no current guide describes the popover. Its only record is the SMOKE_TEST step. It also has a
  Non-standard PDFs row.

## Settings, links and safety

### R-41 · Options panel

- **Promise:** ⌘, in either window opens Options with these settings: link format; 0–5 blank lines between
  links; the three copy-cleaning toggles; the viewer's default split (0.2–0.8); the default read-state filter;
  ANY for subject filters; list text size (10–20 pt); and the case-duplicate warning.
- **Promised in:** `CLAUDE.md` §Options, §Architecture; `README.md` §What it does; `SMOKE_TEST.md` step T.
- **Reached by:** ⌘, through the `Settings { OptionsView() }` scene (`ArchiveReaderApp.swift`). The controls are
  in `Views/OptionsView.swift` (`:24`, `:27`, `:32-34`, `:39`, `:43`, `:49`, `:54`, `:71`). They are read at
  `Views/NavigationModel.swift:150`, `:359`, `:1358` and `:1369`, by `DocumentViewerModel` for copy, and at
  `Views/NavigationWindowView.swift:131` for the font size.
- **Real-path test:** none.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** the panel also has Dates (R-42) and Excluded folders sections, which §Options does not list.

### R-42 · Dates in other calendars

- **Promise:** Options ▸ Dates ▸ "Show dates in other calendars" is off by default. Turned on, the list's
  right-click menu gains "Show Date In ▸" with every calendar. The Date column then shows a day-precision date
  in that calendar, Julian marked "(O.S.)", with the stored ISO day as its tooltip. This changes the display
  only: the choice is kept in the app's settings, and the file and its tags are never touched.
- **Promised in:** `CLAUDE.md` Implementation map (`DisplayCalendarPreferences.swift`); `SUITE_TODO_DONE.md`
  `W24.cal1-reader`, `W24.cal1`.
- **Reached by:** the Options toggle (`Views/OptionsView.swift:59`, key `displayCalendarsEnabled`) and the
  context menu's "Show Date In ▸" (`Views/NavigationWindowView.swift:176-182`, `:197`). The menu shows only
  when `canChooseDisplayCalendar` holds (`Views/NavigationModel.swift:464`). Its action is `setDisplayCalendar`
  (`:466`). The cell text and tooltip are drawn at `Views/AppKitTableView.swift:314-316`. "(O.S.)" comes from
  `Core/DisplayCalendarPreferences.swift:30-35`.
- **Real-path test:** `ArchiveReaderTests/DisplayCalendarReaderTests.testJulianDayIsConvertedAndMarkedOldStyle`,
  `.testChoiceRoundTripsAcrossInstancesAndIsPerArchive`, `.testSwitchIsOffByDefault`. No UITest uses the menu.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** the menu is hidden on a root without a durable marker, by design (`W24.cal1-reader` review).

### R-43 · Showing the JPEG original

- **Promise:** in the document window, View ▸ Show JPEG Image (⌘⌥J) switches the image pane between the PDF's
  page and the original JPEG from the JPEGS tree. The choice persists per archive and per PDF, and a page link
  records the JPEG it resolved to.
- **Promised in:** `SUITE_TODO_DONE.md` `W24.jpeg1`, `W24.jpeg1a`, `W24.jpeg1b`.
- **Reached by:** View ▸ Show JPEG Image / Show PDF Image, ⌘⌥J (`ArchiveReaderCommands.swift:42-46`). It appears
  only when `doc.hasJPEGPartner`. The command calls `DocumentViewerModel.toggleImageSource`, which saves through
  `DocumentImageSourcePreferences` (`Views/DocumentImageSourcePreferences.swift`). Page links pin the JPEG
  through `jpegRelativePath` (`Core/ArchiveLinkWriter.swift:43`, `:88`, `:156`).
- **Real-path test:** `ArchiveReaderUITests/ViewerUITests.testJPEGImageSwitchIsAvailableAndSticky`;
  `ArchiveReaderTests/DocumentRenderGuardTests.testLinkedJPEGPartnerRendersAndPreferenceRestores`;
  `ArchiveReaderTests/ArchiveLinkWriterTests.testPageLinkCarriesOnlyTheCleanlyResolvedJPEGPartner`.
- **Runtime evidence:** none. The W40.a3 screenshots show the JPEG fixture drawn in the preview and the viewer,
  but they were a suite run (see the header).
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:** the preview sheet shows the choice but never saves it.

### R-44 · Durable archive links

- **Promise:** the Reader copies links to a document and to a page. Each carries the archive's saved root
  identifier, so it still resolves after the archive moves. Opening such a link (from Notes, say) reveals the
  file in the Reader and opens the page. A missing file is reported without freezing the app (`W23.m14`).
- **Promised in:** `SUITE_TODO_DONE.md` `W4`, `W23.m4`, `W23.m6`, `W23.m14`, `W24.jpeg1b`; `CLAUDE.md`
  Implementation map (ArchiveCore durable-link types).
- **Reached by:** Selection ▸ Copy Archive Link(s), ⌘⇧L (`ArchiveReaderCommands.swift:78`), calls
  `NavigationModel.copyArchiveLinks` (`Views/NavigationModel.swift:1375`). Document ▸ Copy Archive Link to This
  Page (`ArchiveReaderCommands.swift:154`) calls `DocumentViewerModel.copyArchivePageLink`. The root identifier
  comes from `RootMarker.ensure` (`Core/RootMarkerState.swift:77`). The `archivereader` URL scheme
  (`Info.plist:25-35`) goes through `.onOpenURL` to `Core/DeepLinkRouter.swift:13`, then
  `NavigationModel.revealAndSelect` (`:819`). For a page link it also calls `requestOpenViewer`, which opens the
  window at that page (`Views/DocumentWindowView.swift:47-49`).
- **Real-path test:** `ArchiveReaderTests/DocumentPageLinkTests.testDeepLinkURLReachesTheViewerRequestWithItsPage`,
  `.testCopiedPageLinkRoundTripsToTheSamePage`, `.testRevealOfAnAbsentFileRequestsNothing`;
  `ArchiveReaderUITests/ViewerUITests.testCopyPageLinkIsEnabledInTheDocumentWindow`. No test sends a real
  `archivereader://` URL to the app. `DeepLinkTests` is skipped on the host lane by standing practice.
- **Runtime evidence:** none.
- **Status:** `unproven`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
- **Notes:**
  - A document link without a page selects the row but opens no window, as a test asserts.
  - Copy Archive Link(s) refuses until the JPEG-partner scan is ready (`NavigationModel.swift:1388-1393`).
  - `W23.m14`'s fix lives in Notes' `ReaderLinkResolver`. Inside the Reader, a miss is an in-memory scan of
    the list, with no disk work.

### R-45 · The Core Directive holds on every tag write

- **Promise:** only Finder tags ever change. A file's bytes and location never do. Every write goes through
  the one audited writer:
  - It is coordinated and metadata-only.
  - It re-reads the tags first and aborts if they cannot be read, so an unreadable file is never wiped.
  - It matches tokens exactly, as whole strings.
  - It checks the result by re-reading it.
  - It re-checks the file's identity before writing (§6, `W14.2-fu`).
  - The PDF panes cannot edit anything.
- **Promised in:** `CLAUDE.md` Core Directive, Safety Protocol §1–§8 and §13, §Never; `README.md` §Prime
  directive; `SPEC/tag-format.md`; `SUITE_TODO_DONE.md` `W14.2`, `W14.2-fu`, `W26.lint`.
- **Reached by:** every Reader write (`NavigationModel.mark`, `applyEdit`, `renameTag`, `applyDelta` and
  `undoLast`, `Views/NavigationModel.swift:1066-1320`) goes through `Core/TagWriter.swift` into
  `CoordinatedTagWriter.write` (`packages/ArchiveCore/Sources/ArchiveCore/Tags/TagWrite.swift:219`). The
  coordinated write is at `:236`, the identity check `:243-250`, the abort on an unreadable read `:262-268`,
  exact matching `:353-355` and the re-read check `:284-299`. The write surface is enforced by
  `ArchiveReader/scripts/lint-write-surface.sh`.
- **Real-path test:** `ArchiveReaderUITests/TriageJourneyUITests.testTriageWritesKeepEveryOtherTagColourAndByte` (every step); `ArchiveReaderUITests/NavigationUITests.testMatchedIdentityWritesSucceedOnScratchFixture`;
  `ArchiveReaderTests/TagWriterTests.testUnreadableFileIsRefusedNotWiped`,
  `.testApplyWithMismatchedIdentityAbortsAndLeavesReplacementUntouched`;
  `ArchiveReaderTests/TriageTests.testMarkReadRemovesOnlyUnreadAndPreservesOtherTags` (checks the bytes are
  unchanged); `ArchiveCoreTests/TagWriterPrimitiveTests.testReplacedFileAbortsAndLeavesReplacementUntouched`.
- **Runtime evidence:** 2026-10-15 · `f5c31a95` · [`evidence/reader/W40.d8-triage.md`](evidence/reader/W40.d8-triage.md): no write changed content, location, another file, an unrelated tag or a colour, on the synthetic fixture or on 76 real-corpus sample files. But every write added `com.apple.quarantine` (`0086;…;ArchiveReader;`) or rewrote an existing one (`0082` → `0086`), an xattr outside "only Finder tags".
- **Status:** `broken`
- **History:**
  - 2026-10-12 W40.b1 — row written, `unproven`.
  - 2026-10-15 W40.d8 — `broken`: `W40.fix-reader-tag-quarantine` (S3).
  - 2026-10-16 W40.f1 — still `broken`, a second defect: undo re-tags a file swapped under its path, because the
    §6 check reads `fileResourceIdentifier` through a reused `URL`'s cache and compares it with itself
    (`UndoDurabilityTests.testUndoRefusesAFileSwappedUnderItsPath`,
    [`evidence/reader/W40.f1-undo.md`](evidence/reader/W40.f1-undo.md)). `W40.fix-identity-url-cache` (S1).
  - 2026-10-17 W40.fix-identity-url-cache — the §6 defect fixed, builder is not verifier: `FileIdentity.capture`
    and `TagReading.read` now read through a new `URL` for the same file, and `CoordinatedTagWriter.write` reads
    and writes through it inside its block, so the capture, the writer's pre-read, its writes and its re-read see
    the disk and never the caller's `URL` cache. The Tier-2 review found, and a probe confirmed, that a write
    through a cached URL also wrote cached Finder info back over a hidden flag set since; fixed in the same
    change. `UndoDurabilityTests.testUndoRefusesAFileSwappedUnderItsPath`
    and `.testFileIdentityThroughAReusedURLSeesASwap` pass without their expected failures; six new
    `ArchiveCoreTests/TagWriterPrimitiveTests` (`…ThroughAReusedURL…`, `testReplacedFileAbortsThroughTheSameURLItWasCapturedThrough`,
    `testWriteReadsTheDiskNotTheCallersURLCache`, `testWriteThroughACachedURLKeepsAnExternalHiddenFlag`,
    `testUncachedURLKeepsTheNameBytesAndRefusesAnEmptyPath`), the cache-sensitive five checked to fail on the
    pre-fix code and pass with it. Still `broken` for the quarantine xattr (`W40.fix-reader-tag-quarantine`).
- **Notes:**
  - The writer-level identity tests above passed only because each handed the writer a new `URL`, while the app
    passes the same `ArchiveFile.url` to the capture and the write. Since `W40.fix-identity-url-cache` the
    primitive reads through a new `URL` itself, and the tests named in its history line pin that. The same
    cache also served the writer's §2 pre-read when the handed-in `URL` had read its tags before (measured:
    the transform saw the old tags after an external change), so that write path is covered by the fix too.
  - The identity is captured when an edit starts (`ArchiveFile.liveIdentity()`), not at discovery. It guards
    the moment between the start of an edit and its write, not a file moved since the list was built.
  - A write that fails its re-read check has already written. It throws without rolling back, which is what §9
    asks ("no blind rollback").
  - The Reader also creates `.archive-suite-root.json` in the granted root (`RootMarkerState.swift:77`). That is
    a new file in the archive, outside the "only Finder tags" promise. `W40.f2` demonstrated it on scratch
    ([`evidence/reader/W40.f2-root-marker.md`](evidence/reader/W40.f2-root-marker.md)): written when a folder is
    chosen, once, and silently re-minted with a new GUID if removed. The owner decides under `W40.root-marker`.

### R-46 · Append-only audit ledger of every change

- **Promise:** every tag change is recorded in an append-only ledger of `{path, bookmark, delta, before[],
  after[], timestamp}`. The ledger is the history and the source for undo.
- **Promised in:** `CLAUDE.md` Safety Protocol §12.
- **Reached by:** every Reader tag write. `Core/TagWriter.swift`'s `recorded(_:_:_:)` wraps each of its four
  writes (`apply`, `applyOccurrence` = undo, `setReadState`, `renameToken`) and hands each verified, non-no-op
  result to `Core/AuditLedger.swift`, which appends one JSON line to `audit-ledger.jsonl` in the Reader's
  Application Support directory (container). A write that fails its post-write verification gets a line marked
  `unverified`. `NavigationModel` binds one `group` per action (a bulk mark, edit or rename is one group, as it
  is one undo) and names the undone group in an undo's `undoes`. **Not yet the undo source:** undo still reads
  the in-memory `undoStack`, so it is lost on quit; reading the ledger is `W40.audit-ledger-undo`.
- **Real-path test:** `ArchiveReaderTests/AuditLedgerTests` (7 tests, through `NavigationModel` on scratch
  fixtures).
- **Runtime evidence:** none.
- **Status:** `fixed-pending-recheck` (the record half; the undo-source half is `W40.audit-ledger-undo`)
- **History:**
  - 2026-10-12 W40.b1 — row written, `unreachable` (a promise with no implementation).
  - 2026-10-16 W40.f1 — memory-only undo demonstrated (`UndoDurabilityTests.testTheUndoHistoryDoesNotSurviveARelaunch`,
    [`evidence/reader/W40.f1-undo.md`](evidence/reader/W40.f1-undo.md)); still `unreachable`. Build or withdraw
    is the owner's call, asked in the Daemon Report; the work it decides is `W40.audit-ledger`.
  - 2026-10-17 W40.audit-ledger — the ledger built (owner, 2026-10-16: build it, and durable undo);
    `fixed-pending-recheck`. Durable undo from it waits on `W40.fix-identity-url-cache` → `W40.audit-ledger-undo`.
- **Notes:** `unreachable` is used because there is no path to it, and this time no code either.
  `W40.b5` leaves §12 in place until the owner rules, marked as unimplemented.

### R-47 · Two same-facet date tags are flagged as ambiguous

- **Promise:** a file with two tags of the same date facet (two Years, two Months, two `Sent With` values) is
  read by a deterministic rule and flagged as ambiguous, so the user can see it needs review.
- **Promised in:** `CLAUDE.md` §Edge cases ("Multiple same-facet date tags … deterministic rule + flag
  ambiguous"); `SPEC/tag-format.md` facet table, Sent With row ("last wins, the earlier is demoted to a subject
  (`sentWithIsAmbiguous`)").
- **Reached by:** **none found.** The deterministic rule exists. For Sent With the flag exists too:
  `DocumentTags.sentWithIsAmbiguous` (`packages/ArchiveCore/Sources/ArchiveCore/Tags/DocumentTags.swift:125`).
  No app reads it; Periphery reported it unused across all three apps' index stores (`W40.e5`), and only
  `ArchiveCoreTests/DualDateTests` touches it. No flag exists for two Years or two Months. Searched:
  `ambiguous` in `ArchiveReader/macOS/Sources` and `packages/ArchiveCore/Sources`.
- **Real-path test:** none.
- **Runtime evidence:** none.
- **Status:** `unreachable`
- **History:**
  - 2026-10-16 W40.e5 — row written, `unreachable` (found by the dead-code scan).
- **Notes:** a Daemon Report decision (2026-10-16): show the flag in the Reader, or drop "flag ambiguous" from
  the guide and the SPEC.
