# Archive Notes — Known Issues & Gotchas

Running log of quirks, risks, and things verified/unverified for the Notes app. Keep current.
(Sibling logs: `../ArchiveReader/KNOWN_ISSUES.md`, `../ArchiveProcessor/KNOWN_ISSUES.md`.)

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
  windows' differing selections. GUI drive of a live paste is deferred with the rest of W7 (Notes has no
  scratch-store launch override until **W8-S7** — driving the live app would write the owner's real store).
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
