# W46.vision-short-reads — are any cached Vision readings short, and what makes Vision read short?

W46.p16-dewarp-floor's first prep batch (2026-11-18 23:42 to 2026-11-19 00:06, `dewarp_placement.py prep`) read about
15% fewer lines on 37-45 of 64 flattened photographs per dewarper, a strict subset of a lone read of the same JPEG. The
readings were discarded, and that runner now reads twice. It was the second such fault: W46.vision-run-guard's 04:49 run
on 2026-11-11 read 58 of the 96 short. This item checked the cached readings that committed results rest on, looked for
the cause, and widened the guard.

**No committed result rests on a short reading that could be found.** Every cache read on macOS 27.2 re-reads the same
(identical, or within the guard's slack on a handwritten page). The caches read on 26.6 cannot be compared page by page,
because the OS update changed nearly every text. But none of their 13 batches leans short beyond what the update alone
does. The cause is still unknown. Neither battery power, Low Power Mode, background QoS, concurrent readers nor CPU or GPU
load is enough to bring the fault back. The guard now reads every page twice, and four runners that did not use it do now.

Scripts: `scripts/segbench/vision_short_reads.py` (cross, reread, split, place-print, reproduce) and
`scripts/segbench/vision_guard.py` (the second read). Counts and hashes only, in `vision-short-reads/*.json`. macOS 27.2
(26B131), `segbench-dewarp` 8c0741beaa66c9b4, read on 2026-11-19 on AC power under the heavy lock, $0.

## Same bytes, every cached reading (cross, nothing read)

Each image read more than once across the caches' jobs files, plus the Real5 photographs that `place-geom-real5`
(2026-11-05) and `dewarp-guard` (2026-11-11) both read: 419 images, 850 readings. Of these, 417 images read identically
every time, two within slack, and **none short**. That covers 310 Real5 photographs, which can no longer be re-read
(they were fetched into `/tmp` and deleted), and the 96 owner originals in `colour-dropout`'s 05:38 run on 2026-11-11
(the good one) against `enh-dewarp`'s 27.2 raw row.

## A sample of 20 per cache, read again twice (reread)

Seeded, 20 pages a cache (15 for ocr-panel-jpeg, all it has), each read twice in separate guarded processes. The verdict
compares the cached reading with the first new one; "shorter" means the cached reading has more than one line, or 3% of
words, fewer.

| cache (the result it feeds) | read on | n | identical | within slack | cached shorter | cached longer | the two new reads |
|---|---|---|---|---|---|---|---|
| ocr-panel-local (owner panel, 27.2 swap) | 11-04 | 20 | 20 | 0 | 0 | 0 | identical 20 |
| capture-ladder | 11-03 | 20 | 20 | 0 | 0 | 0 | identical 20 |
| bench-corpus routes (440 set, 27.2 swap) | 11-04 | 20 | 20 | 0 | 0 | 0 | identical 20 |
| place-curved-owner `lines-up` (upright copies made again) | 11-10 | 20 | 20 | 0 | 0 | 0 | identical 20 |
| colour-dropout | 11-11 | 20 | 19 | 1 | 0 | 0 | p053 differs past slack |
| owner-set-grow | 11-18 | 20 | 20 | 0 | 0 | 0 | identical 20 |
| date-full-date sheet | 11-18 | 20 | 20 | 0 | 0 | 0 | identical 20 |
| place-print, all 121 pages, `accurate` (81 with a cached reading) | 11-03 | 81 | 80 | 1 | 0 | 0 | p048 within slack |
| place-print, all 121 pages, `documents` (81) | 11-03 | 81 | 81 | 0 | 0 | 0 | p048, p054 differ past slack |
| enh-dewarp arms (26.6) | 10-22 | 20 | 2 | 6 | 6 | 6 | identical 20 |
| ocr-panel-jpeg (26.6) | 10-29 | 15 | 0 | 9 | 2 | 4 | identical 15 |
| bench-corpus sample (26.6) | 10-17/18 | 20 | 0 | 6 | 11 | 3 | identical 20 |

On 27.2 the differences are all on handwritten pages that move from run to run: p053 flips between 26 lines / 151 words
and 25 / 142. Vision's RecognizeDocumentsRequest (place-print's `documents` arm) reads p054 at 16 or 20 lines, and the
Bentham page 116_244_001 at 7 lines (four of five reads, and the cached one) or 24 (one). In each of these the cached
reading is the commoner one. The 26.6 rows differ in both directions because the update moved Vision (95 of the 96
texts, `vision-27-reread.md`), so they are judged by direction below.

## The caches read on macOS 26.6, read whole on 27.2 (split)

A short batch shows up as most of its pages reading shorter. The OS update has its own split, taken from
W46.vision-27-reread's dated 26.6/27.2 pairs. Each batch is set beside the pair for its material:

| batch | made | shorter | longer | within slack | identical | baseline (26.6 against 27.2) |
|---|---|---|---|---|---|---|
| baseline: owner lines, `enh-dewarp/lines/raw-26.6` | 10-22 | 32 | 31 | 35 | 1 | — |
| baseline: owner text, `ocr-panel-local/vision-26.6` | 10-14 | 41 | 53 | 44 | 1 | — |
| baseline: 440 set, `bench-corpus/routes/vision-26.6` | 10-17 | 173 | 108 | 39 | 0 | — |
| enh-dewarp docres | 10-22 | 26 | 27 | 34 | 12 | owner lines |
| enh-dewarp enc-1600-q90 | 10-22 | 28 | 41 | 29 | 1 | owner lines |
| enh-dewarp enc-2048-q85 | 10-22 | 26 | 37 | 34 | 2 | owner lines |
| enh-dewarp enc-2400-q90 | 10-22 | 28 | 36 | 34 | 1 | owner lines |
| enh-dewarp quad | 10-22 | 32 | 34 | 32 | 1 | owner lines |
| enh-dewarp uvdoc | 10-22 | 26 | 30 | 42 | 1 | owner lines |
| enh-dewarp quarter / quad-quarter / uvdoc-quarter | 10-22 | 7 / 5 / 6 | 9 / 11 / 11 | 4 / 4 / 3 | 0 | owner lines |
| enh-dewarp hand | 10-22 | 2 | 0 | 2 | 0 | owner lines |
| enh-dewarp raw (the 27.2 swap) | 11-04 | 0 | 0 | 1 | 95 | — |
| ocr-panel-jpeg | 10-29 | 2 | 4 | 9 | 0 | owner text |
| bench-corpus sample | 10-17 | 165 | 110 | 43 | 0 | 440 set |
| bench-corpus sample | 10-18 | 177 | 107 | 49 | 4 | 440 set |

The faulty batches read 60-70% of their pages short. No batch here comes near that. The owner-material batches split
about evenly, like their baseline. The 440 set leans short (54-55%), and so does its baseline (54%); that is the update,
not a fault.

## Not checked

- `dewarp-placement`: its flattened images and their readings were deleted with the item's scratch. Its committed
  figures rest on readings made twice. UVDoc, DocScanner-L and DocGeoNet's run 1 equal their read-twice reruns on every
  arm and line, and DvD's run 1 lies inside its rerun floor (`dewarp-placement.md`).
- `enh-ocr-input`: no Vision reading or arm image is left in its cache.
- `place-hands`, `place-truth-lines`, `place-geom`: no Vision line cache (their hypotheses come from other readers).

## Looking for the cause

- **Power.** The 18 November batch ran on battery (the pmset log has the Mac on battery from 17:41 to 00:30, charge
  falling to 48%) with Low Power Mode enforced, and the reads that agreed 40 minutes later ran on AC. But the 11:37 prep
  that morning also ran on battery with Low Power Mode enforced (dasd's log). Its DocScanner-L and DocGeoNet readings
  equal their reruns. So battery and Low Power Mode are not enough. The pmset log does not reach back to 11 November.
- **The runtime.** Vision recognised about 63 images a minute in the bad window against 160 in a good one at 01:03. The
  good 11:37 battery run was slower still (43). The bad window shows no `E5RT Error` from TextRecognition. Model-asset
  readiness messages (modelcatalogd's "NOT ready") came at the same rate as in a good window.
- **Other work.** The heavy lock's other slot held nothing from 23:41 to 00:06. Another engine session started at 23:41:59
  and took the lock at 00:06:43.
- **Reproduction.** The 96 were read by `segbench-dewarp lines` under each condition:

  | condition | seconds | lines | words | pages changed | pages past slack |
  |---|---|---|---|---|---|
  | baseline | 16.3 | 4,451 | 29,200 | — | — |
  | background QoS (`taskpolicy -b`) | 77.4 | 4,454 | 29,214 | 2 | p053 |
  | four readers at once (each) | 21.8 | 4,450-4,451 | 29,191-29,200 | 0-2 | p053 (one reader) |
  | torch CPU load beside (12 threads) | 17.4 | 4,451 | 29,200 | 1 | — |
  | torch GPU load beside (MPS) | 18.9 | 4,451 | 29,200 | 1 | — |
  | background QoS and CPU load | 70.1 | 4,454 | 29,214 | 3 | p053 |
  | baseline again | 16.1 | 4,451 | 29,200 | 1 | — |

  None reproduces it. Memory pressure was not tried: simulating it needs root, and filling memory by hand would run into
  the engine's memory stop.

**A third fault, of another kind, during this item.** At 02:12:38 on 2026-11-19 a guarded `segbench-ocr` run over the
bench-corpus sample stopped writing after 160 of its 655 pages. TextRecognition logged about 500 `E5RT Error:
e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed (Code: 13)` over 28 s, and
the process then exited. The guard refused the run on its missing end references and quarantined the 160 outputs. Those
160 match a clean run of the same pages (159 identical, one within slack), so this fault leaves pages missing, not short.
The next run, four minutes later, was clean.

## The guard, widened

- `vision_guard.run` now reads every page a run writes a second time, in a separate guarded process. A page is settled
  once two of its readings agree within the slack, and the first of the agreeing pair is kept. A page still unsettled
  after five reads is quarantined and the run refused. If a re-read's references come back short, the run's first
  readings are quarantined too. On real Vision, 12 of the 96 including p048, p050 and p053 settle with both tools
  (6.9 s and 8.1 s). The second read costs about the time of the first.
- The reference check stays as well. A fault that lasts longer than a run, as the 18 November one did (about 20
  minutes, several processes), would give two agreeing short reads that only the references catch.
- Now guarded: `dewarp_placement.py` (each pass of its own byte-for-byte read-twice), `place_curved.py` (the survey's
  parallel readers and the upright re-read), `date_undated.py` (both Vision calls) and `licence_sweep.py` (BLN600's
  Vision pilot). Still unguarded: `segbench-ocr-lines` (`item_fields_retruth`), `layout_photo_vision`,
  `place_print_vision` and `segbench-ocr-orient`. Their output forms differ, and none has shown a fault.

## Measurement card

- **Truth.** None. Vision readings are compared with Vision readings of the same bytes, and nothing is scored.
- **Selection.** The samples are seeded (`W46.vision-short-reads <cache>`) from each jobs file's rows whose image and
  reading are still cached. The split reads whole caches, and the cross check takes every repeated image. Nothing was
  chosen by a route's result or by ABBYY text.
- **Comparison.** The same cached binaries and settings throughout. The cached readings were made with the binary of
  their day: place-curved-owner's with `/tmp/pco-dewarp`, built from the same `dewarp.swift`, and everything on 26.6
  with the older builds.
- **Noise.** On 27.2 typed pages read identically from run to run. Handwritten pages move, a few past the slack (p053,
  p048, p054, 116_244_001 under `documents`). A 26.6 batch is judged against the OS change's own split, not page by page.
- **Scope.** A sample of 20 cannot rule out a few short pages in a cache, only a batch fault like the two seen (most
  pages short). The 26.6 caches are checked by direction only. The cause of the 11 and 18 November faults is not found,
  and the E5RT fault seen here may or may not be related. Nothing here says anything about the Processor app's own Vision
  path.
