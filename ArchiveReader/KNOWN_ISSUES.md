# Known Issues & Gotchas

Running log of quirks, risks, and things verified/unverified. Keep current.

Fixed and closed entries, and the July–October 2026 fix logs, are archived in
[`KNOWN_ISSUES_HISTORY.md`](KNOWN_ISSUES_HISTORY.md) (W49.reader-docs-launch-hygiene, 2026-11-25). This file
keeps the open limits, measured costs, verified facts, deferred hardening, open risks and environment notes,
and any entry whose disposition is still `(queued: …)` or `(asked: …)`.

## Finder tags are no longer mirrored by default (W49.storage-finder, 2026-11-27)

- **New Processor output carries no Finder tags unless mirroring is on.** The owner's call (W49.storage-finder-owner-ok:
  off everywhere by default) means a PDF the Processor files has its fields, read state included, only in its catalogue
  record. A folder read without File ▸ Use Catalogue Companions for This Folder lists only Read- or Unread-tagged PDFs,
  so such output does not appear there until that mode is turned on or the Processor's Settings ▸ Output ▸ Mirror
  archive fields to Finder tags is on. The Reader's own mirroring, Import or Re-publish of a Finder edit and an undoable
  Remove Suite Tags follow in the same item (queued: W49.storage-finder).

## Accessibility audit of the preview and document windows (W49.ui-fails-under-coverage, 2026-11-27)

- Both thumbnail sidebars put an unnamed element (type other) around each page thumbnail button, which is labelled
  itself. It is the row host of SwiftUI's `LazyVStack`: in guest probes it went only with a plain `VStack`, which
  would make and fetch a thumbnail for every page of every open file at once, and stayed with every lazy-stack
  variant tried. `AccessibilityAuditUITests` exempts it on those two screens. (asked: W49.reader-thumb-row-host-owner-ok)
- While any text field has the focus, the audit reports one unnamed "Parent/Child mismatch": AppKit's shared field
  editor, seen with the find field, the OCR search and the plain `NSTextField` file-name filter alike, and gone when
  the focus leaves. `AccessibilityAudit.focusedTextFieldOrphan` exempts it on the find-bar screen alone (the find
  field's missing description and the date badge's role were fixed by W49.reader-audit-find-bar-inspector-shown).
  (accepted: a platform fact, AppKit's field editor and not an app element)

## Tag changes across the apps — the limits (W40.tag-rename-suite, 2026-11-26)

- A rename is recorded only when the granted folder has a durable root marker (`RootFolderStore.rootMarker`); a root
  whose marker could not be written renames its files and tells Notes nothing (accepted: the marker is the archive's
  identity, and without it Notes cannot tell which archive a record belongs to; `RootMarkerState` already reports the
  degraded identity).

## Moving the archive folder (W49.reader-root-movable, 2026-11-23)

On the same mounted volume, Reader can reopen the same adopted directory at a new path and read flags and
page turns from its verified companions. The OCR index and page pictures use the marker, local directory
identity and relative path. Unchanged files reuse their text and pixels. A copied folder gets its own cache
and its own adoption choice, even when it carries the same marker. A renamed leaf gets a fresh cache row, and
settled scans retire the disappeared search path. A PDF-only rename requires the explicit companion repair.

The first use of the scoped cache builds it once. The move needs a filesystem that can establish the same
local directory identity. A cross-volume copy starts a separate cache. Before moving a root adopted by an
older build, open it at its previous path once so Reader can carry forward the local adoption setting. A
folder moved before that upgrade can be adopted again. The PDF and companion still carry their own identities.
Legacy `FlagStore` flags and `PageTurnStore` turns keep their absolute-path behavior.

## Dating a folder's documents from its confirmed date — the limits (W47.ct-folder-date-reader, 2026-11-19)

Shipped: setting or confirming a folder run's date in the Container section offers to date the run's documents that
are eligible under the owner's folder-date rule (`SPEC/containers.md` §The folder-date rule). A date from a
stamp counts as a document date and stays in place (W49.folder-date-stamp-first). The tags go
through `TagWriter` in one undo group (Edit ▸ Undo Tag Change); the `Date evidence:` value is kept in the folder's
`.archivesuite/item-fields.json` and the Checks name the folder for those dates.
- **Choosing Not Now does not ask again until the folder's date is edited again**; its Edit ▸ Confirm asks again
  (accepted: the user's own answer to the offer; owner call 21, 2026-11-19, asked only that the dates follow the
  folder's, W49.reader-folder-date-undo).
- **A folder's date removed and typed again in Finder while the Reader is not running reads as the folder's.** While
  it runs, its library watcher sees the date change and retires the record for good (W49.reader-folder-date-undo-fu2);
  a removal and retyping both made while it is closed (or both inside one full rescan) leave the file's tags as they
  were, so a later folder-date edit offers to replace or remove that date (accepted: a platform fact, Finder keeps no
  history of a tag edit and the tags read the same afterwards; a removal while it is closed and a retyping while it
  runs is seen).
- **The offer is made only from the Container section.** A folder date written into the container file elsewhere
  (Live Capture's Finish, another app) dates nothing already written until it is set or confirmed here (accepted: the
  offer answers the user's own edit; Live Capture dates its own session's documents, W47.ct-folder-date-live).
- **A placeholder PDF (not on disk) is never opened**, so a date it carries is treated as its own text's and stands;
  one with no date is dated (accepted: the Core Directive forbids materialising a placeholder).
- **The evidence record is keyed by file name**: a renamed file loses it and its Checks fall back to page 2's evidence
  (accepted: as the item-field values and container runs are keyed).

## Editing containers — the limits (W47.ct-reader-edit, 2026-11-19)

Shipped: the Inspector's **Container** section edits. Each value has an **Edit** menu (Change…, Confirm, None Here,
Remove Your Value, Use a Standard Name…, Stop Using the Standard Name), and **Add** gives a field the file lacks. An
edit goes where the shown value lives (`ContainerEdits.target`), and the row says which files it reaches: the run
that gives it, else the live run of its level, else a new run at the file when the folder's runs of that level
start later, else the folder's own values. With several files selected, **set for selection** gives one field one
value for them and no others, splitting runs at the selection's ends. The folder's **warnings** are listed under
the section, each with Show. Writes only `<folder>/.archivesuite/containers.json` and the nearest
`container-names.json`, each read fresh and written with its stamp (`NavigationModel+ContainerEdits`). A value the
user set ends its disagreement warning (`SPEC/containers.md` §Warnings). Contract: `SPEC/containers.md`.
What it does not do, deliberately or not yet:
- **Undo is Edit ▸ Undo and Redo** (W47.ct-reader-edit-undo; W49.reader-undo-menu-names): ⌘Z and ⇧⌘Z take the newest
  change of any kind, a container edit, a tag change or a turn, and the item names it ("Undo Container Change").
  Undo puts back what each touched file held, read fresh, and leaves alone, with the reason, a file that changed
  after the edit; a replaced label read comes back with it. Where there was no file, undo leaves an empty one, since
  the store deletes nothing: an empty container file reads as none, and an empty standard-names file is only ever at
  the folder the Reader wrote it in, so it hides no names further up for the Reader (accepted: no delete in the
  store's write class). Undo and Redo run on the main thread, so the step that reverses them is registered in
  place; a folder another app holds locked can delay one by up to 5 s (accepted: the files are small and the lock
  short). The history is the window's; an edit made under another archive root is not undone after the root
  changes (accepted: the step names files of the old root).
- **A newer container file is never set aside.** A `containers.json` or `container-names.json` of a newer
  `schemaVersion` stays refused with the reason, and no set-aside is offered for it, so an older build cannot erase a
  newer one's values. An unreadable or dropping one is offered for setting aside (W49.reader-ct-set-aside).
  (accepted: SPEC/containers.md §Setting aside, a newer document is never set aside).
- **An edit to the folder's own values reaches the folders inside it** and outranks their label reads, as the SPEC's
  precedence says (user, then label, then path). The row says "every file in this folder and the folders inside
  it". It is chosen only where the folder has no run of that field's level. (accepted: the SPEC's precedence, user then label then path, SPEC/containers.md).
- **Set for selection** takes every field, a date and other marks included, for any number of files
  (W49.reader-set-selection-limits): a date or other marks goes in folder runs, the deepest level, so the folder-date
  rule reads a date set there. It takes the files in each folder's order on disk, so a file the list does not show
  still keeps its value, and edits each folder in one pass and one write. Across several folders it is all or
  nothing: every folder's file is checked before any is written, and a write failing partway puts the folders
  already written back and says so; one changed again in that moment is named as not put back (accepted: putting
  it back would overwrite the other app's change, which the Reader's Core Directive on file safety forbids). A date set this way offers to date the
  documents of every folder run it is in, in every folder, as one offer that names the folders (at most 10, then a
  count), dates them in one ledger group (one Undo) and rechecks each run's date at the answer; an Undo or Redo of the
  edit offers for every run whose date it changed (W49.reader-set-selection-date-offer). A selection scattered through one folder makes
  two runs per stretch of neighbours; a container file holds up to 64 MB (SPEC §The container file), which every other
  file of the corpus's largest folder (2.5 MB) and every field at every level for every file there (27.5 MB) both fit,
  and each folder's size is checked when it is prepared, so a refusal writes nothing (W49.ct-file-size-cap).
- **Warnings: disagreements and long unmarked runs only** (`ContainerInference.warnings`). The Inspector lists the
  selected file's folder; the Library health popover lists every folder's, each with its folder and a Show that
  reaches a file the list hides by lifting the folder and filters as Show in All Files does, at most 200 listed and
  the rest counted (W49.reader-ct-warnings-all). The marker warnings (a photo inside your run, a marker with no read)
  come from Route A as label reads are applied, which the Reader does not do. (accepted: the marker warnings are
  Route A's, in the Processor; the Reader applies no label reads).
- **Stop Using the Standard Name removes the whole entry**, with every wording it gathered and anything it filled in
  other fields. (accepted: an entry is one name with its wordings; a single value is changed with Change… instead).

## Containers in the list — the limits (W47.ct-reader-view, 2026-11-19)

Shipped: a **Container** column (box, folder and folder title, else the collection; ⚠︎ where sources disagree;
sortable; offered once a file has a value), a **Containers** list in the filter bar (repository, collection,
accession, series and container, with type-to-filter and counts narrowed by the other selected facets), the Inspector's
**Container** section (each value with its check state, every disagreement with its candidates), and the **folder
levels** sheet, offered once per root after its scan settles. File ▸ Container Levels… edits the map governing
the selected folder. Save writes its `.archivesuite/container-levels.json`. Advanced Search offers the same
searchable list, with counts scoped by the other container facets required by its rules (W49.reader-facet-list).
Contract: `SPEC/containers.md`.
What it does not do, deliberately or not yet:
- **Editing is the section above** (W47.ct-reader-edit). The Reader works out no runs from marker photos itself:
  Route A needs label reads (`W47.ct-processor-capture`, `W47.ct-backfill`). It shows and edits the runs that
  container files already hold. (accepted: Route A reads labels in the Processor, W47.ct-processor-capture and W47.ct-backfill; the Reader edits the runs they write).
- **Container files changed by another app are read again on the next change to the listed files, a Rescan or a
  relaunch**, not the moment they change: the catalog is rebuilt when the listed paths change. (accepted: the catalog follows the listed files; a Rescan reads a changed container file at once).
- **A container rule is skipped until the catalog for the open root is built** (W47.ct-reader-facet-rules), like a
  text rule whose index answer has not come back: a smart folder with one lists and counts its other rules' files
  for that moment after launch or a root change. It compares the facet's shown value by `ContainerNames.key`, the
  same value the Containers list offers, so a collection matches by its title when it has one, else its number. (accepted: as a text rule waits for its index answer; the rule applies once the catalog is built).
- **The narrowest window scrolls sideways** once Container is shown, as with Capture marker: the default columns
  already take 656 of its 668 pt (`TableColumnFitter`). (accepted: the default columns already fill the narrowest window; a column can be hidden from the header menu).
- **The tree root is the archive's main folder**: the granted folder, or its "Archival Photos" folder when it holds
  one (`ReaderArchiveLayout`). Files outside it (the JPEG partner tree) have no container. (accepted: the main folder is the container tree by design, ReaderArchiveLayout; a JPEG original's partner PDF carries its container).

## Field checks in the Inspector — the limits (W40.reader-field-status, 2026-11-18)

Shipped: the Inspector's **Checks** section lists one file's dates and page-2 item fields, each Checked (green),
Unchecked (yellow) or Unchecked, lower confidence (red), with its own label and symbol and a tooltip giving the
source and the measured figure; "Mark checked" / "Uncheck" writes or removes a `Checked <Field>` tag through
`TagWriter`, and typing a date checks it. Contract: `SPEC/tag-format.md` §Field checks.
What it does not do, deliberately or not yet:
- **The Processor's Mac item fields carry lower confidence** (W47.wh-item-fields-mac-fill). The Checks show the
  Mac models' suggested kind, byline and publication date. The tooltips show bench estimates for the exact kind,
  complete byline and full issue date, with ranges that allow for fills outside the owner’s check sample
  (W46.p18-mac-field-precision). Confirm each using Mark checked or enter a correction
  (accepted: lower-confidence fill, owner call 23, 2026-11-19).
- **Item fields are corrected beside the file, not in it** (W40.reader-item-field-edit, 2026-11-19). Each item field
  has an Edit menu (Change…, None, Remove Your Value) and Add Item Field gives one page 2 lacks; for several selected
  files one value, None or Remove is given to them all, all or nothing, one Undo (W49.reader-item-fields-follow). The
  value goes to the folder's `.archivesuite/item-fields.json` and is shown checked, page 2's value in the tooltip. Page 2
  is never rewritten. Any file under the folder the Reader was given can be corrected, the boundary its tag writes keep.
  The entry is keyed by file name, so renaming a file in Finder leaves its corrections behind and a later file given
  that name takes them. The adopted catalogue has a guarded same-folder repair for a verified pair
  (W49.reader-item-fields-rename). Reader controls and the switch to the catalogue are queued in W49.storage-reader.
  Legacy names are compared composed, so two files whose names differ only in Unicode composition, possible on some
  network volumes, share corrections (accepted: a platform fact: APFS and
  HFS+ take such names as one name, and Finder shows the two alike). A
  `Checked <Field>` tag set before the correction stays and speaks for page 2's value again once the correction is
  removed (accepted: SPEC/tag-format.md §Field checks: a check names the field and never holds the value).
- **Corrections reach search and the Item fields column** (W49.reader-item-fields-search, W49.reader-item-fields-follow).
  The content index keeps page 2's item fields and the corrections beside each file; the OCR text box and an Advanced
  Search OCR text rule match a corrected value, a hit on a correction alone shows a marked snippet of the correction,
  and the Item fields column (offered once a file has one) shows what the Inspector shows and sorts by that text, files
  with none last. A correction made in this Reader is indexed at once; one written by another app or another copy of the
  Reader is picked up when the watcher sees its folder's file change. Page 2's own value stays searchable too, since it
  is in the page's text (accepted: the text page is the file's searchable OCR text, which the Reader never rewrites). A
  query of stop words alone keeps a snippet of the text without a mark when only a correction matched (accepted: such a
  query is read by a scan of the text, W40.fix-reader-fts-snippets, measured at up to a second a row with `snippet()`).
  In an adopted catalogue folder, Improve OCR and its Restore move the file's record to the new text and keep every
  correction, clear and check (W49.proc-item-fields-rerun). In a legacy folder the Processor does not read corrections:
  a later run that rewrites page 2 leaves them beside the file, still shown over the new page 2 (accepted: owner call
  24, 2026-11-20, put corrections in the catalogue record; a legacy folder keeps them shown, not lost).
- **Container fields have their own Inspector section** (W47.ct-reader-view), with the same badge and no check
  button: a container value is confirmed or corrected from its Edit menu (W47.ct-reader-edit). (accepted: by design, W47.ct-reader-edit; a container value is confirmed by being the user's own).
- **A group selection counts the checked dates** and checks them all at once; item fields are listed one file at a
  time. (accepted: item fields are per document, so a group has no one value to show).
- **A check is not tied to the value it checked.** It names the field. Another writer that changes the value
  without the user (a copied source tag set, a later Processor rewrite of page 2) leaves the check standing. (accepted: SPEC/tag-format.md §Field checks: a check names the field and never holds the value).

## Improve OCR in the Reader: flag, filter, hand-off, receipts — the limits (W44.reocr-reader, 2026-11-13)

Shipped: Tags ▸ Flag as Poor OCR / Remove Poor OCR Flag (⌃⌘P, also in the row menu and the document window),
Sort & Filter ▸ Show Poor OCR Only, Tags ▸ Improve OCR…, File ▸ Connect Improve OCR Folder…, the text page's reader
and Kind in the document window's status bar, and receipt-driven re-indexing. Contract: `SPEC/improve-ocr.md`.
What it does not do, deliberately or not yet:
- **The index's freshness key is the date, inode and size** (W44.reocr-reader-freshness), so a replacement that
  keeps the date is read again without its receipt, and a tag edit (an extended attribute written in place) is not.
  What still passes as unchanged: a rewrite in place, same inode, that keeps both the size and the date. No suite
  writer does that (a Processor publication changes the inode, `SPEC/improve-ocr.md`); a receipt or a rebuild fixes it. (accepted: no suite writer rewrites a file in place keeping its size and date; a receipt or a rebuild covers one that does).
- **Generic edits that name `OCR Poor` run on the main thread**, as every Reader tag write does, and wait at most 1 s
  for the file's flag lock (`SPEC/improve-ocr.md` §3 states the exception). The Flag command runs off it. (accepted: SPEC/improve-ocr.md §3 states the exception; the wait is bounded at 1 s).
- **Never connected, a generic edit of the tag is not recorded**, like an edit in Finder; the Flag command asks for
  the folder first. Connected but unusable (moved, replaced by another store, no root marker): every write that names
  the tag is refused with the reason, and unrelated edits go ahead. (accepted: unconnected, there is no store to record in, as for an edit in Finder; unusable, the write is refused with the reason).
- **The command's direction comes from the list's rows** (flag unless every target is flagged), which lag a change
  made in another app until the watcher sees it; the write itself re-reads the file. (accepted: the write re-reads the file, so a lagging row changes only which way the command goes).
- **Receipts are read on library changes, on activation and every 20 s**; the Processor sends no wake-up. Seen IDs are
  kept in the Reader's own defaults, all of them; receipts stay in the shared folder. An index pass already running
  when a receipt is handled can write the file's old text back after the row was dropped; it carries the old file's
  inode, so the next pass after the watcher sees the replacement reads the file again. (accepted: the Processor sends no wake-up; a stale row is read again on the next pass after the watcher sees the replacement).
- **A reload after a receipt rebuilds the document's panes** on the same page pair; zoom and find highlights in that
  window start again. (accepted: the file changed under the panes, so they are rebuilt).
- **Not exercised by automation:** the real Launch Services launch of Archive Processor (no Processor is installed in
  the test VM, so `ImproveOCRUITests` uses the DEBUG hand-off recorder) and the Connect panel itself (the test connects
  the fixture's folder by path). The hand-off link and manifest are unit-tested against the Processor's decoder rules. (accepted: the test VM has no Processor installed; the link and manifest are unit-tested against the Processor's decoder rules).

## PDF header metadata and format ambiguities (W44.reocr-spec, 2026-11-07)

Core now uses one structured parse for stripping and header metadata; `Kind:` and reader provenance
are per physical text page, with unknown/mixed summaries for merged files. Reader's existing FTS
still indexes all text including headers; its existing stripped display remains page 2 only. The
feature's menus, filter, hand-off and completion refresh shipped in W44.reocr-reader (entry at the top).

PDFKit can omit the blank separator below the header. A body whose first line looks exactly like the
next optional header field can therefore be interpreted as metadata. A filename indistinguishable
from provenance has a similar prefix ambiguity. Later body lookalikes stay text; malformed provenance
is retained raw, never repaired from a later body line. Missing/invalid/repeated/late Kind stays unknown.
These limits are pinned by `ArchiveCoreTests/ReOCRHeaderTests`; they are not classifier evidence or
proof that a file has a valid image/text pair. The normative grammar is in
[`SPEC/tag-format.md`](../SPEC/tag-format.md#2-page-pdf-structure).

## Find in the document window: what "both panes" can and cannot do (W40.fix-reader-find-both-panes, 2026-11-05)

A find hit is one occurrence, selected in both panes of its page pair and stepped together; the
JPEG original gets boxes at the PDF image page's match positions (a page overlay — `PDFPage.copy()` shares
annotations with the original and removing one from the copy leaves it there, measured). Since
W49.reader-find-word-align (2026-11-20) the two panes' matches are paired by lining the pages' words up
(`FindWordAlignment`: a diff over case/diacritic-folded words; a match on a word the diff could not line up
pairs with the other page's unpaired match in the same stretch between shared words), not by ordinal, so a
word the image page's text layer split or missed no longer shifts the later hits: it is a hit of the text
pane alone. Cost, measured in the unit bundle: a 300-page document with 9,908 matches, 0.558 s for the find
alone and 0.568 s with the alignment; two unrelated 1,500-word pages 0.046 s. Limits that stay:
- **An occurrence the image layer lacks among identical neighbours is ambiguous.** When a word is repeated
  and one copy is missing from the layer with nothing between to tell them apart ("zulu image zulu" against
  "zulu image zulu zulu"), the alignment may treat a different copy as the missing one, and within a stretch
  the diff could not line up, matches pair in order. (accepted: the two texts carry nothing that tells the
  copies apart; the diff picks one of the equally good alignments).
- **An image page with no text layer gets no highlight** (the test corpus's image pages have none): there are
  no positions to draw from. The hit still shows on the text page. (accepted: an image page with no text layer has no positions to draw from).

## ⚠️ LIMITATION (W37.dual-date, 2026-10-06) — the year filter does not say which date matched

The Sort & Filter year range matches a file's own date OR its `Sent With` date (each value meeting both
bounds) and lists the file once. The Date column shows both dates (`Nov 3, 1957 · sent Mar 12, 1958`), but
nothing highlights which of the two put the row in the result. The sent-with date is edited in the ⌥⌘I Inspector's
Date section, the one date editor (owner, 2026-10-12; `W40.fix-reader-sent-with-date`, 2026-10-29).

The filter bar was crowded in a narrow window. Since W40.fix-reader-filter-bar (2026-11-05) the name and OCR
fields have a row of their own under the query controls, with the chips for what is in effect below them, so the
first row holds only read state, quality, tags, dates and the trailing buttons, which `FilterBarLayout` still wraps.

## ⚠️ LIMITATION (W24.jpeg1, 2026-09-26) — duplicate JPEG stems need a known collection mapping

Reader resolves exact mirrored paths and unique stems across relocated folders. If the same stem occurs in
multiple JPEGS collections and the PDF's collection has a different folder name, Reader has no verified
cross-tree mapping to identify which candidate belongs to that PDF. It leaves the partner unresolved and
hides the switch rather than infer from a shared prefix or similar-looking folder name. The Core resolver
can use an explicit candidate-relative collection context when a caller has one; do not add a folder-name
heuristic here, because a wrong match would display another collection's archival scan.

## 📏 MEASURED (`W26.verify`, corrected by `W26.verify-fu1`, 2026-08-10) — what Spotlight-free discovery costs at 150k

Recorded because the de-Spotlight plan's projection (~12 s at 150k) is **not** what a measurement says, and
the plan is being deleted. Synthetic **scratch** corpus, 150,000 files / 124,647 PDFs / 652 dirs / depth 7 /
115,999 Read-or-Unread-tagged; never the real corpus. Harness: `ops/scale/run-scale-verify.sh`.

> ⚠️ **Every per-file absolute below is quoted from a sample taken in the QoS band the app actually walks
> in** — `LibraryScan.onDedicatedThread` runs discovery on a dedicated `.utility` thread. That qualifier is
> load-bearing and is the whole of `W26.verify-fu1`: this section's first version quoted **248 µs/file**,
> which was measured inside a `swift test` process an unattended daemon session had clamped to
> `QOS_CLASS_BACKGROUND`. Under that clamp every filesystem primitive — including a bare `stat(2)`, which
> contains no code of ours — costs ~6× more. **Do not quote a per-file number from a lane that did not
> report `quotable=yes`.**

- **Cold full walk: 6.1 s** (40.8 µs/file) — one pass, in the background, off the main actor. That is **half**
  the plan's ~12 s projection, not 3× it; the earlier "37 s / ~3× worse" reading was the clamp. Against it:
  Spotlight's answer for the owner's real corpus on 2026-08-04 was **zero rows**. (accepted: measured, W26.verify and W26.verify-fu1; a figure, not a defect).
- **Warm start: 0.460 s** for 115,999 cached rows (4.0 µs/row), matching the plan's 4.3 µs/row projection.
  This is the number a user experiences on every launch after the first. (accepted: measured, W26.verify and W26.verify-fu1; a figure, not a defect).
- **Fingerprint-only pass** (warm start's first phase): **0.69 s** (4.6 µs/file). **Steady revalidation: 3.4 s**
  — the fingerprint pass plus the trustworthy tag reads the cache cannot vouch for. (accepted: measured, W26.verify and W26.verify-fu1; a figure, not a defect).
- **Cold index persist: 1.58 s** for 115,999 rows (13.7 µs/row). **Cache size: 43.2 MiB, 390 B/row**
  including WAL/shm. **Footprint: +277 MiB** across the Reader lane's full cold-walk-and-persist sequence. (accepted: measured, W26.verify and W26.verify-fu1; a figure, not a defect).
- **Vs the API pattern it replaced: 1.2–1.5×** (three runs on the same tree: 1.19×, 1.32×, 1.48×) — the
  right side of the +15% the plan predicted from `CorpusWalker`'s extra `stat(2)` per entry, but noisier
  than one run suggests. ⚠️ Two cautions. Compare only passes that are equally *warm*: timing the walker
  first and the old path second reports a spurious 1.36×, because the first pass warms the cache for the
  second. And this ratio is the one figure here that has only ever been taken **in the clamped lane** — the
  clamp taxes `stat(2)` heavily, which is exactly where the walker's extra cost is, so if anything it
  overstates the penalty. The shape is trustworthy; the exact factor is not. (accepted: measured, W26.verify and W26.verify-fu1; a figure, not a defect).
- **Discovery writes nothing** — every path's inode, size, mtime, ctime and xattr digest identical before
  and after, measured by a separate process (150,650 paths, and the hostile sibling too). (accepted: measured, W26.verify and W26.verify-fu1; a figure, not a defect).
- A cancelled pass is `cancelled`, not `completed`, not `isClean`, and prunes nothing; a cancelled warm
  revalidation leaves `asOf == nil` with every row preserved. (accepted: measured, W26.verify and W26.verify-fu1; a figure, not a defect).
- **The QoS cliff is `.background`, not "any non-default band."** Measured on the same tree in the same
  process: `.utility` 40.8 µs/file vs `.userInitiated` 42.6 µs/file — no difference worth the name. It is
  the background clamp alone that costs ~6×, so a shipping change that moved discovery to `.utility` from a
  higher band would cost nothing, and one that let it fall to `.background` would cost everything. (accepted: measured, W26.verify and W26.verify-fu1; a figure, not a defect).

## 📏 MEASURED (`W40.reader-scale-measure`, 2026-11-11) — one change still costs the whole library: tag changes, selection and the document window's file switch FIXED, S2

The chain behind one change, timed end to end at 115,999 rows with 10 smart folders, live FSEvents, at -O (Debug in
brackets). Harness: `ops/scale/run-reader-at-size.sh --only chain [--optimized]` (`ReaderChainAtSizeTests`); stages
are `os_signpost` intervals (`ReaderStages`, subsystem `com.archivereader.app`, category `Stages`), so Instruments
shows the same chain in the running app. Evidence: `verification/evidence/reader/W40.reader-scale-measure.md`.

- ✅ **A foreign tag change on one file** was visible after 6.9 s, with 7.4 s of main-thread busy time and a 6.0 s
  stall [10.7 s, 12.9 s, 7.2 s]: `ArchiveLibrary.apply` re-sorted every path on main (5.9 s), then all 10 smart
  folders were counted twice, row by row on main (1.2 s). **Fixed 2026-11-11 (`W40.fix-reader-change-incremental`):
  19 ms busy, a 13 ms stall, visible in a median 309 ms** (the wait is FSEvents' delivery, not the Reader). The library patches the changed rows through a row index and
  publishes a `LibraryChangeSet`; the model patches the list, the selection and the counts from it, and no indexing
  pass, format-status read or second recompute starts for a tag change. Smart-folder counts run off main. (accepted: fixed, W40.fix-reader-change-incremental; the measured cost before and after).
- ✅ **A Reader write on 1 or 20 files in a smart folder** was visible after 0.7–0.8 s with 1.5–1.8 s busy [2.7–3.0 s,
  5.7–6.3 s]. **Fixed 2026-11-11: 4.5 and 7 ms busy after TagWriter, visible in 47 and 86 ms.** TagWriter's own share
  (verify, two full fsyncs, audit: 30 ms for 1 file, 67 ms for 20) is unchanged and is now nearly all of it.
  Still on the whole-library path, correct and not budgeted: a change that adds or removes a row, a content change,
  a subtree read. Evidence: `verification/evidence/reader/W40.fix-reader-change-incremental.md`. (accepted: fixed, W40.fix-reader-change-incremental; the changes left on the whole-library path are correct and rare).
- ~~**An arrow key or ⇧-arrow: 105–158 ms busy whatever is selected**~~ — fixed by `W40.fix-reader-selection-at-size`
  (2026-11-11): 0-7 ms at -O, with the inspector shown. Evidence: `verification/evidence/reader/W40.fix-reader-selection-at-size.md`. (accepted: fixed, W40.fix-reader-selection-at-size; kept as the measured record).
- ~~**Next file in a document window with 5 open: 245 ms**~~ — fixed by `W40.fix-reader-viewer-switch` (2026-11-11):
  30 ms main-busy and visible in a median 32 ms at -O. The 245 ms was the lane drawing the page on the main actor;
  sampled in the VM with real PDFViews, PDFKit draws tiles on its own queue, so the real cost was 150–500 ms of blank
  page. The image page of the open file and both neighbours is now drawn ahead and shown until PDFKit's tiles land,
  and the neighbours (and their JPEG originals) are opened off the main actor. A jump to a file that is not a
  neighbour still waits about 200 ms for its pixels, with the main thread free. Evidence:
  `verification/evidence/reader/W40.fix-reader-viewer-switch.md`. (accepted: fixed, W40.fix-reader-viewer-switch; a jump past the neighbours waits for PDFKit, with the main thread free).
- **Memory: no leak in the model.** Over 200 edits and 200 file switches the footprint stops growing within 20 steps
  (+228 MB at -O, +72 and +142 MB in two Debug runs), and a quiet minute returns nothing. The growth is freed whole-library copies kept by
  the allocator (about 370 MB of Malloc Small reclaimable). ✅ Since `W40.fix-reader-change-incremental` (rows patched
  in place; `ArchiveFile` shares its fields, so a whole-list copy is a pointer per row) the same run ends where it
  started (484 against 485 MiB). The views' memory, measured in the VM with real PDFViews on the real sample
  (`W40.fix-reader-viewer-switch`): 200 switches with 5 open end within 29 MiB of their start, so a fresh PDFView per
  page does not accumulate IOSurface; the owner's 332 MB at 6 h 19 min is not reproduced by switching alone. (accepted: measured, W40.reader-scale-measure and W40.fix-reader-viewer-switch; no leak in the model or the views).
- **The owner's builds are now Release:** `ArchiveReader/launch.sh` builds and runs Release (-O; `--debug` for
  Debug), since -O shows a change 1.5–4× sooner. The Reader's Release build had been carrying `get-task-allow`. It no
  longer does. Notes and the DMG check: `W40.release-no-debug-entitlements`. (accepted: a fact about the owner's builds, W40.release-no-debug-entitlements).

## 📏 MEASURED (`W40.d7`, 2026-10-15) — the Reader at corpus size: two S2 stalls, both fixed 2026-10-31

Full numbers, method and caveats: `verification/evidence/reader/W40.d7-at-size.md`. Harness:
`ops/scale/run-reader-at-size.sh [--optimized]`. Quote its `-O` run as the shipped cost; the unit bundle is
Debug otherwise, and Swift-side sorting is 1.5–3× slower there.

- **Discovery** re-measured against the section above: within ~10% (cold walk 6.98 s, warm start 0.48 s, steady
  revalidation 3.70 s at 150k). The Reader lane's footprint rose to +409 MiB from +277 MiB; not explained. (accepted: measured, W40.d7; the footprint is the one-off cold walk's, and the model's memory was measured since with no leak (W40.reader-scale-measure)).
- **Fixed 2026-10-31, S2 — `W40.fix-reader-list-recompute-at-size`.** At 115,999 rows every tag edit re-sorted
  everything on the main thread: 1.56 s per edit, 0.96–5.5 s per sort change. Now **139 ms per edit** and 62–171 ms
  per sort change at `-O` (decorated sort on cached collation ranks, stored native-UTF-8 paths, byte-keyed hashing,
  no per-edit table dictionary); `ReaderAtSizeTests` asserts it. Still paid once per session: a sort's first sight
  of its keys, 0.74 s for 116k names. Evidence: `verification/evidence/reader/W40.fix-reader-list-recompute-at-size.md`. (accepted: fixed, W40.fix-reader-list-recompute-at-size; a sort's first sight of its keys is paid once per session).
- **Fixed 2026-10-31, S2 — `W40.fix-reader-fts-snippet-stall`** (`87201576`): snippets leave out stop words, seek each
  hit by rowid and stop after 250 ms; the long-body reproduction went from 2/60 to 60/60 previews in budget. Re-run on
  the sample lane by `W40.fts-snippet-sample-rerun` (2026-10-31): 270.6 ms at 102,478 rows, every hit previewed. What was measured:
  `searchRanked("Bureau of the Budget")` took **41.7 s** over
  102k rows (the sample's real text, replicated); distinctive single terms take 11–146 ms. It runs on the
  `ContentIndex` actor, so later queries queue behind it. (accepted: fixed, W40.fix-reader-fts-snippet-stall; re-run on the sample by W40.fts-snippet-sample-rerun).
- **Fixed 2026-11-05, S3 — `W40.fix-reader-fts-snippets`:** the 250 ms budget above left hits without a snippet
  (owner, Reader session 1), and every hit past the 300th never had one. They are now filled in, off the main thread,
  as their rows are drawn; a query of stop words alone is quoted by scanning the body (`snippet()` on `the` took
  0.9 s for one long body). At 102k every hit with body text among the first 1,000 has one; a photo (no body) still
  shows only its name. Evidence: `verification/evidence/reader/W40.fix-reader-fts-snippets.md`. (accepted: fixed, W40.fix-reader-fts-snippets; a photo has no body text to quote).
- **Fine at size:** filters 7–33 ms, the health popover's `dataQuality` 30 ms, scrolling's cell work 2.7 ms a
  row, index build 1.7 ms per real PDF (5,268 in 9.2 s; ~3 min projected for the corpus [I]). (accepted: measured, W40.d7; within budget).

## Verified facts to rely on (2026-07-04)
- Writing `.tagNamesKey` while keeping the color-name token (`Red`/`Purple`) and **not** touching
  `.labelNumberKey` **preserved** `labelNumber` (tested on a Red-labeled scratch copy, local APFS).
  Still verify `labelNumber` after every write and restore on drift. (accepted: a verified platform fact; the writer verifies the label after every write).
- `FileManager.setAttributes([.creationDate:])` accepts historical dates (1938, 1850) but **clamps
  below ~1677-09-21** (int64-ns-since-1970). → Do NOT use creation date as the chronological sort
  key; sort by a date derived from the tags (no range limit, medieval-safe). (accepted: a verified platform fact; the sort key comes from the tags).
- ~~Spotlight tag queries are fast (compound 3-facet over 6,941 files ≈ 0.38s) and scale.~~
  ⛔ **RETRACTED 2026-08-07 (`W26.docs`) — this "verified fact" is what the 2026-08-04 incident falsified,
  and it is exactly the kind of fact this section exists to be trusted on.** The 0.38 s was measured on a
  *healthy* index and says nothing about the failure mode that matters: a dead Data-volume index answers
  just as fast, with **zero rows**, and reports no error — 1,849 correctly-tagged PDFs became *"No
  Read/Unread-tagged PDFs were found in this folder."* Speed was never the risk; **unfalsifiable emptiness**
  was. Replacement fact, measured read-only 2026-08-04 on the real corpus: a single-threaded
  `FileManager.enumerator` walk of 123,028 files / 102,478 PDFs at depth 7 takes **10.15 s**, and it cannot
  be silently empty. Discovery is that walk now (`ArchiveCore.CorpusWalker`, `W26.walk1`/`walk2`). (accepted: retracted, W26.docs; discovery is the file walk now).

## macOS tag/label coupling (verified 2026-07-05)
- A **`Red`/`Purple` tag token is inseparable from its Finder color label**: setting the token makes
  macOS auto-assign label 6/3, and there is no "Red subject with no label" state. So `TagWriter`'s
  color-clear removes the token matching the *actual* label (correct), and a document whose subject
  is literally "Red"/"Purple" will always appear color-labeled. Non-color subjects are unaffected. (accepted: macOS couples the token and the label; a subject literally Red or Purple is always labelled).
- **Do not run overlapping `xcodebuild test` invocations** on the same scheme/DerivedData — the
  concurrent test processes contend on `NSFileCoordinator` and tag writes, ballooning runtimes
  (seen: a 0.07s suite took 448s under contention). Run one build/test at a time. (accepted: an environment rule; the heavy lock runs one build or test at a time).

## Deferred hardening (from the 2026-07-05 code review)
- **Write-target identity re-verification (Safety §6, low severity) — FIXED 2026-07-17 (mechanism
  `838b456`+`d393ff3`, W14.2; armed at live call sites `1a7c6cb`+W14.2-fu).** The concern: a tag write
  applies to whatever file currently occupies the URL, so a Finder move/replace between discovery and the
  write could tag the wrong file. **Mechanism:** `CoordinatedTagWriter.write(_:expectedIdentity:)`
  + `FileIdentity` (backed by `fileResourceIdentifier`, compared via `isEqual:` — **never**
  `.documentIdentifierKey`, which mutates on read) re-verify the resolved URL's identity **inside the
  `NSFileCoordinator` block** and abort with `.identityMismatch` on a moved/replaced file; the Reader
  `TagWriter.apply`/`setReadState` adapter exposes an opt-in `expecting:` param (fully unit-tested on
  scratch copies). **Armed (W14.2-fu):** every `NavigationModel` write call site — `mark`, group/inline
  edits, corpus-wide rename, and undo — now captures the file's `FileIdentity` **lazily at edit time**
  (via `ArchiveFile.liveIdentity()`, never at bulk discovery — the original rationale was Spotlight's
  "no per-file I/O" fast path, which `W26.walk2` retired, but **lazy is still correct**: an identity
  captured at discovery would already be stale at edit time, and a stale identity is worse than a fresh
  one) and passes it through `expecting:`; undo re-verifies against the identity captured at the
  ORIGINAL edit, so a file swapped under its path between edit and undo is skipped rather than mis-tagged.
  The group/rename path uses the identity-carrying `TagWriter.apply(_:to:[(url,identity)])` batch overload.
  A `nil` identity (file with no resolvable id) transparently skips the check for that file. Guard active
  in production; failures surface as "could not update/edit" without altering any other file.
  **Re-opened and fixed 2026-10-17 (`W40.f1` → `W40.fix-identity-url-cache`, S1).** The check compared a
  `URL`'s resource-value cache with itself: `FileIdentity.capture` read `fileResourceIdentifier` through the
  `URL` it was handed, a reused `URL` answers from the cache on its backing `NSURL` (every copy shares it,
  and `NSFileCoordinator` hands the block that same object), and the Reader passes one `ArchiveFile.url` to
  the capture and to the write. Measured: a file deleted and replaced under its path kept the old identity
  **and the old `tagNames`** through the reused `URL`, so the writer's §2 pre-read was stale the same way.
  The main thread's run loop flushes the cache each turn, which is why the defect showed in an undo made in
  the same turn as its edit (`UndoDurabilityTests.testUndoRefusesAFileSwappedUnderItsPath`) and would show
  in any writer off the main thread (Notes' store). The Tier-2 review found the writes affected too, and a
  probe confirmed it: `setResourceValue` on an `NSURL` holding cached Finder info rebuilds the 32-byte
  Finder-info block from the **cache**, so a tag or label write through a reused `URL` (the Reader's rows carry
  the enumerator's URLs, which arrive with Finder info cached) reverted a hidden flag another writer had set.
  Fix in ArchiveCore: `FileIdentity.capture` and `TagReading.read` read through a new `URL` for the same
  file-system representation (`URL.uncached`; built byte-exactly as `CorpusWalker.inspect` does, never from
  `path`, so composed Unicode and an empty path cannot redirect it), and `CoordinatedTagWriter.write` does
  every read and write inside its block through that URL, dropping the handed-in URL's cache on exit. The
  rebuild costs ~1.5 µs plus a real attribute fetch (~7 µs); the walker, which builds its URL fresh per file
  anyway, reads through `readTrustingURL` and pays neither. Pinned by `TagWriterPrimitiveTests`
  (`…ThroughAReusedURL…`, `testWriteReadsTheDiskNotTheCallersURLCache`,
  `testWriteThroughACachedURLKeepsAnExternalHiddenFlag`, `testUncachedURLKeepsTheNameBytesAndRefusesAnEmptyPath`)
  and the two `UndoDurabilityTests` that failed before it. (accepted: fixed, W14.2 and W40.fix-identity-url-cache; how the identity check works).

## Open risks / to verify
**Reviewed with the owner 2026-07-18** — every former entry here was grounded against current code; almost all
are now settled in code + tests. Kept as a short record:
- **SETTLED — Spotlight content indexing is not relied on.** Full-text search uses the Reader's own FTS5 index
  (`Search/ContentIndex.swift` + `ContentIndexer` + `PDFTextExtractor` over page-2 text), never
  `kMDItemTextContent` (0 code references). The old "re-check on-disk indexing" residual is moot. (accepted: settled with the owner, 2026-07-18).
- **SETTLED — `.documentIdentifierKey` is never requested** (it can assign/persist an identifier = a mutation).
  It appears only in "never request" comments; W14.2 identity re-verification uses `fileResourceIdentifier`
  (Safety §6). Enforced, not "to confirm." (accepted: settled with the owner, 2026-07-18).
- **SETTLED — tag-write coordination.** The shared `CoordinatedTagWriter` uses
  `NSFileCoordinator(.contentIndependentMetadataOnly)` (never `.forReplacing`), reads the array **inside** the
  coordinated block (TOCTOU), and verifies by re-read multiset. Covered by focused example tests
  (`TagWriterPrimitiveTests`/`TagWriterTests`). *(A generative property test was considered 2026-07-18 and
  declined as assurance-only — the path is deterministic + audited + green.)* (accepted: settled with the owner, 2026-07-18; a property test was declined as assurance only).
- **SETTLED — facet classification is display/sort/filter only, never drives a write.** `DocumentTags.parse`
  demotes shadowed collisions (a subject literally `1984`/`P7`/`Read`) back to subjects; `TagEditing` removes only
  the exact winning token. Regression-tested (incl. the `Read`-substring case). (accepted: settled with the owner, 2026-07-18).
- **SETTLED — segment features degrade when Classification is absent** (`DocumentRuns` returns a single item);
  the nav table is AppKit `NSTableView`; non-2-page / corrupt / non-PDF files degrade via `PDFFormatStatus` +
  render guards (page count is never a defect signal). (accepted: settled with the owner, 2026-07-18).
- **Low-pri, NOT queued (owner-reviewed 2026-07-18) — Unicode-on-write verification.** A scratch probe/guard for
  (a) macOS not trimming whitespace off a tag on write and (b) locking in that the verify treats NFC==NFD as
  equal. **The note's NFC/NFD "false-fail" fear is already neutralized** — Swift `String` comparison is
  canonical-equivalence-aware — so only the trim case is unpinned. Assurance-only, not a correctness gap; left
  as a soft backlog item. (accepted: the owner's call, 2026-07-18: assurance only, not queued).

## Environment notes
- Xcode 27.2 / Swift 6.4 toolchain (checked 2026-11-19); XcodeGen 2.45.2 at `/opt/homebrew/bin/xcodegen`. (accepted: an environment note).
- GitHub CLI: use `/opt/homebrew/bin/gh` (bare `gh` is shadowed on this machine). (accepted: an environment note).
- The corpus lives in `Test files/Brown Gemini/` at the repository root (150-PDF representative sample as of 2026-07-18, slimmed from ~6,941) and is gitignored — never modify it. (accepted: an environment note; the sample is read-only).

### W40.audit-ledger-undo — history now survives relaunch (2026-10-18)

Undo reads the append-only ledger, retaining the latest 100 forward groups per archive (consumed groups
count toward the bound). It skips unsupported/unverified/broken lines, follows matching bookmarks after
moves, and refuses mismatched or missing recorded identity. Device/inode is checked around a fresh
FileIdentity capture; the writer checks that identity again inside coordination. The recorded inode is
bound to the forward write's object, rather than captured only after the write returned.

A synchronized undoAttempt consumes the group before any inverse, so a crash or failed ledger append
cannot cause a non-idempotent occurrence inverse to replay. Partial failures name files. A member
that failed for any cause but an identity refusal is re-recorded afterwards as its own undo step
(W40.fix-reader-undo-partial: "Undo again to retry"), up to three attempts so a cause that never
passes cannot block older undo; a crash between consumption and that record loses the retry, never
replays. An identity refusal (replaced, gone, outside the archive) is never retried. Forward append failure disables older undo and warns; recovery appends a
synchronized history barrier. A failure counter keeps the warning even when another member of the
same batch recovers storage.

**Durability (W40.fix-reader-ledger-durability, 2026-11-03).** Each forward action is write-ahead
journalled: an `actionIntent` line is flushed (`F_FULLFSYNC`) inside coordination before its first
tag write, and an `actionDone` is flushed once every record of the action has been appended. An intent
with no `actionDone` (the process or the Mac died mid-action, a record failed, or a write failed its
verification so its change is uncertain) leaves its files in doubt, so the gap no longer depends on the
in-memory flag surviving. **Since W49.reader-undo-after-crash (2026-11-20)** the intent lists the files
the action expects to write (bulk actions declare them; a write to an undeclared file synchronizes an
extending intent first) and the process that wrote it. After a crash an unclosed action counts as
complete when every listed file has its record, nothing else from that process touched those files
after it began, and each file is still the recorded object reading as its newest record's after-state.
Otherwise the action is withheld, with every older change to a file it listed or recorded, every change
to those files by the same process, and transitively whatever those withheld groups touched; older
actions on other files stay undoable. An intent without a file list is still a full barrier. The live file is cut into numbered segments at 4 MiB
(`audit-ledger.000001.jsonl`, …) that are kept, not pruned (§12 is append-only); undo reads them newest
first and stops at a barrier or a full window. A file that exists but cannot be read, or a segment cut
by another running copy during the read, offers nothing rather than older history. Appends use
`O_APPEND`, so two running copies never write over each other's lines. What is still not covered:
- **A double fault.** If an intent itself cannot be written (storage failing: the first one, or an
  extending one for an undeclared file) and the process dies before storage recovers, the change is on
  disk with no line at all, and older history of that file is offered after relaunch. The tag write
  still goes ahead, because a ledger failure never fails a tag write. The in-process warning and barrier still cover the case while the app runs. (accepted: the in-process warning and barrier cover it while the app runs; it needs a second fault before storage recovers).
- **The disk keeps everything:** about 1 KB per changed file (mostly the bookmark). Deleting old segments
  would lose audit history, which §12 keeps; ask before adding a retention. (accepted: Safety §12 keeps the audit history; a retention is the owner's to ask for).
- **Two running copies.** The same-process rule cannot see a second copy of the Reader (another
  launch) that changed a crashed action's file between its last line and the crash, so that copy's
  newer change can be offered over the crashed write. (accepted: a platform fact: macOS runs one copy
  of an app per login unless it is started with `open -n`, and another login has its own container
  and ledger).
- **An action left open without a crash** (an unverified write, which sets no recording gap) withholds,
  for the rest of that session, every later change its own process makes to the action's files, even
  after the action ended. That is the safe direction, and it clears on relaunch. (accepted: the owner's call 22,
  2026-11-19, keeps an unproven action's files out of the history).
- **A crashed bulk action that skipped a declared file is never proven complete.** A file it declared
  but did not write (already in the target state, or refused for its identity) has no record, so the
  action and older history of every file it declared stay withheld. Callers declare only the files
  their cached tags say will change, which keeps this small. (accepted: the owner's call 22, 2026-11-19,
  `17b-accepted-review-round2.json` entry `r-crash-undo`: an action not proven complete keeps its listed
  files out of the history).
- **Reading is bounded only once the window fills.** An archive with fewer than 100 actions since the
  last barrier still decodes every segment on each undo refresh (on the main actor), as it did before. (accepted: under 100 actions since the last barrier the read is small).
- Two running copies cutting a segment at the same moment: the second rename fails, is logged, and the
  append goes on into the live file. (accepted: logged, and the append goes on into the live file, so no line is lost).

Scratch regressions: UndoDurabilityTests, LedgerUndoHistoryTests, LedgerJournalTests; evidence in
verification/evidence/reader/W40.audit-ledger-undo.md. R-46 stays fixed-pending-recheck.

### W45.undo-still-applied — undo never takes a token past its count before the change (fixed 2026-10-20)

The occurrence inverse used to append its additions unconditionally and always restore the label, so an
undo against a file changed since stacked tokens. Tested on scratch files before the fix: a second undo
of the same step turned `[A,A,B]` into `[A×4,B]`, two undos at once left `Unread` twice, a token put back
since got a second copy, and a colour changed since got the old label and colour token back over it.
`beginUndo` does not stop two running copies of the app from both undoing one group, so the guard lives
in the writer: `TagWriter.applyOccurrence(undoing:)` moves each token in the inverse toward, never past,
its count before the change, on the coordinated fresh read. It restores the label only while the label
still reads as the change left it, and otherwise also leaves the inverse's colour tokens alone. Each
token is judged on its own, and the rest of the file's undo still goes ahead. Tests:
`TagWriterTests`, MARK "Undo against a file changed since".
- **Changed meaning:** a copy someone added since, of a token the change removed, now counts toward the
  restore. Before `[A,A]`, the change removes both, someone adds one `A`, undo gives `[A,A]` (main gave `[A,A,A]`). (accepted: the intended meaning of the guard, W45.undo-still-applied).
- **Two running copies are covered by reasoning, not by a test.** The in-process path lock serializes two
  undos inside one app. Across two copies, the guard relies on `NSFileCoordinator` writing claims excluding
  each other, so the later undo reads the earlier one's result. Writers that do not coordinate (Finder, raw
  xattr writes) were never serialized and still are not. (accepted: NSFileCoordinator's write claims exclude each other; Finder and raw xattr writers never coordinated).
- **Counts are exact strings:** a re-cased copy (`unread` put back where the change removed `Unread`) is not
  counted, so undo still adds `Unread`. This is unchanged from before, and matches the path's exact matching of Read/Unread. (accepted: matches the path's exact matching of Read and Unread).
