# Archive Notes — W6: Viewers (note & extract 3-pane), search/filter/sort, replication UI, templates, dates & quality
> Status: PROPOSED · part of Archive Notes (see 00-overview.md) · Wave 6

> ⚠️ **Canonical shared types & cross-wave APIs are defined in `00-overview.md` §16 (Interface Contract).** Where a sketch in this file differs — store type/name (`actor NoteStore` + `@MainActor NotesModel`/`OrganizationStore`), `DurableLink`/`RootMarker`, the single `NotesFilter` type, template-assignments-only, the index `items` projection, the `archivenotes://open?id=` grammar — **the overview is authoritative.**


## Goal
Build the DevonThink-style browsing surface for Archive Notes: one reusable **3-pane shell** (folder tree │ item list │ detail) instantiated as two windows — a **Note viewer** and an **Extract viewer** — with a **mutable, id-keyed virtual folder tree** (net-new relative to Reader's read-only path tree), a **virtualized item list** with sortable columns and a notes/extracts/both segmented control, **keyword+tag+kind+quality+date-range** filtering with bm25 relevance search and SPEC `sortDate` chronological sort, **replication UI** (visual replicant marks, "show all locations", and the mandatory delete-last-instance guard), **template assignment + "New from template"**, and **priority-style date and quality controls** that write front-matter (not Finder tags). Everything reuses Reader's shipped 3-pane/table/filter/priority-cell code, adapted from path identity to UUID identity and from tags to front-matter (per 00-overview §1, §3.6–3.7, §7, §D9).

## Dependencies
- **W1** (`01`) — the `ArchiveNotes/` app scaffold (`@main`, scenes, entitlements, `./launch.sh notes`) and the **ArchiveCore** package. W6 consumes `ArchiveCore.DocumentTags.sortDate` (00-overview §7, §10) for chronological sort, and `RootMarker` only indirectly. **Blocking.**
- **W2** (`02`) — the durable data layer W6 renders and drives. W6 assumes these W2-owned surfaces exist (net-new; named here so an implementer can stub/verify against them):
  - `struct NoteItem` (front-matter model per 00-overview §3.1) and a light index projection `struct NoteListItem` (see Design) queried from the DB, **not** by reading every `.md`.
  - `@MainActor final class NotesStore` — `create(kind:in:template:)`, `save(_:)`, atomic front-matter writers for individual fields, and the **audited `deleteItem(id:)`** (the file-deleting primitive; 00-overview §3.6, §12 lists it under W2 Tier-2). W6 provides the *guard + wiring*, W2 provides the *delete primitive*.
  - `@MainActor final class OrganizationStore` — the persistent folder/membership/template graph + `organization.json` atomic export (00-overview §3.6, §11).
  - `actor NotesIndex` — FTS5 search returning bm25-ranked ids, and a filtered/sorted row projection (00-overview §11).
  - `NotesTagProjector` — the audited subject→Finder-tag mirror (00-overview §9). W6 never calls the raw tag API; a subject edit made in a W6 control routes through W2's projector.
  - **Blocking.**
- **W3** (`03`) — the rich-text/Markdown editor view (`NoteEditorView`, opened over a `NoteItem`) that fills the shell's **detail pane**. W6 embeds it for notes; the extract read-view is a thin W3 wrapper. **Blocking for the detail pane; the tree/list/filter panes can be built and GUI-verified against a placeholder detail view if W3 lags.**
- W4/W5 are **not** required by W6 (source-block rendering and Zotero chips are additive inside the W3 detail pane).

## Design

### 0. Assumed W2 model surface (referenced, not defined here)
```swift
// 00-overview §3.1 — authoritative in front-matter; W2 owns the type.
enum ItemKind: String, Codable, Sendable { case note, extract }

// The light row the list/tree render — projected from the index DB (§11), NOT by reading .md.
struct NoteListItem: Identifiable, Hashable, Sendable {
    let id: UUID                 // == item folder name; stable link identity (§D1)
    var kind: ItemKind
    var title: String
    var authors: [String]
    var sortDate: Int?           // ArchiveCore.DocumentTags.sortDate(...) — nil = undated
    var displayDate: String      // e.g. "1968", "1970s", "March 1968"
    var dateUncertain: Bool
    var quality: Int?            // 1...5, 5 highest (§D9)
    var tags: [String]
    var modified: Date
    // folderCount is NOT stored here — it is joined in from OrganizationStore at render
    // time so replication changes don't force an index rewrite.
}

// 00-overview §3.6
enum FolderKind: String, Codable, Sendable { case normal, smart }
struct Folder: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var parentId: UUID?
    var sortOrder: Int
    var templateId: UUID?
    var kind: FolderKind
    var savedQuery: NotesFilter?   // populated for .smart folders
}
struct Membership: Codable, Hashable, Sendable { let itemId: UUID; let folderId: UUID; let addedAt: Date }
```
If W2 names these differently, W6 adapts at the seam; the **shapes** above are dictated by 00-overview and must hold.

---

### 1. The 3-pane shell + two windows  *(NEW)*

**File: `ArchiveNotes/macOS/Sources/ArchiveNotes/Views/NotesBrowserView.swift` (NEW).**
Direct adaptation of `NavigationWindowView.body`'s HStack (`ArchiveReader/macOS/Sources/ArchiveReader/Views/NavigationWindowView.swift:18-40`). Three panes instead of two:

```swift
struct NotesBrowserView: View {
    @StateObject private var model: NotesNavigationModel
    let defaultKind: ItemKind            // .note → Note viewer, .extract → Extract viewer

    @AppStorage("an.showTree")   private var showingTree = true
    @AppStorage("an.treeWidth")  private var treeWidth   = 220.0   // ↔ NavigationWindowView.swift:10
    @AppStorage("an.detailFrac") private var detailFrac  = 0.42    // list/detail split as a fraction
    @AppStorage("an.listWidth")  private var listWidth   = 360.0

    var body: some View {
        HStack(spacing: 0) {
            if showingTree {
                NotesFolderTreeView(model: model)
                    .frame(width: treeWidth)
                    .transition(.move(edge: .leading))
                NotesPanelDivider(width: $treeWidth, panelOnLeft: true, range: 160...400)
            }
            NotesItemListPane(model: model)          // filter bar + table + status
                .frame(minWidth: 320)
            NotesPanelDivider(width: $listWidth, panelOnLeft: true, range: 260...900)
            NotesDetailPane(model: model)            // W3 editor (note) or read-view (extract)
                .frame(minWidth: 300)
        }
        .frame(minWidth: 1040, minHeight: 620)
        .toolbar { toolbar }
        .navigationTitle(defaultKind == .note ? "Archive Notes" : "Archive Notes — Extracts")
        .background(WindowSizePersister(size: $model.windowSize))   // see below
    }
}
```

- **`NotesPanelDivider` (NEW file `Views/NotesPanelDivider.swift`)** — a byte-for-byte copy of the `private struct PanelDivider` at `NavigationWindowView.swift:460-491` (it is `private`, so it cannot be imported; it is pure UI, so it does **not** belong in the UI-free ArchiveCore). Made non-`private` and shared by both panes.
- **Two windows** = the same `NotesBrowserView` seeded with `defaultKind`. In `ArchiveNotesApp.swift` (W1) add two SwiftUI scenes: `WindowGroup(id: WindowID.notes)` and `WindowGroup(id: WindowID.extracts)`, each rendering `NotesBrowserView(defaultKind:)`. The Extract window's list defaults its kind segmented control to `.extracts`; the Note window to `.notes`. This satisfies "two windows sharing one shell" without duplicating layout code.
- **Persisted window size** — mirror `AppSettings.viewerWindowSize` / `setViewerWindowSize` (`ArchiveReader/macOS/Sources/ArchiveReader/Core/AppSettings.swift:60-67`). A tiny `WindowSizePersister: NSViewRepresentable` reads its `NSWindow` on `viewDidMoveToWindow`, observes `didResizeNotification`, and writes W/H into `NotesAppSettings` (NEW; see §8). Panel widths persist via `@AppStorage` exactly as Reader does (`NavigationWindowView.swift:9-12`).

**Concurrency:** `NotesBrowserView`, `NotesNavigationModel`, and every pane view are `@MainActor` (SwiftUI default). `@AppStorage` keys are all `an.`-prefixed to avoid collision with Reader's `ar.` keys in a shared defaults domain (the two apps have distinct bundle ids, so domains are already separate — the prefix is belt-and-suspenders and self-documenting).

---

### 2. Mutable folder tree  *(NEW — net-new model layer)*

Reader's tree (`FolderNode`, `NavigationModel.swift:7-15`, `buildFolderTree` L568-594) is **derived read-only from file paths** and keyed by absolute path. Notes' tree is **user-authored, id-keyed, and mutable** — a different model with a different build algorithm.

**File: `Views/NotesFolderTreeView.swift` (NEW)** — adapts `SidebarView` (`ArchiveReader/macOS/Sources/ArchiveReader/Views/SidebarView.swift:18-98`):

```swift
struct NotesFolderNode: Identifiable, Hashable, Sendable {
    let id: UUID                     // Folder.id — NOT a path (the key difference from Reader)
    var name: String
    var kind: FolderKind
    var templateId: UUID?
    var itemCount: Int               // DISTINCT items in this subtree (memberships de-duped)
    var children: [NotesFolderNode]
    var childrenOrNil: [NotesFolderNode]? { children.isEmpty ? nil : children }   // ↔ FolderNode.swift:13-14
}
```

- **Tree build** — `NotesNavigationModel.buildFolderTree()` converts `OrganizationStore.folders` (an adjacency list via `parentId`) into `NotesFolderNode`s. Algorithm differs from Reader's path-split (`buildFolderTree` L568-594): group folders by `parentId`, sort siblings by `sortOrder` then localized name, recurse; compute `itemCount` by unioning membership item-ids over the subtree (replicants counted once). O(F + M). Cite Reader L587-593 for the recursive-convert shape.
- **Rendering** — `List(selection:)` + `OutlineGroup(root.children, children: \.childrenOrNil)` exactly as `SidebarView.swift:53-59`, tagging rows by `node.id.uuidString`. Two sections: **Smart Folders** (kind `.smart`, badge = live match count) above **Folders** (kind `.normal`), mirroring `SidebarView.swift:26-60`. An **"All Notes"** pseudo-row (like `SidebarView.allFilesTag`, L20) clears the folder scope. A separate **"Templates"** disclosure row anchors the template area (§6).
- **Two-way selection sync** — copy `SidebarView`'s `@State selection` + `applySelection`/`syncSelectionFromModel` (`SidebarView.swift:23,63-87`) verbatim in spirit: clicking a folder calls `model.setFolderScope(folderId)`; external scope changes mirror back. The comment at `SidebarView.swift:8-13` (why `@State` beats a computed `Binding` for `OutlineGroup`) applies unchanged.
- **Smart folder as scoped root** — selecting a `.smart` folder calls `model.applyScope(folder.savedQuery!)`, reusing the exact scope semantics shipped in Reader (`NavigationModel.applyScope` L204-216, `clearUserFilters` L219-230, `effective` merge in `LibraryFilter.effective` L97-109). Smart folders in Notes persist their `NotesFilter` in the `Folder` record rather than in a separate `SavedSearch` store, but behave identically (base scope = visible universe; user filters AND on top; selecting a normal folder / All Notes exits).

**Mutations (the net-new part), all routed through `OrganizationStore` (W2) which persists to DB + `organization.json` atomically:**

```swift
extension NotesNavigationModel {
    func createFolder(name: String, under parentId: UUID?)            // context-menu "New Folder"
    func renameFolder(_ id: UUID, to newName: String)                 // inline edit / sheet
    func moveFolder(_ id: UUID, newParent: UUID?, at index: Int)      // drag reorder / reparent
    func deleteFolder(_ id: UUID)                                      // folder only — see below
}
```
- **Rename** — an inline `TextField` in the row (double-click to edit) or a small sheet reusing the alert pattern at `NavigationWindowView.swift:64-73`. Empty/whitespace names rejected; siblings deduped with the ` 2`, ` 3` suffix logic copied from `SavedSearchStore.uniqueName` (`ArchiveReader/macOS/Sources/ArchiveReader/Search/SavedSearch.swift:63-69`).
- **Move/reorder** — `.onMove` for sibling reorder (copy `SidebarView.swift:39` + `SavedSearchStore.move` L50-59), and drag-reparent via the drop machinery in §5. A folder cannot be dropped into its own descendant — `OrganizationStore.moveFolder` must reject a cycle (guard: walk `parentId` chain of the target; refuse + surface a status message if `id` appears).
- **Delete folder** — deleting a *folder* is **not** deleting items. It removes the folder + its memberships **for that folder only**; child folders are reparented to the deleted folder's parent (never orphaned). Items that lose their *last* membership as a side effect trigger the same delete-last-instance guard as §5 (a folder delete can strand a note). Edge case: deleting a folder containing 500 items where 30 are sole-instance → present a **single batched** confirmation listing the 30 sole-instance titles, not 30 modals.

**Edge cases / graceful degradation:** empty store → tree shows only "All Notes"/"Templates"; a `smart` folder whose `savedQuery` fails to decode → shown but selecting it surfaces "This smart folder's saved query is unreadable" and falls back to All Notes (mirrors Reader's `sanitizedPathPrefix` degrade, `NavigationModel.swift:417-422`); an item with zero memberships (transient, e.g. mid-drag) is still discoverable under "All Notes" so it can never be lost from view.

---

### 3. Item list — virtualized table  *(NEW)*

**File: `Views/NotesTableView.swift` (NEW)** — adapt `AppKitTableView` (`ArchiveReader/macOS/Sources/ArchiveReader/Views/AppKitTableView.swift`) wholesale: same `NSViewRepresentable` + `NSTableViewDiffableDataSource<Int, UUID>` + `Coordinator` + `ColumnPickerHeaderView` + `ContextMenuTableView` structure. In-memory scale is proven — Reader holds up to ~150k `ArchiveFile` and this table stays smooth (CLAUDE.md), so 100k `NoteListItem` is within the demonstrated envelope; no separate virtualization work is needed beyond copying this file.

- **Data** — `NotesNavigationModel.displayed: [NoteListItem]`; the diffable snapshot is `displayed.map(\.id)` (copy `applySnapshot` L204-211). `displayedByID` cache copied from L97/L132.
- **Columns** (copy the column table at `AppKitTableView.swift:67-88`; keep `ColumnPickerHeaderView` hide/show + secondary-sort menu verbatim, L483-576):

  | id | title | sortField | cell |
  |----|-------|-----------|------|
  | `kind` | ⬦ | `.kind` | glyph: note = `doc.text`, extract = `quote.opening` |
  | `title` | Title | `.title` | text; **replicant styling** (see §5) |
  | `instances` | In | `.instances` | membership count "▣ 3"; blank if 1 (the "aliases-style" column) |
  | `date` | Date | `.date` | `displayDate`; **italic when `dateUncertain`** (copy L286-288) |
  | `quality` | Quality | `.quality` | "★★★★☆"/"—" |
  | `tags` | Tags | `.tags` | comma-joined subjects (read-only here; edited in detail/⌘I) |

- **Kind segmented control** — a `Picker(.segmented)` in the list pane's filter bar (see §4) with `notes / extracts / both`, bound to `model.filter.kind`. This is what makes the two windows differ by default yet remain the same shell; changing it re-scopes the list live.
- **Sorting** — reuse the header-click → `sortDescriptorsDidChange` → `model.sort` bridge (`AppKitTableView.swift:104,362-371`) and the `NotesSort`/`SortField` model in §4. `ColumnPickerHeaderView` secondary-sort and column hide/show carried over unchanged (persist hidden columns via `NotesAppSettings.hiddenColumns`, mirroring `AppSettings.hiddenColumns` L69-74).
- **Selection** — `@Binding var selection: Set<UUID>`; selecting a single row loads it into the detail pane (§1) via `model.select(id)`. Double-click opens the item in a dedicated editor window (future) or focuses the detail editor.
- **Context menu** (copy `buildNSContextMenu` shape, `NavigationWindowView.swift:124-147`): *Open · Reveal in Finder · Copy Archive Link (archivenotes://open?id=…, from §D8 — populated in W4) · Add to Folder… · Move to Folder… · Remove from This Folder · New from Template · Set Quality ▸ · Delete…*.

**Concurrency:** the `Coordinator` and all cells are `@MainActor` (as in the Reader original). `NoteListItem` is `Sendable`, crossing from the `NotesIndex` actor to the main actor cleanly.

---

### 4. Search + filter + sort  *(NEW)*

**File: `Core/NotesFilter.swift` (NEW)** — adapt `LibraryFilter` (`ArchiveReader/macOS/Sources/ArchiveReader/Core/LibraryFilter.swift:20-110`):

```swift
enum KindFilter: String, Sendable, CaseIterable, Codable { case notes, extracts, both }

struct NotesFilter: Sendable, Equatable, Codable {
    var kind: KindFilter = .both
    var tags: Set<String> = []
    var tagCombine: SubjectCombine = .all          // reuse Reader's enum verbatim (LibraryFilter.swift:14-17)
    var qualities: Set<Int> = []                   // subset of 1...5; empty = any (↔ priorities, LibraryFilter.swift:22)
    var dateFrom: Int? = nil                        // sortDate ints (year*10000+month*100+day)
    var dateTo: Int? = nil
    var folderId: UUID? = nil                       // folder scope — the id analog of pathPrefix (LibraryFilter.swift:29)
    var searchText: String = ""                     // title substring
    var isActive: Bool { kind != .both || !tags.isEmpty || !qualities.isEmpty
        || dateFrom != nil || dateTo != nil || folderId != nil
        || !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    // `matches` mirrors LibraryFilter.matches (L43-72) but over NoteListItem + a membership set the
    // model supplies (folder scope is a DB membership test, not a path-prefix test).
    func matches(_ item: NoteListItem, folderItemIDs: Set<UUID>?) -> Bool { … }
}
```
- **Folder scope** — because membership is a graph, not a path prefix, the model resolves `folderId` → `Set<UUID>` of item ids in that folder's subtree (from `OrganizationStore`) once per recompute, and `matches` tests set membership. This replaces `LibraryFilter`'s `pathPrefix` string test (L45-48). Tolerant `init(from:)` (copy `LibraryFilter.swift:79-90`) so smart folders persisted by older builds decode.
- **`NotesSort`** — copy `SortField`/`ARSortDescriptor`/`LibrarySort` (`LibraryFilter.swift:114-212`) verbatim, replacing the field set with `title, date, kind, quality, relevance`. **`sortDate` chronological sort reuses `nilLast` (L195-202)** so undated items sort last in both directions; quality sort likewise nil-last. Default sort = `[date asc, title asc]` (copy `LibrarySort.default` L124-128).
- **Keyword FTS + debounce + relevance** — copy `NavigationModel`'s search pipeline exactly:
  - `@Published var searchText` + a 150 ms debounce Combine pipeline (`NavigationModel.swift:88-103`) copying into `filter.searchText` (title substring) **and** driving the FTS query.
  - `runFullTextSearch()` with a generation token (`NavigationModel.swift:426-454`): `await NotesIndex.search(q)` → `ftsIDs: Set<UUID>` + `ftsRank: [UUID:Int]`; auto-switch `sort` to `.relevance` while a query is active and back to default on clear (L435-440). bm25 column weights per 00-overview §11 (title 10 · tags 6 · authors 4 · body 1 · linked-doc names 3) — set in W2's index; W6 just consumes the ranked order.
  - `recompute()` (copy `NavigationModel.swift:327-351`): filter `allItems` by scope set → `filter.matches` → intersect `ftsIDs` → order by `ftsRank` when `.relevance` else `LibrarySort.sorted`.
- **Filter bar** (`Views/NotesFilterBar.swift`, NEW) — adapt `NavigationWindowView.filterBar` (L244-311):
  - kind segmented `Picker` (§3);
  - **quality toggles** — a row of button-toggles `★1…★5` copied structurally from the priority toggles at `NavigationWindowView.swift:256-267` (there `[10,9,8,7]`; here `[5,4,3,2,1]`), binding `filter.qualities`;
  - tag filter field + chips (copy `subjectFilterField` L318-344, including the ALL/ANY `subjectCombine` segmented picker);
  - a **date-range** control: two compact `DatePrecisionField`s (§7) or plain year fields → `dateFrom`/`dateTo`;
  - keyword search field with the FTS indicator + clear button (copy L276-290);
  - "Save as Smart Folder" + "Clear" (copy L303-308; Save writes a `.smart` `Folder` with the effective `NotesFilter`).

**Edge cases:** empty query clears `ftsIDs` (no filtering); a stale generation result is dropped (copy the `generation == self.ftsGeneration` guard, L444); an item indexed after a search runs is folded in on index-pass completion via `refreshFullTextSearchIfActive` (copy L459-466).

---

### 5. Replication UI + drag + **delete-last-instance guard**  *(NEW — Tier-2)*

**Visual replicant marks.** In `NotesTableView.makeCell` for the `title` column, when `folderCount > 1` render the title with a subtle distinguishing style — a leading chain glyph `􀯚`/color accent and/or italic — reusing the attributed-string + colored-glyph technique already in `AppKitTableView.swift:291-309` (the box/folder dot) and the italic technique at L286-288. The `instances` column shows the count. `folderCount` is joined from `OrganizationStore.membershipCount(itemId:)` at render (kept out of `NoteListItem` so replication edits don't rewrite the index).

**"Show all locations."** A detail-pane inspector section (and a context-menu item) listing every folder an item belongs to: `OrganizationStore.folders(forItem: id)` → a small `List` of folder rows (reuse `SidebarView.row`, `SidebarView.swift:89-97`); clicking a row navigates the tree to that folder (`model.setFolderScope`). Each row has a **Remove-from-this-folder** control that runs the guarded removal below.

**Drag — move vs replicate.**
- **Drag source:** table rows are draggable, providing item ids. Since the table is AppKit, implement `NSTableViewDataSource.tableView(_:pasteboardWriterForRow:)` returning an `NSPasteboardItem` carrying a custom UTI `com.archivenotes.item-ids` (JSON `[uuidString]`) — ids only, `Sendable`, no file bytes.
- **Drop target:** folder rows in `NotesFolderTreeView`. Because modifier-key detection is unreliable in SwiftUI's `dropDestination`, implement the drop on the AppKit side (or a small `NSView` drop overlay) via `NSDraggingDestination`, reading `NSEvent.modifierFlags` at drop:
  - **Default drag = MOVE** — `OrganizationStore.removeMembership(item, from: sourceFolder)` + `addMembership(item, to: target)`. If the drag originates from "All Notes"/search (no single source folder), MOVE degrades to a pure **add** (nothing to remove from).
  - **⌥ Option drag = REPLICATE** — `addMembership(item, to: target)` only; source memberships untouched (this is the DevonThink replicant — one file, K places).
  - `dropOperation` shows `.move` vs `.copy` cursor accordingly. A **context-menu fallback** ("Add to Folder…" / "Move to Folder…" via a folder picker) provides the same operations for keyboard/accessibility users.
- Dropping an item onto a `.smart` folder is refused (smart folders are queries, not containers) — surface "Smart folders can't hold items directly."

**Delete-last-instance guard (the crown-jewel W6 safety surface).** Two entry points remove a membership: the "Remove from this folder" control and a MOVE drag's source-removal. The guard wraps **every** membership removal:

```swift
func removeMembership(_ itemId: UUID, from folderId: UUID) {
    let remaining = organization.membershipCount(itemId: itemId) - 1     // AFTER this removal
    if remaining > 0 {
        organization.removeMembership(itemId: itemId, folderId: folderId) // quiet — a replicant
        return
    }
    // Last instance → this removal deletes the underlying note. MANDATORY confirmation (§3.6, §9).
    pendingLastInstance = (itemId, folderId, title: titleFor(itemId))
    showLastInstanceModal = true
}
```
- The modal (an `.alert`, copying the presentation pattern at `NavigationWindowView.swift:53-73`) reads **exactly** as specified in 00-overview §3.6: *"This is the only remaining instance of '<title>' — deleting it removes the note permanently."* Buttons: **Delete Note** (`.destructive`) and **Cancel** (`.cancel`, default). No silent path exists.
- On confirm: `organization.removeMembership(...)` **then** `NotesStore.deleteItem(id:)` (the W2 audited primitive). Deleting a *replicant* (remaining > 0) is quiet, no modal.
- **Batched variant** for folder-delete (§2): if a folder delete would strand N ≥ 1 sole-instance items, present **one** modal listing those titles ("Deleting this folder will permanently delete N notes that exist nowhere else: …") before any write.

**File-safety notes (Tier-2).**
- `NotesStore.deleteItem` (W2) is the only file-deleting call; W6 never unlinks. **Mitigation: it must delete via `FileManager.trashItem(at:resultingItemURL:)` (macOS Trash — recoverable), not `removeItem`**, even though the UI copy says "permanently." Recoverability is a strict upgrade over the promise and matches the Suite's irreplaceable-data ethos (00-overview §12). Wrap in `NSFileCoordinator` for a coordinated move-to-trash.
- W6 writes only `organization.json` + the index DB (app-owned org data, atomic) and — via W2 — the item's own `.md`/folder. **It never touches the Reader/Processor corpus.** All dev/test membership + delete exercises run on a scratch `<NotesStore>` created with `mktemp -d` (00-overview §12; Reader Prime Directive), never the owner's real store.
- Subject-tag edits made anywhere in W6 route through W2's `NotesTagProjector` (00-overview §9) — W6 imports no tag-write API.
- The delete-last-instance detection must read `membershipCount` **freshly** from `OrganizationStore` at click time (no cached count), so a concurrent replicate in another window can't cause a false "last instance." (Analogous to `TagWriter`'s fresh-read-inside-the-write-block rule, Reader Safety Protocol §2.)

**Concurrency:** all of this is `@MainActor` on `NotesNavigationModel`/`OrganizationStore`. The modal state (`showLastInstanceModal`, `pendingLastInstance`) is main-actor `@Published`. `deleteItem` is `async` (coordinated I/O) — awaited; the model recomputes `displayed` and refreshes the tree's `itemCount` after it returns.

---

### 6. Templates  *(NEW)*

**Model (W2-owned, per 00-overview §3.7):** `Template { id, name, kind, bodyMarkdown, frontmatterDefaults }`, stored as real `.md` files under `<NotesStore>/Templates/` plus an index entry; `Folder.templateId` assigns one to a folder.

**W6 UI:**
- **Assignment** — a folder context-menu submenu **"Template ▸ (None / … each template … / Manage…)"** setting `Folder.templateId` via `OrganizationStore.setTemplate(folderId:templateId:)`. Reuse the `Menu`/`Picker` idiom from `InlineEditCells.PriorityCell` (`ArchiveReader/macOS/Sources/ArchiveReader/Views/InlineEditCells.swift:34-42`).
- **"New note from template"** — resolves the effective template: the selected folder's `templateId`, else the **nearest ancestor's** (walk `parentId` up the tree until a `templateId` is found), else "Blank". `NotesStore.create(kind:in:template:)` instantiates: copy `bodyMarkdown` into the body, seed front-matter from `frontmatterDefaults` (title/date/quality/tags per §3.1), assign a fresh UUID + `created`/`modified`, add a membership to the target folder, then open it in the W3 detail editor. Available from the toolbar (`+` menu), the folder context menu, and `⌘N` (routes to nearest-ancestor template of the current scope).
- **Template management** — a **"Templates"** area anchored by the sidebar row (§2). Selecting it lists the templates as ordinary items; **editing a template opens it in the normal W3 editor** (they *are* notes) but writes back to `Templates/`. New/duplicate/rename/delete templates via `OrganizationStore`. A template can be `kind: note` or `kind: extract` (00-overview §3.7); "New from template" only offers templates matching the active window's default kind.

**Edge cases:** a folder whose `templateId` points at a deleted template → treated as "no template" (fall through to ancestor/blank), and the assignment is lazily cleared. Deleting a template used by K folders → clear those assignments (batched) and warn.

**File-safety:** template `.md` files live inside the Notes store (never the corpus); creation/edit use W2's atomic front-matter writer.

---

### 7. Dates UI  *(NEW)*

**File: `Views/NoteMetadataInspector.swift` (NEW)** — a detail-pane inspector strip; the date sub-control adapts `InlineEditCells.DateCell` (`ArchiveReader/macOS/Sources/ArchiveReader/Views/InlineEditCells.swift:48-110`) and `TagEditorView.dateSection` (`ArchiveReader/macOS/Sources/ArchiveReader/Views/TagEditorView.swift:96-131`), but writes **front-matter** (`date`, `date_precision`, `date_uncertain`) instead of tags.

```swift
enum DatePrecision: String, Codable, Sendable, CaseIterable { case decade, year, month, day }  // §7
```
- A compact control: a `Picker(.segmented)` for precision `decade | year | month | day`, precision-appropriate fields (decade → a 4-digit start-year ending in 0 rendered "1970s"; year → year; month → year + month menu copied from `DateCell.monthBinding` L102-105; day → year + month + day), and a **"Date uncertain"** `Toggle` copied from `DateCell.uncertainBinding` (L96, L106-109).
- Setting a value calls `NotesStore` field writers (`setDate`, `setDatePrecision`, `setDateUncertain`) which rewrite front-matter atomically and re-index. `sortDate` is recomputed via **`ArchiveCore.DocumentTags.sortDate`** exactly per the SPEC (00-overview §7, §10) — decade `1970` → `19_700_000`, uncertain still sorts by its value (rendered italic, never dumped last), matching Reader (`InlineEditCells.swift:62-63,107-108`).
- Validation reuses Reader's ranges (`DateCell` L78-79: year `100...9999`, day `1...31`).

**File-safety:** front-matter only; no Finder-tag date write this run (00-overview §7, §D2). Atomic write via W2.

---

### 8. Quality UI  *(NEW — modeled exactly on Reader's priority)*

Quality is Reader's priority pattern re-skinned to a 1..5 front-matter field (00-overview §D9): "None + 1..5, 5 highest."

- **Inline/detail control** — a `QualityControl` copied from `InlineEditCells.PriorityCell` (`InlineEditCells.swift:30-45`): a borderless `Menu` with **None** then `ForEach([5,4,3,2,1])` (Reader uses `[10,9,8,7]`, L36), each calling `model.setQuality(_:for:)`. Label renders `★★★★☆`/"—".
- **Group/inspector control** — a facet-button row copied from `TagEditorView.prioritySection` (`TagEditorView.swift:135-145`) using the shared `facetButton(label:current:action:)` helper (`TagEditorView.swift:195-199`), buttons **None · 1 · 2 · 3 · 4 · 5**, highlighting the current value.
- **Filter** — the `★1…★5` toggle row in the filter bar (§4), copied from the priority toggles at `NavigationWindowView.swift:256-267`.
- **Sort** — `SortField.quality`, nil-last, via the `LibrarySort` pattern (§4; `LibraryFilter.swift:168-169`).

**Critical distinction:** quality writes the **front-matter `quality` key**, **never a Finder tag** (00-overview §D9, §9). `model.setQuality` calls W2's `NotesStore.setQuality(_:for:)` atomic front-matter writer. It does **not** touch `NotesTagProjector`. This is the one place an implementer could wrongly mirror to a tag — do not.

---

### 9. View model  *(NEW)*
**File: `Views/NotesNavigationModel.swift` (NEW)** — the W6 orchestrator, a `@MainActor final class … : ObservableObject` shaped after `NavigationModel` (`ArchiveReader/macOS/Sources/ArchiveReader/Views/NavigationModel.swift:19-131`): holds `filter`/`sort`/`selection`/`displayed`, the debounce pipelines (L88-103), `recompute()` (L327-351), `runFullTextSearch()` (L431-454), scope methods (L204-256), and the folder/membership/template/date/quality actions above. Owns `allItems: [NoteListItem]` refreshed from the index on store change (the in-memory mirror justified by Reader's 150k `library.files`). `Sendable` domain types cross from the `NotesIndex` actor.

## Reuse from the existing codebase
- **3-pane HStack + divider + persisted widths** — `ArchiveReader/macOS/Sources/ArchiveReader/Views/NavigationWindowView.swift:18-40` (HStack), `:460-491` (copy `PanelDivider` into a shared `NotesPanelDivider`), `:9-12` (`@AppStorage` width pattern).
- **Persisted window size accessor** — `ArchiveReader/macOS/Sources/ArchiveReader/Core/AppSettings.swift:60-67` (`viewerWindowSize`/`setViewerWindowSize`); also `:69-74` (`hiddenColumns`) for the table's column persistence; adopt the whole `enum SettingsKey`/`enum AppSettings` accessor idiom for `NotesAppSettings`.
- **Sidebar tree rendering + two-way selection sync** — `ArchiveReader/macOS/Sources/ArchiveReader/Views/SidebarView.swift:26-67` (`List(selection:)` + `OutlineGroup`), `:63-87` (sync), `:89-97` (`row`), `:39` (`.onMove`). Adapt from path-tag to `Folder.id`.
- **Read-only path tree to contrast/adapt** — `ArchiveReader/macOS/Sources/ArchiveReader/Views/NavigationModel.swift:7-15` (`FolderNode`), `:568-594` (`buildFolderTree` recursive-convert shape). Note the algorithm changes (path-split → parentId adjacency) and identity changes (path → UUID).
- **Search UX (debounce + generation + relevance + recompute)** — `NavigationModel.swift:88-103` (debounce), `:426-466` (`runFullTextSearch`/refresh), `:327-351` (`recompute`), `:204-256` (scope). Copy near-verbatim.
- **Scope-as-root smart-folder behavior** — `NavigationModel.applyScope` `:204-216`, `clearUserFilters` `:219-230`, `LibraryFilter.effective` `:97-109`, `setFolderScope` `:550-556`, `sanitizedPathPrefix` degrade `:417-422`.
- **Virtualized table (whole file)** — `ArchiveReader/macOS/Sources/ArchiveReader/Views/AppKitTableView.swift`: columns `:67-88`, diffable data source `:99-107`/`:204-211`, `makeCell` `:226-345` (esp. italic `:286-288` and colored-glyph attributed title `:291-321` for replicant/date styling), header sort bridge `:104,362-371`, `ColumnPickerHeaderView` `:483-576`, `ContextMenuTableView` `:580-601`.
- **Filter + sort model** — `ArchiveReader/macOS/Sources/ArchiveReader/Core/LibraryFilter.swift:20-73` (`LibraryFilter`/`matches`), `:79-90` (tolerant decode), `:97-109` (`effective`), `:114-212` (`SortField`/`ARSortDescriptor`/`LibrarySort` incl. `nilLast` `:195-202`). `SubjectCombine` enum `:14-17` reused verbatim.
- **Filter bar controls** — `NavigationWindowView.swift:244-311` (bar), esp. priority toggles `:256-267` (→ quality toggles) and `subjectFilterField` `:318-344` (→ tag filter + ALL/ANY).
- **Priority control → quality control** — `ArchiveReader/macOS/Sources/ArchiveReader/Views/InlineEditCells.swift:30-45` (`PriorityCell` menu), `ArchiveReader/macOS/Sources/ArchiveReader/Views/TagEditorView.swift:135-145` (`prioritySection`), `:195-199` (`facetButton`).
- **Date control** — `InlineEditCells.swift:48-110` (`DateCell` popover, month/uncertain bindings), `TagEditorView.swift:96-131` (`dateSection`). Rewrite the write target to front-matter.
- **Name-dedup / smart-folder naming** — `ArchiveReader/macOS/Sources/ArchiveReader/Search/SavedSearch.swift:63-69` (`uniqueName`), `:50-59` (`move`) for folder rename/reorder.
- **Alert/sheet presentation for the delete-last-instance modal** — `NavigationWindowView.swift:53-73`.
- **Chronological sort key** — `ArchiveCore.DocumentTags.sortDate` (seeded from Reader per 00-overview §10); do **not** re-derive.

## Bounded sub-tasks

Each sub-task = one fresh overnight session: own worktree → clean build (`xcodegen generate` in `ArchiveNotes/macOS`, then `xcodebuild -scheme ArchiveNotes -configuration Debug -derivedDataPath ./build/DD build`), **no new warnings**, named unit tests, GUI check via `./launch.sh notes`, docs move in the same commit. Tier per 00-overview §12.

**S1 — 3-pane shell + two windows + persistence.** *(Tier-1)*
Scope: `NotesBrowserView`, `NotesPanelDivider` (copied), the two `WindowGroup` scenes in `ArchiveNotesApp.swift`, `NotesAppSettings` (window size + panel-width keys), placeholder tree/list/detail panes.
Steps: copy `PanelDivider`; build the HStack + two dividers; wire `@AppStorage` widths + `WindowSizePersister`; register `WindowID.notes`/`.extracts`.
Verify: build clean; `NotesAppSettingsTests` (persist/restore round-trip). GUI: `./launch.sh notes` — both windows open, panels resize + widths survive relaunch; `cliclick` drag on a divider then relaunch to confirm persistence.
Done: shell renders with placeholders; SUITE_TODO "W6 · 3-pane shell" `[x]`.

**S2 — mutable folder tree.** *(Tier-1; app-owned org writes, atomic)*
Scope: `NotesFolderNode`, `NotesFolderTreeView`, `NotesNavigationModel.buildFolderTree` + create/rename/move/delete-folder + `setFolderScope`; smart-folder scope wiring (`applyScope`).
Files: `Views/NotesFolderTreeView.swift`, additions to `NotesNavigationModel`. Depends on `OrganizationStore` (W2).
Steps: adjacency→tree build; OutlineGroup render + two-way sync (copy `SidebarView`); context-menu New/Rename/Delete; `.onMove` reorder; cycle-guard on reparent; smart-folder-as-scope.
Verify: `FolderTreeBuildTests` (adjacency→tree, sibling order, subtree count), `FolderMutationTests` (rename dedup, reparent-cycle rejection, delete reparents children), `SmartFolderScopeTests`. GUI: create/rename/nest/delete folders; select a folder scopes the list; select a smart folder enters scope; relaunch shows the tree (backed by `organization.json`).
Done: SUITE_TODO "W6 · mutable folder tree" `[x]`.

**S3 — item list table + kind segmented control.** *(Tier-1)*
Scope: `NotesTableView` (copied from `AppKitTableView`), columns (kind/title/instances/date/quality/tags), header sort + column hide/show, kind segmented control, single-select → detail load.
Files: `Views/NotesTableView.swift`, list-pane wrapper, `NotesNavigationModel.displayed`/`selection`.
Steps: adapt diffable data source keyed by UUID; implement `makeCell` per column; wire header sort to `NotesSort`; kind picker → `filter.kind`.
Verify: build clean at scale (seed a scratch store of 50k synthetic `NoteListItem`s and confirm smooth scroll/sort). `NotesTableSnapshotTests` (id-diff apply). GUI: list renders, columns sort/hide, kind toggle re-scopes, selection loads detail.
Done: SUITE_TODO "W6 · item list" `[x]`.

**S4 — search + filter + sort.** *(Tier-1)*
Scope: `NotesFilter`, `NotesSort`, filter bar (kind/tags/quality/date-range/keyword), debounce + FTS + relevance + `recompute`, folder-scope intersection, Save-as-Smart-Folder.
Files: `Core/NotesFilter.swift`, `Views/NotesFilterBar.swift`, `NotesNavigationModel` search pipeline. Depends on `NotesIndex.search` (W2).
Steps: copy `LibraryFilter`/`LibrarySort` adapting fields; copy debounce + generation-token FTS; wire quality toggles + tag chips + date-range + kind; intersect folder-scope set.
Verify: `NotesFilterTests` (kind/tag ALL-ANY/quality/date-range/scope), `NotesSortTests` (date nil-last, quality nil-last, relevance ordering), `SearchDebounceTests`. GUI: type a query → relevance sort + results; tag/quality/date filters compose; Save creates a smart folder that reopens.
Done: SUITE_TODO "W6 · search/filter/sort" `[x]`.

**S5 — replication UI + drag move/replicate + delete-last-instance guard.** *(Tier-2 — the delete path)*
Scope: replicant styling + `instances` column join, "show all locations" inspector, drag (ids-only pasteboard) with default-MOVE / ⌥-REPLICATE, context-menu Add/Move-to-Folder, and the guarded membership removal + single/batched delete-last-instance modal calling W2's trash-based `deleteItem`.
Files: `NotesTableView` (drag source + title styling), `NotesFolderTreeView` (drop), `NotesNavigationModel.removeMembership`/`deleteItem` wiring, `Views/LocationsInspector.swift`.
Steps: pasteboard writer; AppKit drop reading `NSEvent.modifierFlags`; fresh `membershipCount` guard; modal with the exact §3.6 wording; batched folder-delete confirmation; route deletion to `FileManager.trashItem` via coordinated write.
Verify (on a `mktemp -d` scratch store only): `MembershipTests` (move removes+adds, replicate adds-only, count join), `DeleteLastInstanceTests` (removal of last membership prompts + deletes; replicant removal is quiet; folder-delete batches sole-instance items; a concurrent replicate makes it NOT last), `TrashDeletionTests` (item lands in Trash, corpus untouched, `organization.json` consistent). **Adversarial review** of the guard + delete wiring. GUI: drag to move vs ⌥-replicate; replicated items show the mark + count; removing a replicant is silent; removing the sole instance shows the modal; confirm deletes to Trash.
Done: SUITE_TODO "W6 · replication + delete guard" `[x]`; `KNOWN_ISSUES.md` updated if any residual.

**S6 — templates.** *(Tier-1)*
Scope: folder `templateId` assignment menu, "New from template" (nearest-ancestor resolution), template area + management (edit-as-note), kind-matched offering.
Files: `Views/NotesFolderTreeView.swift` (assignment menu, Templates row), `NotesNavigationModel` template actions. Depends on `OrganizationStore.setTemplate` + `NotesStore.create(...:template:)` (W2).
Steps: assignment submenu; ancestor-walk resolver; instantiate + open in W3; Templates section listing + CRUD; dangling-templateId cleanup.
Verify: `TemplateResolutionTests` (nearest-ancestor, blank fallback, dangling id cleared, kind filtering). GUI: assign a template to a folder; `⌘N` in a child inherits it; new note carries defaults + body; edit a template in the normal editor.
Done: SUITE_TODO "W6 · templates" `[x]`.

**S7 — dates & quality UI.** *(Tier-1)*
Scope: `NoteMetadataInspector` date control (precision segmented + fields + uncertain) and `QualityControl` (None + 1..5), both writing front-matter via W2, plus the group/inspector facet-button variants.
Files: `Views/NoteMetadataInspector.swift`, `Views/QualityControl.swift`; `NotesNavigationModel.setDate/setDatePrecision/setDateUncertain/setQuality`.
Steps: copy `DateCell`/`dateSection` and `PriorityCell`/`prioritySection`, retarget writes to front-matter; recompute `sortDate` via `ArchiveCore.DocumentTags.sortDate`; confirm no Finder-tag write for quality/date.
Verify: `FrontMatterDateWriteTests` (precision round-trip, `sortDate` incl. decade + uncertain-sorts-by-value), `QualityWriteTests` (writes `quality`, asserts **no** Finder tag mutated). GUI: change precision/uncertain and quality; list date/quality columns + sort update live.
Done: SUITE_TODO "W6 · dates & quality" `[x]`; if S6 and S7 both fit one window's budget they may be merged, but default to separate sessions.

## Tests
Unit (XCTest, in `ArchiveNotes/macOS/Tests/ArchiveNotesTests/`): `FolderTreeBuildTests`, `FolderMutationTests`, `SmartFolderScopeTests`, `NotesFilterTests`, `NotesSortTests`, `SearchDebounceTests`, `NotesTableSnapshotTests`, `MembershipTests`, `DeleteLastInstanceTests`, `TrashDeletionTests`, `TemplateResolutionTests`, `FrontMatterDateWriteTests`, `QualityWriteTests`, `NotesAppSettingsTests`. All file-touching tests build a scratch `<NotesStore>` via `mktemp -d`.
GUI/behavioral (via `./launch.sh notes` + `cliclick`, promoted to XCUITest in W8): divider resize persistence; folder CRUD + scope; list sort/hide/kind-toggle; search relevance + composite filters; drag move vs ⌥-replicate; replicant marks + locations inspector; the delete-last-instance modal (wording + Trash landing); template inherit + new-from-template; date-precision + quality edits reflected in columns/sort.

## Risks & file-safety
- **Data-loss risk — the delete-last-instance path (Tier-2).** A membership removal that strands a note deletes files. Mitigations: fresh `membershipCount` read at click time (no cached count, mirroring `TagWriter`'s TOCTOU rule); mandatory modal with the exact §3.6 wording and no silent branch; **delete via `FileManager.trashItem` (recoverable) under `NSFileCoordinator`, never `removeItem`**; batched confirmation for folder-delete strandings; adversarial review + scratch-only tests in S5. Confirm the guard also covers the MOVE-drag source removal and folder-delete, not just the explicit "Remove from folder" button.
- **Never the real corpus.** W6 writes only `organization.json`, the index DB, and the item's own files (via W2); it imports no corpus-mutating API and no Finder-tag API (subject mirroring goes through `NotesTagProjector`; quality/date are front-matter-only per §D2/§D9). All tests use `mktemp -d` scratch stores.
- **Identity confusion (path vs UUID).** Reader's tree is path-keyed; Notes' is UUID-keyed. Copying `SidebarView`/`buildFolderTree` verbatim without switching identity would silently break replication (a note in two folders shares one id). Enforced by `FolderTreeBuildTests` asserting distinct folders can reference the same item id.
- **Reparent cycles.** `moveFolder` must reject making a folder its own descendant, else the tree build recurses infinitely — guarded + `FolderMutationTests`.
- **Scale.** In-memory `allItems` at 100k is within Reader's demonstrated 150k envelope, but confirm with a 50k synthetic scratch store in S3; if recompute jank appears, push `matches`/sort into a SQL projection on `NotesIndex` (fallback path, non-blocking).
- **Concurrency.** Two windows share one store/index; membership edits in one must not corrupt the other's view. `OrganizationStore` mutations are serialized on the main actor and persisted atomically; `NotesIndex` is an actor. `Sendable` on all crossing types.

## Open questions
1. Should MOVE be the default drag and REPLICATE the ⌥-modifier (Finder-like), or the reverse (some DevonThink muscle memory)? Proposed: MOVE default, ⌥=replicate; revisit with the owner during S5 GUI.
2. Do smart folders belong to the folder tree (as `.smart` nodes) or a separate top section? This plan nests them as a labeled section like Reader; the owner may prefer inline smart nodes anywhere in the tree.
3. Should the two windows share one `NotesNavigationModel` (synchronized scope/selection) or hold independent instances? This plan uses independent instances per window; a shared model would let the Extract window follow the Note window's selection — decide after W7 (extracts) lands.
4. "Aliases-style" column presentation — count-only ("In 3") vs. a hover list of folder names vs. a dedicated glyph. Proposed count + glyph; finalize with the owner.
5. Column set beyond title/aliases/date/kind/quality — add authors and modified-date columns (hidden by default via `ColumnPickerHeaderView`)? Low-cost; deferred to owner preference.
