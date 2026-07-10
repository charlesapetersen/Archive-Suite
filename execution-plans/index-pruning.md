# Execution plan — prune the content index (Reader)

**Goal:** bound the content index's growth and make its corpus-wide counts correct at the source, by
removing rows for files that no longer exist under the current root — **without ever deleting a row
for a still-present file**.

**Scope:** `ArchiveReader/macOS/Sources/ArchiveReader/Search/ContentIndex.swift` (a new gated prune
method) + `Search/ContentIndexer.swift` + one gated call site in `Views/NavigationModel.swift`
(+ tests). The index is a **disposable, rebuildable SQLite cache** — a `DELETE` here is a cache
eviction, never a corpus mutation, and is allowed by the write-surface lint (which bans *filesystem*
deletes, not cache SQL). No SPEC/`TagWriter` change. **Risk: Tier-2** (destructive cache op gated on
live-query state) → adversarial self-review + tests on a scratch DB.

> **Grounded against the code, 2026-07-09** by the `index-plan-verify` workflow (reviewer verdict:
> *needs-change, not blocker* — the naive form is unsafe; the gated form below is the required fix).

## Why (today)

The content index is **never pruned** — rows for deleted/moved files and for previously-indexed roots
accumulate forever. The code already *works around* the resulting over-count with path-scoped queries
(`ContentIndex.needsAttentionCount(among:)`), but the DB still grows unbounded and the corpus-wide
`needsAttentionCount()` / `indexedCount()` over-report.

## The trap — why the naive version is UNSAFE (do not ship it)

"During an indexing pass, DELETE index rows whose path ∉ `library.files`" would **delete most of the
index on every launch and every root switch**, and can delete live rows in steady state. Two verified
transient-absence windows exist **within a single root** — so the owner's "root rarely changes"
assumption does **not** cover them:

1. **Empty/partial gather (severe).** `ArchiveLibrary.start(scope:)` sets `files = []`
   (`ArchiveLibrary.swift:63`) *before* Spotlight returns anything, and `files` is `@Published`, so the
   empty state immediately fires `libraryDidChange()` with an empty list
   (`NavigationModel.swift:71-77,400,410`). `start` runs at launch (`:105`) and on every root switch
   (`:490`). A prune on that snapshot deletes **everything**.
2. **Transient live-update drop (subtle).** `NSMetadataQueryDidUpdate` also routes to `reload()`
   (`ArchiveLibrary.swift:47-49,126-157`); Spotlight can momentarily drop a still-present file from the
   result set (e.g. right after a `TagWriter` xattr write re-indexes it) and re-add it on the next
   update. `isGathering` is **false** during this window, so an `isGathering`-only gate doesn't cover it.

## Design — gated, scoped, batched, its own pass

A prune runs **only** from a settled, non-empty, scope-correct snapshot, and never off the raw
`library.$files` sink.

1. **Its own gated pass — not folded into `startIndexing`.** `indexer.startIndexing(files)`
   (`NavigationModel.swift:410`) is intentionally a harmless no-op on an empty/partial set; a
   destructive delete must **not** ride that emission. Add a separate `indexer.pruneIfSettled(...)`
   call with stricter preconditions.
2. **Gate 1 — settled + non-empty:** only when `library.isGathering == false && !library.files.isEmpty`.
   Closes window (1).
3. **Gate 2 — confirm across two emissions (debounce):** a path is eligible for deletion only if it is
   absent from **two consecutive** post-gather snapshots (or after a short settle timer). Closes window
   (2)'s transient drop. Alternative/adjunct: expose it as a **user-initiated "Compact index"** action
   (File menu) so deletion is never fully automatic — decide during implementation; the automatic
   two-emission gate is the default.
4. **Scope to the current root.** Only rows whose path is under `rootStore.root` are prune-candidates,
   using the same path-**component-boundary** test as `NavigationModel.sanitizedPathPrefix`
   (`:311-316`) — **not** a substring `LIKE`. This prevents wiping a previously-indexed root's rows on
   a (rare) root switch and matches the existing scope-to-current-root pattern (`:277`). Under the
   "root rarely changes" assumption, cross-root rows simply linger harmlessly until a compact within
   that root; no `root_id` column / per-root DB needed.
5. **Batched delete, in-memory diff.** Reuse Part A's `existingMTimes()` snapshot pattern: one
   `SELECT path FROM files`, compute `victims = (indexed paths under root) − (current library set)`
   in memory, and `DELETE` victims in ~500-row transactions. Avoids a pathological
   `DELETE … WHERE path NOT IN (<150k binds>)` single statement.

## API sketch

- `ContentIndex.pathsUnder(prefix:) -> [String]` (or reuse `existingMTimes` keys + in-memory prefix
  filter) → the indexed paths under the current root.
- `ContentIndex.deletePaths(_ paths: [String])` → batched `DELETE FROM files … ; DELETE FROM fts …`
  in ~500-row transactions (mirror `upsertBatch`'s transaction discipline + the actor-reentrancy
  invariant: no `await` between `BEGIN` and `COMMIT`).
- `ContentIndexer.pruneIfSettled(currentPaths:root:)` → does the in-memory diff + the two-emission
  confirm, then calls `deletePaths`.

## Test plan (scratch DB only)

- Seed a scratch index with rows for paths A,B,C; call prune with a current set {A,B} under a root that
  contains all three → only C deleted; A,B intact; search/counts reflect it.
- **Empty-set guard:** prune with `isGathering == true` or an empty current set → **no deletion**.
- **Transient-drop guard:** a path missing from one snapshot but present in the next → **not** deleted.
- **Scope guard:** rows under a *different* root prefix are never touched.
- Counts: after a prune, `indexedCount()` / corpus-wide `needsAttentionCount()` drop to the live set.

## Verification

- Clean build (no new warnings); full test suite; Reader smoke test.
- Tier-2 adversarial self-review focused on the gate: prove no path in the live corpus can be deleted
  by any interleaving of gather/update emissions.

## Docs (same commit as the code)

- `SUITE_TODO.md`: tick the pruning item, cite the commit; note that corpus-wide counts are now
  correct at the source (the `among:`-scoped workaround can stay as defense-in-depth).
- `ArchiveReader/CLAUDE.md`: update the *Content index* bullet — "incremental **and pruned** (gated on
  a settled, scope-correct snapshot)".
- Delete this plan on ship.

## Dependencies / sequencing

- Best done **after** `index-parallelization.md` ships — it reuses that plan's `existingMTimes()`
  snapshot pattern and the `upsertBatch` transaction discipline. Independent otherwise; low user-facing
  urgency (it's growth/hygiene, not a visible feature).
