# Archive Reader — Project Guide

A native macOS app that lets a **historian read through PDFs of historical documents** that were
tagged by the sibling app **Archive Processor** (same author, `../Archive Processor`). Archive
Reader is the *reading & triage* companion: find tagged PDFs, list them in chronological order,
filter by subject / priority / read-state, read them two-up (image + OCR text), copy text and
file links, and mark them Read as you go.

> **Status:** Shipped — v1 plus a full P2 pass (non-standard-PDF detection, near-duplicate tag
> finder, document-viewer refinements, duplicate-filename disambiguation); 135 tests green. **This
> file is the durable record** for the Reader. **Core Directive**, **Verified Facts**, and **Safety
> Protocol** below are settled and non-negotiable; the keyboard map, options, edge-case rules, and
> decisions are folded into the sections below.

---

## CORE DIRECTIVE (bulletproof — this overrides everything)

Archival image files are **irreplaceable** and their tagging was **extremely time-consuming**.

- The app **MUST NOT** delete, move, rename, trash, re-save, or alter any file's **bytes/contents**
  or **location** — ever.
- The app **MUST NOT** mangle, drop, or lose any tag *unintentionally*.
- The app **MAY edit macOS Finder tags** — add / remove / change subject, date, priority, color,
  and read-state tags, for a single file **or a group** — but **only** as a *deliberate user
  action*, routed through one audited choke-point (`TagWriter`), applied as a precise **delta**
  (add-set / remove-set) to a **freshly-read** tag array, and **verified** afterward. Finder-tag
  (extended-attribute) metadata is the *only* thing the app ever changes; file **bytes and file
  location never change**. (Read/Unread triage is just the fast-path preset of this same editor.)
- Everything else — discovery, filtering, viewing, copying — is strictly **read-only**.

This is an architectural property, not a coding-discipline hope: **all tag writes route through the
single audited `TagWriter`** (see Safety Protocol). No other code imports a file-mutating API, and
even `TagWriter` never calls a move / rename / delete / content-write API — only the tag-array and
(deliberately) the color-label metadata.

---

## Verified Facts (measured against the real corpus + Archive Processor source, 2026-07-04)

> **Single source of truth:** the tag/PDF contract shared with Archive Processor is authoritatively
> documented in [`../SPEC/tag-format.md`](../SPEC/tag-format.md) (Suite root). The facts below
> mirror it from the Reader side; if they ever disagree, the SPEC wins and both must be reconciled.

**Corpus:** `Test files/Brown Gemini/` — ~6,941 two-page PDFs. Real production scale is up to
**~150,000** files. Filenames like `00001 IMG — Brown.pdf` (note the **em dash** U+2014; production
paths also contain **non-breaking spaces** U+00A0).

**Tags** are macOS Finder tags:
- Read: `url.resourceValues(forKeys: [.tagNamesKey]).tagNames` → `[String]`.
- Write: `(url as NSURL).setResourceValue([String], forKey: .tagNamesKey)`.
- Color label: `.labelNumberKey` (Red=6 ⇒ box photo, Purple=3 ⇒ folder photo). **Verified:** keeping
  the color-name token (`"Red"`/`"Purple"`) in the tag array and writing `.tagNamesKey` **preserves
  `labelNumber`** without writing it (tested on a Red-labeled scratch copy). Still verify-after-write.
- Spotlight exposes tags as `kMDItemUserTags`.

**Tag facets** (a file's tag array mixes these; classify for display/filter/sort, never lose any):
- **Year:** 3–4 digits, e.g. `1980` (or `842`). Archive Processor emits 4-digit years; Reader's
  `parseYear` accepts **3–4** (medieval-friendly), so don't assume exactly 4.
- **Month:** `MM Month`, e.g. `03 March`.
- **Day:** `Day N` (unpadded), e.g. `Day 25`, `Day 1`. Often absent.
- **Date Uncertain:** flags that the date is **speculative** — the file *usually still has a Year
  tag*. So these files sort by their (speculative) year like any dated file; the nav window renders
  the derived date in **italics** to signal speculation (never dumped to the end).
- **Priority:** exactly one of `P7 P8 P9 P10` (P10 highest). Box/folder pages & some docs have none.
- **Read state:** `Read` or `Unread` (Archive Processor stamps `Unread` last on new output).
- **Subject:** 2–6 free-form-ish strings (`Jerry Brown`, `DP chapters`, `Economics`, …). May be a
  controlled vocabulary. **Subjects can collide with other facets** (a subject literally `1984`,
  `P7`, or `Read`) — facet classification is display-only and must never drive a destructive write.
  Note Archive Processor also emits some *literal* subject tokens: `Box`/`Folder` on marker pages
  (alongside the color) and `OCR Failed` on OCR failures — Reader treats these as plain subjects.

**PDF structure:** exactly **2 pages** — page 1 = original photographed image (correctly oriented);
page 2 = OCR text as **real selectable text** (dynamic height). *In this test corpus* page 1 has no
text; **in production the image page will often also carry a searchable text layer**, so the copy
tool must work in whichever pane holds the selection. Page-2 header format:
```
Extracted text.
<original filename, verbatim>          # any image ext (.jpg/.png/.tiff/.heic); OMITTED if the source name is unknown
<Provider> · <Model> · <D Month YYYY>
Classification: <Box | Folder | Document Start | Continuation>          # line may be ABSENT (see below)
<body…>
```
Do **not** hard-assume 2 pages: guard against 1-page, >2-page, 0-page, corrupt/encrypted, and
tagged **non-PDF** images (box/folder markers may be images) — degrade, never crash.

**Document segments (the reading unit).** The reading/triage unit is a *document* — a run of
consecutive PDFs — which is **finer than** the Red/Purple folder/box markers (a folder holds many
documents). Segments are recoverable from the page-2 `Classification:` line: verified values are
`Document Start`, `Continuation`, `Box`, `Folder`. Ordered by the filename sequence within a folder,
a segment = a `Document Start` plus any following `Continuation` pages (a lone `Start` = 1-page doc);
`Box`/`Folder` are higher-level markers/provenance. (Sample distribution: ~74% Start, ~19%
Continuation, rest markers.) The classification lives in the PDF's page-2 **text**, so it's read via
the content index, not a tag.
> **Classification is NOT guaranteed present** — older outputs, Mistral/heuristic runs, or
> hand-added files may lack it. Segment-awareness is therefore a **best-effort enhancement that
> degrades gracefully**: when the classification is missing, fall back to filename-sequence order +
> manual multi-select. Never build a core behavior that assumes the classification exists.

**Search:** Spotlight (`mdfind`/`NSMetadataQuery`) finds these by tag fast — a compound 3-facet
query over 6,941 files returned in **0.38s**; `Read OR Unread` in **0.45s**. Scales to 150k (index
lookups, not scans). Text-content indexing may lag/miss on some locations. **v1 assumes local disk,
no cloud drives** (cloud support is deferred — long-term; see `POTENTIAL_FEATURES.md`).

**Chronological sort key:** derived **from the Year/Month/Day tags** into a sortable integer
(e.g. `year*10000 + month*100 + day`; the arithmetic is BC-capable, though no BC/negative-year token
exists in the tag vocabulary today). This has **no date-range limit** — medieval
and ancient dates sort correctly — requires **no** change to Archive Processor and **no** writes to
files. This is the primary sort key.
- *Optional future bonus (deferred):* also mirroring the date into the file's **creation date**
  (`FileManager.setAttributes([.creationDate:])`, verified for 1938/1850; floor ≈ 1677-09-21,
  range ~1678–2262) would let **Finder itself** browse chronologically and give zero-parse native
  sort — but it is range-limited and unnecessary for correctness, so it is **not** relied upon.

---

## Safety Protocol — `TagWriter` (the single write choke-point for ALL tag edits)

Every tag write — subject/date/priority/color edits, group edits, and Read/Unread triage — goes
through **one** function. It is the *entire* write surface. An edit is expressed as a **delta**:
`{ add: Set<String>, remove: Set<String>, color: ColorChange? }`. A Read/Unread swap is just the
delta `remove {opposite}, add {target}`. "Set the year to 1981" is `remove {matching Year token(s)},
add {"1981"}`. All of the following hold for every delta.

1. **Coordinated, metadata-only write.** Wrap in `NSFileCoordinator` with
   `.contentIndependentMetadataOnly` (never `.forReplacing`, which can re-save content). Open PDFs
   for reading with `.withoutChanges`.
2. **Fresh read inside the write block** (avoid TOCTOU): read `.tagNamesKey` + `.labelNumberKey`
   again immediately before computing/writing.
3. **Trustworthy-read guard (prevents the catastrophic tag-wipe).** If the read *throws* or returns
   `nil` tagNames, **ABORT** — never coerce a read failure to `[]`. A file with genuinely zero tags
   is distinct from an unreadable file; only a *confirmed* array may be written back. (With arbitrary
   editing now allowed, this guard matters for *every* edit, not just triage.)
4. **Exact, whole-string, case-insensitive** matching when identifying tokens to remove — never
   substring (so removing `Unread` never touches a subject `"Read later"`). If the intended target
   is ambiguous, **refuse and surface**, don't guess.
5. **Compute the new array losslessly:** `new = (fresh − remove) + add`, preserving every untouched
   token verbatim; append order stable. Never build the write array from Spotlight's
   `kMDItemUserTags` (lossy/stale). A **no-op delta writes nothing** (no mod-date churn).
6. **Do not request `.documentIdentifierKey`** on read (it can *assign & persist* an identifier —
   a mutation). Use security-scoped bookmarks + re-verify the resolved URL's identity before writing
   (guards against writing to the wrong file after a Finder move).
7. **Color label:** write `.labelNumberKey` **only** when the delta explicitly changes color
   (box/folder). Otherwise never write it; read before/after and restore only on unintended drift.
8. **Verify by re-read.** Assert the resulting tag **multiset** equals `(old − remove) ∪ add`
   exactly — nothing else added, removed, or altered; color as intended; file **bytes unchanged**
   (data-fork hash guard on the writer). Multiset equality, not order (macOS may reorder).
9. **No blind rollback / no blind restore.** On verify-fail, re-read fresh and reconcile by
   re-computing the *delta* against current state — never rewrite a stale full array. **Undo = the
   inverse delta** (`add↔remove`) applied to a fresh read, so undo can never emit or destroy an
   unrelated token, and it preserves concurrent third-party edits. Bulk/group actions = **one**
   grouped undo.
10. **Group edits** show tri-state presence (on all / some / none of the selection, like Finder);
    "add X" affects only files lacking X, "remove X" only files having it. The Read/Unread fast-path
    default does **not** add a read-state token to a marker/neither file (option, off).
11. **Batch = independent idempotent units** (bounded concurrency), never all-or-nothing. Surface
    partial failures ("12 of 15 updated; 3 could not — Retry"); a row leaves a filtered view only
    after its write **verified**.
12. **Append-only audit ledger** of `{path, bookmark, delta, before[], after[], timestamp}` for
    every change — transparency/history and inverse-delta undo source, *not* blind full-array restore.
13. **PDF panes are provably non-writing:** PDFViews non-editable, annotations disabled, no
    `PDFDocument.write` path exists. The write-surface lint covers *all* write spellings
    (`setResourceValue(s)`, `setxattr`, `FileManager` mutators, `PDFDocument.write`). The lint is one
    layer; the real guarantee is that only `TagWriter` imports tag-write APIs and *nothing* imports
    move/rename/delete/content-write APIs.

Risk tiering (mirrors Archive Processor): `TagWriter` and anything it touches is **Tier-2
adversarial-review + property/integration tests on scratch copies** on every change. Never test tag
writes against the real corpus — always a copy.

---

## Architecture

- **Discovery/filter/sort (tags):** `NSMetadataQuery` scoped to user-granted **archive root(s)**
  (security-scoped bookmarks). Master universe predicate: `kMDItemUserTags == "Read" ||
  kMDItemUserTags == "Unread"`. Facet filters combined in-query + in-memory. Live-updating. The
  filesystem/tags are the **source of truth**.
- **Content index (full-text + segments):** a background extractor reads each PDF's page-2 text
  **once** and caches: OCR body (for corpus-wide full-text search), the `Classification:` value (for
  document segments + markers), and header metadata (provider/model/OCR-date). Stored in
  **system SQLite FTS5** (`libsqlite3`, OS-provided — *not* a third-party ORM/GRDB dependency).
  Incremental (only new/changed files). It is a **disposable, rebuildable cache** — deleting it loses
  nothing; the corpus + tags remain authoritative. This powers v1 full-text search and segment-aware
  reading without relying on Spotlight content indexing (which was absent on the test copy).
- **Reading model — the user decides which files open together.** Manual multi-selection in the nav
  window is the *definitive* grouping mechanism; **the app never auto-groups**. Segment/classification
  awareness is at most an *optional, opt-in convenience* (e.g. an "extend selection to the next
  Document Start" command) — never required, and it silently degrades to plain selection when the
  classification is absent. The content index exists primarily for **full-text search** (v1) and
  optional provenance display, not for grouping.
- **Two windows** (SwiftUI scenes): a single **navigation window** (Finder-Smart-Folder-like table)
  and a **document view window** opened with a selection payload.
- **Navigation table:** SwiftUI `Table` (NSTableView-backed on macOS 14+), data layer abstracted so
  an AppKit `NSTableView` swap is possible if `Table` janks at 150k (test early). Columns: Document
  date, File name, File type, File tags, Read/Unread (+ optional Box/Folder provenance).
- **Document viewer:** two `PDFView`s (image left / OCR text right), **independent zoom** per pane,
  draggable gray splitter with center grab handle, **default 2/3 : 1/3** — the split, per-pane zoom,
  and window size then persist as the next viewer's default (DV-1/DV-2; **no** per-document reset).
  `↑/↓` **scroll** the focused pane; `⌘⇧↑/↓` cycle the segment (see §Keyboard). Intelligent copy +
  in-doc Find. Degrades for non-2-page/corrupt.
- **Intelligent copy** (`⌘⇧C`): collapse single newlines → space; blank line = paragraph break (keep);
  de-hyphenate line-end hyphens; works in whichever pane holds the selection. `⌘C` copies verbatim.
- **Options panel (⌘,):** link format, copy-text cleaning, viewer split, nav defaults, list density,
  near-duplicate warning (see **§Options** below).

## §Keyboard map (the menu bar is the single source of shortcuts — `ArchiveReaderCommands.swift`)

*Navigation window*
- `↑/↓` move selection · `⇧↑/⇧↓` extend · `⌘A` select all · type letters/digits = type-select *(native `Table`)*
- `Space` Quick-Look-style **Preview** (2-up peek; fires only when the list has key focus) · `⌘Y` Preview (menu) ·
  `⏎`/double-click or `⌘O` open in the document window
- `⌘R` Mark Read · `⌘U` Mark Unread · `⌘I` Edit Tags… · `⌘⇧F` Toggle Flag · `⌘Z` Undo tag change (grouped; **no redo binding**)
- **Keyboard triage (G4):** `⌘]`/`⌘[` Next/Previous Unread · `⌘⇧M` Mark Read & Next Unread (mark Read via `TagWriter`,
  then jump to the next `Unread`). Focus-scoped bare-key equivalents fire only when the list has key focus
  (text-field-safe, like `Space`): `]`/`[` = next/previous unread, `\` = mark read & advance. All read-state
  mutation routes through `mark(.read)` → `TagWriter` (undoable); the next/previous math is pure (`TriageNavigation`).
- `⌘⇧C` Copy Link(s) · `⌘⇧R` Reveal in Finder · `⌘⇧O` Choose Archive Folder…
- `⌘L` focus tag filter · `⌘⌥F` Search OCR text · `⌘⇧K` Clear filters & search
- *Menu-only (no shortcut):* Sort by Date/Name/Priority/Read-state · Rename Tag… · Find Similar Tags… ·
  Save Current Search… · Select Document Run · Open in Default App

*Document window* (the **focused pane** carries an accent border; switch it with `⌘⌥←`/`⌘⌥→`)
- `↑/↓` **scroll** the focused page (PDFView) — *not* document cycling
- `⌘⇧↑/⌘⇧↓` previous/next page in the segment (the opened run/selection)
- `⌘⌥←`/`⌘⌥→` focus image pane / focus text pane
- `⌘↑`/`⌘↓` zoom in/out the focused pane · `⌘0` fit the focused page · `⌥⌘0` reset split + zoom to defaults
- `⌘C` copy verbatim · `⌘⇧C` copy cleaned-for-prose (intelligent) · `⌘F` find in document
- `⌘,` Options (both windows)

*Preview sheet* (opened by `Space`/`⌘Y`)
- `↑/↓` previous/next file in the list (nav selection follows) · `←/→` cycle within a multi-file selection ·
  `⌘C`/`⌘⇧C` copy verbatim/cleaned · `⌘O` open the full viewer · `Space`/`Esc` close

> **Reconciled with the code, 2026-07-07.** The viewer scheme changed after PLAN was written
> (shipped UI batch #14): `↑/↓` now **scroll the focused page** instead
> of cycling documents; cycling moved to `⌘⇧↑/↓`; zoom is `⌘↑/↓` (not `⌘=`/`⌘-`); reset is `⌥⌘0` (not
> `⌥⌘=`); `⌘C`/`⌘⇧C` are verbatim/cleaned copy. The document window has **no** Mark-Read (`⌘R`) or
> copy-link shortcut — those are nav-window only.

## §Options (⌘, — `OptionsView`, read via `AppSettings`)

- **Copying links:** link format (`file://` URL · POSIX path · Markdown · HTML) · blank lines between links (0–5).
- **Copying text:** collapse single line breaks → spaces (on) · blank line = paragraph break (on) · rejoin hyphenated line-splits (on).
- **Document viewer:** default split (image %/text %, 0.2–0.8). Per-pane zoom, split position, and window
  size are **not** toggles — the viewer persists the *last used* value as the next default (DV-1/DV-2).
- **Navigation defaults:** default read-state filter (All / Unread / Read / No-read-state) · combine subject filters with ANY (off = ALL).
- **File list:** list text size (10–20 pt; smaller = denser rows).
- **Tag editing:** warn when a new subject differs only by case from an existing one (on).

> PLAN's §Options listed controls that did **not** ship as toggles (viewer zoom/fit-mode & reset-per-
> document, "skip OCR header", date-display format, default sort levels, Box/Folder column, controlled-
> vocabulary restriction, large-edit confirm threshold, animation speed, in-panel archive-root
> management). The shipped panel is the leaner set above; archive roots are chosen via
> File ▸ Choose Archive Folder…, not the Options panel.

## §Edge-case rules

- **Not exactly 2 pages / non-PDF / corrupt/encrypted:** probe open + page count; single-pane / "no OCR
  page" state; `PDFDocument(url:)==nil` guarded. **Page count is never a defect signal** — merged >2-page
  PDFs are legitimate (`PDFFormatStatus`); a file is flagged only when unreadable or text-less. Tagged
  non-PDF images stay listed (they carry read-state); the viewer degrades.
- **Neither Read nor Unread:** tri-state "No-read-state" bucket; markers stay visible, never silently lost.
- **Read-failure ≠ empty tags:** abort the write (Safety Protocol §3).
- **Duplicate filenames across boxes:** colliding rows show their containing folder as a subtitle
  (`DuplicateNames`); copied link groups carry full paths.
- **Unicode:** normalize (NBSP→space, dash-fold, case/diacritic-fold) for search/type-ahead/sort keys
  **only**; preserve real bytes for display + link encoding.
- **Multiple same-facet date tags** (two Years/Months): deterministic rule + flag ambiguous.
- **Facet-looking subjects** (`1984`, `P7`, `Read`): heuristics + display-only correction; never affects writes.

## §Decisions (settled with the owner; the app ships these)

- **Chronological sort key derived from tags** (universal, medieval-safe, no Processor change);
  creation-date native sort is a deferred bonus.
- **Date Uncertain** sorts by its speculative year, rendered *italic* (never dumped to the end).
- **Discovery = Spotlight** (`NSMetadataQuery`) over granted archive root(s); universe = files tagged
  `Read`/`Unread`. No third-party ORM (the content index uses OS SQLite FTS5).
- **Subject filters AND by default** (OR/NOT via toggle); read-state is a tri-state filter; "Mark Read"
  never adds a read-state token to a marker/neither file (option, off).
- **Facet classification is display/sort/filter only** — never drives a write.
- **Full tag editing is first-class** (single + group), always via `TagWriter`; free-form subjects with
  autocomplete + near-duplicate warning (`TagSimilarity`) to curb fragmentation.
- **Reading/grouping is user-driven manual multi-selection** — the app never auto-groups; segment
  awareness is opt-in convenience that degrades silently when the classification is absent.
- **Full-text OCR search is in v1** via the app's content index (not Spotlight content indexing) + in-doc `⌘F`.
- **v1 sandboxed** to a granted root; non-sandboxed whole-Mac search is long-term (behind a `FileAccessProvider` abstraction).

## Implementation map (shipped — v1 + P2 complete, 135 tests, 2026-07-07)

`ArchiveReader/Sources/ArchiveReader/`
```
ArchiveReaderApp.swift        @main; two scenes (nav Window + document WindowGroup) + Settings (⌘,).
ArchiveReaderCommands.swift   Menu bar (File · Selection · Tags · Sort & Filter · Document). Menus are
                              the SINGLE source of the keyboard shortcuts (toolbars don't re-declare
                              them); commands act on the focused window via @FocusedObject.
Core/                         UI-free domain (package-ready → future ArchiveCore):
  TagWriter.swift             THE single write choke-point. TagDelta{add,remove,color}; apply()/
                              setReadState()/batch; coordinated metadata-only write; trustworthy-read
                              guard; multiset+label+bytes verify; label-only .restoreLabel inverse undo.
  TagEditing.swift            TagEditOp → per-file TagDelta; GroupTagSummary (tri-state across selection).
  TagReading.swift            Safe read; TagReadResult distinguishes confirmed-empty vs unreadable.
  TagSimilarity.swift         Pure near-duplicate subject clustering (normalize + length-scaled
                              Levenshtein, union-find) behind Find Similar Tags; suggests merges, never writes.
  DocumentTags.swift          Tag→facet parser (year/month/Day N/priority/read/color/subjects);
                              sortDate (medieval-safe), displayDate, dateIsSpeculative.
  LibraryFilter.swift         LibraryFilter (Codable, incl. pathPrefix folder-scope) + LibrarySort.
  ArchiveFile.swift           A nav-row record (url identity + parsed tags).
  DuplicateNames.swift        Pure detection of rows sharing a base filename + containing-folder
                              disambiguator (display aid only; never writes).
  LibraryChangeSignature.swift Pure order-independent change-signatures (paths / DISTINCT-subject union /
                              match-facets) that gate NavigationModel's cache rebuilds. Subjects sig is
                              over the union (NOT the multiset) so even-count edits can't XOR-cancel.
  FileLink.swift              LinkFormat + FileLinkFormatter (percent-encoding; HTML-escaped).
  CopyTextCleaner.swift       Intelligent copy (collapse single NLs, paragraph on blank, de-hyphenate).
  DocumentRuns.swift          Pure run detection (Start + Continuations) for opt-in run selection.
  TriageNavigation.swift      Pure next/previous-unread selection math (skip read, wrap/stop) for G4
                              keyboard triage; touches no file — the caller writes via TagWriter.
  PDFFormatStatus.swift       Pure read-only classifier: standard / unreadable / no-text-layer (page
                              count is NOT a defect signal). Drives the ⚠︎ badge + viewer banner.
  AppSettings.swift           UserDefaults-backed option accessors the models read at point of use.
Search/                       Discovery + disposable caches (never the corpus):
  ArchiveLibrary.swift        NSMetadataQuery over Read/Unread tags, scoped to the root; live updates.
  RootFolderStore.swift       Security-scoped bookmark to the archive root.
  ContentIndex.swift          SQLite FTS5 actor (import SQLite3) — full-text + classification.
  ContentIndexer.swift        Background (detached) incremental indexing; async search/classification.
  PDFTextExtractor.swift      PDFKit text + Classification-line extraction (guards corrupt/non-PDF).
  NotesStore.swift            Per-file note+flag in UserDefaults (outside the corpus).
  SavedSearch.swift           Named filter+FTS query (smart folders), UserDefaults-persisted.
Views/
  NavigationModel.swift       Nav view model: filter/sort/selection, folder tree, smart-folder counts,
                              view-state persistence, inline + corpus-wide edits — all via TagWriter.
  NavigationWindowView.swift  Results Table (customizable columns), filter bar, sidebar+tag-cloud panels,
                              toolbar, context menus, sheets, header-click sort, focus shortcuts, FlowLayout.
  SidebarView.swift           Left sidebar: Smart Folders (saved searches) + a navigable folder tree
                              (List(selection:)+OutlineGroup) that scopes the list via filter.pathPrefix.
  InlineEditCells.swift       In-list single-file editors: ReadStateCell (1-click toggle), PriorityCell
                              (menu), DateCell / TagsCell (popovers). Multi-file edits use the ⌘I editor.
  SubjectTokenField.swift     Inline NSTokenField subject editor per row: autocomplete from the corpus;
                              edit-start-base diff → ONE TagWriter delta; commits the field's tokens on
                              blur — WYSIWYG, so a typed-but-not-Return'd word sticks (owner 2026-07-08;
                              GUI-verified). Adds only route through TagWriter, so existing tags never lost.
  TagFilterField.swift        NSComboBox-backed tag filter with autocomplete (+focus token for ⌘L).
  RenameTagSheet.swift        Corpus-wide tag rename (D1): shows the affected-file count; via TagWriter batch.
  SimilarTagsSheet.swift      Near-duplicate tag finder (TagSimilarity clusters): pick a canonical +
                              Merge drives the corpus-wide rename (→ RenameTagSheet → TagWriter). Advisory only.
  TagEditorView.swift         Group-aware tag editor sheet (⌘I).
  OptionsView.swift           Settings form (⌘,), @AppStorage (incl. list font size).
  DocumentViewerModel.swift   Loads the selection; page cycling; focused-pane zoom; plain + intelligent copy.
  DocumentWindowView.swift    Two-up layout, draggable splitter, per-pane zoom, focus border.
  PDFPaneView.swift           Read-only single-page PDFView + PDFPaneController (zoom/focus/selection/find).
  PreviewSheet.swift          Quick 2-up preview (Space): image | OCR text; ↑/↓ browse list, ←/→ cycle.
Info.plist · ArchiveReader.entitlements (sandbox + user-selected + app-scope bookmarks)
```
UI shipped in two owner-requested batches (Batch 1 refinements; Batch 2: sidebar, smart folders,
item-4 wins, tag rename) — see `git log` for the detail.
`ArchiveReader/Tests/ArchiveReaderTests/` — 16 test files (149 tests). `scripts/lint-write-surface.sh`
enforces the write surface. Build: `xcodegen generate && xcodebuild -scheme ArchiveReader … build/test`.

## Stack & Build

- Swift 6, SwiftUI (+ AppKit where needed), **XcodeGen** (`project.yml` authoritative; `.xcodeproj`
  generated & **gitignored**). PDFKit, `NSMetadataQuery`, `NSURL` resource values, `NSFileCoordinator`.
- Target macOS 14+. Sandbox posture: **v1 sandboxed**, scoped to a user-granted archive root
  (start with the provided test-files folder) via a security-scoped bookmark — OS-enforced
  containment of irreplaceable files. **Non-sandboxed whole-Mac search is planned long-term**, so
  file access + search go behind a `FileAccessProvider` abstraction: switching posture is an
  entitlement/config change, not a rewrite.
- Build: `xcodegen generate` then `xcodebuild -scheme ArchiveReader -configuration Debug build`.
  Per-worktree DerivedData (`-derivedDataPath ./build/DD`) for concurrent agents, like the sibling.

## Archive Suite (long-term convergence with Archive Processor)

Archive Reader and Archive Processor are two halves of one offering — the Processor *writes* tags,
the Reader *reads and edits* them — and will eventually ship together as **Archive Suite**. Notably,
Archive Reader realizes several items already on Archive Processor's own `POTENTIAL_FEATURES.md`
(full-text search, filter-by-tag, browse, side-by-side original/OCR view).

**The shared contract is the risk.** Both apps must interpret tags, date facets, priorities,
color/markers, the `Read/Unread` convention, and the 2-page PDF + `Classification:` format
*identically* — a divergence would corrupt or mis-read irreplaceable data. That contract is the real
thing to keep in sync — authoritatively in [`../SPEC/tag-format.md`](../SPEC/tag-format.md)
(the Suite-root contract both apps cite; Verified Facts above mirror it from the Reader side).

**Recommended approach (staged, low-risk):**
1. **Now — separate repo, shared contract.** Develop Archive Reader in its own repo with its own
   XcodeGen project, mirroring Archive Processor's conventions (docs, worktrees, tiered review, push
   cadence). Keep all domain logic in a **self-contained `Core/` module** (tag facets, `TagWriter`,
   PDF/classification model, date parsing, link formatting) with **no UI imports**, so it can be
   lifted out cleanly later. Document the tag/PDF contract identically in both repos.
2. **At Reader ~M3 (stable core) — extract `ArchiveCore` Swift package.** Move the shared domain into
   a standalone Swift package; both apps depend on it. This unifies the safety-critical tag code
   (Processor's `MacOSTagger` + Reader's `TagWriter` reconcile into one audited writer) so it can
   never drift. This is the appropriate incorporation point — earlier risks churning an unstable API.
3. **Ship — Archive Suite.** Either a **monorepo** (`Archive Suite/` with `ArchiveProcessor/`,
   `ArchiveReader/`, `ArchiveCore/`, one `bootstrap.sh`, a shared version tag) distributed as two
   apps, or a single app with Process/Read modes. A monorepo is preferred once the package exists:
   one clone, one build, atomic cross-app changes, no submodule friction.

Until step 2, treat the tag/PDF contract as the coupling; keep `Core/` UI-free and package-ready.

## Never
- Never write to the corpus during development/testing — copy files to the scratchpad first.
- Never hand-edit `.pbxproj` (edit `project.yml` + regenerate).
- Never add a tag-writing call outside `TagWriter`; never add a move/rename/delete/content-write
  call anywhere (not even in `TagWriter`).

Milestones M0–M3 and the High-priority backlog all shipped; the keyboard map, options, edge-case
rules, and decisions are folded into the §sections above. Further ideas live in `POTENTIAL_FEATURES.md`,
open issues in `KNOWN_ISSUES.md`, and the manual smoke test in `SMOKE_TEST.md`.
