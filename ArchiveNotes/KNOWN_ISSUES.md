# Archive Notes — Known Issues & Gotchas

Running log of quirks, risks, and things verified/unverified for the Notes app. Keep current.
(Sibling logs: `../ArchiveReader/KNOWN_ISSUES.md`, `../ArchiveProcessor/KNOWN_ISSUES.md`.)

## Editor↔item body wiring — follow-ups (W7-S1a, 2026-07-13, open)

W7-S1a bound `NoteEditorPane` to the selected item's body (`NoteBodyEditorModel`: load-on-select,
autosave via `NotesModel.setBody`, flush-on-switch, autosave-race-safe). Two conscious deferrals:

- **Inline-image paste doesn't persist yet (item-scoped asset store deferred).** `NoteEditorPane` passes
  **no** `EditorAssetStore`, so pasting/dropping an image into a note editor won't copy it into the item's
  `assets/` (unchanged from before W7-S1a — the pane never had a store). The clean fix is an item-scoped
  store backed by `NoteStore.importAsset`, but that API is an **async actor** method while
  `EditorAssetStore.addAsset` is **synchronous** — bridging them without blocking the main thread is the
  real work. Deferred to a focused follow-up. (The W2 asset-copy helper already covers *extract* snapshots
  via `ExtractBuilder`; this gap is only the note editor's inline-paste path.)
- **GUI drive of load/autosave deferred (GUI paused).** The load-on-select + autosave-on-switch behavior
  is proven at the model layer (`NoteBodyEditorModelTests` incl. the cross-item race + generation guard;
  `NotesModelBodyTests` round-trip/reindex/front-matter-preservation), but not yet driven in a live window.
  When GUI resumes: select note A, type, select B → A's edit persists (assert the on-disk `.md`) and B
  loads fresh; force-quit within the ~600 ms debounce is the known autosave-window caveat.

## Extracts create/copy-paste — follow-ups (W7-S2, 2026-07-13, open)

W7-S2 shipped the live Create-Extract (⌘⌥E) / Append-to-Extract… commands and the copy-in-Notes →
paste-into-Extract round-trip (`Extract` menu; `com.archivenotes.passage` on ⌘C in a note editor;
paste in an extract editor → note-passage blocks). Model + codec paths are unit-tested; conscious gaps:

- **Inline-image BYTES don't survive the copy→paste round-trip yet (rides the deferred asset store,
  W7-S5).** `NoteEditorPane` passes **no** `EditorAssetStore`, so `EditorPassageSource` snapshots the
  passage's markdown image *references* (`assets/<name>`) but not the bytes; the extract paste inserts
  those refs (rendering as missing-asset placeholders) rather than importing bytes into the extract's
  own `assets/`. The Create/Append *commands* copy bytes correctly **when** a store is present (proven
  by `ExtractBuilder` create/append asset tests) — this gap is only the editor's live copy/paste path,
  and closes when the same item-scoped `EditorAssetStore` (W7-S5) lands for both note-image paste and
  passage copy.
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
