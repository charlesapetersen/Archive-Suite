# Archive Notes — Known Issues & Gotchas

Running log of quirks, risks, and things verified/unverified for the Notes app. Keep current.
(Sibling logs: `../ArchiveReader/KNOWN_ISSUES.md`, `../ArchiveProcessor/KNOWN_ISSUES.md`.)

## Editor↔item body wiring — follow-ups (W7-S1a, 2026-07-13, open)

W7-S1a bound `NoteEditorPane` to the selected item's body (`NoteBodyEditorModel`: load-on-select,
autosave via `NotesModel.setBody`, flush-on-switch, autosave-race-safe). Two conscious deferrals:

- **~~Inline-image paste doesn't persist yet~~ — RESOLVED (W7-S5, `ItemAssetStore`).** `NoteEditorPane` now
  creates an item-scoped `ItemAssetStore` (retargeted to the selected item) and passes it to
  `MarkdownEditorView`, so pasting/dropping an image copies it into the item's `assets/`. The sync↔async
  bridge: `ItemAssetStore` (the single @MainActor name arbiter) reserves a unique `assets/<name>`
  *synchronously* (matching `NoteStore.disambiguateAsset`, against on-disk files + an in-flight `reserved`
  set) and hands it to the editor, then writes the bytes off-main via `NoteStore.writeReservedAsset`
  (exact name, never re-disambiguates → the ref always matches the file that lands; no-overwrite guard).
  Proven on a scratch store (`ItemAssetStoreTests`, 7 tests: persist/reload, same-name disambiguation,
  skip-preexisting, retarget, no-target-throw, never-overwrite, path-traversal-reject). Residual edges
  (non-blocking, documented for a future touch): (a) an async write *failure* (e.g. disk full) leaves a
  dangling ref → missing-asset placeholder (no data loss; logged, not surfaced to the user); (b) two
  windows editing the **same** note and pasting the same-named image in the same second have independent
  `reserved` sets, so the second write is refused by the no-overwrite guard (safe — no clobber — but that
  paste shows a placeholder); a shared name authority would need a single store, which can't serve two
  windows' differing selections. GUI drive of a live paste is deferred with the rest of W7 (Notes has no
  scratch-store launch override until **W8-S7** — driving the live app would write the owner's real store).
- **GUI drive of load/autosave deferred (GUI paused).** The load-on-select + autosave-on-switch behavior
  is proven at the model layer (`NoteBodyEditorModelTests` incl. the cross-item race + generation guard;
  `NotesModelBodyTests` round-trip/reindex/front-matter-preservation), but not yet driven in a live window.
  When GUI resumes: select note A, type, select B → A's edit persists (assert the on-disk `.md`) and B
  loads fresh; force-quit within the ~600 ms debounce is the known autosave-window caveat.

## Extracts create/copy-paste — follow-ups (W7-S2, 2026-07-13, open)

W7-S2 shipped the live Create-Extract (⌘⌥E) / Append-to-Extract… commands and the copy-in-Notes →
paste-into-Extract round-trip (`Extract` menu; `com.archivenotes.passage` on ⌘C in a note editor;
paste in an extract editor → note-passage blocks). Model + codec paths are unit-tested; conscious gaps:

- **Inline-image BYTES: copy side now embeds them (W7-S5); extract-paste byte import still a follow-up.**
  With W7-S5's `ItemAssetStore` wired into `NoteEditorPane`, the **copy** path
  (`copyPassageIfNote` → `EditorPassageSource(assetStore:)`) now resolves + snapshots the passage's inline-
  image *bytes* (not just the `assets/<name>` refs) into the `com.archivenotes.passage` payload. The
  Create/Append *commands* already persist those bytes into the new extract's `assets/` (proven by
  `ExtractBuilder` create/append asset tests). **Remaining gap:** the live extract-editor *paste* handler
  (`MarkdownEditorView.handlePassagePaste` → `ExtractBuilder.pastedExtractMarkdown`) inserts the passage
  markdown with image *references* but does not yet import the payload's bytes into the extract's own
  `assets/` (and rewrite the refs on name collision) — so a live copy→paste into an extract renders those
  images as missing-asset placeholders until saved via Create/Append. Closing this is a focused follow-up
  on the paste handler (the store + payload bytes are now both present); best confirmed under GUI drive.
- **Create-Extract doesn't auto-raise + select the new extract in the Extracts window (GUI, deferred).**
  The extract is created, filed into the Extracts home folder, and appears in the Extracts window's list
  immediately (both windows observe `allItems`), but the two windows hold independent
  `NotesNavigationModel` selections with no cross-window "open + select id X" channel yet. Raising/
  selecting the Extracts window on create → a GUI follow-up (needs a shared open-request on `NotesModel`
  or `openWindow`, best verified live). Same for the Append picker (an `NSAlert` popup, model-tested).
- **GUI drive deferred (GUI paused).** Not yet driven live: ⌘⌥E on a two-block selection → a two-block
  extract; copy-note → paste-into-extract → provenanced blocks; plain external paste → freeform; the
  Append picker. Logic is proven at the model/codec layer (`ExtractCommandTests`, `PasteboardPassageTests`,
  `BlockParserTests`).

## Extracts jump-to-source + provenance chips — follow-ups (W7-S3, 2026-07-13, open)

W7-S3 shipped the note-passage provenance chip's **Jump to Source** button + live-title label + the
in-app navigation channel (`NotesModel.openItem`/`pendingOpen`) and the Note-window consume side
(observe → `NotePassageResolve.openAction` → select + scroll-to-block, gated on `loadedID`). Pure logic
is unit-tested (`NotePassageResolveTests`, 20 tests incl. `openAction`); conscious gaps / edges:

- **GUI drive deferred (GUI paused).** Not yet driven live: click Jump in an extract block → the Note
  window selects the source note and scrolls to the right block; a deleted source → greyed chip +
  "source no longer exists — extract text preserved" status; a stale ordinal → scroll-to-top +
  "source has changed" status; a renamed source → chip shows the current title. Verify with
  `cliclick` on `an.chip.jump` + a screenshot when GUI resumes.
- **Window is selected + scrolled but not programmatically RAISED.** `openItem` reveals + scrolls the
  source note in the window that features its kind, but does not `orderFront`/focus that window (the
  cross-window channel W7-S2 flagged as missing now EXISTS for select+scroll; only the raise is left).
  A GUI follow-up (best verified live).
- **Chip live title refreshes on re-style, not reactively.** The chip resolves the source's current
  title/date from `allItems` when the extract editor (re)styles its content (open / select / raw-toggle
  / paste). A rename in the *other* window while the extract editor sits idle won't recolor the chip
  until it next re-styles. Acceptable (the common path — open the extract — shows current titles).
- **Same-window active-editing edge.** If the jump target note is being actively edited *in the same
  window* (its text view is first responder), freeze-during-edit skips the content re-apply, so the
  scroll maps against possibly-stale content (falls back to top if out of range — non-crashing). The
  realistic jump is cross-window (Extract → Note window), where the target window isn't first responder,
  so content re-applies and the scroll is exact.
- **Folder-scope-hidden target.** A jump clears the window's *user* filters so the row is reachable, but
  a shared *folder scope* that excludes the note is left intact; the editor still loads + scrolls the
  note (detail reads `allItems`, not the filtered list), but the list-row highlight may be absent.
- **Pre-existing warning (not W7-S3):** `Core/NotePassageSource.swift:118` — "conditional cast from
  '[NSValue]' to '[NSValue]' always succeeds" (W7-S2 code; surfaces on a clean compile). Trivial; fold
  into a future W7 touch.

## Extract-viewer featuring — follow-ups (W7-S4, 2026-07-14, open)

W7-S4 gave each window its kind featuring (Note→notes, Extract→extracts, remembered per window) via the
already-shipped segmented control, and added the extract-only **Sources** column (distinct source notes,
indexed into `items.source_count`). Logic is fully unit-tested (`KindFilterQueryTests` kind predicate +
distinct-source count; `NotesIndexTests.sourceCountRoundTrip` SQLite bind/read; `NotesAppSettingsTests`
per-window kind round-trip; `NotesNavigationModelTests` window defaults). Conscious gaps:

- **GUI drive deferred — no scratch Notes-store override yet (blocked on W8-S7).** Unlike Reader
  (`-ARUITestRootPath`), Notes has **no** DEBUG launch-arg to point the app at a throwaway store, so
  driving the live app to *create a segmented extract* would write into the owner's real Notes store
  (the file-safety analog of the Reader "never mutate the live root" incident). So the live checks —
  Extract window opens featuring extracts / Note window features notes / toggling to `both` unions /
  the Sources column shows the right count for a segmented extract — are deferred to Morning Review and
  are the natural payload for the **W8-S7** fixture-rooted XCUITest (which builds the scratch store).
- **The "Sources" column is always present, not per-window-hidden.** It renders the count for extracts
  and blank for notes, in *both* windows (so a notes list shows an empty column rather than adapting the
  column set away). Per-window default column visibility would need per-window `hiddenColumns` (today a
  single global `NotesAppSettings.hiddenColumns`); deferred as a polish item — the user can hide it via
  the existing right-click column picker.
- **`source_count` back-fills on re-index, not instantly, for a pre-`source_count` DB.** The additive
  `ALTER TABLE` defaults existing rows to 0; a stale row shows a blank Sources cell until its mtime
  changes (or the disposable index is deleted + rebuilt). Only affects a dev DB created before this
  change; a fresh index is correct from first build.

## Test harness — headless full-scheme run crashes (found 2026-07-13, open)

Running the **whole** `ArchiveNotes` unit scheme headless (`xcodebuild test …`, and therefore
`test-smoke.sh notes`) aborts the shared Swift-Testing process with:

```
NSInvalidArgumentException: -[ArchiveNotes.BlockHeaderChipView performClick:]: unrecognized selector
```

- **Source:** `SourceBlockViewTests` → "reveal callback receives the anchor" (a W4-S7 **display** test
  that drives the chip's Reveal button). It reproduces identically on `main` **before** any later files
  are compiled, so it is pre-existing — not tied to whatever change a session is making.
- **Impact:** one fatal `NSException` in a display test aborts *all* Swift-Testing tests in that process,
  so the whole-scheme smoke gate is red headless even when the logic suites are green. This is why W4-S7
  reported "**92 non-display** tests green".
- **Workaround (until fixed):** verify per-suite, not whole-scheme. `-only-testing:`/`-skip-testing:` do
  **not** match Swift-Testing suites in this Xcode/SDK (see below), so you can't skip the crashing suite
  by name; instead run the specific logic suite(s) you touched (e.g.
  `-only-testing:ArchiveNotesTests/<YourSwiftTestingSuite>` — which DOES run once the files are compiled).
- **Fix candidates (GUI-paused, deferred):** make `BlockHeaderChipView` respond to / forward
  `performClick:` (or have the test click the hosted `NSButton`, not the container `NSView`); and/or gate
  the display suites behind a trait so headless runs skip them. Then confirm the whole scheme is green.

## Build/test gotchas (XcodeGen + Swift Testing, 2026-07-13)

- **`xcodegen generate` must run AFTER adding files.** XcodeGen expands the globbed source dirs into an
  explicit file list at *generation* time (not synchronized groups). If you add a `.swift` file to
  `Sources/`/`Tests/` **after** generating, the `.xcodeproj` won't reference it — it silently isn't
  compiled, and `-only-testing:…/NewSuite` matches 0 tests. In a fresh worktree: write your files first,
  *then* `xcodegen generate`, then build/test. (Confirmed: 0 → N pbxproj refs only after re-generating.)
- **`-only-testing:` / `-skip-testing:` don't select Swift-Testing suites here** (Xcode w/ MacOSX26.2 SDK).
  A `Target/SuiteType` (or `Target/SuiteType/func`) filter selects 0 for `@Suite`/`@Test` types; the XCTest
  "Executed N tests" summary also excludes Swift-Testing results (those print as `✔ Test "…"` lines). Read
  the `✔ Test`/`✔ Suite`/`Test run with N tests` lines to confirm a Swift-Testing suite ran, not the XCTest
  summary. A bare `-only-testing:<Target>` runs everything (and hits the crash above).
