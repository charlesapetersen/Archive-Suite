# Execution plan — Reader GUI test harness (reliable, repeatable XCUITest)

**Status:** proposed · **Owner:** overnight-capable · one bounded sub-task per session (5 total).


> ## ⚠️ Adversarial review (2026-07-10) — verdict: **needs-change**. Apply these BEFORE/while implementing:
>
>- Route B entitlement must be READ-WRITE, not read-only: W5.c1 writes a subject tag to the fixture through TagWriter's coordinated metadata write; com.apple.security.temporary-exception.files.absolute-path.read-only blocks that write (test fails or silently no-ops). Use the read-write temporary-exception variant with the machine-specific absolute fixture path.
>- Make Route B (fixture at ~/Library/Application Support/ArchiveReader, granted via the UITest-only entitlement) the PRIMARY route and demote Route A (sandbox container) to experimental. Discovery is entirely NSMetadataQuery/Spotlight (ArchiveLibrary.swift L36-67); Spotlight does not reliably index ~/Library/Containers/<id>/Data, whereas Route B's path is already proven visible to the sandboxed app's NSMetadataQuery (SMOKE_TEST step A = 30 rows). Do not gate the whole plan on the unproven container probe.
>- Move the sandbox-visibility de-risk into sub-task 1: prove that the sandboxed app's NSMetadataQuery returns the fixture rows via the temporary-exception grant (a different mechanism than today's open-panel user-selected grant that the smoke test relies on) before building anything on it.
>- Fix the fixture 'indexed' gate trust domain: make-gui-fixture.sh confirms indexing with mdfind from OUTSIDE the sandbox, which does not guarantee the sandboxed app sees the same items. The authoritative readiness gate must be inside the running app (wait for ar.table rowCount >= expected, generous timeout); treat mdfind as advisory only.
>- Give the tags cell per-ROW accessibility identity. Cells are virtualized/reused (NSTableViewDiffableDataSource; makeTagTokenCell sets the id only on new cells and rebinds itemID on reuse), so a single shared ar.cell.tags id can't reliably target a specific row. Encode the row's stable id/name into the token field's accessibility on every bind, or locate via the row's Name cell then descend to the tags cell. Validate this locate path in sub-task 2, not sub-task 5.
>- De-risk NSTokenField inline typing EARLY (sub-task 1 spike): driving an inline NSTokenField type-token-then-commit-on-blur through XCUITest is a known weak spot; prove one real typeText -> blur -> controlTextDidEndEditing -> TagWriter round-trip, with a DEBUG test-only command invoking commitSubjectEdit as a documented fallback if XCUITest can't focus the field editor.
>- W5.c1 disk assertion races the async write: commitSubjectEdit -> TagWriter runs its coordinated write+verify asynchronously, so shelling `tag -l` immediately can read pre-write state. Poll `tag -l` (or the row value) with a timeout before asserting, and again after Undo.
>- Expose PDFView zoom for W5.d2: an accessibilityIdentifier on the PDFView does not surface scaleFactor, so per-pane-zoom independence can't be asserted and would falsely pass by asserting nothing. Expose scaleFactor via a DEBUG accessibilityValue or a test hook on PDFPaneView.
>- Give the FTS/relevance-sort test a deterministic index-ready signal: the content index (ContentIndexer, detached/background) must finish extracting page-2 text before an OCR query returns hits, so 'type query, assert order changed' can be flaky or falsely green. Expose an index-complete signal to await, or seed the FTS DB deterministically in the fixture.
>- Build the fixture ONCE per test class (class-level setUp), not in per-method setUp: a per-test mdimport + poll (up to ~40s each) both bloats runtime and multiplies indexing-latency flakiness across the 7 tests.
>- Pass the fixture path as a two-element launchArguments array (['-ARUITestRootPath', path]) so the space in the 'Archive Suite'/'Application Support' paths can't be split; do not put it in a single scheme argument string.
>
> _Reviewer note: The plan's architecture is viable and its safety-critical core — the TEST-ONLY root override — is genuinely sound (verified against RootFolderStore.swift: no bookmark read/write, #if DEBUG + volatile argument-domain, bypasses resolveSaved). But it must not proceed as written: it ships a read-only entitlement against a test that writes tags, it prioritizes the unproven container route over the already-proven one, and it defers several XCUITest/Spotlight risks that will make the suite flaky or falsely green. Fix the required changes below, then it's a good plan. Sequencing fix: pull the two hardest de-risks (sandboxed NSMetadataQuery visibility for the chosen route, and NSTokenField inline type-commit) into sub-task 1 so the whole plan isn't built on unproven assumptions._

## Goal

Replace today's screenshot-guessing / AppleScript-System-Events GUI verification (which
**cannot** select `NSTableView` rows or focus in-content fields) with a deterministic **XCUITest**
harness that satisfies the sandbox, never drives the `NSOpenPanel` picker, never touches the real
corpus, and never overwrites the user's real `archiveRootBookmark`. Concretely: verify the 5
Wave-5 items that could not be driven via System Events — **W5.c1** inline subject-tag cell edit,
**W5.c3** header-click + right-click secondary sort, **W5.a3** smart-folder scope, **W5.c4**
panel drag/collapse, **W5.d1–d4** viewer/preview text pane + own-zoom + non-PDF.

> Context that shaped this plan: System Events `click at {x,y}` fails on the AppKit table / in-content
> fields (menu commands + keyboard-focused fields + toolbar clicks work); `cliclick` posts real
> CGEvents and works where System Events didn't — but XCUITest is the *structured, assertable*
> route and is what this plan standardizes on. `cliclick` remains a manual fallback for one-off pokes.

## Risk tier — MUST NOT change production behavior

- **accessibilityIdentifiers are inert** display metadata — no runtime behavior. (Tier-1.)
- **The fixture-root override is `#if DEBUG` + launch-arg gated** — compiled out of the Release DMG
  entirely, and inactive in Debug unless `-ARUITestRootPath` is passed (the owner never passes it).
  It sets `root` **without** persisting a bookmark and **without** reading/writing
  `archiveRootBookmark`. Reviewed to guarantee it can never shadow or clobber the real root. (Tier-1,
  but review the override as if Tier-2 because it lives next to the file-access boundary.)
- **The only tag WRITE** the harness triggers (W5.c1) routes through the existing single `TagWriter`
  choke-point, against a **fixture copy** built by `make-gui-fixture.sh` — never the real corpus.
  Honors the Reader Core Directive.

## Scope (files)

- `ArchiveReader/macOS/project.yml` — new UI-test target + scheme wiring (sub-task 1).
- `ArchiveReader/macOS/Tests/ArchiveReaderUITests/` — new (XCUITests; sub-tasks 1, 5).
- `ArchiveReader/macOS/Sources/ArchiveReader/Search/RootFolderStore.swift` — DEBUG override (sub-task 3).
- `ArchiveReader/macOS/Sources/ArchiveReader/ArchiveReader.entitlements` **only if Route B** — a
  parallel `ArchiveReader.uitest.entitlements` (sub-task 3); prod entitlements stay byte-identical.
- Views getting identifiers (sub-task 2): `Views/NavigationWindowView.swift`,
  `Views/AppKitTableView.swift`, `Views/SidebarView.swift`, `Views/PreviewSheet.swift`,
  `Views/DocumentWindowView.swift`, `Views/PDFPaneView.swift`, `Views/TagFilterField.swift`.
- `ArchiveReader/scripts/make-gui-fixture.sh` — new, alongside `scripts/smoke-setup.sh` (sub-task 4).

---

## Sub-task 1 — Add the XCUITest target + scheme (project.yml)

**Integration point:** `project.yml` currently defines `ArchiveReader` (app, L16–36) and
`ArchiveReaderTests` (`bundle.unit-test`, L38–49); the `ArchiveReader` scheme's `test` action lists
only `ArchiveReaderTests` (L59–62). Add a sibling **UI-test** target and add it to the test action:

```yaml
  ArchiveReaderUITests:
    type: bundle.ui-testing        # distinct from the existing bundle.unit-test target
    platform: macOS
    sources:
      - Tests/ArchiveReaderUITests
    dependencies:
      - target: ArchiveReader
    settings:
      base:
        SWIFT_VERSION: "6.0"
        GENERATE_INFOPLIST_FILE: YES
        PRODUCT_BUNDLE_IDENTIFIER: com.archivereader.uitests
        TEST_TARGET_NAME: ArchiveReader     # XCUITest launches this app
```

Then extend the scheme test targets (L61–62) to include `- ArchiveReaderUITests` (keep
`ArchiveReaderTests`). `xcodegen generate` after editing (the `.xcodeproj` is gitignored — CLAUDE.md).

**xcodebuild invocation** (per-worktree DerivedData like the rest of the repo):

```bash
xcodegen generate
xcodebuild test -scheme ArchiveReader -destination 'platform=macOS' \
  -derivedDataPath ./build/DD -only-testing:ArchiveReaderUITests
```

**Deliverable for this session:** the target + one trivial smoke test
(`app.launch(); XCTAssertTrue(app.windows["Archive Reader"].waitForExistence(timeout: 10))`) proven
GREEN, so the invocation is trusted before any real assertions land. UI tests need the app to
actually launch under the test runner — confirm the scheme test action builds the app target.

---

## Sub-task 2 — accessibilityIdentifiers on the key controls

**Convention:** dotted `ar.<area>.<control>` (stable, greppable, никогда localized).
**Critical wrinkle:** SwiftUI's `.accessibilityIdentifier(_:)` works for SwiftUI views, but for
`NSViewRepresentable`-wrapped AppKit controls it does **not** reach the wrapped `NSView` — those must
call `nsView.setAccessibilityIdentifier(_:)` inside `makeNSView`/`updateNSView`.

**SwiftUI — `NavigationWindowView.swift`:**

| Control | Line | Proposed id |
|---|---|---|
| Read-state `Picker` | L246 | `ar.filter.readState` |
| Priority toggle `P{p}` | L258 | `ar.filter.priority.P\(p)` |
| Filename `TextField` | L271 | `ar.filter.name` |
| OCR-search `TextField` | L278 | `ar.filter.ocr` |
| OCR clear button | L284 | `ar.filter.ocrClear` |
| Needs-attention toggle | L293 | `ar.filter.needsAttention` |
| "Save as Smart Folder" | L304 | `ar.filter.saveSmartFolder` |
| "Clear" | L306 | `ar.filter.clear` |
| Subject-combine `Picker` | L336 | `ar.filter.subjectCombine` |
| Tag-cloud panel container (VStack) | L178 | `ar.tagCloud` |
| Tag-cloud token `Button`s | L195 | `ar.tagCloud.tag` (label already = tag text) |
| Toolbar buttons | L351–413 | `ar.toolbar.{sidebar,chooseFolder,saved,tagCloud,open,preview,copyLinks,markRead,markUnread,editTags,flag,undo}` |
| Status health button | L436 | `ar.status.health` |
| `PanelDivider` (add id param) | L24 / L32 | `ar.divider.sidebar` / `ar.divider.tagCloud` |

For **W5's "tag cloud has no date tokens"** assertion: give the panel container `ar.tagCloud`
(L178) and each button `ar.tagCloud.tag` (L195); the test enumerates buttons under the container and
asserts none of their `.label`s look like a year/decade/`MM Month`/`Day N`.

**`PanelDivider`** (L460–491) has no identifier hook — add a `var id: String` and
`.accessibilityIdentifier(id)` so W5.c4 can grab the divider to drag it.

**AppKit-wrapped — `AppKitTableView.swift`** (`setAccessibilityIdentifier` in `makeNSView`, ~L31):
- the `ContextMenuTableView` → `ar.table`;
- `ColumnPickerHeaderView` (L41) → `ar.table.header` (right-click target for W5.c3 secondary sort);
- `TagTokenCellView.tokenField` (created L388 / class L444) → `ar.cell.tags` (W5.c1 target; XCUITest
  disambiguates the per-row instance by containing row / cell value).
- Column headers for **click-to-sort**: try matching by `NSTableColumn.title` first (L80–87 set
  titles); if XCUITest can't reliably hit an AppKit header cell by title, add per-column header ids
  here (see Open Questions).

**`SidebarView.swift`** — add an id arg to the `row(...)` helper (L89) and set it on each row:
- smart-folder rows (L31) → `ar.sidebar.smart` (+ the visible label = search name);
- "All Files" (L51) → `ar.sidebar.allFiles`;
- folder-tree rows (L55) → `ar.sidebar.folder` (+ label = folder name).

**`PreviewSheet.swift`** — image pane (L77) `ar.preview.imagePane`; right PDF pane (L81) /
embeddedText `ScrollView` (L84) both `ar.preview.textPane`; "No OCR text page"
`ContentUnavailableView` (L93) `ar.preview.noText`; "Open" (L61) `ar.preview.open`; "Done" (L64)
`ar.preview.done`.

**`DocumentWindowView.swift`** — image pane (L54) `ar.doc.imagePane`; text PDF pane (L60) /
embeddedText `ScrollView` (L65) both `ar.doc.textPane`; "No OCR text page" (L74) `ar.doc.noText`;
format banner (L114) `ar.doc.formatBanner`; find field (L127) `ar.doc.findField`.

**`PDFPaneView.swift`** — the wrapped `PDFView` needs `setAccessibilityIdentifier`; add an `id`
param so `ar.{doc,preview}.{image,text}Pane` propagate to the actual pane view (needed to assert
independent per-pane zoom, W5.d2).

**`TagFilterField.swift`** — in `makeNSView` (L16) `cb.setAccessibilityIdentifier("ar.filter.tagField")`.

**Verify:** `xcodegen generate && xcodebuild -scheme ArchiveReader build` — no new warnings; the
app runs identically (identifiers are metadata).

---

## Sub-task 3 — TEST-ONLY archive-root override (never touches the real bookmark)

**Where it slots in:** `RootFolderStore` persists the root as a security-scoped bookmark in
UserDefaults key `archiveRootBookmark` (`RootFolderStore.swift` L13), resolved on `init()` →
`resolveSaved()` (L15, L41). `NavigationModel` owns the store (L22) and, in `init()`, starts
discovery with `if let root = rootStore.root { library.start(scope: root) }` (L130). The override
must make `rootStore.root` non-nil **before** that line, without going through `setRoot(_:)` (L18,
which persists a bookmark) and without `resolveSaved()` reading/refreshing the real key.

**Mechanism — volatile launch argument → UserDefaults argument domain.** XCUITest sets
`app.launchArguments = ["-ARUITestRootPath", fixturePath]`. macOS parses `-key value` launch args
into UserDefaults' **argument domain**, which is **volatile — never written to disk**, so it can
never shadow a subsequent normal launch (verify — see Open Questions). Add to `RootFolderStore.init`:

```swift
init() {
#if DEBUG
    if let p = UserDefaults.standard.string(forKey: "ARUITestRootPath"), !p.isEmpty {
        adoptTestRoot(URL(fileURLWithPath: p, isDirectory: true))   // sets `root` only
        return                                                       // SKIP resolveSaved() entirely
    }
#endif
    resolveSaved()
}
```
`adoptTestRoot` sets `root = url` and leaves `accessing = nil`; it **does not** call
`bookmarkData`, **does not** `UserDefaults.set(_, forKey: key)`, and **does not**
`startAccessingSecurityScopedResource()` (the fixture path needs no scope — see sandbox routes).
Release builds compile the whole branch out.

**The sandbox wrinkle** (a *sandboxed* app pointed at a fixture with no user grant):

- **Route A (preferred — zero entitlement/config change):** put the fixture **inside the app's own
  sandbox container** (`~/Library/Containers/com.archivereader.app/Data/Library/Application
  Support/ArchiveReader/AR-GUI-Fixture`). A sandboxed app **always** has read-write to its own
  container with **no bookmark and no security scope** — so `adoptTestRoot` just uses the path
  directly. Prod entitlements untouched. **Gated on the Spotlight probe** (Open Questions): the app
  discovers via `NSMetadataQuery`, so the container must be Spotlight-indexed.
- **Route B (fallback if Spotlight won't index the container):** keep the fixture at the
  smoke-proven, confirmed-indexed `~/Library/Application Support/ArchiveReader/AR-GUI-Fixture`
  (outside the container) and grant read access via a **UITest-only** entitlement —
  `com.apple.security.temporary-exception.files.absolute-path.read-only` for that path — in a
  **separate `ArchiveReader.uitest.entitlements`** applied only to a UITest build configuration.
  Production's `ArchiveReader.entitlements` (sandbox + user-selected + app-scope bookmarks, verified
  at L1–11 of the entitlements file) stays byte-identical, so prod posture is unchanged.

**Verify:** a unit test asserts that after driving `adoptTestRoot`, `UserDefaults` has **no**
`archiveRootBookmark` write (spy/clear-then-check), and a normal launch still resolves the real
bookmark.

---

## Sub-task 4 — Fixture builder (`scripts/make-gui-fixture.sh`)

Model it on the existing `scripts/smoke-setup.sh` (copies real PDFs with `ditto` to a scratch dir,
`mdimport`, then polls `mdfind` until indexed — never writes the real corpus). Differences:

- **Destination = the route chosen in sub-task 3** (Route A container path / Route B App-Support path).
- Copy a *small, curated handful* (~10–12) of PDFs from
  `Test files/Brown Gemini` (git can't store the Finder-tag xattrs, so tags MUST be applied by this
  step — the corpus is built, never committed).
- **Strip inherited tags then re-apply a deliberate VARIETY** via `/opt/homebrew/bin/tag`:
  - years incl. a 3-digit medieval one + a `NNNNs` decade token + a plain 4-digit year;
  - a `MM Month` + a `Day N`;
  - subjects (`Jerry Brown`, `Economics`, …), incl. one facet-colliding subject (`1984`);
  - one of each priority `P7 P8 P9 P10`;
  - a Read/Unread spread (and one *neither* marker for the tri-state bucket);
  - a **Box** marker (color Red / token `Box`) and a **Folder** marker (Purple / `Folder`);
  - one **image-only / no-text-layer** PDF and one **non-PDF** image (for W5.d4 degrade).
- `mdimport <dst>` then poll `mdfind -onlyin <dst> 'kMDItemUserTags=="Unread"||kMDItemUserTags=="Read"'`
  until count ≥ copied (same wait loop as `smoke-setup.sh`).
- Idempotent (`rm -rf` + rebuild). Emits the fixture path on stdout so the test runner passes it as
  `-ARUITestRootPath`.
- **Route A note:** if the container doesn't exist yet, `mkdir -p` it (or do a throwaway app launch
  first — see Open Questions).

The `tag` CLI writes Finder tags (`com.apple.metadata:_kMDItemUserTags`), matching the Verified-Facts
tag model; color is set via `tag` + the color-name token convention (Red⇒box, Purple⇒folder).

---

## Sub-task 5 — Initial XCUITests for the 5 un-verified Wave-5 items

Each test: `make-gui-fixture.sh` in `setUp` (or once per class), launch with
`-ARUITestRootPath <fixture>`, wait for `ar.table` to populate.

1. **W5.c1 — inline subject-tag cell edit.** Locate the `ar.cell.tags` token field on a known row,
   type a new subject, commit by blurring (click another row / press Tab — mirrors
   `controlTextDidEndEditing` → `commitSubjectEdit` at `AppKitTableView.swift` L420–433, which routes
   through `TagWriter`). **Assert the write on disk** by shelling out to `/opt/homebrew/bin/tag -l
   <fixtureFile>` and checking the new token is present and no prior token was lost (Core-Directive:
   adds only — `SubjectTokenField` never drops existing tags). Undo (`⌘Z`) and re-assert.
2. **W5.c3 — header click + right-click secondary sort.** Click the "Document date" header (title
   from `AppKitTableView.swift` L80–87) to toggle sort; capture the first N row values (Name column),
   assert reorder. Then right-click a sortable header → the `ColumnPickerHeaderView` menu (L493–550)
   "Set as Secondary Sort (A→Z)" → assert the tie-break order changes as expected.
3. **W5.a3 — smart-folder scope.** With the fixture including a saved search (seed one via the
   `SavedSearch` store, or create one through `ar.filter.saveSmartFolder`), click its
   `ar.sidebar.smart` row → assert the status bar count drops to the scoped subset; add a user filter
   (a priority toggle) → count narrows further; hit `ar.filter.clear` → assert it returns to the
   **base scope**, NOT the whole root (per `clearUserFilters`, `NavigationModel.swift` L219); click
   `ar.sidebar.allFiles` → assert scope exits (full count restored).
4. **W5.c4 — panel drag / collapse.** Toggle `ar.toolbar.sidebar` and `ar.toolbar.tagCloud` →
   assert the `ar.tagCloud` / sidebar existence flips; drag `ar.divider.sidebar` →
   assert a width change (row/panel frame delta).
5. **W5.d1–d4 — viewer / preview.** Select a 2-page row, `Space` → assert `ar.preview.imagePane`
   **and** `ar.preview.textPane` exist (single-page text pane, d1); select the image-only fixture →
   assert `ar.preview.noText` / `ar.doc.noText` shows (d4 non-standard degrade). Open the full viewer
   (`⌘O`) on a normal doc → assert both `ar.doc.imagePane` + `ar.doc.textPane`; zoom the text pane
   only (toolbar "Zoom In Right", `DocumentWindowView.swift` L161) and assert the image pane's zoom is
   unchanged (independent per-pane zoom, d2); open the non-PDF marker → assert graceful degrade, no
   crash (d3).

**Two regressions to bundle in:**
- **Tag cloud has no date tokens:** open `ar.tagCloud`, enumerate `ar.tagCloud.tag` labels, assert
  none match year/decade/month/`Day N`.
- **Relevance sort reorders:** type a query into `ar.filter.ocr`, wait for the FTS refresh, assert
  the row order changes and the active sort is relevance (nav auto-switches to `.relevance` on an
  active query — CLAUDE §Decisions); clearing the query restores the prior sort.

---

## Verification

- `xcodegen generate && xcodebuild -scheme ArchiveReader build` — no new warnings (sub-tasks 2, 3).
- `xcodebuild test -scheme ArchiveReader -destination 'platform=macOS' -derivedDataPath ./build/DD
  -only-testing:ArchiveReaderUITests` — GREEN (sub-tasks 1, 5).
- Unit assertion: the DEBUG override never writes `archiveRootBookmark` (sub-task 3).
- Confirm the existing `scripts/lint-write-surface.sh` still passes (the harness adds **no** new
  tag-write spelling; W5.c1 goes through the existing `TagWriter`).
- Re-run the full existing suite (`-only-testing:ArchiveReaderTests`, 186 tests) — still green.

## Docs move with the code (same commit — CLAUDE.md Definition of Done)

- Flip the `SUITE_TODO.md` item for this plan; keep it under **Active execution plans** until shipped,
  then **delete this plan** and mark it `~~struck~~ — SHIPPED` there (matching the existing entries).
- `ArchiveReader/CLAUDE.md` Implementation Map: note the new **`ArchiveReaderUITests`** target, the
  `ar.<area>.<control>` accessibilityIdentifier convention, and the DEBUG `-ARUITestRootPath` override
  (with its "never persists / never touches `archiveRootBookmark`" guarantee).
- `ArchiveReader/KNOWN_ISSUES.md`: record the System-Events limitation (can't select AppKit table
  rows / focus in-content fields) and that XCUITest is now the sanctioned GUI-verification route.
- `SMOKE_TEST.md`: cross-reference `make-gui-fixture.sh` next to `smoke-setup.sh`.
- If **Route B**: document the UITest-only entitlements/build-config in the build section and stress
  that prod `ArchiveReader.entitlements` is unchanged.

## Sequencing notes

- Sub-task 1 unblocks everything (proves the invocation). 2 and 3 are independent and can be either
  order; 4 depends on 3's route choice; 5 depends on 1+2+3+4.
- Resolve the **Spotlight-indexes-the-container** probe early in sub-task 3 — it picks Route A vs B
  and shapes sub-task 4.
