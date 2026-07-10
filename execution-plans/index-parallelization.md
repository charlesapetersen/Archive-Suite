# Execution plan — parallel + batched content indexing, ranked search (Reader)

**Goal:** make Archive Reader's content-index build **much faster** (first-run + post-schema-bump
re-index over up to ~150k PDFs) **without** making the main UI unusably slow while it runs — and, on
the same pass, make full-text search **relevance-ranked** and usable *during* a build.

**Scope:** `ArchiveReader/macOS/Sources/ArchiveReader/Search/ContentIndex.swift` +
`ContentIndexer.swift` (extraction/index); plus, for ranked search only, `Views/NavigationModel.swift`
+ `Core/LibraryFilter.swift` (+ their tests). No change to the tag/PDF SPEC, no change to `TagWriter`,
no new file-write surface — extraction stays strictly read-only; the index is the same disposable,
rebuildable SQLite cache. **Risk: Tier-2** (touches actor isolation) → adversarial self-review + a
functional test on scratch copies (never the real corpus).

> **Grounded against the code, 2026-07-09** by the `index-plan-verify` workflow (4 code readers + 3
> adversarial reviewers; all citations below are verified). The three reviewer verdicts were all
> *needs-change, not blocker*; every required change is folded in below.

## Problem (measured from the code)

`ContentIndexer.launch` runs **one** `Task.detached` that walks the file list in a serial `for`
loop: `PDFTextExtractor.extract` (CPU+I/O-bound PDFKit parse of every page) then `await idx.upsert`,
one file at a time on a single core. `ContentIndex.upsert` wraps **each** file in its own
`BEGIN…COMMIT` → one fsync per file. Two bottlenecks: (1) extraction is single-threaded;
(2) writes are one-transaction-per-file. Separately, full-text search returns results in **rowid
order, not relevance** (`ContentIndex.search` has no `ORDER BY`, `ContentIndex.swift:102-104`).

---

## Part A — faster index build

### A1. Parallelize extraction across cores (the main win)
Extraction is embarrassingly parallel: each file is independent and gets its own `PDFDocument`.
Replace the serial loop with a **bounded** `withTaskGroup` (sliding window of width `workers`). Each
child captures **primitives only** (`url`, `path`, `mtime`, `name` — not the whole `ArchiveFile`),
runs the CPU-bound `PDFTextExtractor.extract` off-actor, and returns a `Sendable` `IndexRow`. The
`ContentIndex` actor keeps all DB writes serialized (correct — one SQLite connection). Expected
~4–8× on the extraction-bound portion on a multicore Mac.
- Check `Task.isCancelled` **inside each child** — before `extract` *and* before handing the row to
  the batch — so a scope change cancels promptly; `group.cancelAll()` on break.

### A2. Batch DB writes into transactions (pairs with A1)
Add `ContentIndex.upsertBatch(_ rows: [IndexRow])` that wraps ~500 rows in **one**
`BEGIN IMMEDIATE…COMMIT` (ROLLBACK on error). Refactor the existing per-file `upsert` body into a
private `upsertRow(...)` (no BEGIN/COMMIT); keep `upsert(...)` as the single-file wrapper so its
signature/behavior — and every existing test/caller — is unchanged. Batching is a classic 10×+ on
bulk SQLite/FTS5 inserts.

> **Actor-reentrancy invariant (load-bearing — reviewer-flagged).** Swift actors suspend at every
> `await`. Today `upsert` is safe *only* because it is fully synchronous between `BEGIN` and `COMMIT`
> (`exec`/`prepare`/`run`/`insertFTS` are non-async), so no other actor call interleaves mid-transaction.
> `upsertBatch` **must** preserve this: no `await`/suspension between `BEGIN` and `COMMIT`; all
> extraction stays *outside* the transaction (children hand in already-extracted `Sendable` `IndexRow`s).
> Add a comment + a test that guards it.

### A3. WAL + relaxed sync
In `open()`, after `busy_timeout`: `PRAGMA journal_mode = WAL;` and `PRAGMA synchronous = NORMAL;`.
**Verified:** no pragmas are set today (default rollback journal), so this is a prerequisite — without
`journal_mode=WAL` the `wal_checkpoint` in A4 is a no-op (`ContentIndex.swift:30`). WAL + `NORMAL`
benefits: cheaper batched writes, fewer fsyncs, and it makes `wal_checkpoint(TRUNCATE)` meaningful.
Safe because the DB is a **disposable cache** — a crash just means re-indexing. (Not `OFF`; `NORMAL`
is the reasonable floor. WAL leaves `-wal`/`-shm` sidecars — fine for a cache, and A4 truncates them.)

### A4. End-of-pass maintenance (corrected ordering)
After a pass, keep the FTS index compact and the WAL sidecar bounded. Implement as **one actor-isolated
method** `performMaintenance()` called via `await idx.performMaintenance()` — **never** run
`optimize`/`checkpoint` against `db` from the detached task's thread (the `sqlite3` handle is confined
to the actor; touching it off-actor concurrently with an in-flight `search` is a data race).
Order and gating (reviewer-corrected):
1. **Merge/optimize first, then checkpoint** — so the checkpoint reclaims the WAL the merge produced.
2. **Skip on ~0-row passes** (a warm reopen that indexed nothing shouldn't pay for it).
3. Prefer **incremental** `INSERT INTO fts(fts, rank) VALUES('merge', N)` on incremental passes;
   reserve full `INSERT INTO fts(fts) VALUES('optimize')` for the **initial bulk build**. Full
   `optimize` rewrites the whole index into one segment — multi-second on 150k — and because it runs
   on the shared actor it **blocks every search for its duration**, so it must not fire each pass.
4. `PRAGMA wal_checkpoint(TRUNCATE)` (not `PASSIVE` — PASSIVE never shrinks `-wal`). Single-connection
   design means no concurrent reader can leave it partial; treat any busy result as non-fatal.

### A5. Skip-check without per-file actor round-trips
Add `ContentIndex.existingMTimes() -> [String: Double]` (one `SELECT path, mtime FROM files`). The
indexer pulls the skip-map once and partitions `files` into `work` (mtime differs) vs skipped
in-memory, instead of a serialized `await needsIndex` per file. Also speeds the **warm reopen** scan
(~150k tiny awaits → one query). `needsIndex` stays for single-file callers/tests.

### Keeping the UI usable while indexing
1. **Reserve cores:** `workers = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)` — headroom
   for the main (user-interactive) thread + system so a full-core parse storm can't peg the machine.
2. **Low QoS:** keep the detached task **and** its child tasks at `.utility`; under contention the
   scheduler favors the main thread.

Progress reporting already hops to the main actor only every 100 files (cheap) and is epoch-guarded
— unchanged.

---

## Part B — search *during* a build (A4-adjacent, verified)

**Search already works mid-pass and is *not* gated on `progress`** (`ContentIndexer.search` has no
progress check, `ContentIndexer.swift:86-89`; the search box has no `.disabled`,
`NavigationWindowView.swift:270-275`). The reason it works is **not** "WAL enables concurrent reads" —
there is exactly one actor and one connection, so search and writes serialize on the actor. It works
because the expensive `PDFTextExtractor.extract` runs **off-actor** (`ContentIndexer.swift:56,66`), so
the actor is idle between files and services a queued `search` in one of those gaps.

The real gap is **staleness, not blocking**: a query typed early in a pass matches only
already-upserted files and is **never auto-refreshed** when the pass completes (the `$progress` sink
refreshes format statuses but not FTS, `NavigationModel.swift:87-92`), so it silently under-reports.

**Fix:** on pass completion (`progress == nil` in the `$progress` sink, `NavigationModel.swift:87-92`)
re-run the active FTS query, **guarded by the existing `ftsGeneration` token** so a concurrent
scope/root switch can't repopulate a stale result. Keep the existing "indexing…" progress bar as the
hint. (Correct the plan's earlier "WAL enables concurrent reads" rationale — it's off-actor
extraction, not WAL. WAL is still worth having for A2/A3/A4.)

---

## Part C — relevance-ranked search (bm25), **no snippet previews**

> Previews (keyword-in-context) are explicitly deferred to the Reader `POTENTIAL_FEATURES.md`.

**Verified trap:** adding `ORDER BY bm25(fts)` in SQL alone is a **user-visible no-op**. Result order
is discarded *twice* — `ContentIndexer.search` wraps rows in `Set(...)` (`ContentIndexer.swift:88`),
and `ftsPaths` is a `Set<String>` (`NavigationModel.swift:49`) — and `recompute()` uses `ftsPaths`
only as a `.contains` membership predicate (`NavigationModel.swift:247`), then **always** sorts by
column descriptors via `LibrarySort.sorted(base, by: sort)` (`NavigationModel.swift:253`). So the
nav list never carries search-result order. Ranked search is a **coordinated 5-point change**:

1. **SQL:** append column-weighted bm25 to both branches at `ContentIndex.swift:102-104`:
   `ORDER BY bm25(fts, w_body, w_class, w_name)` — weights in **schema column order**
   (`body, classification, name`, per `ContentIndex.swift:35`; transposing silently mis-ranks). Weight
   the visible fields higher (e.g. `bm25(fts, 1.0, 5.0, 10.0)`) so `name`/`classification` hits surface
   first and the order is explainable from what the user can see. **No `LIMIT` conflict** — `ORDER BY`
   reorders but drops zero rows, so the "return ALL matching paths" set-membership contract holds; it
   even *fixes* the "dropped-by-rowid" hazard the `search()` doc comment flags for limited callers.
2. **Drop the `Set` wrap** at `ContentIndexer.swift:88` — return an **ordered `[String]`** in bm25 order.
3. **Widen `ftsPaths`** (`NavigationModel.swift:49`) to carry rank: keep a `Set<String>` for the O(1)
   membership intersection at `:247` **and** an ordered list / `[String: Int]` rank map. Assign it
   through the **existing `ftsGeneration`-guarded path** (`:338-344`) and preserve the root-switch
   invalidation (`:487-489`) so a stale ranked result can't repopulate after a scope change.
4. **`recompute()` is the load-bearing change** (`:247`/`:253`): `base` inherits `library.files` order,
   so preserving `ftsPaths` order upstream is *not enough*. When a query is active, order `base` by the
   rank map (`base.sorted { rank[$0.url.path]! < rank[$1.url.path]! }`) **instead of**
   `LibrarySort.sorted(base, by: sort)`; keep the cheap `.contains` intersection at `:247`.
5. **`LibrarySort.relevance` case** in `Core/LibraryFilter.swift` for menu/state plumbing — but the
   actual ordering is injected at `recompute():253` (the comparator only sees `ArchiveFile` fields; rank
   isn't one, so a bare enum case can't sort). Lifecycle: **auto-select `.relevance` only while
   `fullTextQuery` is non-empty**; fall back to `LibrarySort.default` when the query clears; **exclude**
   it from header-click sort bridging (`:322-331`, no backing column); and omit/coerce it in `ViewState`
   persistence (`:287-301`) so a persisted `.relevance` with no query can't wedge the sort.

**Cost note:** bm25 scores+sorts the entire match set — on a common term across ~150k PDFs this is
measurably more than the current rowid scan. Acceptable (search is user-initiated, not per-keystroke),
but noted; a limited/ranked cap is a possible future mitigation.

---

## Test plan (scratch only — never the real corpus)

- `ContentIndexTests`: `upsertBatch` parity (batch insert searchable, `indexedCount` correct, reindex
  within a batch replaces the old body); existing tests stay green (verifies the `upsert`→`upsertRow`
  refactor + WAL pragmas are transparent).
- **bm25 ordering test:** upsert docs with a known term frequency; assert `search` returns them in
  bm25 order (and with column weights, that a `name`/`classification` hit outranks a body-only hit).
- **Parallel-extraction functional test:** write K small PDFs to `NSTemporaryDirectory()`, extract
  **concurrently** via a task group, assert each body/classification — proves distinct-instance PDFKit
  parallelism holds. (Temp dir, cleaned up.)
- **Maintenance test:** after a batch, `performMaintenance()` leaves the index searchable and (WAL on)
  runs without error; a 0-row pass skips it.
- **Perf smoke (manual, in review):** copy a few hundred PDFs from `Test files/` into the scratchpad,
  run a throwaway indexer pass, confirm completion + search hits; eyeball speedup vs. serial baseline.

## Verification

- `xcodegen generate` in the worktree; `xcodebuild -scheme ArchiveReader -configuration Debug
  -derivedDataPath ./build/DD build` — **no new warnings**.
- Full test suite via the `test` action.
- Reader smoke test (`SMOKE_TEST.md`) for the index/search path; GUI-verify that a text query reorders
  the list by relevance and reverts to the prior sort when cleared.
- Tier-2 adversarial self-review of the diff (data races, cancellation, rollback, epoch guard,
  actor-reentrancy invariant, `.relevance` lifecycle).

## Docs (same commit as the code — definition of done)

- `SUITE_TODO.md`: tick the *P2 — Reader performance* item, cite the commit hash.
- `ArchiveReader/CLAUDE.md`: update the *Content index* architecture bullet — parallel bounded
  extraction + batched transactions + WAL + end-of-pass maintenance; the core-reservation/QoS measure;
  and the new **relevance sort** (auto while a query is active). Add `bm25`/`relevance` to §Decisions.
- Delete this `execution-plans/index-parallelization.md` on ship (git keeps history).

## Rollout / risk

- **Sequencing:** Part A (build speed) and Part C (ranked search) are independent; A is the priority.
  A can ship first; B is tiny and folds into A; C can be a follow-up commit if the diff gets large.
- Behavior parity: single-file `upsert` signature/semantics unchanged → callers + tests unaffected.
- Memory: bounded window caps simultaneously-open `PDFDocument`s (no unbounded fan-out on 150k).
- **PDFKit** distinct-instance concurrency is the one genuinely parallel thing introduced — validate on
  the corpus; if it ever misbehaves, fall back to **serial extraction** but keep A2/A3/A4 (still a large
  win — the wins are independent).
- Related follow-on: `execution-plans/index-pruning.md` (bounding index growth) reuses A5's
  `existingMTimes` snapshot pattern.
