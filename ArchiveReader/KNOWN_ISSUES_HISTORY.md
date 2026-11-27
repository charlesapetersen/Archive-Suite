# Archive Reader — Known Issues history

Archived from [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md) on 2026-11-25 (W49.reader-docs-launch-hygiene): the fixed
and closed entries and the July–October 2026 fix logs, in the order they stood. History only; the open limits
stay in `KNOWN_ISSUES.md`. A new fixed entry may still be written there and moved here later.

## Document window panes left the accessibility tree when the image was zoomed (fixed 2026-11-27)

With the image page zoomed past fit, the document window's content reported no accessibility children. Both panes
were gone for VoiceOver and XCUITest until Fit Page, and `DocumentPaneKeysUITests` failed at "the Original image
page is in the window". The page-naming walk inside `ReaderPDFView.accessibilityChildren()` caused it on macOS
27.2. The walk now runs just after the query.
[Measurements](../verification/evidence/reader/W40.fix-reader-docpanekeys-vm-harness.md). (W40.fix-reader-docpanekeys-vm-harness)

## Cloud-only PDFs in Reader (S-002, fixed 2026-11-21)

Selection, page thumbnails and neighbor prefetch leave cloud-only PDFs in the cloud. The document window
and Space preview offer **Download and Show**. Find reports when its results cover downloaded files only.
[Reproduction and regression](../verification/evidence/reader/W49.reader-s002-reproduce-check.md).
(W49.fix-reader-dataless-prefetch)

## OCR search with an unavailable index (S-003, fixed 2026-11-22)

When an OCR query empties the list and Reader cannot open the index, the list says “OCR search unavailable”
and offers **Rescan**, which retries the existing archive scan. The active query runs again after indexing.
[Independent VM reproduction](../verification/evidence/reader/W49.reader-s003-reproduce-check.md).
(W49.fix-reader-dead-index-overlay)

## Password-protected PDFs in the document viewer (S-005, fixed 2026-11-21)

The document window and Space preview explain that the PDF is password-protected. Library health
still classifies the locked PDF as unreadable.
[Independent scratch reproduction](../verification/evidence/reader/W49.reader-s005-reproduce-check.md).
(W49.fix-reader-encrypted-pdf)

## ✅ CLOSED (W40.reader-jpeg-read, 2026-11-17) — Mark Read and Unread work on JPEGs; the status line says why a file was left alone

Read state may now be written in the `Archival Photos JPEGS` tree beside MAIN: Mark Read/Unread (menu, R, row menu,
document window), the Read cell and Clear Read State. Every other tag change still stays inside MAIN, and so does every
undo or redo line that changes anything but Read/Unread, even when its file has since moved into JPEGS (judged by the
line's inverse). Undo history covers both trees. What stays as it was: **Mark Read never adds a read-state tag to a file
that has none** (Safety §10, hard-coded); the status line now says so ("1 has no Read or Unread tag, so it was left
alone."), and likewise for files already in that state and files outside both trees, instead of "Marked 0 Read.". The
Read cell still adds one on a click, as before. A cached row that lost its tag on disk still counts as "could not
update", because re-verification needs a read-state tag to track the file.

## ✅ CLOSED (W40.fix-reader-inspector-narrow, 2026-11-11) — the window makes room for the Inspector

At the navigation window's 900-pt minimum with the sidebar shown, the Inspector ran past the window's right edge and its
Close button could not be clicked. The minimum now adds up the open panels and the content column's ~600 pt, and a narrower
window is widened when the Inspector opens and put back when it closes. With both panels at their widest the minimum is
1444 pt, more than a 1440-pt screen. UITest launches start with the Inspector closed (`-ar.infoVisible NO`).

## ✅ CLOSED (W40.reader-commands-table, 2026-11-11) — one command table; Edit Info is the Inspector on ⌥⌘I

Names, keys and tooltips were written beside each control, so a moved key left stale copies: the preview sheet
bound ⌥⌘C (Copy Link(s)) to the cleaned copy and three tooltips named it. `ReaderCommand` now holds them all, and
`ReaderCommandTableTests` fails on a clash, a menu item that differs from the table, or any string naming an
unbound key. Edit Info is View ▸ Show/Hide Inspector, ⌥⌘I, as in Notes; ⌘I is free.

## ✅ CLOSED (W40.reader-prose-shortcut, 2026-11-08) — prose copy uses Command–Shift–C

The owner’s requested shortcut is ⇧⌘C for Edit ▸ Copy Cleaned for Prose. Selection ▸ Copy Link(s)
uses the freed ⌥⌘C, keeping the commands distinct even while the preview sheet is open.
The menu shortcut checks and existing document/preview copy interaction tests use the new bindings.

## ✅ CLOSED (W40.reader-page-views, 2026-11-11) — Thumbnails and Contact Sheet across all open files

Preview's page views are in the document window and the preview sheet: View ▸ Show/Hide Thumbnails ⌥⌘2 (one
item since W40.reader-thumbnails-toggle; it was Hide Thumbnails ⌥⌘1 and Thumbnails ⌥⌘2), Contact Sheet ⌥⌘6 (All Pages Tiled, below, renamed), plus two toolbar buttons. The sidebar shows the image
page of each page pair, never the OCR text page, for every open file under a heading that marks the file on view;
the contact sheet keeps every PDF page. Both draw lazily from the on-disk `PDFThumbnailer` cache, decoded to their
size, and turned as the reader turned the page; off-screen cells hold no bitmap. Each window remembers its sidebar.
Found on the way: `PDFThumbnailer` sized its canvas from the unturned crop box while PDFKit drew the page's own
`/Rotate`, so a quarter-turned page came out mostly blank, in Copy Archive Link's pictures too; fixed, with a test.

## ✅ CLOSED (W40.reader-tiled-pages, 2026-11-08) — all PDF pages tiled, without window tabs

View ▸ All Pages Tiled and the document toolbar show numbered tiles for every physical PDF page,
including OCR pages and an odd trailing scan. Click a tile to read its scan/OCR pair; the toolbar returns
to the selected page. Find and page cycling also return to reading. Pane-only commands are disabled in
the overview. Tiles always open the PDF page even when the JPEG original was selected, without changing
the saved JPEG preference. Rendering is serial, off-main and read-only; offscreen tiles release their
bitmaps. The preview sheet keeps its existing reading view. Automatic window tabbing is off, and document
windows disallow it; View no longer offers Show All Tabs.

Reader smoke passed: 731 tests, three skipped, zero failures; no new compiler warnings. Five-page scratch
coverage verifies page/focus mapping, find/cycling, unavailable/invalid inputs, distinct rendered tiles and
unchanged PDF bytes; the paired-JPEG regression passes. All five headless tile PNGs were inspected.
ViewerUITests.testAllPagesOverview passed in the macOS 27.2 VM, including the absent Show All Tabs item,
OCR-tile opening and Find's return to reading; both screenshots were inspected. Separate adversarial review,
write-surface lint and its 25 mutation checks passed. The broader VM suite remains tracked by
W40.vm-macos27-reader; this feature's focused interaction check is verified.

## ✅ CLOSED (W40.fix-reader-tagcloud-slider, 2026-11-08) — drag the tag cloud threshold

The minimum-file threshold is now a slider with an explicit count label. It uses whole numbers, spans the
current view's tag counts plus one (so all tags can be hidden), and keeps a remembered higher threshold
when browsing a smaller scope. The same AppStorage key remembers the choice between launches. Tags in the
active filter remain clickable even below the threshold. Narrow-panel light/dark render checks cover 1, 7
and a remembered 999; their images were inspected. Reader smoke: 726 tests, three skipped, zero failures;
write-surface lint and all 25 mutation checks passed. NavigationUITests.testTagCloudMinimumCountHidesRareTags passed in the macOS 27.2 VM, dragging to hide
all fixture tags and back to show every tag; both screenshots were inspected.

## ✅ CLOSED (W40.fix-reader-sort-indicator-icons, 2026-11-08) — sort carets on the icon columns

The Flag and Needs attention headers now draw a compact up/down caret for the primary sort. AppKit
suppressed its native indicator in these narrow columns, even with twelve extra points. The compact
header cell keeps the original widths, native sorting and header accessibility; the minimum-window fit
still keeps Read on screen. SortIndicatorHeaderTests checks both directions and visible icons in light/dark
at the narrow-window fit; its direction comparison failed with the native cells. The focused VM test clicks
the icons, compares their rendered directions and checks that each becomes the primary sort.

## ✅ CLOSED (W40.fix-reader-columns-in-header, 2026-11-08) — choose columns from the headers

Right-click a list column header to show or hide columns, as in Finder (Reader session 2, row 3).
The filter bar's Columns chip is removed. Hidden columns remain in the header menu so they can be shown
again, and choices persist between launches. File name stays checked and disabled; Capture marker is
disabled while no file has one. Explicit menu validation and action guards protect those fixed choices.
Existing secondary-sort commands remain in the same menu. ColumnHeaderMenuTests covers the real menu's
validation, hide/show actions, persistence, unchanged sort and an off-screen header render;
ColumnHeaderUITests.testHeaderMenuShowsAndHidesAColumn passed in the macOS 27.2 VM; all three screenshots
were inspected. Reader smoke: 724 tests, three skipped, zero failures; write-surface lint clean.

## ✅ CLOSED (W40.fix-reader-in-effect-folder, 2026-11-08) — In effect shows filters and searches

The ordinary sidebar folder no longer appears as an In effect chip (Reader session 2, row 5). Smart folders
and unsaved Advanced Searches keep their chip: their rules still apply after Clear All, so the chip explains
that base search and offers a way to leave it. Empty-list explanations still name the ordinary folder, and
Clear Folder remains available when its scope alone hides every file. Clearing a search chip keeps the sidebar
selection. `ActiveFiltersTests` covers these cases on scratch files; the focused navigation UITest checks the
folder/search transition and screenshots the row in the off-screen VM.

## ✅ CLOSED (W40.fix-reader-smart-folders, 2026-11-08) — smart folders count files and open without snippets

Sidebar counts now evaluate every saved rule tree, including OCR text, negative text and nested all/any
rules. Counts describe the folder's base set across the library, independently of the currently open folder
and user filters, and leave excluded folders out. Committed content-index changes refresh OCR counts even
when the smart folder is closed; generation checks discard superseded answers after rule or library changes.

Opening a smart folder or unsaved Advanced Search lists its matching files without OCR previews. Typing in
Search OCR text supplies snippets from that query; clearing it returns to the base set and plain filenames.
Scope relevance sorting remains available without extracting unused snippets. Injected test defaults now also
own the saved-search store, so scratch smart-folder tests never write the owner's saved searches.

`AdvancedSearchScopeTests` covers real scratch indexing, nested/negative/zero counts, user narrowing,
reindexing, exclusions, rapid rule replacement/deletion and snippet clearing, and renders the shared sidebar
count row and actual filename formatter. `AdvancedSearchUITests.testSmartFolderCountsAndPreviewsOnlyForUserTextSearch`
checks the sidebar count and saved-folder/search/clear transitions in the off-screen VM.

**Fixed 2026-11-17 (`W40.fix-reader-ocr-clear-preview`):** clearing the search could leave a preview on the
rows below the visible rect. When the rows kept their IDs, the table reloaded only the visible rows, but
NSTableView also holds rows it has prepared past that rect. Those kept the old snippet and came on screen
as the shorter rows moved up. The list now reloads every row it holds a view for, and notes their heights.
Snippet fill and type-marker colour changes use the same set.

## ✅ CLOSED (W40.fix-reader-tag-add-speed, 2026-11-08) — verified tags render before the large-library refresh

The inspector already submitted Return and Tab promptly. Scratch timing found the delay after verification:
at 50,001 synthetic rows the queued cache/filter/sort pass occupied the main thread for 394–592 ms. Large
snapshots with unchanged paths now prepare immutable presentation data off-main; verified library tags can
render while that work runs. A newer library snapshot cancels the preparation, and a newer filter/sort view
supersedes its presentation. Small libraries keep their inexpensive synchronous refresh. Rapid successive
inspector additions retain the verified tag's spelling before autocomplete finishes refreshing.

The writer, identity checks, verification and durable undo journal remain synchronous and unchanged.
`DocumentWindowTagTests.testInspectorReturnAndTabDoNotWaitForLargeLibraryPresentation` exercises the real
Return and Tab delegate routes, fresh scratch tags, unchanged file bytes, one undo per key, rapid case variants,
a superseding filter and an empty replacement library. Its 250 ms main-thread budget fails the measured old
path. The test also renders the verified chip. `TagEntryUITests.testInspectorShowsTagsAfterReturnAndTab`
checks both visible chips and disk tags in the off-screen VM. Timing details:
`verification/evidence/reader/W40.fix-reader-tag-add-speed.md`.

## ✅ CLOSED (W40.fix-reader-undo-status-detail, 2026-11-08) — Undo and Redo describe the verified change

The status names the file, field and before/after values; groups count distinct files and combine matching
changes. Subject changes list precise added/removed tokens, preserving duplicate and case differences.
Descriptions come from the actual verified writes, so a concurrent edit, a no-op or a failed member is not
reported as a successful reversal. Multiple writes to one file combine only across continuous snapshots.
Failure counts and retry guidance remain visible. The document window shares the completed status and offers
its full text on hover. Scratch undo/redo tests cover relaunch, groups, partial retries and document routing;
`TagChangeStatusTests` covers dates, labels, occurrences and external edits between writes. The focused VM
ledger-undo check now asserts Undo and Redo details and screenshots both before restoring the scratch tags.

## ✅ CLOSED (W40.reader-edit-info-inspector, 2026-11-07) — Edit Info stays open beside the files

⌘I and the library toolbar show or hide a resizable right-hand inspector. It follows the visible selection
or the document window's open file, with separate remembered widths and visibility. Filtering away a row
removes it from list actions immediately. Each editor instance keeps explicit original target paths, so a
field leaving focus or disappearing cannot write its draft to the newly selected file. Hiding retains invalid
date text and its hint; valid fields still apply through the existing audited writer. An open document
inspector no longer disables tag undo from the document panes; TextUndoGuard protects typing in fields.

`PhantomSelectionTests` and `DocumentWindowTagTests` cover scratch targeting and undo; `TagInspectorRenderTests`
renders empty, single and mixed groups in light/dark at the minimum column width. Focused VM tests cover
selection and ⌘I/Close, pending/invalid drafts with on-disk tag assertions, document following, health-warning
actions and document menus. The visual-tour helper now hides the inspector with ⌘I instead of sheet Escape.

## ✅ CLOSED (W40.fix-reader-health-issue-detail, 2026-11-07) — file warnings explain the issue and offer actions

Click the ⚠︎ in the PDF warning column or an ambiguous Date cell for the file's name, path, exact symptom,
and next steps. An unreadable PDF is described as a failed open, with possible causes rather than a claim of
corruption; missing selectable text explains why OCR search cannot find its contents. Open Document and
Reveal in Finder act on the named file. Reader does not repair PDF contents or run OCR. Conflicting dates
name the tags used and set aside, with Edit Info selecting that file alone in the existing editor.

An unchanged index refresh preserves an open explanation; changed issues or cell reuse dismiss it. Presented
actions capture their file, so a selection change or reused cell cannot redirect them. Opening details or a
document writes no tags. `FileHealthDetailTests` covers real table cells, distinct symptoms, healthy cells,
click targets, action targeting across selection changes/reuse, and headless renders in light and dark.
`NavigationUITests.testFileHealthWarningOpensDetailsAndEditInfoForThatFile` covers the actual table click,
popover and Edit Info path in the off-screen VM.
`NavigationUITests.testPDFWarningExplainsMissingTextAndOffersActions` checks the PDF warning, its viewing
and Finder actions, and Escape dismissal. The new popover leaves identifiers on individual controls; a
container identifier propagated over them in SwiftUI and prevented the VM from finding the actions.

## ✅ CLOSED (W40.fix-reader-health-live, 2026-11-07) — Library health updates while indexing

The open health popover observes the navigation model directly, so discovery and tag changes refresh its
counts without reopening it. PDF health refreshes after successful index batch commits, coalesced to at most
once a second during a fast build, with an immediate refresh when indexing becomes idle. Extraction progress
alone does not trigger reads of uncommitted results. Counts remain scoped to the current library.

`LibraryHealthLiveTests` holds the last two of 502 synthetic extractions, verifies 500 committed health results
before the pass finishes, then verifies the final partial batch and a cleared library. It renders the same
mounted popover through discovery, indexing and completion. The existing ambiguous-date navigation UITest
now opens the popover once and waits for its Show button, rather than reopening it until counts arrive.
`NavigationUITests.testLibraryHealthPopoverShowsCountsAndFilters` exercises that health/filter path on its
own. The broader `testTwoYearTagsAreFlaggedAndTheFilterFindsThem` passes in the macOS 27 VM since
W40.vm-macos27-reader (2026-11-12). Its original assertions are retained.

## ✅ CLOSED (W40.fix-reader-filter-undo-levels, 2026-11-07) — multiple filename-filter undo steps

The file-name filter has its own native field editor and undo history. Each typing, paste, replacement or deletion edit can be undone and redone separately; undo/redo publishes the result to the live filter. Binding echoes retain the caret and history, while Clear or another external reset starts fresh history. Marked-text editing keeps native input-method behavior, and switching fields keeps their undo histories separate.

Covered by `FilenameFilterFieldTests`, `NavigationUITests.testFilenameFilterUndoesAndRedoesSuccessiveEdits` (field, filter chip and list), and `UndoFocusUITests` (text versus tag history on scratch files).

## ✅ CLOSED (W40.fix-reader-doc-keys-focus, 2026-11-07) — document arrows and clicked-pane focus

Plain arrows pan the focused PDF page, bounded at its edges; modified arrows retain menu and text-selection behavior. Clicking a PDF or extracted-text pane updates the focus border and focused zoom even without a selection. Rebuilt panes recover keyboard focus only when the window itself holds it, preserving the Find field’s caret.

`DocumentPaneInputTests` exercises real PDFKit scroll geometry and never-ordered AppKit windows, including PDF/extracted-text replacements and a live field editor. Whole-window pointer/key verification: `ArchiveReaderUITests/DocumentPaneKeysUITests.testDocumentPaneKeyboardFocusAndPan` passes in the macOS 27.2 guest (W40.fix-reader-doc-keys-focus-ui, 2026-11-12, 3 of 3; screenshots read).

## ✅ CLOSED (W40.fix-reader-a11y-labels, 2026-10-25) — unnamed Reader controls and PDF pages

The tag/name/OCR filters and file list have explicit names; the OCR magnifier is decorative. Flag and warning
cells announce their state even when visually empty, resetting labels on reuse. Both panel dividers expose
native named splitter roles and bounded width actions; pointer resizing uses global coordinates. PDFKit's
actual AXPage nodes carry “Original image page” / “OCR text page” titles without replacing their selectable
text descendants (PDFKit ignores the page label setter, but accepts its public title setter).

The light/dark main-screen VM audits pass with the labels KnownIssue removed, including external PDF titles,
preview content containment and both directions of pointer resize. Native PDF/splitter regressions and the
full Reader smoke pass. Evidence: [`W40.fix-reader-a11y-labels.md`](../verification/evidence/reader/W40.fix-reader-a11y-labels.md).
The separate contrast finding was closed by W40.fix-reader-a11y-contrast below; reading order and whole-task
keyboard access were not established by these audits.

## ✅ CLOSED (W40.fix-reader-a11y-contrast, 2026-10-25) — small labels and warnings below AA

Sidebar/tag-cloud counts, navigation status text and preview/viewer page counters use primary text. Type and
both read states use primary text plus active/inactive selection colours; Unread is semibold rather than accent
blue. ReaderColors gives warnings a darker amber in light mode and a pale orange in dark, yielding to selection
text when selected. This changes presentation only.

The 4.5:1 pixel guard covers read states, Type/warning inks and chip text through selection transitions. The
main-screen accessibility audit has no contrast KnownIssue exemption. Verification results and screenshots:
[`W40.fix-reader-a11y-contrast.md`](../verification/evidence/reader/W40.fix-reader-a11y-contrast.md).

## ✅ CLOSED (W40.fix-reader-selected-row-contrast, 2026-10-24) — selected Read labels and tag chips

The Read column's accent-blue “Unread” and native token fills merged into the active selection highlight.
`TintedTextCellView` follows active and inactive selection text colours. W40.fix-reader-a11y-contrast later
replaced the secondary “Read” and ordinary accent “Unread” with primary text (Unread semibold). `WrappingTokenField` draws filled chips on ordinary/inactive rows and outlined chips with
selection text on active rows, returning to native tokens during editing. Selection does not change chip
geometry. A wrapping cell asks for its row height again after layout rather than drawing below its row.

`SelectedRowContrastTests` samples the real cells' label, chip lettering and outline in light/dark; it also
reuses the cells through active, inactive, deselected and reselected states, and rejects the old accent label.
The focused VM screenshot check and its measured results are kept in
[`selected-row-contrast-2026-10-24.md`](../verification/evidence/reader/selected-row-contrast-2026-10-24.md).

## ✅ CLOSED (gate-fix, 2026-10-17) — write-surface lint allowances lagged the fresh-URL writer

`W40.fix-identity-url-cache` (`20e8f078`) moved the three audited tag/label setters from the
coordinator's cached `writeURL` to `target = writeURL.uncached`, but left the lint's exact-line
allowances stale. Re-audited all three: they remain inside metadata-only coordination, after the
identity/trustworthy-read guards, with label-drift restoration and post-write verification. The lint
now pins those exact `target` lines. Two comments name the metadata setter descriptively to avoid
tripping the deliberately broad API-name scan; no scan, scope, or safety check changed.

Verified both failing gate steps repeatedly, including all 22 scratch-tree mutation/control checks
in `test-lint-write-surface.sh`. Only allowance data and prose changed; app behavior is unchanged.

## ✅ CLOSED (2026-08-10) — the VM XCUITest lane went BLIND for a day: TWO faults, neither in the app

**Both apps' entire UITest bundles failed as *"Main window should appear"*, and the apps were drawing
correctly throughout.** The health gate read the 37 failures as "a reproducible build/test regression the
per-change reviews missed" and **parked the daemon**. Nothing in the 30 commits since the last green gate
was involved. Kept here because the symptom is maximally misleading — it names a window, so it reads as a
product bug — and because it took two rounds to fix, each of which looked like a total failure until the
other landed:

1. **The guest could not SEE.** `AXIsProcessTrusted()` was false and `kAXWindows` returned **-25211**
   (`kAXErrorAPIDisabled`). Everything `tart exec` starts is attributed to the tart guest agent, so the
   lane borrows *its* Accessibility grant — and that grant, while present and reading `auth_value = 2`,
   was silently not honoured: *"Failed to match existing code requirement …"*, `authReason=5`. Two causes,
   both needed: the agent binary is **linker-signed** ad-hoc (`codesign --verify` → "not signed at all"),
   which can satisfy **no** requirement; and it is a **fat** binary, so the requirement must be its
   designated requirement (`cdhash <arm64> or cdhash <x86_64>`), not one slice's hash.
2. **There was nothing to see.** XCUITest launches the app-under-test **without**
   `-ApplePersistenceIgnoreState`, though Xcode passes it to its own test runner. AppKit then restores
   saved state whose window set is empty (`hasPersistentStateToRestore=1` → `No windows open yet`) and
   SwiftUI never opens the `Window` scene. Self-perpetuating: that launch re-saves "no windows".

**Fixed:** `ops/gui/vm-seed-accessibility.sh` (idempotent, backs up, verifies) for (1); a
`UITestLaunch.archiveUITestApp()` seam in **both** UITest bundles for (2). **Guarded:**
`ops/gui/vm-check-accessibility.swift` runs as a preflight in the interactive lane *and* the health gate,
and a lane that cannot see is now a **SKIP** ("NOT VERIFIED"), never a RED — an environment fault must not
be able to park the daemon on a phantom regression again.

⚠️ **The lesson worth keeping:** *a UITest-launch fix can only be tested by a UITest run.* Fix (2) was
briefly dismissed during the repair because the flag was tried against a plain `open`, which opens a
window anyway and therefore could not show a difference. Equally, `CGWindowList` and the *sighted* lane
see real pixels while XCUITest sees only the accessibility tree — when they disagree, the lane is blind,
not the app. Full record: `SUITE_TODO.md` → **W26.vmuitest-blind**.

## ✅ FIXED (`W26.previewzoom`) — the preview sheet's zoom/fit shortcuts did nothing; `⌘0` never reached it

**Found 2026-08-09** by `W26.docs-fu1`, the item that finally ran a GUI check deferred since the feature
shipped; **fixed 2026-08-10.** It was a *shipped claim that was false*, not a regression: `SUITE_TODO_DONE.md`
recorded **"⌘0 = fit full page everywhere zoom applies"** and **"on open, focus the image pane so keyboard
zoom works immediately"**, and neither held in the preview sheet (`Space` / `⌘Y`). The full **document window
was always fine** — only the sheet was affected.

**What was measured in the VM** (`ArchiveReaderUITests.testFitPageCommandReachesThePreviewSheet`; screenshots
in `~/.tart-mirror/vm-artifacts/shots-reader/`):
- Document ▸ `Fit Page` was disabled from the list (correct — nothing to fit) and **stayed disabled while the
  preview sheet was open**, so `ArchiveReaderCommands`' `@FocusedObject var doc` was nil and `.disabled(doc == nil)`
  killed `Fit Page`, `Zoom In`, `Zoom Out` and the pane-focus commands alike. (accepted: fixed, W26.previewzoom; what the VM measured before the fix).
- In pixels the sheet's image pane was **byte-identical** before and after `⌘↑`×3 and again after `⌘0` (three
  screenshots, two blobs — the result bundle deduplicated the identical pair). Nothing zoomed; nothing refit. (accepted: fixed, W26.previewzoom; what the VM measured before the fix).

**Cause:** `PreviewSheet` published with `.focusedObject(model)`, which applies only while the modified
subtree holds SwiftUI keyboard focus — and the pane is an AppKit `PDFView` behind `NSViewRepresentable`, which
never gives SwiftUI that focus. It was the app's only `.focusedObject`; `NavigationWindowView` and
`DocumentWindowView` both use `.focusedSceneObject`, and their Document-menu commands always worked.

🔺 **THE ONE-TOKEN FIX THAT SUGGESTS IS HALF OF IT, AND THE OTHER HALF IS THE PART WORTH REMEMBERING: a
focused-SCENE value is NOT retracted when the view that set it is torn down.** Switching the sheet to
`.focusedSceneObject(model)` made `Fit Page` correctly ENABLED with the sheet open, and left it **enabled
after the sheet was dismissed** — a live command over a dead preview model, and with it the Document menu's
⌘C / ⌘⇧C shadowing the Selection menu's own bindings in the nav window. Not a test artifact:
`documentMenuItem` re-opens the Document menu on every call, so every read is a fresh AppKit validation.
**A destroyed view cannot publish `nil`**, so scene-scoped publication has to be owned by something that
outlives what it publishes.

**Shipped shape:** `PreviewSheet` publishes nothing and reports its model up through a `@Binding`
(`published`, set in `onAppear`, cleared in `onDisappear`); `NavigationWindowView` holds it in `@State` and
publishes `publishedPreviewViewer`, which is `nil` unless `model.showingPreview` — belt-and-braces, because
`onDisappear` is not guaranteed on every teardown path but the sheet cannot be on screen with its own
`isPresented` binding false. The model stays a fresh `@StateObject` **per presentation** on purpose:
`PDFPaneController` carries `savedScale` forward by design (DV-2), so one shared long-lived instance would
have made a re-opened preview restore the last zoom instead of fit-full-page — falsifying the *"Preview gets
its own default zoom"* behaviour while fixing this one.

**The 241 s stall recorded against this issue was the bug**, not a separate mystery: with `⌘0` bound to
nothing the app never went idle. After the fix, from the test's own timing prints, `⌘↑`×3 = **0.4 s** and
`⌘0` = **0.1 s**.

**How it is now proven** — the inverse of the deduplication that proved the bug. Three shots bracket
`fit → ⌘↑×3 → ⌘0`: shot 2 differs from shot 1, and shot 3 is **byte-identical to shot 1** (MD5
`29e26af3…`), so the zoom happened *and* `⌘0` refit exactly back to the default rather than merely changing
something. VM lane 19 tests / 0 failures.

**Residual, tracked as `W26.previewzoom-fu1` — ✅ ALSO FIXED, 2026-08-10:** publishing the model necessarily
enables *every* `.disabled(doc == nil)` item in the Document menu while the preview is up, and `Find…` /
`Find Next` / `Find Previous` had no find bar there to drive. They now gate on a
`DocumentViewerModel.supportsFind` (false for the sheet's model), as do the model's own `performFind` /
`findNext` / `findPrevious` — the invariant belongs to the viewer, not to three `.disabled` modifiers.
⚠️ It is **not** derived from `persists`, deliberately: the two co-vary in today's one preview, but a future
non-persisting viewer that renders a find bar would inherit the wrong answer. Everything else the publication
enables (zoom / fit, paging, pane focus, ⌘C / ⌥⌘C, *Copy Archive Link to This Page*) is wanted and stays
enabled — the UITest asserts that pair, because "find disabled" is only meaningful next to "the rest is not".

## ✅ FIXED (`W26.fsev-fu2`) — a folder that would not open left the list spinning "Scanning…" for ever

**Found 2026-08-06** by `W26.fsev-fu1`, which bounded the *stream*'s `open(2)` and measured that the *walk*'s
own probe had no bound at all. `CorpusWalker.canonicalRoot` (`rootIsOpenable` when this was written; renamed
by `W26.symroot`, which also made it resolve a symlinked root) calls `opendir(3)` on the same root, on its
dedicated `Thread`; under an unanswered TCC prompt, a stalled network/cloud mount or a disconnected volume it
does not return, the pass never reaches `finish`, and `LibraryPhase` stays `.firstScan(done: 0, seen: 0)` —
which `LibraryEmptyState` reads as `.scanning`. So the status bar was honest about live updates while the
list beneath it blanked behind a spinner that would never stop.

**Fixed 2026-08-06 (`5b4a8c8` → completion commit).** A pass that has examined **zero** files after
`scanStallTimeout` (5 s) publishes `.degraded(.scanStalled)` — *"Archive folder has not answered"*. It is a
**reported** deadline, not a cancellation, because a thread blocked in `opendir` cannot be interrupted: the
walk keeps running and supersedes the verdict if it returns, and so does the first file it sees. The verdict
grants nothing — `.degraded` is not settled, so no content-index pruning and no authoritative absence.

⚠️ **The thread is still stuck.** Nothing here makes an unopenable root openable, or reclaims the thread and
security scope that a stalled walk holds for the life of the process. What changed is that the app says so
and stays usable. If you are diagnosing a Reader that reports this, the problem is the volume or the
permission prompt, not the app.

## ✅ FIXED (`W26.fsev-fu1`) — the app could hang at launch, with no window, starting the FSEvents stream

**Found 2026-08-06** while shipping `W26.vocab-fu1`, from a stack sample rather than a reading. A Reader
unit run sat for 9+ minutes at **0% CPU** in:

```
NavigationModel.init() → ArchiveLibrary.start(scope:) :186 → startWatcher :465
  → CorpusWatcher.start() :256 (FSEventStreamCreate) → open(2)   ← main thread
```

`FSEventStreamCreate` opens the watched root, and it was called synchronously on the main thread during
`NavigationModel` construction. On local disk that is microseconds and invisible. Under an unanswerable TCC
prompt, a stalled network/cloud mount, or a disconnected volume the `open` does not return and **the app
never draws** — no window, no message, nothing to cancel. Everything else in this subsystem was already off
the main thread (the launch walk has a dedicated `Thread`, the stream runs on its own queue); the stream's
*creation* was the last synchronous step.

**Fixed 2026-08-06 (`a4aced6` → completion commit).** The start runs on a dedicated `Thread`, and
`W26.fsev`'s ordering guarantee is preserved by inverting *who waits*: the launch **walk** is deferred behind
the start instead of the main thread waiting on the open. A 2-second deadline bounds that deferral — an
unopenable root now draws a window, lists whatever it can read, and says *"Archive folder is not
responding"* (`DiscoveryFailure.liveUpdatesStalled`) instead of stalling silently. A stream that returns late
is still adopted and pays for the interval it missed with exactly one catch-up pass. Full entry, including
the three non-obvious decisions and the mutation results, in `SUITE_TODO_DONE.md` §Wave 26.

✅ **The walk's own `opendir` now has a deadline too** — see the `W26.fsev-fu2` entry above. Its probe still
blocks; the difference is that the list stops claiming to be scanning and says the folder has not answered.

**Practical consequence for testing — resolved by `W20.deeplink-isolation`.** The no-root deep-link test now
constructs `NavigationModel(defaults: fixtureDefaults())`; that unpinned, throwaway domain has no
`archiveRootBookmark`, so it never resolves or walks the owner's saved root. The Reader gate includes the test
again rather than hiding it with `-skip-testing`; a no-root regression now fails visibly without any real-corpus
contact or TCC prompt.

## ✅ FIXED (`W26.walk2`) — Release discovery was Spotlight-only and could blame an unreadable index on files

**Found 2026-08-04.** The owner pointed the Reader at a folder of 1,849 correctly-tagged PDFs on a volume
whose Spotlight index was dead, and the app said *"No Read/Unread-tagged PDFs were found in this folder."*
Root cause: `ArchiveLibrary` discovers only through `NSMetadataQuery`, and the one filesystem walk that
exists (`loadFixtureSynchronously`) is `#if DEBUG` — **compiled out of Release entirely**. There is no
fallback to fail over to, and `NavigationWindowView.swift:174-176` states the empty result as a fact about
the corpus rather than about what the app could see.

**Engine shipped 2026-08-05 (`W26.walk1`: `b3efb16` → `025d126`).** `ArchiveCore.CorpusWalker` is the
deterministic replacement — read-only, and its result distinguishes *has tags* / *verified none* /
**could not read** (`unreadable`, `directoryErrors`, `isClean`), which no layer of the old stack could.
`ArchiveReaderTests/LibraryDiscoveryTests` pins that it returns exactly what the shipped loader returns on a
readable tree, and that it diverges on exactly one thing: an unreadable file, which the loader drops in
silence while still reporting a settled library.

**Fixed 2026-08-05 (`W26.walk2`: `f1c0d2f` → `b88d20a` → `6f5d6ad` → completion commit).** Release now uses
that walker; all `NSMetadataQuery`/`NSMetadataItem` discovery and the Spotlight-lag `PendingWrite` subsystem
are deleted. `LibraryPhase` is the single health gate: only a clean, root-stable `.settled` pass may treat an
absence as real, prune content-index rows, or claim that no files carry Read/Unread tags. That last sentence
must quote how many regular files were examined. A degraded pass keeps every unseen prior row, including
descendants of a directory the enumerator could not enter, and cannot consume a deep link's not-found retry
budget. `W26.fsev` now supplies live FSEvents; File ▸ Rescan Archive Folder (⌘⌥R) remains the explicit
recovery control.

**Non-vacuous GUI proof:** the Tart VM's fixture builder timed out with **0/11 files Spotlight-indexed**, yet
Reader rendered all 11 tagged files and its existing 16 UI tests passed. A separate UI test over one genuinely
untagged sandbox file verified the rendered denominator. The incident no longer has an app-side workaround
because it no longer depends on Spotlight discovery.

## ✅ FIXED (`W26.fsev`) — external Finder/Processor changes were invisible until a manual rescan

**Fixed 2026-08-05 (completion commit).** `CorpusWatcher` now starts a FileEvents + MarkSelf + WatchRoot
FSEvents stream before the launch walk, on a serial dispatch queue, and holds an additional security scope
for exactly the stream lifetime. Each asynchronous exact/subtree read holds its own balanced operation scope
and is cancelled on root replacement. Every retained event is re-statted and re-read through
`ArchiveCore.CorpusWalker.inspect`; semantic item flags are never trusted. Exact paths update in place,
`MustScanSubDirs` replaces only its subtree, stream/drop sentinels force a root pass, and
RootChanged/mount/unmount re-resolve the saved bookmark before restarting. Hidden files, package
descendants, directory symlink targets, and the measured `.sb-XXXXXXXX-XXXXXX` atomic-save sibling stay
outside the walk's universe.

The app persists no event ID: each launch walks once and watches `SinceNow`. A volume whose stream cannot
start shows *"Live archive updates unavailable"* instead of going quietly stale; activation retries it and,
if still unavailable and the last clean settle is over five minutes old, re-walks. Recovering a stream also
forces one catch-up walk because `SinceNow` cannot replay its outage. There is no periodic timer. Root passes
are bounded to one active + one queued with a minimum interval, and queued recovery never exposes a false
settled/pruning window.

**Adversarial corrections before ship (11 across two passes):** dropped/history sentinels are interpreted
before path containment; RootChanged wins over unioned drop/history flags; an old-root callback is
generation-rejected; live work cannot outlive its security scope or root generation; a live read has the same
newer-verified-write precedence as a full walk while still accepting freshly read content metadata;
directory→file replacement clears phantom descendants; directory symlinks never expand the watched tree; a
queued root pass never briefly publishes settled; a recovered `SinceNow` stream gets a catch-up walk; and a
failed `FSEventStreamStart` does not call the start-only `Stop` API. The real APFS test changes Finder tags
from a separate `/usr/bin/xattr` process and uses `FSEventStreamFlushSync` to prove delivery without
Spotlight. Final self-review also made a newer serialized live read retire converged verified-write ordering
guards, so a long-running healthy library cannot retain every Reader edit forever. All filesystem fixtures are
temporary scratch trees; the real corpus was neither read nor written.

## ✅ FIXED (`W26.idx`) — launch blocked on a full walk, and persisted rows could amplify stale writes

The owned filesystem walk made discovery truthful, but a large root still showed no rows until the pass
finished. `W26.idx` adds a separate disposable system-SQLite discovery cache keyed by byte-exact root path +
marker GUID + file path. It restores tracked rows immediately as visibly revalidating, then compares fresh
`stat(2)` fingerprints and re-reads tags for every new, changed or unverified path. The tuple includes ctime,
because a Finder tag edit need not change mtime. Scan provenance prevents an interrupted/denied pass from
claiming currency or deleting unseen rows after relaunch; canceled corpus-scale DB work yields every 500 rows.

The cache does not gain write authority. Every cache-provenance row is re-inspected before a bulk or inline
mutation derives a target/delta, and the corpus rename primitive re-reads under coordination and requires the
old token still to exist. Out-of-root/canonical-lookalike paths are rejected byte-exactly. Dataless rows never
reach the PDF-open boundary; stale content-index rows are removed without materialising the file. Regression
tests cover warm correction after an app-closed tag change, mixed valid/stale selections, conditional rename,
root/commit races, partial SQLite state, canonical Unicode spellings and no-download extraction policy. The
index and saved-selection shape are new v1 state: there is deliberately no migration or compatibility path.

## ✅ FIXED (W26.deny) — `TagWriter` could DESTROY tags on a file whose xattrs are unreadable-but-writable

**Found 2026-08-04** while auditing Spotlight removal; **independent of Spotlight** and of that wave.

**Fixed 2026-08-05** — `2956f3c` (the read primitive) → `ad86cce` (the write path). Affects
`packages/ArchiveCore` — filed here because Reader tag safety is documented here. The finding is kept below
in full, followed by *what shipped*, because two of the prescriptions written into it were measured wrong.

`TagWrite.swift:252-261` states *"§2/§3 fresh read inside coordination; a read FAILURE aborts (never treated
as empty)"* and then does:

```swift
let rv = try writeURL.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey])
before = rv.tagNames ?? []          // ← breaks the promise directly above
```

**The `catch` never fires in the dangerous case.** Measured: `resourceValues` throws `NSCocoaErrorDomain/257`
for parent-directory denial and for an ACL denying `read`/`readattr`/`readextattr` — both already safe — but
for **a file that is itself unreadable with a traversable parent it SUCCEEDS with `tagNames == nil`**. So
`before = []`, `transform([], nil)` computes a delta against nothing, and `:271` commits it.

**Reproduced twice on scratch files** (tags `["Unread","Subj","P9"]`, then a "mark Read"):

| Setup | read | write | result |
|---|---|---|---|
| `mode 0o200` (write-only) | no throw, `before=[]` | **SUCCEEDED** | `["Read"]` — **`Subj`/`P9` destroyed** |
| ACL `deny readextattr`, perms `0644` | no throw, `before=[]` | **SUCCEEDED** | `["Read"]` — **destroyed** |
| `mode 0o000` | no throw, `before=[]` | fails (−5000) | tags survive, but `before`/inverse is `[]` → **undo corrupt** |

Violates the Core Directive (*"MUST NOT mangle, drop, or lose any tag unintentionally"*).

**Exposure on the real corpus: ZERO — measured, not assumed.** Read-only scan of all **123,028** files under
`~/Desktop/Google Drive/Archival Photos`: `owner lacks read bit: 0`, `getxattr EACCES: 0`. (51 files match
"nil tags yet `_kMDItemUserTags` present"; inspected samples decode to a literal **empty array** at
`-rw-r--r--` — benign residue of removed tags, not denial.) So **latent, not an active fire** — but modes and
ACLs arrive from network copies, restores and archive extractions, and the corpus is irreplaceable.

⚠️ **Testing gotcha that already caused one wrong conclusion here:** `URL.resourceValues` **caches on the
backing `NSURL`**, so a probe that reuses a `URL` value returns a stale answer and the test passes while
asserting nothing. Build a fresh `URL` per probe, or use `stat(2)`/`getxattr`. See *@Published willSet
timing* below and the `url-resourcevalues-caches` note (W23.m11-fu) for the same class of trap.

### What shipped (2026-08-05)

**`TagXattr.inspect`** (`packages/ArchiveCore/.../Tags/TagReading.swift`) is the new shared primitive that
answers *absent* / *readable-but-empty* / *unreadable* by asking the filesystem directly:
`getxattr(path, "com.apple.metadata:_kMDItemUserTags", …)`, where **only `ENOATTR` (93) confirms absence** —
`EACCES`, `EPERM`, `EIO`, `ENOTSUP`, `ENOENT` all mean *we could not look*. It runs **only on the
`tagNames == nil` branch**, so a tagged file costs nothing extra. Both call sites route through it:
`TagReading.read`, and `CoordinatedTagWriter`'s §2/§3 fresh read **and** its §8 post-write re-read (without
the latter, a write to an *empty* tag array would "verify" against a file nobody can read).

🔴 **Two prescriptions in the finding above are WRONG — do not follow them; they are corrected in
`execution-plans/despotlight.md` §4a.1 and §7a.3:**

1. **`access(R_OK)` is not a usable probe** (the finding's own later text says this; the "Fix" line said
   `access(R_OK)`/`getxattr`). An ACE denying only `readextattr` leaves the file *data* readable, so
   `access(R_OK)` returns 0 while the tags are unreadable.
2. **The probe must FOLLOW symlinks — NOT `XATTR_NOFOLLOW`.** Measured: `resourceValues` reports the
   **target's** tags through a symlink, so a `XATTR_NOFOLLOW` probe answers about the *link*, which has no
   attribute of its own, and returns `ENOATTR` — "confirmed no tags" — for a **denied target**. The same
   coercion, displaced one indirection.
3. **"a returned size of 0" is not the only honest empty.** Removing a file's tags leaves a **42-byte
   empty-array plist** behind, and macOS reports `tagNames == nil` for it. **51 of the owner's 123,302
   files** are in that state; treating a nonzero size as unreadable would have mis-flagged every one. The
   shipped rule: a readable attribute that decodes to an **empty array** is a confirmed "no tags"; a
   non-empty array macOS did not report as tags, a non-array plist, or undecodable bytes are all unreadable.

**Corpus census, read-only, 2026-08-05** — 123,302 regular files in 30.8 s, 0 walk errors: 21,311 `ENOATTR` ·
101,940 tagged · 51 empty-array residue · **0 denied** · 0 undecodable. Exposure was and is zero; this is a
guard against modes and ACLs arriving from network copies, restores and archive extractions.

**Known consequence, explained by `W26.notsup` (fixed 2026-08-05):** a volume with no xattr support (some
SMB/NFS mounts — *not* FAT/exFAT, where macOS emulates them) returns `ENOTSUP`, so every file there still
correctly reads as unreadable. Reader now surfaces *"Finder tags unavailable for N files"* and explains that
it cannot list or edit those files because their volume cannot represent Read/Unread tags; it recommends an
archive copy on a Finder-tag-capable volume such as APFS, followed by a rescan. Mixed-mount permission and
folder failures keep their own counts. Classification keys on ArchiveCore's exact ENOTSUP suffix, not a broad
substring that could be present in a filename. The safe read/write primitive is unchanged.

**Tests:** `ArchiveCoreTests/TagDenialTests` (20, scratch temp files only), non-vacuity measured on six
mutants — including reverting the coercion, which turns the write tests red by **succeeding**.

## ✅ FIXED (W23.l2) — a cancelled prune task could still defeat the two-emission absence gate

**2026-07-31.** `ContentIndexer.pruneIfSettled` cancels the prior prune task before starting a new one,
and that cancellation was doing more work than it can. **Cancellation is cooperative**: a task already
past its last `Task.isCancelled` check runs to completion, and `MainActor.run` is *not* cancellation-aware,
so its late hops execute too. The old code then read `pendingPrune` in one hop and wrote it in another,
with nothing tying either to the emission it belonged to.

**Re-confirmed empirically before anything changed** — the finding was inspection-only, and the first
probe *refuted itself*, which is the useful part. Replaying the pre-fix shape under the real concurrency
runtime, back-to-back emissions turned out to be **safe**: task A dies at its first cancellation check
because it hasn't started running when B cancels it. The race needs A genuinely mid-flight — which is the
real case, since `allPaths()` over a large index takes real time. With the probe parked past A's last
check, all four questions confirmed: A observed `Task.isCancelled == true` and ran its hops anyway; a
superseded A overwrote state a newer emission had just written; that stale stash then deleted a path
after only **one** current absence; and in the other interleaving A deleted a path the newest snapshot
said was **present**. Search results vanish until a reindex — the files themselves were never at risk
(the content index is an explicitly rebuildable cache).

**The fix is a prune epoch, and two halves of it are load-bearing:**
- `commitPruneDecision` does read-decide-write in **one main-actor hop**. A split read-then-write is the
  window a newer emission interleaved through, so a generation check alone would not have closed it. (accepted: fixed, W23.l2; why the fix is built this way).
- The row delete **re-checks the epoch** before running. Skipping a superseded delete costs only that the
  rows survive another two-emission cycle; deleting them wrongly costs search hits until a reindex. (accepted: fixed, W23.l2; why the fix is built this way).

Gotchas for whoever touches this next:
- **`resetPruneState` bumps the epoch, not just the task.** A root change invalidates the old root's
  absences; without the bump an in-flight task from that root re-stashes them over the cleared state. (accepted: fixed, W23.l2; a note for whoever touches this next).
- **The delete now happens AFTER the pending-state write** (it used to be before). That ordering is safe
  because `pendingPrune` is in-memory only: if the `try?`'d delete fails, the next emission re-stashes the
  absence and prunes a cycle later. Two end-to-end tests over a real scratch index pin the observable
  contract so the reordering can't drift. (accepted: fixed, W23.l2; a note for whoever touches this next).
- **`pruneDecision` is now a pure function here too**, mirroring `NotesIndexer`'s (this file is its
  fork) — which moves the "an empty snapshot can never wipe the index" guarantee inside the decision.
  `NavigationModel` already refuses to call with an empty set, so no reachable behaviour changed; the
  point is that the guarantee can no longer be lost to a future caller. (accepted: fixed, W23.l2; a note for whoever touches this next).
- **The race tests don't try to win a real race.** They drive the interleavings through the epoch seam
  (`beginPruneGeneration` / `commitPruneDecision`), and each one re-implements the pre-fix ungated logic
  against the same fixture and asserts it produced the harmful outcome — so a passing test can't be
  vacuous. `inFlightPruneTask` exists so an end-to-end test can await an emission instead of sleeping. (accepted: fixed, W23.l2; a note for whoever touches this next).

## ✅ FIXED (W23.m9) — a failed `ContentIndex.open()` poisoned search until restart, silently
**2026-07-30.** Two defects on the same path, both about silence.

**The half-open handle.** `sqlite3_open_v2` is *lazy*: it returns a live handle for a file it hasn't read.
So a corrupt or foreign `content-index-v2.sqlite3` opened with `SQLITE_OK` and died on the first PRAGMA
("file is not a database", rc=26 — confirmed by experiment before any code changed). `open()` threw with
`db` still non-nil, and since it short-circuits on `guard db == nil`, **every later `open()` returned
"success" without completing setup**: the index was poisoned for the life of the process, and since the bad
file is still there next launch, every launch after. `open()` is now all-or-nothing — the PRAGMA/schema half
runs inside a `do` whose `catch` calls the new `discardHandle()` and rethrows. `discardHandle()` uses
**`sqlite3_close_v2`, not `sqlite3_close`**: close_v2 never returns BUSY, so clearing `db` can't strand a
live connection holding the file lock. That mattered — under the neutered build the stranded handle kept the
`-shm` sidecar locked and even *replacing* the bad file failed.

**The silent finish.** `ContentIndexer.launch` opened with `try?` and wrote every batch with `try?`, then
finished like any other pass: a dead index produced a run that extracted every PDF in the library, threw all
of it away, cleared `progress`, and left an idle status bar. Search answered `[]` — indistinguishable from
"no matches" — and format health answered 0, i.e. "nothing needs attention". The driver now publishes a typed
`Failure` (`.unavailable(detail:)` / `.incomplete(rows:)`), mapped from a pass `Outcome` in one place
(`finish`), where `.ok` **clears** it so a transient corruption can't leave a permanent warning. The five
query paths go through `openForQuery()`, which records the failure rather than answering empty.
`NavigationModel.indexFailure` mirrors it; the status bar shows an amber line whose tooltip carries the
SQLite reason (`ar.status.indexFailure`).

Gotchas for whoever touches this next:
- **`pruneIfSettled`'s `try?` is deliberate.** A failed open there makes `allPaths()` empty, so the diff finds
  nothing absent and the prune deletes nothing — it degrades to a no-op. The asymmetry with the query paths is
  intentional and commented in place. (accepted: by design, W23.m9; a failed open there degrades the prune to a no-op).
- **A failed open now STOPS the pass.** Continuing meant extracting 150k PDFs to discard them one batch at a
  time; the honest path is also the cheap one. (accepted: by design, W23.m9; stopping is the honest and the cheap path).
- **`.incomplete(rows:)` has no end-to-end test** and can't easily get one: post-fix a batch write can only
  fail at *runtime* (disk full, corruption after open), and there is no portable way to make SQLite fail a
  write on demand short of corrupting an open file (undefined behaviour). The outcome→state mapping is a pure
  function that IS tested; the count itself is `batch.count` at two flush sites, exact because `upsertBatch`
  rolls the whole batch back on any error. (accepted: SQLite cannot be made to fail a write on demand; the outcome mapping is a tested pure function).
- `ContentIndexer` gained an `init(url:)` seam (the app path is now `convenience init()`), which is how the
  failure paths are reachable without an Application Support file. (accepted: fixed, W23.m9; the seam the failure tests use).

Tests: `ContentIndexRecoveryTests` (3), `ContentIndexerFailureTests` (7) — scratch garbage sqlite3 files under
the bundle temp dir; the `ArchiveFile` paths need not exist (an unreadable file is a legitimate row). Both
mechanisms proven non-vacuous by neutering. The same fix shipped in Notes the same day — see
`../ArchiveNotes/KNOWN_ISSUES.md`.

## ✅ FIXED (W23.m9-fu3) — the Reader index warning and live recovery had never been rendered

**2026-09-25.** The amber `ar.status.indexFailure` line was only covered by headless tests. The GUI fixture
builder now has an opt-in mode that seeds its generated scratch tree with exactly 1 KiB of invalid SQLite
bytes. `ContentIndexer` accepts a DEBUG index-path override only when the path is the fixture's expected
cache and the root is a non-symlink directory with the exact generated Reader marker. The UI test renders the
warning, truncates that disposable cache, invokes File ▸ Rescan Archive Folder in the same process, and
asserts both that the warning retracts and that California OCR search results return.

The off-screen Tart VM test passed. Reader's 404 unit tests, the 36 fixture-script checks, and the write-surface
lint passed. The fixture is scratch-only; no archive corpus was read or written.

## ✅ FIXED (`W20.deeplink-isolation`) — the no-root deep-link test could read the owner's saved root
The app-hosted unit bundle shares `com.archivereader.app` defaults, so a bare `NavigationModel()` could resolve
the owner's persisted `archiveRootBookmark`; the no-root assertion then failed or spent time discovering a root
the test did not own. `W26.fixturehang` provided injectable defaults and `fixtureDefaults()`; the test now uses
an unpinned throwaway suite, so its `RootFolderStore` deterministically has no bookmark. The health gate now
runs this case normally. Nothing stashes, removes, reads, or writes the real bookmark.

## GUI-pass regressions in the AppKit nav table + tag filter (2026-07-16 — owner GUI re-test)
An interactive GUI pass surfaced three display/interaction bugs in shipped Reader features. Two fixed, one deferred:
- **FTS snippet previews never rendered (FIXED).** The keyword-in-context excerpt line under a search hit was
  clipped: the AppKit name-column `NSTextField` (a `labelWithString:` field) stayed single-line
  (`usesSingleLineMode`/`wraps = false`), so the appended second line + `\n` never grew the row under
  `usesAutomaticRowHeights`. Fix: in the snippet branch, put the field into the same multi-line-capable state the
  tags cell (`TagTokenCellView`) uses, and reset it in the non-hit branch (cells are reused). `AppKitTableView.swift`. (accepted: fixed, the 2026-07-16 GUI pass; AppKitTableView.swift).
- **Column-header click sort was dead (FIXED).** `sortDescriptorsDidChange` is an `NSTableViewDataSource`
  callback, but it was implemented on the `Coordinator` (only the table's *delegate*); the
  `NSTableViewDiffableDataSource` is the real `dataSource` and never forwarded it. Fix: a
  `SortableDiffableDataSource` subclass implements + forwards it — **and the method MUST be `@objc`**: an optional
  @objc-protocol method added on a *subclass* is not auto-exposed to the Obj-C runtime, so `respondsToSelector:`
  returned false and AppKit never called it (build was clean; only runtime/GUI surfaced it). `AppKitTableView.swift`. (accepted: fixed, the 2026-07-16 GUI pass; the @objc lesson).
- **Selected-tag filter chips shifted the file table left (FIXED `b5a5a01`, owner-verified 2026-07-16).** The chips
  rendered as separate buttons beside the "Add tag filter…" field in a single-row filter bar that already sits near
  the window width; each added chip's width tipped the content column past the window, so the root `HStack`
  re-centered and dragged the file table left.
  **Two container fixes failed — the instructive part:** a horizontal `ScrollView` capped at 260 pt *reserved* its
  max eagerly (a scroll viewport's width is the width proposed to it, independent of content), so it overflowed on
  the **first** chip — worse than the original; a wrapping `FlowLayout` then got compressed to ~one chip wide and
  piled the tags up vertically. Both attempts were tuning a container's width; the bug was that **any**
  content-sized chip row inflates a bar that has no slack.
  **Fix (by construction, not by tuning):** `Views/SubjectFilterTokenField.swift` — an `NSTokenField` whose tokens
  ARE the selected filters, bounded (220 pt), single-line, horizontally scrolling, with LOW horizontal compression
  resistance. Tags live *inside* the field, so adding a filter adds **zero** width to the bar and the column can't
  be pushed past the window. Replaced the `TagFilterField` combo box (deleted; that was its only call site).
  **Lesson:** when a layout bug is "container X inflates its parent", moving the content *inside* an
  already-bounded control beats resizing the container. (accepted: fixed, b5a5a01, owner-verified 2026-07-16; the layout lesson).

## @Published willSet timing (fixed 2026-07-05 — GUI-caught)
- A Combine subscription on a nested `@Published` (`library.$files`) fires in **willSet**, *before* the
  property commits. A synchronous sink that reads the stored property (`self.library.files`) inside
  `recompute()` therefore sees the **old** value — which made the nav list show **0 of N** after a
  load. Fix: `.receive(on: DispatchQueue.main)` before the sink so it runs after the value commits
  (or use the value the publisher delivers, not the stored property). **Do not** read a just-changed
  `@Published` back from `self` inside its own synchronous sink. Unit tests missed this; only running
  the GUI surfaced it (verified via `screencapture`). (accepted: fixed, 2026-07-05; a lesson for Combine sinks).

## SwiftUI `Table` row-render skip via identity-only Equatable (fixed 2026-07-05 — GUI-caught)
- `ArchiveFile` conformed to `Equatable`/`Hashable` by **`url` only** (treating `==` as *identity*).
  SwiftUI's `Table` diffs elements by Equatable, so when a tag edit changed a row's *tags* but not its
  `url`, the Table judged the element "unchanged" and **skipped re-rendering the cell** — marking a
  file Read left the row visibly "Unread" even though the model was correct. This *masked* the separate
  Spotlight clobber (below): we never saw "Read" appear, so it looked like the write/optimistic update
  failed. Fix: **value-based `==`** (url + name + fileType + tags + contentModified) in
  `ArchiveFile.swift`; row *identity* for selection stays `id` = url.path; url-only `hash` remains valid
  (value-equal ⇒ same url ⇒ same hash). **Lesson:** for a type used as SwiftUI collection data, make
  `Equatable` reflect **displayed value**, not identity — identity belongs in `id`. Unit tests missed
  it; only the live GUI surfaced it (same lesson as the willSet gotcha above). (accepted: fixed, 2026-07-05; Equatable reflects the displayed value, identity is id).

## Spotlight tag-index lag clobber (fixed 2026-07-05; obsolete subsystem removed by W26.walk2 2026-08-05)
- The 2026-07-05 fix overlaid `TagWriter`'s verified `.after` value while Spotlight re-emitted stale tags.
  It was necessary while `ArchiveLibrary` consumed `NSMetadataQuery`, but its 600-second TTL, convergence
  comparisons, and settle timer had no role once filesystem discovery shipped. `W26.walk2` deleted that
  `PendingWrite` subsystem and its 8-case test file. A smaller monotonic ordering guard now protects the
  distinct race that remains: if a walk started before a verified write, its later emission cannot replace
  the fresh `.after`/`.afterLabel`. All five write call sites still publish only the writer's verified re-read;
  no optimistic reconstruction, disk write, or extra disk read was introduced. (accepted: fixed, W26.walk2; the Spotlight subsystem is gone; the ordering guard remains).

## Interleaved merged PDFs: pages 3+ were unviewable AND unfindable (W23.m2 — fixed 2026-07-30)
- Processor merges a multi-page document as `image1, text1, image2, text2, …` (`PDFGenerator.mergeDocumentPDFs`,
  and its "Re-OCR multi-page PDF" mode), and `SPEC/tag-format.md` §"Interleaved multi-page variant" states
  outright that **consumers must not hard-assume two pages**. Reader assumed exactly that in three places at
  once: `DocumentViewerModel.imagePage`/`textPage` were `page(at: 0)`/`page(at: 1)`, `next()`/`previous()`
  stepped **file URLs** rather than pages within a document, and `DocumentFindScanner` had a literal
  `default: break` discarding every match on page index ≥ 2. Net effect for any merged document with 2+ source
  pages: every scan after the first, and all of its OCR text, was unreachable at every affordance — no
  scrolling, no cycling, no find, no menu command — **even though the full-text index had already extracted it**,
  so search would lead you to a document whose matching page you then could not open. (accepted: fixed, W23.m2; the defect as found).
- Fix: a **page-pair** model. New pure `Core/DocumentPagePairs` — pair `p` is PDF page `2p` (image) + `2p+1`
  (OCR text) — is the single home for that arithmetic, shared by the viewer and the find scanner so they
  cannot drift. `pairCount` rounds **up**, so a merge of a 2-page document and a bare scan doesn't lose the
  trailing scan. `DocumentViewerModel` publishes `pair`: cycling walks pairs then files (backwards lands on the
  previous document's **last** pair), `canGoNext`/`canGoPrevious` gate the buttons, `positionLabel` gains
  "· page 2 of 4" only when there IS more than one pair, and `DocumentFindScanner.pairMatchCounts` buckets
  every page so `FindNavigator` can address a match by `(doc, pair, pane)`. (accepted: fixed, W23.m2; the page-pair model).
- **Gotcha worth remembering:** both viewers must key their panes on `model.pageIdentity` (index + pair), not
  on the file index. `PDFPaneView.updateNSView`'s reuse fallback compares `page.string`, which is `nil` for
  both the old and the new **image** page — so without the pair in the `.id`, stepping to the next pair leaves
  the previous scan on screen. `PreviewSheet` had no `.id` at all, which was the same latent bug for document
  cycling there; it is keyed now too. (accepted: fixed, W23.m2; a note for whoever touches the panes).
- Not a SPEC change: the SPEC already documented the interleaved variant and the no-2-page-assumption rule.
  This is Reader coming into conformance with it. (accepted: not a SPEC change; the Reader conforms to the SPEC).
- ~~Still open (separate item)~~ **CLOSED by `W23.m4`** (below): the focused-pane page number, the command's
  unreachability from the document window, and reveal dropping the page are all fixed. (accepted: fixed, W23.m4; closed below).

## Page-level durable links were broken at all three ends (W23.m4 — fixed 2026-07-30)
`archivereader://reveal?…&page=N` is the citation Notes stores for a quoted page (the reveal contract in
`execution-plans/archive-notes/00-overview.md` §8.3 requires the page be passed on). Three independent
defects meant the feature could not work at all — each fixed here, together, because fixing one alone still
leaves it broken:
- **You could not make one where you read.** `ArchiveReaderCommands` reached for the archive root + marker
  through `@FocusedObject NavigationModel` and disabled the command on `nav == nil`. A document window
  publishes only `.focusedSceneObject(model)` (its `DocumentViewerModel`) — there is no `NavigationModel` in
  that scene — so "Copy Archive Link to This Page" was **greyed out in the document window** and reachable
  only over the navigation window's preview sheet.
  Fix: `Core/ArchiveLinkTarget.swift` — the root + marker as one small `Sendable` value, published as a
  **focused value** by every window that shows a document, plus an app-level `ArchiveLinkContext`
  (`@StateObject` injected into both scenes) that carries it out of the navigation window. The nav model
  stays the single writer (`attach(linkContext:)` + a `rootStore.objectWillChange` sink), so a root switch or
  clear can never leave a document window citing the old archive. The command now needs only the focused
  viewer + that target. (accepted: fixed, W23.m4; ArchiveLinkTarget).
- **It wrote the wrong page.** The page was `imagePageIndex(pair:) + 1` — the pair's **image** page — no
  matter which pane you were reading, so citing a passage of OCR text produced a link to the scan.
  Fix: `DocumentViewerModel.focusedPageNumber`, the 1-based PDF page of the **focused** pane, degrading to
  the pair's image page when that pane holds no page (a trailing text-less scan, or a failed load). (accepted: fixed, W23.m4; focusedPageNumber).
- **Reveal threw the page away.** `revealAndSelect` stored it in `pendingRevealPage`; the only other
  mentions **cleared** it. The link selected the row and stopped — no viewer, no page.
  Fix: `goToPDFPage(_:)` (the exact inverse of `focusedPageNumber`: page → pair + pane, clamped, a vanished
  text page degrading to its image page), an additive optional `DocumentSelection.initialPage`, and
  `openViewerRequest`/`openViewerSelection` — a counter+payload request in the shape of the existing
  `requestScroll`, since `openWindow` is an Environment action only a View holds. A link **without** a page
  still just selects and scrolls; that is unchanged. (accepted: fixed, W23.m4; goToPDFPage).
- **Gotchas worth remembering:** (a) adding those two modifiers inline to `NavigationWindowView.body`
  overflowed the compiler's type-check budget ("unable to type-check this expression in reasonable time") —
  they live in one extracted `archivePageLinkBridge` modifier. (b) `make-gui-fixture.sh` now writes a
  `.archive-suite-root.json` with a FIXED GUID: with no marker at the fixture root there is no portable link
  identity, so every archive-link command stays disabled and the GUI lane could not test them at all.
  (c) `initialPage` is part of the `WindowGroup` value, so two links to different pages of one document open
  two windows (same page → the existing window is brought forward). That is the value-identity semantics of
  `openWindow(id:value:)`, and reasonable here: each cited page gets its own view. (accepted: by design, W23.m4; two links to different pages open two windows, as openWindow's value identity gives).

## A root's identity could be a GUID the disk never had (W23.m6 + W23.l3 — fixed 2026-07-30)
Every durable archive link names the root's `.archive-suite-root.json` GUID, so a GUID that isn't on disk is a
link that can never resolve. `ArchiveCore/Links/RootMarker` handed one out three ways, and the Reader minted
from it without knowing:
- **Unreadable was reported as absent.** `read` mapped ENOENT *and every other read failure* (permissions, I/O)
  to `nil`. "Absent" is precisely the answer that licenses minting a replacement, so a transient read error on
  an **existing** marker invited `ensure` to write a new GUID over it — orphaning every link already copied
  from that root. Now: `nil` means absent and nothing else; unreadable throws the new `.unreadable`, malformed
  still throws `.malformed`, and `ensure` refuses to fall through to creation on either. (accepted: fixed, W23.m6; nil means absent and nothing else).
- **A failed write returned the in-memory marker anyway.** Indistinguishable from a durable one, but it is a
  different GUID after the next launch. On a read-only volume / no write permission / disk full, links copied
  during that session were born broken. Now `ensure` throws the (declared-but-never-used) `.readOnly`, carrying
  the marker as `provisional` so a caller can say *which* identity was lost without being able to mint from it.
  Same for a write that reports success but leaves nothing readable. (accepted: fixed, W23.m6; ensure throws .readOnly).
- **First-time creation was a check-then-write race (W23.l3).** The absence check sat *outside* the write
  coordination, so two processes could both see absence and both write; the loser returned a GUID the disk had
  already replaced. The re-check, write and confirmation now happen inside **one** write claim, and a racer that
  finds a winner adopts it. (Codex confirmed this by inspection only — the new concurrency fixture reproduces
  it: under the old ordering 8 racers get 8 different GUIDs with one on disk, 3 runs out of 3.) (accepted: fixed, W23.l3; one write claim).

Reader side: `RootFolderStore.rootMarker` is now derived from `Core/RootMarkerState.swift` and is **nil unless
the identity is durable** — one choke point, so `copyArchiveLinks`, the W23.m4 focused link target and
`revealAndSelect` all refuse together instead of each remembering to check. It also degrades **visibly**:
`RootMarkerDegradation` keeps the four distinguishable reasons and each says what is wrong and what would fix
it. Copying a link from a degraded root used to say "Choose an archive folder first." with a folder plainly
open; an incoming link used to be blamed for pointing at a different archive.

Gotcha: `ensure` needs an **uncoordinated** `decode` helper for the in-claim re-check — calling `read` there
would nest a second `NSFileCoordinator` inside an accessor block and deadlock.

Notes' duplicate `RootMarkerStore.ensureMarker` writer was removed in W23.l3-fu. It now delegates to
`RootMarker.ensure`, so Notes first-touch creation shares ArchiveCore's coordinated re-check, write and disk
confirmation. The existing `MarkerError.corruptRootMarker` surface preserves the Notes caller contract for
malformed, unreadable and failed-write markers. Its scratch-backed concurrency test verifies simultaneous
Notes first touches all return the single durable GUID.

## Reactive/eventual-consistency bugs found by adversarial review (fixed 2026-07-05)
A multi-agent hunt for this bug class (the willSet + clobber category) confirmed four more:
- **`extendSelectionToDocumentRun` selection race:** the `Task` mixed a *pre-await* `selected` snapshot
  with the *post-await* current `self.selection`, so a selection change during the `await` polluted it.
  Fix: snapshot the selection before the await and bail if it changed (the selection is the epoch). (accepted: fixed, 2026-07-05; the selection is the epoch).
- **`ContentIndexer` dropped live updates:** `guard !running` silently dropped any index request that
  arrived during a running pass (new/re-OCR'd files never indexed). Fix: coalescing `pending` + relaunch
  on finish (a tag-only update does not restart a huge initial index, since `needsIndex` skips it). (accepted: fixed, 2026-07-05; coalescing pending and relaunch).
- **`ContentIndexer` uncancelled scope change:** the detached task was never cancelled (its
  `Task.isCancelled` check was dead code), so a stale-scope pass held the slot and the new root was
  never indexed. Fix: store + cancel the task on an empty-set (scope-clear) call, with a `generation`
  token so a superseded pass can't clobber newer progress/finish state. (accepted: fixed, 2026-07-05; a cancelled, generation-checked pass).
- **⌘O orphaned the Preview sheet:** the Selection-menu ⌘O stayed enabled over the preview and opened
  the doc window without dismissing the sheet. Fix: `openSelection()` clears `showingPreview` first. (accepted: fixed, 2026-07-05; openSelection clears the preview first).

### W40.root-marker — root identity deferred to the first archive-link copy (fixed 2026-10-18)

Choosing/reopening a folder used to create `.archive-suite-root.json` without a deliberate write action,
contradicting the Core Directive. `RootFolderStore` now only reads on adoption; navigation, viewer and
preview archive-link commands prepare the durable identity at copy time, after checking the live root
and partner scan. Read-only, damaged and unreadable identities refuse visibly without replacing the
clipboard or marker. Ordinary browsing, tag edits and copying never create it. Display-calendar and
image-source choices use a container-only identity before/after that first copy. If someone removes the
marker, browsing does not recreate it; another explicit archive-link copy makes a new GUID, invalidating
old links. The Core Directive and SPEC now disclose this single creation exception. Scratch regressions:
`RootMarkerDisclosureTests`; no real corpus used.

**Superseded 2026-11-06 by W40.root-marker-auto** (owner: "I'd rather this be possible automatically"):
choosing a folder creates the marker if absent, so Notes accepts the folder the Reader shows with no
link copy first. Reopening at launch still only reads; an archive-link copy still creates one for a root
that has none. A read-only folder opens with no marker (`.degraded(.notWritable)`) and copies refuse.

### W40.fix-reader-link-status-line — concise archive-link copy confirmation (fixed 2026-11-08)

Copy Archive Link now confirms only “Copied 1 archive link.” (or the plural), as requested in Reader
session 2, row 25. The opening instructions added by W40.fix-reader-link-paste-help remain in the README;
they no longer fill the status line. `RootMarkerDisclosureTests` checks the exact singular/plural messages
alongside the scratch link round-trip and marker, file-byte and tag preservation checks.
