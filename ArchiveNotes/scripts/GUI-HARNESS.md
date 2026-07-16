# Archive Notes — GUI test harness (W8-S7/S8)

The deterministic GUI-verification harness for Archive Notes: an **XCUITest** suite that drives the
real app against a **scratch fixture store**, plus a cliclick/osascript drive library for the checks
XCUITest cannot express. This file is the human-facing README — what each check proves, how to run the
suite, and (crucially) **which checks are "owner-eye"**: they cannot be fully asserted by an automated
run and need a human to look.

> **File safety (Core Directive).** Every check runs against the SCRATCH fixture at
> `~/Library/Application Support/ArchiveNotes/AN-GUI-Fixture` — **never** the real store, never the
> corpus. The app is pointed at the fixture only via the volatile `-ANUITestStorePath` launch argument
> (`#if DEBUG`, never a persisted bookmark). **Never** drive "Choose Store Folder…" (it would overwrite
> the owner's real `notesStoreRootBookmark`). Full protocol: [`../GUI_SAFETY.md`](../GUI_SAFETY.md).

## Running the automated suite

```bash
# 1. (Re)build the scratch fixture (idempotent; prints the fixture path).
./ArchiveNotes/scripts/make-notes-fixture.sh

# 2. Build + run the XCUITest suite (GUI-on: unlocked screen, TCC Accessibility +
#    Screen Recording, taskport=allow for password-free XCUITest — see the root
#    .maintenance/AUTONOMOUS_PLAN.md GUI VERIFICATION block).
cd ArchiveNotes/macOS
xcodegen generate
xcodebuild test -scheme ArchiveNotes -only-testing:ArchiveNotesUITests \
  -derivedDataPath ./build/DD -destination 'platform=macOS'
```

The XCUITest runner is sandboxed with a DEBUG-only Route-B temporary-exception entitlement granting
read of `/Users/`, so it can both `fileExists`-check the fixture and let the app read the launch-arg
path. Each test subtracts a pre-test `itemDirs()` snapshot, because the runner has **read-only**
`/Users/` and cannot delete the items G0…/G1/G9 create — the fixture is rebuilt fresh per run instead.

## Check catalog

`G0`–`G11` are the per-wave checks (08-testing §3.7). "Auto" = asserted end-to-end by XCUITest;
"owner-eye" = a human must perform/observe the part XCUITest can't reach (see below).

| ID  | What it proves | Status |
|-----|----------------|--------|
| G0  | The `an.status.indexReady` probe is XCUITest-queryable and flips to the completion token once the initial index build settles | **Auto** |
| G1  | ⌘N / New menu writes a new `items/<uuid>/<Title>.md` on disk | **Auto** |
| G2  | Typing into the styled editor persists to the note's `.md` | **owner-eye** (typing gesture) |
| G3  | Raw-Markdown toggle shows literal source + is lossless round-trip | **Auto** |
| G4  | Paste image → the item's `assets/…png` + an inline `![](…)` reference (Tier-2 write) | **Auto** (via DEBUG paste seam); ⌘V gesture is owner-eye |
| G5  | Paste archive link as a source block (⌘⇧V) → a `reader-page` block in the `.md` | **Auto** |
| G6  | Reveal a reader-page source block → dispatches `archivereader://reveal?…` | **Auto** (URL dispatch); Reader launch is owner-eye |
| G7  | Replicate an item into a folder → a new membership in `organization.json` | **Auto** |
| G8  | Delete-last-instance guard: Cancel keeps, Delete trashes (Tier-2) | **Auto** |
| G9  | Create Extract from a note selection (⌘⌥E) → an extract item + note-passage block | **Auto** (via DEBUG selection seam) |
| G10 | Jump to Source from a note-passage chip → the source note is selected/loaded | **Auto** (via DEBUG jump seam); chip click is owner-eye |
| G11 | Open a Zotero chip → dispatches `zotero://select/…` | **Auto** (URL dispatch); Zotero launch is owner-eye |

### Why some checks use a DEBUG seam instead of the real gesture

TextKit-2 attachment view-provider subviews — the source-block/Zotero chip buttons (`an.chip.reveal`,
`an.chip.jump`, `an.chip.zoteroOpen`) — and the styled `NSTextView` itself are **not hit-testable by
XCUITest** (the same framework limit as PDFView content panes). So the checks that would otherwise
depend on those gestures drive the **real callback** through a `#if DEBUG` + `-ANUITestStorePath`-gated
seam on the hidden control strip (`an.editor.test.*`), which is compiled out of Release. This asserts
everything downstream of the gesture; only the **gesture itself** stays owner-eye.

## Owner-eye checks (must be done by a human)

Run these interactively against the scratch fixture. Launch the app pointed at the fixture — either
run the XCUITest suite (which launches it) or, for a manual session, pass the launch arg to a DEBUG
build so it opens the scratch store, e.g. via Xcode's scheme arguments:
`-ANUITestStorePath "$HOME/Library/Application Support/ArchiveNotes/AN-GUI-Fixture"`. **Never** use
File ▸ Choose Store Folder… (it persists over the owner's real root).

- **G2 — typing persists.** Select the plain note. Click into the editor body and type a short unique
  phrase. Switch to another note and back (or ⌘Q and relaunch against the fixture). **Expect:** the
  typed phrase is still there, and the note's `.md` in `AN-GUI-Fixture/items/<uuid>/` contains it.
  *(Automated coverage: G4/G5/G9 already prove the write-back/flush path on disk; only the raw keyboard
  typing gesture into the styled NSTextView is unautomatable.)*

- **G6 — reveal actually opens Reader.** Select the reader-page source-block note; in styled mode click
  the chip's **Reveal** button. **Expect:** Archive Reader launches (or comes forward) and selects the
  linked PDF. *(Automated coverage: G6 asserts the exact `archivereader://reveal?root=<GUID>…` URL is
  dispatched via `WorkspaceOpenSpy`; the harness suppresses the real launch under `-ANUITestStorePath`,
  so the cross-app open is the owner-eye part. Point Reader at the fixture's embedded
  `AN-GUI-Fixture/reader-corpus/`, not the real corpus.)*

- **G11 — Zotero chip actually opens Zotero.** Select the Zotero note; click the chip's **Open in
  Zotero**. **Expect:** Zotero comes forward on the referenced item (Zotero must be installed and the
  item present). *(Automated coverage: G11 asserts the exact `zotero://select/library/items/<key>` URL
  is dispatched; the real Zotero launch is owner-eye.)*

- **Chip-button click gestures (`an.chip.*`).** For G6/G10/G11 the automated checks fire the buttons'
  real callbacks via DEBUG seams because the chip buttons aren't XCUITest-hittable. A human should, at
  least once, confirm the on-screen chip buttons (Reveal / Jump to Source / Open in Zotero) are visible,
  correctly labelled, and respond to a real click. Making these subviews hit-testable would also help
  VoiceOver, but may be impossible for TextKit-2 attachment subviews (tracked in `KNOWN_ISSUES.md`).

## Files

- `make-notes-fixture.sh` — builds the scratch fixture (notes/reader-page/Zotero/extract items,
  replicated membership, embedded scratch Reader corpus, initial Finder-tag projection).
- `gui-drive-notes.sh` — sourced cliclick/osascript/capture/tag-read drive library (scratch-only; reads
  tags to assert, never drives the store picker). Calibrate its table geometry against a
  `gui_capture_window` shot before trusting row-index clicks.
- `macOS/Tests/ArchiveNotesUITests/` — `SmokeUITest.swift` (launch) + `NotesGUITests.swift`
  (`NotesFixtureUITestCase` base + G0–G11).
- [`../GUI_SAFETY.md`](../GUI_SAFETY.md) — the authoritative test file-safety protocol + the runtime
  DEBUG scratch-write guard.
