# Known Issues & Gotchas

Running log of quirks, risks, and things verified/unverified. Keep current.

## `DeepLinkTests.testRevealAndSelectNoRoot` fails on a machine with a persisted archive root (environmental)
The unit-test host shares the `com.archivereader.app` UserDefaults domain, so if this machine has a persisted
`archiveRootBookmark` (e.g. left by a GUI/XCUITest session pointing at the `AR-GUI-Fixture`), `NavigationModel()`
resolves a root and the test's "No archive folder" assertion fails. It's **environmental, not a regression** —
the diff under test touches no NavigationModel/DeepLink/RootFolderStore code. The WS7 health gate
(`ops/autonomous/health-gate.sh`) therefore runs the Reader unit suite with
`-skip-testing:ArchiveReaderTests/DeepLinkTests/testRevealAndSelectNoRoot` so it doesn't false-park the
autonomous run. **Real fix (then drop the skip) — QUEUED 2026-07-18 as `W20.deeplink-isolation`:** isolate the
test's defaults (inject a volatile `UserDefaults(suiteName:)` with no bookmark), so it doesn't read the machine's
persisted archive root. ⚠️ Must NOT be "fixed" by stashing/removing the machine's real `archiveRootBookmark`
(that's the never-mutate-live-root hazard) — inject a throwaway defaults instead.

## GUI-pass regressions in the AppKit nav table + tag filter (2026-07-16 — owner GUI re-test)
An interactive GUI pass surfaced three display/interaction bugs in shipped Reader features. Two fixed, one deferred:
- **FTS snippet previews never rendered (FIXED).** The keyword-in-context excerpt line under a search hit was
  clipped: the AppKit name-column `NSTextField` (a `labelWithString:` field) stayed single-line
  (`usesSingleLineMode`/`wraps = false`), so the appended second line + `\n` never grew the row under
  `usesAutomaticRowHeights`. Fix: in the snippet branch, put the field into the same multi-line-capable state the
  tags cell (`TagTokenCellView`) uses, and reset it in the non-hit branch (cells are reused). `AppKitTableView.swift`.
- **Column-header click sort was dead (FIXED).** `sortDescriptorsDidChange` is an `NSTableViewDataSource`
  callback, but it was implemented on the `Coordinator` (only the table's *delegate*); the
  `NSTableViewDiffableDataSource` is the real `dataSource` and never forwarded it. Fix: a
  `SortableDiffableDataSource` subclass implements + forwards it — **and the method MUST be `@objc`**: an optional
  @objc-protocol method added on a *subclass* is not auto-exposed to the Obj-C runtime, so `respondsToSelector:`
  returned false and AppKit never called it (build was clean; only runtime/GUI surfaced it). `AppKitTableView.swift`.
- **Selected-tag filter chips shifted the file table left (FIXED `b5a5a01`, owner-verified 2026-07-16).** The chips
  rendered as separate buttons beside the "Add tag filter…" field in a single-row filter bar that already sits near
  the window width; each added chip's width tipped the content column past the window, so the root `HStack`
  re-centered and dragged the file table left.
  **Two container fixes failed — the instructive part:** a horizontal `ScrollView` capped at 260 pt *reserved* its
  max eagerly (a scroll viewport's width is the width proposed to it, independent of content), so it overflowed on
  the **first** chip — worse than the original; a wrapping `FlowLayout` then got compressed to ~one chip wide and
  piled the tags up vertically. Both attempts were tuning a container's width; the bug was that **any**
  content-sized chip row inflates a bar that has no slack.
  **Fix (by construction, not by tuning):** `Views/SubjectFilterTokenField.swift` — an `NSTokenField` whose tokens
  ARE the selected filters, bounded (220 pt), single-line, horizontally scrolling, with LOW horizontal compression
  resistance. Tags live *inside* the field, so adding a filter adds **zero** width to the bar and the column can't
  be pushed past the window. Replaced the `TagFilterField` combo box (deleted; that was its only call site).
  **Lesson:** when a layout bug is "container X inflates its parent", moving the content *inside* an
  already-bounded control beats resizing the container.

## Verified facts to rely on (2026-07-04)
- Writing `.tagNamesKey` while keeping the color-name token (`Red`/`Purple`) and **not** touching
  `.labelNumberKey` **preserved** `labelNumber` (tested on a Red-labeled scratch copy, local APFS).
  Still verify `labelNumber` after every write and restore on drift.
- `FileManager.setAttributes([.creationDate:])` accepts historical dates (1938, 1850) but **clamps
  below ~1677-09-21** (int64-ns-since-1970). → Do NOT use creation date as the chronological sort
  key; sort by a date derived from the tags (no range limit, medieval-safe).
- Spotlight tag queries are fast (compound 3-facet over 6,941 files ≈ 0.38s) and scale.

## macOS tag/label coupling (verified 2026-07-05)
- A **`Red`/`Purple` tag token is inseparable from its Finder color label**: setting the token makes
  macOS auto-assign label 6/3, and there is no "Red subject with no label" state. So `TagWriter`'s
  color-clear removes the token matching the *actual* label (correct), and a document whose subject
  is literally "Red"/"Purple" will always appear color-labeled. Non-color subjects are unaffected.
- **Do not run overlapping `xcodebuild test` invocations** on the same scheme/DerivedData — the
  concurrent test processes contend on `NSFileCoordinator` and tag writes, ballooning runtimes
  (seen: a 0.07s suite took 448s under contention). Run one build/test at a time.

## Deferred hardening (from the 2026-07-05 code review)
- **Write-target identity re-verification (Safety §6, low severity) — FIXED 2026-07-17 (mechanism
  `838b456`+`d393ff3`, W14.2; armed at live call sites `1a7c6cb`+W14.2-fu).** The concern: a tag write
  applies to whatever file currently occupies the URL, so a Finder move/replace between Spotlight
  discovery and the write could tag the wrong file. **Mechanism:** `CoordinatedTagWriter.write(_:expectedIdentity:)`
  + `FileIdentity` (backed by `fileResourceIdentifier`, compared via `isEqual:` — **never**
  `.documentIdentifierKey`, which mutates on read) re-verify the resolved URL's identity **inside the
  `NSFileCoordinator` block** and abort with `.identityMismatch` on a moved/replaced file; the Reader
  `TagWriter.apply`/`setReadState` adapter exposes an opt-in `expecting:` param (fully unit-tested on
  scratch copies). **Armed (W14.2-fu):** every `NavigationModel` write call site — `mark`, group/inline
  edits, corpus-wide rename, and undo — now captures the file's `FileIdentity` **lazily at edit time**
  (via `ArchiveFile.liveIdentity()`, never at bulk discovery, so the "no per-file I/O" fast path is
  preserved) and passes it through `expecting:`; undo re-verifies against the identity captured at the
  ORIGINAL edit, so a file swapped under its path between edit and undo is skipped rather than mis-tagged.
  The group/rename path uses the identity-carrying `TagWriter.apply(_:to:[(url,identity)])` batch overload.
  A `nil` identity (file with no resolvable id) transparently skips the check for that file. Guard active
  in production; failures surface as "could not update/edit" without altering any other file.

## @Published willSet timing (fixed 2026-07-05 — GUI-caught)
- A Combine subscription on a nested `@Published` (`library.$files`) fires in **willSet**, *before* the
  property commits. A synchronous sink that reads the stored property (`self.library.files`) inside
  `recompute()` therefore sees the **old** value — which made the nav list show **0 of N** after a
  load. Fix: `.receive(on: DispatchQueue.main)` before the sink so it runs after the value commits
  (or use the value the publisher delivers, not the stored property). **Do not** read a just-changed
  `@Published` back from `self` inside its own synchronous sink. Unit tests missed this; only running
  the GUI surfaced it (verified via `screencapture`).

## SwiftUI `Table` row-render skip via identity-only Equatable (fixed 2026-07-05 — GUI-caught)
- `ArchiveFile` conformed to `Equatable`/`Hashable` by **`url` only** (treating `==` as *identity*).
  SwiftUI's `Table` diffs elements by Equatable, so when a tag edit changed a row's *tags* but not its
  `url`, the Table judged the element "unchanged" and **skipped re-rendering the cell** — marking a
  file Read left the row visibly "Unread" even though the model was correct. This *masked* the separate
  Spotlight clobber (below): we never saw "Read" appear, so it looked like the write/optimistic update
  failed. Fix: **value-based `==`** (url + name + fileType + tags + contentModified) in
  `ArchiveFile.swift`; row *identity* for selection stays `id` = url.path; url-only `hash` remains valid
  (value-equal ⇒ same url ⇒ same hash). **Lesson:** for a type used as SwiftUI collection data, make
  `Equatable` reflect **displayed value**, not identity — identity belongs in `id`. Unit tests missed
  it; only the live GUI surfaced it (same lesson as the willSet gotcha above).

## Spotlight tag-index lag clobber + the verified-write overlay (fixed 2026-07-05)
- After a verified `TagWriter` write, Spotlight fires `NSMetadataQueryDidUpdate` but re-emits the
  **stale** `kMDItemUserTags` until it re-indexes, so `ArchiveLibrary.reload()` overwrote the correct
  row with the pre-write value (no guaranteed self-heal). Fix: `applyVerifiedWrites(_:)` records
  `TagWriter`'s re-read `.after`/`.afterLabel` per URL and `reload()` **overlays** it until Spotlight
  *value-converges* (case/order-insensitive multiset + normalized label) or a 600 s TTL leak-guard
  (via a coalesced settle `Timer` for when Spotlight goes silent). It **never backslides** within the
  TTL and is **display-only — no disk write, not even a disk read** (a read-only "disk oracle" variant
  was considered and rejected as unneeded complexity + a scale hazard). The per-row decision is the
  pure, unit-tested `overrideDecision`. Replaced the old `applyOptimisticReadState`/`setExactTags`
  (which reconstructed tags from the model's own stale array); `mark`/`applyEdit`/`undo` now route
  through one `applyVerifiedWrites` pass (batch O(N+M), one publish; undo displays the inverse-apply's
  fresh `.after`, Safety §9).

## Reactive/eventual-consistency bugs found by adversarial review (fixed 2026-07-05)
A multi-agent hunt for this bug class (the willSet + clobber category) confirmed four more:
- **`extendSelectionToDocumentRun` selection race:** the `Task` mixed a *pre-await* `selected` snapshot
  with the *post-await* current `self.selection`, so a selection change during the `await` polluted it.
  Fix: snapshot the selection before the await and bail if it changed (the selection is the epoch).
- **`ContentIndexer` dropped live updates:** `guard !running` silently dropped any index request that
  arrived during a running pass (new/re-OCR'd files never indexed). Fix: coalescing `pending` + relaunch
  on finish (a tag-only update does not restart a huge initial index, since `needsIndex` skips it).
- **`ContentIndexer` uncancelled scope change:** the detached task was never cancelled (its
  `Task.isCancelled` check was dead code), so a stale-scope pass held the slot and the new root was
  never indexed. Fix: store + cancel the task on an empty-set (scope-clear) call, with a `generation`
  token so a superseded pass can't clobber newer progress/finish state.
- **⌘O orphaned the Preview sheet:** the Selection-menu ⌘O stayed enabled over the preview and opened
  the doc window without dismissing the sheet. Fix: `openSelection()` clears `showingPreview` first.

## Open risks / to verify
**Reviewed with the owner 2026-07-18** — every former entry here was grounded against current code; almost all
are now settled in code + tests. Kept as a short record:
- **SETTLED — Spotlight content indexing is not relied on.** Full-text search uses the Reader's own FTS5 index
  (`Search/ContentIndex.swift` + `ContentIndexer` + `PDFTextExtractor` over page-2 text), never
  `kMDItemTextContent` (0 code references). The old "re-check on-disk indexing" residual is moot.
- **SETTLED — `.documentIdentifierKey` is never requested** (it can assign/persist an identifier = a mutation).
  It appears only in "never request" comments; W14.2 identity re-verification uses `fileResourceIdentifier`
  (Safety §6). Enforced, not "to confirm."
- **SETTLED — tag-write coordination.** The shared `CoordinatedTagWriter` uses
  `NSFileCoordinator(.contentIndependentMetadataOnly)` (never `.forReplacing`), reads the array **inside** the
  coordinated block (TOCTOU), and verifies by re-read multiset. Covered by focused example tests
  (`TagWriterPrimitiveTests`/`TagWriterTests`). *(A generative property test was considered 2026-07-18 and
  declined as assurance-only — the path is deterministic + audited + green.)*
- **SETTLED — facet classification is display/sort/filter only, never drives a write.** `DocumentTags.parse`
  demotes shadowed collisions (a subject literally `1984`/`P7`/`Read`) back to subjects; `TagEditing` removes only
  the exact winning token. Regression-tested (incl. the `Read`-substring case).
- **SETTLED — segment features degrade when Classification is absent** (`DocumentRuns` returns a single item);
  the nav table is AppKit `NSTableView`; non-2-page / corrupt / non-PDF files degrade via `PDFFormatStatus` +
  render guards (page count is never a defect signal).
- **Low-pri, NOT queued (owner-reviewed 2026-07-18) — Unicode-on-write verification.** A scratch probe/guard for
  (a) macOS not trimming whitespace off a tag on write and (b) locking in that the verify treats NFC==NFD as
  equal. **The note's NFC/NFD "false-fail" fear is already neutralized** — Swift `String` comparison is
  canonical-equivalence-aware — so only the trim case is unpinned. Assurance-only, not a correctness gap; left
  as a soft backlog item.
- **QUEUED (owner-reviewed 2026-07-18) — the `DeepLinkTests` no-root flake real-fix** (top of this file) is now
  tracked as **`W20.deeplink-isolation`** in `SUITE_TODO.md`.

## Environment notes
- Xcode 26.3 / Swift 6.2 toolchain; XcodeGen 2.45.2 at `/opt/homebrew/bin/xcodegen`.
- GitHub CLI: use `/opt/homebrew/bin/gh` (bare `gh` is shadowed on this machine).
- The corpus lives in `Test files/Brown Gemini/` (150-PDF representative sample as of 2026-07-18, slimmed from ~6,941) and is gitignored — never modify it.
