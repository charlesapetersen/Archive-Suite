# Execution plan — parallel + batched content indexing (Reader)

**Goal:** make Archive Reader's content-index build **much faster** (first-run + post-schema-bump
re-index over up to ~150k PDFs) **without** making the main UI unusably slow while it runs.

**Scope:** `ArchiveReader/macOS/Sources/ArchiveReader/Search/ContentIndex.swift` +
`ContentIndexer.swift` (+ their tests). No change to the tag/PDF SPEC, no change to `TagWriter`, no
new write surface — extraction stays strictly read-only; the index is the same disposable,
rebuildable SQLite cache. **Risk: Tier-2** (touches actor isolation) → adversarial self-review + a
functional test on scratch copies (never the real corpus).

## Problem (measured from the code, 2026-07-09)

`ContentIndexer.launch` runs **one** `Task.detached` that walks the file list in a serial `for`
loop: `PDFTextExtractor.extract` (CPU+I/O-bound PDFKit parse of every page) then `await idx.upsert`,
one file at a time on a single core. `ContentIndex.upsert` wraps **each** file in its own
`BEGIN…COMMIT` → one fsync per file. So two bottlenecks: (1) extraction is single-threaded;
(2) writes are one-transaction-per-file.

## Approach — three independent wins

### 1. Parallelize extraction across cores (the main win)
Extraction is embarrassingly parallel: each file is independent and gets its own `PDFDocument`.
Replace the serial loop with a **bounded** `withTaskGroup` (sliding window of width `workers`). Each
child captures **primitives only** (`url`, `path`, `mtime`, `name` — not the whole `ArchiveFile`),
runs the CPU-bound `PDFTextExtractor.extract` off-actor, and returns a `Sendable` `IndexRow`. The
`ContentIndex` actor keeps all DB writes serialized (correct — one SQLite connection). Expected
~4–8× on the extraction-bound portion on a multicore Mac.

### 2. Batch DB writes into transactions (pairs with #1)
Add `ContentIndex.upsertBatch(_ rows: [IndexRow])` that wraps ~500 rows in **one**
`BEGIN IMMEDIATE…COMMIT` (ROLLBACK on error). Refactor the existing per-file `upsert` body into a
private `upsertRow(...)` (no BEGIN/COMMIT); keep `upsert(...)` as the single-file wrapper so its
signature/behavior — and every existing test/caller — is unchanged. Once extraction is parallel,
per-file fsync would otherwise become the new bottleneck; batching is a classic 10×+ on bulk
SQLite/FTS5 inserts.

### 3. WAL + relaxed sync during bulk load (safe here)
In `open()`, after `busy_timeout`: `PRAGMA journal_mode = WAL;` and `PRAGMA synchronous = NORMAL;`.
WAL also lets full-text **search reads run concurrently with the indexing writes** (less UI stall on
search during a pass). Aggressive in general, but this DB is a **disposable cache** — a crash just
means re-indexing, which is already the safe fallback — so durability is a non-issue. (Not going to
`OFF`; `NORMAL` is the reasonable floor. WAL leaves `-wal`/`-shm` sidecars — fine for a cache.)

### Skip-check without per-file actor round-trips
Add `ContentIndex.existingMTimes() -> [String: Double]` (one `SELECT path, mtime FROM files`). The
indexer pulls the skip-map once and partitions `files` into `work` (mtime differs) vs skipped
in-memory, instead of a serialized `await needsIndex` per file. `needsIndex` stays for single-file
callers/tests.

## Keeping the UI usable while indexing (the "easy way")

Two cheap, targeted measures — no architectural change:

1. **Reserve cores:** `workers = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)`. Leaving
   ~2 cores free keeps CPU headroom for the main (user-interactive) thread + system, so a full-core
   PDF-parse storm can't peg the machine. On an 8-core Mac → 6 workers (still ~6× parallel); on a
   4-core → 2.
2. **Low QoS:** keep the detached task **and** its child tasks at `.utility`. Under CPU contention
   the scheduler favors the main thread's user-interactive QoS, so scrolling/typing stays ahead of
   indexing.
3. **WAL (from #3)** removes writer-vs-reader lock stalls so a search issued mid-index isn't blocked.

Progress reporting already hops to the main actor only every 100 files (cheap) and is epoch-guarded
— unchanged.

> Note: the *other* known nav-window jank (Table re-diff per keystroke at 40k) is a **separate**,
> already-tracked item (AppKit `NSTableView` swap in `SUITE_TODO.md`) — out of scope here.

## Concurrency-safety notes (Tier-2)

- Child tasks are **pure producers**: they only read the filesystem and return a value. All mutable
  state (`batch`, `done`, the work iterator) is touched **only** on the awaiting parent task between
  `group.next()` results — no shared mutable state across children, no locks needed.
- `IndexRow` is a `Sendable` value type; nothing non-Sendable crosses the task boundary (capture
  primitives, not `ArchiveFile`).
- **Cancellation:** the parent detached `Task.cancel()` (scope change / empty set) propagates to the
  group; loop checks `Task.isCancelled`, breaks, `group.cancelAll()`, and the epoch (`generation`)
  guard already stops a superseded pass's `report`/`finish` from clobbering newer state. Coalescing
  via `pending` is untouched (it wraps `launch`).
- **PDFKit:** distinct `PDFDocument` instances on separate threads are expected-safe, but this is the
  one assumption to *prove* — see functional test below.

## Test plan (scratch only — never the real corpus)

- `ContentIndexTests`: add `upsertBatch` coverage — batch insert is searchable, `indexedCount`
  correct, a reindex within a batch replaces the old body (parity with single `upsert`); existing
  tests must stay green (verifies the `upsert`→`upsertRow` refactor + WAL pragmas are transparent).
- **Parallel-extraction functional test:** write K small PDFs to `NSTemporaryDirectory()`, extract
  them **concurrently** via a task group, assert each body/classification — proves distinct-instance
  PDFKit parallelism holds. (Temp dir, cleaned up; never the corpus.)
- **Perf smoke (manual, in review):** copy a few hundred PDFs from `Test files/` into the scratchpad,
  point a throwaway indexer run at them, confirm it completes and search returns hits; eyeball the
  speedup vs. the serial baseline. Never against the real corpus.

## Verification

- `xcodegen generate` in the worktree; `xcodebuild -scheme ArchiveReader -configuration Debug
  -derivedDataPath ./build/DD build` — **no new warnings**.
- Full test suite via the `test` action.
- Reader smoke test (`SMOKE_TEST.md`) for the index/search path.
- Tier-2 adversarial self-review of the diff (data races, cancellation, rollback, epoch guard).

## Docs (same commit as the code — definition of done)

- `SUITE_TODO.md`: add the shipped item, cite the commit hash.
- `ArchiveReader/CLAUDE.md`: update the *Content index* architecture bullet — parallel bounded
  extraction + batched transactions + WAL, and the core-reservation/QoS UI-responsiveness measure.
- Delete this `execution-plans/index-parallelization.md` on ship (git keeps history).

## Rollout / risk

- Behavior parity: single-file `upsert` signature/semantics unchanged → callers + tests unaffected.
- Memory: bounded window caps simultaneously-open `PDFDocument`s (no unbounded fan-out on 150k).
- If the PDFKit-parallelism test ever shows instability, fall back to serial extraction but **keep**
  batched writes + WAL (still a large win) — the two wins are independent.
