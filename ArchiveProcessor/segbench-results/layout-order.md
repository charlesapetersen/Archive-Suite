# W46.layout-order — the ordering stage with detection held fixed

Gap audit §5 item 28, E-layout test 2. Produced by `scripts/segbench/layout_order.py run` (figures in
`layout-order.json`, per page and summarised). Free, on the Mac, 2026-10-28. Orli and the trained orderers (kraken
`rotrain`, an Orli fine-tune) are not in this note: they are `W46.layout-order-orli` and `W46.layout-order-train`.
Gemini asked for boxes in order is `W46.layout-order-paid`, and the 30 annotated owner pages are
`W46.layout-order-marks`.

## What was run

- **Pages.** The 40 scored pages of the historical reading-order benchmark (Jha, MIT; clone at commit `3688a62`;
  15 multi-column: English print, Swedish court hand and Middle-French manuscripts; 25 single-column). NewsBench's
  15 Library of Congress newspaper pages (L9).
- **Detection, fixed.**
  - DocLayout-YOLO DocStructBench (ONNX, 1024 px, confidence 0.25) and PP-DocLayoutV3 (MLX, 1024 px, 0.5), both
    run here through the Vision OCR lab's `ops/ocrlab/layout-regions.py`.
  - The benchmark's own YOLOv8m line boxes, from its bundled predictions.
  - Apple Vision's lines at the app's settings, for L9.
  - kraken blla, from the benchmark's bundled predictions and from the W43.script-specialists segmentation of L9.
- **Ordering stages.**
  - `topbottom` sorts by the y-centre.
  - `columns` and `xycut` are the benchmark's own, ported unchanged.
  - `xycut_yfirst` is recursive XY-cut as MinerU and PaddleX run it: rows first, then columns.
  - `app_regions` is the lab app's region sort, `LayoutModel.crops`: columns by x-centre, top to bottom.
  - `app_columns` is the lab app's line column sort, `SearchableWriter.columnOrdered`, run as the app's own Swift.
  - `hdbscan` is HDBSCAN on x-centres plus band rules. The IDI paper publishes no code, so these rules are our
    reading of it.
  - Native orders: kraken blla's, and PP-DocLayoutV3's coupled order on its own regions.
- **Scores.** Kendall tau over the matched lines, kept only on pages passing the benchmark's guard (at least 60% of
  the truth lines and at least 15). The order-induced word error assumes perfect recognition: the truth lines'
  own text, read in the predicted order. Body stream only, so running heads, folios, margins, stamps, quire marks
  and drop capitals are left out.
  - For L9, every arm orders the same Vision lines inside DocLayout-YOLO's body regions, so recognition is
    identical across arms. Order is then scored against the volunteer transcription three ways: tau over the
    lines found in it, the gap between the order-free bag-of-words F1 and word accuracy, and OmniDocBench's
    reading-order edit.
  - That transcription covers only part of some L9 pages, so L9 keeps the guard's 15-line floor and drops its
    60% share.

## Results

The tables show tau on the pages that pass the guard, as [valid pages/pages]. Word error is the mean over those
pages.

**Benchmark pages, the benchmark's line boxes.** This reproduces the paper (top to bottom 0.50, column clustering
0.99, word error 82% to 2%), which checks the scorer.

| Ordering | multi-column tau | single tau | word error from order, multi |
|---|---|---|---|
| top to bottom | 0.499 [15/15] | 0.970 [20/25] | 82.1% |
| benchmark column clustering | 0.989 [15/15] | 0.951 [20/25] | 1.9% |
| benchmark XY-cut | 0.499 [15/15] | 0.970 [20/25] | 82.1% |
| XY-cut, rows first | **0.990** [15/15] | 0.970 [20/25] | 1.8% |
| app region sort | 0.983 [15/15] | 0.933 [20/25] | 2.3% |
| app line column sort | 0.833 [15/15] | 0.970 [20/25] | 27.0% |
| HDBSCAN rule | 0.575 [15/15] | 0.956 [20/25] | 82.5% |
| kraken blla native | 0.991 [15/15] | 0.979 [21/25] | 1.9% |

**Benchmark pages, DocLayout-YOLO regions.** Each truth line takes its region's place.

| Ordering | multi-column tau | single tau | lines inside a body region |
|---|---|---|---|
| top to bottom, benchmark XY-cut, app line sort | 0.501 [5/15] | 0.996 [14/25] | 50% |
| benchmark column clustering | 0.893 [5/15] | 0.996 [14/25] | 50% |
| XY-cut, rows first | 0.829 [5/15] | 0.996 [14/25] | 50% |
| HDBSCAN rule | 0.850 [5/15] | 0.996 [14/25] | 50% |
| app region sort | **0.991** [5/15] | 0.996 [14/25] | 50% |
| PP-DocLayoutV3 native (its own regions) | **0.999** [15/15] | 0.998 [19/25] | 89% |

**L9 newspapers, Vision lines in DocLayout-YOLO body regions.** There are 15 pages, all of them valid.

| Ordering | tau | word acc. | order gap (bow F1 less word acc.) | reading-order edit |
|---|---|---|---|---|
| top to bottom, benchmark XY-cut, app line sort on regions | 0.198 | 10.6% | 50.0 | 0.689 |
| benchmark column clustering | 0.398 | 16.3% | 44.3 | 0.518 |
| XY-cut, rows first | 0.574 | 24.2% | 36.4 | 0.445 |
| app line column sort on Vision lines, no detector | 0.560 | 19.0% | 41.5 | 0.259 |
| app region sort | 0.905 | 34.1% | 26.5 | **0.147** |
| HDBSCAN rule | **0.922** | 34.8% | 25.8 | 0.249 |
| PP-DocLayoutV3 native | 0.881 | **37.2%** | **23.4** | 0.318 |
| kraken blla native | 0.293 | 14.3% | 46.3 | 0.515 |

The bag-of-words F1 is 60.6% in every L9 row, because the words are the same and only their order differs.

- **PP-DocLayoutV3** places 94% of the lines in its own regions. Its tau over those lines alone is 0.977.
- **kraken blla** finds lines covering only 67% of Vision's lines on these pages: about 200 lines on a page Vision
  reads 900 on. Its tau over its own lines is 0.754, so on L9 kraken loses on detection as much as on order.

## What it says

1. **Region order is solved by geometry on print; detection is what fails.**
   - On DocLayout-YOLO's regions, the app's own region sort reaches 0.991 on the multi-column print pages that
     pass the guard, and 0.996 on single-column pages.
   - On newspapers it reaches 0.905 tau with the lowest reading-order edit. HDBSCAN is level with it (0.922);
     PP-DocLayoutV3's coupled order is level too (0.881 overall, 0.977 on its own lines).
   - No ordering stage rescues a missing region. DocLayout-YOLO finds no body region at all on the Swedish court
     hand and three of the five Middle-French manuscripts, where PP-DocLayoutV3 finds them and orders them at
     0.999.
   - This bears on W46.layout-photo and the kind gate (route R8): on handwriting the detector, not the orderer,
     decides.
2. **The app's region sort is the right default and needs no change.** It beats the benchmark's column clustering
   on regions (0.991 against 0.893 multi-column, 0.905 against 0.398 on L9). Column clustering's gap rule is
   stated in line heights, which suits lines, not regions.
3. **The app's line column sort is not a region orderer.** `columnOrdered` needs line-shaped boxes, so on regions
   it finds no gutter and returns top to bottom.
   - On the benchmark's lines it reaches 0.833 multi-column, because it keeps the given order inside a column and
     refuses gutters it cannot prove. On L9's Vision lines with no detector it reaches 0.560.
   - So a newspaper page wants the detector and the region sort, not the line sort. That agrees with R1/R2's
     detector-first design.
4. **The paper's "XY-cut fails" is its implementation.** The benchmark's XY-cut asks for a vertical gap wider than
   1.2 median box widths, which no gutter is, so it never cuts a column and equals top to bottom.
   - XY-cut as the toolkits run it (rows first) reaches 0.990 on the same line boxes.
   - On regions it is weaker than the app's sort (0.829 multi-column, 0.574 on L9): a row of headlines across
     columns cuts the page into bands that are then read across.
   - E-layout claim 14 (XY-cut 0.50) should be read as "the benchmark's XY-cut".
5. **HDBSCAN is a region rule.** On line boxes, x-centre clusters split at every indent (0.575). On regions it is
   level with the app's sort on newspapers.
6. **Whether a trained orderer is needed is still open.** Geometry on detected regions is at 0.99 on public print,
   and PP-DocLayoutV3's order at 0.999 on manuscripts. The open question is the owner's pages with marks
   (`W46.layout-order-marks`). `W46.layout-order-train` waits on that result.

## Caveats

- The HDBSCAN rule is our reading of an unpublished method.
- The benchmark's images are reduced-quality redistributions. DocLayout-YOLO on full-resolution scans might find
  more regions on the manuscripts.
- L9's truth is partial on some pages, so word accuracy is low in every row. Only the differences between rows
  measure order.
- Multi-column region results rest on the 5 English pages that pass the guard.
