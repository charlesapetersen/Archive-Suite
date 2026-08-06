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

**Refined by a second, independent benchmark pass the same day** (12 cores, same real corpus). The API
choice for the *walk* matters far more than parallelism does:

| Stage | Measured | At 150k |
|---|---|---|
| Walk via **`getattrlistbulk`** (mtime+ctime+size+ino), 123,028 files | **0.348 s** (2.8 µs/file) | ~0.42 s warm |
| Walk via `FileManager.enumerator` (the figure in the table above) | 10.15 s | ~12.4 s |
| Tag read, `TagReading.read` serial | 64.5 µs/file | ~9.7 s |
| Tag read, `TagReading.read` in a `TaskGroup` (3.2× win) | ~20 µs/file | ~3.0 s |
| **Whole Spotlight-free discovery** | — | **~4.2 s warm / ~6.7 s cold** |
| Warm start: load + rebuild 150,000 persisted rows | 0.61–0.64 s | (4.3 µs/row) |

Two notes on method: parallelism is **not** the main lever, and dropping to raw `getxattr` + binary-plist
decode does **not** pay off as folklore suggests (2× serially, but it loses to `TaskGroup`-parallelised
`resourceValues` and forfeits the audited path) — so **use `TagReading.read` as the read primitive** and get
the win from concurrency width. Cold figures come from an untouched 162,945-file sibling tree, since a true
cold cache needs `sudo purge`.

**And the "too slow at 150k" objection is dead by a factor of ~460×:** the PDF content extraction the app
**already performs unconditionally** over the whole corpus costs **9,706 µs/file** (measured: PDFKit open +
page-2 text over 300 real multi-page OCR'd PDFs), against **21 µs/file** for the entire discovery walk and
tag read. No work item needs a "is a full walk affordable?" spike, and **no design may reintroduce Spotlight
as a performance optimisation.**

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

✅ **SHIPPED 2026-08-05 (`W26.walk1`: `b3efb16` → `025d126` → the trackers commit).** Two deliberate
divergences from the sketch below, both forced by constraints this plan records elsewhere:

- **Not a `TaskGroup`.** §4a.4/§7a.10 require the dataless I/O policy on *every* thread that touches a
  corpus file, and it is thread-scoped while the cooperative pool reuses threads. The pass is therefore a
  **synchronous single-threaded walk** — which §2 already measured at 10.15 s for 123k — with
  `scanOnDedicatedThread`/`scanDetached` for off-main callers. Parallelising it later means giving each
  worker the policy, not swapping in a `TaskGroup`.
- **Emits `[CorpusEntry]`, not `[ArchiveFile]`.** `ArchiveFile` is the Reader's row model (it carries
  `fileType`, a display string); ArchiveCore vends the raw material (`tagNames`, `labelNumber`,
  `contentModified`, `contentTypeIdentifier`, `isDataless`) and `W26.walk2` builds the row. The shape is
  otherwise 1:1 — `LibraryDiscoveryTests` pins that the rows built from it equal the shipped loader's.

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

⚠️ **`isGathering: Bool` is not expressive enough and must be replaced outright.** Today the overlay is
binary: either `isGathering` — which renders a full-screen spinner that **blanks the list**
(`NavigationWindowView.swift:163-170`) — or settled. A warm start has *real rows on screen* while
revalidating, so a boolean would either blank them or lie that the view is settled.

```swift
enum LibraryPhase {
    case noRoot
    case firstScan(done: Int, seen: Int)     // full-screen spinner is correct ONLY here
    case revalidating(asOf: Date)            // rows stay on screen; subtle affordance only
    case settled(asOf: Date)
    case degraded(Failure, asOf: Date?)
}
```

`Failure` mirrors `ContentIndexer.Failure`'s proven shape (`ContentIndexer.swift:19-44`, `:456-473`) —
`Equatable + Sendable`, a `message` for the status bar, a `detail` for the tooltip, and a **pure
`Outcome -> Failure?` mapping so health is decided in one place and is unit-testable**:
`.indexUnavailable(detail:)`, `.rootUnreadable(path:errno:)`, `.scanIncomplete(dirErrors:)`.

**The anti-pattern fix is one guard, and it needs a denominator.** *"No Read/Unread-tagged PDFs were found
in this folder"* is currently rendered on the sole condition that the list is empty — **it has no idea
whether anything was successfully scanned.** New rule:

> That copy may appear **only** when the last scan's `outcome = complete` **AND** `dir_errors = 0`
> **AND** `files_seen > 0` — and it must then **state the denominator**:
> *"Scanned 1,849 files in this folder; none carry a Read or Unread tag."*

Anything else is `.degraded`, which says what failed and what to do, and **never** implies anything about
the corpus. That single guard is what makes today's incident unrepresentable.

**Copy the generation-token discipline verbatim** from `ContentIndexer` (`:176-179`): every scan launch
bumps a `scanGeneration`, and every progress / batch / finish hop is `guard gen == scanGeneration`, so a
root switch mid-scan cannot let stale batches publish over the new root.

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
   emulate Spotlight — slow, invasive, and it would trip TCC prompts across unrelated directories.
   ⚠️ **Note the corrected premise:** the **Processor is UNSANDBOXED** (its entitlements carry no
   `app-sandbox` key at all), so a home-wide walk is *legally available* to it in a way it is not to the
   Reader. The argument against it is therefore cost and invasiveness, **not** capability — say that
   honestly rather than implying it is impossible, or someone will "fix" it later.

⚠️ **REVISED 2026-08-04 — prefer keeping the scope, not narrowing it.** Two independent measurements of the
actual vocabulary changed this recommendation: **~7,051 distinct tag names** exist under `$HOME` (excluding
`~/Library`), **~157,401 tagged files**, and **~99% of them live under `~/Desktop`**. So a walk of
**`~/Desktop`** reproduces essentially all of Spotlight's answer at a cost this plan has already shown is
trivial — no narrowing required, and no `$HOME` sweep either. Prefer that over option 3's capability
reduction; keep options 1–2 (persisted, monotonic vocabulary) as the *storage* design.

**The concrete deliverable that comes with it:** the Processor is unsandboxed but its `Info.plist` carries
only `NSLocalNetworkUsageDescription` (`:29`), so reading `~/Desktop` needs an
**`NSDesktopFolderUsageDescription`** string — a real, user-visible TCC prompt that must be worded honestly.
That is the one honest cost of keeping the scope, and it belongs in `W26.vocab`.

**If the scope IS narrowed anyway, it is a genuine capability reduction, not a like-for-like swap** — be
explicit about it in the commit.
Also: **eight consumer sites** depend on `SystemTagsProvider`'s API surface, and the `isReady` →
*"building tag suggestions…"* UI state exists **solely because the Spotlight gather was slow**. With a
persisted vocabulary, suggestions are available instantly on launch, so that state can likely be retired —
check all eight consumers before removing it.

### 4.5 `CorpusWatcher` — new (W26.fsev), FSEvents live updates — ✅ SHIPPED 2026-08-05

> ⚠️ **Amended 2026-08-06 by `W26.fsev-fu1`.** "It starts the stream before the launch walk" is still the
> guarantee, but the *mechanism* changed, and the original one was a bug: `FSEventStreamCreate` `open(2)`s
> the root, and doing that synchronously on the main thread meant an unopenable root (unanswered TCC prompt,
> stalled network/cloud mount, disconnected volume) hung `NavigationModel.init()` and **the app never drew a
> window**. The start now runs on a dedicated `Thread` and the **walk** waits behind it
> (`ArchiveLibrary.passWaitingForWatcher`, gating `beginScan` and `drainWatchWork`) instead of the main
> thread waiting on the open. A 2-second `watcherStartTimeout` bounds that wait: past it, discovery proceeds
> without live events and the UI says *"Archive folder is not responding"*
> (`DiscoveryFailure.liveUpdatesStalled`); a stream that returns late is still adopted and owes exactly one
> catch-up pass. **Anything that reintroduces a synchronous `start()` on the main actor — including a lock
> inside `CorpusWatcher`, which a stuck `start()` would hold against `stop()` — reintroduces the hang.**
>
> ✅ **The walk's own deadline landed 2026-08-06 as `W26.fsev-fu2`.** `CorpusWalker`'s `opendir(3)` probe
> blocks on the same root, so a pass that has examined **zero** files after `scanStallTimeout` (5 s) now
> publishes `.degraded(.scanStalled)` — *"Archive folder has not answered"*, the list's own half of what
> `liveUpdatesStalled` says about the refresh channel. **Reported, not cancelled**: a blocked `opendir`
> cannot be interrupted, so the walk keeps running and either its first examined file or its completion
> withdraws the verdict, through the generation token that already existed. It is deliberately **not** routed
> through `DiscoveryHealth` and grants no pruning and no authoritative absence — §7a.4's gate is unchanged,
> because `.degraded` is not settled. This is also what makes §5.6's forced decision (a SYNCHRONOUS walker)
> safe to keep: the blocking call is still blocking, but it can no longer silence the UI.

The shipped implementation is `ArchiveReader/.../Search/CorpusWatcher.swift` plus the bounded merge/scheduler
in `ArchiveLibrary`. It starts the stream before the launch walk (so there is no scan→watch gap), reads every
retained path through `ArchiveCore.CorpusWalker.inspect`, and preserves the launch walk's hidden/package
exclusions. Exact paths are one stat/tag read; coalesced directories get subtree passes; recovery sentinels
get one bounded root pass.

**Verified empirically 2026-08-04** (scratch dir, `kFSEventStreamCreateFlagFileEvents`): a pure Finder
tag write — `setResourceValue(_:forKey:.tagNamesKey)`, changing **no file bytes** — *does* produce an
event, flagged `ItemXattrMod | ItemInodeMetaMod | ItemModified`. A raw `setxattr` of a non-Finder xattr
fires too. **So a watcher can see third-party tag edits; polling is not required.**

**Critical gotcha, also measured:** FSEvents **unions flags across its coalescing window**. The
byte-free tag write above *also* reported `ItemRenamed`, which never happened. Therefore:

> Treat every event as **"this path may have changed — re-`stat` and re-read its tags"**, never as
> "this specific thing happened." Flags may be used to *skip* work, never to *decide* semantics.

- **Coalescing and drop-to-subtree are the COMMON path at this corpus's scale, not a rare edge.** Measured:
  **12,060 xattr tag writes in 0.30 s produced only 1,088 delivered events in 37 batches.** A bulk
  Read/Unread operation over a few thousand files *will* collapse into subtree re-walk requests, so the
  re-walk path is mainline code that must be efficient — not an error handler. Apple states explicitly that
  flags are **hints, not a replayable log**; observed one event coalescing a file's creation *and* its
  subsequent tag write.
- Recovery flags, all reducible to two primitives — *"re-read these paths"* and *"re-walk this subtree"*:
  `MustScanSubDirs` (0x1) → re-walk that subtree; `UserDropped` (0x2) / `KernelDropped` (0x4) → **full
  monitored-root pass** (the SDK permits sentinel path `/`, so stream-wide flags are reduced before path containment);
  `RootChanged` → re-resolve the bookmark + re-walk; `EventIdsWrapped`/`HistoryDone` → full re-walk;
  `Unmount`/`Mount` → stop/restart.
- **Own-write detection has a proper API — use it instead of a side channel.**
  `kFSEventStreamCreateFlagMarkSelf` tags the app's own writes with
  `kFSEventStreamEventFlagOwnEvent` (0x80000); verified that a *different* process making the
  byte-identical `setResourceValue` call is **not** so tagged. This is more reliable than `TagWriter`
  publishing a URL list, and it distinguishes our write from Finder's even when the values match.
- **`FSEventStreamSetDispatchQueue` is required — run-loop scheduling is deprecated as of macOS 13.**
  Teardown order is mandated by the header: `Stop`, then **`Invalidate` while the stream is still
  scheduled**, then `Release`. Getting this wrong is a crash, not a warning.
- **No event-ID persistence in v1.** Launch starts the stream at `kFSEventStreamEventIdSinceNow` and then
  performs a complete walk (that order, per the amendment above — the walk is what waits). Non-ascending IDs
  and FullHistory values below the request make a naïve persisted high-water mark a silent-loss mechanism.
  A SinceNow stream that starts *after* discovery — a recovery, or a start whose open outran its deadline —
  is followed by one catch-up walk so the unwatched interval cannot disappear.
  *(A captured `FSEventsGetCurrentEventId()` would remove the ordering constraint outright by making the
  replay authoritative, which `W26.fsev-fu1` considered and did not take: it makes
  `kFSEventStreamEventFlagHistoryDone` arrive for the first time, and that flag is currently reduced to a
  full rescan — so it would trade a bounded wait for a whole-corpus re-walk on every launch plus a rewrite of
  a 20-test reducer. Revisit only with a correctness argument.)*
- **`FSEventStreamFlushSync` gives tests a deterministic synchronisation point** — which is precisely the
  reason the fixture scripts currently poll `mdfind`, so it is what makes `W26.scripts` possible.
- **`kqueue`/`DispatchSource.makeFileSystemObjectSource` is disqualified at this scale** (`EVFILT_VNODE`
  needs one open file descriptor per watched file — 123k fds), and `NSFilePresenter` is disqualified on
  semantics. FSEvents is the only viable choice; do not re-litigate it.
- **Verify, don't assume, that the root has a working event channel.** A successful
  `FSEventStreamStart` on the chosen path is the direct capability check; device-UUID probes only answer
  whether *historical* events are available and legitimately return nil on read-only/firmlink arrangements.
  Start failure surfaces *"Live archive updates unavailable"*. There is no periodic timer: activation retries
  and, while still unavailable, re-walks once the last clean settle is over five minutes old; ⌘⌥R is immediate.
- Sandbox: the stream is created on the **security-scoped root**, with
  `start/stopAccessingSecurityScopedResource` balanced across the *stream's whole lifetime*, not per
  read. Because exact/subtree work is asynchronous, each worker also owns a separate balanced operation scope
  and cancellation token; stream teardown or root replacement cancels that work before its result can merge.
  Directory symlinks are classified as non-regular and are never traversed, so a watched subtree cannot escape
  the granted root. Entitlements already present (`app-sandbox`, `files.user-selected.read-only`,
  app-scoped bookmarks) are sufficient — POSIX/FSEvents access to a user-granted root works even where
  Spotlight query visibility does not (the very asymmetry documented at `ArchiveLibrary.swift:62-65`).
- Atomic writes create temp siblings (measured: `a.txt.sb-858602c2-RXb79N`) — only the exact measured
  `.sb-[8 hex]-[6 alnum]` suffix is ignored; an ordinary filename containing `.sb-` remains visible.
- **Self-write suppression:** the stream uses `MarkSelf` and drops `OwnEvent`; there is no `TagWriter` URL
  side channel. Recovery flags override OwnEvent because a unioned batch can also contain external work.

### 4.6 `LibraryIndex` — new (W26.idx), instant warm start — ✅ SHIPPED 2026-08-05

**Shipped implementation.** `Search/LibraryIndex.swift` is the separate system-SQLite actor at
`library-index-v1.sqlite3`. It persists every readable regular file, raw tags, label, tracked/verified,
dataless state and the fresh `(mtime, ctime, size, inode)` tuple under composite byte-exact
`(root path, marker GUID, file path)` identity. Warm tracked rows publish with cache provenance, then
`LibraryScan.revalidatedPass` fingerprints the root on a dedicated thread and reads tags only for
new/changed/unverified paths. Scan provenance makes partial/canceled work non-authoritative; absence applies
only on a clean pass. SQLite decode/encode/write work polls cancellation every 500 rows. Cache rows are
freshly re-inspected before any mutation, corpus rename is conditional, dataless rows never reach PDF open,
and the FSEvents path remains byte-exact through coalescing/containment/inspection. This is clean-slate v1:
no migration, dual reader or legacy selection-state fallback.

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
-- Store the RAW tag array only. DocumentTags.parse(raw:labelNumber:) is the single parse authority
-- (ArchiveLibrary.swift:110-115, :205-207 both build ArchiveFile through it), so persisting derived
-- facets (read_state / priority / year) would fork that authority and let the DB disagree with the parser.
CREATE TABLE entry (
  path      TEXT NOT NULL,        -- byte-exact as the walk returned it; never NFC/NFD-normalised (§5.3)
  root_id   INTEGER NOT NULL,
  name      TEXT NOT NULL,
  ext       TEXT NOT NULL DEFAULT '',
  mtime     REAL NOT NULL,        -- content mtime: feeds ContentIndexer's extraction skip
  ctime     REAL NOT NULL,        -- LOAD-BEARING: a tag write bumps ctime ONLY (§5.12)
  size      INTEGER NOT NULL DEFAULT 0,
  ino       INTEGER NOT NULL DEFAULT 0,
  tags_raw  TEXT NOT NULL,        -- verbatim array, order preserved
  label     INTEGER,
  tracked   INTEGER NOT NULL,     -- 1 = carries Read/Unread
  verified  INTEGER NOT NULL,     -- 0 = carried over from a scan that did not complete cleanly
  is_dataless INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(root_id, path)
);
CREATE INDEX entry_root ON entry(root_id, tracked);

-- Scan provenance. THIS is what makes honest status survive a relaunch: ContentIndexer's Failure is
-- @Published in memory only (ContentIndexer.swift:19-47) and is lost on quit, so a warm start currently
-- cannot tell "these 1,849 rows are correct" from "these are what a half-failed scan managed to see".
CREATE TABLE scan (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  root_id    INTEGER NOT NULL,
  started    REAL NOT NULL,
  finished   REAL,                -- NULL = did not complete (crash / cancel / quit mid-scan)
  dirs_seen  INTEGER NOT NULL DEFAULT 0,
  files_seen INTEGER NOT NULL DEFAULT 0,
  dir_errors INTEGER NOT NULL DEFAULT 0,   -- from the errorHandler (§4a.2) — gates the empty state
  outcome    TEXT                          -- complete | partial | failed
);
```

**Name it `library-index-v1.sqlite3`** and bump to `-v2` for any schema change. The filename-bump
convention is not stylistic: **the write-surface lint bans file-delete APIs app-wide, so the app literally
cannot remove a superseded DB** — bumping the name is the only available "migration". No versioned readers,
no migration code (2026-08-01 no-migration directive).

**Shipped: persist ALL regular files, not just tagged ones** (`tracked` distinguishes them). Measured cost on
the real corpus was **60 MB and 1.3× the rows** — cheap, and it means an untagged file that *becomes* tagged
is a changed-row read rather than absent from the cache universe.

**No back-pressure machinery is needed.** Because the walk is ~10× cheaper than the tag read it feeds, two
sequential phases are the simplest correct design (proven: two complete 123,028-entry fingerprint
dictionaries built and diffed in one process): (A) walk on the policy-guarded dedicated `Thread` →
`[Fingerprint]`; (B) one `SELECT path,mtime,ctime,size,ino FROM entry WHERE root_id=?` → diff map;
(C) read tags only for the diff. **No `AsyncStream`, no bounded continuation, no semaphore.** Batch upserts
at 500 rows purely to match `ContentIndex` — measured spread from 500→2000 is 15%, i.e. not a real lever.

- **The filesystem and its xattrs remain the sole source of truth.** This DB is a disposable cache;
  deleting it loses nothing (same guarantee `ContentIndex` already documents). It is stored **outside
  the corpus**, in app support — never written into an archive folder.
- **Warm start:** show persisted rows immediately, then revalidate in the background (`stat` each path,
  re-read tags only where mtime/**ctime**/size/inode/dataless state moved, plus a full walk to catch
  additions/removals). The user sees
  rows in milliseconds with a subtle "revalidating…" affordance rather than a 10-second spinner.
- **Removals** are applied only after the walk **completes successfully** — a cancelled or failed walk
  must never be read as "these files are gone." (`ContentIndexer` already models this hazard with its
  two-snapshot prune gates and `rootPrefix` eviction, `ContentIndexer.swift:361-420`; reuse that shape.)

---

## 4a. 🔴 The two ways the FIX reproduces the BUG — read this first

The incident was a **silent empty result** mistaken for a true negative. **Both halves of the replacement
have their own version of that failure**, and neither is hypothetical — both were measured 2026-08-04.

### 4a.1 `TagReading.read` reports "no tags" when it means "couldn't read"

⚠️ **CORRECTED 2026-08-04 by a second, more careful measurement — the first was wrong (see §4a.3).** The
trap is real but far narrower than originally written, and the difference decides where the fix belongs:

| Denial shape | `resourceValues(forKeys:[.tagNamesKey,.labelNumberKey])` | Honest? |
|---|---|---|
| Parent directory unreadable (`chmod 000`) | **THROWS** `NSCocoaErrorDomain/257` | ✅ already honest |
| ACL denying `read`/`readattr`/`readextattr` | **THROWS** `NSCocoaErrorDomain/257` | ✅ already honest |
| **File itself unreadable, parent traversable** | **NO THROW → `tagNames == nil`** | 🔴 **the whole bug** |
| Parent `0o111` (traverse-only, not listable) | reads fine, full tags | ✅ correct |

So `TagReading.read` **already** returns `.failure` for both *tree-level* denials. The single leak is the
third row: the call succeeds, `tagNames` is `nil`, and `TagReading.swift:34`'s `values.tagNames ?? []`
reports *"confirmed no tags"* about a file carrying `["Unread", …]`. In exactly that case
`access(path, R_OK) == -1` and `getxattr(...) == -1` with `EACCES(13)`, so the condition is cheaply
detectable.

**Required, and precisely scoped:** probe **only on the `tagNames == nil` branch**. A blanket pre-check on
every file is wasted work at 150k and was this plan's earlier, wrong prescription; adding a `.denied` case to
`TagReadResult` has the largest blast radius of the three options (§9 non-goals). `CorpusWalker` must still
surface three outcomes — *has tags*, *verified none*, *could not read* — with the third feeding `.degraded`,
never an absence.

🔴 **THE PROBE MUST BE `getxattr`, NOT `access(R_OK)` — verified 2026-08-04.** An ACE denying **only**
`readextattr` (narrower than the ACL row in the table above, which also denies `read`/`readattr` and
therefore throws) produces:

```
resourceValues: no throw, tagNames=nil
access(R_OK) = 0        ← the discriminator this plan first specified: FAILS to detect it
getxattr     = -1 errno=13 (EACCES)   ← detects it
```

`access(R_OK)` tests readability of the **file data**, not of its extended attributes, so it passes cleanly
while the xattr is unreadable — and the wave's first item would then coerce a tagged file to "no tags"
exactly as before. **Use:**

```c
getxattr(path, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, 0)
```

and return `.failure` when it returns `-1` with **any errno other than `ENOATTR` (93)**. This is the same
errno rule §7a.3 imposes on the optional size-0 pre-filter — one rule, applied in both places.

🔴 **TWO CORRECTIONS, made while SHIPPING `W26.deny` (2026-08-05, `ad86cce`). Both were wrong above, both
are load-bearing, and a later item that copies the original wording reintroduces the bug this wave exists
to fix. The shipped `TagXattr.inspect` is the reference implementation — read it, not this section.**

1. **The final argument is `0`, NOT `XATTR_NOFOLLOW`** (corrected in the snippet above). `resourceValues`
   **follows** symlinks — measured: through a symlink to a tagged file it reports the *target's* tags. A
   `XATTR_NOFOLLOW` probe therefore answers about the **link**, which carries no attribute of its own, and
   returns `ENOATTR` — "confirmed no tags" — for a **denied target**. That is precisely the coercion §4a.1b
   describes, displaced one indirection. Pinned by `TagDenialTests.testSymlinkToDeniedTargetIsAFailure`,
   which is red under `XATTR_NOFOLLOW` and green under `0`.
2. **"`ENOATTR`, or a returned size of `0`, is the only honest 'verified no tags'" was too strict and would
   have mis-flagged real files.** Removing a file's tags leaves a **42-byte empty-array plist** behind, and
   macOS reports `tagNames == nil` for it. A census of the owner's corpus (read-only, 2026-08-05, 123,302
   regular files, 30.8 s, 0 walk errors) found **51 files in exactly that state** — the strict rule reports
   every one of them as unreadable. The shipped rule: a *readable* attribute that decodes to an **empty
   array** is a confirmed "no tags"; a non-empty array macOS did not report as tags, a non-array plist, or
   undecodable bytes are all `.unreadable`.

For completeness, that same census is the current exposure figure, and it supersedes the 123,028-file one
quoted elsewhere in this plan: **21,311 ENOATTR · 101,940 tagged · 51 empty-array residue · 0 denied ·
0 undecodable · 0 non-array.** Zero denied means `W26.deny` changed the answer for **no file on disk
today** — it is a guard against modes and ACLs arriving from network copies, restores and extractions.

### 4a.1b 🔴 THE SAME COERCION IS IN THE AUDITED WRITE PATH — and it destroys tags

**This is the most serious finding in the wave, it has nothing to do with Spotlight, and no design agent
found it. `TagWrite.swift:252-261`:**

```swift
// §2/§3 fresh read inside coordination; a read FAILURE aborts (never treated as empty).
do {
    let rv = try writeURL.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey])
    before = rv.tagNames ?? []          // ← the comment's promise is broken right here
    beforeLabel = rv.labelNumber
} catch { throw TagWriteError.unreadable(error.localizedDescription) }
```

The comment promises *"a read FAILURE aborts (never treated as empty)"* — but in the §4a.1 third-row case
**the read does not throw**, so the `catch` never fires and `before` becomes `[]` for a file that carries
real tags. `transform([], nil)` then computes a delta against nothing, and line 271 writes it.

**Reproduced twice on scratch files:**

```
mode 0o200 (write-only, no read)      read: no-throw, before=[]   write: SUCCEEDED
    tags on disk: ["Unread","Subj","P9"] → ["Read"]     *** Subj and P9 destroyed ***
ACL deny readextattr (perms 0644)     read: no-throw, before=[]   write: SUCCEEDED
    tags on disk: ["Unread","Subj","P9"] → ["Read"]     *** destroyed ***
mode 0o000 (no read, no write)        read: no-throw, before=[]   write: failed (-5000)
    tags preserved — but the reported `.before` is still wrong, so the UNDO delta is wrong
```

This is a direct violation of the Core Directive (*"MUST NOT mangle, drop, or lose any tag
unintentionally"*) reachable on any file whose xattrs are unreadable but writable, and the `0o000` row shows
that even when the write fails the recorded `before`/inverse is corrupt.

**Exposure on the real corpus today: ZERO — measured, not assumed.** A read-only scan of all **123,028**
files found `owner lacks read bit: 0`, `getxattr EACCES: 0`. (51 files matched a nil-tags-with-xattr-present
pattern; all inspected samples decode to a literal **empty array** with normal `-rw-r--r--` perms — benign
residue of removed tags, not denial.) So this is a **latent** bug, not an active fire — but modes and ACLs
arrive from network copies, restores and archive extractions, and the corpus is irreplaceable.

**Therefore `W26.deny` is the wave's first item, Tier-2, and it fixes BOTH call sites** — `TagReading.swift:34`
and `TagWrite.swift:257` — routing the writer's §2/§3 fresh read through the corrected primitive so its
comment becomes true. It is independent of everything else here and must not wait behind the walker.

### 4a.2 `FileManager.enumerator` silently skips what it cannot read

`FileManager.enumerator(at:includingPropertiesForKeys:options:)` — **the overload without an
`errorHandler:`** — silently skips unreadable directories and keeps going. A walk over a corpus with one
permission-denied subtree returns a smaller set with **no error and no signal**. The already-working DEBUG
fixture loader uses exactly this overload (`ArchiveLibrary.swift:97-99`), so copying it verbatim inherits
the flaw.

**Required:** use the `errorHandler:` variant, count and surface every skipped path, and treat a non-empty
skip list as a degraded walk (`.failed` or a distinct `.partial`). **The walk must be honest about what it
could not see** — that single rule is what this whole wave is buying.

### 4a.3 A cautionary note on how this was nearly got wrong — reuse a `URL` and you measure nothing

The first measurement of §4a.1 concluded that **parent-directory** denial produced the silent `nil`. That was
**wrong**, and the reason is the trap this repo already documents: the test probed a control case on a `URL`
value, then sealed the parent and probed **the same `URL` object again**. `URL.resourceValues` **caches on
the backing `NSURL`**, so the second answer was served from cache. The corrected run in §4a.1 builds a
**fresh `URL` from the path string immediately before every probe** and corroborates each result at the
syscall layer (`access(R_OK)`, `getxattr` + `errno`), which is what surfaced the true third-row case.

Two consequences for the implementer:

1. **Any test of freshness, denial, or tag change must construct a new `URL` per probe** (or use `stat(2)` /
   `getxattr` directly). A test that reuses a `URL` value will pass while asserting nothing — and the failure
   is invisible, because the cached value is a *plausible* value.
2. `TagReading.read` itself is **not** sloppy: it separates `.success` from `.failure` and carries a CRITICAL
   comment forbidding this coercion (`TagReading.swift:5-9`). Its one bad line is the `:32-33` comment
   asserting *"a nil `tagNames` legitimately means 'no tags' (confirmed empty)"*, which is false in exactly
   the third-row case — and `:34` then acts on it.

This is the same hazard recorded as `url-resourcevalues-caches` (measured W23.m11-fu). It cost one wrong
conclusion in this very plan; treat §5.1 as load-bearing, not decorative.

### 4a.4 🔴 And it reproduces on cloud storage — with a hang, not just a lie

Also reproduced 2026-08-04, against a **real** `~/Library/CloudStorage/GoogleDrive-…` directory (Google
Drive.app installed but not signed in): the no-`errorHandler` enumerator returns the **same silent empty
result**, and `getattrlistbulk` there fails with **`errno 60` (Operation timed out) after 0.54 s**.

**The mitigation is proven and it is one call:**
`setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)`
returns 0 and turns that timeout into a clean, immediate error instead of a stall.

⚠️ **But the policy is PER-THREAD, and Swift's cooperative pool reuses threads across unrelated tasks.**
Setting it inside a `Task.detached` body therefore both (a) fails to guarantee it covers the whole walk and
(b) **leaks the policy into unrelated work that happens to land on that thread.** So: **the scan must run
on a dedicated `Thread`** that sets the policy first. This is a hard requirement on `W26.walk1`, not an
optimisation.

✅ **MET (`b3efb16`).** `CorpusWalker.scanOnDedicatedThread` is a real `Thread` (named
`ArchiveCore.CorpusWalker`, asserted by a test) rather than `Task.detached`, and
`withDatalessMaterializationDisabled` sets the policy on it and **restores the prior value** afterwards, so
nothing leaks even if a caller runs `scan` on a thread it does not own. `scan` itself is synchronous, so an
`await` mid-pass cannot silently break the coverage. Note the second reason for the dedicated thread, which
this section does not give: a ~10 s blocking walk would starve the cooperative pool for its duration.

This does not contradict §2 — the owner's corpus is genuinely local and needs no placeholder handling. It
means the **walker is a general component** and a user can point a root anywhere, so it must fail fast and
loudly rather than hang. (Open question for the owner: `IOPOL_SCOPE_PROCESS` would also stop
`PDFTextExtractor`/`ContentIndexer` silently downloading dataless files — broader, but a bigger behavioural
change. Flagged, not decided.)

> **The design principle, stated once:** every layer must be able to say *"I don't know"* separately from
> *"there is nothing."* Spotlight could not, which is why the app lied. Do not rebuild that — in the
> walker, in `TagReading`, or in the index.

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
   ✅ **HALF DONE (`W26.walk1`)**: `ArchiveReaderTests/LibraryDiscoveryTests.swift` is the first test ever to
   construct `ArchiveLibrary` (Reader 276 → 279). It pins loader ≡ walker equivalence on a readable tree, and
   their one required divergence on an unreadable file. **`ArchiveLibraryOverrideTests`' 8 cases remain
   `W26.walk2`'s to delete** — and two of the three new cases go with them, since they compare against
   `loadFixtureSynchronously` and the compiler retires them.
6. ⚠️ **SYNC-VS-ASYNC IS THE FIRST DECISION, AND IT IS FORCED BY EXISTING TESTS.** Two test files already
   drive the DEBUG walker *as the production path* and assert **synchronously** that a freshly-tagged
   scratch PDF is in `model.library.files` immediately after `NavigationModel()` returns:
   `DocumentPageLinkTests.swift:229-233` + `:239-240` (*"precondition: the scratch PDF is discoverable"*)
   and `RootMarkerStateTests.swift:143`. **If the new walker is async, both break.** These are
   simultaneously the plan's free head start and its hardest constraint. Decide the API shape **before**
   writing the walker: either keep a synchronous settle path for tests, or adopt Notes'
   `awaitSettled()` seam (`NotesModel.swift:286-300`) and convert both tests. Do not discover this at
   the build gate.
   ✅ **DECIDED (`W26.walk1`, `b3efb16`): SYNCHRONOUS.** `CorpusWalker.scan` is a plain function, so both test
   files keep working unchanged and no conversion is needed. Two independent reasons, not only the tests: the
   thread-scoped dataless policy (§4a.4) is sound only if no `await` can move the pass to another thread, and
   a caller who wants it off-main gets a dedicated `Thread` (`scanOnDedicatedThread`/`scanDetached`) rather
   than a cooperative-pool task.
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
11. 🔴 **`pruneIfSettled` computes `indexedUnderRoot.subtracting(currentPaths)` — a streaming discovery
    source breaks it outright.** With a partial `currentPaths`, *everything not yet walked looks deleted*.
    Its safety rests on five gates and **two are broken by a naive incremental/streaming source**. This is
    the sharpened form of §4.2's `isGathering` warning: publishing batches progressively (which the plan
    wants, for a responsive UI) is exactly what endangers it. **Either** prune only from a *complete*
    snapshot, **or** gate pruning on a walk-completion generation counter — decide in `W26.walk2`, before
    `W26.idx` builds on it.
12. 🔴 **A Finder tag write does not change mtime — it changes ctime.** `ContentIndexer`'s incremental skip
    is keyed on **content** mtime, so a tag-only edit is correctly *not* a re-extraction trigger — but it
    also means **mtime cannot be used to detect a tag change.** The walker must vend
    `.contentModificationDateKey` for the content-index skip (not ctime, or every tag edit would force a
    full re-OCR-extraction of the corpus) **and** detect tag changes by comparing the tag array itself (or
    ctime) separately. Conflating the two breaks either freshness or performance.
13. **The absence rule INVERTS — and this is the item most likely to lose data if rushed.**
    `ContentIndexer.swift:280-284`'s two-consecutive-emission gate exists to close *"Spotlight's transient-drop
    window"*. A deterministic walk has **no** transient drop — so the old justification evaporates — but it
    acquires a **strictly worse** hazard the old gate cannot see: a scan that ends early (permission error,
    cancel, quit, unmounted volume) yields a *legitimately complete-looking* short list, and every unseen
    row looks deleted. Replace it with a three-tier rule keyed on scan provenance:
    1. `outcome != complete` **or** `dir_errors > 0` → **absence is not actionable at all.** Keep unseen
       rows and mark them `verified = 0`. The files may be perfect and simply unreachable — exactly the
       incident, one layer down.
    2. `outcome = complete` and `dir_errors = 0` → absence is real; apply it.
    3. Retain a confirmation count across *clean* scans for the FSEvents-coalescing case (§4.5), since a
       dropped-to-subtree re-walk can still momentarily under-report.
    **Do not delete the gate and do not keep it as-is** — re-derive it from the `scan` table.
14. **Bookmark resolution success is not proof of readability.** Resolving the bookmark and getting `true`
    from `startAccessingSecurityScopedResource` does **not** mean the root can be read. The Reader's
    existing lifetime shape is already correct for a long-lived walk + watch (one process-lifetime
    `startAccessing`, balanced by one `stopAccessing`), so the sandbox side needs no redesign — but adopt a
    **combined probe** (resolve + start + an actual test read) before declaring a root healthy, or
    `.failed` will never fire when it should.
15. **Entitlement correction:** the Reader's production entitlements grant user-selected **read-write**, not
    read-only. That does not license any write — the Core Directive and the write-surface lint (§5.7) are
    what constrain it — but do not cite "read-only entitlement" as a safety argument, because it is false.
16. 🔴 **Changing the mtime SOURCE silently triggers a full re-extraction of the whole corpus.** Verified:
    `ContentIndexer.swift:112` computes `f.contentModified?.timeIntervalSince1970 ?? 0` and `:114` decides
    work by **exact double inequality** (`stored != mtime`). Today `contentModified` comes from Spotlight's
    `NSMetadataItemFSContentChangeDateKey` (`ArchiveLibrary.swift:196`); after the swap it comes from
    `.contentModificationDateKey`. **If those two doubles differ by even one representable bit, every file
    re-extracts.** Cost, using this plan's own measurement (9,706 µs/file × 102,478 PDFs):
    **≈17 minutes of PDF text extraction**, once, in the background.
    **Decide this deliberately in `W26.walk2` rather than discovering it:** (a) accept the one-time
    re-extraction — simple, self-healing, and the index is explicitly disposable; or (b) compare with a
    tolerance — which risks *masking real changes* and is worse. **Recommend (a), and say so in the commit**
    so the post-deploy CPU burst is expected rather than alarming. Do **not** bump `content-index-v2` → `v3`:
    that forces the same re-extraction *and* strands a DB the app cannot delete (§5.7).
17. **Excluded folders must stay a POST-discovery filter — do not skip them during the walk.** Verified in
    `NavigationModel.swift:636-650`: exclusion is applied *after* discovery by path prefix to produce
    `filesToIndex`, and `pruneIfSettled` is then called with that **filtered** set against the **whole**
    `rootPrefix` — the comment states the intent outright: *"Uses `filesToIndex` (excludes user-excluded
    folders) so excluded paths are eligible for pruning."* So excluded files are deliberately present in
    `library.files` (visible in the UI) but deliberately absent from the content index. A walker that skipped
    excluded directories during enumeration would drop them from the UI entirely — a silent behaviour change
    — while producing the *same* index outcome, which makes it hard to spot. **Return everything tagged; let
    `NavigationModel` do the excluding.**
18. **Do not persist an FSEvents `sinceWhen` checkpoint in v1** — this supersedes the softer "keep a
    conservative high-water mark" in §4.5. Because event IDs are **not** delivered in ascending order and
    `FullHistory` can deliver IDs *below* the one requested, "persist the last ID seen" **silently loses
    events**. In v1, resume by re-walking on launch (which is ~4 s warm anyway) and use
    `kFSEventStreamEventIdSinceNow`. Revisit only with a correctness argument, not a performance one.

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
| `W26.deny` | ✅ **SHIPPED `ad86cce`** — read coercion fixed in BOTH `TagReading.swift` and `TagWrite.swift`; `TagXattr.inspect` is the primitive later items must reuse | S | med | **2** | none | — |
| `W26.lint` | ✅ **SHIPPED `1460125`** — both trees linted, `(file, exact line)` allowances, 9-check self-test; rule 1 had been passing VACUOUSLY. Nothing invokes it → `W26.lint-fu` | S | low | 1 | none | — |
| `W26.walk1` | ✅ **SHIPPED `003ca59`** — `CorpusWalker` in ArchiveCore + first-ever discovery test | M | low | 1 | none | `W26.deny`, `W26.lint` |
| `W26.walk2` | ✅ **SHIPPED through `6f5d6ad` + completion commit** — Reader Release discovery uses `CorpusWalker`; `PendingWrite` deleted; honest `LibraryPhase`; hostile VM at 0/11 Spotlight-indexed green | L | med | 2 | none | `W26.walk1` |
| `W26.notsup` | ✅ **SHIPPED in completion commit** — ENOTSUP stays unreadable but gets specific Finder-tag capability guidance; mixed-mount counts preserved | S | low | 1 | none | `W26.walk2` |
| `W26.fsev` | ✅ **SHIPPED in completion commit** — FSEvents FileEvents/MarkSelf/WatchRoot; exact/subtree/full recovery; SinceNow + catch-up; one active + one queued; real external-xattr test | M | med | 2 | none | `W26.walk2` |
| `W26.idx` | ✅ **SHIPPED in completion commit** — SQLite warm start; byte-exact root/path identity; stat/ctime revalidation; honest provenance; cache-write and dataless guards | L | med | 2 | none | `W26.walk2` |
| `W26.vocab` | Processor `SystemTagsProvider` off Spotlight → persisted `TagVocabulary` | M | low | 1 | none | `W26.walk1` |
| `W26.oracle` | Processor test oracle `assert_mac.py` off `mdls` → `disk_tags()` | S | low | 1 | none | — |
| `W26.reinfect` | Rewrite the open JPEGS-index item off `NSMetadataQuery` + add its blocking edge | S | low | 1 | none | — |
| `W26.scripts` | Fixture scripts drop `mdimport`/`mdfind` polling | S | low | 1 | none | `W26.walk2` |
| `W26.docs` | Docs/SPEC stop claiming Spotlight (incl. `ArchiveReader/CLAUDE.md:106`) | S | low | 1 | none | `W26.walk2` |
| `W26.verify` | Scale + safety verification on a scratch copy; gates deleting this plan | M | med | 2 | none | `W26.fsev`, `W26.idx`, `W26.vocab`, `W26.oracle`, `W26.reinfect`, `W26.deny`, `W26.lint` |

`W26.oracle` and `W26.reinfect` are **unblocked and can go first** — neither depends on the walker.
`W26.reinfect` is deliberately early: it is cheap, and every day it is undone is a day the JPEGS item
could ship a second `NSMetadataQuery` into the codebase this wave exists to clear.

**`W26.deny` goes first and is not optional.** It is a live Core Directive violation (§4a.1b), it is
independent of Spotlight, and every later item builds on the corrected primitive. **`W26.lint` closes a
governance hole this plan itself would otherwise open:** `ArchiveReader/scripts/lint-write-surface.sh:10`
hardcodes `SRC="macOS/Sources/ArchiveReader"`, so moving discovery into `packages/ArchiveCore` moves it
**out of the Core Directive's automated enforcement**. (Note the same gap already exempts ArchiveCore's own
`TagWrite.swift` — which is precisely where §4a.1b's bug has been sitting unlinted.) Extend `SRC` to cover
`packages/ArchiveCore/Sources/ArchiveCore`, keeping the *tag-write* rule's allow-list pointed at the audited
writer.

**Per-item test gates** (an item is not done without one that would *fail* if the work were wrong):

- `W26.deny` — the reproduction from §4a.1b, as a test: a scratch file tagged `["Unread","Subj","P9"]` set to
  `mode 0o200` (and a second with an ACL denying `readextattr`), then a `TagWriter` "mark Read". **Today it
  destroys `Subj` and `P9`; after the fix the write must ABORT with `TagWriteError.unreadable`** and the tags
  must be byte-identical afterwards. Add the `0o000` variant asserting the recorded `before`/inverse is not
  `[]`. Plus a `TagReading` unit test for all four rows of §4a.1's table. ⚠️ Build every probe from a **fresh
  `URL`** (§4a.3) or the test will pass while asserting nothing.
- `W26.lint` — ✅ **MET (`1460125`).** `./ArchiveReader/scripts/lint-write-surface.sh` fails when a
  `setResourceValue` is planted in a new ArchiveCore file outside the audited writer, and passes on a clean
  tree — plus 8 more checks in `./ArchiveReader/scripts/test-lint-write-surface.sh`, all against a `mktemp`
  copy of the two trees (nothing is planted in the real repo). The gate was also run against the **old**
  script for contrast: it exits 0 on the same plants.
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

## 7a. Defects found by the adversarial stress pass — each must be closed by the named item

Two adversarial lenses (file-safety/Core-Directive; daemon-shippability) attacked this plan. Everything below
was **verified against the code before being written down**. They are ordered by severity, not by item.

### 7a.1 🔴 A persisted index turns seconds of staleness into DAYS — and one write path is unconditional

`renameTag` (`NavigationModel.swift:976-1004`) selects `library.files.filter { $0.subjects.contains(old) }`
from the **in-memory library**, then applies `TagDelta(add: [new], remove: [old])` to every file in that set.
`TagDelta.add` is documented *"skipped if already present"* — idempotent, but **never conditional on `old`
still being there**. So a file whose `old` tag was removed in Finder since the scan still receives `new`.

Scenario: the index says 4,000 files carry `Rosevelt`; the owner has since fixed 600 of them in Finder. A
rename `Rosevelt → Roosevelt` during `.revalidating` **adds `Roosevelt` to those 600** — a subject tag on
files that should not have it.

**Important framing:** this is a **pre-existing** bug (Spotlight lag or a long-closed window produce the same
staleness) — but `W26.idx` **durably amplifies it** from seconds to *days across restarts*. That makes it
this wave's responsibility.

- **Fix (`W26.idx`, with a test):** a conditional rename primitive —
  `TagWriter.renameToken(from:to:on:expecting:)` whose `transform` returns `nil` unless the **fresh** array
  still contains `old` (reusing the existing `shouldRemoveTag` matching). A no-op is the correct outcome.
- **Fix (`W26.idx`):** `ArchiveFile` gains `provenance: .disk(readAt:) | .cache(asOf:)`. Rows sourced from the
  index are **cache-provenance**, and any *bulk* operation over a cache-provenance selection must re-verify
  the selection first. Note the general case is safer than it looks — `TagWriter` recomputes against a
  **fresh** read (`TagWrite.swift:256`) and deltas are *relative*, so `mark(.read)` is correct regardless of
  what else changed. **The exposure is the stale SELECTION SET and the stale TOKEN, not the delta arithmetic.**

### 7a.2 🔴 Deleting `PendingWrite` removes the only write-vs-walk ORDERING guard

§3's justification — *"a re-walk reads the same disk through the same primitive, so it converges"* — is
**wrong about ordering**. Convergence is not sequencing.

Scenario: the owner multi-selects 2,000 `Unread` rows and marks them Read. `mark(.read)` writes them one at a
time; an FSEvents debounce expires around write #300 and a full re-walk begins, reading files #300–#2000
**while their writes are still pending**. The walk's emission can then land *after* `applyVerifiedWrites` and
publish pre-write values over verified ones.

- **Fix (`W26.walk2`, in the SAME commit as the deletion):** replace the TTL/convergence overlay with a
  strictly simpler **sequence guard** — `ArchiveLibrary` keeps
  `verifiedWrites: [URL: (after: [String], afterLabel: Int?, seq: UInt64)]` and a monotonic counter; a walk
  emission carries the generation it started at, and a row whose `verifiedWrites[url].seq` is newer than the
  emission's generation keeps the verified value. **No TTL, no timer, no convergence comparison** — this is
  ~15 lines replacing ~80, and it is a genuine ordering guarantee rather than a race that usually settles.

### 7a.3 🔴 The promoted code has a THIRD silent-drop path — in five lines

The body being lifted to Release silently drops files twice (verified):

```swift
let rv = try? url.resourceValues(forKeys: Set(keys))                 // :102  error swallowed
guard rv?.isRegularFile == true else { continue }                    // :103  → vanishes
guard case let .success(tagNames, labelNumber) = TagReading.read(url) else { continue }   // :104 → vanishes
```

A `.failure` from `TagReading.read` — the exact case `W26.deny` exists to make honest — is `continue`d. So an
unreadable file leaves the library with **no error, no count, no signal**, and the scan still reports
complete with `dirErrors == 0`. Promoting this verbatim would defeat `W26.deny` one item later.

- **Fix (`W26.walk1`):** ✅ **DONE** (`b3efb16`) — a `.failure` is **counted and surfaced** as
  `CorpusScanResult.unreadable` (with its reason), and a non-empty `unreadable` makes `isClean` false ⇒
  absence is not actionable, per §5.13 tier 1. **KEEPING an existing row is `W26.walk2`'s half**: the walker
  has no rows, so it hands the caller every URL it could not read and walk2 must not drop those rows.
  Never `continue`.
- **Fix (`W26.walk1`):** if a `getxattr` size-0 probe is used as a cheap pre-filter, **only `errno == ENOATTR`
  may conclude "no tags."** `EACCES`, `EPERM`, `EIO`, `ENOTSUP` **must** fall through to `TagReading.read`.
  Otherwise `W26.deny`'s bug is reintroduced *and persisted* into the index. ⚠️ **Do not add "or a returned
  size of 0" — and do not pass `XATTR_NOFOLLOW`.** Both were in the original wording here and both are wrong;
  see the two corrections in §4a.1, measured while shipping `W26.deny`. Better: **call `TagXattr.inspect`,
  which is shipped, tested against all seven denial shapes, and already applies exactly this rule.** ✅ **RESOLVED BY NOT DOING IT** (`b3efb16`): `W26.walk1` uses **no
  pre-filter at all** — every regular file goes through `TagReading.read`, whose `nil` branch already routes
  through `TagXattr.inspect`. One fewer place for the rule to be re-derived wrongly, and an untagged file
  still costs only the single immediate `getxattr` that branch makes.

### 7a.4 The prune gate is wider than `.firstScan`

`pruneIfSettled` fires on `if !library.isGathering, !filesToIndex.isEmpty, …` (`NavigationModel.swift:649`).
When `isGathering` is derived from `LibraryPhase`, it must read **true for every phase that is not
`.settled`** — so `.revalidating` **and** `.degraded` also block pruning. Deriving it only from `.firstScan`
would let a degraded or mid-revalidation pass delete content-index rows. (`W26.walk2`.)

### 7a.5 A live re-read failure must KEEP the row

`W26.fsev`'s re-read of a dirty path must remove a row **only on a positive determination of absence** —
`lstat`/`access` reporting `ENOENT`, or a fingerprint showing a different inode at that path. **Any
`TagReading.read` `.failure` keeps the row**, marks it unverified, and contributes to `.degraded`. Otherwise a
file momentarily locked by Time Machine, antivirus, or another process silently drops out of a `.settled`
library with `dirErrors == 0`.

### 7a.6 Schema: key on `(root_id, path)` — nested roots already exist

`path` as a **global** primary key is wrong: nested Reader roots exist inside the corpus, so scanning a
subfolder root rewrites `root_id` for those paths and the parent root's next revalidation sees them as
missing. Use `PRIMARY KEY (root_id, path)`, and define root identity as the **conjunction** of resolved path
**and** marker GUID. (`W26.idx`.)

### 7a.7 "Read-only verification" is false as written — pointing the app at a folder WRITES

`W26.verify`'s no-write assertion cannot hold if the measurement is taken by driving the app: selecting a
root **writes `.archive-suite-root.json`** (a fresh GUID if absent). Two consequences:

- Take the timing/scale measurement **out of the app** — a headless ArchiveCore driver calling the walker
  directly (`swift run` or an `ArchiveCoreTests` performance case). Then the read-only assertion is true.
- Any acceptance step that *does* drive the app must declare the marker write as a **known, owner-sanctioned
  exception**, and must not point at a folder lacking a marker unless creating one is intended.

Related: `W26.verify`'s completion grep is **unsatisfiable as written**, because this wave's own items add new
`kMDItem`/Spotlight mentions (the xattr name itself, the `KNOWN_ISSUES` entry, this plan's history). Split it:
(1) no `NSMetadataQuery|NSMetadataItem|MDQuery|CoreSpotlight|CSSearchable|mdfind|mdls|mdimport|mdutil` outside
passages **explicitly annotated as history**; (2) `kMDItemUserTags` permitted **only** as the xattr name in the
read primitive.

### 7a.8 Ordering and gate corrections

- **`W26.lint` must land BEFORE any ArchiveCore discovery code** — otherwise `W26.walk1` authors and commits
  the new engine entirely outside Core Directive enforcement. `W26.walk1` is therefore
  `(blocked-on: W26.deny, W26.lint)`. ✅ **SHIPPED `1460125`** — both trees are linted and the allowlist is
  `(file, exact source line)` pairs as prescribed below. **But nothing invokes the lint** (measured: no caller
  in `ops/`, `.claude/hooks/`, or any script — the script's own header claimed otherwise and was wrong), so
  enforcement is only as real as the person running it. Filed as `W26.lint-fu`; until it lands, **running
  `./ArchiveReader/scripts/lint-write-surface.sh` is part of `W26.walk1`'s gate**, and its self-test is
  `./ArchiveReader/scripts/test-lint-write-surface.sh`.
  One thing this correction under-stated: the tag-write rule was not merely *scoped* too narrowly, it was
  **passing vacuously**. The Reader app target has **zero** `setResourceValue|setxattr` hits of its own, so
  after the W0 refactor moved the write into `CoordinatedTagWriter` the rule had nothing left to catch. Ran
  the old script against planted ArchiveCore violations to confirm: exit 0, "✓ write-surface lint clean".
- **The lint's enumerator rule must be multi-line aware.** Verified: `grep -rn 'enumerator(at:'` matches
  **zero** occurrences in this repo (the call is written across lines) while `\.enumerator\(` matches 4. A rule
  keyed on `enumerator(at:` would pass vacuously — the worst kind of green.
  ⚠️ **This rule is OWNED BY `W26.walk1`, not `W26.lint`** (decided while shipping the latter, 2026-08-05).
  `W26.lint` deliberately did not add it: the only enumerator call sites today are the ones `W26.walk1`/`walk2`
  replace or delete, so a rule written now would either fail on code that is about to go away or — worse, and
  exactly per the warning above — be written to pass. Distinguishing the `errorHandler:`-less overload is also
  not a `grep` problem, since the call spans lines. Add it **with** the walker, keyed on the ban that matters
  (`.enumerator(` without `errorHandler:` in the same call), and give it a planted-violation test in
  `test-lint-write-surface.sh` like every other rule there.
  ✅ **DONE** (`025d126`) — rule 3, balanced-paren via perl so it reads the whole call however many lines it
  spans. Verified non-vacuous against the tree: exactly the two known multi-line sites, and `CorpusWalker`'s
  handler-bearing call passes. Allowances: `ArchiveLibrary.swift:97` (the call `W26.walk2` deletes — the
  STALE-allowance guard then FORCES the allowance out, and a self-test case simulates that deletion) and
  `PDFThumbnailer.swift:158` (its own disposable cache; an unreadable entry there costs an under-counted byte
  total in an index rebuilt on demand). Self-test 9 → 13 cases, including a handler-BEARING plant that must
  **pass**, so the rule cannot decay into a ban on walking. Honest limit, in the script header: a
  TRAILING-closure spelling of `errorHandler:` trips the rule — fail-safe, never a silent pass.
- **Allowlist by `(file, exact pattern)`, not by file.** A file-level allowlist in ArchiveCore becomes a
  permanent unchecked hole in the package that now hosts the corpus walker. ✅ Done in `1460125`, with two
  additions its adversarial pass turned up — both were ways the *new* lint could still print "✓ clean" while
  checking less than it claimed: a **renamed source root** (`grep` just skips a missing path; stderr is
  suppressed so the report stays readable, and the rest of the tree passes) and a **stale allowance** whose
  line no longer exists, sitting there as a pre-approved hole for the next write to slip into. Both hard-fail
  now. Honest limit, recorded: matching on line *content* means a byte-identical duplicate of an allowed line
  in the same file would also be allowed — accepted because line numbers churn on every edit above the site,
  and the allowed lines reference locals that exist only inside the writer's coordination block.
- **`W26.walk2` must ship `rescan()` AND its user-visible trigger** (a "Rescan Archive Folder" command,
  ⌘⌥R — ⌘R is Mark Read). It deletes `DidUpdate`/`DidFinishGathering`, and `W26.fsev` is a later item, so
  without this the Reader has **no way to refresh at all** in between. The plan already names manual refresh
  as the accepted interim; that makes shipping it part of the same item, not a follow-up.
- **`W26.walk2` must state that the scan runs OFF the main actor.** The promoted body is a *synchronous
  MainActor* function; at 150k that is a ~10 s beachball, and none of the current gates would catch it. Set
  `phase = .firstScan` synchronously on the MainActor, then run the walk detached at `.utility`.
- **`W26.idx` must state that something WRITES the index.** The plan describes the read/warm-start side; add
  an explicit first deliverable: at the end of every scan pass, `upsertBatch` all regular files seen under the
  scan generation (500-row batches).

### 7a.9 The regression guard would pass vacuously

`W26.walk2`'s headline test — *"a fixture Spotlight has never indexed must still list every tagged file"* —
**passes today** if it sets `-ARUITestRootPath`, because that key (`ArchiveLibrary.swift:66`) selects the
existing DEBUG walker. It would prove nothing. The test must construct `ArchiveLibrary()` **directly** with
`ARUITestRootPath` **absent** from `UserDefaults` (assert its absence), so it exercises the real production
path. This is the single most important test in the wave; it must fail for the right reason today.

### 7a.10 🔴 The dataless guard is on the CHEAPEST I/O and missing from the most expensive

§4a.4's thread-scoped policy protects the **walk**. But tag xattrs on a placeholder are readable *without*
materialising the file, whereas `PDFDocument(url:)` in `ContentIndexer` **downloads it**. So the flip would
convert *"Spotlight sees nothing in a cloud tree"* into *"silently download every file in a cloud tree"* —
a strictly worse failure, and one that costs bandwidth and disk rather than just showing a wrong list.

**Rule:** *every* thread that touches a corpus file sets the thread-scoped dataless policy — the traversal
`Thread` **and each tag-read worker and each content-extraction worker**. Additionally have `CorpusWalker`
record per-entry datalessness (`getattrlistbulk` already returns the attribute) and persist it, so
`ContentIndexer` can **skip** dataless files rather than materialise them. (`W26.walk1` + `W26.idx`.)

✅ **`W26.walk1`'s half DONE** (`b3efb16`): the walk is single-threaded, so the one thread that touches corpus
files sets the policy — `withDatalessMaterializationDisabled`, which also **restores** the prior value (and
restores `IOPOL_DEFAULT` when the prior cannot be read, rather than skipping the *set* and silently dropping
the protection). `CorpusEntry.isDataless` comes from `st_flags & SF_DATALESS` on the per-entry `stat`, not
`getattrlistbulk`. **Still open for `W26.idx`:** persisting it, and making `ContentIndexer` skip on it — the
expensive half, since `PDFDocument(url:)` is what downloads.

### 7a.11 `.settled` is reachable from a TRUNCATED walk — and `.settled` is what authorises pruning

`completed` means only *"the enumerator ended"*. If the root goes away mid-walk — external drive ejected, a
File Provider domain dropping out — the remaining top-level children can **list empty rather than error**, so
the pass finishes with `filesSeen: 40,000`, `dirErrors: 0`, `completed: true`. That is *clean and complete* by
the §5.13 rule, and pruning then deletes ~110,000 rows for files that are perfectly fine.

**Fix (`W26.walk2`):** `.settled` additionally requires a **post-pass root re-validation** — the root still
exists, `access(R_OK) == 0`, and its `(f_fsid, st_ino)` are **identical to the values captured in the pre-pass
precondition**. Capture them in the precondition specifically so this comparison is possible. A mismatch or
a vanished root ⇒ `.degraded`, and absence is not actionable.

### 7a.12 A mid-scan disappearance is not a tag failure — and must not poison cleanliness

Measured by the reviewer: with two directories renamed mid-enumeration, the `errorHandler:` enumerator still
yielded **403 of 1,203** paths that no longer existed. Persisting those rows would have `ContentIndexer` open
them, get `nil` from `PDFDocument`, and record them as unreadable — a fabricated format-health problem.

**Fix (`W26.walk1`):** ✅ **DONE** (`b3efb16`) — a distinct `vanishedMidScan` counter. An `ENOENT` on the
per-entry `stat`/tag read means the entry disappeared: **excluded from `entries`, never persisted, and NOT
counted as unreadable** (so it spoils neither `isClean` nor pruning). It is normal churn, not a denial.
Tested deterministically: with `batchSize: 1` the `onBatch` callback deletes the rest of a 24-file fixture
from inside the walk, and the pass must still be `isClean` with `entries + vanished == 24`.
⚠️ **Known consequence, recorded:** a **dangling symlink** reports `.vanished` on every pass, not only the one
it broke in (the probe follows symlinks, as `TagReading` does). Harmless — excluded from `entries`, as the
Spotlight-era loader also excluded it, and it does not spoil cleanliness — but `vanishedMidScan` on such a
tree is a floor, not a churn signal.

### 7a.13 Warm start must not claim currency from a scan that never finished

The quit window is far wider than "seconds": the walk is ~9 s but the `ContentIndexer` pass behind it is
~1,456 s at 150k, so *"quit mid-cold-index"* is a **~24-minute** window. Rows from that scan are committed in
500-row batches, so the index legitimately holds e.g. 40,000 of 150,000 entries with `finished IS NULL`.

**Fix (`W26.idx`):** publish `.revalidating(asOf:)` **only** when the newest scan row for the root has a
non-NULL `finished` **and** a clean outcome. A NULL-`finished` or non-clean row publishes its rows as
**unverified** (and must never authorise pruning). Otherwise the app asserts "as of Tuesday 14:03" about a
list that was never complete.

### 7a.14 The FSEvents mainline is an unthrottled full re-walk

§4.5 already establishes that bursts **drop to a root-level re-scan** as the common case. Nothing yet bounds
that: a 2,000-file group edit, or the Processor writing a batch over ten minutes, can start walk N, then have
events 1 s later start walk N+1, and so on.

**Fixed (`W26.fsev`, completion commit):** **at most one full re-walk in flight and at most one queued,
coalesced newest-wins**, with a one-second minimum interval between event-driven root passes. A queued pass
keeps `LibraryPhase` revalidating even while it waits, so absence and content-index pruning are never enabled
between the two walks. Targeted path/subtree work is likewise serial and coalesced.

### 7a.15 Cloud-root detection: `MNT_LOCAL` cannot fire, so identify positively

A `statfs`/`MNT_LOCAL` test does **not** flag `~/Library/CloudStorage/GoogleDrive-…` — a File Provider domain
presents as a local mount, and `isReadableFile` returns true. Given the owner's corpus lives in a folder
*named* "Google Drive", mis-picking the real Drive path is the single most likely wrong click in the folder
picker.

**Fix (`W26.walk2`):** identify a non-local root **positively** — resolved path inside `~/Library/CloudStorage`,
or an `NSFileProviderManager` domain match — and **degrade honestly** rather than hanging or silently
under-reporting. ⚠️ **This is in tension with §9's non-goal "do NOT refuse cloud-backed roots at selection
time."** Both are defensible; the reconciliation this plan adopts is: **detect and warn, do not refuse** —
proceed with the dataless guard on, show `.degraded` with the reason, and never present a partial cloud walk
as `.settled`.

### 7a.16 Correction to §4.4's revised vocabulary scope

The `~/Desktop` harvest is **2.2× larger than §4.4's revision implies**: measured read-only, `~/Desktop` holds
**343,595 files across 7,690 directories**, of which **286,419 are the corpus + JPEGS trees**. So the "just walk
`~/Desktop`" recommendation is a ~2.8× corpus walk that runs **straight through the sacred corpus, possibly
while the Processor is capturing/OCRing**.

**Fix (`W26.vocab`):** state that real denominator rather than only the tagged-file count, run the harvest at
`.utility` with a **worker width of 2**, and reuse the persisted index where one exists
(`SELECT tags_raw …` was measured at 0.295 s for 150k rows) instead of re-walking. The scope decision stands;
the cost claim needed correcting.

### 7a.17 Path canonicalisation — sound advice, one premise not reproduced

Guidance adopted: compose child URLs with
`URL(fileURLWithFileSystemRepresentation:isDirectory:relativeTo:)` from the **raw name bytes**, never via
`String(cString:)`, and key the index on the `fileSystemRepresentation` bytes. Three stores
(`CorpusIndex`/`ContentIndex`/the live model) are joined by exact path equality, so one normalising producer
would silently fork them.

⚠️ **But the supporting claim — that the corpus contains an NFD filename — did not reproduce.** The cited
`Lécuyer pollution in SV proofs.doc` is **NFC** (precomposed `c3 a9`; no `cc 81` combining acute). Treat the
canonicalisation rule as **defensive practice**, which §5.3 already required, and **not** as a fix for a
known-present NFD path. Do not cite an NFD corpus file as motivation.

### Rejected

One lens raised a **CRITICAL** "the wave's tags collide with an existing W26 set; add `W26.retire` to delete
the old entries." **Not applicable** — that is an artifact of the review comparing a *parallel, independently
invented* item set against the one actually committed here. There is exactly one W26 set in the trackers and
`next-queue-item.sh` resolves all of it. **Do not create `W26.retire`; do not delete any W26 entry.**

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

**Non-goals that three independent designs converged on** (recorded because each is a plausible-sounding
idea that a later reviewer will propose, and the reasoning against it is not obvious):

- **Do NOT add a `.denied` case to `TagReadResult`.** It is the theoretically honest fix for §4a.1, but it
  ripples through every `TagReading` caller in **all three apps** plus `CoordinatedTagWriter`'s §3 refusal
  logic in `TagWrite.swift`. All three designs declined it independently, preferring the walker probe the
  parent directory's readability instead. ⚠️ **This contradicts §4a.3's recommendation**, which argues the
  fix belongs in `TagReading` because the Safety §3 write guard is bypassable through that path. **Genuine
  open decision, not an oversight — resolve it explicitly in `W26.walk1` and record the choice.** The narrow
  reading: fix the walker now (cheap, unblocks the wave), file the `TagReadResult` question as its own
  Tier-2 item with the Safety §3 argument attached, rather than smuggling a three-app enum change into a
  discovery task.
- **Do NOT share one database between the apps, and do NOT add an App Group.** The Reader is sandboxed (its
  Application Support lives inside `~/Library/Containers/com.archivereader.app/Data/`) and the Processor is
  not, so a shared store means a new entitlement and a new cross-app coupling. **Share the walker CODE in
  ArchiveCore; keep STORAGE per-app.** (The `SELECT tags_raw` vocabulary query is only 0.295 s at 150k rows,
  so the Processor can simply do its own root-scoped read.)
- **Do NOT build a shadow/dual-run mode** comparing the walk against Spotlight before the flip. It sounds
  like the responsible move and is worthless here: **the Data volume's Spotlight index is dead on this
  machine**, so the comparison baseline is an empty set. There is nothing to validate against.
- **Do NOT add a periodic re-walk timer.** Prefer window-activation-triggered revalidation (only when the
  last settle is older than ~5 minutes) plus an explicit ⌘⌥R. A timer would contend with `ContentIndexer`
  for I/O on a corpus this size, for no correctness gain over FSEvents plus a launch walk.
- **Do NOT refuse cloud-backed roots at selection time.** Detecting FileProvider/CloudStorage paths is
  imperfect and refusal is a UX cliff; the §4a.4 thread-policy guard plus honest `.degraded` reporting is
  the right shape — fail fast and explain, don't pre-emptively forbid.
- **Do NOT adopt the shared walker in Archive Notes now.** Notes has zero Spotlight references and its own
  working walk; adding a dependency buys nothing this wave.

**One argument for the ArchiveCore placement, worth stating:** the membership predicate is **already
duplicated today** — the `NSMetadataQuery` predicate at `ArchiveLibrary.swift:41-42` and the DEBUG walk's
case-insensitive check at `:105-109` are two independent expressions of the same rule. A Reader-local fix
would leave that duplication and let the Processor grow a third. One component in ArchiveCore, next to the
audited writer it must agree with, collapses all three.

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
- `ArchiveReader/CLAUDE.md` carries **eight** statements that become false — including a **§Decisions
  entry** (which the owner ships as settled) plus the architecture and stack sections. Treat the §Decisions
  one carefully: it is a record of an owner decision, so **supersede it with a dated new decision** rather
  than editing history.
- `ArchiveReader/KNOWN_ISSUES.md` — **five** affected passages, including a *"Verified facts to rely on"*
  entry **that the incident itself falsified**, and a whole section documenting the Spotlight-lag mechanism
  being deleted.
- ⚠️ **`SPEC/tag-format.md` names `ArchiveLibrary` as the Spotlight consumer in its API table.** That row
  *is* the contract both apps must interpret identically, so this one edit **does** touch the shared
  contract and must land with both apps together (CLAUDE.md §"The shared contract is the risk"). The tag
  *vocabulary* is still unchanged — it is the reader-side API row that moves.
- ⚠️ **`REVIEW.md` assigns "Spotlight consistency" as a standing review concern for Reader/Search — and the
  autonomous daemon reads that file to pick review units.** Leaving it stale sends future review sessions
  hunting a subsystem that no longer exists.
- `ArchiveReader/SMOKE_TEST.md` — the historical record of the 2026-07-05 two-bug incident **whose fix #2 is
  what this wave deletes**; one PASS criterion is phrased in Spotlight-window terms. Keep the history,
  re-word the criterion.
- The **suite-level `README.md`** makes a user-facing **product claim** about Spotlight, in prose *and* in
  the architecture diagram. Two Processor docs describe `SystemTagsProvider` as Spotlight-sourced (its
  implementation map + file tree). A cross-app **execution plan** states the Reader's deep-link reveal
  contract in Spotlight terms, **and Notes depends on that contract**.
- `AGENTS.md`; `SUITE_TODO.md` → `SUITE_TODO_DONE.md` as items ship.

⚠️ **Do not mechanically find-and-replace.** Three `Spotlight`/`kMDItem` matches in the tree are
**xattr / Finder-comment references, not Spotlight queries** (including two benign prose mentions in Notes,
one of which already documents that Notes discovery is *not* Spotlight). They must survive untouched.

**A second dividend:** `SUITE_TODO_DONE.md` records **two GUI verifications that were deferred precisely
because the scratch corpus was not Spotlight-indexed.** Removing Spotlight discharges them — check them off
rather than re-deferring.

**A side benefit worth recording:** `ops/gui/tart-lib.sh:74` runs `make-gui-fixture.sh` **inside a guest
VM**, where a cold Spotlight index is the least reliable thing in the environment. `W26.scripts` removes
that dependency from the GUI lane entirely — no `tart-lib.sh` edit required.

**Delete this plan when `W26.verify` passes.**
