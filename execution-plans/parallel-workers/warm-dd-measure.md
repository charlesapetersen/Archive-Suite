# W35.warm-dd-measure — cold vs warm DerivedData, per app (measured 2026-10-08)

Evidence for `W35.warm-dd` (efficiency plan item 14). The rule, fixed before measuring: build `W35.warm-dd` only
if the moved-tree case saves at least 30% or 60 s of the cold median for at least two apps.

**Verdict: YES — build `W35.warm-dd`.** The moved-tree build saved 86% (Reader), 86% (Notes) and 93% (Processor)
of the cold median, 93-227 s per build. All three apps clear both thresholds.

## Method

`xcodebuild -scheme Archive<App> -configuration Debug -derivedDataPath ./build/DD build` (the AGENTS.md build
command), after `xcodegen generate`. Each build ran under `heavy-run.py run`, with the clock started *inside* the
lock, so the figures exclude lock waits (Vision OCR held the Mac lock for minutes at a time during the runs).
Three runs per app, interleaved Reader → Notes → Processor so load drift spreads across apps. Each run:

1. **cold** — a fresh detached worktree at `6b319b3` with an empty `./build/DD`.
2. **oneline** — a comment line appended to one app source file (`Search/ArchiveLibrary.swift`,
   `ArchiveNotesCommands.swift`, `Capture/CaptureModels.swift`), same tree, rebuild.
3. **moved** — the probe reverted, the same tree path checked out at `2154db2` (10 commits later on main:
   about one session's worth of parallel-worker traffic; it changes one Reader source file and Notes UITests),
   `xcodegen generate`, rebuild.

A fourth run per app measured a pessimistic move instead: cold at `461bba7`, then moved to `5c9cb7d`
(W37.dual-date — +24 lines in ArchiveCore's public sources, plus 22 Processor files). Of the last 100 main
commits only 3 touched Reader sources, 17 Notes, 2 Processor and 4 ArchiveCore, so a typical move is closer to
case 3 than to this one.

Scripts: kept in the session's scratch dir only (`/tmp/wdd-measure/measure.sh`); the method above is all of it.

## Results (wall seconds inside the lock)

| App | cold (runs) | cold median | oneline (runs) | oneline median | moved (runs) | moved median | moved saves |
|---|---|---|---|---|---|---|---|
| Reader | 204, 86, 132 | 132 | 21, 15, 19 | 19 | 20, 16, 19 | 19 | 113 s · 86% |
| Notes | 125, 67, 108 | 108 | 29, 12, 22 | 22 | 15, 10, 19 | 15 | 93 s · 86% |
| Processor | 214, 259, 243 | 243 | 19, 33, 26 | 26 | 16, 16, 18 | 16 | 227 s · 93% |

Pessimistic move (ArchiveCore public-source change), one run each:

| App | cold | moved to `5c9cb7d` | saves | SwiftCompile steps, cold → moved |
|---|---|---|---|---|
| Reader | 90 | 26 | 71% | 95 → 10 |
| Notes | 70 | 39 | 44% | 129 → 83 |
| Processor | 257 | 216 | 16% | 174 → 104 |

Processor's 16% is that commit's 22 Processor files recompiling, not a lost cache.

**SPM.** The Reader logs four `Fetching from … (cached)` lines (swift-snapshot-testing and its swift-syntax,
swift-custom-dump, swift-issue-reporting dependencies) on every cold build and none on any warm build: the
global SwiftPM cache spares the network, but each fresh DerivedData re-clones and recompiles those packages,
swift-syntax among them. Notes and Processor have no remote packages and fetched nothing. `xcodegen generate`
took 0.1-0.35 s in every case and is not a factor.

## Caveats

- Daemon sessions run QoS-background-clamped, so the absolute seconds may be inflated relative to an
  interactive run; the verdict rests on the ratio threshold, which every app clears by a wide margin.
- Cold variance is large (Reader 86-204 s) from concurrent load outside the lock; warm builds are tight.
- Each Reader build at `6b319b3` reports one pre-existing warning (`ArchiveLibrary.swift:650`, weak/strong
  capture), fixed by `2154db2`; it is not introduced by this measurement.
- `build` only. A session's `xcodebuild test -only-testing:<App>Tests` also compiles the test bundle, so its
  cold cost (and the saving) is larger than these figures.

## For W35.warm-dd

Add the re-measured warm figure from the stable tree here when that item lands.
