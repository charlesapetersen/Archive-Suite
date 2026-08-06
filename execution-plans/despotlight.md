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

### Site 1 — `ArchiveReader/.../Search/ArchiveLibrary.swift` — ✅ REMOVED by `W26.walk2` (`f1c0d2f` → `0ac71fd`)

Inventory removed 2026-08-06: every `NSMetadataQuery` / `NSMetadataItem` path and the Spotlight-lag
`PendingWrite` subsystem this table catalogued is **gone**, so all of its line references pointed at code that
no longer exists — actively misleading. The one durable finding is kept: **a working filesystem discovery path
already existed and had been compiled out of Release**, which is how a Release build with no fallback shipped
at all.
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

> ✅ **SHIPPED as `W26.oracle` (2026-08-06, `50ea4a1` → the completing commit) — and the "would have" above
> is WRONG, measured.** The harness puts TESTOUT at `/tmp/ap-e2e-$$/out` (`e2e-phone-mac.sh:34-35`), and
> neither `/tmp` nor `/var/folders` is Spotlight-indexed. On a file whose tags `xattr -px` returns in full,
> `mdls -name kMDItemUserTags` answers `(null)` and **exits 0**. So this oracle was not *fragile during an
> incident* — its tag branch was **dead in every E2E run that has ever happened**, and `year` has only ever
> been satisfiable from the output filename or the extracted text. The failure mode is not a false FAIL but a
> silently absent assertion. `disk_tags` moved into a new shared `ArchiveProcessor/scripts/finder_tags.py`
> (whose `read_tags` also reports `absent` vs `unreadable` — §4a.1's distinction, in Python), and
> `tier2_assert.py` was proven byte-identical against its own predecessor before being switched over. Gate:
> `./ArchiveProcessor/scripts/test-finder-tags.sh`. **Generalise the lesson when reading the rest of this
> plan: every `mdls`/`mdfind` site under a `mktemp`/`/tmp` path is presumed BLIND, not merely slow — check
> whether the site's location is indexable before writing down what its failure mode was.**

### Site 7 — a **future re-infection** already approved in the backlog — ✅ CLOSED 2026-08-06

The item (open, owner-decided) specified *"Detection: index the JPEGS tree (**a second `NSMetadataQuery`**).
This is **REQUIRED, not an optimisation** — 80.1% of partners need relocation resolution no path rule can
do."* Shipping it before or during this wave would have **re-introduced the exact dependency the owner is
removing.** Highest-value find in the doc lane, and it is now shut: §2 is a walk-built stem index over the
JPEGS subtree (`CorpusWalker.scanFingerprints`), with the requirement itself untouched.

Two corrections this plan owes the reader, both from measuring rather than reading (full record in
`SUITE_TODO_DONE.md` → `W26.reinfect`):
- **"same walker, second root" was wrong** — `Archival Photos JPEGS` is a *sibling* of `Archival Photos`
  under `~/Desktop/Google Drive/`, so design decision #1's root raise already contains it. It is a second
  **subtree** of one root, needing no second bookmark.
- **`(blocked-on: W26.walk1)` was too weak.** The JPEGS tree is **163,106 files** against the main tree's
  123,302, so the root raise roughly **doubles every cold walk** (~286k). The edge shipped as
  `(blocked-on: W26.walk2, W26.verify)`.

The item also had **no tag** — which is why this section and `W26.reinfect` both cited it as
`SUITE_TODO.md:1048`, a line number 336 lines stale by the time the work ran. It is now **`W24.jpeg1`**.

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

### The better precedent: Archive Notes, end-to-end — ✅ decision made; detail removed 2026-08-06

Its only job was to force §5.6's synchronous-vs-async choice and supply a shape to copy. That choice was made
**SYNCHRONOUS** in `W26.walk1` (`b3efb16`), and the shape shipped as `LibraryPhase` + `DiscoveryHealth` in
`W26.walk2` (`0ac71fd`). Still standing: §9 forbids adopting the shared walker **into** Notes this wave.
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

### 4.1 `CorpusWalker` — ✅ SHIPPED 2026-08-05 (`W26.walk1` `b3efb16` → `025d126` → `003ca59`)

Sketch removed 2026-08-06. This is a correctness win as much as a size one: the shipped type deliberately
diverged from the sketch, and leaving the old prescription in place invites exactly the failure §4a.1 warns
about — a later item copies the plan's wording and reintroduces the thing that was fixed. **Two prescriptions
in the deleted sketch are now FALSE; do not resurrect them:**

- the pass is **synchronous and single-threaded**, NOT "parallelised with a bounded `TaskGroup`" — the
  thread-scoped dataless policy in §4a.4 / §7a.10 requires it;
- it emits **`[CorpusEntry]`**, not `[ArchiveFile]`.

Authoritative: `packages/ArchiveCore/Sources/ArchiveCore/Corpus/CorpusWalker.swift`.
### 4.2 `ArchiveLibrary` — the swap — ✅ SHIPPED 2026-08-05 (`W26.walk2` `f1c0d2f` → `b88d20a` → `6f5d6ad` → `0ac71fd`)

Deletion list removed 2026-08-06: every item on it is already gone from the code, so the list only described
work that no longer exists (`git log -p -- execution-plans/despotlight.md` for the text). Kept because §5.11
sharpens it and still binds: **§4.2's `isGathering` warning** — publishing batches progressively lets a partial
result be mistaken for a complete one, so a list that is still filling must never present as settled (§4.3's
honest states, and OPEN `W26.verify`'s GUI lane asserts exactly this).
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

### 4.5 `CorpusWatcher` — FSEvents live updates — ✅ SHIPPED 2026-08-05 (`W26.fsev` `7c016ce`, amended by `W26.fsev-fu1` `ab80c12` and `W26.fsev-fu2` `5394a97`)

Design detail removed 2026-08-06 (shipped — `CorpusWatcher.swift` is authoritative; full text in
`git log -p -- execution-plans/despotlight.md`). Four sections still cite this one BY NUMBER, so the facts they
depend on are kept verbatim rather than dropped:

- **FSEvents flags are UNIONED across the coalescing window** — so a flag set means "this path *may* have
  changed", never "this specific thing happened". Always re-read; never trust the flags. (Cited by §5.4 and
  §5.13.)
- **A burst drops to a root-level re-scan** as the common case. (Cited by §7a.14, which still owns bounding it
  — the FSEvents mainline re-walk is unthrottled.)
- **`FSEventStreamFlushSync` replaces `mdfind` polling** in the fixture scripts — that is what makes OPEN
  `W26.scripts` possible at all.
- ⚠️ This section's original event-ID *"conservative high-water mark"* wording is **SUPERSEDED by §5.18**
  (event IDs are **not** delivered in ascending order). Use §5.18, not the phrasing §5.18 quotes.
- FSEvents vs kqueue vs `NSFilePresenter` was decided here — a later reviewer should **not** re-litigate it
  (§Rejected).
### 4.6 `LibraryIndex` — instant warm start — ✅ SHIPPED 2026-08-05 (`W26.idx` `84d18b0`)

Design detail removed 2026-08-06 (shipped — `ArchiveReader/.../Search/LibraryIndex.swift` and its real schema
supersede the DDL sketch that was here; full text in `git log -p -- execution-plans/despotlight.md`). The facts
that still BIND OPEN items are kept verbatim:

- **Rows are keyed on the BYTE-EXACT `(root path, marker GUID, file path)` — never NFC/NFD-normalised** (§5.3).
  ⚠️ **This bullet's reading of `W26.symroot` was WRONG and is corrected here** (2026-08-06, `W26.symroot`
  shipped). It said the item's obvious fix (`resolvingSymlinksInPath()` before enumeration) *"breaks precisely
  this contract"*, so the item had to keep the caller's root spelling for identity. Measured: the enumerator
  **already** yields fully ancestor-resolved paths — hand it a root spelled `/var/folders/…` and every entry
  comes back `/private/var/folders/…` — so the caller's spelling was never what the walk emitted, and what
  this contract actually requires is that the walk's own output be *stable*, not that it echo the caller.
  Keeping the link spelling for identity would have been the harmful choice: it invents a third spelling that
  neither FileManager nor FSEvents produces, so `CorpusWatcher`'s realpath'd events would match no row at all.
  Shipped as `CorpusWalker.canonicalRoot`: identity follows enumeration, and **only a symlinked final
  component** is canonicalised, so no existing root's spelling — and therefore no cached row — moves. The
  residual is `W26.symroot-fu1`: a CALLER's root-relative logic (the Reader's folder tree, exclusions, link
  writing, watcher containment) still compares against its granted spelling.
- Persisting every regular file measured **~60 MB / 1.3× rows**; OPEN `W26.verify` compares the SQLite file
  size against that baseline (and peak RSS at 150k rows).
- **Removals apply only after a cleanly COMPLETED walk** — a truncated or cancelled walk must never authorise
  pruning (§7a.11, §7a.13); a cancelled warm revalidation must leave `asOf == nil` and prune nothing.
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
| `W26.reinfect` | ✅ **SHIPPED in completion commit** — JPEGS §2 is a walk-built stem index; item tagged `W24.jpeg1`; edge `(blocked-on: W26.walk2, W26.verify)`, not `walk1` (§Site 7) | S | low | 1 | none | — |
| `W26.scripts` | Fixture scripts drop `mdimport`/`mdfind` polling | S | low | 1 | none | `W26.walk2` |
| `W26.docs` | Docs/SPEC stop claiming Spotlight (incl. `ArchiveReader/CLAUDE.md:106`) | S | low | 1 | none | `W26.walk2` |
| `W26.verify` | Scale + safety verification on a scratch copy; gates deleting this plan | M | med | 2 | none | `W26.fsev`, `W26.idx`, `W26.vocab`, `W26.oracle`, `W26.reinfect`, `W26.deny`, `W26.lint` |

`W26.oracle` and `W26.reinfect` were **unblocked and went first** — neither depends on the walker.
`W26.reinfect` was deliberately early: it is cheap, and every day it stayed undone was a day the JPEGS item
could ship a second `NSMetadataQuery` into the codebase this wave exists to clear. Both are now shipped.

**`W26.deny` goes first and is not optional.** It is a live Core Directive violation (§4a.1b), it is
independent of Spotlight, and every later item builds on the corrected primitive. **`W26.lint` closes a
governance hole this plan itself would otherwise open:** `ArchiveReader/scripts/lint-write-surface.sh:10`
hardcodes `SRC="macOS/Sources/ArchiveReader"`, so moving discovery into `packages/ArchiveCore` moves it
**out of the Core Directive's automated enforcement**. (Note the same gap already exempts ArchiveCore's own
`TagWrite.swift` — which is precisely where §4a.1b's bug has been sitting unlinted.) Extend `SRC` to cover
`packages/ArchiveCore/Sources/ArchiveCore`, keeping the *tag-write* rule's allow-list pointed at the audited
writer.

**Per-item test gates** (an item is not done without one that would *fail* if the work were wrong):

- ✅ **The per-item test gates for the SHIPPED items** (`W26.deny`, `lint`, `walk1`, `walk2`, `notsup`, `fsev`,
  `idx`, `vocab`, `oracle`) were all met, and are recorded per item — in more detail than here — in
  `SUITE_TODO_DONE.md`; the tests themselves now exist in the repo. Bullets removed 2026-08-06 to bring this
  plan back inside its context budget (`git log -p -- execution-plans/despotlight.md` for the text). Two of
  them were also **wrong as written** and survived only as history: `W26.oracle`'s wanted a scratch DMG plus a
  paid Gemini run (see `SUITE_TODO_DONE.md` for what actually replaced it), and `W26.deny`'s probe wording
  (`XATTR_NOFOLLOW`, "a returned size of 0") is corrected in §4a.1. The gate bullets for the still-OPEN items
  below are untouched.
- ✅ `W26.reinfect` — met, with one deliberate deviation recorded in `SUITE_TODO_DONE.md`: the grep returns
  **one** hit outside §Wave 26, the superseded clause quoted inside the annotation that replaces it, which
  is §7a.7's "explicitly annotated as history" carve-out. The gate's second half was unsatisfiable, not
  merely stale: `next-queue-item.sh` can never report the JPEGS item as `blocked:` anything, because it
  draws candidates from the plan's `## WORK QUEUE` only and that item is owner-gated, so it is kept out.
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
