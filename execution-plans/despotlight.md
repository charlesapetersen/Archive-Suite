# Execution plan — Remove all reliance on Spotlight (Archive Suite)

**Owner directive, 2026-08-04:** *"Spotlight is fundamentally unreliable on macOS."* Replace every use of
Spotlight (`NSMetadataQuery` / `kMDItem*` / `mdfind`) across the suite with owned, deterministic
filesystem discovery. **Wave 26.** Tracked from `SUITE_TODO.md` §"Wave 26 — de-Spotlight the suite".

---

## 0. Why — the incident that triggered this

The owner pointed Archive Reader's root at `~/Desktop/Glazer Gemini 2.5 LLM` — **1,849 PDFs, every one
correctly tagged** (`("Nathan Glazer", Unread, Red)`, verified on disk) — and got:

> **No tagged documents** — "No Read/Unread-tagged PDFs were found in this folder."

Diagnosed 2026-08-04. The files were perfect. The **macOS Spotlight index for the entire Data volume was
dead**: `mdfind -onlyin` returned **0** for that folder, for `$HOME`, for `/Applications`, and for the
known-good corpus, while system-volume queries still worked (446 PDFs under `/System/Library`). Four
`mdbulkimport` helpers had been wedged for **14 days 23 hours at 0% CPU**; `mdutil -s` on the folder
returned `Error: unknown indexing state` while cheerfully reporting "Indexing enabled" for the volume.

Two separate failures, and the second is ours:

1. **Spotlight was blind** — a system service we do not control, silently returning an empty result set
   that is indistinguishable from a true negative.
2. **The app blamed the files.** `NavigationWindowView.swift:174-176` asserts a *fact about the corpus*
   ("no Read/Unread-tagged PDFs were found") when the truth was "this app cannot see them." That sent
   the owner looking at his tagging instead of at Spotlight. **An empty index must never render as an
   empty corpus.**

This plan removes the dependency, not just the misleading string.

---

## 1. Ground truth — the complete Spotlight inventory

Audited 2026-08-04 across the whole worktree (all three apps + `packages/ArchiveCore` + tests + scripts).

### Site 1 — `ArchiveReader/.../Search/ArchiveLibrary.swift` (219 lines) — **the critical one**

The **sole** discovery mechanism for the Reader. In a Release build there is **no filesystem fallback
whatsoever**.

| Line(s) | What Spotlight provides |
|---|---|
| 20 | `private let query = NSMetadataQuery()` |
| 41-42 | predicate `(kMDItemUserTags == "Read") \|\| (kMDItemUserTags == "Unread")` |
| 43-46 | `valueListAttributes`: path, FSName, contentType, FSContentChangeDate, `kMDItemUserTags`, `kMDItemFSLabel` |
| 48-53 | `DidFinishGathering` / `DidUpdate` → `reload()` — the live-update mechanism |
| 74-80 | `searchScopes = [user-picked root]`, else `NSMetadataQueryLocalComputerScope` |
| 179-212 | `reload()` builds every `ArchiveFile` purely from `NSMetadataItem` attributes |

- **Its stated justification (lines 11-12)** — *"building the list needs no per-file disk I/O (the fast
  path at 150k)"* — **is already false in practice.** See §2.
- **Lines 22-38 + 122-177 + 197-209: the `PendingWrite` override subsystem (~80 lines)** — `pending`
  dict, `settleTimer`, `overrideTTL = 600`, `applyVerifiedWrites`, `overrideDecision`, `sameTags`,
  `sameLabel`, `rebuilt`. It exists **solely to mask Spotlight's tag-index lag**: after a `TagWriter`
  write, Spotlight fires `DidUpdate` but "frequently re-emits the OLD `kMDItemUserTags` until it
  re-indexes — which was clobbering the correct value with no guaranteed self-heal." **All of this is
  pure Spotlight tax and gets deleted.**
- **Lines 60-73 + 87-119: `loadFixtureSynchronously`** — a *working* `FileManager` enumeration +
  `TagReading.read` discovery path that already "mirror[s] the production predicate" — but it is
  `#if DEBUG`, gated on the `-ARUITestRootPath` UITest flag, and "compiled out of Release entirely."
  **The fix was already written, tested, and then excluded from the shipping build.** Its comment
  (62-65) even documents the exact production failure mode as a test-only concern.

### Site 2 — `ArchiveProcessor/.../Tagging/SystemTagsProvider.swift` (97 lines)

Tag-vocabulary autocomplete for manual tagging. `searchScopes = [NSMetadataQueryUserHomeScope]`,
predicate `kMDItemUserTags LIKE "*"` (lines 31-32). Harvests **every Finder tag in use anywhere in the
user's home** — a scope no per-root walk reproduces. Needs a real decision, not a hand-wave (§4.4).

### Site 3 — `ArchiveReader/.../Search/ContentIndexer.swift:283` — comment only

References `NSMetadataQueryDidUpdate` in prose about tag-write lag. Update the comment; no code change.

### Site 4 — test/fixture infrastructure (decide, don't just delete)

- `ArchiveReader/scripts/make-gui-fixture.sh` — lines 16, 179 (`mdimport`), 186 (poll `mdfind`)
- `ArchiveReader/scripts/smoke-setup.sh` — lines 22 (`mdimport`), 26 (poll `mdfind`)

Both force-index fixture copies and then **poll `mdfind` until the tags appear** — a wait that becomes
both unnecessary and impossible once discovery is ours. Removing these polls also removes a real source
of fixture-setup flake.

### Site 5 — docs that become false

`ArchiveReader/CLAUDE.md:106` (*"Search: Spotlight (`mdfind`/`NSMetadataQuery`) finds these by tag
fast"*), plus the *Verified Facts* line "Spotlight exposes tags as `kMDItemUserTags`" (true of macOS,
but no longer how we read them). Check `SPEC/tag-format.md`, `README.md`, `AGENTS.md`, `KNOWN_ISSUES.md`.

### Site 6 — `ArchiveProcessor/scripts/assert_mac.py:43` — a **test oracle** reading tags via `mdls`

```python
tags = "\n".join(sh("mdls", "-name", "kMDItemUserTags", p) for p in pdfs)
```
Consumed at `:44` (`name_tag_blob`) and `:55`. **During the 2026-08-04 incident this oracle would have
reported empty tags and failed an otherwise-passing build** — the same failure mode as the Reader, in the
test lane. Replace with `tier2_assert.py`'s `disk_tags()`. Independently shippable; was not in the
original inventory.

### Site 7 — a **future re-infection** already approved in the backlog

`SUITE_TODO.md:1048` (open, owner-decided) specifies *"Detection: index the JPEGS tree (**a second
`NSMetadataQuery`**). This is **REQUIRED, not an optimisation** — 80.1% of partners need relocation
resolution no path rule can do."* If that ships before or during this wave it **re-introduces the exact
dependency the owner is removing.** Rewrite it to a walk-built stem index (same walker, second root) and
add a `(blocked-on: W26.walk1)` edge so it cannot start first. Highest-value find in the doc lane.

### Site 8 — a load-bearing claim that may itself rest on a Spotlight myth

`ArchiveProcessor/TESTING.md:72`: *"All PDF / Finder-tag / sidecar verification is done externally … reading
tags in-process contends with Spotlight and wedges."* The Processor's **entire out-of-process test
verification architecture** rests on that diagnosis — but `TagReading.read` uses `url.resourceValues`
(`TagReading.swift:29-38`), which **does not go through Spotlight at all**. So the stated mechanism is
dubious and the real cause is more likely the main-actor context named in the same comment. **Flag it;
do not silently keep or delete that architecture.** Investigating it is out of scope for this wave.

### Confirmed clean

**Archive Notes and `packages/ArchiveCore` contain no Spotlight usage at all** (two benign prose mentions
in Notes, one of which already documents that Notes discovery is *not* Spotlight). No entitlement and no
`project.yml` change is needed anywhere: **there is no Spotlight-specific entitlement in the suite.** This
is a pure code + doc change. One real build consequence: un-fencing the walker means the
`UniformTypeIdentifiers` import at `ArchiveLibrary.swift:4-6` must come out of `#if DEBUG`, and the
**Release** build must be gated (not just Debug).

### The better precedent: Archive Notes, end-to-end

`ContentIndex` is the right *storage* precedent, but **Archive Notes already implements this whole
pattern** — a filesystem walk feeding a disposable FTS5 index, with a readiness flag, a settle await,
health adoption, and tests around all of it. Copy the shape rather than invent it:

- `ArchiveNotes/.../Core/NotesModel.swift:286-300` — `buildIndexFromDisk`: `allItemRefs` → `startIndexing`
  → **`awaitSettled`** → `reloadItems` → **`markIndexReady`** → `adoptIndexFailure`.
- `awaitSettled()` is the **test seam** that answers the sync/async question in §5.6.
- `markIndexReady` is the `isGathering` analogue; `adoptIndexFailure` (`:311-321`) is the honest-degraded
  precedent.
- `ArchiveNotes/.../ReaderLinkResolver.swift:235-266` — the **already-reviewed** pattern for an off-actor
  enumerator (private `FileManager` instance, `nextObject()` rather than `for-in`). Use it verbatim.

---

## 2. Measured evidence — the numbers that make this safe

All measured 2026-08-04 on this machine, **read-only**, with the exact Foundation APIs the replacement
would use (`FileManager.enumerator` + `URL.resourceValues`). Scratch benchmarks, no corpus mutation.

**The real production corpus** (`~/Desktop/Google Drive/Archival Photos`), full recursive walk reading
tags + label + type + mtime for every file:

```
walked in 10.15 s
files=123028  pdfs=102478  dirs=535  maxDepth=7  Read/Unread-tagged=95201
per file: 82 us          extrapolated to 150k: 12.4 s
```

**A 1,849-file flat folder** (the incident folder), isolating the two costs:

| Operation | Cold | Warm | → 150k files |
|---|---|---|---|
| `FileManager.enumerator` walk | 193 ms | 78 ms | ~6–16 s |
| `resourceValues` (tags+label+type+mtime), serial | 16 ms (9 µs/file) | 15 ms | ~1.3 s |
| same, **parallel** (width 12) | 4 ms (2 µs/file) | 5 ms | **~0.4 s** |

**Conclusions that the plan rests on:**

1. **A complete, correct cold discovery pass over the real 102k-PDF corpus takes ~10 seconds
   single-threaded** — one time, in the background, and parallelisable to a few seconds. Spotlight's
   current answer for the same corpus is **zero rows**. Any "too slow at 150k" objection must beat that
   arithmetic.
2. **`ArchiveLibrary`'s no-per-file-I/O justification is already void.**
   `ContentIndexer.startIndexing(_ files:)` (line 84) takes its work list from the Spotlight-derived
   library and then **opens and extracts text from every PDF in the corpus**. The app already performs
   full-corpus per-file I/O, at a cost orders of magnitude above an xattr read. Discovery I/O is noise
   next to work already being done.
3. **The `Read`/`Unread` tag read is exact.** The walk found 95,201 tagged files in the real corpus and
   1,846 of 1,849 in the incident folder, via `TagReading`'s own key set — including filenames
   containing an em dash (U+2014) followed by a **non-breaking space** (U+00A0), which round-trip fine.

**The "Google Drive" hazard does not exist.** `~/Desktop/Google Drive/` is **not** synced to Google
Drive — the name is residual (owner, 2026-08-04). It is a plain directory on `/dev/disk3s5`, no
DriveFS/FUSE mount, and files are fully materialised (288 blocks × 512 B ≈ 145,485 B logical). So: no
placeholder/dataless files, no download-on-read, no egress cost, no third-party sync client mutating
files behind us. **Do not add defences for any of that.** (Corollary: the corpus is *not* backed up by
Drive — it is irreplaceable local data, which is why the Core Directive exists.)

---

## 3. Strategy — stop the recurrence first, then build the durable end state

Three stages, each independently shippable, **never leaving the app broken between items**:

- **Stage A — Own the discovery (W26.walk1 → W26.walk2).** A read-only `CorpusWalker` in ArchiveCore
  becomes the Reader's real discovery path in Release. Spotlight is gone from the Reader. Ships the
  honest degraded states. **After this stage the incident cannot recur.**
- **Stage B — Live and instant (W26.fsev → W26.idx).** FSEvents replaces `DidUpdate` for third-party
  edits; a SQLite index gives an instant warm start and background revalidation at 150k.
- **Stage C — Finish the suite (W26.vocab, W26.scripts, W26.docs, W26.verify).** The Processor's
  vocabulary comes off Spotlight, the fixture scripts drop `mdimport`/`mdfind`, docs stop claiming
  Spotlight, and a scale verification gates deleting this plan.

**Why Stage A does not need Stage B to be coherent:** the Reader's own tag writes already return a
*verified* `.after` array from `TagWriter`. Applying that directly to the row is strictly more correct
than anything Spotlight offered — it is ground truth read back from disk — so self-inflicted updates are
exact from W26.walk2 onward. Only *third-party* edits (Finder, another app) wait for W26.fsev, and until
then a manual refresh covers them. This is why the ~80-line override subsystem can die immediately: it
existed only because Spotlight contradicted a verified write.

---

## 4. Architecture

### 4.1 `CorpusWalker` — new, `packages/ArchiveCore/Sources/ArchiveCore/Corpus/CorpusWalker.swift`

Read-only, deterministic discovery. Shared by both apps (the repo's DRY + shared-contract convention).

- Input: a root `URL` (security-scoped), a predicate (default: has `Read` or `Unread`), a cancellation
  token, a progress callback.
- Walk with `FileManager.enumerator(at:includingPropertiesForKeys:options:)`, options
  `[.skipsHiddenFiles, .skipsPackageDescendants]` — matching the already-working DEBUG fixture loader
  (lines 97-99), so behaviour is pre-validated.
- Per file, read tags/label/type/mtime through **`TagReading.read`** (`ArchiveCore/Tags/TagReading.swift:29`)
  — already the authoritative pre-write read, so discovery and writes agree by construction.
- Emits `[ArchiveFile]` (unchanged shape) in batches so the UI can populate progressively.
- **Never writes, never moves, never renames.** Enumeration + `resourceValues` only.
- Parallelised with a bounded `TaskGroup` (width = `activeProcessorCount`, capped) over directory
  chunks; ordering is imposed afterwards, not relied on from the enumerator.

### 4.2 `ArchiveLibrary` — modify (the swap)

- Delete: `query`, the predicate, `valueListAttributes`, both `NotificationCenter` observers, both
  `searchScopes` branches, and the whole `reload()`-from-`NSMetadataItem` path.
- Delete: **the entire `PendingWrite` override subsystem** — `PendingWrite`, `pending`, `settleTimer`,
  `overrideTTL`, `armSettleTimer`, `overrideDecision`, `sameTags`, `sameLabel`, `applyVerifiedWrites`'s
  pinning behaviour (the method stays, but now applies `TagWriter`'s verified `.after` **permanently and
  directly**, because nothing will contradict it).
- Promote `loadFixtureSynchronously` out of `#if DEBUG` into the real `CorpusWalker`-backed path; the
  `-ARUITestRootPath` flag then selects a *fixture root*, not a *different discovery mechanism* —
  removing the DEBUG/Release divergence that hid this bug.
- `start(scope:)` runs the walk off the main actor, publishing batches; `isGathering` drives the
  existing spinner, now with real progress (`n of m`), which Spotlight could never provide.

⚠️ **`applyVerifiedWrites` has five callers that will not compile if its signature changes** —
`NavigationModel.swift:839` (mark), `:862` (group edit), `:952` (inline edit — carries the *"one O(N+M)
overlay pass (was per-file O(N×M))"* note), `:998` (corpus-wide rename), `:1050` (undo). Rewrite all five
to a direct row replacement from the verified `.after`/`.afterLabel` they *already pass in*, reusing
`rebuilt` (`:139-142`): same batch shape, one publish, no dict, no timer. Safety §11 still holds — only
verified results move a row.

⚠️ **`isGathering` and `scopeDescription` are correctness gates, not cosmetics.** Declared at
`ArchiveLibrary.swift:17-18`, four consumers, two load-bearing: `pruneIfSettled`
(`NavigationModel.swift:649-651`) gates **deletion of content-index rows** on `isGathering == false`, and
the deep-link reveal give-up counter depends on it. **A walker that leaves `isGathering` false during a
partial pass would let `pruneIfSettled` evict index rows for files the walk has not reached yet.**
Redefine precisely: true while a pass is in flight, false **only after a pass completes**; a cancelled or
failed pass must leave pruning blocked.

⚠️ **Publisher ordering.** `NavigationModel.swift:110-117` uses a `willSet` publisher + a
`MainActor.assumeIsolated` sink whose `.receive(on:)` hop fixes a **GUI-only** bug that unit tests
provably missed (root cause at `ArchiveReader/KNOWN_ISSUES.md:166-173` — *"showed 0 of N"*). A background
walk publishing batches from a detached task **must keep that hop** — hence `W26.walk2` needs a
functional/GUI gate, not only unit tests.

### 4.3 Honest states — the actual UX fix

`NavigationWindowView.swift` gains a state it never had: **"we could not read this folder"** as distinct
from **"this folder has no tagged PDFs."** Mirror `ContentIndexer.Failure`
(`ContentIndexer.swift:19-45`), which already does this correctly for the content index
(`.unavailable(detail:)` / `.incomplete(rows:)` → "Search index unavailable", with a tooltip explaining
the index is a rebuildable cache).

New `DiscoveryStatus`: `.idle`, `.walking(done:total:)`, `.ok(count:)`,
`.failed(reason:)` (permission denied, root unreachable, bookmark stale, volume unmounted),
`.emptyButReadable(scanned:)`.

- `.emptyButReadable` is the **only** state permitted to say "no tagged PDFs were found" — and it now
  says it with evidence: *"Scanned 1,849 files in this folder; none carry a Read or Unread tag."*
- `.failed` says what failed and what to do, and **never** implies anything about the corpus.

### 4.4 `SystemTagsProvider` (Processor) — the home-wide-scope problem

Spotlight gave a vocabulary over the *entire home folder*; no per-root walk reproduces that. Resolve it
as follows, in order of preference:

1. **Persist the vocabulary.** A `TagVocabulary` store (app support, SQLite or a plist — it is a small
   set of strings) accumulated from: every root the Processor/Reader has ever been pointed at, plus
   every tag the user types (`register(_:)` already does this, lines 89-96), plus every tag any
   `TagWriter` write emits. It **grows monotonically** and survives launches — after one session it is
   *better* than Spotlight's answer, because it is scoped to the archive rather than polluted by every
   tagged file in the home folder.
2. **Seed it** on first run by walking the known archive roots (cheap — §2), not `$HOME`.
3. **Accept the narrowing explicitly.** Tags on unrelated personal files outside any archive root will
   no longer appear as suggestions. That is a *behaviour change and an improvement* for an archival
   tagging UI; record it in the Processor's `CLAUDE.md` and in `SUITE_TODO`. **Do not** walk `$HOME` to
   emulate Spotlight — that would be slow, invasive, and would trip TCC prompts across unrelated dirs.

### 4.5 `CorpusWatcher` — new (W26.fsev), FSEvents live updates

**Verified empirically 2026-08-04** (scratch dir, `kFSEventStreamCreateFlagFileEvents`): a pure Finder
tag write — `setResourceValue(_:forKey:.tagNamesKey)`, changing **no file bytes** — *does* produce an
event, flagged `ItemXattrMod | ItemInodeMetaMod | ItemModified`. A raw `setxattr` of a non-Finder xattr
fires too. **So a watcher can see third-party tag edits; polling is not required.**

**Critical gotcha, also measured:** FSEvents **unions flags across its coalescing window**. The
byte-free tag write above *also* reported `ItemRenamed`, which never happened. Therefore:

> Treat every event as **"this path may have changed — re-`stat` and re-read its tags"**, never as
> "this specific thing happened." Flags may be used to *skip* work, never to *decide* semantics.

- Recovery flags to handle explicitly: `MustScanSubDirs` (→ re-walk that subtree),
  `RootChanged` (→ re-resolve the bookmark, re-walk), `EventIdsWrapped`/`HistoryDone` (→ full re-walk),
  `Unmount`/`Mount`.
- Sandbox: the stream is created on the **security-scoped root**, with
  `start/stopAccessingSecurityScopedResource` balanced across the *stream's whole lifetime*, not per
  read. Entitlements already present (`app-sandbox`, `files.user-selected.read-only`,
  app-scoped bookmarks) are sufficient — POSIX/FSEvents access to a user-granted root works even where
  Spotlight query visibility does not (the very asymmetry documented at `ArchiveLibrary.swift:62-65`).
- Atomic writes create temp siblings (measured: `a.txt.sb-858602c2-RXb79N`) — the watcher must ignore
  paths that fail the predicate rather than treating them as corpus members.
- **Self-write suppression:** `TagWriter` publishes the URLs it just wrote; the watcher drops the
  matching event so the app does not re-read its own write. Because the verified `.after` is already
  applied, a missed suppression is merely redundant work, never incorrect.

### 4.6 `LibraryIndex` — new (W26.idx), instant warm start

Follows the **existing, proven** `ContentIndex` precedent (`Search/ContentIndex.swift`): an `actor`
wrapping **system SQLite** (`import SQLite3`, no third-party dependency), living under
`.applicationSupportDirectory` (`ContentIndexer.swift:65`), with schema changes handled by **bumping the
filename** (line 68) rather than writing a migration — exactly what the no-migration-burden directive
licenses.

**Sibling store, not an extension of `ContentIndex`.** Discovery must work *before* content extraction
(`ContentIndex` is populated *from* the library), so folding discovery into it would invert the
dependency and would put the 8-case content-index test suite in the blast radius of every discovery
change. Keep them separate; both are disposable caches.

```sql
CREATE TABLE files (
  path        TEXT PRIMARY KEY,   -- absolute; see normalisation note below
  root        TEXT NOT NULL,      -- owning root, for prefix eviction
  name        TEXT NOT NULL,
  mtime       REAL NOT NULL,      -- from stat(2), NOT resourceValues (see §5)
  size        INTEGER NOT NULL,
  uti         TEXT,
  tags        TEXT NOT NULL,      -- JSON array, verbatim, order preserved
  label       INTEGER,
  scanned_at  REAL NOT NULL
);
CREATE INDEX files_root ON files(root);
CREATE INDEX files_mtime ON files(mtime);
```

- **The filesystem and its xattrs remain the sole source of truth.** This DB is a disposable cache;
  deleting it loses nothing (same guarantee `ContentIndex` already documents). It is stored **outside
  the corpus**, in app support — never written into an archive folder.
- **Warm start:** show persisted rows immediately, then revalidate in the background (`stat` each path,
  re-read tags only where mtime/size moved, plus a full walk to catch additions/removals). The user sees
  rows in milliseconds with a subtle "revalidating…" affordance rather than a 10-second spinner.
- **Removals** are applied only after the walk **completes successfully** — a cancelled or failed walk
  must never be read as "these files are gone." (`ContentIndexer` already models this hazard with its
  two-snapshot prune gates and `rootPrefix` eviction, `ContentIndexer.swift:361-420`; reuse that shape.)

---

## 5. Verified traps the implementer must respect

1. **`URL.resourceValues` caches on the backing `NSURL`.** Measured on this machine (2026-08-01,
   W23.m11-fu; memory `url-resourcevalues-caches`): rewriting a file 100 → 250 bytes between two calls
   **on the same `URL` value** read back **unchanged** on both `.fileSizeKey` and
   `.contentModificationDateKey`. **A revalidation pass that reuses `URL` values is silently a no-op —
   it compiles, looks right, and never fires.** Use `stat(2)` via
   `url.withUnsafeFileSystemRepresentation { stat($0, &info) }` (~15 µs, nanosecond `st_mtimespec`) for
   every freshness check, or construct a fresh `URL` per read. This is the single most likely way to get
   W26.idx wrong.
2. **`URL.standardizedFileURL` touches the filesystem** (52.7 µs on an existing path vs 12.8 µs on a
   missing one — same measurement session). Do not use it per-file in the walk on the belief that it is
   string-only.
3. **Unicode normalisation on SQLite path keys.** Filenames contain U+2014 em dash and U+00A0
   non-breaking space; APFS is normalisation-*preserving* but comparison-insensitive in ways Swift
   `String` equality is not. Store the path exactly as the enumerator returned it and compare
   byte-identically (or key on the file-system representation) — never round-trip through an NFC/NFD
   normalisation, or warm-start lookups will miss and re-index the whole corpus every launch.
4. **FSEvents flags are unioned across the coalescing window** (§4.5) — re-read, don't trust flags.
5. **No test currently covers Reader discovery at all.** `grep 'ArchiveLibrary(' ArchiveReader/macOS/Tests`
   returns **zero hits** — nothing anywhere constructs it. The only `ArchiveLibrary` test file is
   `ArchiveLibraryOverrideTests.swift` (8 cases: `testConvergedExactMatchDropsOverride`,
   `testConvergedIgnoresTagOrderAndCase`, `testLabelDifferenceIsNotConverged`, `testNilLabelEqualsZeroLabel`,
   `testStaleEchoKeepsShowingVerifiedValue`, `testDoublyStaleValueStillDoesNotBackslide`,
   `testExpiredOverrideYieldsToSpotlight`, …), every one testing the Spotlight-lag override. That gap is
   precisely how a Release build with no discovery fallback shipped. **The whole file is deleted and
   `W26.walk1` must land the replacement tests in the same work item** — the suite total drops by 8, so
   say it up front or a green run with fewer tests reads as a regression.
6. ⚠️ **SYNC-VS-ASYNC IS THE FIRST DECISION, AND IT IS FORCED BY EXISTING TESTS.** Two test files already
   drive the DEBUG walker *as the production path* and assert **synchronously** that a freshly-tagged
   scratch PDF is in `model.library.files` immediately after `NavigationModel()` returns:
   `DocumentPageLinkTests.swift:229-233` + `:239-240` (*"precondition: the scratch PDF is discoverable"*)
   and `RootMarkerStateTests.swift:143`. **If the new walker is async, both break.** These are
   simultaneously the plan's free head start and its hardest constraint. Decide the API shape **before**
   writing the walker: either keep a synchronous settle path for tests, or adopt Notes'
   `awaitSettled()` seam (`NotesModel.swift:286-300`) and convert both tests. Do not discover this at
   the build gate.
7. **The Reader's write-surface lint bans ordinary file writes across the whole app target.**
   `ArchiveReader/scripts/lint-write-surface.sh:20-25` rejects `removeItem|moveItem|trashItem|replaceItem|
   createFile|FileHandle forWriting|PDFDocument.write|.write(to:)` anywhere under
   `macOS/Sources/ArchiveReader/`. So **`LibraryIndex` must persist through the SQLite3 C API** exactly as
   `ContentIndex.swift` does — not `Data.write(to:)`, not `FileManager`. (This constraint already forced
   one design decision in `ContentIndexer`.) The read-only `FileManager.enumerator` walk itself is fine.
8. **`DeepLinkTests.swift` sets `-ARUITestRootPath` in four places** (`:45-46`, `:60-61`, `:90-91`,
   `:115-116`) and one case (`testRevealAndSelectGuidMatch`, `:118-123`) depends on the root having **no
   discoverable files**. Those temp dirs hold only a marker JSON, so a real walk should still find zero
   tagged PDFs and the deferral should hold — but **re-run it, do not assume**; this is the case most
   likely to change meaning silently.
9. **15 fixture-based UI tests inherit a readiness assumption.** `FixtureUITestCase.swift:53`, `:62-64`
   (*"loads synchronously off disk (DEBUG `-ARUITestRootPath` path)"* — comment becomes false), `:75-80`
   (`waitForRows`). Re-validate the `waitForRows` timeouts against the new walker's latency on the
   12-file fixture; if the walker goes async, the GUI lane flakes here first.
10. **`NavigationUITests.swift:46-48`** states the exclusion rule in Spotlight terms but its assertion
    becomes the **end-to-end pin that the walker's membership rule equals the old predicate.** Keep the
    assertion, fix the comment, and promote it to an explicit equivalence check.

---

## 6. What gets deleted (net simplification)

| Deleted | Why it existed |
|---|---|
| ~80 lines of `PendingWrite` machinery in `ArchiveLibrary.swift` | masked Spotlight's tag-index lag |
| `ArchiveLibraryOverrideTests.swift` (8 cases) | tested that masking |
| `NSMetadataQuery` setup + both observers + `reload()` attribute plumbing | Spotlight |
| `#if DEBUG` / Release discovery divergence (`loadFixtureSynchronously`) | Spotlight can't see sandbox temp-exception paths |
| `mdimport` + `mdfind`-polling in 2 fixture scripts | waiting for Spotlight to catch up |

This is a plan that removes more code than it adds to the Reader's discovery path, and deletes a whole
class of bug (*"the index disagrees with the disk"*) rather than managing it.

---

## 7. Work items — `SUITE_TODO.md` carries the detail; this is the sequence

Daemon-sized: each independently shippable in one fresh session, each with its own build + test gate,
each leaving the app **working**.

| Tag | Title | Effort | Risk | Tier | needs | blocked-on |
|---|---|---|---|---|---|---|
| `W26.walk1` | `CorpusWalker` in ArchiveCore + first-ever discovery test | M | low | 1 | none | — |
| `W26.walk2` | Reader discovery → `CorpusWalker`; delete `PendingWrite`; honest `DiscoveryStatus` | L | med | 2 | none | `W26.walk1` |
| `W26.fsev` | `CorpusWatcher` (FSEvents) replaces `DidUpdate`; self-write suppression | M | med | 2 | none | `W26.walk2` |
| `W26.idx` | `LibraryIndex` (SQLite) warm start + background revalidation | L | med | 2 | none | `W26.walk2` |
| `W26.vocab` | Processor `SystemTagsProvider` off Spotlight → persisted `TagVocabulary` | M | low | 1 | none | `W26.walk1` |
| `W26.oracle` | Processor test oracle `assert_mac.py` off `mdls` → `disk_tags()` | S | low | 1 | none | — |
| `W26.reinfect` | Rewrite the open JPEGS-index item off `NSMetadataQuery` + add its blocking edge | S | low | 1 | none | — |
| `W26.scripts` | Fixture scripts drop `mdimport`/`mdfind` polling | S | low | 1 | none | `W26.walk2` |
| `W26.docs` | Docs/SPEC stop claiming Spotlight (incl. `ArchiveReader/CLAUDE.md:106`) | S | low | 1 | none | `W26.walk2` |
| `W26.verify` | Scale + safety verification on a scratch copy; gates deleting this plan | M | med | 2 | none | `W26.fsev`, `W26.idx`, `W26.vocab`, `W26.oracle`, `W26.reinfect` |

`W26.oracle` and `W26.reinfect` are **unblocked and can go first** — neither depends on the walker.
`W26.reinfect` is deliberately early: it is cheap, and every day it is undone is a day the JPEGS item
could ship a second `NSMetadataQuery` into the codebase this wave exists to clear.

**Per-item test gates** (an item is not done without one that would *fail* if the work were wrong):

- `W26.walk1` — scratch fixture with tagged/untagged/hidden/nested/package files + an em-dash+NBSP
  filename; assert the exact expected set. Assert the walker performs **zero** writes (pre/post xattr +
  mtime snapshot of the fixture).
- `W26.walk2` — the incident reproduction, inverted: a fixture that Spotlight has *not* indexed
  (`.metadata_never_index`, or simply never `mdimport`-ed) must still list every tagged file. This test
  **fails today** and is the regression guard for the whole plan. Plus: `.failed` renders on an
  unreadable root and `.emptyButReadable` only on a genuinely untagged one.
- `W26.fsev` — write a tag with `TagWriter` on a fixture file, assert the row updates without any
  Spotlight involvement; assert a *third-party* `setResourceValue` (simulating Finder) is picked up;
  assert `MustScanSubDirs` triggers a subtree re-walk.
- `W26.idx` — cold index, quit, warm start: assert rows appear before any walk completes, and that a
  file whose tags changed **while the app was not running** is corrected on revalidation (this is the
  test that catches the `resourceValues` caching trap, §5.1).
- `W26.vocab` — vocabulary survives relaunch and accumulates across roots; no `$HOME` walk occurs.
- `W26.oracle` — the Tier-2 assertion suite passes on a fixture whose volume has **indexing disabled**
  (`mdutil -i off` on a scratch DMG, or simply never `mdimport`-ed). Today's `mdls` oracle fails that;
  `disk_tags()` must not. This is the incident reproduced inside the *test lane*.
- `W26.reinfect` — `grep -n "NSMetadataQuery" SUITE_TODO.md` returns nothing outside Wave 26's own
  historical notes, and `next-queue-item.sh` reports the JPEGS item as `blocked:W26.walk1`.
- `W26.verify` — full-scale run against a **scratch copy** (never the real corpus), 100k+ files:
  timings, memory ceiling, no-write assertion across the whole tree, and cancel-mid-walk leaves no
  partial removals.

---

## 8. Safety — Core Directive compliance

The Reader's Core Directive is untouched and this plan **narrows** the write surface:

- Discovery becomes strictly read-only: `FileManager.enumerator` + `resourceValues`/`stat` only.
- **`TagWriter` remains the single audited write choke-point.** Nothing in `CorpusWalker`,
  `CorpusWatcher` or `LibraryIndex` may import a file-mutating API. Add this to the review checklist.
- The index lives in **application support, never in the corpus**. No file in an archive folder is
  created, renamed, moved or rewritten.
- **The index never repairs the disk.** Reconciliation is one-directional: disk → index. A stale or
  corrupt index can only cause *stale display* (self-healing on the next walk), never a write. Any
  proposal to drive a bulk tag write from index contents is out of scope and must be refused.
- All tests use scratch copies. `W26.verify` explicitly forbids the real corpus.

---

## 9. Explicitly out of scope

- **Rebuilding the owner's Spotlight index.** Independent of this plan (and a system-level fix the owner
  may still want): `sudo killall mdbulkimport; sudo mdutil -E /System/Volumes/Data`. Note the Data
  volume is **90% full (98 GB free of 926 GB)**, which plausibly contributed to the wedge. This plan's
  whole point is that the app must not care.
- **Full-text search changes.** `ContentIndex`/`ContentIndexer` already work without Spotlight; they only
  need their input list re-sourced (automatic once `ArchiveLibrary` changes) and one comment corrected.
- **A file-level "watch the whole Mac" mode.** The `NSMetadataQueryLocalComputerScope` branch
  (`ArchiveLibrary.swift:78`) is dead "future use" code — delete it rather than reimplement it. A
  whole-disk walk is not something this app should do.
- **Emulating Spotlight's home-wide tag vocabulary** — see §4.4.3; explicitly declined.
- **Migration or back-compat for any on-disk format.** Per the no-production-material directive; bump
  the DB filename and move on.

## 10. Docs that move with the code (same commit, per convention)

The audited list, so `W26.docs` is a checklist rather than a hunt:

- `ArchiveReader/CLAUDE.md:106` (*"Search: Spotlight (`mdfind`/`NSMetadataQuery`)…"*), its §Verified Facts
  Spotlight line, the Implementation Map, **and `:319` + `:429-431`** (the *"behind a `FileAccessProvider`
  abstraction: switching posture is an entitlement/config change, not …"* claim — false once whole-Mac
  becomes "walk N granted roots", which is new code).
- `ArchiveReader/POTENTIAL_FEATURES.md:17-19` — claims whole-Mac search is a one-line entitlement flip.
  Deleting the `NSMetadataQueryLocalComputerScope` branch makes that untrue; restate the cost honestly.
- `ArchiveReader/Core/ArchiveFile.swift:5-7` and `:38-46` — the doc encodes the *"from the
  Spotlight-provided tag array — the fast path, no per-file I/O"* invariant **twice**, and `liveIdentity()`
  exists specifically to preserve it (identity capture is deliberately lazy so it never runs at bulk
  discovery). The premise is abandoned; **keeping identity capture lazy is still right** (a stale identity
  is worse than a fresh one) — say so explicitly rather than leaving the contradiction.
- Four source comments citing *"the Spotlight echo"* as the rationale for change-signature gating and the
  inline-edit re-render guards: `Core/LibraryChangeSignature.swift:5`, `NavigationModel.swift:620-621`
  and `:1015`. **Every mechanism stays correct** (a re-walk also emits identically-valued snapshots) —
  only the rationale is falsified. Retarget the wording to *"a repeat emission from a re-walk"* so a
  reviewer does not read them as dead code.
- `NavigationWindowView.swift:157-158` — overlay doc naming Spotlight.
- `Tests/ArchiveReaderUITests/FixtureUITestCase.swift:62-64` and `NavigationUITests.swift:46-48` (§5.9/5.10).
- `ArchiveProcessor/CLAUDE.md` — vocabulary narrowing (§4.4.3); `ArchiveProcessor/TESTING.md:72` — flag the
  dubious Spotlight-contention premise (§ Site 8) without acting on it.
- `SPEC/tag-format.md` — how tags are *read*. The tag vocabulary itself is unchanged, so **this is not a
  shared-contract change** and does not trip the both-apps-together rule.
- `README.md`, `AGENTS.md`, `KNOWN_ISSUES.md`; `SUITE_TODO.md` → `SUITE_TODO_DONE.md` as items ship.

**A side benefit worth recording:** `ops/gui/tart-lib.sh:74` runs `make-gui-fixture.sh` **inside a guest
VM**, where a cold Spotlight index is the least reliable thing in the environment. `W26.scripts` removes
that dependency from the GUI lane entirely — no `tart-lib.sh` edit required.

**Delete this plan when `W26.verify` passes.**
