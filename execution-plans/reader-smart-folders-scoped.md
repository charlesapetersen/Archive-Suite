# Execution plan — Smart folders as a scoped root (base-scope ⟂ user filters) (Reader)

**Goal:** make Archive Reader's smart folders (saved searches) behave like a **scoped root**, not a
one-shot filter dump. Concretely:
1. Selecting a saved search shows **exactly** its filtered set.
2. With a smart folder selected, **no** filters render as "set" in the filter bar.
3. *Clear filters* returns to the smart folder's **base set** — not the whole root.

The enabling model change is a **base-scope** concept that is *distinct from* user-applied filters: a
smart folder defines the visible universe; user filters layer on top of it; *Clear* resets the user
layer to empty (→ back to the base), and exiting the scope (sidebar → All Files / a folder) returns to
the whole root.

**Scope (files):**
- `ArchiveReader/macOS/Sources/ArchiveReader/Views/NavigationModel.swift` — the model change (new
  `scope`/`baseFtsPaths`, `applyScope`, `clearUserFilters`, `recompute` layering, base full-text
  search, C2 persistence, `effectiveFilter` for save/summary).
- `ArchiveReader/macOS/Sources/ArchiveReader/Views/SidebarView.swift` — smart-folder selection becomes
  a durable highlight; folder/All-Files selection exits the scope.
- `ArchiveReader/macOS/Sources/ArchiveReader/Views/NavigationWindowView.swift` — filter-bar Clear/Save
  wiring, status bar, the saved-search menu.
- `ArchiveReader/macOS/Sources/ArchiveReader/ArchiveReaderCommands.swift` — the `⌘⇧K` Clear command.
- `ArchiveReader/macOS/Sources/ArchiveReader/Core/LibraryFilter.swift` — a pure `effective(base:user:)`
  merge helper (+ its test).
- `ArchiveReader/macOS/Sources/ArchiveReader/Search/SavedSearch.swift` — unchanged as a type (`scope`
  reuses `SavedSearch`); read only.
- `ArchiveReader/Tests/ArchiveReaderTests/` — new pure-logic tests.

**Risk: Tier-1.** Display/filter/sort only. **No** `TagWriter` path, **no** file bytes/location write,
**no** move/rename/delete, **no** change to the tag/PDF **SPEC** (no facet is parsed or written
differently), **no** actor-isolation change — the base scope's full-text search reuses the existing
generation-guarded `@MainActor` async pattern (`runFullTextSearch`, `NavigationModel.swift:336-347`).
Still gets: clean build (no new warnings), the pure merge unit-tested, and a GUI smoke driven against a
**scratch copy** of the corpus (never the real corpus — Reader Core Directive). `scripts/lint-write-surface.sh`
must stay green (this change adds no write spelling).

---

## Problem (measured from the code)

A smart folder is applied by **wholesale-replacing** the user filter with the saved one:
`applySaved` sets `filter = f` and `fullTextQuery = search.fullTextQuery`
(`NavigationModel.swift:160-174`). Consequences, all traceable:

- **Facets render as "set."** The filter bar reads `model.filter` directly — subject chips
  (`NavigationWindowView.swift:316-318`), the name/OCR fields, and the visibility of the Save/Clear
  buttons via `model.filter.isActive` (`NavigationWindowView.swift:296`). So a saved search's own
  facets show up as user-applied filters. (Violates goal 2.)
- **Clear wipes to the whole root.** *Clear Filters & Search* (`⌘⇧K`,
  `ArchiveReaderCommands.swift:90-94`) and the filter-bar **Clear** button
  (`NavigationWindowView.swift:299-304`) both do `filter = LibraryFilter()` → an empty filter →
  the whole root, discarding the smart folder entirely. (Violates goal 3.)
- **No notion of a base universe.** `recompute()` filters `library.files` by the single `filter`
  (`NavigationModel.swift:245-253`); there is no layer that says "this smart folder is the universe,
  and user filters narrow *within* it." (The missing model concept behind goals 1–3.)

There is also a latent inconsistency: `applySaved` runs `runFullTextSearch()`
(`NavigationModel.swift:173`), so a saved OCR query lights the **user** OCR indicator
(`model.ftsPaths != nil`, `NavigationWindowView.swift:269`) — i.e. the saved query reads as a
user-applied search too.

---

## Approach

### 1. Model: introduce the base scope (`NavigationModel.swift`)

Add two published fields near `filter`/`ftsPaths` (`NavigationModel.swift:27,49`):

```swift
/// The active smart folder's base scope — the visible universe. nil = whole root. User `filter`
/// (below) narrows *within* this. A value copy of the SavedSearch (its `.filter` already
/// pathPrefix-sanitized against the current root, like restoreViewState/applySaved do today).
@Published private(set) var scope: SavedSearch?
/// Paths matching the base scope's own OCR query (scope.fullTextQuery). nil = scope has no query
/// (or no scope). Kept SEPARATE from `ftsPaths` (the USER query) so a scoped OCR query never lights
/// the user OCR indicator (NavigationWindowView.swift:269) or the filter-bar Clear/Save row.
@Published private(set) var baseFtsPaths: Set<String>?
private var baseFtsGeneration = 0
```

`scope` reuses `SavedSearch` (`SavedSearch.swift:5-10`) — no new persisted type; it already carries
`{filter, fullTextQuery, name}`.

### 2. `recompute()` — layer user filters on top of the base (`NavigationModel.swift:245-257`)

Rewrite the head of `recompute` so the base scope is the universe and the user filter narrows it:

```swift
func recompute() {
    var base = library.files
    if let scope {                                   // base scope = the visible universe
        base = base.filter(scope.filter.matches)
        if let baseFtsPaths { base = base.filter { baseFtsPaths.contains($0.url.path) } }
    }
    base = base.filter(filter.matches)               // USER filter layers on top (AND)
    if let ftsPaths { base = base.filter { ftsPaths.contains($0.url.path) } }
    // needsAttention lives OUTSIDE `matches` (LibraryFilter.swift:31-34), so honor it from BOTH layers:
    if filter.needsAttentionOnly || (scope?.filter.needsAttentionOnly ?? false) {
        base = base.filter { formatStatuses[$0.url.path]?.needsAttention == true }
    }
    displayed = LibrarySort.sorted(base, by: sort)
    // …unchanged tail: duplicatedNames / refreshSelectionCache / persistViewState…
}
```

Note `searchText`/`pathPrefix`/subjects/priority/read of the *scope* are applied via
`scope.filter.matches` (all live inside `matches`, `LibraryFilter.swift:43-71`); only
`needsAttentionOnly` (`:31-34`) and full-text (async index) are model-applied, hence the extra
`||` guard and `baseFtsPaths`.

### 3. `applyScope` replaces `applySaved` (`NavigationModel.swift:160-174`)

```swift
func applyScope(_ search: SavedSearch) {
    var f = search.filter
    let sanitized = Self.sanitizedPathPrefix(f.pathPrefix, against: rootStore.root?.path)  // :311
    if sanitized != f.pathPrefix {
        f.pathPrefix = sanitized
        statusMessage = "Smart folder’s folder scope isn’t under the current archive root — showing the whole root."
    }
    var s = search; s.filter = f
    scope = s
    clearUserFilters(recompute: false)   // neutral user layer → NO chips/indicators lit (goal 2)
    runBaseFullTextSearch()              // computes baseFtsPaths (from scope.fullTextQuery) + recompute
    recompute()                          // immediate update before the async FTS returns
}
```

`clearUserFilters` (new; used by `applyScope` AND both Clear sites):

```swift
func clearUserFilters(recompute doRecompute: Bool = true) {
    filter = LibraryFilter()             // neutral: read=.all, no subjects/priorities/searchText/pathPrefix
    filterSearchText = ""                // keep the debounced field (NavigationModel.swift:28) in sync
    fullTextQuery = ""
    ftsGeneration += 1                   // invalidate any in-flight USER FTS (mirrors :487)
    ftsPaths = nil
    if doRecompute { recompute() }
}
```

`runBaseFullTextSearch` (new; mirrors `runFullTextSearch`, `NavigationModel.swift:336-347`, but reads
`scope?.fullTextQuery` and writes `baseFtsPaths`/`baseFtsGeneration`):

```swift
private func runBaseFullTextSearch() {
    let q = scope?.fullTextQuery.trimmingCharacters(in: .whitespaces) ?? ""
    baseFtsGeneration += 1
    let generation = baseFtsGeneration
    Task { [weak self] in
        guard let self else { return }
        let result: Set<String>? = q.isEmpty ? nil : await self.indexer.search(q)
        guard generation == self.baseFtsGeneration else { return }   // superseded
        self.baseFtsPaths = result
        self.recompute()
    }
}
```

### 4. Clear filters → base set, not root (`ArchiveReaderCommands.swift:90-94`, `NavigationWindowView.swift:299-304`)

Both sites become `model.clearUserFilters()`. Because `clearUserFilters` leaves `scope` untouched,
`recompute` re-derives `displayed` = the scope's base set (goal 3). With **no** scope active it resets
to the whole root exactly as today (`LibraryFilter()` neutral). Drop the manual
`filter = LibraryFilter()` / `fullTextQuery = ""` / `runFullTextSearch()` triplets at both sites.

### 5. Exiting the scope + folder selection (`NavigationModel.swift:423-427`, `SidebarView.swift:66-83`)

Selecting a folder or **All Files** in the sidebar exits any active scope (scope and folder are the
sidebar's mutually-exclusive single highlight — see Open Question 3). Fold scope-clearing into
`setFolderScope` and fix its early-return so exiting a scope whose `pathPrefix` was `nil` still
recomputes:

```swift
func setFolderScope(_ path: String?) {
    let scopeWasActive = scope != nil
    if scopeWasActive { scope = nil; baseFtsGeneration += 1; baseFtsPaths = nil }
    guard scopeWasActive || filter.pathPrefix != path else { return }   // was: filter.pathPrefix != path
    filter.pathPrefix = path
    recompute()
}
```

`SidebarView.applySelection` (`SidebarView.swift:66-75`): the smart-folder branch calls
`model.applyScope(s)` (was `applySaved`); the folder/All-Files branch keeps calling
`model.setFolderScope(...)` (now scope-clearing).

`SidebarView.syncSelectionFromModel` (`SidebarView.swift:80-83`) — reflect the scope as the durable
highlight (smart folders are no longer transient):

```swift
private func syncSelectionFromModel() {
    let want = model.scope.map { SidebarView.smartPrefix + $0.id.uuidString }
        ?? (model.filter.pathPrefix ?? SidebarView.allFilesTag)
    if selection != want { selection = want }
}
```

Add a sync trigger for scope changes next to the existing pathPrefix one (`SidebarView.swift:62`):
`.onChange(of: model.scope?.id) { _, _ in syncSelectionFromModel() }` (`UUID?` is Equatable). Update
the doc-comment at `SidebarView.swift:9-14` (it currently says smart folders resolve to a non-durable
highlight).

### 6. The saved-search menu (`NavigationWindowView.swift:378`)

`Button(s.name) { model.applySaved(s) }` → `model.applyScope(s)`.

### 7. Save / summary while a scope is active — `effectiveFilter` (see Open Question 1)

With a neutral user layer, the filter-bar Save/Clear row is hidden (its `model.filter.isActive`
guard, `NavigationWindowView.swift:296`, is false) — correct, there is nothing user-added to save. The
only wrinkle is saving **after** the user layers filters onto a scope. Add a pure merge in
`LibraryFilter.swift`:

```swift
/// Fold a user filter onto a base scope for "Save Current Search" / the status summary. Per-facet:
/// user wins when set, else inherit the base; subjects = union; pathPrefix/searchText = user ?? base;
/// needsAttentionOnly = OR. subjectCombine: user's when the user set subjects, else base's (the one
/// genuine ambiguity — see the plan's Open Question 1).
static func effective(base: LibraryFilter, user: LibraryFilter) -> LibraryFilter { … }
```

Route `saveCurrentSearch` (`NavigationModel.swift:110-112`), `suggestedSmartFolderName`
(`:116-136`) and `activeFilterSummary` (`:139-159`) through `scope`-aware inputs: when `scope != nil`,
compute against `LibraryFilter.effective(base: scope.filter, user: filter)` and
`scope.fullTextQuery`-or-`fullTextQuery`; prefix `activeFilterSummary` with the scope name (e.g.
`"[Batch-A] · Unread"`). When `scope == nil`, behavior is unchanged.

### 8. C2 persistence (see Open Question 2) (`NavigationModel.swift:287-302`)

Extend `ViewState` with `var scopeID: UUID?`; `persistViewState` writes `scope?.id`. `restoreViewState`
sets the (now-neutral) user `filter` as today, then re-resolves the scope from
`savedSearches.searches` (already loaded — the store loads in its property initializer,
`SavedSearch.swift:20-23`; runs before `restoreViewState` at `init` `NavigationModel.swift:67`) by id;
if found, set `scope` and call `runBaseFullTextSearch()`; if the id is gone, leave `scope == nil`.

### 9. Active-scope lifecycle vs. its saved search (see Open Question 4)

In the existing `savedSearches.objectWillChange` sink (`NavigationModel.swift:101-104`): after
`refreshSmartFolderCounts`, if `scope != nil` and no `savedSearches.searches` element has that id →
`setFolderScope(scope?.filter.pathPrefix)`-style clear (or `clearUserFilters`-preserving clear); if the
id still exists but the stored copy differs (rename/edit), refresh `scope` to the new value and
`runBaseFullTextSearch()` + `recompute()`.

---

## Edge cases

- **Scope with an OCR query, badge vs. list.** `smartFolderCounts` (`NavigationModel.swift:431-435`)
  counts `scope.filter.matches` only (no FTS) — but the sidebar already hides the badge for
  FTS-carrying searches (`SidebarView.swift:28-29`), so badge ↔ `displayed` stay consistent. No change
  to `refreshSmartFolderCounts`.
- **Base FTS not lighting the user indicator.** The OCR box + its clear-X read `model.ftsPaths`
  (`NavigationWindowView.swift:269,276`) — the base query uses `baseFtsPaths`, so a scoped OCR query
  stays invisible in the user filter bar (intended).
- **Stale pathPrefix in a saved scope** (older/other root): `applyScope` reuses the existing
  `sanitizedPathPrefix` guard (`NavigationModel.swift:311`), same as `applySaved`/`restoreViewState`.
- **Root switch while scoped** (`chooseRoot`, `NavigationModel.swift:469-492`): add `scope = nil;
  baseFtsGeneration += 1; baseFtsPaths = nil` alongside the existing FTS reset (`:485-489`) — a scope
  from the old root can't apply to a new one (parallels the `filter.pathPrefix = nil` reset at `:479`).
- **Clear with no scope** = whole root (unchanged) — `clearUserFilters` neutralizes and `recompute`
  has no scope layer.
- **needsAttention from the scope**: honored via the `||` in `recompute` (§2); the filter-bar toggle
  (`NavigationWindowView.swift:286`) still lets the user add it on top.
- **Triage / document-run / tag-cloud** all read `displayed` or `library.files`
  (`NavigationModel.swift:181-208, 216-218, 382-389, 545-587`); with a scope, `displayed` is the scoped
  set, so triage/next-unread/tag-cloud stay *within* the smart folder — desirable, no code change.
- **Empty scope result**: if a scope legitimately matches 0 files, the list is empty (correct) — the
  status bar `"0 shown · N total"` (`NavigationWindowView.swift:453`) already conveys this; the scope
  name in `activeFilterSummary` disambiguates "empty scope" from "empty root."
- **Selection persistence** (`NavigationModel.swift:224-241`) is path-based and scope-independent — a
  restored selection outside the current scope simply won't be in `displayed` (unchanged semantics).

---

## Test plan (scratch copies ONLY — never the real corpus)

Pure-logic unit tests (no corpus, no writes) in `ArchiveReader/Tests/ArchiveReaderTests/`:
- `LibraryFilter.effective(base:user:)`: per-facet precedence — user-wins-when-set, subjects union,
  `pathPrefix`/`searchText` = user ?? base, `needsAttentionOnly` OR; and the subjectCombine tie-break
  (document the chosen resolution once the owner answers Open Question 1).
- A `recompute`-layering test via a small seam: assert `library.files ∩ scope.filter ∩ user.filter`
  equals the scope's set when the user filter is neutral, and a strict subset when narrowed, and that
  `clearUserFilters` returns to the scope's set (not the full list). Drive it with in-memory
  `ArchiveFile` fixtures (as existing filter tests do) — no disk.
- C2 round-trip: `ViewState` with `scopeID` encodes/decodes; a missing id resolves to `scope == nil`.

GUI smoke (drive `./launch.sh reader` against a **scratch copy** of a small tagged folder — copy into
the scratchpad first; the app is read-only here but honor the Core Directive regardless):
1. Select a smart folder → list shows exactly its set; **no** subject chips, name/OCR fields empty,
   Save/Clear row hidden, OCR indicator off; sidebar highlight sits on the smart folder.
2. Add a subject/name filter → list narrows within the scope; Clear/Save row appears.
3. *Clear* (`⌘⇧K` and the button) → returns to the smart folder's base set (not the whole root).
4. Select **All Files** / a folder → scope exits, whole root (scoped to the folder).
5. Relaunch → the scope is restored (if Open Question 2 = yes) and the list matches.

---

## Verification

From an isolated worktree (per `CLAUDE.md` Worktree-first):
```
cd ArchiveReader/macOS
xcodegen generate
xcodebuild -scheme ArchiveReader -configuration Debug -derivedDataPath ./build/DD build   # no NEW warnings
xcodebuild -scheme ArchiveReader -configuration Debug -derivedDataPath ./build/DD test     # 161 + new, all green
../scripts/lint-write-surface.sh                                                            # unchanged / green
```
Then the GUI smoke above on a scratch copy. (Follows `ArchiveReader/CLAUDE.md` → Stack & Build.)

---

## Docs move with the code — SAME commit

- **`SUITE_TODO.md`**: flip this plan's checkbox to `[x]` (cite the commit) under *P2 — Reader
  features*, and remove its bullet from *Active execution plans* (`SUITE_TODO.md:32-46`).
- **`ArchiveReader/CLAUDE.md`**: update §Decisions (smart folders are a scoped root: base scope ⟂ user
  filters; Clear resets to the base) and the Implementation map notes for `SidebarView.swift`
  (durable smart-folder highlight; folder selection exits scope) and `NavigationModel.swift`
  (`scope`/`baseFtsPaths`/`applyScope`).
- **`SPEC/tag-format.md`**: **no change** — this touches no tag/PDF facet parse or write; state so in
  the commit message.
- **Delete** `execution-plans/reader-smart-folders-scoped.md` once shipped (git keeps history), per the
  Docs & backlog convention.

---

## Open questions for the owner

1. **Save while a scope is active + layered filters** — proposed `effectiveFilter` merge (user wins
   per-facet; subjects union; needsAttention OR). The one ambiguity is a **subjectCombine conflict**
   (scope AND vs. user OR) — recommend user's combine wins + a status note. Confirm, or should *Save*
   be disabled/redirected while scoped (save only from the whole-root view)?
2. **Persist the active scope across relaunch?** Proposed: yes, via `scopeID` in the C2 ViewState;
   drop silently if the saved search was deleted. Confirm (alternative: always start at the root).
3. **Folder selection while scoped** — proposed: selecting a folder / All Files **exits** the scope
   (mutually-exclusive sidebar highlight). Confirm, vs. layering a folder subtree *within* the scope.
4. **Delete/rename of the active scope's saved search** — proposed: auto-clear on delete, refresh the
   held copy on rename. Confirm acceptable.
