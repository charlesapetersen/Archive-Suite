# W46.layout-order-marks — the ordering stage on the owner's pages

Gap audit §5 item 28, the owner-page arm of W46.layout-order. Produced by `scripts/segbench/layout_order_marks.py`
(`detect`, then `run`; figures in `layout-order-marks.json`). Free, on the Mac, 2026-11-04.

## The item had to change shape

The item asked for tau on 30 annotated marks-set pages. The marks set's truth is the reconciled owner core:
mark boxes, each with a class and whether it touches print. It has no reading order, so tau cannot be scored on it.
Two panels instead, each scored only on truth it has:

- **Order on the 96 owner truth pages.** The owner's adjudicated text is in reading order.
- **Whether marks reach the ordered stream**, on the 32 detector-eligible marks-core pages.

## What was run

- **Lines.** Apple Vision's lines at the app's settings (`layout_order.swift lines`). Every arm orders this same
  line set, so recognition is the same in every row.
- **Detection, held fixed per detector** (measurement audit LAY-2). The regions come from W46.layout-photo's cache
  for the 96 and are run fresh for the marks pages.
  - DocLayout-YOLO with its picture regions kept (it labels hands `figure`), plus tables.
  - PP-DocLayoutV3's text classes, plus tables and aside text.
  - Vision's `RecognizeDocumentsRequest` regions.
- **Orderers.** Each arm keeps the lines inside its detector's regions and orders them with the geometric rules
  from `layout_order`. The native orders are PP-DocLayoutV3's and Vision's. Two arms use no detector: Vision's own
  line order and the app's line column sort (`columnOrdered`).
- **Score.** Tau is over the lines found in the truth text, on pages with at least 15 placed (the L9 rule). Word
  accuracy is over the whole truth, so it counts the lines an arm drops.
  - The base is the app's region sort on DocLayout-YOLO. Each arm's difference from it is paired over the pages
    both score, with a page-bootstrap interval.
  - The reading-order edit is not reported: the owner truth has no blank-line blocks, so it is undefined.

## Results: the 96

Tau is shown as [valid pages/pages], with the number of pages reaching tau 0.95 beside it.

| Detection · ordering | tau | ≥ 0.95 | Δ vs base [95% CI] | lines kept | word acc. |
|---|---|---:|---|---:|---:|
| none · Vision's line order | 0.972 [72/96] | 64 | +0.027 [+0.001, +0.056] | 100% | 75.1% |
| none · app line column sort | 0.971 [72/96] | 64 | +0.026 [−0.004, +0.057] | 100% | **75.6%** |
| none · top to bottom | 0.901 [72/96] | 55 | −0.048 [−0.098, −0.000] | 100% | 67.3% |
| DocLayout-YOLO · app region sort (base) | 0.945 [68/96] | 50 | – | 92% | 71.4% |
| DocLayout-YOLO · XY-cut, rows first | 0.961 [68/96] | 56 | +0.016 [−0.001, +0.034] | 92% | 72.0% |
| DocLayout-YOLO · HDBSCAN rule | 0.955 [68/96] | 54 | +0.010 [−0.010, +0.029] | 92% | 70.6% |
| DocLayout-YOLO · benchmark column clustering | 0.889 [68/96] | 49 | −0.055 [−0.101, −0.017] | 92% | 68.0% |
| PP-DocLayoutV3 · its own order | **0.992** [66/96] | 63 | +0.047 [+0.023, +0.078] | 82% | 69.0% |
| PP-DocLayoutV3 · HDBSCAN rule | 0.972 [66/96] | 58 | +0.026 [−0.001, +0.056] | 82% | 66.5% |
| PP-DocLayoutV3 · app region sort | 0.961 [66/96] | 53 | +0.014 [−0.005, +0.040] | 82% | 66.8% |
| Vision regions · its own order | 0.958 [70/96] | 60 | +0.013 [−0.016, +0.044] | 92% | 73.2% |
| Vision regions · app region sort | 0.923 [70/96] | 53 | −0.024 [−0.070, +0.018] | 92% | 70.4% |

Every other arm and every page group are in the JSON. Tau by page kind for four arms:

| Arm | typed | clippings | tables | handwritten |
|---|---|---|---|---|
| none · Vision's line order | 0.997 [40/41] | 0.883 [11/13] | 0.948 [6/12] | 0.997 [3/16] |
| none · app line column sort | 0.996 [40/41] | 0.884 [11/13] | 0.955 [6/12] | 0.991 [3/16] |
| DocLayout-YOLO · app region sort | 0.959 [39/41] | 0.893 [9/13] | 0.873 [6/12] | 0.996 [2/16] |
| PP-DocLayoutV3 · its own order | 0.997 [39/41] | 0.995 [10/13] | 0.986 [5/12] | 1.000 [3/16] |

## Results: marks on the owner core

There are 45 owner marks on 32 pages. A mark reaches a stream when one kept region, or Vision's lines inside the
mark, cover at least half its box. Each cell is found/of, with a 95% page-bootstrap interval.

| Stream | all | touching print | clear of print | A-core | B-core |
|---|---|---|---|---|---|
| Vision lines | 30/45 (54–79%) | 9/18 | 21/27 | 5/6 | 25/39 |
| DocLayout-YOLO, the app's filter (text, title) | 7/45 (4–34%) | 4/18 | 3/27 | 2/6 | 5/39 |
| DocLayout-YOLO, pictures and tables kept | 26/45 (29–78%) | 10/18 | 16/27 | 2/6 | 24/39 |
| DocLayout-YOLO, any region | 32/45 (48–87%) | 13/18 | 19/27 | 4/6 | 28/39 |
| PP-DocLayoutV3, text classes | 2/45 (0–10%) | 0/18 | 2/27 | 0/6 | 2/39 |
| PP-DocLayoutV3, any region | 3/45 (0–13%) | 0/18 | 3/27 | 0/6 | 3/39 |

## What it says

1. **No trained orderer is needed for the owner's pages.** Several free arms are above tau 0.95 on the 96:
   PP-DocLayoutV3's own order (0.992), Vision's line order (0.972), the app's line column sort (0.971) and the
   rows-first XY-cut on YOLO regions (0.961). By the rule W46.layout-order-train carries, that item moves behind
   W46.nice-to-have.
2. **Order and coverage pull apart.**
   - PP-DocLayoutV3 orders best, and has the highest tau on clippings and tables. It keeps only
     82% of the lines, so its word accuracy (69.0%) is below the no-detector arms (75.1-75.6%).
   - The app's line column sort with no detector loses nothing and orders about as well as Vision's own order.
     For a whole-page reading of the owner's typed pages, which are most of them, it is enough.
   - Where a detector is used, the region orderer matters less than the detector does.
3. **The app's region filter drops the marks.** With the app's filter (text and title only), DocLayout-YOLO's stream
   keeps 7 of 45 marks. Keeping pictures and tables raises that to 26, which confirms LAY-2. PP-DocLayoutV3 keeps
   3 at most, as W46.marks-detect found. Vision's lines read 30 of 45, and 21 of the 27 that are clear of print.
   Any route that reads regions has to keep pictures, or read marks in a separate layer (W46.marks-detect).
4. **Handwriting is not settled here.** Only 2-3 of the 16 handwritten pages place 15 lines in the truth, so the
   handwritten column rests on 3 pages.

## Measurement card

- **Truth.**
  - The 96: the owner's adjudicated truth text (`ocr-truth.md`). Claude Opus 5.5 and Gemini 3.8 Flash drafted it,
    and the owner checked it. Neither drafter is an arm here.
  - Marks: the reconciled owner core (`marks-set-reconciled-da388b05c388-dac79c80c2f6`). The boxes are rough
    Gemini 3.7 Flash and Qwen3-VL 8B drafts that the owner kept, so the half-box cover rule is loose on purpose.
    Neither detector drafted a mark.
- **Selection.**
  - The 96 are the frozen benchmark set.
  - The marks pages are the core's two-phase selection: A-core is independent of every route, and B-core came
    from Qwen3.6-27B's pre-flag. They are reported apart, with no population weights.
  - Neither set was chosen by a tested route or by ABBYY text.
- **Comparison.** Every arm uses the same Vision lines, so recognition is equal across arms. Detection is fixed per
  detector, at the settings W46.layout-photo used. Only the owner's set is scored here. The public pages are
  W46.layout-order's, whose geometric arms are the same code, so both sets are covered between the two items.
- **Noise.** n is 66-72 valid pages for the 96 and 45 marks. The intervals are paired page bootstraps. The
  orderers and Vision are deterministic, so there is no rerun floor to add. Differences whose interval holds zero
  are ties: most region-orderer pairs on one detector are ties.
- **Scope.**
  - This does not rank OCR routes.
  - It does not measure order on handwritten pages: 3 of 16 are valid.
  - It does not say where a kept mark should sit in the stream, which is a design choice with no truth yet.
  - kraken blla's native order is not run on the 96.
