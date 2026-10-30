# The region and tile arms, rescored order-free (W46.ocr-rescore-offline)

Measured 2026-10-30 from the cached readings of `regions-20261021` (four open readers, Sherlock) and
`regions-gateway-20261028` (Gemini 3.7 Flash, the Stanford gateway). Each page is stitched exactly as those
reports stitched it, and every page's NES reproduces theirs, except the open readers' p025 and p088, which are
rescored here on the owner's 2026-10-29 truth corrections. $0: no model, network or cluster.
Script: `scripts/segbench/corpus/regions_orderfree.py`. 5,940 page readings scored.

## What this changes

- **Reading order inflated the arms' losses on the 96, and the losses still stand.** The measurement audit's OCR-6
  asked how much of the -11.9 and -5.7 was order, since the 96's truth has no reading order to score.
  Gemini 3.7 Flash, PP-DocLayoutV3 regions: -11.9 in order, -7.5 (-10.8 to -4.8) order-free. Tiles: -5.7 in order, -2.4 (-3.8 to -1.0) order-free.
  Qwen3.6-27B: regions -9.3 in order, -6.4 (-9.8 to -3.7) order-free. Tiles: -5.2 in order, -2.8 (-4.1 to -1.6) order-free.
  Every one of these intervals stays below 0, so whole-page reading remains the default. What is left after order
  is roughly 40 to 70 per cent of the in-order loss.
- **What is left after order is content.** Regions miss words: the missed rate rises, most of all on hands.
  Gemini on the 16 hand pages: -24.8 in order, -17.6 (-32.1 to -6.0) order-free, with the missed rate up
  +18.4 points. Tiles add words: where the
  stitch does not find the repeat, the overlap band is read twice. For Gemini on the 96 the added rate is up
  +8.5 points, and on clippings it is up 23 to 36 for every reader.
  On hand pages, Gemini's tiles are a tie order-free (-1.1 (-4.5 to +1.2)).
- **Typed pages with no table or clipping:** tiles are a tie order-free for Qwen and LightOn; for Gemini they
  cost a fifth of a point (-0.18 (-0.37 to -0.02)), small, but its
  interval stays below 0. The small readers' tile gains that regions-20261021.md reported (GLM-OCR, PaddleOCR-VL 1.5) keep
  their direction order-free, but their intervals reach 0.
- **Newspapers (L9) do not change in kind.** Regions lift the two small readers by more than 60 points order-free.
  Tiles lift them about 11 points and cost LightOn and Qwen most of their L9 score, so the fixed tiler stays ruled
  out. **Registers (L4):** Qwen's tiles, a tie in order (+3.3 (-0.7 to +7.9)), are a gain
  order-free (+5.9 (+1.3 to +11.1)); no other L4 verdict changes (GLM-OCR's tiles stay a tie).
- **The cells arms are not rescored.** They return named table fields, each scored by exact match, so there is no
  reading order to remove. Their receipts are on Sherlock, not on this Mac (regions-cells-20261025.md).

## Measurement card

- **Truth.** The 96: drafted by Claude Opus 5.5 and Gemini 3.8 Flash, with their disagreements adjudicated by the
  owner and the two 2026-10-29 corrections applied. Gemini 3.7 is a close relative of a drafter, so its whole-page
  figure may be flattered, but both sides of each difference are the same reader against the same truth. L1, L3,
  L4 and L9 use the public sets' own published truth, which is independent of every route here.
- **Selection.** The parent reports' pages: all 96, plus the frozen L1, L3, L4 and L9 pages of the 895 for the open
  readers. For Gemini, three public pages a stratum, drawn by a stable hash of the page id (regions_gateway.choose).
  No tested route and no ABBYY text chose a page.
- **Comparison.** Each arm is compared page for page with the same reader's whole-page reading at the same settings.
  A page an arm returned nothing for scores 0 on both NES and bowF1, as the reports scored it. Both OCR sets: the 96
  and the public strata. Gemini's public rows are 3 pages a stratum, a labelled sample, not a set result.
- **Noise.** 95% paired bootstrap intervals over pages (ocr_panel_score.paired). No rerun-noise floor exists yet
  (W46.ocr-rerun-noise), so a difference whose interval crosses 0 is a tie.
- **Scope.** bowF1 credits the right words in any order, but a reader of the page needs the order. The order-free
  figure is therefore the lower bound of the content loss, and it does not make an arm's jumbled text usable. It does
  not re-decide the layout routes for newspapers (W46.layout-photo, W46.layout-order) or the cells arms.

## Columns

ΔNES is the arm less the whole page in reading-order character similarity, the figure the reports judged on.
ΔbowF1 is the same difference in NewsBench's bag-of-words F1, which ignores order: the loss left once the order
penalty is removed. Δgap is the change in NewsBench's order gap (bowF1 less 1 - CER), its own order penalty.
1 - CER falls below 0 where a reading repeats text, so the gap is large on tiles and is not on the NES scale.
Missed and added are word rates over the truth's words, arm less whole. Intervals are 95% paired bootstrap over
pages.

## Gemini 3.7 Flash (the gateway default)

| group | reader | arm | pages | whole NES | arm NES | ΔNES | ΔbowF1 (order-free) | Δgap | Δmissed | Δadded |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| the 96 | Gemini 3.7 Flash | PP-DocLayoutV3 | 96 | 96.7 | 84.9 | -11.9 (-15.6 to -8.5) | -7.5 (-10.8 to -4.8) | +5.2 | +5.6 | +3.6 |
| the 96 | Gemini 3.7 Flash | tiles | 96 | 96.7 | 91.0 | -5.7 (-8.3 to -3.3) | -2.4 (-3.8 to -1.0) | +4.5 | +2.7 | +8.5 |
| handwritten | Gemini 3.7 Flash | PP-DocLayoutV3 | 16 | 95.1 | 70.3 | -24.8 (-39.1 to -12.4) | -17.6 (-32.1 to -6.0) | +7.7 | +18.4 | +3.5 |
| handwritten | Gemini 3.7 Flash | tiles | 16 | 95.1 | 90.6 | -4.5 (-9.1 to -1.1) | -1.1 (-4.5 to +1.2) | +3.0 | +0.1 | +1.7 |
| typed, no table or clipping | Gemini 3.7 Flash | PP-DocLayoutV3 | 41 | 98.8 | 95.4 | -3.4 (-5.7 to -1.6) | -2.0 (-3.5 to -0.9) | +1.1 | +3.2 | +1.2 |
| typed, no table or clipping | Gemini 3.7 Flash | tiles | 41 | 98.8 | 98.4 | -0.4 (-1.2 to +0.3) | -0.2 (-0.4 to -0.0) | -0.2 | +0.1 | +0.1 |
| clippings | Gemini 3.7 Flash | PP-DocLayoutV3 | 13 | 95.6 | 79.7 | -16.0 (-26.9 to -7.9) | -10.3 (-20.1 to -3.2) | +8.2 | +7.7 | +6.2 |
| clippings | Gemini 3.7 Flash | tiles | 13 | 95.6 | 76.9 | -18.7 (-30.6 to -7.4) | -8.6 (-15.0 to -2.8) | +21.1 | -0.1 | +36.3 |
| tables | Gemini 3.7 Flash | PP-DocLayoutV3 | 12 | 99.0 | 83.4 | -15.5 (-28.4 to -4.7) | -8.7 (-18.1 to -1.6) | +11.7 | +4.9 | +6.2 |
| tables | Gemini 3.7 Flash | tiles | 12 | 99.0 | 97.7 | -1.2 (-3.7 to +0.6) | -0.2 (-1.6 to +0.9) | +0.7 | +2.2 | +0.0 |
| L9 | Gemini 3.7 Flash | PP-DocLayoutV3 | 3 | 97.8 | 82.4 | -15.4 (-19.1 to -11.0) | -4.9 (-6.7 to -2.9) | +10.8 | +0.5 | +9.6 |
| L9 | Gemini 3.7 Flash | tiles | 3 | 97.8 | 43.8 | -54.0 (-59.4 to -49.7) | -18.7 (-23.0 to -13.2) | +65.9 | -2.0 | +50.1 |
| L4 | Gemini 3.7 Flash | PP-DocLayoutV3 | 3 | 75.8 | 63.4 | -12.4 (-24.2 to -1.0) | -16.7 (-38.6 to -5.0) | -7.1 | +23.3 | -3.7 |
| L4 | Gemini 3.7 Flash | tiles | 3 | 75.8 | 76.4 | +0.6 (-2.8 to +5.4) | +0.6 (-1.8 to +1.8) | +1.1 | -1.6 | +1.2 |
| L3 | Gemini 3.7 Flash | PP-DocLayoutV3 | 3 | 98.2 | 92.1 | -6.1 (-9.8 to -0.6) | -2.7 (-5.1 to +0.0) | +2.0 | +4.0 | -1.2 |
| L3 | Gemini 3.7 Flash | tiles | 3 | 98.2 | 96.4 | -1.8 (-3.8 to +0.4) | -0.2 (-1.5 to +1.3) | +1.0 | +0.4 | +0.0 |
| L1 | Gemini 3.7 Flash | PP-DocLayoutV3 | 3 | 90.2 | 86.4 | -3.8 (-8.9 to +0.5) | +1.0 (-3.4 to +6.3) | +2.9 | +1.9 | -3.8 |
| L1 | Gemini 3.7 Flash | tiles | 3 | 90.2 | 80.7 | -9.6 (-14.8 to -3.6) | -5.5 (-8.3 to -1.4) | +2.8 | +4.2 | +1.9 |

## The four open readers

| group | reader | arm | pages | whole NES | arm NES | ΔNES | ΔbowF1 (order-free) | Δgap | Δmissed | Δadded |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| the 96 | GLM-OCR | DocLayout-YOLO | 96 | 90.9 | 70.9 | -20.0 (-27.3 to -13.2) | -15.3 (-22.4 to -8.8) | +9.0 | +4.4 | +2.8 |
| the 96 | GLM-OCR | PP-DocLayoutV3 | 96 | 90.9 | 84.9 | -6.0 (-9.7 to -2.6) | -3.8 (-7.1 to -0.3) | +2.8 | +1.8 | +1.2 |
| the 96 | GLM-OCR | tiles | 96 | 90.9 | 87.8 | -3.1 (-5.9 to -0.5) | -0.5 (-2.5 to +2.2) | +5.9 | +0.2 | +8.0 |
| the 96 | LightOnOCR-3 4B | DocLayout-YOLO | 96 | 89.4 | 67.5 | -21.8 (-29.0 to -15.1) | -17.5 (-24.4 to -10.9) | +13.1 | +4.5 | +5.2 |
| the 96 | LightOnOCR-3 4B | PP-DocLayoutV3 | 96 | 89.4 | 80.5 | -8.9 (-12.8 to -5.2) | -5.9 (-9.5 to -2.5) | +6.7 | +1.5 | +2.2 |
| the 96 | LightOnOCR-3 4B | tiles | 96 | 89.4 | 84.0 | -5.4 (-8.2 to -2.9) | -3.1 (-4.8 to -1.6) | +7.1 | +1.8 | +10.0 |
| the 96 | PaddleOCR-VL 1.5 | DocLayout-YOLO | 96 | 83.8 | 70.2 | -13.6 (-21.3 to -5.9) | -8.2 (-15.5 to -1.1) | +9.5 | -0.4 | +2.6 |
| the 96 | PaddleOCR-VL 1.5 | PP-DocLayoutV3 | 96 | 83.8 | 83.0 | -0.7 (-5.4 to +4.2) | +1.7 (-3.0 to +6.8) | +3.9 | -2.8 | +2.0 |
| the 96 | PaddleOCR-VL 1.5 | tiles | 96 | 83.8 | 84.2 | +0.4 (-4.8 to +5.9) | +4.5 (-0.2 to +9.7) | +7.3 | -3.2 | +7.0 |
| the 96 | Qwen3.6-27B | DocLayout-YOLO | 96 | 95.0 | 71.7 | -23.3 (-30.6 to -16.6) | -18.4 (-25.4 to -12.0) | +9.1 | +7.3 | +1.9 |
| the 96 | Qwen3.6-27B | PP-DocLayoutV3 | 96 | 95.0 | 85.7 | -9.3 (-13.2 to -5.9) | -6.4 (-9.8 to -3.7) | +3.5 | +4.3 | +0.6 |
| the 96 | Qwen3.6-27B | tiles | 96 | 95.0 | 89.8 | -5.2 (-8.1 to -2.6) | -2.8 (-4.1 to -1.6) | +6.0 | +2.0 | +8.2 |
| handwritten | GLM-OCR | DocLayout-YOLO | 16 | 85.6 | 11.0 | -74.6 (-84.4 to -61.7) | -73.5 (-82.0 to -61.8) | +1.7 | +74.3 | -8.4 |
| handwritten | GLM-OCR | PP-DocLayoutV3 | 16 | 85.6 | 70.2 | -15.5 (-28.4 to -4.5) | -13.1 (-24.8 to -3.8) | +4.0 | +15.0 | -1.3 |
| handwritten | GLM-OCR | tiles | 16 | 85.6 | 86.9 | +1.3 (-0.1 to +3.0) | +1.3 (+0.1 to +2.4) | -0.1 | -1.4 | -0.8 |
| handwritten | LightOnOCR-3 4B | DocLayout-YOLO | 16 | 88.8 | 11.2 | -77.6 (-87.5 to -64.4) | -78.7 (-87.1 to -66.5) | +0.6 | +78.7 | -1.1 |
| handwritten | LightOnOCR-3 4B | PP-DocLayoutV3 | 16 | 88.8 | 67.7 | -21.1 (-35.5 to -8.7) | -17.8 (-32.0 to -6.1) | +13.5 | +14.3 | +9.1 |
| handwritten | LightOnOCR-3 4B | tiles | 16 | 88.8 | 87.5 | -1.4 (-5.8 to +2.1) | -0.9 (-3.3 to +1.1) | +2.9 | -1.4 | +4.3 |
| handwritten | PaddleOCR-VL 1.5 | DocLayout-YOLO | 16 | 70.8 | 11.1 | -59.7 (-77.7 to -39.3) | -55.7 (-72.4 to -37.4) | +4.0 | +58.8 | -6.0 |
| handwritten | PaddleOCR-VL 1.5 | PP-DocLayoutV3 | 16 | 70.8 | 66.4 | -4.4 (-21.2 to +11.6) | -0.8 (-15.9 to +14.5) | +3.8 | +2.6 | +5.5 |
| handwritten | PaddleOCR-VL 1.5 | tiles | 16 | 70.8 | 73.1 | +2.3 (-12.9 to +18.2) | +8.9 (-5.5 to +24.6) | +1.6 | -9.3 | +7.1 |
| handwritten | Qwen3.6-27B | DocLayout-YOLO | 16 | 90.9 | 11.2 | -79.7 (-89.8 to -66.2) | -78.5 (-87.9 to -66.1) | +0.6 | +81.9 | -5.3 |
| handwritten | Qwen3.6-27B | PP-DocLayoutV3 | 16 | 90.9 | 72.0 | -18.9 (-33.1 to -7.1) | -15.6 (-29.6 to -4.7) | +4.0 | +18.7 | +0.2 |
| handwritten | Qwen3.6-27B | tiles | 16 | 90.9 | 87.6 | -3.3 (-5.9 to -1.3) | -2.2 (-4.1 to -0.5) | +3.0 | +0.8 | +3.5 |
| typed, no table or clipping | GLM-OCR | DocLayout-YOLO | 41 | 94.0 | 92.8 | -1.2 (-4.6 to +2.6) | +1.2 (-2.4 to +6.8) | +2.6 | -1.8 | +3.4 |
| typed, no table or clipping | GLM-OCR | PP-DocLayoutV3 | 41 | 94.0 | 94.7 | +0.6 (-2.7 to +4.4) | +1.9 (-1.8 to +7.6) | +0.1 | -0.0 | +1.2 |
| typed, no table or clipping | GLM-OCR | tiles | 41 | 94.0 | 96.2 | +2.1 (+0.1 to +5.3) | +2.8 (-0.0 to +8.0) | -0.4 | -2.4 | +0.4 |
| typed, no table or clipping | LightOnOCR-3 4B | DocLayout-YOLO | 41 | 96.8 | 88.8 | -7.9 (-12.9 to -3.6) | -4.4 (-7.6 to -1.9) | +9.3 | -0.8 | +9.3 |
| typed, no table or clipping | LightOnOCR-3 4B | PP-DocLayoutV3 | 41 | 96.8 | 91.6 | -5.2 (-8.0 to -2.7) | -2.6 (-4.1 to -1.2) | +3.0 | +1.4 | +2.5 |
| typed, no table or clipping | LightOnOCR-3 4B | tiles | 41 | 96.8 | 96.3 | -0.5 (-2.0 to +0.7) | +0.1 (-0.1 to +0.4) | +0.4 | -0.8 | -0.2 |
| typed, no table or clipping | PaddleOCR-VL 1.5 | DocLayout-YOLO | 41 | 90.2 | 92.5 | +2.3 (-5.0 to +11.2) | +5.1 (-1.7 to +13.8) | +3.8 | -8.1 | +2.4 |
| typed, no table or clipping | PaddleOCR-VL 1.5 | PP-DocLayoutV3 | 41 | 90.2 | 93.5 | +3.4 (-1.7 to +9.8) | +5.4 (-0.5 to +12.9) | +1.8 | -5.8 | +0.3 |
| typed, no table or clipping | PaddleOCR-VL 1.5 | tiles | 41 | 90.2 | 96.1 | +6.0 (-0.7 to +14.6) | +6.8 (-0.0 to +15.9) | +0.9 | -8.5 | +0.0 |
| typed, no table or clipping | Qwen3.6-27B | DocLayout-YOLO | 41 | 98.0 | 93.7 | -4.3 (-7.8 to -1.6) | -2.1 (-4.0 to -0.6) | +3.1 | +0.8 | +2.2 |
| typed, no table or clipping | Qwen3.6-27B | PP-DocLayoutV3 | 41 | 98.0 | 95.3 | -2.7 (-5.0 to -0.9) | -1.5 (-2.7 to -0.5) | +1.0 | +2.9 | -0.1 |
| typed, no table or clipping | Qwen3.6-27B | tiles | 41 | 98.0 | 97.9 | -0.2 (-0.7 to +0.3) | -0.1 (-0.3 to +0.1) | +0.0 | -0.2 | -0.3 |
| clippings | GLM-OCR | DocLayout-YOLO | 13 | 86.9 | 86.6 | -0.3 (-11.1 to +8.8) | +0.5 (-5.2 to +4.8) | +10.7 | -7.8 | +4.4 |
| clippings | GLM-OCR | PP-DocLayoutV3 | 13 | 86.9 | 81.8 | -5.1 (-15.2 to +3.0) | -4.2 (-12.8 to +2.7) | +3.8 | -1.2 | +0.6 |
| clippings | GLM-OCR | tiles | 13 | 86.9 | 71.8 | -15.1 (-26.3 to -4.7) | -6.3 (-12.0 to -1.3) | +20.2 | -5.3 | +34.2 |
| clippings | LightOnOCR-3 4B | DocLayout-YOLO | 13 | 90.3 | 85.2 | -5.1 (-19.0 to +6.0) | -0.2 (-10.9 to +7.6) | +16.0 | -5.9 | +1.8 |
| clippings | LightOnOCR-3 4B | PP-DocLayoutV3 | 13 | 90.3 | 78.6 | -11.7 (-25.5 to -0.0) | -5.7 (-18.8 to +5.2) | +10.5 | +0.1 | +1.1 |
| clippings | LightOnOCR-3 4B | tiles | 13 | 90.3 | 74.0 | -16.4 (-28.6 to -5.0) | -8.0 (-14.0 to -2.3) | +20.9 | -1.0 | +35.5 |
| clippings | PaddleOCR-VL 1.5 | DocLayout-YOLO | 13 | 79.8 | 82.7 | +2.8 (-9.5 to +15.5) | +7.4 (-2.5 to +20.8) | +17.0 | -5.9 | +5.5 |
| clippings | PaddleOCR-VL 1.5 | PP-DocLayoutV3 | 13 | 79.8 | 81.1 | +1.3 (-6.2 to +10.1) | +4.6 (-2.7 to +14.2) | +8.1 | -1.5 | +2.0 |
| clippings | PaddleOCR-VL 1.5 | tiles | 13 | 79.8 | 69.6 | -10.2 (-25.0 to +4.8) | +0.8 (-11.0 to +14.8) | +23.4 | +2.3 | +23.4 |
| clippings | Qwen3.6-27B | DocLayout-YOLO | 13 | 93.6 | 88.1 | -5.5 (-14.8 to +2.1) | -2.4 (-7.5 to +1.0) | +13.8 | -2.6 | +2.9 |
| clippings | Qwen3.6-27B | PP-DocLayoutV3 | 13 | 93.6 | 82.0 | -11.6 (-22.7 to -3.8) | -7.7 (-17.3 to -0.5) | +7.5 | +4.0 | +1.4 |
| clippings | Qwen3.6-27B | tiles | 13 | 93.6 | 76.4 | -17.2 (-29.1 to -6.4) | -8.0 (-13.7 to -2.9) | +21.1 | -1.2 | +35.0 |
| tables | GLM-OCR | DocLayout-YOLO | 12 | 91.9 | 76.3 | -15.6 (-29.0 to -4.5) | -4.2 (-9.4 to -0.1) | +31.0 | -0.7 | +11.1 |
| tables | GLM-OCR | PP-DocLayoutV3 | 12 | 91.9 | 82.8 | -9.1 (-18.3 to -2.3) | -4.6 (-10.8 to -0.2) | +6.2 | +4.0 | +1.8 |
| tables | GLM-OCR | tiles | 12 | 91.9 | 88.9 | -3.0 (-8.2 to +0.6) | -2.7 (-7.3 to +0.1) | +15.4 | +1.7 | +6.4 |
| tables | LightOnOCR-3 4B | DocLayout-YOLO | 12 | 68.2 | 62.3 | -5.9 (-17.6 to +5.5) | +2.0 (-6.4 to +11.8) | +37.9 | -10.5 | +10.2 |
| tables | LightOnOCR-3 4B | PP-DocLayoutV3 | 12 | 68.2 | 73.3 | +5.1 (-4.3 to +14.6) | +6.4 (-2.2 to +15.9) | -13.0 | -8.2 | -10.7 |
| tables | LightOnOCR-3 4B | tiles | 12 | 68.2 | 65.2 | -2.9 (-6.3 to +0.0) | -3.4 (-6.4 to -0.9) | +15.1 | +0.8 | +7.3 |
| tables | PaddleOCR-VL 1.5 | DocLayout-YOLO | 12 | 82.1 | 75.4 | -6.7 (-19.7 to +4.8) | +0.2 (-6.8 to +10.0) | +21.9 | -1.9 | +9.7 |
| tables | PaddleOCR-VL 1.5 | PP-DocLayoutV3 | 12 | 82.1 | 81.7 | -0.4 (-14.2 to +13.7) | -0.3 (-9.9 to +11.3) | +5.3 | +1.8 | +3.9 |
| tables | PaddleOCR-VL 1.5 | tiles | 12 | 82.1 | 84.0 | +1.9 (-3.2 to +8.2) | +1.6 (-3.3 to +9.0) | +18.9 | -2.1 | +9.8 |
| tables | Qwen3.6-27B | DocLayout-YOLO | 12 | 94.8 | 78.4 | -16.4 (-29.8 to -5.2) | -5.3 (-10.8 to -0.5) | +29.3 | +0.3 | +10.3 |
| tables | Qwen3.6-27B | PP-DocLayoutV3 | 12 | 94.8 | 85.3 | -9.6 (-19.7 to -2.1) | -5.3 (-11.7 to -1.0) | +4.7 | +4.0 | +0.8 |
| tables | Qwen3.6-27B | tiles | 12 | 94.8 | 91.0 | -3.8 (-8.2 to -0.0) | -2.7 (-7.0 to -0.0) | +14.0 | +1.8 | +5.4 |
| L9 | GLM-OCR | DocLayout-YOLO | 15 | 29.2 | 91.1 | +61.9 (+41.8 to +80.5) | +63.8 (+41.5 to +85.0) | +1.7 | -76.4 | +3.8 |
| L9 | GLM-OCR | PP-DocLayoutV3 | 15 | 29.2 | 86.2 | +57.0 (+37.5 to +74.8) | +61.6 (+39.9 to +82.0) | +4.5 | -73.3 | +5.8 |
| L9 | GLM-OCR | tiles | 15 | 29.2 | 29.6 | +0.4 (-16.4 to +16.7) | +10.7 (-5.2 to +27.7) | +15.2 | -9.0 | +5.8 |
| L9 | LightOnOCR-3 4B | DocLayout-YOLO | 15 | 92.5 | 88.4 | -4.1 (-9.1 to +2.0) | -3.2 (-5.7 to +0.4) | +0.8 | -2.1 | +8.2 |
| L9 | LightOnOCR-3 4B | PP-DocLayoutV3 | 15 | 92.5 | 83.6 | -8.9 (-13.2 to -3.7) | -5.8 (-7.9 to -2.7) | +3.1 | +0.7 | +11.3 |
| L9 | LightOnOCR-3 4B | tiles | 15 | 92.5 | 34.7 | -57.8 (-71.5 to -45.3) | -44.4 (-63.9 to -26.7) | +29.4 | +44.5 | +22.9 |
| L9 | PaddleOCR-VL 1.5 | DocLayout-YOLO | 15 | 0.0 | 92.3 | +92.3 (+89.0 to +95.3) | +97.5 (+96.7 to +98.3) | +4.6 | -97.7 | +2.8 |
| L9 | PaddleOCR-VL 1.5 | PP-DocLayoutV3 | 15 | 0.0 | 89.7 | +89.7 (+86.9 to +92.3) | +96.4 (+95.1 to +97.4) | +6.0 | -93.9 | +1.7 |
| L9 | PaddleOCR-VL 1.5 | tiles | 15 | 0.0 | 8.1 | +8.1 (+0.7 to +17.9) | +11.7 (+1.3 to +24.8) | +3.6 | -5.7 | +0.4 |
| L9 | Qwen3.6-27B | DocLayout-YOLO | 15 | 93.5 | 88.9 | -4.6 (-9.9 to +1.7) | -3.3 (-5.1 to -1.1) | +1.3 | +0.0 | +6.5 |
| L9 | Qwen3.6-27B | PP-DocLayoutV3 | 15 | 93.5 | 83.0 | -10.6 (-16.0 to -5.1) | -5.5 (-7.1 to -3.5) | +5.1 | +2.9 | +8.2 |
| L9 | Qwen3.6-27B | tiles | 15 | 93.5 | 25.7 | -67.9 (-80.2 to -55.4) | -56.6 (-75.8 to -37.9) | +29.1 | +57.2 | +23.2 |
| L4 | GLM-OCR | DocLayout-YOLO | 80 | 59.7 | 1.2 | -58.5 (-61.9 to -55.1) | -59.5 (-62.4 to -56.4) | -1.4 | +51.0 | -22.8 |
| L4 | GLM-OCR | PP-DocLayoutV3 | 80 | 59.7 | 48.9 | -10.8 (-14.8 to -6.8) | -9.4 (-12.8 to -6.1) | +1.2 | +7.3 | +2.0 |
| L4 | GLM-OCR | tiles | 80 | 59.7 | 57.9 | -1.8 (-3.7 to +0.3) | +0.5 (-0.9 to +2.6) | +3.3 | -3.7 | +7.4 |
| L4 | LightOnOCR-3 4B | DocLayout-YOLO | 80 | 55.0 | 5.7 | -49.3 (-53.0 to -45.5) | -61.4 (-64.4 to -58.4) | -5.5 | +54.9 | -24.3 |
| L4 | LightOnOCR-3 4B | PP-DocLayoutV3 | 80 | 55.0 | 37.7 | -17.3 (-21.1 to -13.6) | -17.2 (-21.0 to -13.6) | +34.2 | +7.9 | +43.2 |
| L4 | LightOnOCR-3 4B | tiles | 80 | 55.0 | 52.9 | -2.1 (-3.5 to -0.8) | -2.8 (-4.8 to -1.0) | +8.1 | -0.9 | +9.2 |
| L4 | PaddleOCR-VL 1.5 | DocLayout-YOLO | 80 | 28.2 | 1.2 | -27.0 (-32.8 to -21.2) | -23.8 (-29.0 to -18.7) | +2.3 | +20.3 | -27.5 |
| L4 | PaddleOCR-VL 1.5 | PP-DocLayoutV3 | 80 | 28.2 | 37.2 | +9.0 (+3.4 to +14.9) | +11.2 (+6.2 to +16.2) | +2.2 | -12.3 | +2.0 |
| L4 | PaddleOCR-VL 1.5 | tiles | 80 | 28.2 | 35.8 | +7.6 (+2.1 to +13.2) | +8.8 (+3.8 to +13.8) | +4.6 | -9.5 | +9.8 |
| L4 | Qwen3.6-27B | DocLayout-YOLO | 80 | 69.3 | 1.3 | -68.0 (-73.2 to -62.1) | -67.8 (-72.7 to -62.2) | -0.1 | +66.9 | -19.6 |
| L4 | Qwen3.6-27B | PP-DocLayoutV3 | 80 | 69.3 | 53.4 | -15.9 (-22.5 to -8.8) | -10.2 (-16.1 to -3.9) | +5.6 | +15.9 | +3.5 |
| L4 | Qwen3.6-27B | tiles | 80 | 69.3 | 72.6 | +3.3 (-0.7 to +7.9) | +5.9 (+1.3 to +11.1) | +2.8 | -4.3 | +2.0 |
| L3 | GLM-OCR | DocLayout-YOLO | 80 | 92.0 | 71.9 | -20.1 (-27.0 to -13.7) | -12.8 (-19.5 to -6.6) | +9.1 | +1.8 | +6.3 |
| L3 | GLM-OCR | PP-DocLayoutV3 | 80 | 92.0 | 87.7 | -4.3 (-9.2 to -0.2) | -3.8 (-8.6 to +0.2) | +0.4 | +0.8 | +1.5 |
| L3 | GLM-OCR | tiles | 80 | 92.0 | 88.3 | -3.7 (-6.4 to -1.2) | -1.8 (-3.5 to -0.2) | +4.6 | -0.9 | +3.3 |
| L3 | LightOnOCR-3 4B | DocLayout-YOLO | 80 | 93.5 | 62.8 | -30.7 (-37.5 to -24.3) | -21.6 (-28.1 to -15.7) | +31.7 | +3.9 | +24.6 |
| L3 | LightOnOCR-3 4B | PP-DocLayoutV3 | 80 | 93.5 | 79.0 | -14.5 (-19.9 to -9.7) | -11.3 (-16.4 to -7.1) | +16.3 | +3.0 | +12.9 |
| L3 | LightOnOCR-3 4B | tiles | 80 | 93.5 | 93.5 | +0.1 (-0.5 to +0.7) | -0.1 (-0.5 to +0.2) | -0.2 | +0.1 | -0.1 |
| L3 | PaddleOCR-VL 1.5 | DocLayout-YOLO | 80 | 92.4 | 71.4 | -21.0 (-27.9 to -14.2) | -13.7 (-20.2 to -7.8) | +9.7 | +3.2 | +5.6 |
| L3 | PaddleOCR-VL 1.5 | PP-DocLayoutV3 | 80 | 92.4 | 86.9 | -5.5 (-10.2 to -1.3) | -4.5 (-9.1 to -0.8) | +1.1 | +2.2 | +0.3 |
| L3 | PaddleOCR-VL 1.5 | tiles | 80 | 92.4 | 91.3 | -1.1 (-2.3 to +0.0) | -0.3 (-0.9 to +0.4) | +1.1 | -0.1 | -0.2 |
| L3 | Qwen3.6-27B | DocLayout-YOLO | 80 | 96.0 | 72.5 | -23.6 (-30.7 to -16.9) | -15.4 (-22.1 to -9.3) | +9.7 | +6.5 | +5.4 |
| L3 | Qwen3.6-27B | PP-DocLayoutV3 | 80 | 96.0 | 88.6 | -7.5 (-12.0 to -3.8) | -6.3 (-11.0 to -2.5) | +1.0 | +5.6 | +0.2 |
| L3 | Qwen3.6-27B | tiles | 80 | 96.0 | 94.8 | -1.2 (-2.2 to -0.4) | -0.8 (-1.3 to -0.4) | +0.5 | +0.1 | +1.2 |
| L1 | GLM-OCR | DocLayout-YOLO | 80 | 78.6 | 3.8 | -74.8 (-79.9 to -69.2) | -70.7 (-76.0 to -64.9) | +4.1 | +71.9 | -15.3 |
| L1 | GLM-OCR | PP-DocLayoutV3 | 80 | 78.6 | 73.6 | -5.0 (-10.4 to +0.1) | -3.0 (-7.9 to +1.3) | +1.5 | -0.8 | +0.6 |
| L1 | GLM-OCR | tiles | 80 | 78.6 | 76.1 | -2.5 (-5.1 to +0.2) | -0.1 (-1.8 to +1.9) | +7.1 | -0.1 | +3.0 |
| L1 | LightOnOCR-3 4B | DocLayout-YOLO | 80 | 87.8 | 4.2 | -83.6 (-87.8 to -78.6) | -82.4 (-86.9 to -77.1) | +4.0 | +85.8 | -5.7 |
| L1 | LightOnOCR-3 4B | PP-DocLayoutV3 | 80 | 87.8 | 78.1 | -9.7 (-14.9 to -5.3) | -8.0 (-12.7 to -4.1) | +5.1 | +5.5 | +2.5 |
| L1 | LightOnOCR-3 4B | tiles | 80 | 87.8 | 84.7 | -3.1 (-5.9 to -0.3) | -1.3 (-2.7 to +0.1) | +2.7 | +2.7 | +4.1 |
| L1 | PaddleOCR-VL 1.5 | DocLayout-YOLO | 80 | 69.5 | 3.5 | -66.1 (-73.0 to -58.6) | -61.5 (-68.3 to -54.0) | +4.2 | +63.6 | -19.1 |
| L1 | PaddleOCR-VL 1.5 | PP-DocLayoutV3 | 80 | 69.5 | 68.3 | -1.2 (-6.9 to +4.5) | -0.1 (-5.3 to +5.0) | +0.8 | -2.1 | +0.0 |
| L1 | PaddleOCR-VL 1.5 | tiles | 80 | 69.5 | 66.9 | -2.7 (-7.6 to +2.5) | -0.0 (-4.4 to +4.9) | +8.6 | -2.2 | +4.5 |
| L1 | Qwen3.6-27B | DocLayout-YOLO | 80 | 88.4 | 4.0 | -84.4 (-88.5 to -79.5) | -81.5 (-86.2 to -76.2) | +3.5 | +86.4 | -9.5 |
| L1 | Qwen3.6-27B | PP-DocLayoutV3 | 80 | 88.4 | 77.1 | -11.2 (-16.4 to -6.8) | -8.6 (-13.1 to -4.9) | +2.4 | +7.0 | -0.0 |
| L1 | Qwen3.6-27B | tiles | 80 | 88.4 | 81.1 | -7.3 (-10.1 to -4.9) | -3.7 (-5.5 to -2.2) | +48.2 | +2.7 | +13.8 |

