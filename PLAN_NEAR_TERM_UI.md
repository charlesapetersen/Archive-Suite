# Implementation Plan — Near-Term UI Batch 2 (2026-07-05)

Durable, **resumable** execution plan for the owner-approved items from
[NEAR_TERM_UI.md](NEAR_TERM_UI.md): **1** (left sidebar: file tree + smart folders), **2** (create a
smart folder from current filters), **all of 4** (small UI wins), and **5** (tag rename + count badges).
Item **3** (non-standard PDFs) is deferred to [POTENTIAL_FEATURES.md](POTENTIAL_FEATURES.md).

## How to resume (read this first if you were interrupted)
1. Read this file's checkboxes — the **longest unbroken run of `[x]` from the top is done**; resume at
   the first `[ ]`. Cross-check `git log --oneline` and `STATUS.md`.
2. Each **milestone is independently shippable**: build green + tests green + committed & pushed before
   moving on. Never leave the tree on a red build.
3. Smoke/GUI runs use the scratch corpus at `~/Library/Application Support/ArchiveReader/AR-Smoke`
   (re-create with `bash scripts/smoke-setup.sh 30`) — **never** the real `Test files/` corpus.

## Working conventions (apply to every milestone)
- **Build/test:** `cd ArchiveReader && /opt/homebrew/bin/xcodegen generate && xcodebuild -scheme ArchiveReader -configuration Debug -derivedDataPath ./build/DD build` then `… test`. Keep **≥83 tests green**.
- **Write-surface lint:** `bash scripts/lint-write-surface.sh` must stay clean — critical after the tag
  rename (M-D1). Only `TagWriter` may write tags; nothing may move/rename/delete/rewrite a file.
- **Commit + push per cluster:** small commits; `git push origin main` after each (remote is the durable
  record). `gh` = `/opt/homebrew/bin/gh`.
- **GUI automation:** `open -a` the built app; **verify `ArchiveReader` is frontmost before every click
  or capture** (the VS Code host reclaims focus — a blind region capture can grab another window, a
  privacy hazard). Window-only captures (`screencapture -R`).
- **Safety:** only two NEW write paths in this batch — **C8** (read/unread single-click) and **D1** (tag
  rename); both route through the audited `TagWriter`. D1 is **Tier-2** (adversarial review +
  integration test on scratch copies). Everything else is display / navigation / read-only.
- **Per-cluster gate = 4 steps:** (1) implement, (2) build + unit tests green + lint clean,
  (3) **code review** (self; adversarial for D1), (4) **GUI test** on scratch (+ **smoke** where it
  writes), then commit + push + tick the box.

---

## Milestone A — Left sidebar shell + navigable folder tree (item 1a)
- [ ] **A1. Path-scope filter.** Add `pathPrefix: String?` to `LibraryFilter` (Codable); `matches()`
      requires the file's path to be within that folder (compare on path-component boundaries, not raw
      `hasPrefix`, so "…/Brown" doesn't match "…/Brown2"). `nil` = whole root. Unit-test the matcher.
- [ ] **A2. Folder-tree model.** In `NavigationModel`, derive a `FolderNode` tree (name, full path,
      children, fileCount) from `library.files` paths relative to `rootStore.root` — no extra disk scan;
      recompute on library change. (fileCount also feeds D2.)
- [ ] **A3. Sidebar view + layout.** New `Views/SidebarView.swift`; wrap the window in
      `HStack { if showSidebar { SidebarView; Divider() }; mainContent }`. Folder section uses
      `OutlineGroup`/`DisclosureGroup`; "All Files" clears `pathPrefix`; selecting a folder sets it.
      Toolbar toggle (`sidebar.left`) + persisted width/visibility (`AppSettings`).
- [ ] **A4. Gate:** build+tests+lint · code review (matcher correctness, nil handling, 150k tree cost)
      · GUI test (toggle sidebar, expand tree, click folder → list scopes; capture) · commit + push.

## Milestone B — Smart Folders in the sidebar (1b) + create-from-filters (2)
- [ ] **B1. Smart Folders section** pinned at the top of the sidebar: list `SavedSearchStore.searches`;
      click → `applySaved`; context menu **Rename** / **Delete**. Add `SavedSearchStore.rename(id:name:)`.
- [ ] **B2. Create from current filters (item 2).** A "+" in the Smart Folders header AND a "Save as
      Smart Folder" button in the filter bar (shown when a filter/search is active) → the save sheet,
      pre-filled with a name derived from the active filters (`NavigationModel.suggestedSmartFolderName`).
      Reuses `SavedSearchStore.add(name:filter:fullTextQuery:)` (captures pathPrefix too).
- [ ] **B3. "Unsaved filters" hint** near the filter bar when the active view isn't a saved smart folder.
- [ ] **B4. Gate:** build+tests · code review (name dupes, delete safety, pathPrefix round-trips through
      Codable) · GUI test (create from a filter → appears in sidebar → click re-applies → rename →
      delete; capture) · commit + push. (No corpus writes — smart folders live in UserDefaults.)

## Milestone C — Item 4 small UI wins (each sub-item is its own commit)
- [ ] **C1. Column customization** — show/hide/reorder/resize persisted via SwiftUI
      `Table(…, columnCustomization:)` + a `.customizationID` per column, backed by `AppStorage`.
- [ ] **C2. Persist view state** across launches — sort, filter, `fullTextQuery`, tag-cloud open,
      sidebar visibility/width. Guard against restoring a `pathPrefix` from a different root.
- [ ] **C3. Row density (compact/comfortable) + list font size** — `AppStorage`, controls in Options
      (⌘,); applied to the table cells.
- [ ] **C4. Active-filter summary** — a human-readable line in the status bar
      ("Unread · P8 · tag: Jerry Brown · folder: …").
- [ ] **C5. Focus shortcuts** — ⌘L focus tag filter, ⌥⌘F focus OCR search, Esc clears filters/search
      (menu commands + `FocusState`). (Type-to-select is native.)
- [ ] **C6. Tag-cloud context menu** — right-click a tag → "Add as filter (All / Any)" and
      "Select files with this tag".
- [ ] **C7. "Open with Preview / default app"** in the row context menu (read-only via `NSWorkspace`).
- [ ] **C8. Quick read/unread toggle** — a single-click affordance on the Read cell (⚠ new write path →
      `TagWriter`, verify on scratch), alongside the existing ⌘R/⌘U.
- [ ] **C9. Tooltips + accessibility pass** for the tag cloud + inline editors.
- [ ] **C-gate:** after each Cx: build+tests(+lint for C8) · quick code review · GUI check · commit+push.

## Milestone D — Item 5 (bigger)
- [ ] **D1. Corpus-wide tag rename** (controlled vocabulary). Entry: tag-cloud context menu "Rename
      tag…" and a Tags-menu command. Sheet shows the affected-file count; on confirm, a **batch**: per
      file carrying X, `TagWriter.apply(remove X, add Y)` → `applyVerifiedWrites(batch)` + **one grouped
      undo**. Independent idempotent units; **surface partial failure** ("renamed N of M; k could not").
      **Tier-2:** adversarial code review + an integration test renaming a tag across scratch copies
      (assert every affected file updated, others untouched, bytes unchanged, undo restores).
- [ ] **D2. Live count badges** on sidebar folders (from `FolderNode.fileCount`) and smart folders
      (files matching the saved filter; cache to avoid O(searches·N) on every render).
- [ ] **D-gate:** build+tests+lint · **adversarial review of D1's write path** (Safety §§1–12) ·
      GUI + **smoke** on scratch (rename a tag on several files; `xattr`-verify; undo) · commit + push.

## Milestone E — Final review, full smoke test, docs
- [ ] **E1. Adversarial code review** (multi-agent) over the new code — focus on the D1 write path, the
      reactive/eventual-consistency class (sidebar/filter/state-persistence interactions), and the
      Equatable/render class. Fix all confirmed findings.
- [ ] **E2. Extend `SMOKE_TEST.md`** with new steps (sidebar folder-scope, smart-folder
      create/apply/rename/delete, column-customization + view-state persistence across relaunch, tag
      rename + undo) **and regression the 14 shipped Batch-1 features**; run the full driven GUI smoke
      test on the scratch corpus.
- [ ] **E3. Update docs** — `STATUS.md`, `KNOWN_ISSUES.md`, `CLAUDE.md` §Implementation map, and mark
      `NEAR_TERM_UI.md` items done. Commit + push.

## Order & dependencies
A → B (sidebar is one coherent slice; do first) → C1…C9 (independent; any order) → D1 (needs review) +
D2 → E. C2 depends on A/B existing (persists their state). D2 depends on A2 (fileCount) + B1.

## Touch map (expected files)
`Core/LibraryFilter.swift` (pathPrefix), `Views/NavigationModel.swift` (folderTree, pathPrefix,
suggestedSmartFolderName, renameTag), `Search/SavedSearch.swift` (rename), `Views/SidebarView.swift`
(new), `Views/NavigationWindowView.swift` (layout, filter-bar button, column customization, status
summary, context menus, shortcuts), `Views/OptionsView.swift` (density/font), `Core/AppSettings.swift`
(persistence), new `Views/RenameTagSheet.swift`, `Tests/…` (pathPrefix matcher, tag-rename integration).
