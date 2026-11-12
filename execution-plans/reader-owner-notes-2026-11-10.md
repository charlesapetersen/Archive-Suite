# The owner's Reader notes of 2026-11-10: causes and plan

The owner used the Reader on the full corpus (about 91,000 PDFs) and sent fifteen points. His instruction for
filing them: treat no point as a simple direction; find why the code works as it does, fix the shared cause, and
fix related things with it. This note records what was read and measured, the causes found, and which item
answers which point. The items are in `SUITE_TODO.md` §"Archive Reader at corpus size, and the owner's notes of
2026-11-10". Delete this note when the last of them ships.

Paths: R = `ArchiveReader/macOS/Sources/ArchiveReader/`, Core = `packages/ArchiveCore/Sources/ArchiveCore/`.
Tags: [M] measured, [R] read in code, [I] inferred.

## 1. Corpus scale: memory, tag changes, selection, paging, the viewer (points 1-5)

**What was measured.**
- The owner's running Reader, at 6 h 19 min on the full corpus (`footprint -p`, read-only): **1,668 MB
  footprint**. Malloc Small 921 MB in 787 regions, IOSurface 332 MB in 96 regions, Malloc Large 185 MB, Untagged
  146 MB, CoreAnimation 48 MB [M]. It was the **Debug** build: `ArchiveReader/launch.sh` builds and runs
  `Debug/ArchiveReader.app` [R], and W40.d7 measured Swift sorting 1.5-3x slower in Debug [M, KNOWN_ISSUES].
- Earlier at-size work (`ops/scale/run-reader-at-size.sh`, `ReaderAtSizeTests`, W40.d7): the re-sort per tag edit
  came down from 1.56 s to 139 ms at 116k rows (W40.fix-reader-list-recompute-at-size) [M]. That harness times
  one stage. It does not time the chain of work a single change sets off, which is where the stalls are now.

**Cause A: every small change is handled as a whole-library change, mostly on the main actor** [R].
One file's tag change, from Finder or from the Reader's own TagWriter:
- `ArchiveLibrary.apply` (`R/…/ArchiveLibrary.swift:1094-1211`) runs on main: a dictionary of all rows, a full
  `rows.filter` per changed path, a full re-sort, a whole-array equality test, then republishes `files`.
  The Reader's own writes go through `applyVerifiedWrites` (:1320-1334), another O(N) pass.
- `NavigationModel.libraryDidChange` (:1207) then: prunes the selection against every displayed URL (:1162);
  applies a new diffable snapshot (`AppKitTableView.swift:432-446`); on any read-state, quality or subject change
  re-runs **every saved smart folder's FTS queries and tests all rows** (`refreshSmartFolderCounts`, :1378-1394);
  starts an indexing pass (:1258) even though a tag change never changes text; when that pass ends,
  `refreshFormatStatuses` does about 3 x 91k SQLite lookups and a synchronous `recompute()` (:915-933), and
  re-runs the active OCR search and smart-folder queries, each ending in another `recompute()` on main.
- FSEvents latency is 0.25 s (`Search/CorpusWatcher.swift:297`) [R], so the owner's ~30 s is this compute, not
  a debounce [I].
- TagWriter itself does two F_FULLFSYNC flushes per action and the undo history is decoded on main afterwards
  (`AuditLedger.swift:84,103,327`) [R]. These are file-safety costs and stay; they are counted, not removed.

**Cause B: one monolithic view model, with O(N) work in view bodies and selection hooks** [R].
- The inspector (Edit Info) is mounted even when hidden, and its `TagEditorView` body calls
  `libraryFiles(atPaths:)`, a linear scan of all 91k rows with string hashing (`TagEditorView.swift:23,375`,
  `NavigationModel.swift:1555`), on every publish: every arrow key, every indexing progress tick, in the library
  window and again in each document window (`DocumentWindowView.swift:39,327`).
- Each selection change filters every displayed row and sorts the result (`selectedFilesCache`, :1151), writes
  UserDefaults (:758), and publishes on the one `ObservableObject`.

**Cause C: the viewer rebuilds everything on each file switch, synchronously** [R].
- Only the current `PDFDocument` is held (`DocumentViewerModel.swift:19`). Corpus files are one or two pages, so
  in a window of several files nearly every Next is a file switch [I]. `loadCurrent` (:599-623) opens the PDF on
  main, finds the JPEG partner by **linear scans** of every candidate (`Core/Corpus/JPEGPartnerIndex.swift:92,107`),
  loads it with `NSImage(contentsOf:)`.
- Each page pair gets fresh PDFViews (`.id(pageIdentity)`, `DocumentWindowView.swift:105,111`) showing a
  `page.copy()` in a throwaway document (`PDFPaneView.swift:140`), so the full scan is decoded again, 75-650 ms by
  the prefetcher's own note [R]. The IOSurface share of the footprint is probably these views' tiles [I].

**Memory, not yet attributed.** The model's own whole-corpus structures (`library.files`, a second permanent copy in
`cachedIndexEntries` whose key stores each path twice, `displayed`, `rowByID`, `formatStatuses`, `classifications`,
the JPEG candidates) come to roughly 250-350 MB at 91k [I]. `CollationRanks` may hold up to 600,000 strings
(`Core/CollationRanks.swift:23`) [R]. The rest of the 921 MB of small allocations is unexplained: fragmentation from
the repeated 91k-entry temporaries of cause A is the likely reading [I], a leak is not ruled out. The owner's
2.4 GB rising to 4.5 GB over a session says something grows. Measure before fixing (W40.reader-scale-measure).
**Measured, 2026-11-11** [M]: at 116k synthetic rows, 200 edits and 200 file switches plateau within 20–40 steps, and a
quiet minute returns nothing. The growth is freed whole-library copies kept by the allocator, not a leak, and
`CollationRanks` stays at the library's size. The chain's figures confirm causes A–C: `library.apply` takes 5.9 s per
foreign change at -O. The views' memory (IOSurface) is not visible in the unit host. Evidence:
`verification/evidence/reader/W40.reader-scale-measure.md`.

**Advanced Search drops rules past about seven (owner, 2026-11-10, sent through the walkthrough).** No cap exists
in the code [R]. Scrolling the rule list does not bring the rows back (owner, 2026-11-10), so they are lost, not hidden
below the 420 pt scroll area. Two readings are left, not reproduced: the edits live only in the sheet's `@State`, seeded
once from the request (`NavigationWindowView.swift:82`), so a re-presented or rebuilt sheet falls back to its opening
rules; and every edit runs `countMatches` over all ~91k rows on the main actor (`NavigationModel.swift:455-465`), cause B
again, which may be what sets off the rebuild [R, I]. Item:
W40.fix-reader-advanced-many-rules, reproduction first.
**Fixed, 2026-11-11** (W40.fix-reader-advanced-many-rules): reproduced in the VM, no rule is lost; the list was fixed
at about eight rows and an added row went below them without scrolling to it. The list now grows to 420 pt and
scrolls to each new row, the rules live in the request, and a count at 116k rows with 12 rules takes a median 216 ms
off main and stops on the next edit. Evidence: `verification/evidence/reader/W40.fix-reader-advanced-many-rules.md`.

**Items.** W40.reader-scale-measure first (the whole chain, Debug and -O, and a long session's memory), then
W40.fix-reader-change-incremental (A), W40.fix-reader-selection-at-size (B), W40.fix-reader-viewer-switch (C).
**Cause A fixed, 2026-11-11** (W40.fix-reader-change-incremental): a foreign tag change 19 ms main-busy, visible in a median
309 ms; a Reader write 4.5–7 ms after TagWriter; no memory growth over 200 edits. The library's row index also serves
`libraryFiles(atPaths:)` now, which cause B's inspector scan was. Evidence:
`verification/evidence/reader/W40.fix-reader-change-incremental.md`.
**Cause B fixed, 2026-11-11** (W40.fix-reader-selection-at-size): an arrow key, ⇧-arrow and the preview arrow 0-7 ms
main-busy at -O with Edit Info shown. The selection is found by the list's sort keys and followed change by change. A
hidden inspector observes nothing, and the indexing count publishes apart from the model. Evidence:
`verification/evidence/reader/W40.fix-reader-selection-at-size.md`.
**Cause C fixed, 2026-11-11** (W40.fix-reader-viewer-switch): a file switch 30 ms main-busy at -O, visible in a median
32 ms. `page.copy()` does not decode (measured), and PDFKit draws tiles off the main thread (sampled in the VM), so the
wait was blank pixels: the image pages either side are drawn ahead and the neighbours opened off main. Views are still
rebuilt per page (no memory growth over 200 switches in the VM). Evidence:
`verification/evidence/reader/W40.fix-reader-viewer-switch.md`.

## 2. Selection, the file on view, and keeping the place (points 10, 12, 13)

One missing idea explains all three: the selection is a bare `Set<URL>` (`NavigationModel.swift:62`) with no anchor
and no current item [R].
- Point 10: the preview sheet binds bare ↑/↓ (`PreviewSheet.swift:72-77`, `modifiers: []`), so ⇧↓ matches nothing,
  and `moveSelectionInList` always collapses to one row (`NavigationModel.swift:2141-2149`) [R]. The list itself is an
  `NSTableView` with multiple selection, where ⇧↓ works while the sheet is closed [R].
- Point 13: the viewer's `currentFilePath` (`DocumentViewerModel.swift:242`) is read only by the document window, its
  tag actions and the preview sheet; the list never sees it [R].
- Point 12: a new row set is applied with nothing anchoring the scroll position (`AppKitTableView.swift:387,445`); a
  selected row that drops out is just removed from the selection, and nothing takes its place (:1162-1166) [R].
  **Owner's call, 2026-11-10:** remove the row at once, keep the rows around it where they were on screen, and
  select the next row (the previous at the end), so the arrow keys carry on from the same place.

**Item.** W40.reader-selection-current — shipped 2026-11-11 (`SUITE_TODO_DONE.md`). Two findings on the way, for the
items after it: SwiftUI hands ⇧↓ to a `.keyboardShortcut(.downArrow, modifiers: [])` button (measured in the VM), so the
reading of point 10 above was half wrong (⇧↓ in the sheet did move, as a plain ↓); and an `NSTableRowView`'s own
accessibility label never reaches the tree, so a row is described through its cells.

## 3. Commands, names and shortcuts (point 14, and a stale binding found on the way)

Shortcuts and command names are written in several places (the menu in `ArchiveReaderCommands.swift`, buttons in
the preview sheet, toolbar help strings, model help text). A move therefore leaves stale copies [R]:
- After ⌥⌘C went to Copy Link(s), the **preview sheet still binds ⌥⌘C to the cleaned copy** (`PreviewSheet.swift:91-93`),
  and three help strings still say ⌥⌘C for Copy Cleaned (`DocumentWindowView.swift:263`, `PreviewSheet.swift:93`,
  `DocumentViewerModel.swift:331`) [R].
- Edit Info is already an inspector panel (`TagInspectorView`, comments call it that) on ⌘I in Tags [R]. Notes calls
  its panel Inspector, View ▸ Show/Hide Inspector, ⌥⌘I (`ArchiveNotesCommands.swift:186-198`) [R]. ⌥⌘I is unbound in
  the Reader [R].
- Preview's rotation keys ⌘L/⌘R are taken in the Reader (⌘L Focus Tag Filter, ⌘R Mark Read) [R]; Preview's view
  keys ⌥⌘1/⌥⌘2/⌥⌘6 are free [R].

**Item.** W40.reader-commands-table, which W40.reader-view-rotate and W40.reader-page-views then use.
**Shipped 2026-11-11** (`ReaderCommand`, `Core/ReaderCommandTable.swift`): it holds ⌃⌘L/⌃⌘R for rotation and ⌥⌘1/⌥⌘2/⌥⌘6 for
the page views; ⌘I is free.

## 4. Rotation and page views (points 7 and 8)

- No rotation exists in the Reader [R]. The Core Directive forbids altering file bytes, and safety rule 13 forbids
  any `PDFDocument.write` path [R], so a rotation is a view of the page, remembered outside the file. The Processor
  bakes its rotation into the pixels (`OCR/PDFGenerator.swift:137`); a page that arrives sideways is a Processor
  rotation miss, which W46.rotation-default addresses [R].
- The document window already has a contact sheet ("All Pages Tiled", `DocumentPageOverview.swift`) with no
  shortcut, off in the preview sheet (`PreviewSheet.swift:32`), and no thumbnail sidebar [R]. Pair *n* is image page
  2n plus text page 2n+1 (`Core/DocumentPagePairs.swift`), so thumbnails must show image pages, not text pages [R].

**Items.** W40.reader-view-rotate (shipped 2026-11-11: `PageTurnStore`, turns in the library index), W40.reader-page-views
(shipped 2026-11-11: `PageThumbnailSidebar`, the contact sheet in `DocumentPageOverview.swift`, `PageThumbnails`).

## 5. Copy Cleaned for Prose (point 11)

**Measured on scratch copies of Bower 00133 and 00073** (PDFKit, `page.string` and `selectionsByLine()`) [M]:
- Neither text layer has a single blank line, so paragraph breaks can come only from the layout pass.
- The layout pass (`Core/CopyTextCleaner.swift:78-148`) matches PDFKit's line selections to the text's lines one for
  one and silently does nothing when they differ (:91-92). On 00133 there are 27 text lines and 28 line selections
  (one list marker is its own selection); on 00073 the counts agree but line selections carry embedded
  newlines from hyphenated words. Both fall back, so both lose every break [M, I for which
  check trips first].
- The geometry needed is there: on 00073 each paragraph's first line starts at x ≈ 120 against 84-86 for the rest; on
  00133 numbered items start at x ≈ 93-98 with continuation lines at 29-35, and lettered sub-items start at x ≈ 117-119
  with hanging continuation lines at 140 [M].
- The cleaner has two outcomes only, a space or a paragraph break, and no case step [R]: list lines run together,
  an isolated indent counts only when neither neighbour is indented (:137), a line starting with a bullet, dash or
  lowercase letter never starts a break (:139), and blocks under 3 lines are skipped (:119).

**Apple Intelligence.** Nothing in the suite uses the Foundation Models framework [R]. From general knowledge, to be
checked by the item: the on-device model needs macOS 26 or later, Apple silicon, and Apple Intelligence switched on;
the suite supports macOS 14; output is not deterministic. So a model can only be an optional second pass, and for a
historian's quotation it must never change a word. The safe shape is guided generation that labels lines (continues,
new paragraph, list item and level, heading), with the app assembling the text and a check that the words out equal
the words in.

**Items.** W40.reader-prose-structure (rules from geometry, no model), then W40.reader-prose-model (the research and
measurement). Title case is shared with W47.ct-normalise, which needs the same rule for label text.

**Rules shipped 2026-11-11** (W40.reader-prose-structure, `SUITE_TODO_DONE.md`): `CopyTextCleaner.structure` and
`assemble` (the units and the word guard W40.reader-prose-model's labels would feed), ArchiveCore
`TitleCase.titleCased(_:keeping:)` for W47.ct-normalise. Both Bower pages keep their breaks, list and levels.

**Model measured 2026-11-12** (W40.reader-prose-model, `ArchiveReader/scripts/prose-model/README.md`): no build.
The checks above hold (macOS 26+, an Apple Intelligence Mac with it switched on; 8,192 tokens on macOS 27). On 40
typed pages, the model labelling lines behind the word guard tied the rules on labels (+0.014, a tie) and lost on
breaks (F1 0.43 against 0.62). It refused 2 pages on safety grounds and takes 3-9 s a page.

## 6. Watermarks, warping and selection (points 6 and 9)

**Owner, 2026-11-10:** these pages are tests of the pipeline, not a request for a bulk re-read; a bulk re-read waits
until the pipeline is sorted out. "UIUC 156" tests how well the readers resolve a red stamp; 00233 and 00149 test
warping with selection.

**Measured on scratch copies, Apple Vision accurate mode at 3,000 px, $0** [M]:
- The text the owner sees on all three is the corpus's pre-app text layer, badly fragmented.
- UIUC 00156, raw image: 50 lines, 198 words; the lines under the red "COPY" stamp break into fragments and about
  fifteen words are lost. With the OCR input made from the red channel alone,
  which turns the red ink as light as the paper: 32 whole lines, 200 words, none of those losses, and the blue RECEIVED
  stamp is still read. The stamp's own word "COPY" is gone from that reading, so it must be recorded as a mark.
- UIUC 00233 (a bound, curved page with the back showing through) and 00149 read cleanly raw: 28 lines / 252 words
  and 37 lines / 239 words, every line whole. The red channel changes nothing on them.
- Vision's lines are also the geometry the placement stage puts words on (`13-stage-rules/05-placement.md`), so a
  stamp that breaks Vision's lines breaks text selection too.

**Rules that bind.** Stage 02: an OCR input is a separate, transient image and nothing is applied before OCR today
(R02.1-R02.3); stamps and marks are evidence and are preserved (W46 `00-plan.md`); the OCR prompt asks readers to
transcribe stamps (`OCR/OCRPrompt.swift:46`). A colour-dropout input therefore fits R02.2 only as an OCR input, needs a
measurement before it becomes a route, and changing R02.1 is the owner's call. Stage 01: no dewarped copy (owner,
2026-11-06); "strongly curled or bound pages untested", and "a new owner kind (bound volumes, curled pages) where
curl-tagged pages exceed the 10 now scored" is a stated reason to look again (`01-reading-copy.md:85,97`).

**Items.** W46.ocr-input-colour-dropout, W46.place-curved-owner.

## 7. Box and Folder are item types, not colours (point 15)

- The SPEC stores the item type as the Finder colour label: Red = 6 means a box photo, Purple = 3 a folder photo
  (`SPEC/tag-format.md:83`, rule 7 at :315); ArchiveCore's `enum ArchiveColor { case box, folder }` hard-codes Red/6 and
  Purple/3 (`Core/Tags/DocumentTags.swift:19-36`); the Processor maps box to Red and folder to Purple
  (`Capture/CaptureModels.swift:5-17`); the Reader's editor section is "Color / marker" with "Box (Red)" and
  "Folder (Purple)" (`TagEditorView.swift:337-347`), and its change status says "Color" [R]. No user can change the
  mapping [R]. Box and Folder also exist as reserved literal subjects (SPEC :82) and as page-2 Classification values
  (SPEC :194) [R].
- **Measured on the 5,000-file sample (xattr reads only):** 75 files carry Red and 186 carry Purple; **none** carries a
  `Box` or `Folder` tag [M]. In the owner's corpus the colour is today the only record of the type.

So the type has to become its own field, and colour a per-user display choice, while a pre-app corpus that marked
types by colour can still be read: the user says once, per folder, which colour meant which type.

**Item.** W40.suite-item-types (Tier-2: the shared contract, all three apps).

## Clashes and extended items

- ⌥⌘I is free in the Reader; ⌘I is Edit Info today and is freed by the rename (W40.reader-commands-table decides
  whether it stays as a second key). ⌥⌘C is Copy Link(s) in the menu but still the cleaned copy in the preview
  sheet: fixed by the same item.
- Extended, not duplicated: W40.fix-reader-date-fields (names the panel Inspector), W40.suite-reader-notes-consistency
  (one name and key for the inspector), W47.ct-normalise (one title-case rule with the prose copy), W47.ct-reader-edit
  (the container inspector is a section of the Inspector), W42.int-s5 (the three UIUC pages as acceptance pages for
  placement), W47.ct-infer (reads the item type, not the colour).
- Not filed: a bulk re-read of the corpus (owner, 2026-11-10: only once the pipeline is sorted out).
