# Near-Term UI Improvements — for owner review (2026-07-05)

Iterative, easily-achievable, **UI-focused** work. Ordered; ★ = you requested it. Effort: **[S]** ≈ a
few hours · **[M]** ≈ ~a day. "Reuses" notes where the plumbing already exists. Nothing here changes
the safety model — all tag edits still route through the audited `TagWriter`; the rest is display/nav.
**Status: proposal awaiting your prioritization.** Suggested first slice: **1a + 1b + 2** (the sidebar),
then **3a–3c** (non-standard triage).

## 1. Left navigation sidebar ★ (first priority)

- **1a. Navigable file tree from the archive root [M].** A collapsible source list on the left showing
  the folder hierarchy under the chosen root. Clicking a folder scopes the list to that subtree (a new
  `pathPrefix` on `LibraryFilter`); "All Files" at the top. Build the tree from the already-discovered
  file paths (no extra disk scan, stays within the tagged universe). Toggle to show/hide; persist width
  + expanded state. *Reuses:* `library.files` paths, `LibraryFilter`.
- **1b. Smart Folders pinned at the top of the sidebar ★ [S].** Surface the user's saved searches as a
  "Smart Folders" section above the file tree — click to apply, context-menu to rename/delete. Promotes
  them out of the toolbar "Saved" menu into the sidebar. *Reuses:* `SavedSearchStore`, `applySaved`.

## 2. Create a Smart Folder from the current filters ★ [S]

A "+" in the Smart Folders header (and a "Save as Smart Folder" button in the filter bar) that captures
the active read-state / priority / tag / filename / OCR-search state into a named smart folder. Show a
subtle "filters unsaved" hint when a view isn't yet saved; naming sheet pre-fills a name derived from
the active filters. *Reuses:* `SavedSearchStore.add(name:filter:fullTextQuery:)` (already wired) — this
just makes it first-class and discoverable.

## 3. Handling PDFs that don't match the standard format ★ (consider)

"Standard" = a 2-page PDF (page 1 image + page 2 OCR text), ideally with a `Classification:` line.
Non-standard = 1-page / >2-page / 0-page / corrupt / encrypted / non-PDF image / no OCR-text layer /
no classification. The viewer + indexer already **degrade gracefully**; the gap is **visibility + triage**:

- **3a. [S]** Library-Health popover: add counts — non-2-page, no OCR-text layer, unreadable/corrupt, non-PDF.
- **3b. [S]** A "Non-standard format" filter chip and/or a built-in **"Needs attention"** smart folder that
  collects them for triage.
- **3c. [S]** A subtle per-row badge (⚠︎) in the list for flagged files.
- **3d. [M]** In the viewer, a clearer banner on a non-standard doc stating what's missing
  ("1 page · no OCR text layer").

*Reuses:* `PDFTextExtractor` / `ContentIndexer` already know page count, text presence, and the
classification; this surfaces that signal. No corpus writes.

## 4. Curated small UI wins (pick any; each [S] unless noted)

- **Column show/hide + width/order persistence** (e.g. hide Type; remember across launches).
- **Persist view state across launches** — sort, filters, tag-cloud open, sidebar width (selection
  restore already exists).
- **Row density (compact/comfortable) + adjustable list font size** — for long reading sessions at scale.
- **Human-readable active-filter summary** in the status bar ("Unread · P8 · tag: Jerry Brown").
- **Focus shortcuts:** ⌘L focus the tag filter, ⌥⌘F focus OCR search, Esc clears filters, type-to-select
  in the table.
- **Tag cloud extras:** right-click a tag → add as AND / Any filter; "select all files with this tag".
- **Context menu:** "Open with Preview.app / default app" alongside Reveal in Finder.
- **Quick read/unread toggle** — a single-click affordance (in addition to the inline menu) + a shortcut
  to toggle read on the selection.
- **Tooltips + accessibility pass** for the new tag cloud and inline editors.

## 5. Slightly bigger (near-term but ~[M]+), for awareness

- **Corpus-wide tag rename** (controlled-vocabulary helper): rename a subject on every file carrying it,
  via a `TagWriter` batch, with a preview list + single grouped undo.
- **Live count badges** on smart folders / folders in the sidebar.
