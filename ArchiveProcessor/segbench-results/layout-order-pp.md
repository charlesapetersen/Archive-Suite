# W46.layout-order-newspapers-pp — region order on PP-DocLayoutV3's own regions, on L9

The app runs PP-DocLayoutV3 on newspapers (`13-stage-rules/03-layout.md` section 3). W46.layout-order ran the
geometric orderers only on DocLayout-YOLO's regions on L9, so it never asked whether PP-DocLayoutV3's regions read
better in another order than its own. This item answers that: **read them in the detector's own order.** The app
region sort and HDBSCAN both lose to it, beyond the interval on tau and on the order gap.

## What was run

- **Inputs.** These are W46.layout-order's L9 inputs, already in the bench cache (`layout-order/`), so nothing was
  detected or read again:
  - NewsBench's 15 Library of Congress pages.
  - Apple Vision's lines at the app's settings.
  - PP-DocLayoutV3's regions (MLX port, 1,024 px, confidence 0.5). Body classes only: text, paragraph and doc
    titles, abstract, content.
  - The volunteer transcriptions.
- **Arms.** Every orderer in `layout_order.py` ordered PP-DocLayoutV3's body regions on each page: top to bottom,
  the benchmark's column clustering and XY-cut, rows-first XY-cut, the app region sort (`LayoutModel.crops`), HDBSCAN
  and the app line column sort run on regions. They are scored beside the detector's own order (`pp_native`). The app
  line column sort on the lines themselves, with no regions, is one more reference row.
- **Line sets.** Each line takes its region's place and is read top to bottom inside it. There are two sets, and
  each is the same for every arm:
  - `own`: the 7,601 Vision lines that fall in a PP-DocLayoutV3 body region. This is the stream the app reads.
  - `all`: all 8,135 lines. The 534 lines outside the regions go last, top to bottom, in every arm.
- **Scorer.** The same as W46.layout-order's L9 panel:
  - tau over the lines placed in the transcription (15-line floor; all 15 pages valid);
  - word accuracy;
  - the order gap (order-free bag-of-words F1 less word accuracy, in points; lower is better);
  - OmniDocBench's reading-order edit (lower is better).

  Each arm is paired against the native order over the 15 pages: the mean difference and a 95% page-bootstrap
  interval, the same code as `layout_pair_newspapers.paired`.
- **Reproduction check.** Before scoring, W46.layout-order's L9 panel was rerun from the same cache. All 150 of its
  per-page figures came out identical (every arm but HDBSCAN, whose orders were computed in the other Python; see
  Caveats).
- **Commands** (in `scripts/segbench/`):
  - `layout_order_pp.py orders` writes the region orders to the cache;
  - `layout_order_pp.py run` scores them;
  - the tests are `test_layout_order_pp.py` (3 pass).
- **Cost.** $0: no model, network or cluster.

## Results

The `own` set, Vision lines inside PP-DocLayoutV3's body regions, 15 pages, all valid. Δ is the arm less the native
order, with its 95% interval.

| Ordering of PP-DocLayoutV3's regions | tau | Δ tau | Word acc. | Order gap | Δ gap (points) | Reading-order edit | Δ edit |
|---|---|---|---|---|---|---|---|
| PP-DocLayoutV3's own order | **0.977** | base | **38.0%** | **21.6** | base | **0.121** | base |
| App region sort (`LayoutModel.crops`) | 0.900 | -0.077 [-0.175, -0.016] | 33.1% | 26.5 | +4.9 [+1.6, +8.6] | 0.217 | +0.096 [-0.008, +0.257] |
| HDBSCAN on x-centres | 0.905 | -0.072 [-0.148, -0.019] | 32.1% | 27.5 | +5.9 [+1.6, +11.7] | 0.268 | +0.147 [+0.067, +0.238] |
| Benchmark column clustering | 0.387 | -0.590 [-0.750, -0.415] | 15.8% | 43.8 | +22.2 | 0.366 | +0.245 |
| Rows-first XY-cut | 0.315 | -0.662 | 14.4% | 45.2 | +23.5 | 0.428 | +0.308 |
| Top to bottom (= benchmark XY-cut, = app line sort on regions) | 0.192 | -0.784 | 10.8% | 48.8 | +27.2 | 0.498 | +0.377 |
| App line column sort on the lines, no regions | 0.574 | -0.403 | 18.5% | 41.0 | +19.4 | 0.300 | +0.159 |

Notes on the table:

- The edit difference is over 14 pages, because the scorer gives no edit on one.
- Page by page, the native order is never lower than 0.920. The app region sort beats it on 2 pages and ties on 3;
  HDBSCAN beats it on none and ties on 2.
- On the `all` set (lines outside the regions go last in every arm) the order is the same:
  - native 0.846, gap 25.5;
  - app region sort 0.781, Δ tau -0.065 [-0.153, -0.013], Δ gap +4.8 [+1.5, +8.5];
  - HDBSCAN 0.783, Δ tau -0.063 [-0.136, -0.016], Δ gap +5.5 [+1.5, +11.0].
- Bag-of-words F1 is the same in every row of a set, because only the order differs.
- Word accuracy is low in every row because the truth is partial. Only the differences between rows measure order.

## What it says

1. **The order rule for the detector the app runs is its own order: a direction on 15 pages (at most 12 items, one collection), descriptive.** On PP-DocLayoutV3's regions, its
   coupled order leads the best geometric rules. Tau is 0.977 against 0.900 and 0.905, beyond the interval. The order gap is 4.9
   and 5.9 points smaller, also beyond the interval. On reading-order edit it ties the app sort and beats HDBSCAN.
   This is the rule `03-layout.md` section 3 already states ("the detector's own order"). It now rests on a paired
   measurement on newspapers, with the same detector, and no longer on a comparison across detectors; the intervals
   are page bootstraps over pages that are not independent (below), so they are optimistic.
2. **Why the app sort does worse here than on YOLO's regions.** On DocLayout-YOLO's regions the app sort reached
   0.905 (`layout-order.md`), level with its 0.900 here. The geometric rule did not get worse. PP-DocLayoutV3's own
   order is the strong arm. One likely reason, read from the method and not measured: its order is learned with the
   regions, while a sweep by x-centre has no notion of a headline that spans the columns below it.
3. **No change to the app.** When a detector runs, the app keeps the detector's order. The app region sort stays
   the order for a detector that gives none.

## Caveats

- n is 15 pages, one source (Library of Congress scans): 14 carry the `mss34132` prefix and four share one item, so
  they hold at most 12 items, almost all from one collection. Photographed newspapers are not measured here, as in
  `layout-pair-newspapers.md`.
- The truth is NewsBench's volunteer text, partial on some pages; tau is over the lines placed in it (4,157 of 7,601).
- HDBSCAN's orders were computed in another offline Python (one with scikit-learn and no compiled rapidfuzz), then
  scored with the same scorer. The orders are deterministic geometry, so this changes nothing measured. The other
  arms reproduced W46.layout-order exactly in the scoring Python.

## Measurement card

- **Truth.**
  - NewsBench's volunteer transcriptions of the 15 L9 pages: public, partial on some pages.
  - No model drafted it, so no scored arm is a drafter or a relative of one.
  - No owner check: it is a public set.
- **Selection.** All 15 L9 pages, as in W46.layout-order. None was chosen by a tested route or by ABBYY text.
- **Comparison.** Every arm orders the same PP-DocLayoutV3 body regions, over the same Vision lines, with the same
  scorer and floor, so only the ordering stage differs. The native order is the detector's own output for the same
  regions.
  - Both OCR sets: this is the public half. The owner's half is `layout-order-marks.md`: on the 96, PP-DocLayoutV3's
    own order scores 0.992 and the app region sort on its regions 0.961. That is the same direction, a tie by
    interval there.
- **Noise.**
  - n is 15, paired, page bootstrap.
  - Every arm is deterministic geometry on fixed boxes, so there is no rerun floor to add.
  - The tau and gap intervals for both geometric rules exclude 0. The app sort's edit interval crosses 0, so on edit
    it is a tie.
- **Scope.**
  - A direction, not settled: region order on PP-DocLayoutV3's regions on scanned newspapers (a direction on 15 pages (at most 12 items, one collection), descriptive).
  - Not settled: photographed newspapers; other detectors' regions; marks in the stream; handwriting, which the
    detector decides (`layout-order.md`).
