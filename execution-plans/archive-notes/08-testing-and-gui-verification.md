# Archive Notes — W8: Testing & GUI verification
> Status: PROPOSED · part of Archive Notes (see 00-overview.md) · Wave 8

> ⚠️ **Canonical shared types & cross-wave APIs are defined in `00-overview.md` §16 (Interface Contract).** Where a sketch in this file differs — store type/name (`actor NoteStore` + `@MainActor NotesModel`/`OrganizationStore`), `DurableLink`/`RootMarker`, the single `NotesFilter` type, template-assignments-only, the index `items` projection, the `archivenotes://open?id=` grammar — **the overview is authoritative.**


## Goal
Deliver the full verification layer for Archive Notes: named **unit suites** covering every no-undo and correctness surface (front-matter round-trip, attributed↔Markdown bridge, `NotesTagProjector` safety, `NotesIndex`/FTS, virtual-folder + replication + delete-last-instance, durable links, date-sort parity, Zotero client), a per-app **`test-smoke.sh`** wired into the root dispatcher as `run_notes`, a deterministic **XCUITest + cliclick GUI harness** modeled byte-for-byte on the shipped Reader harness (Route-B read-write entitlement, per-row cell IDs, DEBUG fixture-root override, deterministic index-ready signal), a scripted **end-to-end scratch scenario** that proves durable links resolve, and a written **scratch-corpus safety protocol** so that no test — GUI or unit — ever touches the owner's real corpus or a real bookmark. All tag writes exercised anywhere in this wave route through the audited `NotesTagProjector` (00-overview §9) against `mktemp` copies only (00-overview §12).

## Dependencies
W8 lands **last** and depends on **W1–W7** (00-overview §13): the ArchiveNotes scaffold + `ArchiveNotes`/`ArchiveNotesTests` targets and `ArchiveCore` package (W1); the store, `NotesFrontMatter` I/O, `NotesTagProjector`, `NotesIndex`, folder/replication model + `organization.json` writer (W2); the attributed↔Markdown bridge + block rendering (W3); the Reader URL scheme, `revealAndSelect`, Copy-Archive-Link pasteboard payload, `archivenotes://` router, durable-link resolver (W4); the Zotero client (W5); the 3-pane viewers, search/sort/replication UI, delete-last-instance guard, date/quality controls (W6); and Create-Extract + jump-to-source (W7). Practically, many of these suites should be **seeded during their own wave** (each wave is Tier-gated and requires unit tests); W8's job is to **guarantee coverage exists, add the adversarial/fuzz/property tests that a feature wave would skip, wire the smoke gate, and build the GUI harness** that can only be built once all surfaces exist. The GUI harness sub-tasks (S7–S9) specifically require the shipped 3-pane windows (W6) and cross-app linking (W4).

## Design

### 0. Test-target layout (project.yml — MODIFIED in W1, extended here)
`ArchiveNotes/macOS/project.yml` is authoritative (00-overview §12; mirror of `ArchiveReader/macOS/project.yml` L1–75). By W8 it has:
- `ArchiveNotes` (app, `com.archivenotes.app`, sandbox + `files.user-selected.read-write` + `files.bookmarks.app-scope` + `network.client` per D10).
- `ArchiveNotesTests` (`bundle.unit-test`, `com.archivenotes.tests`) — the unit suites below.
- **NEW (S7): `ArchiveNotesUITests`** (`bundle.ui-testing`, `com.archivenotes.uitests`, `TEST_TARGET_NAME: ArchiveNotes`) — the XCUITest target, exactly as the Reader plan specifies (`reader-gui-test-harness.md` §Sub-task 1, L69–94).
- `ArchiveCore` package has its **own** SwiftPM test target `ArchiveCoreTests` (the read-side parser/`sortDate`/`RootMarker`/durable-link tests that seed from Reader's `DocumentTagsTests`, 00-overview §10). Pure-model suites that live in `ArchiveCore` (front-matter parser if it lands there, `sortDate` parity, durable-link codec) run under `swift test` in the package **and** are surfaced through the app scheme.

Scheme `ArchiveNotes` test action lists `ArchiveNotesTests` **and** `ArchiveNotesUITests` (mirror `ArchiveReader` scheme, `project.yml` L67–75). `xcodegen generate` after every project.yml edit (the `.xcodeproj` is gitignored — CLAUDE.md).

Invocation (per-worktree DerivedData, like the whole repo):
```bash
xcodegen generate
xcodebuild test -scheme ArchiveNotes -destination 'platform=macOS' -derivedDataPath ./build/DD \
  -only-testing:ArchiveNotesTests            # unit only (the free smoke gate)
xcodebuild test -scheme ArchiveNotes -destination 'platform=macOS' -derivedDataPath ./build/DD \
  -only-testing:ArchiveNotesUITests          # GUI harness (needs the fixture + Accessibility perm)
```

### 1. UNIT suites (named)

All temp-file suites follow the **proven Reader pattern** (`TagWriterTests.swift` L8–33): a per-test `tempDir = NSTemporaryDirectory()/ArchiveNotesTests-<UUID>`, created in `setUpWithError`, `rm`'d in `tearDownWithError`; helper `makeFile(_:tags:bytes:)` writing bytes then `(url as NSURL).setResourceValue(_, forKey: .tagNamesKey)`. **Never** the corpus.

#### 1.1 `NotesFrontMatterTests` (pure; ArchiveCore or app) — Tier-1
Target: the YAML front-matter reader/writer (00-overview §5).
- `testRoundTripPreservesAllKnownKeys` — build an `Item` with every §5 field populated (`schema,id,kind,title,authors,date,date_precision,date_uncertain,quality,tags,roundup,zotero[…],created,modified`), serialize → parse → assert struct-equal.
- `testUnknownKeysPreservedVerbatim` — inject a front-matter file with keys the current schema does not know (`foo_future: bar`, a nested `experimental: {a: 1}`); parse → re-serialize → assert the unknown keys survive **byte-for-byte in place** (00-overview §5 "unknown keys preserved on round-trip (never dropped)"). Implementation implication: the front-matter model must keep an `unknownKeys: [String: YAMLNode]` bag, not a fixed `Codable` struct that silently drops extras.
- `testMissingOptionalFieldsDefaultGracefully` — a minimal front-matter (`id,kind,title` only) parses with sane defaults (`quality=nil`, `tags=[]`, `roundup=false`).
- `testBlockHeaderRoundTrip` — parse the §6 grammar (`<!-- block: <kind> … -->`) for each kind (`freeform,reader-page,reader-doc,zotero-item,zotero-attachment,note-passage`), assert unrecognized header fields preserved verbatim, and **a body region with no header degrades to a single `freeform` block** (00-overview §6 graceful-degradation rule).
- `testFuzzFrontMatterNeverCrashesAndNeverInvents` — a **fuzz** loop: generate N=2000 pseudo-random byte blobs (seeded RNG for determinism) + N structured-but-corrupt YAML fronts (truncated `---`, tabs-in-yaml, duplicate keys, CRLF, BOM, 10 000-char title, emoji, control chars). Assert: parser never throws an uncaught error / never crashes; either returns a best-effort `Item` **or** a typed `.malformed` error; and on any file it *does* accept, a subsequent write→re-read is idempotent (no invented keys, no dropped unknowns).
- `testTitleFilenameSyncInvariant` — `title` mirrors `<Title>.md` filename (D1); renaming the title updates the filename target and vice-versa; assert no collision path writes over an existing sibling.

#### 1.2 `MarkdownBridgeTests` (pure) — Tier-1
Target: the attributed↔Markdown bridge for the WYSIWYG editor (D6, W3). Scope the **supported subset** explicitly (bold, italic, headings, bullet/numbered lists, blockquote, inline code, links, inline image `![](assets/…)`, the block HTML-comment headers passed through untouched).
- `testAttributedToMarkdownToAttributedIdempotentForSupportedSubset` — for a table of representative `NSAttributedString` fixtures over the supported subset: `attributed → md → attributed'` and assert the *rendered* attributes are equal (idempotency), and `md → attributed → md'` with `md == md'` for canonical Markdown inputs.
- `testUnsupportedAttributesDegradeLosslesslyInMarkdown` — an attributed run carrying an unsupported attribute (e.g. a font-family) round-trips its **text + supported** attributes without corrupting the Markdown; unsupported styling is dropped predictably, never mangling adjacent text.
- `testBlockCommentHeadersSurviveBridge` — the `<!-- block: … -->` headers and the `![alt](assets/…)` thumbnail line (00-overview §5 example, L196–200) are **passed through verbatim** by the bridge (they are structure, not prose) so editing prose in a sourced block never rewrites the provenance header.
- `testImagePasteProducesRelativeAssetReference` — pasted image → a `![](assets/pasted-…png)` reference with a **relative** path (never absolute), matching the on-disk layout (00-overview §4).

#### 1.3 `NotesTagProjectorSafetyTests` (mktemp scratch files; **Tier-2**) — the crown jewel
Target: `NotesTagProjector` (00-overview §9), which projects `tags` (title-cased subjects) **+** `ArchiveSuite` onto the item's own `.md`, obeying every `TagWriter` invariant. Model directly on `TagWriterTests.swift` (L8–70 helpers + assertions). Every case runs on a `mktemp` `.md` with pre-seeded Finder tags; **assert file bytes unchanged** after every write (data-fork equality, `TagWriterTests` L48–50 pattern).
- `testAttemptedTagWipeOnUnreadableFileAborts` — create the file, then make the tag read fail (e.g. delete the file after opening / point at a path whose `resourceValues(forKeys:[.tagNamesKey])` throws or returns `nil`). Drive `project(subjects:on:)`. **Assert it throws / returns `.aborted` and writes nothing** — never coerces the failed read to `[]` (00-overview §9 invariant 2; the anti-tag-wipe rule).
- `testConcurrentWriteNoLoss` — two projections to the **same** file dispatched concurrently (`async let` / `withThrowingTaskGroup`), each adding a distinct subject. Assert the final tag multiset contains **both** subjects + `ArchiveSuite` and lost nothing (invariant 3; verifies the `NSFileCoordinator(.contentIndependentMetadataOnly)` serialization actually serializes).
- `testPreExistingUnrelatedTagPreservedLossless` — seed the file with a tag the projector does **not** manage (e.g. a hand-applied `"Do Not Sync"` Finder tag). Project a subject set. Assert `"Do Not Sync"` survives verbatim (invariant 5: only ever touches tokens it manages + `ArchiveSuite`).
- `testSubjectLiterallyArchiveSuiteCollision` — a note whose **subject** is literally `"ArchiveSuite"`. Assert: (a) the projected array contains exactly **one** `ArchiveSuite` token (no duplicate); (b) whole-string exact matching means a *different* note removing its `ArchiveSuite` membership marker still leaves a note that legitimately carries `ArchiveSuite` as a subject intact within its own front-matter; (c) removing the subject `ArchiveSuite` from front-matter does **not** strip the mandatory marker (the marker is added independently). This pins the one genuinely ambiguous token.
- `testVerifyByReReadFailurePathReconciles` — inject a verify mismatch (a test seam: a stubbed re-read that returns a wrong multiset once). Assert the projector detects the mismatch, **re-reads fresh and recomputes the delta** (never a blind full-array restore — invariant 4 + Reader Safety-Protocol §9), and surfaces failure rather than silently reporting success.
- `testNoOpDeltaWritesNothing` — projecting the identical subject set twice: the second call detects a no-op and writes nothing (no mod-date churn); assert mtime unchanged.
- `testTitleCasingMatchesSharedConvention` — subjects are title-cased per the shared convention before projection (00-overview §5), and `ArchiveSuite` is emitted with its canonical casing.

**File-safety note:** this suite is the one place W8 exercises a real Finder-tag write. Every file is a `mktemp` throwaway; the suite never resolves or writes a security-scoped bookmark; `lint-write-surface.sh` (§4) must confirm the projector is the *only* new tag-write spelling.

#### 1.4 `NotesIndexTests` (mktemp sqlite; Tier-2 for the org-graph writer) — 
Target: `NotesIndex` (FTS5, forked from Reader's `ContentIndex`, 00-overview §11) + the organizational-graph tables. Model on `ContentIndexTests.swift` (L6–45): `makeIndex()` → temp `.sqlite3`, `defer` remove, `open()`/`close()`.
- `testUpsertAndSearch` — insert notes; assert term search returns the right ids (parity with `ContentIndexTests.testUpsertAndSearch` L15).
- `testIncrementalNeedsIndexByMtime` — `needsIndex(id:mtime:)` true when new/changed, false when unchanged (parity with `testNeedsIndexIncremental` L33).
- `testReindexReplacesOldBody` — re-upsert replaces stale body (parity L44).
- `testPruneGatedRemovesOnlyMissingItems` — prune only evicts rows for items no longer on disk / outside the store scope; **gated** (settled + non-empty + boundary scope) so a mid-build empty snapshot never wipes the index (Reader's `pruneIfSettled` posture, CLAUDE.md Search §).
- `testBM25OrderingWeights` — insert notes so a **title** hit, a **tags** hit, an **authors** hit, a **body** hit and a **linked-doc-display** hit compete; assert the returned order matches the Notes column weights (title=10 · tags=6 · authors=4 · body=1 · linked-doc-display=3, 00-overview §11), i.e. a title/tag hit outranks a body-only hit.
- `testFTSQuerySanitizerRejectsInjection` — feed FTS5-hostile query strings (unbalanced quotes, `NEAR/`, `*` prefixes, `MATCH`-breaking punctuation, a bare `"`); assert the sanitizer produces a safe query that either matches literally or returns empty — **never throws a SQLite error** and never crashes (Reader ships this sanitizer; port its tests).
- `testOrganizationGraphPersistAndReload` — insert folders + membership rows + template assignments; close; reopen; assert the graph reloads (these tables are **app-owned durable data**, not disposable, 00-overview §3/§11).
- `testOrganizationJSONExportRoundTrip` — after a graph mutation, assert `organization.json` (00-overview §4) is atomically written and parses back to the same folder/membership/template graph (survives a DB wipe → rebuild).

#### 1.5 `VirtualFolderReplicationTests` (pure model, no files) — Tier-2 (delete path)
Target: the folder/replication model (00-overview §3.6) — a pure `OrganizationGraph` value type operating on `{Folder}`, `{Membership(itemId,folderId,addedAt)}`, decoupled from disk so the **delete-last-instance guard is unit-testable without touching files**.
- `testReplicateAddsMembershipRowNotACopy` — replicating item I into folder F adds one membership row; the item still has its single underlying folder on disk (DevonThink replicant semantics).
- `testItemInKFoldersHasKMemberships` — count invariant.
- `testRemoveMembershipRemovesReplicantOnly` — removing one of K≥2 memberships leaves the item present in K−1 folders and does **not** signal deletion.
- `testRemoveLastMembershipSignalsDeleteGuard` — removing the **sole remaining** membership returns a `.wouldDeleteItem(itemId)` decision (the pure guard), which the UI (W6) turns into the mandatory "sole remaining instance — this will delete the note itself" confirmation **before** any file delete (00-overview §3.6/§9). Assert the guard fires exactly on the last membership, never earlier.
- `testMoveFolderPreservesMembershipGraph` — reparenting a folder (`parentId`) keeps every membership intact.
- `testSmartFolderScopeIsQueryNotMembership` — a `smart` folder stores a saved query and yields items by query, holding **zero** membership rows (00-overview §3.6; mirrors Reader smart-folder-as-scope).
- `testCycleGuardOnReparent` — reparenting a folder under its own descendant is rejected (no cycles in the tree).

#### 1.6 `DurableLinkTests` (ArchiveCore, pure + one mktemp for root marker) — Tier-2
Target: `RootMarker` + the URL codec/resolver (00-overview §8, D5). 
- `testReaderRevealLinkEncodeDecode` — `archivereader://reveal?root=<GUID>&rel=<pct-encoded>&page=<int>` round-trips; `rel` percent-encoding survives spaces, the em-dash (U+2014) and NBSP (U+00A0) that the corpus filenames contain (Reader Verified-Facts), `/` in the rel path preserved, `page` optional.
- `testNotesOpenLinkEncodeDecode` — `archivenotes://open?id=<UUID>` (+ optional `#block-<n>`) round-trips.
- `testRootMarkerIdempotentNeverOverwrites` — dropping `.archive-suite-root.json` on a scratch dir writes `{guid,name,kind}` once; a second call **never overwrites an existing guid** (00-overview §8.1) — assert the guid is stable across calls.
- `testResolveSameMachine` — with a registered root GUID → currently-granted root URL, resolve `rel` under it, verify existence (scratch dir).
- `testResolveNewMachineAfterRegrant` — GUID present in `.archive-suite-root.json` matches the stored one after a simulated re-grant → resolves; **unknown GUID → returns `.needsRootGrant` (guided re-grant), never a silent failure** (00-overview §8.3).
- `testFallbackOrder` — resolution order: exact `rel` → same basename elsewhere under root (offer) → `.notFound`; assert it **never returns a path outside the granted scope** (§8.3 last line).

#### 1.7 `DateSortParityTests` (ArchiveCore, pure) — Tier-1
Target: `date`/`date_precision`/`date_uncertain` → sort key **must equal** the SPEC/Reader `sortDate` (00-overview §7). Seed from Reader's `DocumentTagsTests`.
- `testSortDateMatchesSPECFormula` — for a table of (`date`,`precision`) pairs, `notesSortKey == year*10000 + month*100 + day`, decade → decade-start (`1970` decade → `19_700_000`, same as year-only `1970`, per SPEC + CLAUDE Verified-Facts).
- `testUncertainStillSortsByDate` — `date_uncertain: true` sorts by its date (rendered italic in UI), **never dumped to the end** (00-overview §7; Reader parity).
- `testMedievalAndThreeDigitYear` — 3-digit year (`842`) sorts correctly (medieval-friendly, matches Reader `parseYear`).
- `testReuseNotReimplemented` — a compile-time/assert check that the Notes sort key calls the **shared** `sortDate` from ArchiveCore (00-overview §10), not a re-implementation (guard against the silent-divergence risk the SPEC warns about).

#### 1.8 `ZoteroClientTests` (stubbed local HTTP server) — Tier-1
Target: the Zotero local-API / Better-BibTeX client (D8, W5) — **read-only**, degrades gracefully when Zotero isn't running.
- Harness: a tiny in-test HTTP server (`NWListener` / a minimal `URLProtocol` stub or a localhost `URLSession` mock) bound to `127.0.0.1:<ephemeral>`, injected via the client's base-URL seam (must be injectable, not hard-coded to the Zotero default port). No third-party dependency (Constraint).
- `testFetchItemMetadataParsesAuthorDateTitleCitation` — stub returns a Zotero item JSON; assert `authors/date/title` auto-fill + formatted `citation` (00-overview §3.4/§5 example L186–191).
- `testAttachmentSelectLinkParsed` — `zotero://select/…` for an **attachment** (not just item) parses to `{itemKey,library,kind:attachment}` (D8: item **and** attachment).
- `testMultipleZoteroRefsOnOneNote` — a note with ≥2 Zotero refs (owner: "multiple Zotero items") round-trips.
- `testDegradesGracefullyWhenServerDown` — point the client at a closed port → assert it returns `.unavailable` (chip still shows the stored `selectLink`, no metadata), **never blocks the UI, never throws to the caller** (D8 degrade-gracefully).
- `testTimeoutBounded` — a stub that hangs → the client times out within a bounded interval (no indefinite hang on the localhost fetch).

**Concurrency/Swift-6 notes (all suites):** `NotesIndex`/`ZoteroClient` are `actor`s (Reader's `ContentIndex` is actor-confined `import SQLite3`); their tests are `async`. `NotesTagProjector` is a value/`enum`-namespaced type like `TagWriter` (static funcs) — tests call it directly. UI-model tests (`ArchiveLibraryOverrideTests` is `@MainActor`, L15) mark `@MainActor` where they touch a `@MainActor` view model. All fixtures/`Item` structs are `Sendable` (immutable value types). Fuzz RNG uses a seeded `SystemRandomNumberGenerator` replacement (a small deterministic LCG) so failures reproduce.

### 2. Smoke gate

**NEW: `ArchiveNotes/test-smoke.sh`** — copy `ArchiveReader/test-smoke.sh` verbatim (it is 39 lines, already generic) and change only the scheme/labels: `-scheme ArchiveNotes`, `PROJ="$ROOT/macOS"` (Notes' XcodeGen dir is `macOS/`, 00-overview §"Repo map"), log prefix `smoke-notes-`, PASS/FAIL label `(notes)`. It runs `xcodegen generate` then `xcodebuild test -scheme ArchiveNotes -destination 'platform=macOS' -derivedDataPath ./build/DD -only-testing:ArchiveNotesTests` (unit-only so the gate stays **free** — no OCR, no network, no corpus; the GUI target is opt-in, not in the free gate). It parses `Executed N tests` and greps `TEST SUCCEEDED` exactly as the Reader script (L27–39).

**MODIFIED: root `test-smoke.sh`** — add a third runner mirroring L15–16 and extend the dispatcher (L18–28):
```bash
run_notes(){ echo "──────── Archive Notes ─────────"; bash "./ArchiveNotes/test-smoke.sh"; }
```
- Add cases `notes|n|ArchiveNotes) run_notes ;;`.
- In `all)`: run `run_notes` after `run_reader` (both free/cheap) and before `run_processor` (the only one that costs cents), folding its rc into the aggregate `rc` (L23–26). Update the usage text (L30–35).

### 3. GUI harness (mirror `reader-gui-test-harness.md` exactly)

The Reader harness plan already resolved every hard problem and shipped with the adversarial review applied (its blockquote L6–20). W8 **ports that same architecture**, not a new design. The Notes-specific pieces:

#### 3.1 DEBUG fixture-root override — `NotesStoreLocator` (NEW seam) — reviewed as Tier-2
Notes chooses its store via a security-scoped bookmark (like Reader's `RootFolderStore`, `RootFolderStore.swift` L13/L18/L41). Add the **same** `#if DEBUG` + launch-arg override the Reader plan specifies (`reader-gui-test-harness.md` §Sub-task 3, L184–198):
```swift
init() {
#if DEBUG
    if let p = UserDefaults.standard.string(forKey: "ANUITestStorePath"), !p.isEmpty {
        adoptTestStore(URL(fileURLWithPath: p, isDirectory: true))   // sets `storeURL` only
        return                                                        // SKIP resolveSaved() entirely
    }
#endif
    resolveSaved()
}
```
`adoptTestStore` sets `storeURL = url`, **does not** call `bookmarkData`, **does not** `UserDefaults.set(_,forKey:key)`, **does not** `startAccessingSecurityScopedResource()`. Compiled out of Release. The launch arg is passed as a **two-element array** `["-ANUITestStorePath", path]` (the harness review's fix for the space in "Archive Suite"/"Application Support", L18). A unit test (`NotesStoreLocatorOverrideTests`, mirroring Reader's `ArchiveLibraryOverrideTests`) asserts that after `adoptTestStore` **no `notesStoreBookmark` is written to UserDefaults** and a normal launch still resolves the real bookmark (`reader-gui-test-harness.md` §Sub-task 3 L216–218).

#### 3.2 Route-B **read-write** entitlement
Per the Reader review's #1 required change (L8): the GUI fixture writes a Finder tag through `NotesTagProjector`, so a read-only temporary-exception entitlement would silently no-op. Use a **separate `ArchiveNotes.uitest.entitlements`** applied only to a UITest build configuration, adding `com.apple.security.temporary-exception.files.absolute-path.read-write` for the fixture path under `~/Library/Application Support/ArchiveNotes/AN-GUI-Fixture` (the Spotlight-proven Application-Support location, matching `smoke-setup.sh` L10 and the review's Route-B choice L9). Production `ArchiveNotes.entitlements` stays **byte-identical**. Notes discovers its own items from `items/**/*.md` on disk (not Spotlight — unlike Reader), so the container-Spotlight risk that forced the Reader's Route-A/B debate largely **does not apply**; the fixture just needs read-write file access, which Route-B's temporary-exception grants. (Confirm in S7: a sandboxed Notes build with the UITest entitlement can read+`NotesTagProjector`-write the fixture `.md` files.)

#### 3.3 accessibilityIdentifiers (convention `an.<area>.<control>`)
Add identifiers to the key surfaces (SwiftUI `.accessibilityIdentifier`; AppKit-wrapped controls need `nsView.setAccessibilityIdentifier(_:)` inside `makeNSView`/`updateNSView` — the Reader wrinkle, `reader-gui-test-harness.md` §Sub-task 2 L106–108). Surfaces (files land in W3/W6/W7):
- **Sidebar / folder tree:** `an.sidebar.folder` (+ label = folder name), `an.sidebar.smart`, `an.sidebar.newFolder`.
- **Item list:** container `an.list`; per-row cells encode the **stable item UUID** into the accessibility identity on **every bind** (the Reader review's per-row fix, L12 — cells are virtualized/reused, so a single shared id can't target a row): `an.row.<uuid>` and `an.row.<uuid>.title`, `.date`, `.quality`, `.tags`. Locate a row via its UUID cell, then descend.
- **Editor:** `an.editor.text` (the NSTextView), `an.editor.rawToggle`, `an.editor.toolbar.{bold,italic,heading,bullet,link,image}`.
- **Source block:** `an.block.<n>.source` (the provenance chip), `an.block.<n>.reveal` (reveal-in-Reader button), `an.block.<n>.zoteroChip`.
- **Extract:** `an.extract.create` (Create-Extract command target), `an.extract.jumpToSource`.
- **Replication / delete:** `an.menu.replicateInto`, `an.dialog.deleteLastInstance` (the mandatory confirmation), `an.dialog.deleteLastInstance.confirm/cancel`.
- **Search/sort:** `an.filter.query`, `an.filter.kind`, `an.filter.tag`, `an.sort.date`.
Give the editor `NSTextView` and any inline token field a **DEBUG test-only command** fallback (`reader-gui-test-harness.md` L13) — driving an inline `NSTextView`/token field through XCUITest is a known weak spot; expose a documented `#if DEBUG` accessibility action so a test can commit text without relying on field-editor focus.

#### 3.4 Deterministic index-ready signal
Notes' `NotesIndex` builds in the background (00-overview §11). Expose an **index-complete signal** to await before any search/relevance assertion (the Reader review's fix for flaky FTS tests, L16): a `@MainActor` published `indexGeneration`/`isIndexReady` on the view model, surfaced to XCUITest via a hidden `an.status.indexReady` element whose `accessibilityValue` flips to the generation token once the initial build of the fixture completes. Tests poll it (generous timeout) instead of racing. Similarly, poll **async tag writes** before asserting `tag -l` (the review's L14 fix): after driving a subject edit that calls `NotesTagProjector`, poll `tag -l <fixture.md>` (or the row value) with a timeout before asserting, and again after Undo.

#### 3.5 Fixture builder — **NEW `ArchiveNotes/scripts/make-notes-fixture.sh`**
Model on `smoke-setup.sh` (L1–31): `set -euo pipefail`, `rm -rf` + rebuild (idempotent), emit the fixture path on stdout for `-ANUITestStorePath`. It builds a **small notes store** into `~/Library/Application Support/ArchiveNotes/AN-GUI-Fixture`:
- A curated **scratch Reader corpus copy**: `ditto` ~8–10 PDFs from `ArchiveProcessor/Test Files` (00-overview grounds the corpus under ArchiveProcessor) into `AN-GUI-Fixture/reader-corpus/`, drop a `.archive-suite-root.json` with a **known GUID** so durable links resolve deterministically. (`ditto` preserves the tag xattr, `smoke-setup.sh` L18.)
- A handful of **note `.md` files** under `AN-GUI-Fixture/items/<uuid>/`: one plain note, one with a `reader-page` source block whose `link` points at the scratch corpus GUID+rel+page, one with a Zotero chip (`selectLink` only, no live server needed), one extract with a `note-passage` block, plus a pre-seeded `organization.json` with two folders and one **replicated** item (so the delete-last-instance path is reachable).
- Applies the initial Finder-tag projection to the fixture `.md`s via `/opt/homebrew/bin/tag` (present, verified) so the projector's *starting* state is known — the same "git can't store xattrs, apply them in the builder" reasoning as the Reader fixture (`reader-gui-test-harness.md` §Sub-task 4 L230).
- `mdimport`/poll is **not** required for Notes discovery (Notes reads files, not Spotlight) but is kept for the embedded scratch **Reader** corpus so a real Reader launch during the reveal test can find the rows (mirror `smoke-setup.sh` L22–29).

#### 3.6 cliclick helper — **NEW `ArchiveNotes/scripts/gui-drive-notes.sh`**
Copy `scripts/gui-drive.sh` (it is a sourced library, L1–203) and adapt: `READER_APP_NAME` → `NOTES_APP_NAME="Archive Notes"`, keep every primitive (`gui_click/double_click/right_click/drag` via cliclick L102–110; `gui_type/gui_key/gui_menu` via osascript System Events L139–179; `gui_capture_window` L185; `gui_tags`/`gui_assert_tag` read-only via `tag -l` L193–199). Keep the same **safety banner** (L25–31): all GUI checks run against the **scratch fixture only**; the helper only *reads* tags to assert; all tag **writes** go through the app's `NotesTagProjector`. Retune table geometry constants (`GUI_ROW_HEIGHT`/`GUI_TABLE_ORIGIN_X/Y`, L45–47) for the Notes list. cliclick is confirmed installed (`/opt/homebrew/bin/cliclick`). **Permissions caveat carried over** (L18–23): the controlling process needs macOS Accessibility permission or clicks silently no-op — document this in the harness README so an unattended run doesn't falsely pass.

#### 3.7 Per-wave GUI checks (drivability marked)
| # | Check (wave) | Driver | Assertion |
|---|---|---|---|
| G1 | Create a note (W6) | XCUITest (menu/⌘N) | new `an.row.<uuid>` appears; `<uuid>/<Title>.md` exists on disk |
| G2 | Type rich text (W3) | **owner-eye** + DEBUG-command fallback (XCUITest can't reliably focus the NSTextView) | bold/italic render; saved `.md` shows correct Markdown |
| G3 | Toggle raw Markdown (W3) | XCUITest (`an.editor.rawToggle`) | raw view shows the `.md` source incl. block headers; toggling back is lossless |
| G4 | Paste image (W3) | cliclick (put PNG on pasteboard, ⌘V) + poll | `assets/pasted-…png` written; `![](assets/…)` reference appears |
| G5 | Paste-from-Reader → source block (W4) | XCUITest (seed the custom-UTI JSON payload on `NSPasteboard`, then ⌘V) | a `reader-page`/`reader-doc` block is created with `link`+`display`+cached thumb (00-overview §8.4) |
| G6 | Click reveal → Reader selects the row (W4) | cliclick (`an.block.<n>.reveal`) + launch scratch Reader | Reader front window shows the target row selected (assert via `gui-drive.sh gui_capture_window` + the Reader's own `ar.table` selection; **owner-eye** confirm on first run, then XCUITest cross-process where feasible) |
| G7 | Replicate into a folder (W6) | XCUITest (`an.menu.replicateInto`) | item appears under the second `an.sidebar.folder`; membership count = 2; disk still one `<uuid>/` folder |
| G8 | Delete-last-instance warning (W6) | XCUITest | removing the sole remaining membership shows `an.dialog.deleteLastInstance`; **Cancel leaves the file on disk** (assert `<uuid>/` still exists) |
| G9 | Create extract from selection (W7) | XCUITest (`an.extract.create`) + DEBUG-command to set the selection | a `kind: extract` item with a `note-passage` block linking the source note is written |
| G10 | Jump-to-source (W7) | cliclick (`an.extract.jumpToSource`) | the source note opens/selects at the linked passage |
| G11 | Zotero chip opens (W5) | cliclick (`an.block.<n>.zoteroChip`) | the `zotero://select/…` URL is dispatched (assert via a `NSWorkspace.open` spy in DEBUG, since Zotero may not be installed on CI — **owner-eye** for the real Zotero round-trip) |

"cliclick-drivable" = pointer/keystroke/menu (per `gui-drive.sh`'s rationale L14–16); "XCUITest" = structured/assertable via identifiers; "owner-eye" = requires human confirmation (rich-text rendering fidelity, cross-app reveal, real Zotero) and is flagged as such in the harness README so an unattended run does not claim to have verified them.

### 4. End-to-end scratch scenario — **NEW `ArchiveNotes/scripts/e2e-durable-links.sh`**
A scripted, assertable run (no GUI required; can run in the free gate as an integration test or standalone):
1. `make-notes-fixture.sh` → build the notes store + embedded scratch Reader corpus with a **known root GUID**.
2. Launch a DEBUG Notes build headless-ish with `-ANUITestStorePath <fixture>` (or exercise the resolver directly in an integration XCTest that points at the fixture dir).
3. **Assert every durable link in every fixture note resolves**: for each `reader-page`/`reader-doc` block, run the resolver (00-overview §8.3) and assert it returns an existing path **under the granted scratch root** (never outside it).
4. Simulate a **computer move**: copy the whole `AN-GUI-Fixture/` to a second scratch dir with a *different* absolute path (new username/volume simulation), re-register the root GUID (one-time re-grant), and assert links still resolve by GUID (00-overview §8.3 new-machine path).
5. Negative: mangle one block's `rel` to a missing basename → assert the resolver returns the **fallback** (`.notFound` / same-basename offer), never a raw out-of-scope open.
6. Teardown `rm -rf` both scratch dirs. Emit PASS/FAIL. This is the single test that proves the D5 durable-provenance promise end-to-end.

### 5. Scratch-corpus SAFETY protocol — **NEW `ArchiveNotes/GUI_SAFETY.md`** + a runtime guard
- Document (in `GUI_SAFETY.md`, cross-referenced from `SMOKE_TEST.md`) the protocol: **copy a subset of `ArchiveProcessor/Test Files` to `mktemp`/Application-Support scratch before any tag-write GUI check**; **confirm the granted root is the scratch dir before ANY tag write**; the harness only *reads* tags to assert (`gui-drive.sh` L25–31, L191–199). Record the memory **`archive-test-run-safety`** rationale (00-overview §12).
- **Runtime guard (belt-and-suspenders):** in the fixture builder and in `NotesTagProjector`'s DEBUG path, assert the write target's path is **under a known scratch prefix** (`AN-GUI-Fixture`/`NSTemporaryDirectory()`) — a DEBUG `precondition` that aborts if a test/GUI-drive ever aims a projector write outside scratch. This is the same "never the real corpus" invariant Reader enforces, made mechanical.
- The GUI drive script's picker note (`gui-drive.sh` L26–29): driving "Choose Store Folder…" would clobber the real `notesStoreBookmark` — so the harness **never** drives the picker; it uses the `-ANUITestStorePath` volatile override (§3.1) which never persists a bookmark.

## Reuse from the existing codebase
- `ArchiveReader/test-smoke.sh` (whole file, L1–39) — copy verbatim; retune scheme/paths/labels for the NEW `ArchiveNotes/test-smoke.sh` (§2).
- `test-smoke.sh` (root) L15–16 (`run_reader`/`run_processor`), L18–28 (case dispatch), L23–26 (`all` aggregate rc) — MODIFY to add `run_notes` + `notes` case (§2).
- `execution-plans/reader-gui-test-harness.md` — the entire harness design: XCUITest target project.yml (L69–94), `an.<area>.<control>` identifier convention + AppKit `setAccessibilityIdentifier` wrinkle (L104–108), the DEBUG volatile launch-arg override that never writes the bookmark (L184–218), the two-element `launchArguments` fix (L18), per-row cell identity (L12), poll-async-writes (L14), Route-B **read-write** entitlement (L8), deterministic index-ready signal (L16), class-level fixture build (L17). Adapt names Reader→Notes.
- `scripts/gui-drive.sh` (L1–203) — copy to NEW `ArchiveNotes/scripts/gui-drive-notes.sh`; reuse every cliclick/osascript/capture/tag-read primitive; keep the safety banner (L25–31) and permissions note (L18–23).
- `ArchiveReader/scripts/smoke-setup.sh` (L1–31) — the `ditto`-copy + `mdimport` + poll-until-indexed idempotent scratch-corpus pattern; basis for NEW `make-notes-fixture.sh` (§3.5).
- `ArchiveReader/macOS/Tests/ArchiveReaderTests/TagWriterTests.swift` (L8–70) — temp-dir setUp/tearDown, `makeFile(_:tags:bytes:)`, `readTags`/`readLabel`, byte-unchanged assertion (L48–50), inverse-delta undo pattern (L63–68) → the template for `NotesTagProjectorSafetyTests` (§1.3).
- `ArchiveReader/macOS/Tests/ArchiveReaderTests/ContentIndexTests.swift` (L6–45) — `makeIndex()` temp-sqlite + `defer` remove + `open/close`, upsert/search/`needsIndex`/reindex assertions → the template for `NotesIndexTests` (§1.4).
- `ArchiveReader/macOS/Tests/ArchiveReaderTests/ArchiveLibraryOverrideTests.swift` (L15–60) — `@MainActor` pure-logic test style + the "override never touches the real bookmark" posture → the template for `NotesStoreLocatorOverrideTests` (§3.1).
- `ArchiveReader/macOS/project.yml` (L38–75) — the unit-test target + scheme test-action shape → basis for the NEW `ArchiveNotesUITests` target (§0).
- `ArchiveReader/macOS/Sources/ArchiveReader/Core/DocumentTags.swift` `sortDate`/`parseYear`/`parseDecade` (cited in CLAUDE.md Implementation map + Verified-Facts) — the shared sort formula that `DateSortParityTests` (§1.7) pins Notes against via ArchiveCore (00-overview §10).
- `ArchiveReader/scripts/lint-write-surface.sh` — run against ArchiveNotes to confirm the projector is the **only** new tag-write spelling (§1.3 safety note).

## Bounded sub-tasks
Each is one fresh autonomous session: own worktree → `xcodegen generate` → clean build, **no new warnings** → the named tests green → GUI check where applicable → docs move in the same commit → push → remove worktree (00-overview §14; root CLAUDE.md "How we work").

- **S1 — Pure-model unit suites (front-matter + Markdown bridge + block headers).** *Files:* NEW `Tests/ArchiveNotesTests/NotesFrontMatterTests.swift`, `MarkdownBridgeTests.swift`, `BlockHeaderTests.swift` (front-matter/block-header tests may live in `ArchiveCoreTests` if the parser is in ArchiveCore per 00-overview §10). *Steps:* implement §1.1 + §1.2 including the seeded fuzz loop and the unknown-key-preservation test. *Verify:* `xcodebuild test -only-testing:ArchiveNotesTests` (+ `swift test` in the package) green; no new warnings. *Tier-1* (pure, no writes). *Done:* all §1.1/§1.2 tests named+green; flip the W8-S1 checkbox in `SUITE_TODO.md` + this plan.
- **S2 — `NotesTagProjectorSafetyTests` (the crown jewel).** *Files:* NEW `Tests/ArchiveNotesTests/NotesTagProjectorSafetyTests.swift`. *Steps:* implement all seven §1.3 cases on `mktemp` `.md`s (model on `TagWriterTests`); add the DEBUG scratch-prefix `precondition` guard to `NotesTagProjector` (§5). *Verify:* suite green on scratch files; `lint-write-surface.sh` passes (projector is the only tag-write spelling); byte-unchanged assertions hold. **Tier-2** (adversarial review + functional test on scratch copies, 00-overview §9/§12). *Done:* every safety invariant (§9 1–5) has a named passing test; tag-wipe-on-unreadable and verify-fail-reconcile explicitly covered; checkbox flipped.
- **S3 — `NotesIndexTests` + org-graph + `organization.json` round-trip.** *Files:* NEW `Tests/ArchiveNotesTests/NotesIndexTests.swift`. *Steps:* §1.4 (build/incremental/prune/bm25/sanitizer + graph persist/reload + JSON export). *Verify:* suite green (temp sqlite); assert prune is gated (empty-snapshot can't wipe). **Tier-2** (the org-graph writer + `organization.json` atomic write are durable app-owned data). *Done:* §1.4 tests named+green; checkbox flipped.
- **S4 — Virtual-folder/replication model + durable-link + date-sort parity.** *Files:* NEW `Tests/ArchiveNotesTests/VirtualFolderReplicationTests.swift`, `Tests/ArchiveCoreTests/DurableLinkTests.swift`, `Tests/ArchiveCoreTests/DateSortParityTests.swift`. *Steps:* §1.5 (incl. delete-last-instance guard, pure), §1.6 (encode/decode/resolve/new-machine/fallback), §1.7 (sortDate parity). *Verify:* green; `testReuseNotReimplemented` confirms shared `sortDate`. **Tier-2** for the delete-last-instance guard + durable-link resolver; Tier-1 for sort parity. *Done:* named tests green; checkbox flipped.
- **S5 — `ZoteroClientTests` (stubbed local server).** *Files:* NEW `Tests/ArchiveNotesTests/ZoteroClientTests.swift` + a small in-test localhost stub (no third-party dep). *Steps:* §1.8 (parse item/attachment, multi-ref, degrade-when-down, bounded timeout). *Verify:* green with the stub bound to an ephemeral port; no network egress. *Tier-1.* *Done:* named tests green; checkbox flipped.
- **S6 — Smoke gate wiring.** *Files:* NEW `ArchiveNotes/test-smoke.sh`; MODIFIED root `test-smoke.sh`. *Steps:* §2. *Verify:* `./test-smoke.sh notes` PASS; `./test-smoke.sh all` runs reader→notes→processor and aggregates rc; usage text updated. *Tier-1.* *Done:* `run_notes` in the dispatcher, per-app script green, checkbox flipped.
- **S7 — GUI harness scaffold (target + IDs + override + entitlements + fixture builder + cliclick helper).** *Files:* MODIFIED `ArchiveNotes/macOS/project.yml` (NEW `ArchiveNotesUITests` target + scheme); NEW `Tests/ArchiveNotesUITests/SmokeUITest.swift` (launch + window exists); NEW `ArchiveNotes.uitest.entitlements` (Route-B read-write); MODIFIED store-locator (`NotesStoreLocator` DEBUG override) + NEW `NotesStoreLocatorOverrideTests.swift`; add `accessibilityIdentifiers` (§3.3) across the shipped views; NEW `scripts/make-notes-fixture.sh` + `scripts/gui-drive-notes.sh`. *Steps:* §3.1–§3.6; prove the sandboxed UITest build can read+projector-write the fixture; prove the trivial `app.launch()` + `waitForExistence` UITest is GREEN (Reader plan L96–99). *Verify:* `-only-testing:ArchiveNotesUITests` green (trivial test); override-unit-test proves no `notesStoreBookmark` write; no new warnings; prod entitlements byte-identical. **Tier-2** (lives next to the file-access boundary + triggers a real projector write — review the override as Tier-2 per Reader plan L44). *Done:* target builds+launches under XCUITest, fixture builder emits a resolvable store, identifiers landed; checkbox flipped.
- **S8 — GUI checks (the per-wave list).** *Files:* NEW `Tests/ArchiveNotesUITests/NotesGUITests.swift` (+ additions to `gui-drive-notes.sh`). *Steps:* implement the XCUITest-drivable checks G1, G3, G5, G7, G8, G9 with the index-ready + async-tag-write polling (§3.4); script the cliclick checks G4, G6, G10, G11 in the helper; document G2/G6/G11 owner-eye steps. Build the fixture **once per class** (class-level setUp, Reader review L17). *Verify:* XCUITest checks green; cliclick checks pass with Accessibility permission granted; G8 asserts the file survives Cancel. **Tier-2** (G7/G8 exercise the delete-last-instance path; G5/G6 the cross-app link path). *Done:* each mapped check passes or is explicitly marked owner-eye in the harness README; checkbox flipped.
- **S9 — End-to-end durable-link scenario + safety doc.** *Files:* NEW `scripts/e2e-durable-links.sh`; NEW `ArchiveNotes/GUI_SAFETY.md`; MODIFIED `ArchiveNotes/SMOKE_TEST.md` (cross-ref). *Steps:* §4 (build store + scratch corpus with known GUID; assert all links resolve; simulate computer-move re-grant; negative fallback) + §5 (write the safety protocol, record `archive-test-run-safety`, confirm the scratch-prefix guard). *Verify:* `e2e-durable-links.sh` PASS on scratch dirs, teardown clean; guard aborts if a write is aimed outside scratch. **Tier-2** (durable-link resolution + scratch safety). *Done:* e2e script green, safety doc committed, checkbox flipped; W8 closed in `SUITE_TODO.md`.

## Tests
Unit suites to add (named above): `NotesFrontMatterTests`, `MarkdownBridgeTests`, `BlockHeaderTests`, `NotesTagProjectorSafetyTests`, `NotesIndexTests`, `VirtualFolderReplicationTests`, `DurableLinkTests`, `DateSortParityTests`, `ZoteroClientTests`, `NotesStoreLocatorOverrideTests`; XCUITests: `SmokeUITest`, `NotesGUITests`. GUI/behavioral checks: G1–G11 (§3.7 table) with drivability marked. Integration: `e2e-durable-links.sh` (§4). Smoke: `ArchiveNotes/test-smoke.sh` + root `run_notes`. The free regression gate = `-only-testing:ArchiveNotesTests` (unit-only, no network/corpus); the GUI target + Zotero-live + reveal cross-app are opt-in / owner-eye.

## Risks & file-safety
- **The only real write surface is `NotesTagProjector`**, and it writes **only Notes' own `.md` files** (00-overview §9). Every W8 tag write (unit S2 + GUI S8) runs on `mktemp`/`AN-GUI-Fixture` scratch; the DEBUG scratch-prefix `precondition` (§5) mechanically aborts any write aimed outside scratch. **Confirm nothing writes the real corpus:** the fixture builder only `ditto`-*copies* PDFs out of `ArchiveProcessor/Test Files` (read-only source) and applies tags to the *copies* (mirrors `smoke-setup.sh`); `lint-write-surface.sh` proves the projector is the sole tag-write spelling and no move/rename/delete/content-write API is imported.
- **Never clobber the real store bookmark:** the harness uses the volatile `-ANUITestStorePath` argument-domain override (never persists `notesStoreBookmark`, §3.1) and **never drives the "Choose Store Folder…" picker** (which would overwrite the real bookmark — `gui-drive.sh` L26–29). A unit test pins "no bookmark write."
- **Flaky/falsely-green GUI risks** (all mitigated per the Reader review): async projector writes → poll `tag -l` before asserting (L14); background index → deterministic `an.status.indexReady` signal (L16); virtualized cells → per-row UUID identity on every bind (L12); inline `NSTextView` focus → DEBUG test-command fallback (L13); path-with-space → two-element `launchArguments` (L18); per-test fixture cost → class-level build (L17). Owner-eye checks (G2/G6/G11) are **flagged as not-auto-verified** so an unattended run cannot claim them.
- **Route-B entitlement must be read-write** (Reader review L8) or S2/G-writes silently no-op → the fix is baked into §3.2; prod entitlements stay byte-identical (verified in S7).
- **cliclick needs Accessibility permission** on the controlling process or clicks silently no-op (`gui-drive.sh` L18–23) — documented in `GUI_SAFETY.md`; the unattended daemon must hold it or skip the cliclick-only checks rather than false-pass.
- **Corpus source is read-only:** `ArchiveProcessor/Test Files` is only ever a `ditto` *source*; no test opens it for writing.

## Open questions
1. Do the front-matter parser + block-header parser live in **ArchiveCore** (shared, tested once) or in the app? 00-overview §10 puts the read-side contract in ArchiveCore; if front-matter is Notes-only it stays in the app — decide in W2, and place §1.1 tests accordingly.
2. Cross-process reveal assertion (G6): can XCUITest reliably assert the *scratch Reader's* row selection from the Notes UITest runner, or is this permanently owner-eye? (The Reader ships its own `ar.table` identifiers, so a two-app XCUITest is theoretically possible but unproven.)
3. Real-Zotero round-trip (G11) depends on Zotero being installed on the run machine; the stub covers logic, but the live `zotero://` open is owner-eye — is that acceptable for the shipped gate, or should we add an optional Zotero-present CI lane?
4. Does the Notes list use an AppKit `NSTableView` (like Reader) or a SwiftUI `List`? If AppKit, port the Reader's `setAccessibilityIdentifier`-in-`makeNSView` + diffable-cell-rebind identity work; if SwiftUI, `.accessibilityIdentifier` suffices — confirm in W6 before S7.
5. Should `e2e-durable-links.sh` run inside the free unit gate (as an XCTest integration case pointing at the fixture dir) or stay a standalone script? Running it in-gate raises coverage but adds fixture-build time to every smoke run.
