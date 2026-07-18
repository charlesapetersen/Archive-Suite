# Archive Notes — Known Issues & Gotchas

Running log of quirks, risks, and things verified/unverified for the Notes app. Keep current.
(Sibling logs: `../ArchiveReader/KNOWN_ISSUES.md`, `../ArchiveProcessor/KNOWN_ISSUES.md`.)

## GUI harness (W8-S8b, W8 COMPLETE): index-ready probe now XCUITest-queryable + owner-eye harness README (2026-07-15) — Tier-2

Closes the two remaining W8-S8 items → **Wave 8 (Notes tests + GUI harness) COMPLETE, SUITE_TODO W8 flipped.**

- **`an.status.indexReady` probe queryability — FIXED.** It was a 1×1 `Color.clear` + `allowsHitTesting(false)`
  a11y element that XCUITest could not resolve (its value stayed empty across a 30 s poll — pass-1 observation).
  Root cause: a zero-size, clear, non-hittable view produces no resolvable a11y element with a readable value,
  and `waitForIndexReady` read **only** `.value` (whereas the working `lastOpenedURL` helper falls back to
  `.label`). Now (`NotesBrowserView.indexReadyProbe`) it is a normally-rendered `Text` **gated to the UITest
  harness** (`#if DEBUG` + `-ANUITestStorePath`, mirroring the control strip — a normal DEBUG run and Release
  carry NO probe at all, strictly cleaner than the old always-present clear element). It sits in
  `.background(...)` behind the opaque 3-pane content, so it is occluded (never visible) yet stays in the a11y
  tree; its `accessibilityValue` carries the bare generation token (empty until settle) and the label mirrors
  it (`building` → `ready:<gen>`), and the helper accepts either. New **G0**
  (`testG0_IndexReadyProbeResolvesAfterInitialBuild`) asserts the probe both exists and flips to a non-empty
  token once the initial index build settles — so a later FTS/relevance check can safely gate on it.
- **Owner-eye harness README shipped** — `ArchiveNotes/scripts/GUI-HARNESS.md`: how to run the suite, the full
  G0–G11 catalog (auto vs owner-eye), and the exact human steps for the checks XCUITest can't fully assert
  (**G2** typing into the styled NSTextView, **G6/G11** the real Reader/Zotero launch, and the un-hit-testable
  **chip-button click** gestures). Linked from `ArchiveNotes/CLAUDE.md`.
- **Verified live GUI-on:** full `ArchiveNotesUITests` suite **TEST EXECUTE SUCCEEDED — 13/13** (G0 + G1/G3/G4/
  G5/G6/G7/G8/G9/G10/G11 + SmokeUITest), 0 failures; `build-for-testing` clean, **0 new warnings**; Release build
  proves the DEBUG probe compiles out (`#else` → `EmptyView`). **Tier-2 gate met:** adversarial self-review
  (display-only a11y element, no write path, no normal-run/Release behavior change) + live scratch functional
  run + post-run file-safety (real `Store` **absent**, `notesStoreRootBookmark` not persisted, real
  `notes-index-v1.sqlite3` untouched — UITest used `notes-index-uitest.sqlite3`, writes confined to `AN-GUI-Fixture`).

## GUI harness (W8-S8 pass 7): G6 reveal → Reader + G11 Zotero chip open green — one `NSWorkspace.open` spy serves both (2026-07-15) — Tier-2

Added **G6** (`testG6_RevealSourceBlockDispatchesReaderDeepLink`) + **G11** (`testG11_ZoteroChipDispatchesSelectLink`):
a reader-page source block's "Reveal in Reader" dispatches the correct `archivereader://reveal?root=<corpus GUID>&rel=sample.pdf&…`
deep link, and a Zotero source block's "Open in Zotero" dispatches `zotero://select/library/items/ABCD1234`. Both pass
live in the full suite (G1/G3/G4/G5/**G6**/G7/G8/G9/G10/**G11** + SmokeUITest, **TEST EXECUTE SUCCEEDED**, 11/11, 0
failures; ~13 s each); 189 XCTest + Swift-Testing green; **Release build clean (all seams compiled out)**; 0 new warnings.

- **New shared choke-point `openExternalURL(_:)`** (`Core/WorkspaceOpen.swift`) that the three external-URL sites now
  route through (`NoteEditorPane` reveal closure, `BlockHeaderChipView.openZoteroClicked`, `ZoteroChipView.open`).
  In Release and a normal DEBUG run it calls `NSWorkspace.shared.open` exactly as before; **only** under a UITest
  launch (`-ANUITestStorePath`) the DEBUG `WorkspaceOpenSpy` **records** the URL and skips the real open — so the
  harness asserts the dispatched URL WITHOUT launching Reader/Zotero (Zotero may not even be installed on the run
  machine). The spy branch is `#if DEBUG` + launch-arg-gated (verified compiled out by a Release build).
- **Chip buttons `an.chip.reveal` / `an.chip.zoteroOpen` are NOT XCUITest-hittable** (same TextKit-2 attachment-view
  limit confirmed for `an.chip.jump` in pass 6), so — as with G4/G9/G10 — DEBUG seams fire the real callbacks:
  `EditorTextView.uiTestRevealFirstSource()` (fires the reader-page chip's real `onReveal` → `openExternalURL`) and
  `uiTestOpenFirstZotero()` (runs the real zotero-open dispatch). The harness reads the dispatched URL back from a
  visible control-strip static text `an.editor.test.lastOpenedURL` (deliberately NOT a 1×1 hidden element — that's
  the `an.status.indexReady` queryability hazard). Only the button CLICK gesture is bypassed; the **real
  Reader/Zotero launch stays owner-eye** (like G2's typing).
- File-safe (read-only dispatch, no store/corpus writes): post-run the real `Store` is **absent**, real
  `notes-index-v1.sqlite3` untouched, `notesStoreRootBookmark` not persisted; all writes confined to the scratch fixture.
- **RESOLVED (W8-S8b, above):** the `an.status.indexReady` probe queryability fix + the G2/G6/G11 owner-eye
  harness docs both landed → **W8-S8 complete, SUITE_TODO W8 flipped.**

## GUI harness (W8-S8 pass 6): G10 jump-to-source green — chip button confirmed NOT XCUITest-hittable → DEBUG jump seam (2026-07-15) — Tier-2

Added **G10** (`NotesGUITests.testG10_JumpToSourceSelectsSourceNoteInNoteWindow`): firing an extract's
`note-passage` chip "Jump to Source" navigates to the linked source note. Single-window design: the Note
window's **fixed** `windowKind` is `.note`, so it owns the jump to a `.note` source *regardless of its kind
filter* — so the check shows BOTH kinds in the Note window (`an.filter.kind` → "Both"), selects the extract
(editor loads "Moore says…"), fires the jump, and observes the SAME editor reload the source note's body
("Moore on Intel…"). Those two phrases are unique per item, so the transition proves the source note was
selected + loaded. Passes live in the full suite (G1/G3/G4/G5/G7/G8/G9/**G10** + SmokeUITest, **TEST EXECUTE
SUCCEEDED**, 0 failures); 189 XCTest + Swift-Testing green; Release build clean (seam compiled out); 0 new warnings.

- **CONFIRMED: the chip's on-screen button `an.chip.jump` is NOT in the XCUITest accessibility tree** (a first
  attempt clicking it timed out at `waitForExistence`). The chip is a TextKit-2 attachment-view-provider
  subview (`BlockHeaderChipView` inside `BlockHeaderAttachment.viewProvider`); such subviews aren't hit-testable
  by XCUITest (same class of limit as PDFView content panes in the Reader harness). This is exactly why the
  plan's ORIGINAL G10 spec (08-testing §Design) said **cliclick**, not XCUITest.
- **Drove the jump through a DEBUG seam** (same plan-blessed precedent as G4/G9): `EditorTextView.uiTestJumpFirstPassage()`
  scans the text storage for the first note-passage `BlockHeaderAttachment` and fires its **real `onJump`
  callback with the real `SourceAnchor`** — the identical closure + anchor the chip button's `jumpClicked`
  invokes (→ `NoteEditorPane.onJumpBlock` → `NotesModel.openItem` → cross-window `NotePassageResolve.openAction`
  → select+load). Only the button-CLICK gesture is bypassed; the literal chip click is **owner-eye** (like G2's
  typing). Surfaced via hidden control-strip button `an.editor.test.jump` (→ `EditorTestBox.jumpFirstPassage`
  → coordinator `uiTestJumpFirstPassage`). All additions `#if DEBUG`, compiled out of Release (verified).
  Read-only navigation (no write-back, no store/corpus write).
- **Future (low-pri, owner-eye today):** making the chip buttons (`an.chip.{jump,reveal,preview,zoteroOpen}`)
  XCUITest-hittable would also help VoiceOver — may not be possible for TextKit-2 attachment subviews; not
  attempted this pass. Logged to Morning Review.
- **REMAINING (W8-S8 still open — oversized, recommend re-split):** G6 (reveal → Reader) + G11 (Zotero chip
  open), both needing a DEBUG `NSWorkspace.open` spy (assert the dispatched URL; real external launch owner-eye);
  the `an.status.indexReady` probe queryability fix; G2/G6/G11 owner-eye docs in the harness README. Only then
  tick W8-S8 + flip SUITE_TODO W8.

## GUI harness (W8-S8 pass 5): G4 paste-image green — the last un-GUI-verified file-WRITE path — via a DEBUG paste seam (2026-07-15) — Tier-2

Added **G4** (`NotesGUITests.testG4_PasteImageWritesAssetAndInlineReference`): pasting an image into a note
writes `items/<uuid>/assets/pasted-….png` AND an `![](assets/pasted-…)` inline reference into the note's
`.md`. This drives W3-S4's image-paste handler (`EditorTextView.tryPasteImage`) end-to-end through W7-S5's
item-scoped `ItemAssetStore` — the **last un-GUI-verified file-WRITE path** in Notes. Passes live in the full
suite (G1/G3/G4/G5/G7/G8/G9 + SmokeUITest, **TEST SUCCEEDED**, 0 failures); 189 XCTest + Swift-Testing green;
Release build clean (seam compiled out); 0 new warnings. Tier-2 (real byte write): adversarial self-review +
scratch functional run + post-run file-safety (asset + reference confined to the scratch `AN-GUI-Fixture`;
real `Store` **absent**; `notesStoreRootBookmark` not persisted).

- **⌘V routing into the styled NSTextView is NOT XCUITest-drivable → drove the paste through a DEBUG seam.**
  A first attempt fired a real `⌘V` after `editor.click()`; it fell through to the DEFAULT `super.paste`
  (no `pasted-…` asset written, only the load/flush round-trip bumped `modified`), i.e. either the text view
  wasn't first responder or the app didn't consume the pasteboard image. This is the **same documented weak
  spot** the selection seam (G9) already works around. Added a DEBUG-only seam
  `EditorTextView.uiTestPasteImage()` → invokes the **real** `tryPasteImage(from: NSPasteboard.general)` (asset
  write + attachment insert + serialize run verbatim; nothing stubbed), surfaced via the hidden control-strip
  button `an.editor.test.pasteImage` (→ `EditorTestBox.pasteImage` → coordinator `uiTestPasteImage` +
  `flushWriteBack`). Only the ⌘V **gesture routing** is bypassed — that gesture is **owner-eye** (like G2's
  typing). All additions are `#if DEBUG` and compile out of Release (verified by a Release build).
- **Plan reconciliation:** the plan lists G4 as a *cliclick* check; it's implemented as a disk-asserted
  XCUITest instead (deterministic, no pointer geometry) — parity with how G5/G9 (also "special-handling"
  checks) were done. Logged in `.maintenance/ARCHIVE_NOTES_PROGRESS.md`.
- **REMAINING (W8-S8 still open):** G6 (reveal → Reader) / G10 (jump-to-source) / G11 (Zotero chip open);
  G2/G6/G11 owner-eye docs in the harness README; and the `an.status.indexReady` probe queryability fix
  (below, pass 1). Only then tick W8-S8 + flip SUITE_TODO W8.

## GUI harness (W8-S8 pass 4): G7 replicate + G8 delete-last-instance green — INDEX-DB seam unblocks the folder graph (2026-07-15) — Tier-2

Added **G7** (`NotesGUITests.testG7_ReplicateItemIntoFolderAddsMembership`) and **G8**
(`…testG8_DeleteLastInstanceGuardCancelKeepsThenConfirmTrashes`). Both drive the folder-organization graph
(replication / the §3.6 delete-last-instance guard) end-to-end and assert on the fixture's
`organization.json` + `items/`. Pass live in the full suite (G1/G3/G5/G7/G8/G9 + SmokeUITest, **TEST EXECUTE
SUCCEEDED**); 189 XCTest + Swift-Testing green; 0 new warnings. Notes-only → Reader/Processor parity holds.
Tier-2 (file-writing + data-loss): adversarial self-review + scratch functional run + post-run file-safety
check (real Store absent, `notesStoreRootBookmark` not persisted, real `notes-index-v1.sqlite3` untouched at
its pre-run mtime, all writes confined to the scratch `AN-GUI-Fixture`).

- **RESOLVED — the pass-3 INDEX-DB blocker.** New DEBUG seam `NotesModel.indexDatabaseURL(inAppSupport:)`:
  under `-ANUITestStorePath` the app opens a dedicated `notes-index-uitest.sqlite3` (container Application
  Support) that is **reset on every launch** (`resetUITestIndexDatabase` deletes the `.sqlite3`/`-wal`/`-shm`
  triple + ensures the dir). So the container index no longer shadows the fixture: the fresh DB has zero
  folders → `OrganizationStore.load` falls back to the fixture's `organization.json` → the Reading/Ideas
  folders + the replicated item load deterministically. Distinct filename keeps the owner's real
  `notes-index-v1.sqlite3` untouched (verified); DEBUG-only + launch-arg-gated → compiled out of Release and
  never runs on a normal launch. The index is a rebuildable cache, so resetting it loses nothing.
- **FIXED (a11y bug, latent) — a container `.accessibilityIdentifier` was shadowing the controls inside it.**
  `LocationsInspector` set `.accessibilityIdentifier("an.detail.locations")` on its enclosing `VStack`; on
  macOS SwiftUI that id **propagates to every descendant AX element**, so the folder-row Remove button
  (intended id `an.locations.remove`) reported `an.detail.locations` instead and was unreachable to XCUITest
  (the W8-S7-"confirmed" id was in fact dead). Moved the section marker onto the header row only; the per-row
  button id now resolves. **Same shape still latent on `an.detail.header` / `an.detail.metadata`** (their
  child elements also report the container id) — harmless today because no check queries those children, but a
  future check that needs one must relocate the marker the same way.
- **G8 confirms the recoverable-delete contract under the sandbox:** Cancel leaves the note on disk + its
  membership intact; Delete Note moves `items/<uuid>` out via `FileManager.trashItem` (system Trash,
  recoverable) — verified working even with only the Route-B temporary-exception grant.
- **REMAINING (W8-S8 still open):** the checks G6 (reveal → Reader) / G10 (jump-to-source) / G11 (Zotero
  chip open); G2/G6/G11 owner-eye docs; and the `an.status.indexReady` probe queryability fix (below, pass 1).
  Only then tick W8-S8 + flip SUITE_TODO W8. **(G4 done — pass 5, above.)**

## GUI harness live (W8-S8 pass 1): first XCUITest checks green (G1, G3) + FIXED a main-thread editor loop the drive surfaced (2026-07-15)

W8-S8 (GUI-on) began driving the shipped Notes UI under XCUITest. First two per-wave checks are green live
(`NotesGUITests`, ~30 s, no hang): **G1** create-a-note (⌘N → a new `items/<uuid>/<Title>.md` appears on
disk) and **G3** raw-Markdown toggle (`an.editor.rawToggle` → the literal `**bold**`/`# ` source shows in raw
mode, hidden in styled; round-trip preserves the note body). Base class `NotesFixtureUITestCase` (mirrors
Reader's `FixtureUITestCase`) launches against the scratch `AN-GUI-Fixture` via the DEBUG `-ANUITestStorePath`
override; readiness gates on a seeded row.

- **FIXED (real bug, Tier-1) — `MarkdownEditorView` pinned the main thread at 100% CPU whenever a styled note
  was shown without the editor focused.** Selecting a note (row click; editor not first responder) made
  `updateNSView` re-apply the styled text on every SwiftUI pass, because its guard compared the *rendered*
  `textView.string` to the *raw* `markdown` — which never match in styled mode. Each re-apply fired a
  selection-change → `Coordinator.textViewDidChangeSelection` → `FormattingContext.updateState()` mutating an
  `@Published` value *during* the view update → SwiftUI re-invalidation → `updateNSView` again → infinite loop
  (XCUITest-captured spindump: main thread 501/501 samples in exactly this cycle; also emitted the "Modifying
  state during view update" runtime issue each turn). Fix: gate the re-apply on the last-applied SOURCE
  markdown (`coordinator.lastAppliedMarkdown`), not the rendered string, so `updateNSView` is idempotent;
  `makeNSView`/`switchMode` record the applied source. This spun in **normal use** too (a user reading a note
  without clicking into the editor), not just under test. 189 XCTest + all Swift-Testing suites green (incl.
  `EditorBindingTests`, `MarkdownBridgeTests`, `FormattingActionTests`), 0 new warnings.
- **OBSERVATION (minor, flagged) — a raw↔styled toggle canonicalizes the note body's whitespace on disk.**
  `switchMode` flushes a write-back and the Markdown serializer collapses the blank line after an ATX heading
  and drops the trailing newline (semantically identical — no content lost). A view-only toggle thus rewrites
  the note's own `.md` (mtime churn) with no edit. Not data loss and within Notes' own-store write rights
  (never the corpus), but worth revisiting (skip the write when `serialize(storage) == parent.markdown`).
- **OBSERVATION — the `an.status.indexReady` probe (W8-S7 §3.4) did not resolve as a readiness gate under
  XCUITest** (1×1 clear-color a11y element; value stayed empty across a 30 s poll). Non-blocking (the tests
  gate on a concrete seeded row) but the probe's queryability — flagged UNVERIFIED at W8-S7 — needs a fix
  (bump the frame / adjust the a11y wrapping) before any FTS/relevance check relies on it.
- **REMAINING (W8-S8 is oversized — recommend re-split; see plan Session Log / Morning Review):** G5 (paste →
  source block), G7 (replicate), G8 (delete-last-instance, Tier-2) under XCUITest;
  G4/G6/G10/G11 in cliclick; G2/G6/G11 owner-eye docs. G5/G6 exercise the reader-page **source-block chip** —
  confirm its durable-link/thumbnail render (against the ungranted scratch corpus root) idles under the drive
  before relying on those checks. (G9 landed in pass 2, below.)

## GUI harness (W8-S8 pass 2): G9 create-extract green — first use of the DEBUG selection seam (2026-07-15)

Added **G9** (`NotesGUITests.testG9_CreateExtractFromSelectionWritesExtractItem`), the first check to drive
the W8-S7 §3.3 DEBUG editor selection seam. Flow: select the plain note → set a non-empty selection via the
hidden strip (`an.editor.test.selectionInput` "0,8" → `an.editor.test.select`) → **Extract ▸ Create Extract
(⌘⌥E)** → assert a NEW `items/<uuid>/<Title>.md` lands with `kind: extract` and a `note-passage` block linking
back to the source note (`archivenotes://open?id=<idPlain>`). Passes live (~18 s, no hang); the model path was
already unit-covered by `ExtractCommandTests`, so this is the end-to-end UI proof. G1 + G3 + SmokeUITest still
green in the same run; 189 XCTest + Swift-Testing suites green; 0 new warnings. Notes-only → Reader/Processor
parity holds.

- **STRIP SIZING (fixed) — the DEBUG UITest control strip was `.frame(height: 14).font(.caption2)`,** which
  the W8-S7 notes flagged as an unverified XCUITest hit-testing hazard. Raised to `.frame(height: 28)` (dropped
  `.caption2`); XCUITest now reliably focuses the field + clicks the buttons. DEBUG- and
  `-ANUITestStorePath`-gated, so a normal run never shows it and Release omits it entirely (no product change).
- **FINDING — the XCUITest *runner* has READ-ONLY access to `/Users/`.** The RW temporary-exception
  entitlement is on the app-under-test, NOT the `ArchiveNotesUITests` runner, so a test can read the fixture
  to assert but **cannot delete the items it creates** (proven: a G1/G9-created dir has mtime = its creation
  time and survives `tearDown`, so `removeItem` silently no-ops). Consequence: create-checks (G1, G9) leave
  their new item on disk within a run; the fixture is rebuilt externally by `make-notes-fixture.sh` before each
  run (mirroring the Reader harness), and every assertion tolerates a dirty fixture by subtracting a pre-test
  `itemDirs()` snapshot — so leftovers never change a result. (The earlier "best-effort cleanup / Route-B is
  RW" comment was wrong for the runner and was removed.)

## GUI harness (W8-S8 pass 3): G5 paste-as-source-block green (2026-07-15)

Added **G5** (`NotesGUITests.testG5_PasteArchiveLinkAsSourceBlockWritesReaderPageBlock`). Flow: seed
`NSPasteboard.general` (from the test runner, cross-process) with a plain-text `archivereader://reveal?…&page=2`
durable link → select the Zotero fixture note (`idZotero`, a real `kind: note`) → ensure STYLED mode →
**Edit ▸ Paste as Source Block(s) (⌘⇧V)** → flush the editor write-back (select-away, W7-S6 inline flush) →
assert the note's `.md` gains a `<!-- block: reader-page … -->` block that preserves the durable link, and the
note's original `zotero-item` block survives (paste is additive). Passes live (~15 s, no hang); G1 + G3 + G9 +
SmokeUITest all still green in the same run (**TEST EXECUTE SUCCEEDED**). 0 new warnings (the 22 residual
`NotesGUITests.swift` warnings are pre-existing base-class `setUpWithError` main-actor-isolation notes, W8-S7's
accepted "32 residual" — none in the G5 additions). File-safe: the block write landed only in the scratch
fixture's `idZotero` note; the real Store is absent and `notesStoreRootBookmark` was not persisted.

- **Uses the plain-text fallback** (`SourceBlockPaster.scanURLs`), not the custom UTI, so no `ArchiveLinkPayload`
  encode is needed and there is no thumbnail render (the pasted `.readerPage` block has `thumbnailData == nil`)
  — G5 deliberately avoids the reader-page-chip thumbnail path (that render idle-check rides G6). Target is
  `idZotero`, not the plain note, so G5 doesn't perturb the note G3/G9 depend on; the Zotero chip has no
  thumbnail either. `handleSourceBlockPaste` requires `!currentIsRaw` (paste only in styled mode) and declines a
  Reader link pasted into an *extract* (§D7) — both honored by the target/mode choice.
- **BLOCKER for G7/G8 (folder replicate / delete-last-instance) — the INDEX-DB caveat, now fully traced.** The
  folder tree loads **DB-first**: `OrganizationStore.load(storeRoot:)` reads folders from the sqlite index
  (`NotesIndex.allFolders()`) and consults the store's `organization.json` **only when that DB has zero
  folders**. The index DB lives in the app **container**
  (`~/Library/Containers/com.archivenotes.app/Data/Library/Application Support/ArchiveNotes/notes-index-v1.sqlite3`),
  NOT under the `-ANUITestStorePath` fixture, and it **survives across launches** (no UITest reset), so a prior
  run's cached graph shadows the fixture's `organization.json` and the fixture's Reading/Ideas folders never
  appear. Replicate/delete DO persist to both the DB and `<fixture>/organization.json` (`OrganizationStore.add/
  forceRemoveLastMembership → exportOrganization`), so a test can assert on `organization.json` — but the folders
  must first LOAD. **Fix for the next session (do NOT delete the owner's container):** add a DEBUG seam that, under
  `-ANUITestStorePath`, points `NotesIndex`'s DB at a path *inside the fixture* (or a temp dir) instead of the
  container — then the fixture DB starts empty → `organization.json` loads fresh → G7/G8 become deterministic,
  and the container is never touched. G8's confirm/cancel IDs are `an.dialog.deleteLastInstance.confirm`/`.cancel`
  (`NotesBrowserView`); the `an.locations.remove` button (`LocationsInspector`) is the trigger; confirm →
  `NoteStore.delete` → `FileManager.trashItem` (recoverable, never `removeItem`).

## Zotero client tested over the REAL transport (in-process HTTP stub); attachment-kind reconciled (W8-S5, 2026-07-14)

W8-S5 added `ZoteroLocalServerTests` (plan §1.8, 5 tests, all green, no network egress). Unlike the W5-S2
`ZoteroClientTests` — which inject a hand-written `ZoteroTransport` stub that never builds a URLSession —
these drive the **production** `URLSessionZoteroTransport` over a URLSession whose `protocolClasses`
intercept every request in-process. So the full runtime HTTP stack is exercised: `Config` base-URL seam →
`URLRequest` → `URLSession.data(for:)` → `HTTPURLResponse` cast → probe/fetch/citation/degrade/**timeout**
(the timeout test really waits ~1.2 s for two 0.6 s request timeouts to fire — the bound is real, not stubbed).

- **HARNESS RECONCILIATION — `URLProtocol`, not a real `NWListener`.** The plan's headline was a localhost
  HTTP server, but the test bundle is hosted by the sandboxed app (`TEST_HOST`) which ships only
  `network.client` — a real listener can't accept loopback connections without `network.server`, and widening
  the shipping app's entitlements for a test would be wrong. `URLProtocol` needs no network entitlement and
  guarantees zero egress; the plan explicitly lists it as an allowed harness. Required one tiny, additive
  production seam: `URLSessionZoteroTransport.init(session:)` (dependency injection; the client's own
  ephemeral session can't have a `URLProtocol` injected, and global `URLProtocol.registerClass` doesn't apply
  to custom-configured sessions).
- **RECONCILIATION — `testAttachmentSelectLinkParsed`.** A `zotero://select/…` URL does **not** encode
  item-vs-attachment (confirmed by `ZoteroSelectLinkTests.testDefaultKindIsItem`); attachment-ness is a
  front-matter/model attribute (`ZoteroRef.kind` = `.attachment` + `parentKey`, covered by
  `ZoteroFrontMatterRoundTripTests`). The test therefore pins the achievable contract: the URL yields the
  right key+library, and an attachment ref both carries `kind:.attachment`/`parentKey` and fetches over the
  client just like an item ref (attachments are addressed by their own key on the local API) — D8's "item AND
  attachment" support. No production change to the parser (a testing sub-task must not invent behaviour).
- **No bug found.** The read-only client degraded correctly on connection-refused (`.unavailable`, no throw to
  the caller) and on hang (bounded timeout); the stored `selectLink`/`citation` survive a down server so the
  chip stays usable. No file-safety surface (no corpus/store writes) → Tier-1.

## Virtual-folder / durable-link / date-sort parity suites; sortDate cross-app divergence guarded (W8-S4, 2026-07-14)

W8-S4 added the plan §1.5/§1.6/§1.7 parity suites and, in doing so, pinned a real cross-app divergence.

- **NEW parity suites (all green, scratch-only):** `VirtualFolderReplicationTests` (7, §1.5 — DevonThink
  replicant + delete-last-instance invariants on a scratch `OrganizationStore`) and
  `ArchiveCoreTests/DateSortParityTests` (7, §1.7 — the shared SPEC §7 `DocumentTags.sortDate` key), plus a
  `/`-in-multi-segment-rel-path round-trip added to `ArchiveCoreTests/DurableLinkTests` (§1.6) and a
  cross-implementation parity guard added to `ItemSortDateTests`.
- **FINDING (flagged to Morning Review) — Notes `Item.sortDate` RE-IMPLEMENTS the shared sort formula
  rather than reusing it.** §1.7's `testReuseNotReimplemented` wanted a "routes through the shared
  `DocumentTags.sortDate`" guard, but `Item.sortDate` (`Store/Item.swift`) duplicates the `*10_000/*100`
  arithmetic inline over `date:String?`+`datePrecision`, whereas Reader reuses
  `ArchiveCore.DocumentTags.sortDate`. ArchiveCore exposes no shared `(year,month,day,decade)→Int?`
  combiner for the string+precision input to call, so a literal reuse-guard isn't satisfiable today.
  Reconciled to a **value-parity guard** (`ItemSortDateTests.testItemSortDateMatchesArchiveCoreSharedFormula`):
  for a shared table of dates, `Item.sortDate` MUST equal `DocumentTags.sortDate`, so any future drift
  fails a test. Sort order is a display/ordering concern (never written to a corpus → low file-safety
  stakes); the hardening follow-up — extract a shared numeric combiner in ArchiveCore and route both sides
  through it — is a Morning-Review item, out of scope for this testing sub-task.
- **RECONCILED — §1.6 resolve / re-grant / fallback live at the Notes layer, not ArchiveCore.** The plan
  placed the durable-link *resolver* cases in `ArchiveCoreTests/DurableLinkTests`, but the resolver
  (`ReaderLinkResolver` + `LinkResolution`, W4-S5) is a `@MainActor` type in the Notes app (it needs
  security-scoped bookmarks), so those cases already live in `ReaderLinkResolverTests` (resolve /
  unknown-guid→`needsRootGrant` / missing→`notFound` / renamed-candidate / path-traversal-rejected /
  grant-verify). ArchiveCore's DurableLink coverage is codec-only; W8-S4 closed its one gap (literal `/`
  preserved on the wire, not percent-encoded to `%2F`).

## Index suite completed + prune-gate hardened; bm25 columns reconciled (W8-S3, 2026-07-14)

W8-S3 completed the `NotesIndex` verification layer (plan §1.4) and hardened the prune path it covers.

- **HARDENED — the two-emission prune gate now provably can't wipe the index on an empty snapshot.**
  The gate logic was inline in `NotesIndexer.pruneIfSettled`'s detached task, so its data-safety property
  was neither deterministically testable nor guaranteed against a *persistent* empty snapshot: a naive
  two-emission gate stashes the whole index as "absent" on the first empty `currentIDs`, then DELETES it
  all on the second. The gate is now a pure `nonisolated static func pruneDecision(indexed:currentIDs:
  previousPending:)` whose **first rule is an empty-`currentIDs` guard** (empty → delete nothing, stash
  nothing). `pruneIfSettled` calls it; the non-empty behaviour is byte-identical to before (verified by
  re-derivation — same absent/confirmed/remaining math, same delete-only-if-nonempty, same pending
  carry-forward). The index is a rebuildable cache, so refusing to prune on an empty snapshot is always
  safe (a mid-build / scope-cleared snapshot is far likelier than a genuine zero-item store, which clears
  via the normal delete path anyway). Note `pruneIfSettled` is **not yet wired to a caller** in Notes
  (mirrors Reader's `ContentIndexer`; future wiring adds the settled/boundary-scope Gate 1), so this was a
  latent risk, not an active bug — but the guarantee now holds inside the method, independent of any
  caller. Pinned by four pure `pruneGate…` tests (empty-snapshot never wipes even when repeated;
  two-emission required; transient drop not deleted; only twice-confirmed absences deleted).
- **RECONCILED (plan §1.4 vs shipped) — the FTS index has four weighted columns, not five.** §1.4 lists a
  `linked-doc-display=3` weight, but the shipped `fts5(title, tags, authors, body, id UNINDEXED)` schema
  (W2-S4) has no such column and orders by `bm25(fts, 10, 6, 4, 1)`. The existing bm25 tests
  (`bm25TitleOutranksBody`, `tagsOutrankAuthorsOutrankBody`) therefore already cover every weighted column;
  no linked-doc-display test was invented. A linked-doc-display column would be a schema + indexer change,
  not a test gap.
- **Coverage added to `NotesIndexTests`** (10 → 16): `reindexReplacesOldBody` (body-specific re-index; the
  existing `incrementalMtimeSkip` covered only the title) and `organizationGraphPersistsAndReloads` (the
  NotesIndex DB layer directly — folders + memberships + **template assignments** survive a close/reopen;
  `OrganizationStoreTests.foldersPersistToDB` covers the store layer but not template assignments via DB).
  All 16 green on scratch sqlite; adjacent `OrganizationStoreTests`/`OrganizationFileTests`/`NotesModelTests`
  (31) green. Tier-2 (the org-graph writer + `organization.json` are durable app-owned data).

## Tag projector safety suite + a latent concurrent-write race (W8-S2, 2026-07-14)

W8-S2 landed the **crown-jewel** `NotesTagProjectorSafetyTests` (10 scratch-file tests) covering every
`TagWriter`/`CoordinatedTagWriter` invariant the projector reimplements: read-failure aborts (never
coerce a failed read to `[]`), lossless preservation of unmanaged tags, the `"ArchiveSuite"`-subject
collision (single token / whole-string match / marker never stripped by dropping the subject),
verify-by-re-read backed by an independent ground-truth read + reconcile-via-fresh-delta, idempotent
no-op (no mod-date churn), shared-convention title-casing, the §7 label-drift guard, and a data-fork
byte-equality assertion on every write. Also added a DEBUG **scratch-write guard** to `NotesTagProjector`
(see below). All green; existing `NotesTagProjectorTests` (9) unaffected.

- **LATENT — PROMOTED → Wave 15 (owner review 2026-07-18).** Now tracked as **W15.tu3** in `SUITE_TODO.md`
  §"Known-issues work — Wave 15" (a per-resolved-path serialization actor/lock inside `CoordinatedTagWriter`),
  bundled with the Processor's "lossless Finder-tag undo" item because both land on the same shared writer.
  **Cross-process writers stay explicitly out of scope** — an in-process lock cannot cover them. Still latent
  (not an active bug) until then; original analysis below.
- **LATENT (found by this suite; NOT fixed — shared cross-app choke-point) — two concurrent same-file
  metadata writes can lose a racing tag.** `ArchiveCore.CoordinatedTagWriter.write` coordinates via
  `NSFileCoordinator(.contentIndependentMetadataOnly)`, which does **not** mutually-exclude two
  concurrent metadata-only write *claims* on the same file. Two projections dispatched in parallel to the
  same `.md` (each adding a distinct subject) each read the pre-write state, and the later `setxattr`
  wins — so one subject is superseded (a lost update; verified deterministic-loss / nondeterministic-
  winner across runs). **File-safety guarantees that DO hold** and are pinned by the suite: no corruption
  / no torn array (each `setxattr` is atomic), the `ArchiveSuite` marker is never lost or duplicated, the
  file is never wiped, and bytes never change. **Why it's latent, not an active bug:** all three apps
  write one-writer-per-file — Reader/Processor batch tag edits across *different* files, Notes saves one
  note at a time, and the projector isn't yet wired to any concurrent path. It would only bite if a future
  design ran the projector on a background re-index *concurrently* with an interactive save of the **same**
  note. **Not fixed here** (S2 is the test suite; touching the shared audited writer's concurrency is a
  separate Tier-2 item — a per-path serialization actor/lock, and it wouldn't cover cross-process writers
  anyway). → flagged to Morning Review as a follow-up-if-it-becomes-real.
- **Added — DEBUG scratch-write guard on `NotesTagProjector` (belt-and-suspenders, plan §5).** Under a
  unit-test harness (`XCTestConfigurationFilePath` set) **or** the GUI-drive store override
  (`ANUITestStorePath` set), `project(…)` now `precondition`s that the write target is under a known
  scratch prefix (`NSTemporaryDirectory()` / `/tmp` / `/private/var/folders` / an `AN-GUI-Fixture` store)
  — mechanically aborting any test or GUI drive that ever aims a Finder-tag write at the real store or the
  corpus. **OFF in the real DEBUG app** (neither trigger present) and **compiled out of Release**, so
  ordinary tag writes to the real store are unaffected. The pure predicate `isScratchPath` is unit-tested
  directly; a companion test asserts the trigger env var is present so the guard is provably live (not
  dormant) during the suite.
- **Verify-fail path is tested at the projector boundary, not via fault injection.** Case 5 pins that a
  reported success equals an independent on-disk re-read and that a subsequent projection reconciles
  against a fresh read (preserving a concurrent third-party tag — never a blind full-array restore). The
  post-write multiset verify itself (throw-on-mismatch, never silent success) lives inside the shared
  `CoordinatedTagWriter`; a fault-injection seam was deliberately **not** added to that audited cross-app
  choke-point for a test.

## Front-matter codec — flow-list quote data-loss FIXED; two edge-normalizations pinned (W8-S1, 2026-07-14)

W8-S1's new `NotesFrontMatterTests` fuzz/property suite (seeded splitmix64: 2000 garbage blobs + 600
structurally-corrupt fronts + 400 well-formed `Item`s) exercised the YAML codec adversarially and found
one real bug plus two benign edge-normalizations:

- **FIXED — flow-list elements containing a quote char were data-lossy.** `emitFlowList` (tags/authors)
  emitted an element like `O'Brien` **unquoted**, and `parseFlowList` treats `'`/`"` as delimiters
  mid-stream → it dropped the apostrophe (`O'Brien` → `OBrien`) or merged elements across a stray `"`.
  Real bug (apostrophes in author names are common). **Fix:** `FrontMatterCodec.needsQuotingInFlow` now
  also quotes any element containing `"` or `'`; `quoteFlowElement` already double-quotes + escapes `\`/`"`,
  and `parseFlowList` treats a double-quoted element's inner quotes as literal. Round-trip proven for `'`,
  `"`, and `\`+`"` combos by the fuzz suite + the well-formed-`Item` loop; no regression across
  `FrontMatterCodecTests`/`ZoteroFrontMatterRoundTripTests`/`NoteStoreTests`/`NotesIndexTests`. Scalar
  values (e.g. `title`) were never affected (`unquoteScalar` only strips *both-end* quotes).
- **PINNED (characterization, not fixed) — leading/trailing non-U+0020 whitespace in a scalar is trimmed
  on read.** `decode` trims a scalar value with `.whitespaces` (which includes tab + category-Zs like
  NBSP), but `encode`'s `needsQuoting` only quotes a *leading/trailing regular space*, so a leading/
  trailing **tab** or **NBSP** on e.g. a title is normalized away (`"\tTabbed"` → `"Tabbed"`). Edge
  regular-spaces DO survive (they're quoted); interior whitespace is unaffected. Pinned by
  `leadingTrailingEdgeWhitespaceInScalarIsNormalized` so a future `needsQuoting` tightening is intentional.
  Marginal (who titles a note with an edge tab?) → flagged to Morning Review, not fixed this session.
- **NOTED (marginal) — `\r\r\n` in body text leaves a residual `\r\n` after one decode.** `decode`'s
  `replacingOccurrences("\r\n" → "\n")` is a single left-to-right pass, so `CR CR LF` collapses to a
  *residual* `\r\n` that then normalizes on a second decode → a body containing raw CR-soup isn't
  byte-idempotent. Real editors emit `\n` or clean `\r\n` (both handled correctly), so this is a
  fuzz-only artifact; the fuzz body generator excludes lone CR and the observation is logged, not fixed.

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
  windows' differing selections. GUI drive of a live paste is deferred to **W8-S8** (the scratch-store launch
  override now exists and is proven — **W8-S7** validated it: `SmokeUITest` LAUNCHES the app under XCUITest
  against the `-ANUITestStorePath` scratch fixture, in-memory-only, without touching the owner's real store).
- **GUI drive of load/autosave deferred (GUI paused).** The load-on-select + autosave-on-switch behavior
  is proven at the model layer (`NoteBodyEditorModelTests` incl. the cross-item race + generation guard;
  `NotesModelBodyTests` round-trip/reindex/front-matter-preservation), but not yet driven in a live window.
  When GUI resumes: select note A, type, select B → A's edit persists (assert the on-disk `.md`) and B
  loads fresh. The **force-quit-within-the-debounce caveat is now CLOSED (W7-S6):** app-terminate and
  window-close flush every open editor's pending edit before the process exits, via an app-level
  `EditorFlushRegistry` each pane registers into + the delegate's `applicationShouldTerminate`, which
  awaits the flush under a bounded timeout (`TerminateFlushCoordinator` — replies on flush-complete OR
  timeout, whichever first, so a wedged write never deadlocks quit). Proven at the model layer
  (`EditorFlushRegistryTests`: registry collection, bounded reply, and a scratch-store "edit within the
  debounce → on disk after flush" functional test). A live GUI confirm (type → ⌘Q at once → reopen →
  edit present) is still deferred with the rest of Notes' GUI drive until the scratch-store launch
  override lands (W8-S7) — driving the live app would write the owner's real store.

## Extracts create/copy-paste — follow-ups (W7-S2, 2026-07-13, open)

W7-S2 shipped the live Create-Extract (⌘⌥E) / Append-to-Extract… commands and the copy-in-Notes →
paste-into-Extract round-trip (`Extract` menu; `com.archivenotes.passage` on ⌘C in a note editor;
paste in an extract editor → note-passage blocks). Model + codec paths are unit-tested; conscious gaps:

- **Inline-image BYTES: copy + Create/Append + extract-paste all import them now (W7-S5 + W14.3, FIXED).**
  With W7-S5's `ItemAssetStore` wired into `NoteEditorPane`, the **copy** path
  (`copyPassageIfNote` → `EditorPassageSource(assetStore:)`) resolves + snapshots the passage's inline-image
  *bytes* (not just the `assets/<name>` refs) into the `com.archivenotes.passage` payload, and the
  Create/Append *commands* persist those bytes into the new extract's `assets/` (proven by `ExtractBuilder`
  create/append asset tests). **W14.3 closes the last gap** — the live extract-editor *paste* handler
  (`MarkdownEditorView.handlePassagePaste`) now copies the payload's bytes into the extract's own `assets/`
  too: a new `ExtractBuilder.pastedExtractMarkdown(from:importingAssetsVia:)` overload imports each segment's
  bytes via `ItemAssetStore.addAsset` (reserve→write, no-overwrite guard) and rewrites the `](assets/…)` refs
  when a name collision disambiguates, so a copy→paste into an extract is self-contained. Verified on scratch
  stores (`ExtractBuilderTests`: byte-on-disk, no-clobber disambiguation, nil-import resilience). **Residual
  (→ Morning Review, minor, not data loss):** (1) because `ItemAssetStore` writes bytes on a background task,
  the just-pasted images can render as missing-asset placeholders until the extract is reloaded (identical to
  the single-image paste path); (2) two selected blocks referencing the *same* source image import as two
  copies (consistent with the audited Create/Append `persist`); (3) the end-to-end **GUI copy→paste drive**
  still wants a live confirm.
- ✅ **FIXED (W14.4b, 2026-07-17):** Create-Extract (and Append-to-Extract) now auto-select + raise the
  extract in the Extracts window. `NotesModel.createExtract`/`appendToExtract` route the new/updated extract
  through `openItem(id:)` after re-index, so the Extracts window's pane consumes the `pendingOpen`, selects
  it, and (if open) raises itself (see the raise fix above). Note: a *closed* Extracts window is not
  auto-opened on create (deliberate — avoids an intrusive pop-up); the extract is still selected the next
  time that window opens. +2 model tests assert the open-request is published. **Live GUI drive → Morning
  Review.**
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
- ✅ **FIXED (W14.4b, 2026-07-17):** window is now programmatically RAISED. `NoteEditorPane.handleOpen`'s
  `.selectAndScroll` branch — which runs only in the window featuring the target's kind — calls
  `openWindow(id:)` (fronts the singleton Notes/Extracts `Window` scene, never duplicates) + `NSApp.activate`,
  so a jump-to-source brings the source note's window forward + focuses it. **Live raise/focus GUI drive →
  Morning Review.**
- ✅ **FIXED (W14.4c, 2026-07-17 `d615589`):** the chip live title now refreshes reactively. `NotesModel`
  gained an `itemsGeneration` counter (bumped on every `replaceItems`); `MarkdownEditorView.updateNSView`
  re-styles a chip-bearing extract when that generation changes even if THIS note's markdown didn't, so a
  rename in the *other* window recolors the chip while the extract sits idle. Gated to docs that carry a
  note-passage chip (plain notes never re-style on unrelated changes); scroll offset preserved across the
  refresh so a reader isn't yanked. **Live cross-window recolor GUI drive → Morning Review.**
- **Same-window active-editing edge.** If the jump target note is being actively edited *in the same
  window* (its text view is first responder), freeze-during-edit skips the content re-apply, so the
  scroll maps against possibly-stale content (falls back to top if out of range — non-crashing). The
  realistic jump is cross-window (Extract → Note window), where the target window isn't first responder,
  so content re-applies and the scroll is exact.
- **Folder-scope-hidden target.** A jump clears the window's *user* filters so the row is reachable, but
  a shared *folder scope* that excludes the note is left intact; the editor still loads + scrolls the
  note (detail reads `allItems`, not the filtered list), but the list-row highlight may be absent.
- ✅ **FIXED (W14.4a, 2026-07-17 `592049a`):** `Core/NotePassageSource.swift:118` "conditional cast from
  '[NSValue]' to '[NSValue]' always succeeds" — `textView.selectedRanges` is already `[NSValue]`, so the
  `as?` cast is redundant; bound directly (behavior-identical). Warning gone on a clean compile.

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
- ✅ **FIXED (W14.4d, 2026-07-17 `7ef833d`):** the "Sources" column is now per-window. `NotesAppSettings`
  gained `windowHiddenColumns(for:)`/`setWindowHiddenColumns(_:for:)` (keyed per window like
  `windowKindFilter`), defaulting the Note window to hide the always-blank Sources column while the Extracts
  window shows it; the header picker's toggle now persists per window. A first open seeds the default from the
  legacy global `hiddenColumns` (upgrade-safe); an explicit empty set means "show all". +4 settings tests.
  **Live two-window visibility GUI drive → Morning Review.**
- **`source_count` back-fills on re-index, not instantly, for a pre-`source_count` DB.** The additive
  `ALTER TABLE` defaults existing rows to 0; a stale row shows a blank Sources cell until its mtime
  changes (or the disposable index is deleted + rebuilt). Only affects a dev DB created before this
  change; a fresh index is correct from first build.

## Test harness — headless full-scheme run crashes — RESOLVED 2026-07-14 (W8-S6)

Running the **whole** `ArchiveNotes` unit scheme headless (`xcodebuild test …`, and therefore
`test-smoke.sh notes`) used to abort the shared Swift-Testing process with:

```
NSInvalidArgumentException: -[ArchiveNotes.BlockHeaderChipView performClick:]: unrecognized selector
```

- **Root cause:** `SourceBlockViewTests` → "reveal callback receives the anchor" (a W4-S7 display test)
  sent `performClick:` to the chip's **container view**. `BlockHeaderChipView` is an `NSView`, not an
  `NSControl`, so it doesn't respond to `performClick:`; the resulting `NSException` SIGABRT'd the whole
  Swift-Testing process, so the smoke gate was red headless even when every logic suite was green (this is
  why W4-S7 reported "**92 non-display** tests green").
- **Fix (W8-S6):** the test now invokes the Reveal **button's** target/action directly (and finally
  asserts the callback received the anchor); the vestigial `performClick:`-on-the-view line is gone.
  Verified headless: `xcodebuild test -only-testing:ArchiveNotesTests` →
  **TEST SUCCEEDED · 492 Swift-Testing tests in 59 suites + 187 XCTest · 0 failures · no abort**. The
  whole-scheme smoke gate (`test-smoke.sh notes`) is green headless again.

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
  summary. A bare `-only-testing:<Target>` runs everything — this is the headless smoke path (the
  `performClick:` abort that used to make it red is fixed; see the RESOLVED note above).
