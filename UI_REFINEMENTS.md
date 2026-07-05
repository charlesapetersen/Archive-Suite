# UI Refinements — 2026-07-05 batch (owner-requested)

Durable tracker for a batch of navigation/viewer UX requests. Implemented in committed clusters, each
built + tested (`xcodebuild … build/test`, keep 83+ green) and GUI-reviewed on the scratch corpus.
**Legend:** [ ] todo · [~] in progress · [x] done (committed).

## Requests

1. [x] **Column-header sort.** Clicking any data column header sorts by it; toggles direction; builds
   multi-level order (click a 2nd column → it's primary, prior becomes secondary). Verified in GUI
   (name asc→desc; then Priority primary with name secondary). Keeps `LibrarySort` semantics via a
   `sortOrder` binding of `ArchiveFileComparator`. (The ⚑ flag column is an action column, not sortable.)
2. [x] **File tags column excludes date tokens.** Dates show in the Document date column, so the File
   tags column shows only non-date, non-read-state tokens (`DocumentTags.topicalTags`).
3. [ ] **Inline editing in the list** for tags, priority, read/unread, and document date. For editing
   MULTIPLE selected files at once, use the pop-up editor (the existing group Tag Editor).
4. [x] **Remove "No read-state"** from the filter-bar read-state segmented control.
5. [x] **"Add subject filter" → "Add tag filter"** with tag autocomplete (native `NSComboBox`:
   inline completion + dropdown of existing tags). Verified in GUI.
6. [ ] **Right-margin tag cloud.** A panel that expands from the right edge showing all non-date,
   non-read-state tags across the *currently viewable* files. Tags listed alphabetically; each tag's
   font size scales with the number of viewable files carrying it.
7. [ ] **Preview arrow-key navigation.** In the Space preview, ↑/↓ move up/down the file list and the
   previewed file changes live to match.
8. [ ] **Move `AR-Smoke` off the Desktop** to a less-visible location; update `scripts/smoke-setup.sh`.
   (Do LAST, after GUI testing, so it doesn't disrupt the app's root during verification.)
9. [x] **Reveal in Finder** — from the list, via a keyboard shortcut AND the right-click context menu
   (read-only: `NSWorkspace.activateFileViewerSelecting`).
10. [ ] **Two copy modes** in the document viewer / preview: plain/direct copy on **⌘C**, and
    intelligent (prose-cleaned) copy on **⌘⇧C**. (Currently ⌘C is the intelligent copy.)
11. [ ] **Top-anchored zoom** in the file viewer — the top of the page stays pinned to the top of the
    pane as you zoom. (Was implemented earlier; re-verify under the new zoom keys.)
12. [ ] *(folded into #14)* Zoom in/out via ⌘↑ / ⌘↓.
13. [ ] **Shift focus between panes** — a keystroke moves keyboard focus from the left (image) page to
    the right (OCR text) page and back.
14. [ ] **Viewer navigation key scheme** (supersedes the old ↑/↓-cycles-selection):
    - **↑ / ↓** — scroll up/down within the currently focused page.
    - **⌘↑ / ⌘↓** — zoom in / out (top-anchored, per #11).
    - **⌘⇧↑ / ⌘⇧↓** — move to the previous / next page within the *segment* currently selected in the
      file navigator (the Document Start + Continuation run).

## Notes / decisions
- Safety unchanged: every tag edit still routes through the audited `TagWriter`; new features are
  display / navigation / read-only-reveal only. Inline edits reuse `TagEditing` + `TagWriter`.
- Sort keeps `LibrarySort`'s semantics (nil-last, medieval-safe, `localizedStandard`); header clicks
  drive the same model so headers and the Sort menu stay consistent.
